
module Pulp.Exec
  ( exec
  , execQuiet
  , psc
  , pscBundle
  ) where

import Prelude
import Data.Either (Either(..), either)
import Data.Function
import Data.String (stripSuffix)
import Data.StrMap (StrMap())
import Data.Maybe (Maybe(..))
import Data.Maybe.Unsafe (fromJust)
import Data.Array as Array
import Control.Monad (when)
import Control.Monad.Error.Class (MonadError, throwError)
import Control.Monad.Eff.Exception (Error(), error)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Aff
import Control.Monad.Aff.AVar (takeVar, putVar, makeVar)
import Node.ChildProcess as CP
import Unsafe.Coerce (unsafeCoerce)

import Pulp.System.Process
import Pulp.System.Stream
import Pulp.System.FFI

psc :: Array String -> Array String -> Array String -> Maybe (StrMap String) -> AffN String
psc deps ffi args env =
  let allArgs = args <> deps <> (Array.concatMap (\path -> ["--ffi", path]) ffi)
  in  execQuiet "psc" allArgs env

pscBundle :: Array String -> Array String -> Maybe (StrMap String) -> AffN String
pscBundle files args env =
  execQuiet "psc-bundle" (files <> args) env

inheritAllButStdout :: Array (Maybe CP.StdIOBehaviour)
inheritAllButStdout = fromJust (Array.updateAt 1 (Just CP.Pipe) CP.inherit)

-- | Start a child process asynchronously, with the given command line
-- | arguments and environment, and wait for it to exit.
-- | On a non-zero exit code, throw an error.
--
-- | If the executable was not found and we are on Windows, retry with ".cmd"
-- | appended.
-- |
-- | Stdout, stdin, and stderr of the child process are shared with the pulp
-- | process (that is, data on stdin from pulp is relayed to the child process,
-- | and any stdout and stderr from the child process are relayed back out by
-- | pulp, which usually means they will immediately appear in the terminal).
exec :: String -> Array String -> Maybe (StrMap String) -> AffN Unit
exec cmd args env = do
  child <- liftEff $ CP.spawn cmd args (def { env = env
                                            , stdio = CP.inherit })
  wait child >>= either (handleErrors cmd retry) onExit

  where
  def = CP.defaultSpawnOptions

  onExit code =
    when (code > 0) $
      throwError $ error $ "Subcommand terminated with exit code " <> show code

  retry newCmd = exec newCmd args env

-- | Same as exec, except instead of relaying stdout immediately, it is
-- | captured and returned as a String.
execQuiet :: String -> Array String -> Maybe (StrMap String) -> AffN String
execQuiet cmd args env = do
  child <- liftEff $ CP.spawn cmd args (def { env = env
                                            , stdio = inheritAllButStdout })
  outVar <- makeVar
  forkAff (concatStream (CP.stdout child) >>= putVar outVar)
  wait child >>= either (handleErrors cmd retry) (onExit outVar)

  where
  def = CP.defaultSpawnOptions

  onExit outVar code =
    takeVar outVar >>= \childOut ->
      if code == 0
        then return childOut
        else do
          write stderr childOut
          throwError $ error $ "Subcommand terminated with exit code " <> show code

  retry newCmd = execQuiet newCmd args env

-- | A slightly weird combination of `onError` and `onExit` into one.
wait :: CP.ChildProcess -> AffN (Either CP.ChildProcessError Int)
wait child = makeAff \_ win -> do
  CP.onExit child (win <<< Right <<< toInt)
  CP.onError child (win <<< Left)
  where
  toInt (CP.Normally x) = x
  toInt (CP.BySignal _) = 127

handleErrors :: forall a. String -> (String -> AffN a) -> CP.ChildProcessError -> AffN a
handleErrors cmd retry err
  | err.code == "ENOENT" = do
     platformWin32 <- ("win32" ==) <$> liftEff getPlatform
     -- On windows, if the executable wasn't found, try adding .cmd
     if platformWin32
       then case stripSuffix ".cmd" cmd of
              Nothing      -> retry (cmd <> ".cmd")
              Just bareCmd -> throwError $ error $
                 "`" <> bareCmd <> "` executable not found. (nor `" <> cmd <> "`)"
       else
         throwError $ error $
           "`" <> cmd <> "` executable not found."
  | otherwise =
     throwError (toErr err)
     where
     toErr :: CP.ChildProcessError -> Error
     toErr = unsafeCoerce

concatStream :: forall a. ReadableStream a -> AffN String
concatStream stream = runNode $ runFn2 concatStream' stream

foreign import concatStream' :: forall a. Fn2 (ReadableStream a) (Callback String) Unit
