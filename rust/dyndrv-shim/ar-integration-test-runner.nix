# Directly imports `patched-nix.nix` for a real derivation reference
# (proper closure tracking) instead of threading a raw string path --
# `builtins.storePath` was tried and confirmed NOT to carry closure
# context earlier this session (see this crate's own history for the
# "wrong glibc mounted" failure that caused).
let
  pkgs = (builtins.getFlake (toString ../..)).legacyPackages.${builtins.currentSystem};
  lib = pkgs.lib;
  self = import ../../nix { inherit pkgs lib; };
  dyndrvShim = import ../dyndrv-shim.nix { inherit pkgs; };
  nixPackage = import ../../try-it-out/patched-nix.nix { };
in
import ./ar-integration-test.nix { inherit pkgs self dyndrvShim nixPackage; }
