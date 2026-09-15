# Regression fixture for the dav1d-overlay-PR bug: meson's own
# compiler-check primitives (`cc.get_supported_arguments(...)`, the
# mechanism real packages like dav1d use to conditionally enable
# compiler flags) must run for real, not defer -- see
# `mkAcceleratedStdenv.nix`'s own `isMesonProbe` header comment for the
# full rationale.
#
# This project probes for `-Qunused-arguments` (a real, Clang-ONLY flag
# gcc has never supported) via `cc.get_supported_arguments`, then only
# adds it to the real target's own compile args if the probe reports
# support. Before the fix: the probe's own deferred stub always
# "succeeds" (exit 0, regardless of what the real, unaccelerated compile
# would report), so meson wrongly concludes gcc supports the flag, bakes
# it into the real target's own compile args, and the real `main.c`
# compile then fails outright with "gcc: error: unrecognized
# command-line option '-Qunused-arguments'". After the fix: the probe is
# recognized (its scratch source file is unconditionally named
# `testfile.<suffix>`, meson's own exact analog to autoconf's
# `conftest` convention) and passed through to run for real, correctly
# reporting failure against gcc, so the flag is never added and the
# real compile succeeds.
#
# Run with:
#   try-it-out/run-nix.sh build --no-link -f try-it-out/examples/33-accelerate-meson-probe.nix
{
  pkgs ? (builtins.getFlake (toString ../..)).legacyPackages.${builtins.currentSystem},
  lib ? pkgs.lib,
  dyndrv ? import ../../nix { inherit pkgs lib; },
  nixPackage ? import ../patched-nix.nix { system = pkgs.stdenv.hostPlatform.system; },
  dyndrvShim ? null,
}:

let
  src = pkgs.runCommand "accelerate-meson-probe-src" { } ''
    mkdir -p $out
    cat > $out/main.c <<'EOF'
    int main(void) { return 0; }
    EOF
    cat > $out/meson.build <<'EOF'
    project('mesonprobe', 'c')
    cc = meson.get_compiler('c')
    supported_args = cc.get_supported_arguments(['-Qunused-arguments'])
    executable('prog', 'main.c', c_args: supported_args, install: true)
    EOF
  '';

  plain = lib.makeOverridable (
    { stdenv }:
    stdenv.mkDerivation {
      pname = "accelerate-meson-probe";
      version = "1.0";
      inherit src;
      nativeBuildInputs = [ pkgs.meson pkgs.ninja pkgs.pkg-config ];
      mesonBuildType = "plain";
    }
  ) { inherit (pkgs) stdenv; };
in
plain.override {
  stdenv = dyndrv.accelerate.mkAcceleratedStdenv {
    inherit (plain) stdenv;
    inherit nixPackage dyndrvShim;
  };
}
