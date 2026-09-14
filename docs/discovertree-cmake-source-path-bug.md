# Bug: `discoverTree` doesn't resolve cmake out-of-tree relative source paths

## Summary

Found while surveying more real nixpkgs packages against
`accelerate.mkAcceleratedStdenv` in a downstream showcase repo. nixpkgs'
`xxhash` builds via cmake, with the cmake project rooted one directory
below the actual sources (`cmakeDir = "build/cmake"`, sources live in the
parent directory). Every real per-TU compile fails identically:

```console
$ pkgs.xxhash.override { stdenv = dyndrv.accelerate.mkAcceleratedStdenv { stdenv = pkgs.stdenv; inherit nixPackage; }; }
...
cc1: fatal error: /build/source/xxhash.c: No such file or directory
compilation terminated.
```

Same failure for every other TU in the package (`cli/xsum_arch.c`,
`xsum_bench.c`, `xsum_os_specific.c`, `xsum_output.c`,
`xsum_sanity_check.c`, `cli/xxhsum.c`).

## Root cause (partial -- not yet fully traced)

Unlike the link-step bug (`discovertree-link-step-bug.md`), this fails at
the *compile* step, not a link. `CMakeDetermineCompilerABI` and the
configure step succeed fine, so cmake itself can see the sources. The
failure is specifically in how `discoverTree`'s per-TU sandbox stages
files: the path cmake bakes into the actual compile command
(`/build/source/xxhash.c`) is an absolute in-sandbox path pointing at
where the *outer* (unaccelerated) build would have the full source tree
unpacked, but the per-TU sandbox `discoverTree` stages only contains
whatever the `-M -MG` scan found relative to the compiler's invocation
directory -- which for a cmake build one level below the source root
apparently doesn't line up with the absolute path cmake actually invokes
`cc` with.

This is distinct from the link-step bug: it affects real compiles (not
links), and the missing file is the primary source itself (not a header
or object file).

## Confirmed pattern: also seen on re2 (cmake+ninja), but shaped differently

re2 (google/re2, cmake+ninja) hits a related-looking but distinct
failure: 20 of ~51 compile-unit derivations fail with

```
cc1plus: fatal error: re2/prefilter.cc: No such file or directory
```

(also `re2/bitstate.cc`, `re2/compile.cc`, `util/strutil.cc`, most of
`re2/testing/*_test.cc`) -- again a *compile*-step failure on the primary
source file, not link, not header. re2's cmake project is NOT out-of-tree
the way xxHash's is (no separate `build/cmake` subdir), so "out-of-tree
cmake dir" isn't the full story -- something about cmake+ninja-generated
compile invocations (as opposed to cmake+make, which zstd/pcre2/freetype
use) may be involved instead, or in addition. Not yet root-caused to the
same level of confidence as the link-step bug -- needs a `nix derivation
show` + `-M -MG` manual repro pass the way the link-step bug got before
being fully trusted.

## Where this was found

Downstream showcase repo, ultracode survey pass looking for more
dyn-drvs-compatible nixpkgs packages beyond freetype/giflib/tinycbor.
Both xxHash and re2 used `nixPackage` explicitly pinned to
`try-it-out/patched-nix.nix` (avoiding the version-mismatch pitfall
documented in `discovertree-link-step-bug.md`), so this is not that
pitfall recurring.
