# dyndrv's test for `dyndrv.graph.compile`: a genuinely dependent 2-node
# graph (b depends on a's not-yet-built output), registered via
# `nix derivation add` and resolved through the `builder-rpc-v0` backend,
# verified against both `toOutput` modes.
#
# Unlike nix/tests/{mkOutputOf,nonTrivial}.nix (which only need
# recursive-nix, working with the installed system Nix), this test needs
# `try-it-out/run-nix.sh` (builder-rpc-v0, via a fetched NixOS/nix build --
# see try-it-out/patched-nix.nix, no patched Nix needed anymore) and
# therefore isn't wired into nix/tests/default.nix's flake-check path.
#
# Run with:
#   try-it-out/run-nix.sh build -f try-it-out/examples/03-graph-of-two.nix
#
# Builds a two-node graph (a -> "from a"; b, depending on a, -> "from a\nand
# b"), and checks both `toOutput = "assemble"` (merges both nodes' outputs
# into one directory: $out/a, $out/b) and `toOutput = { sink = "b"; }`
# (returns node b's content directly, no wrapping directory) resolve
# correctly.

{
  pkgs ? (builtins.getFlake (toString ../..)).legacyPackages.${builtins.currentSystem},
  lib ? pkgs.lib,
  dyndrv ? import ../../nix { inherit pkgs lib; },
  toOutputMode ? "assemble", # "assemble" | "sink"
}:

let
  patchedNix = import ../patched-nix.nix { system = pkgs.stdenv.hostPlatform.system; };

  mkNode =
    text: deps:
    { ref }:
    {
      name = "dyndrv-graph-of-two-node-${text}";
      system = pkgs.stdenv.hostPlatform.system;
      builder = "/bin/sh";
      args = [
        "-c"
        (
          if deps == [ ] then
            "echo 'from ${text}' > $out"
          else
            "{ ${pkgs.coreutils}/bin/cat ${lib.escapeShellArg (ref (builtins.elemAt deps 0))}; echo 'and ${text}'; } > $out"
        )
      ];
      env.out = ref "self";
      inputs = lib.optionalAttrs (deps != [ ]) {
        drvs = { };
        srcs = [ (builtins.baseNameOf "${pkgs.coreutils}") ];
      };
      outputs.out = {
        method = "nar";
        hashAlgo = "sha256";
      };
    };
in
dyndrv.mkDynamicDerivation {
  pname = "dyndrv-graph-of-two";
  version = "1.0";
  backend = "builder-rpc-v0";
  producer = dyndrv.graph.compile {
    nixPackage = patchedNix;
    name = "dyndrv-graph-of-two-1.0";
    toOutput = if toOutputMode == "sink" then { sink = "b"; } else "assemble";
    nodes = {
      a = {
        deps = [ ];
        mkDrv = mkNode "a" [ ];
      };
      b = {
        deps = [ "a" ];
        mkDrv = mkNode "b" [ "a" ];
      };
    };
  };
}
