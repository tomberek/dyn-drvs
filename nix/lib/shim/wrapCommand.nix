{ pkgs, lib, self }:

# Intercepts a toolchain command on `$PATH` (e.g. `cc`) so that, instead of
# running immediately, each invocation writes a batch-pending STUB (see
# `batchStub.nix`) and returns instantly, with zero compile work done and
# nothing registered with Nix yet. `accelerate.mkAcceleratedStdenv` is
# built from this; `shim.collectStubs` is what resolves every stub a real
# build leaves behind, afterward.
#
# WHY EVERYTHING DEFERS, UNCONDITIONALLY (no "materialize now" mode):
# earlier versions of this file also supported an immediate
# register-then-realize-inline mode ("materialize"), which needed the
# `recursive-nix` backend's own `RestrictedStore`/`RestrictedBuilder`
# (the only one of the two backends whose sandbox can actually call
# `BuildPaths`/realize a derivation from inside a running script).
# `builder-rpc-v0` ("RecursiveSubmitted" connections) categorically
# cannot do this -- confirmed by reading Nix's own `daemon.cc:performOp`
# connection-mode allowlist: it permits only `AddToStore*`/`SubmitOutput`/
# `AddTempRoot`/`IsValidPath`; `BuildPaths`/`QueryMissing` are absent and
# rejected outright. A `builder-rpc-v0` shim can register a node but can
# NEVER realize it or block on the result mid-script. Since
# `mkAcceleratedStdenv` now runs entirely on `builder-rpc-v0` (dropping
# its earlier `recursive-nix` dependency), "materialize" is no longer
# reachable and has been removed from this file entirely, along with its
# `nix derivation add`/`nix-store --realise` inline calls -- every
# invocation defers, always; nothing in `wrapCommand` itself ever
# resolves a deferred stub, that's `shim.collectStubs`'s job, run once at
# the end of the whole build rather than per-invocation.
#
# `command`: the command name being intercepted (e.g. "cc") -- informational,
#   used only in error messages; callers install the returned script at
#   `<wrapperDir>/bin/<command>` themselves.
# `realCommand`: absolute path to the real command this wrapper shadows.
#   Used for passthrough (see `toNode` below).
# `toNode`: a Nix expression STRING, `argv: { defer = { record }; outputArg
#   | outputPath } | null`:
#   Returning `null` (a PASSTHROUGH) skips deferral entirely and execs
#   `realCommand` directly with the original argv -- this is how
#   `accelerate.mkAcceleratedStdenv` tells configure-time feature probes
#   and other non-graph invocations to run for real, immediately, since
#   they're not part of the package's own cacheable build graph and have
#   no caching value; `wrapCommand` itself doesn't know or care which
#   invocations should be accelerated, that policy lives entirely in the
#   caller-supplied `toNode`.
#   Otherwise, `toNode` returns:
#     - `defer`: `{ record }`. `record`: a PRE-SERIALIZED
#       (`builtins.toJSON {...}`) STRING (same "must be pre-serialized"
#       reasoning `viaDerivationAdd.nix`/`graph.compile`'s per-node
#       `mkDrv` already documents: `nix-instantiate --eval --json`
#       without `--strict` fails with "cannot convert a thunk to JSON" on
#       any attrset containing a `builtins.toJSON`-produced value -- the
#       fix, used by `wrapperScript` below, is `--eval --strict --json`
#       together), carrying everything `shim.collectStubs` needs to
#       compile this member for real, later, plus its own batch-group
#       `key` as one of its fields (a plain string, e.g. a directory
#       name -- `collectStubs` only combines records sharing the exact
#       same `key` into one derivation; a member with no `key` set is its
#       own solo unit). `wrapCommand` never inspects `record`'s contents
#       -- it's opaque here, written to a record file verbatim and left
#       for `collectStubs` to read back later.
#     - `outputArg`: the index into `argv` naming the file path the
#       CALLING build tool expects to exist after this command returns.
#       `argv` is `$@` as the wrapper script sees it, WITHOUT the command
#       name itself (i.e. NOT including `$0`) -- so for `cc -c foo.c -o
#       foo.o`, `argv = ["-c" "foo.c" "-o" "foo.o"]` and `outputArg = 3`
#       names `foo.o` (index 3, zero-based). The wrapper writes a
#       batch-pending stub there -- the outer build process sees an
#       ordinary file at the path it asked for, satisfying its own `test
#       -e` prerequisite check, without any compile having happened yet.
#       Mutually exclusive with `outputPath` below -- supply exactly one.
#     - `outputPath` (ALTERNATIVE to `outputArg`): a literal RELATIVE path
#       string, for invocations with no `-o` at all -- a real, common
#       case: `libtool --mode=compile` invokes the real compiler as
#       `cc -c foo.c ... -fPIC -DPIC`, with no `-o` flag, relying on the
#       compiler's own documented default (source basename, extension
#       stripped, `.o` appended, written to the CURRENT DIRECTORY
#       regardless of the source file's own directory). Since no argv
#       index names this path, `toNode` must compute it itself (see
#       `accelerate/mkAcceleratedStdenv.nix`) and return it directly.
#   Instantiated once PER INVOCATION with `argv` bound to this call's
#   actual arguments (a JSON array of strings, crossing the eval->build
#   boundary the same way `viaNixInstantiate`'s own `args` does).
# `nixPackage`: the Nix to run `nix store add`/`nix store add-file` with,
#   inside the sandbox, for the staging steps below (this file itself
#   never registers/realizes anything -- see `shim.collectStubs` for
#   that).
# `discoverTree`: OPTIONAL bash script TEXT, run as `bash -c "$discoverTree"
#   -- "$@"` with the ORIGINAL compiler argv as its own positional params.
#   Exists for compilers whose real invocations depend on RELATIVE `-I`
#   search paths across a multi-directory source tree -- the default
#   per-file, flatten-to-basename rewrite below can't support this, since
#   flattening destroys the relative directory structure `-I` depends on.
#   Must print every RELATIVE path (sources AND headers, one per line)
#   this invocation needs beyond argv's own positional files -- typically
#   the output of a `cc -M -MG`-style dependency scan (see
#   `accelerate/mkAcceleratedStdenv.nix`). When set:
#     - the old per-file "rewrite relative paths to their own store path"
#       behavior is SKIPPED entirely (it would destroy the relative
#       structure this mode exists to preserve);
#     - every relative file argv already names, PLUS every path
#       `discoverTree` prints, is staged into ONE scratch directory that
#       mirrors their original relative layout, added to the store as a
#       SINGLE unit (`nix store add`, which preserves directory structure,
#       unlike `nix store add-file`), and its basename exported as
#       `DYNDRV_TREE_BASENAME` -- `toNode` reads this via
#       `builtins.getEnv "DYNDRV_TREE_BASENAME"` to build a `record` whose
#       `setupCmd` `cp -r`s that ONE tree into the shared working
#       directory before running the REAL command with argv UNCHANGED
#       (still relative);
#     - `argv` as seen by `toNode` is therefore the RAW, unmodified
#       original argv in this mode (NOT rewritten to absolute store
#       paths) -- `toNode` must reference that tree basename in its own
#       `record.srcs` (one directory input), not per-file basenames, when
#       `discoverTree` is active.
# `toNodeBash`: OPTIONAL POSIX-sh function-body TEXT, an alternative to
#   `toNode` that AVOIDS spawning `nix-instantiate` (a full Nix evaluator
#   boot) per intercepted invocation -- confirmed by direct measurement to
#   be the single largest per-call cost in this shim, well beyond `jq`'s
#   own fork+exec (nixgg's own registration-tax findings, re-confirmed
#   here: process/interpreter STARTUP dominates, not the actual decision
#   logic, which for `accelerate.mkAcceleratedStdenv`'s `toNode` is pure
#   string prefix/suffix manipulation with no structural need for a Nix
#   evaluator at all). When set, takes priority over `toNode` for EVERY
#   invocation (mutually exclusive in practice -- a caller supplies one or
#   the other, not both; `toNode` stays required so existing/future
#   callers that genuinely need arbitrary Nix-expression logic, or that
#   haven't been ported, keep working unmodified).
#
#   Contract: a shell function body (not a full script -- no `#!` line,
#   no surrounding braces; this wrapper's own scripts declare `#!/bin/sh`
#   but always actually run under bash inside a Nix sandbox -- nixpkgs'
#   own stdenv symlinks `/bin/sh` to bash there unconditionally,
#   regardless of the HOST's own `/bin/sh` -- so bash builtins are safe,
#   though this contract deliberately only requires POSIX `"$@"`
#   positional-parameter passing, not bash arrays, since that's simpler
#   and there's no need for the extra syntax) defining a function named
#   `dyndrv_to_node` that reads argv via ordinary positional parameters
#   (`"$@"`, called as `dyndrv_to_node "$@"` after the SAME rewriting --
#   rewritten-to-store-path / stripped-pwd-prefix as appropriate for the
#   variant in use -- `toNode`'s own `argv` JSON list would have
#   received) and prints EXACTLY what `resolveNodeFields` below expects
#   to read: either the bare text `null` (PASSTHROUGH, mirrors `toNode`'s
#   own `null` return), or a JSON object shaped like `toNode`'s own
#   return value (`{"defer":{"record":"<pre-serialized-JSON-string>"},
#   "outputArg":<int>}` or `..."outputPath":"<string>"}`). Helper
#   functions available in scope (defined earlier in the SAME wrapper
#   script, so `toNodeBash`'s own body can call them directly):
#   `dyndrv_read_batch_stub` (from `batchStub.nix`, already sourced).

# `toNodeCompiled`: OPTIONAL, a derivation providing `bin/dyndrv-shim` (see
#   `rust/dyndrv-shim`) -- an alternative to BOTH `toNode` and `toNodeBash`
#   that replaces the ENTIRE wrapper script (not just the decision step)
#   with one compiled-binary exec: no `nix-instantiate`, no `jq`, no `nix
#   store add-file`/`add` subprocess -- the binary does its own argv
#   rewriting, decision logic, and stub-write natively, using the raw
#   daemon worker-protocol client (`nix-builder-rpc-client`) for staging.
#   Takes priority over `toNodeBash`/`toNode` when set. `DYNDRV_TOOL` is
#   set to THIS wrapper's own `command` param and exported before the
#   exec, so the binary knows which decision logic to dispatch to
#   ("ar"/"ranlib"/"cc") -- NOT `argv[0]`/`exec -a`: confirmed by direct
#   reproduction that this wrapper's own `#!/bin/sh` is NOT always bash
#   the way a Nix sandbox's `/bin/sh` is (only nixpkgs' own stdenv
#   guarantees that -- see `toNode`'s bash-availability comment above);
#   run directly on a host whose real `/bin/sh` is dash (e.g. via
#   `shim.devShell`'s wrapper, outside any sandbox), `exec -a` is a
#   bash-only builtin and fails outright ("exec: -a: not found"). A
#   plain env var works under any POSIX `/bin/sh`.
#   `compiledEnv`: extra env vars (name -> value strings) the binary's own
#   decision logic needs (e.g. `DYNDRV_REAL_COMMAND`/
#   `DYNDRV_BINTOOLS_BASENAME` for `ar`/`ranlib`, `DYNDRV_COREUTILS_BASENAME`/
#   `DYNDRV_STDENV_CC_BASENAME`/`DYNDRV_BATCH_GROUPS` for `cc`) -- exported
#   before the exec. `discoverTree` (the Nix-level PARAMETER) has no
#   effect when `toNodeCompiled` is set -- the binary decides internally,
#   based on `DYNDRV_TOOL`, whether to run the plain or discoverTree-
#   equivalent pipeline (`rust/dyndrv-shim/src/cc.rs`'s own
#   `discover_tree`/`cc_to_node`, invoked via `wrapper::run_discover_tree`
#   for `cc` specifically) -- so passing both is harmless, just redundant.
#
# `DYNDRV_BYPASS` (an ENV VAR the CALLER sets around a build step, not a
#   Nix-level parameter of this function): checked FIRST, before any
#   other logic, in every one of `wrapperScript`'s three variants -- if
#   set (to anything non-empty), `exec`s straight to `realCommand` with
#   the original argv, skipping deferral/decision logic entirely.
#   Mirrors nixgg's own identical `NIXGG_BYPASS` mechanism exactly (same
#   name convention, same "checked first, unconditional passthrough"
#   semantics). This is DIFFERENT from `toNode` returning `null` (a
#   PASSTHROUGH decision made per-invocation, by argv-shape heuristics
#   like `is_conftest`'s `conftest*`-basename check): `DYNDRV_BYPASS` is
#   a blanket, caller-controlled override for an ENTIRE build step whose
#   own invocations can't be reliably distinguished by argv shape alone
#   -- the motivating case is meson/cmake's own configure-time compiler
#   probes (`meson setup`'s sanity check, every `compiler.compiles()`/
#   `.has_function()` check), named `testfile.<ext>`/`sanitycheck{c,
#   cpp,...}.*` by meson -- NOT `conftest*` -- so `is_conftest` never
#   catches them, and deferring them breaks meson's own synchronous
#   pass/fail configure logic outright (it needs the real exit code/
#   output immediately, not a batch-pending stub). A caller (e.g.
#   `accelerate.mkAcceleratedStdenv`'s own callers, via `preConfigure`/
#   `postConfigure`) sets `DYNDRV_BYPASS=1` around `meson setup`/`cmake`
#   and unsets it before the real `ninja`/`make` build step runs.
#
{
  command,
  realCommand,
  toNode,
  toNodeBash ? null,
  toNodeCompiled ? null,
  compiledEnv ? { },
  nixPackage ? pkgs.nix,
  discoverTree ? null,
}:


let
  inherit (self.shim.batchStub) writeStubFn readStubFn;

  # Resolves `$outputPath`/`$payload` from `$node`/`$argvJson` in ONE `jq`
  # call -- shared by both `wrapperScript` variants below, immediately
  # before `finalizeTail`. This script runs on EVERY intercepted command
  # invocation during a real build, so collapsing what would otherwise be
  # 2 separate `jq` spawns into 1 matters here.
  resolveNodeFields = ''
    { IFS= read -r outputPath; IFS= read -r payload; } < <(
      printf '%s' "$node" | ${pkgs.jq}/bin/jq -r --argjson argv "$argvJson" '
        (has("outputArg")) as $hasArg |
        (if $hasArg then $argv[.outputArg] else .outputPath end) as $outputPath |
        $outputPath, .defer.record
      '
    )
  '';

  # Computes `$node` (a JSON string, or the bare text `null`) -- decided
  # ONCE, at Nix EVAL time (not per-invocation), which of the two
  # mechanisms to embed: `toNodeBash` (when set) calls the caller's own
  # `dyndrv_to_node` shell function directly, with NO subprocess beyond
  # ordinary shell built-ins; `toNode` (the fallback) spawns
  # `nix-instantiate` -- a full Nix evaluator boot -- per invocation, the
  # single largest measured per-call cost in this shim (see `toNodeBash`'s
  # own header comment for the full rationale). Both variants assign the
  # SAME `$node` shell variable, so `resolveNodeFields` below is
  # completely agnostic to which path produced it.
  #
  # The `toNodeBash` branch calls `dyndrv_to_node` inside a FUNCTION (not
  # inline) specifically so `set --`ing the rewritten argv onto its own
  # positional parameters is scoped to that function's own call frame --
  # plain shell `set --` has no other way to swap "$@" temporarily
  # without a function boundary, and the CALLER's own real "$@" (needed
  # unchanged for the PASSTHROUGH `exec` immediately afterward) must
  # never be touched. Reads `$dyndrv_rewritten_argv` (set by each
  # wrapperScript variant right before this splice -- see either
  # variant's own comment for what "rewritten" means for it), one
  # element per line.
  computeNodeScript =
    if toNodeBash != null then
      ''
        ${toNodeBash}
        dyndrv_call_to_node() {
          set --
          while IFS= read -r a; do
            set -- "$@" "$a"
          done <<DYNDRV_REWRITTEN_ARGV
        $dyndrv_rewritten_argv
        DYNDRV_REWRITTEN_ARGV
          dyndrv_to_node "$@"
        }
        node=$(dyndrv_call_to_node)
      ''
    else
      ''
        nodeExprFile=$(mktemp)
        cat > "$nodeExprFile" <<'DYNDRV_TONODE_EXPR'
        ${toNode}
        DYNDRV_TONODE_EXPR

        argvFile=$(mktemp)
        printf '%s' "$argvJson" > "$argvFile"

        node=$(ARGV_PATH="$argvFile" nix-instantiate --eval --strict --json --expr \
          "let argv = builtins.fromJSON (builtins.readFile (builtins.getEnv \"ARGV_PATH\")); f = import $nodeExprFile; in f argv" 2>/dev/null)
        rm -f "$nodeExprFile" "$argvFile"
      '';

  # Shared "finalize" tail, appended after BOTH wrapperScript variants
  # have resolved `$outputPath`/`$payload`. Every non-passthrough
  # invocation defers -- write a batch-pending stub and a JSON record
  # file alongside it, then exit 0 immediately. Nothing in THIS script
  # ever reads the record back -- that's `shim.collectStubs`'s job, run
  # once at the end of the whole build.
  #
  # If `$outputPath` is ALREADY a pending stub from an EARLIER deferred
  # invocation, CHAIN onto it (`chainedFrom`) rather than overwriting --
  # confirmed necessary by direct reproduction against a real freetype
  # build: libtool runs `ar cr libfreetype.a *.o` (deferred, depending on
  # every `.o`) immediately followed by `ranlib libfreetype.a` on the
  # SAME path (also deferred, operating on that archive in place). A
  # naive overwrite silently discarded `ar`'s own record -- and with it,
  # its dependency on every compiled `.o` -- the moment `ranlib`'s stub
  # write landed on the same path, so `shim.collectStubs` registered
  # only the `ranlib` step with NO inputs at all ("ranlib: not found",
  # since nothing declared its own binary as a store input either).
  # `shim.collectStubs`'s `dyndrv_record_chain` walks this pointer back
  # to render EVERY step, oldest first, and to union every step's own
  # `args`-derived deps and `srcs`, not just the newest one's.
  finalizeTail = ''
    chainedFrom=$(dyndrv_read_batch_stub "$outputPath")
    recordPath=$(mktemp)
    if [ -n "$chainedFrom" ]; then
      printf '%s' "$payload" | ${pkgs.jq}/bin/jq --arg chainedFrom "$chainedFrom" '. + {chainedFrom: $chainedFrom}' > "$recordPath"
    else
      printf '%s' "$payload" > "$recordPath"
    fi
    ${writeStubFn}
    dyndrv_write_batch_stub "$outputPath" "$recordPath"
    # Automake's classic depcomp idiom (`-MT $@ -MD -MP -MF
    # .deps/$*.Tpo` alongside `-c -o $@`) writes a SECOND file as a
    # byproduct of the same compile, then the OUTER, unaccelerated
    # `make` process immediately runs `mv -f .deps/$*.Tpo .deps/$*.Po`
    # on it -- see `docs/depfile-side-output-bug.md` for the full
    # writeup. Only the primary `-o`/`outputArg` output gets a deferred
    # stub above; `-MF <path>`'s own value is never tracked at all, so
    # that `mv` fails outright ("No such file or directory") the moment
    # this compile defers instead of running for real -- confirmed via
    # direct reproduction against real nixpkgs gperf, every one of its
    # ~20 real per-TU compiles failing identically at the Makefile line
    # immediately after the (successfully deferred) compile stub.
    # Since Nix always rebuilds fully from scratch (no cross-derivation
    # incremental-depfile reuse the way a real, unaccelerated `make`
    # re-run would exploit -- the eventual real compile, once it runs
    # for real inside `shim.collectStubs`'s own deferred derivation,
    # writes ITS OWN copy of this same file inside that derivation's
    # own isolated sandbox, but that derivation only ever tracks the
    # primary `.o` as a real Nix output, so this copy is simply
    # discarded, never fed back anywhere `make`'s own dependency
    # tracking reads from again), the depfile's CONTENT is irrelevant
    # here -- only its EXISTENCE, in THIS outer, unaccelerated tree,
    # matters, so the immediately-following `mv` succeeds. An empty
    # file is sufficient:
    # confirmed by direct reading of automake's own `depcomp` script
    # (`gcc3` mode: `"$@" ...; mv "$tmpdepfile" "$depfile"` -- the `mv`
    # only checks the file EXISTS, never its content) and by direct
    # reproduction against real gperf with this exact fix. Scans the
    # ORIGINAL, not-yet-batched argv (`"$@"`, this wrapper script's own
    # positional params, unrelated to `argvForCc`'s rewritten "$out"
    # sentinel) for `-MF <path>`, touching an empty file there (relative
    # to the invocation's own real cwd, NOT `$treeDir` -- the `mv` reads
    # from the caller's own working directory, never the per-invocation
    # staging tree this script already tore down by this point).
    dyndrv_mf_next=0
    for dyndrv_mf_a in "$@"; do
      if [ "$dyndrv_mf_next" = 1 ]; then
        case "$dyndrv_mf_a" in
          /*) ;; # an absolute depfile path is a real store/build input already, not this invocation's own byproduct to touch
          *)
            ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$dyndrv_mf_a")" 2>/dev/null || true
            : > "$dyndrv_mf_a" 2>/dev/null || true
            ;;
        esac
        dyndrv_mf_next=0
      elif [ "$dyndrv_mf_a" = "-MF" ]; then
        dyndrv_mf_next=1
      fi
    done
  '';
in
{
  # The wrapper script's content. Callers place this at
  # `<wrapperDir>/bin/<command>` (mode 0755) and prepend `<wrapperDir>/bin`
  # to `$PATH` ahead of the real toolchain.
  wrapperScript =
    if toNodeCompiled != null then
      ''
        #!/bin/sh
        set -eu
        if [ -n "''${DYNDRV_BYPASS:-}" ]; then
          exec ${realCommand} "$@"
        fi
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}") compiledEnv
        )}
        export DYNDRV_TOOL=${lib.escapeShellArg command}
        exec ${toNodeCompiled}/bin/dyndrv-shim "$@"
      ''
    else if discoverTree == null then
      ''
        #!/bin/sh
        set -eu
        if [ -n "''${DYNDRV_BYPASS:-}" ]; then
          exec ${realCommand} "$@"
        fi

        export PATH="${nixPackage}/bin:$PATH"
        export NIX_CONFIG='extra-experimental-features = nix-command ca-derivations dynamic-derivations'
        # `toNode` (the NESTED `nix-instantiate --eval` this script's own
        # `computeNodeScript` below spawns) needs to know THIS wrapper's
        # own `realCommand` -- `mkAcceleratedStdenv.nix`'s `ccShim`/
        # `cxxShim` share the IDENTICAL `toNode` string (both need the
        # SAME discovery/deferral logic; only the underlying tool binary
        # differs), so `toNode` can't just splice in a single fixed
        # `''${realCc}` at DEFINITION time -- that bakes `cc` into
        # `record.tool` even for a `c++`-invoked deferral, which then
        # ACTUALLY LINKS via plain `cc` at build time instead of `c++`/
        # `g++`, and `cc` alone never auto-links `libstdc++` the way
        # `c++` does (confirmed by direct reproduction against
        # `nix-util-c`'s own link: missing `operator new`/`delete`,
        # `__cxa_throw`, RTTI vtables -- core runtime symbols only
        # `libstdc++` provides). `nix-instantiate` inherits this WHOLE
        # shell's own environment (already relied on for `NIX_SET_
        # BUILD_ID`/`NIX_CFLAGS_COMPILE`/etc., see `wrapperEnvPairs`),
        # so exporting it here lets `toNode` read it back via
        # `builtins.getEnv "DYNDRV_REAL_COMMAND"`.
        export DYNDRV_REAL_COMMAND="${realCommand}"

        ${readStubFn}

        # Absolute-but-actually-relative paths first: some real build
        # tools (e.g. libtool's own `ar`/`ranlib` invocations, confirmed
        # by direct reproduction against a real freetype build) pass
        # paths like `/build/freetype-2.14.3/objs/ftbase.o` -- absolute
        # in TEXT, but relative to the calling build's own `$PWD`, not a
        # real Nix store path. Left unstripped, the `case` below's `-*`/
        # `/nix/store/*` arms don't match (it's neither a flag nor a
        # store path) so it fell into the relative-file branch, but as
        # an ABSOLUTE string -- `shim.collectStubs` only ever recognizes
        # stub/dependency paths by their RELATIVE form, so an absolute
        # sibling reference here silently failed to resolve as a
        # dependency at all (e.g. `ar cr liba.a /build/.../a.o` lost its
        # entire dependency on `a.o`). Mirrors the `discoverTree`
        # variant's own `stripPwdPrefix`, needed here for the identical
        # reason even though this variant never stages a tree.
        origPwd=$(${pkgs.coreutils}/bin/pwd)
        stripPwdPrefix() {
          case "$1" in
            "$origPwd"/*) printf '%s' "''${1#"$origPwd"/}" ;;
            *"$origPwd"/*)
              printf '%s%s' "''${1%%"$origPwd"/*}" "''${1#*"$origPwd"/}"
              ;;
            *) printf '%s' "$1" ;;
          esac
        }
        firstArg=1
        for a in "$@"; do
          a=$(stripPwdPrefix "$a")
          if [ "$firstArg" = 1 ]; then
            set -- "$a"
            firstArg=0
          else
            set -- "$@" "$a"
          fi
        done

        # This invocation's own cwd, relative to `NIX_BUILD_TOP` (stable
        # across the WHOLE sandboxed build, confirmed by direct
        # reproduction -- see `collectStubs.nix`'s own matching comment
        # on `.dyndrv-build-relpath`) -- exported so `toNode`/
        # `toNodeBash` can record it on `record.cwd`. Needed because a
        # build tool routinely `cd`s into a subdirectory (e.g. cmake's
        # generated `cd build && cc CMakeFiles/.../a.o ... -o exe`)
        # BEFORE invoking this wrapper, so a link step's own relative
        # argv (e.g. "CMakeFiles/.../a.o") and the EARLIER compile
        # step's own discovered stub path (relative to `collectStubs`'
        # fixed `buildRoot`, e.g. "build/CMakeFiles/.../a.o") are two
        # DIFFERENT strings for the identical real file -- without
        # recording each invocation's own cwd offset, `collectStubs`'
        # plain string comparison between a record's own `args` and its
        # discovered stub paths can never connect the two, silently
        # dropping the dependency edge (confirmed by direct reproduction:
        # a nested, cwd-changing repro reproduces `ld.bfd: cannot find
        # CMakeFiles/.../a.o`, while the identical repro with NO cwd
        # change between producer and consumer succeeds). Pure string
        # arithmetic (`-m`), not a real filesystem check -- `origPwd`
        # always exists, but this mirrors the same primitive used
        # elsewhere for the same reason.
        dyndrvInvocationCwd=$(${pkgs.coreutils}/bin/realpath -m --relative-to="''${NIX_BUILD_TOP:-/build}" "$origPwd")
        export DYNDRV_INVOCATION_CWD="$dyndrvInvocationCwd"

        # Rewrite any argv element that's a path to an EXISTING regular
        # file not already under /nix/store into its real store path
        # first: a real build's source files (e.g. `cc -c a.c -o a.o`)
        # are ordinary relative paths in the outer build's own working
        # directory, not yet Nix store objects, and a `toNode` expression
        # referencing such a path directly fails ("'a.c' is too short to
        # be a valid store path") since the sandbox has no access to the
        # outer build's $PWD -- only to real store paths declared as
        # inputs. Doing this HERE, once, before `toNode` ever sees
        # `argv`, means every `toNode` can treat every non-flag argv
        # element uniformly as a real, already-addable store path.
        #
        # A path that's itself a still-pending batch stub (e.g. a link
        # step's own `main.o`/`liba.a` args) is left as its literal
        # relative text instead -- staging its placeholder stub bytes as
        # if they were real object content would corrupt the eventual
        # build; `shim.collectStubs` resolves these via its own
        # dependency scan later, not via a store path here.
        #
        # Rewrites into a SEPARATE `rewrittenArgs`-lines string, NOT "$@"
        # itself -- the PASSTHROUGH `exec` further down must still run
        # with the ORIGINAL, unrewritten argv, since `realCommand` needs
        # the real relative source path in the outer build's own `$PWD`,
        # not a `/nix/store/` copy. `computeNodeScript`'s own `toNodeBash`
        # branch reads this rewritten form back via `dyndrv_rewritten_argv`
        # (one element per line) rather than through `"$@"`, so the
        # ORIGINAL positional parameters are never disturbed at all.
        rewrittenArgs=""
        for a in "$@"; do
          case "$a" in
            /nix/store/*)
              rewritten="$a"
              ;;
            -*)
              rewritten="$a"
              ;;
            *)
              if [ -f "$a" ] && [ -z "$(dyndrv_read_batch_stub "$a")" ]; then
                rewritten=$(nix store add-file "$a" 2>/dev/null)
              else
                rewritten="$a"
              fi
              ;;
          esac
          rewrittenArgs="$rewrittenArgs$rewritten"$'\n'
        done

        argvJson=$(printf '%s' "$rewrittenArgs" | ${pkgs.jq}/bin/jq -R -s 'split("\n") | .[:-1]')
        # Strips the loop's own trailing $'\n' -- left as-is, the
        # heredoc `dyndrv_call_to_node` reads this through (below) would
        # ALSO add its own trailing newline, producing a spurious final
        # EMPTY argv element (confirmed by direct reproduction: a
        # heredoc's content always ends in a newline before its
        # terminator, so a string already ending in "\n" plus that gets
        # read back as one extra blank line).
        dyndrv_rewritten_argv="''${rewrittenArgs%$'\n'}"

        ${computeNodeScript}

        # A top-level `null` from `nix-instantiate --eval --strict --json`
        # is the bare text `null` -- this is how we detect the
        # PASSTHROUGH case documented in this file's `toNode` contract.
        if [ "$node" = "null" ]; then
          exec "${realCommand}" "$@"
        fi

        ${resolveNodeFields}

        ${finalizeTail}
      ''
    else
      ''
        #!/bin/sh
        set -eu
        if [ -n "''${DYNDRV_BYPASS:-}" ]; then
          exec ${realCommand} "$@"
        fi

        export PATH="${nixPackage}/bin:$PATH"
        export NIX_CONFIG='extra-experimental-features = nix-command ca-derivations dynamic-derivations'
        # See this file's OTHER `discoverTree == null` branch's own
        # matching comment on `DYNDRV_REAL_COMMAND` above -- same
        # reason, same mechanism -- this is the branch `ccShim`/
        # `cxxShim` (both set `discoverTree`) actually reach.
        export DYNDRV_REAL_COMMAND="${realCommand}"

        ${readStubFn}

        # discoverTree mode: preserves relative directory structure
        # instead of flattening every input to its own basename -- needed
        # for compilers whose real invocations depend on relative `-I`
        # search paths across a multi-directory source tree.
        #
        # Some real build systems (e.g. freetype's libtool-driven build)
        # pass ABSOLUTE paths that are nonetheless relative to the
        # CALLING BUILD'S OWN `$PWD`, not real Nix store paths (e.g.
        # `/build/freetype-2.14.3/src/base/ftbase.c` -- `/build` is the
        # sandbox's own build directory, not a store path) -- these must
        # be normalized to genuinely relative form FIRST, or the later
        # "any `/`-prefixed path is already a real store input"
        # assumption incorrectly skips staging them. Any argv element NOT
        # prefixed with `$origPwd/` (e.g. a real `/nix/store/...` -I flag
        # value) is left untouched.
        #
        # This must also handle the GLUED flag form (`-I/build/.../foo`,
        # the path stuck directly onto the flag letter with no space --
        # confirmed this is how real autotools/libtool builds pass `-I`),
        # not just a standalone positional path argument. `stripPwdPrefix`
        # handles both the bare and any glued-flag-prefix form
        # generically, rather than one `case` arm per known flag letter.
        origPwd=$(${pkgs.coreutils}/bin/pwd)
        # A bare `-l<name>` link argument (`-lx265-10`) is a linker
        # SEARCH-PATH reference, not a literal file path -- it names its
        # target only by basename, resolved by `ld` itself at link time
        # against whatever `-L<dir>` search paths are active. Every OTHER
        # dependency-wiring mechanism in this shim (the positional-arg
        # scan below, `discoverTree`'s own `-M -MG` scan,
        # `extraStorePaths`' literal-substring match) works by finding a
        # literal relative/absolute PATH somewhere in argv -- none of
        # them has anything to match against here, since `-lx265-10`'s
        # own text never names `libx265-10.a` at all. Confirmed via real
        # nixpkgs x265 (`docs/bare-lname-link-arg-bug.md`): its own
        # cmake-generated link line reads `-Wl,-Bstatic -lx265-10
        # -lx265-12 -Wl,-Bdynamic`, where `libx265-10.a`/`libx265-12.a`
        # are RELATIVE symlinks x265's own `preBuild` creates
        # (`ln -s ../build-10bits/libx265.a ./libx265-10.a`) pointing at
        # a SEPARATE deferred `ar` invocation's own not-yet-resolved
        # output -- `ld.bfd: cannot find -lx265-10: No such file or
        # directory`, since nothing ever staged/resolved it.
        #
        # Fixed here, ONE step before everything else in this script
        # (including `stripPwdPrefix`) ever sees argv: resolve any
        # `-l<name>` against the SAME `-L<dir>` search-path convention
        # `ld` itself would use, restricted to RELATIVE search dirs only
        # (an ABSOLUTE `-L<dir>`, e.g. a real Nix store lib directory,
        # can never resolve to a not-yet-built stub -- only relative
        # `-L.`/`-Lbuild/lib`-style in-tree paths matter here; this
        # build's own `NIX_LDFLAGS`-injected absolute `-L` entries are
        # irrelevant), and REWRITE `-l<name>` into that resolved
        # RELATIVE path directly in argv. From this point on, `-lx265-10`
        # simply reads as `libx265-10.a` everywhere downstream -- the
        # existing positional-arg literal-path machinery (staging real
        # files, recognizing pending stubs, wiring cross-unit
        # `inputs.drvs`) already handles an ordinary relative path
        # correctly, with zero changes needed anywhere else. Prefers a
        # match found via an EARLIER `-L<dir>` over a LATER one, matching
        # `ld`'s own first-match search-path semantics; within one
        # directory, `.so` is tried before `.a` (a real system `.so`
        # living in an absolute `-L` directory was already excluded
        # above, so whichever variant genuinely exists locally, relative
        # to the build root, is the only one that could possibly be a
        # same-build dependency worth resolving).
        dyndrvLDirs="."
        for dyndrvLArg in "$@"; do
          case "$dyndrvLArg" in
            -L/*) ;;
            -L*) dyndrvLDirs="$dyndrvLDirs
        ''${dyndrvLArg#-L}" ;;
          esac
        done
        dyndrvLFirstArg=1
        for dyndrvLArg in "$@"; do
          case "$dyndrvLArg" in
            -l*)
              dyndrvLName="''${dyndrvLArg#-l}"
              dyndrvLResolved=""
              while IFS= read -r dyndrvLDir; do
                [ -z "$dyndrvLDir" ] && continue
                for dyndrvLExt in so a; do
                  dyndrvLCand="$dyndrvLDir/lib$dyndrvLName.$dyndrvLExt"
                  if [ -e "$dyndrvLCand" ]; then
                    # `-e` above only confirms SOMETHING exists at this
                    # path -- x265's own real shape (`ln -s
                    # ../build-10bits/libx265.a ./libx265-10.a`) is a
                    # SYMLINK, and its literal text (`./libx265-10.a`)
                    # would never match any discovered stub's own key
                    # (`build-10bits/libx265.a`) -- `realpath` resolves
                    # through it to the CANONICAL underlying path (still
                    # relative to `$origPwd`, matching every OTHER
                    # relative reference this script already produces),
                    # so the rewritten argv element names the SAME path
                    # the earlier `ar` stub was actually written to.
                    dyndrvLResolved=$(${pkgs.coreutils}/bin/realpath -m --relative-to="$origPwd" "$dyndrvLCand")
                    break 2
                  fi
                done
              done <<DYNDRV_LDIRS
        $dyndrvLDirs
        DYNDRV_LDIRS
              if [ -n "$dyndrvLResolved" ]; then
                dyndrvLArg="$dyndrvLResolved"
              fi
              ;;
          esac
          if [ "$dyndrvLFirstArg" = 1 ]; then
            set -- "$dyndrvLArg"
            dyndrvLFirstArg=0
          else
            set -- "$@" "$dyndrvLArg"
          fi
        done
        stripPwdPrefix() {
          case "$1" in
            "$origPwd"/*) printf '%s' "''${1#"$origPwd"/}" ;;
            *"$origPwd"/*)
              printf '%s%s' "''${1%%"$origPwd"/*}" "''${1#*"$origPwd"/}"
              ;;
            *) printf '%s' "$1" ;;
          esac
        }
        firstArg=1
        for a in "$@"; do
          a=$(stripPwdPrefix "$a")
          if [ "$firstArg" = 1 ]; then
            set -- "$a"
            firstArg=0
          else
            set -- "$@" "$a"
          fi
        done
        # `argv` here is now relative wherever the original was
        # absolute-but-under-$PWD -- genuinely absolute paths (real store
        # paths) are unchanged.

        # See this file's OTHER `discoverTree == null` branch's own
        # matching comment on `DYNDRV_INVOCATION_CWD` above -- same
        # reason (a link step's own cwd, e.g. cmake's `cd build && cc
        # ...`, routinely differs from an earlier compile step's cwd
        # that produced one of its `.o` inputs), same mechanism.
        dyndrvInvocationCwd=$(${pkgs.coreutils}/bin/realpath -m --relative-to="''${NIX_BUILD_TOP:-/build}" "$origPwd")
        export DYNDRV_INVOCATION_CWD="$dyndrvInvocationCwd"

        argvJson=$(printf '%s\n' "$@" | ${pkgs.jq}/bin/jq -R -s 'split("\n") | .[:-1]')
        # `"$@"` is already the relevant form here (this variant never
        # substitutes real store paths in place of source files the way
        # the plain variant does), so `dyndrv_rewritten_argv` -- consumed
        # by `computeNodeScript`'s own `toNodeBash` branch below -- is
        # simply its newline-joined form.
        dyndrv_rewritten_argv=$(printf '%s\n' "$@")

        discoverFile=$(mktemp)
        cat > "$discoverFile" <<'DYNDRV_DISCOVER_SCRIPT'
        ${discoverTree}
        DYNDRV_DISCOVER_SCRIPT

        # `discoverTree`'s own stdout: one RELATIVE path per line (sources
        # and headers this invocation needs, already relative to $PWD).
        # Any positional (non-"-"-prefixed) argv element that names an
        # existing relative regular file is included automatically, so a
        # caller's `discoverTree` only needs to report paths argv itself
        # doesn't already name (typically just the discovered headers).
        # `|| true` is required here: under `set -e`, a `discoverTree`
        # that legitimately finds nothing to report (e.g. a link
        # invocation like `cc main.o lib_0.o -o prog` has no headers to
        # discover, so its own internal `grep -v '^$'` exits 1 on empty
        # input) would otherwise abort the WHOLE wrapper script here,
        # before `toNode` ever gets a chance to return `null` for exactly
        # this kind of non-compile invocation.
        discoveredPaths=$(sh -c "$(cat "$discoverFile")" -- "$@") || true
        rm -f "$discoverFile"

        argvPaths=""
        for a in "$@"; do
          case "$a" in
            -Wl,*)
              # A linker-passthrough flag can GLUE an existing relative
              # file onto its own value (`-Wl,/build/.../libfreetype.ver`,
              # already relative after `stripPwdPrefix` above -- confirmed
              # necessary by direct reproduction against a real freetype
              # build: libtool generates `objs/.libs/libfreetype.ver` via
              # plain shell `echo`/`cat`/`sed` redirection, NOT via `cc`/
              # `ar`, so it's real content already sitting in the tree,
              # invisible to the positional-arg scan below since `-Wl,...`
              # is `-`-prefixed). Only the LAST comma-separated token is
              # ever a file path in practice (`-Wl,-version-script,<file>`
              # or a bare `-Wl,<file>`); checking every token after the
              # first comma costs nothing and can't misfire, since a
              # normal `-Wl` sub-option (e.g. `-rpath`) never happens to
              # also be an existing relative regular file.
              _dyndrv_wlRest="''${a#-Wl,}"
              while [ -n "$_dyndrv_wlRest" ]; do
                case "$_dyndrv_wlRest" in
                  *,*) _dyndrv_wlTok="''${_dyndrv_wlRest%%,*}"; _dyndrv_wlRest="''${_dyndrv_wlRest#*,}" ;;
                  *) _dyndrv_wlTok="$_dyndrv_wlRest"; _dyndrv_wlRest="" ;;
                esac
                case "$_dyndrv_wlTok" in
                  -*|/*|"") ;;
                  *)
                    if [ -f "$_dyndrv_wlTok" ] && [ -z "$(dyndrv_read_batch_stub "$_dyndrv_wlTok")" ]; then
                      argvPaths="$argvPaths$_dyndrv_wlTok
        "
                    fi
                    ;;
                esac
              done
              ;;
            -*) ;;
            /*) ;;
            *)
              # A positional relative arg that's itself a still-pending
              # batch stub (e.g. a link step's own `main.o`/`liba.a`
              # args, each some earlier compile's/archive's deferred
              # output) must NOT be staged as real file content -- it's
              # placeholder stub bytes, not a real object. Its literal
              # relative-path TEXT stays in argv unchanged (so the
              # rendered command still reads `cc main.o liba.a -o $out`)
              # for `shim.collectStubs`'s own dependency scan to resolve
              # into a real cross-unit reference later; only genuinely
              # real files get staged here.
              if [ -f "$a" ] && [ -z "$(dyndrv_read_batch_stub "$a")" ]; then
                argvPaths="$argvPaths$a
        "
              fi
              ;;
          esac
        done

        allPaths=$(printf '%s\n%s\n' "$argvPaths" "$discoveredPaths" | sort -u | grep -v '^$' || true)

        # `nix store add`'s resulting store path/hash depends on the
        # STAGING DIRECTORY'S OWN BASENAME, not just its contents -- two
        # directories with byte-identical contents but different
        # basenames produce two DIFFERENT store paths. Stage into a
        # FIXED basename (`dyndrv-tree`) under a randomized `mktemp -d`
        # PARENT, so concurrent invocations get distinct filesystem
        # paths while the directory `nix store add` actually hashes
        # always has the same name.
        # A real build routinely compiles from a directory ONE OR MORE
        # LEVELS BELOW its own source root (meson's own convention,
        # confirmed necessary by direct reproduction against NixOS/nix's
        # own `nix-util` component: EVERY compile there runs `cc ... -c
        # ../hash.cc ...`, `../` and all) -- a naive `$treeDir/$p` join
        # for such a path resolves OUTSIDE `$treeDir` entirely
        # (`$treeDir/../hash.cc` is `$treeParent/hash.cc`), so it never
        # reaches `nix store add`'s input and the eventual real compile
        # fails with "No such file or directory" -- confirmed this is
        # NOT a one-off: every single one of nix-util's ~90 translation
        # units hit this identically, since meson's out-of-source-tree
        # convention is uniform across the whole component.
        #
        # Fixed by giving the staged tree an EXTRA, fixed-name nested
        # "cwd" chain (`dyndrvUpDirName`, repeated) representing the
        # invocation's own real working directory, `dyndrvUpDepth`
        # levels below the tree's root -- deep enough that even the
        # LARGEST `../` prefix among this invocation's own paths still
        # lands inside the tree. A path with `k` leading `../` segments
        # (`k <= dyndrvUpDepth`) is staged `(dyndrvUpDepth - k)` "cwd"
        # levels down (i.e. `k` levels ABOVE the deepest nesting),
        # exactly matching where it will resolve to once the eventual
        # builder `cd`s into that same nested chain before running the
        # real command -- a path with NO `../` prefix (an ordinary
        # `-I<relative>`/positional source under the invocation's own
        # cwd) stays at the full nesting depth. `DYNDRV_TREE_UPDEPTH`
        # (exported below) tells `toNode`/`toNodeBash` how many
        # `dyndrvUpDirName` levels the eventual builder needs to `cd`
        # into -- baked into `record.chdir`, read by `collectStubs.nix`'s
        # `dyndrv_render_member` (and its Rust `render_record_line`
        # equivalent) at RENDER time, since that's the only point a
        # relative source path is actually resolved for real (this
        # wrapper script's own job ends at registration).
        dyndrvUpDirName=".dyndrv-cwd"
        treeParent=$(mktemp -d)
        treeDir="$treeParent/dyndrv-tree"
        ${pkgs.coreutils}/bin/mkdir -p "$treeDir"
        dyndrvUpDepth=0
        while IFS= read -r p; do
          [ -z "$p" ] && continue
          case "$p" in
            /*) continue ;; # absolute paths (e.g. system headers under /nix/store) are real store inputs already, not staged into the tree
          esac
          dyndrvK=0
          dyndrvRest="$p"
          while :; do
            case "$dyndrvRest" in
              ../*) dyndrvK=$((dyndrvK + 1)); dyndrvRest="''${dyndrvRest#../}" ;;
              *) break ;;
            esac
          done
          [ "$dyndrvK" -gt "$dyndrvUpDepth" ] && dyndrvUpDepth="$dyndrvK"
        done <<DYNDRV_PATHS
        $allPaths
        DYNDRV_PATHS
        # The eventual builder unconditionally `cd`s `dyndrvUpDepth`
        # levels into `dyndrvUpDirName/dyndrvUpDirName/...` BEFORE
        # running the real command (see `mkAcceleratedStdenv.nix`'s
        # own `dyndrv_chdir` -- this is the SAME depth), regardless of
        # whether any INDIVIDUAL file this invocation stages happens
        # to land there -- confirmed necessary by direct reproduction
        # against NixOS/nix's own `nix-util` component: a compile
        # whose OWN source has NO `../` prefix at all (e.g. `-c
        # checked-arithmetic.cc`, staged at nesting level 0) but whose
        # sibling `-I../include` flags still need `dyndrvUpDepth = 1`
        # (from OTHER paths this SAME invocation references) never
        # triggers the per-file `mkdir -p "$(dirname "$dyndrvDest")"`
        # loop below for the `.dyndrv-cwd/` directory ITSELF (nothing
        # is ever staged strictly AT that nesting level for this
        # invocation) -- so without this, `cd .dyndrv-cwd/` failed
        # outright ("No such file or directory") the moment a
        # compile's OWN source happened to need zero nesting while its
        # sibling headers needed some.
        dyndrvI=0
        dyndrvMkdirPath="$treeDir"
        while [ "$dyndrvI" -lt "$dyndrvUpDepth" ]; do
          dyndrvMkdirPath="$dyndrvMkdirPath/$dyndrvUpDirName"
          dyndrvI=$((dyndrvI + 1))
        done
        ${pkgs.coreutils}/bin/mkdir -p "$dyndrvMkdirPath"
        # A real (unaccelerated) meson/ninja build always creates its
        # WHOLE build-directory skeleton (every `<target>.p/` output
        # subdirectory) up front, during `configurePhase`, before any
        # compiler ever runs -- so a compiler's own `-MF <relative-
        # dir>/<file>.d` dependency-file output can always assume its
        # own parent directory already exists. This accelerator's
        # staged tree, by contrast, only ever contains what
        # `discoverTree`'s own dependency SCAN found (real SOURCE/
        # HEADER *inputs*, never an output-only directory nothing
        # `-include`s) -- confirmed necessary by direct reproduction
        # against NixOS/nix's own `nix-util` component:
        # `library-versions.cc`'s own `-MF libnixutil.so.2.36.0.p/
        # library-versions.cc.o.d` failed outright ("No such file or
        # directory") the moment its compile actually tried to WRITE
        # that file, since nothing else in this invocation's own argv
        # ever referenced `libnixutil.so.2.36.0.p/` as an INPUT (its
        # sibling `-Ilibnixutil.so.2.36.0.p` flag names the identical
        # directory, but as a search path, invisible to the input-only
        # scan above). Pre-creating every `-MF`/`-MT`/`-o` value's own
        # dirname here -- at the SAME nesting depth this invocation's
        # own `dyndrvUpDepth` computed above -- covers this generically,
        # without needing to special-case dependency-file generation
        # specifically (any OTHER compiler flag that writes a relative-
        # path output nothing else references would hit the identical
        # gap).
        for a in "$@"; do
          case "$a" in
            /*) continue ;;
          esac
          # `a` can be a `-`-prefixed FLAG, not a real path at all --
          # confirmed necessary by direct reproduction against real
          # nixpkgs libwebp (cmake+ninja's own generated link line):
          # `-Wl,--dependency-file=CMakeFiles/webpdecoder.dir/link.d`
          # is ONE glued argv token, and without this check the loop
          # below computed ITS OWN literal dirname (`-Wl,--dependency-
          # file=CMakeFiles/webpdecoder.dir`, the flag's own text minus
          # its last path segment) instead of the REAL relative
          # directory the linker actually needs
          # (`CMakeFiles/webpdecoder.dir`) -- the genuinely-needed
          # directory was never created at all, so `ld.bfd` failed
          # outright ("cannot open dependency file CMakeFiles/
          # webpdecoder.dir/link.d: No such file or directory"). This
          # was ORIGINALLY misdiagnosed (in `~/overlay`'s own libwebp/
          # leveldb/brotli/libssh survey findings) as `discoverTree`
          # itself misstaging multi-subdirectory cmake source trees --
          # confirmed by direct reproduction that the REAL cause is
          # here instead, one level later than `discoverTree` (this
          # loop runs AFTER it, over the SAME raw, unfiltered argv).
          # `-Wl,`-glued flags still need their OWN embedded path
          # extracted (unglue on `,` the same way the input-file scan
          # above already does, then take the part after `=` for an
          # `--option=value`-shaped sub-flag like `--dependency-file=`)
          # -- every OTHER `-`-prefixed flag has no real path to
          # extract at all and is skipped outright.
          case "$a" in
            -Wl,*)
              dyndrvOutOrig="$a"
              _dyndrv_wlRest="''${a#-Wl,}"
              while [ -n "$_dyndrv_wlRest" ]; do
                case "$_dyndrv_wlRest" in
                  *,*) _dyndrv_wlTok="''${_dyndrv_wlRest%%,*}"; _dyndrv_wlRest="''${_dyndrv_wlRest#*,}" ;;
                  *) _dyndrv_wlTok="$_dyndrv_wlRest"; _dyndrv_wlRest="" ;;
                esac
                case "$_dyndrv_wlTok" in
                  *=*) a="''${_dyndrv_wlTok#*=}" ;;
                  *) a="$_dyndrv_wlTok" ;;
                esac
                case "$a" in
                  -*|/*|"") continue ;;
                esac
                dyndrvOutK=0
                dyndrvOutRest="$a"
                while :; do
                  case "$dyndrvOutRest" in
                    ../*) dyndrvOutK=$((dyndrvOutK + 1)); dyndrvOutRest="''${dyndrvOutRest#../}" ;;
                    *) break ;;
                  esac
                done
                dyndrvOutNestLevels=$((dyndrvUpDepth - dyndrvOutK))
                [ "$dyndrvOutNestLevels" -lt 0 ] && continue
                dyndrvOutNestPrefix=""
                dyndrvOutI=0
                while [ "$dyndrvOutI" -lt "$dyndrvOutNestLevels" ]; do
                  dyndrvOutNestPrefix="$dyndrvOutNestPrefix$dyndrvUpDirName/"
                  dyndrvOutI=$((dyndrvOutI + 1))
                done
                ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$treeDir/$dyndrvOutNestPrefix$dyndrvOutRest")"
              done
              a="$dyndrvOutOrig"
              continue
              ;;
            -*) continue ;;
          esac
          dyndrvOutK=0
          dyndrvOutRest="$a"
          while :; do
            case "$dyndrvOutRest" in
              ../*) dyndrvOutK=$((dyndrvOutK + 1)); dyndrvOutRest="''${dyndrvOutRest#../}" ;;
              *) break ;;
            esac
          done
          dyndrvOutNestLevels=$((dyndrvUpDepth - dyndrvOutK))
          [ "$dyndrvOutNestLevels" -lt 0 ] && continue
          dyndrvOutNestPrefix=""
          dyndrvOutI=0
          while [ "$dyndrvOutI" -lt "$dyndrvOutNestLevels" ]; do
            dyndrvOutNestPrefix="$dyndrvOutNestPrefix$dyndrvUpDirName/"
            dyndrvOutI=$((dyndrvOutI + 1))
          done
          ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$treeDir/$dyndrvOutNestPrefix$dyndrvOutRest")"
        done
        while IFS= read -r p; do
          [ -z "$p" ] && continue
          case "$p" in
            /*) continue ;; # absolute paths (e.g. system headers under /nix/store) are real store inputs already, not staged into the tree
          esac
          if [ -f "$p" ]; then
            dyndrvK=0
            dyndrvRest="$p"
            while :; do
              case "$dyndrvRest" in
                ../*) dyndrvK=$((dyndrvK + 1)); dyndrvRest="''${dyndrvRest#../}" ;;
                *) break ;;
              esac
            done
            dyndrvNestLevels=$((dyndrvUpDepth - dyndrvK))
            dyndrvNestPrefix=""
            dyndrvI=0
            while [ "$dyndrvI" -lt "$dyndrvNestLevels" ]; do
              dyndrvNestPrefix="$dyndrvNestPrefix$dyndrvUpDirName/"
              dyndrvI=$((dyndrvI + 1))
            done
            dyndrvDest="$treeDir/$dyndrvNestPrefix$dyndrvRest"
            ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$dyndrvDest")"
            ${pkgs.coreutils}/bin/cp "$p" "$dyndrvDest"
          fi
        done <<DYNDRV_PATHS
        $allPaths
        DYNDRV_PATHS

        treePath=$(nix store add "$treeDir" 2>/dev/null)
        rm -rf "$treeParent"
        export DYNDRV_TREE_BASENAME=$(${pkgs.coreutils}/bin/basename "$treePath")
        export DYNDRV_TREE_UPDEPTH="$dyndrvUpDepth"
        export DYNDRV_TREE_UPDIRNAME="$dyndrvUpDirName"

        nodeExprFile=$(mktemp)
        cat > "$nodeExprFile" <<'DYNDRV_TONODE_EXPR'
        ${toNode}
        DYNDRV_TONODE_EXPR

        argvFile=$(mktemp)
        printf '%s' "$argvJson" > "$argvFile"

        node=$(ARGV_PATH="$argvFile" DYNDRV_TREE_BASENAME="$DYNDRV_TREE_BASENAME" DYNDRV_TREE_UPDEPTH="$DYNDRV_TREE_UPDEPTH" DYNDRV_TREE_UPDIRNAME="$DYNDRV_TREE_UPDIRNAME" nix-instantiate --eval --strict --json --expr \
          "let argv = builtins.fromJSON (builtins.readFile (builtins.getEnv \"ARGV_PATH\")); f = import $nodeExprFile; in f argv" 2>/dev/null)
        rm -f "$nodeExprFile" "$argvFile"

        if [ "$node" = "null" ]; then
          exec "${realCommand}" "$@"
        fi

        ${resolveNodeFields}

        ${finalizeTail}
      '';
}
