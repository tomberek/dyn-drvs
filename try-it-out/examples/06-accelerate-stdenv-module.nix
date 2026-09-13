# Worked example of `dyndrv.accelerate.mkAcceleratedStdenv`'s
# `granularity = "module"` mode: point this at an existing package with
# one line changed (same adoption story as `05-accelerate-stdenv.nix`),
# but opt a `vendor/` subdirectory into batched compilation via
# `shouldBatch` -- both files under `vendor/` compile into ONE combined
# derivation (plus the `ar` step that archives them, auto-merged in by
# `shim.collectStubs`'s own rule: a keyless stub -- the `ar` call --
# joins its deps' shared unit since both its inputs already share that
# SAME group), while `main.c` (outside `vendor/`) keeps the default
# per-file behavior. See `nix/lib/accelerate/mkAcceleratedStdenv.nix`'s
# header comment for the full design and its documented scope limits.
#
# `builder-rpc-v0`-only (phase 1's own requirement; phase 2, which runs
# `installPhase`, needs no special capability at all).
#
# Run with:
#   try-it-out/run-nix.sh build --no-link -f try-it-out/examples/06-accelerate-stdenv-module.nix
#
# Builds a 3-file C program (main.c + vendor/lib_a.c + vendor/lib_b.c)
# via an ordinary Makefile; the final linked binary runs and produces
# correct output (5 = lib_a(1) + lib_b(1) = 2 + 3).
#
# `dyndrvShim ? null`: pass the compiled `rust/dyndrv-shim` package
# (`import ../../rust/dyndrv-shim.nix { inherit pkgs; }`) to exercise
# `granularity = "module"`/`DYNDRV_BATCH_GROUPS` through the compiled
# `cc` shim instead of the default bash `toNodeBash`/`collectStubs`
# path -- for direct comparison between the two, not a different example.

{
  pkgs ? (builtins.getFlake (toString ../..)).legacyPackages.${builtins.currentSystem},
  lib ? pkgs.lib,
  dyndrv ? import ../../nix { inherit pkgs lib; },
  # See 05-accelerate-stdenv.nix's own comment on this -- must match the
  # Nix `try-it-out/run-nix.sh` uses to drive this build.
  nixPackage ? import ../patched-nix.nix { system = pkgs.stdenv.hostPlatform.system; },
  dyndrvShim ? null,
}:

let
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
    inherit nixPackage;
    granularity = "module";
    # Opt-in per path -- here, everything under vendor/ batches.
    shouldBatch = path: lib.hasPrefix "vendor/" path;
    inherit dyndrvShim;
  };
}
