#!/usr/bin/env bash
# thunk-nix-multinode-test.sh: permanent regression fixture for
# `Thunk{format: Nix}` mode's multi-thunk `import` chaining (task #90)
# -- exercises a real TWO-compile-plus-one-archive graph and confirms:
#   1. `a.o`/`b.o` are DEFERRED `.nix`-thunk symlinks (never realized,
#      `DYNDRV_AUTOFORCE` unset for the compiles -- see below for why
#      this matters), and `ar`'s own rendered `.nix` thunk correctly
#      contains TWO real `${import <path>}` interpolations, one per
#      compile -- the concrete proof this is a genuine cross-thunk
#      dependency edge, not just literal relative-path text.
#   2. `DYNDRV_AUTOFORCE=1` on the ARCHIVE step alone correctly realizes
#      the WHOLE transitively-`import`-referenced graph via ONE `nix
#      build --file` call on the archive's own thunk (no separate
#      registration-tree walk needed -- Nix's own `import` mechanism
#      resolves the graph natively), producing a real, valid `liba.a`
#      that a further link+run step confirms is functionally correct.
#
# Runs OUTSIDE any `builder-rpc-v0` sandbox on purpose -- `Thunk` mode's
# whole design point is working against an ordinary, unrestricted
# system daemon connection (or even NO daemon features at all --
# `Thunk{Nix}` needs no `ca-derivations`/`dynamic-derivations`), so
# (unlike `ar-integration-test.nix`) this is a plain shell script
# driving the compiled shim binary directly, not a Nix derivation.
# Mirrors `drv-thunk-multinode-test.sh`'s own structure exactly, one
# level down (`.nix` thunks + `import`, not `.drv` files + `inputDrvs`).
#
# Usage: rust/dyndrv-shim/thunk-nix-multinode-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DYNDRV_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

WORKDIR=$(mktemp -d -t dyndrv-nix-multinode-test.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

echo "building dyndrv-shim + wrapper..." >&2
WRAPPER_DIR=$(nix build --impure --no-link --print-out-paths --expr '
  let
    pkgs = import <nixpkgs> {};
    lib = pkgs.lib;
    self = import '"$DYNDRV_ROOT"'/nix { inherit pkgs lib; };
    dyndrvShim = import '"$DYNDRV_ROOT"'/rust/dyndrv-shim.nix { inherit pkgs; };
  in (self.shim.devShell { stdenv = pkgs.stdenv; inherit dyndrvShim; }).wrapperDir
')

export PATH="$WRAPPER_DIR/bin:$PATH"
export CC="$WRAPPER_DIR/bin/cc"
export AR="$WRAPPER_DIR/bin/ar"
export DYNDRV_MODE=thunk
export DYNDRV_THUNK_FORMAT=nix
# Same reasoning as `drv-thunk-multinode-test.sh`'s own identical note:
# `DYNDRV_AUTOFORCE` is read unconditionally by EVERY invocation
# (`mode::detect()`), so it's left UNSET for the two compiles below --
# only exported around the `ar`/link steps, so `a.o`/`b.o` stay real
# `.nix`-thunk SYMLINKS (never promoted), the precondition this fixture
# needs to actually exercise cross-thunk `import` chaining at all.

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
  echo "FAIL: a.o/b.o are not symlinks -- expected deferred .nix-thunk symlinks with DYNDRV_AUTOFORCE unset" >&2
  exit 1
fi
echo "OK: a.o, b.o are deferred .nix-thunk symlinks (not yet realized)" >&2

echo "archiving liba.a (autoforce)..." >&2
DYNDRV_AUTOFORCE=1 "$AR" cr liba.a a.o b.o

if ! file liba.a | grep -q "ar archive"; then
  echo "FAIL: liba.a is not a valid ar archive" >&2
  exit 1
fi

# Check #1: the ARCHIVE step's own rendered .nix thunk (found by
# matching its script content, not "most recently modified" -- same
# reasoning as drv-thunk-multinode-test.sh's own identical check) must
# contain TWO real `${import ...}` interpolations, one per compile --
# confirmed real bug this fixture guards against (is_pending never
# recognized a Thunk{Nix} symlink before task #90, which would have
# produced literal, meaningless relative-path text in the script
# instead of a real cross-thunk import).
ARCHIVE_THUNK=$(grep -l "ar 'cr'" .dyndrv/thunks/*.nix)
IMPORT_COUNT=$(grep -o '\${import ' "$ARCHIVE_THUNK" | wc -l)
if [ "$IMPORT_COUNT" -lt 2 ]; then
  echo "FAIL: archive thunk's own script has fewer than 2 \${import ...} references (found $IMPORT_COUNT) -- multi-thunk chaining regressed" >&2
  cat "$ARCHIVE_THUNK" >&2
  exit 1
fi
echo "OK: archive thunk references $IMPORT_COUNT real \${import ...} dependencies" >&2

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
