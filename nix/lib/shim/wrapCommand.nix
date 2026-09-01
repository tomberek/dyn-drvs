{ pkgs, lib, self }:

# Intercepts a toolchain command on `$PATH` (e.g. `cc`) so that, instead of
# running immediately, each invocation registers itself as a dynamically-
# produced derivation and is realized immediately, with the real result
# copied to wherever the calling build tool expects its output --
# `accelerate.mkAcceleratedStdenv` is built from this (nixgg's own
# `cc`/`ar`/`ranlib` shims, generalized as its own primitive so it's usable
# outside the accelerator too).
#
# v0.2 SCOPE (verified 2026-08-31, by reading Nix's own
# `daemon.cc:performOp`'s connection-mode allowlist directly): only
# `resolveInputs = "materialize"` is implemented, and only for the
# `recursive-nix` backend. This is not an arbitrary restriction:
#   - `builder-rpc-v0` ("RecursiveSubmitted" connections) are restricted to
#     exactly `AddToStore*`/`SubmitOutput`/`AddTempRoot`/`IsValidPath` --
#     `BuildPaths`/`QueryMissing` are absent from that allowlist and
#     rejected outright ("Operation N not allowed inside derivation",
#     confirmed directly: op 40 = QueryMissing). A builder-rpc-v0 shim can
#     register a node but can never realize it or block on its result mid-
#     script -- so "materialize" is structurally impossible there.
#   - `recursive-nix` has its own `RestrictedStore`/`RestrictedBuilder`
#     wrapper that DOES implement `buildPaths`/realization, gated only by
#     an `isAllowed` per-path check (input closure, or previously added via
#     a prior recursive-Nix call) -- confirmed working directly via
#     `nix-store --realise` inside a `recursive-nix` sandbox.
#
# `resolveInputs = "defer"` (write a stub instead of blocking, matching
# nixgg's `drvref` pattern, resolved later by a collecting pass over the
# whole build tree -- nixgg's own `assemble`) works in principle under
# EITHER backend since it never calls BuildPaths itself, but needs its own
# stub format + collection pass and is follow-on work, not implemented
# here yet -- `wrapCommand { resolveInputs = "defer"; }` throws a clear
# "not yet implemented" error.
#
# `command`: the command name being intercepted (e.g. "cc") -- informational,
#   used only in error messages; callers install the returned script at
#   `<wrapperDir>/bin/<command>` themselves.
# `realCommand`: absolute path to the real command this wrapper shadows.
#   Used both for passthrough (see `toNode` below) and, in principle, by a
#   `toNode` expression that wants to invoke the real compiler itself
#   inside the registered derivation's own builder.
# `toNode`: a Nix expression STRING, `argv: { drvJson, outputArg } | null`:
#   Returning `null` (a PASSTHROUGH) skips registration/realization
#   entirely and execs `realCommand` directly with the original argv --
#   this is how `accelerate.mkAcceleratedStdenv` (v0.2) tells `cc`'s link
#   invocations (no `-c` flag) to run normally, while only `-c` compile
#   invocations get intercepted; `wrapCommand` itself doesn't know or care
#   which invocations should be accelerated, that policy lives entirely in
#   the caller-supplied `toNode`.
#   Otherwise, `toNode` returns:
#     - `drvJson`: a `nix derivation add`-shaped attrset, PRE-SERIALIZED
#       via `builtins.toJSON` (i.e. `drvJson = builtins.toJSON {...};`,
#       a STRING, not a nested attrset -- same schema as
#       `viaDerivationAdd.nix`/`graph.compile`'s per-node `mkDrv` -- see
#       those files for the exact shape) describing what this ONE
#       invocation should actually do (typically the same command, run
#       for real, inside the registered derivation's own builder).
#       MUST be pre-serialized, not a nested attrset: confirmed by direct
#       reproduction that `nix-instantiate --eval --json` (without
#       `--strict`) fails with "cannot convert a thunk to JSON" on ANY
#       attrset containing a `builtins.toJSON`-produced value, even a
#       fully static one with no dependency on `argv` at all -- a
#       genuine `nix-instantiate` quirk, not specific to this file. The
#       fix (used by `wrapperScript` below) is `--eval --strict --json`
#       together, which serializes such values correctly.
#     - `outputArg`: the index into `argv` naming the file path the
#       CALLING build tool expects to exist after this command returns.
#       `argv` is `$@` as the wrapper script sees it, WITHOUT the command
#       name itself (i.e. NOT including `$0`) -- so for `cc -c foo.c -o
#       foo.o`, `argv = ["-c" "foo.c" "-o" "foo.o"]` and `outputArg = 3`
#       names `foo.o` (index 3, zero-based). The wrapper copies the
#       realized derivation's real output there after resolving it, so
#       the outer build process (make, a Makefile, etc.) sees an
#       ordinary file at the path it asked for and can proceed normally,
#       unaware anything was intercepted. Mutually exclusive with
#       `outputPath` below -- supply exactly one.
#     - `outputPath` (ALTERNATIVE to `outputArg`): a literal RELATIVE path
#       string, for invocations with no `-o` at all -- confirmed a real,
#       common case by direct reproduction: `libtool --mode=compile`
#       invokes the real compiler as `cc -c foo.c ... -fPIC -DPIC`, with
#       NO `-o` flag whatsoever, relying on the compiler's own documented
#       default (source basename, extension stripped, `.o` appended,
#       written to the CURRENT DIRECTORY regardless of the source file's
#       own directory -- confirmed directly: `cc -c sub/foo.c` from cwd
#       `sub/` produces `sub/foo.o`, but `cc -c /tmp/bar.cpp` from cwd `/`
#       fails outright rather than writing to `/tmp/bar.o`). Since no
#       argv index NAMES this path, `toNode` must compute it itself (see
#       `accelerate/mkAcceleratedStdenv.nix` for the exact basename/
#       extension-stripping logic) and return it directly as a string.
#   Instantiated once PER INVOCATION with `argv` bound to this call's
#   actual arguments (a JSON array of strings, crossing the eval->build
#   boundary the same way `viaNixInstantiate`'s own `args` does).
# `nixPackage`: the Nix to run `nix derivation add`/`nix-store --realise`
#   with, inside the sandbox -- for `recursive-nix` this may just be
#   `pkgs.nix` (no patched build needed, unlike `builder-rpc-v0`).
# `discoverTree`: OPTIONAL bash script TEXT, run as `bash -c "$discoverTree"
#   -- "$@"` with the ORIGINAL compiler argv as its own positional params.
#   Exists for compilers whose real invocations depend on RELATIVE `-I`
#   search paths across a multi-directory source tree (confirmed necessary
#   by direct reproduction against a real openssl build: `-Iapps/include
#   -Iinclude`-style flags, and headers like `apps.h`/`openssl/
#   opensslconf.h` resolved only via those relative paths -- the default
#   per-file, flatten-to-basename rewrite below cannot support this, since
#   flattening destroys the relative directory structure `-I` depends on).
#   Must print every RELATIVE path (sources AND headers, one per line,
#   already deduplicated is not required) this invocation needs beyond
#   argv's own positional files -- typically the output of a `cc -M -MG`-
#   style dependency scan (see `accelerate/mkAcceleratedStdenv.nix` for a
#   concrete implementation). When set:
#     - the old per-file "rewrite relative paths to their own store path"
#       behavior is SKIPPED entirely (it would destroy the relative
#       structure this mode exists to preserve);
#     - every relative file argv already names, PLUS every path
#       `discoverTree` prints, is staged into ONE scratch directory that
#       mirrors their original relative layout, added to the store as a
#       SINGLE unit (`nix store add`, confirmed to preserve directory
#       structure by direct reproduction -- unlike `nix store add-file`,
#       which only handles single files), and its basename exported as
#       `DYNDRV_TREE_BASENAME` -- `toNode` reads this via
#       `builtins.getEnv "DYNDRV_TREE_BASENAME"` (the same eval/build-
#       boundary-crossing convention `mkArgs.nix`/`ARGV_PATH` already
#       establish) to build a `drvJson` whose builder script `cp -r`s that
#       ONE tree into its cwd, then runs the REAL command with argv
#       UNCHANGED (still relative) against that copied tree -- confirmed
#       working by direct reproduction: `-I`/positional relative paths
#       resolve correctly when the builder's cwd contains the whole
#       staged tree, exactly as they would in the original build
#       directory.
#     - `argv` as seen by `toNode` is therefore the RAW, unmodified
#       original argv in this mode (NOT rewritten to absolute store
#       paths, unlike the default/no-`discoverTree` mode) -- `toNode`
#       must reference `inputs.srcs = [ treeBasename ]` (one directory
#       input), not per-file basenames, when `discoverTree` is active.

{
  command,
  realCommand,
  toNode,
  resolveInputs ? "materialize",
  nixPackage ? pkgs.nix,
  discoverTree ? null,
}:

if resolveInputs == "defer" then
  throw ''
    dyndrv.shim.wrapCommand: resolveInputs = "defer" is not yet
    implemented (needs its own stub-file format + a collecting pass over
    the whole build tree, tracked as follow-on work -- see
    nix/lib/shim/wrapCommand.nix's header comment). Use
    resolveInputs = "materialize" (the default) for now.
  ''
else if resolveInputs != "materialize" then
  throw ''dyndrv.shim.wrapCommand: unknown resolveInputs "${resolveInputs}" (expected "materialize" or "defer")''
else

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

        # Rewrite any argv element that's a path to an EXISTING regular file
        # not already under /nix/store into its real store path first --
        # confirmed necessary by direct reproduction: a real build's source
        # files (e.g. `cc -c a.c -o a.o`) are ordinary relative paths in the
        # outer build's own working directory, not yet Nix store objects at
        # all, and a `toNode` expression referencing such a path directly
        # (whether in `args` or `inputs.srcs`) fails ("'a.c' is too short to
        # be a valid store path") because it's registering a derivation whose
        # sandbox has no access to the outer build's $PWD -- only to real
        # store paths declared as inputs. Adding such files to the store
        # HERE, once, before `toNode` ever sees `argv`, means every `toNode`
        # (this file's own convention -- see its header comment) can treat
        # every non-flag argv element uniformly as a real, already-addable
        # store path.
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

        # A top-level `null` from `nix-instantiate --eval --strict --json` is
        # the bare text `null` (confirmed directly by repeated testing -- an
        # earlier version of this comment incorrectly claimed it was wrapped
        # as `{"value":null}`; that was wrong and caused a real bug: the
        # PASSTHROUGH check below never matched, so even non-`-c` invocations
        # fell through to the drvJson/outputArg extraction path and failed
        # with a confusing `jq: Cannot index array with null` error instead
        # of executing the real command) -- this is how we detect the
        # PASSTHROUGH case documented in this file's `toNode` contract.
        if [ "$node" = "null" ]; then
          exec "${realCommand}" "$@"
        fi

        # `.drvJson` is itself an already-JSON-encoded STRING (per this
        # file's own `toNode` contract: `drvJson = builtins.toJSON {...};`)
        # -- `jq -r` unwraps that one level of JSON-string-quoting so
        # `nix derivation add` receives the raw JSON object it expects,
        # rather than a JSON string containing escaped JSON (confirmed by
        # direct reproduction: without `-r`, `nix derivation add` receives
        # `"{\"name\":...}"` -- a JSON string literal -- and rejects it).
        drvJson=$(echo "$node" | ${pkgs.jq}/bin/jq -r '.drvJson')
        # `outputArg`/`outputPath` are mutually exclusive (see this file's
        # header comment) -- `jq -r 'if .outputArg ...'` returns the
        # literal text "null" (not empty) when a key is absent, so the
        # `[ -n ]`/`!= "null"` check below distinguishes "not supplied"
        # from "supplied as an actual JSON null", matching the same
        # `nix-instantiate`-null convention already established for the
        # PASSTHROUGH check above.
        outputArgRaw=$(echo "$node" | ${pkgs.jq}/bin/jq -r 'if has("outputArg") then .outputArg else "null" end')
        if [ "$outputArgRaw" != "null" ]; then
          outputPath=$(echo "$argvJson" | ${pkgs.jq}/bin/jq -r --argjson i "$outputArgRaw" '.[$i]')
        else
          outputPath=$(echo "$node" | ${pkgs.jq}/bin/jq -r '.outputPath')
        fi

        # `2>/dev/null` on every internal Nix bookkeeping command in this
        # script (here and throughout) is REQUIRED, not cosmetic --
        # confirmed by direct reproduction against a real autoconf/libtool
        # probe (freetype's own `configure`): autoconf's PIC-detection
        # test runs the compiler as `gcc ... conftest.c >&5` (redirecting
        # BOTH stdout and stderr to its own `config.log`) and separately
        # captures `2>conftest.err`, which it then diffs against expected
        # compiler-warning boilerplate to decide whether the flag "works".
        # Since this wrapper script is invoked in place of the real
        # compiler, ANY of its own diagnostic noise on stderr ("this
        # derivation will be built:", "warning: you did not specify
        # '--add-root'...", etc.) lands in `conftest.err` too -- silently
        # corrupting that diff and making autoconf report "PIC flag
        # doesn't work" (or similar) even though the real, underlying
        # compile succeeded perfectly (`$? = 0`, a valid, non-empty `.o`
        # produced). This is a generic risk for ANY command-line tool a
        # caller might capture/diff stderr from (not autoconf-specific),
        # so every `nix`-family command below is silenced regardless of
        # whether a specific caller is known to care.
        drvPath=$(echo "$drvJson" | nix derivation add 2>/dev/null)
        realOut=$(nix-store --realise "$drvPath" 2>/dev/null)

        ${pkgs.coreutils}/bin/cp -r "$realOut" "$outputPath"
      ''
    else
      ''
        #!/bin/sh
        set -eu

        export PATH="${nixPackage}/bin:$PATH"
        export NIX_CONFIG='extra-experimental-features = nix-command ca-derivations dynamic-derivations recursive-nix'

        # discoverTree mode: preserves relative directory structure instead
        # of flattening every input to its own basename -- needed for
        # compilers whose real invocations depend on relative `-I` search
        # paths across a multi-directory source tree (confirmed necessary
        # by direct reproduction against a real openssl build; see this
        # file's header comment for the full rationale).
        #
        # Some real build systems (confirmed by direct reproduction against
        # freetype's libtool-driven build) pass ABSOLUTE paths that are
        # nonetheless relative to the CALLING BUILD'S OWN `$PWD`, not real
        # Nix store paths (e.g. `/build/freetype-2.14.3/src/base/ftbase.c`
        # -- `/build` is the sandbox's own build directory, not a store
        # path) -- these must be normalized to genuinely relative form
        # FIRST, before anything else in this script runs, or the later
        # "any `/`-prefixed path is already a real store input" assumption
        # (see below) incorrectly skips staging them, leaving the per-TU
        # sandbox with a source path that doesn't exist inside it
        # (confirmed directly: "cc1: fatal error: /build/.../ftbase.c: No
        # such file or directory"). Any argv element NOT prefixed with
        # `$origPwd/` (e.g. a real `/nix/store/...` -I flag value) is left
        # untouched.
        #
        # This must also handle the GLUED flag form (`-I/build/.../foo`,
        # the path stuck directly onto the flag letter with no space --
        # confirmed by direct reproduction that this is how a real
        # autotools/libtool build actually passes `-I`: none of freetype's
        # real `-I` flags were ever a separate argv element from their
        # path), not just a standalone positional path argument -- a
        # naive whole-element match (`"$a" = "$origPwd"/*`) misses this
        # entirely, since `-I/build/...` as a whole string never equals
        # `$origPwd/*` (confirmed directly: relativizing only bare
        # positional paths left every `-I/build/...` flag pointing at a
        # path that doesn't exist inside the staged sandbox, producing
        # "fatal error: freetype/internal/ftdebug.h: No such file or
        # directory" even after source-file paths were already fixed).
        # `stripPwdPrefix` handles both the bare and any glued-flag-prefix
        # form generically, rather than one `case` arm per known flag
        # letter (`-I`, `-isystem`, `-iquote`, ... -- an open-ended list
        # for any future compiler flag that glues a path onto itself).
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
        # and headers this invocation needs, already relative to $PWD --
        # see this file's header comment for the exact contract). Any
        # positional (non-"-"-prefixed) argv element that names an existing
        # relative regular file is included automatically, so a caller's
        # `discoverTree` only needs to report paths argv itself doesn't
        # already name (typically just the discovered headers). `|| true`
        # is required here: under `set -e`, a `discoverTree` that legitimately
        # finds nothing to report (confirmed by direct reproduction: a link
        # invocation like `cc main.o lib_0.o -o prog` has no headers to
        # discover, so the discovery script's own internal `grep -v '^$'`
        # exits 1 on empty input) would otherwise abort the WHOLE wrapper
        # script here, before `toNode` ever gets a chance to return `null`
        # (PASSTHROUGH) for exactly this kind of non-compile invocation.
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
        # STAGING DIRECTORY'S OWN BASENAME, not just its contents --
        # confirmed by direct reproduction: two directories with byte-
        # identical contents but different basenames (e.g. two different
        # `mktemp -d` results) produced two DIFFERENT store paths. Using
        # `mktemp -d`'s randomized basename here made every single
        # invocation's staged tree (and therefore the whole registered
        # derivation, since `treeBasename` is embedded in its `args`) hash
        # differently even when nothing relevant had changed -- confirmed
        # as the root cause of a real regression: EVERY translation unit
        # rebuilt on a one-file patch, defeating the entire point of
        # per-TU caching. Fixed by staging into a FIXED basename
        # (`dyndrv-tree`, created fresh under a `mktemp -d` PARENT so
        # concurrent invocations still get distinct filesystem paths,
        # but the directory `nix store add` actually hashes always has
        # the same name).
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

        drvJson=$(echo "$node" | ${pkgs.jq}/bin/jq -r '.drvJson')
        # `outputArg`/`outputPath` are mutually exclusive (see this file's
        # header comment) -- `jq -r 'if .outputArg ...'` returns the
        # literal text "null" (not empty) when a key is absent, so the
        # `[ -n ]`/`!= "null"` check below distinguishes "not supplied"
        # from "supplied as an actual JSON null", matching the same
        # `nix-instantiate`-null convention already established for the
        # PASSTHROUGH check above.
        outputArgRaw=$(echo "$node" | ${pkgs.jq}/bin/jq -r 'if has("outputArg") then .outputArg else "null" end')
        if [ "$outputArgRaw" != "null" ]; then
          outputPath=$(echo "$argvJson" | ${pkgs.jq}/bin/jq -r --argjson i "$outputArgRaw" '.[$i]')
        else
          outputPath=$(echo "$node" | ${pkgs.jq}/bin/jq -r '.outputPath')
        fi

        drvPath=$(echo "$drvJson" | nix derivation add 2>/dev/null)
        realOut=$(nix-store --realise "$drvPath" 2>/dev/null)

        ${pkgs.coreutils}/bin/cp -r "$realOut" "$outputPath"
      '';
}
