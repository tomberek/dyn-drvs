use serde::{Deserialize, Serialize};

/// Mirrors `wrapCommand.nix`/`mkAcceleratedStdenv.nix`'s `record` JSON
/// shape exactly (`key`/`tool`/`args`/`srcs`/`setupCmd`) -- the same
/// on-disk format the existing bash `toNode`/`toNodeBash` paths write,
/// so `collectStubs.nix`'s bash collector keeps working unmodified
/// against stubs this binary writes, and vice versa (either path can
/// produce/consume any stub in the SAME build -- no migration needed to
/// switch one shim at a time).
#[derive(Clone, Serialize, Deserialize)]
pub struct Record {
    pub key: Option<String>,
    pub tool: String,
    pub args: Vec<String>,
    pub srcs: Vec<String>,
    #[serde(rename = "setupCmd", default, skip_serializing_if = "Option::is_none")]
    pub setup_cmd: Option<String>,
    /// The nested-position path (e.g. `".dyndrv-cwd/.dyndrv-cwd/"`,
    /// see `wrapCommand.nix`'s own header comment on
    /// `DYNDRV_TREE_UPDEPTH`/`dyndrvUpDirName`) this record's own tool
    /// invocation must run from -- needed whenever the invocation's own
    /// paths referenced its source via one or more leading `../`
    /// (meson's out-of-source-tree convention, confirmed necessary by
    /// direct reproduction against NixOS/nix's own `nix-util`
    /// component). Kept as its own field, NOT baked into `setup_cmd` as
    /// a bare `cd` -- see `render.rs::render_record_line`'s own comment
    /// for why a plain `cd` would leak into a LATER chained/merged
    /// record's own `setup_cmd` otherwise. `None` for the common case
    /// (every OTHER example/fixture this accelerator has been run
    /// against so far, which never needed the tree's nested "cwd"
    /// chain at all).
    #[serde(rename = "chdir", default, skip_serializing_if = "Option::is_none")]
    pub chdir: Option<String>,
    #[serde(rename = "chainedFrom", default, skip_serializing_if = "Option::is_none")]
    pub chained_from: Option<String>,
    /// Names an EARLIER dependency (an args-equivalent reference,
    /// resolved the SAME way an `args` element is -- a real
    /// `/nix/store/...` path, or an unresolved stub/symlink/text-stub
    /// reference) whose content must be copied into `$out` BEFORE this
    /// record's own tool line runs -- port of `ranlibToNode`'s own
    /// "seed `$out`" need: `ranlib`'s only positional arg indexes an
    /// archive IN PLACE (both input and output), so unlike `ar`'s
    /// distinct-inputs-vs-output shape, `$out` must already contain a
    /// real copy of the archive's CURRENT content before `ranlib` runs
    /// on it. Kept as its own field (not folded into `args`, which
    /// always literally overwrites this same slot with `"$out"`) so a
    /// caller resolving a `deps` map by scanning `args` doesn't need a
    /// special case to ALSO discover this reference -- callers that
    /// build a `deps` map (`rpc_tail.rs`/`wrapper.rs::run_sandbox_eager_
    /// tail`/`thunk_tail.rs`) scan this field the SAME way they scan
    /// `args`, and each render layer (`render.rs`/`drv.rs`/
    /// `drv_thunk.rs`) resolves+seeds it explicitly. `coreutils_basename`
    /// travels alongside the reference itself (rather than as a
    /// separate function parameter threaded through every render call
    /// site) since the render layers have no other source for it.
    /// `None` for any record with no such need (every OTHER tool's own
    /// decision logic, plus this field's own JSON representation,
    /// `seedFrom`, stays absent from the OLD bash-oracle-compatible
    /// record shape by default -- `ranlib_to_node` is the only producer
    /// today).
    #[serde(rename = "seedFrom", default, skip_serializing_if = "Option::is_none")]
    pub seed_from: Option<SeedFrom>,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct SeedFrom {
    pub from: String,
    #[serde(rename = "coreutilsBasename")]
    pub coreutils_basename: String,
}

