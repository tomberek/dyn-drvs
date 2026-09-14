# Bug: secondary compiler side-outputs (`-MD`/`-MF` depfiles) don't round-trip back to the caller's tree

## Summary

Automake-generated Makefiles compile with the classic depcomp idiom:

```
$(CXX) ... -MT $@ -MD -MP -MF .deps/$*.Tpo -c -o $@ $<
mv -f .deps/$*.Tpo .deps/$*.Po
```

The compile's declared `-o $@` output (the real `.o`) correctly resolves
back to a usable file via `shim.collectStubs`/`toNode`. But `-MF
.deps/$*.Tpo` is a SECOND file the same invocation writes as a
byproduct, and the immediately-following `mv` (same Makefile recipe
line, run by the *outer*, non-accelerated `make` process) can't find it.

## Reproduction

```console
$ pkgs.gperf.override { stdenv = dyndrv.accelerate.mkAcceleratedStdenv { stdenv = pkgs.stdenv; inherit nixPackage; }; }
```

Real per-TU compiles succeed (confirmed: `g++ ... -c -o hash.o hash.cc`
and 20+ others all compile with no error), then fails at the very next
Makefile line for every single one of them:

```
g++ -DHAVE_CONFIG_H -I. -g -O2 -MT hash.o -MD -MP -MF .deps/hash.Tpo -c -o hash.o hash.cc
mv -f .deps/hash.Tpo .deps/hash.Po
mv: cannot stat '.deps/hash.Tpo': No such file or directory
make[2]: *** [Makefile:2266: hash.o] Error 1
```

Deterministic — reproduced independently a second time, identical
failure, all `.deps/*.Tpo` `mv` targets missing across both `lib/` and
`src/`.

## Root cause

`mkAcceleratedStdenv.nix`'s `toNode` (and `collectStubs`) track exactly
ONE resolved output per compile stub — the file named by `-o`/`-c`'s
positional argv. `-MF <path>` names an independent second output the
same compiler invocation writes, which isn't part of that tracked
output at all. `wrapCommand.nix` already has commentary acknowledging a
related issue for NixOS/nix's own build (`library-versions.cc.o.d`,
around line 747-762) — that existing fix pre-creates the *directory* a
depfile will land in inside the per-TU sandbox, but doesn't carry the
depfile's *contents* back out into the shared tree the top-level `make`
process reads from for its own next command (`mv .Tpo .Po` here). The
per-TU sandbox writes `.deps/hash.Tpo` inside its own isolated build;
that file never survives past the sandbox boundary.

## Why this didn't surface before

freetype/giflib/tinycbor/zstd's build systems either don't use automake's
classic depcomp idiom at all (cmake, qmake, plain Makefiles) or don't hit
it in a way this survey exercised. gperf's `Makefile.in` (autotools,
`automake`-generated) is the first proven-tested package using the
`-MD -MP -MF .deps/$*.Tpo` + `mv` pattern — extremely common across
autotools-based C/C++ projects, so this is likely a high-impact,
frequently-hit gap, not a rare edge case.

## Suggested fix

`toNode`'s argv-scan needs to recognize `-MF <path>` (and `-MMD`/`-MD`'s
implicit default depfile path, when `-MF` isn't given at all) as a
SECOND tracked output of the same stub, staged back into the caller's
tree alongside the primary `-o` output — not just pre-created as an
empty directory inside the sandbox.

## Where this was found

Downstream showcase repo, ultracode survey pass looking for more
dyn-drvs-compatible nixpkgs packages beyond freetype/giflib/tinycbor.
`nixPackage` was pinned explicitly (not the ambient-Nix version-mismatch
pitfall documented in `discovertree-link-step-bug.md`). Independently
reproduced a second time before writing this up.
