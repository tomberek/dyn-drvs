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

  # Joins a record's own `cwd` (relative to `NIX_BUILD_TOP` -- see
  # `wrapCommand.nix`'s own header comment on `DYNDRV_INVOCATION_CWD`)
  # with one of its own `args` entries (relative to THAT cwd), then
  # normalizes the result onto the SAME `NIX_BUILD_TOP`-relative frame
  # every discovered stub's own key already uses (Phase 1's `dyndrv_
  # buildRoot`-relative scan) -- pure string path arithmetic (splits on
  # "/", collapses ".." against the preceding non-".." segment, drops
  # "."/empty segments), no filesystem check, since the argument may
  # name a stub that doesn't exist as a real file yet. Reconciles the
  # exact cwd-relative-path-frame mismatch that silently dropped a link
  # step's own dependency on an earlier compile step run from a
  # DIFFERENT cwd -- confirmed by direct reproduction: a cmake-style `cd
  # build && cc CMakeFiles/.../a.o -o exe` link, where the compile that
  # produced that `.o` ran from the package's own root instead, so the
  # link's own `args` entry ("CMakeFiles/.../a.o") and the compile's own
  # discovered stub key ("build/CMakeFiles/.../a.o") were two different
  # strings for the identical real file. `cwd == ""` (the common case,
  # every OTHER example/fixture this accelerator has been run against
  # so far never needed this at all) is a pure identity join.
  joinRelFn = ''
    dyndrv_join_rel() {
      local cwd="$1" rel="$2" joined
      if [ -z "$cwd" ] || [ "$cwd" = "." ]; then
        joined="$rel"
      else
        joined="$cwd/$rel"
      fi
      local -a parts result=()
      IFS='/' read -r -a parts <<< "$joined"
      local seg
      for seg in "''${parts[@]}"; do
        case "$seg" in
          "" | ".") continue ;;
          "..")
            if [ "''${#result[@]}" -gt 0 ] && [ "''${result[-1]}" != ".." ]; then
              unset 'result[-1]'
            else
              result+=("..")
            fi
            ;;
          *) result+=("$seg") ;;
        esac
      done
      local IFS='/'
      printf '%s' "''${result[*]:-}"
    }
  '';

  # Computes path B relative to path A, where BOTH are already relative
  # to the SAME anchor (here, `NIX_BUILD_TOP`) -- pure segment-prefix
  # arithmetic (drop the longest common leading-segment prefix, then
  # `..` back out of whatever's left of A, followed by whatever's left
  # of B), no filesystem check. Needed because `wrapCommand.nix`'s own
  # `DYNDRV_INVOCATION_CWD` is captured relative to `NIX_BUILD_TOP` (the
  # one anchor stable across the WHOLE sandboxed build -- see that
  # file's own header comment), but `collectStubs`' own stub keys are
  # relative to `dyndrv_buildRoot` specifically (usually a SUBDIRECTORY
  # of `NIX_BUILD_TOP`, e.g. `/build/source` under `/build` -- `unpackPhase`
  # creates it, it is NOT the sandbox root itself). Confirmed necessary
  # by direct reproduction: without this step, an ORDINARY compile with
  # no cwd mismatch at all (cwd == buildRoot) still got a non-empty
  # `record.cwd` (e.g. "source", buildRoot's own offset from
  # `NIX_BUILD_TOP`), corrupting `dyndrv_join_rel`'s join for every
  # single invocation, not just the ones that actually need it -- a real
  # regression against example 05's own baseline link step
  # ("cannot find main.o"). Called once per record, converting its own
  # `NIX_BUILD_TOP`-relative `cwd` into a `dyndrv_buildRoot`-relative one
  # BEFORE `dyndrv_join_rel` ever runs, so stub keys and joined args
  # references land on the exact same frame.
  relativeBetweenFn = ''
    dyndrv_relative_between() {
      local from="$1" to="$2"
      local -a fromSegs toSegs fromF=() toF=()
      IFS='/' read -r -a fromSegs <<< "$from"
      IFS='/' read -r -a toSegs <<< "$to"
      local seg
      for seg in "''${fromSegs[@]}"; do [ -n "$seg" ] && [ "$seg" != "." ] && fromF+=("$seg"); done
      for seg in "''${toSegs[@]}"; do [ -n "$seg" ] && [ "$seg" != "." ] && toF+=("$seg"); done
      local k=0
      while [ "$k" -lt "''${#fromF[@]}" ] && [ "$k" -lt "''${#toF[@]}" ] && [ "''${fromF[$k]}" = "''${toF[$k]}" ]; do
        k=$((k + 1))
      done
      local -a result=()
      local i
      for (( i = k; i < ''${#fromF[@]}; i++ )); do result+=(".."); done
      for (( i = k; i < ''${#toF[@]}; i++ )); do result+=("''${toF[$i]}"); done
      local IFS='/'
      printf '%s' "''${result[*]:-}"
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
    ${joinRelFn}
    ${relativeBetweenFn}

    dyndrv_buildRoot=${lib.escapeShellArg buildRoot}
    # `dyndrv_buildRoot`'s own position relative to `NIX_BUILD_TOP` --
    # the anchor `wrapCommand.nix`'s own `DYNDRV_INVOCATION_CWD` is
    # relative to (see that file's header comment). Pure string
    # arithmetic, computed ONCE here rather than per-record, since every
    # record's own `cwd` needs the SAME conversion before it can be
    # compared against a stub key relative to `dyndrv_buildRoot`.
    dyndrv_buildRootTop=$(${pkgs.coreutils}/bin/realpath -m --relative-to="''${NIX_BUILD_TOP:-/build}" "$dyndrv_buildRoot")

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
        _dcs_recCwd=$(${pkgs.jq}/bin/jq -r '.cwd // ""' "$_dcs_rec")
        # Convert this record's own `cwd` (relative to `NIX_BUILD_TOP`,
        # see `wrapCommand.nix`'s own header comment) into a `dyndrv_
        # buildRoot`-relative one, matching the frame every discovered
        # stub key already uses -- see `dyndrv_relative_between`'s own
        # header comment for why this conversion is required even for
        # the ordinary case (cwd == buildRoot), not just the mismatch
        # case.
        _dcs_recCwdRel=$(dyndrv_relative_between "$dyndrv_buildRootTop" "$_dcs_recCwd")
        while IFS= read -r _dcs_a; do
          [ -z "$_dcs_a" ] && continue
          # Join this arg against ITS OWN record's `cwd` (already
          # converted to `dyndrv_buildRoot`-relative form above) before
          # comparing against a discovered stub's own key -- both are
          # then on the SAME frame, reconciling a link step's own args
          # (relative to ITS cwd) with an earlier compile's own
          # discovered stub path (relative to `dyndrv_buildRoot`) even
          # when the two invocations ran from different directories. A
          # no-op join when `cwd` is empty (the common case -- every
          # OTHER example/fixture this accelerator has been run against
          # so far never needed this at all).
          _dcs_key=$(dyndrv_join_rel "$_dcs_recCwdRel" "$_dcs_a")
          [ "$_dcs_key" = "$_dcs_p" ] && continue
          if [ -n "''${DYNDRV_IS_STUB[$_dcs_key]:-}" ]; then
            _dcs_deps="$_dcs_deps $_dcs_key"
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
      local setupCmd="" cmdLine="" srcs="" tool thisSetupCmd thisChdir thisCwd thisCwdRel theseSrcs argsLine a key rec
      local -a chain
      dyndrv_record_chain chain "''${DYNDRV_STUB_RECORD[$1]}"
      for rec in "''${chain[@]}"; do
        {
          IFS= read -r tool
          IFS= read -r thisSetupCmd
          IFS= read -r thisChdir
          IFS= read -r thisCwd
          IFS= read -r theseSrcs
          # See Phase 2's own matching comment on `dyndrv_relative_
          # between` -- converts THIS record's own `cwd` from `NIX_
          # BUILD_TOP`-relative to `dyndrv_buildRoot`-relative BEFORE
          # joining against any of its own `args`, required even in the
          # ordinary (no mismatch) case since `dyndrv_buildRoot` is
          # itself a subdirectory of `NIX_BUILD_TOP`, not `NIX_BUILD_TOP`
          # itself.
          thisCwdRel=$(dyndrv_relative_between "$dyndrv_buildRootTop" "$thisCwd")
          argsLine=""
          while IFS= read -r a; do
            # Join against THIS record's own `cwd` (see `wrapCommand.
            # nix`'s own header comment on `DYNDRV_INVOCATION_CWD`)
            # before checking self-reference/stub-ness -- reconciles a
            # link step's own `args` (relative to ITS cwd) with an
            # earlier compile's own discovered stub path (relative to
            # `dyndrv_buildRoot`), same as Phase 2's identical join. The
            # ORIGINAL (unjoined) text `$a` is still what gets rendered
            # for a non-stub reference below (`dyndrv_sq "$a"`) -- only
            # the LOOKUP key changes, never the literal argv text a
            # non-stub reference renders as.
            key=$(dyndrv_join_rel "$thisCwdRel" "$a")
            if [ "$a" = '$out' ]; then
              argsLine="$argsLine $ownOutVar"
            elif [ "$key" = "$p" ]; then
              # This argv element is a REFERENCE TO THIS SAME COMPILE'S
              # OWN OUTPUT PATH (e.g. `-MQ <objpath>` alongside `-o
              # <objpath>`, both naming the identical real path -- ninja/
              # meson generate this pair directly, no `$out` sentinel
              # substitution involved) -- confirmed by direct
              # reproduction against a real meson build (NixOS/nix's own
              # `nix-util` component): a compile's own output path is
              # ITSELF a discovered stub the moment its `.o` gets
              # written (that's how deferral works), so without this
              # check the generic `DYNDRV_IS_STUB` branch below matched
              # it and substituted the MERGED-unit member-reference form
              # (`$<sanitized-name>`) instead of `$ownOutVar` -- wrong
              # for a solo unit (`$out` is never bound under that
              # sanitized name at all, an undefined-variable reference
              # gcc then saw as a missing/empty `-MQ` argument, shifting
              # every argv element after it and producing "cannot
              # specify '-o' with '-c'... with multiple files"). Must be
              # checked BEFORE the generic `DYNDRV_IS_STUB` branch, which
              # would otherwise match this exact same case first.
              argsLine="$argsLine $ownOutVar"
            elif [ -n "''${DYNDRV_IS_STUB[$key]:-}" ]; then
              if [ "''${DYNDRV_UNIT_OF[$key]}" = "$u" ]; then
                argsLine="$argsLine \$''${DYNDRV_OUTPUT_NAME[$key]}"
              else
                argsLine="$argsLine @dyndrv-node-placeholder:''${DYNDRV_UNIT_OF[$key]}:$key@"
              fi
            else
              argsLine="$argsLine $(dyndrv_sq "$a")"
            fi
          done
        } < <(${pkgs.jq}/bin/jq -r '
          (.tool),
          (.setupCmd // ""),
          (.chdir // ""),
          (.cwd // ""),
          ((.srcs // []) | join("")),
          (.args[]? | select(type == "string"))
        ' "$rec")
        setupCmd="$setupCmd$thisSetupCmd"
        if [ -n "$theseSrcs" ]; then
          srcs="$srcs''${theseSrcs//$'\x01'/$'\n'}
"
        fi
        # `thisChdir` (see `mkAcceleratedStdenv.nix`'s own header
        # comment on why this is a SEPARATE record field, not baked
        # into `setupCmd` as a bare `cd`): wraps ONLY this one record's
        # own `tool $argsLine` invocation in a `( cd ... && ... )`
        # subshell, so a merged unit's LATER member's own `setupCmd`
        # (its `cp -r`, run in the shared, unmodified build root) is
        # never affected by an EARLIER member's nested cwd -- the
        # subshell's own cwd change is invisible outside it.
        if [ -n "$thisChdir" ]; then
          cmdLine="$cmdLine( cd $(dyndrv_sq "$thisChdir") && $tool $argsLine ); "
        else
          cmdLine="$cmdLine$tool $argsLine; "
        fi
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
          --arg system "${pkgs.stdenv.hostPlatform.system}" \
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
          --arg system "${pkgs.stdenv.hostPlatform.system}" \
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
    # Phase 1's own absolute cwd, relative to `NIX_BUILD_TOP` (already
    # computed above as `dyndrv_buildRootTop`, for the UNRELATED cwd-
    # relative-path-frame reconciliation) -- written here UNCONDITIONALLY
    # (not gated on meson's own `build.ninja` marker, as this used to
    # be) so `phases/split.nix`'s own phase 2 can ALWAYS reconstruct
    # this exact same absolute position, regardless of which build
    # system generated phase 1's build state. Confirmed necessary by
    # direct reproduction against real nixpkgs `capnproto` (cmake+make,
    # no meson involved at all): cmake's own generated `Makefile`
    # re-invokes `cmake --check-build-system` against the ABSOLUTE
    # source directory baked into `CMakeCache.txt` during phase 1's
    # `configurePhase` (`CMAKE_HOME_DIRECTORY`) -- with the old meson-
    # only gate, phase 2 never reconstructed that position at all,
    # failing at `installPhase` with `CMake Error: The source directory
    # "/build/source" does not exist` even though every real compile
    # and link had ALREADY succeeded. `dyndrvCdToBuildDir` (the
    # consumer, `phases/split.nix`) treats a `"."` relpath (the common
    # case: phase 1 never `cd`ed anywhere beyond `dyndrv_buildRoot`
    # itself) as a pure no-op, so writing this unconditionally is safe
    # for every OTHER already-proven package too, not just meson's own
    # out-of-source convention.
    printf '%s' "$dyndrv_buildRootTop" > "$dyndrv_origTree/.dyndrv-build-relpath"
    # meson (and similarly out-of-tree build systems) reference SOURCE-
    # tree files/directories one level ABOVE the build dir via literal
    # "../<path>" tokens throughout build.ninja -- both as an edge's
    # own explicit dependency (e.g. "build libnixutil.so.2.36.0.p/
    # archive.cc.o: cpp_COMPILER ../archive.cc") AND, just as often, as
    # an `-I../include`-style compiler flag on that same edge's own
    # `ARGS` line (an entire HEADER DIRECTORY, not a single file --
    # confirmed by direct reproduction: restricting this scan to only
    # "build ...:" lines missed every one of these, since headers
    # reached purely via `-I` never appear as an edge's own explicit
    # dependency at all, only implicitly via a `-MD` depfile that
    # doesn't exist yet at THIS point). Two failure modes if either is
    # missing: ninja's own dependency-graph LOADING step refuses to
    # proceed at all if a referenced SOURCE file is absent (confirmed:
    # "ninja: error: '../archive.cc', needed by 'libnixutil.so.2.36.0.p
    # /archive.cc.o', missing and no known rule to make it"), while a
    # missing HEADER directory instead lets ninja proceed but fails
    # the actual compile outright ("fatal error: nix/util/archive.hh:
    # No such file or directory") the moment anything really needs
    # rebuilding (or, if using a build tool whose restat check doesn't
    # already treat every real, up-to-date output as still fresh --
    # see `phases/split.nix`'s own mtime-normalization comment -- EVEN
    # when nothing actually needs rebuilding). `dyndrv_buildRoot`
    # itself (== "." here, the build dir) is the only tree this script
    # ever submits -- by design, to avoid re-shipping the WHOLE
    # original source tree a second time -- so these specific,
    # individually-named files/directories (still sitting right there
    # on disk one level up, in THIS sandbox, untouched) are carried
    # forward too, into a dedicated `.dyndrv-carried-up1/` subdir of
    # the submitted tree (stripped of their own leading "../"), rather
    # than a blind copy of the whole parent directory. `phases/
    # split.nix`'s own phase 2 looks for this exact subdir to decide
    # whether it needs to reconstruct the one-level-up nesting at all
    # (a plain, non-meson build never produces one, so this is purely
    # additive there).
    if [ -f "$dyndrv_buildRoot/build.ninja" ] || [ -f "$dyndrv_buildRoot/CMakeCache.txt" ]; then
      dyndrv_carriedDir="$dyndrv_origTree/.dyndrv-carried-up1"
      dyndrv_buildAbs=$(${pkgs.coreutils}/bin/realpath "$dyndrv_buildRoot")
    fi
    if [ -f "$dyndrv_buildRoot/CMakeCache.txt" ]; then
      # `CMAKE_HOME_DIRECTORY` (`CMakeCache.txt`'s own record of the
      # SOURCE dir cmake was invoked against) distinguishes cmake's
      # out-of-tree convention (`cmakeConfigurePhase`'s default `mkdir
      # -p build; cd build`: `CMAKE_HOME_DIRECTORY` is `dyndrv_buildRoot`'s
      # own PARENT) from an in-source build (`dontUseCmakeBuildDir =
      # true`, example-18's own fixture: `CMAKE_HOME_DIRECTORY` IS
      # `dyndrv_buildRoot` itself, cmake invoked directly from the
      # source dir with no separate `build/` subdir at all) --
      # confirmed necessary by direct reproduction: without this
      # check, the carry-forward below unconditionally tried to copy
      # `dyndrv_buildRoot`'s own PARENT DIRECTORY (in-source: that's
      # `$NIX_BUILD_TOP` itself, which nests `dyndrv_buildRoot`
      # directly) INTO a subdirectory of `dyndrv_origTree`, which
      # itself lives under a `mktemp -d` scratch dir ALSO directly
      # under `$NIX_BUILD_TOP` -- `cp -r` then tried to copy that
      # scratch dir into itself ("cp: cannot copy a directory ... into
      # itself"), since the source and destination trees overlapped.
      dyndrv_cmakeHome=$(${pkgs.gnused}/bin/sed -n 's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p' "$dyndrv_buildRoot/CMakeCache.txt")
      dyndrv_cmakeHomeAbs=$(${pkgs.coreutils}/bin/realpath -m "$dyndrv_cmakeHome")
      if [ "$dyndrv_cmakeHomeAbs" != "$dyndrv_buildAbs" ]; then
      # cmake's own out-of-tree convention (`cmakeConfigurePhase`'s
      # `mkdir -p build; cd build`, the SAME one-level-up nesting
      # meson's own `meson setup build && cd build` uses) puts the
      # ENTIRE source tree (`CMakeLists.txt`, every `.c`/`.h`, any
      # subdirectory `add_subdirectory()` references) one level ABOVE
      # `dyndrv_buildRoot`, with NO equivalent of meson's own
      # `build.ninja`/`intro-install_plan.json` machine-readable
      # dependency listing to scan instead -- cmake's generated
      # `Makefile`s reference these sources via bare, ALREADY-ABSOLUTE
      # paths (confirmed by direct reproduction: `CMakeFiles/prog.dir/
      # build.make`'s own compile rule reads straight from
      # `$dyndrv_buildAbs/../main.c`, no relative `"../"` token to grep
      # for at all), so the precise text/JSON-scan approach meson needs
      # doesn't even apply here. Carrying forward the WHOLE parent
      # directory's contents (everything sitting alongside
      # `dyndrv_buildRoot` itself, i.e. every sibling of the build dir)
      # is simpler and just as correct: cmake's own convention never
      # puts real source content ANYWHERE else, and this is exactly
      # the same one-level-up nesting `phases/split.nix`'s own
      # `dyndrvCdToBuildDir` already reconstructs via `.dyndrv-carried-
      # up1` for meson -- confirmed necessary by direct reproduction
      # against a synthetic cmake+make fixture: without this, phase
      # 2's tree contains ONLY `dyndrv_buildRoot`'s own content (the
      # `build/` dir), so `cmake --check-build-system`'s own re-
      # invocation at install time fails outright ("The source
      # directory ... does not appear to contain CMakeLists.txt").
      dyndrv_buildParentAbs=$(${pkgs.coreutils}/bin/dirname "$dyndrv_buildAbs")
      dyndrv_buildBasename=$(${pkgs.coreutils}/bin/basename "$dyndrv_buildAbs")
      ${pkgs.coreutils}/bin/mkdir -p "$dyndrv_carriedDir"
      for _dcs_sib in "$dyndrv_buildParentAbs"/* "$dyndrv_buildParentAbs"/.[!.]*; do
        [ -e "$_dcs_sib" ] || continue
        _dcs_sibName=$(${pkgs.coreutils}/bin/basename "$_dcs_sib")
        [ "$_dcs_sibName" = "$dyndrv_buildBasename" ] && continue
        ${pkgs.coreutils}/bin/cp -r "$_dcs_sib" "$dyndrv_carriedDir/$_dcs_sibName"
      done
      fi
    fi
    if [ -f "$dyndrv_buildRoot/build.ninja" ]; then
      while IFS= read -r _dcs_rel; do
        [ -z "$_dcs_rel" ] && continue
        case "$_dcs_rel" in
          /*)
            # An ABSOLUTE path (from `intro-install_plan.json`, see
            # below) -- convert to the SAME relative-to-`$dyndrv_
            # buildRoot` form the `../`-prefixed sources already use,
            # so the single carry-forward loop below handles all three
            # sources uniformly. `-m`/`--canonicalize-missing`: pure
            # STRING path arithmetic, no filesystem existence check --
            # confirmed necessary by direct reproduction: without it,
            # `realpath --relative-to` silently failed (empty stdout,
            # nonzero exit swallowed by this loop's own `$()`) the
            # moment `$_dcs_rel` named a path that happens not to
            # exist relative to the CALLER's OWN cwd (a real concern
            # here specifically since this whole block already runs
            # from an arbitrary, possibly-unrelated cwd during ad hoc
            # debugging/reproduction -- inside the real sandbox this
            # path always exists, but there's no reason to depend on
            # that when pure string arithmetic is just as correct and
            # strictly more robust).
            _dcs_rel=$(${pkgs.coreutils}/bin/realpath -m --relative-to="$dyndrv_buildAbs" "$_dcs_rel")
            ;;
        esac
        _dcs_srcPath="$dyndrv_buildRoot/$_dcs_rel"
        _dcs_relNoUp="$_dcs_rel"
        while true; do
          case "$_dcs_relNoUp" in
            ../*) _dcs_relNoUp="''${_dcs_relNoUp#../}" ;;
            *) break ;;
          esac
        done
        if [ -d "$_dcs_srcPath" ]; then
          ${pkgs.coreutils}/bin/mkdir -p "$dyndrv_carriedDir/$_dcs_relNoUp"
          ${pkgs.coreutils}/bin/cp -r "$_dcs_srcPath"/. "$dyndrv_carriedDir/$_dcs_relNoUp"/
        elif [ -f "$_dcs_srcPath" ]; then
          ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$dyndrv_carriedDir/$_dcs_relNoUp")"
          ${pkgs.coreutils}/bin/cp "$_dcs_srcPath" "$dyndrv_carriedDir/$_dcs_relNoUp"
        fi
      done < <(
        (
          # Every command in this subshell can LEGITIMATELY match/find
          # NOTHING for a given component (e.g. a component with no
          # `../`-relative source references, or no `headers`/`data`
          # entries outside its own build dir at all) -- `grep`/`jq`
          # both exit NONZERO when they produce zero output, and this
          # whole block runs inside a `(...)` subshell under `set -e`
          # (inherited from `stdenv`'s own `setup` script, confirmed by
          # direct reading, plus `set -o pipefail` right below it) --
          # confirmed by direct reproduction: `echo "" | grep -oE
          # '\.\./' | grep -oE '\.\./'` exits 1, and WITHOUT `|| true`
          # on every one of these, that nonzero exit ABORTED THIS WHOLE
          # SUBSHELL silently the moment any ONE stage found nothing,
          # skipping every source listed AFTER the first one to come
          # up empty (confirmed this exact failure mode: the
          # `intro-install_plan.json` fix below NEVER ran at all for
          # `nix-util-c`, despite being byte-for-byte correct in
          # isolation, because the PRECEDING `ninja -t deps` pipeline
          # happened to match zero lines for that specific component
          # and silently aborted everything after it). `|| true` on
          # every stage, not just the last, makes each source
          # independently best-effort.
          ${pkgs.gnugrep}/bin/grep -oE '\.\./[^ $"'"'"']+' "$dyndrv_buildRoot/build.ninja" || true
          # `ninja -t deps` (no target arg -- dumps EVERY compiled
          # target's own already-logged deps) catches dependencies the
          # plain `build.ninja` TEXT scan above structurally can't see
          # at all: a C23 `#embed "schema.sql"` directive (confirmed
          # against NixOS/nix's own `nix-store` component,
          # `local-store.cc`'s `#embed "schema.sql"`/`#embed "ca-
          # specific-schema.sql"`) is tracked by gcc's own `-MD`
          # depfile exactly like an `#include`, but that tracking
          # lands ONLY in ninja's binary `.ninja_deps` log -- it never
          # appears as literal text in `build.ninja` itself (confirmed
          # by direct reproduction: `grep -c schema build.ninja`
          # returns 0 even though `ninja -t deps` correctly lists
          # `../src/schema.sql`). Run from `$dyndrv_buildRoot` (cd'd
          # into first, in a subshell, so this doesn't disturb the
          # caller's own cwd) since `-t deps` reads `.ninja_deps`
          # relative to the invoking cwd, same as any other ninja
          # command. `2>/dev/null || true`: a target with NO tracked
          # deps at all (e.g. a link step) prints nothing for itself,
          # not an error, but `ninja -t deps` exits nonzero if ANY
          # target lacks deps info -- harmless here, this is a
          # best-effort ADDITIONAL source of `../`-paths, not the only
          # one.
          ( cd "$dyndrv_buildRoot" && ${pkgs.ninja}/bin/ninja -t deps 2>/dev/null || true ) \
            | ${pkgs.gnugrep}/bin/grep -oE '^ +\.\./[^ ]+' | ${pkgs.gnugrep}/bin/grep -oE '\.\./[^ ]+' || true
          # `meson-info/intro-install_plan.json` (machine-readable,
          # always regenerated after `meson setup`) catches what
          # NEITHER of the above two sources can: a plain `install()`ed
          # header/data file is NEVER a compile-time dependency at all
          # (nothing `#include`s it as part of ITS OWN build; it's
          # public API surface meant for downstream consumers only),
          # so it never appears in `build.ninja`'s own edges OR any
          # compiler's `-MD` depfile -- confirmed by direct
          # reproduction against NixOS/nix's own `nix-util-c`
          # component: `nix_api_util.h` is genuinely absent from BOTH
          # `build.ninja`'s text and `ninja -t deps`' output, yet
          # `meson install`'s own install PLAN records its absolute
          # source path directly (`headers: {"/build/source/src/
          # libutil-c/nix_api_util.h": {...}}`), and fails outright
          # ("Tried to install something that isn't a file") the
          # moment that path doesn't exist in phase 2's tree. Every
          # section's own top-level keys (`headers`/`data`/`man`/etc,
          # `targets` too though those always live INSIDE the build
          # dir already and get filtered out below) are each one
          # absolute SOURCE path meson's own installer will read
          # from -- filtering to just the ones OUTSIDE the build dir
          # (a `targets`-section entry, e.g. `libnixutilc.a`, is
          # already inside it, needing no carry-forward at all) gives
          # exactly the missing set, with no false positives.
          if [ -f "$dyndrv_buildRoot/meson-info/intro-install_plan.json" ]; then
            ${pkgs.jq}/bin/jq -r --arg buildabs "$dyndrv_buildAbs" '
              [.[] | keys[]] | map(select(startswith($buildabs) | not)) | .[]
            ' "$dyndrv_buildRoot/meson-info/intro-install_plan.json" 2>/dev/null || true
          fi
        ) | sort -u
      )
      # meson ALSO bakes phase 1's own ABSOLUTE build-dir path into
      # OTHER generated state beyond build.ninja itself -- confirmed by
      # direct reproduction against nix-util's own `ninja install`:
      # `meson-private/install.dat` (a pickled Python object,
      # `installdata.headers[].path`) records the literal absolute
      # source path `/build/source/src/libutil/build/include/nix/util/
      # config.hh`, which `phases/split.nix`'s own synthetic
      # `.dyndrv-build/` staging name does NOT match at all -- meson's
      # own installer then finds a symlink at that exact path pointing
      # nowhere real relative to ITS OWN understanding of where things
      # are, and refuses to install it ("Tried to install something
      # that isn't a file"). This is now handled generically by the
      # UNCONDITIONAL `.dyndrv-build-relpath` write above (right after
      # `dyndrv_origTree` is created) -- meson is simply the tool that
      # first surfaced the need for it, not the only one that needs it
      # (see that write's own comment for why it's no longer gated on
      # `build.ninja`).
      # meson's own `--prefix=$out` (baked in at CONFIGURE time, phase
      # 1) is NEVER overridden by a fresh `$out` at install time --
      # unlike autotools/make (`make install DESTDIR=...`), `meson
      # install` reads NO env var for its own destination at all;
      # `--destdir`/`$DESTDIR` is meson's own PREPEND mechanism instead
      # (confirmed via `meson install --help`) -- installed content
      # lands at `$DESTDIR/<baked-prefix>/...`, not `$DESTDIR/...`
      # directly. Since phase 1's own baked prefix (its OWN `$out`, a
      # `builder-rpc-v0`-sandboxed placeholder value never meant to be
      # a REAL path -- see `phases/split.nix`'s own header comment) is
      # simply unknown to phase 2 otherwise, it's recorded here, once,
      # alongside the other meson-specific markers -- confirmed
      # necessary by direct reproduction: without exporting `DESTDIR`
      # in phase 2, `ninja install` wrote everything under a literal,
      # nonsensical `$out/nix-util-2.36.0pre.drv/...` path (phase 1's
      # own placeholder `$out`, complete with its own `.drv` suffix),
      # never under phase 2's real `$out` at all.
      printf '%s' "$out" > "$dyndrv_origTree/.dyndrv-phase1-out"
    fi
    dyndrv_origTreePath=$(nix store add "$dyndrv_origTree")
    dyndrv_origTreeBasename=$(basename "$dyndrv_origTreePath")

    _dcs_finalCopyLines="${pkgs.coreutils}/bin/mkdir -p \$out; ${pkgs.coreutils}/bin/cp -r ${builtins.storeDir}/$dyndrv_origTreeBasename/. \$out/; ${pkgs.coreutils}/bin/chmod -R u+w \$out; "
    for _dcs_p in "''${dyndrv_stubPaths[@]}"; do
      _dcs_finalCopyLines="$_dcs_finalCopyLines${pkgs.coreutils}/bin/mkdir -p \"\$(${pkgs.coreutils}/bin/dirname \"\$out/$_dcs_p\")\"; ${pkgs.coreutils}/bin/ln -s \"@dyndrv-final-placeholder:$_dcs_p@\" \"\$out/$_dcs_p\"; "
    done

    _dcs_finalDrvJson=$(${pkgs.jq}/bin/jq -nc \
      --arg name ${lib.escapeShellArg name} \
      --arg system "${pkgs.stdenv.hostPlatform.system}" \
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
