# Regression fixture for the gperf-survey bug: automake's classic
# depcomp idiom (`-MT $@ -MD -MP -MF .deps/$*.Tpo` alongside `-c -o $@`)
# writes a SECOND file as a byproduct of the same compile, then the
# OUTER, unaccelerated `make` process immediately runs `mv -f
# .deps/$*.Tpo .deps/$*.Po` on it -- see `docs/depfile-side-output-bug.md`
# for the full writeup, and `nix/lib/shim/wrapCommand.nix`'s own
# `finalizeTail` header comment for the fix's rationale.
#
# Before the fix: only the primary `-o`/`outputArg` output gets a
# deferred stub; `-MF <path>`'s own value is never tracked at all, so
# the `mv` immediately after fails outright ("No such file or
# directory") the moment the compile defers instead of running for
# real. After the fix: an empty depfile is touched at defer time
# (content is irrelevant -- Nix always rebuilds fully from scratch, no
# cross-derivation incremental-depfile reuse), satisfying the `mv`.
#
# This fixture reproduces the exact automake `gcc3` depcomp shape
# directly (see automake's own `depcomp` script, `gcc3)` case) --
# confirmed failing before the fix (identical "No such file or
# directory" on the `mv`) and passing after.
#
# Run with:
#   try-it-out/run-nix.sh build --no-link -f try-it-out/examples/35-accelerate-depfile-side-output.nix
{
  pkgs ? (builtins.getFlake (toString ../..)).legacyPackages.${builtins.currentSystem},
  lib ? pkgs.lib,
  dyndrv ? import ../../nix { inherit pkgs lib; },
  nixPackage ? import ../patched-nix.nix { system = pkgs.stdenv.hostPlatform.system; },
  dyndrvShim ? null,
}:

let
  src = pkgs.runCommand "accelerate-depfile-side-output-src" { } ''
    mkdir -p $out/.deps
    cat > $out/hash.c <<'EOF'
    int hash(void) { return 1; }
    EOF
    cat > $out/Makefile <<'EOF'
    all: hash.o

    hash.o: hash.c
    	$(CC) -MT hash.o -MD -MP -MF .deps/hash.Tpo -c -o hash.o hash.c
    	mv -f .deps/hash.Tpo .deps/hash.Po

    install: all
    	mkdir -p $(out)
    	cp hash.o $(out)/
    EOF
  '';

  plain = lib.makeOverridable (
    { stdenv }:
    stdenv.mkDerivation {
      pname = "accelerate-depfile-side-output";
      version = "1.0";
      inherit src;
      preConfigure = ''
        mkdir -p .deps
      '';
      dontConfigure = true;
    }
  ) { inherit (pkgs) stdenv; };
in
plain.override {
  stdenv = dyndrv.accelerate.mkAcceleratedStdenv {
    inherit (plain) stdenv;
    inherit nixPackage dyndrvShim;
  };
}
