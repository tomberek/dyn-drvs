# Regression fixture for the libssh-overlay-PR bug: cmake's own
# `install(EXPORT ...)` bakes phase 1's LITERAL placeholder path
# (`/build/dyndrv-placeholder-out`) into a generated target-import
# file's `_IMPORT_PREFIX`, since nixpkgs' multi-output-aware
# `CMAKE_INSTALL_*DIR` flags are already absolute paths under phase 1's
# single forced output -- that tips cmake into emitting a literal
# `set(_IMPORT_PREFIX "...")` rather than the relative
# `get_filename_component`-based form it falls back to when every
# install dir is a plain subpath of one prefix.
#
# `dyndrvCopyPlaceholderScript` (`nix/lib/phases/split.nix`) copies the
# placeholder tree's content into the real `$out` byte-for-byte, but
# (before this fix) never rewrote the literal placeholder STRING baked
# into any file's own CONTENT -- only a meson-specific `.pc`-file
# `includedir` rewrite existed. A caller's own `postFixup` (mirroring
# real nixpkgs libssh's recipe: `substituteInPlace $dev/lib/cmake/
# foo/foo-config.cmake --replace-fail "set(_IMPORT_PREFIX \"$out\")"
# ...`) then failed outright ("doesn't match anything in file ..."),
# since the file only ever contained the placeholder path, never the
# real `$out`.
#
# Confirmed failing before the fix (same "doesn't match anything"
# substituteInPlace error, byte-for-byte) and passing after, against
# this minimal fixture reproducing the exact `install(EXPORT ...)` +
# `postFixup`/`substituteInPlace` shape.
#
# Run with:
#   try-it-out/run-nix.sh build --no-link -f try-it-out/examples/32-accelerate-cmake-import-prefix.nix
{
  pkgs ? (builtins.getFlake (toString ../..)).legacyPackages.${builtins.currentSystem},
  lib ? pkgs.lib,
  dyndrv ? import ../../nix { inherit pkgs lib; },
  nixPackage ? import ../patched-nix.nix { system = pkgs.stdenv.hostPlatform.system; },
  dyndrvShim ? null,
}:

let
  src = pkgs.runCommand "accelerate-cmake-import-prefix-src" { } ''
    mkdir -p $out
    cat > $out/foo.c <<'EOF'
    int foo(void) { return 1; }
    EOF
    cat > $out/CMakeLists.txt <<'EOF'
    cmake_minimum_required(VERSION 3.10)
    project(foo C)
    add_library(foo SHARED foo.c)
    install(TARGETS foo EXPORT foo-config
            RUNTIME DESTINATION ''${CMAKE_INSTALL_BINDIR}
            LIBRARY DESTINATION ''${CMAKE_INSTALL_LIBDIR}
            ARCHIVE DESTINATION ''${CMAKE_INSTALL_LIBDIR})
    install(EXPORT foo-config DESTINATION ''${CMAKE_INSTALL_LIBDIR}/cmake/foo)
    EOF
  '';

  plain = lib.makeOverridable (
    { stdenv }:
    stdenv.mkDerivation {
      pname = "accelerate-cmake-import-prefix";
      version = "1.0";
      inherit src;
      outputs = [ "out" "dev" ];
      nativeBuildInputs = [ pkgs.cmake ];
      postFixup = ''
        substituteInPlace "$dev"/lib/cmake/foo/foo-config.cmake \
          --replace-fail "set(_IMPORT_PREFIX \"$out\")" "set(_IMPORT_PREFIX \"$dev\")"
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
