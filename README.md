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

## Status

**v0.1 (in progress).** Core primitives and both backends
(`builder-rpc-v0` default, `recursive-nix` fallback) are implemented and
verified end-to-end against real Nix builds. See below for what's usable
today.

## Layout

```
nix/lib/            Core Nix-expression library (the load-bearing part —
                     works on stock Nix, no compiled tooling required)
nix/lib/builders/    Backend-specific builder-script generators
nix/tests/           dyndrv's own tests, cross-checked against Nix's oracle
tests/oracle/        Vendored reference copies of Nix core's own
                     tests/functional/dyn-drv/ test cases
try-it-out/          Get-started tooling: a patched-Nix packaging recipe,
                     a run-nix.sh wrapper, and runnable examples
```

## Quickstart

**The `builder-rpc-v0` backend is the default**, but it requires an
unreleased/patched Nix (tracking
[NixOS/nix#15793](https://github.com/NixOS/nix/pull/15793)). If you don't
have one, `dyndrv.capabilities.withFallback` lets you degrade gracefully —
see `try-it-out/examples/02-fallback-ifd.nix`, which runs on plain, stock
Nix with no experimental features at all.

If you do have a NixOS/nix#15793 checkout built locally:

```console
$ NIX_SRC=/path/to/nix-checkout/build-release ./try-it-out/run-nix.sh \
    build --impure -f try-it-out/examples/01-hello-dynamic-drv.nix
```

See `try-it-out/README.md` for the full walkthrough.

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

- `dyndrv.mkDynamicDerivation` — the mkDerivation-shaped wrapper around the
  whole outer-drv + `outputOf`-unwrap pattern found in every surveyed
  project. Returns an ordinary, immediately-usable derivation.
- `dyndrv.builders.viaNixInstantiate` / `.viaDerivationAdd` — the two
  backend-specific ways a `producer` can construct the inner derivation
  (`recursive-nix` + `nix-instantiate`, vs. `builder-rpc-v0` +
  `nix derivation add`/`nix store submit-output`).
- `dyndrv.capabilities.detect` / `.withFallback` — feature detection and a
  graceful degrade-to-IFD combinator, so adopting `dyndrv` is never an
  all-or-nothing bet on an experimental Nix feature.
- `dyndrv.mkOutputOf` / `dyndrv.wrapOutputOf` — low-level helpers that
  paper over `builtins.outputOf`'s two permanent rough edges (string-only
  argument, `DrvDeep`-context rejection) and turn a raw `outputOf` string
  into something `nix run`/`nix profile install` can consume.

## Running the tests

```console
$ nix/tests/run-tests.sh
```

Runs against the installed system Nix using the `recursive-nix` backend
(no patched Nix required). Tests are cross-checked against the oracle
behavior locked in by Nix core's own `tests/functional/dyn-drv/` suite
(vendored under `tests/oracle/`).

## Known v0.1 limitations

- Chaining two *interdependent* dynamically-produced derivations through
  `viaNixInstantiate`'s JSON-encoded `args` does not yet propagate the
  dependency edge into the inner sandbox (`builtins.toJSON` strips Nix's
  string context) — building a real dependency graph across many dynamic
  derivations is `dyndrv.graph.compile`, planned for v0.2.
- `builder-rpc-v0` support requires packaging a patched Nix yourself (see
  `try-it-out/patched-nix.nix`); there is no released Nix with this
  feature yet.
