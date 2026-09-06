/// Which format a `Thunk`-mode tail writes to disk. `Nix` mirrors
/// nixgg's own default native mode exactly (a plain `.nix` expression,
/// realized later via `nix build --file`); `Drv` is EXPERIMENTAL (task
/// #65) -- writes a real ATerm-serialized `.drv` file directly, no
/// daemon call at all for the write itself, realized via `nix-store
/// --realise`/`nix build <path>.drv^out`. Never auto-selected; only
/// reachable via an explicit `DYNDRV_THUNK_FORMAT=drv` override.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ThunkFormat {
    Nix,
    Drv,
}

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
    /// devShell/native, NO experimental-features requirement at all:
    /// write a `.nix`/`.drv` thunk file to disk, symlink the
    /// caller-visible output at it. If `autoforce`, realize the whole
    /// thunk graph immediately (link/archive steps only -- mirrors
    /// nixgg's own link-shim-only `NIXGG_AUTOFORCE` trigger).
    Thunk {
        format: ThunkFormat,
        autoforce: bool,
    },
}

/// Auto-detects the mode from the environment, mirroring
/// `nix-builder-rpc-client`'s own `in_drv` check (`NIX_BUILD_TOP` is set
/// by the daemon before running any builder, and has no purpose outside
/// one): `NIX_REMOTE` set AND `NIX_BUILD_TOP` set -> `Sandbox`; anything
/// else (assumed to be an interactive devShell or plain command
/// invocation) -> `Rpc`, with `autoforce` from `DYNDRV_AUTOFORCE=1`.
///
/// `DYNDRV_MODE=sandbox|rpc|thunk` overrides auto-detection outright,
/// for tests/CI and for reaching `Thunk` mode at all (never
/// auto-selected -- `Rpc` mode's own requirements, `ca-derivations`/
/// `dynamic-derivations`, are ALWAYS assumed available outside a
/// sandbox in this codebase's own established policy, matching
/// `capabilities.nix`'s "assume `builder-rpc-v0`, don't detect" stance;
/// a caller who genuinely lacks them opts into `Thunk` explicitly).
/// `DYNDRV_THUNK_FORMAT=nix|drv` (only consulted when `Thunk` is
/// selected) picks the format; defaults to `nix`.
pub fn detect() -> DyndrvMode {
    let autoforce = std::env::var("DYNDRV_AUTOFORCE").as_deref() == Ok("1");
    let thunk_format = match std::env::var("DYNDRV_THUNK_FORMAT").ok().as_deref() {
        Some("drv") => ThunkFormat::Drv,
        _ => ThunkFormat::Nix,
    };
    match std::env::var("DYNDRV_MODE").ok().as_deref() {
        Some("sandbox") => return DyndrvMode::Sandbox,
        Some("rpc") => return DyndrvMode::Rpc { autoforce },
        Some("thunk") => {
            return DyndrvMode::Thunk {
                format: thunk_format,
                autoforce,
            }
        }
        _ => {}
    }
    if in_sandbox() {
        DyndrvMode::Sandbox
    } else {
        DyndrvMode::Rpc { autoforce }
    }
}

/// `NIX_REMOTE` set AND `NIX_BUILD_TOP` set -- see `detect()`'s own doc
/// comment for the full rationale. Exposed separately from `detect()`
/// so `connect()` below can use the SAME signal `nix-builder-rpc-
/// client::connect_from_env`'s own looser `in_drv` heuristic
/// (`NIX_BUILD_TOP` alone) gets wrong: confirmed by direct reproduction
/// that `nix develop`'s own shell-setup derivation leaves `NIX_BUILD_TOP`
/// set in the INTERACTIVE shell it hands back (a real, common nixpkgs
/// `mkShell` convention many setup hooks rely on for scratch space) even
/// though `NIX_REMOTE` is empty there -- `connect_from_env()`'s own
/// `in_drv` check alone would then wrongly select the sandboxed-only
/// `AddToStoreScanning` opcode outside any sandbox at all, failing with
/// "the daemon does not support the 'add-to-store-scanning' protocol
/// feature" the moment `Rpc` mode's `add_to_store_nar` ran.
pub fn in_sandbox() -> bool {
    std::env::var_os("NIX_REMOTE").is_some() && std::env::var_os("NIX_BUILD_TOP").is_some()
}

/// Connects using the SAME `in_sandbox()` signal `detect()` uses for
/// `in_drv`, instead of `BuilderRpcClient::connect_from_env()`'s own
/// looser `NIX_BUILD_TOP`-alone heuristic -- see `in_sandbox()`'s own
/// doc comment for why that heuristic is wrong outside a real sandbox.
/// Otherwise mirrors `connect_from_env`'s own socket-path resolution
/// exactly (`$NIX_REMOTE`, `unix://`-prefixed or a bare absolute path,
/// else the standard daemon socket).
pub fn connect() -> anyhow::Result<nix_builder_rpc_client::BuilderRpcClient> {
    use nix_builder_rpc_client::BuilderRpcClient;
    use std::path::PathBuf;

    const DEFAULT_DAEMON_SOCKET: &str = "/nix/var/nix/daemon-socket/socket";

    let path = match std::env::var("NIX_REMOTE") {
        Ok(remote) if matches!(remote.as_str(), "daemon" | "auto" | "") => {
            PathBuf::from(DEFAULT_DAEMON_SOCKET)
        }
        Ok(remote) => {
            if let Some(stripped) = remote.strip_prefix("unix://") {
                PathBuf::from(stripped)
            } else if remote.starts_with('/') {
                PathBuf::from(remote)
            } else {
                anyhow::bail!("dyndrv-shim: unsupported NIX_REMOTE '{remote}'");
            }
        }
        Err(_) => PathBuf::from(DEFAULT_DAEMON_SOCKET),
    };
    if !path.exists() {
        anyhow::bail!("dyndrv-shim: no daemon socket at {}", path.display());
    }
    BuilderRpcClient::connect_unix(&path, in_sandbox()).map_err(|e| anyhow::anyhow!("{e}"))
}
