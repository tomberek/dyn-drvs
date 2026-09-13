#!/usr/bin/env bash
# Fetches/builds a real, unpatched NixOS/nix commit
# (try-it-out/patched-nix.nix) that supports `builder-rpc-v0`/`nix store
# submit-output`, then re-execs into it against a local, non-daemon store
# with the right --extra-experimental-features/--extra-system-features
# baked in.
#
# CONFIRMED (2026-09-02): `builder-rpc-v0` needs no patched Nix at all --
# it's on real NixOS/nix `master`, gated only by the SAME
# `dynamic-derivations` experimental feature `dyndrv` already needs
# everywhere else (see patched-nix.nix's own header comment for the full
# finding). This script just fetches+builds a pinned commit via
# `builtins.getFlake` -- no local checkout, no meson build step required.
#
# This still needs a LOCAL, non-daemon store (not the ambient system
# nix-daemon) because:
#  - the system nix-daemon's experimental-features are fixed at daemon
#    startup and can't be overridden per-invocation (confirmed directly:
#    passing --extra-experimental-features to `nix build` has no effect
#    if the daemon itself doesn't have the feature enabled);
#  - the multi-user daemon doesn't support `builder-rpc-v0` regardless
#    (same workaround gradle-drvs and nix-ninja each documented
#    independently).
#
# VERSION MATCHING: this script uses the SAME fetched Nix build as both
# the outer driving Nix and (via `viaDerivationAdd`'s `nixPackage`
# argument, set by each example itself) the Nix running inside the
# sandbox -- confirmed necessary by direct reproduction, see
# patched-nix.nix's header comment.
#
# Usage:
#   try-it-out/run-nix.sh build -f try-it-out/examples/01-hello-dynamic-drv.nix
#   try-it-out/run-nix.sh eval --impure --expr '...'
#
# Env vars:
#   NIX_REV       NixOS/nix commit to fetch+build (default: the commit
#                 pinned in patched-nix.nix -- override to try a newer one)
#   DYNDRV_STORE  local store root to build/run against (default:
#                 /tmp/dyndrv-store, kept stable across runs so repeated
#                 invocations reuse already-built paths)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DYNDRV_ROOT="$(dirname "$SCRIPT_DIR")"

DYNDRV_STORE="${DYNDRV_STORE:-/tmp/dyndrv-store}"

REV_ARG=""
if [[ -n "${NIX_REV:-}" ]]; then
  REV_ARG="--argstr rev $NIX_REV"
fi

# shellcheck disable=SC2086
# `patched-nix.nix` resolves to a multi-output derivation (has a `-man`
# split output) -- `--print-out-paths` prints every output on its own
# line, so `nix build ... .^out` selects ONLY the `out` output explicitly
# (confirmed necessary by direct reproduction: without `^out`, capturing
# `$(...)` into one variable concatenated both lines into a single,
# unusable garbled path).
#
# `patched-nix.nix`'s own `system` param defaults to `builtins.
# currentSystem` (impure) -- passed explicitly here instead, sourced
# from `nix show-config`'s own `system` setting (a plain config query,
# not an eval, so it needs no `--impure` at all) so this whole `nix
# build` stays pure.
SYSTEM=$(nix config show --json | jq -r .system.value)
PATCHED_NIX=$(nix build --no-link --print-out-paths $REV_ARG \
  --argstr system "$SYSTEM" \
  -f "$DYNDRV_ROOT/try-it-out/patched-nix.nix" '^out')

mkdir -p "$DYNDRV_STORE"

exec "$PATCHED_NIX/bin/nix" \
  --extra-experimental-features "nix-command ca-derivations dynamic-derivations recursive-nix" \
  --extra-system-features "builder-rpc-v0" \
  --store "local?root=$DYNDRV_STORE" \
  "$@"
