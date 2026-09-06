use anyhow::Context;
use dyndrv_shim::mode;
use dyndrv_shim::tonode::{ar_to_node, ranlib_to_node};
use dyndrv_shim::wrapper::run_plain;
use nix_builder_rpc_client::BuilderRpcClient;

/// Entrypoint for the `ar`/`ranlib` shims, dispatched via `DYNDRV_TOOL`
/// (set by `wrapCommand.nix`'s `toNodeCompiled` wrapper script) rather
/// than `argv[0]` -- confirmed necessary by direct reproduction: this
/// binary is also run directly via `shim.devShell`'s wrapper, on a HOST
/// whose real `/bin/sh` may not be bash (e.g. dash), where `exec -a`
/// (the only way to override `argv[0]` from `/bin/sh` portably) isn't
/// available. `cc`/`gcc` dispatch is a later step -- this binary starts
/// with the simpler two tools (fixed argv shape, no
/// `discoverTree`/probe-detection) to prove the plain-wrapper pipeline
/// end to end before porting `cc`'s larger decision logic.
///
/// Env vars (set by `wrapCommand.nix`'s caller, mirroring today's
/// `realCommand`/`nixPackage` Nix-level params):
///   DYNDRV_TOOL           which decision logic to dispatch to ("ar"/"ranlib")
///   DYNDRV_REAL_COMMAND   absolute path to the real ar/ranlib binary
///   DYNDRV_BINTOOLS_BASENAME  store basename of the bintools package
///   DYNDRV_MODE           optional override: "sandbox" | "rpc"
///   DYNDRV_AUTOFORCE      "1" to realize immediately in Rpc mode
fn main() -> anyhow::Result<()> {
    let tool = std::env::var("DYNDRV_TOOL").context("DYNDRV_TOOL")?;

    let real_command = std::env::var("DYNDRV_REAL_COMMAND").context("DYNDRV_REAL_COMMAND")?;
    let bintools_basename =
        std::env::var("DYNDRV_BINTOOLS_BASENAME").context("DYNDRV_BINTOOLS_BASENAME")?;

    let argv: Vec<String> = std::env::args().skip(1).collect();

    let client = BuilderRpcClient::connect_from_env().context("connect_from_env")?;
    let mode = mode::detect();

    match tool.as_str() {
        "ar" => run_plain(&client, &real_command, &argv, mode, |rewritten| {
            ar_to_node(rewritten, &real_command, &bintools_basename)
        }),
        "ranlib" => run_plain(&client, &real_command, &argv, mode, |rewritten| {
            ranlib_to_node(rewritten, &real_command, &bintools_basename)
        }),
        other => anyhow::bail!("dyndrv-shim: unrecognized DYNDRV_TOOL '{other}'"),
    }
}
