# Test variant of example 06 using the compiled dyndrv-shim/dyndrv-collect
# path (dyndrvShim passed through) instead of the bash toNodeBash/
# collectStubs path -- for direct comparison against the original
# 06-accelerate-stdenv-module.nix build. Exercises `granularity =
# "module"`/`DYNDRV_BATCH_GROUPS` through the compiled `cc` shim
# specifically, which 05's own variant doesn't cover.
let
  pkgs = import <nixpkgs> { };
  lib = pkgs.lib;
  dyndrv = import ../../nix { inherit pkgs lib; };
  patchedNix = import ../patched-nix.nix { };
  dyndrvShim = import ../../rust/dyndrv-shim.nix { inherit pkgs; };

  src = pkgs.runCommand "accelerate-module-example-src" { } ''
    mkdir -p $out/vendor
    cat > $out/main.c <<'EOF'
    #include <stdio.h>
    extern int lib_a(int x);
    extern int lib_b(int x);
    int main(void) {
      printf("%d\n", lib_a(1) + lib_b(1));
      return 0;
    }
    EOF
    cat > $out/vendor/lib_a.c <<'EOF'
    int lib_a(int x) { return x + 1; }
    EOF
    cat > $out/vendor/lib_b.c <<'EOF'
    int lib_b(int x) { return x + 2; }
    EOF
    cat > $out/Makefile <<'EOF'
    all: prog
    prog: main.o liba.a
    	$(CC) main.o liba.a -o prog
    liba.a: vendor/lib_a.o vendor/lib_b.o
    	$(AR) rcs liba.a vendor/lib_a.o vendor/lib_b.o
    %.o: %.c
    	$(CC) -c $< -o $@
    EOF
  '';

  plain = lib.makeOverridable (
    { stdenv }:
    stdenv.mkDerivation {
      pname = "accelerate-module-example";
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
    granularity = "module";
    shouldBatch = path: lib.hasPrefix "vendor/" path;
    inherit dyndrvShim;
  };
}
