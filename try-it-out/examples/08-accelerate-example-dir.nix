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
# `builder-rpc-v0`-only (phase 1's own requirement) -- run via
# `try-it-out/run-nix.sh`, same as examples 01/03/05/06/07:
#
#   try-it-out/run-nix.sh build --no-link --print-out-paths -f try-it-out/examples/08-accelerate-example-dir.nix
#
# Also reachable as the flake output `.#example` (`flake.nix`), same
# underlying file, still built the same way (`run-nix.sh ... .#example`)
# -- flakes don't change the `builder-rpc-v0` requirement.

{
  pkgs ? (builtins.getFlake (toString ../..)).legacyPackages.${builtins.currentSystem},
}:
let
  lib = pkgs.lib;
  dyndrv = import ../../nix { inherit pkgs lib; };
  patchedNix = import ../patched-nix.nix { system = pkgs.stdenv.hostPlatform.system; };
  dyndrvShim = import ../../rust/dyndrv-shim.nix { inherit pkgs; };

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
    nixPackage = patchedNix;
    inherit dyndrvShim;
  };
}
