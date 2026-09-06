use crate::mode::DyndrvMode;
use crate::record::Record;
use crate::rpc_tail::run_rpc_tail;
use crate::stub;
use crate::tonode::Decision;
use nix_builder_rpc_client::BuilderRpcClient;
use std::path::Path;

/// Strips the calling build's own `$PWD` prefix from an argv element --
/// port of `wrapCommand.nix`'s `stripPwdPrefix`, handling both the bare
/// and glued-flag-prefix form generically.
pub fn strip_pwd_prefix(s: &str, orig_pwd: &str) -> String {
    let prefix = format!("{}/", orig_pwd);
    if let Some(rest) = s.strip_prefix(&prefix) {
        return rest.to_string();
    }
    if let Some(idx) = s.find(&prefix) {
        return format!("{}{}", &s[..idx], &s[idx + prefix.len()..]);
    }
    s.to_string()
}

/// Runs the plain (non-`discoverTree`) wrapper pipeline for one
/// intercepted invocation: strip-pwd-prefix every argv element, rewrite
/// any existing-relative-file element to its own store path (skipping
/// anything that's itself a pending stub), run the decision closure,
/// then either exec the real command (passthrough) or write a deferred
/// stub -- direct port of `wrapCommand.nix`'s plain `wrapperScript`
/// variant, minus the `nix-instantiate`/`jq` spawns it needed.
///
/// `decide`: closure implementing this tool's own `toNode`/`toNodeBash`
/// equivalent, given the REWRITTEN argv. `mode`: decided once by
/// `crate::mode::detect()` in the entrypoint, threaded in here rather
/// than re-detected per call.
pub fn run_plain<F>(
    client: &BuilderRpcClient,
    real_command: &str,
    orig_argv: &[String],
    mode: DyndrvMode,
    decide: F,
) -> anyhow::Result<()>
where
    F: FnOnce(&[String]) -> Decision,
{
    let orig_pwd = std::env::current_dir()?.display().to_string();

    let stripped: Vec<String> = orig_argv
        .iter()
        .map(|a| strip_pwd_prefix(a, &orig_pwd))
        .collect();

    let rewritten: Vec<String> = stripped
        .iter()
        .map(|a| rewrite_argv_element(client, a))
        .collect::<anyhow::Result<Vec<_>>>()?;

    match decide(&rewritten) {
        Decision::Passthrough => {
            // PASSTHROUGH execs with the ORIGINAL argv (not rewritten,
            // not stripped) -- `realCommand` needs the real relative
            // source path in the outer build's own $PWD.
            exec_passthrough(real_command, orig_argv)
        }
        Decision::Defer {
            record,
            output_arg,
            output_path,
        } => {
            let output_path = match (output_arg, output_path) {
                (Some(idx), _) => rewritten
                    .get(idx)
                    .cloned()
                    .ok_or_else(|| anyhow::anyhow!("outputArg {idx} out of range"))?,
                (None, Some(p)) => p,
                (None, None) => anyhow::bail!("decision returned neither outputArg nor outputPath"),
            };
            match mode {
                DyndrvMode::Sandbox => finalize_defer(&output_path, record),
                DyndrvMode::Rpc { autoforce } => {
                    let drv_name = Path::new(&output_path)
                        .file_name()
                        .map(|n| n.to_string_lossy().into_owned())
                        .unwrap_or_else(|| output_path.clone());
                    run_rpc_tail(client, &output_path, record, &drv_name, autoforce)
                }
            }
        }
    }
}

/// Any argv element that's a path to an existing REGULAR file, not
/// already under the store, and not itself a pending stub, gets
/// rewritten to its own store path -- port of `wrapCommand.nix`'s
/// rewrite loop (`nix store add-file`, here `add_to_store_flat` --
/// same CA method, no subprocess).
///
/// `StorePath`'s own `Display` impl prints just `<hash>-<name>` (the
/// base path form, matching Nix's internal convention -- see
/// `harmonia_store_path::StorePath`'s own doc), NOT the full
/// `/nix/store/<hash>-<name>` path -- confirmed by direct reproduction
/// that using it bare here produced a rendered command line referencing
/// a nonexistent RELATIVE path (`ar cr $out jqrq2...-a.o`, no
/// directory), and separately broke `extra_store_paths`' own
/// `/nix/store/` prefix-detection downstream. The full absolute path
/// must be reconstructed explicitly.
fn rewrite_argv_element(client: &BuilderRpcClient, a: &str) -> anyhow::Result<String> {
    if a.starts_with("/nix/store/") || a.starts_with('-') {
        return Ok(a.to_string());
    }
    let path = Path::new(a);
    if path.is_file() && stub::read_batch_stub(path).is_none() {
        let name = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| a.to_string());
        let bytes = std::fs::read(path)?;
        let store_path = client.add_to_store_flat(&name, &bytes)?;
        return Ok(format!("/nix/store/{store_path}"));
    }
    Ok(a.to_string())
}

fn exec_passthrough(real_command: &str, argv: &[String]) -> anyhow::Result<()> {
    use std::os::unix::process::CommandExt;
    let err = std::process::Command::new(real_command).args(argv).exec();
    Err(anyhow::anyhow!("exec {real_command} failed: {err}"))
}

/// Shared "finalize" tail -- port of `wrapCommand.nix`'s
/// `finalizeTail`: chain onto an EARLIER pending stub at the same
/// output path if one exists (see that file's header comment for why
/// -- `ar cr liba.a *.o` immediately followed by `ranlib liba.a` on the
/// SAME path), then write the (possibly chained) record + stub.
fn finalize_defer(output_path: &str, mut record: Record) -> anyhow::Result<()> {
    let output_path = Path::new(output_path);

    if let Some(chained_from) = stub::read_batch_stub(output_path) {
        record.chained_from = Some(chained_from.display().to_string());
    }

    let record_json = serde_json::to_vec(&record)?;
    let record_path = tempfile_path(&std::env::temp_dir());
    std::fs::write(&record_path, record_json)?;

    stub::write_batch_stub(output_path, &record_path)?;
    Ok(())
}

fn tempfile_path(dir: &Path) -> std::path::PathBuf {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    dir.join(format!("dyndrv-record-{}-{}", std::process::id(), nanos))
}
