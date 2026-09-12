# Worked example of `dyndrv.accelerate.mkAcceleratedStdenv` applied to
# NixOS/nix's own `nix-cli` component -- the FINAL, TOP-LEVEL `nix`
# executable itself, completing the full dependency chain started in
# example 09 (`nix-util` -> `nix-store` -> `nix-fetchers` -> `nix-expr`
# -> `nix-flake` -> `nix-main` -> `nix-cmd` -> `nix-cli`).
#
# FIRST component that's an EXECUTABLE, not a shared library --
# `mkMesonExecutable` instead of `mkMesonLibrary` (confirmed via
# `src/nix/package.nix`) -- and the first whose own `meson.build`
# creates `install_symlink`/`custom_target ln -sf` entries for every
# one of `nix`'s own conventional entry points (`nix-build`,
# `nix-env`, `nix-store`, `nix-shell`, ... -- ~12 symlinks total, plus
# `build-remote`), all pointing at the SAME one compiled binary. No
# NEW accelerator-side fix was needed for any of this -- confirmed by
# direct build success -- since these `ln -sf` custom_targets are
# ordinary ninja build edges with real, already-resolved inputs
# (`depends: this_exe`), not compiler invocations at all, so they're
# outside the accelerator's own interception surface entirely (only
# `cc`/`c++`/`ar`/`ranlib` are ever intercepted).
#
# `withPluginCApi ? true` (default, confirmed via `src/nix/package.nix`)
# pulls in SIX more small components beyond `nix-cmd` itself:
# `nix-util-c`, `nix-store-c`, `nix-fetchers-c`, `nix-expr-c`,
# `nix-flake-c`, `nix-main-c` (plain C-API shim libraries, embedding
# the public C API into the `nix` binary so plugins can resolve those
# symbols without linking the C++ libraries directly) -- every one of
# these, like `nix-cmd` before it, needs its own `overrideAttrs`
# bracket in the scope below, for the SAME reason `nix-store` needed
# it for `nix-util` in example 10 (a component pulled in through the
# SAME scope needs its OWN bracket; a caller-side `overrideAttrs` on
# just the top-level component doesn't propagate).
#
# Run with:
#   try-it-out/run-nix.sh build --impure --no-link --print-out-paths -f try-it-out/examples/16-accelerate-nix-cli.nix
#
# `dyndrvShim ? null`: same convention as every other example -- pass
# the compiled `rust/dyndrv-shim` package to exercise the compiled `cc`
# shim path instead of the default bash `toNodeBash`/`collectStubs`
# path.

{
  pkgs ? import <nixpkgs> { },
  lib ? pkgs.lib,
  dyndrv ? import ../../nix { inherit pkgs lib; },
  # See 05-accelerate-stdenv.nix's own comment on this -- must match
  # the Nix `try-it-out/run-nix.sh` uses to drive this build.
  nixPackage ? import ../patched-nix.nix { },
  dyndrvShim ? null,
  # Same pinned rev examples 09-15 use.
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
      nix-flake = prev.nix-flake.overrideAttrs dyndrvBypassConfigure;
      nix-main = prev.nix-main.overrideAttrs dyndrvBypassConfigure;
      nix-cmd = prev.nix-cmd.overrideAttrs dyndrvBypassConfigure;
      nix-util-c = prev.nix-util-c.overrideAttrs dyndrvBypassConfigure;
      nix-store-c = prev.nix-store-c.overrideAttrs dyndrvBypassConfigure;
      nix-fetchers-c = prev.nix-fetchers-c.overrideAttrs dyndrvBypassConfigure;
      nix-expr-c = prev.nix-expr-c.overrideAttrs dyndrvBypassConfigure;
      nix-flake-c = prev.nix-flake-c.overrideAttrs dyndrvBypassConfigure;
      nix-main-c = prev.nix-main-c.overrideAttrs dyndrvBypassConfigure;
      nix-cli = prev.nix-cli.overrideAttrs dyndrvBypassConfigure;
    }
  );
in
scoped.nix-cli
