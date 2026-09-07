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

## Making `nix develop` actually work end to end

`shim.devShell`'s own header comment always claimed `cc`/`ar`/`ranlib`
wrappers, but `ccShim` was never actually built there — only `ar`/
`ranlib`, with `realCc` computed and unused. A real `nix develop`
session therefore got shimmed `ar`/`ranlib` but a completely
UNshimmed, real `cc` — no acceleration at all for compiles, the bulk
of any real build. Fixed by adding `ccShim`/`CC`/`CXX` exports,
mirroring `mkAcceleratedStdenv.nix`'s own `wrapperDir` convention
exactly (installed under both `cc` and `gcc`). Also added a real
`devShells.dyndrv-shim` output in `flake.nix` (previously `shim.
devShell` had no flake-level consumer at all — `nix develop` couldn't
reach it).

Getting a real `nix develop` session to compile+archive+link+run
correctly surfaced FOUR more real bugs, none reachable from any
existing fixture (`Sandbox` mode's `ar`+`ranlib` chaining and
`Rpc`-mode-without-autoforce never exercise the code paths these live
in):

- **Standalone `ranlib` never seeded `$out` with the archive's real
  content.** `ranlib` modifies its one archive argument IN PLACE, but
  outside `Sandbox` mode's `ar`+`ranlib` `chainedFrom` chaining (which
  folds both steps into one script where `ar`'s own output IS the
  seed), a lone `ranlib` invocation registered `ranlib $out;` with
  nothing ever populating `$out` — confirmed by direct reproduction
  against a real `nix develop` session (`ranlib: No such file`). Fixed
  by giving `ranlib_to_node` its own `setup_cmd` (`cp <real-archive-
  path> $out && chmod u+w $out &&`), mirroring `cc`'s own `setup_cmd`
  convention. Needed threading `DYNDRV_COREUTILS_BASENAME` through to
  `ranlib` (previously `cc`-only) and adding the archive's own real
  store path (excluded from the ordinary `extra_store_paths` scan,
  since that argv slot is about to be overwritten with `"$out"`) as an
  explicit `srcs` entry, or the sandboxed derivation never mounted it
  at all.
- **`run_plain` resolved `outputArg` from the REWRITTEN argv, not the
  original.** For `ranlib`, the output path IS an already-real INPUT
  file, so `rewrite_argv_element`'s generic "any existing regular file
  gets rewritten to its own store path" pass had already replaced that
  exact argv slot by the time `decide()` returned `output_arg` —
  resolving a `/nix/store/...` string as the "output path" instead of
  the caller's own relative `liba.a`. Identical gap in the bash
  oracle's own `resolveNodeFields` (also indexes the rewritten
  `$argvJson`), never triggered there since `Sandbox` mode's chaining
  means the archive is always still a pending STUB, never a real file,
  at rewrite time. Fixed by resolving `output_arg` from the stripped
  (pre-rewrite) argv instead — a no-op for the already-working stub
  case, since a stub path rewrites to itself either way.
- **`run_rpc_tail`'s autoforce byte-copy left the output read-only.**
  `fs::copy` sets the destination's permissions to match the SOURCE's
  regardless of whether the destination already existed — copying from
  a read-only Nix store path left the caller-visible output at mode
  444. A LATER standalone `ranlib` invocation modifying that same path
  in place (via the fix above) then failed with "Permission denied"
  trying to write back over it. Fixed with an explicit `chmod u+w`
  after the copy.
- **`connect_from_env`'s own `in_drv` heuristic misfires inside `nix
  develop`.** `nix-builder-rpc-client::connect_from_env` treats
  `NIX_BUILD_TOP` alone as "inside a derivation build," but `nix
  develop`'s own shell-setup derivation leaves `NIX_BUILD_TOP` set in
  the INTERACTIVE shell it hands back (an ordinary, common nixpkgs
  `mkShell` convention many setup hooks rely on for scratch space) even
  though `NIX_REMOTE` is empty there. This wrongly selected the
  sandboxed-only `AddToStoreScanning` opcode outside any sandbox,
  failing with "the daemon does not support the 'add-to-store-
  scanning' protocol feature" the moment `cc`'s own `discoverTree`-
  equivalent path called `add_to_store_nar`. Fixed by adding
  `mode::connect()` — same socket-resolution logic as `connect_from_env`,
  but using dyndrv's own already-correct `in_sandbox()` check (`NIX_REMOTE`
  AND `NIX_BUILD_TOP` both set, matching `mode::detect()`'s own
  criterion) instead of the vendored crate's looser one. Both binaries
  (`dyndrv-shim`, `dyndrv-collect`) now use this helper.

Verified end-to-end after all four fixes: a real `nix develop
.#dyndrv-shim` session (via `flake.nix`'s new devShell) compiling two
files, archiving one into a static library, `ranlib`-indexing it,
linking against both the object and the archive, and running the
result — all through the compiled shim, with `DYNDRV_AUTOFORCE=1` so
every step realizes immediately.

## Spike finding: freshly-`add_drv_to_store`d paths are NOT sandbox-
## visible (task #83)

Investigated switching `Sandbox` mode's own intermediate representation
from a text-based batch-pending stub to a real symlink pointing
straight at a `.drv`'s own store path (see `docs/drv-thunk-multinode-
design.md`'s sibling design doc for the full "symlink-based IR" plan
this answers a prerequisite question for). The open question: does a
store path registered via `add_drv_to_store` MID-BUILD become
filesystem-visible (`stat`/`readlink -f`) inside the SAME sandboxed
builder that just registered it, or is `builder-rpc-v0`'s sandbox only
ever bind-mounted with the DECLARED input closure known before the
build started?

**Confirmed by direct reproduction: NOT visible.** A throwaway spike
binary (`sandbox-visibility-spike.rs`, built and run once, then
deleted — not a kept fixture) registered a brand-new, never-before-seen
derivation via `add_drv_to_store` inside a real `builder-rpc-v0`
sandbox, then immediately checked the resulting path both directly
(`std::fs::symlink_metadata`) and through a freshly-created symlink to
it. Both checks failed identically: `No such file or directory (os
error 2)`. The daemon accepts and returns a real, valid `StorePath` for
the registration itself (confirmed: `add_drv_to_store` succeeded, the
path just isn't locally statable) — this is purely a sandbox
mount-namespace limitation, not a registration failure.

**Consequence**: any design that wants to detect "is this on-disk path
actually a resolved dependency, and if so what's its real identity"
from WITHIN a `Sandbox`-mode build cannot use a plain filesystem check
for anything registered live, mid-build (unlike `Thunk` mode's `.nix`/
`.drv` thunk files, which ARE real local files and stay `stat`-able).
It needs a daemon `IsValidPath` round-trip instead — the primitive
already exists one layer down in `harmonia-store-remote` (confirmed
present in the vendored crate) but is not yet wrapped by `nix-builder-
rpc-client`'s own public API, so using it would mean adding that
wrapper first. This is exactly the "Design B" branch of the symlink-IR
plan; any eager-registration redesign of `Sandbox` mode's file- or
module-granularity paths must budget for this daemon round-trip's
latency, not assume a free local `stat`.

## `Thunk{Drv}`'s multi-node graph: built, verified (tasks #77-82)

The single-node limitation flagged in the "Experimental finding" above
is resolved — `Thunk{format: Drv}` now chains real `inputDrvs` across
multiple `.drv`-format thunks (see `docs/drv-thunk-multinode-design.md`
for the original design). Summary:

- **`compute_drv_store_path`** (`drv_thunk.rs`): computes a `.drv`'s own
  content-addressed `StorePath` locally, no daemon call, via
  `harmonia_store_content_address::make_store_path_from_ca` +
  `ContentAddress::Text(Sha256::digest(aterm_bytes))` — mirrors what
  `add_drv_to_store`'s server side computes internally. Verified
  byte-identical against a real `add_drv_to_store` call for two
  independently-generated derivations (a throwaway check binary, built,
  run twice, then deleted).
- **Dependency scan + `inputDrvs` wiring** (`thunk_tail.rs`::
  `run_drv_format`, `drv_thunk.rs`::`write_drv_thunk`/
  `resolve_drv_thunk_dependency`): before writing a record's own `.drv`,
  scans `record.args` for elements that are symlinks into
  `.dyndrv/thunks-drv/` (an earlier, already-completed shim
  invocation's own thunk), resolves each one's real `StorePath`, and
  wires it as a `SingleDerivedPath::Built` `inputDrvs` edge — with the
  script's own literal argv reference substituted for the dependency's
  real placeholder token (`Placeholder::ca_output`). Verified directly:
  a two-compile-plus-archive graph's own `ar` derivation correctly
  lists both compiles' real store paths in `inputDrvs`.
- **Real bug found and fixed along the way**: `stub::is_pending`
  (the "is this argv element a placeholder, not real content" check
  every argv-rewrite guard uses) never recognized a `Thunk{Drv}`
  symlink as pending — only `Sandbox`'s text stub and `Rpc`'s
  store-path symlink. Without this, `rewrite_argv_element` staged a
  `.drv`-thunk symlink's own ATerm bytes as if they were real object
  content, corrupting the dependent derivation (empty `inputDrvs`,
  bogus store paths in the script) — confirmed by direct reproduction,
  fixed by having `is_pending` also check `resolve_drv_thunk_dependency`.
- **Multi-node realization, the plan's own crux unverified claim,
  confirmed FALSE as originally hoped, then fixed**: `nix-store
  --realise` on a `--add`ed root `.drv` does NOT resolve `inputDrvs`
  entries pointing at `.drv` files that were never themselves
  registered ("store path '...' does not exist") — confirmed by direct
  reproduction. Worse, `nix-store --add`'s own FLAT-CA naming produces
  a DIFFERENT path than a `.drv`'s real `text:sha256` identity, so
  `--add`ing every file individually doesn't help either — the
  resulting paths don't match what `inputDrvs` actually names. Fixed
  with `register_drv_tree` (`thunk_tail.rs`): parses each `.drv`'s own
  ATerm to discover its `inputDrvs`, recurses bottom-up matching
  against sibling `.drv` files by re-computing their store paths, and
  registers each one via `add_to_store_text` — the SAME CA method
  `add_drv_to_store` uses internally, so the resulting path matches
  `compute_drv_store_path`'s own computation exactly. Still no `nix
  build`/scheduling call except the one final `--realise` on the root.
- **Verified end-to-end** with a real three-node graph (two compiles +
  one archive) under `DYNDRV_AUTOFORCE=1` on just the archive step (NOT
  globally — `DYNDRV_AUTOFORCE` is read unconditionally by every
  invocation including `cc`, so forcing it globally eagerly promotes
  compiles to real files before `ar` ever sees a `.drv`-thunk symlink,
  never exercising cross-drv chaining at all — confirmed by direct
  reproduction on the fixture's own first draft): the archive's own
  `inputDrvs` correctly resolves both compiles' real outputs, producing
  a genuinely valid `liba.a` that links and runs correctly (11+22=33).
  Kept as a permanent regression fixture,
  `rust/dyndrv-shim/drv-thunk-multinode-test.sh` (a plain shell script,
  not a Nix derivation, since `Thunk` mode's whole design point is
  working outside any sandbox).

## Symlink-IR redesign: `Sandbox` mode's file-granularity path (task #85)

`Sandbox` mode's file-granularity (`granularity = "file"`, the
default) path is redesigned per the plan referenced above: a keyless
record with no dependency on a still-pending TEXT stub now registers
its own derivation EAGERLY (`add_drv_to_store`, legal inside a
`builder-rpc-v0` sandbox — only `BuildPaths`/realization is
restricted there) and symlinks the caller-visible output straight at
the registered `.drv`'s real store path — the SAME representation
`Rpc` mode's own non-autoforce tail already uses (`stub::
read_pending_symlink`), instead of a JSON-record text stub.

- **`dyndrv-collect`'s own discovery/Phase 7 needed two fixes** to see
  these eager symlinks at all: `collect::discover_stubs` only ever
  looked for text stubs (now also matches `read_pending_symlink`,
  carrying the resolved `StorePath` on a new `Stub::eager_drv` field);
  `walk_files` used `path.is_file()`/`is_dir()`, which FOLLOW symlinks
  — a freshly-registered store path isn't locally `stat`-able from
  inside the SAME sandbox that registered it (task #83's own spike),
  so every eager stub was silently invisible to directory discovery.
  Fixed via `DirEntry::file_type()` (no dereference), treating a
  symlink entry as a discovered stub outright. Phase 7 now reuses an
  eager stub's own already-registered `StorePath` instead of
  re-rendering/re-registering it.
- **Real correctness bug found and fixed along the way**: `ranlib_to_
  node` overwrote the archive's own argv slot with `"$out"` BEFORE any
  caller ever scanned for dependencies, so a standalone (non-chained)
  `ranlib`'s registered derivation always ended up with ZERO
  `inputDrvs` — confirmed via `nix derivation show`:
  `"inputs":{"drvs":{}}`. `ranlib` would silently run against an empty
  `$out` instead of the real archive, rather than failing loudly. This
  affected every ALREADY-COMMITTED eager tail sharing this decision
  logic (`Rpc` mode, `Thunk{Drv}` mode too), not just the new `Sandbox`
  path. Fixed by giving `Record` a new `seed_from` field (a
  `SeedFrom{from, coreutils_basename}` pair) that `ranlib_to_node`
  populates instead of building its own `setup_cmd` string directly;
  every render layer (`drv.rs`, `drv_thunk.rs`, `thunk.rs`, `render.rs`)
  now resolves it the same way it resolves an `args` element (via the
  `deps` map if still unresolved, else literal already-real text) and
  emits the seeding `cp`+`chmod` command with a real `inputDrvs` edge
  wired in when applicable.
- **A second real bug found and fixed**: `dispatch_defer`'s original
  eager/deferred split checked `record.key.is_none()` alone — but
  `ar`/`ranlib` are ALWAYS keyless regardless of `granularity`, so a
  `granularity = "module"` build's own `ar` step would have been
  wrongly routed onto the new eager path even when its `.o` inputs are
  still KEYED, text-stub-based batched compiles (module-granularity
  stays entirely on the OLD deferred-JSON collector, task #86's own
  scope). Fixed by also checking whether any dependency (`args` or
  `seed_from`) is currently a pending TEXT stub, forcing the old
  collector fallback in that case.
- **Verified end-to-end**: example 05's compiled variant (three eager
  compiles + a link step, no `ar`) builds and the resulting `prog`
  prints the correct sum; a real `cc`+`ar`+`ranlib` chain under the new
  eager path registers `ranlib` with a genuine `inputDrvs` edge to
  `ar`'s own derivation and a correct `cp`-seeded script — realizing it
  produces a genuinely valid archive (confirmed via `ar t`/`ar p`, not
  just "the build succeeded"). Existing fixtures re-verified unchanged:
  `ar-integration-test`, `collect-integration-test` (both still
  text-stub-only), example 06's compiled module-granularity variant
  (correctly still falls back to the old collector, correct program
  output), and the `Thunk{Drv}` multi-node fixture.

## Symlink-IR redesign: `Sandbox` mode's module-granularity path (task #86)

`Sandbox` mode's module-granularity path (`granularity = "module"`) is
also redesigned per the plan's own proposed "group-state" mechanism,
rather than staying on the old deferred-JSON collector: each batch
group (`record.key`) accumulates its members into ONE growing,
multi-output derivation, registered incrementally after EVERY member
compile.

- **New `group.rs` module**: `accumulate_and_register` reads a LOCAL
  copy of the group's current head derivation's own ATerm bytes
  (`.dyndrv/groups/<key>/head.drv`), re-parses it, appends the new
  member's own script line + named output, and re-registers the whole
  thing via `add_drv_to_store`. Each member's own caller-visible output
  is symlinked at the group's current head with a `#<output-name>`
  suffix — `stub::read_pending_symlink` now returns `(StorePath,
  OutputName)` instead of just `StorePath` to carry this.
- **Confirmed the SAME sandbox-visibility gap task #83's spike found
  applies here too**: a store path registered moments earlier by an
  EARLIER member's own invocation is NOT locally readable from inside
  the same sandbox — confirmed by direct reproduction (a real `cp:
  cannot stat`-equivalent failure the first time this was tried against
  the store path directly). Fixed the same way `Thunk{Drv}` mode's
  `write_drv_thunk` does: a LOCAL file this process itself controls,
  never a read-back through `/nix/store/<head>`.
- **Real bug found and fixed during verification**: `reparse_head`
  initially passed a hardcoded placeholder name to `parse_derivation_
  aterm` instead of the group's own deterministic name — since a
  parsed `Derivation`'s own `name` field is taken directly from that
  argument (not read back from the ATerm bytes), this silently
  RENAMED the group's derivation on every subsequent member. Confirmed
  via `nix derivation show`: a two-member group registered TWO
  differently-named derivations instead of accumulating onto one.
  Fixed by computing the group's name once from `key` and reusing it
  for both the fresh-group and reparse code paths.
- **`dyndrv-collect.rs`'s own Phase 7/8 needed fixing too**: every
  "solo unit → output `\"out\"`" shortcut assumed a solo eager unit's
  real output was always `"out"` — true for task #85's file-
  granularity case, false for a group member (always its own solo unit
  per `assign_units`' merge rule, but carrying a real NAMED output
  within its group's shared multi-output derivation). Added a
  `solo_output_name` map threaded through the per-unit render,
  cross-unit reference resolution, and final-tree placeholder
  substitution.
- **`wrapper.rs::dispatch_defer`'s `Sandbox` branch now splits three
  ways**: keyless + no pending-text-stub dependency → file-granularity
  eager (task #85, unchanged); keyed + no pending-text-stub dependency
  → group accumulation (task #86, new); anything else (a dependency
  still a pending text stub, meaning the group hasn't finished
  transitioning yet) → the old deferred-JSON collector, unchanged.
- **Verified end-to-end**: example 06's compiled module-granularity
  variant now registers ONE combined multi-output `dyndrv-batch-
  vendor.drv` for both `vendor/*.o` compiles (confirmed via `nix
  derivation show`: one name, two named outputs, both script lines
  present, in order) and the built `prog` produces the correct output.
  The "byte-identical to today's collector" claim the plan flagged as
  an open risk was NOT separately verified byte-for-byte (the group
  derivation's own script/env shape is structurally equivalent by
  construction — same per-member render logic reused from `group::
  append_member`, mirroring `render.rs::render_unit`'s own per-member
  loop — but no `cross_mode_check.rs`-style byte-diff was run against
  this specific case). Existing fixtures re-verified unchanged: example
  05 (byte-identical output path), `ar-integration-test`, `collect-
  integration-test`, the `Thunk{Drv}` multi-node fixture, and a real
  `nix develop`-driven `Rpc`-mode devShell session (`cc`+`ar`+`ranlib`+
  link, autoforce).

## What's still follow-on work

- Batching across the transitive thunk graph for `Thunk { format: Nix
  }`'s own autoforce path (nixgg's own `realise.Realise`) is unbuilt —
  only the single-thunk case works today.
- Re-measuring `real-package-patch-rebuild.sh`/
  `real-package-version-bump.sh` against the compiled path and updating
  `BASELINE.md` accordingly is still open (unblocked now — see
  `BASELINE.md`'s own "Real bug found and fixed while attempting the
  compiled-shim re-measurement" section for the `phases.split`
  `/nonexistent`-unwritable-in-a-real-sandbox bug this attempt found and
  fixed along the way, switching the placeholder to `/build/dyndrv-
  placeholder-out`).
- The symlink-IR redesign's own "byte-identical to today's collector"
  claim for module-granularity (flagged above) hasn't been verified via
  a direct byte-diff the way `cross_mode_check.rs` verifies solo-record
  cross-mode agreement — worth doing if module-granularity's own
  real-world adoption grows past the current toy fixture.
- No new eager-mode-specific Nix-level regression fixture exists yet
  for `granularity = "module"` (example 06's compiled variant is the
  only current coverage) — a dedicated `dyndrv-shim`-crate-level
  integration test (mirroring `ar-integration-test.nix`'s own pattern)
  would give tighter, faster-to-run coverage than a full example build.

