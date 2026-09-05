# dyndrv

A shared library and tooling for Nix's **dynamic derivations** feature —
making it easier to build fine-grained, per-unit incremental caching (per
Maven artifact, per C/C++ translation unit, per Haskell module, per Go
package, per Rust compilation unit, ...) without paying import-from-derivation's
eval-time blocking cost.

## Why

Nix's dynamic-derivations feature (`builtins.outputOf`, the `.drv^output`
installable syntax, plus the newer `builder-rpc-v0`/`nix store submit-output`
mechanism) lets a derivation's output *be* another derivation, resolved at
build time instead of eval time. This is a real, recurring need — but every
project that has used it so far (drowse, gradle-drvs, nixgg, sandstone,
nix-ninja, dgd) has independently reinvented the same handful of primitives
and hit the same handful of undocumented rough edges. One project
(nix-cargo-unit) evaluated the feature for almost exactly this purpose and
declined to use it, citing immaturity.

`dyndrv` collapses those independent reinventions into one shared, tested
library, so the next project starts from "call a tested function" instead
of "reread `DownstreamPlaceholder.cc` and hope."

## The fastest way to see the value: one command, one real number

```console
$ ./try-it-out/benchmarks/small-lib-patch-rebuild.sh
```

Builds a synthetic 30-file C "library" twice — once with plain
`stdenv.mkDerivation`, once with `dyndrv.accelerate.mkAcceleratedStdenv` —
then patches one file and rebuilds both. On the machine this was last
measured on (see `try-it-out/benchmarks/BASELINE.md` for full numbers and
methodology):

| | Plain `stdenv.mkDerivation` | `accelerate.mkAcceleratedStdenv` |
|---|---|---|
| Patched rebuild (1 of 30 files changed) | 28.96s (rebuilds everything) | 9.98s (rebuilds 1 derivation) |

**~2.9x faster**, with only 1/31 derivations actually rebuilt, and *zero
lines changed in the package's own build recipe* beyond swapping in the
accelerated `stdenv`. `BASELINE.md` also records the honest counter-case
where this is **not** worth it (trivial per-file compile cost, where
per-derivation registration overhead dominates) — the whole point of this
benchmark shipping in the repo is that you can run it yourself and see
both sides, not just take a README's word for it.

No patched Nix required for this one — `mkAcceleratedStdenv` only needs
`recursive-nix`, which works on stock, released Nix (Determinate Nix
2.34.6/mainline 2.24+).

## Status

**v0.1 + v0.2, both implemented and verified end-to-end** against real
Nix builds (not just designed). See `try-it-out/benchmarks/BASELINE.md`
and the plan doc referenced in git history for full findings.

- **v0.1**: core primitives (`mkDynamicDerivation`, `mkOutputOf`,
  `wrapOutputOf`, `capabilities`) and both
  backends (`builder-rpc-v0` default via `viaDerivationAdd`,
  `recursive-nix` fallback via `viaNixInstantiate`).
- **v0.2**: `graph.compile` (whole dependency-graph compilation into one
  outer submission, `builder-rpc-v0` backend), `shim.wrapCommand`
  ($PATH-command interception, `recursive-nix` backend), and
  `accelerate.mkAcceleratedStdenv` (the one-line accelerator built on
  both — the main adoption lever), plus the `registration-overhead.sh`
  and `small-lib-patch-rebuild.sh` benchmarks.

## Layout

```
nix/lib/             Core Nix-expression library (the load-bearing part —
                      works on stock Nix, no compiled tooling required)
nix/lib/builders/     Backend-specific single-node builder-script generators
nix/lib/graph/        Whole-dependency-graph compiler (graph.compile) and
                      its toOutput strategies (assemble, selectSink)
nix/lib/shim/         $PATH-command interception primitive (wrapCommand)
nix/lib/accelerate/   The one-line stdenv accelerator, built on shim/
nix/tests/            dyndrv's own tests, cross-checked against Nix's oracle
tests/oracle/         Vendored reference copies of Nix core's own
                      tests/functional/dyn-drv/ test cases
try-it-out/           Get-started tooling: a NixOS/nix packaging recipe,
                      a run-nix.sh wrapper, runnable examples, and benchmarks
try-it-out/benchmarks/  Reproducible numbers, not just README claims —
                        see BASELINE.md
```

## Quickstart

**Want to accelerate an existing C/C++ package?** No special Nix build
needed, one attribute changed — override the `stdenv` a package is built
with:

```nix
myPackage.override {
  stdenv = dyndrv.accelerate.mkAcceleratedStdenv { stdenv = pkgs.stdenv; };
}
```

Run `try-it-out/examples/05-accelerate-stdenv.nix` for a minimal, runnable
demo end to end, `try-it-out/examples/04-wrap-command.nix` for the
underlying `shim.wrapCommand` mechanism it's built from, or
`try-it-out/benchmarks/small-lib-patch-rebuild.sh`/
`real-package-patch-rebuild.sh` for the accelerator applied to real
multi-file builds (synthetic and real-nixpkgs, respectively).

**Want to build a lang2nix-style tool, or a dependency-graph compiler
(gradle-drvs'/sandstone's use case)?** The **`builder-rpc-v0` backend is
the default**. It's on real NixOS/nix `master` (commit `55eea4554`,
"Implement new builder-rpc-v0 derivation feature") — not in a stable
release yet, so most installed Nix binaries (Determinate, nixos-unstable's
pinned Nix, etc.) still don't have it, but `try-it-out/run-nix.sh` fetches
and builds a working one directly (see `try-it-out/patched-nix.nix`), no
patched fork or local checkout required. If you'd rather not fetch that,
`dyndrv.capabilities.withFallback` lets you degrade gracefully — see
`try-it-out/examples/02-fallback-ifd.nix`, which runs on plain, stock Nix
with no experimental features at all.

```console
$ ./try-it-out/run-nix.sh build --impure -f try-it-out/examples/01-hello-dynamic-drv.nix
```

See `try-it-out/README.md` for the full walkthrough, and
`try-it-out/examples/03-graph-of-two.nix` for a genuinely dependent
two-node graph built via `dyndrv.graph.compile`.

## Core API

```nix
dyndrv = import ./nix { inherit pkgs lib; };

dyndrv.mkDynamicDerivation {
  pname = "my-tool";
  version = "1.0";
  producer = dyndrv.builders.viaNixInstantiate {
    expr = "derivation { ... }"; # evaluated at BUILD time, not eval time
  };
}
```

| Function | What it's for |
|---|---|
| `dyndrv.mkDynamicDerivation` | The `mkDerivation`-shaped wrapper around the whole outer-drv + `outputOf`-unwrap pattern found in every surveyed project. Returns an ordinary, immediately-usable derivation. Leaving `backend` unset now defaults to `"builder-rpc-v0"` directly (a policy choice — not detected, since that's structurally impossible at eval time, see `docs/upstream-tracking.md`) — needs a Nix build recent enough to support it (see `try-it-out/patched-nix.nix`; no patched fork required, on real NixOS/nix `master` since commit `55eea4554`). Pass `backend = "auto"` for the conservative, eval-time-detected choice instead (today: always `"recursive-nix"`), or `backend = "recursive-nix"` to force it directly; check `passthru.backend` to confirm what was actually selected. |
| `dyndrv.builders.viaNixInstantiate` / `.viaDerivationAdd` | The two backend-specific ways a single `producer` can construct its inner derivation (`recursive-nix` + `nix-instantiate`, vs. `builder-rpc-v0` + `nix derivation add`/`nix store submit-output`). |
| `dyndrv.capabilities.detect` / `.withFallback` | Feature detection and a graceful degrade-to-IFD combinator, so adopting `dyndrv` is never an all-or-nothing bet on an experimental Nix feature. |
| `dyndrv.mkOutputOf` / `dyndrv.wrapOutputOf` | Low-level helpers that paper over `builtins.outputOf`'s two permanent rough edges (string-only argument, `DrvDeep`-context rejection) and turn a raw `outputOf` string into something `nix run`/`nix profile install` can consume. |
| `dyndrv.placeholder` | Pure-Nix implementation of `DownstreamPlaceholder::unknownCaOutput`, verified byte-for-byte against Nix's own computed placeholder — the exact formula gradle-drvs hand-reimplemented in bash. |
| `dyndrv.graph.compile` | Compiles a whole dependency graph (many nodes, each possibly depending on other nodes' not-yet-built outputs) into ONE outer submission — `builder-rpc-v0` backend. Optional per-node `group` field merges every node sharing the same `group` string into ONE registered derivation (one `nix derivation add` call, one distinctly-named output per member) instead of one call per node — the one mechanism this library provides for consolidating a fine-grained graph into coarser sub-components; nodes that never set `group` are byte-for-byte unaffected. See `try-it-out/examples/03-graph-with-groups.nix`. |
| `dyndrv.graph.assemble` / `.selectSink` | The two `toOutput` strategies `graph.compile` supports: merge every node's output into one tree, or return one named "sink" node's output directly. |
| `dyndrv.graph.groupByDirectory` | Canned `group`-assignment helper: given a flat node set and a function extracting each node's own path, sets `group` to that path's directory — sugar over `graph.compile`'s `group` field, not a second grouping mechanism. See `try-it-out/examples/03-graph-groupby-directory.nix`. |
| `dyndrv.shim.wrapCommand` | Intercepts a toolchain command on `$PATH` so each invocation either registers itself as its own dynamically-produced, immediately-realized derivation (`materialize`, the default), or defers to a batch-pending stub resolved later by `shim.wrapArchiver` (`defer`) — decided per-invocation by the caller-supplied `toNode`'s own return shape, so one shim instance can mix both. `recursive-nix` backend. What `accelerate.mkAcceleratedStdenv` is built from. |
| `dyndrv.shim.wrapArchiver` | The `ar`-collection companion to `wrapCommand`'s `defer` mode: combines every same-batch-group deferred stub into ONE registered, realized derivation (compile + archive together) instead of one call per member; falls back to resolving mixed/foreign inputs individually so nothing is left dangling. Ported from nixgg's own proven `batch`/`batchpending`/`batcharchive` design. |
| `dyndrv.accelerate.mkAcceleratedStdenv` | The lowest-friction entry point in the library: `{ stdenv }: stdenv`, for overriding an existing package's `stdenv` (`myPkg.override { stdenv = dyndrv.accelerate.mkAcceleratedStdenv { stdenv = pkgs.stdenv; }; }`). Ordinary `cc -c` compiles become independent, per-translation-unit cacheable derivations. `granularity = "file"` (default), `"module"` (opt-in `ar`-batched compiles per directory via a required `shouldBatch : relativePath -> bool` predicate — see `try-it-out/examples/06-accelerate-stdenv-module.nix`), or `"package"` (no-op escape hatch). |

### The producer contract

`producer` is a plain, duck-typed shape — `{ script :: backend -> string;
extraDrvArgs :: attrset; }` — not a special type. `dyndrv.builders.
viaNixInstantiate`/`.viaDerivationAdd` are the two single-node
constructors; `dyndrv.graph.compile` satisfies the exact same shape while
internally orchestrating a whole graph of nodes, so it's just as valid a
`producer` argument despite living under a different top-level name.
Writing your own is only ever a matter of matching this shape — see
`nix/lib/mkDynamicDerivation.nix`'s header comment for the full contract
and the naming constraint every producer's inner derivation must satisfy.

### Escape hatches

Every derivation `dyndrv.mkDynamicDerivation` produces exposes the same
three `passthru` attributes, regardless of which backend/producer built
it — "I need the raw thing underneath" is always the same names, not a
per-function bespoke API:

- `passthru.dynamicDrv` — the outer, `.drv`-producing derivation itself.
- `passthru.outputOf` — the raw `builtins.outputOf` string.
- `passthru.backend` — which backend was actually selected
  (`"builder-rpc-v0"` or `"recursive-nix"`), so a caller can assert on it
  in tests without re-running `capabilities.detect`.

`dyndrv.wrapOutputOf`'s result exposes `passthru.outputOf` only (there is
no outer wrapper derivation in that lower-level case).

## Running the tests

```console
$ nix/tests/run-tests.sh
```

Runs against the installed system Nix using the `recursive-nix` backend
(no patched Nix required). Tests are cross-checked against the oracle
behavior locked in by Nix core's own `tests/functional/dyn-drv/` suite
(vendored under `tests/oracle/`).

## Benchmarks

```console
$ ./try-it-out/benchmarks/registration-overhead.sh          # metric 3: the per-call "tax"
$ ./try-it-out/benchmarks/small-lib-patch-rebuild.sh         # metrics 1/2/4: synthetic fixture, real win (and honest loss case)
$ ./try-it-out/benchmarks/real-package-patch-rebuild.sh      # same metrics against real, unmodified nixpkgs freetype
```

See `try-it-out/benchmarks/BASELINE.md` for the last-known numbers, kept
up to date via reviewed PR rather than left to go stale in a README.
Proving the value proposition, not just asserting it, is a first-class
goal of this project — see the numbers, run them yourself, and see where
the tradeoff does *not* favor `dyndrv` too (it's documented, not hidden).

## Known limitations

- **`accelerate.mkAcceleratedStdenv`'s `granularity = "module"` batches
  `ar`-collected object files, but not the linker** — `granularity =
  "module"` (2026-09-04) shims `ar` in addition to `cc`, batching every
  opted-in (`shouldBatch`) source's compile into one combined derivation
  per archive; the final link step still passes through unaccelerated
  (comparatively cheap, rarely dominates a real rebuild). A batched
  member's staged tree merging (see `mkAcceleratedStdenv.nix`'s header
  comment) has one documented, unguarded gap: two DIFFERENT batched
  members staging DIFFERENT content at the SAME relative path silently
  keep whichever ran last, with no detection or error.
- **Packages that bake their own not-yet-known `$out` path into every
  compile flag (openssl's `-DOPENSSLDIR=`/`-DENGINESDIR=`/`-DMODULESDIR=`
  being the confirmed example) cannot demonstrate per-TU caching on a
  patch** — since `$out` changes whenever the outer derivation's own
  attributes change, EVERY per-TU derivation's hash changes too, for a
  reason that has nothing to do with which file was actually edited. This
  is a structural property of those packages' own build systems, not a
  dyndrv bug — nixgg's own real fix needs `builder-rpc-v0` + an
  `out = "/nonexistent"` sandboxed phase + a separate restore/patchelf
  phase (`phases.split`), genuinely v0.3 scope. See
  `try-it-out/benchmarks/BASELINE.md` for the full finding and why
  `real-package-patch-rebuild.sh` uses freetype instead.
- **`graph.compile` only implements the `builder-rpc-v0` backend** —
  `recursive-nix` multi-node graphs need their own single-composed-Nix-
  expression codegen (confirmed to work in principle; not yet built).
- **`builder-rpc-v0` support needs a Nix build recent enough to have it**
  (see `try-it-out/patched-nix.nix`, which fetches+builds one directly —
  no patched fork, no source patching); there is no STABLE RELEASE with
  this feature yet, so most installed Nix binaries (Determinate,
  nixos-unstable's pinned Nix, etc.) don't have it out of the box. Nothing
  that needs it (`graph.compile`, `mkDynamicDerivation`'s default backend)
  works without one — `capabilities.withFallback` is the escape hatch.

See `docs/upstream-tracking.md` for which of these trace back to a
specific open (or recently-closed) NixOS/nix issue, rather than being a
`dyndrv`-side gap.
