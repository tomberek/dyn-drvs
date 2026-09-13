# dyndrv's test for `dyndrv.graph.compile`: a THREE-node graph where the
# final node depends on TWO upstream nodes (not just one, unlike
# `03-graph-of-two.nix`) -- a small diamond shape: a -> b -> c, and c ALSO
# depends directly on a. Exercises `ref` resolving more than one declared
# dependency name inside a single node's `mkDrv`, and `toOutput`'s
# "assemble"/`{ sink = ...; }` modes over three nodes instead of two.
#
# Unlike nix/tests/{mkOutputOf,nonTrivial}.nix (which only need
# recursive-nix, working with the installed system Nix), this test needs
# `try-it-out/run-nix.sh` (builder-rpc-v0, via a fetched NixOS/nix build --
# see try-it-out/patched-nix.nix, no patched Nix needed anymore) and
# therefore isn't wired into nix/tests/default.nix's flake-check path.
#
# Run with:
#   try-it-out/run-nix.sh build -f try-it-out/examples/03-graph-of-three.nix
#
# Builds a three-node graph -- a -> "a"; b, depending on a -> "a\nb"; c,
# depending on BOTH a and b -> "a\na\nb\nc" (c's own body concatenates a's
# content, then b's content -- which already includes a's -- then appends
# its own line, hence the repeated "a") -- and checks both `toOutput =
# "assemble"` (merges all three nodes' outputs into one directory: $out/a,
# $out/b, $out/c) and `toOutput = { sink = "c"; }` (returns node c's
# content directly, no wrapping directory) resolve correctly.

{
  pkgs ? (builtins.getFlake (toString ../..)).legacyPackages.${builtins.currentSystem},
  lib ? pkgs.lib,
  dyndrv ? import ../../nix { inherit pkgs lib; },
  toOutputMode ? "assemble", # "assemble" | "sink"
}:

let
  patchedNix = import ../patched-nix.nix { system = pkgs.stdenv.hostPlatform.system; };

  coreutilsBasename = builtins.baseNameOf "${pkgs.coreutils}";

  # `deps`: names of upstream nodes THIS node reads from (via `ref <name>`).
  # `catCmd`: shell command concatenating every dep's content, in order.
  mkNode =
    text: deps:
    { ref }:
    {
      name = "dyndrv-graph-of-three-node-${text}";
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
  pname = "dyndrv-graph-of-three";
  version = "1.0";
  backend = "builder-rpc-v0";
  producer = dyndrv.graph.compile {
    nixPackage = patchedNix;
    name = "dyndrv-graph-of-three-1.0";
    toOutput = if toOutputMode == "sink" then { sink = "c"; } else "assemble";
    nodes = {
      a = {
        deps = [ ];
        mkDrv = mkNode "a" [ ];
      };
      b = {
        deps = [ "a" ];
        mkDrv = mkNode "b" [ "a" ];
      };
      c = {
        deps = [ "a" "b" ];
        mkDrv = mkNode "c" [ "a" "b" ];
      };
    };
  };
}
