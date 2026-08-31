#!/usr/bin/env bash
# Measures the per-call "registration tax" of dyndrv's two backend
# primitives -- `nix derivation add` (builder-rpc-v0's registration
# mechanism, via viaDerivationAdd) and `nix-instantiate` (recursive-nix's,
# via viaNixInstantiate) -- in isolation, with no package build required.
#
# This is metric 3 from the plan's "Measuring the benefit" section: the
# honest cost side of the ledger, established BEFORE any acceleration
# story exists to benchmark, so v0.2's win numbers don't look one-sided.
# Reproduces gradle-drvs' own measurement methodology (they measured
# ~1100 sequential `nix derivation add` calls taking 2m20s, dropping to
# 54s at 16-way sharding) at a smaller, CI-friendly scale.
#
# Usage: try-it-out/benchmarks/registration-overhead.sh [N]
#   N: number of registrations per trial (default: 100)
#
# Notes on methodology:
# - Measured standalone (outside a sandbox), not inside an actual dyndrv
#   build, because the fork+exec cost that dominates this tax is a
#   property of invoking the `nix` binary N times, not of the sandbox
#   itself (confirmed: both mechanisms' costs are dominated by process
#   startup, not by the trivial work each call actually does).
# - Both `nix derivation add` and `nix-instantiate` are measured with
#   plain, unpatched Nix -- neither requires builder-rpc-v0 or a patched
#   Nix to reproduce this specific cost (registration overhead is a
#   property of the CLI invocation, independent of which sandbox
#   feature the resulting derivation later requires).
# - "Sharded" here means: split N registrations across P parallel
#   processes (xargs -P), matching gradle-drvs' own sharding trick of
#   running independent batches concurrently rather than one at a time.

set -euo pipefail

N="${1:-100}"
SHARDS="${SHARDS:-8}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

bench_derivation_add() {
  local i="$1"
  printf '{"args":["-c","touch $out"],"builder":"/bin/sh","env":{"out":"/nix/store/00000000000000000000000000000000-bench-add-%s"},"inputs":{"drvs":{},"srcs":[]},"name":"bench-add-%s","outputs":{"out":{"hashAlgo":"sha256","method":"nar"}},"system":"x86_64-linux","version":4}' "$i" "$i" \
    | nix derivation add --extra-experimental-features "nix-command" >/dev/null 2>&1
}
export -f bench_derivation_add

bench_nix_instantiate() {
  local i="$1"
  nix-instantiate --expr "derivation { name = \"bench-inst-$i\"; system = builtins.currentSystem; builder = \"/bin/sh\"; args = [\"-c\" \"touch \$out\"]; }" >/dev/null 2>&1
}
export -f bench_nix_instantiate

time_sequential() {
  local fn="$1"
  local start end
  start=$(date +%s.%N 2>/dev/null || date +%s)
  for i in $(seq 1 "$N"); do "$fn" "$i"; done
  end=$(date +%s.%N 2>/dev/null || date +%s)
  awk -v s="$start" -v e="$end" 'BEGIN { printf "%.2f", e - s }'
}

time_sharded() {
  local fn="$1"
  local start end
  start=$(date +%s.%N 2>/dev/null || date +%s)
  seq 1 "$N" | xargs -P "$SHARDS" -I{} bash -c "$fn {}"
  end=$(date +%s.%N 2>/dev/null || date +%s)
  awk -v s="$start" -v e="$end" 'BEGIN { printf "%.2f", e - s }'
}

echo "dyndrv registration-overhead benchmark"
echo "N=$N registrations, SHARDS=$SHARDS"
echo ""

echo "=== nix derivation add (builder-rpc-v0's registration primitive) ==="
seq_time=$(time_sequential bench_derivation_add)
per_call=$(awk -v t="$seq_time" -v n="$N" 'BEGIN { printf "%.1f", (t / n) * 1000 }')
echo "sequential: ${seq_time}s total, ${per_call}ms/call"
sharded_time=$(time_sharded bench_derivation_add)
echo "sharded (${SHARDS}-way): ${sharded_time}s total"
echo ""

echo "=== nix-instantiate (recursive-nix's registration primitive) ==="
seq_time=$(time_sequential bench_nix_instantiate)
per_call=$(awk -v t="$seq_time" -v n="$N" 'BEGIN { printf "%.1f", (t / n) * 1000 }')
echo "sequential: ${seq_time}s total, ${per_call}ms/call"
sharded_time=$(time_sharded bench_nix_instantiate)
echo "sharded (${SHARDS}-way): ${sharded_time}s total"
echo ""

echo "Reference: gradle-drvs measured ~1100 sequential 'nix derivation add'"
echo "calls at 2m20s (~127ms/call), dropping to 54s at 16-way sharding --"
echo "these numbers should land in a comparable per-call range."
