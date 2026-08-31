## try-it-out

Five minutes to your first dynamic derivation.

### 1. Get a Nix that supports `builder-rpc-v0` (dyndrv's default backend)

`builder-rpc-v0` (the mechanism `dyndrv.mkDynamicDerivation` defaults to,
since it avoids `recursive-nix`'s overhead) is unreleased -- tracked at
[NixOS/nix#15793](https://github.com/NixOS/nix/pull/15793). Neither mainline
nor Determinate Nix nor the system nix-daemon support it yet.

```console
$ git clone <your NixOS/nix#15793 checkout> ~/nix-checkout
$ cd ~/nix-checkout && meson setup build-release --buildtype release && ninja -C build-release
$ NIX_SRC=~/nix-checkout/build-release ./run-nix.sh --version
```

`run-nix.sh` builds `patched-nix.nix` with your ambient system Nix, then
re-execs into it against a local non-daemon store (`/tmp/dyndrv-store` by
default) with the right `--extra-experimental-features`/
`--extra-system-features` already set -- no flags to remember.

### 2. Run the examples

```console
$ ./run-nix.sh build -f examples/01-hello-dynamic-drv.nix
$ cat $(readlink -f result | sed 's|^/nix|/tmp/dyndrv-store/nix|')
```

`01-hello-dynamic-drv.nix` builds a minimal dynamic derivation via the
`builder-rpc-v0` backend end to end: `dyndrv.mkDynamicDerivation` wraps a
`dyndrv.builders.viaDerivationAdd` producer, whose script registers one
inner derivation with `nix derivation add` and hands it to the outer
derivation via `nix store submit-output`.

`02-fallback-ifd.nix` shows the same intent expressed through
`capabilities.withFallback` -- a `dynamic` alternative alongside a plain
`ifd` alternative, so it *also* works on stock, unpatched Nix (try it with
plain `nix build`, no `run-nix.sh`, no patched Nix required):

```console
$ nix build --extra-experimental-features "nix-command" -f examples/02-fallback-ifd.nix
```

This is the pairing the whole library is designed around: `builder-rpc-v0`
is the better default when it's available, but nothing here forces an
all-or-nothing bet on an unreleased Nix feature to get started.

### 3. Not sure what your Nix supports?

`dyndrv doctor` (v0.2+) will report exactly which of
dynamic-derivations/ca-derivations/recursive-nix/builder-rpc-v0/
submit-output the current Nix actually supports. Until then,
`nix-config.sh` documents the exact feature flags dyndrv needs.
