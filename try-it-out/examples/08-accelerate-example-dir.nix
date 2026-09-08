# Worked example of `dyndrv.accelerate.mkAcceleratedStdenv` applied to a
# REAL, checked-in on-disk source directory (`../../example/`) instead
# of a synthesized `pkgs.runCommand` fixture the way every other example
# in this directory does. Also the paired half of `rust/dyndrv-shim/
# devshell-parity-test.sh`'s own verification: that fixture drives these
# SAME sources through `nix/lib/shim/devShell.nix`'s own Rpc-mode
# wrappers directly (no sandbox at all) and confirms the resulting
# per-TU derivations match what THIS file's own sandboxed `mkAccelerated
# Stdenv` build registers -- the real-project instance of the property
# `docs/rust-status.md`'s "Cross-mode substitution" section already
# confirmed synthetically (`cross_mode_check.rs`).
#
# `builder-rpc-v0`-only (phase 1's own requirement) -- the ambient
# system Nix daemon doesn't support it, so this needs a driving Nix
# build recent enough to have it, plus an isolated alt store (neither of
# which the ambient daemon provides) -- exactly what `try-it-out/
# run-nix.sh` sets up. Standalone:
#
#   try-it-out/run-nix.sh build --impure --no-link --print-out-paths -f try-it-out/examples/08-accelerate-example-dir.nix
#
# Also reachable as `packages.<system>.example` (`flake.nix`), which
# passes `dyndrv`/`dyndrvShim` in directly instead of re-importing
# them -- still needs the SAME `run-nix.sh`-equivalent driving-Nix/alt-
# store wrapper to actually build, since `flake.nix`'s own `nix` input
# is just a version-matched `nixPackage` source, not a way around the
# ambient daemon's own missing `builder-rpc-v0` support:
#
#   try-it-out/run-nix.sh build --impure --no-link --print-out-paths .#example

{
  pkgs ? import <nixpkgs> { },
  lib ? pkgs.lib,
  dyndrv ? import ../../nix { inherit pkgs lib; },
  # Must match the OUTER Nix actually driving this build (see
  # `patched-nix.nix`'s own header comment for the version-matching
  # requirement) -- a real derivation reference, since this file is
  # always called from ordinary Nix code (`try-it-out/run-nix.sh` via
  # `-f`, or `flake.nix`'s own `packages.<system>.example`), never
  # across a bash-string process boundary the way `real-package-lib.
  # nix`'s own `nixPackagePath` param exists to support.
  nixPackage ? import ../patched-nix.nix { },
  dyndrvShim ? import ../../rust/dyndrv-shim.nix { inherit pkgs; },
}:

let
  # `../../example`, NOT a `pkgs.runCommand`-synthesized source tree --
  # the one thing this example demonstrates that 01-07 don't: a real,
  # checked-in multi-file project directory works with `mkAccelerated
  # Stdenv` exactly the same way a synthesized one does (relative source
  # paths within `$PWD`, the only thing the accelerator's own shims care
  # about, are identical either way).
  plain = lib.makeOverridable (
    { stdenv }:
    stdenv.mkDerivation {
      pname = "dyndrv-example";
      version = "1.0";
      src = ../../example;
      installPhase = ''
        mkdir -p $out/bin
        cp hello $out/bin/
      '';
    }
  ) { inherit (pkgs) stdenv; };
in
plain.override {
  stdenv = dyndrv.accelerate.mkAcceleratedStdenv {
    inherit (plain) stdenv;
    inherit nixPackage dyndrvShim;
  };
}
