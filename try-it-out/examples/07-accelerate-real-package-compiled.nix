# Test variant of example 07 using the compiled dyndrv-shim/dyndrv-collect
# path (dyndrvShim passed through) instead of the bash toNodeBash/
# collectStubs path -- for direct comparison against the original
# 07-accelerate-real-package.nix build. Exercises the compiled `cc`
# shim's discoverTree-equivalent path (cc.rs's `discover_tree`/
# `cc_to_node`) against a real, unmodified nixpkgs package (freetype,
# libtool/autotools, ~45 translation units, real cross-package -I/-L
# build inputs) -- the actual scale/complexity 05/06's toy fixtures
# don't exercise.
let
  pkgs = import <nixpkgs> { };
  lib = pkgs.lib;
  dyndrv = import ../../nix { inherit pkgs lib; };
  patchedNix = import ../patched-nix.nix { };
  dyndrvShim = import ../../rust/dyndrv-shim.nix { inherit pkgs; };

  acceleratedStdenv = dyndrv.accelerate.mkAcceleratedStdenv {
    stdenv = pkgs.stdenv;
    nixPackage = patchedNix;
    inherit dyndrvShim;
  };

  accelerated = pkgs.freetype.override { stdenv = acceleratedStdenv; };

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
