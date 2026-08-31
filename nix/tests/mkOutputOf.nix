# dyndrv's own port of nix-src's `eval-outputOf.sh` oracle test's core
# property (see ../../tests/oracle/eval-outputOf.sh, `testStaticHello`/
# `testDynamicHello`): for both a plain and a dynamically-produced
# derivation, `drv.outPath` must equal
# `builtins.outputOf (unsafeDiscardOutputDependency drv.drvPath) "out"` --
# and dyndrv.mkOutputOf must reproduce that equality without the caller
# ever touching `unsafeDiscardOutputDependency` directly.
#
# Pure eval-time assertions -- no build required, so this runs on any Nix
# with `dynamic-derivations` enabled, no recursive-nix/builder-rpc-v0
# needed. Run with:
#   nix-instantiate --eval --extra-experimental-features "dynamic-derivations ca-derivations" \
#     --strict --json nix/tests/mkOutputOf.nix

{ pkgs, lib, dyndrv }:

let
  plain = pkgs.runCommand "dyndrv-test-plain" { } "touch $out";

  # A CA derivation whose output is another derivation's .drv file --
  # the same shape as nix-src's own text-hashed-output.nix `producingDrv`.
  producingDrv = pkgs.stdenv.mkDerivation {
    name = "dyndrv-test-producing.drv";
    dontUnpack = true;
    __contentAddressed = true;
    outputHashMode = "text";
    outputHashAlgo = "sha256";
    buildPhase = ''
      runHook preBuild
      cp ${builtins.unsafeDiscardOutputDependency plain.drvPath} $out
      runHook postBuild
    '';
    installPhase = "true";
  };

  # Oracle property 1 (testStaticHello): dyndrv.mkOutputOf on a plain
  # derivation must equal that derivation's own outPath.
  staticEqual = plain.outPath == dyndrv.mkOutputOf plain "out";

  # Oracle property 2 (testDynamicHello): dyndrv.mkOutputOf applied TWICE
  # -- once to resolve the producing drv's own output (which is itself a
  # .drv), once more to resolve THAT drv's output -- must equal what
  # `outputOf producingDrv.outPath "out"` gives directly.
  dynamicA = builtins.outputOf producingDrv.outPath "out";
  dynamicB = dyndrv.mkOutputOf (dyndrv.mkOutputOf producingDrv "out") "out";
  dynamicEqual = dynamicA == dynamicB;
in
{
  inherit staticEqual dynamicEqual;
  pass = staticEqual && dynamicEqual;
}
