# Rust status

`rust/dyndrv-shim` is a real, working compiled binary (two entrypoints:
`dyndrv-shim` for per-invocation `cc`/`ar`/`ranlib` shimming,
`dyndrv-collect` for the end-of-`buildPhase` whole-tree resolution
pass), built via `nix/rust/dyndrv-shim.nix` (`rustPlatform.buildRustPackage`).
It replaces the `nix`/`jq` CLI shellouts `wrapCommand.nix`/
`collectStubs.nix` otherwise use with a raw Nix daemon worker-protocol
client, collapsing each shim invocation to one process.

This reverses the earlier (2026-09-02) "not yet justified" call recorded
in this file's own prior version — not because the underlying cost
argument changed (per-derivation registration tax is still real, see
`try-it-out/benchmarks/BASELINE.md`'s own honest 0.29x-0.30x numbers on
freetype), but because the user explicitly requested it, and because
"collapse every shim invocation to one process, and support running
outside a sandbox entirely" cannot be done within the existing
shell+jq+CLI-shellout stack no matter how much that stack is optimized —
it genuinely needs a different implementation, not just a faster one.

## What's built

Three interoperating modes, auto-detected from the environment
(`rust/dyndrv-shim/src/mode.rs`), sharing one `Record` -> `Derivation`
construction path so a TU registered one way and the same TU registered
another way land at the identical content-addressed store path
(confirmed directly, not just designed-to-be-true — see "Cross-mode
substitution" below):

- **`Sandbox`**: inside a `builder-rpc-v0` sandbox (`NIX_REMOTE` +
  `NIX_BUILD_TOP` both set) — defer + write a batch-pending stub,
  resolved later by `dyndrv-collect`. Wired into `wrapCommand.nix` as
  `toNodeCompiled`, verified byte-identical against the existing bash
  `toNodeBash`/`collectStubs.nix` mechanism (see
  `rust/dyndrv-shim/ar-integration-test.nix`/
  `collect-integration-test.nix`, kept as regression fixtures).
- **`Rpc`**: outside any sandbox (an ordinary shell/devShell) —
  register the real `Derivation` immediately over the UNRESTRICTED
  daemon connection (no deferral needed). `DYNDRV_AUTOFORCE=1`
  additionally realizes it (`build_paths`) and byte-copies the result
  back over the caller-visible path. `nix/lib/shim/devShell.nix` wires
  this into an ordinary `nix develop` shellHook — this is the actual
  native-mode interop the user asked about.
- **`Thunk { format: Nix }`**: no `ca-derivations`/`dynamic-derivations`
  requirement at all — writes a content-addressed `.nix` expression
  file to `.dyndrv/thunks/<id>.nix` (mirroring nixgg's own
  `.nixgg/thunks/<id>.nix` layout and idempotent tmp+rename write
  exactly) and symlinks the caller-visible output at it. No daemon call
  for the write itself. `DYNDRV_AUTOFORCE=1` runs one `nix build
  --file` and byte-copies the result back.
- **`Thunk { format: Drv }`** (EXPERIMENTAL, opt-in via
  `DYNDRV_THUNK_FORMAT=drv`): writes a REAL, ATerm-serialized `.drv`
  file directly to `.dyndrv/thunks-drv/<id>.drv`, via the same
  `harmonia_store_aterm::print_derivation_aterm` printer `Rpc` mode
  uses internally against a socket. See "Experimental finding" below —
  this mode's own realization path needed a correction once actually
  tested.

## Cross-mode substitution, confirmed not just designed

A standalone check (`cross_mode_check.rs`, run once during development,
not kept as a permanent fixture) fed the IDENTICAL logical `Record`
through both `Rpc` mode's `drv.rs::record_to_derivation` and
`dyndrv-collect`'s own solo-unit `render.rs::render_unit` construction,
and diffed the raw ATerm bytes both produce. First attempt: MISMATCH —
`record_to_derivation` was missing the trailing `"; "`
`render_member`'s chain-rendering convention always appends, which
would have silently broken cross-mode store-path agreement for any
multi-step chain even though a solo record happened to still match.
Fixed to match byte-for-byte. This is the concrete, mechanical reason a
TU registered by hand in a devShell and the same TU registered inside a
sandboxed `nix build` land at the same content-addressed store path —
not a separately-maintained equivalence test (nixgg's own
`tests/drv-equivalence.sh` exists specifically because ITS native/
sandbox code paths are NOT unified this way), a structural property of
sharing one construction path.

## Experimental finding: a `.drv` file needs `nix-store --add` before
## it can be realized (task #65)

The plan for `Thunk { format: Drv }` assumed a real `.drv`'s own
`inputDrvs` field being Nix's native on-disk dependency-edge format
would mean **no daemon call at all**, even for realization — write the
ATerm bytes, then hand the file straight to `nix-store --realise`.

**Confirmed false by direct reproduction**: both `nix-store --realise
<path>` and `nix build <path>^out` refuse a `.drv` at an arbitrary
FILESYSTEM path outright (`"is not in the Nix store"` /
`"is not a flake"`) — Nix's builder/scheduler machinery only operates
on an ALREADY-REGISTERED store path, never a raw on-disk file no
matter how well-formed its content. The fix: `nix-store --add
<path>` first (a trivial, build-free content-addressed file copy —
negligible overhead, no scheduling involved), THEN `--realise` on the
resulting store path. Also confirmed: the added path's own naming
(flat-CA hash of the file's bytes) does NOT need to match what the
derivation's own ATerm `name` field would compute — Nix parses the
ATerm content itself to determine the real output path, ignoring the
`.drv` file's own on-disk basename. Both single-node realization and
(implied, not yet built) a real multi-node `inputDrvs` graph would work
this way — each node individually `--add`ed before the root's own
`--realise`, no separate thunk-graph helper file needed the way
`Thunk { format: Nix }` requires for its own batched `nix build --file`
call.

Net effect: `Drv` format's write path IS still fully daemon-free (as
designed); only ITS OWN realization path needed one small daemon
round-trip (`--add`) that the original plan didn't anticipate.

## `cc`'s decision logic + `discoverTree`, ported and verified against
## real freetype (task #67)

`cc.rs`'s `cc_to_node`/`discover_tree` is a byte-exact port of
`ccToNodeBash`/`mkAcceleratedStdenv.nix`'s `discoverTree` bash script,
including the deliberately-preserved `-1`-sentinel arithmetic asymmetry
(see that file's own module comment). Wired into `wrapCommand.nix`
(`toNodeCompiled`), `mkAcceleratedStdenv.nix` (all three shims), and
`phases/split.nix` (`dyndrv-collect` for the sandboxed collection tail)
behind a `dyndrvShim` param, default `null` (unchanged bash path).

Verified against three fixtures of increasing complexity — 05
(toy 3-file program), 06 (`granularity = "module"` batching), and 07
(real, unmodified `pkgs.freetype`, ~45 translation units, real
cross-package `-I`/`-L` inputs, libtool-driven link with a generated
version-script) — each built via
`try-it-out/examples/0N-*-compiled.nix` copies passing `dyndrvShim`
through. All three now build and run correctly (05/06's `prog`
binaries produce their documented expected output; 07's full compile
+link pipeline reaches the exact same point bash-path 07 does, failing
identically on an unrelated environmental `/nonexistent` permission
issue present in both paths — not a regression, confirmed by running
both side by side and diffing their tails byte-for-byte).

Four real bugs found and fixed during this verification pass (none
caught by the smaller `ar`/`ranlib` fixtures — only surfaced once a
real multi-directory, multi-library package exercised `discoverTree`'s
full path):

- **Absolute discovered paths corrupted the staged tree.**
  `run_discover_tree`'s `all_paths` list included `cc -M -MG`'s raw
  output unfiltered — an absolute system-header path (e.g. glibc's
  `stdio.h`) reached `stage_tree`, where Rust's `PathBuf::join` on an
  absolute argument REPLACES the whole destination rather than
  nesting it, so `fs::copy` tried to copy a read-only store file onto
  itself (`Permission denied`). Fixed by filtering `discovered` for
  absolute paths before staging, matching the bash oracle's own
  `case "$p" in /*) continue;; esac`.
- **`extra_store_paths` (both `cc.rs` and `tonode.rs`) used
  `str::strip_prefix`, a whole-element check, not a substring scan.**
  A real argv element routinely GLUES a store path onto a flag with no
  space (`-I/nix/store/...-bzip2-1.0.8-dev/include`) — confirmed
  necessary by direct reproduction against real freetype:
  `ftbzip2.c`'s compile failed with `bzlib.h: No such file or
  directory` because `bzip2-...-dev` never made it into the
  derivation's own `srcs`. Fixed to scan for `/nix/store/` ANYWHERE in
  the element, matching the bash oracle's `grep -o "/nix/store/[^/\"']*"`
  and `toNode`'s own `builtins.match ".*(...)."`.
- **`run_discover_tree` never ported the `-Wl,*`-glued-path case.**
  libtool generates `objs/.libs/libfreetype.ver` via plain shell
  redirection (not `cc`/`ar`), then references it as
  `-Wl,-version-script,objs/.libs/libfreetype.ver` — invisible to the
  positional scan since `-Wl,...` is `-`-prefixed. Missing this staged
  an incomplete tree, and the LINK step failed
  (`ld.bfd: cannot open linker script file`). Ported
  `wrapCommand.nix`'s own comma-token walk. The positional scan was
  also missing the stub-exclusion guard (`dyndrv_read_batch_stub`) the
  bash oracle has — a link step's own `.o` positional args can be
  OTHER pending stubs, which must stay as literal argv text, not get
  staged as real (placeholder) file content.
- **`dyndrv-collect`'s final tree-assembly script referenced
  `orig_tree_path.to_base_path()` bare**, missing the `/nix/store/`
  prefix (same `StorePath::Display` gotcha `wrapper.rs::
  rewrite_argv_element` already had its own comment about) — the
  generated `cp -r <basename>/. $out/` resolved against the CALLING
  derivation's own relative cwd instead of the real store path
  (`cp: cannot stat '<hash>-dyndrv-orig-tree/.': No such file or
  directory`). Fixed by reconstructing the absolute path explicitly.

All four were caught by direct reproduction against increasingly real
fixtures, not designed around in advance — consistent with this
project's own established discipline: the smaller `ar`/`ranlib`
fixtures (05/06, plus the standalone integration tests) stayed green
throughout, since none of them exercise `discoverTree`'s absolute-path
filtering, glued-flag store-path scanning, or `-Wl,`-referenced
generated files at all.

## What's still follow-on work

- `Thunk { format: Drv }`'s multi-node graph case (real `inputDrvs`
  chaining across several dyndrv-produced `.drv` files) is unbuilt —
  only verified against a single-node fixture.
- Batching across the transitive thunk graph for `Thunk { format: Nix
  }`'s own autoforce path (nixgg's own `realise.Realise`) is unbuilt —
  only the single-thunk case works today.
- Re-measuring `real-package-patch-rebuild.sh`/
  `real-package-version-bump.sh` against the compiled path is BLOCKED
  in the current environment, not just open — see `BASELINE.md`'s own
  "Compiled-shim re-measurement: BLOCKED" section: both the bash-path
  and compiled-path accelerated freetype builds now fail identically on
  this machine at `phases.split`'s phase 2 `installPhase` (`mkdir:
  cannot create directory '/nonexistent': Permission denied`),
  confirmed environmental (the UNMODIFIED bash-path script fails the
  same way with no `dyndrvShim` involved at all) and unrelated to
  correctness — examples 05/06/07 all still build and run correctly
  under the compiled path.
