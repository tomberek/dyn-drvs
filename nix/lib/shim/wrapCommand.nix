{ pkgs, lib, self }:

# Intercepts a toolchain command on `$PATH` (e.g. `cc`) so that, instead of
# running immediately, each invocation either registers itself as a
# dynamically-produced derivation and is realized immediately
# ("materialize"), or defers to a batch-pending stub resolved later by
# `shim.wrapArchiver` ("defer") -- decided PER-INVOCATION by `toNode`'s
# own return shape (see below), not by a single setting for the whole
# shim. `accelerate.mkAcceleratedStdenv` is built from this.
#
# v0.2 SCOPE: "materialize" is `recursive-nix`-only, verified by reading
# Nix's own `daemon.cc:performOp` connection-mode allowlist:
#   - `builder-rpc-v0` ("RecursiveSubmitted" connections) are restricted to
#     exactly `AddToStore*`/`SubmitOutput`/`AddTempRoot`/`IsValidPath` --
#     `BuildPaths`/`QueryMissing` are absent and rejected outright. A
#     builder-rpc-v0 shim can register a node but can never realize it or
#     block on its result mid-script -- "materialize" is structurally
#     impossible there.
#   - `recursive-nix` has its own `RestrictedStore`/`RestrictedBuilder`
#     wrapper that DOES implement `buildPaths`/realization, gated by an
#     `isAllowed` per-path check (input closure, or previously added via
#     a prior recursive-Nix call).
#
# "defer" (write a stub instead of blocking, matching nixgg's `drvref`/
# `batchpending` pattern) works under EITHER backend since it never calls
# BuildPaths itself. Instead of registering+realizing immediately, the
# wrapper writes a small stub FILE (never a symlink -- see `batchStub.nix`
# for why) at the expected output path and exits 0 immediately, with a
# JSON record of everything needed to compile this invocation later
# alongside it. This satisfies a calling build tool's `test -e`
# prerequisite check without any compile or registration having happened
# yet. Nothing in `wrapCommand` itself ever resolves a deferred stub --
# that's `shim.wrapArchiver`'s job.
#
# `command`: the command name being intercepted (e.g. "cc") -- informational,
#   used only in error messages; callers install the returned script at
#   `<wrapperDir>/bin/<command>` themselves.
# `realCommand`: absolute path to the real command this wrapper shadows.
#   Used both for passthrough (see `toNode` below) and, in principle, by a
#   `toNode` expression that wants to invoke the real compiler itself
#   inside the registered derivation's own builder.
# `toNode`: a Nix expression STRING, `argv: { drvJson, outputArg | outputPath }
#   | { defer = { record }; outputArg | outputPath } | null`:
#   Returning `null` (a PASSTHROUGH) skips registration/realization
#   entirely and execs `realCommand` directly with the original argv --
#   this is how `accelerate.mkAcceleratedStdenv` tells `cc`'s link
#   invocations (no `-c` flag) to run normally, while only `-c` compile
#   invocations get intercepted; `wrapCommand` itself doesn't know or care
#   which invocations should be accelerated, that policy lives entirely in
#   the caller-supplied `toNode`.
#   Otherwise, `toNode` returns:
#     - `drvJson`: a `nix derivation add`-shaped attrset, PRE-SERIALIZED
#       via `builtins.toJSON` (i.e. `drvJson = builtins.toJSON {...};`,
#       a STRING, not a nested attrset -- same schema as
#       `viaDerivationAdd.nix`/`graph.compile`'s per-node `mkDrv`)
#       describing what this ONE invocation should actually do (typically
#       the same command, run for real, inside the registered
#       derivation's own builder). MUST be pre-serialized, not a nested
#       attrset: `nix-instantiate --eval --json` (without `--strict`)
#       fails with "cannot convert a thunk to JSON" on any attrset
#       containing a `builtins.toJSON`-produced value -- the fix (used by
#       `wrapperScript` below) is `--eval --strict --json` together.
#       Mutually exclusive with `defer` below -- `wrapCommand` reads the
#       returned value's own shape at runtime to decide
#       materialize-vs-defer, so ONE shim instance can freely mix both
#       across different invocations.
#     - `defer` (mutually exclusive with `drvJson` above): `{ record }`.
#       `record`: a PRE-SERIALIZED (`builtins.toJSON {...}`) STRING, same
#         "must be pre-serialized" reasoning as `drvJson` above, carrying
#         everything `wrapArchiver` needs to compile this member for
#         real, later, plus its own batch-group `key` as one of its
#         fields (a plain string, e.g. a directory name -- `wrapArchiver`
#         only combines records sharing the exact same `key` into one
#         derivation). `wrapCommand` never inspects `record`'s contents --
#         it's opaque here, written to a record file verbatim and left
#         for `wrapArchiver` to read back later.
#     - `outputArg`: the index into `argv` naming the file path the
#       CALLING build tool expects to exist after this command returns.
#       `argv` is `$@` as the wrapper script sees it, WITHOUT the command
#       name itself (i.e. NOT including `$0`) -- so for `cc -c foo.c -o
#       foo.o`, `argv = ["-c" "foo.c" "-o" "foo.o"]` and `outputArg = 3`
#       names `foo.o` (index 3, zero-based). In `materialize` mode, the
#       wrapper copies the realized derivation's real output there; in
#       `defer` mode, it writes a batch-pending stub there instead --
#       either way, the outer build process sees an ordinary file at the
#       path it asked for. Mutually exclusive with `outputPath` below --
#       supply exactly one.
#     - `outputPath` (ALTERNATIVE to `outputArg`): a literal RELATIVE path
#       string, for invocations with no `-o` at all -- a real, common
#       case: `libtool --mode=compile` invokes the real compiler as
#       `cc -c foo.c ... -fPIC -DPIC`, with no `-o` flag, relying on the
#       compiler's own documented default (source basename, extension
#       stripped, `.o` appended, written to the CURRENT DIRECTORY
#       regardless of the source file's own directory). Since no argv
#       index names this path, `toNode` must compute it itself (see
#       `accelerate/mkAcceleratedStdenv.nix`) and return it directly.
#   Instantiated once PER INVOCATION with `argv` bound to this call's
#   actual arguments (a JSON array of strings, crossing the eval->build
#   boundary the same way `viaNixInstantiate`'s own `args` does).
# `nixPackage`: the Nix to run `nix derivation add`/`nix-store --realise`
#   with, inside the sandbox -- for `recursive-nix` this may just be
#   `pkgs.nix`.
# `discoverTree`: OPTIONAL bash script TEXT, run as `bash -c "$discoverTree"
#   -- "$@"` with the ORIGINAL compiler argv as its own positional params.
#   Exists for compilers whose real invocations depend on RELATIVE `-I`
#   search paths across a multi-directory source tree -- the default
#   per-file, flatten-to-basename rewrite below can't support this, since
#   flattening destroys the relative directory structure `-I` depends on.
#   Must print every RELATIVE path (sources AND headers, one per line)
#   this invocation needs beyond argv's own positional files -- typically
#   the output of a `cc -M -MG`-style dependency scan (see
#   `accelerate/mkAcceleratedStdenv.nix`). When set:
#     - the old per-file "rewrite relative paths to their own store path"
#       behavior is SKIPPED entirely (it would destroy the relative
#       structure this mode exists to preserve);
#     - every relative file argv already names, PLUS every path
#       `discoverTree` prints, is staged into ONE scratch directory that
#       mirrors their original relative layout, added to the store as a
#       SINGLE unit (`nix store add`, which preserves directory structure,
#       unlike `nix store add-file`), and its basename exported as
#       `DYNDRV_TREE_BASENAME` -- `toNode` reads this via
#       `builtins.getEnv "DYNDRV_TREE_BASENAME"` to build a `drvJson`
#       whose builder script `cp -r`s that ONE tree into its cwd, then
#       runs the REAL command with argv UNCHANGED (still relative)
#       against that copied tree;
#     - `argv` as seen by `toNode` is therefore the RAW, unmodified
#       original argv in this mode (NOT rewritten to absolute store
#       paths) -- `toNode` must reference `inputs.srcs = [ treeBasename ]`
#       (one directory input), not per-file basenames, when `discoverTree`
#       is active.

{
  command,
  realCommand,
  toNode,
  nixPackage ? pkgs.nix,
  discoverTree ? null,
}:

let
  inherit (self.shim.batchStub) writeStubFn;

  # Resolves `$outputPath`/`$hasDefer`/`$payload` from `$node`/`$argvJson`
  # in ONE combined `jq` call -- shared by both `wrapperScript` variants
  # below, immediately before `finalizeTail`. This script runs on EVERY
  # intercepted command invocation during a real build, so collapsing
  # what would otherwise be 3 separate `jq` spawns into 1 matters here.
  resolveNodeFields = ''
    { IFS= read -r hasDefer; IFS= read -r outputPath; IFS= read -r payload; } < <(
      printf '%s' "$node" | ${pkgs.jq}/bin/jq -r --argjson argv "$argvJson" '
        (has("outputArg")) as $hasArg |
        (if $hasArg then $argv[.outputArg] else .outputPath end) as $outputPath |
        (has("defer")) as $hasDefer |
        (if $hasDefer then .defer.record else .drvJson end) as $payload |
        ($hasDefer | tostring), $outputPath, $payload
      '
    )
  '';

  # Shared "finalize" tail, appended after BOTH wrapperScript variants
  # have resolved `$outputPath`/`$hasDefer`/`$payload`. Which of
  # "materialize" or "defer" happens is decided per-invocation, at
  # runtime, by `$hasDefer` -- not by a single Nix-eval-time setting for
  # the whole shim. This is what lets ONE `cc` shim instance batch SOME
  # invocations (module-granularity, opted in per source path) while
  # every other invocation keeps the default immediate-materialize
  # behavior.
  finalizeTail = ''
    if [ "$hasDefer" = "true" ]; then
      # `defer`: no compile, no registration -- write a batch-pending
      # stub at $outputPath and a JSON record file alongside it, then
      # exit 0 immediately. Nothing in THIS script ever reads the record
      # back -- that's `shim.wrapArchiver`'s job.
      recordPath=$(mktemp)
      printf '%s' "$payload" > "$recordPath"
      ${writeStubFn}
      dyndrv_write_batch_stub "$outputPath" "$recordPath"
    else
      # `materialize`: `$payload` is `.drvJson`, already the raw JSON
      # object `nix derivation add` expects.
      #
      # `2>/dev/null` on every internal Nix bookkeeping command in this
      # script is REQUIRED, not cosmetic: a real autoconf/libtool probe
      # (freetype's own `configure`) runs the compiler as `gcc ...
      # conftest.c >&5` and separately captures `2>conftest.err`, diffing
      # it against expected compiler-warning boilerplate to decide
      # whether a flag "works". Since this wrapper runs in place of the
      # real compiler, any of its own diagnostic noise on stderr lands in
      # `conftest.err` too, silently corrupting that diff even though the
      # real compile succeeded. This is a generic risk for any tool that
      # captures/diffs a wrapped command's stderr, not autoconf-specific.
      drvPath=$(printf '%s' "$payload" | nix derivation add 2>/dev/null)
      realOut=$(nix-store --realise "$drvPath" 2>/dev/null)

      ${pkgs.coreutils}/bin/cp -r "$realOut" "$outputPath"
    fi
  '';
in
{
  # The wrapper script's content. Callers place this at
  # `<wrapperDir>/bin/<command>` (mode 0755) and prepend `<wrapperDir>/bin`
  # to `$PATH` ahead of the real toolchain.
  wrapperScript =
    if discoverTree == null then
      ''
        #!/bin/sh
        set -eu

        export PATH="${nixPackage}/bin:$PATH"
        export NIX_CONFIG='extra-experimental-features = nix-command ca-derivations dynamic-derivations recursive-nix'

        # Rewrite any argv element that's a path to an EXISTING regular
        # file not already under /nix/store into its real store path
        # first: a real build's source files (e.g. `cc -c a.c -o a.o`)
        # are ordinary relative paths in the outer build's own working
        # directory, not yet Nix store objects, and a `toNode` expression
        # referencing such a path directly fails ("'a.c' is too short to
        # be a valid store path") since the sandbox has no access to the
        # outer build's $PWD -- only to real store paths declared as
        # inputs. Doing this HERE, once, before `toNode` ever sees
        # `argv`, means every `toNode` can treat every non-flag argv
        # element uniformly as a real, already-addable store path.
        rewrittenArgs=""
        for a in "$@"; do
          case "$a" in
            /nix/store/*)
              rewritten="$a"
              ;;
            -*)
              rewritten="$a"
              ;;
            *)
              if [ -f "$a" ]; then
                rewritten=$(nix store add-file "$a" 2>/dev/null)
              else
                rewritten="$a"
              fi
              ;;
          esac
          rewrittenArgs="$rewrittenArgs$rewritten"$'\n'
        done

        argvJson=$(printf '%s' "$rewrittenArgs" | ${pkgs.jq}/bin/jq -R -s 'split("\n") | .[:-1]')

        nodeExprFile=$(mktemp)
        cat > "$nodeExprFile" <<'DYNDRV_TONODE_EXPR'
        ${toNode}
        DYNDRV_TONODE_EXPR

        argvFile=$(mktemp)
        printf '%s' "$argvJson" > "$argvFile"

        node=$(ARGV_PATH="$argvFile" nix-instantiate --eval --strict --json --expr \
          "let argv = builtins.fromJSON (builtins.readFile (builtins.getEnv \"ARGV_PATH\")); f = import $nodeExprFile; in f argv" 2>/dev/null)
        rm -f "$nodeExprFile" "$argvFile"

        # A top-level `null` from `nix-instantiate --eval --strict --json`
        # is the bare text `null` -- this is how we detect the
        # PASSTHROUGH case documented in this file's `toNode` contract.
        if [ "$node" = "null" ]; then
          exec "${realCommand}" "$@"
        fi

        ${resolveNodeFields}

        ${finalizeTail}
      ''
    else
      ''
        #!/bin/sh
        set -eu

        export PATH="${nixPackage}/bin:$PATH"
        export NIX_CONFIG='extra-experimental-features = nix-command ca-derivations dynamic-derivations recursive-nix'

        # discoverTree mode: preserves relative directory structure
        # instead of flattening every input to its own basename -- needed
        # for compilers whose real invocations depend on relative `-I`
        # search paths across a multi-directory source tree.
        #
        # Some real build systems (e.g. freetype's libtool-driven build)
        # pass ABSOLUTE paths that are nonetheless relative to the
        # CALLING BUILD'S OWN `$PWD`, not real Nix store paths (e.g.
        # `/build/freetype-2.14.3/src/base/ftbase.c` -- `/build` is the
        # sandbox's own build directory, not a store path) -- these must
        # be normalized to genuinely relative form FIRST, or the later
        # "any `/`-prefixed path is already a real store input"
        # assumption incorrectly skips staging them. Any argv element NOT
        # prefixed with `$origPwd/` (e.g. a real `/nix/store/...` -I flag
        # value) is left untouched.
        #
        # This must also handle the GLUED flag form (`-I/build/.../foo`,
        # the path stuck directly onto the flag letter with no space --
        # confirmed this is how real autotools/libtool builds pass `-I`),
        # not just a standalone positional path argument. `stripPwdPrefix`
        # handles both the bare and any glued-flag-prefix form
        # generically, rather than one `case` arm per known flag letter.
        origPwd=$(${pkgs.coreutils}/bin/pwd)
        stripPwdPrefix() {
          case "$1" in
            "$origPwd"/*) printf '%s' "''${1#"$origPwd"/}" ;;
            *"$origPwd"/*)
              printf '%s%s' "''${1%%"$origPwd"/*}" "''${1#*"$origPwd"/}"
              ;;
            *) printf '%s' "$1" ;;
          esac
        }
        firstArg=1
        for a in "$@"; do
          a=$(stripPwdPrefix "$a")
          if [ "$firstArg" = 1 ]; then
            set -- "$a"
            firstArg=0
          else
            set -- "$@" "$a"
          fi
        done
        # `argv` here is now relative wherever the original was
        # absolute-but-under-$PWD -- genuinely absolute paths (real store
        # paths) are unchanged.
        argvJson=$(printf '%s\n' "$@" | ${pkgs.jq}/bin/jq -R -s 'split("\n") | .[:-1]')

        discoverFile=$(mktemp)
        cat > "$discoverFile" <<'DYNDRV_DISCOVER_SCRIPT'
        ${discoverTree}
        DYNDRV_DISCOVER_SCRIPT

        # `discoverTree`'s own stdout: one RELATIVE path per line (sources
        # and headers this invocation needs, already relative to $PWD).
        # Any positional (non-"-"-prefixed) argv element that names an
        # existing relative regular file is included automatically, so a
        # caller's `discoverTree` only needs to report paths argv itself
        # doesn't already name (typically just the discovered headers).
        # `|| true` is required here: under `set -e`, a `discoverTree`
        # that legitimately finds nothing to report (e.g. a link
        # invocation like `cc main.o lib_0.o -o prog` has no headers to
        # discover, so its own internal `grep -v '^$'` exits 1 on empty
        # input) would otherwise abort the WHOLE wrapper script here,
        # before `toNode` ever gets a chance to return `null` for exactly
        # this kind of non-compile invocation.
        discoveredPaths=$(sh -c "$(cat "$discoverFile")" -- "$@") || true
        rm -f "$discoverFile"

        argvPaths=""
        for a in "$@"; do
          case "$a" in
            -*) ;;
            /*) ;;
            *)
              if [ -f "$a" ]; then
                argvPaths="$argvPaths$a
        "
              fi
              ;;
          esac
        done

        allPaths=$(printf '%s\n%s\n' "$argvPaths" "$discoveredPaths" | sort -u | grep -v '^$' || true)

        # `nix store add`'s resulting store path/hash depends on the
        # STAGING DIRECTORY'S OWN BASENAME, not just its contents -- two
        # directories with byte-identical contents but different
        # basenames produce two DIFFERENT store paths. Using `mktemp -d`'s
        # randomized basename here made every invocation's staged tree
        # (and therefore the whole registered derivation) hash
        # differently even when nothing relevant had changed -- the root
        # cause of a real regression where every translation unit
        # rebuilt on a one-file patch. Fixed by staging into a FIXED
        # basename (`dyndrv-tree`, created fresh under a `mktemp -d`
        # PARENT so concurrent invocations still get distinct filesystem
        # paths, but the directory `nix store add` actually hashes always
        # has the same name).
        treeParent=$(mktemp -d)
        treeDir="$treeParent/dyndrv-tree"
        ${pkgs.coreutils}/bin/mkdir -p "$treeDir"
        while IFS= read -r p; do
          [ -z "$p" ] && continue
          case "$p" in
            /*) continue ;; # absolute paths (e.g. system headers under /nix/store) are real store inputs already, not staged into the tree
          esac
          if [ -f "$p" ]; then
            ${pkgs.coreutils}/bin/mkdir -p "$treeDir/$(${pkgs.coreutils}/bin/dirname "$p")"
            ${pkgs.coreutils}/bin/cp "$p" "$treeDir/$p"
          fi
        done <<DYNDRV_PATHS
        $allPaths
        DYNDRV_PATHS

        treePath=$(nix store add "$treeDir" 2>/dev/null)
        rm -rf "$treeParent"
        export DYNDRV_TREE_BASENAME=$(${pkgs.coreutils}/bin/basename "$treePath")

        nodeExprFile=$(mktemp)
        cat > "$nodeExprFile" <<'DYNDRV_TONODE_EXPR'
        ${toNode}
        DYNDRV_TONODE_EXPR

        argvFile=$(mktemp)
        printf '%s' "$argvJson" > "$argvFile"

        node=$(ARGV_PATH="$argvFile" DYNDRV_TREE_BASENAME="$DYNDRV_TREE_BASENAME" nix-instantiate --eval --strict --json --expr \
          "let argv = builtins.fromJSON (builtins.readFile (builtins.getEnv \"ARGV_PATH\")); f = import $nodeExprFile; in f argv" 2>/dev/null)
        rm -f "$nodeExprFile" "$argvFile"

        if [ "$node" = "null" ]; then
          exec "${realCommand}" "$@"
        fi

        ${resolveNodeFields}

        ${finalizeTail}
      '';
}
