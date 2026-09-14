# Regression fixture for task #131: CMake's own `try_compile`-backed
# feature probes (`check_c_compiler_flag`, the mechanism real packages
# like zstd use to conditionally enable compiler flags) must run for
# real, not defer -- see `mkAcceleratedStdenv.nix`'s own `isCMakeProbe`
# header comment for the full rationale.
#
# This project probes for `-Qunused-arguments` (a real, Clang-ONLY flag
# gcc has never supported) via `check_c_compiler_flag`, then only adds it
# to `CMAKE_C_FLAGS` if the probe reports success. Before the fix: the
# probe's own deferred stub always "succeeds" (exit 0, regardless of what
# the real, unaccelerated compile would report), so CMake wrongly
# concludes gcc supports the flag, bakes it into every real compile's own
# flags, and the real `main.c` compile then fails outright with "gcc:
# error: unrecognized command-line option '-Qunused-arguments'". After
# the fix: the probe is recognized (its scratch files live under
# `CMakeFiles/CMakeScratch/TryCompile-<random>/`) and passed through to
# run for real, correctly reporting failure against gcc, so the flag is
# never added and the real compile succeeds.
#
# Run with:
#   try-it-out/run-nix.sh build --no-link -f try-it-out/examples/18-accelerate-cmake-probe.nix
{
  pkgs ? (builtins.getFlake (toString ../..)).legacyPackages.${builtins.currentSystem},
  lib ? pkgs.lib,
  dyndrv ? import ../../nix { inherit pkgs lib; },
  nixPackage ? import ../patched-nix.nix { system = pkgs.stdenv.hostPlatform.system; },
  dyndrvShim ? null,
}:

let
  src = pkgs.runCommand "accelerate-cmake-probe-src" { } ''
    mkdir -p $out
    cat > $out/main.c <<'EOF'
    int main(void) { return 0; }
    EOF
    cat > $out/CMakeLists.txt <<'EOF'
    cmake_minimum_required(VERSION 3.10)
    project(cmakeprobe C)
    include(CheckCCompilerFlag)
    check_c_compiler_flag("-Qunused-arguments" HAS_QUNUSED_ARGUMENTS)
    if(HAS_QUNUSED_ARGUMENTS)
      add_compile_options(-Qunused-arguments)
    endif()
    add_executable(prog main.c)
    EOF
  '';

  plain = lib.makeOverridable (
    { stdenv }:
    stdenv.mkDerivation {
      pname = "accelerate-cmake-probe";
      version = "1.0";
      inherit src;
      nativeBuildInputs = [ pkgs.cmake ];
      # In-source build (cmake's default out-of-tree `build/` subdirectory
      # hits a SEPARATE, already-documented bug --
      # `docs/discovertree-cmake-source-path-bug.md` -- unrelated to this
      # fixture's own target (CMake probe-detection); avoided here so
      # this fixture isolates just the one fix it exists to verify.
      dontUseCmakeBuildDir = true;
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
