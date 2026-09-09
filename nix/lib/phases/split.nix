{ pkgs, lib, self }:

# General "sandboxed, then replay" two-derivation split -- nixgg's own
# `dynDrvStdenv` phase1/phase2 pattern, built here as a standalone,
# reusable primitive rather than reinvented inside `accelerate.
# mkAcceleratedStdenv` (this library's first real consumer of it).
#
# WHY THIS EXISTS: a `builder-rpc-v0`-gated derivation can register other
# derivations (`nix derivation add`) but can NEVER build/realize one from
# inside its own running script (`BuildPaths`/`QueryMissing` are absent
# from that backend's connection-mode opcode allowlist -- see
# `shim/wrapCommand.nix`'s header for the full, source-verified finding).
# So a package whose build needs dynamic-derivation acceleration DURING
# `buildPhase` (e.g. `accelerate.mkAcceleratedStdenv`'s deferred `cc`/`ar`
# shims) cannot ALSO run `installPhase`/`fixupPhase` in that same
# sandboxed derivation -- those need a real, resolved `$out` tree to
# work against, which `builder-rpc-v0` structurally cannot produce
# inline. The fix is this file's own split: phase 1 stays sandboxed
# (gated on `builder-rpc-v0`) and only goes as far as submitting a
# resolved build-tree snapshot; phase 2 is an ORDINARY derivation (no
# special capability needed at all) that consumes that snapshot and
# runs the remaining phases completely normally -- real `$out`, real
# multi-output support (nixpkgs' own multi-output machinery runs
# unmodified in phase 2, since nothing there is intercepted).
#
# `pname`/`version`: required. Phase 1's OWN derivation is named
#   `"${pname}-${version}.drv"` -- the SAME ".drv"-suffixed convention
#   `mkDynamicDerivation.nix`'s outer wrapper uses, for the SAME reason:
#   `nix store submit-output` submits the `.drv` FILE ITSELF as the
#   content, so the on-disk `.drv` file's own name must match what the
#   outer CA derivation's naming validation expects -- confirmed
#   necessary by direct reproduction (an un-suffixed name here fails
#   with "was named '<name>.drv', expected '<name>'"). The INNER
#   submitted node (`shim.collectStubs`'s own final registered
#   derivation) is named plainly `"${pname}-${version}"` (no suffix) --
#   `collectStubs`'s `name` argument is threaded through as this
#   un-suffixed inner name, matching `graph.compile`'s own identical
#   convention for its own synthesized final node.
# `stdenv`: the stdenv phase 1's `sandboxedPhases` should actually run
#   under (e.g. so a real compiler is on `$PATH` during `buildPhase`).
# `sandboxed`: the FULL attrset that would normally go to
#   `stdenv.mkDerivation` for building the package for real -- `src`,
#   `nativeBuildInputs`, `patches`, `configureFlags`, a custom
#   `buildPhase` if the package has one, etc. This file does NOT
#   override or wrap `buildPhase`'s own content at all -- whatever the
#   caller supplies (or nixpkgs' own default `make`-based one) runs
#   completely unmodified; accelerating what happens DURING it (e.g. via
#   shimmed `cc`/`ar`) is the CALLER's job (`accelerate.
#   mkAcceleratedStdenv`'s), not this primitive's.
# `sandboxedPhases`: default `[ "unpackPhase" "patchPhase"
#   "configurePhase" "buildPhase" ]` -- phase 1's own `phases` list is
#   this PLUS one synthesized final phase (`collectPhase`) that runs
#   `shim.collectStubs`'s whole-tree resolution pass and submits the
#   result.
# `replay`: the attrset passed to phase 2 -- `installPhase`,
#   `fixupPhase`, `outputs` (multi-output works here), `meta`, etc.
#   `src`/`phases`/`unpackPhase` are set BY this file (phase 2's own
#   "unpack" is "copy phase 1's already-resolved tree in place", not a
#   real source unpack) -- supplying those in `replay` is an error.
# `replayPhases`: default `[ "installPhase" "fixupPhase" ]`.
# `nixPackage`: same as elsewhere -- the Nix to run registration/
#   submission commands with, inside phase 1's sandbox.
#
# THE RESTORE STEP: phase 1's `configurePhase` runs with NO real `$out`
# (`builder-rpc-v0` structurally can't produce one -- see above), so any
# nixpkgs package whose `configureFlags` bake `$out`'s value into the
# generated build system literally (rather than deferring it via Make's
# own `$(out)`-style variable syntax) ends up with the WRONG, placeholder
# path frozen into its Makefiles -- confirmed by direct reproduction
# against real, unmodified freetype: `configureFlags` includes
# `--prefix=${dyndrvPlaceholderOut}` (stdenv's own automatic multi-output
# logic, `multiple-outputs.sh`'s `_multioutConfig`, substitutes
# `${!outputBin}` etc. at CONFIGURE time). Since phase 1 always forces
# `outputs = ["out"]` (see above), every OTHER output variable (`dev`,
# `bin`, ...) is simply unset there -- `multiple-outputs.sh`'s own
# `_overrideFirst outputDev "dev" "out"` falls back to `"out"` for every
# one of them, so EVERYTHING configure bakes in collapses to the single
# literal `${dyndrvPlaceholderOut}`, not a per-output-suffixed set of
# placeholder paths (confirmed directly: no
# `${dyndrvPlaceholderOut}-dev`-style path appears anywhere in a real
# freetype configure run). `make install` in phase 2 (which reads the
# ALREADY-GENERATED Makefile, unaffected by phase 2's own real,
# multi-output `$out`/`$dev` env vars) therefore writes everywhere under
# that one `${dyndrvPlaceholderOut}/...` root instead of the real
# per-output paths, and `fixupPhase` then fails outright since nothing
# was ever installed under the real `$dev/include` etc.
#
# WHY UNDER `/build`, NOT `/nonexistent`: this placeholder must be a path
# the SANDBOX ITSELF can actually create and write to -- confirmed by
# direct reproduction that a real Nix sandbox's root filesystem is
# `drwxr-x---`, owned by the build user/group with NO write permission
# even for that same group, so an absolute path outside the sandbox's
# own bind-mounted build directory (`/nonexistent`, matching
# `mkDynamicDerivation.nix`'s own placeholder-output convention, which
# only ever needs the path to be UNWRITABLE, never to be written to)
# fails outright with "Permission denied" the moment `make install`
# actually tries to `mkdir` it in phase 2. `/build` (Nix's own
# `sandbox-build-dir` setting, confirmed present and writable in every
# sandboxed derivation) is the one absolute path guaranteed writable
# regardless of the sandbox's own root-permission scheme -- using a
# literal path underneath it (not `$NIX_BUILD_TOP`, an env var only
# available at the CALLING derivation's OWN build time, not after that
# Makefile has already been generated and carried into phase 2's fresh
# sandbox) works identically in both phase 1 (where it's set but never
# written to) and phase 2 (where `make install` actually creates it).
#
# The fix: after `installPhase` runs (and BEFORE `fixupPhase`, which
# needs the real paths to exist), `dyndrvRestoreOutput` merges
# `${dyndrvPlaceholderOut}`'s ENTIRE tree into the real `$out` -- not
# split across outputs, since nothing in the generated build system ever
# distinguished them -- via `cp -r`+`chmod -R u+w` (matching this
# codebase's own established staging idiom elsewhere) rather than a
# plain `mv`, since `installPhase` may ALSO have written some files
# directly to the real `$out`/`$dev` already (e.g. via a `postInstall`
# hook that references `$dev` directly, unaffected by this bug at all)
# that must not be clobbered. Multi-output-aware packages (`fixupPhase`'s
# own `_multioutDevs`/`_multioutDocs` hooks) then correctly redistribute
# `$out`'s newly-merged content across the real outputs exactly as they
# always would for an ordinary, non-accelerated build -- this restore
# step's only job is getting everything OFF the placeholder root and
# INTO the one real path multi-output's own existing, unmodified
# machinery already knows how to split correctly.

{
  pname,
  version,
  stdenv,
  sandboxed,
  sandboxedPhases ? [
    "unpackPhase"
    "patchPhase"
    "configurePhase"
    "buildPhase"
  ],
  replay,
  replayPhases ? [
    "installPhase"
    "fixupPhase"
  ],
  nixPackage ? pkgs.nix,
  # The compiled `rust/dyndrv-shim` package (providing `bin/dyndrv-collect`),
  # to use for the end-of-`buildPhase` collection pass instead of the bash
  # `shim.collectStubs` -- verified byte-identical against the bash
  # collector for the same input (see `rust/dyndrv-shim/collect-
  # integration-test.nix`). Defaults to `null` (bash path, unchanged
  # behavior).
  dyndrvShim ? null,
}:

let
  useCompiledCollect = dyndrvShim != null;

  # A fixed, `/build`-relative placeholder path -- see this file's own
  # "WHY UNDER `/build`, NOT `/nonexistent`" header comment above for why
  # this specific absolute path (not `/nonexistent`, not `$NIX_BUILD_TOP`)
  # is required. Not itself unique per build; that's fine, since it's
  # only ever real content within ONE sandboxed derivation's own build
  # directory at a time, never shared across builds.
  dyndrvPlaceholderOut = "/build/dyndrv-placeholder-out";

  # The submitted (inner) node's own name must match phase 1's OUTER
  # derivation's name exactly -- but `nix store submit-output` submits
  # the `.drv` FILE ITSELF as the content (same mechanism `viaDerivationAdd
  # .nix`'s own `nix store submit-output "$drvPath" out` call uses),
  # so `sandboxedDrv`'s own name needs the SAME ".drv"-suffixed
  # convention `mkDynamicDerivation.nix`'s outer wrapper uses -- and
  # `sandboxedResult` below needs the SAME double-`outputOf` unwrap
  # (level 1: the submitted `.drv` FILE; level 2: THAT drv's own real
  # output) that convention requires. Confirmed necessary by direct
  # reproduction: without the ".drv" suffix here, `submit-output`
  # rejected the correctly-named (un-suffixed) inner node with "was
  # named '<name>.drv', expected '<name>'" -- i.e. NIX ITSELF expects
  # the `.drv`-suffixed name on the OUTER wrapper whenever the inner
  # content crosses through `submit-output`, regardless of backend.
  name = "${pname}-${version}.drv";
  innerName = "${pname}-${version}";

  collectScript =
    if useCompiledCollect then
      ''
        export DYNDRV_COREUTILS_BIN="${pkgs.coreutils}/bin"
        "${dyndrvShim}/bin/dyndrv-collect" . ${lib.escapeShellArg innerName}
      ''
    else
      (self.shim.collectStubs { name = innerName; inherit nixPackage; }).collectScript;

  # Phase 1: real unpack/patch/configure/build (unmodified, whatever the
  # caller supplied), gated on `builder-rpc-v0`, ending in a synthesized
  # `collectPhase` that never touches `$out` directly (mirrors
  # `mkDynamicDerivation.nix`'s own `out = "/nonexistent"` override and
  # its accompanying rationale: stdenv's `_assignFirst` bookkeeping
  # needs SOME output variable set, but the real output is whatever
  # `nix store submit-output` submits, not a conventional file write).
  sandboxedDrv = stdenv.mkDerivation (
    sandboxed
    // {
      inherit name;
      phases = sandboxedPhases ++ [ "collectPhase" ];
      requiredSystemFeatures = (sandboxed.requiredSystemFeatures or [ ]) ++ [ "builder-rpc-v0" ];
      # ALWAYS single-output, regardless of what the wrapped package
      # itself declares (`sandboxed` may be a real package's own attrset,
      # e.g. a multi-output `pkgs.freetype`, inherited via `.override`) --
      # a `.drv`-suffixed name (required, see above) is only valid for a
      # derivation producing EXACTLY one output (confirmed by direct
      # reproduction: inheriting freetype's own `outputs = ["out" "dev"]`
      # here fails outright with "derivation names are allowed to end in
      # '.drv' only if they produce a single derivation file"). Any real
      # multi-output declaration belongs on PHASE 2 (below), where it
      # works completely normally -- phase 1 only ever produces the ONE
      # `.drv` file `shim.collectStubs` submits.
      outputs = [ "out" ];
      # `separateDebugInfo = false`: nixpkgs' own stdenv machinery
      # injects an EXTRA "debug" output whenever `separateDebugInfo =
      # true` is set, INDEPENDENTLY of the plain `outputs` attrset
      # above -- confirmed by direct reproduction against NixOS/nix's
      # own `nix-util` component (`separateDebugInfo = true`,
      # `packaging/components.nix`'s own `mesonBuildLayer`): overriding
      # `outputs = [ "out" ];` alone still left `outputs == [ "out"
      # "debug" ]` on the actual derivation, hitting the exact same
      # ".drv only if single output" error this override exists to
      # avoid. Forcing it off here is safe -- phase 1 never produces a
      # meaningful standalone debug-info output anyway (it's not `$out`
      # in the conventional sense, see `dyndrvPlaceholderOut` above);
      # any real package that wants separate debug info still gets it
      # normally in PHASE 2 below, which inherits the caller's own
      # unmodified `separateDebugInfo` setting.
      separateDebugInfo = false;
      __contentAddressed = true;
      outputHashMode = "text";
      outputHashAlgo = "sha256";
      out = dyndrvPlaceholderOut;
      # `preCollect`/`postCollect`, NOT `preInstall`/`postInstall` --
      # confirmed by direct reproduction against real freetype: `runHook`
      # fires by HOOK NAME, not by phase, so calling `runHook
      # preInstall`/`postInstall` here also fires the WRAPPED PACKAGE'S
      # OWN `preInstall`/`postInstall` (freetype's real `postInstall`
      # runs `wrapProgram "$dev/bin/freetype-config"`), which crashes
      # here since `$out`/`$dev` are still the placeholder path in phase 1.
      # `installPhase`'s `preInstall`/`postInstall` still fire normally
      # in phase 2 below, against phase 1's real, resolved output.
      collectPhase = ''
        runHook preCollect
        ${collectScript}
        runHook postCollect
      '';
    }
  );

  # Two levels of `outputOf` -- level 1: `sandboxedDrv`'s own output IS
  # the submitted `.drv` FILE (what `shim.collectStubs`'s final `nix
  # store submit-output` call submits); level 2: resolving THAT `.drv`'s
  # own real output. Same convention, same reasoning,
  # `mkDynamicDerivation.nix`'s own `transformDrv` uses -- see that
  # file's header comment for the full "why two levels" explanation.
  sandboxedResult = self.mkOutputOf (self.mkOutputOf sandboxedDrv "out") "out";

  # A synthesized `dyndrvRestoreOutput` phase is inserted immediately
  # after EVERY `"installPhase"` entry in `replayPhases` (ordinarily just
  # the one) -- see this file's own "THE RESTORE STEP" header comment
  # above for the full rationale. It merges `dyndrvPlaceholderOut` (the
  # EXACT path `sandboxedDrv.out` is set to above -- not a placeholder to
  # look up, a known constant) into the real `$out`, via
  # `cp -r` (not a plain `mv`) specifically so any file `installPhase`
  # already wrote directly to the real `$out`/`$dev` (unaffected by this
  # bug, e.g. via a `postInstall` hook referencing `$dev` directly) is
  # left untouched rather than clobbered. A no-op (skipped entirely) for
  # any package whose `configureFlags` never bake `$out`'s value in
  # literally, so this is safe to always insert rather than something a
  # caller opts into.
  finalReplayPhases = lib.concatMap (
    p: if p == "installPhase" then [ p "dyndrvRestoreOutput" ] else [ p ]
  ) replayPhases;
in
# Phase 2: an ORDINARY derivation (no special `requiredSystemFeatures`
# at all) whose `src` is phase 1's own resolved output -- runs
# `replayPhases` completely normally, real `$out`, real multi-output
# support, since this is nixpkgs' own ordinary derivation machinery
# with nothing intercepted.
stdenv.mkDerivation (
  replay
  // {
    inherit pname version;
    src = sandboxedResult;
    phases = [ "unpackPhase" ] ++ finalReplayPhases;
    dyndrvRestoreOutput = ''
      runHook preDyndrvRestoreOutput
      if [ -d ${dyndrvPlaceholderOut} ]; then
        mkdir -p "$out"
        cp -r ${dyndrvPlaceholderOut}/. "$out"/
        chmod -R u+w "$out"
        rm -rf ${dyndrvPlaceholderOut}
        # Everything just landed under the single `$out` root, since
        # phase 1 (where these paths were baked in) only ever had ONE
        # output -- for a real multi-output package, nixpkgs' own
        # `_multioutDevs`/`_multioutDocs` (declared by
        # `multiple-outputs.sh`, unconditionally sourced by stdenv, so
        # always available as plain bash functions here regardless of
        # whether THIS package opted into multiple outputs) must run
        # NOW, before anything else, to redistribute `$out`'s content
        # across the real outputs -- confirmed necessary by direct
        # reproduction against real freetype: leaving this to the
        # ORDINARY `preFixupHooks` array (which already contains these
        # same functions) is NOT reliable, since a caller's OWN
        # `nativeBuildInputs` can register another `preFixupHooks` entry
        # (freetype's own `flatten-include-hack-hook`) that happens to
        # run first and expects `$dev/include` to already exist --
        # confirmed this exact ordering failure by direct reproduction
        # ("cd: .../include: No such file or directory"). Calling these
        # explicitly here, unconditionally, makes the split happen
        # deterministically before ANY other `preFixupHook` gets a
        # chance to run, matching what an ordinary (non-accelerated)
        # build's own install-time behavior already guaranteed for free.
        # Both are no-ops (their own top-line `getAllOutputNames`/`-z`
        # checks) when `outputs` is just `"out"`.
        _multioutDocs
        _multioutDevs
      fi
      runHook postDyndrvRestoreOutput
    '';
    unpackPhase = ''
      runHook preUnpack
      cp -r "$src"/. .
      chmod -R u+w .
      runHook postUnpack
    '';
  }
)
