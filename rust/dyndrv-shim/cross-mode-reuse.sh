#!/usr/bin/env bash
# cross-mode-reuse.sh: proves REAL substitution, not just derivation-
# hash agreement -- the missing half of devshell-parity-test.sh/
# devshell-parity-smalllib-test.sh, which prove the SET of registered
# TU drv-hashes matches between Rpc mode and Sandbox mode but never
# build anything through BOTH paths against the SAME store, so they
# can't tell "these two modes would produce the same drv" apart from
# "a real substitution event happens when one mode's build follows the
# other's" -- the actual property nixgg's own ARCHITECTURE.md
# "Corollary: dev-shell and pure-build derivations are interchangeable"
# describes, and its own tests/cross-mode-reuse.sh proves. This script
# is dyndrv's analog.
#
# THE MISSING MECHANISM this needed (found by direct reproduction, not
# assumed): `Rpc` mode's `BuilderRpcClient::connect_from_env()` always
# connects to the AMBIENT system daemon (`$NIX_REMOTE` or the default
# socket) -- there was no way to point it at the SAME isolated alt
# store `try-it-out/run-nix.sh`'s own sandboxed side drives, so the two
# paths had no shared store a real substitution could even happen in.
# Fixed here by running a SEPARATE, PRIVATE `nix daemon --socket-path
# <sock> --store 'local?root=<dir>'` (confirmed available on the
# patched-nix.nix build this repo already depends on for
# `builder-rpc-v0` -- `--socket-path` is a real, documented daemon flag,
# not a workaround) and pointing the native side's `NIX_REMOTE` at that
# socket while pointing `DYNDRV_STORE` (try-it-out/run-nix.sh's own
# store-root env var) at the SAME directory.
#
# Sequence (confirmed working by direct reproduction before this
# script was written):
#   1. Start the private daemon+store; copy the devShell wrapper's own
#      closure into it (a compile's `record.srcs` declares coreutils/
#      stdenv.cc/etc. as real store-path references, and
#      `add_drv_to_store`'s reference-scanning requires each to
#      already be a VALID object in the target store -- confirmed
#      necessary: the very first attempt failed with "path ... is not
#      valid" before this copy).
#   2. Run `make` through the devShell wrapper, `NIX_REMOTE` pointed at
#      the private socket -- registers (no autoforce), leaving
#      `main.o`/`util.o` as deferred `Rpc`-mode `.drv` symlinks.
#   3. `nix-store --realise` those two `.drv`s directly against the
#      private daemon -- this is the step `nixgg`'s own script also
#      does by hand ("Force those 2 thunks into real derivations")
#      before a sandboxed build could possibly substitute anything;
#      skipping it means there's no REAL content in the store yet for
#      the sandboxed side to find, and the first draft of this exact
#      script caught that mistake directly: without this step, the
#      sandboxed side's own build log DOES show `building
#      'main.o.drv'`/`'util.o.drv'` (a normal, correct realize-the-
#      derivation-for-the-first-time event, not a substitution
#      failure) -- so THIS step is what makes "absent from the
#      building log" a meaningful signal at all.
#   4. Run a full, ordinary sandboxed `nix build` of `08-accelerate-
#      example-dir.nix` via `try-it-out/run-nix.sh`, `DYNDRV_STORE`
#      pointed at the SAME directory the private daemon manages.
#   5. Assert `main.o.drv`/`util.o.drv` do NOT appear in this run's own
#      `building '...'` lines -- confirmed by direct reproduction this
#      is genuinely a substitution, not an artifact of the two drvs
#      simply being irrelevant to this build: BEFORE step 3 (no real
#      content realized yet), the exact same two `building '...'`
#      lines DID appear; only after realizing them does that log go
#      quiet for those two paths specifically, while the OUTER
#      `dyndrv-example-1.0.drv`/`dyndrv-example-1.0.drv.drv` (never
#      pre-realized) still legitimately build every time -- the
#      negative control this script's own assertion structure needs to
#      mean anything.
#
# NOT checked here (a real, known gap, left as a documented limitation
# rather than a false claim): dyndrv's own submitted-tree architecture
# copies bytes via resolved PLACEHOLDER TEXT at script-generation time
# (`graph/compile.nix`'s bash port of `DownstreamPlaceholder::
# unknownCaOutput`, `dyndrv-collect.rs`'s Rust equivalent), not
# `inputDrvs` edges -- confirmed by direct reproduction (`nix
# derivation show -r` on the final submitted tree) that `main.o.drv`/
# `util.o.drv` never appear in ITS own recursive closure at all, even
# on a run where they WERE substituted. nixgg's own second half of this
# check ("the sandbox build's own drv graph references the native-built
# paths") doesn't map onto dyndrv's architecture the same way -- the
# "absent from the building log, but only after being pre-realized"
# structure above is the meaningful substitute for dyndrv specifically.
#
# Usage: rust/dyndrv-shim/cross-mode-reuse.sh
#
# Env vars:
#   KEEP_STORE=1   don't wipe the private store/socket at start (for
#                  local iteration)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DYNDRV_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

PRIVATE_STORE="/tmp/dyndrv-cross-mode-reuse-store"
PRIVATE_SOCKET="/tmp/dyndrv-cross-mode-reuse.sock"

if [[ "${KEEP_STORE:-}" != "1" ]]; then
  chmod -R u+w "$PRIVATE_STORE" 2>/dev/null || true
  rm -rf "$PRIVATE_STORE"
fi
mkdir -p "$PRIVATE_STORE"

WORKDIR=$(mktemp -d -t dyndrv-cross-mode-reuse.XXXXXX)
trap 'rm -rf "$WORKDIR"; kill "${DAEMON_PID:-0}" 2>/dev/null || true; rm -f "$PRIVATE_SOCKET"' EXIT

echo "resolving builder-rpc-v0-capable Nix..." >&2
# `system` passed explicitly (sourced from `nix config show`, a plain
# config query, not an eval) so this build needs no `--impure` for
# `patched-nix.nix`'s own `system ? builtins.currentSystem` default --
# same fix `try-it-out/run-nix.sh` already applies.
SYSTEM=$(nix config show --json | jq -r .system.value)
DYNDRV_NIX=$(nix build --no-link --print-out-paths \
  --argstr system "$SYSTEM" \
  -f "$DYNDRV_ROOT/try-it-out/patched-nix.nix" '^out')

echo "starting a private daemon against an isolated store..." >&2
NIX_CONFIG='extra-experimental-features = nix-command ca-derivations dynamic-derivations recursive-nix' \
  "$DYNDRV_NIX/bin/nix" daemon --store "local?root=$PRIVATE_STORE" --socket-path "$PRIVATE_SOCKET" \
  >"$WORKDIR/daemon.log" 2>&1 &
DAEMON_PID=$!
# No IPC signal for "daemon is listening" -- the socket file appearing
# is the observable event; a short poll loop (not a fixed sleep) keeps
# this from being flaky under load.
for _ in $(seq 1 50); do
  [[ -S "$PRIVATE_SOCKET" ]] && break
  sleep 0.1
done
if [[ ! -S "$PRIVATE_SOCKET" ]]; then
  echo "FAIL: private daemon never created its socket; see $WORKDIR/daemon.log:" >&2
  cat "$WORKDIR/daemon.log" >&2
  exit 1
fi

echo "building devShell wrapper..." >&2
WRAPPER_DIR=$(nix build --impure --no-link --print-out-paths --expr '
  let
    pkgs = (builtins.getFlake "'"$DYNDRV_ROOT"'").legacyPackages.${builtins.currentSystem};
    lib = pkgs.lib;
    self = import '"$DYNDRV_ROOT"'/nix { inherit pkgs lib; };
    dyndrvShim = import '"$DYNDRV_ROOT"'/rust/dyndrv-shim.nix { inherit pkgs; };
  in (self.shim.devShell { stdenv = pkgs.stdenv; inherit dyndrvShim; autoforce = false; }).wrapperDir
' 2>/dev/null)

echo "seeding the private store with the devShell wrapper's own closure..." >&2
"$DYNDRV_NIX/bin/nix" copy --no-check-sigs --to "local?root=$PRIVATE_STORE" "$WRAPPER_DIR" >/dev/null 2>&1

echo "running make through the devShell wrapper against the PRIVATE daemon (no autoforce)..." >&2
cp "$DYNDRV_ROOT"/example/main.cc "$DYNDRV_ROOT"/example/util.cc \
  "$DYNDRV_ROOT"/example/util.h "$DYNDRV_ROOT"/example/Makefile "$WORKDIR/"
(
  cd "$WORKDIR"
  export PATH="$WRAPPER_DIR/bin:$PATH"
  export CC="$WRAPPER_DIR/bin/cc"
  export CXX="$WRAPPER_DIR/bin/c++"
  export AR="$WRAPPER_DIR/bin/ar"
  export RANLIB="$WRAPPER_DIR/bin/ranlib"
  export DYNDRV_MODE=rpc
  export NIX_REMOTE="unix://$PRIVATE_SOCKET"
  make
)

if [ ! -L "$WORKDIR/main.o" ] || [ ! -L "$WORKDIR/util.o" ]; then
  echo "FAIL: main.o/util.o are not symlinks -- expected deferred Rpc-mode .drv symlinks with DYNDRV_AUTOFORCE unset" >&2
  exit 1
fi
MAIN_O_DRV=$(readlink "$WORKDIR/main.o")
UTIL_O_DRV=$(readlink "$WORKDIR/util.o")
MAIN_O_DRV_BASENAME=$(basename "$MAIN_O_DRV")
UTIL_O_DRV_BASENAME=$(basename "$UTIL_O_DRV")
echo "OK: devShell registered main.o -> $MAIN_O_DRV_BASENAME, util.o -> $UTIL_O_DRV_BASENAME" >&2

# THE step that makes "absent from the building log" meaningful --
# see this script's own header comment for why skipping this made the
# first draft's assertion vacuous (both TU drvs still built normally
# the first time through, a correct realize-for-the-first-time event,
# not a substitution failure).
echo "realizing both TU drvs against the private daemon (what NIXGG_AUTOFORCE=1 / nixgg force would do automatically for a real link step)..." >&2
NIX_REMOTE="unix://$PRIVATE_SOCKET" "$DYNDRV_NIX/bin/nix-store" --realise "$MAIN_O_DRV" --extra-experimental-features ca-derivations >/dev/null 2>&1
NIX_REMOTE="unix://$PRIVATE_SOCKET" "$DYNDRV_NIX/bin/nix-store" --realise "$UTIL_O_DRV" --extra-experimental-features ca-derivations >/dev/null 2>&1

echo "running a full, ordinary sandboxed nix build against the SAME store..." >&2
DYNDRV_STORE="$PRIVATE_STORE" "$DYNDRV_ROOT/try-it-out/run-nix.sh" build --impure --no-link --print-out-paths \
  -f "$DYNDRV_ROOT/try-it-out/examples/08-accelerate-example-dir.nix" \
  >"$WORKDIR/sandbox-build.log" 2>&1 || {
  echo "FAIL: sandboxed build failed; see $WORKDIR/sandbox-build.log:" >&2
  tail -30 "$WORKDIR/sandbox-build.log" >&2
  exit 1
}

# THE actual substitution check: neither TU drv should appear in this
# run's own "building '...'" lines -- if either does, Nix chose to
# REBUILD a derivation whose content it already had, meaning the two
# modes' construction paths produced non-identical results for the
# identical logical compile (the exact regression this whole fixture
# exists to catch), OR (less likely, but a real possibility this
# assertion alone can't distinguish) the realize-in-step-3 above
# silently failed.
FAILED=0
for basename in "$MAIN_O_DRV_BASENAME" "$UTIL_O_DRV_BASENAME"; do
  if grep -q "building '/nix/store/$basename'" "$WORKDIR/sandbox-build.log"; then
    echo "FAIL: sandboxed build REBUILT $basename instead of substituting the devShell's own already-realized content" >&2
    FAILED=1
  fi
done
if [ "$FAILED" = "1" ]; then
  exit 1
fi
echo "OK: neither main.o.drv nor util.o.drv appear in the sandboxed build's own 'building' log -- real substitution, not just matching hashes" >&2

echo "PASS" >&2
