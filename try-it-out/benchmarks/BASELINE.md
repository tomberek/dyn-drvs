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

### Real limitation surfaced while building this benchmark

The v0.2 `cc` shim (`shim.wrapCommand`'s `toNode` inside
`mkAcceleratedStdenv.nix`) only tracks files named explicitly in argv —
it has no `#include`-search-path awareness. A fixture with a shared local
header (`lib.h` included by every translation unit) fails with "No such
file or directory" inside the per-TU sandbox, because the header was never
declared as an input. This benchmark's fixture generator
(`gen-small-lib.sh`) works around it by declaring every cross-file
reference `extern` instead of via a shared header — a deliberate,
documented fixture design choice, not a benchmark artifact hiding a
problem. This is the exact "build-time discovery" gap the plan defers to
v0.3 (nix-ninja's header-discovery pattern) — any real C/C++ package with
shared local headers will hit this today, and isn't yet accelerable
by `mkAcceleratedStdenv` without that follow-on work.

## openssl-patch-rebuild.sh

Not yet run — tracked as the next benchmark to build (real package scale,
scheduled/nightly, not per-PR). No numbers to report yet.

## Diff-size comparison (nixpkgs idioms)

Not yet built (`generated-diff-comparison.md`, static, no build required) —
tracked as follow-on work per the plan's "Measuring the benefit" section.
