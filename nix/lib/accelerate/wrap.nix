{ pkgs, lib, self }:

# The lowest-friction entry point in the whole library, per the plan's own
# adoption story: point this at an existing, ordinary `stdenv.mkDerivation`-
# built package and get per-translation-unit caching with ONE LINE CHANGED,
# no dynamic-derivation vocabulary required to try it.
#
#   before: pkgs.callPackage ./package.nix { }
#   after:  dyndrv.accelerate.wrap (pkgs.callPackage ./package.nix { })
#
# Sugar for `drv.override { stdenv = dyndrv.accelerate.mkAcceleratedStdenv
# { stdenv = drv.stdenv; }; }` -- matches the plan's own documented
# signature exactly (`derivation -> derivation`, no knobs). Anyone who
# wants the `granularity` knob (or any future knob `mkAcceleratedStdenv`
# grows) uses that directly instead -- it's the documented, composable
# escape hatch this function is sugar OVER, not a second copy of its
# argument surface to keep in sync.
#
# Requires `drv.stdenv` and `drv.override` to both exist. `.stdenv` comes
# from any `stdenv.mkDerivation` call; `.override` does NOT (confirmed
# directly: a bare `stdenv.mkDerivation { ... }` call has `.stdenv` but no
# `.override` at all) -- it only comes from `pkgs.callPackage`/
# `lib.makeOverridable` wrapping the package FUNCTION before it's called.
# This is exactly how every real nixpkgs package (`pkgs.foo`) already
# works, so `dyndrv.accelerate.wrap pkgs.foo` just works for the actual
# "point this at an existing package" adoption case -- the requirement
# only bites someone constructing a raw `stdenv.mkDerivation` value by
# hand outside of `callPackage`, who gets a clear error below instead of
# a confusing "attribute 'stdenv' missing" from deep inside `.override`'s
# own machinery.
drv:

if !(drv ? stdenv) then
  throw ''
    dyndrv.accelerate.wrap: ${drv.name or "this derivation"} has no
    `.stdenv` attribute, so there's nothing to accelerate -- `wrap` only
    works on ordinary `stdenv.mkDerivation`-built packages. If you're
    building your own derivation from scratch, use
    `dyndrv.accelerate.mkAcceleratedStdenv` directly instead.
  ''
else if !(drv ? override) then
  throw ''
    dyndrv.accelerate.wrap: ${drv.name or "this derivation"} has no
    `.override` -- it was built directly via `stdenv.mkDerivation` rather
    than through `callPackage` (which is what actually attaches
    `.override`, via `lib.makeOverridable`), so `wrap` can't re-invoke its
    builder with a different `stdenv`. Wrap your package in
    `lib.makeOverridable` yourself (the same thing `callPackage` would do
    for you), or use `dyndrv.accelerate.mkAcceleratedStdenv` directly and
    pass the result to whatever constructs the derivation.
  ''
else
  drv.override {
    stdenv = self.accelerate.mkAcceleratedStdenv { inherit (drv) stdenv; };
  }
