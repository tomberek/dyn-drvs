# Builds `rust/dyndrv-shim` (see that crate's own doc comments, and
# `docs/rust-status.md`, for the full harmonia/nix-builder-rpc-client
# dependency story) into a real Nix package exposing `bin/dyndrv-shim`
# -- what `shim.wrapCommand`'s `toNodeCompiled` param expects.
{
  pkgs ? import <nixpkgs> { },
}:

pkgs.rustPlatform.buildRustPackage {
  pname = "dyndrv-shim";
  version = "0.1.0";
  src = ./dyndrv-shim;
  cargoLock = {
    lockFile = ./dyndrv-shim/Cargo.lock;
    # `harmonia-*` and `nix-builder-rpc-client` are real `git`
    # dependencies now (see `dyndrv-shim/Cargo.toml`'s own header
    # comment for the full "why not vendored" story) -- `buildRustPackage`
    # needs an explicit fixed-output-derivation hash for each distinct
    # git commit `Cargo.lock` references, keyed by "<name>-<version>"
    # (any one crate from that commit; nixpkgs' own `importCargoLock`
    # maps it to the commit SHA internally, so every OTHER crate from
    # the SAME repo+rev is covered by the one entry). Two distinct
    # commits here: harmonia's own pinned rev (shared by all 15
    # harmonia-* crates), and tomberek/nix-ninja's `dyndrv-consumption`
    # branch (nix-builder-rpc-client's own dependency, itself pinned to
    # the SAME harmonia rev -- see that crate's own Cargo.toml).
    outputHashes = {
      "harmonia-protocol-3.1.0" = "sha256-fKJ0H/8sSkolq37PfWLsHX7evNWZE2AQRkgMgjg3bzc=";
      "nix-builder-rpc-client-0.1.0" = "sha256-HqNPfS/pSidgCOEltPIf6f+8I1EmLpFWgySyINdZ++8=";
    };
  };
}
