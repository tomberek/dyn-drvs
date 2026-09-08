# Minimal end-to-end demo of `dyndrv.accelerate.mkAcceleratedStdenv`, the
# lowest-friction entry point in the whole library: override an existing
# package's `stdenv` and get per-translation-unit caching, one attribute
# changed, no dynamic-derivation vocabulary required.
#
# This example builds a tiny 3-file C program (main.c + two independent
# "library" files) via a completely ordinary `stdenv.mkDerivation`,
# `.override`d to use the accelerated `stdenv` -- every `cc`/`ar`
# invocation defers (writes a batch-pending stub instead of compiling),
# `dyndrv.phases.split` runs `buildPhase` to completion almost instantly
# against a tree full of stubs, then `shim.collectStubs` resolves the
# whole discovered compile graph in one pass and submits a fully-resolved
# tree for phase 2 (an ORDINARY derivation) to run `installPhase` against.
#
# `builder-rpc-v0`-only (phase 1's own requirement; phase 2 needs no
# special capability at all) -- run via `try-it-out/run-nix.sh`, same as
# examples 01/03.
#
# See `try-it-out/benchmarks/small-lib-patch-rebuild.sh` and
# `real-package-patch-rebuild.sh` for the numbers this mechanism actually
# produces.
#
# Run with:
#   try-it-out/run-nix.sh build --impure --no-link -f try-it-out/examples/05-accelerate-stdenv.nix
#
# `dyndrvShim ? null`: pass the compiled `rust/dyndrv-shim` package
# (`import ../../rust/dyndrv-shim.nix { inherit pkgs; }`) to exercise the
# compiled `dyndrv-shim`/`dyndrv-collect` path instead of the default
# bash `toNodeBash`/`collectStubs` path -- both produce byte-identical
# behavior; this is here for direct comparison between the two, not a
# different example.

{
  pkgs ? import <nixpkgs> { },
  lib ? pkgs.lib,
  dyndrv ? import ../../nix { inherit pkgs lib; },
  # `mkAcceleratedStdenv`'s own `nixPackage` version-matching requirement
  # (see that file's header): must be the SAME fetched Nix
  # `try-it-out/run-nix.sh` uses to drive this build, not the ambient
  # `pkgs.nix` -- confirmed necessary by direct reproduction: using
  # `pkgs.nix` here fails with "Operation 19 not allowed inside
  # derivation" (`SetOptions`, rejected by the newer daemon's stricter
  # `builder-rpc-v0` connection allowlist).
  nixPackage ? import ../patched-nix.nix { },
  dyndrvShim ? null,
}:

let
  src = pkgs.runCommand "accelerate-example-src" { } ''
    mkdir -p $out
    cat > $out/main.c <<'EOF'
    #include <stdio.h>
    extern int lib_a(int x);
    extern int lib_b(int x);
    int main(void) {
      printf("%d\n", lib_a(1) + lib_b(1));
      return 0;
    }
    EOF
    cat > $out/lib_a.c <<'EOF'
    int lib_a(int x) { return x + 1; }
    EOF
    cat > $out/lib_b.c <<'EOF'
    int lib_b(int x) { return x + 2; }
    EOF
    cat > $out/Makefile <<'EOF'
    OBJS = main.o lib_a.o lib_b.o
    all: prog
    prog: $(OBJS)
    	$(CC) $(OBJS) -o prog
    %.o: %.c
    	$(CC) -c $< -o $@
    EOF
  '';

  # An ordinary `stdenv.mkDerivation`-built package, wrapped the same way
  # `pkgs.callPackage` wraps every real nixpkgs package -- `.override`
  # doesn't exist on a bare `stdenv.mkDerivation { ... }` call (confirmed
  # directly: only `.stdenv` does), it comes from `lib.makeOverridable`
  # wrapping the package FUNCTION before it's called, which is exactly
  # what `callPackage` already does for you on any real `pkgs.foo`.
  plain = lib.makeOverridable (
    { stdenv }:
    stdenv.mkDerivation {
      pname = "accelerate-example";
      version = "1.0";
      inherit src;
      installPhase = ''
        mkdir -p $out/bin
        cp prog $out/bin/
      '';
    }
  ) { inherit (pkgs) stdenv; };
in
# The one-line change: override the `stdenv` a package is built with. No
# separate wrapper function needed -- `.override` is ordinary nixpkgs
# mechanics, and every real package (`pkgs.foo`, via `callPackage`)
# already has it.
plain.override {
  stdenv = dyndrv.accelerate.mkAcceleratedStdenv {
    inherit (plain) stdenv;
    inherit nixPackage dyndrvShim;
  };
}
