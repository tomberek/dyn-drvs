#!/usr/bin/env bash
# drv-thunk-multinode-test.sh: permanent regression fixture for
# `Thunk{format: Drv}` mode's multi-node `inputDrvs` chaining (tasks
# #77-80, see docs/drv-thunk-multinode-design.md) -- exercises a real
# TWO-compile-plus-one-archive graph and confirms:
#   1. `a.o`/`b.o` are DEFERRED `.drv`-thunk symlinks (never realized,
#      `DYNDRV_AUTOFORCE` unset for the compiles -- see below for why
#      this matters), and `ar`'s own registered `.drv` correctly lists
#      both compiles' real store paths in `inputDrvs` (not empty, not
#      literal relative paths) -- the concrete proof this is a genuine
#      cross-drv dependency edge, not just a plausible-looking
#      derivation.
#   2. `DYNDRV_AUTOFORCE=1` on the ARCHIVE step alone correctly realizes
#      the WHOLE graph via one root `--realise` call
#      (`register_drv_tree`'s own recursive registration,
#      `thunk_tail.rs`), producing a real, valid `liba.a` that a further
#      link+run step confirms is functionally correct.
#
# Runs OUTSIDE any `builder-rpc-v0` sandbox on purpose -- `Thunk` mode's
# whole design point is working against an ordinary, unrestricted
# system daemon connection, so (unlike `ar-integration-test.nix`) this
# is a plain shell script driving the compiled shim binary directly,
# not a Nix derivation.
#
# Usage: rust/dyndrv-shim/drv-thunk-multinode-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DYNDRV_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

WORKDIR=$(mktemp -d -t dyndrv-drv-multinode-test.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

echo "building dyndrv-shim + wrapper..." >&2
# Built via `flake.nix`'s own `packages.<system>.rpc-wrapper` output
# (`autoforce = false` there matches this script's own unset default)
# -- see `rust/dyndrv-shim/parity-test-lib.sh`'s matching comment for
# why this avoids `--impure`.
SYSTEM=$(nix config show --json | jq -r .system.value)
WRAPPER_DIR=$(nix build --no-link --print-out-paths "$DYNDRV_ROOT#packages.$SYSTEM.rpc-wrapper")

export PATH="$WRAPPER_DIR/bin:$PATH"
export CC="$WRAPPER_DIR/bin/cc"
export AR="$WRAPPER_DIR/bin/ar"
export DYNDRV_MODE=thunk
export DYNDRV_THUNK_FORMAT=drv
# `DYNDRV_AUTOFORCE` is a GLOBAL, unconditional env var (`mode::detect()`
# reads it for every invocation, `cc` included) -- left UNSET for the
# two compiles below so `a.o`/`b.o` stay real `.drv`-thunk SYMLINKS
# (never promoted to real content), which is the whole precondition
# this fixture needs to actually exercise cross-drv `inputDrvs`
# chaining at all. Confirmed by direct reproduction: setting it
# unconditionally for the WHOLE script (the naive first attempt at this
# fixture) eagerly promotes `a.o`/`b.o` to real files immediately after
# each `cc` call, so `ar` never sees a `.drv`-thunk symlink to resolve
# -- `resolve_drv_thunk_dependency` correctly returns `None` for a real
# file, the resulting archive still works, but the multi-node code path
# this fixture exists to test never actually runs. Only exported around
# the `ar` step below, matching nixgg's own "autoforce only meaningful
# on a link/archive step, the natural DAG root" design (`mode.rs`'s own
# doc comment).

cd "$WORKDIR"
cat > a.c <<'EOF'
int a(void) { return 11; }
EOF
cat > b.c <<'EOF'
int b(void) { return 22; }
EOF
cat > main.c <<'EOF'
#include <stdio.h>
extern int a(void);
extern int b(void);
int main(void) { printf("%d\n", a() + b()); return 0; }
EOF

echo "compiling a.c, b.c (deferred, no autoforce)..." >&2
"$CC" -c a.c -o a.o
"$CC" -c b.c -o b.o

if [ ! -L a.o ] || [ ! -L b.o ]; then
  echo "FAIL: a.o/b.o are not symlinks -- expected deferred .drv-thunk symlinks with DYNDRV_AUTOFORCE unset" >&2
  exit 1
fi
echo "OK: a.o, b.o are deferred .drv-thunk symlinks (not yet realized)" >&2

echo "archiving liba.a (autoforce)..." >&2
DYNDRV_AUTOFORCE=1 "$AR" cr liba.a a.o b.o

if ! file liba.a | grep -q "ar archive"; then
  echo "FAIL: liba.a is not a valid ar archive" >&2
  exit 1
fi

# Check #1: the ARCHIVE step's own registered .drv (found by matching
# its rendered script, not "most recently modified" -- `ar`'s own
# thunk is written and immediately consumed by autoforce, so it is NOT
# reliably the newest file by mtime once realization touches other
# paths) must reference real inputDrvs, not an empty list -- confirmed
# real bug this fixture guards against (task #78's own "is_pending
# never recognized a Thunk{Drv} symlink" finding, which produced an
# EMPTY inputDrvs list and literal, meaningless relative-path text in
# the script instead of a real cross-drv edge).
ARCHIVE_DRV=$(grep -l "ar 'cr'" .dyndrv/thunks-drv/*.drv)
INPUT_DRV_COUNT=$(grep -o '\.drv",\[' "$ARCHIVE_DRV" | wc -l)
if [ "$INPUT_DRV_COUNT" -lt 2 ]; then
  echo "FAIL: archive drv's own inputDrvs has fewer than 2 entries (found $INPUT_DRV_COUNT) -- multi-node chaining regressed" >&2
  cat "$ARCHIVE_DRV" >&2
  exit 1
fi
echo "OK: archive drv references $INPUT_DRV_COUNT real inputDrvs entries" >&2

# Check #2: the realized archive must actually work -- link + run.
echo "linking + running..." >&2
DYNDRV_AUTOFORCE=1 "$CC" -c main.c -o main.o
DYNDRV_AUTOFORCE=1 "$CC" main.o liba.a -o prog
RESULT=$(./prog)
if [ "$RESULT" != "33" ]; then
  echo "FAIL: expected 33 (11+22), got $RESULT" >&2
  exit 1
fi
echo "OK: prog produced correct output ($RESULT)" >&2

echo "PASS" >&2
