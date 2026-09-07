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
# Backend: `builder-rpc-v0` (via `patched-nix.nix`, matching
# `small-lib-patch-rebuild.sh`'s own pattern) -- `mkAcceleratedStdenv` no
# longer has a `recursive-nix` code path at all (see that file's own
# header for why: `builder-rpc-v0` cannot realize a derivation from
# inside a running script, so the whole accelerator was rebuilt on top of
# `phases.split`'s sandboxed/replay two-derivation wiring instead).
#
# See BASELINE.md for the actual numbers -- this script's OWN historical
# header comment used to assert a specific "accelerated is slower here"
# result, measured under the earlier `recursive-nix`-backed architecture;
# that result is not necessarily representative of the current
# `builder-rpc-v0`/`phases.split` architecture (different registration
# mechanism, different per-unit granularity, an added `phases.split`
# restore step) and should not be assumed to hold without re-measuring.
# The general SHAPE of the tradeoff this script exists to demonstrate
# (metric 2, derivations-rebuilt, improves a lot; metric 1, wall-clock,
# depends on per-file compile time vs. the registration tax) is still the
# right thing to look for -- just verify the actual numbers in
# BASELINE.md rather than trusting a stale inline claim.
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
DYNDRV_ROOT="$(dirname "$SCRIPT_DIR")"

WORKDIR="${DYNDRV_BENCH_DIR:-$(mktemp -d -t dyndrv-real-pkg-bench.XXXXXX)}"
mkdir -p "$WORKDIR"
if [[ -z "${KEEP:-}" ]]; then
  trap 'chmod -R u+w "$WORKDIR" 2>/dev/null; rm -rf "$WORKDIR" || true' EXIT
fi

EXTRA_FEATURES="nix-command ca-derivations dynamic-derivations recursive-nix"
SYSTEM_FEATURES="builder-rpc-v0"

# Same version-matching requirement `small-lib-patch-rebuild.sh` already
# documents: the Nix driving this build and the `nixPackage` passed
# internally to `builder-rpc-v0` registration calls must be the SAME
# fetched build. Resolved once here, exactly the way
# `try-it-out/run-nix.sh`/`small-lib-patch-rebuild.sh` already do.
DYNDRV_NIX=$(nix build --impure --no-link --print-out-paths \
  -f "$DYNDRV_ROOT/patched-nix.nix" '^out')
NIX_BIN="$DYNDRV_NIX/bin/nix"

# `USE_COMPILED_SHIM=1` re-measures against the compiled `rust/
# dyndrv-shim` path (dyndrvShim param) instead of the bash `toNodeBash`/
# `collectStubs` path -- mirrors examples 05/06/07's own `-compiled.nix`
# variants. Resolved once here, same store both variants build against
# (the compiled shim itself is an ordinary derivation, not gated on
# `builder-rpc-v0`).
DYNDRV_SHIM_ARGS=()
if [[ "${USE_COMPILED_SHIM:-0}" = "1" ]]; then
  DYNDRV_SHIM=$(nix build --impure --no-link --print-out-paths \
    -f "$DYNDRV_ROOT/../rust/dyndrv-shim.nix" '^out')
  DYNDRV_SHIM_ARGS=(--argstr dyndrvShimPath "$DYNDRV_SHIM")
fi

echo "dyndrv real-package-patch-rebuild benchmark (nixpkgs freetype)"
echo "workdir=$WORKDIR"
if [[ "${USE_COMPILED_SHIM:-0}" = "1" ]]; then
  echo "shim=compiled ($DYNDRV_SHIM)"
else
  echo "shim=bash (toNodeBash/collectStubs)"
fi
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
  "$NIX_BIN" build \
    --extra-experimental-features "$EXTRA_FEATURES" \
    --extra-system-features "$SYSTEM_FEATURES" \
    --store "local?root=$store" \
    --no-link --print-out-paths \
    --impure --argstr variant "$variant" \
    --argstr nixPackagePath "$DYNDRV_NIX" \
    "${DYNDRV_SHIM_ARGS[@]}" \
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
  # Counts distinct per-unit builder invocations the ACTIVE shim path
  # registers. The bash `toNodeBash`/`collectStubs` path names a solo
  # unit `dyndrv-<flattened-relative-path>` (e.g. `dyndrv-objs_ftglyph_o`
  # for `objs/ftglyph.o`) and a merged batch unit `dyndrv-batch-<key>` --
  # both start with `dyndrv-` (confirmed against a real freetype build
  # log directly, matching `small-lib-patch-rebuild.sh`'s own identical
  # pattern). The COMPILED path (task #85/#86's eager register+symlink
  # redesign) names each derivation after the OUTPUT'S OWN basename
  # instead (`wrapper.rs::run_sandbox_eager_tail`'s own `drv_name`,
  # e.g. `ftglyph.o`) or `dyndrv-batch-<key>` for a module-granularity
  # group (`group.rs`'s own naming, unchanged from the bash path's own
  # convention there) -- so under the compiled path, count `.o.drv`/
  # `.lo.drv` builds (real per-TU compile outputs) plus `dyndrv-batch-`
  # builds, instead of requiring the `dyndrv-` prefix unconditionally.
  if [[ "${USE_COMPILED_SHIM:-0}" = "1" ]]; then
    grep -cE "building '.*(\.o|\.lo)\.drv'|building '.*dyndrv-batch-.*\.drv'" "$WORKDIR/last-build.log" || true
  else
    grep -c "building '.*dyndrv-.*\.drv'" "$WORKDIR/last-build.log" || true
  fi
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
if [[ "${USE_COMPILED_SHIM:-0}" = "1" ]]; then
  # `store-accelerated` is a FRESH alt store -- it has no substituter
  # for the ambient-store-built `DYNDRV_SHIM` path, so a build against
  # it fails outright ("is required, but there is no substituter that
  # can build it") unless that closure is copied in explicitly first.
  # `nixPackagePath`'s own identical `patched-nix.nix` path never hits
  # this because it's a real, cache-substitutable Nix build; the
  # compiled shim is a small, purely local derivation with no cache
  # entry anywhere. Confirmed necessary by direct reproduction.
  mkdir -p "$WORKDIR/store-accelerated"
  "$NIX_BIN" copy --no-check-sigs --to "local?root=$WORKDIR/store-accelerated" "$DYNDRV_SHIM"
fi
echo "-- cold build --"
time_build "$WORKDIR/store-accelerated" "accelerated" 0
acc_cold_time=$(cat "$WORKDIR/last-elapsed")
echo "  ${acc_cold_time}s"

echo "-- patched rebuild (one real source file changed) --"
time_build "$WORKDIR/store-accelerated" "accelerated" 1
acc_patch_time=$(cat "$WORKDIR/last-elapsed")
acc_patch_rebuilt=$(count_dyndrv_builds)
echo "  ${acc_patch_time}s"
echo "  dynamic per-TU derivations rebuilt: $acc_patch_rebuilt (only the patched file's own"
echo "  compiles -- libtool compiles each source twice, once static and once -fPIC for the"
echo "  shared lib, so 2 real per-TU derivations for one changed file; autoconf's own"
echo "  configure-time probes are pure passthrough, never registered as dyndrv derivations"
echo "  at all, so they don't inflate this count)"
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
echo "  accelerated: $acc_patch_rebuilt dynamic derivations (only the changed file's compiles --"
echo "  configure-time probes are pure passthrough, never registered)"
echo "  plain:       1 / 1 (the whole freetype derivation, unconditionally)"
echo ""

echo "=== Metric 3: registration overhead (\"the tax\") ==="
echo "  Not re-measured here -- see try-it-out/benchmarks/registration-overhead.sh"
echo ""

echo "=== Metric 4: break-even guidance ==="
echo "  Whether freetype's real per-file compile time lands past this machine's registration"
echo "  tax is exactly what metric 1's speedup number above answers -- see BASELINE.md for"
echo "  the last-recorded result. Packages with heavier per-TU compile cost (see"
echo "  small-lib-patch-rebuild.sh's"
echo "  LOOPS-scaled fixture for the exact shape of the tradeoff) cross into a real win."
