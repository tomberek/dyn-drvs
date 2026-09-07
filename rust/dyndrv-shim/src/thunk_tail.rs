use crate::drv_thunk;
use crate::mode::ThunkFormat;
use crate::record::Record;
use crate::thunk;
use anyhow::Context;
use nix_builder_rpc_client::BuilderRpcClient;
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
/// `output_path`. `Drv` format's own autoforce path registers every
/// TRANSITIVELY-referenced `.drv` (via `add_to_store_text`, the SAME
/// CA method `add_drv_to_store` uses internally -- see
/// `realise_drv_and_promote`'s own doc for why this, not `nix-store
/// --add`, is required for a multi-node graph), then `nix-store
/// --realise`s the root. Nix's own dependency resolution then walks
/// the root's real `.drv`'s `inputDrvs` transitively on its own, so a
/// MULTI-node graph needs no separate thunk-graph helper file the way
/// `Nix`-format thunks do -- just every node registered at its own
/// REAL (not flat-CA) store identity before the root's own `--realise`.
pub fn run_thunk_tail(
    client: &BuilderRpcClient,
    output_path: &str,
    record: Record,
    format: ThunkFormat,
    autoforce: bool,
) -> anyhow::Result<()> {
    match format {
        ThunkFormat::Nix => run_nix_format(output_path, &record, autoforce),
        ThunkFormat::Drv => run_drv_format(client, output_path, &record, autoforce),
    }
}

fn run_drv_format(
    client: &BuilderRpcClient,
    output_path: &str,
    record: &Record,
    autoforce: bool,
) -> anyhow::Result<()> {
    let cwd = std::env::current_dir()?;
    let workspace = thunk::resolve_workspace(&cwd);

    // Scan this record's own `args` for positional elements that are
    // ACTUALLY symlinks into `.dyndrv/thunks-drv/` -- real cross-drv
    // dependencies left by an earlier, already-completed shim
    // invocation in the SAME `Thunk{Drv}` graph (e.g. `ar`'s own `.o`
    // args, each some earlier `cc` invocation's deferred output). Each
    // match becomes a real `SingleDerivedPath::Built` `inputDrvs` edge
    // in the derivation `write_drv_thunk` builds below, instead of a
    // plain (and, once this `.drv` is realized elsewhere, likely
    // nonexistent) relative-path string.
    let mut deps = std::collections::HashMap::new();
    for a in record.args.iter().chain(record.seed_from.as_ref().map(|s| &s.from)) {
        if a == "$out" || a.starts_with('-') {
            continue;
        }
        if let Some(dep) = drv_thunk::resolve_drv_thunk_dependency(Path::new(a)) {
            deps.insert(a.clone(), dep);
        }
    }

    let (drv_path, _store_path) = drv_thunk::write_drv_thunk(&workspace, record, &deps)?;

    let output_abs = if Path::new(output_path).is_absolute() {
        Path::new(output_path).to_path_buf()
    } else {
        cwd.join(output_path)
    };
    thunk::link_placeholder(&output_abs, &drv_path)?;

    if autoforce {
        realise_drv_and_promote(client, &output_abs, &drv_path)?;
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
/// file must be added to the store FIRST.
///
/// SECOND FINDING (task #80, confirmed by direct reproduction against
/// a real multi-node graph): `nix-store --add`'s own FLAT-CA naming
/// produces a DIFFERENT store path than a `.drv`'s own logical
/// `text:sha256` identity (`compute_drv_store_path`'s own computation,
/// matching what `add_drv_to_store` registers internally) -- fine for
/// a SINGLE, standalone `.drv` handed directly to `--realise` (nothing
/// else references that specific path, so the mismatch is harmless),
/// but NOT fine for a multi-node graph: a dependent's own `inputDrvs`
/// entry references the dependency's REAL logical identity, and
/// `--realise` fails outright ("store path '...' does not exist") if
/// that exact path was never registered, regardless of whether SOME
/// path with the same CONTENT exists under a different (flat-CA) name.
/// Confirmed by direct reproduction: `nix-store --add`ing every `.drv`
/// in a two-compile-plus-archive graph individually still left
/// `--realise` failing on the root, since none of the resulting
/// flat-CA paths matched what the root's own `inputDrvs` field
/// actually names.
///
/// The fix: register every `.drv` (root AND every transitively-
/// referenced dependency, walking `inputDrvs` recursively) via
/// `add_to_store_text` -- a REAL daemon RPC call using
/// `ContentAddressMethodAlgorithm::Text`, the SAME CA method
/// `add_drv_to_store` uses internally, so the resulting store path
/// matches `compute_drv_store_path`'s own computation exactly (unlike
/// `nix-store --add`'s CLI-only Flat CA method). This still needs no
/// `nix build`/scheduling call except the one final `--realise` on the
/// root -- `add_to_store_text` is a plain content-addressed upload, no
/// build involved, matching the "cheap, no build" cost this plan's own
/// original finding already established for the single-node case.
fn realise_drv_and_promote(
    client: &BuilderRpcClient,
    output_abs: &Path,
    drv_path: &Path,
) -> anyhow::Result<()> {
    let store_dir = harmonia_store_path::StoreDir::default();
    let added_root = register_drv_tree(client, &store_dir, drv_path)?;

    let out = std::process::Command::new("nix-store")
        .args(["--realise", "--extra-experimental-features", "ca-derivations"])
        .arg(format!("/nix/store/{added_root}"))
        .output()?;
    if !out.status.success() {
        anyhow::bail!(
            "nix-store --realise /nix/store/{added_root} failed: {}",
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

/// Recursively registers `drv_path` and every `.drv` it (transitively)
/// references via `inputDrvs`, bottom-up (dependencies before
/// dependents, so `add_to_store_text` never sees an `inputDrvs`
/// reference to a not-yet-registered path), via `add_to_store_text` --
/// see `realise_drv_and_promote`'s own doc for why this specific call,
/// not `nix-store --add`, is required. Parses each `.drv`'s own ATerm
/// bytes (`harmonia_store_aterm::parse_derivation_aterm`) to discover
/// its `inputDrvs` -- the `deps` map built by `run_drv_format`'s own
/// scan only covers ONE level (this record's immediate positional
/// args), so a graph deeper than 2 levels (e.g. an `ar` archive
/// consumed by a further link step, itself a `.drv`-thunk dependency)
/// needs this recursive walk to register every ancestor, not just the
/// immediate ones `write_drv_thunk` already wired into the root's own
/// `inputDrvs`.
fn register_drv_tree(
    client: &BuilderRpcClient,
    store_dir: &harmonia_store_path::StoreDir,
    drv_path: &Path,
) -> anyhow::Result<harmonia_store_path::StorePath> {
    let aterm_bytes = std::fs::read(drv_path)
        .with_context(|| format!("read {}", drv_path.display()))?;
    let store_path =
        drv_thunk::compute_drv_store_path(store_dir, "dyndrv-thunk", &aterm_bytes)?;

    // Parse the ATerm to discover this drv's own `inputDrvs` -- each
    // entry is an ABSOLUTE store path (possibly not yet registered,
    // since `write_drv_thunk` only ever computed it locally, never
    // called `add_drv_to_store`). Recurse into each one FIRST (bottom-
    // up), matching it against the `.drv` files sitting in the SAME
    // `.dyndrv/thunks-drv/` directory by RE-COMPUTING each candidate's
    // own store path and comparing (thunk files are named by a content
    // hash of their OWN ATerm bytes, a different value than the store
    // path's own hash, so the store hash can't be used to guess the
    // filename directly). A reference to something that ISN'T a dyndrv
    // thunk (a real, already-registered dependency, e.g. a toolchain
    // package) has no match here and is left alone -- `add_to_store_
    // text` only ever concerns thunk-produced `.drv`s, real store
    // paths need no registration.
    let name: harmonia_store_path::StorePathName =
        "dyndrv-thunk".parse().map_err(|e| anyhow::anyhow!("{e:?}"))?;
    let parsed = harmonia_store_aterm::parse_derivation_aterm(store_dir, &aterm_bytes, name)
        .map_err(|e| anyhow::anyhow!("parse_derivation_aterm {}: {e:?}", drv_path.display()))?;
    let input_drv_paths: Vec<harmonia_store_path::StorePath> = parsed
        .inputs
        .iter()
        .filter_map(|p| match p {
            harmonia_store_derivation::derived_path::SingleDerivedPath::Built {
                drv_path, ..
            } => Some(drv_path.root_path().clone()),
            harmonia_store_derivation::derived_path::SingleDerivedPath::Opaque(_) => None,
        })
        .filter(|sp| sp.is_derivation())
        .collect();
    if !input_drv_paths.is_empty() {
        let thunks_dir = drv_path.parent().unwrap_or(Path::new("."));
        for entry in std::fs::read_dir(thunks_dir)
            .with_context(|| format!("read_dir {}", thunks_dir.display()))?
        {
            let entry = entry?;
            let candidate = entry.path();
            if candidate == drv_path || candidate.extension().and_then(|e| e.to_str()) != Some("drv")
            {
                continue;
            }
            let candidate_bytes = std::fs::read(&candidate)
                .with_context(|| format!("read {}", candidate.display()))?;
            let candidate_path =
                drv_thunk::compute_drv_store_path(store_dir, "dyndrv-thunk", &candidate_bytes)?;
            if input_drv_paths.contains(&candidate_path) {
                register_drv_tree(client, store_dir, &candidate)?;
            }
        }
    }

    client
        .add_to_store_text("dyndrv-thunk.drv", &aterm_bytes)
        .with_context(|| format!("add_to_store_text {}", drv_path.display()))?;
    Ok(store_path)
}

fn run_nix_format(output_path: &str, record: &Record, autoforce: bool) -> anyhow::Result<()> {
    let cwd = std::env::current_dir()?;
    let workspace = thunk::resolve_workspace(&cwd);

    // Scan this record's own `args` for positional elements that are
    // ACTUALLY symlinks into `.dyndrv/thunks/` -- real cross-thunk
    // dependencies left by an earlier, already-completed shim
    // invocation in the SAME `Thunk{Nix}` graph (e.g. `ar`'s own `.o`
    // args, each some earlier `cc` invocation's deferred output). Each
    // match becomes a real `${import <path>}` interpolation in the
    // rendered expression (task #90), instead of a plain (and, once
    // this thunk is realized elsewhere, likely nonexistent) relative-
    // path string.
    let mut deps = std::collections::HashMap::new();
    for a in record.args.iter().chain(record.seed_from.as_ref().map(|s| &s.from)) {
        if a == "$out" || a.starts_with('-') {
            continue;
        }
        if let Some(dep) = thunk::resolve_nix_thunk_dependency(Path::new(a)) {
            deps.insert(a.clone(), dep);
        }
    }

    let expr = thunk::record_to_thunk_expr(record, &deps);
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

/// Realizes the WHOLE transitively-`import`-referenced thunk graph via
/// ONE `nix build --file` call and promotes the root's own result over
/// the caller-visible symlink -- mirrors nixgg's own whole-DAG batching
/// (`realise.Realise`). Verified directly (task #90): `nix build
/// --file` on a thunk expression that `${import <path>}`s another
/// thunk transitively builds BOTH derivations in one call, no separate
/// registration-tree walk needed the way `Thunk{Drv}` mode's own
/// `register_drv_tree` requires -- a plain Nix expression's `import`
/// is Nix's own native cross-file reference mechanism, unlike a raw
/// `.drv` file's `inputDrvs`, which has no such mechanism of its own
/// and must be registered into the store explicitly before `--realise`
/// can resolve it.
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
