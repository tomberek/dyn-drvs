# BASELINE

Last-known benchmark numbers for `dyndrv`'s benchmark harness (see the
plan's "Measuring the benefit, continuously" section for the full
methodology and the four metrics tracked). Updated via reviewed PR when
numbers move meaningfully — this is what makes claims here checkable
rather than a one-time README assertion.

All numbers below were measured on this machine (2026-08-31): `nix
(Determinate Nix 3.20.0) 2.34.6`, `recursive-nix` backend (no patched Nix
required for anything in this file — `builder-rpc-v0` is not exercised by
the accelerator, see `mkAcceleratedStdenv.nix`'s header). Absolute numbers
will differ on other hardware; the *shape* of the results (large win at
real compile cost, honest loss at trivial compile cost, break-even
in between) is what should reproduce.

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
does this — not a dyndrv bug. nixgg's own real fix for this (confirmed by
reading its source directly) requires the `builder-rpc-v0` backend plus a
`out = "/nonexistent"` sentinel during a sandboxed build phase, then a
SEPARATE ordinary-derivation phase that restores real paths and
`patchelf`-fixes RPATHs — genuinely v0.3 scope (`phases.split`), not a
v0.2 fix. freetype doesn't bake `$out` into its compile flags, so it
demonstrates the same real-package-scale value within v0.2's current
scope, honestly, without requiring that larger architecture.

| | Plain `stdenv.mkDerivation` | `accelerate.mkAcceleratedStdenv` |
|---|---|---|
| Cold build | 41.22s | 82.70s |
| Patched rebuild (1 real file changed) | 16.69s | 26.64s |
| Dynamic derivations rebuilt (patched) | n/a (1 opaque derivation) | 4 (2 configure-time probes + 2 real compiles of the patched file — libtool compiles each source twice, once static, once `-fPIC`) |

**Speedup on patched rebuild: 0.63x — accelerated is SLOWER here, reported
honestly.** freetype's real per-file compile time is small enough that
the per-derivation registration tax dominates, and `configure` reruns
from scratch on both sides regardless of acceleration (neither variant
has an autoconf cache layer). This is the same break-even shape
`small-lib-patch-rebuild.sh`'s own LOOPS-scaled fixture already
demonstrates — freetype just happens to land on the "not yet worth it"
side of that line on this machine, which this benchmark reports rather
than hides. What DOES improve is the *number* of things needing rebuild
(4 real per-TU derivations vs. one full opaque rebuild) — real signal
that the mechanism is working correctly on a genuine multi-directory
package with real header dependencies, even though it doesn't yet convert
to a wall-clock win at this package's scale.

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

Not yet built (`generated-diff-comparison.md`, static, no build required) —
tracked as follow-on work per the plan's "Measuring the benefit" section.
