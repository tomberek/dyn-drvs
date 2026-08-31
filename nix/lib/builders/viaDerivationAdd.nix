{ pkgs, lib, self }:

# A `producer` constructor for the "builder-rpc-v0" backend: registers one
# derivation via `nix derivation add` (reading hand-built JSON on stdin) and
# hands its output to the outer derivation via `nix store submit-output`,
# instead of writing to `$out` directly.
#
# `builder-rpc-v0` sandboxes have no store DB view and cannot call
# `nix-instantiate`/`builtins.outputOf`/`builtins.storePath` (confirmed
# against gradle-drvs' and nixgg's own notes: "Operation not allowed" ).
# So unlike `viaNixInstantiate`, this backend can only ever consume
# already-fully-known derivation JSON.
#
# v0.1 scope: ONE inner derivation, registered and submitted directly.
# Building a *graph* of many inner derivations (gradle-drvs'/sandstone's
# actual use case) is `dyndrv.graph.compile` (v0.2) -- that's what computes
# a correct registration order and wires up `inputDrvs`/placeholders across
# many nodes; `viaDerivationAdd` is the single-node primitive it's built on.
#
# `toDrvJson`: a plain Nix attrset (the exact schema `nix derivation add`
#              expects -- see nix-src's own `non-trivial.nix` test for the
#              canonical shape: `name`/`system`/`builder`/`args`/`env`/
#              `inputs.{drvs,srcs}`/`outputs`/`version`).
#
#              IMPORTANT: never embed `builtins.placeholder "out"` (or any
#              other output name) directly in `toDrvJson` -- confirmed by
#              direct reproduction: `hashPlaceholder` is a fixed string
#              purely a function of the output NAME (`sha256("nix-output:"
#              + name)`), identical for every derivation's "out" output.
#              Embedding it in `toDrvJson` bakes that string into the
#              *outer* derivation's own `drvJson` env var at Nix-eval time,
#              where Nix's self-reference rewriting (meant to substitute
#              the outer derivation's own placeholder with its real path
#              post-build) silently corrupts it -- the inner derivation
#              ends up with `env.out` pointing at the OUTER derivation's
#              own `.drv` path instead of a real placeholder, and the
#              inner build fails with "failed to produce output path"
#              with no further explanation. This is exactly the pitfall
#              nix-src's own `non-trivial.nix` test comments on: "Cannot
#              just literally include this, or Nix will think it is the
#              *outer* derivation that's trying to refer to itself."
#
#              Instead, use the sentinel `"@dyndrv-placeholder:<output>@"`
#              anywhere a placeholder is needed (e.g.
#              `env.out = "@dyndrv-placeholder:out@"`); the builder script
#              substitutes it for the real, freshly-computed placeholder
#              at BUILD time (via `nix eval --raw`, same as nix-src's test
#              does), after the JSON has already crossed the eval/build
#              boundary -- so it never appears as a literal string in the
#              outer derivation's own eval-time attributes.
#
# `nixPackage`: the patched Nix (tracking NixOS/nix#15793) to run `nix
#               derivation add`/`nix store submit-output` with, INSIDE the
#               sandbox. Deliberately not defaulted to `pkgs.nix`: an
#               unpatched client sends a `SetOptions` worker-protocol call
#               on connect that the restricted store rejects outright
#               ("Operation 19 not allowed inside derivation") -- only a
#               client that negotiates `featureDisableSetOptions` (the
#               patched build) works here. `try-it-out/patched-nix.nix`
#               is the intended source for this argument.
#
#               MUST be a properly-packaged Nix store derivation (e.g. via
#               `autoPatchelfHook`, not a raw copy of a meson build tree's
#               binary) -- verified end-to-end against a local build of
#               NixOS/nix#15793: a hand-copied binary's `$ORIGIN`-relative
#               rpath and unregistered runtime closure (glibc/sqlite/etc)
#               both break once the binary is referenced by a plain string
#               or `builtins.storePath` (neither carries closure
#               information), silently producing "required file not
#               found"/"cannot open shared object file" deep inside the
#               sandbox instead of an eval-time error. Passing `nixPackage`
#               as an ordinary derivation (so its full closure is tracked
#               normally) avoids this entirely.

{
  toDrvJson,
  nixPackage,
}:

{
  script =
    backend:
    if backend != "builder-rpc-v0" then
      throw "dyndrv.builders.viaDerivationAdd only supports the builder-rpc-v0 backend, got: ${backend}"
    else
      ''
        runHook preBuild
        export PATH="${nixPackage}/bin:$PATH"
        export NIX_CONFIG='extra-experimental-features = nix-command ca-derivations dynamic-derivations'

        drvJson="$(cat "$drvJsonPath")"
        for outputName in $(echo "$drvJson" | grep -oP '@dyndrv-placeholder:\K[^@]+(?=@)' | sort -u); do
          placeholder=$(nix eval --raw --expr "builtins.placeholder \"$outputName\"")
          drvJson="''${drvJson//@dyndrv-placeholder:$outputName@/$placeholder}"
        done

        drvPath=$(echo "$drvJson" | nix derivation add)
        nix store submit-output "$drvPath" out
        runHook postBuild
      '';

  extraDrvArgs = {
    passAsFile = [ "drvJson" ];
    drvJson = builtins.toJSON toDrvJson;
  };
}



