# Bug: linked executable loses its execute bit under discoverTree

## Summary

Found while surveying more real nixpkgs packages against
`accelerate.mkAcceleratedStdenv`. libb64 (plain Makefile, `ar`-based
static lib, then two example binaries + a CLI linked directly via
`gcc`/`g++`) compiles and links completely cleanly -- neither the
link-step bug (`discovertree-link-step-bug.md`) nor the cmake
source-path bug (`discovertree-cmake-source-path-bug.md`) is in play
here, since libb64 uses neither cmake nor a `.so`-shaped link.

It fails later, at:

```console
$ pkgs.libb64.override { stdenv = dyndrv.accelerate.mkAcceleratedStdenv { stdenv = pkgs.stdenv; inherit nixPackage; }; }
...
make[1]: *** [Makefile:36: test-c-example1] Error 126
```

`c-example1` is the just-linked binary from the immediately preceding
build step; libb64's Makefile runs it directly as its own "test" target
right after linking. Exit code 126 is the shell's own "found the file,
couldn't execute it" -- i.e. the just-produced `c-example1` file exists
but lacks the execute bit.

## Root cause (not yet traced to a specific line)

Not investigated to the same depth as the other two bugs in this
directory (no `nix derivation show`/manual sandbox repro pass done yet).
The working theory: `discoverTree`'s link-output handling (or whatever
staging/restoring step runs between a link derivation's build sandbox and
the file `make` sees next) doesn't preserve the executable permission bit
that an ordinary in-place `gcc -o c-example1 ...` would produce by
default. This only surfaces for packages whose build script executes its
own freshly-linked binary before `installPhase` (most packages don't;
libb64's `examples`/`base64` Makefile targets do, as does the pattern
`giflib.nix`'s own comment contrasts against for why it doesn't hit
other bugs).

## Where this was found

Downstream showcase repo, ultracode survey pass looking for more
dyn-drvs-compatible nixpkgs packages beyond freetype/giflib/tinycbor.
`nixPackage` was pinned explicitly (not the ambient-Nix version-mismatch
pitfall documented in `discovertree-link-step-bug.md`).
