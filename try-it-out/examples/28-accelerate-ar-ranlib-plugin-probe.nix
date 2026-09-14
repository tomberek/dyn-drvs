# Regression fixture for `ranlibToNode`'s own probe-detection gap:
# `isProbe`'s original heuristic (`!(any (a: !hasPrefix "-" a) argv)`)
# required EVERY argv element to be `-`-prefixed to recognize a probe --
# confirmed insufficient by direct reproduction against real nixpkgs
# x264, whose own `./configure` unconditionally probes LTO-plugin
# support via `gcc-ranlib --plugin /nix/store/<hash>-.../liblto_plugin.so
# --version`: the plugin path itself is a REAL, non-`-`-prefixed
# positional argument, so the original check misclassified this whole
# invocation as "index this archive" and deferred it, producing a
# bogus, unsatisfiable stub instead of running the real probe.
#
# This fixture reproduces the exact shape directly (`ranlib --plugin
# ./some-plugin.so --version`, `ar --plugin ./some-plugin.so --version`)
# -- confirmed failing before the fix (misclassified as real archive
# operations), passing after (recognized as probes via the added
# `builtins.elem "--version"/"--help" argv` check, regardless of
# position).
#
# Run with:
#   try-it-out/run-nix.sh build --no-link -f try-it-out/examples/28-accelerate-ar-ranlib-plugin-probe.nix
{
  pkgs ? (builtins.getFlake (toString ../..)).legacyPackages.${builtins.currentSystem},
  lib ? pkgs.lib,
  dyndrv ? import ../../nix { inherit pkgs lib; },
  nixPackage ? import ../patched-nix.nix { system = pkgs.stdenv.hostPlatform.system; },
  dyndrvShim ? null,
}:

let
  src = pkgs.runCommand "accelerate-ar-ranlib-plugin-probe-src" { } ''
    mkdir -p $out
    cat > $out/util.c <<'EOF'
    int helper(void) { return 7; }
    EOF
    cat > $out/Makefile <<'EOF'
    all: libutil.a
    libutil.a: util.c
    	touch fake-plugin.so
    	$(AR) --plugin ./fake-plugin.so --version > /dev/null
    	$(RANLIB) --plugin ./fake-plugin.so --version > /dev/null
    	$(CC) -c util.c -o util.o
    	$(AR) cr libutil.a util.o
    	$(RANLIB) libutil.a
    EOF
  '';

  plain = lib.makeOverridable (
    { stdenv }:
    stdenv.mkDerivation {
      pname = "accelerate-ar-ranlib-plugin-probe";
      version = "1.0";
      inherit src;
      installPhase = ''
        mkdir -p $out
        cp libutil.a $out/
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
