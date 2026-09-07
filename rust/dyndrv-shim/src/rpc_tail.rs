use crate::drv::record_to_derivation;
use crate::record::Record;
use crate::stub;
use harmonia_store_derivation::derived_path::SingleDerivedPath;
use harmonia_store_path::StoreDir;
use nix_builder_rpc_client::BuilderRpcClient;
use std::path::Path;

/// `Rpc` mode tail: register the record's derivation immediately (no
/// deferral -- the connection isn't restricted the way a
/// `builder-rpc-v0` sandbox's is), and if `autoforce`, realize it via
/// `build_paths` and copy the real bytes back over the caller-visible
/// output path.
///
/// `drv_name`: a name unique enough not to collide across invocations
/// in the same devShell session -- callers derive this from the output
/// path's own basename (see `wrapper::run_plain`'s dispatch).
pub fn run_rpc_tail(
    client: &BuilderRpcClient,
    output_path: &str,
    record: Record,
    drv_name: &str,
    autoforce: bool,
) -> anyhow::Result<()> {
    let store_dir = StoreDir::default();

    // Scan this record's own `args` for positional elements that are
    // ACTUALLY symlinks into `/nix/store/*.drv` -- an EARLIER,
    // already-registered (but not yet realized) invocation's own drv,
    // e.g. `ar`'s own `.o` args when they're still deferred symlinks
    // rather than real, promoted files (the norm without `autoforce`).
    // Each match becomes a real `SingleDerivedPath::Built` `inputDrvs`
    // edge in the derivation `record_to_derivation` builds below --
    // confirmed necessary by direct reproduction: without this, a
    // deferred `ar` step never declared its own `.o` inputs' owning
    // derivations as real dependencies at all.
    let mut deps = std::collections::HashMap::new();
    for a in record.args.iter().chain(record.seed_from.as_ref().map(|s| &s.from)) {
        if a == "$out" || a.starts_with('-') {
            continue;
        }
        if let Some(sp) = stub::read_pending_symlink(Path::new(a)) {
            let out_name: harmonia_store_derivation::derived_path::OutputName =
                "out".parse().map_err(|e| anyhow::anyhow!("{e:?}"))?;
            deps.insert(a.clone(), (sp, out_name));
        }
    }

    let drv = record_to_derivation(&record, drv_name, &deps)?;
    let drv_path = client.add_drv_to_store(&store_dir, &drv)?;

    if autoforce {
        let single = SingleDerivedPath::Built {
            drv_path: std::sync::Arc::new(SingleDerivedPath::Opaque(drv_path)),
            output: "out".parse().map_err(|e| anyhow::anyhow!("{e:?}"))?,
        };
        let results = client.build_paths(&store_dir, std::slice::from_ref(&single))?;
        let real_path = results
            .into_iter()
            .next()
            .ok_or_else(|| anyhow::anyhow!("build_paths returned no result"))?;

        // Store-path mtimes are pinned to 1969 -- a bare symlink would
        // make `make`'s own staleness check treat the output as older
        // than its source forever (nixgg's own documented reason for
        // byte-copying instead of symlinking in native mode, see
        // ARCHITECTURE.md's "Why bytes not symlinks"). Copy bytes and
        // stamp the mtime to now instead.
        //
        // `fs::copy` sets the DESTINATION's permissions to match the
        // SOURCE's, regardless of whether the destination already
        // existed -- confirmed by direct reproduction: copying from a
        // read-only Nix store path left `output_path` at mode 444, so a
        // LATER standalone `ranlib` invocation modifying THIS SAME
        // output path in place (via its own `cp`-then-modify `setup_cmd`,
        // see `tonode.rs::ranlib_to_node`) failed with "Permission
        // denied" trying to write back over it. `chmod u+w` explicitly
        // afterward, matching this codebase's own established
        // `cp && chmod u+w` idiom elsewhere (`cc`'s own `setup_cmd`,
        // `ranlib_to_node`'s new one).
        let real_abs = format!("/nix/store/{}", real_path.to_base_path());
        std::fs::copy(&real_abs, output_path)?;
        {
            let mut perms = std::fs::metadata(output_path)?.permissions();
            #[allow(clippy::permissions_set_readonly_false)]
            perms.set_readonly(false);
            std::fs::set_permissions(output_path, perms)?;
        }
        let now = std::time::SystemTime::now();
        let file = std::fs::File::open(output_path)?;
        file.set_modified(now)?;
    } else {
        // Deferred (no autoforce): symlink the caller-visible path
        // straight at the registered `.drv`'s own store path, instead
        // of `Sandbox` mode's text-based stub -- `Rpc` mode already has
        // a real, registered `StorePath` in hand here, and (unlike
        // `Sandbox` mode) never runs inside a `builder-rpc-v0` sandbox,
        // so this path IS locally resolvable by a later invocation in
        // the same devShell session (confirmed safe: task #83's own
        // spike found the OPPOSITE only holds INSIDE a sandbox, which
        // `Rpc` mode structurally never is -- see `mode.rs`'s own
        // `in_sandbox()` check). A later `nixgg force`-equivalent (a
        // direct `nix build` on the drv, or another shim invocation
        // resolving this symlink via `stub::read_pending_symlink`) can
        // still find the real derivation this way, with no on-disk
        // record file needed at all -- the derivation is ALREADY
        // registered, unlike `Sandbox` mode's own deferred JSON record.
        let abs_drv_path = format!("/nix/store/{drv_path}");
        if let Some(parent) = Path::new(output_path).parent() {
            std::fs::create_dir_all(parent)?;
        }
        let _ = std::fs::remove_file(output_path);
        std::os::unix::fs::symlink(&abs_drv_path, output_path)?;
    }

    Ok(())
}
