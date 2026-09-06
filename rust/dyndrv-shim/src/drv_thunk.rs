use crate::record::Record;
use harmonia_store_content_address::{ContentAddress, ContentAddressMethodAlgorithm};
use harmonia_store_derivation::derivation::{Derivation, DerivationOutput};
use harmonia_store_derivation::derived_path::{OutputName, SingleDerivedPath};
use harmonia_store_derivation::placeholder::Placeholder;
use harmonia_store_path::{StoreDir, StorePath};
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

/// EXPERIMENTAL (task #65): writes a real, ATerm-serialized `.drv` file
/// directly to disk -- via the SAME printer (`harmonia_store_aterm::
/// print_derivation_aterm`) `Rpc` mode's `add_drv_to_store` uses
/// internally, just writing the bytes to a local path instead of over
/// a socket. No daemon call at all for the write itself.
///
/// UNVERIFIED beyond the single-node case as of this writing: a real
/// `.drv`'s own `inputDrvs` field is Nix's native on-disk dependency-
/// edge format, so in principle chaining several `.drv`-format thunks
/// together needs no separate thunk-graph helper file the way `Nix`-
/// format thunks do (`thunk_tail.rs`'s own single-thunk-only
/// limitation) -- but this function only builds a single derivation
/// from a single `Record`, with no `inputDrvs` wiring to another
/// dyndrv-produced `.drv` at all. Cross-thunk `.drv` chaining is
/// explicitly NOT implemented here; see this module's own doc for why
/// (the plan's own "genuine experiment, not a committed deliverable"
/// framing).
pub fn write_drv_thunk(workspace: &Path, record: &Record) -> anyhow::Result<(PathBuf, StorePath)> {
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
