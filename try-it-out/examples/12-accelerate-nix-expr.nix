# Worked example of `dyndrv.accelerate.mkAcceleratedStdenv` applied to
# NixOS/nix's own `nix-expr` component -- the Nix LANGUAGE evaluator
# itself, the fourth real component in a row (after `nix-util`,
# `nix-store`, `nix-fetchers` -- examples 09-11), directly depending
# on all three (confirmed via `src/libexpr/package.nix`'s own
# `propagatedBuildInputs`).
#
# FIRST component with GENERATED PARSER/LEXER source -- confirmed via
# direct reading of `src/libexpr/meson.build`: a `custom_target`
# invokes `bison -o parser-tab.cc parser.y -d`, then a SECOND
# `custom_target` invokes `flex --outfile lexer-tab.cc lexer.l` (this
# one depending on bison's OWN output, `parser_tab`, chaining two
# DIFFERENT external generators). Both generated `.cc`/`.hh` files are
# compiled into their own SEPARATE static library (`nixexpr-parser`),
# which meson's own `meson.build` explicitly builds with
# `override_options: ['unity=off', 'b_lto=false' (for gcc), ...]` --
# meson ITSELF disables unity build and (for gcc) LTO for just this
# one static lib, since "unity builds mess up the recursive header
# dependency between flex and bison generated code."
#
# Despite this being architecturally novel (a `custom_target` chaining
# TWO different external generators, not meson's own compiler), no NEW
# accelerator-side fix was needed to build this successfully --
# `bison`/`flex`'s own OUTPUT files (`parser-tab.cc`/`lexer-tab.cc`/
# their own `.hh` headers) land directly in the BUILD directory
# itself (not one level up, unlike a `../`-relative SOURCE reference),
# so the existing per-TU discovery (gcc's own `-MD` depfile scan) sees
# them exactly like any other in-tree generated header -- confirmed by
# direct build success, not assumed.
#
# Also FIRST component using the `nix-meson-build-support/generate-
# header` mechanism (`src/libexpr/primops/meson.build`'s own
# `subdir()`): a meson `generator()` shells out to `bash -c` wrapping
# an arbitrary input file as a C++ raw-string-literal header
# (`<name>.gen.hh`, `#include`d directly, e.g. wrapping `fetchurl.nix`'s
# own text) -- like the parser/lexer case above, this generator's own
# OUTPUT lands in the build directory too, so it's likewise already
# covered by the existing discovery mechanism with no new fix needed.
#
# Same three structural facts as examples 09-11 apply unchanged
# (meson+ninja, multi-component scope via `getStdenv`, `withUnityBuild`
# as a scope-level setting needing the same `overrideScope` override,
# `DYNDRV_BYPASS` bracketing needing to cover EVERY component pulled in
# through the scope) -- see example 09's own header comment for the
# full rationale, not repeated here.
#
# Run with:
#   try-it-out/run-nix.sh build --impure --no-link --print-out-paths -f try-it-out/examples/12-accelerate-nix-expr.nix
#
# `dyndrvShim ? null`: same convention as every other example -- pass
# the compiled `rust/dyndrv-shim` package to exercise the compiled `cc`
# shim path instead of the default bash `toNodeBash`/`collectStubs`
# path.

{
  pkgs ? (builtins.getFlake (toString ../..)).legacyPackages.${builtins.currentSystem},
  lib ? pkgs.lib,
  dyndrv ? import ../../nix { inherit pkgs lib; },
  # See 05-accelerate-stdenv.nix's own comment on this -- must match
  # the Nix `try-it-out/run-nix.sh` uses to drive this build.
  nixPackage ? import ../patched-nix.nix { system = pkgs.stdenv.hostPlatform.system; },
  dyndrvShim ? null,
  # Same pinned rev examples 09-11 use.
  nixRev ? "72385de1bef8b8879384b4810e3b0864f4d3c3da",
  nixSrcFlake ? builtins.getFlake "github:NixOS/nix/${nixRev}",
}:

let
  accelerated = dyndrv.accelerate.mkAcceleratedStdenv {
    inherit (pkgs) stdenv;
    inherit nixPackage dyndrvShim;
  };

  components = nixSrcFlake.lib.makeComponents {
    inherit pkgs;
    getStdenv = _: accelerated;
  };

  dyndrvBypassConfigure = old: {
    preConfigure = (old.preConfigure or "") + ''
      export DYNDRV_BYPASS=1
    '';
    postConfigure = ''
      unset DYNDRV_BYPASS
    '' + (old.postConfigure or "");
  };
  scoped = components.overrideScope (
    final: prev: {
      withUnityBuild = false;
      nix-util = prev.nix-util.overrideAttrs dyndrvBypassConfigure;
      nix-store = (prev.nix-store.override { withAWS = false; }).overrideAttrs dyndrvBypassConfigure;
      nix-fetchers = prev.nix-fetchers.overrideAttrs dyndrvBypassConfigure;
      nix-expr = prev.nix-expr.overrideAttrs dyndrvBypassConfigure;
    }
  );
in
scoped.nix-expr
