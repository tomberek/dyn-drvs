# Locks in the policy change: `mkDynamicDerivation`'s unset `backend` now
# defaults to `"builder-rpc-v0"` directly (a policy choice, not a
# detection result -- see mkDynamicDerivation.nix's and capabilities.nix's
# headers for why real detection is structurally impossible at eval
# time), while `backend = "auto"` still routes through
# `capabilities.selectBackend`'s conservative, eval-time-detected pick
# (today: always `"recursive-nix"`).
#
# Pure eval-time assertions -- `passthru.backend` is computed from
# `selectedBackend` at eval time regardless of backend, so no build is
# needed to check which one was chosen. Run with:
#   nix-instantiate --eval --extra-experimental-features "dynamic-derivations ca-derivations" \
#     --strict --json nix/tests/defaultBackend.nix

{ pkgs, lib, dyndrv }:

let
  mkProbe =
    extraArgs:
    dyndrv.mkDynamicDerivation (
      {
        pname = "dyndrv-default-backend-probe";
        version = "1.0";
        onUnsupported = "fail";
        producer = dyndrv.builders.viaDerivationAdd {
          nixPackage = pkgs.nix;
          toDrvJson = {
            name = "dyndrv-default-backend-probe-1.0";
            system = builtins.currentSystem;
            builder = "/bin/sh";
            args = [
              "-c"
              "echo hi > $out"
            ];
            env.out = "@dyndrv-placeholder:out@";
            inputs = {
              drvs = { };
              srcs = [ ];
            };
            outputs.out = {
              method = "nar";
              hashAlgo = "sha256";
            };
            version = 4;
          };
        };
      }
      // extraArgs
    );

  unsetDefaultsToBuilderRpcV0 = (mkProbe { }).dynamicDrv.backend == "builder-rpc-v0";

  autoMatchesCapabilitiesSelectBackend =
    (mkProbe { backend = "auto"; }).dynamicDrv.backend == dyndrv.capabilities.selectBackend (
      dyndrv.capabilities.detect { }
    );

  explicitRecursiveNixIsHonored = (mkProbe { backend = "recursive-nix"; }).dynamicDrv.backend == "recursive-nix";
in
{
  inherit
    unsetDefaultsToBuilderRpcV0
    autoMatchesCapabilitiesSelectBackend
    explicitRecursiveNixIsHonored
    ;
  pass = unsetDefaultsToBuilderRpcV0 && autoMatchesCapabilitiesSelectBackend && explicitRecursiveNixIsHonored;
}
