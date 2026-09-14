# FIXED: link-step fix broke single-invocation compile+link (`cc foo.c -o foo`)

## Status: fixed

`discoverTree`'s guard (`nix/lib/accelerate/mkAcceleratedStdenv.nix`) now
checks a `has_source_file` flag instead of `has_c_flag`/`has_compile_flag`.
The binding builds `args` in a single pass over `"$@"`, setting
`has_source_file=1` the moment any positional arg matches
`*.c|*.cc|*.cpp|*.cxx|*.c++|*.m|*.mm`, then:

```sh
if [ "$has_source_file" = 0 ]; then
  exit 0
fi
```

runs immediately before the `-M -MG` scan, replacing the old `if [
"$has_c_flag" = 0 ]; then exit 0; fi` guard. This correctly runs header
discovery for a plain compile (`-c foo.c -o foo.o`) AND for
compile+link-in-one-step (`cc foo.c libbar.a -o foo`, no `-c` at all,
which is exactly `gifinto.c`'s shape), while still skipping the scan for
a genuine link-only invocation (all `.o`/`.a` positional args, no real
source file) -- preserving the original efficiency win
`discovertree-link-step-bug.md` was going for.

This is precisely the approach this file's own "Suggested fix" section
below anticipated ("skip `-M -MG` if none of the positional args end in
a recognized source-file extension") -- that section is now superseded
by the actual fix described above, not a still-open proposal.

## Summary

The fix for the link-step bug (`discovertree-link-step-bug.md`, now marked
FIXED) made `discoverTree` skip its `-M -MG` header-discovery scan
whenever no `-c` flag is present in argv, on the assumption that no `-c`
means "this must be a pure link with `.o`/`.a` inputs, which `-M -MG`
can't help with anyway." That assumption is correct for cmake- and
libtool-style builds (compile and link are always separate invocations),
but wrong for the common pattern of compiling AND linking a `.c` source
directly in one command: `cc foo.c libbar.a -o foo` has no `-c` flag,
but it DOES compile a real source file needing header discovery, not
just link precompiled objects.

## Reproduction

Regressed `giflib`, previously fully proven (see `nix/packages/giflib.nix`,
which explicitly documented `giflib`'s `ar`-based build having no
`cc`-driven link step at all -- true for the LIBRARY, but giflib also
ships several small utility programs built exactly this way):

```console
$ pkgs.giflib.override { stdenv = dyndrv.accelerate.mkAcceleratedStdenv { stdenv = pkgs.stdenv; inherit nixPackage; }; }
```

Fails building `gifinto`/`gifsponge`/`giftext`/... (giflib's small CLI
utilities, `util/gifinto.c` etc.):

```
gifinto.c:22:10: fatal error: getarg.h: No such file or directory
   22 | #include "getarg.h"
      |          ^~~~~~~~~~
compilation terminated.
```

`nix derivation show` on the failing `.drv` confirms the exact invocation:

```
cc -std=gnu99 -fPIC -Wall -O2 gifinto.c \
  /nix/store/...-dyndrv-libgif_a /nix/store/...-dyndrv-libutil_a \
  -lm -o $out -Wl,--build-id=sha1
```

One command: compiles `gifinto.c` (a real source file, needs
`getarg.h` staged) AND links it against `libgif_a`/`libutil_a` in the
same invocation. No `-c` flag anywhere in argv.

## Root cause

`discoverTree`'s guard (`nix/lib/accelerate/mkAcceleratedStdenv.nix`,
the `if [ "$has_c_flag" = 0 ]; then exit 0; fi` line inside the
`discoverTree` script) uses "has `-c`" as a proxy for "is this a
compile," but that's not the real distinguishing condition. The real
condition is "does this invocation have at least one real
`.c`/`.cc`/`.cpp` source file as a positional arg" -- true for both `cc
-c foo.c -o foo.o` (ordinary compile) and `cc foo.c libbar.a -o foo`
(compile+link in one step), and false only for a genuine link-only
invocation like `cc foo.o bar.o -o foo` (no source files, only
objects/archives). The guard's own comment explicitly reasons about "a
link invocation (no `-c`)" as if that were the only case reaching this
branch, missing the compile+link-in-one-step case entirely.

## Suggested fix (superseded -- see "Status: fixed" above)

This section is kept for history; the landed fix matches it exactly.

Change the guard from "skip `-M -MG` if no `-c` flag" to "skip `-M -MG`
if none of the positional args end in a recognized source-file
extension (`.c`, `.cc`, `.cpp`, `.cxx`, `.m`, `.mm`, ...)." That
correctly runs header discovery for BOTH plain compiles and
compile+link-in-one-step invocations, while still skipping it for pure
`.o`/`.a`-only link invocations (the original bug this fix targeted).
Whatever mechanism now correctly resolves `.o`/`.a` positional args for
pure links (the `DYNDRV_INVOCATION_CWD`-based fix this guard's own
comment references) should remain unconditional, since a compile+link
invocation like `gifinto.c`'s ALSO needs its `libgif_a`/`libutil_a`
inputs resolved correctly alongside header discovery -- both need to
run together for this invocation shape, not either/or.

## Where this was found

Downstream showcase repo, CI regression: `dyndrv-giflib` (previously
fully proven, hard-gated in CI) broke immediately after bumping to the
commit containing the discoverTree-link-step-bug fix. Confirmed via
`nix derivation show` on the failing per-utility-program `.drv`.
