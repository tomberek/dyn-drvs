# Regression fixture for the compile-and-link-in-one-step bug
# (docs/compile-and-link-in-one-step-regression.md): `discoverTree`'s
# own `-M -MG` header-discovery-skip guard once used "has `-c` flag" as
# a proxy for "is this a compile," which incorrectly ALSO skipped
# header discovery for a compile+link-in-one-step invocation like `cc
# foo.c libbar.a -o foo` (no `-c` flag, but foo.c IS a real source file
# needing header discovery) -- broke real giflib CLI utilities
# (gifinto.c etc, "fatal error: getarg.h: No such file or directory").
#
# This fixture reproduces the exact shape: a small static library
# (compiled+archived via separate `cc -c`/`ar` invocations, same as any
# other example), then a "CLI utility" whose OWN build step compiles a
# source file WITH A LOCAL HEADER DEPENDENCY and links it against that
# library, all in ONE invocation (no `-c` flag) -- exactly the case the
# old `has_c_flag`-only guard misclassified as "pure link, skip
# discovery."
#
# Run with:
#   try-it-out/run-nix.sh build --no-link -f try-it-out/examples/21-accelerate-compile-and-link-one-step.nix
{
  pkgs ? (builtins.getFlake (toString ../..)).legacyPackages.${builtins.currentSystem},
  lib ? pkgs.lib,
  dyndrv ? import ../../nix { inherit pkgs lib; },
  nixPackage ? import ../patched-nix.nix { system = pkgs.stdenv.hostPlatform.system; },
  dyndrvShim ? null,
}:

let
  src = pkgs.runCommand "accelerate-compile-and-link-one-step-src" { } ''
    mkdir -p $out
    cat > $out/util.h <<'EOF'
    int helper(void);
    EOF
    cat > $out/util.c <<'EOF'
    #include "util.h"
    int helper(void) { return 7; }
    EOF
    cat > $out/prog.c <<'EOF'
    #include "util.h"
    int main(void) { return helper() - 7; }
    EOF
    cat > $out/Makefile <<'EOF'
    all: prog
    libutil.a: util.c util.h
    	$(CC) -c util.c -o util.o
    	$(AR) cr libutil.a util.o
    prog: prog.c libutil.a
    	$(CC) prog.c libutil.a -o prog
    EOF
  '';

  plain = lib.makeOverridable (
    { stdenv }:
    stdenv.mkDerivation {
      pname = "accelerate-compile-and-link-one-step";
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
    inherit nixPackage dyndrvShim;
  };
}
