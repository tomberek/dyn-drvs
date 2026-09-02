# Resolves a real, buildable NixOS/nix checkout that supports
# `builder-rpc-v0`/`nix store submit-output` -- CONFIRMED (2026-09-02):
# this feature landed on real NixOS/nix `master` via commit `55eea4554`
# ("Implement new builder-rpc-v0 derivation feature", 2025-11-17). It is
# NOT gated behind a separate `builder-rpc-v0` experimental feature flag
# at all -- `nix store submit-output`'s own source
# (`src/nix/store-submit-output.cc`) declares its `experimentalFeature()`
# as `Xp::DynamicDerivations`, the SAME flag `dyndrv` already needs for
# everything else. `builder-rpc-v0` itself is a plain `requiredSystemFeatures`
# string, checked only when a derivation using it is actually scheduled
# (`derivations.cc`), same as any other system feature -- no daemon-level
# opt-in beyond that.
#
# This means: NO manual meson build, NO `autoPatchelfHook`/absolute-
# `NEEDED`-path workarounds are needed anymore -- a PLAIN `nix build
# github:NixOS/nix/<rev>#packages.<system>.nix` (i.e. exactly what this
# file does) produces a fully working, already-packaged Nix derivation.
# Confirmed by direct reproduction: a `dyndrv.mkDynamicDerivation {
# backend = "builder-rpc-v0"; }` call, with THIS package as its
# `viaDerivationAdd`'s `nixPackage`, registered and submitted a real
# output end to end with zero patching.
#
# VERSION MATCHING REQUIREMENT, confirmed by direct reproduction: the
# `nixPackage` used INSIDE the sandbox (by `viaDerivationAdd.nix`'s
# generated script) and the OUTER Nix actually driving the whole build
# must be running compatible worker-protocol versions -- using an OLDER
# ambient Nix (e.g. Determinate Nix 2.34.x) as `nixPackage` against a
# NEWER outer daemon (this package, ~2.36.0pre) fails with "Operation 19
# not allowed inside derivation" (`SetOptions`, rejected by the newer
# daemon's stricter `RecursiveSubmitted`-connection allowlist -- an older
# client tries to negotiate options a newer daemon's restricted mode
# doesn't permit). The fix that's ALWAYS correct: use THIS SAME package
# as the outer driving Nix too (see `run-nix.sh`, which does exactly
# this) -- don't mix an ambient system Nix with this one.
#
# `rev`: the NixOS/nix commit to build. Pinned to a specific commit
#        (not a branch) so this stays reproducible -- update deliberately,
#        not implicitly, when a newer commit is desired.

{
  rev ? "72385de1bef8b8879384b4810e3b0864f4d3c3da",
  system ? builtins.currentSystem,
}:

let
  flake = builtins.getFlake "github:NixOS/nix/${rev}";
in
flake.packages.${system}.nix
