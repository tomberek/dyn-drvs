# Rust status

`rust/dyndrv-shim` is a compiled binary that replaces the `nix`/`jq` CLI
shellouts `wrapCommand.nix`/`collectStubs.nix` otherwise use with a raw
Nix daemon worker-protocol client, collapsing each shim invocation to
one process. It has two entrypoints, both built via `rust/dyndrv-shim.nix`
(`rustPlatform.buildRustPackage`):

- `dyndrv-shim` (`src/bin/dyndrv-shim.rs`): per-invocation `cc`/`ar`/
  `ranlib` shimming.
- `dyndrv-collect` (`src/bin/dyndrv-collect.rs`): the end-of-`buildPhase`
  whole-tree resolution pass for `Sandbox` mode's deferred (text-stub)
  path.

## What's built

Four interoperating modes, auto-detected from the environment
(`src/mode.rs`'s `detect()`), sharing one `Record -> Derivation`
construction path so a translation unit (TU) registered one way and the
same TU registered another way land at the identical content-addressed
store path (see "Cross-mode substitution" below for what's proven and
how):

- **`Sandbox`**: inside a `builder-rpc-v0` sandbox (`NIX_REMOTE` and
  `NIX_BUILD_TOP` both set). A keyless record with no dependency still
  pending as a text stub registers its own derivation eagerly
  (`add_drv_to_store`, legal inside a `builder-rpc-v0` sandbox — only
  `BuildPaths`/realization is restricted there) and symlinks the
  caller-visible output straight at the registered `.drv`'s store path.
  A keyed record (part of a `granularity = "module"` batch group) instead
  accumulates into that group's growing multi-output derivation
  (`src/group.rs`'s `accumulate_and_register`), re-registered after every
  member. Anything still depending on an unresolved text stub falls back
  to the older deferred-JSON collector, resolved at the end of
  `buildPhase` by `dyndrv-collect`. Wired into `wrapCommand.nix` as
  `toNodeCompiled`.
- **`Rpc`**: outside any sandbox (an ordinary shell/devShell) — registers
  the real `Derivation` immediately over an unrestricted daemon
  connection (no deferral needed). `DYNDRV_AUTOFORCE=1` additionally
  realizes it (`build_paths`) and byte-copies the result back over the
  caller-visible path. `nix/lib/shim/devShell.nix` wires this into an
  ordinary `nix develop` shellHook.
- **`Thunk { format: Nix }`**: no `ca-derivations`/`dynamic-derivations`
  requirement at all — writes a content-addressed `.nix` expression file
  to `.dyndrv/thunks/<id>.nix` and symlinks the caller-visible output at
  it. No daemon call for the write itself. A multi-thunk graph is wired
  via `${import <dep-thunk>}` interpolation directly in the generated Nix
  expression (`src/thunk.rs`'s `record_to_thunk_expr`) — a plain `nix
  build --file` on the root thunk builds the whole graph in one call, no
  separate registration-tree walk needed. `DYNDRV_AUTOFORCE=1` runs that
  one `nix build --file` and byte-copies the result back.
- **`Thunk { format: Drv }`** (opt-in via `DYNDRV_THUNK_FORMAT=drv`):
  writes a real, ATerm-serialized `.drv` file directly to
  `.dyndrv/thunks-drv/<id>.drv`, via the same
  `harmonia_store_aterm::print_derivation_aterm` printer `Rpc` mode uses
  internally, entirely without a daemon call. A multi-node graph wires
  real `inputDrvs` edges across thunks (`src/drv_thunk.rs`). Realizing a
  thunk graph needs one daemon round-trip regardless of graph size:
  `src/thunk_tail.rs`'s `register_drv_tree` parses each `.drv`'s ATerm to
  discover its `inputDrvs`, recurses bottom-up registering each node via
  `add_to_store_text` (the same content-addressing method
  `add_drv_to_store` uses internally, so paths match `inputDrvs`
  references exactly), then issues one final `nix-store --realise` on the
  root. `.drv` files at an arbitrary filesystem path can't be realized
  directly (Nix's builder/scheduler only operates on already-registered
  store paths) — this is why the `--add`/register step exists even though
  the write path itself is daemon-free.

## Cross-mode substitution

`Rpc` mode's `drv.rs::record_to_derivation`, `Sandbox` mode's
`render.rs::render_member`/`render_unit`, `Thunk{Drv}`'s
`drv_thunk.rs::write_drv_thunk`, and `group.rs::append_member` are four
independently-written call sites that all need to agree on exactly how a
single `Record` renders into ATerm bytes. They now all delegate to one
function, `render.rs::render_record_line`, for that single-record
rendering step — so agreement between the `Rpc` and `Sandbox`
construction paths is compiler-enforced (the same code runs either way),
not maintained by convention or re-verified by a one-off diff tool. This
is the concrete, mechanical reason a TU registered by hand in a devShell
and the same TU registered inside a sandboxed `nix build` land at the
same content-addressed store path.

This is verified at three levels, each a permanent fixture:

- **Unit level**: `render.rs`'s `cross_mode_tests` module (`cargo test`,
  run in CI) feeds synthetic `Record` shapes through both
  `record_to_derivation` and `render_member` and asserts byte-identical
  ATerm output. Runs on every CI push.
- **Real-project level**: `rust/dyndrv-shim/devshell-parity-test.sh` (and
  `devshell-parity-smalllib-test.sh`) build `example/` (a small, real,
  checked-in C++ project — `main.cc`/`util.cc`/`util.h`/`Makefile`)
  through `nix/lib/shim/devShell.nix`'s `Rpc`-mode wrappers, separately
  build the same sources via `try-it-out/examples/08-accelerate-example-dir.nix`
  (a real sandboxed `builder-rpc-v0` build), and confirm both sides
  register byte-identical `main.o.drv`/`util.o.drv` paths (via `nix
  path-info`, a direct store lookup) and produce identical, correct
  `hello` output. The link step's own `.drv` is *not* expected to match
  byte-for-byte between the two paths (each mode resolves cross-unit
  references differently at that stage — `Rpc` mode wires `Built`
  `inputDrvs` edges via CA placeholders, `Sandbox` mode's per-unit render
  resolves the same references to literal `Opaque` store-path text). Only
  the real translation units are required to match, and do.
- **Reuse level**: `rust/dyndrv-shim/cross-mode-reuse.sh` proves an
  actual substitution event, not just matching hashes: it runs a
  private, isolated `nix daemon --socket-path <sock> --store
  'local?root=<dir>'`, seeds it with the devShell wrapper's closure (`nix
  copy`), registers+realizes two TU drvs from the `Rpc` side against that
  private store, then runs a full sandboxed `nix build` of
  `08-accelerate-example-dir.nix` against the *same* store and confirms
  neither TU drv appears in the build's own `building '...'` lines — a
  negative-control run (skipping the realize step) confirms this
  assertion is meaningful, not vacuous, by reproducing those exact lines
  when the TUs are genuinely being built for the first time.

Both `Rpc` and `Sandbox` C++ support depends on a separate `cxxShim`
(same `command = "cc"` dispatch as the C shim, `realCommand` pointed at
the real `c++` instead of `cc`) installed under `c++`/`g++`, mirroring
the existing `cc`/`gcc` pair — `stdenv.cc` provides `cc`/`c++` as
genuinely different binaries (linking a C++ object via plain `cc` fails
without `-lstdc++`, which only `c++`'s own driver adds by default).
`mkAcceleratedStdenv.nix` and `devShell.nix` both wire this in.

One architectural difference from dyndrv's dependency model: dyndrv's
final submitted tree resolves cross-unit references via resolved
placeholder text at script-generation time (`graph/compile.nix`'s bash
port and `dyndrv-collect.rs`'s Rust equivalent), not `inputDrvs` edges —
`nix derivation show -r` on a final submitted tree never lists the
per-TU `.drv`s directly, even when they were substituted from the store.
This is a deliberate difference from nixgg's own `inputDrvs`-edge
approach, not a gap.

## Multi-node / group architecture, by mode

- **`Sandbox`, file granularity (default)**: each keyless, non-batched
  compile registers its own solo derivation eagerly and symlinks its
  output directly at the registered store path
  (`stub::read_pending_symlink`). A freshly-`add_drv_to_store`d path is
  *not* locally `stat`-able from inside the same sandboxed builder that
  just registered it (a `builder-rpc-v0` sandbox mount-namespace
  limitation, not a registration failure) — `dyndrv-collect`'s discovery
  pass therefore uses `DirEntry::file_type()` (no dereference) rather
  than `Path::is_file()`/`is_dir()` (which follow symlinks and would
  silently miss every eager stub) to find these.
- **`Sandbox`, module granularity**: each batch group (keyed by
  `record.key`) accumulates its members into one growing, multi-output
  derivation. `group::accumulate_and_register` reads a *local* copy of
  the group's current head derivation's ATerm bytes
  (`.dyndrv/groups/<key>/head.drv`), re-parses it, appends the new
  member's script line and named output, and re-registers the whole
  thing. Each member's caller-visible output is symlinked at the group's
  current head with a `#<output-name>` suffix. The same
  sandbox-visibility limitation applies here too — the head is always
  read back from the local file this process itself wrote, never through
  `/nix/store/<head>`. `wrapper.rs::dispatch_defer` routes a record
  keyless-with-no-pending-stub-dependency to the file-granularity eager
  path, keyed-with-no-pending-stub-dependency to group accumulation, and
  anything still depending on an unresolved text stub to the old
  deferred-JSON collector (this last case matters because `ar`/`ranlib`
  are always keyless regardless of granularity, so a module-granularity
  build's `ar` step must stay on the old collector until its `.o` inputs
  — still keyed, batched compiles — are actually resolved). Verified
  byte-identical to the old (batch-then-render-once) collector output for
  a representative two-member group.
- **`Thunk{format: Nix}`**: multi-thunk graphs chain via literal
  `${import <dep>}` Nix interpolation, generated by a `NixStringBuilder`
  that tracks literal-vs-interpolation script segments separately (so a
  blanket string-escape pass never mangles the interpolation syntax
  itself).
- **`Thunk{format: Drv}`**: multi-node graphs chain via real `inputDrvs`
  edges computed locally (`drv_thunk.rs::compute_drv_store_path`, via
  `harmonia_store_content_address::make_store_path_from_ca` — mirrors
  what `add_drv_to_store`'s server side computes internally, with no
  daemon call). `stub::is_pending` recognizes a `Thunk{Drv}` (and
  `Thunk{Nix}`) thunk symlink as pending, alongside `Sandbox`'s text stub
  and `Rpc`/eager-`Sandbox`'s store-path symlink, so `rewrite_argv_element`
  never stages a thunk symlink's own file content as if it were real
  object content.
- **Regression fixtures covering this architecture**:
  `rust/dyndrv-shim/ar-integration-test.nix`/`collect-integration-test.nix`
  (text-stub-only `Sandbox` path), `try-it-out/examples/05-accelerate-stdenv.nix`
  (file granularity), `06-accelerate-stdenv-module.nix` (module
  granularity / group accumulation), `rust/dyndrv-shim/drv-thunk-multinode-test.sh`
  and `thunk-nix-multinode-test.sh` (multi-node `Thunk{Drv}`/`Thunk{Nix}`
  graphs, plain shell scripts since `Thunk` mode's whole point is working
  outside any sandbox), and `devshell-parity-test.sh`/`cross-mode-reuse.sh`
  (`Rpc` vs `Sandbox`, described above).

## `harmonia-*`/`nix-builder-rpc-client`: real git dependencies, not vendored

`rust/dyndrv-shim/Cargo.toml` depends on `harmonia-store-derivation`/
`-store-path`/`-store-content-address`/`-store-aterm`/`-utils-hash`
(`git`, `rev`-pinned to a specific `nix-community/harmonia` commit — `rev`
rather than `branch`, since harmonia's own `main` has since diverged
incompatibly) and `nix-builder-rpc-client` (`git`, pointed at a personal
fork's `dyndrv-consumption` branch rather than `pdtpartners/nix-ninja`
directly). Two reasons for the fork:

1. It carries two small, additive local methods (`add_to_store_flat`,
   `is_valid_path`) not yet in `pdtpartners/nix-ninja` upstream — see
   [nix-ninja#57](https://github.com/pdtpartners/nix-ninja/pull/57).
   Switch to upstream directly once/if that merges.
2. Its `Cargo.toml` pins harmonia to the *same* exact `rev` this crate's
   own direct harmonia deps use, instead of inheriting nix-ninja's
   workspace-wide `branch = "main"` — resolving two differently-pinned
   copies of the same harmonia crate fails to compile, so both paths must
   agree on one commit.

`rust/dyndrv-shim.nix` needs no vendor-copy `postPatch` step —
`buildRustPackage`'s `cargoLock.outputHashes` (one entry per distinct git
commit referenced, covering every other crate from the same repo+rev
automatically) is all a git dependency needs.

## NixOS/nix acceleration results

`try-it-out/examples/09-accelerate-nix-util.nix` through
`16-accelerate-nix-cli.nix` point `dyndrv.accelerate.mkAcceleratedStdenv`
at successive components of NixOS/nix's own build (`nix-util`,
`nix-store`, `nix-fetchers`, `nix-expr`, `nix-flake`, `nix-main`,
`nix-cmd`, and finally `nix-cli` bracketing all 8 core components plus 6
`-c` API shims in one scope). This is proven to work end to end: all 378
translation units across every component compile, link, install, and fix
up correctly, and the resulting `nix` binary runs correctly (`nix
--version` reports the expected version) with all 12 conventional
entry-point symlinks (`nix-build`, `nix-env`, `nix-store`, `nix-shell`,
...) present. See those examples directly for the up-to-date mechanism;
notable durable facts this required:

- A compile's own `-MQ <objpath>` alongside `-o <objpath>` names the
  compile's own output path — both the bash and Rust renderers
  (`collectStubs.nix`'s `dyndrv_render_member`, `render.rs`'s
  `render_member`) check "is this argv element myself" before the
  generic cross-unit reference lookup, or the self-reference gets
  substituted with the wrong placeholder.
- meson compiles from a build subdirectory one level below the source
  root (`-c ../hash.cc`), a path a Nix store tree can't represent
  directly. `wrapCommand.nix`'s discoverTree staging and `wrapper.rs`'s
  `stage_tree` stage into a nested `.dyndrv-cwd/` chain (depth = the max
  leading-`../` count for the invocation) and the builder `cd`s into the
  matching depth before running the real command (a `chdir` record
  field, not baked into `setupCmd`, so it doesn't leak across a merged
  unit's sibling members). The chain is created unconditionally up
  front, not lazily per staged file, since an invocation's `../`-depth
  can come from flags alone with no file actually staged at that depth.
- nixpkgs' cc-wrapper/bintools-wrapper setup hooks inject extra flags
  (e.g. `-isystem <path>/include`) via env vars
  (`NIX_CFLAGS_COMPILE`/`NIX_LDFLAGS`/...), not argv — `toNode` captures
  an allowlist of these vars (bare and `suffixSalt`-suffixed forms) and
  scans their *values* for `/nix/store/` references too, excluding any
  `*.drv`-suffixed self-referential CA output placeholder from that scan.
- A build-tool that expects its own output directories to already exist
  (e.g. a compile's `-MF <dir>/<file>.d`) needs those directories
  pre-created generically for every non-flag argv element's own dirname,
  not just special-cased for dependency-file generation.
- Linking many separately-registered, per-TU CA derivations under LTO
  (`-flto`) can drop symbols a single monolithic ninja invocation would
  have resolved via cross-TU LTO partitioning — `libm` (`pow`) and, for
  a plain `cc`-invoked (not `c++`-invoked) link, `libstdc++` (`operator
  new`/`delete`, `__cxa_throw`, RTTI vtables) both need to be appended
  explicitly (`-lm`/`-lstdc++`) to any link invocation containing
  `-flto`. Both `mkAcceleratedStdenv.nix`'s `argvForCc'` and Rust
  `cc.rs`'s `cc_to_node` carry this fix.
- `mkAcceleratedStdenv.nix`'s bash `toNode` resolves the real compiler
  via `DYNDRV_REAL_COMMAND` (exported by `wrapCommand.nix`'s generated
  wrapper script, read back via `builtins.getEnv`, falling back to the
  hardcoded `realCc` only if unset) rather than a single baked-in
  `realCc` string — the same `toNode` text is embedded verbatim into
  both the `cc` and `c++` wrapper scripts, so a hardcoded compiler name
  would silently downgrade every `c++`/`g++` invocation to plain `cc`
  (which never auto-links `libstdc++`). The Rust path (`cc.rs`'s
  `cc_to_node`) is parameterized by its own `real_cc` argument directly
  and never had this issue.
- meson bakes phase 1's own placeholder `$out` directly into the text of
  any `.pc` file it installs (the `prefix=` line) — this only matters
  once a later component actually consumes another component's
  installed pkg-config metadata (as `nix-cli` does, via
  `-whole-archive.pc` files). `nix/lib/phases/split.nix`'s `postFixup`
  hook (must run there, not the earlier `dyndrvRestoreOutput` phase,
  since nixpkgs' own `_multioutDevs` hook relocates `.pc` files during
  `fixupPhase`'s `preFixupHooks`) rewrites the placeholder to `$out`
  wherever a `.pc` file ends up.
- `overrideAttrs` on a single component in a multi-component
  `nixSrcFlake.lib.makeComponents` scope does not propagate
  `DYNDRV_BYPASS` to that component's own dependencies resolved through
  the same scope — bracket every component that needs it via
  `overrideScope`, not just the top-level one being built (see example
  10's `scoped` binding).
- `ninja -t deps` (not just a text scan of `build.ninja`) is needed to
  discover `../`-relative dependencies tracked only in ninja's binary
  `.ninja_deps` log — a C23 `#embed` directive (used by `nix-store`'s
  `local-store.cc`) is tracked by gcc's `-MD` depfile exactly like an
  `#include`, but never appears as literal text in `build.ninja` itself.
  `shim.collectStubs`'s carry-forward scan runs both the `build.ninja`
  text scan and `ninja -t deps` as complementary sources, and every
  command in that carry-forward subshell is best-effort (`|| true`) —
  `stdenv`'s own `set -eu -o pipefail` means a legitimately-empty source
  (e.g. no `../`-relative deps at all) would otherwise abort every
  command listed after it in the same subshell.
- Phase 2's `sourceRoot` must be explicitly reset to `"."` in
  `phases/split.nix` — simply omitting an override there is not the same
  as clearing one inherited from the original package via a shallow
  `replay // {...}` merge, and `stdenv`'s own `setup` script `cd`s into
  the (stale) inherited `sourceRoot` unconditionally.
- meson's own `build.ninja` includes a `REGENERATE_BUILD` edge whose
  dependencies are the original *source*-tree files, which phase 2's
  build-dir-only tree never carries forward — a synthetic
  `dyndrvCdToBuildDir` phase deletes that edge (and its own indented
  option lines) outright.
- ninja's dependency-graph validation requires every declared dependency
  of every build edge to exist on disk even when that edge's output is
  already fully built — both explicit source-file edges and header
  directories referenced only via an edge's `ARGS`-line `-I../include`
  flag. `shim.collectStubs` parses `build.ninja` (and `ninja -t deps`,
  per above) for every `../`-prefixed token and carries just those paths
  forward into a `.dyndrv-carried-up1/` subdir, reconstructed by
  `dyndrvCdToBuildDir` at the *exact* absolute position phase 1's
  `buildPhase` had (meson also bakes absolute paths into
  `meson-private/install.dat`, a pickled Python object, so a synthetic
  staging location isn't sufficient — matching the real absolute
  position resolves those references for free). Every carried-forward
  and freshly-unpacked file also has its mtime normalized to a fixed
  epoch after copying, or ninja's restat check sees "now"-stamped
  sources as newer than an already-built object's fixed epoch-1 store
  mtime and recompiles the whole tree unaccelerated.
- `meson install` reads no env var for its destination (unlike
  autotools' `DESTDIR`-via-`make install`) — `--prefix` is baked in at
  `configurePhase` time to phase 1's own placeholder `$out`. Fixed via
  meson's own `DESTDIR` mechanism: `dyndrvCdToBuildDir` exports
  `DESTDIR="$out"`, and `dyndrvRestoreOutput` hoists the resulting
  `$out$<phase-1-out>/...` nesting back up to `$out` directly (`DESTDIR`
  prepends onto the baked prefix rather than substituting for it).

Regression coverage for this whole chain: `nix/tests/run-tests.sh` and
`rust/dyndrv-shim`'s own `cargo test`/`clippy`, unchanged before/after
this work; the three existing Nix-level regression checks (`mkOutputOf`,
`nonTrivial`, `defaultBackend` in `nix/tests/`) continue to pass.

## Making `nix develop` work end to end

`nix/lib/shim/devShell.nix` provides a `shellHook` that installs
compiled `cc`/`c++`/`ar`/`ranlib` wrappers (via `mkCompiledShim`,
backed by the `rust/dyndrv-shim` package) into an ordinary `nix develop`
session, auto-detected into `Rpc` mode. A real `devShells.dyndrv-shim`
flake output (`flake.nix`) exposes this. Notable properties of the
current implementation:

- A standalone `ranlib` invocation (outside `Sandbox` mode's `ar`+
  `ranlib` chaining, which folds both steps into one script) needs its
  own `setup_cmd` to seed `$out` with the archive's real content before
  `ranlib` runs in place — `ranlib_to_node` builds this via a `Record`
  `seed_from: Option<SeedFrom>` field (a `{from, coreutils_basename}`
  pair), which every render layer (`drv.rs`, `drv_thunk.rs`, `thunk.rs`,
  `render.rs`) resolves the same way it resolves an ordinary `args`
  element (through the `deps` map if still unresolved, else literal
  text), emitting a `cp`+`chmod` seeding command with a real `inputDrvs`
  edge wired in when applicable. This also fixed a latent bug shared by
  every eager tail (`Rpc`, `Thunk{Drv}`, and the `Sandbox` eager paths):
  before `seed_from` existed, `ranlib_to_node` overwrote the archive's
  own argv slot with `"$out"` before any caller scanned for
  dependencies, so a standalone `ranlib`'s registered derivation always
  ended up with zero `inputDrvs`.
- `run_plain`'s `output_arg` resolution reads the *pre-rewrite* argv
  (not the argv after `rewrite_argv_element`'s generic "any existing
  regular file becomes its own store path" pass), since for `ranlib`
  the output path is itself an already-real input file that pass would
  otherwise have already replaced.
- `run_rpc_tail`'s autoforce byte-copy explicitly `chmod u+w`s the
  destination after copying — `fs::copy` mirrors the *source's*
  permissions, so copying from a read-only store path would otherwise
  leave the caller-visible output read-only, breaking any later
  in-place modification (e.g. a subsequent standalone `ranlib`).
- Mode detection for a devShell session uses `mode::connect()`
  (`src/mode.rs`), not the vendored `nix-builder-rpc-client::
  connect_from_env`'s own looser `in_drv` heuristic — `nix develop`'s
  shell-setup derivation leaves `NIX_BUILD_TOP` set in the interactive
  shell it hands back (an ordinary nixpkgs `mkShell` convention many
  setup hooks rely on) even with `NIX_REMOTE` empty there, which would
  otherwise misdetect `Sandbox` mode outside any sandbox.
  `mode::connect()` uses dyndrv's own `in_sandbox()` check (`NIX_REMOTE`
  *and* `NIX_BUILD_TOP` both set) instead. Both binaries use this helper.

## Environment parity: `devShell.nix` vs. a real sandboxed build

For an `Rpc`-mode devShell registration and a real sandboxed
`mkAcceleratedStdenv` build of the identical compile to register
byte-identical `.drv`s, `devShell.nix`'s `compiledEnv` bakes in several
values a real sandboxed build gets for free from `stdenv.cc`'s setup
hooks and the sandbox environment, but an ordinary `nix develop` shell
does not:

- `NIX_HARDENING_ENABLE` (from `stdenv.cc.default_hardening_flags_str`,
  not a hand-copied literal, so it tracks the real toolchain default),
  `NIX_ENFORCE_NO_NATIVE = "1"`, `NIX_ENFORCE_PURITY = "1"` — the same
  values `gcc-wrapper`'s own setup hook and `stdenv`'s `default.nix`
  always export.
- `NIX_STORE = builtins.storeDir` — required alongside
  `NIX_ENFORCE_PURITY`: `gcc-wrapper`'s script checks `"$NIX_STORE"`
  unguarded under `set -u` once `NIX_ENFORCE_PURITY=1`, so setting the
  latter without the former crashes the real compiler outright. Because
  `cc.rs`'s `discover_tree` only checked whether its `cc -M -MG`
  subprocess could be *spawned*, not whether it *succeeded*
  (`out.status.success()`), this particular crash used to fail silently
  — producing an empty discovered-headers list rather than a visible
  error, silently corrupting the registered derivation's staged tree.
  `discover_tree` now checks `out.status.success()` explicitly, so a
  future crash of this kind fails safely instead.
- `NIX_CFLAGS_COMPILE = " -frandom-seed=dyndrv-pla"` and
  `NIX_LDFLAGS = "-rpath /build/dyndrv-placeholder-out/lib "` — both
  derive from the literal text of `$out` at build time
  (`reproducible-builds.sh`'s own `randSeed=${NIX_OUTPATH_USED_AS_RANDOM_SEED:-$out}`);
  inside a real sandboxed `phases.split` build, `$out` is always the
  fixed placeholder string `phases/split.nix`'s `dyndrvPlaceholderOut`
  binding defines (`"/build/dyndrv-placeholder-out"`). These two
  literals are hardcoded in `devShell.nix`, cross-referenced in a
  comment to that binding as the source of truth to keep them in sync
  with if it ever changes.

With these in place, `devshell-parity-test.sh` and
`devshell-parity-smalllib-test.sh` register genuinely byte-identical
derivations between the `Rpc`-mode devShell and a real sandboxed build
for the identical compile, and `cross-mode-reuse.sh` continues to pass.

## Flake-pinned nixpkgs: what's pure now, what still needs `--impure`

`flake.nix` pins nixpkgs via `nixpkgs.follows = "nix/nixpkgs"` and
exposes it as a `legacyPackages` output. Every fixture under
`try-it-out/examples/`, `try-it-out/benchmarks/`, and
`rust/dyndrv-shim/` defaults its `pkgs` argument to
`(builtins.getFlake (toString ../..)).legacyPackages.${builtins.currentSystem}`
(depth adjusted per file's location) rather than an impure
`import <nixpkgs> { }` resolved via `$NIX_PATH` — so a bare `nix build -f
try-it-out/examples/....nix` and `nix develop`/`nix build .#...` always
resolve the same nixpkgs revision and `stdenv`, regardless of what
`$NIX_PATH` happens to point at on a given machine.

This default itself needs no `--impure`: `builtins.getFlake` on a local
path is treated as an unlocked flake reference only once its result is
*used* for something other than a plain config query — every one of
these fixtures' own driver scripts (`run-nix.sh`, `parity-test-lib.sh`,
etc.) route through a real flake output (`.#packages.<system>.rpc-wrapper`,
`.#checks.<system>.<name>`) rather than an inline `--expr` calling
`builtins.getFlake` directly, which is what would force `--impure`.

What still needs `--impure`, and why: any invocation that evaluates
`nix eval --impure --expr` directly against `dynamic-derivations`'
`outputOf` (see `tests/oracle/eval-outputOf.sh`), and `nix flake check`
run with `recursive-nix` enabled (`nix/tests/default.nix`'s own header
comment) — both are inherent to what's being exercised (impure
evaluation of a dynamic derivation's own not-yet-known output content),
not an artifact of this repo's own default-resolution choices. Any
`try-it-out/run-nix.sh build ...` invocation against a real sandboxed
`builder-rpc-v0` build (e.g. inside `cross-mode-reuse.sh` and the
devshell-parity scripts) also passes `--impure` itself, needed for
`patched-nix.nix`'s own `builtins.getFlake` resolution of a *remote*
(`github:NixOS/nix/<rev>`) flake, which is unlocked by nature.

## What's still follow-on work

- No eager-mode-specific Nix-level regression fixture exists yet for
  `granularity = "module"` beyond example 06's compiled variant — a
  dedicated `dyndrv-shim`-crate-level integration test (mirroring
  `ar-integration-test.nix`'s own pattern) would give tighter,
  faster-to-run coverage than a full example build.
- Every one of NixOS/nix's own 14 build components now builds completely
  through the accelerator, from `nix-util` up through the final `nix`
  executable itself (378 translation units total). No further real
  components remain to exercise for this particular "build all of Nix"
  goal.
- The `devShell.nix` ↔ sandboxed-build environment-parity gap
  (`NIX_HARDENING_ENABLE`, `NIX_CFLAGS_COMPILE`, `NIX_LDFLAGS`,
  `NIX_ENFORCE_*`, `NIX_STORE`) is fully closed — no known remaining
  differences between the two registration paths for an ordinary C/C++
  compile.
