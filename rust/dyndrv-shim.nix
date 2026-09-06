# Builds `rust/dyndrv-shim` (see that crate's own doc comments, and
# `docs/rust-status.md`, for the full "why vendor nix-builder-rpc-client/
# harmonia instead of a git dependency" rationale) into a real Nix
# package exposing `bin/dyndrv-shim` -- what `shim.wrapCommand`'s
# `toNodeCompiled` param expects.
{
  pkgs ? import <nixpkgs> { },
}:

pkgs.rustPlatform.buildRustPackage {
  pname = "dyndrv-shim";
  version = "0.1.0";
  src = ./dyndrv-shim;
  cargoLock = {
    lockFile = ./dyndrv-shim/Cargo.lock;
    outputHashes = { };
  };

  # The workspace also depends on ../vendor/{harmonia,nix-builder-rpc-client}
  # via relative `path = "../vendor/..."` entries in Cargo.toml -- these
  # are OUTSIDE `src` (which is scoped to just `./dyndrv-shim`), so a
  # plain `src = ./dyndrv-shim` copy loses them. Point `postPatch` at the
  # real sibling paths instead of trying to widen `src` to the whole
  # `rust/` tree (which would also pull in `target/`, `smoke-sandbox-
  # fixture.nix`, etc. -- irrelevant to this build).
  postPatch = ''
    mkdir -p ../vendor
    cp -r ${./vendor/harmonia} ../vendor/harmonia
    cp -r ${./vendor/nix-builder-rpc-client} ../vendor/nix-builder-rpc-client
    chmod -R u+w ../vendor
  '';
}
