# Generated-diff comparison: what a routine dependency bump costs today

A static comparison, not a runnable benchmark — no build required, just
`git log -p` against real nixpkgs history. The point: nixpkgs' own
lockfile-hash idioms exist because IFD is banned for evaluation-
performance reasons (`pkgs/README.md`'s own words: "committing generated
intermediate files to version control and reading those instead"). Every
routine dependency bump regenerates one of these files wholesale, and a
human has to review the diff even though nothing about the *logic* of the
package changed — only a fetched artifact set did.

A `dyndrv`-based build-time resolver (each dependency its own dynamic
derivation, resolved at build time instead of eval time) needs nothing
generated or committed: the diff for the same bump is a one-line lockfile
hash change, full stop.

## Three real commits, mined from `~/nixpkgs` git history

| Package / file | Commit | Change | Generated-file diff |
|---|---|---|---|
| `pkgs/servers/mastodon/gemset.nix` (Ruby, `bundix`-generated, 4894 lines) | `4b29665caa17` — mastodon 4.5.8 → 4.5.9 | one patch-version bump | **35 lines changed** (19 insertions, 16 deletions) |
| `pkgs/by-name/fs/fsautocomplete/deps.json` (NuGet, 1077 lines) | `05025c9f8e34` — fsautocomplete 0.78.4 → 0.78.5 | one patch-version bump | **12 lines changed** (6 insertions, 6 deletions) |
| `pkgs/build-support/rust/build-rust-crate/test/rcgen-crates.nix` (`crate2nix`-generated, one modest crate's dependency tree) | in-tree test fixture, cited directly in the plan's own research | N/A — this is the STEADY-STATE size for one crate | **5013 lines**, for a single crate's `Cargo.nix` |

The `dyndrv` equivalent for all three: **0 lines** in any generated file,
for the same dependency-version change — a lockfile hash updates, nothing
gets regenerated because nothing was ever generated to begin with.

## Why this matters more than it looks

The mastodon/fsautocomplete diffs above (12–35 lines) look small in
isolation — but they're for the *cheapest* case, a single patch-version
bump with no dependency-tree reshuffling. `crate2nix`'s own in-tree
fixture (5013 lines for one crate) is the realistic steady-state size a
reviewer actually has to hold in their head, and it's why `crate2nix`
isn't used for general nixpkgs packages — only `buildRustPackage`'s
single-opaque-hash `cargoHash` (no per-crate visibility at all) is. The
tradeoff nixpkgs has actually made is "either a large, low-signal diff
per bump, or no diff and no crate-level granularity" — dynamic
derivations are the one option that gets both: zero generated diff AND
real per-crate/per-gem build granularity, because the graph is resolved
at build time instead of baked into eval-time Nix source.

## Reproduce this yourself

```console
$ git -C ~/nixpkgs log --oneline -- pkgs/servers/mastodon/gemset.nix
$ git -C ~/nixpkgs show --stat 4b29665caa17 -- pkgs/servers/mastodon/gemset.nix
```

No `dyndrv` checkout needed for this one — it's nixpkgs' own history,
already sitting there.
