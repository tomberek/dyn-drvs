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
    placeholder = callLib ./lib/placeholder.nix;

    builders = {
      viaNixInstantiate = callLib ./lib/builders/viaNixInstantiate.nix;
      viaDerivationAdd = callLib ./lib/builders/viaDerivationAdd.nix;
    };

    graph = {
      topoSort = callLib ./lib/graph/topoSort.nix;
      assemble = callLib ./lib/graph/assemble.nix;
      selectSink = callLib ./lib/graph/selectSink.nix;
      compile = callLib ./lib/graph/compile.nix;
    };

    shim = {
      wrapCommand = callLib ./lib/shim/wrapCommand.nix;
    };

    accelerate = {
      mkAcceleratedStdenv = callLib ./lib/accelerate/mkAcceleratedStdenv.nix;
      wrap = callLib ./lib/accelerate/wrap.nix;
    };
  };
in
dyndrv
