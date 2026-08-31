{ pkgs, lib, self }:

# Turn a raw `builtins.outputOf` string into something `nix run`/`nix
# profile install`/`nix build` can consume directly. A bare `outputOf`
# string has no `.type`/`.drvPath`, so those commands fail outright
# ("attribute 'type' does not exist") unless wrapped -- this is what
# nixgg's `.package` and drowse's `transformDrv` both do by hand.
#
# `mkDynamicDerivation` calls this internally; it's exposed standalone for
# callers who already have an `outputOf` string (e.g. from a hand-built
# `producer`, or from chaining another dynamic derivation) and just need it
# turned into an ordinary derivation.

{
  name,
  meta ? null,
  pname ? null,
  version ? null,
  pos ? null,
}:
outputOfString:

pkgs.runCommand name
  (
    {
      passthru = {
        outputOf = outputOfString;
      };
    }
    // lib.optionalAttrs (pos != null) { inherit pos; }
    // lib.optionalAttrs (meta != null) { inherit meta; }
    // lib.optionalAttrs (pname != null && version != null) { inherit pname version; }
  )
  ''
    ln -s ${outputOfString} "$out"
  ''
