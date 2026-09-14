# NOT A BUG: a package that self-execs its own just-linked binary mid-`buildPhase` is structurally unsupported

## Status: root-caused, NOT fixable as a bug -- this is an inherent architectural limitation, documented as a known limitation instead (see README.md's "Known limitations" section)

## Summary (original finding)

Found while surveying more real nixpkgs packages against
`accelerate.mkAcceleratedStdenv`. libb64 (plain Makefile, `ar`-based
static lib, then two example binaries + a CLI linked directly via
`gcc`/`g++`) compiles and links completely cleanly -- neither the
link-step bug nor the cmake source-path bug is in play here, since
libb64 uses neither cmake nor a `.so`-shaped link.

It fails later, at:

```console
$ pkgs.libb64.override { stdenv = dyndrv.accelerate.mkAcceleratedStdenv { stdenv = pkgs.stdenv; inherit nixPackage; }; }
...
gcc -g -Werror -pedantic -I../include c-example1.c ../src/libb64.a -o c-example1
./c-example1
/nix/store/.../bash: line 1: ./c-example1: Permission denied
make[1]: *** [Makefile:36: test-c-example1] Error 126
```

`c-example1` is the just-linked binary from the immediately preceding
build step; libb64's own `Makefile` runs it directly as its own "test"
target right after linking, in the SAME `buildPhase` invocation.

## Root cause (confirmed by direct reproduction -- NOT a lost exec bit)

This was originally suspected to be a permission-bit-preservation bug
somewhere in the staging/restore pipeline ("discoverTree's link-output
handling doesn't preserve the executable bit"). That diagnosis is
**wrong**. Confirmed by direct reproduction:

Every `cc`/`ar` invocation `mkAcceleratedStdenv`'s shims intercept is
**unconditionally deferred** (`shim.wrapCommand`'s own header comment:
"WHY EVERYTHING DEFERS, UNCONDITIONALLY" -- `builder-rpc-v0` cannot
realize a derivation from inside a running script, so there is no
"materialize now" fallback at all, by design). A deferred invocation
writes a **plain placeholder text file** at the expected output path
(`shim.batchStub`'s `writeStubFn`):

```
#!dyndrv-batch-pending
<path to a JSON record file>
```

This stub is only ever resolved into a real symlink (pointing at the
real, resolved store path) by `shim.collectStubs`'s whole-build-tree
resolution pass -- which runs **once, at the very end of `buildPhase`**
(the synthesized `collectPhase`), never incrementally as each
individual stub is written.

libb64's own `Makefile` runs `./c-example1` as part of the SAME `make`
invocation that just linked it, **before `buildPhase` (and therefore
`collectPhase`) has finished** -- so at that exact moment, `c-example1`
on disk is still the plain-text stub above, not a resolved binary.
Confirmed byte-for-byte via direct reproduction:

```console
$ printf '%s\n%s\n' '#!dyndrv-batch-pending' '/build/somefile' > stub
$ ./stub
bash: ./stub: Permission denied    # exit 126 -- EXACTLY libb64's own failure
$ chmod +x stub && ./stub
bash: ./stub: dyndrv-batch-pending: bad interpreter: No such file or directory   # still exit 126
```

Setting the execute bit on the stub does **not** fix this -- the
kernel's own `#!` interpreter lookup then fails outright ("bad
interpreter"), since `dyndrv-batch-pending` isn't a real, resolvable
program. There is no permission-bit fix available here: the file
genuinely isn't executable code yet, by design, at the point this
package's own Makefile tries to run it.

## Why this is not fixable as a bug

`wrapCommand.nix`'s own header comment already explains why no
"materialize inline" fallback exists: `builder-rpc-v0` ("RecursiveSubmitted"
connections) categorically cannot realize a derivation from inside a
running script -- confirmed by reading Nix's own `daemon.cc:performOp`
connection-mode allowlist, which permits only `AddToStore*`/
`SubmitOutput`/`AddTempRoot`/`IsValidPath`; `BuildPaths`/`QueryMissing`
are absent and rejected outright. An earlier version of this codebase
supported a `recursive-nix`-backed "materialize" mode that could
realize inline, but it was removed entirely once `mkAcceleratedStdenv`
moved fully onto `builder-rpc-v0`.

This means: **any package whose own build script executes a just-
linked (or just-compiled) artifact directly, within the SAME
`buildPhase` invocation that produced it, before `installPhase` ever
runs, is structurally incompatible with this accelerator's whole
architecture** -- not just this one instance. Deferring is the entire
point of the mechanism (that's what makes per-TU/per-archive caching
possible at all); a package that needs its own intermediate artifacts
to be immediately real defeats that by construction.

## Known affected packages

- **libb64**: `examples`' own `test-c-example1`/`test-c-example2` Make
  targets run the just-linked example binaries directly.
- Any other package with an analogous "build then immediately self-
  test/self-exec" `buildPhase` step (as opposed to a separate
  `checkPhase`/`installCheckPhase`, which runs AFTER `buildPhase` --
  and therefore after `collectPhase` -- and is unaffected).

## What DOES still work

A package whose own test/self-exec step is a genuinely separate PHASE
(nixpkgs' own `checkPhase`, gated by `doCheck`) rather than a
sub-target of `buildPhase` itself is unaffected -- `checkPhase` runs
strictly after `buildPhase` (and therefore after `collectPhase`), by
which point every stub this package produced has already been resolved
into a real symlink. This is exactly the SAME distinction that already
makes `installPhase`/`fixupPhase` (phase 2, an ordinary derivation with
a real, resolved tree) work correctly for every other proven package.

## Where this was found

Downstream showcase repo, ultracode survey pass looking for more
dyn-drvs-compatible nixpkgs packages beyond freetype/giflib/tinycbor.
Root-caused (superseding the original, incorrect "lost exec bit"
theory above) via direct reproduction against real nixpkgs libb64,
tracing the exact failing shell command back to `shim.batchStub`'s
plain-text stub format and `shim.wrapCommand`'s own "always defer,
never materialize inline" design.
