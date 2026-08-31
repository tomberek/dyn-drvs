{ pkgs, lib, self }:

# Default `toOutput` for `graph.compile`: merge every node's output into
# one directory tree via symlinks, for graphs where every node's output
# matters (no single "final" node) -- gradle-drvs' own "assembler"
# derivation (copying every fetched Maven artifact into one
# `$out/https/<host>/...` tree) and nixgg's `assemble` (walking a build
# tree collecting every pending compile's stub) are both this shape.
#
# `nodeOutputs`: an attrset `{ <nodeName> = <derivation-or-outputOf-string>; }`
#                -- one entry per graph node, already resolved.

nodeOutputs:

pkgs.symlinkJoin {
  name = "dyndrv-graph-assembled";
  paths = builtins.attrValues nodeOutputs;
}
