use crate::mode::DyndrvMode;
use crate::record::Record;
use crate::rpc_tail::run_rpc_tail;
use crate::stub;
use crate::thunk_tail::run_thunk_tail;
use crate::tonode::Decision;
use anyhow::Context;
use nix_builder_rpc_client::BuilderRpcClient;
use std::path::{Path, PathBuf};

/// Strips the calling build's own `$PWD` prefix from an argv element --
/// port of `wrapCommand.nix`'s `stripPwdPrefix`, handling both the bare
/// and glued-flag-prefix form generically.
pub fn strip_pwd_prefix(s: &str, orig_pwd: &str) -> String {
    let prefix = format!("{}/", orig_pwd);
    if let Some(rest) = s.strip_prefix(&prefix) {
        return rest.to_string();
    }
    if let Some(idx) = s.find(&prefix) {
        return format!("{}{}", &s[..idx], &s[idx + prefix.len()..]);
    }
    s.to_string()
}

/// Runs the plain (non-`discoverTree`) wrapper pipeline for one
/// intercepted invocation: strip-pwd-prefix every argv element, rewrite
/// any existing-relative-file element to its own store path (skipping
/// anything that's itself a pending stub), run the decision closure,
/// then either exec the real command (passthrough) or write a deferred
/// stub -- direct port of `wrapCommand.nix`'s plain `wrapperScript`
/// variant, minus the `nix-instantiate`/`jq` spawns it needed.
///
/// `decide`: closure implementing this tool's own `toNode`/`toNodeBash`
/// equivalent, given the REWRITTEN argv. `mode`: decided once by
/// `crate::mode::detect()` in the entrypoint, threaded in here rather
/// than re-detected per call.
pub fn run_plain<F>(
    client: &BuilderRpcClient,
    real_command: &str,
    orig_argv: &[String],
    mode: DyndrvMode,
    decide: F,
) -> anyhow::Result<()>
where
    F: FnOnce(&[String]) -> Decision,
{
    let orig_pwd = std::env::current_dir()
        .context("run_plain: current_dir")?
        .display()
        .to_string();

    let stripped: Vec<String> = orig_argv
        .iter()
        .map(|a| strip_pwd_prefix(a, &orig_pwd))
        .collect();

    let rewritten: Vec<String> = stripped
        .iter()
        .map(|a| rewrite_argv_element(client, a))
        .collect::<anyhow::Result<Vec<_>>>()
        .context("run_plain: rewrite_argv_element")?;

    match decide(&rewritten) {
        Decision::Passthrough => {
            // PASSTHROUGH execs with the ORIGINAL argv (not rewritten,
            // not stripped) -- `realCommand` needs the real relative
            // source path in the outer build's own $PWD.
            exec_passthrough(real_command, orig_argv)
        }
        Decision::Defer {
            record,
            output_arg,
            output_path,
        } => {
            let output_path = match (output_arg, output_path) {
                // Resolved from the ORIGINAL (stripped, pre-rewrite)
                // argv, not `rewritten` -- confirmed necessary by direct
                // reproduction against a standalone `ranlib` invocation
                // (`Rpc` mode, no preceding `ar` in the same unit):
                // `ranlib`'s own output path IS an already-real input
                // file (it indexes an archive in place), so `rewrite_
                // argv_element` had ALREADY replaced that exact argv
                // slot with the archive's store path by the time
                // `decide` returned `output_arg`, making the resolved
                // "output path" a `/nix/store/...` string instead of
                // the caller's own relative `liba.a`. This gap is
                // identical in the bash oracle (`wrapCommand.nix`'s own
                // `resolveNodeFields` also indexes `$argvJson`, the
                // rewritten form) but never triggers there: `Sandbox`
                // mode's own `ar`+`ranlib` chaining means the archive is
                // still a pending STUB, never a real file, at rewrite
                // time, so this exact argv slot is never actually
                // rewritten in that mode. Using `stripped` here changes
                // nothing for that already-working case (a stub path
                // rewrites to itself either way) while fixing the
                // previously-unreachable standalone case.
                (Some(idx), _) => stripped
                    .get(idx)
                    .cloned()
                    .ok_or_else(|| anyhow::anyhow!("outputArg {idx} out of range"))?,
                (None, Some(p)) => p,
                (None, None) => anyhow::bail!("decision returned neither outputArg nor outputPath"),
            };
            dispatch_defer(client, mode, &output_path, record)
        }
    }
}

/// Runs the `discoverTree`-mode wrapper pipeline for one intercepted
/// `cc` invocation: stage the whole discovered source/header tree into
/// ONE store object (preserving relative directory structure, so `-I`
/// flags keep working), run the decision closure against the RAW/
/// relative argv (never rewritten to store paths -- see
/// `wrapCommand.nix`'s own header comment for why flattening would
/// break this), then dispatch exactly like `run_plain`'s own tail.
///
/// `discover`: closure implementing `discoverTree`'s own header-scan
/// contract -- given the ORIGINAL argv, returns every RELATIVE path
/// (source AND header) this invocation needs beyond what argv already
/// names directly.
/// `decide`: closure implementing `cc`'s own decision logic, given the
/// RAW argv (unmodified -- `discoverTree` mode's whole point) and the
/// freshly-staged tree's own store basename.
pub fn run_discover_tree<D, F>(
    client: &BuilderRpcClient,
    real_command: &str,
    orig_argv: &[String],
    mode: DyndrvMode,
    discover: D,
    decide: F,
) -> anyhow::Result<()>
where
    D: FnOnce(&[String]) -> Vec<String>,
    F: FnOnce(&[String], &str) -> Decision,
{
    let orig_pwd = std::env::current_dir()
        .context("run_discover_tree: current_dir")?
        .display()
        .to_string();

    // `argv` here is relative wherever the original was
    // absolute-but-under-$PWD; genuinely absolute paths (real store
    // paths) are unchanged -- mirrors `wrapCommand.nix`'s own
    // `discoverTree`-variant `stripPwdPrefix` pass exactly.
    let argv: Vec<String> = orig_argv
        .iter()
        .map(|a| strip_pwd_prefix(a, &orig_pwd))
        .collect();

    let discovered = discover(&argv);

    let mut all_paths: Vec<String> = Vec::new();
    for a in argv.iter() {
        // `-Wl,*` can GLUE an existing relative file onto its own value
        // (e.g. `-Wl,-version-script,objs/.libs/libfreetype.ver`) --
        // confirmed necessary by direct reproduction against a real
        // freetype build: libtool generates that file via plain shell
        // redirection, not `cc`/`ar`, so it's real content already
        // sitting in the tree, invisible to the plain positional scan
        // below since `-Wl,...` is `-`-prefixed. Port of `wrapCommand.
        // nix`'s own `discoverTree`-variant `-Wl,*` case -- only the
        // LAST comma-separated token is ever a file path in practice.
        if let Some(wl_rest) = a.strip_prefix("-Wl,") {
            for tok in wl_rest.split(',') {
                if !tok.is_empty()
                    && !tok.starts_with('-')
                    && !tok.starts_with('/')
                    && Path::new(tok).is_file()
                    && !stub::is_pending(Path::new(tok))
                {
                    all_paths.push(tok.to_string());
                }
            }
            continue;
        }
        if a.starts_with('-') || a.starts_with('/') {
            continue;
        }
        // Excludes `-o`'s own value the same way the plain variant's
        // rewrite loop implicitly does via its own `-*` check --
        // `-o`'s value is never itself `-`-prefixed, so this positional
        // scan would otherwise wrongly stage it as a source/header.
        // `wrapCommand.nix`'s own discoverTree variant has the
        // identical gap (it relies on `-o`'s value typically not being
        // an existing regular file at scan time) -- matched here, not
        // fixed, to stay byte-identical in behavior.
        //
        // A positional relative arg that's itself a still-pending batch
        // stub (e.g. a link step's own `main.o`/`liba.a` args, each some
        // earlier compile's/archive's deferred output -- confirmed
        // necessary by direct reproduction against a real freetype
        // build's `cc ... .libs/*.o ... -o libfreetype.so` link step)
        // must NOT be staged as real file content -- it's placeholder
        // stub bytes, not a real object. Its literal relative-path TEXT
        // stays in argv unchanged for `shim.collectStubs`'s/`dyndrv-
        // collect`'s own dependency scan to resolve into a real
        // cross-unit reference later; only genuinely real files get
        // staged here. Port of `wrapCommand.nix`'s own identical guard.
        if Path::new(a).is_file() && !stub::is_pending(Path::new(a)) {
            all_paths.push(a.clone());
        }
    }
    all_paths.extend(discovered.into_iter().filter(|p| !p.starts_with('/')));
    all_paths.sort();
    all_paths.dedup();

    let tree_dir = stage_tree(&all_paths).context("run_discover_tree: stage_tree")?;
    let tree_basename = client
        .add_to_store_nar("dyndrv-tree", &tree_dir)
        .context("run_discover_tree: add_to_store_nar")?;
    std::fs::remove_dir_all(tree_dir.parent().unwrap_or(&tree_dir)).ok();

    match decide(&argv, &tree_basename.to_string()) {
        Decision::Passthrough => exec_passthrough(real_command, orig_argv),
        Decision::Defer {
            record,
            output_arg,
            output_path,
        } => {
            let output_path = match (output_arg, output_path) {
                (Some(idx), _) => argv
                    .get(idx)
                    .cloned()
                    .ok_or_else(|| anyhow::anyhow!("outputArg {idx} out of range"))?,
                (None, Some(p)) => p,
                (None, None) => anyhow::bail!("decision returned neither outputArg nor outputPath"),
            };
            dispatch_defer(client, mode, &output_path, record)
        }
    }
}

/// Stages every path in `paths` into one scratch directory tree,
/// preserving relative structure -- port of `wrapCommand.nix`'s own
/// discoverTree-variant staging loop. Uses a FIXED basename
/// (`dyndrv-tree`) under a freshly `mktemp`-style-unique parent, same
/// reasoning as that file's own comment: `add_to_store_nar`'s `name`
/// argument (not the on-disk basename) is what actually determines the
/// resulting store name here, so unlike the CLI `nix store add` this
/// binary replaces, the parent directory's own randomization is purely
/// cosmetic -- kept anyway for trivial collision-avoidance across
/// concurrent invocations sharing the same process's cwd.
fn stage_tree(paths: &[String]) -> anyhow::Result<PathBuf> {
    let parent = std::env::temp_dir().join(format!("dyndrv-tree-parent-{}", std::process::id()));
    let tree_dir = parent.join("dyndrv-tree");
    std::fs::create_dir_all(&tree_dir)
        .with_context(|| format!("create_dir_all {}", tree_dir.display()))?;
    for p in paths {
        let src = Path::new(p);
        if !src.is_file() {
            continue;
        }
        let dst = tree_dir.join(p);
        if let Some(parent) = dst.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("create_dir_all {}", parent.display()))?;
        }
        std::fs::copy(src, &dst)
            .with_context(|| format!("copy {} -> {}", src.display(), dst.display()))?;
    }
    Ok(tree_dir)
}

/// Shared tail dispatch -- both `run_plain` and `run_discover_tree`
/// funnel into this once a `Decision::Defer` is known, so the
/// per-`DyndrvMode` branching lives in exactly one place.
///
/// `DyndrvMode::Sandbox`'s own branch splits three ways, based on
/// `record.key` and whether any dependency is still a pending TEXT
/// stub (`record_has_pending_text_stub_dep`):
/// - KEYLESS + no pending text-stub dep (file-granularity, the common
///   default): registers EAGERLY (task #85) via `record_to_derivation`/
///   `add_drv_to_store`, symlinking the caller-visible output at the
///   result -- legal inside a `builder-rpc-v0` sandbox (`AddToStore*`
///   is allowlisted there, only `BuildPaths`/realization is
///   restricted, confirmed by `phases/split.nix`'s own header).
/// - KEYED (`granularity = "module"`, this record's own source path
///   satisfies the caller's `shouldBatch`) + no pending text-stub dep:
///   accumulates EAGERLY into its own batch group's growing multi-
///   output derivation (task #86, `group::accumulate_and_register`),
///   symlinking the caller-visible output at the group's CURRENT head
///   with a `#<output-name>` suffix (`stub::read_pending_symlink`'s own
///   extended format).
/// - Everything else (any dependency still a pending text stub) stays
///   on the OLD deferred-JSON-record path (`finalize_defer`).
///
/// The dependency check matters because `ar`/`ranlib` are ALWAYS
/// keyless themselves (`tonode.rs`'s own decision logic never assigns
/// either a `key`), regardless of `granularity` -- checking `record.key`
/// ALONE would wrongly route a `granularity = "module"` build's own
/// `ar` step onto the file-granularity eager path even when its `.o`
/// inputs are still KEYED, text-stub-based batched compiles (confirmed
/// by direct reproduction against example 06's compiled variant, BEFORE
/// task #86's own group-accumulation path existed: `stub::read_pending_
/// symlink` never matches a TEXT stub, so eager registration would have
/// silently rendered each `.o` arg as a bogus LITERAL relative-path
/// string instead of either a real cross-drv edge or a fallback).
/// `record_has_pending_text_stub_dep` below detects this and forces the
/// `finalize_defer` fallback -- this ALSO covers the FIRST compile in a
/// FRESH batch group correctly (it has no deps at all, so it always
/// takes the eager group-accumulation branch), and every subsequent
/// member/consumer once every earlier member in the SAME group has
/// already switched to the eager symlink representation.
fn dispatch_defer(
    client: &BuilderRpcClient,
    mode: DyndrvMode,
    output_path: &str,
    record: Record,
) -> anyhow::Result<()> {
    match mode {
        DyndrvMode::Sandbox if record_has_pending_text_stub_dep(&record) => {
            finalize_defer(output_path, record)
        }
        DyndrvMode::Sandbox if record.key.is_some() => {
            run_sandbox_group_tail(client, output_path, record)
        }
        DyndrvMode::Sandbox => run_sandbox_eager_tail(client, output_path, record),
        DyndrvMode::Rpc { autoforce } => {
            let drv_name = Path::new(output_path)
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| output_path.to_string());
            run_rpc_tail(client, output_path, record, &drv_name, autoforce)
        }
        DyndrvMode::Thunk { format, autoforce } => {
            run_thunk_tail(client, output_path, record, format, autoforce)
        }
    }
}

/// True if any of `record`'s own dependency references (`args`,
/// `seed_from`) is currently a `Sandbox`-mode TEXT stub (`stub::
/// read_batch_stub`) -- i.e. a dependency that's STILL accumulating in
/// the OLD deferred-JSON-record collector's own batch group, not yet
/// resolvable any other way. See `dispatch_defer`'s own doc comment for
/// why this, not `record.key` alone, decides eager-vs-deferred.
fn record_has_pending_text_stub_dep(record: &Record) -> bool {
    let is_text_stub = |a: &str| stub::read_batch_stub(Path::new(a)).is_some();
    record.args.iter().any(|a| is_text_stub(a))
        || record
            .seed_from
            .as_ref()
            .is_some_and(|s| is_text_stub(&s.from))
}

/// `Sandbox` mode's module-granularity eager tail (task #86): accumulates
/// this record into its own batch group's growing derivation
/// (`group::accumulate_and_register`) and symlinks the caller-visible
/// output at the group's CURRENT head, with a `#<output-name>` suffix
/// naming this specific member's own output within the (multi-output)
/// group derivation -- see `group.rs`'s own module doc for the full
/// mechanism.
fn run_sandbox_group_tail(
    client: &BuilderRpcClient,
    output_path: &str,
    record: Record,
) -> anyhow::Result<()> {
    let key = record
        .key
        .clone()
        .ok_or_else(|| anyhow::anyhow!("run_sandbox_group_tail: record has no key"))?;

    let mut deps = std::collections::HashMap::new();
    for a in record.args.iter().chain(record.seed_from.as_ref().map(|s| &s.from)) {
        if a == "$out" || a.starts_with('-') {
            continue;
        }
        if let Some(dep) = stub::read_pending_symlink(Path::new(a)) {
            deps.insert(a.clone(), dep);
        }
    }

    let cwd = std::env::current_dir().context("run_sandbox_group_tail: current_dir")?;
    let workspace = crate::group::resolve_workspace(&cwd);
    let (head, out_name) =
        crate::group::accumulate_and_register(client, &workspace, &key, output_path, &record, &deps)
            .context("run_sandbox_group_tail: accumulate_and_register")?;

    let abs_target = format!("/nix/store/{head}#{out_name}");
    let output_path = Path::new(output_path);
    if let Some(parent) = output_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let _ = std::fs::remove_file(output_path);
    std::os::unix::fs::symlink(&abs_target, output_path)?;
    Ok(())
}

/// `Sandbox` mode's eager, file-granularity tail (task #85): registers
/// the record's derivation immediately, EXACTLY like `Rpc` mode's own
/// non-autoforce path (`rpc_tail::run_rpc_tail`) -- `autoforce` is
/// never available here (`builder-rpc-v0`'s own opcode allowlist has no
/// `BuildPaths`, so a sandboxed connection can never realize inline,
/// confirmed by `phases/split.nix`'s own header comment) -- then
/// symlinks the caller-visible output at the registered `.drv`'s real
/// store path.
///
/// Confirmed by direct reproduction (task #83's own spike): a path
/// registered via `add_drv_to_store` mid-build is NOT locally
/// `stat`-able from inside the SAME sandbox that registered it -- this
/// means the symlink written here is genuinely UNRESOLVABLE by a LATER
/// invocation in the same sandboxed build via a plain filesystem check.
/// Dependency detection for a LATER invocation's own argv (e.g. `ar`
/// reading this compile's own `.o` output) therefore uses
/// `stub::read_pending_symlink` (which only needs the symlink's TARGET
/// TEXT, not the target's own existence) to discover the reference,
/// then `client.is_valid_path` (a real daemon round-trip, task #85's
/// own `is_valid_path` addition to `nix-builder-rpc-client`) to confirm
/// it before trusting it -- see `rewrite_argv_element`'s own updated
/// logic.
fn run_sandbox_eager_tail(
    client: &BuilderRpcClient,
    output_path: &str,
    record: Record,
) -> anyhow::Result<()> {
    let store_dir = harmonia_store_path::StoreDir::default();

    let mut deps = std::collections::HashMap::new();
    for a in record.args.iter().chain(record.seed_from.as_ref().map(|s| &s.from)) {
        if a == "$out" || a.starts_with('-') {
            continue;
        }
        if let Some(dep) = stub::read_pending_symlink(Path::new(a)) {
            deps.insert(a.clone(), dep);
        }
    }

    let drv_name = Path::new(output_path)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| output_path.to_string());
    let drv = crate::drv::record_to_derivation(&record, &drv_name, &deps)?;
    let drv_path = client
        .add_drv_to_store(&store_dir, &drv)
        .context("run_sandbox_eager_tail: add_drv_to_store")?;

    let abs_drv_path = format!("/nix/store/{drv_path}");
    let output_path = Path::new(output_path);
    if let Some(parent) = output_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let _ = std::fs::remove_file(output_path);
    std::os::unix::fs::symlink(&abs_drv_path, output_path)?;
    Ok(())
}

/// Any argv element that's a path to an existing REGULAR file, not
/// already under the store, and not itself a pending stub, gets
/// rewritten to its own store path -- port of `wrapCommand.nix`'s
/// rewrite loop (`nix store add-file`, here `add_to_store_flat` --
/// same CA method, no subprocess).
///
/// `StorePath`'s own `Display` impl prints just `<hash>-<name>` (the
/// base path form, matching Nix's internal convention -- see
/// `harmonia_store_path::StorePath`'s own doc), NOT the full
/// `/nix/store/<hash>-<name>` path -- confirmed by direct reproduction
/// that using it bare here produced a rendered command line referencing
/// a nonexistent RELATIVE path (`ar cr $out jqrq2...-a.o`, no
/// directory), and separately broke `extra_store_paths`' own
/// `/nix/store/` prefix-detection downstream. The full absolute path
/// must be reconstructed explicitly.
fn rewrite_argv_element(client: &BuilderRpcClient, a: &str) -> anyhow::Result<String> {
    if a.starts_with("/nix/store/") || a.starts_with('-') {
        return Ok(a.to_string());
    }
    let path = Path::new(a);
    if path.is_file() && !stub::is_pending(path) {
        let name = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| a.to_string());
        let bytes = std::fs::read(path).with_context(|| format!("read {}", path.display()))?;
        let store_path = client
            .add_to_store_flat(&name, &bytes)
            .with_context(|| format!("add_to_store_flat {}", path.display()))?;
        return Ok(format!("/nix/store/{store_path}"));
    }
    Ok(a.to_string())
}

fn exec_passthrough(real_command: &str, argv: &[String]) -> anyhow::Result<()> {
    use std::os::unix::process::CommandExt;
    let err = std::process::Command::new(real_command).args(argv).exec();
    Err(anyhow::anyhow!("exec {real_command} failed: {err}"))
}

/// Shared "finalize" tail -- port of `wrapCommand.nix`'s
/// `finalizeTail`: chain onto an EARLIER pending stub at the same
/// output path if one exists (see that file's header comment for why
/// -- `ar cr liba.a *.o` immediately followed by `ranlib liba.a` on the
/// SAME path), then write the (possibly chained) record + stub.
fn finalize_defer(output_path: &str, mut record: Record) -> anyhow::Result<()> {
    let output_path = Path::new(output_path);

    if let Some(chained_from) = stub::read_batch_stub(output_path) {
        record.chained_from = Some(chained_from.display().to_string());
    }

    let record_json = serde_json::to_vec(&record).context("finalize_defer: serialize record")?;
    let record_path = tempfile_path(&std::env::temp_dir());
    std::fs::write(&record_path, record_json)
        .with_context(|| format!("finalize_defer: write {}", record_path.display()))?;

    stub::write_batch_stub(output_path, &record_path)
        .with_context(|| format!("finalize_defer: write_batch_stub {}", output_path.display()))?;
    Ok(())
}

fn tempfile_path(dir: &Path) -> std::path::PathBuf {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    dir.join(format!("dyndrv-record-{}-{}", std::process::id(), nanos))
}
