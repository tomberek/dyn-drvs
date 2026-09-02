# Upstream tracking

Maps `dyndrv`'s own workarounds to the specific NixOS/nix issues they
paper over — so as upstream Nix matures, workarounds can be deleted
instead of quietly accumulating, and so upstream sees aggregated real
demand instead of scattered reports (`dyndrv` becoming the common
dependency for several projects, per the plan's own adoption goal).

| Issue | Status (2026-09-02) | What it blocks | `dyndrv`'s workaround | Inflating the "tax"? |
|---|---|---|---|---|
| [NixOS/nix#15793](https://github.com/NixOS/nix/pull/15793) — `builder-rpc-v0`/`nix store submit-output` | **Merged** (commit `55eea4554`, 2025-11-17) — on real NixOS/nix `master`, not in a stable release yet | Nothing anymore, for the mechanism itself. `try-it-out/patched-nix.nix` fetches+builds a pinned commit directly — no patched fork, no source patching | None needed beyond "fetch a recent-enough Nix" (see `try-it-out/patched-nix.nix`'s header). `capabilities.nix`'s `builderRpcV0`/`submitOutput` fields stay hardcoded `false` regardless — confirmed structurally undetectable at eval time (negotiated during the daemon connection handshake), not a consequence of this issue's merge status | No — registration overhead (`registration-overhead.sh`) is a property of the `nix derivation add`/`submit-output` CLI round-trip itself, not of whether the feature is merged |
| [NixOS/nix#12727](https://github.com/NixOS/nix/issues/12727) — incomplete `outputOf` monadic-join | **Open** | `nix-cargo-unit`'s exact rejection reason for dynamic derivations (per-compilation-unit Rust builds) — no clean way to chain "an output's output" across more than the two levels `dyndrv.mkOutputOf` already special-cases | `mkOutputOf`/`mkDynamicDerivation`'s `transformDrv` hard-codes exactly TWO `outputOf` calls (verified against nix-src's own `eval-outputOf.sh` oracle test) rather than a general N-level chain — sufficient for every backend/producer `dyndrv` currently supports, but not a general solution to what #12727 describes | No — this is a design-completeness gap, not a runtime cost |

## Watching for movement

- **#15793**: already landed — the thing to watch now is stable-release
  adoption (nixos-unstable's pinned Nix, Determinate's next baseline
  bump). Once `builder-rpc-v0` is typical rather than master-only,
  revisit `capabilities.nix`'s `backend = "auto"` default (see the plan's
  own "open question" on this, recorded 2026-09-02) — at that point
  defaulting to `recursive-nix` unconditionally may become the wrong
  conservative choice for a growing fraction of users, not just a safe
  one.
- **#12727**: if this lands, re-check whether `graph.compile`'s own
  hand-rolled multi-node placeholder chaining (`dyndrv.placeholder`,
  ported to bash for the `builder-rpc-v0` sandbox) could be simplified or
  replaced by whatever general join operation the issue's resolution
  provides — that Rust/bash port exists specifically because Nix itself
  doesn't yet expose one.

## Why track this at all

Every workaround above exists because of a real, specific upstream gap —
not because `dyndrv` chose a harder path than necessary. Recording the
mapping means:
1. A `dyndrv` contributor hitting confusing behavior can check here first
   before re-deriving "is this a Nix limitation or a `dyndrv` bug."
2. When an issue moves (like #15793 already has), there's a checklist of
   exactly what to reconsider, not a vague memory of "something about
   builder-rpc-v0 needing a patch."
3. It's the concrete evidence, for Nix maintainers, that multiple
   independent projects (the seven surveyed in this project's own
   research, now converging through `dyndrv`) are blocked on the same
   handful of gaps — aggregated demand, not scattered reports.
