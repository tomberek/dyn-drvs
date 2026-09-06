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
