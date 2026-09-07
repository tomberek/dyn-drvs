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

/// Detects whether `path` is a symlink into `.dyndrv/thunks/` (a
/// `Thunk{Nix}`-produced dependency, written by an EARLIER, already-
/// completed shim invocation -- e.g. `ar`'s own `.o` positional args,
/// each some earlier `cc` invocation's deferred output) and, if so,
/// returns that target `.nix` file's own absolute path -- for
/// substituting a real `import <path>` reference into a DEPENDENT
/// thunk's own expression (task #90's own multi-thunk chaining),
/// instead of the dependency's literal relative-path TEXT (which,
/// realized in a completely different working directory, wouldn't
/// resolve to anything real). Returns `None` for a real file, a
/// `Thunk{Drv}` thunk symlink (`.dyndrv/thunks-drv/`, a different
/// directory), or anything else that isn't this specific
/// representation -- callers fall back to treating the argv element as
/// plain text in that case. Mirrors `drv_thunk::resolve_drv_thunk_
/// dependency`'s own identical "check the target's own parent
/// directory name" convention exactly, since a `.dyndrv/thunks/`
/// symlink may be absolute OR relative depending on how it was
/// written.
pub fn resolve_nix_thunk_dependency(path: &Path) -> Option<PathBuf> {
    let target = std::fs::read_link(path).ok()?;
    if target.parent().and_then(|p| p.file_name()) != Some(std::ffi::OsStr::new("thunks")) {
        return None;
    }
    Some(target)
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
///
/// `deps`: `{ <record.args element> -> <dependency's own .nix thunk
/// path> }`, built by the CALLER (`thunk_tail.rs::run_nix_format`'s own
/// dependency scan, task #90) by detecting which of THIS record's
/// `args` are symlinks into `.dyndrv/thunks/` -- i.e. real cross-thunk
/// references, not plain content. For each such element, this function
/// substitutes a real `import <path>` reference into the SCRIPT's own
/// reference to that arg (via `${import <path>}`, Nix's own string-
/// interpolation-of-a-derivation convention -- resolves to the
/// dependency's OWN realized output path once THIS thunk is built)
/// instead of the literal relative-path text, which is what makes a
/// SINGLE `nix build --file` on the root thunk transitively realize the
/// WHOLE referenced graph on its own -- verified directly: `nix build
/// --file` on a thunk that `import`s another correctly builds BOTH
/// derivations in one call, no separate registration-tree walk needed
/// (unlike `Thunk{Drv}` mode's own `register_drv_tree`, which exists
/// specifically because a raw `.drv` file has no `import`-equivalent
/// mechanism of its own).
pub fn record_to_thunk_expr(
    record: &crate::record::Record,
    deps: &std::collections::HashMap<String, PathBuf>,
) -> String {
    let mut script = NixStringBuilder::new();
    if let Some(setup) = &record.setup_cmd {
        script.push_literal(setup);
    }
    // See `drv.rs::record_to_derivation`'s identical handling for the
    // full rationale. `seed.from` resolves through `deps` the same way
    // an `args` element does -- see below.
    if let Some(seed) = &record.seed_from {
        script.push_literal(&format!("/nix/store/{cu}/bin/cp ", cu = seed.coreutils_basename));
        if let Some(dep_path) = deps.get(&seed.from) {
            script.push_interp(&format!("import {}", nix_path_literal(dep_path)));
        } else {
            script.push_literal(&crate::render::shell_quote(&seed.from));
        }
        script.push_literal(&format!(
            " $out && /nix/store/{cu}/bin/chmod u+w $out && ",
            cu = seed.coreutils_basename,
        ));
    }
    script.push_literal(&record.tool);
    for a in &record.args {
        script.push_literal(" ");
        if a == "$out" {
            // The literal sentinel "$out" must stay UNESCAPED as raw
            // Nix-string text (`$out`, not `\$out`) so the builder's own
            // shell expands it -- confirmed by direct reproduction:
            // escaping it makes `/bin/sh -c` see the literal three
            // characters `$out` unexpanded. `push_literal`'s own
            // escaping only touches `"`/`\`/`\n`/a BARE interpolation-
            // introducing `$` (i.e. `${`) -- a lone `$` followed by
            // anything else (like `out`) is untouched by Nix's own
            // string-escaping rules, so this is already safe to push as
            // a plain literal rather than needing special-casing here.
            script.push_literal(a);
        } else if let Some(dep_path) = deps.get(a) {
            script.push_interp(&format!("import {}", nix_path_literal(dep_path)));
        } else {
            script.push_literal(&crate::render::shell_quote(a));
        }
    }
    script.push_literal("; ");

    let srcs_list = record
        .srcs
        .iter()
        .map(|s| format!("(builtins.storePath \"/nix/store/{s}\")"))
        .collect::<Vec<_>>()
        .join(" ");

    format!(
        "let srcs = [ {srcs_list} ]; in\nderivation {{\n  name = \"dyndrv-thunk\";\n  system = builtins.currentSystem;\n  builder = \"/bin/sh\";\n  args = [ \"-c\" {} ];\n  __contentAddressed = true;\n  outputHashMode = \"nar\";\n  outputHashAlgo = \"sha256\";\n  # Referencing `srcs` here (even though the script never reads this\n  # attribute directly -- every path is already inlined as an absolute\n  # string above) is what actually registers each store path as a real\n  # input dependency; a plain string interpolated into `args` alone\n  # carries no context of its own.\n  inherit srcs;\n}}\n",
        script.finish(),
    )
}

/// Renders an absolute filesystem path as a literal Nix PATH
/// expression (`/abs/path`, unquoted -- Nix's own path-literal syntax,
/// distinct from a string) -- what `import` expects as its argument.
/// `thunk_path`s are always absolute already (`resolve_nix_thunk_
/// dependency`'s own `read_link` result, or `write_thunk`'s own
/// `workspace.join(...)` construction), so no relative-path handling
/// is needed here.
fn nix_path_literal(path: &Path) -> String {
    path.display().to_string()
}

/// Builds a Nix double-quoted string literal from a mix of LITERAL
/// text (escaped normally) and raw INTERPOLATION expressions (`${...}`,
/// emitted verbatim, never escaped) -- needed because `record_to_thunk_
/// expr`'s own dependency substitution must emit a REAL Nix
/// interpolation (`${import <path>}`) that the Nix evaluator itself
/// expands, not literal text. Confirmed necessary by direct
/// reproduction: an earlier version of this function ran the WHOLE
/// script string (interpolation syntax included) through a single
/// blanket escape pass at the end, which escaped the interpolation's
/// own `$` into `\$` -- Nix never expands an escaped `\${...}`, so the
/// resulting derivation's builder script contained the LITERAL text
/// `${import ./dep.nix}` instead of the dependency's real realized
/// path, and the builder's own `/bin/sh` failed with "bad
/// substitution" trying to interpret that text as a SHELL variable
/// expansion instead.
struct NixStringBuilder {
    out: String,
}

impl NixStringBuilder {
    fn new() -> Self {
        Self {
            out: String::from("\""),
        }
    }

    fn push_literal(&mut self, s: &str) {
        for c in s.chars() {
            match c {
                '"' => self.out.push_str("\\\""),
                '\\' => self.out.push_str("\\\\"),
                '\n' => self.out.push_str("\\n"),
                // A bare `$` followed by `{` starts a Nix interpolation
                // even inside a literal push (e.g. a `setup_cmd` string
                // that happens to contain literal `${` text, which
                // none of this codebase's own producers generate today,
                // but escaping it defensively costs nothing and avoids
                // a latent injection surface if one ever does).
                '$' => self.out.push_str("\\$"),
                _ => self.out.push(c),
            }
        }
    }

    /// Emits `${<expr>}` verbatim -- `expr` is trusted Nix source text
    /// (a resolved dependency's own absolute path, never user-
    /// controlled argv content), matching `nix_path_literal`'s own
    /// "always absolute, never needs escaping" guarantee.
    fn push_interp(&mut self, expr: &str) {
        self.out.push_str("${");
        self.out.push_str(expr);
        self.out.push('}');
    }

    fn finish(mut self) -> String {
        self.out.push('"');
        self.out
    }
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
