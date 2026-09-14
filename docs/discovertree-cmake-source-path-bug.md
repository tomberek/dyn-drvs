# FIXED: `firstSourceIdx` misidentified `-MT`/`-MF`'s own values as the source file

## Status: fixed

The original diagnosis in this file (below, kept as history) was WRONG.
This was never a `discoverTree` staging/out-of-tree-cmake-path problem —
confirmed by direct reproduction against real nixpkgs `xxhash` that the
actual bug is one level earlier, in `toNode`/`cc_to_node`'s own argv-shape
classification.

## The real root cause

`firstSourceIdx` (`toNode`, `mkAcceleratedStdenv.nix`) and its Rust port
`first_source_idx` (`cc.rs`) scan argv for "the first non-flag token that
isn't `-o`'s own value," treating that as `sourcePath`. But cmake's own
generated compile lines always look like:

```
cc ... -MD -MT $out -MF <relative-depfile-path> -o $out -c /build/source/xxhash.c
```

`-MT`'s own value (here, `$out` — a relative Make-target string, not a
source file) and `-MF`'s own value (a relative depfile path) both come
BEFORE `-c`'s own real, absolute source argument, and neither was ever
excluded from the "first non-flag token" scan — only `-o`'s value was.
So `firstSourceIdx` latched onto `-MT`'s own value as `sourcePath`,
completely missing the real source file at the argv's own end.

This silently broke the ALREADY-EXISTING "pass through a compile whose
source is still an absolute path" check (`hasCompileFlag && sourcePath
!= null && hasPrefix "/" sourcePath`) — that check depends entirely on
`sourcePath` being the REAL source argument. Since `sourcePath` was
actually `-MT`'s own relative value, the check never fired, and a real
cmake compile with a genuinely absolute source path got wrongly
deferred into a per-TU derivation instead of passed through — which
then failed for real, since a deferred derivation's own staged tree
(built from `discoverTree`'s relative-path scan) never contains an
absolute host path at all:

```
cc1: fatal error: /build/source/xxhash.c: No such file or directory
```

## The fix

`firstSourceIdx`/`positionalIdxs` (and their Rust equivalents) now
exclude the VALUE of every value-taking flag that can appear ahead of
the real source/output — `-o`, `-MT`, `-MF`, `-MQ` — not just `-o`'s.
A new `valueSlotIdxs`/`isValueSlotValue` helper computes this once and
is shared by both scans.

## Regression fixture

`try-it-out/examples/22-accelerate-mt-mf-absolute-source.nix`
reproduces the exact `-MD -MT ... -MF ... -o ... -c <absolute path>`
shape with a real absolute source path — confirmed failing before this
fix (the compile step wrongly deferred and failed), passing after (the
compile step correctly passes through and runs synchronously), on both
the bash and compiled-Rust paths.

## Where this was found

Direct reproduction against real, unmodified nixpkgs `xxhash` (via
`~/overlay`'s downstream package-porting survey), building it through
`accelerate.mkAcceleratedStdenv` and inspecting the registered per-TU
`.drv`'s own rendered command line via `nix derivation show`
equivalent (reading the raw ATerm).

---

## Original (incomplete) diagnosis, kept as history

Found while surveying more real nixpkgs packages against
`accelerate.mkAcceleratedStdenv` in a downstream showcase repo. nixpkgs'
`xxhash` builds via cmake, with the cmake project rooted one directory
below the actual sources (`cmakeDir = "build/cmake"`, sources live in the
parent directory). Every real per-TU compile failed identically:

```console
$ pkgs.xxhash.override { stdenv = dyndrv.accelerate.mkAcceleratedStdenv { stdenv = pkgs.stdenv; inherit nixPackage; }; }
...
cc1: fatal error: /build/source/xxhash.c: No such file or directory
compilation terminated.
```

The original theory was that `discoverTree`'s own per-TU sandbox staging
didn't resolve cmake's out-of-tree relative source paths correctly. That
theory was never confirmed and turned out to be wrong — the real bug
(above) is upstream of `discoverTree` entirely: the compile should have
been passed through, never staged/deferred at all.

re2 (google/re2, cmake+ninja) hit the identical underlying bug, shaped
slightly differently (ninja-generated compile lines also emit `-MT`/
`-MF` ahead of the real source).
