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
#       unaware anything was intercepted.
#   Instantiated once PER INVOCATION with `argv` bound to this call's
#   actual arguments (a JSON array of strings, crossing the eval->build
#   boundary the same way `viaNixInstantiate`'s own `args` does).
# `nixPackage`: the Nix to run `nix derivation add`/`nix-store --realise`
#   with, inside the sandbox -- for `recursive-nix` this may just be
#   `pkgs.nix` (no patched build needed, unlike `builder-rpc-v0`).

{
  command,
  realCommand,
  toNode,
  resolveInputs ? "materialize",
  nixPackage ? pkgs.nix,
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
  wrapperScript = ''
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
            rewritten=$(nix store add-file "$a")
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
      "let argv = builtins.fromJSON (builtins.readFile (builtins.getEnv \"ARGV_PATH\")); f = import $nodeExprFile; in f argv")
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
    outputArg=$(echo "$node" | ${pkgs.jq}/bin/jq -r '.outputArg')
    outputPath=$(echo "$argvJson" | ${pkgs.jq}/bin/jq -r --argjson i "$outputArg" '.[$i]')

    drvPath=$(echo "$drvJson" | nix derivation add)
    realOut=$(nix-store --realise "$drvPath")

    ${pkgs.coreutils}/bin/cp -r "$realOut" "$outputPath"
  '';
}
