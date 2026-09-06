use std::path::{Path, PathBuf};

pub const STUB_HEADER: &str = "#!dyndrv-batch-pending";

/// Returns the record path if `path` is a batch-pending stub, `None`
/// otherwise -- port of `batchStub.nix`'s `readStubFn`. Never errors on a
/// missing/non-stub/binary file (a real `.o`/`.a` must never be
/// misclassified as pending), matching that file's own `|| true` guard.
pub fn read_batch_stub(path: &Path) -> Option<PathBuf> {
    let content = std::fs::read(path).ok()?;
    let mut lines = content.splitn(2, |&b| b == b'\n');
    let first = lines.next()?;
    if first != STUB_HEADER.as_bytes() {
        return None;
    }
    let rest = lines.next()?;
    let second = rest.split(|&b| b == b'\n').next()?;
    if second.is_empty() {
        return None;
    }
    Some(PathBuf::from(String::from_utf8_lossy(second).into_owned()))
}

/// Writes a stub at `output_path` pointing at `record_path` -- port of
/// `batchStub.nix`'s `writeStubFn`.
pub fn write_batch_stub(output_path: &Path, record_path: &Path) -> std::io::Result<()> {
    if let Some(parent) = output_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(
        output_path,
        format!("{}\n{}\n", STUB_HEADER, record_path.display()),
    )
}

/// Returns the target `StorePath` if `path` is a symlink into
/// `/nix/store/*.drv`, `None` otherwise -- the OTHER pending-dependency
/// representation, used by `Rpc` mode's own deferred (no-autoforce)
/// tail (`rpc_tail.rs`) instead of a text stub, since `Rpc` mode
/// already has a real, registered `StorePath` in hand at write time
/// and never runs inside a `builder-rpc-v0` sandbox (confirmed by
/// direct reproduction, task #83's spike: a store path registered
/// mid-build is NOT locally `stat`-able from inside the SAME sandbox
/// that registered it, so this representation only works where the
/// registering process ISN'T sandboxed -- `Sandbox` mode keeps the
/// text-stub format for exactly this reason). Never errors on a
/// missing/non-symlink/real file, matching `read_batch_stub`'s own
/// `|| true`-equivalent guard.
pub fn read_pending_symlink(path: &Path) -> Option<harmonia_store_path::StorePath> {
    let target = std::fs::read_link(path).ok()?;
    let rest = target.to_str()?.strip_prefix("/nix/store/")?;
    if !rest.ends_with(".drv") {
        return None;
    }
    harmonia_store_path::StorePath::from_base_path(rest).ok()
}

/// True if `path` is EITHER pending-dependency representation --
/// `Sandbox` mode's text stub or `Rpc` mode's real symlink-to-`.drv`.
/// Callers that only need the boolean fact "is this a placeholder, not
/// real content" (argv-rewrite guards that would otherwise wrongly
/// stage placeholder bytes as real file content) should use this
/// instead of `read_batch_stub(..).is_some()` alone, now that a pending
/// dependency can be represented either way depending on mode.
pub fn is_pending(path: &Path) -> bool {
    read_batch_stub(path).is_some() || read_pending_symlink(path).is_some()
}
