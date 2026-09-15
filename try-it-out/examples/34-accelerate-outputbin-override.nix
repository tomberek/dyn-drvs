# Regression fixture for the libpng/libtasn1-overlay-PR bug: a package
# whose real recipe sets `outputBin`/`outputMan`/`outputDev` to an
# EXPLICIT LITERAL value (not left to stdenv's own fallback-to-`"out"`
# default) crashes at phase 1 setup, before any real compile runs --
# see `nix/lib/phases/split.nix`'s own header comment on
# `outputBin`/`outputMan`/`outputDev` for the full rationale, and
# `docs/split-outputbin-override-bug.md` for the original writeup.
#
# `phases.split`'s `sandboxedDrv` forces phase 1 to `outputs = [ "out" ]`
# (correct: phase 1 can only ever produce ONE `.drv`-suffixed output),
# but (before this fix) never cleared a LITERAL `outputBin = "dev";`
# override the caller's own `sandboxed` attrset already set -- it passed
# straight through the `//` merge unchanged. Inside phase 1's sandbox,
# nixpkgs' own `multiple-outputs.sh` sees `outputBin` is ALREADY
# non-empty (`"dev"`) and skips its own fallback-to-`"out"` logic
# entirely, then `_overrideFirst outputMan "man" "$outputBin"` expands
# to `_assignFirst outputMan "man" "dev"` -- looking for a non-empty
# `$man` or `$dev` env var, neither of which phase 1 ever exports (only
# `$out`) -- and crashes outright BEFORE `configurePhase` even starts:
# `_assignFirst: could not find a non-empty variable whose name to
# assign to outputMan.`
#
# This fixture reproduces the exact shape directly: a 3-output
# (`out`/`dev`/`man`) package with `outputBin = "dev";` set explicitly,
# matching real nixpkgs `libpng`/`libtasn1`'s own recipes -- confirmed
# failing before the fix (identical `_assignFirst` error) and passing
# after.
#
# Run with:
#   try-it-out/run-nix.sh build --no-link -f try-it-out/examples/34-accelerate-outputbin-override.nix
{
  pkgs ? (builtins.getFlake (toString ../..)).legacyPackages.${builtins.currentSystem},
  lib ? pkgs.lib,
  dyndrv ? import ../../nix { inherit pkgs lib; },
  nixPackage ? import ../patched-nix.nix { system = pkgs.stdenv.hostPlatform.system; },
  dyndrvShim ? null,
}:

let
  src = pkgs.runCommand "accelerate-outputbin-override-src" { } ''
    mkdir -p $out
    cat > $out/lib.c <<'EOF'
    int helper(void) { return 1; }
    EOF
    cat > $out/Makefile <<'EOF'
    all: liboutputbin.a
    lib.o: lib.c
    	$(CC) -c lib.c -o lib.o
    liboutputbin.a: lib.o
    	$(AR) cr liboutputbin.a lib.o
    install: all
    	mkdir -p $(INSTALL_DEV)/lib $(INSTALL_MAN)/share/man
    	cp liboutputbin.a $(INSTALL_DEV)/lib/
    	echo "fake man page" > $(INSTALL_MAN)/share/man/outputbin.1
    EOF
  '';

  plain = lib.makeOverridable (
    { stdenv }:
    stdenv.mkDerivation {
      pname = "accelerate-outputbin-override";
      version = "1.0";
      inherit src;
      outputs = [ "out" "dev" "man" ];
      outputBin = "dev";
      installFlags = [ "INSTALL_DEV=$(dev)" "INSTALL_MAN=$(man)" ];
    }
  ) { inherit (pkgs) stdenv; };
in
plain.override {
  stdenv = dyndrv.accelerate.mkAcceleratedStdenv {
    inherit (plain) stdenv;
    inherit nixPackage dyndrvShim;
  };
}
