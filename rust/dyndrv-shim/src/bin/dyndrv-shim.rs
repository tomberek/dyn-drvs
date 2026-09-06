use anyhow::Context;
use dyndrv_shim::cc::{cc_to_node, discover_tree};
use dyndrv_shim::mode;
use dyndrv_shim::tonode::{ar_to_node, ranlib_to_node};
use dyndrv_shim::wrapper::{run_discover_tree, run_plain};
use nix_builder_rpc_client::BuilderRpcClient;
use std::collections::HashMap;

/// Entrypoint for the `cc`/`ar`/`ranlib` shims, dispatched via
/// `DYNDRV_TOOL` (set by `wrapCommand.nix`'s `toNodeCompiled` wrapper
/// script) rather than `argv[0]` -- confirmed necessary by direct
/// reproduction: this binary is also run directly via
/// `shim.devShell`'s wrapper, on a HOST whose real `/bin/sh` may not
/// be bash (e.g. dash), where `exec -a` (the only way to override
/// `argv[0]` from `/bin/sh` portably) isn't available.
///
/// Env vars (set by `wrapCommand.nix`'s caller, mirroring today's
/// `realCommand`/`nixPackage` Nix-level params):
///   DYNDRV_TOOL           which decision logic to dispatch to ("cc"/"ar"/"ranlib")
///   DYNDRV_REAL_COMMAND   absolute path to the real cc/ar/ranlib binary
///   DYNDRV_BINTOOLS_BASENAME  store basename of the bintools package (ar/ranlib only)
///   DYNDRV_COREUTILS_BASENAME  store basename of coreutils (cc only)
///   DYNDRV_STDENV_CC_BASENAME  store basename of stdenv.cc (cc only)
///   DYNDRV_BATCH_GROUPS   JSON `{relSourcePath: groupKey}` (cc only, optional)
///   DYNDRV_MODE           optional override: "sandbox" | "rpc" | "thunk"
///   DYNDRV_AUTOFORCE      "1" to realize immediately (Rpc/Thunk modes)
fn main() -> anyhow::Result<()> {
    let tool = std::env::var("DYNDRV_TOOL").context("DYNDRV_TOOL")?;
    let real_command = std::env::var("DYNDRV_REAL_COMMAND").context("DYNDRV_REAL_COMMAND")?;
    let argv: Vec<String> = std::env::args().skip(1).collect();

    let client = BuilderRpcClient::connect_from_env().context("connect_from_env")?;
    let mode = mode::detect();

    match tool.as_str() {
        "ar" => {
            let bintools_basename =
                std::env::var("DYNDRV_BINTOOLS_BASENAME").context("DYNDRV_BINTOOLS_BASENAME")?;
            run_plain(&client, &real_command, &argv, mode, |rewritten| {
                ar_to_node(rewritten, &real_command, &bintools_basename)
            })
        }
        "ranlib" => {
            let bintools_basename =
                std::env::var("DYNDRV_BINTOOLS_BASENAME").context("DYNDRV_BINTOOLS_BASENAME")?;
            run_plain(&client, &real_command, &argv, mode, |rewritten| {
                ranlib_to_node(rewritten, &real_command, &bintools_basename)
            })
        }
        "cc" => {
            let coreutils_basename = std::env::var("DYNDRV_COREUTILS_BASENAME")
                .context("DYNDRV_COREUTILS_BASENAME")?;
            let stdenv_cc_basename = std::env::var("DYNDRV_STDENV_CC_BASENAME")
                .context("DYNDRV_STDENV_CC_BASENAME")?;
            let batch_groups: HashMap<String, String> = std::env::var("DYNDRV_BATCH_GROUPS")
                .ok()
                .and_then(|s| serde_json::from_str(&s).ok())
                .unwrap_or_default();
            run_discover_tree(
                &client,
                &real_command,
                &argv,
                mode,
                |argv| discover_tree(argv, &real_command),
                |argv, tree_basename| {
                    cc_to_node(
                        argv,
                        &real_command,
                        &coreutils_basename,
                        &stdenv_cc_basename,
                        tree_basename,
                        &batch_groups,
                    )
                },
            )
        }
        other => anyhow::bail!("dyndrv-shim: unrecognized DYNDRV_TOOL '{other}'"),
    }
}
