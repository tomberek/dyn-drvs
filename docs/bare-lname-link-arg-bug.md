# Bug: bare `-l<name>` link args are never resolved to their producing derivation

## Summary

The `overlay` showcase repo's wide nixpkgs survey has driven every
package it tried into either a genuine PASS or a package-level
workaround, except this one -- still genuinely open at the `dyndrv`
level as of this writing (latest pushed commit: `d541476`), worked
around in the showcase repo but not fixed here.

## Finding: bare `-l<name>` link args are never resolved to their
producing derivation (x265)

### Reproduction

```console
$ pkgs.x265.override { stdenv = dyndrv.accelerate.mkAcceleratedStdenv { stdenv = pkgs.stdenv; inherit nixPackage; }; }
```

Every real per-TU compile and both `ar`-driven archive steps
(`libx265_a.a`/`libhdr10plus_a.a`, previously blocked by the now-fixed
`28af81d` bug) succeed. The final shared-lib link then fails:

```
ld.bfd: cannot find -lx265-10: No such file or directory
ld.bfd: cannot find -lx265-12: No such file or directory
collect2: error: ld returned 1 exit status
```

`nix derivation show` on the failing link's `.drv` confirms
`inputs.drvs = {}`.

### Root cause

x265's own cmake build produces a multi-bitdepth encoder: separate
`libx265-10.a`/`libx265-12.a` static libs for the 10-bit/12-bit encoder
variants, linked into the final `libx265.so` via a bare library-name
reference:

```
-Wl,-Bstatic -lx265-10 -lx265-12 -Wl,-Bdynamic
```

Every other link-step gap this survey has found and fixed (the original
`discoverTree` `-M -MG` link-step scan, `28af81d`'s `ar`-input scan,
`e5f9a61`'s `dyndrvMoveFromOut`) works by recognizing a LITERAL,
already-resolved `/nix/store/...` substring already present somewhere in
argv or a captured wrapper-env string, and wiring that as a declared
`inputs.drvs` dependency. A bare `-l<name>` is fundamentally different:
it's a linker *search-path* reference (`-L.` + `-lx265-10` means "find
`libx265-10.a`/`.so` somewhere on the search path," resolved by `ld`
itself at link time, not by anything visible in the invoking process's
own argv as a literal path). None of the existing literal-substring
scanning machinery has anything to match against here — there is no
store path anywhere in this invocation's argv or environment that names
`libx265-10.a`; the only place its resolved store path exists is inside
the OTHER derivation record that will eventually produce it, which this
invocation has no way to look up from its own argv alone.

Confirmed not fixed by any dyn-drvs commit through `caa7c5d` (checked
`dc07a0a`, `1347c8c`, `e5f9a61`, `5468402`, `bb1c077`, `caa7c5d`
specifically — none add `-l<name>` resolution; the ones that look
related fix adjacent-but-distinct things: `dc07a0a` unglues an
already-literal `-Wl,`-style path, `e5f9a61` redistributes ordinary
bin/lib content post-build, `caa7c5d` fixes a meson probe-classification
gap unrelated to link-arg resolution — none touch search-path-relative
library references).

### Workaround used downstream (not a dyndrv-level fix)

`overlay`'s `nix/packages/x265.nix` passes
`multibitdepthSupport = false` (a real nixpkgs `x265.override`
parameter) to disable the whole multi-bitdepth cmake path that bakes in
this `-lx265-10`/`-lx265-12` linkage in the first place — genuinely
avoiding the bug, not fixing it. Real trade-off: this drops 10-bit/12-bit
HDR encoding support entirely, unlike every other workaround this survey
found (which only disabled auxiliary/test machinery, not real product
functionality).

### What a real fix would need

Resolving a bare `-l<name>` reference requires knowing the FULL set of
`-L<dir>` search paths active at link time (both the sandbox's
`NIX_LDFLAGS`-style entries and any relative `-L.`/`-Lbuild/lib`-style
in-tree paths) and then matching `<name>` against the basename patterns
`lib<name>.so`/`lib<name>.a` across every OTHER pending/resolved
dynamic-derivation record this build has registered so far — genuinely
harder than the existing literal-substring scan, since it requires
correlating two different derivations' own output-naming conventions
rather than finding a literal path already present in one place. Likely
needs its own dedicated pass in `collectStubs.nix`, analogous to (but
more involved than) the existing `extraStorePaths` scan.

### Where this was found

`overlay`'s `nix/packages/x265.nix` and `benchmarks/RESULTS.md`,
applying `accelerate.mkAcceleratedStdenv` to unmodified nixpkgs `x265`
(cmake, H.265 encoder, ~99 real per-TU compile derivations — the
heaviest-per-TU-cost package this survey found still hitting a distinct
dyn-drvs bug after all lighter-weight bugs on the same package were
already fixed).
