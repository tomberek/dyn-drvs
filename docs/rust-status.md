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
Fixed to match byte-for-byte at the time, but by hand-editing two
independently-written functions to agree — not yet a structural
guarantee, since nothing stopped a later edit to one from silently
drifting away from the other again (which is exactly the mechanism the
first mismatch demonstrates: it's not a hypothetical risk).

**Since made structural**: `record_to_derivation`, `render_member`,
`drv_thunk.rs::write_drv_thunk`, and `group.rs::append_member` were four
independently-written copies of this same setup_cmd/seed_from/tool-args/
`"; "` script-rendering pattern. All four now delegate to one function,
`render.rs::render_record_line`, for the single-record rendering step —
so agreement between the Rpc (`record_to_derivation`) and Sandbox
(`render_member`/`render_unit`) construction paths is compiler-enforced
(the same code runs either way), not re-verified by a one-off diff tool
or hand-kept in sync by convention. This is the concrete, mechanical
reason a TU registered by hand in a devShell and the same TU registered
inside a sandboxed `nix build` land at the same content-addressed store
path — not a separately-maintained equivalence test (nixgg's own
`tests/drv-equivalence.sh` exists specifically because ITS native/
sandbox code paths are NOT unified this way), a genuinely structural
property of sharing one construction path now, matching nixgg's own
`toolchainEnv`/`scrubWrapperEnv` model of "one string, fed into both
sides" rather than "two strings, kept in sync by testing."

Re-verified end to end after this unification via
`rust/dyndrv-shim/devshell-parity-test.sh` (Rpc-vs-Sandbox, `example/`'s
real TUs) and `try-it-out/examples/06-accelerate-stdenv-module.nix` with
`dyndrvShim` set (exercises `group.rs::append_member`'s own batched
path) — both pass, confirming the refactor is behavior-preserving.

## Cross-mode substitution, verified against a REAL project

The claim above was only ever checked via a synthetic `Record` diff.
`example/` (a small, real, checked-in C++ project — `main.cc`/`util.cc`/
`util.h`/`Makefile`, building `hello`) plus a new permanent fixture,
`rust/dyndrv-shim/devshell-parity-test.sh`, make it directly checkable
against genuine `make` output instead:

- Run `make` through `nix/lib/shim/devShell.nix`'s own `Rpc`-mode
  wrappers (no sandbox, no autoforce — just registration) against
  `example/`'s real sources, capture the resulting `main.o`/`util.o`
  symlinks' own `.drv` targets.
- Separately build `try-it-out/examples/08-accelerate-example-dir.nix`
  (the same sources wrapped with `dyndrv.accelerate.mkAcceleratedStdenv`,
  a real sandboxed `builder-rpc-v0` build) via `try-it-out/run-nix.sh`.
- Confirm the sandboxed build's own alt store contains those EXACT SAME
  `main.o.drv`/`util.o.drv` paths (`nix path-info`, a direct store
  lookup, not an inference from "both builds succeeded") — **confirmed
  true**: both paths registered byte-identical derivations for the
  identical logical compile.
- Confirm both sides' own final `hello` binary produces identical,
  correct output (`Hello from nixgg:3`).

**A genuine, previously-undetected bug found along the way**: this was
the first C++ project ever exercised through `mkAcceleratedStdenv`/
`devShell.nix` (every prior example used plain C) — and it immediately
surfaced that C++ builds were never actually being accelerated at all.
nixpkgs' own `gcc-wrapper` setup hook unconditionally exports
`CXX=g++` (the real compiler's bare name), running AFTER this codebase's
own `env.CXX = "${wrapperDir}/bin/cc"` override is already set — setup
hooks run at the START of a sandboxed build, before `buildPhase`, so the
override was silently clobbered the moment any C++ TU's build actually
ran, falling through to the real, unshimmed `g++` on `$PATH` instead
(never registering a dynamic derivation for the link step at all).
Separately confirmed that simply reusing the existing `cc`-only shim for
C++ wouldn't have worked either way: `stdenv.cc` provides `cc`/`c++` as
genuinely DIFFERENT binaries (linking a C++ `.o` via plain `cc` fails
outright — `"undefined reference to `std::cout'"` — without `-lstdc++`,
which only `c++`'s own wrapper adds by default). Fixed by adding a
SEPARATE `cxxShim` (same `command = "cc"` dispatch, just `realCommand`
pointed at the real `c++`) to both `mkAcceleratedStdenv.nix` and
`devShell.nix`, installed under `c++`/`g++` mirroring the existing
`cc`/`gcc` pair exactly.

The link step's own `.drv` is NOT expected to (and does not) match
byte-for-byte between the two paths — `Rpc` mode wires real `Built`
`inputDrvs` edges to `main.o.drv`/`util.o.drv` via CA placeholders,
while `Sandbox` mode's own per-unit render resolves the SAME
cross-references to literal `Opaque` store-path text instead (a
pre-existing, unrelated difference in how each mode's own final-node
construction resolves a dependency reference — not a bug, and not
something this check claims should match). Only the REAL translation
units (`main.o`, `util.o`) are expected to be byte-identical, and are.
Curiously, Nix's own CA-derivation resolution mechanism still resolves
BOTH differently-shaped `hello.drv`s to the exact same final realized
output path when actually built — confirmed by direct reproduction, not
required by this fixture's own assertions, but a reassuring sign of just
how much further this substitution property extends in practice.

## Cross-mode substitution, proven as REAL reuse, not just hash agreement

Both fixtures above prove the SET of registered TU drv-hashes matches
between `Rpc` mode and `Sandbox` mode — but neither ever builds anything
through BOTH paths against the SAME store, so neither can distinguish
"these two modes would produce the same drv" from "a real substitution
event happens when one mode's build follows the other's" — nixgg's own
`tests/cross-mode-reuse.sh` exists specifically to prove the latter,
stronger property, and dyndrv had no equivalent until now
(`rust/dyndrv-shim/cross-mode-reuse.sh`).

**The missing mechanism, found by direct reproduction**: `Rpc` mode's
`BuilderRpcClient::connect_from_env()` always connects to the AMBIENT
system daemon — there was no way to point a devShell-side registration
at the SAME isolated alt store `try-it-out/run-nix.sh`'s own sandboxed
side drives, so the two paths had no shared store a real substitution
could even happen in. Fixed by running a separate, PRIVATE `nix daemon
--socket-path <sock> --store 'local?root=<dir>'` (a real, documented
Nix flag already present on the `patched-nix.nix` build this repo
depends on for `builder-rpc-v0` — not a workaround) and pointing the
native side's `NIX_REMOTE` at that socket while pointing `DYNDRV_STORE`
at the same directory the sandboxed side drives.

**Two things confirmed necessary by direct reproduction, not assumed**:
1. The private store must be seeded with the devShell wrapper's own
   closure (`nix copy`) BEFORE registering anything — a compile's own
   `record.srcs` declares coreutils/`stdenv.cc`/etc. as real store-path
   references, and `add_drv_to_store`'s reference-scanning requires
   each to already be a valid object in the TARGET store. Without this,
   the very first registration attempt failed outright ("path ... is
   not valid").
2. The native side's two TU drvs must be explicitly `nix-store
   --realise`d against the private daemon (mirroring `NIXGG_AUTOFORCE=1`/
   `nixgg force`) BEFORE the sandboxed build runs — confirmed by direct
   reproduction that skipping this makes the whole check vacuous: the
   sandboxed build's own log then legitimately shows `building
   'main.o.drv'`/`'util.o.drv'` (a correct realize-for-the-first-time
   event, not a substitution failure), so "absent from the building
   log" only means anything once there's real content in the store
   FIRST for the sandboxed side to find instead.

With both steps in place, a full sandboxed `nix build` of
`08-accelerate-example-dir.nix` against that same store shows NEITHER
TU drv in its own `building '...'` lines — genuine reuse, not matching
hashes that happen to never get exercised. Verified this assertion is
meaningful (not a false positive from the two drvs simply being
irrelevant) by a negative-control run: skipping the realize step
reproduces the exact `building 'main.o.drv'`/`'util.o.drv'` lines the
real run's own absence is checked against.

**A known, documented gap, not silently glossed over**: nixgg's own
`cross-mode-reuse.sh` also confirms the sandbox build's own drv graph
references the native-built paths via `inputDrvs`. That check doesn't
map onto dyndrv's architecture — the final submitted tree copies bytes
via resolved PLACEHOLDER TEXT at script-generation time (`graph/
compile.nix`'s bash port of `DownstreamPlaceholder::unknownCaOutput`,
`dyndrv-collect.rs`'s Rust equivalent), not `inputDrvs` edges, confirmed
directly (`nix derivation show -r` on the final tree never lists
`main.o.drv`/`util.o.drv`, even on a run where they WERE substituted).
The "absent from the building log, but only meaningful after forcing
real content to exist first" structure above is the correct substitute
for dyndrv's own architecture, not a lesser version of nixgg's check.

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
  Existing fixtures re-verified unchanged: example 05 (byte-identical
  output path), `ar-integration-test`, `collect-integration-test`, the
  `Thunk{Drv}` multi-node fixture, and a real `nix develop`-driven
  `Rpc`-mode devShell session (`cc`+`ar`+`ranlib`+link, autoforce).
- **Byte-diff verified (task #88)**: the plan's own "byte-identical to
  today's collector" claim, flagged as an open risk, is CONFIRMED —
  a throwaway check binary (`group-render-check.rs`, built, run,
  deleted, mirroring this session's own `compute-drv-check.rs`/
  `cross_mode_check.rs` discipline) built the identical two-member
  `vendor/lib_a.o`+`vendor/lib_b.o` batch group both ways: once through
  the OLD collector's own `render.rs::render_unit` (the SAME code path
  `dyndrv-collect.rs`'s Phase 7 uses for a real, still-deferred batch),
  once through the NEW eager path's `group::append_member`, called
  twice in sequence exactly as `accumulate_and_register` would. The two
  resulting `Derivation`s' printed ATerm bytes were byte-for-byte
  IDENTICAL (670 bytes, exact match) — confirming the incremental,
  per-invocation accumulation produces the SAME content-addressed
  result as the old collector's single end-of-build merge, for this
  representative case.

## `Thunk{Nix}`'s multi-thunk graph: built, verified (task #90)

`Thunk{format: Nix}`'s own autoforce path only ever handled a single
thunk. Now resolved, mirroring `Thunk{Drv}`'s own multi-node story
(tasks #77-82) but structurally simpler:

- **Verified first, not assumed**: a throwaway two-derivation spike
  confirmed a plain Nix `${import ./dep.nix}` interpolation inside a
  builder script is sufficient — `nix build --file` on a thunk that
  imports another correctly builds BOTH derivations in one call. No
  separate registration-tree walk is needed the way `Thunk{Drv}` mode's
  own `register_drv_tree` requires — a raw `.drv` file has no
  `import`-equivalent mechanism of its own; a Nix expression does,
  natively.
- **`thunk::resolve_nix_thunk_dependency`** mirrors `drv_thunk::
  resolve_drv_thunk_dependency`'s own "check the target symlink's
  parent directory name" convention, for `.dyndrv/thunks/` instead of
  `.dyndrv/thunks-drv/`. `record_to_thunk_expr` now takes a `deps` map
  and substitutes a real `${import <path>}` interpolation for any
  `args`/`seed_from` reference that resolves to an earlier thunk in the
  same graph.
- **Real bug found and fixed along the way**: the original single
  blanket string-escape pass ran over the WHOLE script, including the
  newly-inserted `${import ...}` syntax itself — escaping its own `$`
  into `\$`, which Nix never expands, so the derivation's script
  contained the LITERAL text `${import ./dep.nix}` instead of the
  dependency's real path, and the builder's own `/bin/sh` failed with
  "bad substitution." Fixed with a `NixStringBuilder` that tracks
  literal vs. interpolation segments separately, only escaping the
  literal ones.
- **A second, previously-latent bug found and fixed**: `stub::is_
  pending` never recognized a `Thunk{Nix}` symlink (`.dyndrv/thunks/
  *.nix`) at all — only `Thunk{Drv}`'s own `.dyndrv/thunks-drv/`
  sibling. Without this, `rewrite_argv_element` would have staged a
  `.nix` thunk symlink's own literal Nix-expression TEXT as if it were
  real object content, corrupting a dependent's script — the same shape
  of bug task #78 found for `Thunk{Drv}` mode, just never checked for
  this mode until now.
- **Verified end-to-end** with a new permanent regression fixture,
  `rust/dyndrv-shim/thunk-nix-multinode-test.sh` (mirrors `drv-thunk-
  multinode-test.sh`'s own structure): two deferred `.nix`-thunk
  compiles, `DYNDRV_AUTOFORCE=1` on just the archive step correctly
  realizes the whole graph via one `nix build --file` call, confirmed
  via the archive's own rendered thunk containing 2 real `${import
  ...}` references (not empty/literal text), and the resulting `liba.a`
  links and runs correctly (11+22=33). Existing `Thunk{Drv}` fixture,
  `ar-integration-test`, `collect-integration-test`, and examples 05/06
  all re-verified unchanged.

## `harmonia-*`/`nix-builder-rpc-client`: un-vendored, real git dependencies now

`rust/vendor/{harmonia,nix-builder-rpc-client}` (a local copy of both,
checked into this repo) is gone. Confirmed by direct diff against a
real cargo checkout that every one of the 14 vendored `harmonia-*`
subcrates was already byte-identical to upstream `nix-community/
harmonia` at the exact commit (`b7c7777`) this repo had pinned — so
nothing was lost switching to a real `git` dependency (`rev`-pinned,
not `branch`-pinned: harmonia's own `main` HEAD has genuinely diverged
incompatibly since that commit, confirmed directly against a fresh
clone — `print_derivation_aterm`'s own generic bound changed).

`nix-builder-rpc-client` couldn't just point at `pdtpartners/nix-ninja`
directly — it carries two small, additive local methods
(`add_to_store_flat`, `is_valid_path`) not present upstream, confirmed
by direct diff against nix-ninja's own repo at the same pinned commit.
Both were upstreamed as a real PR
(https://github.com/pdtpartners/nix-ninja/pull/57); until/unless it
merges, `dyndrv-shim/Cargo.toml` points at a personal fork's branch
carrying them.

**A real, structural gotcha found by direct reproduction, not
theoretical**: `nix-builder-rpc-client`'s own `Cargo.toml` declares its
harmonia deps as `branch = "main"` (nix-ninja's own workspace
convention) — a plain `cargo generate-lockfile` against dyndrv-shim's
own `rev`-pinned harmonia deps resolved TWO different, incompatible
copies of `harmonia-store-aterm` (one per pinning strategy) and failed
to compile. Cargo's `[patch]` mechanism can't fix this cleanly here
(can't patch a source against itself). The actual fix: a SEPARATE
branch on the personal fork (`dyndrv-consumption`, distinct from the
PR branch) where `nix-builder-rpc-client`'s own `Cargo.toml` is edited
to pin harmonia via the same exact `rev`, not inherited `branch =
"main"` — so both dyndrv-shim's own direct deps and this crate's
transitive ones resolve to one identical commit.

`rust/dyndrv-shim.nix`'s own `postPatch` (which used to `cp -r` the
vendor directories into place before a build) is gone too —
`buildRustPackage`'s `cargoLock.outputHashes` (keyed `"<name>-
<version>"`, one entry per distinct git commit referenced, covering
every OTHER crate from the same repo+rev automatically) is all a git
dependency needs.

Re-verified end-to-end after the switch: `cargo build`/`test`/`clippy`
clean, a full `nix build -f rust/dyndrv-shim.nix` succeeds, and
`devshell-parity-test.sh`/example 06 (compiled, batched)/`cross-mode-
reuse.sh` all still pass, each landing on the exact same store-path
hashes as before the migration.

## Accelerating a real component of Nix's own build (nix-util)

New example, `try-it-out/examples/09-accelerate-nix-util.nix`: points
`dyndrv.accelerate.mkAcceleratedStdenv` at NixOS/nix's own `nix-util`
component (~76 real `.cc` translation units, meson+ninja) — the first
time this accelerator has run against a meson project, a multi-
component nixpkgs scope, or anything at this scale. Getting there
surfaced five real, previously-undiscovered bugs, all now fixed (and
regression-tested via `nix/tests/run-tests.sh` + the compiled shim's
own `cargo test`/`clippy`, unchanged before/after):

1. **Stub self-reference substitution** (`collectStubs.nix`'s
   `dyndrv_render_member`, and `render.rs`'s `render_member`): a
   compile's own `-MQ <objpath>` alongside `-o <objpath>` (ninja/meson
   both emit this pair, naming the IDENTICAL literal path) was
   substituted with the generic cross-reference token instead of
   `$out`/`own_out_var`, since a compile's own output path is itself a
   discovered stub the moment its `.o` gets written. Fixed by checking
   "is this argv element MYSELF" before the generic same-unit lookup,
   in both the bash and Rust renderers.
2. **`../`-escaping tree staging** (`wrapCommand.nix`'s discoverTree
   staging loop, and `wrapper.rs`'s `stage_tree`): meson always
   compiles from a build subdirectory one level below the source root
   (`-c ../hash.cc`), a path a Nix store tree can't represent directly
   (`treeDir/../hash.cc` resolves OUTSIDE `treeDir` at the filesystem
   level, so `nix store add`/`add_to_store_nar` never see it). Fixed
   by staging into a nested `.dyndrv-cwd/` chain (depth = the max
   leading-`../` count for that invocation) and having the eventual
   builder `cd` into the matching depth before running the real
   command — carried as a new `chdir` record field (not baked into
   `setupCmd` as a bare `cd`, which would leak across a merged unit's
   own sibling members).
3. **Missing wrapper-env-var store-path declarations**
   (`mkAcceleratedStdenv.nix`'s `toNode`): nixpkgs' cc-wrapper/
   bintools-wrapper setup hooks inject extra flags (e.g. boost's own
   `-isystem <path>/include`) via env vars (`NIX_CFLAGS_COMPILE`,
   `NIX_LDFLAGS`, ...), not literal argv — invisible to the old argv-
   only store-path scan, so `#include <boost/format.hpp>` failed even
   though boost IS a real `propagatedBuildInput`. Fixed by capturing
   an allowlist of these vars (bare + `stdenv.cc.suffixSalt`-suffixed
   forms, PLUS the `NIX_CC_WRAPPER_TARGET_HOST`/`NIX_BINTOOLS_
   WRAPPER_TARGET_HOST`-style role markers `add-flags.sh` itself needs
   present before it copies the bare var into the salted one gcc
   actually reads) and re-exporting them in `setupCmd`, and extending
   the store-path scan to also cover their VALUES (via
   `builtins.split`, since `builtins.match` only returns the first
   match in a string with many concatenated `-isystem` flags). Had to
   also exclude the derivation's OWN self-referential CA output
   placeholder (e.g. `NIX_LDFLAGS`'s own `-rpath $out/lib`, already
   substituted to placeholder text by env-construction time) from
   that scan — a `*.drv`-suffixed basename is never a legitimate
   `srcs` reference, so filtering on that suffix excludes it safely.
4. **Missing `.dyndrv-cwd` directory**: the per-file staging loop only
   ever created directories via each staged file's own `dirname` — if
   an invocation's own `../`-depth came entirely from files OTHER than
   the one being compiled (e.g. `checked-arithmetic.cc` itself has no
   `../` prefix, but sibling `-I../include` flags still drove
   `up_depth = 1` for the whole invocation), nothing ever staged
   AT that nesting level, so the directory itself was never created —
   the builder's own unconditional `cd .dyndrv-cwd/` then failed
   outright. Fixed by unconditionally creating the full nested chain
   up front, before the per-file staging loop runs.
5. **Missing output directory for `-MF` dependency-file writes**: a
   real (unaccelerated) meson/ninja build always creates its whole
   build-directory skeleton up front, during `configurePhase`, before
   any compiler runs — so a compile's own `-MF <relative-dir>/<file>.
   d` output can always assume its parent directory exists. This
   accelerator's staged tree, by contrast, only ever contained what
   the discovery scan found as an INPUT — an output-only directory
   nothing `-include`s (confirmed via `library-versions.cc`'s own
   `-MF libnixutil.so.2.36.0.p/library-versions.cc.o.d`) was never
   created, so the compile failed writing the `.d` file. Fixed by
   pre-creating every non-flag argv element's own dirname (at the
   correct nesting depth) generically, covering `-MF`/`-MT`/`-o`-style
   relative outputs without needing to special-case dependency-file
   generation specifically.

With all five fixed, all 76 translation units now compile and LINK
(`[76/76] Linking target libnixutil.so.2.36.0`) — the first time this
accelerator has built a real, substantial multi-file component all
the way to a link step. The link itself currently fails with
`undefined reference to 'pow'` under LTO (`-flto=auto`, meson's
`release` buildtype default) — confirmed via direct A/B testing NOT
to be caused by any of the five fixes above: both a unity-build and a
non-unity, fully UNACCELERATED build of the identical component link
successfully. The gap is specific to LTO combined with each `.o`
being compiled and registered as a SEPARATE, isolated CA derivation
rather than one shared ninja invocation (GCC's LTO partitioning
across the 76 separately-compiled objects resolves `std::pow` calls
in `util.cc`/`linux/cgroup.cc` differently than when ninja compiles
and links them all within one build tree) — open as follow-on work,
see below.

## What's still follow-on work

- The `nix-util` LTO/`pow` linking gap above: still unresolved.
  Candidate next steps: try disabling LTO for real this time (`meson`
  reads `-Db_lto=...` last-wins, and `packaging/components.nix`'s own
  `preConfigure` unconditionally re-appends `-Db_lto=true` for
  `release`/`minsize` build types AFTER any caller-supplied override,
  so a plain `mesonFlags` addition doesn't actually take effect — an
  `overrideAttrs` on `preConfigure` itself, or a `buildType` override,
  would be needed to genuinely test LTO-off); or investigate whether
  explicitly linking `-lm` in the final link unit's own record
  resolves it, without waiting to fully explain the GCC LTO
  partitioning difference.
- No new eager-mode-specific Nix-level regression fixture exists yet
  for `granularity = "module"` (example 06's compiled variant is the
  only current coverage) — a dedicated `dyndrv-shim`-crate-level
  integration test (mirroring `ar-integration-test.nix`'s own pattern)
  would give tighter, faster-to-run coverage than a full example build.

