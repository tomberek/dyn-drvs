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

/// Returns `(target StorePath, output name)` if `path` is a symlink into
/// `/nix/store/*.drv`, `None` otherwise -- the OTHER pending-dependency
/// representation, used by `Rpc` mode's own deferred (no-autoforce)
/// tail (`rpc_tail.rs`) and `Sandbox` mode's own eager tails (tasks
/// #85/#86) instead of a text stub. `Rpc` mode already has a real,
/// registered `StorePath` in hand at write time and never runs inside a
/// `builder-rpc-v0` sandbox; `Sandbox` mode's eager tails CAN register
/// mid-build (`AddToStore*` is allowlisted there) even though a freshly
/// registered path is NOT locally `stat`-able from inside the SAME
/// sandbox that registered it (confirmed by direct reproduction, task
/// #83's spike) -- callers detect the reference via this function's own
/// TEXT-only parse (`read_link`, never a real filesystem `stat` on the
/// target) and confirm validity via a daemon round-trip when needed
/// (`client.is_valid_path`), not via `read_pending_symlink` itself.
///
/// The target's own OUTPUT NAME travels as a `#<name>` suffix on the
/// symlink text (e.g. `/nix/store/<hash>-dyndrv-batch-vendor.drv#vendor_
/// lib_a_o`) -- needed because task #86's own module-granularity eager
/// path registers ONE combined multi-output derivation per batch group,
/// where each member's own output is named (`output_name_of`'s
/// sanitized relative path), never `"out"`. Defaults to `"out"` when no
/// `#` suffix is present, matching every symlink `Rpc` mode and task
/// #85's own solo-unit eager path already write today (both always
/// single-output derivations) -- so neither of those existing writers
/// needs to change.
pub fn read_pending_symlink(
    path: &Path,
) -> Option<(
    harmonia_store_path::StorePath,
    harmonia_store_derivation::derived_path::OutputName,
)> {
    let target = std::fs::read_link(path).ok()?;
    let s = target.to_str()?;
    let rest = s.strip_prefix("/nix/store/")?;
    let (drv_part, out_part) = match rest.split_once('#') {
        Some((d, o)) => (d, o),
        None => (rest, "out"),
    };
    if !drv_part.ends_with(".drv") {
        return None;
    }
    let store_path = harmonia_store_path::StorePath::from_base_path(drv_part).ok()?;
    let out_name: harmonia_store_derivation::derived_path::OutputName = out_part.parse().ok()?;
    Some((store_path, out_name))
}

/// True if `path` is ANY pending-dependency representation --
/// `Sandbox` mode's text stub, `Rpc`/`Sandbox`-eager mode's real
/// symlink-to-`.drv` (a STORE path), `Thunk{Drv}` mode's real
/// symlink-to-`.drv` (a WORKSPACE-relative `.dyndrv/thunks-drv/` path,
/// not yet in the store), or `Thunk{Nix}` mode's real symlink-to-`.nix`
/// (a WORKSPACE-relative `.dyndrv/thunks/` path). Callers that only
/// need the boolean fact "is this a placeholder, not real content"
/// (argv-rewrite guards that would otherwise wrongly stage placeholder
/// bytes as real file content) should use this instead of `read_batch_
/// stub(..).is_some()` alone, now that a pending dependency can be
/// represented FOUR different ways depending on mode -- confirmed
/// necessary by direct reproduction (task #78, `Thunk{Drv}` mode):
/// without that mode's own check, `rewrite_argv_element` staged a
/// `.drv`-thunk symlink's OWN ATerm bytes as if they were real object
/// content, corrupting the dependent derivation's `srcs`/script with a
/// bogus store path instead of a real `inputDrvs` edge. `Thunk{Nix}`
/// mode's own equivalent gap (this function never recognized a
/// `.dyndrv/thunks/*.nix` symlink at all, only `Thunk{Drv}`'s
/// `.dyndrv/thunks-drv/` sibling) was found and fixed the same way
/// while building task #90's own multi-thunk `import` chaining.
pub fn is_pending(path: &Path) -> bool {
    read_batch_stub(path).is_some()
        || read_pending_symlink(path).is_some()
        || crate::drv_thunk::resolve_drv_thunk_dependency(path).is_some()
        || crate::thunk::resolve_nix_thunk_dependency(path).is_some()
}
