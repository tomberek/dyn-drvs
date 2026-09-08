# real-package-bench-lib.sh: shared plumbing for real-package-patch-rebuild.sh
# and real-package-version-bump.sh -- both scripts build the same real
# nixpkgs `freetype` twice (plain vs. `dyndrv.accelerate.mkAcceleratedStdenv`)
# through `real-package-lib.nix`, only the patch content and the reported
# prose differ. Meant to be `source`d, not run directly -- expects
# `SCRIPT_DIR`/`DYNDRV_ROOT`/`WORKDIR` to already be set by the caller.

EXTRA_FEATURES="nix-command ca-derivations dynamic-derivations recursive-nix"
SYSTEM_FEATURES="builder-rpc-v0"

# Same version-matching requirement `small-lib-patch-rebuild.sh` already
# documents: the Nix driving this build and the `nixPackage` passed
# internally to `builder-rpc-v0` registration calls must be the SAME
# fetched build. Resolved once here, exactly the way
# `try-it-out/run-nix.sh` already does.
DYNDRV_NIX=$(nix build --impure --no-link --print-out-paths \
  -f "$DYNDRV_ROOT/patched-nix.nix" '^out')
NIX_BIN="$DYNDRV_NIX/bin/nix"

# `USE_COMPILED_SHIM=1` re-measures against the compiled `rust/
# dyndrv-shim` path (dyndrvShim param) instead of the bash `toNodeBash`/
# `collectStubs` path -- mirrors examples 05/06/07's own `dyndrvShim`
# param. Resolved once here, same store both variants build against (the
# compiled shim itself is an ordinary derivation, not gated on
# `builder-rpc-v0`).
DYNDRV_SHIM_ARGS=()
if [[ "${USE_COMPILED_SHIM:-0}" = "1" ]]; then
  DYNDRV_SHIM=$(nix build --impure --no-link --print-out-paths \
    -f "$DYNDRV_ROOT/../rust/dyndrv-shim.nix" '^out')
  DYNDRV_SHIM_ARGS=(--argstr dyndrvShimPath "$DYNDRV_SHIM")
fi

print_shim_banner() {
  if [[ "${USE_COMPILED_SHIM:-0}" = "1" ]]; then
    echo "shim=compiled ($DYNDRV_SHIM)"
  else
    echo "shim=bash (toNodeBash/collectStubs)"
  fi
}

nix_build() {
  local store="$1" variant="$2" patchFile="$3"
  local patchArgs=()
  if [[ -n "$patchFile" ]]; then
    patchArgs=(--arg patch "$patchFile")
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
  local store="$1" variant="$2" patchFile="$3"
  local start end
  start=$(date +%s.%N)
  nix_build "$store" "$variant" "$patchFile" >"$WORKDIR/last-build.log" 2>&1
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

# `store-accelerated` is a FRESH alt store -- it has no substituter for
# the ambient-store-built `DYNDRV_SHIM` path, so a build against it fails
# outright ("is required, but there is no substituter that can build it")
# unless that closure is copied in explicitly first. `nixPackagePath`'s
# own identical `patched-nix.nix` path never hits this because it's a
# real, cache-substitutable Nix build; the compiled shim is a small,
# purely local derivation with no cache entry anywhere. Confirmed
# necessary by direct reproduction.
copy_compiled_shim_if_needed() {
  local store="$1"
  if [[ "${USE_COMPILED_SHIM:-0}" = "1" ]]; then
    mkdir -p "$store"
    "$NIX_BIN" copy --no-check-sigs --to "local?root=$store" "$DYNDRV_SHIM"
  fi
}
