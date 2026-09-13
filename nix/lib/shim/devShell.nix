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
  # See `mkAcceleratedStdenv.nix`'s own `realCxx` doc comment for why a
  # C++ build needs the shim pointed at the REAL `c++`, not `cc` --
  # `stdenv.cc` provides both as distinct binaries, and linking a C++
  # translation unit via plain `cc` fails outright without `-lstdc++`.
  realCxx = "${stdenv.cc}/bin/c++";
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
        # A real sandboxed build sources `stdenv.cc`'s own setup-hook
        # (`gcc-wrapper`'s `nix-support/setup-hook`, `: ${NIX_HARDENING_
        # ENABLE=...}`) automatically, as part of `nativeBuildInputs`
        # processing -- this devShell's own `mkShellNoCC` never does,
        # and NEITHER does `devshell-parity-test.sh`'s own bare
        # subshell (confirmed by direct reading: it sets only `PATH`/
        # `CC`/`CXX`/`AR`/`RANLIB`/`DYNDRV_MODE` before running `make`,
        # no `shellHook`/`nix develop` env-sourcing involved at all) --
        # so without this, `cc.rs`'s own `capture_wrapper_env` (which
        # reads its OWN process environment, not a static default)
        # sees `NIX_HARDENING_ENABLE` genuinely unset here, producing a
        # DIFFERENT registered `.drv` than the identical compile run
        # through a real sandboxed build (confirmed by direct
        # reproduction: `main.o.drv`'s own hash differed by exactly
        # this). Baked into `compiledEnv` (a static, eval-time value
        # written directly into the wrapper SCRIPT'S text, unlike
        # `DYNDRV_REAL_COMMAND` which is also static but per-invocation)
        # rather than relying on the CALLER's ambient shell to set it --
        # this way it's correct regardless of what environment actually
        # invokes this wrapper, matching a real build's OWN
        # `stdenv.cc`-sourced default exactly (`default_hardening_
        # flags_str`, not a hand-copied literal, so it stays correct if
        # the underlying compiler/hardening-flags-set default ever
        # changes). `NIX_ENFORCE_NO_NATIVE`/`NIX_ENFORCE_PURITY`: the
        # OTHER two vars a real build's `stdenv/*/default.nix` always
        # exports unconditionally (`"''${NIX_ENFORCE_PURITY-1}"` --
        # meaning "1" unless something else already set it), so the
        # literal `"1"` here matches that same always-on default.
        #
        # `NIX_CFLAGS_COMPILE`'s own `-frandom-seed=<10-char-prefix-of-
        # $out>` and `NIX_LDFLAGS`'s own `-rpath $out/lib` BOTH derive
        # from the literal TEXT of `$out` at build time -- inside a
        # real sandboxed `phases.split` build, `$out` is THAT file's
        # own fixed placeholder string, `dyndrvPlaceholderOut =
        # "/build/dyndrv-placeholder-out"` (`phases/split.nix`,
        # currently a private `let` binding there, not re-exported --
        # if that string ever changes, update the two literals below
        # to match). Reproduced here as the SAME two literal strings
        # (confirmed byte-for-byte via direct `nix derivation show`
        # comparison against a real sandboxed build's own registered
        # `main.o.drv`: `NIX_CFLAGS_COMPILE=' -frandom-seed=dyndrv-
        # pla'`, `NIX_LDFLAGS='-rpath /build/dyndrv-placeholder-out/
        # lib '`, trailing space included) -- these are ORDINARY
        # static strings, not something that needs a real CA/dynamic-
        # derivations build to compute: `dyndrv-pla` is simply
        # `dyndrvPlaceholderOut`'s own basename truncated to 10 chars,
        # the exact same truncation
        # `pkgs/build-support/setup-hooks/reproducible-builds.sh`
        # performs on `$out` at real build time.
        NIX_CFLAGS_COMPILE = " -frandom-seed=dyndrv-pla";
        NIX_LDFLAGS = "-rpath /build/dyndrv-placeholder-out/lib ";
        NIX_HARDENING_ENABLE = stdenv.cc.default_hardening_flags_str or "";
        NIX_ENFORCE_NO_NATIVE = "1";
        NIX_ENFORCE_PURITY = "1";
        # REQUIRED alongside `NIX_ENFORCE_PURITY` -- `gcc-wrapper`'s own
        # script checks `[[ "${NIX_ENFORCE_PURITY:-}" = 1 && -n
        # "$NIX_STORE" ]]` under `set -u`, with `"$NIX_STORE"`
        # UNGUARDED (no `:-` default) -- so setting `NIX_ENFORCE_PURITY
        # = "1"` without ALSO exporting `NIX_STORE` crashes the real
        # compiler outright ("NIX_STORE: unbound variable") the moment
        # it runs. A real sandboxed build always has `NIX_STORE`
        # ambient; an interactive `nix develop` shell may not
        # (confirmed: this repo's own dev machine did not). This
        # crashed EVERY real `cc -M -MG` header-discovery scan
        # silently (see `cc.rs`'s own `discover_tree`, whose error
        # path returns an empty `Vec` for a failed scan indistinguishably
        # from "no extra headers needed") -- confirmed by direct
        # reproduction: adding `NIX_ENFORCE_PURITY` above without this
        # made `main.cc`'s own `#include "util.h"` vanish from the
        # staged tree entirely, producing a `.drv` missing real header
        # content. `builtins.storeDir` (not a hardcoded `/nix/store`)
        # in case this is ever run against a non-default store dir.
        NIX_STORE = builtins.storeDir;
      } // extraEnv;
    };

  ccShim = mkCompiledShim "cc" realCc {
    DYNDRV_COREUTILS_BASENAME = coreutilsBasename;
    DYNDRV_STDENV_CC_BASENAME = stdenvCcBasename;
  };
  # A SEPARATE shim instance from `ccShim` -- same `command = "cc"`
  # dispatch (`dyndrv-shim`'s own `DYNDRV_TOOL` match has no separate
  # "cxx" case; a C vs. C++ compile's own argv-decision shape is
  # identical), just `realCommand`/`DYNDRV_REAL_COMMAND` pointed at the
  # real `c++` -- mirrors `mkAcceleratedStdenv.nix`'s own `cxxShim`.
  cxxShim = mkCompiledShim "cc" realCxx {
    DYNDRV_COREUTILS_BASENAME = coreutilsBasename;
    DYNDRV_STDENV_CC_BASENAME = stdenvCcBasename;
  };
  arShim = mkCompiledShim "ar" realAr { DYNDRV_BINTOOLS_BASENAME = bintoolsBasename; };
  ranlibShim = mkCompiledShim "ranlib" realRanlib {
    DYNDRV_BINTOOLS_BASENAME = bintoolsBasename;
    DYNDRV_COREUTILS_BASENAME = coreutilsBasename;
  };

  # cc-wrapper's own setup hook exports `CC=gcc`/`CXX=g++` (the real
  # compiler binaries' own bare NAMES) into the shell environment -- so
  # shadowing `cc`/`c++` alone on `$PATH` doesn't intercept `$CC`/`$CXX`-
  # driven builds (same gotcha `mkAcceleratedStdenv.nix`'s own
  # `wrapperDir` comment documents, including the real C++-project bug
  # that surfaced it: linking a C++ TU via the `cc`-only shim -- the
  # ONLY wrapper this devShell installed before this fix -- fails
  # outright without `-lstdc++`, and a plain `CXX="${wrapperDir}/bin/
  # cc"` export pointed the shim at the wrong underlying tool). Installed
  # under `cc`/`gcc` AND `c++`/`g++`, matching that file's convention
  # exactly; `CC`/`CXX` are exported explicitly below, now pointed at
  # their own correct binaries.
  wrapperDir = pkgs.runCommand "dyndrv-shim-devshell-wrapper" { } ''
    mkdir -p $out/bin
    install -Dm755 ${pkgs.writeText "cc" ccShim.wrapperScript} $out/bin/cc
    ln -s cc $out/bin/gcc
    install -Dm755 ${pkgs.writeText "c++" cxxShim.wrapperScript} $out/bin/c++
    ln -s c++ $out/bin/g++
    install -Dm755 ${pkgs.writeText "ar" arShim.wrapperScript} $out/bin/ar
    install -Dm755 ${pkgs.writeText "ranlib" ranlibShim.wrapperScript} $out/bin/ranlib
  '';
in
{
  shellHook = ''
    export PATH="${wrapperDir}/bin:$PATH"
    export CC="${wrapperDir}/bin/cc"
    export CXX="${wrapperDir}/bin/c++"
    export AR="${wrapperDir}/bin/ar"
    export RANLIB="${wrapperDir}/bin/ranlib"
    export DYNDRV_MODE=rpc
    ${lib.optionalString autoforce "export DYNDRV_AUTOFORCE=1"}
  '';

  # Exposed for callers that want to inspect/reuse the wrapper directly
  # (e.g. a test harness) rather than only via `shellHook`'s PATH splice.
  inherit wrapperDir ccShim cxxShim arShim ranlibShim;
}
