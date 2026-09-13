# Directly imports `patched-nix.nix` for a real derivation reference
# (proper closure tracking) instead of threading a raw string path --
# `builtins.storePath` does not carry closure context, so import
# patched-nix.nix directly instead of threading a raw store-path
# string.
let
  pkgs = (builtins.getFlake (toString ../..)).legacyPackages.${builtins.currentSystem};
  lib = pkgs.lib;
  self = import ../../nix { inherit pkgs lib; };
  dyndrvShim = import ../dyndrv-shim.nix { inherit pkgs; };
  nixPackage = import ../../try-it-out/patched-nix.nix { };
in
import ./ar-integration-test.nix { inherit pkgs self dyndrvShim nixPackage; }
