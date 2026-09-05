{ pkgs, lib, self }:

# The `ar`-collection shim companion to `shim.wrapCommand`'s `defer`
# mode: given an `ar` invocation whose input `.o` paths are ALL still-
# pending batch-deferred stubs (see `batchStub.nix`) sharing the exact
# same batch-group `key`, combines every member's compile plus the `ar`
# step itself into ONE registered, realized derivation instead of N+1 --
# mirroring nixgg's own `tryBatchArchive`/`collectSameGroupMembers`/
# `submitCombinedArchive` design.
#
# Any input that does NOT qualify (a real, already-compiled object; a
# stub from a different batch group; anything else) means this whole
# `ar` invocation isn't a pure same-group batch -- in that case, every
# input that IS a pending stub is resolved individually into an ordinary
# per-TU derivation first (so nothing is left dangling for the real `ar`
# to choke on), and then the REAL `ar` runs against the now-fully-
# resolved input set. This fallback makes deferring safe for any
# consumer, not just a same-group archive -- nixgg's `ResolvePendingMember`
# role.
#
# `command`/`realCommand`: same convention as `wrapCommand.nix` -- "ar"
#   and the absolute path to the real `ar` binary.
# `nixPackage`: same as `wrapCommand.nix` -- the Nix to run
#   `nix derivation add`/`nix-store --realise` with, inside the sandbox.
# `record` (as written by `wrapCommand.nix`'s `defer` branch, read back
#   here): a JSON object `{ key, tool, args, srcs, setupCmd }`.
#   `key`: this member's batch-group identifier -- only members sharing
#     the SAME `key` (checked across every input to one `ar` call) are
#     combined into one derivation.
#   `tool`: absolute path to the real compiler to invoke for this member.
#   `args`: the member's own FULL original compiler argv (as a JSON
#     array of strings), with its own `-o`/implicit-output-path replaced
#     by the LITERAL SENTINEL STRING `"$out"` (`toNode`, not this file,
#     performs that rewrite when constructing `record`). This file
#     replaces that one sentinel-valued array element with a plain
#     per-member object PATH (never a real Nix derivation output) when it
#     builds the combined script.
#   `srcs`: extra `/nix/store/...` basenames this member's own compile
#     needs beyond the toolchain -- unioned across every combined member
#     into the batch derivation's own `inputs.srcs`.
#   `setupCmd` (optional, default ""): a shell snippet run IMMEDIATELY
#     BEFORE this member's own compile command, inside the SAME combined
#     script -- e.g. `mkAcceleratedStdenv.nix`'s per-member `cp -r
#     .../<tree> . &&` staging step (that file's `toNode` is ALWAYS in
#     `discoverTree` mode, so every member needs its own tree staged
#     before compiling). MUST include its own trailing command separator
#     (`&&`/`;`), since this file concatenates `"$setupCmd $tool
#     $argsLine"` with a plain SPACE -- a `setupCmd` without one is
#     silently swallowed as extra positional arguments to whatever
#     command it names. Runs from the SAME shared working directory
#     every member and the final `ar` step share, so a LATER member's
#     `setupCmd` staging a same-named file as an EARLIER member's would
#     collide -- `mkAcceleratedStdenv.nix`'s own `shouldBatch`-gated
#     callers are responsible for this not happening in practice.
#
# Combined derivation shape: one `/bin/sh -c` script running every
# member's own compile command sequentially, each writing to its own
# fixed, plain (non-output) filename inside the builder's own working
# directory (e.g. `dyndrv-member-1.o`) -- only the final `ar` step's
# result is a real declared derivation output (`$out`), since Nix only
# ever auto-provides an env var per entry in a derivation's `outputs`
# (an intermediate `.o` referencing an undeclared env var is simply
# unset). Then the real `ar` invocation runs over every member's now-real
# object, with the same modifiers/flags/archive-name the intercepted `ar`
# call itself specified. Registered via `nix derivation add`, realized
# via `nix-store --realise` (same `recursive-nix`-only backend
# `wrapCommand`'s `materialize` mode uses -- this shim only defers WHEN
# each member's compile happens, not whether the batch eventually runs
# through the same register-then-realize machinery).
#
# IMPLEMENTATION NOTE: every multi-line piece of data this script
# iterates is fed to `while read` via `< <(printf '%s' "$var")` process
# substitution, never a plain `| while read` pipe (a pipe runs the loop
# body in a subshell, silently discarding every variable the loop sets
# once it exits) and never a `<<HEREDOC` either (a heredoc's literal
# body, embedded inside a Nix indented string, inherits the source
# file's own indentation on the line introducing `$var`, corrupting the
# heredoc's first line with leading whitespace). Text substitution uses
# bash's own `${var//search/replace}`, not `sed` (which isn't part of
# `coreutils`).

{
  command,
  realCommand,
  nixPackage ? pkgs.nix,
}:

let
  inherit (self.shim.batchStub) readStubFn;
in
{
  wrapperScript = ''
    #!/bin/sh
    set -eu

    export PATH="${nixPackage}/bin:$PATH"
    export NIX_CONFIG='extra-experimental-features = nix-command ca-derivations dynamic-derivations recursive-nix'

    ${readStubFn}

    # Registers, realizes, and copies the result to $2, for a derivation
    # named $1 whose whole builder script is $3 -- the one register-then-
    # realize sequence both the fast path (one combined derivation for a
    # whole batch) and the fallback path (one derivation per still-
    # pending member) need.
    dyndrv_build_and_copy() {
      local name="$1" dest="$2" script="$3" srcsJson="$4"
      local drvJson selfPlaceholder drvPath realOut
      drvJson=$(${pkgs.jq}/bin/jq -n \
        --arg name "$name" \
        --arg system "${builtins.currentSystem}" \
        --arg script "$script" \
        --argjson srcs "$srcsJson" \
        '{
          name: $name, system: $system, builder: "/bin/sh",
          args: ["-c", $script],
          env: { out: "@dyndrv-batch-placeholder@" },
          inputs: { drvs: {}, srcs: $srcs },
          outputs: { out: { method: "nar", hashAlgo: "sha256" } },
          version: 4
        }')
      selfPlaceholder=$(nix eval --raw --expr 'builtins.placeholder "out"' 2>/dev/null)
      drvJson="''${drvJson//@dyndrv-batch-placeholder@/$selfPlaceholder}"
      drvPath=$(printf '%s' "$drvJson" | nix derivation add 2>/dev/null)
      realOut=$(nix-store --realise "$drvPath" 2>/dev/null)
      ${pkgs.coreutils}/bin/cp "$realOut" "$dest"
    }

    # `ar`'s own argv shape (simpler and more fixed than `cc`'s -- no
    # discovery needed): the FIRST token is the modifiers/command string
    # (e.g. "rcs" -- no leading `-`, unlike `cc`'s flags: `ar rcs
    # archive.a a.o`, not `ar -rcs ...`), the SECOND is the archive path,
    # and everything after that is a positional object-file input.
    modifiers=""
    archive=""
    inputs=""
    seenModifiers=0
    seenArchive=0
    for a in "$@"; do
      if [ "$seenModifiers" = 0 ]; then
        modifiers="$a"
        seenModifiers=1
        continue
      fi
      if [ "$seenArchive" = 0 ]; then
        archive="$a"
        seenArchive=1
        continue
      fi
      inputs="$inputs$a
    "
    done

    # Check every input: does it qualify as a pending stub, and do they
    # all share the same key? `allPending`/`sameKey` both start "true"
    # and flip permanently to "false" the moment ANY input disqualifies
    # the batch.
    allPending=true
    firstKey=""
    sameKey=true
    recordPaths=""
    while IFS= read -r in; do
      [ -z "$in" ] && continue
      recPath=$(dyndrv_read_batch_stub "$in")
      if [ -z "$recPath" ]; then
        allPending=false
        continue
      fi
      thisKey=$(${pkgs.jq}/bin/jq -r '.key' "$recPath" 2>/dev/null)
      if [ -z "$firstKey" ]; then
        firstKey="$thisKey"
      elif [ "$thisKey" != "$firstKey" ]; then
        sameKey=false
      fi
      recordPaths="$recordPaths$recPath
    "
    done < <(printf '%s' "$inputs")

    if [ "$allPending" = "true" ] && [ "$sameKey" = "true" ] && [ -n "$firstKey" ]; then
      # Fast path: combine every member's own compile plus this archive
      # step into ONE derivation.
      compileLines=""
      objPaths=""
      allSrcs=""
      i=0
      while IFS= read -r recPath; do
        [ -z "$recPath" ] && continue
        i=$((i + 1))
        memberObj="dyndrv-member-$i.o"
        # One `jq` call per member: `tool`/`setupCmd`/`argsLine` come
        # back as three fixed lines, `srcs` as however many trailing
        # lines remain.
        {
          IFS= read -r tool
          IFS= read -r setupCmd
          IFS= read -r argsLine
          theseSrcs=$(cat)
        } < <(
          ${pkgs.jq}/bin/jq -r --arg obj "$memberObj" \
            '.tool, (.setupCmd // ""), (.args | map(if . == "$out" then $obj else @sh end) | join(" ")), (.srcs[]?)' \
            "$recPath"
        )
        compileLines="$compileLines$setupCmd $tool $argsLine; "
        objPaths="$objPaths $memberObj"
        allSrcs="$allSrcs$theseSrcs
    "
      done < <(printf '%s' "$recordPaths")

      srcsJson=$(printf '%s\n' "$allSrcs" | ${pkgs.jq}/bin/jq -R -s 'split("\n") | map(select(. != "")) | unique')
      dyndrv_build_and_copy "dyndrv-batch-$firstKey" "$archive" \
        "$compileLines${realCommand} $modifiers \$out$objPaths" "$srcsJson"
    else
      # Fallback: resolve every still-pending input individually into its
      # own ordinary per-TU derivation, then run the REAL `ar` against
      # the now-fully-materialized input set.
      while IFS= read -r in; do
        [ -z "$in" ] && continue
        recPath=$(dyndrv_read_batch_stub "$in")
        [ -z "$recPath" ] && continue
        {
          IFS= read -r tool
          IFS= read -r setupCmd
          IFS= read -r argsLine
          IFS= read -r srcsJson
        } < <(
          ${pkgs.jq}/bin/jq -r \
            '.tool, (.setupCmd // ""), (.args | map(if . == "$out" then "\"$out\"" else @sh end) | join(" ")), (.srcs | tojson)' \
            "$recPath"
        )
        dyndrv_build_and_copy "dyndrv-batch-resolved-$(${pkgs.coreutils}/bin/basename "$in")" "$in" \
          "$setupCmd $tool $argsLine" "$srcsJson"
      done < <(printf '%s' "$inputs")

      exec "${realCommand}" "$@"
    fi
  '';
}
