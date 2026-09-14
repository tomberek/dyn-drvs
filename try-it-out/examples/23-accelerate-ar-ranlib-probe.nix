# Regression fixture for `arToNode`/`ranlibToNode`'s own probe-crash
# bug: `ar --version`/`ranlib --version` (meson's own unconditional
# linker-detection probe, run during every native build's
# `configurePhase`) has no real archive-path positional arg at all --
# `arToNode` assumed argv[0] was always a modifiers string and argv[1]
# the archive path, so a 1-element probe argv made its own `len - 2`
# go negative and `builtins.genList` threw outright ("cannot create
# list of size -1"); the Rust port's `ar_to_node` would have panicked
# on the equivalent out-of-bounds `argv[0]`/`argv[2..]` access.
# `ranlibToNode`/`ranlib_to_node` don't crash (their own arithmetic
# never goes negative for a non-empty argv) but silently MISCLASSIFY
# the probe's own flag as "the archive path" and defer it instead.
#
# This fixture reproduces the `ar --version` shape directly (a plain
# Makefile calling `$(AR) --version` before the real `ar cr` archive
# step, mirroring meson's own unconditional probe) -- confirmed
# failing before the fix (`ar --version` crashed the whole build),
# passing after (the probe correctly passes through, runs for real,
# and the real archive step still defers normally).
#
# Run with:
#   try-it-out/run-nix.sh build --no-link -f try-it-out/examples/23-accelerate-ar-ranlib-probe.nix
{
  pkgs ? (builtins.getFlake (toString ../..)).legacyPackages.${builtins.currentSystem},
  lib ? pkgs.lib,
  dyndrv ? import ../../nix { inherit pkgs lib; },
  nixPackage ? import ../patched-nix.nix { system = pkgs.stdenv.hostPlatform.system; },
  dyndrvShim ? null,
}:

let
  src = pkgs.runCommand "accelerate-ar-ranlib-probe-src" { } ''
    mkdir -p $out
    cat > $out/util.c <<'EOF'
    int helper(void) { return 7; }
    EOF
    cat > $out/Makefile <<'EOF'
    all: libutil.a
    libutil.a: util.c
    	$(CC) -c util.c -o util.o
    	$(AR) --version > /dev/null
    	$(RANLIB) --version > /dev/null
    	$(AR) cr libutil.a util.o
    	$(RANLIB) libutil.a
    EOF
  '';

  plain = lib.makeOverridable (
    { stdenv }:
    stdenv.mkDerivation {
      pname = "accelerate-ar-ranlib-probe";
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
