{ pkgs, lib, self }:

# Compiles an arbitrary dependency graph into a dyn-drv graph: N
# independently-declared nodes, each possibly depending on other nodes'
# not-yet-built outputs, registered in one bash script via `nix derivation
# add`, with a final output selected/assembled and submitted via
# `nix store submit-output`.
#
# This is the mechanism gradle-drvs (per-Maven-artifact fetch) and
# sandstone (per-Haskell-module compile) each hand-rolled independently in
# ~1000+ lines of bash+jq/Haskell; `graph.compile` is that algorithm
# written once.
#
# ARCHITECTURE: this compiles the WHOLE graph into ONE generated bash
# script that registers every node via `nix derivation add`, rather than
# calling `dyndrv.builders.viaDerivationAdd` once per node and gluing the
# results together afterward -- the latter can't work, since crossing the
# eval->build (JSON) boundary per-node loses Nix's own dependency-tracking
# string context. `graph.compile` is its own producer constructor
# (returning the `{ script, extraDrvArgs }` shape `mkDynamicDerivation.nix`
# defines as "the producer contract"), not a wrapper around N
# `viaDerivationAdd` calls.
#
# v0.2 SCOPE: implements the `builder-rpc-v0` backend only (the natural
# fit -- `nix derivation add`'s JSON schema already has `inputs.drvs`).
# `viaNixInstantiate`/`recursive-nix` multi-node graphs need their own
# single-composed-Nix-expression codegen -- follow-on work, not
# implemented here; `graph.compile { backend = "recursive-nix"; }` throws
# a clear "not yet implemented" error.
#
# `nodes`: an attrset `{ <name> = { deps = [ <name> ... ]; group = null; mkDrv = { ref }: {...}; }; }`.
#   - `deps`: names of other nodes this node depends on. `graph.compile`
#     wires these into the registered derivation's `inputs.drvs`
#     automatically (using each dep's ACTUAL registered basename, known
#     only at build time) -- callers never construct `inputs.drvs` by hand.
#   - `mkDrv`: a function `{ ref }: <toDrvJson-shaped attrset, minus
#     inputs.drvs>` (see `viaDerivationAdd.nix` for the exact schema:
#     `name`/`system`/`builder`/`args`/`env`/`outputs`/`version`).
#     `ref depName` returns a sentinel string that the generated builder
#     script substitutes, at BUILD time, for the real
#     `DownstreamPlaceholder::unknownCaOutput` placeholder of that
#     dependency's actual registered output, once the dependency has
#     actually been registered (its real drvPath/hashPart is only
#     knowable then). `ref "self"` is the sentinel for THIS node's own
#     output.
#   - `group` (optional, default `null`): a plain string key. Every node
#     sharing the SAME `group` string is merged into ONE registered
#     derivation (one `nix derivation add` call instead of N), with one
#     distinctly-NAMED output per member instead of each getting its own
#     "out"-named derivation -- the one mechanism this library provides
#     for consolidating a fine-grained graph into coarser sub-components.
#     A `group` shared by only one node (or left `null`) is exactly
#     equivalent to no grouping -- existing callers that never set
#     `group` are byte-for-byte unaffected. See "Merging mechanics" below
#     for the constraint merged members' `mkDrv` must satisfy.
#
# MERGING MECHANICS (only relevant to nodes that share a `group`): a
# merged group's members are compiled SEQUENTIALLY inside ONE generated
# `/bin/sh -c` script, in the same relative order `graph.topoSort`
# already establishes for the whole graph (a subsequence of a valid
# topological order remains valid for the induced subgraph) -- so a
# member referencing a fellow member's output can rely on it having
# already been written. A merged member's `mkDrv` MUST return `builder =
# "/bin/sh"; args = [ "-c" "<cmd referencing its own output as $out>" ];`
# -- `graph.compile` rewrites the literal substring `$out` to the
# member's own output variable (`$<memberName>`) when folding it into the
# merged unit's script; a member whose `mkDrv` doesn't follow this shape
# throws a clear error. `ref "self"` and `ref "<fellowMemberName>"` both
# resolve via the plain, drvPath-independent `hashPlaceholder` formula
# (no cross-derivation lookup needed, since both are outputs of the same
# not-yet-registered derivation) -- only a reference to a node OUTSIDE
# the group still goes through the cross-node
# `DownstreamPlaceholder::unknownCaOutput` mechanism, generalized to ask
# for that dependency's own registered output name rather than assuming
# "out".
#
# `toOutput`: how the graph's many node outputs become the ONE output the
#   outer derivation submits (builder-rpc-v0/recursive-nix only allow one
#   submitted output per outer derivation):
#   - `"assemble"` (default) -- synthesizes one additional "assembler" node
#     that copies every other node's output into one directory tree
#     (gradle-drvs' own pattern).
#   - `{ sink = "<nodeName>"; }` -- submit that one named node's output
#     directly (sandstone's pattern: only the final linked binary matters).
#     A trivial rename node is synthesized if the sink's own name doesn't
#     already match what the outer wrapper expects.
#
# `nixPackage`: same as `viaDerivationAdd.nix` -- the Nix to run
#   `nix derivation add`/`nix store submit-output` with, inside the sandbox.
#
# `name`: MUST match the outer `mkDynamicDerivation` call's expected inner
#   name exactly (i.e. `"${pname}-${version}"`) -- without this, the
#   synthesized assembler/sink-rename node's name mismatches what the
#   outer wrapper expects and realization fails. Individual graph nodes
#   are free to have any name; only the final node (the assembler, or the
#   renamed sink) needs to match.

{
  nodes,
  toOutput ? "assemble",
  nixPackage,
  name,
}:

let
  order = self.graph.topoSort nodes;

  # Every node belongs to a "unit" -- the thing that actually becomes ONE
  # `nix derivation add` call. An ungrouped node is its own solo unit,
  # output named literally "out". A node with `group` set shares a unit
  # with every other node that set the exact same `group` string; a
  # unit's members become that ONE derivation's distinctly-named outputs
  # (named after each member's own node name).
  isSolo = nodeName: (nodes.${nodeName}.group or null) == null;
  unitKeyOf = nodeName: if isSolo nodeName then "__solo:${nodeName}" else nodes.${nodeName}.group;
  outputNameOf = nodeName: if isSolo nodeName then "out" else nodeName;

  membersByUnit = lib.groupBy unitKeyOf order; # unitKey -> [ nodeName ], relative order preserved

  # Keeping intra-unit relative order isn't enough to order UNITS
  # themselves: grouping can put topologically distant nodes in the same
  # unit, so two units' relative registration order must still respect
  # any dependency edge crossing between them. Reuses `graph.topoSort`
  # unchanged -- a unit graph is the same `{ <name> = { deps = [...] }; }`
  # shape `topoSort` already handles.
  unitGraphNodes = lib.mapAttrs (
    unitKey: members:
    {
      deps = lib.unique (
        lib.filter (u: u != unitKey) (lib.concatMap (m: map unitKeyOf (nodes.${m}.deps or [ ])) members)
      );
    }
  ) membersByUnit;
  unitOrder = self.graph.topoSort unitGraphNodes;

  # `ref` as seen by a given node `fromName`'s own `mkDrv`. "self" means
  # "my own output". A reference to a fellow member of the SAME unit
  # (including self) resolves via the plain, drvPath-independent
  # `hashPlaceholder` formula (`@dyndrv-self-placeholder:<outputName>@`);
  # a reference crossing into a DIFFERENT unit needs the real
  # `DownstreamPlaceholder::unknownCaOutput` formula against that unit's
  # own, only-known-at-build-time drvPath
  # (`@dyndrv-node-placeholder:<unitKey>:<outputName>@`).
  refSentinelFor =
    fromName: toName:
    let
      toName' = if toName == "self" then fromName else toName;
      toOutputName = outputNameOf toName';
    in
    if unitKeyOf fromName == unitKeyOf toName' then
      "@dyndrv-self-placeholder:${toOutputName}@"
    else
      "@dyndrv-node-placeholder:${unitKeyOf toName'}:${toOutputName}@";

  # A node's own `{ unit, outputName }` reference pair -- shared by
  # `externalRefsOf` (a unit's deps) and `finalNode` (the outer wrapper's
  # own view of a node).
  refOf = n: {
    unit = unitKeyOf n;
    outputName = outputNameOf n;
  };

  # Every (unit, outputName) pair any member of THIS unit references
  # outside the unit -- drives both `inputs.drvs` wiring and cross-unit
  # placeholder substitution for the generated script.
  externalRefsOf =
    unitKey: members:
    lib.unique (
      lib.concatMap (
        m: map refOf (lib.filter (dep: unitKeyOf dep != unitKey) (nodes.${m}.deps or [ ]))
      ) members
    );

  # Renders ONE unit into `{ unitKey, selfOutputNames, externalRefs,
  # drvJson }`. A solo unit renders identically to a single ungrouped
  # node's own `mkDrv` JSON -- so a caller that never sets `group` sees
  # zero behavioral change. A real unit (2+ members, or an explicit
  # single-member `group`) synthesizes one merged, multi-output
  # derivation instead.
  renderUnit =
    unitKey:
    let
      members = membersByUnit.${unitKey};
      drvsOf = map (m: {
        member = m;
        drv = nodes.${m}.mkDrv { ref = refSentinelFor m; };
      }) members;
    in
    {
      inherit unitKey;
      selfOutputNames = map outputNameOf members;
      externalRefs = externalRefsOf unitKey members;
      drvJson =
        if builtins.length members == 1 && isSolo (builtins.head members) then
          let
            only = builtins.head drvsOf;
          in
          builtins.toJSON (only.drv // { version = only.drv.version or 4; })
        else
          let
            # Every merged member's mkDrv must use the `/bin/sh -c
            # "<cmd>"` shape -- enforced here with a clear error, since a
            # merged unit's builder script is these commands
            # CONCATENATED, not one member's verbatim JSON.
            cmdOf =
              d:
              if
                (d.drv.builder or null) != "/bin/sh" || (d.drv.args or [ ]) == [ ] || builtins.elemAt d.drv.args 0
                != "-c"
              then
                throw ''
                  dyndrv.graph.compile: node "${d.member}" is grouped
                  (group = "${unitKey}") but its mkDrv didn't return the
                  required `builder = "/bin/sh"; args = [ "-c" "<cmd>" ];`
                  shape -- grouped nodes' commands are concatenated into
                  one script, so this exact shape is required (see
                  graph/compile.nix's "MERGING MECHANICS" header comment).
                ''
              else
                builtins.elemAt d.drv.args 1;
            # Env vars are named after their OUTPUT, per Nix's derivation
            # ABI (output "a" is seen as `$a` inside the builder, just
            # like a solo derivation's "out" is seen as `$out`) -- so
            # each member's own `$out` reference is rewritten to its own
            # member-named output variable before concatenation.
            rewrittenCmdOf = d: lib.replaceStrings [ "$out" ] [ ("$" + d.member) ] (cmdOf d);
            combinedCmd = lib.concatMapStringsSep "; " rewrittenCmdOf drvsOf;
          in
          builtins.toJSON {
            name = "dyndrv-group-${unitKey}";
            system = pkgs.stdenv.hostPlatform.system;
            builder = "/bin/sh";
            args = [
              "-c"
              combinedCmd
            ];
            env = lib.genAttrs members (m: "@dyndrv-self-placeholder:${m}@");
            inputs = {
              drvs = { };
              srcs = lib.unique (lib.concatMap (d: d.drv.inputs.srcs or [ ]) drvsOf);
            };
            outputs = lib.genAttrs members (m: {
              method = "nar";
              hashAlgo = "sha256";
            });
            version = 4;
          };
    };

  renderedUnits = map renderUnit unitOrder;

  sinkName = if builtins.isAttrs toOutput then toOutput.sink else null;

  needsAssemblerNode = toOutput == "assemble";

  # The final node MUST be named exactly `name` -- so both the "assemble"
  # and "sink" cases synthesize one small final node with that exact
  # name, rather than renaming an existing node in place (a node's own
  # name is already baked into its registered .drv). This final node is
  # always its own solo unit -- never grouped -- so it goes through the
  # same generic per-unit script generation below, just appended after
  # `unitOrder`.
  #
  # "assemble": copies every real node's output into one directory tree
  # via symlinks, mirroring gradle-drvs' own assembler derivation.
  # "sink": a trivial single-symlink passthrough to the named sink node's
  # output (sandstone's pattern).
  finalNode =
    let
      copyLines =
        if needsAssemblerNode then
          map (
            n: ''${pkgs.coreutils}/bin/ln -s "@dyndrv-node-placeholder:${unitKeyOf n}:${outputNameOf n}@" "$out/${n}"''
          ) order
        else
          [
            ''${pkgs.coreutils}/bin/ln -s "@dyndrv-node-placeholder:${unitKeyOf sinkName}:${outputNameOf sinkName}@" "$out"''
          ];
      # `inputs.srcs` wants a bare basename, not a full store path.
      # Declares coreutils as an input so `mkdir`/`ln` are usable by
      # absolute path -- a `builder-rpc-v0`-registered derivation has no
      # ambient $PATH.
      coreutilsBasename = builtins.baseNameOf "${pkgs.coreutils}";
    in
    {
      unitKey = "__dyndrv_final";
      selfOutputNames = [ "out" ];
      externalRefs = lib.unique (if needsAssemblerNode then map refOf order else [ (refOf sinkName) ]);
      drvJson = builtins.toJSON {
        inherit name;
        system = pkgs.stdenv.hostPlatform.system;
        builder = "/bin/sh";
        args = [
          "-c"
          (
            if needsAssemblerNode then
              "${pkgs.coreutils}/bin/mkdir -p $out; ${lib.concatStringsSep "; " copyLines}"
            else
              lib.concatStringsSep "; " copyLines
          )
        ];
        env = {
          out = "@dyndrv-self-placeholder:out@";
        };
        inputs = {
          drvs = { };
          srcs = [ coreutilsBasename ];
        };
        outputs.out = {
          method = "nar";
          hashAlgo = "sha256";
        };
        version = 4;
      };
    };

  allUnits = renderedUnits ++ [ finalNode ];

  finalUnitKey = "__dyndrv_final";

  # Bash port of DownstreamPlaceholder::unknownCaOutput (verified by
  # direct reproduction against Nix's own computed placeholder for a
  # real CA derivation) -- `nix hash convert` is used here since this
  # runs inside the bash builder script, not Nix-expression eval, where
  # `builtins.convertHash` isn't reachable.
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

  renderUnitScript = u: ''
    drvJson=$(cat <<'DYNDRV_UNIT_JSON'
    ${u.drvJson}
    DYNDRV_UNIT_JSON
    )

    # `//= {} | //= []` ensures both keys exist even if a solo unit's own
    # mkDrv output omitted `inputs` entirely -- merged units always set
    # both explicitly already, so this is a no-op for them.
    drvJson=$(echo "$drvJson" | jq '.inputs.drvs //= {} | .inputs.srcs //= []')

    # Substitute THIS unit's own self-placeholder sentinels (its own
    # output(s) -- one for a solo unit, one per member for a merged one;
    # also covers any fellow-member reference within a merged unit,
    # since both resolve to the identical sentinel spelling).
    for _outName in ${lib.concatMapStringsSep " " lib.escapeShellArg u.selfOutputNames}; do
      _selfPlaceholder=$(nix eval --raw --expr "builtins.placeholder \"$_outName\"")
      drvJson="''${drvJson//@dyndrv-self-placeholder:$_outName@/$_selfPlaceholder}"
    done

    # Wire every OTHER unit this one references into inputs.drvs (using
    # that unit's actual registered basename, known only now), and
    # substitute each cross-unit placeholder sentinel this unit's JSON
    # references, using the already-registered upstream unit's real
    # drvPath. Grouped by unit once (rather than re-filtering
    # `u.externalRefs` per distinct unit), since a ref list can
    # legitimately reference the same unit for several output names.
    inputDrvs='{}'
    ${
      lib.concatMapStringsSep "\n" (
        depUnitRefs:
        let
          depUnit = (builtins.head depUnitRefs).unit;
          outs = lib.unique (map (r: r.outputName) depUnitRefs);
        in
        ''
          inputDrvs=$(echo "$inputDrvs" | jq --arg k "''${drvs[${depUnit}]}" --argjson outs '${
            builtins.toJSON outs
          }' '. + {($k): {"outputs": $outs, "dynamicOutputs": {}}}')
        ''
      ) (builtins.attrValues (lib.groupBy (r: r.unit) u.externalRefs))
    }
    drvJson=$(echo "$drvJson" | jq --argjson inputDrvs "$inputDrvs" '.inputs.drvs = (.inputs.drvs + $inputDrvs)')

    ${lib.concatMapStringsSep "\n" (ref: ''
      depPlaceholder=$(dyndrv_placeholder "''${drvPathByName[${ref.unit}]}" ${lib.escapeShellArg ref.outputName})
      drvJson="''${drvJson//@dyndrv-node-placeholder:${ref.unit}:${ref.outputName}@/$depPlaceholder}"
    '') u.externalRefs}

    drvPathByName[${u.unitKey}]=$(echo "$drvJson" | nix derivation add)
    drvs[${u.unitKey}]=$(basename "''${drvPathByName[${u.unitKey}]}")
  '';
in
{
  script =
    backend:
    if backend != "builder-rpc-v0" then
      throw ''
        dyndrv.graph.compile: only the "builder-rpc-v0" backend is
        implemented so far (got: ${backend}). recursive-nix multi-node
        graphs need their own single-composed-Nix-expression codegen --
        tracked as follow-on work, not yet implemented.
      ''
    else
      ''
        runHook preBuild
        export PATH="${nixPackage}/bin:$PATH"
        export NIX_CONFIG='extra-experimental-features = nix-command ca-derivations dynamic-derivations'

        ${placeholderBashFn}

        declare -A drvs=()
        declare -A drvPathByName=()

        ${lib.concatMapStringsSep "\n\n" renderUnitScript allUnits}

        nix store submit-output "''${drvPathByName[${finalUnitKey}]}" out
        runHook postBuild
      '';

  extraDrvArgs = {
    nativeBuildInputs = [ pkgs.jq ];
  };
}
