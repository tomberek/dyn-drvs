#!/usr/bin/env bash
# devshell-parity-test.sh: permanent regression fixture verifying the
# property `docs/rust-status.md`'s "Cross-mode substitution, confirmed
# not just designed" section established SYNTHETICALLY
# (`cross_mode_check.rs`, a one-off Record diff, never checked against a
# real project -- now `render::cross_mode_tests`, a permanent `#[test]`
# suite) against a REAL checked-in C++ project (`example/`):
# running `make` through `nix/lib/shim/devShell.nix`'s own Rpc-mode
# wrappers (no sandbox at all) registers the SAME per-translation-unit
# derivations as a sandboxed `nix build` of the equivalent
# `dyndrv.accelerate.mkAcceleratedStdenv`-wrapped package
# (`try-it-out/examples/08-accelerate-example-dir.nix`).
#
# Confirms two things:
#   1. `main.o.drv`/`util.o.drv` -- the REAL translation units -- are
#      BYTE-FOR-BYTE IDENTICAL derivations between the two paths (same
#      registered store path), not just "both builds happen to
#      succeed." This is the concrete, mechanical reason Nix
#      substitutes rather than rebuilds when the same TU is later
#      registered again inside a real sandboxed build.
#   2. The final `hello` binary produced by EACH path runs and produces
#      IDENTICAL, correct output -- functional equivalence on top of
#      the derivation-identity check. (The LINK step's own `.drv`
#      differs in its exact ATerm representation between the two paths
#      -- `Rpc` mode wires real `Built` `inputDrvs` edges to `main.o.
#      drv`/`util.o.drv`, while `Sandbox` mode's own per-unit render
#      resolves cross-references to literal `Opaque` store-path text
#      instead -- but Nix's own CA-derivation resolution mechanism
#      resolves BOTH to the exact same final realized output path,
#      confirmed by direct reproduction; this fixture checks output
#      equality rather than THIS specific drv's own byte-identity,
#      since that part is expected to differ, only the two real TUs are
#      expected to match exactly.)
#
# The devShell side runs OUTSIDE any `builder-rpc-v0` sandbox (the whole
# point of `Rpc` mode) against the AMBIENT system Nix store. The
# sandboxed-build side runs via `try-it-out/run-nix.sh`, which drives an
# ISOLATED alt store (`$DYNDRV_STORE`, default `/tmp/dyndrv-store`) --
# every `nix`/`nix-store` call against that side's own output MUST pass
# `--store "local?root=$DYNDRV_STORE"` explicitly, or it silently
# resolves against the wrong (ambient) store instead.
#
# Shares its actual devShell-build/collect/store-lookup mechanics with
# devshell-parity-smalllib-test.sh via parity-test-lib.sh (mirrors
# nixgg's own tests/lib/drv-equiv-common.sh split) -- this script's own
# body is just its fixture's identity (`example/`, `08-accelerate-
# example-dir.nix`) plus the functional `hello`-output check that
# fixture's own single, non-generic final binary makes easy to assert.
#
# Usage: rust/dyndrv-shim/devshell-parity-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DYNDRV_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
DYNDRV_STORE="${DYNDRV_STORE:-/tmp/dyndrv-store}"

# shellcheck source=./parity-test-lib.sh
source "$SCRIPT_DIR/parity-test-lib.sh"

WORKDIR=$(mktemp -d -t dyndrv-devshell-parity-test.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

echo "building devShell wrapper..." >&2
WRAPPER_DIR=$(parity_build_devshell_wrapper)

echo "running make through the devShell wrapper (no autoforce -- registers, doesn't realize)..." >&2
parity_run_native_build "$WRAPPER_DIR" "$WORKDIR" \
  "$DYNDRV_ROOT"/example/main.cc "$DYNDRV_ROOT"/example/util.cc \
  "$DYNDRV_ROOT"/example/util.h "$DYNDRV_ROOT"/example/Makefile

cd "$WORKDIR"
if [ ! -L main.o ] || [ ! -L util.o ] || [ ! -L hello ]; then
  echo "FAIL: main.o/util.o/hello are not symlinks -- expected deferred Rpc-mode .drv symlinks with DYNDRV_AUTOFORCE unset" >&2
  exit 1
fi

DEVSHELL_HELLO_DRV_BASENAME=$(basename "$(readlink hello)")

echo "building the sandboxed dyndrv.accelerate.mkAcceleratedStdenv variant of the same sources..." >&2
SANDBOXED_OUT=$("$DYNDRV_ROOT/try-it-out/run-nix.sh" build --impure --no-link --print-out-paths \
  -f "$DYNDRV_ROOT/try-it-out/examples/08-accelerate-example-dir.nix" 2>/dev/null)

# THE actual parity check: does the SANDBOXED build's own store
# (`$DYNDRV_STORE`) contain every TU drv the devShell registered --
# NOT via the outer package derivation's own `--requisites` closure
# (see `parity_check_sandbox_has_drv`'s own doc for why) but via a
# direct `nix path-info` lookup, confirming the exact path exists as a
# real, valid store object. If both paths construct byte-identical
# ATerm for the identical logical compile (the property
# `render::cross_mode_tests` now structurally guarantees via the
# shared `render_record_line` construction path), the sandboxed
# build's own `dyndrv-collect` run registers that SAME path too (Nix
# substitutes/no-ops rather than re-registering under a different
# name) -- a direct, mechanical check, not an inference from "both
# builds succeeded."
while IFS=' ' read -r rel drv_basename; do
  echo "OK: devShell registered $rel -> $drv_basename" >&2
  if ! parity_check_sandbox_has_drv "$drv_basename"; then
    echo "FAIL: the sandboxed build's own store does not contain the devShell's own registered $drv_basename -- the two paths registered DIFFERENT derivations for the identical logical compile" >&2
    exit 1
  fi
done < <(parity_collect_native_tu_drvs "$WORKDIR")
echo "OK: sandboxed build's own store contains every TU drv the devShell registered -- byte-identical derivations, confirmed via direct store lookup" >&2

# Functional check: realize the devShell's own registered link-step
# drv (against the AMBIENT store -- Rpc mode never uses an alt store)
# and confirm it runs and produces the SAME output as the sandboxed
# build's own binary. `SANDBOXED_OUT` is printed in `/nix/store/...`
# form (matching the ambient store's own path convention, regardless of
# which store a path actually lives under) but the alt store's real
# on-disk files live under `$DYNDRV_STORE/nix/store/...` -- same
# distinction `try-it-out/run-nix.sh`'s own callers already navigate
# elsewhere in this repo (e.g. every benchmark script's own direct
# binary invocations).
echo "realizing devShell's own hello.drv and comparing output against the sandboxed build..." >&2
DEVSHELL_HELLO_OUT=$(nix-store --realise "/nix/store/$DEVSHELL_HELLO_DRV_BASENAME" --extra-experimental-features ca-derivations 2>/dev/null | tail -1)
DEVSHELL_RESULT=$("$DEVSHELL_HELLO_OUT")
SANDBOXED_RESULT=$("$DYNDRV_STORE$SANDBOXED_OUT/bin/hello")

if [ "$DEVSHELL_RESULT" != "$SANDBOXED_RESULT" ]; then
  echo "FAIL: devShell hello ('$DEVSHELL_RESULT') and sandboxed hello ('$SANDBOXED_RESULT') produced DIFFERENT output" >&2
  exit 1
fi
echo "OK: both paths produce the identical, correct output: '$DEVSHELL_RESULT'" >&2

echo "PASS" >&2
