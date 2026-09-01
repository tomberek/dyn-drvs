# Minimal end-to-end demo of `dyndrv.accelerate.wrap`, the lowest-friction
# entry point in the whole library: point it at an existing, ordinary
# `stdenv.mkDerivation`-built package and get per-translation-unit
# caching, one line changed, no dynamic-derivation vocabulary required.
#
# This example builds a tiny 3-file C program (main.c + two independent
# "library" files) via a completely ordinary `stdenv.mkDerivation`, wrapped
# with `dyndrv.accelerate.wrap` -- each `cc -c` invocation becomes its own
# dynamically-produced derivation via `shim.wrapCommand`, and only the
# link step (and, on the first build, feature-probe-style invocations, of
# which this simple Makefile has none) passes through unaccelerated.
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
#     -f try-it-out/examples/05-accelerate-wrap.nix

let
  pkgs = import <nixpkgs> { };
  lib = pkgs.lib;
  dyndrv = import ../../nix { inherit pkgs lib; };

  src = pkgs.runCommand "accelerate-wrap-example-src" { } ''
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

  # `dyndrv.accelerate.wrap` needs `.override`/`.stdenv` on its argument --
  # exactly what `pkgs.callPackage` gives every ordinary nixpkgs package
  # (confirmed directly: a bare `stdenv.mkDerivation { ... }` call has
  # `.stdenv` but NOT `.override`, since that only comes from
  # `lib.makeOverridable`/`callPackage` wrapping the package FUNCTION, not
  # its result). `lib.makeOverridable` here mirrors exactly what
  # `callPackage` does for a real package file, so this example matches
  # what "point `accelerate.wrap` at an existing package" actually means.
  plain = lib.makeOverridable (
    { stdenv }:
    stdenv.mkDerivation {
      pname = "accelerate-wrap-example";
      version = "1.0";
      inherit src;
      installPhase = ''
        mkdir -p $out/bin
        cp prog $out/bin/
      '';
    }
  ) { inherit (pkgs) stdenv; };
in
dyndrv.accelerate.wrap plain
