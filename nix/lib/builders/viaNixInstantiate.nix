{ pkgs, lib, self }:

# A `producer` constructor for the "recursive-nix" backend: runs
# `nix-instantiate` on a literal Nix expression *inside* the sandbox
# (recursive-nix lets a build invoke Nix itself), installing the resulting
# `.drv` as the outer derivation's output.
#
# Ported from drowse's `instantiate.nix`. Pass an `expr` that does a
# `callPackage`-style `import ./generated.nix { ... }` yourself if that's
# your shape (drowse's own actual use case) -- there's no separate
# `dyndrv.builders.callPackage` wrapper for it; `viaNixInstantiate` is
# already the generic primitive for "instantiate an arbitrary Nix
# expression at build time," and a `callPackage` call is just one such
# expression.
#
# `expr`: a string of Nix source, instantiated via `nix-instantiate --expr`.
#         If `args` is non-empty, `expr` must be a function taking one
#         argument named `args` (i.e. `args: <expr using args>`) --
#         mirrors drowse's `callPackage.nix` layering, generalized so any
#         caller can cross the eval->build boundary this way, not just a
#         callPackage-specific wrapper.
# `args`: crosses the eval->build boundary via mkArgs (JSON attrset, or a
#         literal Nix-expression string); bound to the name `args` inside
#         `expr` (see mkArgs.nix for the exact protocol).

{
  expr,
  args ? { },
  nativeBuildInputs ? [ ],
}:

let
  args' = self.mkArgs "instantiateArgs" args;
  hasArgs = args != { };
in
{
  script =
    backend:
    if backend != "recursive-nix" then
      throw "dyndrv.builders.viaNixInstantiate only supports the recursive-nix backend, got: ${backend}"
    else
      ''
        runHook preBuild
        # `args'.load`'s value contains literal double-quote characters
        # (e.g. `builtins.getEnv "instantiateArgsPath"`) -- assigning it to
        # a bash variable via single-quoted Nix antiquotation, then
        # referencing it as "$argsLoad", keeps those quotes intact:
        # embedding it directly inside the --expr string below (double
        # quoted) would let bash's OWN parser treat those quote chars as
        # bash quoting syntax and silently strip them, corrupting the expr
        # nix-instantiate receives (confirmed by direct reproduction --
        # this produced `builtins.getEnv instantiateArgsPath`, no quotes,
        # which nix-instantiate then rejects as an undefined variable).
        argsLoad='${lib.optionalString hasArgs args'.load}'
        drv=$(nix-instantiate --expr "($(cat "$instantiateExprPath")) $argsLoad")
        install -Dm444 "$drv" "$out"
        runHook postBuild
      '';

  extraDrvArgs = {
    nativeBuildInputs = nativeBuildInputs ++ [ pkgs.nix ];
    passAsFile = [
      "instantiateExpr"
      "instantiateArgs"
    ];
    instantiateExpr = expr;
    instantiateArgs = args'.value;
  };
}
