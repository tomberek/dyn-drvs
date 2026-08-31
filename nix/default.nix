{ pkgs, lib }:

let
  callLib = file: import file ({ inherit pkgs lib; } // { self = dyndrv; });

  dyndrv = {
    capabilities = callLib ./lib/capabilities.nix;
    mkArgs = callLib ./lib/mkArgs.nix;
    pathToString = callLib ./lib/pathToString.nix;
    mkOutputOf = callLib ./lib/mkOutputOf.nix;
    wrapOutputOf = callLib ./lib/wrapOutputOf.nix;
    mkDynamicDerivation = callLib ./lib/mkDynamicDerivation.nix;

    builders = {
      viaNixInstantiate = callLib ./lib/builders/viaNixInstantiate.nix;
      viaDerivationAdd = callLib ./lib/builders/viaDerivationAdd.nix;
    };
  };
in
dyndrv
