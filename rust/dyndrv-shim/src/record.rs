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
    #[serde(rename = "chainedFrom", default, skip_serializing_if = "Option::is_none")]
    pub chained_from: Option<String>,
}
