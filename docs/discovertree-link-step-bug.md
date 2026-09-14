# FIXED: `discoverTree`'s `-M -MG` scan can't see link-step inputs (+ a deeper cwd-frame bug)

## Status: fixed

Two real, distinct issues were found investigating this report; both are
now fixed.

## Original report (accurate as far as it went)

`accelerate.mkAcceleratedStdenv`'s `cc`/`c++` shims (`ccShim`/`cxxShim` in
`nix/lib/accelerate/mkAcceleratedStdenv.nix`) used `discoverTree` mode
unconditionally — for compiles *and* links. `discoverTree`'s own `-M -MG`
header-dependency scan genuinely finds nothing for a link invocation
(`gcc <objs> -M -MG` treats every `.o`/`.a` positional arg as "unused
linker input" and prints nothing — confirmed directly). This is real,
but turned out to be *harmless in isolation*: a flat (non-nested,
same-cwd) minimal repro with the identical "discoverTree finds nothing"
property still succeeds, because `wrapCommand.nix`'s separate positional-
argv-scan loop (`argvPaths`) independently recognizes and preserves
pending-stub references in a link's own `args`, regardless of what
`discoverTree` found.

Fixed anyway, as a pure efficiency win (the scan can never succeed for a
link, so running it is wasted subprocess spawns): `discoverTree` now
exits immediately when no `-c` flag is present in argv, skipping the
`-M -MG` spawn entirely for every link invocation.

## The actual root cause (found during this investigation, not in the original report)

A **cwd-relative-path-frame mismatch**, unrelated to `discoverTree`'s own
scan result. When a build step's own current working directory (e.g.
cmake's generated `cd build && cc CMakeFiles/prog.dir/src/a.c.o ... -o
exe`) DIFFERS from the cwd of the invocation that *produced* that `.o`
file (e.g. a compile step run from the package's own root directory,
writing to `build/CMakeFiles/prog.dir/src/a.c.o`), the two invocations
reference the SAME real file via TWO DIFFERENT RELATIVE-PATH STRINGS:
`collectStubs.nix`'s Phase 1 discovers the compile's own stub as
`"build/CMakeFiles/prog.dir/src/a.c.o"` (relative to the fixed package
build root), while the link step's own `record.args` (built from the RAW
argv the link's own wrapper script actually saw) contains only
`"CMakeFiles/prog.dir/src/a.c.o"` (relative to `build/`, since that's
what the link command's own argv says once already `cd`'d there). Phase
2's dependency-matching (a plain string/array lookup) never connected
these two strings, so the link step's own dependency on the compile step
was silently lost, and the real build failed with `ld.bfd: cannot find
CMakeFiles/prog.dir/src/a.c.o: No such file or directory`.

Confirmed via three separate minimal repros: a flat repro (no cwd
change) succeeded; a nested, cwd-changing repro reproduced the failure
identically; a nested-but-same-cwd control succeeded — isolating the cwd
change itself (not nesting depth, not `discoverTree`'s scan result) as
the trigger.

### The fix

Each invocation now records its own cwd, relative to `NIX_BUILD_TOP`
(the one anchor stable across a whole sandboxed build) —
`DYNDRV_INVOCATION_CWD` in `wrapCommand.nix`, `record.cwd` in the JSON
record shape. `collectStubs.nix` converts this into a `dyndrv_buildRoot`-
relative offset (`dyndrv_relative_between`) and joins it against each
`args` reference (`dyndrv_join_rel`) before comparing against a
discovered stub's own key — reconciling both invocations onto the same
relative-path frame regardless of which directory either one ran from.
Ported identically to the Rust path (`Record.cwd`, `wrapper::
invocation_cwd`, `collect::{join_rel,relative_between}`,
`render.rs::render_member`'s per-record join).

A regression fixture (`try-it-out/examples/17-accelerate-cwd-mismatch.nix`)
exercises exactly this shape — compile from the package root, link from
a nested `build/` subdirectory — confirmed failing before the fix and
passing after, on both the bash and compiled-shim code paths.

## Where this was found

Downstream showcase repo, `nix/packages/zstd.nix` and
`benchmarks/RESULTS.md`, applying `accelerate.mkAcceleratedStdenv` to
unmodified nixpkgs `zstd` (cmake).
