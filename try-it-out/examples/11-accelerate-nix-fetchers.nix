# Worked example of `dyndrv.accelerate.mkAcceleratedStdenv` applied to
# NixOS/nix's own `nix-fetchers` component -- the third real component
# in a row (after `nix-util`, example 09, and `nix-store`, example
# 10), one step deeper into NixOS/nix's own dependency graph.
# `nix-fetchers` DIRECTLY depends on both `nix-util` and `nix-store`
# (confirmed via `src/libfetchers/package.nix`'s own
# `propagatedBuildInputs`), plus one new dependency beyond what those
# two already need: `libgit2`.
#
# The SIMPLEST of the three so far -- confirmed via direct reading of
# `src/libfetchers/meson.build`: no generated/embedded source content
# at all (unlike `nix-store`'s C23 `#embed`-using `local-store.cc`),
# just a plain `sources = files(...)` list across its own 17 `.cc`
# files. Same three structural facts as examples 09/10 apply
# unchanged (meson+ninja, multi-component scope via `getStdenv`,
# `withUnityBuild` as a scope-level setting needing the same
# `overrideScope` override) -- see example 09's own header comment for
# the full rationale, not repeated here.
#
# Uses the SAME `overrideScope`-brackets-every-component-in-the-scope
# pattern example 10 introduced (needed there because `nix-store`
# pulls in `nix-util` through the SAME scope, and `overrideAttrs`
# alone doesn't propagate across that) -- `nix-fetchers` pulls in BOTH
# `nix-util` and `nix-store` the identical way, so all three need
# bracketing here too.
#
# Run with:
#   try-it-out/run-nix.sh build --impure --no-link --print-out-paths -f try-it-out/examples/11-accelerate-nix-fetchers.nix
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
  # Same pinned rev examples 09/10 use.
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
    }
  );
in
scoped.nix-fetchers
