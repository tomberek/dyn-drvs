use crate::record::Record;
use harmonia_store_content_address::ContentAddressMethodAlgorithm;
use harmonia_store_derivation::derivation::{Derivation, DerivationOutput};
use harmonia_store_derivation::derived_path::OutputName;
use harmonia_store_derivation::derived_path::SingleDerivedPath;
use harmonia_store_derivation::placeholder::Placeholder;
use harmonia_store_path::StorePath;

/// Builds a real `Derivation` from a `Record` -- `Rpc` mode's own tail
/// (registers immediately, no deferral needed since the connection
/// isn't restricted).
///
/// UNLIKE `Sandbox` mode, `Rpc` mode has no on-disk chain to walk here:
/// `finalize_defer`'s `chainedFrom` mechanism exists specifically
/// because a DEFERRED `ar` stub might later be overwritten by a
/// deferred `ranlib` stub at the same output path, before either is
/// ever resolved -- `dyndrv-collect` needs the chain to render both
/// steps in order. `Rpc` mode never defers: each invocation registers
/// (and, with `autoforce`, realizes) synchronously before the NEXT
/// tool invocation even runs, so a real `ranlib` following a real `ar`
/// sees an ALREADY-REAL archive on disk and needs no chaining of its
/// own -- it's just an ordinary new derivation depending on the
/// previous one's real output.
///
/// The rendered command line's OWN shape (per-record `tool args; `,
/// literal `"$out"` sentinel left unquoted) mirrors `render.rs`'s
/// `render_member` exactly -- confirmed necessary by direct
/// reproduction (`cross_mode_check.rs`): a mismatched trailing `"; "`
/// between this function and `render_member`'s own chain-concatenation
/// convention produced two DIFFERENT ATerm byte strings for the
/// logically-identical single-record case, which would have silently
/// broken cross-mode store-path agreement for any real, multi-step
/// chain (only a solo, unchained record happens to still match without
/// this).
///
/// `args`: the record's own `args`, with the literal `"$out"` sentinel
/// already resolved by the CALLER to the real output name token
/// (always `"$out"` here, since a solo `Rpc`-mode derivation has
/// exactly one output).
pub fn record_to_derivation(record: &Record, drv_name: &str) -> anyhow::Result<Derivation> {
    let mut drv = Derivation::new(
        drv_name.parse().map_err(|e| anyhow::anyhow!("{e:?}"))?,
        bytes::Bytes::from_static(b"x86_64-linux"),
        bytes::Bytes::from_static(b"/bin/sh"),
    );

    let mut script = String::new();
    if let Some(setup) = &record.setup_cmd {
        script.push_str(setup);
    }
    script.push_str(&record.tool);
    for a in &record.args {
        script.push(' ');
        // The literal sentinel "$out" must stay UNQUOTED so the
        // builder's own shell expands it -- confirmed by direct
        // reproduction: quoting it (`'$out'`) makes `/bin/sh -c`
        // pass the literal three-character string through unexpanded,
        // so the builder wrote to a file actually named `$out` instead
        // of the real output path, and Nix reported "failed to
        // produce output path" with no further explanation. Mirrors
        // `render.rs`'s own `render_member`, which already special-
        // cases this same sentinel the same way.
        if a == "$out" {
            script.push_str(a);
        } else {
            script.push_str(&crate::render::shell_quote(a));
        }
    }
    // `render_member`'s own per-chain-step convention ALWAYS appends
    // "; " after each record (see that function's own loop) -- matched
    // here so a solo record renders byte-identically either way.
    script.push_str("; ");

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

    Ok(drv)
}
