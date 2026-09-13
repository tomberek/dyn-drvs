#!/usr/bin/env bash
# devshell-parity-smalllib-test.sh: the SAME Rpc-vs-Sandbox parity
# check devshell-parity-test.sh runs against `example/` (a 2-TU C++
# project), run against a SECOND, independently-generated real project
# (`gen-small-lib.sh`'s own synthetic multi-file C "library" fixture,
# also used by small-lib-patch-rebuild.sh's benchmark) -- proving the
# invariant generalizes beyond one hand-picked fixture, not just that
# it happens to hold for `example/`'s own two files.
#
# Confirms the same property devshell-parity-test.sh does: every
# `lib_N.o`/`main.o` derivation `make` registers via `nix/lib/shim/
# devShell.nix`'s Rpc-mode wrappers is BYTE-FOR-BYTE IDENTICAL (same
# registered store path) to what a sandboxed `dyndrv.accelerate.
# mkAcceleratedStdenv` build of the identical sources registers --
# generic over N (unlike a hardcoded 2-file check), via
# `parity-test-lib.sh`'s shared `parity_collect_native_tu_drvs`.
#
# `small-lib.nix`'s own sandboxed side is built with `dyndrvShim` SET
# (the compiled shim), matching `08-accelerate-example-dir.nix`'s own
# wiring -- `shim.devShell` (the native side) is ALWAYS the compiled
# shim, never the bash `toNodeBash`/`collectStubs` path, so comparing
# against the sandboxed side's DEFAULT (bash) path would compare two
# different derivation-naming conventions and fail for a reason that
# has nothing to do with cross-mode parity (confirmed by direct
# reproduction: this is the exact mismatch this fixture hit before
# `small-lib.nix` grew its own `dyndrvShim` param).
#
# Env vars:
#   NFILES  number of lib_N.c translation units (default 5 -- enough
#           to exercise "more than one TU" without the fixture-
#           generation/build cost of a full benchmark-scale run)
#
# Usage: rust/dyndrv-shim/devshell-parity-smalllib-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DYNDRV_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
DYNDRV_STORE="${DYNDRV_STORE:-/tmp/dyndrv-store}"
NFILES="${NFILES:-5}"

# shellcheck source=./parity-test-lib.sh
source "$SCRIPT_DIR/parity-test-lib.sh"

WORKDIR=$(mktemp -d -t dyndrv-devshell-parity-smalllib-test.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

echo "generating small-lib fixture ($NFILES files)..." >&2
"$DYNDRV_ROOT/try-it-out/benchmarks/gen-small-lib.sh" "$WORKDIR/src" "$NFILES"

echo "building devShell wrapper..." >&2
WRAPPER_DIR=$(parity_build_devshell_wrapper)

echo "running make through the devShell wrapper (no autoforce -- registers, doesn't realize)..." >&2
mkdir -p "$WORKDIR/native"
parity_run_native_build "$WRAPPER_DIR" "$WORKDIR/native" "$WORKDIR"/src/*.c "$WORKDIR/src/Makefile"

NATIVE_DRVS=$(parity_collect_native_tu_drvs "$WORKDIR/native")
NATIVE_COUNT=$(printf '%s\n' "$NATIVE_DRVS" | grep -c . || true)
# nfiles lib_N.c + main.c
EXPECTED_COUNT=$((NFILES + 1))
if [ "$NATIVE_COUNT" -ne "$EXPECTED_COUNT" ]; then
  echo "FAIL: expected $EXPECTED_COUNT registered TU drvs (main.o + $NFILES lib_N.o), got $NATIVE_COUNT" >&2
  exit 1
fi

echo "building the sandboxed dyndrv.accelerate.mkAcceleratedStdenv variant of the same sources..." >&2
# `dyndrvShim` set: the devShell side (`shim.devShell`) is ALWAYS the
# compiled Rust shim (never the bash toNodeBash/collectStubs path), so
# the sandboxed comparison side must use the SAME shim to compare
# apples to apples -- otherwise the two sides use different derivation-
# naming conventions (bash: `dyndrv-<flattened-path>`; compiled: the
# bare output basename, see `real-package-patch-rebuild.sh`'s own
# `count_dyndrv_builds` for this exact distinction) and a mismatch here
# would be a test-setup artifact, not a real parity failure.
SANDBOXED_OUT=$("$DYNDRV_ROOT/try-it-out/run-nix.sh" build --impure --no-link --print-out-paths \
  --arg src "$WORKDIR/src" --argstr variant "accelerated" \
  --arg dyndrvShim "(import $DYNDRV_ROOT/rust/dyndrv-shim.nix {})" \
  -f "$DYNDRV_ROOT/try-it-out/benchmarks/small-lib.nix" 2>/dev/null)

# THE actual parity check -- see devshell-parity-test.sh's own header
# comment for the full rationale (direct store lookup, not an
# inference from "both builds succeeded").
while IFS=' ' read -r rel drv_basename; do
  echo "OK: devShell registered $rel -> $drv_basename" >&2
  if ! parity_check_sandbox_has_drv "$drv_basename"; then
    echo "FAIL: the sandboxed build's own store does not contain the devShell's own registered $drv_basename -- the two paths registered DIFFERENT derivations for the identical logical compile" >&2
    exit 1
  fi
done <<<"$NATIVE_DRVS"
echo "OK: sandboxed build's own store contains every TU drv the devShell registered ($NATIVE_COUNT total) -- byte-identical derivations, confirmed via direct store lookup" >&2

echo "PASS" >&2
