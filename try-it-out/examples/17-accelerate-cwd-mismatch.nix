# Regression fixture for the cwd-relative-path-frame mismatch fixed via
# `DYNDRV_INVOCATION_CWD`/`record.cwd` (see `wrapCommand.nix`'s and
# `collectStubs.nix`'s own header comments, and `docs/discovertree-link-
# step-bug.md`'s "Root cause" section for the full story) -- a real,
# common cmake pattern: compile from the package's own root, but LINK
# from a nested `build/` subdirectory (`cd build && cc CMakeFiles/.../a.o
# ... -o exe`). The compile step's own discovered stub gets keyed relative
# to the FIXED package build root (`build/a.o`), while the link step's own
# `args` names it relative to ITS OWN cwd (`a.o`) -- two different strings
# for the identical real file, silently dropping the dependency edge
# without the cwd-frame reconciliation this fixture exists to prove.
#
# Deliberately NOT cmake-driven (no real cmake/ninja dependency needed to
# exercise this) -- a hand-written two-step Makefile recipe reproduces the
# EXACT same cwd-mismatch shape directly: compile `a.c` from the package
# root into `build/a.o`, then `cd build && cc a.o -o prog` (link referring
# to `a.o` relative to `build/`, not `build/a.o` relative to the root).
#
# Run with:
#   try-it-out/run-nix.sh build --no-link -f try-it-out/examples/17-accelerate-cwd-mismatch.nix
{
  pkgs ? (builtins.getFlake (toString ../..)).legacyPackages.${builtins.currentSystem},
  lib ? pkgs.lib,
  dyndrv ? import ../../nix { inherit pkgs lib; },
  nixPackage ? import ../patched-nix.nix { system = pkgs.stdenv.hostPlatform.system; },
  dyndrvShim ? null,
}:

let
  src = pkgs.runCommand "accelerate-cwd-mismatch-src" { } ''
    mkdir -p $out
    cat > $out/a.c <<'EOF'
    int main(void) { return 0; }
    EOF
    cat > $out/Makefile <<'EOF'
    all: prog
    build/a.o: a.c
    	mkdir -p build
    	$(CC) -c a.c -o build/a.o
    prog: build/a.o
    	cd build && $(CC) a.o -o ../prog
    EOF
  '';

  plain = lib.makeOverridable (
    { stdenv }:
    stdenv.mkDerivation {
      pname = "accelerate-cwd-mismatch";
      version = "1.0";
      inherit src;
      installPhase = ''
        mkdir -p $out/bin
        cp prog $out/bin/
      '';
    }
  ) { inherit (pkgs) stdenv; };
in
plain.override {
  stdenv = dyndrv.accelerate.mkAcceleratedStdenv {
    inherit (plain) stdenv;
    inherit nixPackage dyndrvShim;
  };
}
