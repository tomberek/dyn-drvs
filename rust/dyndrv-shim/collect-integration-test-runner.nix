let
  pkgs = import <nixpkgs> { };
  lib = pkgs.lib;
  self = import ../../nix { inherit pkgs lib; };
  dyndrvShim = import ../dyndrv-shim.nix { inherit pkgs; };
  nixPackage = import ../../try-it-out/patched-nix.nix { };
in
import ./collect-integration-test.nix { inherit pkgs self dyndrvShim nixPackage; }
