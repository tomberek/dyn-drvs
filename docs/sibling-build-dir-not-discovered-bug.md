# FIXED: a sibling build directory (created via a `preConfigure`/`preBuild` hook, before the main `cd build`) is never scanned for stubs at all

## Status: fixed

Fixed in `nix/lib/shim/collectStubs.nix`: a new sibling-directory
detection pass runs BEFORE Phase 1 (keyed off `CMakeCache.txt`'s own
`CMAKE_HOME_DIRECTORY` differing from `dyndrv_buildRoot`, the same
signal `.dyndrv-carried-up1`'s existing carry-forward already uses),
populating `dyndrv_extraRoots` with every sibling that itself looks
like another build directory. Phase 1's own `find` walk now also scans
every entry in `dyndrv_extraRoots`, keying each discovered stub
`../<sibling-name>/<subpath>` -- the same relative-path convention
`dyndrv_join_rel` already normalizes any `../`-prefixed argv reference
to, so a later link step's own `../build-10bits/libx265.a` reference
resolves against this key with no further changes needed downstream.
Phase 8's `.dyndrv-carried-up1` carry-forward now also strips each
sibling's own real stubs from its content copy (replacing them with
the correctly-resolved final symlink instead), so the placeholder text
doesn't linger in the submitted tree.

Confirmed via a new regression fixture,
`try-it-out/examples/37-accelerate-sibling-build-dir.nix` (mirrors
x265's own `multibitdepthSupport` shape exactly), and via a real
x265 rebuild: `dyndrv-libx265_so_215.drv` -- the exact derivation
originally blocked by "cannot find -lx265-10" -- now links
successfully, with both `build-10bits`/`build-12bits` sibling trees
correctly discovered and registered as real dynamic derivations.

Real x265 (multibitdepth + unittests, no workaround) still does not
reach a full end-to-end PASS: a separate, distinct bug in `test_
TestBench`'s own link step surfaced only once this fix let the build
progress far enough to reach it (`build-10bits`/`build-12bits`'s own
`api.cpp.o` stub appears to get compiled/registered as if
`EXPORT_C_API=1` rather than the `0` `cmakeStaticLibFlags` actually
requests, producing plain `x265_api_get_215`/`x265_api_query` symbols
instead of the expected `x265_10bit::`/`x265_12bit::`-namespaced ones
-- confirmed absent in a stock, unaccelerated x265 build). That is a
new, separate investigation, not part of this fix.

## Summary (original writeup, kept as history)

Found while investigating x265's `-l<name>` link-arg gap
(`bare-lname-link-arg-bug.md`) after fixing the search-path resolution
half of that bug.

## Reproduction

```console
$ pkgs.x265.override { stdenv = dyndrv.accelerate.mkAcceleratedStdenv { stdenv = pkgs.stdenv; inherit nixPackage; }; }
```

With `bare-lname-link-arg-bug.md`'s own fix in place, `-lx265-10`/
`-lx265-12` now correctly rewrite to `../build-10bits/libx265.a`/
`../build-12bits/libx265.a` (the real relative symlink targets x265's
own `preBuild` creates). The link step then fails differently:

```
ld.bfd: cannot find ../build-10bits/libx265.a: No such file or directory
ld.bfd: cannot find ../build-12bits/libx265.a: No such file or directory
collect2: error: ld returned 1 exit status
```

Confirmed via direct log inspection that `build-10bits/libx265.a` WAS
actually built for real -- `make -C ../build-10bits` genuinely compiles
every real TU and links `libx265.a` there (`[ 86%] Linking CXX static
library libx265.a`, via a real, deferred `ar` invocation this
accelerator DID intercept and defer, exactly like every other `ar`
call).

## Root cause

x265's own nixpkgs recipe (`preConfigure`, gated on
`multibitdepthSupport`):

```nix
preConfigure = lib.optionalString multibitdepthSupport ''
  cmake -B build-10bits "''${cmakeFlags[@]}" ...
  cmake -B build-12bits "''${cmakeFlags[@]}" ... ${lib.cmakeBool "MAIN12" true}
  cmakeFlagsArray+=(...)
'';
```

This runs from `source/` (x265's own `sourceRoot`), BEFORE
`configurePhase` itself ever runs -- and nixpkgs' own
`cmakeConfigurePhase` is what does the standard `mkdir -p build; cd
build` for the MAIN configure. So by the time the main `cmake`/`make`
invocation runs (inside `build/`), `build-10bits`/`build-12bits`
already exist as SIBLINGS of `build/`, both directly under `source/`:

```
source/
  build/          <- dyndrv_buildRoot ("."), the ONLY tree collectStubs scans
  build-10bits/   <- sibling, created by preConfigure, NEVER scanned
  build-12bits/   <- sibling, created by preConfigure, NEVER scanned
```

`shim.collectStubs`'s Phase 1 (`nix/lib/shim/collectStubs.nix`, ~line
310) discovers stubs via `find "$dyndrv_buildRoot" -type f -print0`
-- `dyndrv_buildRoot` is always `"."`, the collect-time cwd, which for
a cmake+make build (via `cmakeConfigurePhase`'s own `cd build`) is
`build/`. `find` never walks upward or sideways into `../build-10bits`,
so the real `ar`-produced stub sitting there (`build-10bits/libx265.a`)
is never added to `DYNDRV_STUB_RECORD`/`dyndrv_stubPaths` at all --
`collectStubs` has no idea it exists as a stub.

There IS an existing mechanism that carries SOME sibling content
forward: `.dyndrv-carried-up1` (Phase 8, ~line 770), gated on
`dyndrv_buildRoot/CMakeCache.txt` existing (true here) -- it `cp -r`s
every sibling of `build/` (so `build-10bits/`, `build-12bits/`, and
`source/`'s other top-level entries) into
`$dyndrv_origTree/.dyndrv-carried-up1/`, specifically so phase 2's own
`installPhase` re-invocation of `cmake --check-build-system` finds
`CMakeLists.txt` and the rest of the real source tree still present at
the same relative position (this is the SAME mechanism task #138's own
fix, `0d233d3`, added). But this carry-forward is UNCONDITIONAL,
UNAWARE content copy -- it runs in Phase 8, strictly AFTER Phase 1-7
(stub discovery, dependency resolution, unit assignment, derivation
registration) have already completed and moved on. `build-10bits/
libx265.a` gets copied byte-for-byte into `.dyndrv-carried-up1/
build-10bits/libx265.a` -- still containing the literal placeholder
stub TEXT (`#!dyndrv-batch-pending\n<record path>`), never resolved
into a real dynamic-derivation symlink, because nothing in Phase 1-7
ever saw it as a stub in the first place.

This is a genuinely distinct bug from `bare-lname-link-arg-bug.md`'s
own search-path-resolution gap (now fixed): that bug was about
resolving WHAT PATH `-lx265-10` even refers to (fixed: it correctly
resolves to `../build-10bits/libx265.a` now). This bug is about that
resolved path's own TARGET never having been discovered as a stub at
all, regardless of how correctly anything upstream names it.

## Why this didn't surface before

Every other cmake+make package this survey has fixed/confirmed
(leveldb, capnproto, brotli, libssh, re2, ...) runs its ENTIRE real
build inside the one `build/` directory `cmakeConfigurePhase` creates
-- nothing in their own recipes runs `cmake -B <other-dir>` a second
time against a sibling location before the main configure. x265's own
multi-bitdepth feature is (so far) the only confirmed instance of a
package deliberately invoking a SECOND, independent cmake configure+
build cycle from a sibling directory as part of its own normal build
(not a probe, not a test -- genuine product functionality: the 10-bit/
12-bit HDR encoder variants).

## What a real fix would need

The stub-discovery/dependency-resolution machinery (Phase 1-7) needs to
run over each carried-forward sibling directory too, not just
`dyndrv_buildRoot` -- concretely:
1. Move the sibling-detection/carry-forward logic (currently Phase 8,
   gated on `CMakeCache.txt`) to run BEFORE Phase 1, so its own output
   directory (or the original sibling locations directly) can be
   included in Phase 1's own `find` walk.
2. Every `../`-relative reference this build's own argv/records name
   (already handled today via `dyndrv_join_rel`/`dyndrv_relative_
   between` for OTHER purposes -- reconciling a differing invocation
   `cwd` against `dyndrv_buildRoot`) needs to also resolve against
   wherever the carried-forward copy of that sibling actually ends up
   relative to the FINAL submitted tree (`.dyndrv-carried-up1/<path>`),
   not just `dyndrv_buildRoot` itself.
3. Confirm no regression across every existing cmake+make/meson
   fixture and real package this carry-forward mechanism already
   serves (leveldb, capnproto, brotli, libssh, re2, the meson `.dyndrv-
   build-relpath` mechanism) -- this touches code every one of them
   already depends on.

This is a genuinely more invasive change than `bare-lname-link-arg-
bug.md`'s own fix (a self-contained rewrite inside `wrapCommand.nix`'s
own per-invocation script, touching nothing else) -- it restructures
`collectStubs.nix`'s own phase ordering and widens what "the build
tree" means for stub-discovery purposes, not just for content
carry-forward.

## Where this was found

Downstream showcase repo, retesting `nix/packages/x265.nix` against
`bare-lname-link-arg-bug.md`'s own fix (`-l<name>` search-path
resolution) -- confirmed that fix resolves the SYMLINK's own target
path correctly, but the target itself (a real stub sitting in a
sibling `build-10bits/` directory) was never discovered by
`collectStubs` at all, a second, independent gap.
