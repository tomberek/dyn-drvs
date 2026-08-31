{ pkgs, lib, self }:

# Capability detection for the running Nix evaluator, and a fallback combinator
# for callers who want "use dynamic derivations if available, else IFD."
#
# `builtins ? outputOf` is a genuine, pure-eval-safe signal: Nix only exposes
# that primop when `dynamic-derivations` is enabled for *this* evaluation, so
# it directly reflects the caller's `--extra-experimental-features`/nix.conf,
# no impure escape hatch needed.
#
# Whether `recursive-nix`/`builder-rpc-v0` system features are actually
# available on some builder is NOT eval-pure-detectable (it's a property of
# the build farm, checked only when Nix tries to schedule a build). v0.1
# approximates this as "assume available if dynamic-derivations is enabled,
# since projects that turn one on generally turn both on together." A real
# probe (attempt a trivial build, see if it schedules) is deferred to the
# `dyndrv doctor` CLI (v0.2+), which can afford to actually run a build.

let
  dynamicDerivations = builtins ? outputOf;

  # Not yet real detection (see note above) -- placeholders until `dyndrv
  # doctor` can do a live probe. Exposed distinctly so `detect`'s result
  # shape doesn't change when better detection lands.
  recursiveNix = dynamicDerivations;
  builderRpcV0 = false; # requires a patched Nix; never assume it's present
  submitOutput = false; # ditto

  detect =
    { }:
    {
      inherit
        dynamicDerivations
        recursiveNix
        builderRpcV0
        submitOutput
        ;
    };

  # Pick the best available backend: "builder-rpc-v0" if present, else
  # "recursive-nix" if present, else null (caller must use `onUnsupported`).
  selectBackend =
    caps:
    if caps.builderRpcV0 then
      "builder-rpc-v0"
    else if caps.recursiveNix then
      "recursive-nix"
    else
      null;

  # `alternatives` is a lazy attrset `{ dynamic, ifd }`; only the selected
  # branch is ever forced, so the unused alternative never needs to type-check
  # against a backend that isn't there.
  withFallback =
    alternatives:
    let
      caps = detect { };
    in
    if caps.dynamicDerivations && selectBackend caps != null then
      alternatives.dynamic
    else if alternatives ? ifd then
      alternatives.ifd
    else
      throw ''
        dyndrv.capabilities.withFallback: dynamic derivations are not
        available (dynamic-derivations experimental feature is off, or no
        backend is usable), and no `ifd` alternative was supplied.
      '';
in
{
  inherit detect selectBackend withFallback;
}
