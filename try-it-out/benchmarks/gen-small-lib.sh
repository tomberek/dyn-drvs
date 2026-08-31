#!/usr/bin/env bash
# Generates a synthetic multi-file C "library" fixture for
# small-lib-patch-rebuild.sh: N independent translation units (each its
# own .c file with no shared local header, deliberately -- see that
# script's header comment for why: mkAcceleratedStdenv's v0.2 `cc` shim
# only tracks argv-named files, not #include search paths, so a shared
# local lib.h is invisible inside a per-TU sandbox and fails with "No such
# file or directory" -- confirmed by direct reproduction. This is the same
# "build-time discovery" gap the plan defers to v0.3/nix-ninja's header-
# discovery pattern, not a benchmark-fixture bug), each declared `extern`
# in main.c, linked into one `prog` binary via a Makefile.
#
# Usage: gen-small-lib.sh <dir> <nFiles> [patchIndex]
#   dir:         output directory (created if missing)
#   nFiles:      number of lib_N.c translation units
#   patchIndex:  if set, lib_<patchIndex>.c gets a one-line change (+1000)
#                relative to the unpatched version -- simulates "one file
#                changed" for the incremental-rebuild scenario.
#   LOOPS (env): how much synthetic work each lib_N.c's body does (default
#                40) -- tunable so the fixture can be scaled from
#                "registration tax dominates" to "real compile time
#                dominates," matching the break-even point measurement in
#                the plan's "Measuring the benefit" section.

set -euo pipefail

dir="$1"
nfiles="$2"
patch_index="${3:-}"
loops="${LOOPS:-40}"

mkdir -p "$dir"

gen_body() {
  local i="$1" extra="$2"
  echo "int lib_$i(int x) {"
  echo "  int s = x + $i$extra;"
  for j in $(seq 1 "$loops"); do
    echo "  s = (s * $j + $i) % 1000003;"
  done
  echo "  return s;"
  echo "}"
}

for i in $(seq 0 $((nfiles - 1))); do
  if [[ "$i" == "$patch_index" ]]; then
    gen_body "$i" " + 1000" > "$dir/lib_$i.c"
  else
    gen_body "$i" "" > "$dir/lib_$i.c"
  fi
done

{
  echo '#include <stdio.h>'
  for i in $(seq 0 $((nfiles - 1))); do
    echo "extern int lib_$i(int x);"
  done
  echo 'int main(void) {'
  echo '  int s = 0;'
  for i in $(seq 0 $((nfiles - 1))); do
    echo "  s += lib_$i(1);"
  done
  echo '  printf("%d\n", s);'
  echo '  return 0;'
  echo '}'
} > "$dir/main.c"

objlist="main.o"
for i in $(seq 0 $((nfiles - 1))); do
  objlist="$objlist lib_$i.o"
done
{
  printf 'OBJS = %s\n' "$objlist"
  echo 'all: prog'
  echo 'prog: $(OBJS)'
  printf '\t$(CC) $(OBJS) -o prog\n'
  echo '%.o: %.c'
  printf '\t$(CC) -O2 -c $< -o $@\n'
} > "$dir/Makefile"
