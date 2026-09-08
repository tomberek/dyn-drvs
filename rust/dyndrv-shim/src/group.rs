use crate::record::Record;
use anyhow::Context;
use harmonia_store_content_address::ContentAddressMethodAlgorithm;
use harmonia_store_derivation::derivation::{Derivation, DerivationOutput};
use harmonia_store_derivation::derived_path::{OutputName, SingleDerivedPath};
use harmonia_store_derivation::placeholder::Placeholder;
use harmonia_store_path::{StoreDir, StorePath, StorePathName};
use nix_builder_rpc_client::BuilderRpcClient;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// `Sandbox` mode's module-granularity eager path (task #86): each
/// batch group (`record.key`, an eval-time-computed directory-based
/// key -- see `mkAcceleratedStdenv.nix`'s own `shouldBatch`/
/// `DYNDRV_BATCH_GROUPS` header comment) accumulates its members into
/// ONE growing, multi-output derivation, registered incrementally after
/// EVERY member compile -- instead of `Sandbox` mode's OLD deferred-
/// JSON-record path, which only discovers/merges the whole group at the
/// very end of `buildPhase` (`dyndrv-collect`'s own Phase 4 unit-merge
/// rule).
///
/// Mechanism: a small on-disk LOCAL copy of the group's CURRENT head
/// derivation's own ATerm bytes, at `.dyndrv/groups/<sanitized-key>/
/// head.drv` -- confirmed necessary by direct reproduction (task #83's
/// own spike, re-confirmed here for the group case specifically): a
/// store path registered via `add_drv_to_store` moments earlier by an
/// EARLIER member's own invocation is NOT locally `stat`/`read`-able
/// from inside the SAME sandbox, so re-parsing the head to accumulate
/// onto it needs a LOCAL file this process itself controls (mirrors
/// `drv_thunk.rs::write_drv_thunk`'s own identical "write the bytes
/// locally too" idiom) rather than reading back through `/nix/store/
/// <head>` directly.
/// The FIRST member in a group registers a solo-output derivation for
/// itself and writes `head.drv`. Each SUBSEQUENT member reads THAT
/// local file (never the store path) to recover every output
/// registered so far (script + `srcs` + `outputs`), builds a NEW
/// derivation unioning the head's own outputs with this member's own
/// (same "combine multiple tool invocations" idea `render.rs::
/// render_unit` already implements for the OLD collector, just invoked
/// incrementally instead of once at the end), registers it, and
/// overwrites `head.drv` to match the new head.
///
/// Every member's own caller-visible output path is symlinked at the
/// group's CURRENT head with a `#<output-name>` suffix (`stub::
/// read_pending_symlink`'s own extended format, task #86) -- so a LATER
/// member re-reads an EARLIER member's own symlink to discover the
/// group's growing derivation, and a downstream consumer (e.g. `ar`,
/// itself keyless and forced onto this SAME eager path once every one
/// of its own dependencies resolves this way -- see `wrapper.rs::
/// dispatch_defer`'s own routing) resolves each member symlink exactly
/// like any other eager dependency, no special-casing needed there at
/// all.
pub fn accumulate_and_register(
    client: &BuilderRpcClient,
    workspace: &Path,
    key: &str,
    member_rel_path: &str,
    record: &Record,
    deps: &HashMap<String, (StorePath, OutputName)>,
) -> anyhow::Result<(StorePath, OutputName)> {
    let store_dir = StoreDir::default();
    let group_dir = workspace.join(".dyndrv/groups").join(sanitize_key(key));
    std::fs::create_dir_all(&group_dir)
        .with_context(|| format!("create_dir_all {}", group_dir.display()))?;
    let head_drv_path = group_dir.join("head.drv");

    let member_out_name: OutputName = crate::collect::output_name_of(member_rel_path)
        .parse()
        .map_err(|e| anyhow::anyhow!("{e:?}"))?;

    // Deterministic from `key` alone -- computed ONCE here and reused
    // for both branches below, so `reparse_head`'s own re-parse always
    // recovers the SAME name a freshly-created group derivation would
    // have gotten, instead of some other placeholder. Confirmed
    // necessary by direct reproduction: an EARLIER version of this
    // function passed a fixed literal name to `parse_derivation_aterm`
    // on re-parse, which (since a real `.drv`'s own `name` field is
    // taken directly from the parser's `name` ARGUMENT, not read back
    // from the ATerm bytes themselves) silently renamed the group's own
    // derivation on every subsequent member -- confirmed via `nix
    // derivation show`: a two-member group registered TWO differently-
    // named derivations (`dyndrv-batch-vendor.drv` then a plain
    // `dyndrv-batch.drv`) instead of accumulating onto the SAME logical
    // name throughout.
    let group_name: StorePathName = format!("dyndrv-batch-{}", sanitize_key(key))
        .parse()
        .map_err(|e| anyhow::anyhow!("{e:?}"))?;

    let mut drv = if head_drv_path.exists() {
        reparse_head(&store_dir, &head_drv_path, group_name)?
    } else {
        Derivation::new(
            group_name,
            bytes::Bytes::from_static(b"x86_64-linux"),
            bytes::Bytes::from_static(b"/bin/sh"),
        )
    };

    append_member(&mut drv, &member_out_name, record, deps)?;

    let aterm_bytes = harmonia_store_aterm::print_derivation_aterm(&store_dir, &drv);
    let new_head = client
        .add_drv_to_store(&store_dir, &drv)
        .context("group::accumulate_and_register: add_drv_to_store")?;

    write_head(&head_drv_path, &aterm_bytes)?;
    Ok((new_head, member_out_name))
}

/// Appends one member's own script line + named output to an
/// (possibly freshly-created) group derivation -- mirrors `render.rs::
/// render_unit`'s per-member loop exactly (same `own_out_var`/`resolve_
/// ref`/`"$out"`-sentinel substitution shape), just building a real
/// `Derivation` incrementally instead of a rendered script string once
/// at the end.
fn append_member(
    drv: &mut Derivation,
    member_out_name: &OutputName,
    record: &Record,
    deps: &HashMap<String, (StorePath, OutputName)>,
) -> anyhow::Result<()> {
    let own_out_var = format!("${member_out_name}");

    // See `drv.rs::record_to_derivation`'s identical `resolve_ref` for
    // the full rationale -- all four of dyndrv's script-construction
    // call sites now delegate to the ONE shared `render.rs::
    // render_record_line` renderer instead of each independently
    // reimplementing the setup_cmd/seed_from/tool-args/`"; "` pattern.
    let resolve_ref = |a: &str| -> Option<String> {
        let (dep_drv_path, dep_out_name) = deps.get(a)?;
        Some(
            Placeholder::ca_output(dep_drv_path, dep_out_name)
                .render()
                .to_string_lossy()
                .into_owned(),
        )
    };
    let (setup, cmd) = crate::render::render_record_line(record, &own_out_var, true, resolve_ref);
    let mut script = setup;
    script.push_str(&cmd);

    // Appended, not replaced -- an EARLIER member's own script line
    // must still run when a LATER member's derivation is realized,
    // exactly like `render_unit`'s own per-unit combined script.
    let mut existing_script = drv
        .args
        .get(1)
        .map(|b| String::from_utf8_lossy(b).into_owned())
        .unwrap_or_default();
    existing_script.push_str(&script);
    if drv.args.len() < 2 {
        drv.args = vec![bytes::Bytes::from_static(b"-c"), bytes::Bytes::new()];
    }
    drv.args[1] = bytes::Bytes::copy_from_slice(existing_script.as_bytes());

    let ph = Placeholder::standard_output(member_out_name).render();
    drv.env.insert(
        bytes::Bytes::copy_from_slice(member_out_name.as_ref().as_bytes()),
        bytes::Bytes::copy_from_slice(ph.as_os_str().as_encoded_bytes()),
    );
    drv.outputs.insert(
        member_out_name.clone(),
        DerivationOutput::CAFloating(ContentAddressMethodAlgorithm::NixArchive(
            harmonia_utils_hash::Algorithm::SHA256,
        )),
    );

    for src_basename in &record.srcs {
        if let Ok(sp) = StorePath::from_base_path(src_basename) {
            drv.inputs.insert(SingleDerivedPath::Opaque(sp));
        }
    }
    for (dep_drv_path, dep_out_name) in deps.values() {
        drv.inputs.insert(SingleDerivedPath::Built {
            drv_path: std::sync::Arc::new(SingleDerivedPath::Opaque(dep_drv_path.clone())),
            output: dep_out_name.clone(),
        });
    }

    Ok(())
}

/// Re-parses the LOCAL `head.drv` copy back into a `Derivation` to
/// accumulate onto -- see `accumulate_and_register`'s own doc comment
/// for why this reads a local file this process's own group, not the
/// registered store path (which, confirmed by direct reproduction, is
/// NOT locally readable from inside the SAME sandbox that registered
/// it moments earlier via an EARLIER member's own invocation). `name`
/// must be the SAME deterministic group name `accumulate_and_register`
/// itself computes from `key` -- see that function's own doc comment
/// on `group_name` for why a mismatched name here silently renamed the
/// group's own derivation on every subsequent member.
fn reparse_head(
    store_dir: &StoreDir,
    head_drv_path: &Path,
    name: StorePathName,
) -> anyhow::Result<Derivation> {
    let aterm_bytes = std::fs::read(head_drv_path)
        .with_context(|| format!("reparse_head: read {}", head_drv_path.display()))?;
    harmonia_store_aterm::parse_derivation_aterm(store_dir, &aterm_bytes, name).map_err(|e| {
        anyhow::anyhow!(
            "reparse_head: parse_derivation_aterm {}: {e:?}",
            head_drv_path.display()
        )
    })
}

fn write_head(head_drv_path: &Path, aterm_bytes: &[u8]) -> anyhow::Result<()> {
    let tmp_drv = head_drv_path.with_extension(format!("tmp.{}", std::process::id()));
    std::fs::write(&tmp_drv, aterm_bytes)
        .with_context(|| format!("write_head: write {}", tmp_drv.display()))?;
    std::fs::rename(&tmp_drv, head_drv_path)
        .with_context(|| format!("write_head: rename to {}", head_drv_path.display()))?;
    Ok(())
}

/// Sanitizes a batch key into a filesystem-safe directory name -- a key
/// is a directory-based relative path (`mkAcceleratedStdenv.nix`'s own
/// `batchGroupOfAttrs`, e.g. `"vendor"`), which may already be safe, but
/// sanitizing defensively matches `collect::output_name_of`'s own
/// established convention rather than assuming every possible key is a
/// safe single path component.
fn sanitize_key(key: &str) -> String {
    crate::collect::output_name_of(key)
}

/// Resolves the workspace root for `.dyndrv/groups/` -- mirrors
/// `thunk::resolve_workspace`'s own walk-up-from-`$PWD` convention
/// exactly (nearest ancestor already containing `.dyndrv/`, else
/// nearest ancestor with `.git`, else `$PWD` itself), reused here rather
/// than duplicated since both need the identical "find the build's own
/// stable root" answer.
pub fn resolve_workspace(start: &Path) -> PathBuf {
    crate::thunk::resolve_workspace(start)
}
