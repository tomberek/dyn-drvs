## try-it-out

Five minutes to your first dynamic derivation.

### 0. Just want to accelerate an existing package? Start here, no patched Nix needed

```console
$ nix build --extra-experimental-features "nix-command ca-derivations dynamic-derivations recursive-nix" \
    --extra-system-features recursive-nix --store 'local?root=/tmp/dyndrv-store' \
    -f examples/05-accelerate-stdenv.nix
```

`05-accelerate-stdenv.nix` builds a tiny 3-file C program via
`dyndrv.accelerate.mkAcceleratedStdenv` end to end (an ordinary `.override`
on the package's `stdenv` — no separate wrapper function needed): each
`cc -c` invocation becomes its own dynamically-produced, immediately-
realized derivation, and only the link step passes through unaccelerated.
This is the mechanism `try-it-out/benchmarks/small-lib-patch-rebuild.sh`/
`real-package-patch-rebuild.sh` measure — see those (and `../README.md`'s
own Benchmarks section) for real numbers on when this is actually worth
adopting.

The rest of this file covers `dyndrv.mkDynamicDerivation` and the
`builder-rpc-v0` backend — the lower-level primitives most users won't
need directly, but which `dyndrv.graph.compile` and anyone building a
lang2nix-style tool will.

### 1. Get a Nix that supports `builder-rpc-v0` (dyndrv's default backend for `mkDynamicDerivation`)

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

`03-graph-of-two.nix` and `04-wrap-command.nix` cover `dyndrv.graph.compile`
(a genuinely dependent multi-node graph) and `dyndrv.shim.wrapCommand` (the
$PATH-command-interception primitive `mkAcceleratedStdenv` is built from)
respectively.

### 3. Not sure what your Nix supports?

`nix-config.sh` documents the exact feature flags dyndrv needs. A
dedicated `dyndrv doctor` diagnostic command is tracked as future work.
