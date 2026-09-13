# Integration test for task #60: runs `dyndrv-shim`'s compiled `ar`
# entrypoint (via `shim.wrapCommand`'s new `toNodeCompiled` mode) inside
# a real `builder-rpc-v0` sandbox against two PRE-EXISTING deferred
# stubs (mimicking what a shimmed `cc` would have already left behind --
# real usage always shims cc too, so ar's own inputs are always stubs,
# never real materialized files; matching that here rather than using
# an unshimmed cc, which would need extra-store-path scanning ar's own
# decision logic was never designed to need), then resolves the
# resulting chain through the EXISTING bash `shim.collectStubs`
# (unmodified) -- proving the compiled shim's on-disk stub/record
# format is byte-compatible with the proven-correct bash collector.
{
  pkgs ? (builtins.getFlake (toString ../..)).legacyPackages.${builtins.currentSystem},
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

  collectScript = (self.shim.collectStubs { name = "dyndrv-shim-ar-integration"; inherit nixPackage; }).collectScript;

  coreutilsBasename = builtins.baseNameOf "${pkgs.coreutils}";

  # A trivial deferred-compile record + stub, matching exactly what
  # `wrapCommand.nix`'s own `finalizeTail` would have written for a real
  # `cc -c a.c -o a.o` invocation -- just with `cp` of an arbitrary
  # already-store-resident file instead of a real compile, since the
  # point here is testing `ar`'s OWN stub-chaining/rendering (via the
  # NEW compiled shim), not `cc`'s decision logic (a later step). `$out`
  # must appear as its own BARE args entry (not embedded inside a larger
  # shell-command string) -- `collectStubs.nix`'s own `dyndrv_render_member`
  # only substitutes a literal, standalone `"$out"` args element, exactly
  # matching how `arToNode`/`ranlibToNode`'s real records already use it.
  mkFakeCompileRecord = srcPath: builtins.toJSON {
    key = null;
    tool = "${pkgs.coreutils}/bin/cp";
    args = [ srcPath "$out" ];
    srcs = [ coreutilsBasename ];
    setupCmd = null;
  };
in
# `stdenv.mkDerivation`, NOT a raw `derivation{}` -- confirmed by direct
# reproduction that a raw `derivation{}`'s own `/bin/sh` is the HOST's
# real `/bin/sh` (dash on this machine), not bash; `collectStubs.nix`'s
# generated script uses bash-only syntax (`local -A`, `local -n`) that
# only nixpkgs' own stdenv sandbox guarantees (see `wrapCommand.nix`'s
# header comment for the "always bash inside a Nix SANDBOX" claim --
# specific to stdenv's sandbox setup, not `derivation{}` in general).
pkgs.stdenv.mkDerivation {
  name = "dyndrv-shim-ar-integration.drv";
  dontUnpack = true;
  buildPhase = ''
    # A real accelerated build's own buildPhase always runs from a real
    # unpacked SOURCE subdirectory, distinct from $NIX_BUILD_TOP/$TMPDIR
    # -- `dontUnpack = true` here leaves $PWD AS $NIX_BUILD_TOP itself,
    # which collides with `collectStubs.nix`'s own `mktemp -d`-under-
    # $TMPDIR placement (confirmed by direct reproduction: "cp: cannot
    # copy a directory, './.', into itself"). Mirrors that real
    # separation with an explicit subdir.
    mkdir -p build
    cd build
    export PATH="${wrapperDir}/bin:$PATH"

    cat > a.o.record.json <<'EOF'
    ${mkFakeCompileRecord "${pkgs.coreutils}/bin/true"}
    EOF
    printf '#!dyndrv-batch-pending\n%s/a.o.record.json\n' "$PWD" > a.o

    cat > b.o.record.json <<'EOF'
    ${mkFakeCompileRecord "${pkgs.coreutils}/bin/false"}
    EOF
    printf '#!dyndrv-batch-pending\n%s/b.o.record.json\n' "$PWD" > b.o

    ar cr liba.a a.o b.o

    ${collectScript}
  '';
  installPhase = "true";

  requiredSystemFeatures = [ "builder-rpc-v0" ];
  __contentAddressed = true;
  outputHashMode = "text";
  outputHashAlgo = "sha256";
  out = "/nonexistent";
}
