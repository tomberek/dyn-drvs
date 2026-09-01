{ pkgs, lib, self }:

# The narrow, single-output slice of nixgg's `dynDrvStdenv`: overrides
# `stdenv.mkDerivation` so `cc` invocations with a `-c` flag (ordinary
# translation-unit compiles) become per-file dynamically-produced
# derivations via `shim.wrapCommand`, while everything else (linking,
# `ar`, configure-time feature probes, etc.) runs completely normally --
# deliberately scoped to skip multi-output placeholder handling and
# rpath rewriting (deferred to v0.3's general `dynDrvStdenv`-equivalent)
# so it's small enough to actually ship in v0.2.
#
# This is the mechanism the adoption story is built around: point this at
# an existing single-output C/C++ `stdenv.mkDerivation` package and get
# per-translation-unit caching, one line changed, no rewrite required.
#
# HOW IT WORKS: `mkAcceleratedStdenv` wraps the toolchain's `cc` (only --
# not `ar`/the linker, in this v0.2 scope) with `shim.wrapCommand`, whose
# `toNode` parses the real invocation's argv:
#   - if it has NO `-c` flag (a link invocation, or any other cc use that
#     isn't a single-file compile) -> `toNode` returns `null`
#     (PASSTHROUGH), and the wrapper execs the real `cc` unmodified.
#   - if it DOES have `-c` -> `toNode` returns a `drvJson` describing "run
#     the real `cc` with this exact argv, inside its own registered
#     derivation" -- `wrapCommand` registers it, realizes it immediately
#     (recursive-nix backend, per wrapCommand.nix's own verified backend
#     split), and copies the result to wherever the calling build process
#     (make, a Makefile, ninja, ...) expects its `.o` file to appear.
#
# This is `recursive-nix`-only (inherited from `shim.wrapCommand`'s own
# v0.2 scope) -- no patched Nix/`builder-rpc-v0` needed, unlike
# `graph.compile`. `requiredSystemFeatures = [ "recursive-nix" ]` is added
# to the accelerated derivation automatically.
#
# `granularity`: how many translation units share one dynamically-
#   produced derivation (see the plan's own design doc for the full
#   file/module/package tradeoff table) -- v0.2 implements only `"file"`
#   (one derivation per `-c` invocation, the default and the whole point
#   of the feature) and `"package"` (a pure no-op passthrough, useful for
#   bisecting whether acceleration itself is the cause of a build
#   problem). `"module"` batching is follow-on work.
#
# DIRECTORY-STRUCTURE / HEADER-DISCOVERY (added after direct reproduction
# against a real nixpkgs package, openssl): a real multi-directory C
# project routinely compiles with relative `-I` search paths (openssl:
# `-Iapps/include -Iinclude`) and includes local headers only resolvable
# through them (`apps.h`, `openssl/opensslconf.h`, ...). Naively adding
# each positional argv file to the store BY BASENAME (dyndrv's original
# v0.2 approach) destroys that relative structure -- confirmed by direct
# reproduction: openssl's real compiles failed with "No such file or
# directory" on exactly these headers, because a flat, basename-only
# sandbox has nowhere for a relative `-I` to point. The fix, using
# `shim.wrapCommand`'s `discoverTree` mode: before registering each
# compile as its own derivation, run a `cc -M -MG` dependency scan (a
# real GCC/Clang flag, confirmed by direct reproduction: `cc <original
# -I flags> -M -MG <source>` prints a Makefile-style rule listing every
# header the compile would need, using the SAME relative resolution the
# real compile itself would use -- `-MG` additionally tolerates
# not-yet-generated headers rather than erroring, since this is a dry
# run), then stage every positional/discovered RELATIVE path into one
# directory tree (preserving structure) and add it to the store as ONE
# object, so the sandbox's builder can `cp -r` it into its cwd and run
# the ORIGINAL relative-path `cc` invocation completely unmodified.

{
  stdenv,
  granularity ? "file",
}:

assert builtins.elem granularity [ "file" "package" ];

let
  realCc = "${stdenv.cc}/bin/cc";

  # Runs BEFORE `toNode` (inside `wrapCommand`'s wrapper script, per
  # `discoverTree`'s contract -- see wrapCommand.nix's header comment):
  # given the ORIGINAL argv as "$@", prints every RELATIVE header path
  # (one per line) this compile needs beyond what argv already names
  # directly -- sources/objects argv names positionally are already
  # covered by `wrapCommand`'s own default handling, so this only needs
  # to report the DISCOVERED extras. Strips `-c`/`-o <file>` first (this
  # is a dependency scan, not a real compile -- `-c -o x.o -M` would try
  # to write the dependency rule INTO x.o instead of printing it, per
  # GCC's own documented `-M`+`-c`+`-o` interaction, confirmed by direct
  # reproduction). Only the FIRST (source-file) line of `cc -M`'s output
  # matters here; the `<target>.o:` prefix and line-continuation
  # backslashes are stripped so each remaining token is a bare path.
  discoverTree = ''
    args=""
    skip_next=0
    for a in "$@"; do
      if [ "$skip_next" = 1 ]; then skip_next=0; continue; fi
      case "$a" in
        -c) continue ;;
        -o) skip_next=1; continue ;;
        *) args="$args $a" ;;
      esac
    done
    ${realCc} $args -M -MG 2>/dev/null \
      | tr -d '\\' \
      | tr ' ' '\n' \
      | sed '1d' \
      | grep -v '^$' || true
  '';

  # Parses a real `cc` invocation's argv (as `wrapCommand`'s wrapper
  # script sees it -- `$@` WITHOUT the command name itself) and decides
  # whether this is a single-translation-unit compile (`-c` present) that
  # should become its own dynamically-produced derivation, or anything
  # else (link, feature probe, `-E`/`-S` alone, etc.) that should just
  # run normally. Written using only `builtins` (no `lib`) since this
  # text is instantiated standalone inside the sandbox, without
  # `<nixpkgs>` necessarily on `NIX_PATH` there.
  #
  # discoverTree mode (see wrapCommand.nix's header comment): `argv` here
  # is the RAW, unmodified original argv (still relative), and
  # `DYNDRV_TREE_BASENAME` (read via `builtins.getEnv`, the same eval/
  # build-boundary convention `mkArgs.nix` established) names the ONE
  # staged directory-tree input covering every source/header this
  # compile needs. The generated builder `cp -r`s that tree into its cwd
  # and then runs the compile with argv COMPLETELY UNCHANGED, so relative
  # `-I` flags resolve exactly as they would in the real build tree.
  toNode = ''
    argv:
    let
      len = builtins.length argv;
      indices = builtins.genList (i: i) len;

      hasPrefix = prefix: str:
        builtins.substring 0 (builtins.stringLength prefix) str == prefix;

      hasCompileFlag = builtins.elem "-c" argv;

      outIdx = builtins.foldl' (
        acc: i: if acc != (-1) then acc
                else if builtins.elemAt argv i == "-o" then i
                else acc
      ) (-1) indices;

      # Real builds routinely omit `-o` entirely (confirmed by direct
      # reproduction against a real `libtool --mode=compile`-driven
      # autotools build, freetype: every actual `gcc -c foo.c ... -fPIC
      # -DPIC` invocation had no `-o` at all) -- when absent, the
      # compiler's own documented default applies: the source file's own
      # BASENAME (directory stripped), its last extension replaced with
      # `.o`, written to the CURRENT DIRECTORY (confirmed directly: `cc -c
      # sub/foo.c` from cwd `sub/` writes `sub/foo.o`; `cc -c /tmp/bar.cpp`
      # run from `/` FAILS rather than writing to `/tmp/bar.o` -- the
      # source's own directory is never consulted, only cwd). The first
      # positional (non-"-"-prefixed) argv element is treated as "the"
      # source file for this purpose, matching a real single-file `-c`
      # invocation's own shape (multiple positional sources with `-c` and
      # no `-o` is a compiler error in practice, not a case this needs to
      # handle).
      firstSourceIdx = builtins.foldl' (
        acc: i: if acc != (-1) then acc
                else if !(hasPrefix "-" (builtins.elemAt argv i)) && !(i == outIdx + 1) then i
                else acc
      ) (-1) indices;
      stripExt = s:
        let
          parts = builtins.split "\\." s;
          # builtins.split on a literal "." returns [ before ("." | []) after ("." | []) ... ] --
          # taking every other element (indices 0, 2, 4, ...) recovers the
          # dot-separated segments; dropping the last segment and rejoining
          # with "." strips exactly the LAST extension, matching cc's own
          # "last dot" rule (e.g. "foo.tab.c" -> "foo.tab", not "foo").
          segments = builtins.filter builtins.isString parts;
          n = builtins.length segments;
        in
        if n <= 1 then s
        else builtins.concatStringsSep "." (builtins.genList (i: builtins.elemAt segments i) (n - 1));
      implicitOutputFile =
        if firstSourceIdx == (-1) then null
        else (stripExt (builtins.baseNameOf (builtins.elemAt argv firstSourceIdx))) + ".o";
    in
    if !hasCompileFlag || (outIdx == (-1) && implicitOutputFile == null) then
      null
    else
      let
        outputFile = if outIdx != (-1) then builtins.elemAt argv (outIdx + 1) else implicitOutputFile;
        treeBasename = builtins.getEnv "DYNDRV_TREE_BASENAME";

        # Single-quote each argv element for safe embedding in a
        # /bin/sh -c command line (escaping any literal single-quote
        # character using the standard POSIX-shell single-quote escape)
        # -- needed because `builder` is invoked directly, NOT via a
        # shell, so `$out` in `args` would never expand unless the
        # actual command line runs through a shell itself (confirmed by
        # direct reproduction: setting `builder = cc` with a literal
        # `"$out"` string in `args` produced a real compiled object file
        # written to a file literally NAMED "$out" in the build
        # directory, instead of the real output path, since `cc` never
        # interprets `$out` as a shell variable the way `/bin/sh -c`
        # would). Routing through `/bin/sh -c` matches
        # `viaDerivationAdd.nix`/`graph.compile.nix`'s own convention for
        # exactly this reason.
        #
        # NOTE: this whole toNode value is itself a Nix indented string
        # (see the outer `toNode = "double-single-quote" ... ;` binding
        # a few lines up) -- so a literal two-single-quote sequence
        # anywhere in THIS code would be interpreted by the OUTER file
        # as Nix's own indented-string escape mechanism, not as two
        # POSIX-shell quote characters (confirmed by direct
        # reproduction: writing the POSIX escape sequence directly
        # caused "syntax error... expecting ';'" in the OUTER file,
        # since the outer parser saw the doubled quote where it expected
        # the indented string to continue). sq/bs are bound to single
        # single-quote/backslash characters via `builtins.substring` so
        # no doubled single-quote ever appears as a literal sequence in
        # this source file.
        sq = builtins.substring 0 1 "'X";
        bs = builtins.substring 0 1 "\\X";
        shellQuote = s: sq + (builtins.replaceStrings [ sq ] [ (sq + bs + sq + sq) ] s) + sq;
        # When the ORIGINAL argv already has an explicit `-o <file>`, its
        # value must be REPLACED with `$out`, not left in place while a
        # second `-o $out` gets appended afterward -- confirmed by direct
        # reproduction against a real libtool/autoconf probe (`cc -c -o
        # out/conftest2.o conftest.c`): GCC accepts multiple `-o` flags
        # silently and uses the LAST one, so appending `-o $out`
        # unconditionally made the compile write to `$out` (succeeding,
        # `$? = 0`) while the file the CALLING build actually expected
        # (`out/conftest2.o`) was never created at all -- a silent,
        # non-obvious failure mode (the compile "succeeds", but the
        # caller's own subsequent `test -s conftest.o`-style check then
        # fails, misreported by autoconf as "PIC flag doesn't work" with
        # no indication the real cause was dyndrv's own double-`-o` bug).
        # Since `argv`'s own `-o` value is about to be discarded either
        # way (the real, sandboxed compile's output path is `$out`,
        # unrelated to whatever relative path the caller named), this
        # replaces IN PLACE at `outIdx + 1` rather than filtering it out
        # and appending anew, preserving every other flag's original
        # relative position.
        argvForCc =
          if outIdx != (-1) then
            builtins.genList (
              i: if i == outIdx + 1 then "$out" else builtins.elemAt argv i
            ) len
          else
            argv ++ [ "-o" "$out" ];
        quotedArgs = builtins.concatStringsSep " " (
          map (a: if a == "$out" then a else shellQuote a) argvForCc
        );

        # Any argv element can reference a store path NOT already covered
        # by `stdenv.cc`/`coreutils`/the staged tree -- e.g. `-I/nix/store/
        # ...-libpng-.../include`, glued directly onto the flag with no
        # space (confirmed necessary by direct reproduction against a real
        # freetype build: `-I/nix/store/...-libpng-apng-.../include/
        # libpng16` was present correctly in the compile line, but its
        # store path was never in `inputs.srcs`, so the sandbox never
        # mounted it at all -- `#include <png.h>` failed with "No such
        # file or directory" even though the `-I` flag pointing at it was
        # syntactically correct; declaring `stdenv.cc`/`coreutils` alone,
        # as the original v0.2 implementation did, only covers the
        # TOOLCHAIN's own closure, not any OTHER library a real multi-
        # dependency package like freetype links `-I`/`-L`-style flags
        # against). `builtins.match` extracts the `<hash>-<name>` store
        # basename from anywhere inside an argv element's text, whether
        # standalone (`/nix/store/...`) or glued onto a flag
        # (`-I/nix/store/...`) -- deduplicated via a plain attrset-as-set
        # trick since this list can otherwise contain the same input
        # (e.g. one library referenced by multiple `-I`/`-L` flags) many
        # times over.
        extraStorePathsRaw = builtins.filter (x: x != null) (
          map (
            a:
            let
              m = builtins.match ".*(${builtins.storeDir}/([^/\"']+)).*" a;
            in
            if m == null then null else builtins.elemAt m 1
          ) argv
        );
        extraStorePaths = builtins.attrNames (
          builtins.listToAttrs (map (n: { name = n; value = null; }) extraStorePathsRaw)
        );
      in
      {
        drvJson = builtins.toJSON {
          name = "dyndrv-cc-''${builtins.baseNameOf outputFile}";
          system = builtins.currentSystem;
          builder = "/bin/sh";
          args = [
            "-c"
            "${pkgs.coreutils}/bin/cp -r ''${builtins.storeDir}/''${treeBasename}/. . && ${stdenv.cc}/bin/cc ''${quotedArgs}"
          ];
          env.out = builtins.placeholder "out";
          inputs = {
            drvs = { };
            srcs = [
              (builtins.baseNameOf "${pkgs.coreutils}")
              (builtins.baseNameOf "${stdenv.cc}")
              treeBasename
            ] ++ extraStorePaths;
          };
          outputs.out = { method = "nar"; hashAlgo = "sha256"; };
          version = 4;
        };
      }
      // (if outIdx != (-1) then { outputArg = outIdx + 1; } else { outputPath = implicitOutputFile; })
  '';

  ccShim = self.shim.wrapCommand {
    command = "cc";
    realCommand = realCc;
    inherit toNode discoverTree;
  };

  # cc-wrapper's own setup hook exports `CC=gcc` (the real compiler's
  # binary NAME, not "cc") directly into the build environment (confirmed
  # by direct reproduction: a Makefile's `CC ?= cc` has no effect, since
  # `?=` only applies when `CC` is unset, and it's already set) -- so
  # shadowing `cc` alone on `$PATH` doesn't intercept anything a real
  # build actually calls. The wrapper is installed under BOTH names
  # (`cc` and `gcc`) and `CC`/`CXX` are also overridden explicitly, so
  # this works regardless of which name-and-lookup convention a given
  # Makefile/build system happens to use.
  wrapperDir = pkgs.runCommand "dyndrv-cc-shim" { } ''
    mkdir -p $out/bin
    install -Dm755 ${pkgs.writeText "cc" ccShim.wrapperScript} $out/bin/cc
    ln -s cc $out/bin/gcc
  '';
in
if granularity == "package" then
  stdenv
else
  # NOT `stdenv.override` -- `stdenv` is a functor-based attrset with its
  # own bootstrapping machinery (confirmed by direct reproduction: naive
  # `.override` calls fail with "function 'anonymous lambda' called with
  # unexpected argument 'mkDerivation'", since `stdenv`'s underlying
  # function has a fixed, closed argument set unrelated to `mkDerivation`
  # overriding). The correct, general nixpkgs pattern for this
  # ("build helper that behaves like `mkDerivation`, wrapping an existing
  # one") is `lib.extendMkDerivation` -- already used by
  # `mkDynamicDerivation.nix` for the SAME reason. Returning a plain
  # attrset `{ inherit mkDerivation; }` (rather than trying to be a real
  # `stdenv`) is deliberate: callers only ever need `.mkDerivation` from
  # this value (matching the "point this at an existing package, change
  # one line" adoption story -- see `accelerate.wrap`, not yet
  # implemented, which will be sugar for exactly this `.mkDerivation`
  # substitution).
  stdenv
  // {
    mkDerivation = lib.extendMkDerivation {
      constructDrv = stdenv.mkDerivation;
      extendDrvArgs =
        finalAttrs: args:
        {
          nativeBuildInputs = [ wrapperDir ] ++ (args.nativeBuildInputs or [ ]);
          requiredSystemFeatures = (args.requiredSystemFeatures or [ ]) ++ [ "recursive-nix" ];
          CC = "${wrapperDir}/bin/cc";
          CXX = "${wrapperDir}/bin/cc";
        };
    };
  }
