#!/usr/bin/env bash
# Runs dyndrv's own Nix-level test suite against the installed Nix
# (recursive-nix backend; builder-rpc-v0 tests require a patched Nix, see
# ../../try-it-out/run-nix.sh, and are not run here in v0.1).
#
# Builds the SAME three checks `flake.nix`'s own `checks.<system>.{
# mkOutputOf,nonTrivial,defaultBackend}` outputs expose (via `nix/tests/
# default.nix`'s `assertPass`, which fails the derivation outright if
# `result.pass != true` -- this script just needs to check `nix build`'s
# own exit code, no `{"pass":true}` JSON round-trip needed). Building via
# a flake attr path (`.#checks.<system>.<name>`) rather than each test's
# own `-f <file>.nix`/`--expr` form stays PURE -- no `--impure` needed --
# because the check itself already has `pkgs` supplied by `flake.nix`'s
# own `checks = builtins.mapAttrs (system: pkgs: ...)`, so the test
# file's own `pkgs ? (builtins.getFlake ...)` DEFAULT (which would need
# `--impure` on THIS local, uncommitted-or-not checkout) never fires.
#
# Usage: nix/tests/run-tests.sh
# Env vars:
#   DYNDRV_STORE  local store root (default: /tmp/dyndrv-store, shared with
#                 try-it-out/run-nix.sh so repeated runs reuse built paths)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DYNDRV_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
DYNDRV_STORE="${DYNDRV_STORE:-/tmp/dyndrv-store}"

mkdir -p "$DYNDRV_STORE"

# A plain config query (not an eval), so this needs no `--impure` either
# -- see `try-it-out/run-nix.sh`'s own matching comment for why
# `builtins.currentSystem` itself is avoided here.
SYSTEM=$(nix config show --json | jq -r .system.value)

run_test() {
  local name="$1" check="$2"
  echo "=== $name ==="
  if nix build \
    --extra-experimental-features "dynamic-derivations ca-derivations nix-command recursive-nix" \
    --store "local?root=$DYNDRV_STORE" \
    --no-link --print-out-paths \
    "$DYNDRV_ROOT#checks.$SYSTEM.$check" >/dev/null; then
    echo "PASS: $name"
  else
    echo "FAIL: $name"
    return 1
  fi
}

run_test "mkOutputOf (oracle: eval-outputOf.sh)" "mkOutputOf"
run_test "nonTrivial (oracle: non-trivial.nix, descoped to independent nodes)" "nonTrivial"
run_test "defaultBackend (unset backend defaults to builder-rpc-v0, not detected)" "defaultBackend"

echo ""
echo "All tests passed."
