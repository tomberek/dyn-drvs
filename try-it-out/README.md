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
since it avoids `recursive-nix`'s overhead) is on real NixOS/nix `master`
(commit `55eea4554`, "Implement new builder-rpc-v0 derivation feature") --
not in a stable release yet, so neither mainline, Determinate Nix, nor the
system nix-daemon support it out of the box. It needs NO patched fork and
NO source patches, though -- just a Nix build recent enough to include
that commit.

```console
$ ./run-nix.sh --version
```

`run-nix.sh` fetches and builds a pinned NixOS/nix commit
(`patched-nix.nix` -- see its own header comment for the full finding),
then re-execs into it against a local non-daemon store (`/tmp/dyndrv-store`
by default) with the right `--extra-experimental-features`/
`--extra-system-features` already set -- no flags to remember, no local
checkout or build step required. Override `NIX_REV` to try a different
commit; override `DYNDRV_STORE` to use a different local store root.

### 2. Run the examples

```console
$ ./run-nix.sh build --impure --print-out-paths -f examples/01-hello-dynamic-drv.nix
```

`01-hello-dynamic-drv.nix` builds a minimal dynamic derivation via the
`builder-rpc-v0` backend end to end: `dyndrv.mkDynamicDerivation` wraps a
`dyndrv.builders.viaDerivationAdd` producer, whose script registers one
inner derivation with `nix derivation add` and hands it to the outer
derivation via `nix store submit-output`.

`02-fallback-ifd.nix` shows the same intent expressed through
`capabilities.withFallback` -- a `dynamic` alternative alongside a plain
`ifd` alternative, so it *also* works on stock Nix (try it with plain
`nix build`, no `run-nix.sh`, no special Nix build required):

```console
$ nix build --extra-experimental-features "nix-command" -f examples/02-fallback-ifd.nix
```

This is the pairing the whole library is designed around: `builder-rpc-v0`
is the better default when it's available, but nothing here forces an
all-or-nothing bet on a not-yet-released Nix feature to get started.

`03-graph-of-two.nix`/`03-graph-of-three.nix` and `04-wrap-command.nix`
cover `dyndrv.graph.compile` (genuinely dependent multi-node graphs -- two
nodes, and a three-node diamond where the final node depends on two
upstream nodes at once) and `dyndrv.shim.wrapCommand` (the
$PATH-command-interception primitive `mkAcceleratedStdenv` is built from)
respectively.

### 3. Not sure what your Nix supports?

`nix-config.sh` documents the exact feature flags dyndrv needs. A
dedicated `dyndrv doctor` diagnostic command is tracked as future work.
