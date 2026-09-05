{ pkgs, lib, self }:

# Canned `group`-assignment helper for `graph.compile`'s node schema:
# given a flat `nodes` attrset and a function extracting each node's own
# source path, returns the same nodes with `group` set to that path's
# directory -- every node in the same directory shares one registered
# derivation.
#
# Sugar over a one-line `lib.mapAttrs`, not a second grouping mechanism --
# the actual merging logic lives entirely in `graph.compile`'s `group`
# field. This just names the "by directory" heuristic once.
#
# `nodes`: a `graph.compile`-shaped `{ <name> = { deps, mkDrv, ... }; }`
#          attrset, `group` field ignored/overwritten.
# `pathOf`: `nodeName -> node -> <relative path string>`. `group` is set
#           to that path's `dirOf`.

pathOf: nodes:
lib.mapAttrs (name: node: node // { group = lib.dirOf (pathOf name node); }) nodes

