# Worked example of `dyndrv.accelerate.mkAcceleratedStdenv` applied to a
# real piece of Nix's own build (github:NixOS/nix) -- the "eat your own
# dogfood" case for a library whose whole reason to exist is dynamic
# derivations, a Nix feature. Three firsts at once, each independently
# confirmed by direct reading/reproduction, not assumed:
#
#   1. FIRST MESON PROJECT this accelerator has ever run against --
#      every prior example/real-package fixture (05/06/`example/`'s own
#      Makefile, 07's freetype autotools/libtool build) used a different
#      build system. Meson+ninja is what Nix's own build is 100% built
#      on (`~/nix/meson.build`, `packaging/components.nix`'s own
#      `mkMesonLibrary`).
#   2. FIRST MULTI-COMPONENT nixpkgs SCOPE this accelerator has been
#      pointed at -- Nix's build isn't one `stdenv.mkDerivation`, it's
#      ~10 components (`nix-util`, `nix-store`, `nix-expr`, ...) built
#      via a `lib.makeScope`-based scope whose OWN `stdenv` is resolved
#      through a SEPARATE sibling scope (`nixDependencies`, itself given
#      `stdenv = getStdenv pkgs;` at construction time,
#      `packaging/dependencies.nix`) -- confirmed by direct reproduction
#      that `.override { stdenv = ...; }` on an individual component
#      (`nix-util`, etc.) has NO EFFECT AT ALL: the package's own
#      `package.nix` function accepts a `stdenv` PARAMETER (used only
#      for read-only `stdenv.hostPlatform` checks), but the actual
#      `stdenv'.mkDerivation` call inside `mkMesonLibrary` closes over a
#      DIFFERENT `stdenv` value, captured once when the whole component
#      SCOPE was built (`packaging/components.nix:15-23,54`) -- so a
#      per-package override silently does nothing; the ONLY real lever
#      is `getStdenv`, passed to the flake's own PUBLIC
#      `lib.makeComponents { pkgs; getStdenv; }` entry point (documented
#      in `~/nix/flake.nix`, "Creates a package set for a given Nixpkgs
#      instance and stdenv") BEFORE the scope is ever constructed --
#      confirmed working by direct reproduction (`scoped.nix-util.stdenv
#      == accelerated` evaluates `true` this way, `false`/no-op via
#      `.override`).
#   3. FIRST REAL GAP FOUND IN THE ACCELERATOR ITSELF -- meson's own
#      configure-time compiler probes (`meson setup`'s sanity check,
#      every `compiler.compiles()`/`.has_function()` dependency-
#      detection check) are named `testfile.<ext>`/
#      `sanitycheck{c,cpp,...}.*` (confirmed via meson's own source),
#      NOT autoconf's `conftest*` convention `mkAcceleratedStdenv`'s
#      existing `is_conftest` heuristic recognizes -- left unaddressed,
#      every meson probe would get DEFERRED instead of run
#      synchronously, breaking meson's own pass/fail configure logic
#      outright (it needs the real exit code/output immediately, not a
#      batch-pending stub). Fixed by adding `DYNDRV_BYPASS` (see
#      `nix/lib/shim/wrapCommand.nix`'s own doc comment for the full
#      mechanism) -- mirrors nixgg's own identical `NIXGG_BYPASS`,
#      which solved this exact problem for its own qemu/fmt/llvm
#      meson/cmake examples the same way (bracket the WHOLE configure
#      step, don't try to extend the filename heuristic).
#
# SCOPE, stated plainly: only `nix-util` (~90 translation units),
# deliberately -- confirmed via `~/nix/src/libutil/package.nix` to
# depend on ordinary nixpkgs packages only (boost, brotli, libarchive,
# libcpuid, libsodium, nlohmann_json, openssl, zstd), zero dependency on
# any OTHER Nix component, so this is a real, substantial, but
# self-contained first target -- not the full `nix-cli`/`nix-everything`
# (~378 TUs across 6+ interdependent components), which is a natural,
# well-scoped follow-on once this lands.
#
# Run with:
#   try-it-out/run-nix.sh build --impure --no-link --print-out-paths -f try-it-out/examples/09-accelerate-nix-util.nix
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
  # The real NixOS/nix source to build FROM -- same pinned rev
  # `patched-nix.nix` already uses, so this stays internally consistent
  # with the rest of the repo's own pinning discipline (both resolve to
  # the exact same commit, just via two different flake outputs of it:
  # `patched-nix.nix` wants the pre-built `nix` PACKAGE to drive the
  # sandbox with; this wants the SOURCE TREE's own `lib.makeComponents`
  # to build a component FROM).
  nixRev ? "72385de1bef8b8879384b4810e3b0864f4d3c3da",
  nixSrcFlake ? builtins.getFlake "github:NixOS/nix/${nixRev}",
}:

let
  accelerated = dyndrv.accelerate.mkAcceleratedStdenv {
    inherit (pkgs) stdenv;
    inherit nixPackage dyndrvShim;
  };

  # `getStdenv = _: accelerated`: ignores the `pkgs` argument
  # `makeComponents` passes it (no cross-compilation variant needed
  # here) and returns the ALREADY-COMPUTED accelerated stdenv --
  # `accelerated` itself is built from the ORIGINAL, unmodified
  # `pkgs.stdenv` above, so there's no circularity despite this being
  # the SAME `pkgs` value threaded through both places.
  components = nixSrcFlake.lib.makeComponents {
    inherit pkgs;
    getStdenv = _: accelerated;
  };

  # `withUnityBuild = false`: unity builds combine multiple TUs into
  # ONE compile unit (mesonLayer's own `-Dunity=on`,
  # `packaging/components.nix:156-158`), which would defeat per-TU
  # acceleration entirely -- confirmed this IS a real, live-read scope
  # attribute (unlike `stdenv`, see above), so `overrideScope` on the
  # already-constructed `components` works correctly for this one,
  # matching the exact pattern `~/nix/flake.nix`'s own devShells already
  # use for this identical setting.
  scoped = components.overrideScope (final: prev: { withUnityBuild = false; });
in
scoped.nix-util.overrideAttrs (old: {
  # Brackets meson's OWN configure-time compiler probes (its sanity
  # check + every dependency-detection compile/link check) with
  # `DYNDRV_BYPASS` -- see `nix/lib/shim/wrapCommand.nix`'s own doc
  # comment for the full rationale (meson's probes aren't named
  # `conftest*`, so the existing `is_conftest` heuristic never catches
  # them; left deferred, meson's own configure step fails outright).
  # `mesonConfigurePhase` (nixpkgs' `meson` setup-hook) runs
  # `preConfigure` FIRST, then `meson setup` itself, then
  # `postConfigure` -- confirmed directly by reading that setup-hook's
  # own source -- so bracketing exactly these two hooks covers the
  # whole configure step, and nothing else.
  preConfigure = (old.preConfigure or "") + ''
    export DYNDRV_BYPASS=1
  '';
  postConfigure = ''
    unset DYNDRV_BYPASS
  '' + (old.postConfigure or "");
})
