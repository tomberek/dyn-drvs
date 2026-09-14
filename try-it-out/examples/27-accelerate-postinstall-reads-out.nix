# Regression fixture for task #140: `phases.split`'s synthesized
# `dyndrvRestoreOutput` phase used to run too late for any package
# whose own `postInstall` reads/writes `$out` directly.
#
# nixpkgs' own `installPhase` calls `runHook postInstall` as its OWN
# LAST statement, strictly BEFORE `dyndrvRestoreOutput` (the NEXT
# phase in the list) ever runs -- so a `postInstall` referencing `$out`
# found it still missing whatever `make install` wrote under the
# placeholder root. Confirmed via real nixpkgs `mosh` ("Cannot wrap
# ... because it does not exist") and `leveldb` ("substitute(): ERROR:
# file ... does not exist") -- see `docs/split-postinstall-before-
# restore-bug.md`.
#
# This fixture reproduces the exact shape directly: a plain autotools
# `./configure --prefix=$out && make install`, then a `postInstall`
# that reads `$out/bin/prog` directly (mirroring mosh's own
# `wrapProgram $out/bin/mosh`) -- confirmed failing before the fix
# ("No such file or directory" / grep failing to find the file at
# all), passing after.
#
# Run with:
#   try-it-out/run-nix.sh build --no-link -f try-it-out/examples/27-accelerate-postinstall-reads-out.nix
{
  pkgs ? (builtins.getFlake (toString ../..)).legacyPackages.${builtins.currentSystem},
  lib ? pkgs.lib,
  dyndrv ? import ../../nix { inherit pkgs lib; },
  nixPackage ? import ../patched-nix.nix { system = pkgs.stdenv.hostPlatform.system; },
  dyndrvShim ? null,
}:

let
  src = pkgs.runCommand "accelerate-postinstall-reads-out-src" { } ''
    mkdir -p $out
    cat > $out/main.c <<'EOF'
    int main(void) { return 0; }
    EOF
    cat > $out/configure <<'EOF'
    #!/bin/sh
    for arg in "$@"; do
      case "$arg" in
        --prefix=*) prefix="''${arg#--prefix=}" ;;
      esac
    done
    cat > Makefile <<MAKEFILE
    all: prog
    prog: main.c
    	\$(CC) main.c -o prog
    install: prog
    	mkdir -p $prefix/bin
    	cp prog $prefix/bin/
    MAKEFILE
    EOF
    chmod +x $out/configure
  '';

  plain = lib.makeOverridable (
    { stdenv }:
    stdenv.mkDerivation {
      pname = "accelerate-postinstall-reads-out";
      version = "1.0";
      inherit src;
      # `postInstall` reads `$out` directly -- the exact shape that
      # exposed this bug against real mosh/leveldb.
      postInstall = ''
        test -x "$out/bin/prog"
        echo "postInstall: confirmed $out/bin/prog exists and is executable"
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
