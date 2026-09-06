use crate::drv::record_to_derivation;
use crate::record::Record;
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
    let drv = record_to_derivation(&record, drv_name)?;
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
        let real_abs = format!("/nix/store/{}", real_path.to_base_path());
        std::fs::copy(&real_abs, output_path)?;
        let now = std::time::SystemTime::now();
        let file = std::fs::File::open(output_path)?;
        file.set_modified(now)?;
    } else {
        // Deferred (no autoforce): leave a batch-pending stub at the
        // caller-visible path, same on-disk format `Sandbox` mode uses,
        // so a later `nixgg force`-equivalent (task #64's thunk-file
        // machinery, or a direct `nix build` on the registered drv) can
        // still resolve it. The record itself is no longer needed on
        // disk (the derivation is ALREADY registered, unlike `Sandbox`
        // mode) -- store the real, already-known drv path directly
        // instead of a record file path.
        crate::stub::write_batch_stub(Path::new(output_path), Path::new(&drv_path.to_base_path()))?;
    }

    Ok(())
}
