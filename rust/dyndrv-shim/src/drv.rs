use crate::record::Record;
use harmonia_store_content_address::ContentAddressMethodAlgorithm;
use harmonia_store_derivation::derivation::{Derivation, DerivationOutput};
use harmonia_store_derivation::derived_path::OutputName;
use harmonia_store_derivation::derived_path::SingleDerivedPath;
use harmonia_store_derivation::placeholder::Placeholder;
use harmonia_store_path::StorePath;
use std::collections::HashMap;

/// Builds a real `Derivation` from a `Record` -- `Rpc` mode's own tail
/// (registers immediately, no deferral needed since the connection
/// isn't restricted), also reused by `Sandbox` mode's own eager
/// file-granularity path (task #85), which registers immediately too
/// (legal per `builder-rpc-v0`'s own `AddToStore*` allowlist -- only
/// `BuildPaths`/realization is restricted there, not registration).
///
/// UNLIKE `Sandbox` mode's OLD deferred path, neither of these tails
/// has an on-disk record CHAIN to walk here: `finalize_defer`'s
/// `chainedFrom` mechanism exists specifically because a DEFERRED `ar`
/// stub might later be overwritten by a deferred `ranlib` stub at the
/// same output path, before either is ever resolved -- `dyndrv-collect`
/// needs the chain to render both steps in order. Eager registration
/// (`Rpc` mode always; `Sandbox` mode's new eager path) never defers:
/// each invocation registers synchronously before the NEXT tool
/// invocation even runs, so a real `ranlib` following a real `ar` sees
/// an ALREADY-REAL archive on disk (or, deferred-but-eagerly-registered,
/// a resolvable symlink to one) and needs no chaining of its own -- see
/// `tonode.rs::ranlib_to_node`'s own `setup_cmd` seeding, which already
/// handles this correctly for exactly this reason.
///
/// The rendered command line's OWN shape (per-record `tool args; `,
/// literal `"$out"` sentinel left unquoted) is `render.rs::
/// render_record_line`'s -- this function is now a thin `deps`-lookup
/// wrapper around that ONE shared renderer, not an independent
/// reimplementation of it (see that function's own doc comment for why:
/// a mismatched trailing `"; "` between this call site and
/// `render_member`'s own chain-concatenation convention, caught by
/// `cross_mode_check.rs`, once produced two DIFFERENT ATerm byte
/// strings for the logically-identical single-record case).
///
/// `args`: the record's own `args`, with the literal `"$out"` sentinel
/// already resolved by the CALLER to the real output name token
/// (always `"$out"` here, since a solo derivation has exactly one
/// output).
/// `deps`: `{ <record.args element> -> (dependency's own StorePath,
/// dependency's own output name) }`, built by the CALLER by detecting
/// which of THIS record's `args` are symlinks into `/nix/store/*.drv`
/// (`stub::read_pending_symlink`) -- an EARLIER, already-registered
/// (but not yet realized) invocation's own drv, e.g. `ar`'s own `.o`
/// positional args when they're still deferred symlinks rather than
/// real, promoted files. Mirrors `drv_thunk.rs::write_drv_thunk`'s own
/// identical `deps` parameter exactly (same shape, same substitution
/// idea, just wiring a REGISTERED store path instead of an on-disk
/// `.drv` file's locally-computed one) -- confirmed necessary by direct
/// reproduction: without this, a deferred (non-autoforce) `Rpc`-mode
/// `ar` step never declared its own `.o` inputs' owning derivations as
/// real `inputDrvs` at all, leaving them as literal (and, once resolved
/// elsewhere, meaningless) relative-path text in the script.
pub fn record_to_derivation(
    record: &Record,
    drv_name: &str,
    deps: &HashMap<String, (StorePath, OutputName)>,
) -> anyhow::Result<Derivation> {
    let mut drv = Derivation::new(
        drv_name.parse().map_err(|e| anyhow::anyhow!("{e:?}"))?,
        bytes::Bytes::from_static(b"x86_64-linux"),
        bytes::Bytes::from_static(b"/bin/sh"),
    );

    let resolve_ref = |a: &str| -> Option<String> {
        let (dep_drv_path, dep_out_name) = deps.get(a)?;
        Some(
            Placeholder::ca_output(dep_drv_path, dep_out_name)
                .render()
                .to_string_lossy()
                .into_owned(),
        )
    };
    let (setup, cmd) = crate::render::render_record_line(record, "$out", true, resolve_ref);
    let mut script = setup;
    script.push_str(&cmd);

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

    Ok(drv)
}
