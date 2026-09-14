# Lessons Learned

A catalog of the hardest-won discoveries in dyn-drvs: specific Nix/nixpkgs
internals that caused real bugs, how each was actually diagnosed, and the
general engineering lesson that fell out of it. Written for someone about to
extend or re-implement parts of this system — treat every "root cause" below
as a landmine with the same shape elsewhere in nixpkgs.

## 1. The inner derivation's name is load-bearing, and nothing checks it at eval time

**What happened:** A producer's inner derivation must be named exactly
`"${pname}-${version}"` (the same `name` the outer `mkDynamicDerivation`
wrapper computes). Get it wrong and realization fails with `derivation has
incorrect output '<path>', should be '<expected>'`.

**Root cause:** For a CA/text-hashed derivation, the output store path is a
function of its *declared name*, not just its content. Nix enforces this at
realization time only — there is no eval-time check.

**The fix / how it was caught:** Confirmed by direct reproduction (deliberately
mis-naming an inner derivation and observing the realization-time error).
Documented directly in `mkDynamicDerivation.nix` (lines 45-58) as a hard
constraint on every producer.

**Generalizable lesson:** When a contract has no static enforcement, document
the invariant next to the code that depends on it — eval-time success proves
nothing about a naming contract that's only checked at build time.

## 2. `builder-rpc-v0`'s daemon opcode allowlist forbids realization, not just IFD

**What happened:** An earlier "materialize" mode tried to register-then-realize
a derivation inline, from inside a running build script. It worked under
`recursive-nix` but was unreachable and deleted once the codebase moved to
`builder-rpc-v0`.

**Root cause:** `daemon.cc:performOp`'s connection-mode allowlist for a
`builder-rpc-v0` ("RecursiveSubmitted") connection permits only
`AddToStore*`/`SubmitOutput`/`AddTempRoot`/`IsValidPath`. `BuildPaths` and
`QueryMissing` are absent and rejected outright — a sandboxed build under this
backend can register a derivation but can never build or block on one from
inside itself. `recursive-nix`'s `RestrictedStore`/`RestrictedBuilder` sandbox
is a structurally different capability that *can* call `BuildPaths`.

**The fix / how it was caught:** Every invocation now defers unconditionally
(writes a stub); nothing resolves inline. Resolution happens once, at the end
of the whole build, in `collectStubs.nix`.

**Generalizable lesson:** "Can register" and "can realize" are two separate
daemon capabilities gated independently — never assume a sandbox that can do
one can do the other; check the actual opcode allowlist for the connection
mode you're targeting.

## 3. Capability detection has exactly one eval-pure-safe signal — everything else is a guess

**What happened:** `capabilities.nix` needed to answer "can I use dynamic
derivations / recursive-nix / builder-rpc-v0 here?" purely at eval time.

**Root cause:** Only `dynamicDerivations = builtins ? outputOf` is a genuine,
pure, eval-safe signal. Whether `recursive-nix`/`builder-rpc-v0` *system
features* are actually schedulable is a property of the build farm, checked
only when Nix tries to schedule a build — there is no way to know this without
attempting a real build.

**The fix / how it was caught:** `recursiveNix` is approximated as equal to
`dynamicDerivations` (an assumption that projects turning one on generally
turn both on). `builderRpcV0`/`submitOutput` are hardcoded `false` — a
deliberately conservative default. A real probe is deferred to a future
`dyndrv doctor` CLI rather than faked at eval time.

**Generalizable lesson:** When a property genuinely can't be detected at eval
time, say so explicitly and pick a conservative default — don't approximate
your way into a false positive that only fails at schedule time on someone
else's farm.

## 4. `outputOf` rejects both derivation attrsets and `DrvDeep` string contexts

**What happened:** Calling `builtins.outputOf` directly on a derivation's
`.drvPath` throws: `has a context which refers to a complete source and binary
closure. This is not supported at this time`.

**Root cause:** Two separate, permanent restrictions baked into Nix itself
(locked in by `tests/functional/dyn-drv/eval-outputOf.sh`, which Nix's own
comment says exists "so we don't liberalise it by accident"): (1) `outputOf`
requires a literal string, not something that merely coerces to one; (2) a
`.drvPath`'s natural string context is `DrvDeep` (tracks the complete source +
binary closure), which `outputOf` refuses outright.

**The fix / how it was caught:** `mkOutputOf.nix` extracts `.drvPath` itself
when given a derivation, and unconditionally applies
`builtins.unsafeDiscardOutputDependency` before calling `outputOf` — a fix
independently rediscovered by every surveyed sibling project (drowse, nixgg,
dgd, sandstone). It's safe to apply unconditionally because it's a documented
no-op on strings already `Opaque` (e.g. chained from an earlier `outputOf`).

**Generalizable lesson:** When multiple independent projects converge on the
same workaround for the same primitive, that's a signal the workaround belongs
in a shared wrapper, not scattered call sites.

## 5. A dynamic derivation's real output needs two chained `outputOf` calls, not one

**What happened:** Resolving a `mkDynamicDerivation` output to something
usable requires calling `outputOf` twice, not once.

**Root cause:** The outer derivation's own output *is* the inner `.drv` file.
Level 1 `outputOf` resolves to that inner `.drv`; level 2 resolves that
`.drv`'s own output — the thing you actually wanted.

**The fix / how it was caught:** Confirmed against Nix's own oracle test
`testDynamicHello` in `eval-outputOf.sh`, which chains exactly two `outputOf`
calls for the same reason. `passthru.outputOf` bakes this chain in once so
callers never have to reason about it.

**Generalizable lesson:** When wrapping a primitive that composes, find the
upstream test suite's own worked example and match its exact chain depth
rather than re-deriving it from first principles.

## 6. `DownstreamPlaceholder::unknownCaOutput` is required because CA output paths don't exist at registration time

**What happened:** Building a multi-node graph, `graph.compile` needs to embed
one unit's dependency on another unit's *not-yet-built* output inside JSON
registered via `nix derivation add`, before that output exists.

**Root cause:** A CA/dynamic derivation's real output path is a hash of its
*content*, unknowable until it's actually built — yet registration for every
unit happens up front, in topo order, before any of them are built.

**The fix / how it was caught:** A bash port of Nix's own
`DownstreamPlaceholder::unknownCaOutput`: split the dependency's drvPath
basename into hash-part and name, form
`clearText = "nix-upstream-output:$drvHashPart:$outputPathName"`, SHA-256 it,
and nix32-encode with a leading `/`. Verified by direct reproduction against
Nix's own computed placeholder for a real CA derivation. Same-unit ("self")
references use a cheaper sentinel substituted via `builtins.placeholder`
instead, since no cross-derivation hash lookup is needed.

**Generalizable lesson:** When you need a stand-in for a not-yet-known
content-addressed path, don't invent your own scheme — Nix already has a
deterministic formula for exactly this (`DownstreamPlaceholder`); port it
byte-for-byte and verify against a real computed placeholder.

## 7. A pending build artifact must be a real file, never a symlink

**What happened:** Deferred stub files (written by `wrapCommand.nix`, read by
`collectStubs.nix`) had to be plain regular files — the header comment states
this explicitly.

**Root cause:** Nothing exists yet at the eventual output when a stub is
written, so a symlink to it would be dangling. Build tools routinely gate on
`test -e $expectedOutput` as a freshness check, and a dangling symlink fails
that test — silently breaking dependency tracking for every tool that relies
on plain existence checks.

**The fix / how it was caught:** The stub format is a two-line regular file:
`#!dyndrv-batch-pending` followed by a path to a JSON record. `writeStubFn`/
`readStubFn` are defined once, shared between writer and reader, so the format
can't drift.

**Generalizable lesson:** When faking "this output exists" for a downstream
tool, match what that tool actually checks (`test -e`, not "is this a valid
reference") — a technically-correct symlink can still fail a plain existence
test.

## 8. Reading a stub file safely requires guarding against EOF on both binary and short files

**What happened:** `readStubFn`'s two `read` calls are both guarded with
`|| true`.

**Root cause:** A genuine (non-stub) source file has no second line, so the
second `read` hits EOF. More surprisingly — confirmed by direct reproduction
against a real nixpkgs build tree's own `favico.ico` — a binary file with no
newline anywhere can make even the *first* `read` hit EOF. Under the caller's
`set -e`, an unguarded failure here would silently abort the entire calling
script rather than just returning "not a stub."

**The fix / how it was caught:** Guard every `read` used as a probe with
`|| true` when running under `set -e`, and treat "isn't a stub" as a normal,
non-erroring outcome.

**Generalizable lesson:** Under `set -e`, any command used purely to *probe*
a file's shape (not to require it) needs an explicit escape from the error
trap — otherwise a legitimate "not what I expected" answer becomes a fatal
script abort.

## 9. cwd-relative path frames: the same file gets two different relative-path strings

**What happened:** `ld.bfd: cannot find CMakeFiles/.../a.o` — a link step
failed to find an object file that had, in fact, been correctly compiled.

**Root cause:** A build tool (cmake's `cd build && cc CMakeFiles/.../a.o -o
exe`) routinely runs a link step from a different cwd than the compile that
produced its `.o` input. Both steps record their own cwd relative to
`NIX_BUILD_TOP`, so the same file on disk is referenced by two different
relative-path strings, and Phase 2's string-lookup dependency-matching in
`collectStubs.nix` silently drops the edge.

**The fix / how it was caught:** A new `record.cwd`/`DYNDRV_INVOCATION_CWD`
field, reconciled via `dyndrv_join_rel`/`dyndrv_relative_between` (bash) and
`Record.cwd`/`collect::{join_rel,relative_between}` (Rust). Confirmed by direct
reproduction: a nested, cwd-changing repro reproduced the exact `ld.bfd`
error.

**The regression the naive fix caused:** The first attempt joined
`record.cwd` directly against `dyndrv_buildRoot`-relative stub keys. That's
wrong because `record.cwd` is `NIX_BUILD_TOP`-relative while stub keys are
`dyndrv_buildRoot`-relative — and critically, even an *ordinary* compile with
no real cwd mismatch still has a non-empty `record.cwd` (buildRoot's own
offset, e.g. `"source"`), so the naive join corrupted dependency matching for
*every* invocation, not just mismatched ones. This was caught only once tried:
it broke example 05's own previously-working baseline link step with
`"cannot find main.o"` — a regression in a case that had nothing to do with
the bug being fixed.

**Generalizable lesson:** When two subsystems compute "relative path" against
different roots, normalizing only the mismatched case isn't enough — test the
*matched* (already-correct) case too, because a partial normalization can
break something that was never broken.

## 10. Multi-output collapse when `$out` gets baked into a build system's own config files

**What happened:** `phases.split`'s sandboxed phase 1 has no real `$out` — it
uses the literal placeholder string `/build/dyndrv-placeholder-out`. Packages
whose `configureFlags` bake `$out` literally into generated Makefiles (e.g.
real freetype's `--prefix=${dyndrvPlaceholderOut}`) freeze that placeholder
into the build system at configure time. Because phase 1 forces
`outputs = ["out"]`, every other output variable (`$dev`, `$man`, ...)
collapses to that same single literal too, and `make install` in phase 2
writes everything under the placeholder root instead of real per-output
paths, so `fixupPhase` fails since nothing exists under the real `$dev/include`.

**Root cause:** stdenv's `multiple-outputs.sh`/`_multioutConfig` machinery
assumes output variables reflect real, distinct paths at configure time; this
tool's placeholder-output design violates that assumption for any package
that reads `$out`/`$dev` before build time rather than only at install time.

**The fix / how it was caught:** `dyndrvRestoreOutput`, inserted right after
`installPhase` (before `fixupPhase`): `cp -r`s (not `mv`, to avoid clobbering
anything the caller's own `postInstall` hook wrote directly to the real
`$out`) the placeholder tree into the real `$out`, then explicitly re-invokes
stdenv's `_multioutDocs`/`_multioutDevs` immediately rather than relying on
the ordinary `preFixupHooks` array — confirmed by direct reproduction that a
caller's own hook (freetype's flatten-include-hack-hook) can run first and
expects `$dev/include` to already exist. The placeholder must be `/build`
specifically (not `/nonexistent`, not `$NIX_BUILD_TOP`) because the sandbox
root filesystem is `drwxr-x---` and unwritable even to the build group;
`/build` is Nix's own `sandbox-build-dir` and guaranteed writable, and it must
be a literal path (not an env var) since it has to resolve identically when
baked into a Makefile in phase 1 and read back in phase 2's separate sandbox.

**Generalizable lesson:** A build-output placeholder scheme is only safe if
you also handle the case where the package's own build system persists that
placeholder into generated config *before* the real path is ever known.

## 11. `outputBin`/`outputMan`/`outputDev` overrides survive a forced single-output `//` merge

**What happened:** `_assignFirst: could not find a non-empty variable` for
`outputMan`, confirmed on real libpng and libtasn1.

**Root cause:** `phases/split.nix`'s `sandboxedDrv` forces `outputs = ["out"]`
via `//`, but that merge doesn't clear an inherited literal override like
`outputBin = "dev";`. nixpkgs' `multiple-outputs.sh` sees `outputBin` already
non-empty and skips its own fallback logic, then
`_overrideFirst outputMan "man" "$outputBin"` fails because the variable it
was told to fall back to isn't actually populated the way it expects.

**The fix / how it was caught:** Open/unresolved in the corpus, with a
suggested fix: explicitly clear `outputBin`/`outputMan`/`outputDev` (not just
force `outputs`) when collapsing to single-output for phase 1.

**Generalizable lesson:** Forcing one attribute (`outputs`) doesn't
automatically neutralize *other* attributes whose semantics only make sense
relative to it — a `//` override is not a full “act as if this package never
set those” operation.

## 12. nixpkgs' `$phases` is computed dynamically — a static override silently drops hook-injected phases

**What happened:** `configurePhase` logged "no configure script, doing
nothing" for real mosh, despite `autoreconfHook` having actually fired.

**Root cause:** nixpkgs' `setup.sh` only computes `phases` dynamically via
`definePhases` when it's still empty (`if [ -z "${phases[*]:-}" ]`). Setup
hooks (like `autoreconfHook`'s `appendToVar preConfigurePhases
autoreconfPhase`) run unconditionally before any phase runs, but if `phases`
was already statically pre-populated (as `phases/split.nix`'s original
`phases = sandboxedPhases ++ [...]` did), the hook's injected phase name is
silently absent from that forced list — the hook ran, but its phase never got
scheduled.

**The fix / how it was caught:** Use `buildCommand` (stdenv's documented
escape hatch that skips `genericBuild`'s default body) to call `definePhases`
itself, walk the resulting `$phases` array, truncate at the last sandboxed
phase, then append the synthesized collection phase — preserving every
dynamically-injected phase rather than guessing the phase list up front.

**Generalizable lesson:** Never statically hardcode a list that nixpkgs itself
computes dynamically from hook side effects — run the real computation and
post-process its result instead of pre-empting it.

## 13. `finalAttrs.finalPackage` is a real self-reference some packages depend on

**What happened:** `error: attribute 'finalPackage' missing` at eval time,
before phase 1 ever ran, for real openssl.

**Root cause:** nixpkgs' `makeOverridable`/`extendMkDerivation` pattern
injects a `finalPackage` attribute into `finalAttrs` pointing at the
eventual returned derivation. Real, unmodified openssl reads
`finalAttrs.finalPackage.doCheck` at 3 call sites in its own recipe, relying
on that self-reference existing.

**The fix / how it was caught:** `mkAcceleratedStdenv.nix` reimplements the
`finalAttrs: {...}` convention, binding `finalPackage` to `result` (the
function's own eventual return value) — legal because Nix's laziness permits
a value to reference its own eventual binding as long as nothing forces it
too early.

**Generalizable lesson:** When reimplementing a nixpkgs convention
(`finalAttrs`), audit real downstream recipes for which self-referential
attributes they actually read, not just which ones the convention's
documentation mentions.

## 14. A custom `mkDerivation` needs its own `overrideAttrs`, or overrides silently vanish

**What happened:** `freetype.override{stdenv=...}.overrideAttrs(old: {patches
= old.patches ++ [x];})` applied only freetype's original 7 patches under the
accelerated stdenv — the added patch was silently dropped — versus all 8
patches under plain `pkgs.stdenv`.

**Root cause:** `phases.split`'s returned value is literally phase 2's own
derivation. nixpkgs' *default* `overrideAttrs` on that value would only
reconstruct phase 2, with `src` still pointing at phase 1's stale, already-
resolved output — silently dropping any override that needs to reach
`patchPhase`, which only runs in phase 1.

**The fix / how it was caught:** A custom `overrideAttrs` that re-runs the
*whole* `phases.split` call (phase 1 included) from scratch on every override,
computing `args = rattrs (args // { inherit finalPackage overrideAttrs; })`
as a lazy fixed point. Caught by direct comparison: same override applied
under accelerated stdenv vs. plain stdenv produced 7 vs. 8 patches.

**Generalizable lesson:** If you split one logical derivation into two real
derivations, the default `overrideAttrs` on the *outer* one only sees the
outer one — any override semantics that need to reach the *inner* stage must
be hand-rolled to re-run the whole pipeline, not just patch the tail.

## 15. CMake's compiler-flag probes and `TryCompile` scratch dirs need cwd-based, not argv-based, detection

**What happened:** Real nixpkgs zstd baked `-Qunused-arguments` (a
Clang-only flag) into `CMAKE_C_FLAGS` even though the actual compiler was gcc.

**Root cause:** A deferred stub always "succeeds," which breaks
compile-then-execute and should-legitimately-fail probes alike, since nothing
in argv distinguishes them from a real build. `mkAcceleratedStdenv`'s
passthrough detection recognized autoconf's `conftest`-named probes but had no
equivalent for CMake's `check_c_compiler_flag`/`TryCompile` naming — so a
stubbed probe for an unsupported flag "succeeded," and CMake wrongly
concluded the flag was supported.

**The fix / how it was caught:** `isCMakeProbe` checks
`DYNDRV_INVOCATION_CWD` for the `CMakeFiles/CMakeScratch/TryCompile-*`
marker, rather than scanning argv text — necessary specifically because
`wrapCommand.nix`'s own `stripPwdPrefix` strips the absolute cwd prefix from
every relative argv element before detection code ever sees it, so the
scratch-dir marker never survives in argv, only in the captured cwd.

**Generalizable lesson:** When a build tool's own convention (a scratch
directory name, a probe naming scheme) is the signal you need, check it where
it actually survives your pipeline's own text transformations — not
wherever seems most obvious.

## 16. `discoverTree`'s dependency scan structurally can't see link-step inputs

**What happened:** Link steps ended up with empty `inputs.drvs`, confirmed via
`nix derivation show` on a real `.drv`; reproduced independently on zstd,
pcre2, and mpfr (all cc/c++-driven links, not `ar`-driven).

**Root cause:** `discoverTree` runs `cc <args> -M -MG` to find files that need
staging before deferring a compile. On a link invocation (`.o`/`.a` files plus
`-o <exe>`, no `-c`), gcc treats those positional args as unused linker input
and `-M -MG` prints nothing — so the scan finds zero dependencies for a step
that has plenty.

**The fix / how it was caught:** Skip the `-M -MG` scan entirely when no `-c`
flag is present (pure efficiency win, confirmed harmless since a separate
positional-argv scan in `wrapCommand.nix` already preserves link dependencies
independently in the cases that do work) — but flagged as "not universal":
qmake-based builds' cc-driven links worked fine, so the actual scope of this
gap is still narrower than "every link step," and a general fix (fall back to
the ordinary per-file rewrite when `hasCompileFlag` is false) is stated but
not yet fully landed everywhere.

**Generalizable lesson:** A dependency-discovery mechanism built around one
compiler flag (`-M -MG`) only covers the invocation shapes that flag was
designed for (compiles) — audit every other invocation shape (links, archives)
the same tool is used for before trusting the same mechanism to cover them.

## 17. Automake's depcomp `-MF`/`mv` idiom produces an untracked secondary output

**What happened:** `mv: cannot stat ... No such file or directory`
immediately after a real compile succeeded, confirmed on real gperf.

**Root cause:** `toNode`/`collectStubs` track exactly one resolved output per
invocation (the `-o`/`-c` argument). Automake's depcomp idiom
(`-MF .deps/$*.Tpo` followed by an `mv` to the final `.deps/$*.Po`) produces a
*second*, untracked output file that never survives the sandbox boundary —
the primary object file round-trips correctly, the depfile silently doesn't.

**The fix / how it was caught:** Open/unresolved in the corpus; flagged as
likely high-impact since the depcomp idiom is common across autotools
projects generally, not specific to gperf.

**Generalizable lesson:** A "track the declared output" model is only as
complete as your enumeration of what a real invocation actually writes —
common build-system idioms produce side outputs (depfiles, listing files,
`.tmp`-then-`mv` patterns) that a single-output model won't see.

## 18. Two deferred invocations targeting the identical output path silently discard each other

**What happened:** `ar cr libfreetype.a *.o` followed immediately by
`ranlib libfreetype.a` both write a stub at the same archive path; a naive
implementation discarded `ar`'s own record — and with it its dependency on
every compiled `.o` — the moment `ranlib`'s stub write landed on the same
path, later registering only the `ranlib` step with no inputs at all
(`ranlib: not found`). Confirmed by direct reproduction against a real
freetype build.

**Root cause:** Each deferred invocation's stub write is, by default, an
overwrite at its output path with no awareness that a *different* invocation
already wrote a pending stub there for the same file.

**The fix / how it was caught:** `chainedFrom`: `wrapCommand.nix`'s
`finalizeTail` checks whether the output path is already a pending stub from
an earlier deferred invocation, and if so, sets `chainedFrom` to that earlier
record's path instead of overwriting it. `dyndrv_record_chain` walks this
pointer back to render every chained step, oldest first, unioning every
step's deps rather than just the newest.

**Generalizable lesson:** Any "one output, one record" model breaks the
moment a real toolchain idiom (`ar` then `ranlib` on the same archive) issues
multiple sequential writes to the same path — treat same-path stub writes as
a chain to preserve, not a slot to overwrite.

## 19. Four independent script-rendering call sites drifted apart on a single trailing separator

**What happened:** A mismatched trailing `"; "` between two hand-written
script-construction call sites produced two *different* ATerm byte strings
for the logically identical single-record case.

**Root cause:** dyndrv's Rust port had four independent call sites
(`Rpc`-mode `record_to_derivation`, `Sandbox`-mode `render_member`/
`render_unit`, `Thunk{Drv}`-mode `write_drv_thunk`, and group-accumulation
`append_member`) each hand-constructing the same setup/seed/command-join
logic — a natural target for silent divergence as each was edited
independently over time.

**The fix / how it was caught:** Unified all four into one shared
`render_record_line` function, making the class of divergence a compile-time
impossibility rather than something a test has to keep re-confirming. Backed
by a `cross_mode_tests` module asserting byte-identical ATerm output across
modes for several `Record` shapes — critically including a two-step chained
`ar`+`ranlib` record, the exact shape that originally exposed the bug (a
solo record's missing separator has nothing after it to misalign, so it
happened to still pass even with the bug present).

**Generalizable lesson:** When the same logic must produce byte-identical
output from multiple independent call sites, delegate to one shared function
rather than trusting hand-copied duplicates to stay in sync — and make sure
your regression test actually exercises the multi-step case, since the
degenerate single-step case can pass despite the bug.

## 20. Per-node registration overhead is a fixed ~80ms tax, and it dominates for small compiles

**What happened:** freetype — this tool's own flagship "works correctly" proof
point, registering exactly the right derivations and rebuilding only what
changed — is nonetheless a *wall-clock loss*: 0.06x-0.35x in dyn-drvs' own
benchmarks, independently reconfirmed at 0.15x (~6.7x slower) in a separate
downstream repo's measurements.

**Root cause:** Every registered dynamic derivation pays a fixed ~80ms
`nix derivation add` CLI-roundtrip tax, regardless of how fast the underlying
compile is. The break-even point measured directly (`BASELINE.md`, 30 files
at LOOPS=400) is roughly 200-300ms of real per-translation-unit compile time
— below that, the registration tax exceeds the savings from skipping
unchanged work.

**The fix / how it was caught:** Not really "fixed" — documented as an
inherent property of the mechanism. Caught by direct wall-clock measurement
against a real package (freetype) rather than a synthetic microbenchmark, and
independently reconfirmed in a separate codebase's own measurement, which
matters: a single measurement could be an artifact of one repo's setup, but
two independent measurements agreeing is a real property of the mechanism.

**Generalizable lesson:** A correctness win (rebuild only what changed) is not
automatically a performance win — always measure against the fixed
per-unit overhead of your own registration mechanism, and state the
crossover point explicitly rather than a single "faster/slower" verdict.

## What reliably breaks this tool, and why

Beyond the individual bugs above, the accumulated validation evidence (both
dyn-drvs' own examples and an independent downstream survey of 8+ real
packages) draws a consistent boundary: this mechanism works today for C/C++
projects built via a **plain, hand-written Makefile** with no autotools,
libtool, cmake, or meson — giflib, tree, figlet, nnn. It reliably breaks on
autotools/libtool idioms (depcomp side-outputs, `autoreconfHook`'s dynamic
phase injection), on cmake-generated builds (both source-path resolution and
compiler-flag-probe naming), on any cc/c++-driven (as opposed to ar-driven)
link step, and on packages that read nixpkgs' own `finalAttrs.finalPackage`
self-reference or set `outputBin`/`outputMan`/`outputDev` explicitly. Every
tier of real-package testing past the original single fixture surfaced a
*new*, previously undiscovered gap, and every one of them traced back to an
autotools- or cmake-specific build-system idiom — never to a plain Makefile.
Treat "plain Makefile, ar-based static lib, no configure/cmake/meson" as the
actual validated scope, not the README's broader claim.

## Meta-lessons on the engineering process itself

- **Build a byte-identical ground-truth oracle before trusting a refactor.**
  The Rust port's `cross_mode_tests` module didn't just test outputs looked
  "close enough" — it asserted byte-identical ATerm strings across four
  independent code paths, which is what actually caught the trailing-`"; "`
  divergence. Fuzzy equivalence checks would have missed it.

- **A minimal, single-variable repro is what turns a hypothesis into a fact.**
  The cwd-relative-path-frame bug, the discoverTree link-step blind spot, and
  the `NIX_STORE`-unbound-variable crash were each pinned down by isolating
  one variable in a deliberately minimal reproduction (a nested cwd-changing
  build, a link-only invocation, a stripped-down env) rather than reasoning
  from the original failing package alone.

- **Confirm a fix against the case that *wasn't* broken, not just the case
  that was.** The naive cwd-frame fix passed on the mismatched case it was
  designed for and broke a previously-working, unmismatched case — the
  regression was only caught because someone re-ran the existing baseline
  fixture after applying the fix, not just the new one.

- **Document blocked and negative results as first-class findings.** Every
  "open, unresolved" bug above (cmake source-path resolution, exec-bit loss,
  outputBin collapse, depfile side-outputs) is written up with the same rigor
  as a fixed bug — root cause traced as far as known, reproduction steps
  preserved, suggested fix stated even when not implemented. A catalog that
  only records successes would misrepresent the tool's actual validated
  scope.

- **Independent re-confirmation matters more than a single measurement.**
  The registration-tax finding and the "breaks on cmake/autotools" boundary
  both gained real credibility only once a *separate* downstream repo,
  measuring independently, reproduced the same numbers and the same failure
  shapes — treat a single benchmark or a single repro as a hypothesis, and a
  second independent one as confirmation.
