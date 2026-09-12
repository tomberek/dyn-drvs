{ pkgs, lib, self }:

# The single-output C/C++ accelerator: overrides `stdenv.mkDerivation` so
# every `cc -c`/link/`ar` invocation defers (see `shim/wrapCommand.nix`'s
# header for why EVERY invocation defers now, unconditionally -- there is
# no live "materialize inline" mode anymore, since `builder-rpc-v0`
# structurally cannot realize a derivation from inside a running script).
# `make`/whatever build tool runs to completion almost instantly against a
# tree full of batch-pending stubs; `shim.collectStubs` then resolves the
# whole discovered graph in one pass at the end of `buildPhase`, submitting
# a fully-resolved build tree. `dyndrv.phases.split` (a general, separately
# usable primitive) supplies the actual two-derivation wiring this needs:
# phase 1 (gated on `builder-rpc-v0`) runs unpack/patch/configure/build
# (deferred) plus the collection pass; phase 2 (an ORDINARY derivation, no
# special capability needed) runs check/install/fixup against phase 1's
# now-fully-resolved tree.
#
# This is the mechanism the adoption story is built around: point this at
# an existing single-output C/C++ `stdenv.mkDerivation` package and get
# per-translation-unit caching, one line changed, no rewrite required.
#
# `granularity`: how many translation units share one dynamically-produced
#   derivation:
#   - `"file"` (default): every `-c` compile is its own solo unit (no
#     `key`) -- one dynamically-produced derivation per translation unit,
#     the whole point of the feature.
#   - `"module"`: same as `"file"`, but every compile whose relative source
#     path satisfies the caller-supplied `shouldBatch` predicate gets a
#     directory-based `key` instead -- every such compile, PLUS any `ar`
#     step whose own inputs are ALL in that same group, merges into ONE
#     combined derivation (`shim.collectStubs`'s own auto-merge rule:
#     a keyless stub -- e.g. an ordinary `ar`/link step -- joins its deps'
#     shared unit iff every one of those deps already belongs to that
#     SAME real unit; this generalizes past just `ar`, unlike the earlier
#     live-shim-era `wrapArchiver`, but the effect for a same-group `ar`
#     call is identical).
#   - `"package"`: a pure no-op passthrough (returns `stdenv` unmodified) --
#     useful for bisecting whether acceleration itself is the cause of a
#     build problem, without reverting the `.override` call.
#
#   `shouldBatch` (required when `granularity = "module"`, ignored
#   otherwise): a function `relativeSourcePath -> bool`, UNCONDITIONALLY
#   OPT-IN per path -- matching nixgg's own `batch.Config`/`shouldBatch`
#   design. Batching an actively-edited directory trades saved
#   registration overhead for wasted real-compiler time on unchanged
#   siblings on every edit, so there is no safe automatic default --
#   `shouldBatch` defaults to `_: false` (nothing batches) if omitted,
#   which is simply `"file"` granularity's own existing behavior.
#
#   HOW `shouldBatch` crosses the eval/build boundary: `toNode`'s
#   generated text is `nix-instantiate`d STANDALONE inside the sandbox,
#   with no access to any outer Nix closure. So `shouldBatch` is
#   evaluated ONCE, at ordinary Nix eval time, against every file found
#   under `args.src` (recursively) -- producing a concrete
#   `{ <relative-path> = <groupKey>; }` mapping (directory-based
#   grouping) that gets spliced into `toNode` as literal JSON data, not a
#   closure. This is a deliberate tradeoff: walking `args.src` this way
#   triggers a REAL eval-time build (import-from-derivation), accepted
#   ONLY for `granularity = "module"` -- `"file"` (the default) never
#   touches `args.src` this way and stays fully IFD-free.
#
# DIRECTORY-STRUCTURE / HEADER-DISCOVERY (unchanged from earlier design,
# still needed for `cc`, NOT needed for `ar` -- see below): a real
# multi-directory C project routinely compiles with relative `-I` search
# paths and includes local headers only resolvable through them. The
# `cc` shim uses `shim.wrapCommand`'s `discoverTree` mode: before
# deferring each compile/link, run a `cc -M -MG` dependency scan (tolerant
# of not-yet-generated headers), stage every positional/discovered
# RELATIVE path into one directory tree (preserving structure), and add
# it to the store as ONE object, so the eventually-registered
# derivation's own builder can `cp -r` it into its cwd and run the
# ORIGINAL relative-path command completely unmodified.
#
# `ar` needs NONE of this: its own positional inputs are already-known
# relative object/archive paths (themselves other stubs, resolved later
# by `collectStubs` via cross-unit/sibling placeholder substitution, not
# via any tree-staging), so it's shimmed with `wrapCommand`'s plain
# (non-`discoverTree`) variant instead -- a simpler `toNode`, no `-M -MG`
# scan, no staged tree at all.

{
  stdenv,
  granularity ? "file",
  # See header comment's `shouldBatch` section -- only consulted when
  # `granularity = "module"`; `_: false` matches `"file"`'s own behavior
  # exactly (nothing ever batches).
  shouldBatch ? (_: false),
  # The Nix to run `nix derivation add`/`nix store add`/`nix store
  # submit-output` with, inside phase 1's sandbox -- same VERSION-
  # MATCHING requirement `builders/viaDerivationAdd.nix`'s own header
  # documents: this must be running a compatible worker-protocol version
  # to the OUTER Nix actually driving the whole build, or registration
  # fails with "Operation ... not allowed inside derivation". Defaults
  # to `pkgs.nix` (the ambient Nix); override when driving the build
  # through a separately-fetched `builder-rpc-v0`-capable Nix (e.g.
  # `try-it-out/patched-nix.nix`) that differs from `pkgs.nix`.
  nixPackage ? pkgs.nix,
  # The compiled `rust/dyndrv-shim` package (providing `bin/dyndrv-shim`)
  # to use for `cc`/`ar`/`ranlib` instead of the bash `toNode`/
  # `toNodeBash` path, via `shim.wrapCommand`'s `toNodeCompiled` mode --
  # collapses every intercepted invocation to one process, using the raw
  # daemon-RPC client instead of `nix-instantiate`/`jq`/`nix` CLI spawns.
  # Verified byte-identical against the bash path for `ar`/`ranlib`
  # (see `rust/dyndrv-shim/ar-integration-test.nix`); `cc`'s own decision
  # logic (`rust/dyndrv-shim/src/cc.rs`) is a direct port of `ccToNodeBash`
  # below, kept byte-identical including its own bash sentinel-arithmetic
  # quirks (see that file's own comments). Defaults to `null` (bash path,
  # unchanged behavior) -- opt in explicitly per call site.
  dyndrvShim ? null,
}:

assert builtins.elem granularity [ "file" "module" "package" ];

let
  useCompiledShim = dyndrvShim != null;
  realCc = "${stdenv.cc}/bin/cc";
  # `stdenv.cc`'s own package ALSO provides a real, separate `c++`
  # binary (confirmed by direct reproduction: `ls stdenv.cc/bin` lists
  # both `cc`/`gcc` AND `c++`/`g++` as distinct files, not aliases) --
  # `cc`/`c++` differ in more than just default file-extension handling:
  # confirmed by direct reproduction that LINKING a C++ translation
  # unit's own `.o` via `cc` (not `c++`) fails outright ("undefined
  # reference to `std::cout'" etc.) unless `-lstdc++` is added
  # explicitly, since only `c++`'s own wrapper defaults to linking
  # against libstdc++. A C++ build's `$(CXX)`-driven compile AND link
  # steps therefore both need the shim pointed at the REAL `c++`, not
  # `cc` -- see `cxxShim` below, a SEPARATE `wrapCommand` instance from
  # `ccShim`.
  realCxx = "${stdenv.cc}/bin/c++";
  # The real `ar`/`ranlib` binaries live under `stdenv.cc.bintools.bintools`,
  # not `stdenv.cc` -- a different nixpkgs wrapper package. That package's
  # own setup hook exports `AR=ar` (the bare name, not a full path), same
  # "wrapper exports the bare name" gotcha as `CC=gcc`/`CXX=g++` below --
  # `AR` must be overridden explicitly for the `ar` shim to intercept a
  # real Makefile's `$(AR)` invocation.
  realAr = "${stdenv.cc.bintools.bintools}/bin/ar";

  # Bash port of `toNode` above -- byte-for-byte the SAME decision logic
  # (probe detection, implicit-output-naming, `-o`-replacement, extra
  # store-path scanning), just expressed as a shell function instead of a
  # Nix expression, so `shim.wrapCommand`'s `toNodeBash` fast-path can run
  # it with NO `nix-instantiate` spawn at all -- confirmed the dominant
  # per-invocation cost in this shim (see `wrapCommand.nix`'s own
  # `toNodeBash` header comment for the full rationale, mirroring nixgg's
  # own registration-tax findings: process/interpreter STARTUP dominates,
  # not the decision logic itself, which here is pure string prefix/
  # suffix manipulation with no structural need for a Nix evaluator).
  #
  # THIS FUNCTION MUST BE KEPT IN SYNC WITH `toNode` ABOVE -- read that
  # one first; every comment explaining WHY a given check exists lives
  # there, not duplicated here. Differences from `toNode`, all purely
  # mechanical (bash has no `builtins.foldl'`/`builtins.match`, etc.):
  #   - `outIdx`/positional-arg scanning use a plain `for`-loop over
  #     argv's own index range instead of `builtins.foldl'`.
  #   - `extraStorePaths` uses `grep -o`/`sort -u` instead of
  #     `builtins.match`+dedup-via-attrset.
  #   - `batchKey` reads `$DYNDRV_BATCH_GROUPS` (the SAME env var
  #     `toNode`'s own `batchGroupOfRaw` reads via `builtins.getEnv`) via
  #     `jq`, since this function has no `builtins.fromJSON` available.
  #   - JSON assembly for the final `record` uses `jq -nc` (one call),
  #     mirroring `collectStubs.nix`'s own established convention.
  ccToNodeBash = ''
    dyndrv_to_node() {
      local len=$# i out_idx=-1 first_source_idx=-1 has_compile_flag=0
      local a next_is_o_val=0

      for a in "$@"; do
        [ "$a" = "-c" ] && has_compile_flag=1
      done

      i=0
      for a in "$@"; do
        if [ "$a" = "-o" ] && [ "$out_idx" = -1 ]; then
          out_idx=$i
        fi
        i=$((i + 1))
      done

      # `firstSourceIdx`: first non-flag arg that isn't `-o`'s own value.
      i=0
      for a in "$@"; do
        case "$a" in
          -*) ;;
          *)
            if [ "$i" != "$((out_idx + 1))" ] && [ "$first_source_idx" = -1 ]; then
              first_source_idx=$i
            fi
            ;;
        esac
        i=$((i + 1))
      done

      source_path=""
      if [ "$first_source_idx" != -1 ]; then
        i=0
        for a in "$@"; do
          [ "$i" = "$first_source_idx" ] && source_path="$a"
          i=$((i + 1))
        done
      fi

      out_val=""
      if [ "$out_idx" != -1 ]; then
        i=0
        for a in "$@"; do
          [ "$i" = "$((out_idx + 1))" ] && out_val="$a"
          i=$((i + 1))
        done
      fi

      # `implicitOutputFile`: cc's own documented default when `-o` is
      # absent -- "a.out" for a link, source-basename-minus-last-
      # extension-plus-".o" for a compile.
      implicit_output=""
      if [ "$has_compile_flag" = 0 ]; then
        implicit_output="a.out"
      elif [ -n "$source_path" ]; then
        base=$(${pkgs.coreutils}/bin/basename "$source_path")
        implicit_output="''${base%.*}.o"
      fi

      # `batchKey`: only ever set for a compile with a known source path,
      # looked up in `$DYNDRV_BATCH_GROUPS` (empty/unset means "file"/
      # "package" granularity, or a "module"-mode compile whose source
      # wasn't found under `args.src` at eval time -- both mean "no key").
      batch_key="null"
      if [ "$has_compile_flag" = 1 ] && [ -n "$source_path" ] && [ -n "''${DYNDRV_BATCH_GROUPS:-}" ]; then
        batch_key=$(printf '%s' "$DYNDRV_BATCH_GROUPS" | ${pkgs.jq}/bin/jq --arg p "$source_path" '.[$p] // null')
      fi

      # `isConftest`: any of source_path/positional args/the `-o` value
      # has a basename starting with "conftest".
      is_conftest() {
        case "$(${pkgs.coreutils}/bin/basename "$1")" in
          conftest*) return 0 ;;
          *) return 1 ;;
        esac
      }

      is_probe=0
      if [ -n "$source_path" ] && is_conftest "$source_path"; then
        is_probe=1
      fi
      if [ "$out_idx" != -1 ] && is_conftest "$out_val"; then
        is_probe=1
      fi

      # Positional args (non-flag, not `-o`'s own value) + real-link /
      # compile-to-executable-probe / info-query detection, and a second
      # `is_conftest` scan over every positional arg.
      has_object_or_archive=0
      has_positional=0
      i=0
      for a in "$@"; do
        case "$a" in
          -*) ;;
          *)
            if [ "$i" != "$((out_idx + 1))" ]; then
              has_positional=1
              case "$a" in
                *.o | *.a | *.so) has_object_or_archive=1 ;;
              esac
              if is_conftest "$a"; then
                is_probe=1
              fi
            fi
            ;;
        esac
        i=$((i + 1))
      done

      is_real_link=0
      [ "$has_compile_flag" = 0 ] && [ "$has_object_or_archive" = 1 ] && is_real_link=1
      if [ "$has_compile_flag" = 0 ] && [ "$is_real_link" = 0 ] && [ "$has_positional" = 1 ]; then
        is_probe=1 # isCompileToExecutableProbe
      fi
      if [ "$has_compile_flag" = 0 ] && [ "$is_real_link" = 0 ] && [ "$has_positional" = 0 ]; then
        is_probe=1 # isInfoQuery
      fi

      if [ "$is_probe" = 1 ]; then
        echo null
        return
      fi
      # PASSTHROUGH: a compile whose source is still an absolute path
      # after `wrapCommand`'s own `stripPwdPrefix` pass.
      case "$source_path" in
        /*)
          if [ "$has_compile_flag" = 1 ]; then
            echo null
            return
          fi
          ;;
      esac
      if [ "$out_idx" = -1 ] && [ -z "$implicit_output" ]; then
        echo null
        return
      fi

      output_file="$out_val"
      [ "$out_idx" = -1 ] && output_file="$implicit_output"

      # `argvForCc`: replace the EXISTING "-o"'s value with the literal
      # sentinel "$out" in place, or append "-o $out" if there was none.
      # Newline-delimited (matching this codebase's own established
      # convention elsewhere, e.g. `wrapCommand.nix`'s own `rewrittenArgs`
      # -- an argv element containing a literal newline is not a case
      # this shim supports anywhere, not just here), fed through `jq -Rs`
      # to become a real JSON array; the trailing `.[:-1]` drops the
      # empty element `split("\n")` always produces after the final
      # newline.
      argv_for_cc_lines=$(
        i=0
        for a in "$@"; do
          if [ "$i" = "$((out_idx + 1))" ] && [ "$out_idx" != -1 ]; then
            printf '%s\n' '$out'
          else
            printf '%s\n' "$a"
          fi
          i=$((i + 1))
        done
        if [ "$out_idx" = -1 ]; then
          printf '%s\n%s\n' "-o" '$out'
        fi
      )
      argv_for_cc_json=$(printf '%s' "$argv_for_cc_lines" | ${pkgs.jq}/bin/jq -R -s 'split("\n") | .[:-1]')

      # `extraStorePaths`: any argv element referencing a store path not
      # already covered by coreutils/stdenv.cc/the staged tree, e.g.
      # `-I/nix/store/...-libpng-.../include` glued onto a flag.
      extra_store_paths_json=$(
        for a in "$@"; do
          printf '%s\n' "$a"
        done | ${pkgs.coreutils}/bin/grep -o "${builtins.storeDir}/[^/\"']*" | while IFS= read -r p; do
          ${pkgs.coreutils}/bin/basename "$p"
        done | sort -u | ${pkgs.jq}/bin/jq -R -s 'split("\n") | map(select(. != ""))'
      )

      # `dyndrv_chdir`: when this invocation's own paths needed the
      # staged tree's extra nested "cwd" chain (see `wrapCommand.nix`'s
      # own header comment on `DYNDRV_TREE_UPDEPTH`/`dyndrvUpDirName` --
      # meson's convention of compiling from a directory below its
      # source root, e.g. `-c ../hash.cc`, needs this), the eventual
      # registered derivation's builder must run THIS record's own tool
      # invocation from that SAME nested position -- relative path text
      # in `args` (e.g. `../hash.cc`) is left completely unchanged, only
      # the process's OWN cwd at invocation time shifts to match where
      # the tree was staged.
      #
      # This is carried as its own record field (`chdir`), NOT baked
      # directly into `setupCmd` as a plain `cd` -- confirmed necessary
      # by direct reasoning about a MERGED unit (`granularity =
      # "module"`, several members' own setup+cmd fragments
      # concatenated into ONE shared shell script/cwd): a bare `cd`
      # would persist across the `&&`-chain into the NEXT member's own
      # `setupCmd` (that member's `cp -r <itsOwnTree>/. .` would then
      # wrongly land inside the PREVIOUS member's nested subdirectory
      # instead of the shared build root every member's tree was
      # actually staged relative to). `collectStubs.nix`'s
      # `dyndrv_render_member` (and its Rust `render_record_line`
      # equivalent) wraps ONLY this one record's own `tool $args`
      # invocation in a `( cd $chdir && ... )` subshell, so the cwd
      # change is scoped to that one invocation and never leaks into a
      # sibling member's own setup. Empty/absent when this invocation
      # staged nothing beyond its own cwd (`DYNDRV_TREE_UPDEPTH` = 0,
      # the common case for every OTHER example/fixture this
      # accelerator has been run against so far) -- `null` there, not
      # an empty string, so the renderer's own presence check
      # (`.chdir // empty`) skips the subshell wrapper entirely rather
      # than emitting a no-op `( cd  && ... )`.
      dyndrv_updepth="''${DYNDRV_TREE_UPDEPTH:-0}"
      dyndrv_chdir=""
      dyndrv_i=0
      while [ "$dyndrv_i" -lt "$dyndrv_updepth" ]; do
        dyndrv_chdir="$dyndrv_chdir''${DYNDRV_TREE_UPDIRNAME:-.dyndrv-cwd}/"
        dyndrv_i=$((dyndrv_i + 1))
      done

      record=$(${pkgs.jq}/bin/jq -nc \
        --argjson key "$batch_key" \
        --arg tool "${realCc}" \
        --argjson args "$argv_for_cc_json" \
        --arg coreutils "${builtins.baseNameOf "${pkgs.coreutils}"}" \
        --arg stdenvCc "${builtins.baseNameOf "${stdenv.cc}"}" \
        --arg treeBasename "$DYNDRV_TREE_BASENAME" \
        --argjson extraSrcs "$extra_store_paths_json" \
        --arg setupCmdPrefix "${pkgs.coreutils}/bin/cp -r ${builtins.storeDir}/" \
        --arg setupCmdSuffix "/. . && ${pkgs.coreutils}/bin/chmod -R u+w . &&" \
        --arg chdir "$dyndrv_chdir" \
        '{
          key: $key,
          tool: $tool,
          args: $args,
          srcs: ([$coreutils, $stdenvCc, $treeBasename] + $extraSrcs),
          setupCmd: ($setupCmdPrefix + $treeBasename + $setupCmdSuffix)
        } + (if $chdir != "" then {chdir: $chdir} else {} end))')

      if [ "$out_idx" != -1 ]; then
        ${pkgs.jq}/bin/jq -nc --argjson defer "{\"record\":$(printf '%s' "$record" | ${pkgs.jq}/bin/jq -R .)}" \
          --argjson outputArg "$out_idx" '{defer: {record: $defer.record}, outputArg: ($outputArg + 1)}'
      else
        ${pkgs.jq}/bin/jq -nc --arg record "$record" --arg outputPath "$implicit_output" \
          '{defer: {record: $record}, outputPath: $outputPath}'
      fi
    }
  '';

  # Runs BEFORE `toNode` (inside `wrapCommand`'s wrapper script, per
  # `discoverTree`'s contract -- see wrapCommand.nix's header comment):
  # given the ORIGINAL argv as "$@", prints every RELATIVE header path
  # (one per line) this compile needs beyond what argv already names
  # directly. Strips `-c`/`-o <file>` first (this is a dependency scan,
  # not a real compile), and `-MF <file>`/`-MT <target>`/`-MQ <target>`/
  # bare `-MMD`/`-MD`/`-MP` (ordinary `make`-generated dependency-file
  # flags, present on every real autotools/make compile -- leaving
  # `-MF <file>` in place redirects THIS scan's own `-M -MG` output into
  # that file instead of stdout, silently discovering nothing). Only the
  # FIRST (source-file) line of `cc -M`'s output matters here; the
  # `<target>.o:` prefix and line-continuation backslashes are stripped
  # so each remaining token is a bare path. `|| true`: a link invocation
  # (no source file to scan) legitimately discovers nothing, which is
  # not an error.
  discoverTree = ''
    args=""
    skip_next=0
    for a in "$@"; do
      if [ "$skip_next" = 1 ]; then skip_next=0; continue; fi
      case "$a" in
        -c|-MMD|-MD|-MP) continue ;;
        -o|-MF|-MT|-MQ) skip_next=1; continue ;;
        *) args="$args $a" ;;
      esac
    done
    ${realCc} $args -M -MG 2>/dev/null \
      | tr -d '\\' \
      | tr ' ' '\n' \
      | sed '1d' \
      | grep -v '^$' || true
  '';

  # Parses a real `cc` invocation's argv (as `wrapCommand`'s wrapper
  # script sees it -- `$@` WITHOUT the command name itself) and always
  # defers it -- both compiles (`-c` present) AND links (`-c` absent) --
  # except for a genuinely foreign invocation (see the "PASSTHROUGH"
  # branch below). Written using only `builtins` (no `lib`) since this
  # text is instantiated standalone inside the sandbox, without
  # `<nixpkgs>` necessarily on `NIX_PATH` there.
  #
  # `argv` here is the RAW, unmodified original argv (still relative --
  # `discoverTree` mode), and `DYNDRV_TREE_BASENAME` (read via
  # `builtins.getEnv`) names the ONE staged directory-tree input
  # covering every source/header this invocation needs. `toNode` embeds
  # this tree's basename in `record.srcs`/`record.setupCmd`; the
  # eventually-registered derivation's own builder `cp -r`s it into its
  # cwd before running the compile/link with argv COMPLETELY UNCHANGED,
  # so relative `-I` flags resolve exactly as they would in the real
  # build tree.
  toNode = ''
    argv:
    let
      len = builtins.length argv;
      indices = builtins.genList (i: i) len;

      hasPrefix = prefix: str:
        builtins.substring 0 (builtins.stringLength prefix) str == prefix;

      hasCompileFlag = builtins.elem "-c" argv;

      outIdx = builtins.foldl' (
        acc: i: if acc != (-1) then acc
                else if builtins.elemAt argv i == "-o" then i
                else acc
      ) (-1) indices;

      # Real builds routinely omit `-o` entirely for a COMPILE (confirmed
      # by direct reproduction against a real `libtool --mode=compile`-
      # driven autotools build, freetype) -- when absent, the compiler's
      # own documented default applies: the source file's own BASENAME
      # (directory stripped), its last extension replaced with `.o`,
      # written to the CURRENT DIRECTORY. A LINK invocation with no `-o`
      # defaults to `a.out`, matching `cc`'s own documented default --
      # this case is rare in practice (most build systems always pass
      # `-o` for a link) but handled uniformly rather than assumed away.
      firstSourceIdx = builtins.foldl' (
        acc: i: if acc != (-1) then acc
                else if !(hasPrefix "-" (builtins.elemAt argv i)) && !(i == outIdx + 1) then i
                else acc
      ) (-1) indices;
      stripExt = s:
        let
          parts = builtins.split "\\." s;
          # builtins.split on a literal "." returns [ before ("." | []) after ("." | []) ... ] --
          # taking every other element (indices 0, 2, 4, ...) recovers the
          # dot-separated segments; dropping the last segment and rejoining
          # with "." strips exactly the LAST extension, matching cc's own
          # "last dot" rule (e.g. "foo.tab.c" -> "foo.tab", not "foo").
          segments = builtins.filter builtins.isString parts;
          n = builtins.length segments;
        in
        if n <= 1 then s
        else builtins.concatStringsSep "." (builtins.genList (i: builtins.elemAt segments i) (n - 1));
      sourcePath = if firstSourceIdx == (-1) then null else builtins.elemAt argv firstSourceIdx;
      implicitOutputFile =
        if !hasCompileFlag then "a.out"
        else if sourcePath == null then null
        else (stripExt (builtins.baseNameOf sourcePath)) + ".o";

      # `batchGroupOf`: `{ <relative-source-path> = <groupKey>; }`, built
      # outside the sandbox and threaded across the eval/build boundary
      # via `DYNDRV_BATCH_GROUPS` (see this file's header comment for the
      # full "why"). `builtins.getEnv` returns `""` when unset (the
      # `"file"`/`"package"`-mode case, and any `"module"`-mode compile
      # whose source wasn't found under `args.src` at eval time), treated
      # as `{}` -- `batchKey` is then always `null` (a solo unit, exactly
      # `"file"` granularity's own shape). A LINK invocation never has a
      # `batchKey` of its own -- only compiles are ever opted into a
      # batch group; a link's own unit is decided later by
      # `shim.collectStubs`'s auto-merge rule, from its real deps.
      batchGroupOfRaw = builtins.getEnv "DYNDRV_BATCH_GROUPS";
      batchGroupOf = if batchGroupOfRaw == "" then { } else builtins.fromJSON batchGroupOfRaw;
      batchKey =
        if !hasCompileFlag || sourcePath == null then null else (batchGroupOf.''${sourcePath} or null);

      # PASSTHROUGH signal, most general first: autoconf's OWN feature-
      # probe harness UNIVERSALLY names its scratch source/object/binary
      # files `conftest.*`/`conftest` (confirmed directly: every probe in
      # a real freetype configure run, including ones that need to run a
      # just-compiled binary immediately AND ones that need a compile to
      # genuinely FAIL to detect a flag, uses this exact convention) --
      # a real package build essentially never names an actual build
      # artifact this way. This is a MUCH more reliable signal than
      # trying to infer probe-vs-real-build intent from argv shape alone:
      # a deferred shim's stub always "succeeds" (exit 0) regardless of
      # what the real compile would have done, which breaks BOTH
      # "compile then immediately execute the result" probes (confirmed:
      # `./conftest` on a non-executable stub fails with "Permission
      # denied") AND "this compile should FAIL to detect a flag" probes
      # (confirmed: `ac_fn_c_try_compile` always reports success on a
      # stub, defeating a negative test with no argv-visible difference
      # from an ordinary positive one). Neither failure mode is fixable
      # by inspecting argv structure -- only the NAME reliably signals
      # "this is a throwaway probe, not part of the real build graph".
      isConftest = a: a != null && hasPrefix "conftest" (builtins.baseNameOf a);
      hasSuffix = suffix: str:
        let
          sl = builtins.stringLength suffix;
          l = builtins.stringLength str;
        in
        l >= sl && builtins.substring (l - sl) sl str == suffix;
      # Positional (non-flag, non-`-o`-value) argv entries -- the actual
      # inputs a link step would combine, or the single source a
      # compile-to-executable probe names.
      positionalIdxs = builtins.filter (
        i: !(hasPrefix "-" (builtins.elemAt argv i)) && i != outIdx + 1
      ) indices;
      positionalArgs = map (i: builtins.elemAt argv i) positionalIdxs;
      looksLikeObjectOrArchive = a: hasSuffix ".o" a || hasSuffix ".a" a || hasSuffix ".so" a;
      # A "link" invocation (no `-c`) whose positional inputs are ALL
      # source files (no `.o`/`.a`/`.so`) is really a COMPILE-STRAIGHT-
      # TO-EXECUTABLE, not a real link step -- kept as a SECONDARY
      # passthrough signal (beyond `isConftest` above) for any probe
      # that doesn't happen to follow the `conftest` naming convention.
      isRealLink = !hasCompileFlag && builtins.any looksLikeObjectOrArchive positionalArgs;
      isCompileToExecutableProbe = !hasCompileFlag && !isRealLink && positionalArgs != [ ];
      # A non-compile invocation with NO positional inputs at all (not
      # even a source file to compile-and-run) is one of GCC's own
      # info-query modes (`-print-multi-os-directory`, `-dumpversion`,
      # `--version`, `-v`, ...) -- confirmed by direct reproduction
      # against a real libtool-driven autotools build (freetype): `cc
      # -print-multi-os-directory -o $out` has no real object/archive/
      # source input whatsoever, just flags, yet still carries an `-o`
      # naming where its plain-text stdout should be written. Neither
      # `isRealLink` nor `isCompileToExecutableProbe` catch this (both
      # require a positional input), so it fell through to the ordinary
      # defer path -- deferring a query with no real content to produce
      # left `$out` never written, and the calling script's own `-o`
      # target permanently missing.
      isInfoQuery = !hasCompileFlag && !isRealLink && positionalArgs == [ ];
      isProbe =
        isCompileToExecutableProbe
        || isInfoQuery
        || isConftest sourcePath
        || builtins.any isConftest positionalArgs
        || (outIdx != (-1) && isConftest (builtins.elemAt argv (outIdx + 1)));
    in
    # PASSTHROUGH for any probe invocation -- see `isProbe` above. These
    # need to run for real, synchronously, since either the calling
    # script executes the result immediately in the same step, or the
    # probe's own logic depends on the REAL exit code/output, not a
    # deferred stub's always-successful placeholder.
    if isProbe then
      null
    else
    # PASSTHROUGH for a compile whose own source is still an ABSOLUTE path
    # after `wrapCommand`'s `stripPwdPrefix` pass -- confirmed by direct
    # reproduction against a real ffmpeg build: its own `configure` script
    # runs GCC feature-probes against scratch files in a THIRD kind of
    # location (`/build/ffconf.XXXXXXXX/test.c`), neither under the
    # compile's own `$PWD` nor a real Nix store path. These are transient
    # compiler self-tests, not part of the package's own cacheable build
    # graph, so there's no caching value in accelerating them -- run them
    # for real, unaccelerated, immediately (this is the ONLY case left
    # that still runs synchronously; nothing else in this shim blocks).
    if hasCompileFlag && sourcePath != null && hasPrefix "/" sourcePath then
      null
    else if outIdx == (-1) && implicitOutputFile == null then
      null
    else
      let
        outputFile = if outIdx != (-1) then builtins.elemAt argv (outIdx + 1) else implicitOutputFile;
        treeBasename = builtins.getEnv "DYNDRV_TREE_BASENAME";
        # `ccShim`/`cxxShim` (below) share this IDENTICAL `toNode`
        # string -- both need the SAME discovery/deferral logic, only
        # the underlying real tool binary differs -- so it can't just
        # splice in a single fixed tool path at DEFINITION time; doing
        # so baked `cc` into `record.tool` even for a `c++`-invoked
        # deferral (meson's own `g++`/`cpp_LINKER` rule), which then
        # ACTUALLY LINKED via plain `cc` at build time instead of
        # `c++`/`g++` -- confirmed by direct reproduction against
        # `nix-util-c`'s own link: missing `operator new`/`delete`,
        # `__cxa_throw`, RTTI vtables (core runtime symbols only
        # `libstdc++` provides, which `cc` alone never auto-links the
        # way `c++` does). `wrapCommand.nix`'s own wrapper script
        # exports `DYNDRV_REAL_COMMAND` (== this invocation's own
        # `realCommand`) before ever calling this nested
        # `nix-instantiate`, so reading it back here gets the tool
        # THIS specific shim actually shadows.
        realCommand = builtins.getEnv "DYNDRV_REAL_COMMAND";
        # See `wrapCommand.nix`'s own header comment on
        # `DYNDRV_TREE_UPDEPTH`/`dyndrvUpDirName` -- the nested-position
        # string for THIS invocation, computed here (not in
        # `ccToNodeBash`, which is DEAD CODE for `cc`/`c++`: both
        # `ccShim`/`cxxShim` below set `discoverTree`, and
        # `wrapCommand.nix`'s `discoverTree`-active wrapperScript
        # variant ONLY ever calls `toNode` via a direct
        # `nix-instantiate` invocation, never `toNodeBash` at all --
        # confirmed by direct reproduction: the actual built `cc`
        # wrapper script contains no `dyndrv_to_node`/
        # `dyndrv_call_to_node`, only the `nix-instantiate` call). `""`
        # (absent from `record`, since `chdir` is entirely omitted
        # below when empty) when this invocation staged nothing beyond
        # its own cwd.
        treeUpDepth = let v = builtins.getEnv "DYNDRV_TREE_UPDEPTH"; in if v == "" then 0 else builtins.fromJSON v;
        treeUpDirName =
          let v = builtins.getEnv "DYNDRV_TREE_UPDIRNAME"; in if v == "" then ".dyndrv-cwd" else v;
        chdir = builtins.concatStringsSep "" (builtins.genList (_: "''${treeUpDirName}/") treeUpDepth);

        # nixpkgs' own cc-wrapper/bintools-wrapper setup hooks inject
        # extra compiler flags via ENV VARS (`NIX_CFLAGS_COMPILE`,
        # `NIX_LDFLAGS`, ...), populated from `buildInputs`/
        # `propagatedBuildInputs` (e.g. boost's own `-isystem` for its
        # headers) at the point THOSE packages' setup hooks ran, long
        # before this compile's own argv was ever constructed --
        # confirmed necessary by direct reproduction against NixOS/
        # nix's own `nix-util` component: `#include <boost/format.hpp>`
        # failed with "No such file or directory" even though boost IS
        # a real `propagatedBuildInput`, because the registered
        # derivation's own `env` (see `setupCmd` below) never carried
        # `NIX_CFLAGS_COMPILE` at all -- only `{out: ...}` was ever
        # exported inside the eventual one-shot builder, so this
        # ambient, setup-hook-populated var was simply unset there.
        # Read here via `builtins.getEnv` (the SAME mechanism
        # `treeBasename`/`treeUpDepth` above already use) for each
        # allowlisted name -- `nix-instantiate`'s own subprocess
        # inherits the calling wrapper script's FULL environment
        # (bash's `VAR=val cmd` form only PREPENDS `ARGV_PATH`/
        # `DYNDRV_TREE_BASENAME`/etc., never clears the rest), so every
        # one of these vars is genuinely present to read, exactly as
        # ambient as they'd be for the compile if it ran unaccelerated.
        wrapperEnvNames = [
          "NIX_CFLAGS_COMPILE_BEFORE"
          "NIX_CFLAGS_COMPILE"
          "NIX_CFLAGS_LINK"
          "NIX_LDFLAGS_BEFORE"
          "NIX_LDFLAGS"
          "NIX_CXXSTDLIB_COMPILE"
          "NIX_CXXSTDLIB_LINK"
          "NIX_DYNAMIC_LINKER"
          "NIX_HARDENING_ENABLE"
          "NIX_ENFORCE_NO_NATIVE"
          "NIX_ENFORCE_PURITY"
        ];
        # `stdenv.cc.suffixSalt` (e.g. `"x86_64_unknown_linux_gnu"`):
        # the TARGET-SUFFIXED form of each name above (confirmed via
        # direct eval this attribute exists and matches the suffix
        # cc-wrapper's own setup hook actually uses) -- both the bare
        # and salted form are captured, matching the bash oracle's own
        # allowlist regex exactly (roughly "_<anything>" as an optional
        # suffix), here narrowed to the ONE concrete salt this stdenv
        # actually uses, since `builtins.getEnv` needs an exact name,
        # not a pattern. This OUTER Nix file's own value for the salt
        # is spliced in directly below (escaped so the INNER generated
        # program's own `n` stays a runtime concatenation, not a
        # second `builtins.getEnv` for the salt itself).
        #
        # `wrapperEnvPairs`: `[ { name = ...; value = ...; } ]` for
        # every actually-SET var among `wrapperEnvNames`'s bare+salted
        # forms, PLUS the `NIX_CC_WRAPPER_TARGET_HOST`/`NIX_BINTOOLS_
        # WRAPPER_TARGET_HOST`-style role markers (SALTED-ONLY -- no
        # bare form exists at all): plain `=1` markers cc-wrapper's/
        # bintools-wrapper's own setup hooks set per BUILD/HOST/TARGET
        # role, read by `add-flags.sh`'s own `accumulateRoles`/
        # `mangleVarList` (ambient in every real, unaccelerated build)
        # to decide WHICH bare `NIX_CFLAGS_COMPILE`-style var actually
        # gets copied into the salted variant `cc` itself reads --
        # confirmed necessary by direct reproduction: exporting
        # `NIX_CFLAGS_COMPILE` (bare) alone, WITHOUT this marker, left
        # `add-flags.sh`'s `role_suffixes` array empty, so the salted
        # var it writes to (the ONLY one `cc`'s own script ever reads)
        # never got boost's `-isystem` flag copied into it at all.
        # Collected as one list of pairs (not built directly into the
        # export string) so `extraStorePaths` below can ALSO scan
        # every value for a real store path it references (e.g.
        # `NIX_CFLAGS_COMPILE`'s own `-isystem /nix/store/...-boost-
        # ...-dev/include`) -- confirmed necessary by direct
        # reproduction against NixOS/nix's own `nix-util` component:
        # exporting the flag TEXT correctly still failed with
        # "boost/format.hpp: No such file or directory", because
        # boost's own store path was never declared as a `srcs` input
        # at all (only argv itself was ever scanned for store-path
        # references before this fix) -- boost's `-isystem` flag lives
        # ENTIRELY inside an env var's value, invisible to that argv-
        # only scan, so the path was simply absent from the sandbox's
        # own mounted closure even though the flag text pointing at it
        # was correctly exported.
        wrapperEnvPairs =
          builtins.concatMap (
            n:
            builtins.concatMap (
              name:
              let v = builtins.getEnv name; in
              if v == "" then [ ] else [ { inherit name; value = v; } ]
            ) [ n "''${n}_${stdenv.cc.suffixSalt or "__dyndrv_no_salt__"}" ]
          ) wrapperEnvNames
          ++ builtins.concatMap (
            n:
            let salted = "''${n}_${stdenv.cc.suffixSalt or "__dyndrv_no_salt__"}"; v = builtins.getEnv salted; in
            if v == "" then [ ] else [ { name = salted; value = v; } ]
          ) [ "NIX_CC_WRAPPER_TARGET_BUILD" "NIX_CC_WRAPPER_TARGET_HOST" "NIX_CC_WRAPPER_TARGET_TARGET" "NIX_BINTOOLS_WRAPPER_TARGET_BUILD" "NIX_BINTOOLS_WRAPPER_TARGET_HOST" "NIX_BINTOOLS_WRAPPER_TARGET_TARGET" ];
        wrapperEnvExports = builtins.concatStringsSep "" (
          map (p: " export ''${p.name}=''${shellQuote p.value};") wrapperEnvPairs
        );

        # Single-quote each argv element for safe embedding in a
        # /bin/sh -c command line -- see `collectStubs.nix`'s own
        # `dyndrv_sq` (the eventual RUNTIME rewrite happens there, over
        # `record.args`; this Nix-side `shellQuote` only matters for the
        # sentinel string "$out" itself staying unquoted so it can later
        # be substituted).
        sq = builtins.substring 0 1 "'X";
        bs = builtins.substring 0 1 "\\X";
        shellQuote = s: sq + (builtins.replaceStrings [ sq ] [ (sq + bs + sq + sq) ] s) + sq;
        # When the ORIGINAL argv already has an explicit `-o <file>`, its
        # value must be REPLACED with the literal sentinel `"$out"`, not
        # left in place while a second `-o $out` gets appended afterward
        # -- confirmed by direct reproduction against a real
        # libtool/autoconf probe: GCC accepts multiple `-o` flags
        # silently and uses the LAST one, so appending unconditionally
        # made the compile write to `$out` while the file the CALLING
        # build actually expected was never created. `argvForCc` (with
        # the literal, UNQUOTED sentinel "$out") is `record.args` --
        # `shim.collectStubs`'s own renderer applies its OWN shell-
        # quoting downstream, so this array must stay unquoted here.
        argvForCc =
          if outIdx != (-1) then
            builtins.genList (
              i: if i == outIdx + 1 then "$out" else builtins.elemAt argv i
            ) len
          else
            argv ++ [ "-o" "$out" ];

        # A LINK invocation compiled with `-flto` can leave `libm`
        # symbols (`pow`, seen in practice) unresolved at link time --
        # confirmed by direct reproduction against NixOS/nix's own
        # `nix-util` component: `std::pow` calls in two SEPARATELY-
        # compiled translation units (`util.cc`/`linux/cgroup.cc`)
        # linked with `undefined reference to 'pow'` under LTO, even
        # though the IDENTICAL component links fine, with the
        # IDENTICAL flags, when built unaccelerated (confirmed by
        # direct A/B rebuild: neither a unity-build nor a per-TU
        # unaccelerated build of the same component ever needs `-lm`
        # explicitly) -- the gap is specific to GCC's LTO partitioning
        # across SEPARATELY-compiled, individually-registered `.o`
        # objects (each its own CA derivation here) rather than one
        # shared ninja invocation's own LTRANS decisions. Confirmed by
        # direct reproduction that appending `-lm` to the EXACT
        # failing link command resolves it. Scoped to LINK invocations
        # (`!hasCompileFlag`) whose own argv already contains `-flto`
        # (matching, not guessing at, what triggered the gap) -- a
        # project that never uses LTO is completely unaffected.
        #
        # The SAME gap ALSO drops core `libstdc++` runtime symbols
        # (`operator new`/`delete`, `__cxa_throw`, RTTI vtables, ...)
        # -- confirmed by direct reproduction against NixOS/nix's own
        # `nix-store` component: meson invokes the plain `cc` (not
        # `c++`) for its final `.so` link, exactly like `nix-util`'s
        # own `libnixutil.so` link, so nothing auto-links `libstdc++`
        # at all; a real, unaccelerated meson/ninja build gets away
        # with this because ONE shared ninja invocation's own LTO
        # partitioning happens to resolve these internally, but per-TU
        # acceleration's SEPARATE, individually-registered `.o`
        # derivations hit the identical class of gap `-lm` above fixes
        # -- so `-lstdc++` is appended alongside it, under the exact
        # same condition.
        argvForCc' =
          if !hasCompileFlag && builtins.any (a: hasPrefix "-flto" a) argvForCc then
            argvForCc ++ [ "-lm" "-lstdc++" ]
          else
            argvForCc;

        # bintools-wrapper's own `ld` injects `--build-id=''${NIX_BUILD_ID_
        # STYLE:-sha1}` whenever `NIX_SET_BUILD_ID_<suffixSalt>` is set
        # (`separate-debug-info.sh`'s own setup hook exports the BARE
        # form unconditionally, whenever `separateDebugInfo = true`) --
        # but `phases/split.nix`'s own phase 1 unconditionally forces
        # `separateDebugInfo = false` (to avoid producing a meaningless
        # standalone debug output there -- see that file's own header
        # comment), so that setup hook never runs during the REAL
        # `buildPhase` where every per-TU compile/link actually
        # happens. `toNode` itself is constructed ONCE, when
        # `mkAcceleratedStdenv` is first called -- long before any
        # particular caller's OWN `separateDebugInfo` value is even
        # known -- so there's no ambient signal to read at all here,
        # unlike `-lm`-under-LTO above (which detects an ALREADY-
        # PRESENT `-flto` flag in argv, not an external setting).
        # Appending this UNCONDITIONALLY on every link step is
        # therefore the only option that actually works: harmless for
        # a caller that never sets `separateDebugInfo` (the flag is
        # simply unused there), but required for one that does --
        # confirmed necessary by direct reproduction against NixOS/
        # nix's own `nix-util` component (`readelf -n` on the linked
        # `.so` showed no `.note.gnu.build-id` section at all without
        # this, which then broke `separateDebugInfo`'s own
        # `_separateDebugInfo` fixup hook outright: "could not find
        # build ID of $i, skipping", then "failed to produce output
        # path for output 'debug'" since nothing ever got created
        # under `$debugOutput/lib/debug/.build-id`).
        argvForCcFinal =
          if !hasCompileFlag then
            argvForCc' ++ [ "-Wl,--build-id=sha1" ]
          else
            argvForCc';

        # Any argv element (or wrapper-env-var VALUE, e.g. `NIX_CFLAGS_
        # COMPILE`'s own `-isystem /nix/store/...-boost-...-dev/include`
        # -- see `wrapperEnvPairs`'s own header comment on why this
        # scan can't be argv-only) can reference a store path NOT
        # already covered by `stdenv.cc`/`coreutils`/the staged tree --
        # e.g. `-I/nix/store/...-libpng-.../include`, glued directly
        # onto the flag with no space (confirmed necessary by direct
        # reproduction against a real freetype build).
        #
        # `findAllStorePaths`: `builtins.match` only ever returns the
        # FIRST match on a `.*(...).*`-style pattern, insufficient for
        # a string like `NIX_CFLAGS_COMPILE`'s value that concatenates
        # MANY `-isystem <path>/include` flags together (confirmed
        # necessary by direct reproduction: a single-`match` scan found
        # only the LAST store path in such a string, silently dropping
        # every earlier one). `builtins.split` (unlike `match`) returns
        # every non-overlapping match across the WHOLE string in one
        # pass -- odd-indexed elements are each match's own capture-
        # group list (even-indexed elements are the literal text
        # BETWEEN matches, discarded here).
        #
        # Filters out any match whose basename ends in `.drv` --
        # confirmed necessary by direct reproduction against NixOS/
        # nix's own `nix-util` component: `NIX_LDFLAGS`'s own `-rpath
        # <placeholder>/lib` value contains THIS DERIVATION'S OWN
        # self-referential CA output placeholder (e.g. `/nix/store/
        # <hash>-nix-util-2.36.0pre.drv/lib`, `stdenv`'s ordinary `-
        # rpath $out/lib` linker flag with `$out` already substituted
        # to the not-yet-built placeholder text by the time this
        # invocation's env is constructed) -- scanning it unconditionally
        # added that self-reference as a required `srcs` entry on
        # EVERY compile's own registered derivation, and since that
        # path can never become valid (it's this package's own not-
        # yet-realized output, referencing itself), the eventual final
        # `nix store submit-output` failed with "path ... is not
        # valid" -- confirmed by direct reproduction that the exact
        # failing path's hash prefix matched this exact placeholder.
        # A REAL store input is never itself named `*.drv` (that
        # naming convention is reserved for `.drv` FILES themselves,
        # never an ordinary package's own output) -- see `phases/
        # split.nix`'s own header comment on why `mkDynamicDerivation`'s
        # outer wrapper is deliberately named this way -- so this
        # filter can never accidentally exclude a genuinely-needed
        # dependency.
        findAllStorePaths = s:
          builtins.filter (p: !(hasSuffix ".drv" p)) (
            builtins.concatMap (
              x: if builtins.isList x then [ (builtins.elemAt x 0) ] else [ ]
            ) (builtins.split "${builtins.storeDir}/([^/\"' ]+)" s)
          );
        extraStorePathsRaw =
          builtins.concatMap findAllStorePaths argv
          ++ builtins.concatMap (p: findAllStorePaths p.value) wrapperEnvPairs;
        extraStorePaths = builtins.attrNames (
          builtins.listToAttrs (map (n: { name = n; value = null; }) extraStorePathsRaw)
        );
        srcsList = [
          (builtins.baseNameOf "${pkgs.coreutils}")
          (builtins.baseNameOf "${stdenv.cc}")
          treeBasename
        ] ++ extraStorePaths;
      in
      {
        defer = {
          record = builtins.toJSON (
            {
              key = batchKey;
              tool = if realCommand == "" then "${realCc}" else realCommand;
              args = argvForCcFinal;
              srcs = srcsList;
              # `chmod -R u+w .` AFTER `cp -r`, not before: `cp -r`
              # preserves the read-only Nix store source's permissions on
              # the destination, so chmod'ing before is a no-op (the
              # following `cp -r` overwrites it right back to read-only);
              # needed both for members sharing a working directory AND
              # for a real compile writing its own `.d` file back into the
              # tree (`-MF`, ffmpeg's own dependency-file generation).
              setupCmd = "''${wrapperEnvExports}${pkgs.coreutils}/bin/cp -r ''${builtins.storeDir}/''${treeBasename}/. . && ${pkgs.coreutils}/bin/chmod -R u+w . &&";
            }
            // (if chdir != "" then { inherit chdir; } else { })
          );
        };
      }
      // (if outIdx != (-1) then { outputArg = outIdx + 1; } else { outputPath = implicitOutputFile; })
  '';

  # `ar`'s own argv shape (simpler and more fixed than `cc`'s -- no
  # discovery needed, no relative `-I` search paths, no headers): the
  # FIRST token is the modifiers/command string (e.g. "rcs" -- no
  # leading `-`, unlike `cc`'s flags), the SECOND is the archive path,
  # everything after that is a positional object-file input. ALWAYS
  # defers -- there is no passthrough case for `ar` (unlike `cc`'s
  # foreign-tempdir-probe exception, no analogous "not part of the
  # build graph" `ar` invocation is known to occur in practice; if one
  # ever does, it would need the same absolute-path check `cc`'s
  # `toNode` uses). No `discoverTree` needed: `ar`'s positional inputs
  # are already-known relative paths (other stubs, resolved later by
  # `shim.collectStubs`'s own sibling/cross-unit substitution), never
  # header files.
  arToNode = ''
    argv:
    let
      len = builtins.length argv;
      modifiers = builtins.elemAt argv 0;
      archivePath = builtins.elemAt argv 1;
      inputs = builtins.genList (i: builtins.elemAt argv (i + 2)) (len - 2);
      argvForAr = [ modifiers "$out" ] ++ inputs;
    in
    {
      defer = {
        record = builtins.toJSON {
          key = null;
          tool = "${realAr}";
          args = argvForAr;
          # `stdenv.cc.bintools.bintools` (the package `realAr` lives in)
          # must be declared here -- confirmed necessary by direct
          # reproduction against a real freetype build: an empty `srcs`
          # left the sandbox with no `ar` binary mounted at all ("ar: not
          # found"), since nothing else in the merged unit's own record
          # chain happened to reference it.
          srcs = [ (builtins.baseNameOf "${stdenv.cc.bintools.bintools}") ];
        };
      };
      outputArg = 1;
    }
  '';

  ccShim = self.shim.wrapCommand {
    command = "cc";
    realCommand = realCc;
    toNodeBash = ccToNodeBash;
    toNodeCompiled = if useCompiledShim then dyndrvShim else null;
    # `DYNDRV_BATCH_GROUPS` is NOT set here -- it's already ambient at
    # runtime, set directly on the sandboxed derivation's own env (see
    # `mkDerivation`'s `sandboxed` attrset below, `granularity ==
    # "module"` branch), inherited by every child process including
    # this compiled binary when it runs `cc`. `rust/dyndrv-shim/src/
    # cc.rs`'s own `cc_to_node` reads it the same way `toNode`'s
    # `builtins.getEnv "DYNDRV_BATCH_GROUPS"` does.
    compiledEnv = lib.optionalAttrs useCompiledShim {
      DYNDRV_REAL_COMMAND = realCc;
      DYNDRV_COREUTILS_BASENAME = builtins.baseNameOf "${pkgs.coreutils}";
      DYNDRV_STDENV_CC_BASENAME = builtins.baseNameOf "${stdenv.cc}";
    };
    inherit toNode discoverTree nixPackage;
  };

  # A SEPARATE `wrapCommand` instance from `ccShim` -- same decision
  # logic (`toNode`/`toNodeBash`/`discoverTree` all identical, since a
  # C vs. C++ compile's OWN argv-decision shape is identical, only the
  # underlying tool binary differs), just `realCommand`/`DYNDRV_REAL_
  # COMMAND` pointed at the real `c++` instead of `cc` -- see `realCxx`'s
  # own doc comment above for why this distinction matters (linking a
  # C++ TU via plain `cc` fails outright without `-lstdc++`).
  cxxShim = self.shim.wrapCommand {
    command = "cc";
    realCommand = realCxx;
    toNodeBash = ccToNodeBash;
    toNodeCompiled = if useCompiledShim then dyndrvShim else null;
    compiledEnv = lib.optionalAttrs useCompiledShim {
      DYNDRV_REAL_COMMAND = realCxx;
      DYNDRV_COREUTILS_BASENAME = builtins.baseNameOf "${pkgs.coreutils}";
      DYNDRV_STDENV_CC_BASENAME = builtins.baseNameOf "${stdenv.cc}";
    };
    inherit toNode discoverTree nixPackage;
  };

  arShim = self.shim.wrapCommand {
    command = "ar";
    realCommand = realAr;
    toNode = arToNode;
    toNodeCompiled = if useCompiledShim then dyndrvShim else null;
    compiledEnv = lib.optionalAttrs useCompiledShim {
      DYNDRV_REAL_COMMAND = realAr;
      DYNDRV_BINTOOLS_BASENAME = builtins.baseNameOf "${stdenv.cc.bintools.bintools}";
    };
    inherit nixPackage;
  };

  # `ranlib`'s own argv shape: the archive path(s) directly, no
  # modifiers/flags in the common case -- confirmed necessary by direct
  # reproduction against a real freetype build: libtool's own link step
  # runs `ranlib` on the archive `ar` JUST created, and since `ar`'s own
  # output there is a deferred STUB (not yet a real archive), an
  # unshimmed `ranlib` fails outright ("file format not recognized").
  # Defers exactly like `ar` -- its own positional argument (the archive
  # path) is itself a pending stub, which `shim.collectStubs`'s own
  # sibling/cross-unit resolution handles the same way any other
  # stub-referencing invocation is handled; no `key` of its own, so it
  # joins whatever unit its one input (the archive) already belongs to.
  realRanlib = "${stdenv.cc.bintools.bintools}/bin/ranlib";
  ranlibToNode = ''
    argv:
    let
      len = builtins.length argv;
      # `ranlib`'s only positional argument (the LAST one, tolerating
      # any leading flags like `-D`) is both its input AND its own
      # output -- it indexes an archive in place, it doesn't produce a
      # separate result. Reusing that SAME path for `outputArg` means
      # the wrapper copies the realized result back over the identical
      # relative path the calling build already expects.
      archiveIdx = len - 1;
      argvForRanlib = builtins.genList (
        i: if i == archiveIdx then "$out" else builtins.elemAt argv i
      ) len;
    in
    {
      defer = {
        record = builtins.toJSON {
          key = null;
          tool = "${realRanlib}";
          args = argvForRanlib;
          # Same "the tool's own store path must be declared as a src"
          # requirement as `arToNode` above -- `ranlib` shares the same
          # `bintools` package as `ar`, so this is the same input, just
          # declared independently since `ranlib`'s own record may be
          # rendered without `ar`'s (e.g. chained standalone) and each
          # record's `srcs` must be self-sufficient.
          srcs = [ (builtins.baseNameOf "${stdenv.cc.bintools.bintools}") ];
        };
      };
      outputArg = archiveIdx;
    }
  '';
  ranlibShim = self.shim.wrapCommand {
    command = "ranlib";
    realCommand = realRanlib;
    toNode = ranlibToNode;
    toNodeCompiled = if useCompiledShim then dyndrvShim else null;
    compiledEnv = lib.optionalAttrs useCompiledShim {
      DYNDRV_REAL_COMMAND = realRanlib;
      DYNDRV_BINTOOLS_BASENAME = builtins.baseNameOf "${stdenv.cc.bintools.bintools}";
      DYNDRV_COREUTILS_BASENAME = builtins.baseNameOf "${pkgs.coreutils}";
    };
    inherit nixPackage;
  };

  # cc-wrapper's own setup hook exports `CC=gcc`/`CXX=g++` (the real
  # compiler binaries' own bare NAMES, not "cc"/"c++") directly into the
  # build environment -- so shadowing `cc`/`c++` alone on `$PATH` doesn't
  # intercept anything a real build actually calls. Confirmed by direct
  # reproduction: `gcc-wrapper`'s own `nix-support/setup-hook` runs its
  # `export CXX=g++` UNCONDITIONALLY, AFTER this derivation's own `env.
  # CXX` attr override below is already set -- setup hooks run at the
  # START of a real sandboxed build, before `buildPhase`, so a plain
  # `env.CXX = "${wrapperDir}/bin/cc";` override alone is silently
  # clobbered the moment ANY C++ translation unit's own build actually
  # runs, falling through to the REAL, unshimmed `g++` on `$PATH`
  # instead -- meaning C++ sources were never being accelerated at all
  # until this wrapper was ALSO installed under `c++`/`g++` (this exact
  # gap was found via a real C++ project, `example/`, the first C++
  # fixture this repo ever exercised through `mkAcceleratedStdenv` --
  # every prior example used plain C, where `CC=gcc` is correctly
  # covered by the `cc`/`gcc` symlink pair below, so this never
  # surfaced before). `cxxShim` (a distinct `wrapCommand` instance
  # pointed at the REAL `c++`, not `cc` -- see `realCxx`'s own doc
  # comment) is installed under BOTH `c++` and `g++` here, mirroring
  # `ccShim`'s own `cc`/`gcc` pair exactly. `CC`/`CXX`/`AR`/`RANLIB` are
  # ALSO overridden explicitly below (`sandboxed` attrset) -- belt and
  # suspenders, since some build systems read the env var directly
  # without ever touching `$PATH`.
  wrapperDir = pkgs.runCommand "dyndrv-cc-shim" { } ''
    mkdir -p $out/bin
    install -Dm755 ${pkgs.writeText "cc" ccShim.wrapperScript} $out/bin/cc
    ln -s cc $out/bin/gcc
    install -Dm755 ${pkgs.writeText "c++" cxxShim.wrapperScript} $out/bin/c++
    ln -s c++ $out/bin/g++
    install -Dm755 ${pkgs.writeText "ar" arShim.wrapperScript} $out/bin/ar
    install -Dm755 ${pkgs.writeText "ranlib" ranlibShim.wrapperScript} $out/bin/ranlib
  '';

  # `shouldBatch`'s eval-time-computed grouping, threaded across the
  # eval/build boundary as `DYNDRV_BATCH_GROUPS` -- see this file's
  # header comment for the full "why" and the accepted IFD cost (only
  # for `granularity = "module"`).
  batchGroupOfAttrs =
    src:
    let
      srcRoot = toString src;
      allSrcFiles = map (
        f: builtins.unsafeDiscardStringContext (lib.removePrefix (srcRoot + "/") (toString f))
      ) (lib.filesystem.listFilesRecursive src);
      batchedFiles = builtins.filter shouldBatch allSrcFiles;
    in
    builtins.listToAttrs (
      map (p: {
        name = p;
        value = lib.dirOf p;
      }) batchedFiles
    );
in
if granularity == "package" then
  stdenv
else
  let
    # `mkDerivation` must accept BOTH call conventions real nixpkgs
    # packages use for `stdenv.mkDerivation`: a plain attrset, OR a
    # `finalAttrs: {...}` function (confirmed necessary by direct
    # reproduction: `pkgs.freetype`'s own definition uses the latter,
    # self-referencing `finalAttrs.pname`/`.version` inside its own
    # `src`) -- mirrors nixpkgs' own `lib.extendMkDerivation`'s
    # `__functor` dispatch (`isFunction fpargs then fpargs final else
    # fpargs`), specifically the lazy self-referential fixed point:
    # `finalArgs` is bound to the FULLY RESOLVED attrset this function
    # itself computes and returns, which Nix's own laziness allows to
    # reference itself before it's fully evaluated.
    #
    # The result's own `overrideAttrs` is a CUSTOM one, NOT the one
    # nixpkgs' own `stdenv.mkDerivation` would attach -- confirmed
    # necessary by direct reproduction against real, unmodified freetype:
    # `phases.split`'s returned value is PHASE 2's own ordinary
    # derivation (install/fixup only), so ITS default `overrideAttrs`
    # only ever re-runs phase 2's construction, with `src` still pointing
    # at phase 1's ALREADY-RESOLVED, stale output -- a caller's
    # `.overrideAttrs (old: { patches = old.patches ++ [x]; })` (the
    # standard nixpkgs idiom for exactly the "patch this package" case
    # this accelerator exists to make cheap) silently never reaches
    # `patchPhase` at all, since that phase only runs in PHASE 1, which
    # already built with the ORIGINAL args before the override call ever
    # happens. Confirmed directly: freetype.override{stdenv=...}.
    # overrideAttrs(old: {patches = old.patches ++ [x];}) applied only
    # freetype's own 7 real patches under the accelerated stdenv (x
    # silently dropped), while the identical call under `pkgs.stdenv`
    # applied all 8 (x included) -- same shape as the bug nixpkgs' own
    # `makeDerivationExtensible` was written to prevent for ordinary
    # `mkDerivation`, just reappearing here because `phases.split`
    # interposes a second, independent `stdenv.mkDerivation` call (phase
    # 2's) whose own default `overrideAttrs` has no way to know phase 1
    # needs re-running too.
    #
    # The fix mirrors `makeDerivationExtensible`'s own self-referential
    # pattern exactly (see `pkgs/stdenv/generic/make-derivation.nix`):
    # `rattrs` is `fpargs` normalized to always be a `final: {...}`
    # function; `args` is computed by feeding `rattrs` ITS OWN eventual
    # result (`args // { inherit overrideAttrs; }`) -- Nix's laziness
    # allows this because `overrideAttrs`'s OWN definition doesn't force
    # `args`'s value, only closes over `rattrs`. `overrideAttrs f0`
    # computes the merged overlay exactly like nixpkgs' own
    # `thisOverlay` (`f0` may be `prev: {...}` OR `final: prev: {...}`,
    # both real nixpkgs call shapes), then calls `mkDerivation` AGAIN
    # with the merged function -- re-running the WHOLE `phases.split`
    # call, phase 1 included, from scratch with the new args. `mkDerivation`
    # is a genuinely recursive `let` binding (Nix `let` bindings can always
    # reference themselves and each other, unlike a plain `//`-merged
    # attrset attribute) so `overrideAttrs`, defined per-call INSIDE
    # `mkDerivation`'s own body below (closing over THIS call's own
    # `rattrs`, needed to compute `prev`), can call `mkDerivation` again by
    # name.
    mkDerivation =
      fpargs:
      let
        rattrs = if builtins.isFunction fpargs then fpargs else (_: fpargs);
        args = rattrs (args // { inherit overrideAttrs; });
        overrideAttrs =
          f0:
          mkDerivation (
            final:
            let
              prev = rattrs final;
              thisOverlay =
                if builtins.isFunction f0 then
                  let
                    fPrev = f0 prev;
                  in
                  if builtins.isFunction fPrev then f0 final prev else fPrev
                else
                  f0;
            in
            prev // thisOverlay
          );
      in
      assert
        args ? pname && args ? version
        || throw "dyndrv.accelerate.mkAcceleratedStdenv: mkDerivation call must set pname/version (phases.split needs both to name phase 1's own inner derivation) -- name-only calls aren't supported yet";
      self.phases.split {
        inherit stdenv nixPackage dyndrvShim;
        inherit (args) pname version;
        sandboxed = args // {
          nativeBuildInputs = [ wrapperDir ] ++ (args.nativeBuildInputs or [ ]);
          CC = "${wrapperDir}/bin/cc";
          CXX = "${wrapperDir}/bin/c++";
          AR = "${wrapperDir}/bin/ar";
          RANLIB = "${wrapperDir}/bin/ranlib";
        }
        // lib.optionalAttrs (granularity == "module") {
          DYNDRV_BATCH_GROUPS = builtins.toJSON (batchGroupOfAttrs args.src);
        };
        replay = args;
      }
      // {
        inherit overrideAttrs;
      };
  in
  # `stdenv // { mkDerivation = ...; }`, NOT a fresh `{ inherit stdenv;
  # ...; }` attrset -- the RETURNED value must still carry every real
  # `stdenv` attribute (`hostPlatform`, `cc`, `buildPlatform`, etc.), not
  # just `.mkDerivation`, since real packages' own `.override { stdenv =
  # ...; }` machinery (confirmed necessary by direct reproduction against
  # `pkgs.freetype.override { inherit stdenv; }`) reads OTHER stdenv
  # attributes off the value passed as `stdenv`, not just `.mkDerivation`
  # -- a nested `{ stdenv = <real stdenv>; }` shape fails with "attribute
  # 'hostPlatform' missing" the moment anything looks for it directly on
  # the top-level value.
  stdenv
  // {
    inherit mkDerivation;
  }
