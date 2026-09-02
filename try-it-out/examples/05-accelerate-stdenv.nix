# Minimal end-to-end demo of `dyndrv.accelerate.mkAcceleratedStdenv`, the
# lowest-friction entry point in the whole library: override an existing
# package's `stdenv` and get per-translation-unit caching, one attribute
# changed, no dynamic-derivation vocabulary required.
#
# This example builds a tiny 3-file C program (main.c + two independent
# "library" files) via a completely ordinary `stdenv.mkDerivation`,
# `.override`d to use the accelerated `stdenv` -- each `cc -c` invocation
# becomes its own dynamically-produced derivation via `shim.wrapCommand`,
# and only the link step (and, on the first build, feature-probe-style
# invocations, of which this simple Makefile has none) passes through
# unaccelerated.
#
# `recursive-nix`-only (inherited from `shim.wrapCommand`/
# `mkAcceleratedStdenv`'s own v0.2 scope) -- no patched Nix needed, unlike
# examples 01/03. See `try-it-out/benchmarks/small-lib-patch-rebuild.sh`
# and `real-package-patch-rebuild.sh` for the numbers this mechanism
# actually produces (a real win at real per-file compile cost, an honest
# loss at trivial compile cost -- see BASELINE.md).
#
# Run with:
#   nix build --extra-experimental-features "nix-command ca-derivations dynamic-derivations recursive-nix" \
#     --extra-system-features recursive-nix --store 'local?root=/tmp/dyndrv-store' \
#     -f try-it-out/examples/05-accelerate-stdenv.nix

let
  pkgs = import <nixpkgs> { };
  lib = pkgs.lib;
  dyndrv = import ../../nix { inherit pkgs lib; };

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
  stdenv = dyndrv.accelerate.mkAcceleratedStdenv { inherit (plain) stdenv; };
}
