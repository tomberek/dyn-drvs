{ pkgs, lib, dyndrv }:

# Wraps nix/tests/*.nix's `{ pass = <bool>; ... }` results into ordinary
# derivations, for `nix flake check`/`self.checks.<system>` consumption.
#
# CAVEAT: these checks require `dynamic-derivations`/`ca-derivations`/
# `recursive-nix` to be enabled AND impure evaluation (mkArgs.nix's
# eval->build boundary helper uses `builtins.getEnv`) -- neither is on by
# default, so plain `nix flake check` will fail with "experimental Nix
# feature 'dynamic-derivations' is disabled" unless invoked as:
#   nix flake check --extra-experimental-features "dynamic-derivations ca-derivations recursive-nix nix-command" --impure
# `nix/tests/run-tests.sh` is the primary, self-contained way to run these
# tests (it sets the required flags itself); this file exists so the same
# tests are also reachable as ordinary flake checks for anyone who wants
# that integration.

let
  assertPass =
    name: result:
    pkgs.runCommand "dyndrv-check-${name}" {
      passStr = builtins.toJSON result.pass;
    } ''
      if [[ "$passStr" != "true" ]]; then
        echo "dyndrv check '${name}' failed: pass=$passStr" >&2
        exit 1
      fi
      touch $out
    '';
in
{
  mkOutputOf = assertPass "mkOutputOf" (import ./mkOutputOf.nix { inherit pkgs lib dyndrv; });
  nonTrivial = assertPass "nonTrivial" (import ./nonTrivial.nix { inherit pkgs lib dyndrv; });
}
