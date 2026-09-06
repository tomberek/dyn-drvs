/// Which tail a shim invocation runs, decided once per process (not per
/// call site) -- mirrors nixgg's own `sandbox.Enabled()` as the sole
/// branch point in its shim entrypoints, with one more rung here since
/// dyndrv distinguishes `Rpc` from `Thunk` where nixgg's native mode
/// only ever writes thunks.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DyndrvMode {
    /// `builder-rpc-v0` sandbox: defer + write a batch-pending stub,
    /// resolved later by `dyndrv-collect` at the end of `buildPhase`.
    Sandbox,
    /// devShell/native, unrestricted daemon connection: register the
    /// real `Derivation` immediately via `add_drv_to_store`. If
    /// `autoforce`, also realize it (`build_paths`) and copy the result
    /// back over the caller-visible path.
    Rpc { autoforce: bool },
}

/// Auto-detects the mode from the environment, mirroring
/// `nix-builder-rpc-client`'s own `in_drv` check (`NIX_BUILD_TOP` is set
/// by the daemon before running any builder, and has no purpose outside
/// one): `NIX_REMOTE` set AND `NIX_BUILD_TOP` set -> `Sandbox`; anything
/// else (assumed to be an interactive devShell or plain command
/// invocation) -> `Rpc`, with `autoforce` from `DYNDRV_AUTOFORCE=1`.
///
/// `DYNDRV_MODE=sandbox|rpc` overrides auto-detection outright, for
/// tests/CI. `Thunk` mode (task #64, the no-experimental-features
/// fallback) is not yet auto-selected by anything -- only reachable via
/// an explicit future `DYNDRV_MODE=thunk`.
pub fn detect() -> DyndrvMode {
    let autoforce = std::env::var("DYNDRV_AUTOFORCE").as_deref() == Ok("1");
    match std::env::var("DYNDRV_MODE").ok().as_deref() {
        Some("sandbox") => return DyndrvMode::Sandbox,
        Some("rpc") => return DyndrvMode::Rpc { autoforce },
        _ => {}
    }
    let in_sandbox =
        std::env::var_os("NIX_REMOTE").is_some() && std::env::var_os("NIX_BUILD_TOP").is_some();
    if in_sandbox {
        DyndrvMode::Sandbox
    } else {
        DyndrvMode::Rpc { autoforce }
    }
}
