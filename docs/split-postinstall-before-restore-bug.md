# Bug: `phases.split`'s synthesized `dyndrvRestoreOutput` phase runs too late for packages whose `postInstall` touches `$out` itself (e.g. `wrapProgram`)

## Status: fixed

Fixed in `1347c8c` ("Fix phases.split: dyndrvRestoreOutput ran too late
for postInstall reading $out (task #140)") -- `dyndrvCopyPlaceholderScript`
(the placeholder-copy half of the restore logic) is now prepended
directly to `replay.postInstall`, so it runs before ANY caller-supplied
`postInstall` gets a chance to read/write `$out`; the multi-output split
half (`dyndrvMultioutSplitScript`) stays in the later
`dyndrvRestoreOutput` phase, unaffected by this fix (confirmed necessary
by direct reproduction against leveldb -- splitting too early moved
content out of `$out` before ITS OWN `postInstall` could see it there).
Confirmed directly: `dyndrv-mosh` now builds clean end to end,
`wrapProgram $out/bin/mosh` succeeds.

## Summary (original writeup, kept as history)

Found retesting `nix/packages/mosh.nix` after bumping `dyndrv` to
8aa6b86 (which fixed the autoreconfHook phase-dropping bug that
previously blocked mosh entirely -- `configurePhase`/`buildPhase` now
run for real). The build gets all the way through `make install`
(mosh-client/mosh-server link and install successfully) and then dies
at the very last step:

```console
$ DYNDRV_STORE=/tmp/scratch ./try-it-out/run-nix.sh build --impure --no-link --print-out-paths -Lv .#dyndrv-mosh
...
mosh> Making install in scripts
mosh>  /nix/store/.../coreutils-9.11/bin/mkdir -p '/build/dyndrv-placeholder-out/bin'
mosh>  /nix/store/.../coreutils-9.11/bin/install -c mosh '/build/dyndrv-placeholder-out/bin'
...
mosh> Making install in src
mosh> Making install in frontend
mosh>  /nix/store/.../coreutils-9.11/bin/mkdir -p '/build/dyndrv-placeholder-out/bin'
mosh>   /nix/store/.../coreutils-9.11/bin/install -c mosh-client mosh-server '/build/dyndrv-placeholder-out/bin'
...
mosh> make[1]: Leaving directory '/build'
mosh> 
mosh> Builder called die: Cannot wrap '/nix/store/b3zw8piyr357s2l8zadp97vlwhdi7nbx-mosh-1.4.0/bin/mosh' because it does not exist
mosh> Backtrace:
mosh> 7 assertExecutable .../make-shell-wrapper-hook/nix-support/setup-hook
mosh> 229 wrapProgramShell .../make-shell-wrapper-hook/nix-support/setup-hook
mosh> 224 wrapProgram .../make-shell-wrapper-hook/nix-support/setup-hook
mosh> 264 _callImplicitHook /nix/store/.../stdenv-linux/setup
mosh> 1610 installPhase /nix/store/.../stdenv-linux/setup
mosh> 1770 runPhase /nix/store/.../stdenv-linux/setup
error: Cannot build '/nix/store/3cnsaisjd0rvzzb4983p1m46hw1vxys0-mosh-1.4.0.drv'.
```

Both real binaries (`mosh-client`, `mosh-server`) linked and installed
correctly -- confirmed present in the log right before the failure
(`install -c mosh-client mosh-server '/build/dyndrv-placeholder-out/bin'`).
`bin/mosh` itself is not a compiled binary at all in nixpkgs' own
`pkgs/by-name/mo/mosh/package.nix` -- it's `scripts/mosh.pl`, installed
by the `Making install in scripts` `make install` step
(`install -c mosh '/build/dyndrv-placeholder-out/bin'`, confirmed
present in the log too). So by the time `postInstall` runs, `bin/mosh`
genuinely has been installed -- just under the wrong (placeholder) root.

## Root cause

`nix/lib/phases/split.nix`'s phase-2 replay list
(`finalReplayPhases`) inserts the synthesized `dyndrvRestoreOutput`
phase (the step that `cp -r`s `/build/dyndrv-placeholder-out/.` into
the real `$out`, fixing exactly the "configure baked in the wrong
prefix" problem this file's own header comment describes) as a
SEPARATE phase immediately AFTER `"installPhase"` in the phase list:

```nix
finalReplayPhases = lib.concatMap (
  p: if p == "installPhase" then [ p "dyndrvRestoreOutput" ] else [ p ]
) replayPhases;
```

But nixpkgs' own `installPhase` (`stdenv-linux/setup`, ~line 1582-1610)
calls `runHook postInstall` as its OWN LAST STATEMENT, still fully
inside `installPhase` itself -- `postInstall` is a *hook*, not a
separate phase, and fires before `installPhase` returns, i.e. strictly
BEFORE the next phase in the list (`dyndrvRestoreOutput`) ever runs.

mosh's own recipe sets:

```nix
postInstall = if withClient then ''
  wrapProgram $out/bin/mosh --prefix PERL5LIB : $PERL5LIB
'' else ...;
```

`$out` here is phase 2's REAL resolved store path (not the placeholder
-- phase 2 is an ordinary derivation with a real `$out` throughout).
But the actual file `bin/mosh` was written under
`/build/dyndrv-placeholder-out/bin/mosh` by `make install`'s generated
recipe (which baked in `--prefix=${dyndrvPlaceholderOut}` at phase-1
configure time -- the exact mechanism `dyndrvRestoreOutput`'s own
header comment already describes for `.pc` files and directory layout).
Since `dyndrvRestoreOutput` hasn't run yet (it's the phase AFTER
`installPhase`, and `postInstall` fires INSIDE `installPhase`),
`$out/bin/mosh` does not exist yet when `wrapProgram` looks for it --
hence "Cannot wrap ... because it does not exist".

This is distinct from every other split.nix-related finding so far
(`split-outputbin-override-bug.md` is about a *pre*-phase-1 `outputs`
override, not a phase-ordering gap; `discovertree-*` bugs are all about
the sandboxed phase-1 shim, not phase 2's replay). It's also not the
`autoreconfHook` phase-dropping bug the 8aa6b86 bump fixed --
`configurePhase` and `buildPhase` both ran correctly here, confirming
that fix works. This is a new gap in the *phase-2 replay* phase
ordering: any package whose `postInstall` (or any other hook that fires
during `installPhase` itself, before `dyndrvRestoreOutput`) reads or
writes `$out` directly -- rather than leaving everything for
`fixupPhase`'s own `preFixupHooks` machinery, which DOES run after
`dyndrvRestoreOutput` -- will find `$out` still missing whatever
`make install` wrote under the placeholder root.

## Why this didn't surface before

freetype (the first proven package) has no `postInstall` that touches
`$out` directly in a way exercised by this restore gap -- its own
`postInstall` (`wrapProgram "$dev/bin/freetype-config"`) is explicitly
called out in `split.nix`'s own header comment as a reason
`preCollect`/`postCollect` (not `preInstall`/`postInstall`) is used for
phase 1's own hook names, but that comment is about phase 1, not this
phase-2 ordering gap -- freetype's `postInstall` still runs at the same
point in phase 2 as mosh's does. It happens to not crash for freetype
only because `freetype-config` is a plain compiled binary that
`fixupPhase`'s own machinery doesn't relocate the same way, and
(unverified here) may already exist under the placeholder-restored
`$dev` by coincidence of ordering, or the check that trips for mosh
(`assertExecutable` in `makeWrapperHook`) doesn't fire the same way for
freetype's own wrap target. giflib/tinycbor/zstd (the other proven/
attempted packages) don't set a `postInstall` that references `$out`/
`$bin` at all. mosh is the first package surveyed whose own
`postInstall` both (a) references `$out` directly and (b) wraps a
target (`bin/mosh`, a generated Perl script, not a compiled binary)
that only ever existed under the phase-1 baked placeholder path -- the
combination that exposes this ordering gap.

## Suggested fix

Either move `dyndrvRestoreOutput` to run as part of `installPhase`
itself (e.g. via a `postInstall`-hook-ordering trick that guarantees it
runs before any CALLER-supplied `postInstall`), or -- more robustly --
insert it as a `preInstall`-time no-op guard plus a genuine hook
registered early in `preFixupHooks`/`postInstall` ordering so it always
runs before any user-supplied `postInstall` gets a chance to read
`$out`. The safest fix is likely restructuring so `dyndrvRestoreOutput`
IS `installPhase`'s own `postInstall` hook (prepended, so it runs
before any package-specific `postInstall`), rather than a phase
inserted after `installPhase` returns.

## Where this was found

Downstream showcase repo, `nix/packages/mosh.nix`, retesting after
bumping the `dyndrv` flake input to 8aa6b86 (which fixed the
`discoverTree` cwd-frame mismatch, CMake compiler-flag-probe
passthrough, autoreconfHook phase-dropping, and
`finalAttrs.finalPackage` bugs that previously blocked mosh/zstd/
openssl). `configurePhase`/`buildPhase` both running correctly here is
itself confirmation the autoreconfHook phase-dropping fix landed; this
is a new, different bug uncovered only once the build got far enough to
reach `installPhase`/`postInstall`.
