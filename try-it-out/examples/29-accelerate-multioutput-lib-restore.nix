# Regression fixture for task #139: `phases.split`'s multi-output
# restore never redistributed ORDINARY library/binary content into
# `$lib`/`$bin` -- only `_multioutDocs`/`_multioutDevs` (doc/dev-shaped
# subpaths) ran, since phase 1 forces a single output (`$out`) and
# nothing else ever moved plain `bin`/`sbin`/`lib`/`libexec`/
# `share/locale` content out of it.
#
# Confirmed via real nixpkgs x264 (`outputs = [ "out" "dev" "lib" ]`):
# without this fix, `$lib` was never created at all -- Nix's own
# builder failed outright ("failed to produce output path for output
# 'lib'") -- even though the real `libx264.so` had already been built
# and installed correctly, just under the wrong (`$out`) root.
#
# This fixture reproduces the same shape directly: a 3-output package
# (`out`/`dev`/`lib`) whose plain Makefile installs a binary to `$out/
# bin` and a library to `$out/lib` (mirroring what an unaccelerated
# build's own `configureFlags` -- `--bindir=$out/bin --libdir=$lib/lib`
# -- would normally route directly to the REAL per-output paths, but
# phase 1's forced single output collapses to `$out` for everything)
# -- confirmed failing before the fix ("failed to produce output path
# for output 'lib'"), passing after.
#
# Run with:
#   try-it-out/run-nix.sh build --no-link -f try-it-out/examples/29-accelerate-multioutput-lib-restore.nix
{
  pkgs ? (builtins.getFlake (toString ../..)).legacyPackages.${builtins.currentSystem},
  lib ? pkgs.lib,
  dyndrv ? import ../../nix { inherit pkgs lib; },
  nixPackage ? import ../patched-nix.nix { system = pkgs.stdenv.hostPlatform.system; },
  dyndrvShim ? null,
}:

let
  src = pkgs.runCommand "accelerate-multioutput-lib-restore-src" { } ''
    mkdir -p $out
    cat > $out/lib.c <<'EOF'
    int helper(void) { return 1; }
    EOF
    cat > $out/main.c <<'EOF'
    int main(void) { return 0; }
    EOF
    cat > $out/Makefile <<'EOF'
    all: prog libhelper.a
    lib.o: lib.c
    	$(CC) -c lib.c -o lib.o
    libhelper.a: lib.o
    	$(AR) cr libhelper.a lib.o
    prog: main.c
    	$(CC) main.c -o prog
    install: all
    	mkdir -p $(INSTALL_OUT)/bin $(INSTALL_LIB)/lib
    	cp prog $(INSTALL_OUT)/bin/
    	cp libhelper.a $(INSTALL_LIB)/lib/
    EOF
  '';

  plain = lib.makeOverridable (
    { stdenv }:
    stdenv.mkDerivation {
      pname = "accelerate-multioutput-lib-restore";
      version = "1.0";
      inherit src;
      outputs = [ "out" "dev" "lib" ];
      installFlags = [ "INSTALL_OUT=$(out)" "INSTALL_LIB=$(lib)" ];
    }
  ) { inherit (pkgs) stdenv; };
in
plain.override {
  stdenv = dyndrv.accelerate.mkAcceleratedStdenv {
    inherit (plain) stdenv;
    inherit nixPackage dyndrvShim;
  };
}
