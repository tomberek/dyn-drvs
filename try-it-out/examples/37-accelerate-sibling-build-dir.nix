# Regression fixture for the sibling-build-dir stub-discovery gap
# (x265's real remaining blocker after `bare-lname-link-arg-bug.md`'s
# own `-l<name>` search-path fix): a package's own `preConfigure` hook
# runs a SECOND, entirely independent cmake configure+build cycle
# against a SIBLING directory, before the main build even starts --
# matching x265's own `multibitdepthSupport` shape exactly (`cmake -B
# build-10bits ...`/`cmake -B build-12bits ...` from `source/`, BEFORE
# `configurePhase`'s own `mkdir -p build; cd build`).
#
# Before the fix: `shim.collectStubs`'s stub-discovery (Phase 1) only
# ever scanned `dyndrv_buildRoot` (the MAIN build dir) -- the sibling's
# own real, genuinely-built `ar` stub was never discovered as a stub at
# all, so a later link step referencing it via its own relative symlink
# (`../sibling-build/libhelper.a`, mirroring x265's `ln -s
# ../build-10bits/libx265.a ./libx265-10.a`) failed outright: `ld.bfd:
# cannot find ../sibling-build/libhelper.a: No such file or directory`,
# even though that file's own producing `ar` invocation genuinely ran
# (and correctly deferred) inside this same sandboxed build.
#
# See docs/sibling-build-dir-not-discovered-bug.md for the full
# original writeup this fixes.
#
# Run with:
#   try-it-out/run-nix.sh build --no-link -f try-it-out/examples/37-accelerate-sibling-build-dir.nix
{
  pkgs ? (builtins.getFlake (toString ../..)).legacyPackages.${builtins.currentSystem},
  lib ? pkgs.lib,
  dyndrv ? import ../../nix { inherit pkgs lib; },
  nixPackage ? import ../patched-nix.nix { system = pkgs.stdenv.hostPlatform.system; },
  dyndrvShim ? null,
}:

let
  src = pkgs.runCommand "accelerate-sibling-build-dir-src" { } ''
    mkdir -p $out/sub
    cat > $out/CMakeLists.txt <<'EOF'
    cmake_minimum_required(VERSION 3.10)
    project(siblingbuilddir C)
    add_executable(prog main.c)
    target_link_directories(prog PRIVATE .)
    target_link_libraries(prog helper-alt)
    install(TARGETS prog RUNTIME DESTINATION bin)
    EOF
    cat > $out/main.c <<'EOF'
    extern int helper(void);
    int main(void) { return helper() == 42 ? 0 : 1; }
    EOF
    cat > $out/sub/CMakeLists.txt <<'EOF'
    cmake_minimum_required(VERSION 3.10)
    project(siblinghelper C)
    add_library(helper STATIC helper.c)
    EOF
    cat > $out/sub/helper.c <<'EOF'
    int helper(void) { return 42; }
    EOF
  '';

  plain = lib.makeOverridable (
    { stdenv }:
    stdenv.mkDerivation {
      pname = "accelerate-sibling-build-dir";
      version = "1.0";
      inherit src;
      nativeBuildInputs = [ pkgs.cmake ];
      # Mirrors x265's own `multibitdepthSupport` shape exactly, split
      # across the SAME two hooks x265 itself uses:
      #   - `preConfigure` (runs from `source/`, BEFORE `configurePhase`'s
      #     own `mkdir -p build; cd build`): configures the SIBLING
      #     build dir only (`cmake -S sub -B sub-build`, matching x265's
      #     own `cmake -B build-10bits ...`) -- `sub-build` ends up a
      #     SIBLING of the main `build/` dir once `configurePhase` runs.
      #   - `preBuild` (runs from `build/`, AFTER `configurePhase`'s own
      #     `cd build` -- x265's own `preBuild` comment says exactly
      #     this: "we are in build"): builds the sibling for real
      #     (`make -C ../sub-build`, matching x265's own `make -C
      #     ../build-10bits`) and symlinks its real output into the MAIN
      #     build dir under a DIFFERENT basename (`ln -s
      #     ../sub-build/libhelper.a ./libhelper-alt.a`, matching x265's
      #     own `ln -s ../build-10bits/libx265.a ./libx265-10.a`).
      preConfigure = ''
        cmake -S sub -B sub-build
      '';
      preBuild = ''
        make -C ../sub-build
        ln -s ../sub-build/libhelper.a ./libhelper-alt.a
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
