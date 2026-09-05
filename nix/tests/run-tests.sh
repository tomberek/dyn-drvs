#!/usr/bin/env bash
# Runs dyndrv's own Nix-level test suite against the installed Nix
# (recursive-nix backend; builder-rpc-v0 tests require a patched Nix, see
# ../../try-it-out/run-nix.sh, and are not run here in v0.1).
#
# Each test is a plain .nix file evaluating to `{ pass = <bool>; ... }`
# after building; this script builds it and checks `pass`.
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

run_test() {
  local name="$1"
  local expr="$2"
  echo "=== $name ==="
  local out
  out=$(nix build \
    --extra-experimental-features "dynamic-derivations ca-derivations nix-command recursive-nix" \
    --store "local?root=$DYNDRV_STORE" \
    --impure --no-link --print-out-paths \
    --expr "$expr")
  local resolved="${DYNDRV_STORE}${out}"
  if [[ "$(cat "$resolved")" != *'"pass":true'* ]] && [[ "$(cat "$resolved")" != "true" ]]; then
    echo "FAIL: $name"
    echo "  output: $(cat "$resolved")"
    return 1
  fi
  echo "PASS: $name"
}

run_test "mkOutputOf (oracle: eval-outputOf.sh)" "
  let
    pkgs = import <nixpkgs> {};
    lib = pkgs.lib;
    dyndrv = import $DYNDRV_ROOT/nix { inherit pkgs lib; };
    result = import $DYNDRV_ROOT/nix/tests/mkOutputOf.nix { inherit pkgs lib dyndrv; };
  in
  pkgs.runCommand \"mkOutputOf-test-result\" {
    staticEqualStr = builtins.toJSON result.staticEqual;
    dynamicEqualStr = builtins.toJSON result.dynamicEqual;
  } ''
    if [[ \"\$staticEqualStr\" == \"true\" && \"\$dynamicEqualStr\" == \"true\" ]]; then
      echo '{\"pass\":true}' > \$out
    else
      echo '{\"pass\":false}' > \$out
    fi
  ''
"

run_test "nonTrivial (oracle: non-trivial.nix, descoped to independent nodes)" "
  let
    pkgs = import <nixpkgs> {};
    lib = pkgs.lib;
    dyndrv = import $DYNDRV_ROOT/nix { inherit pkgs lib; };
    result = import $DYNDRV_ROOT/nix/tests/nonTrivial.nix { inherit pkgs lib dyndrv; };
  in
  pkgs.runCommand \"nonTrivial-test-result\" {
    passStr = builtins.toJSON result.pass;
  } ''
    echo \"{\\\"pass\\\":\$passStr}\" > \$out
  ''
"

run_test "defaultBackend (unset backend defaults to builder-rpc-v0, not detected)" "
  let
    pkgs = import <nixpkgs> {};
    lib = pkgs.lib;
    dyndrv = import $DYNDRV_ROOT/nix { inherit pkgs lib; };
    result = import $DYNDRV_ROOT/nix/tests/defaultBackend.nix { inherit pkgs lib dyndrv; };
  in
  pkgs.runCommand \"defaultBackend-test-result\" {
    passStr = builtins.toJSON result.pass;
  } ''
    echo \"{\\\"pass\\\":\$passStr}\" > \$out
  ''
"

echo ""
echo "All tests passed."
