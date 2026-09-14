# Bug: `phases.split` forces `outputs = ["out"]` but doesn't clear a stale `outputBin`/`outputMan`/`outputDev` override

## Summary

`phases.split`'s `sandboxedDrv` (`nix/lib/phases/split.nix` ~line 194)
forces phase 1 to `outputs = [ "out" ]` unconditionally, with its own
header comment (~line 73-77) explicitly noting this collapses every
`_overrideFirst outputDev "dev" "out"`-style stdenv fallback to `"out"`.
That reasoning is correct for the *fallback* case, but it misses a
distinct case: a package whose nixpkgs recipe sets `outputBin`,
`outputMan`, or `outputDev` to an *explicit literal value* (not left for
stdenv's own fallback to fill in) that names one of the now-removed
outputs. `sandboxedDrv = stdenv.mkDerivation (sandboxed // { outputs =
["out"]; ... })` overrides `outputs` but the `//` merge doesn't touch
`outputBin` at all — it passes straight through from `sandboxed`
(inherited from the real package's own attrs) into phase 1's build,
where that output no longer exists.

## Reproduction

```console
$ pkgs.libpng.override { stdenv = dyndrv.accelerate.mkAcceleratedStdenv { stdenv = pkgs.stdenv; inherit nixPackage; }; }
```

Fails immediately, before any real compile runs:

```
error: _assignFirst: could not find a non-empty variable whose name to assign to outputMan.
       The following variables were all unset or empty:
           man dev
```

Identical failure on `pkgs.libtasn1`.

nixpkgs' real recipe for both packages sets `outputBin = "dev";`
explicitly (confirmed: `pkgs.libpng.outputBin` evaluates to `"dev"`,
`pkgs.libpng.outputs` is `["out" "dev" "man"]`).

## Root cause

1. `phases.split`'s `sandboxedDrv` forces `outputs = [ "out" ]`, but the
   real package's own `outputBin = "dev"` (a literal, not a fallback)
   passes through unchanged into `sandboxed // {...}`'s merge.

2. Inside phase 1's sandbox, nixpkgs' own
   `pkgs/build-support/setup-hooks/multiple-outputs.sh` still runs its
   ordinary output-variable bookkeeping: `_overrideFirst outputBin "bin"
   "out"` sees `outputBin` is already non-empty (`"dev"`, inherited from
   step 1) and skips its own fallback-to-`"out"` logic entirely — the
   exact mechanism `phases.split`'s own header comment describes for the
   *unset* case doesn't fire here, because this variable was never unset.

3. `multiple-outputs.sh` then runs `_overrideFirst outputMan "man"
   "$outputBin"`, which expands to `_assignFirst outputMan "man" "dev"`
   — looking for a non-empty `$man` or `$dev` variable to assign
   `outputMan` from. But phase 1 only ever exports `$out` (forced to one
   output in step 1); no `$dev`, no `$man`. `_assignFirst` finds nothing
   and fails outright, before `configurePhase`/`buildPhase` even start.

## Why this didn't surface before

Every package proven so far (freetype, giflib, tinycbor's cmake variant,
zstd) happens to leave `outputBin`/`outputMan`/`outputDev` unset entirely
— they either declare a real multi-output `outputs` list with no scalar
override (zstd), or are single-output (giflib, tinycbor). Only a package
whose recipe sets one of these scalar overrides to something other than
`"out"` (as `outputBin = "dev"` does) hits this. Likely affects a
significant fraction of real multi-output nixpkgs C/C++ packages,
since `outputBin = "dev"` (small libraries whose only binary is a
dev-only helper) is a common pattern.

## Suggested fix

`sandboxedDrv`'s override should also reset any `outputBin`/`outputMan`/
`outputDev` (and any other `output<X>` scalar override) inherited from
`sandboxed` back to `"out"` (or unset them), consistent with forcing
`outputs = [ "out" ]` in the same merge — mirroring the *intent* the
existing header comment already describes, just extending it to cover
explicit literal overrides, not only stdenv's own fallback defaults.

## Where this was found

Downstream showcase repo, ultracode survey pass looking for more
dyn-drvs-compatible nixpkgs packages beyond freetype/giflib/tinycbor.
Confirmed independently on both `libpng` (1.6.58) and `libtasn1`
(4.21.0), both plain autotools + libtool with no cmake and no
autoreconfHook. `nixPackage` was pinned explicitly (not the ambient-Nix
version-mismatch pitfall documented in
`discovertree-link-step-bug.md`).
