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
  # The LAST phase name in this list marks where phase 1 stops -- NOT a
  # complete, static phase list to run verbatim (see `sandboxedDrv`'s own
  # `buildCommand` header comment below for why: nixpkgs' own dynamic
  # `$phases` computation, which a setup hook like `autoreconfHook`
  # extends via `appendToVar preConfigurePhases autoreconfPhase`, must
  # still run, or that hook's own injected phase is silently dropped).
  # Default matches stdenv's own standard phase ORDER up through
  # `buildPhase` (nothing here needs to be exhaustive -- only the LAST
  # entry, `buildPhase`, is actually consulted as the truncation
  # boundary; the earlier entries exist only for this attrset's own
  # documentation value).
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

  # The single phase name phase 1 stops AT (inclusive) -- see
  # `sandboxedPhases`'s own doc comment above.
  lastSandboxedPhase = lib.last sandboxedPhases;

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
      # NOT a static `phases = sandboxedPhases ++ [...]` override (what
      # this used to be) -- that sets the derivation's own `phases` env
      # var directly, which is ALREADY non-empty by the time nixpkgs'
      # own `setup.sh`'s `definePhases` runs (`if [ -z "${phases[*]:-}"
      # ]`), so its dynamic computation (which incorporates whatever a
      # setup hook `appendToVar preConfigurePhases`/`preBuildPhases`/etc.
      # into) never runs at all -- confirmed by direct reproduction
      # against real nixpkgs `mosh` (`autoreconfHook`): with the static
      # override, `configurePhase` logged "no configure script, doing
      # nothing" even though `autoreconfHook`'s own `appendToVar
      # preConfigurePhases autoreconfPhase` DID run (setup hooks run
      # unconditionally, before ANY phase), because its own injected
      # `autoreconfPhase` name was silently absent from the STATIC
      # `phases` list this override forced. `buildCommand` (below) is
      # the stdenv-recognized escape hatch that skips `genericBuild`'s
      # own default body ENTIRELY (`setup.sh`: `if [ -n
      # "${buildCommand:-}" ]; then eval "$buildCommand"; return; fi`),
      # letting us call the SAME `definePhases`/`runPhase` primitives
      # nixpkgs' own `genericBuild` uses, get the REAL dynamically-
      # computed phase list (now correctly including `autoreconfPhase`
      # or any other setup-hook-injected phase), then truncate it at the
      # `lastSandboxedPhase` boundary before appending `collectPhase` --
      # preserving every phase a real, unaccelerated build would have
      # run up to that point, dynamically injected ones included.
      buildCommand = ''
        definePhases
        dyndrvTruncatedPhases=""
        dyndrvFoundBoundary=0
        for dyndrvPhase in ''${phases[*]}; do
          dyndrvTruncatedPhases="$dyndrvTruncatedPhases $dyndrvPhase"
          if [ "$dyndrvPhase" = ${lib.escapeShellArg lastSandboxedPhase} ]; then
            dyndrvFoundBoundary=1
            break
          fi
        done
        if [ "$dyndrvFoundBoundary" != 1 ]; then
          echo "dyndrv.phases.split: sandboxedPhases' last entry '${lastSandboxedPhase}' never appears in the dynamically computed phase list ($phases) -- check sandboxedPhases against the real phase names this package's own setup hooks produce" >&2
          exit 1
        fi
        phases="$dyndrvTruncatedPhases collectPhase"
        for curPhase in ''${phases[*]}; do
          runPhase "$curPhase"
        done
      '';
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
    phases = [ "unpackPhase" "dyndrvCdToBuildDir" ] ++ finalReplayPhases;
    # `replay`'s own inherited `sourceRoot` (if the ORIGINAL package set
    # one) must be explicitly CLEARED here, not just left unset in THIS
    # attrset -- `replay // {...}` never REMOVES a key `replay` itself
    # already set, confirmed by direct reproduction: omitting this
    # override left the ORIGINAL, phase-1-only `sourceRoot` value
    # (`nix-util`'s own `"${src.name}/./src/libutil"`) still active,
    # and `runPhase`'s own hardcoded post-`unpackPhase` step (`stdenv`'s
    # `setup` script itself) unconditionally `cd`s into
    # `"${sourceRoot:-.}"` after ANY phase literally named
    # `"unpackPhase"` finishes -- kept a no-op here (`sourceRoot`
    # deliberately left unset) since `sandboxedResult`'s own tree ROOT
    # already IS phase 1's OWN resolved `buildPhase` cwd (`shim.
    # collectStubs`'s own `dyndrv_buildRoot = "."`, captured relative to
    # that exact cwd) -- no `cd` needed at all to reach it.
    sourceRoot = ".";
    # meson bakes phase 1's own PLACEHOLDER `$out` (the exact value
    # `$dyndrvPhase1Out` holds during `dyndrvCdToBuildDir`/
    # `dyndrvRestoreOutput` above -- an absolute, `.drv`-suffixed
    # string, e.g. `/nix/store/AAAA-nix-util-c-2.36.0pre.drv`, per
    # this file's own `name = "${pname}-${version}.drv"` convention)
    # directly into the TEXT of any `.pc` file it installs
    # (`prefix=...`) -- unlike the tree-content DESTDIR gap fixed in
    # `dyndrvRestoreOutput` above, this is baked into a FILE'S OWN
    # CONTENT, not its location, so no amount of moving/hoisting the
    # tree fixes it: a downstream component that later reads this
    # `.pc` file back (e.g. `nix-cli`'s own `dependency('nix-util-c-
    # whole-archive')`) gets a linker `cannot find .../nix-util-c-
    # 2.36.0pre.drv/lib/libnixutilc.a: No such file or directory` --
    # confirmed by direct reproduction against NixOS/nix's own
    # `nix-cli` component specifically (the ONLY consumer, among every
    # component built so far, of another component's own `.pc` file
    # via pkg-config -- every earlier component only ever consumed
    # ordinary compiled libraries, never pkg-config metadata).
    # Appended to `postFixup` (NOT `dyndrvRestoreOutput`, which runs
    # BEFORE `fixupPhase`'s own `_multioutDevs` split relocates `.pc`
    # files from `$out` to the real `$dev` -- confirmed necessary by
    # direct reproduction: scanning `$out` alone in `dyndrvRestoreOutput`
    # found nothing, since `lib/pkgconfig` hadn't moved to `$dev` yet)
    # -- `postFixup` fires at the very END of `fixupPhase`, after every
    # `preFixupHook` (including `_multioutDevs`) has already run, so
    # every output's own FINAL `.pc` file location is scanned.
    # `getAllOutputNames`: stdenv's own multi-output-aware helper,
    # always available regardless of whether this package opted into
    # multiple outputs. `[ -n "''${dyndrvPhase1Out:-}" ]`: a no-op for
    # any non-meson build (the var is simply never set there).
    # Rewrites to `$out` specifically (not whichever output a given
    # `.pc` file itself landed in, e.g. `$dev`) -- confirmed via
    # direct reading of a real captured `.pc` file: `libdir=${prefix}/
    # lib` derives from this SAME `prefix` variable, and the actual
    # `.a`/`.so` files it names always live under `$out/lib`
    # regardless of which output the `.pc` file's own OWN location
    # ends up at (its OTHER variable, `includedir`, already correctly
    # points at the real `$dev` on its own, set from a live env var at
    # configure time rather than baked from this SAME placeholder).
    postFixup = (replay.postFixup or "") + ''
      if [ -n "''${dyndrvPhase1Out:-}" ]; then
        for dyndrvOutputName in $(getAllOutputNames); do
          dyndrvOutputPath="''${!dyndrvOutputName}"
          for dyndrvPcFile in $(${pkgs.findutils}/bin/find "$dyndrvOutputPath" -iname "*.pc" 2>/dev/null); do
            ${pkgs.gnused}/bin/sed -i "s|$dyndrvPhase1Out|$out|g" "$dyndrvPcFile"
          done
        done
      fi
    '';
    dyndrvCdToBuildDir = ''
      runHook preDyndrvCdToBuildDir
      # `.dyndrv-build-relpath` (see `shim.collectStubs`'s own header
      # comment) is now written UNCONDITIONALLY by phase 1, for every
      # package regardless of build system -- not gated on meson's own
      # `build.ninja` marker, as this used to be (confirmed necessary by
      # direct reproduction against real nixpkgs `capnproto`, cmake+
      # make: cmake's own generated `Makefile` re-invokes `cmake
      # --check-build-system` against the ABSOLUTE source directory
      # baked into `CMakeCache.txt` during phase 1's `configurePhase`,
      # which the old meson-only gate never reconstructed at all,
      # failing at `installPhase` with `CMake Error: The source
      # directory "/build/source" does not exist` even after every real
      # compile/link had already succeeded). For the common case (phase
      # 1 never `cd`ed anywhere beyond its own build root at all --
      # every plain-Makefile/autotools package proven so far), its own
      # CONTENT is simply `"."` -- a pure no-op, skipped entirely below,
      # since there's nothing to relocate.
      #
      # For an out-of-source build (meson's own `mesonConfigurePhase`
      # setup-hook: `meson setup build && cd build`; cmake's own
      # `cmakeConfigurePhase`, same convention), its CONTENT is phase
      # 1's own absolute build-dir path, relative to `NIX_BUILD_TOP`
      # (e.g. "source/src/libutil/build") -- reconstructing this EXACT
      # SAME absolute position here (both sandboxes fix `NIX_BUILD_TOP`
      # at "/build", confirmed by direct reproduction) is required
      # because meson bakes phase 1's own absolute paths into MULTIPLE
      # generated files, not just `build.ninja` -- `meson-private/
      # install.dat` (a pickled Python object) was ALSO confirmed, by
      # direct reproduction, to record an absolute header path that a
      # synthetic staging name (a plain `.dyndrv-build/` subdirectory,
      # tried first and found insufficient) does NOT match, causing
      # meson's own installer to find a symlink where it expected a
      # real file and refuse to install it ("Tried to install
      # something that isn't a file"). Matching the REAL absolute
      # position makes every one of these baked references correct
      # "for free," with no per-file special-casing needed at all.
      if [ -f .dyndrv-build-relpath ]; then
        dyndrvRelpath=$(cat .dyndrv-build-relpath)
        rm -f .dyndrv-build-relpath
        # `dyndrvRelpath == "."` (the common case, see above) means
        # phase 1's own build root ALREADY IS `NIX_BUILD_TOP` -- nothing
        # to relocate at all. Confirmed necessary by direct reproduction:
        # without this guard, `mv .dyndrv-tmp-root "."` fails outright
        # ("'.dyndrv-tmp-root' and './.dyndrv-tmp-root' are the same
        # file") the moment the relpath is trivially `.` itself, since
        # `.dyndrv-tmp-root` (staged one level under the CURRENT
        # directory) and its own move target (`.`, that SAME current
        # directory) resolve to the identical path.
        if [ "$dyndrvRelpath" != "." ]; then
        dyndrvParentRelpath=$(dirname "$dyndrvRelpath")
        # Stage everything into a TEMP holder first, then relocate that
        # holder in one atomic `mv` -- `dyndrvRelpath` can be MULTIPLE
        # segments deep (e.g. "source/src/libutil/build"), and
        # `mkdir -p`-ing it directly beforehand would create a
        # top-level entry (e.g. "source") that a subsequent `for f in
        # *` loop would then re-match and try to move INTO its own
        # descendant -- confirmed by direct reasoning about `mkdir -p`
        # + glob ordering, avoided entirely by never creating any part
        # of the target path until every real file is already
        # sitting safely inside the temp holder.
        mkdir .dyndrv-tmp-root
        for f in * .[!.]*; do
          case "$f" in
            .dyndrv-carried-up1|.dyndrv-tmp-root|'*'|'.[!.]*') continue ;;
          esac
          [ -e "$f" ] || continue
          mv -- "$f" .dyndrv-tmp-root/
        done
        mkdir -p "$dyndrvParentRelpath"
        mv .dyndrv-tmp-root "$dyndrvRelpath"
        # `dyndrvParentRelpath` is exactly one level up from
        # `dyndrvRelpath` -- the SAME level every carried-forward
        # `../<path>` reference (see `shim.collectStubs`'s own header
        # comment on `.dyndrv-carried-up1`) needs to resolve against.
        if [ -d .dyndrv-carried-up1 ]; then
          cp -r .dyndrv-carried-up1/. "$dyndrvParentRelpath"/
          rm -rf .dyndrv-carried-up1
        fi
        # `cp` (no `-p`) stamps every one of these newly-carried files
        # with "now" -- newer than the already-built `.cc.o` symlinks
        # sitting in `$dyndrvRelpath`, which `unpackPhase`'s own mtime
        # normalization (see that phase's header comment) ran BEFORE
        # this copy ever happened. Left alone, ninja's own restat
        # check sees every one of these sources as freshly changed and
        # recompiles the WHOLE tree via phase 2's real, unaccelerated
        # compiler -- confirmed by direct reproduction: every `.cc.o`
        # got rebuilt from scratch despite being a real, already-
        # resolved output. Re-normalize here, after the copy, for the
        # same reason `unpackPhase` does it at all.
        find "$dyndrvParentRelpath" -not -type l -exec touch -d @1 {} +
        cd "$dyndrvRelpath"
        # A build tool that bakes ABSOLUTE paths into generated build
        # state during `configurePhase` (meson's own `build.ninja`,
        # confirmed by direct reproduction against NixOS/nix's own
        # `nix-util` component: `build.ninja` literally references
        # `/build/source/src/libutil`, phase 1's OWN absolute source
        # directory, which never exists in phase 2's entirely
        # separate sandbox) will otherwise try to REGENERATE that
        # state the moment `installPhase` runs `ninja install` --
        # ninja's own `build.ninja` file declares a real EDGE (rule
        # `REGENERATE_BUILD`) with `build.ninja` itself as the
        # OUTPUT and every meson.build/`.version`/etc SOURCE-tree
        # file as its own DEPENDENCY, and ninja unconditionally
        # checks whether that edge's dependencies changed on EVERY
        # invocation, regardless of any file's own mtime -- a
        # dependency that's simply MISSING (as every one of THESE
        # is, in phase 2's own tree) is always treated as "changed",
        # so a mtime `touch` alone (confirmed insufficient by direct
        # reproduction) can never suppress this. Deleting the whole
        # EDGE -- the `build build.ninja: REGENERATE_BUILD ...` line
        # itself PLUS every immediately-following indented OPTION
        # line (ninja's own multi-line syntax for a build statement's
        # `pool =`/etc -- confirmed necessary by direct reproduction:
        # deleting ONLY the first line orphaned its own `pool =
        # console` option line, which ninja then rejected outright,
        # "unexpected indent", having no preceding `build` statement
        # left to attach to) -- removes the edge entirely, so ninja
        # has no reason to ever invoke `meson --internal regenerate`
        # at all -- it just proceeds straight to the already-fully-
        # resolved `install` target, exactly what phase 2 needs
        # (every actual compile/link output was already resolved by
        # phase 1; nothing here ever needs reconfiguring).
        if [ -f build.ninja ]; then
          awk '
            /^build build\.ninja: REGENERATE_BUILD / { skip = 1; next }
            skip && /^ / { next }
            { skip = 0; print }
          ' build.ninja > build.ninja.dyndrv-tmp
          mv build.ninja.dyndrv-tmp build.ninja
        fi
        fi
      fi
      # `.dyndrv-phase1-out` (see `shim.collectStubs`'s own header
      # comment) exists IFF phase 1 found a `build.ninja` -- meson
      # bakes its own `--prefix` in at CONFIGURE time (phase 1) and
      # NEVER re-reads a fresh `$out` at install time the way
      # autotools/make does (`make install DESTDIR=...`) -- `ninja
      # install` (== `meson install --no-rebuild`) instead only ever
      # honors `$DESTDIR`, meson's own PREPEND mechanism: installed
      # content lands at `$DESTDIR/<baked-prefix>/...`, not
      # `$DESTDIR/...` directly. Exporting it here, unconditionally
      # once this file is known to be a meson build, means
      # `installPhase` (which runs immediately after this phase)
      # writes everything under phase 2's own real `$out` after all --
      # `dyndrvPhase1Out` (a plain, non-`local` variable -- every phase
      # here runs sequentially in the SAME shell process, so this
      # persists into `dyndrvRestoreOutput` below without needing a
      # file) records the exact nested subpath to hoist back out of,
      # since `$DESTDIR` PREPENDS rather than substitutes.
      if [ -f .dyndrv-phase1-out ]; then
        dyndrvPhase1Out=$(cat .dyndrv-phase1-out)
        rm -f .dyndrv-phase1-out
        export DESTDIR="$out"
      fi
      runHook postDyndrvCdToBuildDir
    '';
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
      # `dyndrvPhase1Out` (see `dyndrvCdToBuildDir` above) is only set
      # for a meson build -- `meson install`'s own `$DESTDIR` PREPENDS
      # itself onto the baked-in prefix rather than substituting for
      # it, so the real content is sitting at `$out$dyndrvPhase1Out`
      # (a literal string concatenation -- both `$out` and
      # `$dyndrvPhase1Out` are absolute paths in their own right, e.g.
      # `$out` == `/nix/store/AAAA-nix-util-2.36.0pre` and
      # `$dyndrvPhase1Out` == `/nix/store/BBBB-nix-util-2.36.0pre.drv`,
      # giving the nested `/nix/store/AAAA-.../nix/store/BBBB-...`)
      # rather than directly under `$out` itself -- hoist it up one
      # level, the same way the autotools-specific restore step above
      # does for its own differently-shaped baked path.
      if [ -n "''${dyndrvPhase1Out:-}" ] && [ -d "$out$dyndrvPhase1Out" ]; then
        dyndrvHoistTmp="$out/.dyndrv-hoist-tmp"
        mkdir -p "$dyndrvHoistTmp"
        cp -r "$out$dyndrvPhase1Out"/. "$dyndrvHoistTmp"/
        rm -rf "''${out:?}''${dyndrvPhase1Out:?}"
        cp -r "$dyndrvHoistTmp"/. "$out"/
        rm -rf "$dyndrvHoistTmp"
        chmod -R u+w "$out"
      fi
      runHook postDyndrvRestoreOutput
    '';
    unpackPhase = ''
      runHook preUnpack
      cp -r "$src"/. .
      chmod -R u+w .
      # Every REAL file just copied here gets "now" as its own mtime
      # (`cp`, no `-p`) -- but a stub's own resolved OUTPUT is a
      # symlink whose target is an immutable, already-built store
      # path, always fixed at Nix's own epoch-1 mtime convention --
      # so it's ALWAYS "older" than every freshly-copied real file
      # sitting right next to it. Any build tool that decides
      # staleness by mtime comparison (ninja's own restat check,
      # `make`'s implicit rules) sees every real input as newer than
      # an already-fully-built output and reschedules it for a
      # pointless -- or, worse, WRONG, via phase 2's real,
      # unaccelerated compiler, silently bypassing per-TU registration
      # entirely -- rebuild. Confirmed by direct reproduction against
      # nix-util's own `ninja install`: every `.cc.o`, despite being a
      # real, already-resolved symlink to a fully-built store path,
      # got recompiled from scratch, defeating the whole point of
      # per-TU acceleration. Forcing every REGULAR (non-symlink)
      # file's mtime down to that same fixed epoch makes every
      # already-built output look at least as fresh as its own real
      # inputs -- symlinked stub outputs are already that old, so
      # this has no effect on them.
      find . -not -type l -exec touch -d @1 {} +
      runHook postUnpack
    '';
  }
)
