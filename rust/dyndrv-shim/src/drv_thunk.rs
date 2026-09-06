use crate::record::Record;
use harmonia_store_content_address::{ContentAddress, ContentAddressMethodAlgorithm};
use harmonia_store_derivation::derivation::{Derivation, DerivationOutput};
use harmonia_store_derivation::derived_path::{OutputName, SingleDerivedPath};
use harmonia_store_derivation::placeholder::Placeholder;
use harmonia_store_path::{StoreDir, StorePath};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// Computes a `.drv`'s own content-addressed `StorePath` LOCALLY, with
/// no daemon round-trip -- the missing piece `Thunk{Drv}` mode's write
/// path needs to let a DEPENDENT invocation (a later `ar`/`cc` step)
/// reference an earlier thunk's real store identity via `SingleDerivedPath::
/// Built`, since nothing here ever calls `add_drv_to_store` (that's the
/// whole point of this mode -- no daemon call for the write itself).
///
/// Mirrors what `nix-builder-rpc-client::add_drv_to_store`'s SERVER
/// side computes internally: a `.drv`'s own CA method is `text:sha256`
/// over its ATerm bytes (confirmed by reading `add_drv_to_store`'s own
/// call, which passes `ContentAddressMethodAlgorithm::Text`), and the
/// `.drv` FILE's own name (for CA-fingerprint purposes, not the
/// deriving package's name) is `"{drv.name}.drv"` -- also confirmed
/// directly from that same call site (`let name = format!("{}.drv",
/// drv.name);`). `harmonia_store_content_address::make_store_path_from_ca`
/// does the actual "fixed:out:r:<hash>:"-style fingerprint + SHA-256
/// Nix uses internally to turn a `ContentAddress` into a real
/// `StorePath` -- this function only supplies the two inputs specific
/// to a `.drv`'s own CA scheme.
pub fn compute_drv_store_path(
    store_dir: &StoreDir,
    drv_name: &str,
    aterm_bytes: &[u8],
) -> anyhow::Result<StorePath> {
    let name: harmonia_store_path::StorePathName = format!("{drv_name}.drv")
        .parse()
        .map_err(|e| anyhow::anyhow!("{e:?}"))?;
    let ca = ContentAddress::Text(harmonia_utils_hash::Sha256::digest(aterm_bytes));
    Ok(harmonia_store_content_address::make_store_path_from_ca(
        store_dir, name, ca,
    ))
}

/// Detects whether `path` is a symlink into `.dyndrv/thunks-drv/` (a
/// `Thunk{Drv}`-produced dependency, written by an EARLIER, already-
/// completed shim invocation -- e.g. `ar`'s own `.o` positional args,
/// each some earlier `cc` invocation's deferred output) and, if so,
/// resolves that target `.drv` file's own `StorePath` -- by re-reading
/// and re-hashing its ATerm bytes via `compute_drv_store_path`, the
/// simplest option and cheap enough given `.drv` files are small (no
/// extra sidecar cache needed unless this proves too slow in practice).
/// Returns `None` for a real file, a `Thunk{Nix}` thunk symlink
/// (`.dyndrv/thunks/`, a different directory), or anything else that
/// isn't this specific representation -- callers fall back to treating
/// the argv element as plain text in that case.
pub fn resolve_drv_thunk_dependency(path: &Path) -> Option<(StorePath, OutputName)> {
    let target = std::fs::read_link(path).ok()?;
    // Confirmed by direct reproduction: `.dyndrv/thunks-drv/` may be an
    // ABSOLUTE or a RELATIVE symlink target depending on how it was
    // written -- checking the target's own PARENT directory NAME
    // (`thunks-drv`) rather than requiring a specific absolute prefix
    // works either way.
    if target.parent().and_then(|p| p.file_name()) != Some(std::ffi::OsStr::new("thunks-drv")) {
        return None;
    }
    let aterm_bytes = std::fs::read(&target).ok()?;
    let store_dir = StoreDir::default();
    let store_path = compute_drv_store_path(&store_dir, "dyndrv-thunk", &aterm_bytes).ok()?;
    let out_name: OutputName = "out".parse().ok()?;
    Some((store_path, out_name))
}

/// EXPERIMENTAL (task #65): writes a real, ATerm-serialized `.drv` file
/// directly to disk -- via the SAME printer (`harmonia_store_aterm::
/// print_derivation_aterm`) `Rpc` mode's `add_drv_to_store` uses
/// internally, just writing the bytes to a local path instead of over
/// a socket. No daemon call at all for the write itself.
///
/// `deps`: `{ <record.args element> -> (dependency's own StorePath,
/// dependency's own output name) }`, built by the CALLER (`thunk_tail
/// .rs::run_drv_format`'s own dependency scan, task #78) by detecting
/// which of THIS record's `args` are symlinks into
/// `.dyndrv/thunks-drv/` -- i.e. real cross-drv `inputDrvs` edges, not
/// plain content. For each such element, this function wires a
/// `SingleDerivedPath::Built { drv_path, output }` into `drv.inputs`
/// (matching `dyndrv-collect.rs`'s own identical pattern for cross-unit
/// deps) and substitutes the SCRIPT's own reference to that arg with
/// the dependency's real placeholder token (`Placeholder::ca_output`,
/// same substitution idea `render.rs`/`dyndrv-collect.rs` already use)
/// instead of the literal relative path text -- the relative path
/// wouldn't exist as a real file when this `.drv` is later realized in
/// a completely different working directory.
///
/// A real `.drv`'s own `inputDrvs` field is Nix's native on-disk
/// dependency-edge format, so chaining several `.drv`-format thunks
/// together needs no separate thunk-graph helper file the way `Nix`-
/// format thunks do (`thunk_tail.rs`'s own single-thunk-only
/// limitation, before task #78/#79) -- `nix-store --realise`'s own
/// transitive `inputDrvs` walk on the ROOT `.drv` should resolve the
/// whole graph on its own (task #80 verifies whether this holds when a
/// referenced `.drv` was never itself `--add`ed to the store).
pub fn write_drv_thunk(
    workspace: &Path,
    record: &Record,
    deps: &HashMap<String, (StorePath, OutputName)>,
) -> anyhow::Result<(PathBuf, StorePath)> {
    let store_dir = StoreDir::default();

    let mut script = String::new();
    if let Some(setup) = &record.setup_cmd {
        script.push_str(setup);
    }
    script.push_str(&record.tool);
    for a in &record.args {
        script.push(' ');
        if a == "$out" {
            script.push_str(a);
        } else if let Some((dep_drv_path, dep_out_name)) = deps.get(a) {
            let ph = Placeholder::ca_output(dep_drv_path, dep_out_name).render();
            script.push_str(&crate::render::shell_quote(&ph.to_string_lossy()));
        } else {
            script.push_str(&crate::render::shell_quote(a));
        }
    }
    script.push_str("; ");

    let mut drv = Derivation::new(
        "dyndrv-thunk".parse().map_err(|e| anyhow::anyhow!("{e:?}"))?,
        bytes::Bytes::from_static(b"x86_64-linux"),
        bytes::Bytes::from_static(b"/bin/sh"),
    );
    drv.args = vec![
        bytes::Bytes::from_static(b"-c"),
        bytes::Bytes::copy_from_slice(script.as_bytes()),
    ];

    let out_name: OutputName = "out".parse().map_err(|e| anyhow::anyhow!("{e:?}"))?;
    let ph = Placeholder::standard_output(&out_name).render();
    drv.env.insert(
        bytes::Bytes::from_static(b"out"),
        bytes::Bytes::copy_from_slice(ph.as_os_str().as_encoded_bytes()),
    );
    drv.outputs.insert(
        out_name,
        DerivationOutput::CAFloating(ContentAddressMethodAlgorithm::NixArchive(
            harmonia_utils_hash::Algorithm::SHA256,
        )),
    );
    for src_basename in &record.srcs {
        if let Ok(sp) = StorePath::from_base_path(src_basename) {
            drv.inputs.insert(SingleDerivedPath::Opaque(sp));
        }
    }
    // Real cross-drv edges -- see this function's own `deps` doc above.
    for (dep_drv_path, dep_out_name) in deps.values() {
        drv.inputs.insert(SingleDerivedPath::Built {
            drv_path: std::sync::Arc::new(SingleDerivedPath::Opaque(dep_drv_path.clone())),
            output: dep_out_name.clone(),
        });
    }

    let aterm_bytes = harmonia_store_aterm::print_derivation_aterm(&store_dir, &drv);
    let store_path = compute_drv_store_path(&store_dir, "dyndrv-thunk", &aterm_bytes)?;

    // Content-addressed filename, matching `thunk.rs`'s own convention
    // (sha256 of the CONTENT, here the ATerm bytes themselves rather
    // than a `.nix` expression string) -- idempotent, same bytes never
    // rewritten.
    let digest = sha256_hex(&aterm_bytes);
    let id = &digest[..32];

    let thunks_dir = workspace.join(".dyndrv/thunks-drv");
    std::fs::create_dir_all(&thunks_dir)?;
    let dst = thunks_dir.join(format!("{id}.drv"));
    if !dst.exists() {
        let tmp = thunks_dir.join(format!("{id}.tmp.{}", std::process::id()));
        std::fs::write(&tmp, &aterm_bytes)?;
        std::fs::rename(&tmp, &dst)?;
    }
    Ok((dst, store_path))
}

fn sha256_hex(bytes: &[u8]) -> String {
    let hash = harmonia_utils_hash::Sha256::digest(bytes);
    let mut s = String::with_capacity(64);
    for b in hash.digest_bytes() {
        s.push_str(&format!("{:02x}", b));
    }
    s
}
