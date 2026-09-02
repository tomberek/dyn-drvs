{ pkgs, lib, self }:

# Cross the eval -> build boundary for an `args` value that's either:
#  - an arbitrary attrset (serialized as JSON, deserialized with fromJSON), or
#  - a literal string of Nix expression source (spliced in as-is via `import`).
#
# Ported from drowse's `__mkArgs.nix`. Used anywhere a `producer` needs to
# hand a value to code that runs *inside* a build (where there's no eval-time
# Nix language available to just reference the attrset directly) -- the value
# crosses via `passAsFile`/`getEnv`, and this decides which encoding to use.
#
# INTERNAL: this is plumbing for `builders.viaNixInstantiate` (its only
# caller), not a user-facing primitive -- deliberately NOT exported from
# `nix/default.nix`'s public attrset, only reachable via `self.mkArgs`
# from other lib files. Anyone writing their own `producer` from scratch
# and needing this exact eval->build boundary trick should just copy the
# pattern rather than reach for it as a stable public API.
#
# `env` is the env-var name prefix; callers are expected to set
# `passAsFile = [ "${env}" ]` and `${env} = (mkArgs env args).value`.

env: args:

if builtins.isString args then
  {
    load = /* nix */ ''(import (builtins.getEnv "${env}Path"))'';
    value = args;
  }
else
  {
    load = /* nix */ ''(builtins.fromJSON (builtins.readFile (builtins.getEnv "${env}Path")))'';
    value = builtins.toJSON args;
  }
