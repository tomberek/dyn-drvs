{ pkgs, lib, self }:

# Alternate `toOutput` for `graph.compile`: instead of merging every node's
# output, return one specific node's output directly, treating every other
# node as a pure means to that end. This is sandstone's shape exactly:
# dozens of per-module compile derivations exist only so the final
# `writeLinkDerivation` (the one node with no downstream dependents) has
# something to link against -- the caller wants that one linked binary
# back, not a directory of intermediate `.o` files.
#
# `sinkName`: which node's output to return.
# `nodeOutputs`: an attrset `{ <nodeName> = <derivation-or-outputOf-string>; }`.

sinkName: nodeOutputs:

if !(nodeOutputs ? ${sinkName}) then
  throw ''
    dyndrv.graph.selectSink: no node named "${sinkName}" in this graph
    (available: ${toString (builtins.attrNames nodeOutputs)})
  ''
else
  nodeOutputs.${sinkName}
