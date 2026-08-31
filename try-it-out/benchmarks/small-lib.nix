{ pkgs ? import <nixpkgs> { }
, lib ? pkgs.lib
, dyndrv ? import ../../nix { inherit pkgs lib; }
, src
, variant ? "plain" # "plain" | "accelerated"
}:

# The Nix side of small-lib-patch-rebuild.sh: builds a synthetic multi-file
# C "library" fixture (see gen-small-lib.sh) either with plain
# `stdenv.mkDerivation` or with `dyndrv.accelerate.mkAcceleratedStdenv`,
# so the driving script can time both and diff their build logs.

let
  stdenv =
    if variant == "accelerated" then
      dyndrv.accelerate.mkAcceleratedStdenv { stdenv = pkgs.stdenv; }
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
