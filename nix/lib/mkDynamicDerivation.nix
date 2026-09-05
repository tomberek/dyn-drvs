{ pkgs, lib, self }:

# The convergent core primitive found in every surveyed project (drowse,
# gradle-drvs, nixgg, sandstone, dgd): an outer derivation named
# "${name}.drv", content-addressed with `outputHashMode = "text"`, whose
# build produces a `.drv` file as its output -- that `.drv`'s own output is
# then resolved via `builtins.outputOf`.
#
# Ported from drowse's `mkDynamicDerivation.nix`, generalized with a
# `backend` argument so both mechanisms found in the wild
# ("recursive-nix" + nix-instantiate/nix derivation add running *inside* the
# sandbox, vs. the newer "builder-rpc-v0" + `nix store submit-output`) are
# supported behind one entry point. See nix/lib/builders/ for what actually
# runs inside the sandbox for each backend -- that's the one place the two
# backends can't be fully unified (a builder-rpc-v0 sandbox has no store DB
# view and can't call nix-instantiate).
#
# `producer` supplies the backend-specific builder script (see
# nix/lib/builders/via*.nix); `mkDynamicDerivation` handles everything else:
# naming, CA/output-hash attributes, unwrap via `outputOf`, and forwarding
# meta/pname/version/position so the returned derivation looks and behaves
# like an ordinary one.
#
# THE PRODUCER CONTRACT: a `producer` is any attrset shaped like
#   { script :: backend -> string; extraDrvArgs :: attrset; }
# `script` is called with the SELECTED backend (`"recursive-nix"` or
# `"builder-rpc-v0"`) and must return the entire `buildPhase` body
# (including its own `runHook` calls) for that backend -- for
# `recursive-nix` it leaves the produced `.drv` at `$out` itself; for
# `builder-rpc-v0` it calls `nix store submit-output` instead (see the
# `out = "/nonexistent"` override below for why). `extraDrvArgs` is merged
# into the outer derivation's own attrs (`nativeBuildInputs`,
# `passAsFile`, etc. -- whatever the producer's script needs available).
#
# This is a plain duck-typed contract, not a real abstraction with its own
# constructor -- every `dyndrv.builders.*` function AND `dyndrv.graph.compile`
# independently satisfy it and are freely interchangeable as `producer`
# values (`graph.compile`'s result is just as valid a `producer` as
# `builders.viaDerivationAdd`'s, despite living under a different
# top-level name -- it compiles a whole graph into the SAME `{ script,
# extraDrvArgs }` shape a single-node producer returns). Anyone writing a
# custom `producer` from scratch needs to satisfy only this shape, nothing
# more.
#
# IMPORTANT, confirmed by direct reproduction (matches gradle-drvs' own
# "assembler must match outer name" workaround): the INNER derivation your
# `producer` constructs must be named exactly `"${pname}-${version}"` (or
# `name`, if you passed that instead) -- the same name `mkDynamicDerivation`
# computes for the outer wrapper, minus the `.drv` suffix. Nix checks this
# at realization time and fails with "derivation has incorrect output
# '&lt;path&gt;', should be '&lt;expected&gt;'" if the inner derivation's name
# doesn't match, since a CA/text-hashed derivation's output path is a
# function of its declared name. `graph.compile` takes its own `name`
# argument for exactly this reason -- there is no eval-time check tying
# the two together, so a caller of `graph.compile` must pass the SAME
# string there as `mkDynamicDerivation`'s `pname`-`version` (or `name`)
# computes, by hand; getting it wrong produces the same realization-time
# error, one level removed from anything the caller wrote directly.

let
  inherit (pkgs) stdenvNoCC runCommand;
in

lib.extendMkDerivation {
  constructDrv = stdenvNoCC.mkDerivation;

  excludeDrvArgNames = [
    "producer"
    "backend"
    "onUnsupported"
  ];

  extendDrvArgs =
    finalAttrs:
    args@{
      producer,
      # `backend`: "builder-rpc-v0" | "recursive-nix" | "auto". Defaults
      # to `"builder-rpc-v0"` -- not detected, just assumed, since "best
      # available" isn't eval-time computable (support is negotiated
      # during the daemon connection handshake, not exposed through any
      # `builtins` -- see `capabilities.nix`'s header). This is a policy
      # choice: `builder-rpc-v0` is on real NixOS/nix `master` (no patched
      # fork needed, see `try-it-out/patched-nix.nix`) and is what every
      # backend-flexible producer here is built around.
      #
      # If your Nix/producer doesn't support it (e.g.
      # `builders.viaNixInstantiate`, or a stock Nix predating
      # `builder-rpc-v0`), pass `backend = "auto"` for the conservative,
      # eval-time-detected choice instead (today: always `"recursive-nix"`),
      # or `backend = "recursive-nix"` to force it directly. Check
      # `passthru.backend` on the result to confirm what was selected.
      backend ? "builder-rpc-v0",
      onUnsupported ? "ifd",
      ...
    }:

    assert
      args ? name && (args ? pname || args ? version) -> throw "name cannot be set with pname or version";
    assert
      (args ? pname) != (args ? version)
      -> throw "either both or none of pname and version have to be set";

    let
      name =
        if args ? name then
          args.name
        else if args ? pname && args ? version then
          "${args.pname}-${args.version}"
        else
          "dyndrv-derivation";

      caps = self.capabilities.detect { };
      selectedBackend = if backend == "auto" then self.capabilities.selectBackend caps else backend;

      backendUnsupported = selectedBackend == null || !caps.dynamicDerivations;
    in

    if backendUnsupported && onUnsupported == "ifd" && !(producer ? ifd) then
      throw ''
        dyndrv.mkDynamicDerivation: no dynamic-derivation backend is
        available (dynamic-derivations experimental feature is off, or
        neither recursive-nix nor builder-rpc-v0 is usable), and
        `onUnsupported = "ifd"` requires `producer.ifd` to be set. Either
        enable the experimental feature, supply `producer.ifd`, or pass
        `onUnsupported = "fail"` for a plain error instead.
      ''
    else if backendUnsupported && onUnsupported == "fail" then
      throw ''
        dyndrv.mkDynamicDerivation: no dynamic-derivation backend is
        available. Run `dyndrv doctor` to see what's missing.
      ''
    else
      {
        name = "${name}.drv";
        __contentAddressed = true;
        outputHashAlgo = "sha256";
        outputHashMode = "text";
        requiredSystemFeatures = [
          (if selectedBackend == "builder-rpc-v0" then "builder-rpc-v0" else "recursive-nix")
        ];

        dontUnpack = true;
        # `producer.script` is the entire buildPhase body (including its own
        # runHook calls) -- for the recursive-nix backend it's expected to
        # leave the produced `.drv` at `$out` itself; for builder-rpc-v0 it
        # calls `nix store submit-output` instead, which is why `$out` is
        # deliberately left unset by the sandbox (see the `out` override
        # below).
        buildPhase = producer.script selectedBackend;
        installPhase = "true";

        # `builder-rpc-v0` leaves `$out` entirely unset (the output is
        # registered via `nix store submit-output` instead of a
        # conventional file at `$out`), but stdenv's own machinery
        # (`_assignFirst`) assumes some output variable is always set and
        # fails loudly otherwise ("could not find a non-empty variable
        # whose name to assign to output..."). nixgg hit this exact error
        # and worked around it the same way: give stdenv a placeholder path
        # so its own bookkeeping is satisfied, while the real output is
        # whatever `producer.script` submits. Any accidental write to this
        # path (as opposed to a `submit-output` call) fails loudly rather
        # than silently succeeding.
      }
      // lib.optionalAttrs (selectedBackend == "builder-rpc-v0") {
        out = "/nonexistent";
      }
      // {
        passthru = {
          outName = name;
          backend = selectedBackend;
          outPos = builtins.unsafeGetAttrPos (if args ? version then "version" else "name") args;
        };
      }
      // (producer.extraDrvArgs or { });

  transformDrv =
    drv:
    let
      # Two levels of `outputOf` are needed here, not one: `drv` itself is
      # the *producer* -- its own output (level 1) IS the inner `.drv` file
      # (this is what makes it a dynamic derivation at all). Resolving the
      # inner `.drv`'s own output requires a second `outputOf` (level 2).
      # Confirmed against nix-src's own `eval-outputOf.sh` oracle test
      # (`testDynamicHello`), which chains exactly two `outputOf` calls for
      # the equivalent case.
      innerDrvOutput = self.mkOutputOf drv "out";
      finalOutput = self.mkOutputOf innerDrvOutput "out";

      args = {
        passthru = {
          # `dynamicDrv` (not `drv`) to match the plan's own UX contract:
          # every `dyndrv`-produced derivation exposes the SAME escape-
          # hatch names (`passthru.dynamicDrv`/`passthru.outputOf`/
          # `passthru.backend`) regardless of which entry point produced
          # it, so "I need the raw thing underneath" is always the same
          # two attribute names rather than a per-function bespoke API.
          dynamicDrv = drv;
          outputOf = finalOutput;
          backend = drv.backend;
        };
        pos = drv.outPos;
      }
      // lib.optionalAttrs (drv ? pname && drv ? version) {
        inherit (drv) pname version;
      }
      // lib.optionalAttrs (drv ? meta) {
        inherit (drv) meta;
      };
    in
    runCommand drv.outName args ''
      ln -s ${finalOutput} "$out"
    '';
}

