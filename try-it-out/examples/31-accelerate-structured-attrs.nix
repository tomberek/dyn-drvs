# Regression fixture for task #143: `phases.split`'s `sandboxedDrv` must
# force `__structuredAttrs = false`, regardless of what the caller's own
# `sandboxed` attrset sets.
#
# Confirmed via a minimal isolated reproduction: under
# `__structuredAttrs = true`, Nix's own builder generates the sandboxed
# shell's env vars FROM the derivation's real, computed CA output path
# (via `NIX_ATTRS_SH_FILE`, sourced before `stdenv/setup` runs) --
# completely IGNORING the literal `out = dyndrvPlaceholderOut` attribute
# override `sandboxedDrv` sets. `$out` resolved to the REAL store path
# instead of the placeholder, defeating this whole file's own "install
# into a fake path now, copy into the real `$out` later" mechanism
# entirely. Confirmed via real nixpkgs `brotli` (the package that first
# surfaced this, `nix-dyn-drv/overlay` PR #9): every real per-TU
# compile/link succeeded, but the final derivation failed ("failed to
# produce output path for output 'lib'") since nothing ever went through
# the placeholder-then-restore path at all.
#
# This fixture reproduces the exact shape directly: a multi-output
# (`out`/`dev`/`lib`) cmake package with `__structuredAttrs = true` set
# explicitly -- confirmed failing before the fix ("failed to produce
# output path for output 'lib'"), passing after.
#
# Run with:
#   try-it-out/run-nix.sh build --no-link -f try-it-out/examples/31-accelerate-structured-attrs.nix
{
  pkgs ? (builtins.getFlake (toString ../..)).legacyPackages.${builtins.currentSystem},
  lib ? pkgs.lib,
  dyndrv ? import ../../nix { inherit pkgs lib; },
  nixPackage ? import ../patched-nix.nix { system = pkgs.stdenv.hostPlatform.system; },
  dyndrvShim ? null,
}:

let
  src = pkgs.runCommand "accelerate-structured-attrs-src" { } ''
    mkdir -p $out
    cat > $out/main.c <<'EOF'
    int main(void) { return 0; }
    EOF
    cat > $out/CMakeLists.txt <<'EOF'
    cmake_minimum_required(VERSION 3.10)
    project(structuredattrstest C)
    add_library(mylib SHARED main.c)
    add_executable(prog main.c)
    install(TARGETS prog RUNTIME DESTINATION bin)
    install(TARGETS mylib LIBRARY DESTINATION lib)
    EOF
  '';

  plain = lib.makeOverridable (
    { stdenv }:
    stdenv.mkDerivation {
      pname = "accelerate-structured-attrs";
      version = "1.0";
      inherit src;
      __structuredAttrs = true;
      nativeBuildInputs = [ pkgs.cmake ];
      outputs = [ "out" "dev" "lib" ];
    }
  ) { inherit (pkgs) stdenv; };
in
plain.override {
  stdenv = dyndrv.accelerate.mkAcceleratedStdenv {
    inherit (plain) stdenv;
    inherit nixPackage dyndrvShim;
  };
}
