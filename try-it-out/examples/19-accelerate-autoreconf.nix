# Regression fixture for task #132: `phases.split` must not silently
# drop a setup-hook-injected phase like `autoreconfHook`'s own
# `autoreconfPhase` (appended to `preConfigurePhases` via `appendToVar`,
# consulted only by nixpkgs' own DYNAMIC `$phases` computation --
# `definePhases`, in `pkgs/stdenv/generic/setup.sh` -- which a STATIC
# `phases = [...]` override bypasses entirely). See `phases/split.nix`'s
# own `sandboxedDrv`/`buildCommand` header comment for the full fix.
#
# This project ships NO `configure` script at all -- only `configure.ac`/
# `Makefile.am` -- so `autoreconfHook`'s own `autoreconfPhase` (which
# runs `autoreconf --install --force --verbose` to GENERATE `configure`)
# is REQUIRED for `configurePhase` to find anything to run at all. Before
# the fix: `configurePhase` logs "no configure script, doing nothing" and
# the real `./configure`-generated `Makefile` never exists, so `buildPhase`
# fails outright ("no Makefile ... doing nothing", then `make`'s own
# implicit rules can't produce `prog` either). After the fix: `autoreconf`
# actually runs, `configure`/`Makefile.in` are generated, `./configure`
# succeeds, and the real build proceeds normally.
#
# Run with:
#   try-it-out/run-nix.sh build --no-link -f try-it-out/examples/19-accelerate-autoreconf.nix
{
  pkgs ? (builtins.getFlake (toString ../..)).legacyPackages.${builtins.currentSystem},
  lib ? pkgs.lib,
  dyndrv ? import ../../nix { inherit pkgs lib; },
  nixPackage ? import ../patched-nix.nix { system = pkgs.stdenv.hostPlatform.system; },
  dyndrvShim ? null,
}:

let
  src = pkgs.runCommand "accelerate-autoreconf-src" { } ''
    mkdir -p $out
    cat > $out/main.c <<'EOF'
    int main(void) { return 0; }
    EOF
    cat > $out/configure.ac <<'EOF'
    AC_INIT([accelerate-autoreconf], [1.0])
    AM_INIT_AUTOMAKE([foreign])
    AC_PROG_CC
    AC_CONFIG_FILES([Makefile])
    AC_OUTPUT
    EOF
    cat > $out/Makefile.am <<'EOF'
    bin_PROGRAMS = prog
    prog_SOURCES = main.c
    EOF
  '';

  plain = lib.makeOverridable (
    { stdenv }:
    stdenv.mkDerivation {
      pname = "accelerate-autoreconf";
      version = "1.0";
      inherit src;
      nativeBuildInputs = [
        pkgs.autoreconfHook
        pkgs.automake
        pkgs.autoconf
      ];
    }
  ) { inherit (pkgs) stdenv; };
in
plain.override {
  stdenv = dyndrv.accelerate.mkAcceleratedStdenv {
    inherit (plain) stdenv;
    inherit nixPackage dyndrvShim;
  };
}
