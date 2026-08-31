#!/usr/bin/env bash
# small-lib-patch-rebuild.sh: the v0.2 macro benchmark for
# dyndrv.accelerate.mkAcceleratedStdenv (see the plan's "Measuring the
# benefit" section) -- a small, fast-to-iterate workload so this can run
# on every PR touching nix/lib/accelerate/ or nix/lib/shim/, unlike the
# openssl-scale benchmark (try-it-out/benchmarks/openssl-patch-rebuild.sh),
# which is expensive and runs on a schedule instead.
#
# Reproduces nixgg's own measurement methodology (one-line patch, N/total
# translation units rebuilt) on a synthetic multi-file C "library"
# (try-it-out/benchmarks/gen-small-lib.sh), reporting all four metrics
# from the plan's "Measuring the benefit" section:
#   1. rebuild wall-clock, patched vs. cold, plain vs. accelerated
#   2. derivations rebuilt vs. total, for the patched-rebuild case
#   3. registration overhead ("the tax") -- see registration-overhead.sh;
#      referenced here, not re-measured, since it's a property of the
#      backend's per-call cost, not of this specific fixture
#   4. break-even point -- derived from 1-3, printed as guidance, not a
#      single number (see below)
#
# IMPORTANT, stated plainly (per the plan's mandate to report where the
# win does NOT hold, not just where it does): at small per-file compile
# cost, the accelerated path's per-derivation registration/realise
# round-trip (`nix derivation add` + `nix-store --realise`, via
# `shim.wrapCommand`'s `recursive-nix` backend) can cost MORE than just
# recompiling everything plainly would have. Confirmed directly: with
# LOOPS=40 (cheap per-file compiles), a 50-file patched rebuild took
# ~11.4s accelerated vs. ~3.6s plain -- accelerated was SLOWER, because
# the ~150-200ms/derivation tax (see registration-overhead.sh) dominates
# when there's almost no real compile work to save. The default LOOPS
# value below is picked so the DEFAULT run demonstrates a real win (per
# nixgg's own measured regime: real compilers doing real work per TU), but
# the LOOPS=40 counter-example is recorded in BASELINE.md exactly so this
# benchmark doesn't read as one-sided -- run with LOOPS=40 yourself to
# reproduce the honest downside case.
#
# Usage:
#   try-it-out/benchmarks/small-lib-patch-rebuild.sh [nFiles] [loops]
#     nFiles: number of translation units (default: 30)
#     loops:  synthetic per-file compile work, see gen-small-lib.sh
#             (default: 1500 -- chosen to land clearly past the break-even
#             point for this machine, confirmed at ~2.8x speedup; see
#             BASELINE.md for the honest LOOPS=40 counter-example and how
#             break-even shifts with hardware -- it's genuinely close at
#             LOOPS=400/30 files, ~0.99x, right at the edge)
#
# Env vars:
#   DYNDRV_BENCH_DIR  scratch dir for fixtures + local stores (default: a
#                     fresh mktemp -d, removed on exit unless KEEP=1)
#   KEEP=1            keep DYNDRV_BENCH_DIR after the run, for inspection

set -euo pipefail

NFILES="${1:-30}"
LOOPS="${2:-1500}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORKDIR="${DYNDRV_BENCH_DIR:-$(mktemp -d -t dyndrv-small-lib-bench.XXXXXX)}"
mkdir -p "$WORKDIR"
if [[ -z "${KEEP:-}" ]]; then
  # Nix store objects under $WORKDIR/store-* are write-protected by design
  # (confirmed directly: a plain `rm -rf` on a local store root fails with
  # "Permission denied" per read-only file, which -- without the trailing
  # `|| true` -- made this trap's own failure become the script's exit
  # code even after a fully successful benchmark run). `chmod -R u+w` first
  # so the following `rm -rf` can actually remove everything.
  trap 'chmod -R u+w "$WORKDIR" 2>/dev/null; rm -rf "$WORKDIR" || true' EXIT
fi

EXTRA_FEATURES="nix-command ca-derivations dynamic-derivations recursive-nix"
SYSTEM_FEATURES="recursive-nix"

echo "dyndrv small-lib-patch-rebuild benchmark"
echo "nFiles=$NFILES, LOOPS=$LOOPS, workdir=$WORKDIR"
echo ""

echo "Generating fixtures..."
LOOPS="$LOOPS" "$SCRIPT_DIR/gen-small-lib.sh" "$WORKDIR/src-cold" "$NFILES"
PATCH_IDX=$(( NFILES / 2 ))
cp -r "$WORKDIR/src-cold" "$WORKDIR/src-patched"
LOOPS="$LOOPS" "$SCRIPT_DIR/gen-small-lib.sh" "$WORKDIR/src-patched-tmp" "$NFILES" "$PATCH_IDX"
cp "$WORKDIR/src-patched-tmp/lib_$PATCH_IDX.c" "$WORKDIR/src-patched/lib_$PATCH_IDX.c"
rm -rf "$WORKDIR/src-patched-tmp"

nix_build() {
  local store="$1" src="$2" variant="$3"
  nix build \
    --extra-experimental-features "$EXTRA_FEATURES" \
    --extra-system-features "$SYSTEM_FEATURES" \
    --store "local?root=$store" \
    --no-link --print-out-paths \
    --arg src "$src" --argstr variant "$variant" \
    -f "$SCRIPT_DIR/small-lib.nix"
}

time_build() {
  local store="$1" src="$2" variant="$3"
  local start end
  start=$(date +%s.%N)
  local drv
  drv=$(nix_build "$store" "$src" "$variant" 2>"$WORKDIR/last-build.log")
  end=$(date +%s.%N)
  echo "$drv"
  awk -v s="$start" -v e="$end" 'BEGIN { printf "%.2f", e - s }' > "$WORKDIR/last-elapsed"
}

count_dyndrv_builds() {
  # Counts distinct `dyndrv-cc-*.drv` builder invocations in the log --
  # metric 2, "derivations rebuilt" for the accelerated path.
  grep -c "building '.*dyndrv-cc-.*\.drv'" "$WORKDIR/last-build.log" || true
}

echo "=== Plain stdenv.mkDerivation ==="
echo "-- cold build --"
time_build "$WORKDIR/store-plain" "$WORKDIR/src-cold" "plain" >/dev/null
plain_cold_time=$(cat "$WORKDIR/last-elapsed")
echo "  ${plain_cold_time}s"

echo "-- patched rebuild (warm store, one file changed) --"
time_build "$WORKDIR/store-plain" "$WORKDIR/src-patched" "plain" >/dev/null
plain_patch_time=$(cat "$WORKDIR/last-elapsed")
echo "  ${plain_patch_time}s (rebuilds the whole derivation -- plain stdenv has no per-TU granularity)"
echo ""

echo "=== dyndrv.accelerate.mkAcceleratedStdenv ==="
echo "-- cold build --"
time_build "$WORKDIR/store-accelerated" "$WORKDIR/src-cold" "accelerated" >/dev/null
acc_cold_time=$(cat "$WORKDIR/last-elapsed")
echo "  ${acc_cold_time}s"

echo "-- patched rebuild (warm store, one file changed) --"
time_build "$WORKDIR/store-accelerated" "$WORKDIR/src-patched" "accelerated" >/dev/null
acc_patch_time=$(cat "$WORKDIR/last-elapsed")
acc_patch_rebuilt=$(count_dyndrv_builds)
echo "  ${acc_patch_time}s"
echo "  derivations rebuilt: $acc_patch_rebuilt / $((NFILES + 1)) translation units"
echo ""

echo "=== Metric 1: rebuild wall-clock (patched, warm store) ==="
echo "  plain:       ${plain_patch_time}s"
echo "  accelerated: ${acc_patch_time}s"
speedup=$(awk -v p="$plain_patch_time" -v a="$acc_patch_time" 'BEGIN { if (a > 0) printf "%.2f", p / a; else print "n/a" }')
if [[ "$speedup" != "n/a" ]] && awk -v s="$speedup" 'BEGIN { exit !(s < 1) }'; then
  echo "  speedup: ${speedup}x (accelerated is SLOWER at this granularity -- see script header)"
else
  echo "  speedup: ${speedup}x"
fi
echo ""

echo "=== Metric 2: derivations rebuilt vs. total (patched rebuild) ==="
echo "  accelerated: $acc_patch_rebuilt / $((NFILES + 1)) (only the changed translation unit + anything downstream)"
echo "  plain:       $((NFILES + 1)) / $((NFILES + 1)) (always rebuilds everything -- one derivation, no internal granularity)"
echo ""

echo "=== Metric 3: registration overhead (\"the tax\") ==="
echo "  Not re-measured here -- see try-it-out/benchmarks/registration-overhead.sh"
echo "  for the per-call 'nix derivation add'/'nix-store --realise' cost this"
echo "  benchmark's accelerated path pays once per translation unit."
echo ""

echo "=== Metric 4: break-even guidance ==="
echo "  Break-even depends on (per-file compile time) vs. (per-derivation tax)."
echo "  Re-run with a smaller LOOPS value (e.g. LOOPS=40) to see the tax dominate"
echo "  and the accelerated path lose -- confirmed on this machine at LOOPS=40,"
echo "  50 files: plain patched-rebuild ~3.6s, accelerated patched-rebuild ~11.4s."
echo "  If your real package's per-TU compile time is well under the tax shown by"
echo "  registration-overhead.sh, mkAcceleratedStdenv is not yet worth adopting"
echo "  for it -- this is a real, honest limitation, not a caveat to hide."
