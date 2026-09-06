# Integration test for task #61: same fixture as ar-integration-test.nix
# (compiled ar shim + two fake compile stubs), but resolved via the NEW
# compiled `dyndrv-collect` binary instead of the bash `collectStubs.nix`
# collector -- proving the compiled collector produces a correct,
# resolvable final submission end to end.
{
  pkgs ? import <nixpkgs> { },
  self,
  dyndrvShim,
  nixPackage ? pkgs.nix,
}:

let
  realAr = "${pkgs.binutils-unwrapped}/bin/ar";
  bintoolsBasename = builtins.baseNameOf "${pkgs.binutils-unwrapped}";

  arShim = self.shim.wrapCommand {
    command = "ar";
    realCommand = realAr;
    toNode = ''argv: null'';
    toNodeCompiled = dyndrvShim;
    compiledEnv = {
      DYNDRV_REAL_COMMAND = realAr;
      DYNDRV_BINTOOLS_BASENAME = bintoolsBasename;
    };
  };

  wrapperDir = pkgs.runCommand "dyndrv-shim-ar-wrapper" { } ''
    mkdir -p $out/bin
    install -Dm755 ${pkgs.writeText "ar" arShim.wrapperScript} $out/bin/ar
  '';

  coreutilsBasename = builtins.baseNameOf "${pkgs.coreutils}";

  mkFakeCompileRecord = srcPath: builtins.toJSON {
    key = null;
    tool = "${pkgs.coreutils}/bin/cp";
    args = [ srcPath "$out" ];
    srcs = [ coreutilsBasename ];
    setupCmd = null;
  };
in
pkgs.stdenv.mkDerivation {
  name = "dyndrv-shim-collect-integration.drv";
  dontUnpack = true;
  buildPhase = ''
    mkdir -p build
    cd build
    export PATH="${wrapperDir}/bin:${dyndrvShim}/bin:$PATH"
    export NIX_CONFIG='extra-experimental-features = nix-command ca-derivations dynamic-derivations'
    export DYNDRV_COREUTILS_BIN="${pkgs.coreutils}/bin"

    cat > a.o.record.json <<'EOF'
    ${mkFakeCompileRecord "${pkgs.coreutils}/bin/true"}
    EOF
    printf '#!dyndrv-batch-pending\n%s/a.o.record.json\n' "$PWD" > a.o

    cat > b.o.record.json <<'EOF'
    ${mkFakeCompileRecord "${pkgs.coreutils}/bin/false"}
    EOF
    printf '#!dyndrv-batch-pending\n%s/b.o.record.json\n' "$PWD" > b.o

    ar cr liba.a a.o b.o

    dyndrv-collect . dyndrv-shim-collect-integration
  '';
  installPhase = "true";

  requiredSystemFeatures = [ "builder-rpc-v0" ];
  __contentAddressed = true;
  outputHashMode = "text";
  outputHashAlgo = "sha256";
  out = "/nonexistent";
}
