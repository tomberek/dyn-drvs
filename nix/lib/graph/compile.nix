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
# ARCHITECTURE NOTE (resolved 2026-08-31, see plan's "RESOLVED" sections):
# this compiles the WHOLE graph into ONE generated bash script that
# registers every node via `nix derivation add`, rather than calling
# `dyndrv.builders.viaDerivationAdd` once per node and gluing the results
# together afterward -- the latter cannot work, because crossing the
# eval->build (JSON) boundary per-node loses Nix's own dependency-tracking
# string context (confirmed directly: this is why v0.1's `viaDerivationAdd`
# stayed single-node). `graph.compile` is therefore its own producer
# constructor (returning the same `{ script, extraDrvArgs }` shape
# `mkDynamicDerivation.nix`'s header comment defines as "the producer
# contract" -- despite living under `graph.*` rather than `builders.*`,
# it's exactly as valid a `producer` as `builders.viaDerivationAdd`, just
# one that internally orchestrates a whole graph of nodes instead of one),
# not a wrapper around N `viaDerivationAdd` calls.
#
# v0.2 SCOPE: implements the `builder-rpc-v0` backend only (the natural
# fit -- `nix derivation add`'s JSON schema already has `inputs.drvs`).
# `viaNixInstantiate`/`recursive-nix` multi-node graphs need their own
# single-composed-Nix-expression codegen (confirmed to work in principle,
# see the plan's "RESOLVED" note on question 1) but are follow-on work,
# not implemented here yet -- `graph.compile { backend = "recursive-nix"; }`
# throws a clear "not yet implemented" error rather than silently doing
# the wrong thing.
#
# `nodes`: an attrset `{ <name> = { deps = [ <name> ... ]; mkDrv = { ref }: {...}; }; }`.
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
#     dependency's actual registered output -- computed via
#     `dyndrv.placeholder`'s verified formula, ported to bash, once the
#     dependency has actually been registered (its real drvPath/hashPart
#     is only knowable then). `ref "self"` is the sentinel for THIS node's
#     own output (same self-reference convention `viaDerivationAdd.nix`
#     already established).
#
# `toOutput`: how the graph's many node outputs become the ONE output the
#   outer derivation submits (Nix's builder-rpc-v0/recursive-nix mechanisms
#   only allow one submitted output per outer derivation):
#   - `"assemble"` (default) -- synthesizes one additional "assembler" node
#     that copies every other node's output into one directory tree
#     (gradle-drvs' own pattern: copy every fetched artifact into one tree).
#   - `{ sink = "<nodeName>"; }` -- submit that one named node's output
#     directly (sandstone's pattern: only the final linked binary matters).
#     A trivial rename node is still synthesized if the sink's own name
#     doesn't already match what the outer wrapper expects (the "inner/
#     outer derivation names must match exactly" constraint confirmed in
#     v0.1, applied automatically so callers never have to think about it).
#
# `nixPackage`: same as `viaDerivationAdd.nix` -- the patched Nix to run
#   `nix derivation add`/`nix store submit-output` with, inside the sandbox.
#
# `name`: MUST match the outer `mkDynamicDerivation` call's expected inner
#   name exactly (i.e. `"${pname}-${version}"`, same "inner/outer names
#   must match exactly" constraint documented in mkDynamicDerivation.nix --
#   confirmed by direct reproduction: without this, the synthesized
#   assembler/sink-rename node's name mismatches what the outer wrapper
#   expects and realization fails with "output ... was named ..., expected
#   ..."). Individual graph NODES are free to have any name (they're
#   intermediate/never directly exposed); only the FINAL node (the
#   assembler, or the renamed sink) needs to match.

{
  nodes,
  toOutput ? "assemble",
  nixPackage,
  name,
}:

let
  order = self.graph.topoSort nodes;

  # `ref "self"` reuses the existing self-reference sentinel convention
  # from viaDerivationAdd.nix (substituted via `builtins.placeholder`,
  # since a node's own not-yet-known output uses the fixed, name-only
  # hashPlaceholder formula, not the cross-node unknownCaOutput one).
  # `ref "<otherNode>"` uses the cross-node sentinel, substituted via the
  # dyndrv_placeholder bash function once that node is registered.
  refSentinel = name: if name == "self" then "@dyndrv-placeholder:out@" else "@dyndrv-node-placeholder:${name}@";

  renderNode =
    name:
    let
      node = nodes.${name};
      drv = node.mkDrv { ref = refSentinel; };
      depsList = node.deps or [ ];
    in
    {
      inherit name depsList;
      drvJson = builtins.toJSON (
        drv
        // {
          version = drv.version or 4;
        }
      );
    };

  rendered = map renderNode order;

  sinkName = if builtins.isAttrs toOutput then toOutput.sink else null;

  needsAssemblerNode = toOutput == "assemble";

  # The final node MUST be named exactly `name` (the outer wrapper's
  # expected inner name) -- so both the "assemble" and "sink" cases
  # synthesize one small final node with that exact name, rather than
  # trying to rename an existing node in place (a node's OWN name is
  # already baked into its registered .drv, immutable after registration).
  #
  # "assemble": copies every real node's output into one directory tree
  # via symlinks, mirroring gradle-drvs' own assembler derivation exactly.
  # "sink": a trivial single-symlink passthrough to the named sink node's
  # output (sandstone's pattern: only the final linked binary matters).
  finalNode =
    let
      copyLines =
        if needsAssemblerNode then
          map (n: ''${pkgs.coreutils}/bin/ln -s "@dyndrv-node-placeholder:${n}@" "$out/${n}"'') order
        else
          [ ''${pkgs.coreutils}/bin/ln -s "@dyndrv-node-placeholder:${sinkName}@" "$out"'' ];
      # `inputs.srcs` wants a bare BASENAME, not a full store path
      # (confirmed empirically: a full path fails with "'' is too short
      # to be a valid store path" -- matches nixgg's own documented
      # gotcha exactly). Declares coreutils as an input so `mkdir`/`ln`
      # are usable by absolute path -- a `builder-rpc-v0`-registered
      # derivation has no ambient $PATH.
      coreutilsBasename = builtins.baseNameOf "${pkgs.coreutils}";
    in
    {
      name = "__dyndrv_final";
      depsList = if needsAssemblerNode then order else [ sinkName ];
      drvJson = builtins.toJSON {
        inherit name;
        system = builtins.currentSystem;
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
          out = "@dyndrv-placeholder:out@";
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

  allNodes = rendered ++ [ finalNode ];

  finalNodeName = "__dyndrv_final";

  # Bash function computing DownstreamPlaceholder::unknownCaOutput,
  # ported from the verified formula in placeholder.nix (confirmed to
  # match Nix's own computed placeholder exactly, see graph/compile.nix's
  # header comment / the plan's resolved findings). `nix hash convert` is
  # used here (unlike placeholder.nix's pure builtins.convertHash) because
  # this runs inside the bash builder script, not Nix-expression eval.
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

  renderNodeScript = n: ''
    drvJson=$(cat <<'DYNDRV_NODE_JSON'
    ${n.drvJson}
    DYNDRV_NODE_JSON
    )

    # Wire this node's declared deps into inputs.drvs, using their ACTUAL
    # registered basenames (known only now, at this point in the script).
    # `+ {inputs: {drvs: {}, srcs: []}}` ensures both keys exist even if
    # the node's own mkDrv output omitted `inputs` entirely (the common
    # case: most producer-authored nodes never reference inputSrcs).
    drvJson=$(echo "$drvJson" | jq '.inputs.drvs //= {} | .inputs.srcs //= []')
    inputDrvs='{}'
    ${lib.concatMapStringsSep "\n" (dep: ''
      inputDrvs=$(echo "$inputDrvs" | jq --arg k "''${drvs[${dep}]}" '. + {($k): {"outputs": ["out"], "dynamicOutputs": {}}}')
    '') n.depsList}
    drvJson=$(echo "$drvJson" | jq --argjson inputDrvs "$inputDrvs" '.inputs.drvs = (.inputs.drvs + $inputDrvs)')

    # Substitute this node's own self-placeholder sentinel (existing
    # convention from viaDerivationAdd.nix).
    selfPlaceholder=$(nix eval --raw --expr 'builtins.placeholder "out"')
    drvJson="''${drvJson//@dyndrv-placeholder:out@/$selfPlaceholder}"

    # Substitute every OTHER node's cross-node placeholder sentinel that
    # this node's JSON references, using the already-registered upstream
    # node's real drvPath.
    ${lib.concatMapStringsSep "\n" (dep: ''
      depPlaceholder=$(dyndrv_placeholder "''${drvPathByName[${dep}]}" out)
      drvJson="''${drvJson//@dyndrv-node-placeholder:${dep}@/$depPlaceholder}"
    '') n.depsList}

    drvPathByName[${n.name}]=$(echo "$drvJson" | nix derivation add)
    drvs[${n.name}]=$(basename "''${drvPathByName[${n.name}]}")
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

        ${lib.concatMapStringsSep "\n\n" renderNodeScript allNodes}

        nix store submit-output "''${drvPathByName[${finalNodeName}]}" out
        runHook postBuild
      '';

  extraDrvArgs = {
    nativeBuildInputs = [ pkgs.jq ];
  };
}
