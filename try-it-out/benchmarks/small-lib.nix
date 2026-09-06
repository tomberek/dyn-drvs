{ pkgs ? import <nixpkgs> { }
, lib ? pkgs.lib
, dyndrv ? import ../../nix { inherit pkgs lib; }
, src
, variant ? "plain" # "plain" | "accelerated"
# Absolute store path of the `builder-rpc-v0`-capable Nix to pass as
# `mkAcceleratedStdenv`'s own `nixPackage` -- must match the OUTER Nix
# actually driving this build (see that file's own header comment for
# the version-matching requirement); defaults to the ambient `pkgs.nix`
# when not set.
, nixPackagePath ? null
}:

# The Nix side of small-lib-patch-rebuild.sh: builds a synthetic multi-file
# C "library" fixture (see gen-small-lib.sh) either with plain
# `stdenv.mkDerivation` or with `dyndrv.accelerate.mkAcceleratedStdenv`,
# so the driving script can time both and diff their build logs.

let
  nixPackage = if nixPackagePath == null then pkgs.nix else builtins.storePath nixPackagePath;
  stdenv =
    if variant == "accelerated" then
      dyndrv.accelerate.mkAcceleratedStdenv { inherit nixPackage; stdenv = pkgs.stdenv; }
    else
      pkgs.stdenv;
in
stdenv.mkDerivation {
  pname = "small-lib";
  version = "1.0";
  inherit src;
  installPhase = ''
    mkdir -p $out/bin
    cp prog $out/bin/
  '';
}
