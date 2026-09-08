# Worked example of `dyndrv.accelerate.mkAcceleratedStdenv` applied to a
# REAL, UNMODIFIED nixpkgs package (`freetype`) rather than a toy fixture
# (see 05/06 for those) -- the actual adoption story this library exists
# to make cheap: point the accelerator at a package you already have, no
# rewrite, and see per-translation-unit caching kick in.
#
# The one-line change (same shape as 05/06, just against a real package):
#
#   pkgs.freetype.override {
#     stdenv = dyndrv.accelerate.mkAcceleratedStdenv { inherit stdenv; nixPackage = ...; };
#   }
#
# Verified two ways, not just "the build succeeded":
#   1. The resulting `libfreetype.so` is actually LOADED and RUN by a
#      small C test program (`FT_Init_FreeType`/`FT_Library_Version`),
#      confirming the accelerated build produces a genuinely correct,
#      usable library -- not just a build log with no errors in it. This
#      mirrors examples 05/06's own binary-output check and this
#      project's own established verification discipline throughout
#      (a build succeeding is necessary, not sufficient).
#   2. `patchOutput` (below) shows the SAME package, `.overrideAttrs`'d
#      with one extra source-file patch -- confirming `overrideAttrs`
#      correctly reaches phase 1 (patches/configureFlags/buildPhase all
#      need to affect the SANDBOXED phase, not just install/fixup) and
#      that only the patched file's own translation units register as
#      new dynamic derivations, not the whole package. See
#      `try-it-out/benchmarks/real-package-patch-rebuild.sh`/
#      `real-package-version-bump.sh` for the numbers this same property
#      produces at full scale, measured over a real timed rebuild.
#
# `builder-rpc-v0`-only (phase 1's own requirement; phase 2, which runs
# `installPhase`/`fixupPhase`, needs no special capability at all --
# nixpkgs' own real multi-output machinery runs there unmodified, which
# is why this example needs no `outputs = ["out"]` collapse the way an
# earlier, now-superseded architecture once did).
#
# Run with:
#   try-it-out/run-nix.sh build --impure --no-link --print-out-paths -f try-it-out/examples/07-accelerate-real-package.nix
#
# Then, to actually verify the library (same check this example's own
# development used): build a tiny test program against the result --
#   nix-shell -p gcc --run '
#     OUT=<accelerated output path>
#     DEV=<accelerated -dev output path>
#     gcc -I"$DEV/include/freetype2" test.c -L"$OUT/lib" -lfreetype -Wl,-rpath,"$OUT/lib" -o test
#     ./test
#   '
# expecting output "FreeType 2.14.3".
#
# `dyndrvShim ? null`: pass the compiled `rust/dyndrv-shim` package
# (`import ../../rust/dyndrv-shim.nix { inherit pkgs; }`) to exercise the
# compiled `cc` shim's discoverTree-equivalent path (cc.rs's
# `discover_tree`/`cc_to_node`) against this real package's ~45
# translation units and real cross-package -I/-L build inputs -- scale
# and complexity 05/06's toy fixtures don't exercise -- instead of the
# default bash `toNodeBash`/`collectStubs` path.

{
  pkgs ? import <nixpkgs> { },
  lib ? pkgs.lib,
  dyndrv ? import ../../nix { inherit pkgs lib; },
  # See 05-accelerate-stdenv.nix's own comment on this -- must match the
  # Nix `try-it-out/run-nix.sh` uses to drive this build.
  nixPackage ? import ../patched-nix.nix { },
  dyndrvShim ? null,
}:

let
  acceleratedStdenv = dyndrv.accelerate.mkAcceleratedStdenv {
    stdenv = pkgs.stdenv;
    inherit nixPackage dyndrvShim;
  };

  # The one-line change: override the stdenv a REAL, unmodified nixpkgs
  # package is built with. `pkgs.freetype` (real multi-output package,
  # `outputs = ["out" "dev"]`, libtool/autotools, ~45 translation units,
  # several other libraries as real -I/-L build inputs) needs nothing
  # else changed at all.
  accelerated = pkgs.freetype.override { stdenv = acceleratedStdenv; };

  # A one-line, comment-only patch to a real source file -- demonstrates
  # the SAME property `real-package-patch-rebuild.sh` measures at scale:
  # after this patch, only `src/base/ftglyph.c`'s own translation units
  # (2 of them -- libtool compiles every source twice, once static and
  # once -fPIC for the shared library) need to be freshly compiled and
  # registered as new dynamic derivations; nixpkgs' own `overrideAttrs`
  # idiom is the standard way any real caller would apply a patch or bump
  # a version, and `mkAcceleratedStdenv`'s own `overrideAttrs` (fixed to
  # correctly re-run phase 1, not just phase 2 -- see that file's own
  # header comment for the "why" of this fix) makes it work exactly the
  # same way it would against the plain, unaccelerated `stdenv`.
  patchOutput = accelerated.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      (pkgs.writeText "example-patch.diff" ''
        --- a/src/base/ftglyph.c
        +++ b/src/base/ftglyph.c
        @@ -1,5 +1,6 @@
         /****************************************************************************
          *
        + * dyndrv example: this comment simulates a one-line patch/version bump
          * ftglyph.c
          *
          *   FreeType convenience functions to handle glyphs (body).
      '')
    ];
  });
in
{
  inherit accelerated patchOutput;
}
