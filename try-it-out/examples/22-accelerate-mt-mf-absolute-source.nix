# Regression fixture for a real, precisely-scoped bug in the argv-shape
# classification `toNode`/`cc_to_node` use to decide compile-vs-link/
# probe-vs-real: `firstSourceIdx`/`first_source_idx` only excluded
# `-o`'s own value from candidacy for "the source file," never `-MT`/
# `-MF`/`-MQ`'s own values -- so for a REAL cmake compile (which always
# emits `-MT <target> -MF <depfile>` ahead of `-o`/`-c`), the scan
# wrongly latched onto `-MT`'s own (relative) value as `sourcePath`
# instead of the REAL, absolute source at argv's own end. This meant
# the existing "pass through a compile whose source is still absolute"
# check (there specifically to avoid deferring transient compiler
# self-tests/probes that write scratch files outside the package's own
# build tree) never fired for this shape at all -- the compile got
# wrongly deferred into a per-TU derivation, which then failed for real
# since a deferred derivation's own staged tree never contains an
# absolute host path.
#
# This was ORIGINALLY misdiagnosed as a `discoverTree`-staging/cmake-
# out-of-tree-source bug (see `docs/discovertree-cmake-source-path-bug
# .md`) -- confirmed by direct reproduction against real nixpkgs
# `xxhash` that the actual cause is this argv-shape misclassification,
# one level earlier than `discoverTree` ever runs; the doc's own
# diagnosis has been superseded.
#
# This fixture reproduces the exact `-MT`/`-MF` argv shape cmake emits,
# with the compile's own source path ALREADY absolute (mirroring a
# transient-scratch-file compiler probe run from OUTSIDE the package's
# own build tree, e.g. autoconf's own feature-detection compiles) --
# before the fix, this got wrongly deferred and failed; after the fix,
# it correctly passes through and runs for real, synchronously.
#
# Run with:
#   try-it-out/run-nix.sh build --no-link -f try-it-out/examples/22-accelerate-mt-mf-absolute-source.nix
{
  pkgs ? (builtins.getFlake (toString ../..)).legacyPackages.${builtins.currentSystem},
  lib ? pkgs.lib,
  dyndrv ? import ../../nix { inherit pkgs lib; },
  nixPackage ? import ../patched-nix.nix { system = pkgs.stdenv.hostPlatform.system; },
  dyndrvShim ? null,
}:

let
  src = pkgs.runCommand "accelerate-mt-mf-absolute-source-src" { } ''
    mkdir -p $out
    cat > $out/main.c <<'EOF'
    int main(void) { return 0; }
    EOF
  '';

  plain = lib.makeOverridable (
    { stdenv }:
    stdenv.mkDerivation {
      pname = "accelerate-mt-mf-absolute-source";
      version = "1.0";
      inherit src;
      # A hand-written buildPhase mirroring cmake's OWN generated
      # compile-line shape exactly: `-MT <target> -MF <depfile> -o
      # <output> -c <ABSOLUTE source path>` -- the absolute source is
      # the load-bearing part (mirrors a transient compiler-probe scratch
      # file living outside the package's own relative build tree, e.g.
      # `$TMPDIR/conftest.c`-style autoconf probes, or -- as found here
      # -- a real cmake compile whose OWN source lives one directory
      # above the cmake project root).
      buildPhase = ''
        runHook preBuild
        cp main.c "$TMPDIR/main.c"
        $CC -MD -MT main.o -MF main.o.d -o main.o -c "$TMPDIR/main.c"
        $CC main.o -o prog
        runHook postBuild
      '';
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
