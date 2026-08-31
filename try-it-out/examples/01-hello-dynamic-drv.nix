# Minimal end-to-end example of the "builder-rpc-v0" default backend:
# dyndrv.mkDynamicDerivation wraps a viaDerivationAdd producer, which
# registers one inner derivation via `nix derivation add` and hands it to
# the outer derivation via `nix store submit-output`.
#
# Run with: try-it-out/run-nix.sh build -f try-it-out/examples/01-hello-dynamic-drv.nix
# (requires a patched Nix -- see try-it-out/README.md)

let
  pkgs = import <nixpkgs> { };
  lib = pkgs.lib;
  dyndrv = import ../../nix { inherit pkgs lib; };
in
dyndrv.mkDynamicDerivation {
  pname = "hello-dyn";
  version = "1.0";
  backend = "builder-rpc-v0";
  producer = dyndrv.builders.viaDerivationAdd {
    nixPackage = (import ../patched-nix.nix { inherit pkgs; }) {
      nixSrc = /. + builtins.getEnv "NIX_SRC";
    };
    toDrvJson = {
      name = "hello-dyn-1.0";
      system = builtins.currentSystem;
      builder = "/bin/sh";
      args = [
        "-c"
        "echo 'hello from a dynamically-produced derivation' > $out"
      ];
      env = {
        out = "@dyndrv-placeholder:out@";
      };
      inputs = {
        drvs = { };
        srcs = [ ];
      };
      outputs = {
        out = {
          method = "nar";
          hashAlgo = "sha256";
        };
      };
      version = 4;
    };
  };
}
