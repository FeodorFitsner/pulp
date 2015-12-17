// module Pulp.System.Process

"use strict";

exports.stdin = process.stdin;
exports.stdout = process.stdout;
exports.stderr = process.stderr;

exports["argv'"] = process.argv;

exports.exit = function exit(code) {
  return function() {
    process.exit(code);
  };
};

exports.getEnvironment = function getEnvironment() {
  return require('util')._extend({}, process.env);
};

exports.getPlatform = function getPlatform() {
  return process.platform;
};

exports.chdir = function chdir(dir) {
  return function() {
    process.chdir(dir);
  };
};

exports.cwd = function cwd() {
  return process.cwd();
};

exports.getEnvNullable = function getEnvNullable(envvar) {
  return function() {
    return process.env[envvar];
  };
};

exports.setEnv = function setEnv(envvar) {
  return function(val) {
    return function() {
      process.env[envvar] = val;
      return {};
    };
  };
};

exports.__dirname = __dirname;
exports.__filename = __filename;
