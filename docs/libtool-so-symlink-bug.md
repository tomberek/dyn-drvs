# Bug: a libtool `.so` symlink (pointing at the real versioned `.so.N.N.N`) is never resolved to its producing derivation

## Summary

Found while wiring `libpng`/`libtasn1` into the `overlay` showcase repo
after the `outputBin` override bug (`split-outputbin-override-bug.md`)
was fixed upstream in `0a8b174`. Still genuinely open at the `dyndrv`
level as of this writing (latest pushed commit: `0c81eec`).

## Finding: libtool's unversioned `.so` symlink never round-trips

### Reproduction

```console
$ pkgs.libpng.override { stdenv = dyndrv.accelerate.mkAcceleratedStdenv { stdenv = pkgs.stdenv; inherit nixPackage; }; }
$ pkgs.libtasn1.override { stdenv = dyndrv.accelerate.mkAcceleratedStdenv { stdenv = pkgs.stdenv; inherit nixPackage; }; }
```

Both packages get well past the (now-fixed) `outputBin` crash: every
real per-TU compile succeeds, and libtool's own real, versioned shared
library (`.libs/libpng16.so.16.58.0`, `.libs/libtasn1.so.6.7.0`) links
and is correctly tracked as a dynamic derivation. The very next link
step that references the library by its libtool-generated *unversioned*
name then fails:

```
# libpng, linking contrib/tools/pngcp against ./.libs/libpng16.so
ld.bfd: cannot find ./.libs/libpng16.so: No such file or directory

# libtasn1, linking examples/CertificateExample against ../lib/.libs/libtasn1.so
ld.bfd: cannot find ../lib/.libs/libtasn1.so: No such file or directory
```

`nix derivation show` on either failing link's `.drv` confirms
`inputs.drvs = {}`.

### Root cause

libtool's own convention for a versioned shared library is to link the
real file (`libpng16.so.16.58.0`) once, then create a plain symlink
alongside it, `libpng16.so -> libpng16.so.16.58.0`, and have every
downstream consumer (an in-tree test binary, an example program, another
target in the same Makefile) link against the *unversioned symlink name*,
not the versioned file. Under `accelerate.mkAcceleratedStdenv`, the
versioned file (`libpng16.so.16.58.0`) is the thing that's actually
produced by a `cc -shared` invocation and gets tracked as a real dynamic
derivation via the ordinary `-o <path>` output-scan. The unversioned
`.so` name, however, is created by a separate `ln -s`/libtool-internal
step, not a compiler invocation `wrapCommand.nix` ever wraps or observes
— so nothing ever registers `libpng16.so` (the symlink) as an alias for,
or dependency on, the dynamic derivation that produces
`libpng16.so.16.58.0` (the real file). When a later link step's argv
literally says `./.libs/libpng16.so`, that string never matches anything
`collectStubs.nix`'s stub-path bookkeeping knows about — it only knows
about the *real* file it tracked (`libpng16.so.16.58.0`), under a
different name.

This is a distinct failure mode from every other link-step gap already
found and fixed in this survey:

- Bug #3 (`discoverTree`'s `-M -MG` scan)/`28af81d`'s `ar`-input scan
  both concern a shim never declaring `inputs.drvs` for a resolved store
  path that's already present, literally, somewhere in argv.
- `bare-lname-link-arg-bug.md` (x265's `-lx265-10`) concerns a bare
  linker *search-path* reference with no literal path anywhere at all.
- This bug is different from both: the literal string `./.libs/
  libpng16.so` genuinely exists in argv, and a dynamic derivation that
  will produce a file *closely related to it* (`libpng16.so.16.58.0`)
  genuinely exists too — but the two are never connected, because the
  symlink itself, not the file it should point to, is what argv
  references, and no code path creates or tracks that symlink as an
  alias of the real dynamic derivation.

### What a real fix would need

After a compile/link stub is registered under its real name (e.g.
`libpng16.so.16.58.0`), the build's own filesystem state (or a scan of
common libtool naming patterns — `lib<name>.so.<major>.<minor>.<patch>`
→ `lib<name>.so.<major>` → `lib<name>.so`, the classic libtool version
chain) would need to register the *unversioned* and *soname* variants as
additional aliases resolving to the same dynamic derivation, so a later
literal-argv reference to any of the three names resolves correctly.
Likely needs a dedicated libtool-aware pass, analogous in spirit to (but
distinct from) `bare-lname-link-arg-bug.md`'s suggested fix, since this
case genuinely has a literal path in argv to match against — the gap is
in never having registered that literal path as an alias in the first
place, not in needing to resolve a search-path-relative name at build
time.

### Where this was found

Downstream showcase repo, wiring `nix/packages/libpng.nix` and
`nix/packages/libtasn1.nix` into `overlay`'s flake outputs after
confirming the `outputBin` override bug (which originally blocked both
packages before any real compile ran) was fixed upstream. Independently
confirmed on both packages — same failure shape, different unversioned
symlink names (`libpng16.so`, `libtasn1.so`) — both autotools + libtool,
no cmake, no autoreconfHook.
