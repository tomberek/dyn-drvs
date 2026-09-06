# Test variant of example 05 using the compiled dyndrv-shim/dyndrv-collect
# path (dyndrvShim passed through) instead of the bash toNodeBash/
# collectStubs path -- for direct comparison against the original
# 05-accelerate-stdenv.nix build.
let
  pkgs = import <nixpkgs> { };
  lib = pkgs.lib;
  dyndrv = import ../../nix { inherit pkgs lib; };
  patchedNix = import ../patched-nix.nix { };
  dyndrvShim = import ../../rust/dyndrv-shim.nix { inherit pkgs; };

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
    int lib_a(int x) { return x + 10; }
    EOF
    cat > $out/lib_b.c <<'EOF'
    int lib_b(int x) { return x + 20; }
    EOF
    cat > $out/Makefile <<'EOF'
    prog: main.o lib_a.o lib_b.o
    	$(CC) main.o lib_a.o lib_b.o -o prog
    %.o: %.c
    	$(CC) -c $< -o $@
    EOF
  '';

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
plain.override {
  stdenv = dyndrv.accelerate.mkAcceleratedStdenv {
    inherit (plain) stdenv;
    nixPackage = patchedNix;
    inherit dyndrvShim;
  };
}
