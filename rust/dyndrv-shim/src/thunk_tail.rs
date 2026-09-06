use crate::drv_thunk;
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
/// `output_path`. `Drv` format's own autoforce path realizes via
/// `nix-store --add` (register the file, no build) then `nix-store
/// --realise` -- CONFIRMED necessary by direct reproduction: neither
/// `nix-store --realise` nor `nix build <path>^out` accept a `.drv` at
/// an arbitrary FILESYSTEM path directly ("is not in the Nix
/// store"/"is not a flake") -- only an already-registered store path
/// works, so the originally-hoped-for "no daemon call at all, not even
/// for realization" property does NOT hold for this format's
/// autoforce path (the write itself is still daemon-free; only
/// REALIZING it needs one `--add`). Nix's own dependency resolution
/// still walks a real `.drv`'s `inputDrvs` transitively once
/// registered, so a MULTI-node graph (not built by this experimental
/// format yet -- see `drv_thunk.rs`'s own single-node-only caveat)
/// would still need no separate thunk-graph helper file the way
/// `Nix`-format thunks do -- just each node individually `--add`ed
/// before the root's own `--realise`.
pub fn run_thunk_tail(
    output_path: &str,
    record: Record,
    format: ThunkFormat,
    autoforce: bool,
) -> anyhow::Result<()> {
    match format {
        ThunkFormat::Nix => run_nix_format(output_path, &record, autoforce),
        ThunkFormat::Drv => run_drv_format(output_path, &record, autoforce),
    }
}

fn run_drv_format(output_path: &str, record: &Record, autoforce: bool) -> anyhow::Result<()> {
    let cwd = std::env::current_dir()?;
    let workspace = thunk::resolve_workspace(&cwd);

    let drv_path = drv_thunk::write_drv_thunk(&workspace, record)?;

    let output_abs = if Path::new(output_path).is_absolute() {
        Path::new(output_path).to_path_buf()
    } else {
        cwd.join(output_path)
    };
    thunk::link_placeholder(&output_abs, &drv_path)?;

    if autoforce {
        realise_drv_and_promote(&output_abs, &drv_path)?;
    }

    Ok(())
}

/// Realizes a real `.drv` file via `nix-store --realise`.
///
/// EXPERIMENTAL FINDING (task #65, confirmed by direct reproduction):
/// `nix-store --realise`/`nix build <path>^out` both REFUSE a `.drv`
/// at an arbitrary filesystem path outright ("is not in the Nix
/// store"/"is not a flake") -- Nix's builder/scheduler machinery only
/// ever operates on an ALREADY-REGISTERED store path, never a raw
/// on-disk file, no matter how well-formed its ATerm content is. The
/// file must be added to the store FIRST (`nix-store --add`, itself
/// just a local content-addressed file copy -- no scheduling, no
/// build, negligible overhead) before `--realise` will accept it.
/// Confirmed the resulting (flat-CA, name-mismatched-from-the-
/// derivation's-own-declared-name) added path still realizes
/// CORRECTLY despite the naming mismatch -- Nix parses the ATerm's own
/// declared `name` field to compute the real output path, not the
/// `.drv` file's own on-disk basename.
fn realise_drv_and_promote(output_abs: &Path, drv_path: &Path) -> anyhow::Result<()> {
    let add_out = std::process::Command::new("nix-store")
        .arg("--add")
        .arg(drv_path)
        .output()?;
    if !add_out.status.success() {
        anyhow::bail!(
            "nix-store --add {} failed: {}",
            drv_path.display(),
            String::from_utf8_lossy(&add_out.stderr)
        );
    }
    let added_drv_path = String::from_utf8_lossy(&add_out.stdout).trim().to_string();

    let out = std::process::Command::new("nix-store")
        .args(["--realise", "--extra-experimental-features", "ca-derivations"])
        .arg(&added_drv_path)
        .output()?;
    if !out.status.success() {
        anyhow::bail!(
            "nix-store --realise {added_drv_path} failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
    let real_path = String::from_utf8_lossy(&out.stdout).trim().to_string();

    // Same symlink-clobber hazard `realise_and_promote` (Nix format)
    // already documents -- remove the symlink before copying real
    // bytes over that path.
    std::fs::remove_file(output_abs)?;
    std::fs::copy(&real_path, output_abs)?;
    let now = std::time::SystemTime::now();
    let file = std::fs::File::open(output_abs)?;
    file.set_modified(now)?;
    Ok(())
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
