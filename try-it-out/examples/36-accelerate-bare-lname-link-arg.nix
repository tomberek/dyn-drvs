# Regression fixture for x265's own bare `-l<name>` link-arg gap:
# a build creates a static lib in a SEPARATE subdirectory (via its own
# deferred ar invocation, exactly like x265's `build-10bits`/
# `build-12bits`), symlinks it into the main build directory under a
# different basename (`ln -s ../other/libhelper.a ./libhelper-alt.a`,
# matching x265's `ln -s ../build-10bits/libx265.a ./libx265-10.a`),
# then links the final binary against it via a bare `-L. -lhelper-alt`
# (a linker search-path reference, not a literal argv path) rather than
# naming the file directly.
#
# See docs/bare-lname-link-arg-bug.md for the full writeup.
#
# Run with:
#   try-it-out/run-nix.sh build --no-link -f try-it-out/examples/36-accelerate-bare-lname-link-arg.nix
{
  pkgs ? (builtins.getFlake (toString ../..)).legacyPackages.${builtins.currentSystem},
  lib ? pkgs.lib,
  dyndrv ? import ../../nix { inherit pkgs lib; },
  nixPackage ? import ../patched-nix.nix { system = pkgs.stdenv.hostPlatform.system; },
  dyndrvShim ? null,
}:

let
  src = pkgs.runCommand "accelerate-bare-lname-link-arg-src" { } ''
    mkdir -p $out/other
    cat > $out/other/helper.c <<'EOF'
    int helper(void) { return 42; }
    EOF
    cat > $out/main.c <<'EOF'
    extern int helper(void);
    int main(void) { return helper() == 42 ? 0 : 1; }
    EOF
    cat > $out/Makefile <<'EOF'
    all: prog

    main.o: main.c
    	$(CC) -c main.c -o main.o

    other/helper.o: other/helper.c
    	$(CC) -c other/helper.c -o other/helper.o

    other/libhelper.a: other/helper.o
    	$(AR) cr other/libhelper.a other/helper.o

    libhelper-alt.a: other/libhelper.a
    	ln -sf other/libhelper.a libhelper-alt.a

    prog: main.o libhelper-alt.a
    	$(CC) main.o -L. -lhelper-alt -o prog

    install: prog
    	mkdir -p $(out)/bin
    	cp prog $(out)/bin/
    EOF
  '';

  plain = lib.makeOverridable (
    { stdenv }:
    stdenv.mkDerivation {
      pname = "accelerate-bare-lname-link-arg";
      version = "1.0";
      inherit src;
    }
  ) { inherit (pkgs) stdenv; };
in
plain.override {
  stdenv = dyndrv.accelerate.mkAcceleratedStdenv {
    inherit (plain) stdenv;
    inherit nixPackage dyndrvShim;
  };
}
