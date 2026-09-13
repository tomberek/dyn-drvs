# Minimal end-to-end example of the "builder-rpc-v0" default backend:
# dyndrv.mkDynamicDerivation wraps a viaDerivationAdd producer, which
# registers one inner derivation via `nix derivation add` and hands it to
# the outer derivation via `nix store submit-output`.
#
# Run with: try-it-out/run-nix.sh build -f try-it-out/examples/01-hello-dynamic-drv.nix
# (no patched Nix needed -- see try-it-out/patched-nix.nix's own header
# comment: builder-rpc-v0 is on real NixOS/nix master, run-nix.sh fetches
# and builds it directly)

{
  pkgs ? (builtins.getFlake (toString ../..)).legacyPackages.${builtins.currentSystem},
}:
let
  lib = pkgs.lib;
  dyndrv = import ../../nix { inherit pkgs lib; };
in
dyndrv.mkDynamicDerivation {
  pname = "hello-dyn";
  version = "1.0";
  backend = "builder-rpc-v0";
  producer = dyndrv.builders.viaDerivationAdd {
    nixPackage = import ../patched-nix.nix { system = pkgs.stdenv.hostPlatform.system; };
    toDrvJson = {
      name = "hello-dyn-1.0";
      system = pkgs.stdenv.hostPlatform.system;
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
