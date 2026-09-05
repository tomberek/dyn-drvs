{ pkgs, lib }:

let
  # `self` (bound below) is the FULL internal attrset, including plumbing
  # (`mkArgs`, `graph.topoSort`) that other lib files call via
  # `self.mkArgs`/`self.graph.topoSort` -- those two are genuine
  # implementation details (used by exactly one caller each internally,
  # never meant to be reached for directly), so they're stripped from
  # `dyndrv`, the value this file actually returns, at the bottom. This
  # keeps internal wiring working without publishing plumbing as if it
  # were a first-class part of the API.
  callLib = file: import file ({ inherit pkgs lib; } // { self = full; });

  full = {
    capabilities = callLib ./lib/capabilities.nix;
    mkArgs = callLib ./lib/mkArgs.nix;
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
      groupByDirectory = callLib ./lib/graph/groupByDirectory.nix;
    };

    shim = {
      wrapCommand = callLib ./lib/shim/wrapCommand.nix;
      wrapArchiver = callLib ./lib/shim/wrapArchiver.nix;
      batchStub = callLib ./lib/shim/batchStub.nix;
    };

    accelerate = {
      mkAcceleratedStdenv = callLib ./lib/accelerate/mkAcceleratedStdenv.nix;
    };
  };
in
removeAttrs full [ "mkArgs" ] // {
  graph = removeAttrs full.graph [ "topoSort" ];
  shim = removeAttrs full.shim [ "batchStub" ];
}
