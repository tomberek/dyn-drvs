# `Thunk{format: Drv}`'s multi-node graph: real `inputDrvs` chaining

## Context

The compiled `dyndrv-shim` work (see `docs/rust-status.md`) is done —
`Sandbox`, `Rpc`, and `Thunk{format: Nix}` are all built, wired, and
verified against real freetype; a `phases.split` sandbox bug
(`/nonexistent` unwritable in a real sandbox) found along the way is
fixed and committed. `Thunk{format: Drv}` — the experimental mode that
writes a real ATerm `.drv` file directly to disk, no daemon call for
the write itself — only handles a SINGLE node today
(`drv_thunk.rs::write_drv_thunk` builds one derivation from one
`Record`, with no `inputDrvs` wiring to any other dyndrv-produced
`.drv`). This doc designs the multi-node case: chaining real
`inputDrvs` across several `.drv`-format thunks, e.g. an `ar` step's
`.drv` referencing the `.drv`s of the `cc` compiles that produced its
own `.o` inputs.

This matters because a `.drv`'s own `inputDrvs` field is Nix's NATIVE
on-disk dependency-edge format — unlike `Thunk{format: Nix}`, which
needs a separate helper file to batch-realize a whole thunk graph via
one `nix build --file` call, a `.drv` graph should need no such helper:
`nix-store --realise` on the ROOT `.drv` walks `inputDrvs` transitively
on its own. That property is exactly what's unverified today.

## The core design problem

Each shim invocation (`ar`, `cc`, `ranlib`) is a SEPARATE process with
no shared state — `write_drv_thunk` only ever sees its own `Record`.
For `ar cr liba.a a.o b.o`, `a.o`/`b.o` are outputs of EARLIER, already-
completed `cc` invocations. There is no in-memory graph to walk; the
only place the dependency is discoverable is ON DISK: `thunk::
link_placeholder` symlinks the caller-visible output (`a.o`) at its
owning thunk file (`.dyndrv/thunks-drv/<id>.drv`). So `ar`'s own
invocation, writing ITS `.drv`, must:

1. For each positional arg that's an existing regular file, check if
   it's actually a SYMLINK into `.dyndrv/thunks-drv/` (a
   `.drv`-format dependency, not real content).
2. If so, compute that `.drv`'s own store-computed name (see below) to
   build a `SingleDerivedPath::Built { drv_path, output: "out" }` input
   instead of an `Opaque` `srcs` entry.
3. If not (a real file, or a `Thunk{format: Nix}` thunk, or content
   from a different, unrelated source), fall back to today's behavior.

This mirrors two mechanisms already in the codebase, just recombined:
- `Sandbox` mode's `finalize_defer`/`chained_from` walks a chain of
  records on the SAME output path (same-unit chaining, e.g. `ar` then
  `ranlib` on one archive).
- `tonode.rs::extra_store_paths`/`wrapper.rs::rewrite_argv_element`
  already detect "this argv element references something already
  known" and rewrite accordingly — but today only for REAL store
  paths, never for a symlink-to-a-`.drv`-thunk.

The `Drv`-thunk case is genuinely NEW: it's cross-process (each
invocation is its own binary run) and cross-unit (a real dependency
edge between two different derivations, not a same-unit record chain).

## Computing a `.drv`'s own name/hash without a daemon round-trip

`nix-builder-rpc-client::add_drv_to_store` never computes the resulting
`StorePath` itself — the DAEMON does, and hands it back. `Thunk{Drv}`
mode has no daemon call for the write, so `write_drv_thunk` needs to
compute the drv's own content-addressed store path locally. Checked
`harmonia_store_content_address::make_store_path_from_ca` — this is
exactly the primitive: `store_dir + name + ContentAddress` ->
`StorePath`, doing the "fixed:out:r:<hash>:"-style fingerprint + SHA-256
Nix does internally (mirrors what `add_drv_to_store`'s SERVER side does
— confirmed by reading `harmonia_store_content_address::to_store_path`'s
own `PathType`/fingerprint logic). Since a `.drv`'s own CA method is
`text:sha256` over its ATerm bytes (`add_drv_to_store`'s own call uses
`ContentAddressMethodAlgorithm::Text`), computing this locally means:
`ContentAddress::Text(Sha256::digest(aterm_bytes))`, then
`make_store_path_from_ca(&store_dir, name, ca)`. This gives
`write_drv_thunk` a REAL, correct `StorePath` for its own `.drv` —
without any daemon call — which is exactly what a DEPENDENT invocation
(a later `ar` step) needs to reference it via `SingleDerivedPath::Built`.

Confirmed this must be done directly, not sidestepped: `nix-store --add`
(used by `realise_drv_and_promote`'s autoforce path today) produces a
FLAT-CA path with a different hash than the drv's own logical
`text:sha256` identity — fine for realizing a ROOT `.drv` handed
directly to the CLI, but NOT fine for a dependent's `inputDrvs` entry,
which must reference the drv's real, Nix-recognized identity for
`nix-store --realise`'s own transitive `inputDrvs` walk to find it
(Nix looks up derivations by their real store path, not by whatever
flat-CA name a manual `--add` happened to produce for an unrelated
copy).

## Plan

1. **`drv_thunk.rs`**: add a helper `compute_drv_store_path(store_dir,
   name, aterm_bytes) -> StorePath` using
   `harmonia_store_content_address::make_store_path_from_ca` +
   `ContentAddress::Text(Sha256::digest(aterm_bytes))`. Verify this
   against a real `add_drv_to_store` call over an actual socket
   connection (reuse the existing sandbox test harness) — confirm the
   locally-computed path matches what the daemon actually returns for
   the IDENTICAL derivation, byte-for-byte, before trusting it anywhere
   else. This is the new plan's own "byte-identical against the proven
   mechanism" check, same discipline as every prior task in this
   codebase's history.

2. **`drv_thunk.rs::write_drv_thunk`**: change signature to accept the
   ALREADY-RESOLVED argv-to-dependency mapping (built by the caller,
   see step 3) instead of just a bare `Record`. For each `record.args`
   element that resolves to a known `.drv`-thunk dependency, add a
   `SingleDerivedPath::Built { drv_path, output }` to `drv.inputs`
   (matching `dyndrv-collect.rs`'s own `drv.inputs.insert(SingleDerivedPath::Built {...})`
   pattern for cross-unit deps) instead of treating it as a plain
   `srcs` `Opaque` entry. The script text itself still needs the
   dependency's REAL realized path substituted at build time — same
   placeholder-substitution idea `dyndrv-collect.rs`/`render.rs` already
   use via `Placeholder::ca_output(drv_path, &out_name)`, computed here
   with the LOCALLY-known `StorePath` from step 1.

3. **`thunk_tail.rs::run_drv_format`**: before calling
   `write_drv_thunk`, scan `record.args` for existing regular files that
   are ACTUALLY symlinks whose target lives under
   `.dyndrv/thunks-drv/` (read via `std::fs::read_link`, not
   `read_batch_stub` — this is a DIFFERENT on-disk convention, a real
   symlink, not the `#!dyndrv-batch-pending` stub text format `Sandbox`
   mode uses). For each match, resolve the target `.drv` file's own
   `StorePath` — either by re-reading+re-hashing its ATerm bytes
   (simplest, no extra bookkeeping needed since `.drv` files are small)
   or by a small on-disk sidecar cache keyed by thunk id (only if the
   re-hash approach proves too slow in practice — start with the
   simple re-hash). Build the argv-element -> `(StorePath, OutputName)`
   map and pass it into `write_drv_thunk`.

4. **Realization** (`realise_drv_and_promote`): unchanged in
   MECHANISM (`nix-store --add` the ROOT `.drv`, then `--realise`) but
   now genuinely exercises the multi-node case, since the root's own
   `inputDrvs` will reference other REAL (not yet store-added) `.drv`
   paths. This is the crux unverified claim from the original design:
   confirm whether `nix-store --realise` on a `--add`ed root `.drv`
   correctly resolves `inputDrvs` entries that themselves point at
   store paths NOT yet present in the store (the dependency `.drv`s
   still only exist as on-disk files under `.dyndrv/thunks-drv/`, never
   `--add`ed). If it does NOT (plausible — Nix's builder may require
   every `inputDrvs` entry to already be a valid, registered store
   path), the fix is recursively `--add`ing every transitively-
   referenced `.drv` bottom-up before realizing the root — still no
   `nix build`/scheduling call except the one final `--realise`, just
   more `--add` calls (cheap, no build, per the earlier-confirmed
   finding in `docs/rust-status.md`'s "Experimental finding" section).

5. **Test fixture**: a small, NEW multi-node fixture exercising a real
   cross-drv `inputDrvs` reference — e.g. two `cc`-shimmed compiles
   producing `a.o`/`b.o` as `.drv`-format thunks, then one `ar`-shimmed
   archive step referencing both, all under `DYNDRV_MODE=thunk
   DYNDRV_THUNK_FORMAT=drv`. Mirrors the existing `ar-integration-test.nix`
   shape (pre-existing stubs feeding into `ar`) but for thunk-mode
   instead of sandbox-mode, and with REAL (not faked) `.drv`
   dependencies. Verify: (a) `ar`'s own `.drv` file's `inputDrvs` field
   contains the two compile `.drv`s' real store paths (inspect the
   ATerm text directly), (b) `DYNDRV_AUTOFORCE=1` on the `ar` step
   correctly realizes the WHOLE graph (both compiles + the archive) via
   ONE root `--realise` call, producing a real, valid `liba.a`.

6. **Docs**: update `docs/rust-status.md`'s "Experimental finding"
   section with the multi-node result — either confirming the
   no-separate-graph-file property holds (just needs recursive
   `--add`), or recording whatever different shape it actually takes.
   Remove the "unbuilt, single-node only" line from "What's still
   follow-on work."

## Files to modify

- `rust/dyndrv-shim/src/drv_thunk.rs` — `compute_drv_store_path` helper,
  `write_drv_thunk` signature change to accept resolved deps.
- `rust/dyndrv-shim/src/thunk_tail.rs` — `run_drv_format`'s new
  dependency-scan step before calling `write_drv_thunk`;
  `realise_drv_and_promote`'s possible recursive-`--add` fix.
- New test fixture, mirroring `rust/dyndrv-shim/ar-integration-test.nix`'s
  shape but thunk-mode (name TBD during implementation, e.g.
  `rust/dyndrv-shim/drv-thunk-multinode-test.nix` + its own `-runner.nix`).
- `docs/rust-status.md` — record the actual finding.

## Verification

- Step 1's byte-identical check against a real `add_drv_to_store` call
  (same discipline as every earlier task in this codebase's history).
- The new multi-node fixture (step 5), inspecting the rendered
  `inputDrvs` ATerm text directly, not just "the build succeeded."
- Re-run the EXISTING `ar-integration-test.nix`/`collect-integration-test.nix`
  regression fixtures afterward, to confirm no regression to `Sandbox`
  mode from any shared-code changes (`drv_thunk.rs` is `Drv`-mode-only,
  but `thunk_tail.rs` touches shared dispatch — check `wrapper.rs`'s
  `dispatch_defer` call site stays unaffected).
