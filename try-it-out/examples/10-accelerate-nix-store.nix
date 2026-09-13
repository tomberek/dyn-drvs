# Worked example of `dyndrv.accelerate.mkAcceleratedStdenv` applied to
# NixOS/nix's own `nix-store` component -- the next real target after
# example 09's `nix-util` (this component's own DIRECT dependency,
# confirmed via `src/libstore/package.nix`'s own `nix-util` parameter,
# wired automatically through `packaging/components.nix`'s scope
# machinery, no explicit plumbing needed here).
#
# SAME three structural facts as example 09 (meson+ninja, multi-
# component scope via `getStdenv`, `withUnityBuild` as a scope-level
# setting) -- see that file's own header comment for the full
# rationale, not repeated here. What's NEW at this component:
#
#   1. MORE, and DIFFERENT, real dependencies than nix-util needed --
#      confirmed via `src/libstore/package.nix`: `curl`, `sqlite`,
#      `libseccomp` (Linux only) beyond nix-util's own set (boost,
#      brotli, libarchive, libcpuid, libsodium, nlohmann_json, openssl,
#      zstd). `withAWS` (default: `lib.meta.availableOn stdenv.
#      hostPlatform aws-c-common`) is explicitly forced OFF here --
#      pulls in `aws-crt-cpp` + `cmake` (only to resolve THAT
#      dependency) purely to support S3-backed stores, orthogonal to
#      exercising the accelerator itself, so disabling it keeps this
#      example's own dependency surface minimal and focused.
#   2. A GENUINELY NEW GAP, found and fixed while building THIS
#      component specifically: `src/libstore/local-store.cc` uses C23
#      `#embed "schema.sql"` / `#embed "ca-specific-schema.sql"` --
#      the compiler tracks an `#embed`'d file in its own `-MD` depfile
#      exactly like an `#include`, but ninja records that tracking
#      ONLY in its own binary `.ninja_deps` log, never as literal text
#      in `build.ninja` itself (confirmed by direct reproduction: a
#      real `#embed`-using translation unit produces a `build.ninja`
#      with zero occurrences of the embedded file's own name, while
#      `ninja -t deps <target>` correctly lists it). `shim.collectStubs`'s
#      own `../`-reference carry-forward scan (added for example 09's
#      own `ninja install` "missing and no known rule to make it" gap)
#      originally only read `build.ninja`'s TEXT, so it missed these
#      entirely -- fixed by ALSO running `ninja -t deps` (no target
#      arg, dumping every already-logged target's own tracked deps) as
#      a second, complementary source of `../`-prefixed paths to carry
#      forward, alongside the existing text scan.
#
# Run with:
#   try-it-out/run-nix.sh build --impure --no-link --print-out-paths -f try-it-out/examples/10-accelerate-nix-store.nix
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
  # Same pinned rev example 09 uses -- nix-store at this commit is a
  # direct dependent of nix-util at the SAME commit, so pinning both
  # examples to the identical rev keeps the two internally consistent.
  nixRev ? "72385de1bef8b8879384b4810e3b0864f4d3c3da",
  nixSrcFlake ? builtins.getFlake "github:NixOS/nix/${nixRev}",
}:

let
  accelerated = dyndrv.accelerate.mkAcceleratedStdenv {
    inherit (pkgs) stdenv;
    inherit nixPackage dyndrvShim;
  };

  # `getStdenv = _: accelerated`: same reasoning as example 09's own
  # identical binding -- no circularity, `accelerated` is built from
  # the ORIGINAL, unmodified `pkgs.stdenv`.
  components = nixSrcFlake.lib.makeComponents {
    inherit pkgs;
    getStdenv = _: accelerated;
  };

  # `withUnityBuild = false`: see example 09's own header comment --
  # same scope-level setting, same reason (unity builds would defeat
  # per-TU acceleration entirely).
  #
  # Brackets meson's OWN configure-time compiler probes -- see example
  # 09's own header comment for the full rationale (identical
  # mechanism, same two hooks) -- on EVERY component in the scope, not
  # just `nix-store` itself: `nix-store` pulls in `nix-util` as its
  # own build input, built through this SAME scope's `nix-util`
  # attribute -- `overrideAttrs` called only on `scoped.nix-store`
  # does NOT propagate to a dependency resolved via the scope, so
  # `nix-util`'s own meson configure step never got the bypass,
  # deferring its probes as stubs instead of running them
  # synchronously and failing outright ("Unknown linker(s): [['ar']]",
  # meson's own linker-detection probe seeing a batch-pending stub
  # exit status instead of a real one) -- confirmed by direct
  # reproduction. `overrideScope` on BOTH components here, rather than
  # `overrideAttrs` on just the top-level one, fixes this generically
  # for any future component added the same way.
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
    }
  );
in
scoped.nix-store
