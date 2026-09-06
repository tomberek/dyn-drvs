# `shim.devShell`: a `shellHook` string that installs the SAME
# `dyndrv-shim`-backed `cc`/`ar`/`ranlib` wrappers `mkAcceleratedStdenv`
# builds for its sandboxed phase 1, but pointed at an ordinary,
# unsandboxed `nix develop` shell instead -- `dyndrv-shim` auto-detects
# `Rpc` mode outside a `builder-rpc-v0` sandbox (see `mode.rs`'s own
# `detect()`: no `NIX_REMOTE`+`NIX_BUILD_TOP` pair means "not inside a
# sandboxed derivation build"), registering real derivations over an
# UNRESTRICTED daemon connection instead of deferring.
#
# Because both tails build the identical `Record` -> `Derivation`
# translation (`drv.rs`'s `record_to_derivation`, shared by
# `rpc_tail.rs` and effectively mirrored by `dyndrv-collect`'s own
# per-unit construction), a TU registered by hand in this devShell and
# the SAME TU registered inside a real sandboxed `nix build` land at
# the identical content-addressed store path -- Nix substitutes rather
# than rebuilds. This is the concrete mechanism behind nixgg's own
# "dev-shell and pure-build derivations are interchangeable" property
# (ARCHITECTURE.md's "Corollary"), here falling out of one shared
# Derivation-construction path rather than a separately-maintained
# equivalence test.
#
# `dyndrvShim`: the `rust/dyndrv-shim` package (providing `bin/dyndrv-shim`).
# `stdenv`: supplies the real `cc`/`ar`/`ranlib` binaries to shadow.
# `autoforce`: if true, sets `DYNDRV_AUTOFORCE=1` -- the link/archive
#   step realizes its whole DAG immediately instead of leaving a
#   registered-but-unbuilt stub, mirroring nixgg's own
#   `NIXGG_AUTOFORCE=1`.

{
  pkgs,
  lib,
  self,
}:

{
  stdenv,
  dyndrvShim,
  autoforce ? false,
}:

let
  realCc = "${stdenv.cc}/bin/cc";
  realAr = "${stdenv.cc.bintools.bintools}/bin/ar";
  realRanlib = "${stdenv.cc.bintools.bintools}/bin/ranlib";
  bintoolsBasename = builtins.baseNameOf "${stdenv.cc.bintools.bintools}";
  coreutilsBasename = builtins.baseNameOf "${pkgs.coreutils}";
  stdenvCcBasename = builtins.baseNameOf "${stdenv.cc}";

  mkCompiledShim =
    command: realCommand: extraEnv:
    self.shim.wrapCommand {
      inherit command realCommand;
      # `toNode`/`toNodeBash` are never invoked in `toNodeCompiled` mode,
      # but `toNode` stays required by `wrapCommand`'s own signature.
      toNode = ''argv: null'';
      toNodeCompiled = dyndrvShim;
      compiledEnv = {
        DYNDRV_REAL_COMMAND = realCommand;
      } // extraEnv;
    };

  ccShim = mkCompiledShim "cc" realCc {
    DYNDRV_COREUTILS_BASENAME = coreutilsBasename;
    DYNDRV_STDENV_CC_BASENAME = stdenvCcBasename;
  };
  arShim = mkCompiledShim "ar" realAr { DYNDRV_BINTOOLS_BASENAME = bintoolsBasename; };
  ranlibShim = mkCompiledShim "ranlib" realRanlib {
    DYNDRV_BINTOOLS_BASENAME = bintoolsBasename;
    DYNDRV_COREUTILS_BASENAME = coreutilsBasename;
  };

  # cc-wrapper's own setup hook exports `CC=gcc` (the real compiler's
  # binary NAME, not "cc") into the shell environment -- so shadowing
  # `cc` alone on `$PATH` doesn't intercept `$CC`/`$CXX`-driven builds
  # (same gotcha `mkAcceleratedStdenv.nix`'s own `wrapperDir` comment
  # documents). Installed under both `cc` and `gcc`, matching that file's
  # convention exactly; `CC`/`CXX` are exported explicitly below.
  wrapperDir = pkgs.runCommand "dyndrv-shim-devshell-wrapper" { } ''
    mkdir -p $out/bin
    install -Dm755 ${pkgs.writeText "cc" ccShim.wrapperScript} $out/bin/cc
    ln -s cc $out/bin/gcc
    install -Dm755 ${pkgs.writeText "ar" arShim.wrapperScript} $out/bin/ar
    install -Dm755 ${pkgs.writeText "ranlib" ranlibShim.wrapperScript} $out/bin/ranlib
  '';
in
{
  shellHook = ''
    export PATH="${wrapperDir}/bin:$PATH"
    export CC="${wrapperDir}/bin/cc"
    export CXX="${wrapperDir}/bin/cc"
    export AR="${wrapperDir}/bin/ar"
    export RANLIB="${wrapperDir}/bin/ranlib"
    export DYNDRV_MODE=rpc
    ${lib.optionalString autoforce "export DYNDRV_AUTOFORCE=1"}
  '';

  # Exposed for callers that want to inspect/reuse the wrapper directly
  # (e.g. a test harness) rather than only via `shellHook`'s PATH splice.
  inherit wrapperDir ccShim arShim ranlibShim;
}
