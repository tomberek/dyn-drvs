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

No patched Nix required for this one, but it does need `builder-rpc-v0` --
run it via `try-it-out/run-nix.sh`, which fetches a real, unpatched
NixOS/nix commit that supports it (see that script's own header comment;
no separate patched fork or meson build step needed).

## Status

Implemented and verified end-to-end against real Nix builds (not just
designed): core primitives (`mkDynamicDerivation`, `mkOutputOf`,
`wrapOutputOf`, `capabilities`, both backends), `graph.compile`,
`shim.wrapCommand`/`collectStubs`, `phases.split`, and
`accelerate.mkAcceleratedStdenv` — the main adoption lever, built on all
of the above. See `try-it-out/benchmarks/BASELINE.md` for the numbers.

## Layout

```
nix/lib/             Core Nix-expression library (the load-bearing part —
                      works on stock Nix, no compiled tooling required)
nix/lib/builders/     Backend-specific single-node builder-script generators
nix/lib/graph/        Whole-dependency-graph compiler (graph.compile) and
                      its toOutput strategies (assemble, selectSink)
nix/lib/shim/         $PATH-command interception (wrapCommand) and whole-
                      build-tree stub resolution (collectStubs)
nix/lib/phases/       The sandboxed/replay two-derivation split (split.nix)
nix/lib/accelerate/   The one-line stdenv accelerator, built on shim/+phases/
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
demo end to end (via `try-it-out/run-nix.sh`, since phase 1 needs
`builder-rpc-v0`), or `try-it-out/examples/07-accelerate-real-package.nix`
for the same change applied to real, unmodified nixpkgs `freetype`,
including a one-line source patch showing only the changed files
rebuild. See `try-it-out/benchmarks/` for the numbers on synthetic and
real-package workloads.

**Want to build a lang2nix-style tool, or a dependency-graph compiler
(gradle-drvs'/sandstone's use case)?** The `builder-rpc-v0` backend is
the default. It's on real NixOS/nix `master` (commit `55eea4554`) but
not in a stable release yet — `try-it-out/run-nix.sh` fetches and builds
a working one directly, no patched fork required. If you'd rather not
fetch that, `dyndrv.capabilities.withFallback` degrades gracefully to
IFD — see `try-it-out/examples/02-fallback-ifd.nix`, which runs on
stock Nix with no experimental features at all.

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
| `dyndrv.mkDynamicDerivation` | The `mkDerivation`-shaped wrapper around the outer-drv + `outputOf`-unwrap pattern found in every surveyed project. Returns an ordinary, immediately-usable derivation. `backend` defaults to `"builder-rpc-v0"`; pass `"auto"` for the eval-time-detected choice instead, or `"recursive-nix"` to force it. Check `passthru.backend` to confirm what was selected. |
| `dyndrv.builders.viaNixInstantiate` / `.viaDerivationAdd` | The two backend-specific ways a single `producer` can construct its inner derivation (`recursive-nix` + `nix-instantiate`, vs. `builder-rpc-v0` + `nix derivation add`/`nix store submit-output`). |
| `dyndrv.capabilities.detect` / `.withFallback` | Feature detection and a graceful degrade-to-IFD combinator, so adopting `dyndrv` is never an all-or-nothing bet on an experimental Nix feature. |
| `dyndrv.mkOutputOf` / `dyndrv.wrapOutputOf` | Low-level helpers that paper over `builtins.outputOf`'s two permanent rough edges (string-only argument, `DrvDeep`-context rejection) and turn a raw `outputOf` string into something `nix run`/`nix profile install` can consume. |
| `dyndrv.placeholder` | Pure-Nix implementation of `DownstreamPlaceholder::unknownCaOutput`, verified byte-for-byte against Nix's own computed placeholder — the exact formula gradle-drvs hand-reimplemented in bash. |
| `dyndrv.graph.compile` | Compiles a whole dependency graph (many nodes, each possibly depending on other nodes' not-yet-built outputs) into ONE outer submission — `builder-rpc-v0` backend. Optional per-node `group` field merges nodes sharing a `group` string into one registered derivation. See `try-it-out/examples/03-graph-with-groups.nix`. |
| `dyndrv.graph.assemble` / `.selectSink` | The two `toOutput` strategies `graph.compile` supports: merge every node's output into one tree, or return one named "sink" node's output directly. |
| `dyndrv.graph.groupByDirectory` | Canned `group`-assignment helper: sets each node's `group` to its own path's directory. See `try-it-out/examples/03-graph-groupby-directory.nix`. |
| `dyndrv.shim.wrapCommand` | Intercepts a toolchain command on `$PATH` so every invocation defers — writes a batch-pending stub instead of running, returning instantly (`builder-rpc-v0` cannot realize a derivation from inside a running script). What `accelerate.mkAcceleratedStdenv` is built from. |
| `dyndrv.shim.collectStubs` | Runs once at the end of a build: walks the tree of deferred stubs, reconstructs the dependency graph, registers one derivation per unit, and submits a fully-resolved tree. |
| `dyndrv.phases.split` | The "sandboxed, then replay" two-derivation primitive: phase 1 runs the real build (gated on `builder-rpc-v0`) ending in a `collectStubs` pass; phase 2 is an ordinary derivation running `installPhase`/`fixupPhase` against phase 1's resolved tree, with no special capability needed (real multi-output support works here). What `accelerate.mkAcceleratedStdenv` is built on. |
| `dyndrv.accelerate.mkAcceleratedStdenv` | The lowest-friction entry point: `myPkg.override { stdenv = dyndrv.accelerate.mkAcceleratedStdenv { stdenv = pkgs.stdenv; }; }`. Ordinary `cc`/`ar` invocations become independent, per-translation-unit cacheable derivations. `granularity`: `"file"` (default), `"module"` (directory-batched compiles via a `shouldBatch` predicate — see example 06), or `"package"` (no-op). `overrideAttrs` correctly re-runs the whole two-phase build, so patches/`configureFlags` overrides work like an ordinary package. See example 07 for a real nixpkgs package. |

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
$ ./try-it-out/benchmarks/real-package-patch-rebuild.sh      # same metrics against real, unmodified nixpkgs freetype, one file patched
$ ./try-it-out/benchmarks/real-package-version-bump.sh       # same, but a 3-file patch across 2 subdirectories -- shaped like a real version bump's diff
```

See `try-it-out/benchmarks/BASELINE.md` for the last-known numbers, kept
up to date via reviewed PR rather than left to go stale in a README.
Proving the value proposition, not just asserting it, is a first-class
goal of this project — see the numbers, run them yourself, and see where
the tradeoff does *not* favor `dyndrv` too (it's documented, not hidden).

## Known limitations

- **`accelerate.mkAcceleratedStdenv`'s `granularity = "module"`** has one
  unguarded gap: two different batched members staging different
  content at the same relative path silently keep whichever ran last,
  with no detection or error.
- **Packages that bake their own not-yet-known `$out` path into every
  compile flag** (openssl's `-DOPENSSLDIR=` etc.) may now work correctly
  under the current `phases.split`-based design (`$out` inside phase 1
  is a per-unit placeholder, not the final package's real path) — not
  yet directly verified against a real build.
- **`graph.compile` only implements the `builder-rpc-v0` backend** — a
  `recursive-nix` codegen path is unbuilt.
- **`builder-rpc-v0` needs a Nix build recent enough to have it** — no
  stable release includes it yet, so most installed Nix binaries don't
  have it out of the box; `try-it-out/patched-nix.nix` fetches one
  directly, or use `capabilities.withFallback` to degrade to IFD.

See `docs/upstream-tracking.md` for which of these trace back to a
specific NixOS/nix issue, rather than being a `dyndrv`-side gap.
