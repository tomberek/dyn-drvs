{ pkgs, lib, self }:

# Pure topological sort of a `nodes` attrset (`name -> { deps = [ names ]; ... }`).
# Returns a list of names such that every node appears after all its deps.
#
# Used by graph/compile.nix so the caller never has to hand-order `nodes`
# themselves -- unlike v0.1's `viaDerivationAdd.nix` doc note ("registration
# order... callers of `viaDerivationAdd` are expected to supply `nodes` in
# dependency order themselves"), which this supersedes for anyone going
# through `graph.compile`.
#
# INTERNAL: a pure algorithm step of `graph.compile` (its only caller),
# not a user-facing primitive -- deliberately NOT exported from
# `nix/default.nix`'s public attrset, only reachable via
# `self.graph.topoSort` from other lib files.

nodes:

let
  names = builtins.attrNames nodes;

  # Kahn's algorithm: repeatedly peel off nodes with no unresolved deps.
  go =
    remaining: resolved:
    if remaining == [ ] then
      resolved
    else
      let
        ready = builtins.filter (
          name: builtins.all (dep: builtins.elem dep resolved) (nodes.${name}.deps or [ ])
        ) remaining;
      in
      if ready == [ ] then
        throw ''
          dyndrv.graph: dependency cycle detected among nodes: ${toString remaining}
        ''
      else
        go (builtins.filter (name: !(builtins.elem name ready)) remaining) (resolved ++ ready);
in
go names [ ]
