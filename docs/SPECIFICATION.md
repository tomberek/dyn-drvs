# dyn-drvs Specification

This document specifies the contracts, on-disk formats, and algorithms that
implementations of dyn-drvs (or ports to other languages) MUST honor. It is
derived from internal research into the reference (Nix + bash + Rust)
implementation and is intended to be sufficient for a from-scratch port
without reading that implementation line-by-line. Where the source research
is imprecise about an exact byte format, this is noted explicitly rather than
guessed.

## 1. The producer contract

`mkDynamicDerivation` (the outer entry point that builds a normal Nix
derivation wrapping a dynamic one) accepts a **producer**: a duck-typed
attrset

```
{
  script        :: backend -> string;
  extraDrvArgs  :: attrset;
}
```

* `script` MUST be a function of one argument, the selected backend name
  (`"recursive-nix"` or `"builder-rpc-v0"`), returning the complete
  `buildPhase` body as a string, including its own `runHook preBuild` /
  `runHook postBuild` calls. The two backends require structurally different
  builder scripts (one writes a derivation description to `$out`, the other
  performs RPC calls against the daemon), so this function is the only
  backend-specific surface of a producer.
* `extraDrvArgs` MUST be an attrset merged into the outer derivation's
  attributes (e.g. `nativeBuildInputs`, `passAsFile`).

This shape is intentionally *not* a constructor-backed abstraction with
identity or methods — it is purely structural. Any value satisfying it is
interchangeable as a `producer`: every `dyndrv.builders.*` function and
`dyndrv.graph.compile` independently return this shape, so a full compiled
multi-node graph (`graph.compile` result) is exactly as valid a producer as a
single-node `builders.viaDerivationAdd` call. `mkDynamicDerivation` factors
out everything backend-agnostic (naming, CA/output-hash derivation
attributes, the `outputOf` unwrap, `meta`/`pname`/`version` forwarding) and
delegates only sandbox-script generation to the producer.

**Naming invariant (load-bearing, build-time enforced only).** The inner
derivation that the producer's script constructs MUST be named exactly
`"${pname}-${version}"` (equivalently, whatever `name` the outer wrapper
computes, minus the `.drv` suffix). This is required because a
content-addressed/text-hashed derivation's output path is a function of its
declared name, and Nix validates this at *realization* time, not eval time —
a mismatch fails with `derivation has incorrect output '<path>', should be
'<expected>'`. There is no eval-time check; a producer that gets this wrong
will pass evaluation and fail only when built.

**Passthru contract.** Every derivation produced via `mkDynamicDerivation`
(through any producer) MUST expose:

* `passthru.dynamicDrv` — the raw outer `.drv`-producing derivation (named
  `dynamicDrv`, not `drv`, by convention).
* `passthru.outputOf` — the fully resolved final output, obtained by
  chaining `builtins.outputOf` exactly twice: level 1 resolves the outer
  derivation's own output (which is itself the inner `.drv` file) to that
  inner `.drv`; level 2 resolves the inner `.drv`'s own output to the real
  result. Two chained calls is a fixed constant of this design, not a
  general N-level chain (see §2 for why).
* `passthru.backend` — the backend name actually selected for this
  derivation.

These three names MUST be identical across every entry point (builders,
graph.compile, etc.) so callers have one uniform "give me the raw thing
underneath" API regardless of which producer constructed the value.

## 2. `mkOutputOf`'s contract

`mkOutputOf` wraps `builtins.outputOf` to paper over two permanent
characteristics of that primitive (documented as intentional, locked-in Nix
behavior by Nix's own test suite, not bugs in dyn-drvs):

1. **Input coercion.** `builtins.outputOf` requires a literal string
   argument; it does not accept a derivation attrset that could coerce to
   one. `mkOutputOf` MUST accept either a derivation attrset or a raw
   `.drvPath` string, and if given a derivation, extract `drv.drvPath`
   itself before calling `builtins.outputOf`.
2. **Context stripping.** `builtins.outputOf` rejects any string argument
   whose string context is `DrvDeep` (the kind of context a derivation's own
   `.drvPath` naturally carries, tracking its complete source+binary
   closure), raising an error that the context "refers to a complete source
   and binary closure. This is not supported at this time." `mkOutputOf`
   MUST apply `builtins.unsafeDiscardOutputDependency` to the path
   unconditionally before calling `builtins.outputOf`. This call is a
   documented no-op when the context is already `Opaque` (e.g. a path
   chained from a prior `outputOf` call), so applying it unconditionally
   rather than branching on context kind is safe.

**Two-level chaining constant.** Because the outer `mkDynamicDerivation`
derivation's own build output *is* the inner `.drv` file, resolving to the
real final artifact always requires exactly two `outputOf` calls: one to
resolve the outer derivation to the inner `.drv`, and one to resolve that
`.drv` to its own output. This is fixed in the implementation (e.g. inside
`transformDrv`) as exactly two calls rather than a general recursive/N-level
join, because `builtins.outputOf` currently has no monadic-join operator to
compose an arbitrary-depth chain generically (tracked as an open upstream gap
in Nix). A port MUST NOT assume a general chain-of-N mechanism exists; two
levels is the extent of what is supported.

## 3. The batch-stub on-disk format and JSON record schema

This is the most implementation-critical contract in the system: it is the
handoff format between the "defer" side (a wrapped `cc`/`ar`/`ranlib`
invocation inside a `builder-rpc-v0` sandbox, unable to realize anything
inline) and the "collect" side (a single end-of-`buildPhase` pass that
resolves every deferred invocation into real registered derivations).

### 3.1 Stub file

A stub is a **plain regular file** written at the path where the tool's real
output was expected. It MUST NOT be a symlink — a symlink dangling to a
not-yet-built target fails a plain `test -e` check, and many build systems
gate on exactly that check to decide whether a dependency is fresh; an
ordinary readable regular file satisfies `test -e` immediately.

Exact on-disk shape: exactly two lines.

```
Line 1: #!dyndrv-batch-pending
Line 2: <absolute path to a separately-written JSON record file>
```

Both the writer and reader of this format MUST be implemented from one
shared definition (not duplicated per side) so the two cannot drift apart.

**Reader defensiveness requirement.** A conformant reader MUST treat both
line reads as fallible without aborting the whole calling script:
* A genuine (non-stub) one-line file will EOF on the second read.
* A binary file with no newline anywhere can EOF even on the *first* read.
Under a caller context with fail-fast semantics (e.g. shell `set -e`), an
unguarded read failure here would abort the entire calling script instead of
simply reporting "this is not a stub." Implementations MUST guard both reads
so failure degrades to a negative ("not a stub") result.

### 3.2 JSON record schema

The stub's second line points at a JSON file — the **record** — describing
the deferred invocation. The corpus establishes the following fields exist
and their roles; where a field's exact JSON type is not stated explicitly in
the corpus, this is called out.

| Field | Type | Presence | Meaning |
|---|---|---|---|
| `key` | string | present; MAY be empty string | Batch-group identity. Empty string means "not opted into a batch group" (solo/file-granularity). A non-empty value groups this record with every other record sharing the same `key` into one registered multi-output derivation (module granularity). |
| `tool` | string | present | Which tool produced this record (e.g. `cc`/`ar`/`ranlib`), used to select rendering/decision logic. |
| `args` | list of strings | present | The tool's argv (post-rewrite/relative-path form as seen by the shim). Used both to reconstruct the command line and, generically, as the dependency-discovery surface: dependency detection scans `args` for strings matching another discovered stub's own relative path — there is no separate declared-dependency schema field. |
| `srcs` | list of strings | present (may be empty) | Source-file inputs associated with the record, unioned across a `chainedFrom` chain when resolving dependencies (see below). |
| `setupCmd` | string | MAY be absent / present | A setup fragment to run before the tool's own command line (used by the shared `render_record_line`/rendering logic that assembles `setup_cmd ; tool args` style script fragments). |
| `chdir` | string (path) | MAY be absent | A directory to change into before running the record's command, distinct from `cwd` (see below); used when rendering the command itself. |
| `cwd` | string (path) | present | The invocation's own working directory, captured **relative to `NIX_BUILD_TOP`** at record-creation time (via something equivalent to `realpath -m --relative-to=$NIX_BUILD_TOP`). Needed because a build tool may invoke a dependent step (e.g. a link) from a different cwd than the step that produced one of its inputs (e.g. a compile), so the two steps' argv text for "the same file" differ as strings unless reconciled — see §3.3. |
| `chainedFrom` | string (path to another record) or absent | MAY be absent | Points at an earlier record that wrote a stub at the *same output path* that this record's stub is about to overwrite. Set instead of overwriting when a second tool invocation (e.g. `ranlib`) targets the identical output path as a prior invocation (e.g. `ar`) already deferred. Preserves the earlier record (and its dependencies) instead of silently discarding it. |
| `seedFrom` (`seed_from`) | optional structured value | MAY be absent | Identifies that this record's output should be seeded from / is a continuation of another already-known output rather than built from scratch (used for standalone tool invocations, e.g. a `ranlib` with no preceding `ar` in the same unit, where the output is itself an already-real input file). Exact structure not fully specified in the corpus beyond it being an `Option<SeedFrom>`-typed field consumed by the shared rendering path. |

**Chain resolution (`chainedFrom`).** When two deferred invocations target
the identical output path in immediate sequence (the canonical example:
`ar cr libfoo.a *.o` followed by `ranlib libfoo.a`), a naive "last write
wins" stub overwrite at that path would silently discard the earlier
record — and with it, its dependency edges (e.g. `ar`'s dependency on every
compiled `.o`) — the moment the later record's stub write lands on the same
path. The correct behavior: when a stub is about to be (over)written at a
path that is already a pending stub from an earlier record, the new record's
`chainedFrom` MUST be set to point at that earlier record instead of
overwriting it. A conformant collector MUST walk the `chainedFrom` pointer
chain, oldest first, when resolving both dependencies (unioning every chain
step's `args`-derived dependencies and `srcs`, not just the newest step's)
and rendering (each chain step rendered in order as a sequence of commands —
e.g. `;`-joined — against the same output).

### 3.3 cwd/path-frame reconciliation

Because `cwd` is captured relative to `NIX_BUILD_TOP` while the collector's
own stub-key namespace is relative to a build root that is typically a
subdirectory of `NIX_BUILD_TOP` (e.g. `/build/source`), dependency matching
MUST NOT join `cwd` directly against build-root-relative stub keys. A
conformant implementation:

1. Computes the build root's own offset from `NIX_BUILD_TOP` once.
2. Converts a `NIX_BUILD_TOP`-relative path into a build-root-relative path
   via that offset before ever comparing it against a stub key.
3. Joins a record's `cwd` with one of its `args` entries and normalizes
   `..`/`.`/empty path segments as pure string arithmetic (no filesystem
   access, since the target may not exist yet).

This reconciliation MUST be applied unconditionally, even to a record whose
invocation cwd equals the build root exactly (i.e. no real mismatch),
because `cwd` is still non-empty in that case (equal to the build root's own
offset string) and skipping the reconciliation step corrupts the dependency
join for every ordinary, non-mismatched invocation, not just the mismatched
ones.

## 4. The `DownstreamPlaceholder`/`unknownCaOutput` formula

**Problem it solves.** For a content-addressed or dynamic derivation, a
dependency's real output store path is not known until that dependency is
actually built (the path is a function of built *content*, not just
declared inputs). Yet derivation registration (e.g. `nix derivation add`)
happens up front, in topological order, before dependencies are built — so a
depending derivation's JSON must reference an output that does not exist yet
as a concrete path. Nix's placeholder mechanism produces a deterministic
stand-in string, purely a function of the upstream derivation's identity and
output name, that Nix transparently substitutes for the real path once that
output is actually realized.

**Formula**, given a dependency's drvPath basename:

1. Split the basename into `drvHashPart` (the substring before the first
   `-`) and `drvName` (the substring between the first `-` and the trailing
   `.drv`).
2. Compute `outputPathName`: if the output name is `"out"`, this is just
   `drvName`; otherwise it is `"${drvName}-${outputName}"`.
3. Form `clearText = "nix-upstream-output:${drvHashPart}:${outputPathName}"`.
4. Compute the SHA-256 digest of `clearText`.
5. nix32-encode that digest and prefix with `/`:
   `/$(nix hash convert --to nix32 --from base16 --hash-algo sha256 <hex-digest>)`

This exact procedure is stated as a direct bash port of Nix's own
`DownstreamPlaceholder::unknownCaOutput`, checked against Nix's own computed
placeholder for a real CA derivation.

**Two flavors, by reference kind:**

* **Self reference** (a not-yet-registered unit referring to its own
  eventual output): uses a cheap sentinel of the form
  `@dyndrv-self-placeholder:<name>@`, later substituted with the real
  `builtins.placeholder` value at build time — no cross-derivation lookup is
  needed since it is a reference to an output of the same derivation being
  constructed.
* **Cross-unit reference** (one already-registered unit referring to
  another *different*, already-registered unit's output): uses the full
  `unknownCaOutput` formula above against the dependency's real,
  already-known drvPath, because only after the dependency has itself been
  registered does its hash-part exist to plug into the formula.

The corpus is explicit that both known implementations (a Nix-eval-time
graph compiler and a build-time bash/Rust collector) MUST implement this
formula identically, ideally by having one canonical implementation that the
other copies verbatim or delegates to, so the two cannot silently diverge.

## 5. The unit-merge algorithm (Phase 4)

Given a discovered graph of stub records (deduplicated, dependency edges
computed per §3.2/§3.3, topologically sorted with cycles rejected), unit
assignment proceeds in topological order using this rule for each stub `s`:

```
for each stub s in topo order:
    if s.key is non-empty:
        assign s to the unit identified by s.key
            (creating that unit if it does not yet exist)
    else if s has at least one dependency (allPending):
        let depUnits = { unit(d) : d in deps(s) }
        if |depUnits| == 1 and that one unit is:
            - a keyed (non-solo) unit
          then:
            assign s to that same unit
        else:
            assign s to a new solo unit "__dyndrv_solo:<s.path>"
    else:
        assign s to a new solo unit "__dyndrv_solo:<s.path>"
```

In prose: a stub carrying its own non-empty `key` always joins that keyed
unit directly. A keyless stub (typically an `ar`/link step) joins its
dependencies' shared unit *only if* every one of its dependencies belongs to
the exact same unit *and* that unit is not itself a solo unit ("allPending
&& sameKey"). Any other case — no dependencies, dependencies split across
multiple units, or dependencies whose shared unit is itself solo — makes the
stub its own solo unit, named deterministically after its own path
(`__dyndrv_solo:<path>`) so solo units never collide with keyed ones or each
other.

After assignment, unit members are grouped preserving the *global* topo
order computed earlier (valid because a subsequence of a topological order
remains a valid topological order for the induced subgraph on that subset).
Each member is then assigned a sanitized, unique output name within its
unit. The unit graph itself is then topologically sorted a second time
(cross-unit edges), because grouping can place topologically distant stubs
in the same unit, so ordering at the unit level is not guaranteed by the
per-stub order alone.

## 6. The `wrapCommand` parameter contract

`wrapCommand` is the generic interception point every wrapped tool (`cc`,
`ar`, `ranlib`, etc.) is built from. A caller constructing a wrapped command
MUST supply:

* **`command`** — the name/path the wrapper is installed as (the name build
  tools will invoke, e.g. `cc`).
* **`realCommand`** — the underlying real tool to fall through to when not
  deferring (e.g. the actual compiler binary), used both for the bypass path
  and for any sub-invocations the decision logic itself needs to run (e.g. a
  dependency scan).
* **`toNode` / `toNodeBash` / `toNodeCompiled`** — three interchangeable
  implementations of the same decision logic (given an invocation's argv/cwd,
  decide: bypass, defer as a stub, or otherwise classify the call), differing
  only in performance characteristics, not in required behavior:
  * `toNode` runs the decision logic by invoking a full Nix evaluator
    (`nix-instantiate --eval --strict --json`) per invocation.
  * `toNodeBash` implements the same decision logic without spawning a Nix
    evaluator, avoiding the dominant per-call cost (evaluator boot time).
  * `toNodeCompiled` is a compiled-binary implementation (the Rust port)
    that additionally avoids spawning `jq` and `nix store add-file`/`add`
    as subprocesses, doing argv rewriting, decision logic, and stub-writing
    natively.
  All three MUST agree on outcome for the same invocation; a caller MAY
  select any one and get equivalent results (mod performance).
* **`discoverTree`** — an optional dependency-discovery mode invoked before
  deferring a compile: it runs a header/dependency scan (e.g. `cc -M -MG`) to
  find every relative file a deferred build will need, stages that set of
  files into one directory tree, and adds that tree to the store as a single
  object so the eventually-registered derivation's builder can `cp -r` it
  into place before running the original command unmodified. `discoverTree`
  is a pure optimization/self-containment mechanism, not a correctness
  mechanism for dependency *edges* between build steps (those are separately
  derived from positional argv paths, per §3.2). It MUST be skipped
  (exit early) for a link-shaped invocation (no `-c` flag), since a
  `-M -MG` scan over already-compiled `.o`/`.a` positional inputs prints
  nothing useful — this is purely an efficiency guard, not a fix for the
  (separate) cwd/path-frame dependency issue in §3.3.
* **`DYNDRV_BYPASS`** — an environment-variable escape hatch: when set (per
  invocation-time environment), the wrapper MUST skip all interception
  entirely and exec `realCommand` directly with the original argv. This is
  the mechanism that lets probes/passthrough cases (see below) and ordinary
  non-deferred invocations opt out of the shim.

**Guaranteed passthrough classes.** Certain invocation shapes MUST always be
treated as passthrough (never deferred), because a deferred stub always
"succeeds" at invocation time regardless of what the real tool would have
done, which breaks any caller that inspects the invocation's real exit
status or output immediately (a compile-then-execute probe, or a
should-legitimately-fail feasibility probe):
* Autoconf-style probes, detected by a `conftest*`-prefixed basename.
* CMake-style compiler-flag probes, detected by inspecting the invocation's
  captured cwd for a `CMakeFiles/CMakeScratch/TryCompile-*` marker — this
  MUST be checked against the cwd, not argv text, because absolute-cwd
  prefixes are stripped from relative argv elements before decision logic
  ever sees them, so the marker does not survive in argv.

## 7. The `phases.split` contract

`phases.split` divides a build into two independent Nix derivations to work
around a structural capability gap: a `builder-rpc-v0` sandboxed derivation
can *register* other derivations (`AddToStore*`/`SubmitOutput` opcodes are
allowlisted on that connection mode) but categorically cannot *realize*
them (`BuildPaths`/`QueryMissing` are not allowlisted). Since
`installPhase`/`fixupPhase` require a real, already-resolved output tree
(for RPATH fixing, output splitting, etc.), that work cannot happen inside
the sandboxed phase.

**Required parameters:**
* **`sandboxed`** — attrs/config for phase 1: runs under
  `requiredSystemFeatures` including `"builder-rpc-v0"`, executes
  unpack/patch/configure/build (whatever the package's build system needs)
  plus a synthesized final `collectPhase` that submits a fully resolved
  tree as this phase's one output.
* **`sandboxedPhases`** — the explicit, static list of phase names phase 1
  is permitted to run (e.g. `unpackPhase patchPhase configurePhase
  buildPhase`), used both to bound phase 1's execution and to determine
  where phase 2's replay picks up.
* **`replay`** — attrs/config for phase 2: an ORDINARY derivation (no
  special `requiredSystemFeatures`) that consumes phase 1's resolved output
  and runs the remaining phases (install/fixup/check) normally, with full,
  unrestricted multi-output support since nothing in phase 2 is intercepted.
* **`replayPhases`** — the phases phase 2 runs, which MUST include the
  restore step (below) inserted immediately after `installPhase` and before
  `fixupPhase`.

**Dynamic phase list caveat.** Because `sandboxedPhases` is a static,
caller-declared list rather than dynamically computed, a setup hook that
injects additional phases at runtime (e.g. `autoreconfHook`'s
`appendToVar preConfigurePhases autoreconfPhase`) will still run (setup
hooks execute unconditionally before phase dispatch) but its injected phase
name can be silently absent from the forced phase list — the safer
implementation path is to let the phase-1 derivation call the normal dynamic
phase-list computation itself, then truncate the resulting list at the last
entry of the caller's declared `sandboxedPhases`, appending the synthesized
`collectPhase` — preserving any phases dynamically injected up to that
boundary rather than guessing the phase list statically.

**`dyndrvPlaceholderOut` convention.** Phase 1 has no real `$out`: its
`out` output attribute MUST be forced to the fixed literal string
`/build/dyndrv-placeholder-out` (mirroring `mkDynamicDerivation`'s own
`out = "/nonexistent"` sentinel convention elsewhere in the system) rather
than a real store path or an environment-variable indirection. Rationale for
each specific choice:
* It MUST be a literal string baked in at both phase 1 (where a package's
  `configureFlags` may freeze this value into generated build files) and
  phase 2 (where `make install` reads that same literal back) — using an
  environment variable would not guarantee the two independently-run
  sandboxes resolve to the same value.
* It MUST be rooted at `/build` specifically (not `/nonexistent`, not
  `$NIX_BUILD_TOP`), because the sandbox root filesystem is not writable
  even to the build group, and `/build` (Nix's own `sandbox-build-dir`) is
  the one path guaranteed writable inside the sandbox.

**Restore-step guarantee.** A step (`dyndrvRestoreOutput`) MUST run
immediately after `installPhase` and before `fixupPhase` in phase 2's
`replayPhases`. It MUST:
1. Copy (not move — to avoid clobbering anything `installPhase` already
   wrote directly to a real output path via its own hook) the entire
   placeholder tree's contents into the real `$out` (and, by the same
   mechanism, each other real output).
2. Explicitly invoke any output-splitting logic (e.g.
   `_multioutDocs`/`_multioutDevs`) itself immediately, rather than relying
   on it firing later via an ordinary pre-fixup hook array, because a
   caller-supplied hook that itself runs before that array's normal firing
   point may already expect the split outputs (e.g. `$dev/include`) to
   exist.

## 8. Cross-mode parity requirements

Because the same on-disk stub/record format and the same registered-
derivation semantics must be producible and consumable by both a bash
implementation and a Rust implementation (and by multiple independent
render call sites within the Rust implementation itself — one per
`DyndrvMode`), the following parity rules apply:

**MUST be byte-identical:**
* The rendered ATerm text produced for a logically identical `Record`
  MUST be byte-identical regardless of which of the independent render call
  sites produced it (one per mode: `Rpc`, `Sandbox`, `Thunk{Drv}`, and the
  module-granularity group-accumulation path). A prior, real divergence — a
  mismatched trailing separator (`"; "`) present in some call sites'
  hand-written construction and absent in others — produced two different
  ATerm byte strings for the same single record and is the reason all such
  call sites MUST delegate to one shared rendering function rather than each
  reimplementing the setup/command-line assembly logic. This guarantees a
  TU registered by hand outside a sandbox (e.g. in a dev shell) and the same
  TU registered inside a sandboxed build land at the identical
  content-addressed store path, so Nix substitutes rather than rebuilds.
* The on-disk stub header line (`#!dyndrv-batch-pending`) and the two-line
  stub structure MUST be identical between bash- and Rust-produced stubs;
  either implementation MUST be able to read a stub the other wrote, in the
  same build, with no migration step.
* The record JSON schema (§3.2) MUST be shared: a record written by one
  implementation must be a valid, fully interpretable record to the other.

**Explicitly ALLOWED to differ:**
* Performance characteristics and process/subprocess usage (evaluator
  boots, `jq` invocations, CLI round-trips) — the entire motivation for the
  Rust port is to eliminate these, not to preserve them.
* Behavior in situations the bash oracle's own usage pattern never
  reaches. For example, resolving an `output_arg` from pre-rewrite vs.
  post-rewrite argv for a standalone `ranlib` with no preceding `ar` in the
  same unit is a case the bash implementation's chaining design never
  actually exercises (its `ar`+`ranlib` chaining means the archive is always
  still a stub at that point), so a fix/behavior here is Rust-only and not a
  parity violation.
* Additional defensive checks layered on top of the ported logic (e.g.
  checking a subprocess's exit status rather than merely that it spawned),
  provided the *documented*/normal-path output remains byte-identical.
* These divergences are permitted only when each is individually justified
  as intentional (not an accidental drift) and verified against a real
  reproduction; unverified/undocumented divergence is not sanctioned.

**Verification mechanism.** Parity is enforced three ways: (1) all
independent render call sites are structurally forced through one shared
function rather than relying on convention; (2) a unit-level test module
asserts byte-identical rendered output across modes for a fixed set of
synthetic `Record` shapes (solo record, cross-derivation dependency,
standalone `seedFrom` record, and a two-step chained record — the last being
the shape that originally exposed the trailing-separator bug, since only a
multi-step chain has trailing content for a missing separator to
misalign); (3) real-project fixtures confirm byte-identical registered
`.drv` paths and an actual substitution event (a build whose log shows
nothing being rebuilt), with a negative control to prove the check is
capable of failing.

## 9. `DyndrvMode` variants

| Mode | Connection assumption | Can realize inline? | Pending-dependency representation left behind |
|---|---|---|---|
| `Sandbox` | Inside a `builder-rpc-v0` sandbox; daemon connection is opcode-restricted (`AddToStore*`/`SubmitOutput`/`AddTempRoot`/`IsValidPath` allowed; `BuildPaths`/`QueryMissing` rejected) | No, never | Depends on sub-path: (a) keyless, no unresolved text-stub dependency → eager file-granularity registration, leaving a **real symlink** into the registered `.drv`'s store path; (b) keyed, no unresolved text-stub dependency → eager accumulation into a growing multi-output group derivation, leaving a real symlink at the group's current head with an output-name suffix; (c) still depends on an unresolved text stub → falls back to the deferred path, leaving a **text stub** (§3.1) for later collection |
| `Rpc { autoforce }` | Unrestricted daemon connection (e.g. an ordinary dev shell / native environment, not inside a restricted sandbox) | Yes, if `autoforce` is set (builds the path and copies the result back); otherwise no | A real symlink to the immediately-registered `.drv` store path (registration itself is always eager and immediate in this mode, since the connection has no opcode restriction) |
| `Thunk { format: Nix, autoforce }` | No `ca-derivations`/`dynamic-derivations` feature requirement at all; never auto-selected, opt-in only | Yes, if `autoforce` (via a full graph build/realise round-trip), otherwise no | A content-addressed `.nix` expression file written to a workspace-relative path (`.dyndrv/thunks/<id>.nix`), with the output symlinked to that path |
| `Thunk { format: Drv, autoforce }` (experimental) | Same as above; no daemon call required for the write itself | Yes, if `autoforce` (one round-trip realizes the whole graph regardless of size), otherwise no | A real ATerm `.drv` file written to a workspace-relative path (`.dyndrv/thunks-drv/<id>.drv`), with its store path computed locally (mirroring the daemon's own registration computation) rather than obtained from a daemon round-trip |

Note on `Sandbox` mode's eager sub-paths: the decision of which sub-path
applies is made by checking whether *any* dependency of the current record
is still represented as an unresolved text stub — checking only whether the
record itself is keyed/keyless is insufficient, because `ar`/`ranlib`
records are always keyless regardless of the batch's overall granularity,
and a keyless record in a module-granularity (keyed) build can still depend
on inputs that are themselves keyed and still pending as text stubs.
