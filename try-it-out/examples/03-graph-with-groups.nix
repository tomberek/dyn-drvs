# dyndrv's test for `dyndrv.graph.compile`'s `group` field: two nodes
# (a, b) sharing `group = "g1"` get merged into ONE registered
# derivation (one `nix derivation add` call instead of two), plus a third
# ungrouped node (c) that depends on the merged group's "b" output
# across the unit boundary -- exercising both a within-group reference
# (b reads a's output, both members of "g1") and a cross-unit reference
# (c reads g1's "b" output, same mechanism `03-graph-of-two.nix`/
# `03-graph-of-three.nix` already exercise for ungrouped nodes).
#
# This is the one mechanism this library provides for consolidating a
# fine-grained dynamic-derivation graph into coarser sub-components --
# a single field on the existing node schema, not a second grouping API.
#
# Unlike nix/tests/{mkOutputOf,nonTrivial}.nix (which only need
# recursive-nix, working with the installed system Nix), this test needs
# `try-it-out/run-nix.sh` (builder-rpc-v0, via a fetched NixOS/nix build)
# and therefore isn't wired into nix/tests/default.nix's flake-check path.
#
# Run with:
#   try-it-out/run-nix.sh build --impure -f try-it-out/examples/03-graph-with-groups.nix
#
# Builds a -> "a" (registered as part of the merged "g1" derivation's
# own "a" output); b, sharing group "g1" with a and depending on it ->
# "a\nb" (the merged derivation's "b" output, read via the within-group
# self-placeholder mechanism -- no cross-derivation lookup needed, since
# both are outputs of the same not-yet-registered derivation); c,
# ungrouped, depending on b -> "a\nb\nc" (read via the ordinary cross-unit
# DownstreamPlaceholder mechanism, asking for group "g1"'s "b"-named
# output specifically, not "out"). Confirms only ONE `nix derivation add`
# call happens for the merged pair.

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
      name = "dyndrv-graph-with-groups-node-${text}";
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
in
dyndrv.mkDynamicDerivation {
  pname = "dyndrv-graph-with-groups";
  version = "1.0";
  backend = "builder-rpc-v0";
  producer = dyndrv.graph.compile {
    nixPackage = patchedNix;
    name = "dyndrv-graph-with-groups-1.0";
    toOutput = "assemble";
    nodes = {
      a = {
        deps = [ ];
        group = "g1";
        mkDrv = mkNode "a" [ ];
      };
      b = {
        deps = [ "a" ];
        group = "g1";
        mkDrv = mkNode "b" [ "a" ];
      };
      c = {
        deps = [ "b" ];
        mkDrv = mkNode "c" [ "b" ];
      };
    };
  };
}
