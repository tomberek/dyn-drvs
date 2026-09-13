# Worked example of `dyndrv.accelerate.mkAcceleratedStdenv` applied to
# NixOS/nix's own `nix-main` component -- the sixth real component in
# a row (after `nix-util`, `nix-store`, `nix-fetchers`, `nix-expr`,
# `nix-flake` -- examples 09-13), directly depending on `nix-expr`
# (transitively `nix-util`/`nix-store`) plus `openssl` (already a
# `nix-util` dependency, nothing new).
#
# No new dependencies, no generators, no custom_targets -- confirmed
# via direct reading of `src/libmain/meson.build` and `package.nix`.
#
# Same three structural facts as examples 09-13 apply unchanged
# (meson+ninja, multi-component scope via `getStdenv`, `withUnityBuild`
# as a scope-level setting needing the same `overrideScope` override,
# `DYNDRV_BYPASS` bracketing needing to cover EVERY component pulled in
# through the scope) -- see example 09's own header comment for the
# full rationale, not repeated here.
#
# Run with:
#   try-it-out/run-nix.sh build --impure --no-link --print-out-paths -f try-it-out/examples/14-accelerate-nix-main.nix
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
  # Same pinned rev examples 09-13 use.
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
      nix-main = prev.nix-main.overrideAttrs dyndrvBypassConfigure;
    }
  );
in
scoped.nix-main
