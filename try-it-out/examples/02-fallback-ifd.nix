# Demonstrates dyndrv.capabilities.withFallback: the same intent (build a
# tiny "hello" derivation) expressed once as a `dynamic` alternative (via
# mkDynamicDerivation) and once as a plain `ifd` alternative -- so this
# works on *any* Nix, not just one with dynamic-derivations enabled.
#
# Run with plain, unpatched Nix (no run-nix.sh, no experimental features
# required for the ifd path to kick in):
#   nix build --extra-experimental-features nix-command -f try-it-out/examples/02-fallback-ifd.nix
#
# Or with dynamic-derivations enabled (picks the `dynamic` alternative
# instead, same result):
#   nix build --extra-experimental-features "nix-command dynamic-derivations ca-derivations recursive-nix" \
#     -f try-it-out/examples/02-fallback-ifd.nix

{
  pkgs ? (builtins.getFlake (toString ../..)).legacyPackages.${builtins.currentSystem},
}:
let
  lib = pkgs.lib;
  dyndrv = import ../../nix { inherit pkgs lib; };

  helloExpr = ''
    derivation {
      name = "hello-fallback-1.0";
      system = builtins.currentSystem;
      builder = "/bin/sh";
      args = [ "-c" "echo 'hello (via dynamic derivation)' > $out" ];
    }
  '';
in
dyndrv.capabilities.withFallback {
  dynamic = dyndrv.mkDynamicDerivation {
    pname = "hello-fallback";
    version = "1.0";
    # `viaNixInstantiate` only supports "recursive-nix", and
    # `withFallback`'s decision to try this branch is based on
    # `capabilities.selectBackend`'s detected pick -- so this branch asks
    # for that same resolution via `backend = "auto"`, rather than relying
    # on `mkDynamicDerivation`'s unset default ("builder-rpc-v0").
    backend = "auto";
    onUnsupported = "fail"; # withFallback already decided this branch is safe to try
    producer = dyndrv.builders.viaNixInstantiate {
      expr = helloExpr;
    };
  };

  ifd = pkgs.runCommand "hello-fallback-1.0" { } ''
    echo 'hello (via plain IFD/import, no dynamic derivations)' > $out
  '';
}
