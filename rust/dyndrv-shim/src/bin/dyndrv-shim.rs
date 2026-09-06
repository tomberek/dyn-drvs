use anyhow::Context;
use dyndrv_shim::tonode::{ar_to_node, ranlib_to_node};
use dyndrv_shim::wrapper::run_plain;
use nix_builder_rpc_client::BuilderRpcClient;

/// Entrypoint for the `ar`/`ranlib` shims (argv[0]-dispatched, mirroring
/// `wrapperDir`'s existing symlink-install convention). `cc`/`gcc`
/// dispatch is a later step -- this binary starts with the simpler two
/// tools (fixed argv shape, no `discoverTree`/probe-detection) to prove
/// the plain-wrapper pipeline end to end before porting `cc`'s larger
/// decision logic.
///
/// Env vars (set by `wrapCommand.nix`'s caller, mirroring today's
/// `realCommand`/`nixPackage` Nix-level params):
///   DYNDRV_REAL_COMMAND   absolute path to the real ar/ranlib binary
///   DYNDRV_BINTOOLS_BASENAME  store basename of the bintools package
fn main() -> anyhow::Result<()> {
    let argv0 = std::env::args().next().unwrap_or_default();
    let tool = std::path::Path::new(&argv0)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("")
        .to_string();

    let real_command = std::env::var("DYNDRV_REAL_COMMAND").context("DYNDRV_REAL_COMMAND")?;
    let bintools_basename =
        std::env::var("DYNDRV_BINTOOLS_BASENAME").context("DYNDRV_BINTOOLS_BASENAME")?;

    let argv: Vec<String> = std::env::args().skip(1).collect();

    let client = BuilderRpcClient::connect_from_env().context("connect_from_env")?;

    match tool.as_str() {
        "ar" => run_plain(&client, &real_command, &argv, |rewritten| {
            ar_to_node(rewritten, &real_command, &bintools_basename)
        }),
        "ranlib" => run_plain(&client, &real_command, &argv, |rewritten| {
            ranlib_to_node(rewritten, &real_command, &bintools_basename)
        }),
        other => anyhow::bail!("dyndrv-shim: unrecognized tool '{other}' (argv[0]={argv0})"),
    }
}
