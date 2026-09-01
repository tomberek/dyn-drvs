#!/usr/bin/env bash
# real-package-patch-rebuild.sh: the v0.2 REAL-PACKAGE macro benchmark for
# dyndrv.accelerate.mkAcceleratedStdenv, using nixpkgs' actual `freetype`
# (a real, unmodified nixpkgs C library -- ~45 translation units, libtool/
# autotools, several other libraries as -I/-L build inputs) rather than
# only the synthetic fixture in small-lib-patch-rebuild.sh.
#
# WHY freetype, not openssl: see real-package-lib.nix's header comment --
# openssl bakes its own outer `$out` path into every compile flag, which
# defeats per-TU caching structurally on any patch (a real, understood
# limitation requiring v0.3's builder-rpc-v0 + phases.split architecture,
# not a v0.2 bug). freetype doesn't have this problem and demonstrates the
# same real-package-scale value within v0.2's current scope.
#
# Applies a one-line comment-only patch to a real freetype source file
# (src/base/ftglyph.c), builds once plain and once accelerated, and
# reports the same four metrics as small-lib-patch-rebuild.sh -- but
# against nixpkgs' actual, unmodified freetype recipe, its actual libtool-
# generated build commands, and its actual multi-library dependency set,
# not a fixture built specifically to exercise dyndrv favorably.
#
# HONEST RESULT, stated plainly (per the plan's mandate not to cherry-pick
# only the favorable case): at freetype's real scale (~45 files, modest
# per-file compile time), the accelerated patched rebuild is typically
# SLOWER in wall-clock than the plain rebuild -- confirmed directly. The
# per-derivation registration/realise tax (~50-80ms/call, see
# registration-overhead.sh) dominates when there's this little compile
# work per file, and `configure` reruns from scratch on every patch either
# way (no ccache/autoconf-cache layer in either variant), adding a fixed
# cost neither side avoids. What DOES improve, and improves a lot, is
# metric 2 (derivations rebuilt): only the ONE patched file's compiles
# (libtool compiles each source twice -- once static, once `-fPIC` for the
# shared lib -- so 2 real per-TU derivations) plus the 2 unavoidable
# configure-time conftest probes rebuild, vs. the plain build's single
# derivation recompiling everything. This is the honest, real-package
# confirmation of small-lib-patch-rebuild.sh's own documented break-even
# finding: dyndrv's per-TU win is real and scales with per-file compile
# cost, but is not automatically a wall-clock win on every package size.
#
# Usage:
#   try-it-out/benchmarks/real-package-patch-rebuild.sh
#
# Env vars:
#   DYNDRV_BENCH_DIR  scratch dir for local stores (default: a fresh
#                     mktemp -d, removed on exit unless KEEP=1)
#   KEEP=1            keep DYNDRV_BENCH_DIR after the run, for inspection

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORKDIR="${DYNDRV_BENCH_DIR:-$(mktemp -d -t dyndrv-real-pkg-bench.XXXXXX)}"
mkdir -p "$WORKDIR"
if [[ -z "${KEEP:-}" ]]; then
  trap 'chmod -R u+w "$WORKDIR" 2>/dev/null; rm -rf "$WORKDIR" || true' EXIT
fi

EXTRA_FEATURES="nix-command ca-derivations dynamic-derivations recursive-nix"
SYSTEM_FEATURES="recursive-nix"

echo "dyndrv real-package-patch-rebuild benchmark (nixpkgs freetype)"
echo "workdir=$WORKDIR"
echo ""

cat > "$WORKDIR/patch.diff" <<'PATCH_EOF'
--- a/src/base/ftglyph.c
+++ b/src/base/ftglyph.c
@@ -1,5 +1,6 @@
 /****************************************************************************
  *
+ * dyndrv benchmark patch marker
  * ftglyph.c
  *
  *   FreeType convenience functions to handle glyphs (body).
PATCH_EOF

nix_build() {
  local store="$1" variant="$2" withPatch="$3"
  local patchArgs=()
  if [[ "$withPatch" = "1" ]]; then
    patchArgs=(--arg patch "$WORKDIR/patch.diff")
  fi
  nix build \
    --extra-experimental-features "$EXTRA_FEATURES" \
    --extra-system-features "$SYSTEM_FEATURES" \
    --store "local?root=$store" \
    --no-link --print-out-paths \
    --impure --argstr variant "$variant" \
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
  grep -c "building '.*dyndrv-cc-.*\.drv'" "$WORKDIR/last-build.log" || true
}

echo "=== Plain stdenv.mkDerivation (real nixpkgs freetype) ==="
echo "-- cold build --"
time_build "$WORKDIR/store-plain" "plain" 0
plain_cold_time=$(cat "$WORKDIR/last-elapsed")
echo "  ${plain_cold_time}s"

echo "-- patched rebuild (one real source file changed) --"
time_build "$WORKDIR/store-plain" "plain" 1
plain_patch_time=$(cat "$WORKDIR/last-elapsed")
echo "  ${plain_patch_time}s (rebuilds the whole derivation)"
echo ""

echo "=== dyndrv.accelerate.mkAcceleratedStdenv (real nixpkgs freetype) ==="
echo "-- cold build --"
time_build "$WORKDIR/store-accelerated" "accelerated" 0
acc_cold_time=$(cat "$WORKDIR/last-elapsed")
echo "  ${acc_cold_time}s"

echo "-- patched rebuild (one real source file changed) --"
time_build "$WORKDIR/store-accelerated" "accelerated" 1
acc_patch_time=$(cat "$WORKDIR/last-elapsed")
acc_patch_rebuilt=$(count_dyndrv_builds)
echo "  ${acc_patch_time}s"
echo "  dynamic per-TU derivations rebuilt: $acc_patch_rebuilt (2 unavoidable configure-time"
echo "  conftest probes + 2 real compiles of the patched file -- libtool compiles each"
echo "  source twice, once static and once -fPIC for the shared lib)"
echo ""

echo "=== Metric 1: rebuild wall-clock (patched, warm store) ==="
echo "  plain:       ${plain_patch_time}s"
echo "  accelerated: ${acc_patch_time}s"
speedup=$(awk -v p="$plain_patch_time" -v a="$acc_patch_time" 'BEGIN { if (a > 0) printf "%.2f", p / a; else print "n/a" }')
if [[ "$speedup" != "n/a" ]] && awk -v s="$speedup" 'BEGIN { exit !(s < 1) }'; then
  echo "  speedup: ${speedup}x (accelerated is SLOWER here -- see script header: freetype's"
  echo "  per-file compile time is small relative to the per-derivation registration tax,"
  echo "  and configure reruns from scratch on either side either way)"
else
  echo "  speedup: ${speedup}x"
fi
echo ""

echo "=== Metric 2: derivations rebuilt vs. total (patched rebuild) ==="
echo "  accelerated: $acc_patch_rebuilt dynamic derivations (only the changed file's compiles"
echo "  + unavoidable configure probes)"
echo "  plain:       1 / 1 (the whole freetype derivation, unconditionally)"
echo ""

echo "=== Metric 3: registration overhead (\"the tax\") ==="
echo "  Not re-measured here -- see try-it-out/benchmarks/registration-overhead.sh"
echo ""

echo "=== Metric 4: break-even guidance ==="
echo "  freetype's real per-file compile time is on the wrong side of break-even for THIS"
echo "  machine's registration tax -- confirmed directly, and reported honestly (see script"
echo "  header). Packages with heavier per-TU compile cost (see small-lib-patch-rebuild.sh's"
echo "  LOOPS-scaled fixture for the exact shape of the tradeoff) cross into a real win."
