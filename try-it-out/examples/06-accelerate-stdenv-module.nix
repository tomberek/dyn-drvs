# Worked example of `dyndrv.accelerate.mkAcceleratedStdenv`'s
# `granularity = "module"` mode: point this at an existing package with
# one line changed (same adoption story as `05-accelerate-stdenv.nix`),
# but opt a `vendor/` subdirectory into batched compilation via
# `shouldBatch` -- both files under `vendor/` compile into ONE registered,
# realized derivation, while `main.c` (outside `vendor/`) keeps the
# default per-file behavior. See `nix/lib/accelerate/mkAcceleratedStdenv.nix`'s
# header comment for the full design and its documented scope limits.
#
# Exercises `shim.wrapCommand`'s `defer` mode (writes a batch-pending
# stub instead of registering/realizing immediately) plus the `shim.
# wrapArchiver` companion shim on `ar` (collects every same-group stub
# into one combined compile+archive derivation).
#
# `recursive-nix`-only (same backend scope as `granularity = "file"`).
#
# Run with:
#   nix build --extra-experimental-features "nix-command ca-derivations dynamic-derivations recursive-nix" \
#     --extra-system-features recursive-nix --store 'local?root=/tmp/dyndrv-store' \
#     -f try-it-out/examples/06-accelerate-stdenv-module.nix
#
# Builds a 3-file C program (main.c + vendor/lib_a.c + vendor/lib_b.c)
# via an ordinary Makefile; `nix log` on the resulting derivation shows
# exactly ONE `dyndrv-batch-vendor.drv` build for BOTH vendor files (not
# two separate `dyndrv-cc-*.drv` registrations), while `main.c` still
# gets its own solo `dyndrv-cc-main.o.drv`. The final linked binary runs
# and produces correct output (5 = lib_a(1) + lib_b(1) = 2 + 3).

let
  pkgs = import <nixpkgs> { };
  lib = pkgs.lib;
  dyndrv = import ../../nix { inherit pkgs lib; };

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
    granularity = "module";
    # Opt-in per path -- here, everything under vendor/ batches.
    shouldBatch = path: lib.hasPrefix "vendor/" path;
  };
}
