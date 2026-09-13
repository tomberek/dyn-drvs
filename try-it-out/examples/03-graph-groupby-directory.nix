# Demonstrates `dyndrv.graph.groupByDirectory` -- the canned "by
# directory" helper for `graph.compile`'s `group` field. Three nodes: two
# share a source path under `src/` and get merged into ONE registered
# derivation; a third, under `lib/`, stays its own solo unit and depends
# on one of the merged pair's outputs.
#
# This is the same underlying mechanism `03-graph-with-groups.nix`
# exercises directly (by hand-setting `group` per node) -- this example
# instead derives `group` automatically from each node's own declared
# path.
#
# Run with:
#   try-it-out/run-nix.sh build --impure -f try-it-out/examples/03-graph-groupby-directory.nix
#
# Builds a (src/a) -> "a"; b (src/b, same directory as a, depends on a)
# -> "a\nb" (merged into ONE derivation with a); c (lib/c, different
# directory, depends on b) -> "a\nb\nc" (read via the ordinary cross-unit
# mechanism).

{
  pkgs ? (builtins.getFlake (toString ../..)).legacyPackages.${builtins.currentSystem},
  lib ? pkgs.lib,
  dyndrv ? import ../../nix { inherit pkgs lib; },
}:

let
  patchedNix = import ../patched-nix.nix { system = pkgs.stdenv.hostPlatform.system; };
  coreutilsBasename = builtins.baseNameOf "${pkgs.coreutils}";

  mkNode =
    text: deps:
    { ref }:
    {
      name = "dyndrv-graph-groupby-directory-node-${text}";
      system = pkgs.stdenv.hostPlatform.system;
      builder = "/bin/sh";
      args = [
        "-c"
        (
          if deps == [ ] then
            "echo '${text}' > $out"
          else
            let
              catArgs = lib.concatMapStringsSep " " (dep: lib.escapeShellArg (ref dep)) deps;
            in
            "{ ${pkgs.coreutils}/bin/cat ${catArgs}; echo '${text}'; } > $out"
        )
      ];
      env.out = ref "self";
      inputs = lib.optionalAttrs (deps != [ ]) {
        drvs = { };
        srcs = [ coreutilsBasename ];
      };
      outputs.out = {
        method = "nar";
        hashAlgo = "sha256";
      };
    };

  # `path` here is just plain data threaded through for `groupByDirectory`
  # to read -- it's not part of `graph.compile`'s own node schema (which
  # only looks at `deps`/`group`/`mkDrv`), matching the "an extra, node-
  # schema-external field a discovery step might carry" shape a real
  # caller (one that already knows each node's source file) would have.
  ungroupedNodes = {
    a = {
      deps = [ ];
      path = "src/a.c";
      mkDrv = mkNode "a" [ ];
    };
    b = {
      deps = [ "a" ];
      path = "src/b.c";
      mkDrv = mkNode "b" [ "a" ];
    };
    c = {
      deps = [ "b" ];
      path = "lib/c.c";
      mkDrv = mkNode "c" [ "b" ];
    };
  };

  nodes = dyndrv.graph.groupByDirectory (name: node: node.path) ungroupedNodes;
in
dyndrv.mkDynamicDerivation {
  pname = "dyndrv-graph-groupby-directory";
  version = "1.0";
  backend = "builder-rpc-v0";
  producer = dyndrv.graph.compile {
    nixPackage = patchedNix;
    name = "dyndrv-graph-groupby-directory-1.0";
    toOutput = "assemble";
    inherit nodes;
  };
}
