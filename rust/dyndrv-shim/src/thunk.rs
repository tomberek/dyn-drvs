use std::path::{Path, PathBuf};

/// Content-addressed thunk file, mirroring nixgg's own
/// `.nixgg/thunks/<id>.nix` layout (`go/internal/thunk/thunk.go`): a
/// plain Nix expression written to disk at shim-invocation time, with
/// NO daemon/store interaction at all -- the fallback for a daemon with
/// `ca-derivations`/`dynamic-derivations` unavailable (this mode's own
/// auto-selection is gated on that, see `mode.rs`).
///
/// `id`: sha256(expression body), truncated to 32 hex chars (matches
/// nixgg's own `thunk.Compute` exactly -- same truncation length, so
/// this stays a recognizable convention for anyone who's used nixgg).
pub fn compute_id(expr: &str) -> String {
    let digest = sha256_hex(expr.as_bytes());
    digest[..32].to_string()
}

fn sha256_hex(bytes: &[u8]) -> String {
    let hash = harmonia_utils_hash::Sha256::digest(bytes);
    hex_encode(hash.digest_bytes())
}

fn hex_encode(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push_str(&format!("{:02x}", b));
    }
    s
}

/// Renders a `Record` as a standalone Nix expression -- a plain
/// `derivation { ... }` call (no `<nixpkgs>` dependency, matching this
/// codebase's own established "no IFD needed for the file granularity
/// path" convention). Each `srcs` entry is referenced via
/// `builtins.storePath` (not a bare string) -- a plain string has no
/// Nix string CONTEXT, so `derivation{}` would never mount it into the
/// build sandbox as a real input, matching nixgg's own documented
/// reason for its `pure-store-path.nix` helper (`builtins.storePath`
/// itself is fine here since thunk-mode realization is always an
/// ordinary, non-`--pure-eval` `nix build --file` call -- no need for
/// nixgg's own `unsafeDiscardStringContext`/`appendContext` workaround,
/// which exists specifically to dodge the pure-eval restriction this
/// codebase doesn't need to dodge).
pub fn record_to_thunk_expr(record: &crate::record::Record) -> String {
    let mut script = String::new();
    if let Some(setup) = &record.setup_cmd {
        script.push_str(setup);
    }
    script.push_str(&record.tool);
    for a in &record.args {
        script.push(' ');
        if a == "$out" {
            script.push_str(a);
        } else {
            script.push_str(&crate::render::shell_quote(a));
        }
    }
    script.push_str("; ");

    let srcs_list = record
        .srcs
        .iter()
        .map(|s| format!("(builtins.storePath \"/nix/store/{s}\")"))
        .collect::<Vec<_>>()
        .join(" ");

    format!(
        "let srcs = [ {srcs_list} ]; in\nderivation {{\n  name = \"dyndrv-thunk\";\n  system = builtins.currentSystem;\n  builder = \"/bin/sh\";\n  args = [ \"-c\" {} ];\n  __contentAddressed = true;\n  outputHashMode = \"nar\";\n  outputHashAlgo = \"sha256\";\n  # Referencing `srcs` here (even though the script never reads this\n  # attribute directly -- every path is already inlined as an absolute\n  # string above) is what actually registers each store path as a real\n  # input dependency; a plain string interpolated into `args` alone\n  # carries no context of its own.\n  inherit srcs;\n}}\n",
        nix_string_escape(&script),
    )
}

fn nix_string_escape(s: &str) -> String {
    let mut out = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '$' => out.push_str("\\$"),
            '\n' => out.push_str("\\n"),
            _ => out.push(c),
        }
    }
    out.push('"');
    out
}

/// Writes a thunk file at `.dyndrv/thunks/<id>.nix` under `workspace`,
/// idempotently (tmp+rename, matching nixgg's own `thunk.Write`) --
/// same content never rewritten, so repeated invocations across a
/// build session don't churn the filesystem.
pub fn write_thunk(workspace: &Path, id: &str, expr: &str) -> anyhow::Result<PathBuf> {
    let thunks_dir = workspace.join(".dyndrv/thunks");
    std::fs::create_dir_all(&thunks_dir)?;
    let dst = thunks_dir.join(format!("{id}.nix"));
    if dst.exists() {
        touch(&dst)?;
        return Ok(dst);
    }
    let tmp = thunks_dir.join(format!("{id}.tmp.{}", std::process::id()));
    std::fs::write(&tmp, expr)?;
    std::fs::rename(&tmp, &dst)?;
    Ok(dst)
}

fn touch(path: &Path) -> std::io::Result<()> {
    let now = std::time::SystemTime::now();
    let file = std::fs::File::open(path)?;
    file.set_modified(now)
}

/// Symlinks `output` at the thunk file, replacing any stale symlink --
/// port of `thunk.LinkPlaceholder`. `make` follows the symlink via
/// `stat(2)`, so the thunk's own mtime (bumped by `write_thunk` even on
/// a content-identical no-op write) is what `make`'s staleness check
/// actually sees.
pub fn link_placeholder(output: &Path, thunk_path: &Path) -> anyhow::Result<()> {
    if let Some(parent) = output.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let _ = std::fs::remove_file(output);
    std::os::unix::fs::symlink(thunk_path, output)?;
    Ok(())
}

/// Workspace root for `.dyndrv/`, mirroring nixgg's own
/// `paths.Resolve` walk-up-from-`$PWD` convention: nearest ancestor
/// already containing `.dyndrv/`, else nearest ancestor with `.git`,
/// else `$PWD` itself.
pub fn resolve_workspace(start: &Path) -> PathBuf {
    let mut cur = start.to_path_buf();
    loop {
        if cur.join(".dyndrv").is_dir() {
            return cur;
        }
        if !cur.pop() {
            break;
        }
    }
    let mut cur = start.to_path_buf();
    loop {
        if cur.join(".git").exists() {
            return cur;
        }
        if !cur.pop() {
            return start.to_path_buf();
        }
    }
}
