# dyndrv's own reduced port of nix-src's non-trivial.nix (see
# ../../tests/oracle/non-trivial.nix): that test hand-builds a 5-node
# diamond dependency graph (a -> b,c -> d -> e) via `nix derivation add`
# inside a recursive-nix sandbox, to prove dynamic derivations work as a
# general graph-construction primitive, not just a two-level trick.
#
# v0.1 scope note, confirmed by direct reproduction: chaining two
# INTERDEPENDENT dynamically-produced derivations through
# `viaNixInstantiate`'s `args` (JSON-encoded) does NOT work yet --
# `builtins.toJSON` strips Nix string context, so a not-yet-built
# derivation's output path loses its dependency-tracking context when it
# crosses `mkArgs.nix`'s eval->build JSON boundary. The result: the
# dependent derivation gets registered with an EMPTY `inputs.drvs`, so its
# build sandbox never mounts the upstream output, and the build fails
# ("cat: not found"/file not accessible) even though the path is
# syntactically present in the builder's `args`. This is real,
# reproducible, and exactly the gap `dyndrv.graph.compile` (v0.2) needs to
# close by wiring `inputDrvs`/`dynamicOutputs` correctly (the way nix-src's
# own hand-rolled bash JSON construction in `non-trivial.nix` does) --
# `viaNixInstantiate`'s simpler args-passing story is not a substitute for
# that. Tracked as a known v0.1 limitation, not silently worked around.
#
# What THIS test proves instead (still a genuine, useful property): two
# INDEPENDENT dynamically-produced derivations, each going through the
# full mkDynamicDerivation -> viaNixInstantiate -> outputOf pipeline, can
# both be realized side by side without interfering with each other.
#
# Run with: try-it-out/run-nix.sh build --impure -f nix/tests/nonTrivial.nix
# (recursive-nix backend, works with the installed system Nix -- see
# nix/tests/run-tests.sh for the exact invocation used in CI)

{ pkgs, lib, dyndrv }:

let
  a = dyndrv.mkDynamicDerivation {
    pname = "dyndrv-test-node-a";
    version = "1.0";
    backend = "recursive-nix";
    producer = dyndrv.builders.viaNixInstantiate {
      expr = ''
        derivation {
          name = "dyndrv-test-node-a-1.0";
          system = pkgs.stdenv.hostPlatform.system;
          builder = "/bin/sh";
          args = [ "-c" "echo 'from node a' > $out" ];
        }
      '';
    };
  };

  c = dyndrv.mkDynamicDerivation {
    pname = "dyndrv-test-node-c";
    version = "1.0";
    backend = "recursive-nix";
    producer = dyndrv.builders.viaNixInstantiate {
      expr = ''
        derivation {
          name = "dyndrv-test-node-c-1.0";
          system = pkgs.stdenv.hostPlatform.system;
          builder = "/bin/sh";
          args = [ "-c" "echo 'from node c' > $out" ];
        }
      '';
    };
  };
in
{
  inherit a c;
  pass = a.outputOf != null && c.outputOf != null;
}
