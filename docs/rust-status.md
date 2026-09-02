# Rust status

There is no Rust code in this repo, despite the original plan naming a
`rust/crates/dyndrv-core` crate (`placeholder.rs`, `drvjson.rs`) as a v0.1
deliverable. This is a deliberate decision, not abandoned work:

- **`placeholder`**: implemented as pure Nix (`nix/lib/placeholder.nix`),
  verified byte-for-byte against Nix's own computed
  `DownstreamPlaceholder::unknownCaOutput` for a real CA derivation. No
  daemon I/O needed, so there was never a reason this couldn't be plain
  Nix — the original "Rust crate" framing assumed a daemon-RPC client
  would be needed alongside it, which turned out not to be true.
- **`drvjson`**: never became its own module. Every producer/builder that
  needs to emit `nix derivation add`-shaped JSON just calls
  `builtins.toJSON` on an ordinary Nix attrset at the call site
  (`viaDerivationAdd.nix`, `graph/compile.nix`, `accelerate/
  mkAcceleratedStdenv.nix`) — there was no reusable logic complex enough
  to justify a typed builder, in Rust or otherwise.

The empty `rust/` scaffolding and the `cargo`/`rustc`/`rust-analyzer`/
`clippy` packages previously in `flake.nix`'s devShell have been removed
(2026-09-02) since nothing uses them.

## When Rust would actually be justified

The plan's own "Later" roadmap item still stands: a raw Nix worker-
protocol client, bypassing CLI shellout for `nix derivation add`/
`nix store submit-output` entirely, for throughput.
`builders/viaDerivationAdd.nix` currently shells out to the `nix` CLI per
call (matching sandstone's still-current approach and nixgg's own
documented starting point) — `registration-overhead.sh` measures exactly
this cost (~50-80ms/call on this machine, dominated by process
startup/CLI overhead, not the actual work each call does). A raw
worker-protocol client would be a pure performance upgrade behind the
same builder-script-generator interface, not a prerequisite for anything
`dyndrv` currently does.

**This is not yet justified**: nothing in the current benchmarks shows
CLI-invocation overhead as the dominant cost anywhere real work has been
measured (`small-lib-patch-rebuild.sh`'s break-even analysis is about
per-file COMPILE time vs. the registration tax, not about the tax's own
internal composition). If a future benchmark shows registration overhead
itself becoming the bottleneck at real scale — e.g. `graph.compile`
against gradle-drvs'-scale graphs (~1100 nodes) — that's the concrete
trigger to revisit this, not before.
