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

{
  stdenv,
  granularity ? "file",
}:

assert builtins.elem granularity [ "file" "package" ];

let
  realCc = "${stdenv.cc}/bin/cc";

  # Parses a real `cc` invocation's argv (as `wrapCommand`'s wrapper
  # script sees it -- `$@` WITHOUT the command name itself) and decides
  # whether this is a single-translation-unit compile (`-c` present) that
  # should become its own dynamically-produced derivation, or anything
  # else (link, feature probe, `-E`/`-S` alone, etc.) that should just
  # run normally. Written using only `builtins` (no `lib`) since this
  # text is instantiated standalone inside the sandbox, without
  # `<nixpkgs>` necessarily on `NIX_PATH` there.
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

      isSkippedIdx = i: i == outIdx || i == outIdx + 1;
      keptIndices = builtins.filter (i: !(isSkippedIdx i)) indices;
      keptArgs = map (i: builtins.elemAt argv i) keptIndices;
    in
    if !hasCompileFlag || outIdx == (-1) then
      null
    else
      let
        outputFile = builtins.elemAt argv (outIdx + 1);
        # Nix-store srcs must be bare basenames, not full store paths
        # (confirmed empirically in v0.1/v0.2 -- see viaDerivationAdd.nix/
        # graph.compile.nix's own notes on this). Source/object files
        # named on the command line are the positional (non-"-"-prefixed)
        # arguments among what's kept.
        positional = builtins.filter (a: !(hasPrefix "-" a)) keptArgs;
        inputBasenames = map builtins.baseNameOf positional;
        ccBasename = builtins.baseNameOf "${stdenv.cc}";

        # Single-quote each kept arg for safe embedding in a /bin/sh -c
        # command line (escaping any literal single-quote character using
        # the standard POSIX-shell single-quote escape) -- needed because
        # `builder` is invoked directly, NOT via a shell, so `$out` in `args` would
        # never expand unless the actual command line runs through a
        # shell itself (confirmed by direct reproduction: setting
        # `builder = cc` with a literal `"$out"` string in `args`
        # produced a real compiled object file written to a file NAMED
        # "$out" in the build directory, instead of the real output
        # path, since `cc` never interprets `$out` as a shell variable
        # the way `/bin/sh -c` would). Routing through `/bin/sh -c`
        # matches `viaDerivationAdd.nix`/`graph.compile.nix`'s own
        # convention for exactly this reason.
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
        quotedArgs = builtins.concatStringsSep " " (map shellQuote keptArgs);
      in
      {
        drvJson = builtins.toJSON {
          name = "dyndrv-cc-''${builtins.baseNameOf outputFile}";
          system = builtins.currentSystem;
          builder = "/bin/sh";
          args = [
            "-c"
            "${stdenv.cc}/bin/cc ''${quotedArgs} -o $out"
          ];
          env.out = builtins.placeholder "out";
          inputs = {
            drvs = { };
            srcs = [ ccBasename ] ++ inputBasenames;
          };
          outputs.out = { method = "nar"; hashAlgo = "sha256"; };
          version = 4;
        };
        outputArg = outIdx + 1;
      }
  '';

  ccShim = self.shim.wrapCommand {
    command = "cc";
    realCommand = realCc;
    inherit toNode;
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
