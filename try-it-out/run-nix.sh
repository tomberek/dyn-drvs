#!/usr/bin/env bash
# Resolves/builds the patched Nix (try-it-out/patched-nix.nix, tracking
# NixOS/nix#15793 for the builder-rpc-v0 backend) with the ambient system
# Nix, then re-execs into it against a local, non-daemon store with the
# right --extra-experimental-features/--extra-system-features baked in.
#
# This exists because:
#  - the system nix-daemon's experimental-features are fixed at daemon
#    startup and can't be overridden per-invocation (confirmed directly:
#    passing --extra-experimental-features to `nix build` has no effect
#    if the daemon itself doesn't have the feature enabled);
#  - builder-rpc-v0 isn't supported by any released Nix or by the
#    multi-user daemon at all, so a local non-daemon store is required
#    regardless (the same workaround gradle-drvs and nix-ninja each
#    documented independently).
#
# Usage:
#   try-it-out/run-nix.sh build -f try-it-out/examples/01-hello-dynamic-drv.nix
#   try-it-out/run-nix.sh eval --impure --expr '...'
#
# Env vars:
#   NIX_SRC       path to a NixOS/nix#15793 checkout with a `build-release`
#                 (or similarly named) meson build directory already built
#                 (default: ../nix/build-release relative to this script --
#                 override if your checkout lives elsewhere)
#   DYNDRV_STORE  local store root to build/run against (default:
#                 /tmp/dyndrv-store, kept stable across runs so repeated
#                 invocations reuse already-built paths)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DYNDRV_ROOT="$(dirname "$SCRIPT_DIR")"

NIX_SRC="${NIX_SRC:-$SCRIPT_DIR/../../nix/build-release}"
DYNDRV_STORE="${DYNDRV_STORE:-/tmp/dyndrv-store}"

if [[ ! -e "$NIX_SRC/src/nix/nix" ]]; then
  echo "run-nix.sh: no built Nix found at \$NIX_SRC ($NIX_SRC/src/nix/nix)." >&2
  echo "  Set NIX_SRC to a NixOS/nix#15793 checkout with a meson build already run," >&2
  echo "  e.g. NIX_SRC=/path/to/nix/build-release $0 ..." >&2
  exit 1
fi

PATCHED_NIX=$(nix build --impure --no-link --print-out-paths --expr "
  let pkgs = import <nixpkgs> {};
  in (import $DYNDRV_ROOT/try-it-out/patched-nix.nix { inherit pkgs; }) {
    nixSrc = $NIX_SRC;
  }
")

mkdir -p "$DYNDRV_STORE"

exec "$PATCHED_NIX/bin/nix" \
  --extra-experimental-features "nix-command ca-derivations dynamic-derivations recursive-nix" \
  --extra-system-features "builder-rpc-v0" \
  --store "local?root=$DYNDRV_STORE" \
  "$@"
