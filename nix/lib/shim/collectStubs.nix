{ pkgs, lib, self }:

# The whole-build-tree resolution pass that replaces the earlier live
# `wrapArchiver` shim: `shim.wrapCommand` now defers EVERY intercepted
# `cc`/`ar` invocation unconditionally (see wrapCommand.nix's own header
# for why -- `builder-rpc-v0` cannot realize a derivation from inside a
# running script, so there is no "materialize now" option anymore). This
# file runs ONCE, at the end of `buildPhase`, after the real build tool
# has finished running against a tree full of batch-pending stubs (see
# `batchStub.nix`) instead of real objects/archives/binaries.
#
# WHAT IT DOES, in order:
#   1. Walks the whole build tree, finds every stub, reads its JSON
#      record (written by `wrapCommand.nix`'s `defer` branch) and walks
#      its `chainedFrom` pointer (if any) back to every EARLIER record
#      chained onto the SAME output path (see `dyndrv_record_chain`
#      below, and `wrapCommand.nix`'s own header comment for why this
#      chaining exists: `ar cr liba.a *.o` followed by `ranlib liba.a`
#      both defer against the identical path, and the second must not
#      silently discard the first's own record -- including its
#      dependency on every compiled `.o`).
#   2. Computes each stub's DEPS generically, by scanning its own
#      record's `args` for other stubs' relative paths (an `ar`/link
#      step's positional inputs are exactly the relative paths its
#      compile/archive dependencies were told to write to -- a compile
#      stub never has deps, since only `cc`/`ar` are intercepted; a
#      generated header from some OTHER tool is real content already
#      sitting in the tree, not a stub).
#   3. Topologically sorts all stubs (Kahn's algorithm, ported to bash --
#      see `dyndrv_topo_sort` below), then groups them into UNITS: a
#      stub with its own explicit `key` (an opted-in batch member, e.g. a
#      `shouldBatch`-selected compile) joins that unit directly; a stub
#      with NO key of its own (e.g. an `ar`/link step) joins its
#      dependencies' shared unit IFF every one of its deps belongs to the
#      SAME real (non-solo) unit -- mirroring the earlier live
#      `wrapArchiver`'s own "allPending && sameKey" rule, generalized
#      beyond just `ar`. Anything else is its own solo unit. This is the
#      exact same "unit" concept `graph/compile.nix`'s `unitKeyOf`/
#      `membersByUnit` implement for an eval-time-known graph -- read
#      that file first, this is a direct bash port of its algorithm
#      operating on a graph discovered at BUILD time instead.
#   4. Registers one `nix derivation add` per unit (never realizes any of
#      them -- `builder-rpc-v0` permits registration only; a merged
#      unit's members run sequentially inside ONE builder script, each
#      member's own "$out" sentinel rewritten to its own per-member
#      output variable, exactly like `graph/compile.nix`'s
#      `renderUnit`/`rewrittenCmdOf`), wiring cross-unit references via
#      the SAME bash port of `DownstreamPlaceholder::unknownCaOutput`
#      `graph/compile.nix`'s `placeholderBashFn` already implements
#      (copied here verbatim -- it's pure bash, no eval-time dependency).
#   5. Registers one FINAL node: the ORIGINAL tree (source files, real
#      generated headers, Makefiles, ... -- everything that ISN'T a
#      stub, added to the store as one snapshot via `nix store add`,
#      preserving directory structure) with every stub's own relative
#      path replaced by a symlink to its owning unit's real (not yet
#      built) output -- a generalization of `graph/compile.nix`'s
#      "assemble" `toOutput` mode (copy every node's output into one
#      tree), here overlaying resolved outputs onto the ORIGINAL tree's
#      own structure instead of a flat directory of per-node symlinks,
#      since `installPhase` (run afterward, in an ordinary second
#      derivation -- see `phases/split.nix`) expects the ordinary,
#      unmodified build-tree layout `make install` was always going to
#      see.
#   6. Submits that final node's output via `nix store submit-output`.
#
# Nothing is actually BUILT by this script itself -- every unit is
# merely registered, wired together via placeholders, and the outer
# `nix build` that eventually resolves the submitted final output is
# what triggers Nix's own scheduler to build every unit, in the correct
# order, for real. This is the same deferred-resolution model
# `graph.compile`'s own generated script already relies on.
#
# `buildRoot`: the directory to walk (relative or absolute) -- normally
#   "." (the build's own cwd at the point this script runs, i.e. right
#   after the real build tool finishes).
# `nixPackage`: the Nix to run `nix derivation add`/`nix store add`/
#   `nix hash convert`/`nix eval` with, inside the sandbox.
# `name`: MUST match the outer `mkDynamicDerivation` call's expected inner
#   name exactly (i.e. `"${pname}-${version}"`) -- same requirement
#   `graph.compile`'s own `name` argument documents, for the same reason
#   (a CA/text-hashed derivation's output path is a function of its
#   declared name; a mismatch fails at realization time with "derivation
#   has incorrect output", one level removed from anything a caller of
#   `phases.split` wrote directly).

{
  buildRoot ? ".",
  nixPackage ? pkgs.nix,
  name,
}:

let
  inherit (self.shim.batchStub) readStubFn;

  # Generic Kahn's-algorithm topological sort, operating via bash
  # namerefs (bash >=4.3) so it can be reused for BOTH the stub-level
  # sort and the unit-level sort below, exactly as `graph/compile.nix`
  # reuses `graph.topoSort` twice (once implicitly, via the already-
  # topologically-valid eval-time node order; once explicitly, over the
  # synthesized unit graph). Throws (via a clear stderr message + exit 1)
  # on a real dependency cycle, matching `topoSort.nix`'s own behavior.
  #
  # $1: name of the array to fill with the sorted order.
  # $2: name of the array holding every node key to sort.
  # $3: name of an associative array mapping node key -> ITS OWN
  #     space-separated string of dep keys (missing keys default to "").
  topoSortFn = ''
    dyndrv_topo_sort() {
      local -n _dts_result="$1" _dts_nodes="$2" _dts_deps="$3"
      _dts_result=()
      local -A _dts_resolved=()
      local -a _dts_remaining=("''${_dts_nodes[@]}")
      while [ "''${#_dts_remaining[@]}" -gt 0 ]; do
        local -a _dts_ready=() _dts_rest=()
        local _dts_n _dts_d _dts_ok
        for _dts_n in "''${_dts_remaining[@]}"; do
          _dts_ok=1
          for _dts_d in ''${_dts_deps[$_dts_n]:-}; do
            if [ -z "''${_dts_resolved[$_dts_d]:-}" ]; then
              _dts_ok=0
              break
            fi
          done
          if [ "$_dts_ok" = 1 ]; then
            _dts_ready+=("$_dts_n")
          else
            _dts_rest+=("$_dts_n")
          fi
        done
        if [ "''${#_dts_ready[@]}" -eq 0 ]; then
          echo "dyndrv.shim.collectStubs: dependency cycle detected among: ''${_dts_remaining[*]}" >&2
          exit 1
        fi
        for _dts_n in "''${_dts_ready[@]}"; do
          _dts_result+=("$_dts_n")
          _dts_resolved[$_dts_n]=1
        done
        _dts_remaining=("''${_dts_rest[@]}")
      done
    }
  '';

  # Bash port of `DownstreamPlaceholder::unknownCaOutput`, copied
  # VERBATIM from `graph/compile.nix`'s own `placeholderBashFn` (that
  # file's the reference implementation/oracle for this formula in this
  # codebase -- see its own comment for the full derivation) rather than
  # re-derived here, so the two can't silently drift apart.
  placeholderBashFn = ''
    dyndrv_placeholder() {
      local drvPath="$1" outputName="''${2:-out}"
      local drvBase drvHashPart drvName outputPathName clearText hashHex
      drvBase=$(basename "$drvPath")
      drvHashPart="''${drvBase%%-*}"
      drvName="''${drvBase#*-}"
      drvName="''${drvName%.drv}"
      if [[ "$outputName" == "out" ]]; then
        outputPathName="$drvName"
      else
        outputPathName="$drvName-$outputName"
      fi
      clearText="nix-upstream-output:$drvHashPart:$outputPathName"
      hashHex=$(printf '%s' "$clearText" | sha256sum | cut -d' ' -f1)
      echo "/$(nix hash convert --to nix32 --from base16 --hash-algo sha256 "$hashHex")"
    }
  '';

  # Walks a stub's own `chainedFrom` pointer (see `wrapCommand.nix`'s
  # `finalizeTail`) back to every EARLIER record chained onto the SAME
  # output path -- `ar cr liba.a *.o` followed by `ranlib liba.a`, both
  # deferred against the identical archive path, is the real case this
  # exists for. $2 is the NEWEST (head) record path; fills $1 (a bash
  # array name) with every record in the chain, OLDEST first, so callers
  # can render/union them in the order they were actually meant to run.
  recordChainFn = ''
    dyndrv_record_chain() {
      local -n _drc_result="$1"
      local _drc_rec="$2" _drc_from
      _drc_result=()
      local -a _drc_newestFirst=("$_drc_rec")
      while true; do
        _drc_from=$(${pkgs.jq}/bin/jq -r '.chainedFrom // ""' "$_drc_rec")
        [ -z "$_drc_from" ] && break
        _drc_newestFirst+=("$_drc_from")
        _drc_rec="$_drc_from"
      done
      local _drc_i
      for (( _drc_i = ''${#_drc_newestFirst[@]} - 1; _drc_i >= 0; _drc_i-- )); do
        _drc_result+=("''${_drc_newestFirst[$_drc_i]}")
      done
    }
  '';
in
{
  # The whole collection script. Callers append this to `buildPhase`,
  # AFTER the real build tool has run to completion against a tree full
  # of deferred stubs, and BEFORE `runHook postBuild`/`nix store
  # submit-output` -- this script itself performs the final
  # `submit-output` call, so nothing else needs to.
  collectScript = ''
    export PATH="${nixPackage}/bin:$PATH"
    export NIX_CONFIG='extra-experimental-features = nix-command ca-derivations dynamic-derivations'

    ${readStubFn}
    ${topoSortFn}
    ${placeholderBashFn}
    ${recordChainFn}

    dyndrv_buildRoot=${lib.escapeShellArg buildRoot}

    # Phase 1: discover every stub under buildRoot; read each one's own
    # record path and `key` (empty/missing means "not opted into a batch
    # group" -- exactly `shouldBatch`'s own default).
    declare -A DYNDRV_STUB_RECORD=()
    declare -A DYNDRV_STUB_KEY=()
    dyndrv_stubPaths=()
    while IFS= read -r -d "" _dcs_f; do
      _dcs_rel="''${_dcs_f#$dyndrv_buildRoot/}"
      _dcs_rec=$(dyndrv_read_batch_stub "$_dcs_f")
      [ -z "$_dcs_rec" ] && continue
      DYNDRV_STUB_RECORD[$_dcs_rel]="$_dcs_rec"
      DYNDRV_STUB_KEY[$_dcs_rel]=$(${pkgs.jq}/bin/jq -r '.key // ""' "$_dcs_rec")
      dyndrv_stubPaths+=("$_dcs_rel")
    done < <(find "$dyndrv_buildRoot" -type f -print0)

    # Phase 2: compute each stub's deps generically -- any of its OWN
    # record's `args` entries that name another discovered stub's own
    # relative path IS a dependency edge (see this file's header comment
    # for why this needs no extra schema field: a leaf compile's args
    # only ever name real source files, never another stub, and an
    # `ar`/link step's positional inputs are exactly the relative paths
    # its own dependencies were told to produce). Scans EVERY record in
    # the chain (see `dyndrv_record_chain`), not just the head -- an
    # `ar cr liba.a *.o` step chained under a later `ranlib liba.a`
    # still depends on every `.o` its OWN (now non-head) record names.
    declare -A DYNDRV_IS_STUB=()
    for _dcs_p in "''${dyndrv_stubPaths[@]}"; do DYNDRV_IS_STUB[$_dcs_p]=1; done

    declare -A DYNDRV_STUB_DEPS=()
    for _dcs_p in "''${dyndrv_stubPaths[@]}"; do
      _dcs_deps=""
      dyndrv_record_chain _dcs_chain "''${DYNDRV_STUB_RECORD[$_dcs_p]}"
      for _dcs_rec in "''${_dcs_chain[@]}"; do
        while IFS= read -r _dcs_a; do
          [ -z "$_dcs_a" ] && continue
          [ "$_dcs_a" = "$_dcs_p" ] && continue
          if [ -n "''${DYNDRV_IS_STUB[$_dcs_a]:-}" ]; then
            _dcs_deps="$_dcs_deps $_dcs_a"
          fi
        done < <(${pkgs.jq}/bin/jq -r '.args[]? | select(type == "string")' "$_dcs_rec")
      done
      DYNDRV_STUB_DEPS[$_dcs_p]="$_dcs_deps"
    done

    # Phase 3: global topological order over every discovered stub.
    dyndrv_topo_sort DYNDRV_STUB_ORDER dyndrv_stubPaths DYNDRV_STUB_DEPS

    # Phase 4: assign each stub to a UNIT, in topo order (so a stub's
    # deps' own unit assignments are already known by the time it's this
    # stub's turn) -- see this file's header comment for the merge rule.
    declare -A DYNDRV_UNIT_OF=()
    for _dcs_p in "''${DYNDRV_STUB_ORDER[@]}"; do
      _dcs_k="''${DYNDRV_STUB_KEY[$_dcs_p]}"
      if [ -n "$_dcs_k" ]; then
        DYNDRV_UNIT_OF[$_dcs_p]="$_dcs_k"
        continue
      fi
      _dcs_shared="" _dcs_allSame=1 _dcs_hasDeps=0
      for _dcs_d in ''${DYNDRV_STUB_DEPS[$_dcs_p]}; do
        _dcs_hasDeps=1
        _dcs_du="''${DYNDRV_UNIT_OF[$_dcs_d]}"
        if [ -z "$_dcs_shared" ]; then
          _dcs_shared="$_dcs_du"
        elif [ "$_dcs_du" != "$_dcs_shared" ]; then
          _dcs_allSame=0
        fi
      done
      if [ "$_dcs_hasDeps" = 1 ] && [ "$_dcs_allSame" = 1 ] && [[ "$_dcs_shared" != __dyndrv_solo:* ]]; then
        DYNDRV_UNIT_OF[$_dcs_p]="$_dcs_shared"
      else
        DYNDRV_UNIT_OF[$_dcs_p]="__dyndrv_solo:$_dcs_p"
      fi
    done

    # Phase 5: group members by unit (preserving the global topo order
    # computed above -- a subsequence of a valid topological order
    # remains valid for the induced subgraph, so THIS order is already
    # correct for rendering a merged unit's members sequentially,
    # exactly as `graph/compile.nix`'s own header comment notes for its
    # eval-time equivalent). Each member gets a sanitized, unique-within-
    # its-unit OUTPUT NAME (a derivation output name/shell-variable name
    # can't contain "/", so a member's own relative path is flattened).
    declare -A DYNDRV_UNIT_MEMBERS=()
    declare -A DYNDRV_OUTPUT_NAME=()
    dyndrv_unitKeys=()
    declare -A DYNDRV_SEEN_UNIT=()
    for _dcs_p in "''${DYNDRV_STUB_ORDER[@]}"; do
      _dcs_u="''${DYNDRV_UNIT_OF[$_dcs_p]}"
      DYNDRV_UNIT_MEMBERS[$_dcs_u]="''${DYNDRV_UNIT_MEMBERS[$_dcs_u]:-}$_dcs_p "
      DYNDRV_OUTPUT_NAME[$_dcs_p]=$(printf '%s' "$_dcs_p" | tr -c 'a-zA-Z0-9' '_')
      if [ -z "''${DYNDRV_SEEN_UNIT[$_dcs_u]:-}" ]; then
        dyndrv_unitKeys+=("$_dcs_u")
        DYNDRV_SEEN_UNIT[$_dcs_u]=1
      fi
    done

    # Phase 6: unit-level deps -- any dep of any member that resolves to
    # a DIFFERENT unit than this one. Two units whose members have a
    # dependency edge crossing between them must still register in the
    # correct relative order, even though grouping can put topologically
    # distant stubs in the same unit -- exactly `graph/compile.nix`'s own
    # `unitGraphNodes` rationale.
    declare -A DYNDRV_UNIT_DEPS=()
    for _dcs_u in "''${dyndrv_unitKeys[@]}"; do
      _dcs_deps=""
      for _dcs_p in ''${DYNDRV_UNIT_MEMBERS[$_dcs_u]}; do
        for _dcs_d in ''${DYNDRV_STUB_DEPS[$_dcs_p]}; do
          _dcs_du="''${DYNDRV_UNIT_OF[$_dcs_d]}"
          if [ "$_dcs_du" != "$_dcs_u" ]; then
            case " $_dcs_deps " in
              *" $_dcs_du "*) ;;
              *) _dcs_deps="$_dcs_deps $_dcs_du" ;;
            esac
          fi
        done
      done
      DYNDRV_UNIT_DEPS[$_dcs_u]="$_dcs_deps"
    done

    dyndrv_topo_sort DYNDRV_UNIT_ORDER dyndrv_unitKeys DYNDRV_UNIT_DEPS

    # Phase 7: register one derivation per unit, in unit-topo order,
    # wiring cross-unit `inputs.drvs` + placeholder substitution against
    # already-registered upstream units' real drvPaths -- mirrors
    # `graph/compile.nix`'s `renderUnitScript` exactly, just operating on
    # bash associative arrays instead of eval-time attrsets.
    #
    # `dyndrv_sq`: single-quote a string for safe embedding in a
    # `/bin/sh -c` command line, escaping any literal single-quote via
    # the standard POSIX-shell escape sequence -- mirrors
    # `mkAcceleratedStdenv.nix`'s own `shellQuote`, needed here for the
    # same reason: `builder` is invoked directly, not through a shell,
    # so only the SCRIPT text itself (the `-c "<this>"` argument) is
    # ever shell-interpreted.
    dyndrv_sq() {
      local s="$1"
      printf "'%s'" "''${s//\'/\'\\\'\'}"
    }

    # Renders ONE member's own command line, substituting:
    #   - the literal sentinel "$out" -> this member's own output
    #     variable (`$out` for a solo unit, `$<outputName>` for a merged
    #     member -- Nix's own derivation ABI: output "foo" is seen as
    #     `$foo` inside the builder, exactly like a solo derivation's
    #     "out" is seen as `$out`).
    # Renders EVERY step in the member's own record CHAIN (see
    # `dyndrv_record_chain`), oldest first, joined with "; " into ONE
    # combined command line -- `ar cr liba.a *.o` followed by `ranlib
    # liba.a` both operate on the SAME output path in sequence, so both
    # steps need to run, in order, against that one path.
    #
    # ONE `jq` call per chain record, not four: `tool`/`setupCmd`/`srcs`/
    # `args` are all read together (`tool`, `setupCmd`, `srcs` joined by
    # a `` separator, then each `args[]` string entry, one per
    # line -- variable-length `args` output goes LAST so the fixed-count
    # fields can be consumed by three ordinary `read`s first). Confirmed
    # the dominant per-unit cost here is `jq`'s own fork+exec, not the
    # JSON parsing itself, so cutting CALL COUNT (this collapses what
    # were 3 separate calls in `dyndrv_render_member` plus a 4th,
    # separate chain-walking call each caller used to make for `srcs`,
    # into 1 call per chain record total) matters far more than cutting
    # bytes parsed.
    #
    # Echoes THREE things: `setupCmd` (line 1, the union of every step's
    # own setup command, concatenated oldest-first), `cmdLine` (line 2,
    # the combined tool+args command line), and `srcs` (the remainder of
    # the stream, NOT a fixed line count since a member can reference
    # arbitrarily many store paths -- callers slurp this with a
    # NUL-delimited `read` after consuming the first two lines) -- this
    # member's own, not-yet-deduplicated `srcs`, one per line. Callers
    # fold this directly into their own running `srcs` accumulator
    # instead of re-walking the chain themselves via their own separate
    # `dyndrv_record_chain` call, which is what the earlier, less minimal
    # version of this function required.
    dyndrv_render_member() {
      local p="$1" ownOutVar="$2" u="$3"
      local setupCmd="" cmdLine="" srcs="" tool thisSetupCmd theseSrcs argsLine a rec
      local -a chain
      dyndrv_record_chain chain "''${DYNDRV_STUB_RECORD[$1]}"
      for rec in "''${chain[@]}"; do
        {
          IFS= read -r tool
          IFS= read -r thisSetupCmd
          IFS= read -r theseSrcs
          argsLine=""
          while IFS= read -r a; do
            if [ "$a" = '$out' ]; then
              argsLine="$argsLine $ownOutVar"
            elif [ -n "''${DYNDRV_IS_STUB[$a]:-}" ]; then
              if [ "''${DYNDRV_UNIT_OF[$a]}" = "$u" ]; then
                argsLine="$argsLine \$''${DYNDRV_OUTPUT_NAME[$a]}"
              else
                argsLine="$argsLine @dyndrv-node-placeholder:''${DYNDRV_UNIT_OF[$a]}:$a@"
              fi
            else
              argsLine="$argsLine $(dyndrv_sq "$a")"
            fi
          done
        } < <(${pkgs.jq}/bin/jq -r '
          (.tool),
          (.setupCmd // ""),
          ((.srcs // []) | join("")),
          (.args[]? | select(type == "string"))
        ' "$rec")
        setupCmd="$setupCmd$thisSetupCmd"
        if [ -n "$theseSrcs" ]; then
          srcs="$srcs''${theseSrcs//$'\x01'/$'\n'}
"
        fi
        cmdLine="$cmdLine$tool $argsLine; "
      done
      printf '%s\n%s\n%s' "$setupCmd" "$cmdLine" "$srcs"
    }

    declare -A DYNDRV_DRV_PATH=()
    declare -A DYNDRV_DRV_BASENAME=()

    for _dcs_u in "''${DYNDRV_UNIT_ORDER[@]}"; do
      _dcs_memberList=(''${DYNDRV_UNIT_MEMBERS[$_dcs_u]})

      if [ "''${#_dcs_memberList[@]}" -eq 1 ]; then
        _dcs_p="''${_dcs_memberList[0]}"
        {
          IFS= read -r _dcs_setupCmd
          IFS= read -r _dcs_cmdLine
          IFS= read -r -d "" _dcs_theseSrcs || true
        } < <(dyndrv_render_member "$_dcs_p" '$out' "$_dcs_u")
        _dcs_srcsJson=$(printf '%s\n' "$_dcs_theseSrcs" | ${pkgs.jq}/bin/jq -R -s 'split("\n") | map(select(. != "")) | unique')
        _dcs_drvJson=$(${pkgs.jq}/bin/jq -nc \
          --arg name "dyndrv-''${DYNDRV_OUTPUT_NAME[$_dcs_p]}" \
          --arg system "${builtins.currentSystem}" \
          --arg script "$_dcs_setupCmd $_dcs_cmdLine" \
          --argjson srcs "$_dcs_srcsJson" \
          '{
            name: $name, system: $system, builder: "/bin/sh",
            args: ["-c", $script],
            env: { out: "@dyndrv-self-placeholder:out@" },
            inputs: { drvs: {}, srcs: $srcs },
            outputs: { out: { method: "nar", hashAlgo: "sha256" } },
            version: 4
          }')
      else
        _dcs_cmd="" _dcs_allSrcs="" _dcs_outNamesFile=$(mktemp)
        for _dcs_p in "''${_dcs_memberList[@]}"; do
          _dcs_n="''${DYNDRV_OUTPUT_NAME[$_dcs_p]}"
          printf '%s\n' "$_dcs_n" >> "$_dcs_outNamesFile"
          {
            IFS= read -r _dcs_setupCmd
            IFS= read -r _dcs_cmdLine
            IFS= read -r -d "" _dcs_theseSrcs || true
          } < <(dyndrv_render_member "$_dcs_p" "\$$_dcs_n" "$_dcs_u")
          _dcs_cmd="$_dcs_cmd$_dcs_setupCmd $_dcs_cmdLine"
          _dcs_allSrcs="$_dcs_allSrcs$_dcs_theseSrcs
"
        done
        _dcs_srcsJson=$(printf '%s\n' "$_dcs_allSrcs" | ${pkgs.jq}/bin/jq -R -s 'split("\n") | map(select(. != "")) | unique')
        _dcs_envJson=$(${pkgs.jq}/bin/jq -R -s 'split("\n") | map(select(. != "")) | map({(.): ("@dyndrv-self-placeholder:" + . + "@")}) | add // {}' "$_dcs_outNamesFile")
        rm -f "$_dcs_outNamesFile"
        _dcs_drvJson=$(${pkgs.jq}/bin/jq -nc \
          --arg name "dyndrv-batch-$_dcs_u" \
          --arg system "${builtins.currentSystem}" \
          --arg script "$_dcs_cmd" \
          --argjson env "$_dcs_envJson" \
          --argjson srcs "$_dcs_srcsJson" \
          '{
            name: $name, system: $system, builder: "/bin/sh",
            args: ["-c", $script], env: $env,
            inputs: { drvs: {}, srcs: $srcs },
            outputs: ($env | keys | map({(.): {method:"nar", hashAlgo:"sha256"}}) | add),
            version: 4
          }')
      fi

      # Substitute this unit's own self-placeholder(s) (one per member --
      # a solo unit's single "out", or one per merged member).
      if [ "''${#_dcs_memberList[@]}" -eq 1 ]; then
        _dcs_selfNames="out"
      else
        _dcs_selfNames=""
        for _dcs_p in "''${_dcs_memberList[@]}"; do
          _dcs_selfNames="$_dcs_selfNames ''${DYNDRV_OUTPUT_NAME[$_dcs_p]}"
        done
      fi
      for _dcs_n in $_dcs_selfNames; do
        _dcs_selfPh=$(nix eval --raw --expr "builtins.placeholder \"$_dcs_n\"")
        _dcs_drvJson="''${_dcs_drvJson//@dyndrv-self-placeholder:$_dcs_n@/$_dcs_selfPh}"
      done

      # Wire cross-unit deps into inputs.drvs and substitute this unit's
      # own reference sentinels against each dependency's already-known
      # real drvPath/output name.
      _dcs_inputDrvs='{}'
      for _dcs_du in ''${DYNDRV_UNIT_DEPS[$_dcs_u]}; do
        _dcs_depBase="''${DYNDRV_DRV_BASENAME[$_dcs_du]}"
        _dcs_depOutsFile=$(mktemp)
        _dcs_depMemberList=(''${DYNDRV_UNIT_MEMBERS[$_dcs_du]})
        # Every output name THIS unit actually references on `$du`.
        for _dcs_p in "''${_dcs_memberList[@]}"; do
          for _dcs_d in ''${DYNDRV_STUB_DEPS[$_dcs_p]}; do
            if [ "''${DYNDRV_UNIT_OF[$_dcs_d]}" = "$_dcs_du" ]; then
              if [ "''${#_dcs_depMemberList[@]}" -eq 1 ]; then
                _dcs_depOutName="out"
              else
                _dcs_depOutName="''${DYNDRV_OUTPUT_NAME[$_dcs_d]}"
              fi
              printf '%s\n' "$_dcs_depOutName" >> "$_dcs_depOutsFile"
              _dcs_depPh=$(dyndrv_placeholder "''${DYNDRV_DRV_PATH[$_dcs_du]}" "$_dcs_depOutName")
              _dcs_sentinel="@dyndrv-node-placeholder:$_dcs_du:$_dcs_d@"
              _dcs_drvJson="''${_dcs_drvJson//$_dcs_sentinel/$_dcs_depPh}"
            fi
          done
        done
        _dcs_outsJson=$(sort -u "$_dcs_depOutsFile" | ${pkgs.jq}/bin/jq -R -s 'split("\n") | map(select(. != ""))')
        rm -f "$_dcs_depOutsFile"
        _dcs_inputDrvs=$(printf '%s' "$_dcs_inputDrvs" | ${pkgs.jq}/bin/jq --arg k "$_dcs_depBase" --argjson outs "$_dcs_outsJson" \
          '. + {($k): {"outputs": $outs, "dynamicOutputs": {}}}')
      done
      _dcs_drvJson=$(printf '%s' "$_dcs_drvJson" | ${pkgs.jq}/bin/jq --argjson inputDrvs "$_dcs_inputDrvs" '.inputs.drvs = (.inputs.drvs + $inputDrvs)')

      DYNDRV_DRV_PATH[$_dcs_u]=$(printf '%s' "$_dcs_drvJson" | nix derivation add)
      DYNDRV_DRV_BASENAME[$_dcs_u]=$(basename "''${DYNDRV_DRV_PATH[$_dcs_u]}")
    done

    # Phase 8: the final node -- the ORIGINAL tree (everything that
    # ISN'T a stub), with every stub's own relative path replaced by a
    # symlink to its owning unit's real output. `nix store add`
    # preserves directory structure (unlike `nix store add-file`).
    dyndrv_origTree=$(mktemp -d)/dyndrv-orig-tree
    ${pkgs.coreutils}/bin/mkdir -p "$dyndrv_origTree"
    ${pkgs.coreutils}/bin/cp -r "$dyndrv_buildRoot"/. "$dyndrv_origTree"/
    ${pkgs.coreutils}/bin/chmod -R u+w "$dyndrv_origTree"
    for _dcs_p in "''${dyndrv_stubPaths[@]}"; do
      ${pkgs.coreutils}/bin/rm -f "$dyndrv_origTree/$_dcs_p"
    done
    dyndrv_origTreePath=$(nix store add "$dyndrv_origTree")
    dyndrv_origTreeBasename=$(basename "$dyndrv_origTreePath")

    _dcs_finalCopyLines="${pkgs.coreutils}/bin/mkdir -p \$out; ${pkgs.coreutils}/bin/cp -r ${builtins.storeDir}/$dyndrv_origTreeBasename/. \$out/; ${pkgs.coreutils}/bin/chmod -R u+w \$out; "
    for _dcs_p in "''${dyndrv_stubPaths[@]}"; do
      _dcs_finalCopyLines="$_dcs_finalCopyLines${pkgs.coreutils}/bin/mkdir -p \"\$(${pkgs.coreutils}/bin/dirname \"\$out/$_dcs_p\")\"; ${pkgs.coreutils}/bin/ln -s \"@dyndrv-final-placeholder:$_dcs_p@\" \"\$out/$_dcs_p\"; "
    done

    _dcs_finalDrvJson=$(${pkgs.jq}/bin/jq -nc \
      --arg name ${lib.escapeShellArg name} \
      --arg system "${builtins.currentSystem}" \
      --arg script "$_dcs_finalCopyLines" \
      --arg src "$dyndrv_origTreeBasename" \
      --arg coreutilsSrc ${lib.escapeShellArg (builtins.baseNameOf "${pkgs.coreutils}")} \
      '{
        name: $name, system: $system, builder: "/bin/sh",
        args: ["-c", $script],
        env: { out: "@dyndrv-self-placeholder:out@" },
        inputs: { drvs: {}, srcs: [$src, $coreutilsSrc] },
        outputs: { out: { method: "nar", hashAlgo: "sha256" } },
        version: 4
      }')
    _dcs_finalSelfPh=$(nix eval --raw --expr 'builtins.placeholder "out"')
    _dcs_finalDrvJson="''${_dcs_finalDrvJson//@dyndrv-self-placeholder:out@/$_dcs_finalSelfPh}"

    _dcs_finalInputDrvs='{}'
    for _dcs_p in "''${dyndrv_stubPaths[@]}"; do
      _dcs_u="''${DYNDRV_UNIT_OF[$_dcs_p]}"
      _dcs_memberList=(''${DYNDRV_UNIT_MEMBERS[$_dcs_u]})
      if [ "''${#_dcs_memberList[@]}" -eq 1 ]; then
        _dcs_outName="out"
      else
        _dcs_outName="''${DYNDRV_OUTPUT_NAME[$_dcs_p]}"
      fi
      _dcs_depPh=$(dyndrv_placeholder "''${DYNDRV_DRV_PATH[$_dcs_u]}" "$_dcs_outName")
      _dcs_finalDrvJson="''${_dcs_finalDrvJson//@dyndrv-final-placeholder:$_dcs_p@/$_dcs_depPh}"
      _dcs_depBase="''${DYNDRV_DRV_BASENAME[$_dcs_u]}"
      _dcs_finalInputDrvs=$(printf '%s' "$_dcs_finalInputDrvs" | ${pkgs.jq}/bin/jq --arg k "$_dcs_depBase" --arg o "$_dcs_outName" \
        '.[$k].outputs = ((.[$k].outputs // []) + [$o] | unique) | .[$k].dynamicOutputs = (.[$k].dynamicOutputs // {})')
    done
    _dcs_finalDrvJson=$(printf '%s' "$_dcs_finalDrvJson" | ${pkgs.jq}/bin/jq --argjson inputDrvs "$_dcs_finalInputDrvs" '.inputs.drvs = (.inputs.drvs + $inputDrvs)')

    _dcs_finalDrvPath=$(printf '%s' "$_dcs_finalDrvJson" | nix derivation add)
    nix store submit-output "$_dcs_finalDrvPath" out
  '';
}
