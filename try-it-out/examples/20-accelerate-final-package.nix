# Regression fixture for task #133: `mkAcceleratedStdenv`'s own
# `mkDerivation` must inject `finalAttrs.finalPackage`, matching real
# nixpkgs `stdenv.mkDerivation`'s `make-derivation.nix`'s identical
# mechanism -- see `mkAcceleratedStdenv.nix`'s own `finalPackage` header
# comment for the full rationale. Before the fix: referencing
# `finalAttrs.finalPackage` inside a `finalAttrs: {...}`-style call
# failed at EVAL time with "attribute 'finalPackage' missing", before
# phase 1 ever ran -- confirmed against real, unmodified openssl, whose
# own recipe reads `finalAttrs.finalPackage.doCheck` at 3 call sites.
#
# Run with:
#   try-it-out/run-nix.sh build --no-link -f try-it-out/examples/20-accelerate-final-package.nix
{
  pkgs ? (builtins.getFlake (toString ../..)).legacyPackages.${builtins.currentSystem},
  lib ? pkgs.lib,
  dyndrv ? import ../../nix { inherit pkgs lib; },
  nixPackage ? import ../patched-nix.nix { system = pkgs.stdenv.hostPlatform.system; },
  dyndrvShim ? null,
}:

let
  src = pkgs.runCommand "accelerate-final-package-src" { } ''
    mkdir -p $out
    cat > $out/main.c <<'EOF'
    int main(void) { return 0; }
    EOF
    cat > $out/Makefile <<'EOF'
    all: prog
    prog: main.c
    	$(CC) main.c -o prog
    EOF
  '';

  accelerated = dyndrv.accelerate.mkAcceleratedStdenv {
    inherit (pkgs) stdenv;
    inherit nixPackage dyndrvShim;
  };
in
accelerated.mkDerivation (
  finalAttrs: {
    pname = "accelerate-final-package";
    version = "1.0";
    inherit src;
    # The exact shape real openssl reads at 3 call sites --
    # `finalAttrs.finalPackage.doCheck` -- referencing the derivation's
    # OWN eventual `doCheck` value through the self-referential
    # `finalPackage` attribute, not `finalAttrs.doCheck` directly (which
    # wouldn't exercise this bug: `finalAttrs` itself always has every
    # attribute the CALL supplied; only `.finalPackage` -- the
    # constructed DERIVATION reflecting back on itself -- was ever
    # missing).
    postPatch = if finalAttrs.finalPackage.doCheck then "" else "";
    installPhase = ''
      mkdir -p $out/bin
      cp prog $out/bin/
    '';
  }
)
