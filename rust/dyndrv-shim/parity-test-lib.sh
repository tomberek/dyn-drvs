# parity-test-lib.sh: shared plumbing for devshell-parity-test.sh and
# devshell-parity-smalllib-test.sh -- both scripts prove the SAME
# invariant (a TU registered by hand via `nix/lib/shim/devShell.nix`'s
# `Rpc`-mode wrappers lands at the identical content-addressed store
# path a sandboxed `dyndrv.accelerate.mkAcceleratedStdenv` build
# registers for it) against a different real project. Mirrors nixgg's
# own `tests/lib/drv-equiv-common.sh` split (one shared harness, N thin
# fixture scripts) -- see that file for the sibling-project precedent
# this one is modeled on. Meant to be `source`d, not executed.
#
# Env knobs (same names devshell-parity-test.sh already documented):
#   DYNDRV_STORE   root of the sandboxed side's alt store (default
#                  /tmp/dyndrv-store, matching try-it-out/run-nix.sh's
#                  own default)

# parity_build_devshell_wrapper
#
# Builds `shim.devShell`'s own wrapper dir against the AMBIENT store
# (no sandbox, no alt store -- the whole point of `Rpc` mode) and
# echoes its store path. Requires `$DYNDRV_ROOT` in scope.
parity_build_devshell_wrapper() {
  nix build --impure --no-link --print-out-paths --expr '
    let
      pkgs = import <nixpkgs> {};
      lib = pkgs.lib;
      self = import '"$DYNDRV_ROOT"'/nix { inherit pkgs lib; };
      dyndrvShim = import '"$DYNDRV_ROOT"'/rust/dyndrv-shim.nix { inherit pkgs; };
    in (self.shim.devShell { stdenv = pkgs.stdenv; inherit dyndrvShim; autoforce = false; }).wrapperDir
  ' 2>/dev/null
}

# parity_run_native_build <wrapper-dir> <workdir> <src-file>...
#
# Copies each `src-file` into `workdir`, then runs `make` there through
# the devShell wrapper -- registers, never realizes (no autoforce),
# leaving every declared target as a deferred `Rpc`-mode `.drv`
# symlink. Takes an explicit file list (not a directory glob) so a
# fixture directory's own stale build artifacts (`*.o`, a linked
# binary -- gitignored but often present on disk from a prior manual
# `make`) never get copied in and silently short-circuit the build.
# Sets up `$PATH`/`$CC`/`$CXX`/`$AR`/`$RANLIB`/`$DYNDRV_MODE` for the
# `make` subshell only (doesn't leak into the caller's own environment).
parity_run_native_build() {
  local wrapper_dir="$1" workdir="$2"
  shift 2
  cp "$@" "$workdir/"
  (
    cd "$workdir"
    export PATH="$wrapper_dir/bin:$PATH"
    export CC="$wrapper_dir/bin/cc"
    export CXX="$wrapper_dir/bin/c++"
    export AR="$wrapper_dir/bin/ar"
    export RANLIB="$wrapper_dir/bin/ranlib"
    export DYNDRV_MODE=rpc
    make
  )
}

# parity_collect_native_tu_drvs <workdir>
#
# Echoes `<relpath> <drv-basename>` for every `*.o` symlink `make` left
# in `workdir` -- the exact set of per-TU derivations the devShell side
# registered, generic over however many object files the fixture has
# (unlike a hardcoded main.o/util.o pair, this scales to N TUs).
parity_collect_native_tu_drvs() {
  local workdir="$1"
  local f
  for f in "$workdir"/*.o; do
    [ -L "$f" ] || continue
    printf '%s %s\n' "$(basename "$f")" "$(basename "$(readlink "$f")")"
  done
}

# parity_check_sandbox_has_drv <drv-basename>
#
# True (exit 0) iff the SANDBOXED side's own alt store
# (`$DYNDRV_STORE`) contains a real, valid store object at
# `drv-basename` -- a direct `nix path-info` lookup, not an inference
# from "both builds succeeded". See devshell-parity-test.sh's own
# header comment for why this is checked via a direct store lookup
# rather than the outer package's own `--requisites` closure (per-TU
# registrations aren't wired as `inputDrvs`/`inputSrcs` edges of the
# final submitted tree, so they never appear in ITS closure at all,
# even though they're real, independently-registered paths in the
# SAME store).
parity_check_sandbox_has_drv() {
  local drv_basename="$1"
  nix --store "local?root=$DYNDRV_STORE" path-info "/nix/store/$drv_basename" >/dev/null 2>&1
}
