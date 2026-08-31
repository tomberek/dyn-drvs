{ pkgs, lib, self }:

# Computes `DownstreamPlaceholder::unknownCaOutput` -- the placeholder
# hash for a not-yet-built output of a KNOWN (not-yet-built) derivation,
# needed whenever one graph node must reference another not-yet-built
# node's output inside a `builder-rpc-v0` sandbox, where `builtins.outputOf`
# and `builtins.storePath` are both blocked ("Operation not allowed").
# This is the exact primitive gradle-drvs hand-reimplemented in bash
# because of that restriction (see pattern 3 in the research).
#
# Formula (confirmed by direct reproduction against Nix's own
# `downstream-placeholder.cc`, matching `builtins.outputOf`'s own computed
# result exactly for a real CA derivation, verified 2026-08-31):
#
#   sha256("nix-upstream-output:" + drvHashPart + ":" + outputPathName)
#     converted to nix32 (no type/algo prefix), where:
#   outputPathName = drvName                    if outputName == "out"
#                  = drvName + "-" + outputName otherwise
#   drvName = the derivation's declared `name`, WITHOUT the trailing `.drv`
#   drvHashPart = the base32 hash portion of the drv's own store-path
#                 basename (the part before the first `-`)
#
# This is a PURE function of (drvPath, outputName) -- no store/daemon
# access needed, computed here entirely via `builtins.hashString` +
# `builtins.convertHash` (both pure builtins, no derivation build or
# external `nix hash convert` call required). Usable from ordinary
# Nix-expression eval-time code, or ported to bash for use inside a
# `builder-rpc-v0` sandbox where these builtins aren't reachable in that
# exact form -- `graph/compile.nix`'s generated builder scripts do the
# bash-side port of this same formula.
#
# `drvName`: the producing derivation's declared name, minus `.drv`.
# `drvHashPart`: the base32 hash-part of the producing derivation's own
#                `.drv` store path (i.e. `builtins.baseNameOf drvPath`,
#                split on the first `-`).
# `outputName`: which output of that derivation to compute a placeholder
#               for (usually `"out"`).

{
  drvName,
  drvHashPart,
  outputName ? "out",
}:

let
  outputPathName = if outputName == "out" then drvName else "${drvName}-${outputName}";
  clearText = "nix-upstream-output:${drvHashPart}:${outputPathName}";
  hashHex = builtins.hashString "sha256" clearText;
  nix32 = builtins.convertHash {
    hash = hashHex;
    hashAlgo = "sha256";
    toHashFormat = "nix32";
  };
in
"/${nix32}"
