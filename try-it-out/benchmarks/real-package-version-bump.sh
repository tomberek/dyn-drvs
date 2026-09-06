#!/usr/bin/env bash
# real-package-version-bump.sh: same real-package macro benchmark as
# real-package-patch-rebuild.sh (nixpkgs' actual, unmodified `freetype`),
# but with a MULTI-FILE patch touching several unrelated subdirectories,
# simulating what a real upstream point-release bump's diff typically
# looks like (a handful of bugfixes scattered across the source tree, not
# one isolated one-line change).
#
# WHY A SOURCE PATCH, NOT AN ACTUAL FETCH OF TWO REAL RELEASES: confirmed
# directly, this environment (and any similarly sandboxed CI runner) has
# NO network access for uncached fetches -- `nix build` on a `fetchurl`
# for a tarball not already in the local store hangs/times out rather
# than failing fast. A genuine "fetch freetype 2.14.2, then fetch
# freetype 2.14.3, diff the two builds" benchmark is therefore not
# reliably runnable here, and would silently break in any CI environment
# without egress. A source-level patch across several files IS a faithful
# proxy for what a version bump's diff looks like from the BUILD SYSTEM's
# own perspective -- some files change, most don't -- without requiring
# network access; that's the property this benchmark actually needs to
# demonstrate (per-file caching granularity), not "did the exact bytes of
# a real upstream commit apply."
#
# Applies THREE one-line changes across THREE different subdirectories
# (src/base/ftglyph.c, src/truetype/truetype.c, src/base/ftinit.c) --
# still each individually trivial (a comment-only marker, so the actual
# COMPILED OUTPUT is unaffected and this remains purely a caching-
# behavior benchmark, not a correctness test), but spread across the
# tree the way a real bugfix-release diff would be, rather than
# real-package-patch-rebuild.sh's single-file change. Reports the same
# four metrics, so results are directly comparable to that script's own
# single-file numbers -- see BASELINE.md for both side by side.
#
# Backend: `builder-rpc-v0` (via `patched-nix.nix`), same as
# `real-package-patch-rebuild.sh`/`small-lib-patch-rebuild.sh`.
#
# Usage:
#   try-it-out/benchmarks/real-package-version-bump.sh
#
# Env vars:
#   DYNDRV_BENCH_DIR  scratch dir for local stores (default: a fresh
#                     mktemp -d, removed on exit unless KEEP=1)
#   KEEP=1            keep DYNDRV_BENCH_DIR after the run, for inspection

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DYNDRV_ROOT="$(dirname "$SCRIPT_DIR")"

WORKDIR="${DYNDRV_BENCH_DIR:-$(mktemp -d -t dyndrv-real-pkg-verbump.XXXXXX)}"
mkdir -p "$WORKDIR"
if [[ -z "${KEEP:-}" ]]; then
  trap 'chmod -R u+w "$WORKDIR" 2>/dev/null; rm -rf "$WORKDIR" || true' EXIT
fi

EXTRA_FEATURES="nix-command ca-derivations dynamic-derivations recursive-nix"
SYSTEM_FEATURES="builder-rpc-v0"

# Same version-matching requirement `small-lib-patch-rebuild.sh`/
# `real-package-patch-rebuild.sh` already document.
DYNDRV_NIX=$(nix build --impure --no-link --print-out-paths \
  -f "$DYNDRV_ROOT/patched-nix.nix" '^out')
NIX_BIN="$DYNDRV_NIX/bin/nix"

echo "dyndrv real-package-version-bump benchmark (nixpkgs freetype, multi-file patch)"
echo "workdir=$WORKDIR"
echo ""

cat > "$WORKDIR/version-bump.diff" <<'PATCH_EOF'
--- a/src/base/ftglyph.c
+++ b/src/base/ftglyph.c
@@ -1,5 +1,6 @@
 /****************************************************************************
  *
+ * dyndrv version-bump benchmark marker (file 1/3)
  * ftglyph.c
  *
  *   FreeType convenience functions to handle glyphs (body).
--- a/src/truetype/truetype.c
+++ b/src/truetype/truetype.c
@@ -1,5 +1,6 @@
 /****************************************************************************
  *
+ * dyndrv version-bump benchmark marker (file 2/3)
  * truetype.c
  *
  *   FreeType TrueType driver component (body only).
--- a/src/base/ftinit.c
+++ b/src/base/ftinit.c
@@ -1,5 +1,6 @@
 /****************************************************************************
  *
+ * dyndrv version-bump benchmark marker (file 3/3)
  * ftinit.c
  *
  *   FreeType initialization layer (body).
PATCH_EOF

nix_build() {
  local store="$1" variant="$2" withPatch="$3"
  local patchArgs=()
  if [[ "$withPatch" = "1" ]]; then
    patchArgs=(--arg patch "$WORKDIR/version-bump.diff")
  fi
  "$NIX_BIN" build \
    --extra-experimental-features "$EXTRA_FEATURES" \
    --extra-system-features "$SYSTEM_FEATURES" \
    --store "local?root=$store" \
    --no-link --print-out-paths \
    --impure --argstr variant "$variant" \
    --argstr nixPackagePath "$DYNDRV_NIX" \
    "${patchArgs[@]}" \
    -f "$SCRIPT_DIR/real-package-lib.nix"
}

time_build() {
  local store="$1" variant="$2" withPatch="$3"
  local start end
  start=$(date +%s.%N)
  nix_build "$store" "$variant" "$withPatch" >"$WORKDIR/last-build.log" 2>&1
  end=$(date +%s.%N)
  awk -v s="$start" -v e="$end" 'BEGIN { printf "%.2f", e - s }' > "$WORKDIR/last-elapsed"
}

count_dyndrv_builds() {
  # Same convention `real-package-patch-rebuild.sh`/
  # `small-lib-patch-rebuild.sh` already use.
  grep -c "building '.*dyndrv-.*\.drv'" "$WORKDIR/last-build.log" || true
}

echo "=== Plain stdenv.mkDerivation (real nixpkgs freetype) ==="
echo "-- cold build --"
time_build "$WORKDIR/store-plain" "plain" 0
plain_cold_time=$(cat "$WORKDIR/last-elapsed")
echo "  ${plain_cold_time}s"

echo "-- version-bump rebuild (3 files changed across 2 subdirectories) --"
time_build "$WORKDIR/store-plain" "plain" 1
plain_patch_time=$(cat "$WORKDIR/last-elapsed")
echo "  ${plain_patch_time}s (rebuilds the whole derivation)"
echo ""

echo "=== dyndrv.accelerate.mkAcceleratedStdenv (real nixpkgs freetype) ==="
echo "-- cold build --"
time_build "$WORKDIR/store-accelerated" "accelerated" 0
acc_cold_time=$(cat "$WORKDIR/last-elapsed")
echo "  ${acc_cold_time}s"

echo "-- version-bump rebuild (3 files changed across 2 subdirectories) --"
time_build "$WORKDIR/store-accelerated" "accelerated" 1
acc_patch_time=$(cat "$WORKDIR/last-elapsed")
acc_patch_rebuilt=$(count_dyndrv_builds)
echo "  ${acc_patch_time}s"
echo "  dynamic per-TU derivations rebuilt: $acc_patch_rebuilt (3 changed files x 2 compiles"
echo "  each -- libtool compiles every source twice, once static and once -fPIC for the"
echo "  shared lib -- so 6 real per-TU derivations expected for 3 changed files; configure-"
echo "  time probes are pure passthrough, never registered, so they don't inflate this count)"
echo ""

echo "=== Metric 1: rebuild wall-clock (version bump, warm store) ==="
echo "  plain:       ${plain_patch_time}s"
echo "  accelerated: ${acc_patch_time}s"
speedup=$(awk -v p="$plain_patch_time" -v a="$acc_patch_time" 'BEGIN { if (a > 0) printf "%.2f", p / a; else print "n/a" }')
if [[ "$speedup" != "n/a" ]] && awk -v s="$speedup" 'BEGIN { exit !(s < 1) }'; then
  echo "  speedup: ${speedup}x (accelerated is SLOWER here -- see real-package-patch-rebuild.sh's"
  echo "  own header for why: freetype's per-file compile time is small relative to the"
  echo "  per-derivation registration tax, and configure reruns from scratch either way)"
else
  echo "  speedup: ${speedup}x"
fi
echo ""

echo "=== Metric 2: derivations rebuilt vs. total (version-bump rebuild) ==="
echo "  accelerated: $acc_patch_rebuilt dynamic derivations (only the 3 changed files' own"
echo "  compiles, out of ~45 translation units total)"
echo "  plain:       1 / 1 (the whole freetype derivation, unconditionally, regardless of"
echo "  how many or how few files actually changed)"
echo ""

echo "=== Metric 3: registration overhead (\"the tax\") ==="
echo "  Not re-measured here -- see try-it-out/benchmarks/registration-overhead.sh"
echo ""

echo "=== Metric 4: break-even guidance ==="
echo "  Same guidance as real-package-patch-rebuild.sh -- whether THIS machine's per-file"
echo "  compile time clears the registration tax is what metric 1's speedup number answers."
echo "  Comparing THIS script's numbers against real-package-patch-rebuild.sh's own"
echo "  single-file numbers (see BASELINE.md) shows how the win scales with the NUMBER of"
echo "  changed files: metric 2 stays proportional to files actually changed either way,"
echo "  while plain's cost is flat regardless of how many files a real version bump touches."
