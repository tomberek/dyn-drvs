# BASELINE

Last-known benchmark numbers for `dyndrv`'s benchmark harness (see the
plan's "Measuring the benefit, continuously" section for the full
methodology and the four metrics tracked). Updated via reviewed PR when
numbers move meaningfully — this is what makes claims here checkable
rather than a one-time README assertion.

All numbers below were measured on this machine. Dates are noted per
section since different sections were measured at different points as
the architecture evolved — `registration-overhead.sh`/
`small-lib-patch-rebuild.sh` predate the `builder-rpc-v0`/`phases.split`
migration and still reflect the `recursive-nix`-backed design active at
the time; `real-package-patch-rebuild.sh`/`real-package-version-bump.sh`
(2026-09-05) reflect the CURRENT architecture. Absolute numbers will
differ on other hardware; the *shape* of the results (large win at real
compile cost, honest loss at trivial compile cost, break-even in
between) is what should reproduce.

## registration-overhead.sh (metric 3 — the "tax")

Run: `try-it-out/benchmarks/registration-overhead.sh 50`

| Mechanism | Sequential (50 calls) | Per-call | Sharded (8-way) |
|---|---|---|---|
| `nix derivation add` (builder-rpc-v0 registration) | 3.99s | 79.8ms/call | 0.71s |
| `nix-instantiate` (recursive-nix registration) | 4.19s | 83.8ms/call | 0.79s |

Reference point (gradle-drvs, cited in the plan): ~1100 sequential `nix
derivation add` calls at 2m20s (~127ms/call), dropping to 54s at 16-way
sharding. These numbers land in a comparable per-call range, somewhat
faster — consistent with this being a smaller N and a different machine,
not a methodology difference.

## small-lib-patch-rebuild.sh (metrics 1, 2, 4)

Run: `try-it-out/benchmarks/small-lib-patch-rebuild.sh [nFiles] [loops]`

### Default (30 files, LOOPS=1500 — real compile work, past break-even)

| | Plain `stdenv.mkDerivation` | `accelerate.mkAcceleratedStdenv` |
|---|---|---|
| Cold build | 49.9s | 72.0s |
| Patched rebuild (1 file changed) | 28.96s | 9.98s |
| Derivations rebuilt (patched) | 31/31 (always all) | 1/31 |

**Speedup on patched rebuild: 2.90x.** Cold build is slower for the
accelerated path (72.0s vs. 49.9s) — this is the honest cost side of the
ledger: registering 31 separate dynamic derivations one time costs more
than one plain compile-everything invocation. The win only shows up on
the *incremental* rebuild, which is the scenario that matters in practice
(most builds after the first are incremental).

### Counter-example (50 files, LOOPS=40 — trivial compile work, before break-even)

| | Plain | Accelerated |
|---|---|---|
| Patched rebuild (1 file changed) | 3.6s | 11.4s |

**Accelerated is 3.2x SLOWER here.** When each translation unit compiles
in a few milliseconds, the ~150-250ms/derivation registration+realise
round-trip (`nix derivation add` + `nix-store --realise`, paid once per
changed file, plus the shim's own per-invocation `nix-instantiate --eval`
call) costs more than just recompiling the file directly would have. This
is not a bug — it's the real, honest shape of the tradeoff, exactly the
"break-even point" metric 4 is meant to surface. Reproduce with:
```
LOOPS=40 try-it-out/benchmarks/small-lib-patch-rebuild.sh 50 40
```

### Near break-even (30 files, LOOPS=400)

| | Plain | Accelerated |
|---|---|---|
| Patched rebuild (1 file changed) | 8.43s | 8.52s |

Speedup ≈ 0.99x — a coin flip. This is the point where per-file compile
time roughly equals the per-derivation registration tax on this machine.
**Practical guidance**: if your real package's per-translation-unit
compile time is well under ~200-300ms on your hardware,
`mkAcceleratedStdenv` is not yet worth adopting for it — check with
`registration-overhead.sh` first, then compare against your own compiler's
typical per-file time before reaching for the accelerator.

### Real limitation surfaced while building this benchmark (RESOLVED — see real-package-patch-rebuild.sh)

The v0.2 `cc` shim originally only tracked files named explicitly in argv —
it had no `#include`-search-path awareness, so a fixture with a shared
local header failed with "No such file or directory" inside the per-TU
sandbox. This benchmark's fixture generator (`gen-small-lib.sh`) works
around it by declaring every cross-file reference `extern` instead of via
a shared header — a deliberate fixture design choice, kept as-is since it
still exercises the registration-tax/break-even tradeoff cleanly without
needing real header discovery.

**The underlying gap itself is now fixed**, via a new `discoverTree` mode
on `shim.wrapCommand` (a real `cc -M -MG` dependency scan run before each
compile, staging discovered headers into a directory tree that preserves
relative structure) — see `real-package-patch-rebuild.sh` below, which
exercises this against a genuine multi-directory nixpkgs package
(freetype) with real local headers and real `-I` search paths, not just
this benchmark's own extern-only workaround.

## real-package-patch-rebuild.sh (metrics 1, 2, 4 — real nixpkgs package)

Run: `try-it-out/benchmarks/real-package-patch-rebuild.sh`

Builds real, unmodified nixpkgs `freetype` (~45 translation units,
libtool/autotools, several other libraries — zlib, bzip2, libpng, brotli
— referenced via real `-I`/`-L` flags), patches one real source file
(`src/base/ftglyph.c`), and compares plain vs. accelerated.

**Why freetype, not openssl**: openssl bakes its own outer `$out` path
into every `cc` invocation via `-DOPENSSLDIR=`/`-DENGINESDIR=`/
`-DMODULESDIR=` (confirmed by direct reproduction) — since `$out` changes
whenever ANY outer-derivation attribute changes (including applying a
one-line patch), this makes EVERY per-TU derivation's hash change too,
defeating per-TU caching structurally on any patch, for ANY package that
does this — not a dyndrv bug. `dyndrv.phases.split` (the `builder-rpc-v0`
sandboxed/replay two-phase split) generalizes past this limitation —
freetype doesn't happen to need it, but the mechanism now exists.

**These numbers were re-measured on 2026-09-05, under the CURRENT
`builder-rpc-v0`/`phases.split` architecture** (superseding the numbers
this section previously reported, which were measured under an earlier
`recursive-nix`-backed design that no longer exists in this codebase —
`mkAcceleratedStdenv` has no `recursive-nix` code path at all anymore).

| | Plain `stdenv.mkDerivation` | `accelerate.mkAcceleratedStdenv` |
|---|---|---|
| Cold build | 21.21s | 67.03s |
| Patched rebuild (1 real file changed) | 14.07s | 49.33s |
| Dynamic derivations rebuilt (patched) | n/a (1 opaque derivation) | 2 (both compiles of the patched file — libtool compiles each source twice, once static, once `-fPIC`; configure-time probes are pure passthrough, never registered as dyndrv derivations at all) |

**Speedup on patched rebuild: 0.29x — accelerated is SLOWER here,
reported honestly.** freetype's real per-file compile time is small
enough that the per-derivation registration tax dominates, and
`configure` reruns from scratch on both sides regardless of acceleration
(neither variant has an autoconf cache layer). This is the same
break-even shape `small-lib-patch-rebuild.sh`'s own LOOPS-scaled fixture
already demonstrates — freetype just happens to land on the "not yet
worth it" side of that line on this machine, which this benchmark
reports rather than hides. What DOES improve is the *number* of things
needing rebuild (2 real per-TU derivations vs. one full opaque rebuild)
— real signal that the mechanism is working correctly on a genuine
multi-directory package with real header dependencies, even though it
doesn't yet convert to a wall-clock win at this package's scale.

## real-package-version-bump.sh (metrics 1, 2, 4 — multi-file patch)

Run: `try-it-out/benchmarks/real-package-version-bump.sh`

Same real, unmodified nixpkgs `freetype` as above, but with a THREE-file
patch (`src/base/ftglyph.c`, `src/truetype/truetype.c`,
`src/base/ftinit.c`, across two different subdirectories) instead of a
single-file change — a closer proxy for what a real upstream point-
release bump's diff typically touches (a handful of scattered bugfixes,
not one isolated line).

**Why a source patch, not an actual fetch of two real releases**:
confirmed directly, this environment (and any similarly sandboxed CI
runner) has no network access for uncached fetches — `nix build` on a
`fetchurl` for a tarball not already in the local store hangs rather
than failing fast. A multi-file source patch is a faithful,
network-independent proxy for the property this benchmark actually needs
to demonstrate (per-file caching granularity scales with how many files
actually changed), without requiring egress in CI.

Measured 2026-09-05, same architecture as `real-package-patch-rebuild.sh`
above:

| | Plain `stdenv.mkDerivation` | `accelerate.mkAcceleratedStdenv` |
|---|---|---|
| Cold build | 21.66s | 66.41s |
| Version-bump rebuild (3 files changed) | 14.11s | 47.29s |
| Dynamic derivations rebuilt | n/a (1 opaque derivation) | 6 (3 changed files × 2 compiles each, exactly as predicted — libtool's static/`-fPIC` double-compile convention applies per changed file) |

**Speedup: 0.30x — same honest shape as the single-file benchmark**,
confirming the win/loss ratio doesn't change qualitatively as the number
of changed files grows from 1 to 3: metric 2 (derivations rebuilt) stays
exactly proportional to files actually changed (2 → 6, doubling then
tripling as expected), while plain's cost is flat regardless of how many
files a real version bump touches. This is the concrete evidence that
`dyndrv`'s per-file caching granularity genuinely scales with the SIZE of
a version bump's diff, not just with a synthetic single-line patch.

### A real bug found while building this: `overrideAttrs` silently dropped patches (RESOLVED)

Building both benchmarks above surfaced a genuine, previously-
undiscovered correctness bug in `mkAcceleratedStdenv` itself, not a
benchmark-script issue: `phases.split`'s returned derivation's
`overrideAttrs` was nixpkgs' own DEFAULT one (attached by phase 2's own
real `stdenv.mkDerivation` call), which only ever re-runs PHASE 2's
construction — `src` still pointed at phase 1's already-resolved, stale
output. A caller's `.overrideAttrs (old: { patches = old.patches ++
[x]; })` (the standard nixpkgs idiom for patching a package, and exactly
what both benchmarks above need to demonstrate the version-bump story at
all) silently never reached `patchPhase`, since that phase only runs in
phase 1, which had already built with the ORIGINAL args before the
override call happened. Confirmed directly: the accelerated variant
applied only freetype's own 7 real upstream patches while silently
dropping the benchmark's own extra patch, while the identical
`.overrideAttrs` call under plain `pkgs.stdenv` applied all 8 correctly.

**Fixed** by giving `mkAcceleratedStdenv`'s own `mkDerivation` function a
custom `overrideAttrs` that mirrors nixpkgs' own `makeDerivationExtensible`
self-referential pattern (see `pkgs/stdenv/generic/make-derivation.nix`)
— re-invoking the WHOLE `mkDerivation`/`phases.split` call with merged
args, rebuilding phase 1 from scratch, rather than delegating to phase
2's own default override. Verified directly: after the fix, both
benchmarks' patches correctly reach `patchPhase` (`patching file
src/base/ftglyph.c` etc. appear in the build log), and examples 05/06
rebuild to byte-identical output, confirming no regression to the
existing, unaffected call path.

### Historical: bugs found building the real-package benchmark under the earlier `recursive-nix` architecture

The section below (six bugs, `-MF` misclassification through internal
`nix`-command stderr leakage) was found and fixed while first building a
real-package benchmark under the ORIGINAL `recursive-nix`-backed
`mkAcceleratedStdenv` design, before the `builder-rpc-v0`/`phases.split`
migration. Kept as a historical record of the kind of gaps a real
package's build surface exposes that toy fixtures don't — several of the
underlying mechanisms it describes (e.g. the `discoverTree` staging path)
are still part of the current architecture, but the specific numbers and
bug descriptions below predate the current backend and should not be
read as describing today's code path 1:1.

### Six real bugs found and fixed while building this benchmark against a real package

Building this benchmark (going from a synthetic fixture to a real
nixpkgs package) surfaced bugs a toy example's narrower argv/directory
surface never exercised — each confirmed by direct reproduction against
freetype's actual build:

1. **`-MF <file>`'s value was misclassified as a source file** — the
   dependency-file path `-MF` *writes to* (an output, not an input)
   doesn't start with `-`, so it was added to `inputs.srcs`. Fixed by
   excluding `-MF`/`-MT`/`-MQ`'s next argv index from that computation
   (by index, not value, since a depfile path is textually indistinguishable
   from a real source path).
2. **Absolute paths that are relative to the build's OWN `$PWD`
   (`/build/pkg/...`), not real Nix store paths, need relativizing before
   staging** — confirmed via freetype's own `libtool --mode=compile gcc
   ... /build/freetype-2.14.3/src/base/ftglyph.c` (and the same for glued
   `-I/build/.../include` flags). Fixed by stripping the calling process's
   own `$PWD` prefix from any argv element (standalone or glued onto a
   flag) before anything else runs.
3. **Real `-I`/`-L` flags reference OTHER libraries beyond the toolchain's
   own closure** — `mkAcceleratedStdenv`'s original `inputs.srcs` only
   declared `stdenv.cc`/`coreutils`, so `-I/nix/store/...-libpng-.../include`
   pointed at a real path the sandbox never mounted. Fixed by scanning
   every argv element for embedded `/nix/store/<hash>-<name>` references
   and adding them all to `inputs.srcs`.
4. **A double `-o` flag silently discarded the real output** — when the
   original invocation already had an explicit `-o <file>`, appending a
   second `-o $out` made GCC (which accepts multiple `-o` and uses the
   LAST one) write only to `$out`, silently never producing the file the
   caller's OWN script expected at the first `-o`'s path. The compile
   still exited 0, making this a genuinely silent failure — surfaced only
   because autoconf's own subsequent `test -s conftest.o`-style check
   failed downstream, misreported by autoconf as "PIC flag doesn't work."
   Fixed by REPLACING the existing `-o` value with `$out` in place, never
   appending a second one.
5. **Implicit (no `-o` at all) output naming** — real builds (confirmed:
   libtool, and autoconf's own compiler probes) routinely omit `-o`
   entirely, relying on the compiler's documented default (source
   basename, last extension stripped, `.o` appended, written to cwd).
   `wrapCommand.nix` gained an `outputPath` alternative to `outputArg` for
   this case.
6. **Internal `nix`-command stderr noise leaks into a calling process's
   OWN captured stderr** — autoconf's PIC-detection probe runs the
   compiler as `cc ... conftest.c >&5` (redirecting stderr into
   `config.log`) and separately `2>conftest.err`, then diffs that against
   expected compiler-warning boilerplate. Since the wrapper script runs
   IN PLACE of the real compiler, its own diagnostic output ("this
   derivation will be built:", GC-root warnings, etc.) landed in
   `conftest.err` too, corrupting the diff and making autoconf report
   "PIC flag doesn't work" even though the real compile succeeded
   perfectly. Fixed by `2>/dev/null`-ing every internal `nix`/`nix-store`/
   `nix-instantiate` bookkeeping call in the wrapper script — a generic
   risk for any tool that might diff/capture a wrapped command's stderr,
   not autoconf-specific.

After all six fixes, a real, complete FreeType 2.14.3 shared library was
built end-to-end through `mkAcceleratedStdenv` and verified to run
correctly at runtime (`FT_Init_FreeType`/`FT_Library_Version` reporting
the correct version against the accelerated build's own `libfreetype.so`).

## Diff-size comparison (nixpkgs idioms)

See `generated-diff-comparison.md` — a static, no-build comparison of real
nixpkgs dependency-bump commits (gemset.nix, deps.json, crate2nix's
Cargo.nix) against the zero-line diff a `dyndrv`-based build-time resolver
would produce for the same change.
