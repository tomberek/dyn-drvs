use crate::mode::ThunkFormat;
use crate::record::Record;
use crate::thunk;
use std::path::Path;

/// `Thunk` mode tail: write a `.nix` (or, experimentally, `.drv`)
/// expression file to disk and symlink the caller-visible output at it
/// -- no daemon call at all for the write itself, matching nixgg's own
/// default native mode exactly.
///
/// `autoforce`: only meaningful for the format that supports batched
/// realization -- for `Nix` format, runs ONE `nix build --refresh
/// --no-link --print-out-paths --file <helper>` over the whole
/// transitively-referenced thunk graph (mirrors nixgg's own
/// `realise.Realise`), then copies the real bytes back over
/// `output_path`. `Drv` format's own autoforce path is task #65's
/// scope (EXPERIMENTAL, not implemented here).
pub fn run_thunk_tail(
    output_path: &str,
    record: Record,
    format: ThunkFormat,
    autoforce: bool,
) -> anyhow::Result<()> {
    match format {
        ThunkFormat::Nix => run_nix_format(output_path, &record, autoforce),
        ThunkFormat::Drv => anyhow::bail!(
            "dyndrv-shim: Thunk{{format: Drv}} is experimental and not yet implemented (task #65) -- \
             use DYNDRV_THUNK_FORMAT=nix (the default) instead"
        ),
    }
}

fn run_nix_format(output_path: &str, record: &Record, autoforce: bool) -> anyhow::Result<()> {
    let cwd = std::env::current_dir()?;
    let workspace = thunk::resolve_workspace(&cwd);

    let expr = thunk::record_to_thunk_expr(record);
    let id = thunk::compute_id(&expr);
    let thunk_path = thunk::write_thunk(&workspace, &id, &expr)?;

    let output_abs = if Path::new(output_path).is_absolute() {
        Path::new(output_path).to_path_buf()
    } else {
        cwd.join(output_path)
    };
    thunk::link_placeholder(&output_abs, &thunk_path)?;

    if autoforce {
        realise_and_promote(&output_abs, &thunk_path)?;
    }

    Ok(())
}

/// Realizes ONE thunk via a plain `nix build --file` and promotes the
/// result over the caller-visible symlink -- a single-thunk special
/// case of nixgg's own whole-DAG batching (`realise.Realise`
/// transitively resolves every `import`-referenced sibling thunk via
/// ONE combined `nix build` call). Batching across the transitive
/// thunk graph is follow-on work; this already gives autoforce a real,
/// working single-step path (`nix build --file` on a thunk that
/// imports NOTHING beyond already-realized inputs, which covers every
/// solo `ar`/`ranlib` invocation this binary's own decision logic
/// produces today -- no cross-thunk `import` chaining exists yet in
/// `record_to_thunk_expr`).
fn realise_and_promote(output_abs: &Path, thunk_path: &Path) -> anyhow::Result<()> {
    let out = std::process::Command::new("nix")
        .args([
            "build",
            "--refresh",
            "--no-link",
            "--print-out-paths",
            "--extra-experimental-features",
            "nix-command",
            "--file",
        ])
        .arg(thunk_path)
        .output()?;
    if !out.status.success() {
        anyhow::bail!(
            "nix build --file {} failed: {}",
            thunk_path.display(),
            String::from_utf8_lossy(&out.stderr)
        );
    }
    let real_path = String::from_utf8_lossy(&out.stdout).trim().to_string();

    // `output_abs` is currently a SYMLINK pointing at `thunk_path` --
    // confirmed by direct reproduction that a naive `fs::copy` here
    // follows the symlink and overwrites the THUNK FILE ITSELF with
    // binary archive content (corrupting it for any future re-read of
    // this thunk ID). Remove the symlink first, then write real bytes
    // at that path -- mirrors nixgg's own `thunk.LinkPlaceholder`,
    // which always `os.Remove`s before `os.Symlink`ing for the same
    // "don't silently clobber through a stale link" reason.
    std::fs::remove_file(output_abs)?;

    // Store-path mtimes are pinned to 1969 (same reason `rpc_tail.rs`
    // byte-copies instead of symlinking for its own autoforce path) --
    // `make` would otherwise treat this output as permanently stale.
    std::fs::copy(&real_path, output_abs)?;
    let now = std::time::SystemTime::now();
    let file = std::fs::File::open(output_abs)?;
    file.set_modified(now)?;
    Ok(())
}
