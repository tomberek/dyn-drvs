use crate::record::{Record, SeedFrom};

/// Result of a `toNode`-equivalent decision: either a real invocation to
/// pass through unmodified (`Passthrough`), or a deferred record plus
/// where the record's own resolved output belongs.
pub enum Decision {
    Passthrough,
    Defer {
        record: Record,
        /// Index into `argv` (the REWRITTEN argv the decision function
        /// itself saw) naming the output path -- mirrors `outputArg`.
        output_arg: Option<usize>,
        /// A literal relative path, when no `-o`/positional slot names
        /// it directly -- mirrors `outputPath`.
        output_path: Option<String>,
    },
}

/// Scans argv for any element that's already a real store path (after
/// `wrapper::rewrite_argv_element`'s own pass) and returns their store
/// basenames -- port of `ccToNodeBash`'s `extraStorePaths` scan,
/// generalized to every tool, not just `cc`. Needed so a Record's own
/// `srcs` fully covers every input the record's rendered command line
/// references, not just the toolchain's own package -- confirmed
/// necessary by direct reproduction in `Rpc` mode: `ar`'s own object-
/// file inputs are REAL store paths there (no sandbox stub-chaining to
/// hide behind, unlike `Sandbox` mode where they're still-pending
/// stubs resolved later by `dyndrv-collect`'s own cross-unit wiring),
/// so omitting them from `srcs` produced a real derivation that failed
/// to build ("No such file or directory") the moment anything tried to
/// realize it.
fn extra_store_paths(argv: &[String]) -> Vec<String> {
    let mut out = Vec::new();
    for a in argv {
        // Scans for "/nix/store/" ANYWHERE in the element, not just as a
        // whole-element prefix -- a real argv element can GLUE a store
        // path onto a flag with no space (e.g. `-I/nix/store/...-bzip2-
        // .../include`, confirmed necessary by direct reproduction
        // against a real freetype build: an `.strip_prefix`-only scan
        // missed exactly this, leaving `bzip2-...-dev` out of `srcs` and
        // the eventual compile failing with "bzlib.h: No such file or
        // directory"). Matches the bash oracle's own `grep -o "/nix/
        // store/[^/\"']*"` and `toNode`'s own `builtins.match
        // ".*(...)."` -- both substring scans, not prefix checks.
        let mut rest = a.as_str();
        while let Some(idx) = rest.find("/nix/store/") {
            let after = &rest[idx + "/nix/store/".len()..];
            let basename: String = after
                .chars()
                .take_while(|&c| c != '/' && c != '"' && c != '\'')
                .collect();
            if !basename.is_empty() && !out.contains(&basename) {
                out.push(basename.clone());
            }
            rest = &after[basename.len()..];
        }
    }
    out
}

/// Port of `arToNode` (`mkAcceleratedStdenv.nix`). `ar`'s argv shape is
/// fixed: token 0 is the modifiers string, token 1 the archive path,
/// everything after is a positional object-file input.
///
/// `cwd`: this invocation's own cwd, relative to `NIX_BUILD_TOP` (see
/// `wrapper::invocation_cwd`'s own doc comment) -- `""`/`"."` for the
/// common case (invocation cwd IS the package build root).
pub fn ar_to_node(argv: &[String], real_ar: &str, bintools_basename: &str, cwd: &str) -> Decision {
    // PASSTHROUGH for a diagnostic/version probe -- see `mkAccelerated
    // Stdenv.nix`'s own matching `arToNode`/`isProbe` comment for the
    // full rationale. `ar`'s own real argv shape ALWAYS has at least 2
    // elements; a 1-arg probe (`ar --version`) previously PANICKED here
    // (`argv[0]`/`argv[2..]` out-of-bounds on a 1-element slice) --
    // confirmed necessary by direct reproduction against real meson
    // (dav1d), which runs `ar --version` unconditionally during every
    // native build's `configurePhase`.
    if argv.len() < 2 || argv[0].starts_with('-') {
        return Decision::Passthrough;
    }
    let modifiers = argv[0].clone();
    let mut args_for_ar = vec![modifiers, "$out".to_string()];
    args_for_ar.extend(argv[2..].iter().cloned());

    let mut srcs = vec![bintools_basename.to_string()];
    srcs.extend(extra_store_paths(&argv[2..]));

    Decision::Defer {
        record: Record {
            key: None,
            tool: real_ar.to_string(),
            args: args_for_ar,
            srcs,
            setup_cmd: None,
            chdir: None,
            cwd: normalize_cwd(cwd),
            chained_from: None,
            seed_from: None,
        },
        output_arg: Some(1),
        output_path: None,
    }
}

/// `""`/`"."` (the common case) normalizes to `None`, matching
/// `mkAcceleratedStdenv.nix`'s own `invocationCwd` normalization.
fn normalize_cwd(cwd: &str) -> Option<String> {
    if cwd.is_empty() || cwd == "." {
        None
    } else {
        Some(cwd.to_string())
    }
}

/// Port of `ranlibToNode`. `ranlib`'s only positional argument (the
/// LAST one, tolerating leading flags) is both its input and its own
/// output -- indexes an archive in place.
///
/// `argv[archive_idx]` (BEFORE being overwritten with the `"$out"`
/// sentinel below) names the archive -- either an already-real
/// `/nix/store/...` path (rewritten there by `wrapper::rewrite_argv_
/// element` before this function ever sees it, the common case outside
/// `Sandbox` mode) or an UNRESOLVED dependency reference (a still-
/// pending stub/symlink -- e.g. `Sandbox` mode's own eager path, task
/// #85, where `ar`'s own output is a symlink into a store path that
/// isn't locally `stat`-able yet, or `Sandbox` mode's OLD chainedFrom
/// path, which never rewrites at all). Recorded here via `seed_from`
/// (NOT folded into `args`/`setup_cmd` directly) so each render layer
/// (`render.rs`/`drv.rs`/`drv_thunk.rs`) can resolve it the SAME way it
/// already resolves any other `args` dependency reference -- confirmed
/// necessary by direct reproduction: the ORIGINAL version here only
/// ever special-cased an already-`/nix/store/`-prefixed literal path,
/// silently reducing to a NO-OP `setup_cmd` (`None`) for a standalone,
/// still-unresolved `ranlib` in `Sandbox`'s new eager mode -- the
/// resulting registered derivation had `ranlib $out;` with `$out`
/// completely empty and NO `inputDrvs` edge to the archive's own
/// derivation at all (confirmed via `nix derivation show`: `"inputs":
/// {"drvs":{}}`), silently producing a broken empty archive instead of
/// indexing the real one, rather than failing loudly.
pub fn ranlib_to_node(
    argv: &[String],
    real_ranlib: &str,
    bintools_basename: &str,
    coreutils_basename: &str,
    cwd: &str,
) -> Decision {
    // PASSTHROUGH for a diagnostic/version probe -- see `ar_to_node`'s
    // own matching comment for the full rationale. Unlike `ar`'s
    // version, an empty/probe-only argv here doesn't panic (`argv.len()
    // - 1` on a real, non-empty argv is always in-bounds) -- it would
    // silently MISCLASSIFY the probe's own flag as "the archive path"
    // and defer it. A real "index this archive" invocation always has
    // at least one non-flag positional arg.
    if !argv.iter().any(|a| !a.starts_with('-')) {
        return Decision::Passthrough;
    }
    let archive_idx = argv.len() - 1;
    let real_archive_path = argv[archive_idx].clone();
    let mut args_for_ranlib = argv.to_vec();
    args_for_ranlib[archive_idx] = "$out".to_string();

    let mut srcs = vec![bintools_basename.to_string(), coreutils_basename.to_string()];
    srcs.extend(extra_store_paths(&argv[..archive_idx]));
    // The archive's own store path is excluded from `argv[..archive_idx]`
    // above (its argv SLOT is about to be overwritten with `"$out"` in
    // `args_for_ranlib`, so `extra_store_paths` never sees it there) --
    // but `seed_from`'s own resolved form (see each render layer's own
    // handling) reads it directly, so it must be declared as its own
    // `srcs` entry when it's ALREADY a real store path, or the
    // sandboxed derivation never mounts it at all (confirmed by direct
    // reproduction: `cp: cannot stat '/nix/store/...-liba.a': No such
    // file or directory`). A still-unresolved dependency reference
    // (not yet a `/nix/store/` path) has nothing to declare here --
    // its OWN owning derivation becomes a real `inputDrvs` edge
    // instead, wired by whichever render layer resolves it.
    if real_archive_path.starts_with("/nix/store/") {
        srcs.extend(extra_store_paths(std::slice::from_ref(&real_archive_path)));
    }

    Decision::Defer {
        record: Record {
            key: None,
            tool: real_ranlib.to_string(),
            args: args_for_ranlib,
            srcs,
            setup_cmd: None,
            chdir: None,
            cwd: normalize_cwd(cwd),
            chained_from: None,
            seed_from: Some(SeedFrom {
                from: real_archive_path,
                coreutils_basename: coreutils_basename.to_string(),
            }),
        },
        output_arg: Some(archive_idx),
        output_path: None,
    }
}
