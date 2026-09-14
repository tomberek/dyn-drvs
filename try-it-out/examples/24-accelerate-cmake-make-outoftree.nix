# Regression fixture for task #138: `phases.split`'s cmake+make
# out-of-tree install failure.
#
# nixpkgs' own `cmakeConfigurePhase` (unlike meson) builds out-of-tree
# by default too: it creates a `build/` subdirectory below `sourceRoot`
# and `cd`s into it before ever invoking `cmake`, exactly like meson's
# own `meson setup build && cd build` convention. `.dyndrv-build-
# relpath` (see `shim.collectStubs`'s own header comment) used to only
# ever be written when phase 1 found a `build.ninja` file -- i.e. ONLY
# for meson's own Ninja generator, never for cmake's own DEFAULT
# generator (plain Unix Makefiles, no `build.ninja` at all). Without
# it, `dyndrvCdToBuildDir` (phase 2) never reconstructed phase 1's own
# absolute build-dir position -- but cmake bakes that exact absolute
# path into `CMakeCache.txt`/`CMakeFiles/Makefile.cmake` during
# `configurePhase`, and its own generated top-level `Makefile` re-
# invokes `cmake --check-build-system` (via the `cmake_check_build_system`
# target, a dependency of `all`/`install` alike) on EVERY subsequent
# `make` invocation -- including `installPhase`'s own `make install`.
# That re-invocation fails outright ("The source directory ... does
# not exist") the moment phase 2's tree doesn't sit at that exact same
# absolute position, even though every real compile/link output was
# already fully resolved by phase 1.
#
# This fixture reproduces cmake's own default out-of-tree convention
# directly (`cmake -S . -B build`, mirroring `cmakeConfigurePhase`,
# with the plain "Unix Makefiles" generator -- no ninja involved at
# all) -- confirmed failing before the fix (`installPhase` errors with
# "CMake Error: The source directory ... does not exist"), passing
# after (the real absolute build-dir position is reconstructed the
# same way meson's own case already was, so cmake's own re-check
# succeeds and `make install` completes normally).
#
# Run with:
#   try-it-out/run-nix.sh build --no-link -f try-it-out/examples/24-accelerate-cmake-make-outoftree.nix
{
  pkgs ? (builtins.getFlake (toString ../..)).legacyPackages.${builtins.currentSystem},
  lib ? pkgs.lib,
  dyndrv ? import ../../nix { inherit pkgs lib; },
  nixPackage ? import ../patched-nix.nix { system = pkgs.stdenv.hostPlatform.system; },
  dyndrvShim ? null,
}:

let
  src = pkgs.runCommand "accelerate-cmake-make-outoftree-src" { } ''
    mkdir -p $out
    cat > $out/main.c <<'EOF'
    int main(void) { return 0; }
    EOF
    cat > $out/CMakeLists.txt <<'EOF'
    cmake_minimum_required(VERSION 3.10)
    project(cmakemakeoutoftree C)
    add_executable(prog main.c)
    install(TARGETS prog RUNTIME DESTINATION bin)
    EOF
  '';

  plain = lib.makeOverridable (
    { stdenv }:
    stdenv.mkDerivation {
      pname = "accelerate-cmake-make-outoftree";
      version = "1.0";
      inherit src;
      nativeBuildInputs = [ pkgs.cmake ];
      # Default, out-of-tree convention (no `dontUseCmakeBuildDir`) --
      # exactly the case that never worked before this fix.
    }
  ) { inherit (pkgs) stdenv; };
in
plain.override {
  stdenv = dyndrv.accelerate.mkAcceleratedStdenv {
    inherit (plain) stdenv;
    inherit nixPackage dyndrvShim;
  };
}
