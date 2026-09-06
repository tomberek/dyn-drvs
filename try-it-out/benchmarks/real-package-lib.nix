{ pkgs ? import <nixpkgs> { }
, lib ? pkgs.lib
, dyndrv ? import ../../nix { inherit pkgs lib; }
, variant ? "plain" # "plain" | "accelerated"
, patch ? null # optional path: a one-file patch to apply before building
, patches ? null # optional list of paths: multiple patches, e.g. for a version-bump simulation (mutually exclusive with `patch`)
, nixPackage ? pkgs.nix
# Absolute store path of the `builder-rpc-v0`-capable Nix to pass as
# `mkAcceleratedStdenv`'s own `nixPackage` -- must match the OUTER Nix
# actually driving this build (see that file's own header comment for
# the version-matching requirement). When set, takes precedence over
# `nixPackage` above -- mirrors `small-lib.nix`'s own `nixPackagePath`
# param, needed here for the identical reason: a driving BASH script
# resolves the patched Nix's store path once via `nix build ... '^out'`
# and must pass it across the process boundary as a plain string
# (`--argstr`), not as a Nix expression referencing an already-built
# derivation.
, nixPackagePath ? null
}:

# The Nix side of real-package-patch-rebuild.sh: builds real nixpkgs
# `freetype` (a genuine multi-directory, libtool/autotools C library, ~45
# translation units, several other libraries as build inputs) either with
# plain `stdenv.mkDerivation` or with `dyndrv.accelerate.mkAcceleratedStdenv`,
# optionally with a one-line source patch applied first.
#
# WHY freetype AND NOT OPENSSL: openssl bakes its own not-yet-known `$out`
# path directly into every `cc` invocation via `-DOPENSSLDIR=/-DENGINESDIR=/
# -DMODULESDIR=` (confirmed by direct reproduction) -- since `$out` changes
# whenever ANY outer-derivation attribute changes (including applying a
# one-line patch), this makes EVERY per-TU derivation's hash change too,
# defeating per-TU caching structurally, not as a dyndrv bug. Fixing this
# for real needs nixgg's own `builder-rpc-v0` + `out = "/nonexistent"` +
# a phases.split (sandboxed-then-restore) architecture -- genuinely v0.3
# scope (see the plan's own findings), not a v0.2 fix. `freetype` doesn't
# bake `$out` into its compile flags, so it demonstrates the SAME
# real-package-scale value proposition within v0.2's current scope.
#
# `doCheck = false`: measures compile/link behavior (what
# `mkAcceleratedStdenv` actually changes), not freetype's own test suite.
#
# Building this end-to-end was itself the forcing function that found and
# fixed several real bugs in `mkAcceleratedStdenv`/`shim.wrapCommand`
# (see BASELINE.md and the plan's own findings for the full list):
# libtool's real invocations use implicit (no `-o`) output naming,
# absolute-but-build-tree-relative paths (`/build/pkg/...`, not real Nix
# store paths), glued `-I<path>` flags referencing OTHER libraries beyond
# the toolchain's own closure, a double-`-o` collision when replacing an
# already-`-o`'d invocation's output path, and internal `nix`-command
# stderr noise leaking into a calling autoconf probe's captured output.

let
  resolvedNixPackage =
    if nixPackagePath != null then builtins.storePath nixPackagePath else nixPackage;

  stdenv =
    if variant == "accelerated" then
      dyndrv.accelerate.mkAcceleratedStdenv { nixPackage = resolvedNixPackage; stdenv = pkgs.stdenv; }
    else
      pkgs.stdenv;

  base = pkgs.freetype.override { inherit stdenv; };

  extraPatches =
    if patches != null then patches
    else if patch != null then [ patch ]
    else [ ];
in
base.overrideAttrs (
  old:
  {
    doCheck = false;
  }
  // lib.optionalAttrs (extraPatches != [ ]) {
    patches = (old.patches or [ ]) ++ extraPatches;
  }
)
