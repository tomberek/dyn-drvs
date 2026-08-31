{ pkgs, lib, self }:

# Avoid copying stuff to the store when possible.
#
# Ported from drowse's `__pathToString.nix`. Naively stringifying a store
# path (`"${path}"`) makes Nix copy the referenced path into the store if
# it isn't already an actual store path (e.g. a source tree from
# `pkgs.path`), and even when it already IS a store path, plain
# stringification attaches full string context (forcing the whole closure to
# be realized before the string can be used). `builtins.appendContext` lets
# us build a string that carries a reference to the path (so Nix still knows
# about the dependency) without forcing a copy or a build -- useful for
# things like `NIX_PATH=nixpkgs=${pathToString pkgs.path}` where only the
# path string is needed, not the derivation output.

path:

if !lib.isDerivation path && lib.isStorePath path then
  let
    str = toString path;
  in
  builtins.appendContext str {
    ${str}.path = true;
  }
else
  "${path}"
