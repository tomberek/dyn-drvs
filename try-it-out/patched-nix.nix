{ pkgs }:

# Packages a locally-built NixOS/nix#15793 checkout (the `builder-rpc-v0` /
# `nix store submit-output` patch) as a normal Nix derivation, so it can be
# referenced as an ordinary store path -- required by
# `dyndrv.builders.viaDerivationAdd`'s `nixPackage` argument (see that
# file's comment for why: a raw copy of the meson build tree's binary has
# unregistered runtime dependencies and a `$ORIGIN`-relative rpath that
# both break once referenced by a bare string; only a real derivation's
# closure survives being passed into a sandboxed build).
#
# `nixSrc`: path to a built NixOS/nix#15793 checkout, i.e. the *source*
#           checkout directory (containing `src/nix/nix`, `src/libutil/`,
#           etc. after a meson build) -- NOT a fetched tarball, since this
#           patch isn't merged/released yet. Point this at a local clone
#           built with `meson setup build --buildtype release && ninja -C
#           build` (or a `meson.build`-driven Nix build), e.g.
#           `nixSrc = /path/to/nix-checkout/build-release`.
#
# Verified end-to-end against a local NixOS/nix#15793 build: this recipe
# (copy the shared libs `autoPatchelfHook` needs alongside the `nix`
# binary under `libexec/`, wrap with `makeWrapper` so `$PATH`-based
# invocation works) is what actually builds and runs correctly inside a
# `builder-rpc-v0` sandbox -- a hand-copied binary without
# `autoPatchelfHook` silently fails ("cannot open shared object file")
# deep inside the sandbox instead of at build time.
#
# One additional wrinkle `autoPatchelfHook` alone does NOT fix: some of
# the libnix*.so files built by this checkout have an ABSOLUTE STORE PATH
# baked into their ELF `NEEDED` entries (e.g. `libnixstore.so` needing
# literally `/nix/store/<hash>-sqlite-3.51.2/lib/libsqlite3.so`, rather
# than just `libsqlite3.so`) -- an artifact of whichever nixpkgs snapshot
# the checkout was originally configured against. `autoPatchelfHook` only
# fixes rpaths, not absolute `NEEDED` paths, so the dynamic linker tries
# that literal (possibly nonexistent, or simply not the one actually
# copied into this derivation's closure) path and fails with "cannot open
# shared object file" -- confirmed directly: `readelf -d
# libnixstore.so | grep NEEDED` shows the bare `.so` name for most
# libraries but a full `/nix/store/...` path for at least `libsqlite3.so`.
# `patchelf --replace-needed` normalizes any such absolute entries to a
# bare SONAME so ordinary rpath search takes over, same as every other
# dependency.

{
  nixSrc,
  version ? "unstable",
}:

pkgs.stdenv.mkDerivation {
  pname = "patched-nix-dyndrv";
  inherit version;

  dontUnpack = true;
  nativeBuildInputs = [
    pkgs.autoPatchelfHook
    pkgs.makeWrapper
    pkgs.patchelf
  ];

  # This list must cover every shared-library dependency `nix-real` and its
  # libnix* siblings pull in beyond glibc/gcc's own runtime -- confirmed by
  # trial-and-error against `autoPatchelfHook`'s own "could not satisfy
  # dependency" errors. If a future Nix revision adds/removes a dependency,
  # `autoPatchelfHook` will name exactly what's missing; add it here.
  buildInputs = with pkgs; [
    boost
    curl
    libarchive
    libgit2
    libseccomp
    libsodium
    lowdown
    editline
    nlohmann_json
    sqlite
    openssl
    stdenv.cc.cc.lib
    boehmgc
    mimalloc
    libblake3
    libcpuid
  ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/libexec $out/bin
    for lib in libutil libstore libexpr libfetchers libflake libmain libcmd; do
      cp -r ${nixSrc}/src/$lib $out/libexec/
    done
    cp ${nixSrc}/src/nix/nix $out/libexec/nix-real
    chmod -R u+w $out

    # Normalize any absolute-store-path NEEDED entries to bare SONAMEs so
    # autoPatchelfHook's rpath fixups (applied in fixupPhase, after this)
    # actually take effect instead of being bypassed by a literal path.
    find "$out/libexec" -name '*.so*' -type f | while read -r sofile; do
      needed=$(patchelf --print-needed "$sofile" 2>/dev/null || true)
      for entry in $needed; do
        if [[ "$entry" == /nix/store/* ]]; then
          patchelf --replace-needed "$entry" "$(basename "$entry")" "$sofile"
        fi
      done
    done

    makeWrapper $out/libexec/nix-real $out/bin/nix
    ln -s nix $out/bin/nix-instantiate
    runHook postInstall
  '';

  meta = {
    description = "Nix build with the builder-rpc-v0 / nix store submit-output patch (NixOS/nix#15793), packaged for use as dyndrv's viaDerivationAdd nixPackage";
    mainProgram = "nix";
  };
}
