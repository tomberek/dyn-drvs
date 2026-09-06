use crate::record::Record;

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
/// everything after is a positional object-file input. ALWAYS defers --
/// no passthrough case (see that file's own header comment).
pub fn ar_to_node(argv: &[String], real_ar: &str, bintools_basename: &str) -> Decision {
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
            chained_from: None,
        },
        output_arg: Some(1),
        output_path: None,
    }
}

/// Port of `ranlibToNode`. `ranlib`'s only positional argument (the
/// LAST one, tolerating leading flags) is both its input and its own
/// output -- indexes an archive in place.
///
/// `argv[archive_idx]` (BEFORE being overwritten with the `"$out"`
/// sentinel below) is the archive's own real store path -- already
/// rewritten there by `wrapper::rewrite_argv_element` before this
/// function ever sees it. A standalone `ranlib` invocation (no
/// preceding `ar` step in the SAME unit -- the norm outside `Sandbox`
/// mode, since `Rpc`/`Thunk` never chain records the way `finalize_
/// defer`'s `chainedFrom` does) needs a `setup_cmd` seeding `$out`
/// with that real content BEFORE running `ranlib` on it, or `$out`
/// starts empty and `ranlib` fails with "No such file" -- confirmed by
/// direct reproduction against a real `nix develop`-style `Rpc`-mode
/// devShell session: `ar cr liba.a a.o; ranlib liba.a` as two
/// independent, non-chained invocations left `ranlib`'s own registered
/// derivation running `ranlib $out;` with nothing ever populating
/// `$out` at all. Mirrors `cc`'s own `setup_cmd` convention (`cp -r
/// <tree>/. . && chmod -R u+w . &&`) — same "prepare real content
/// before the tool runs" shape, just a single-file `cp` instead of a
/// tree copy.
pub fn ranlib_to_node(
    argv: &[String],
    real_ranlib: &str,
    bintools_basename: &str,
    coreutils_basename: &str,
) -> Decision {
    let archive_idx = argv.len() - 1;
    let real_archive_path = argv[archive_idx].clone();
    let mut args_for_ranlib = argv.to_vec();
    args_for_ranlib[archive_idx] = "$out".to_string();

    let mut srcs = vec![bintools_basename.to_string(), coreutils_basename.to_string()];
    srcs.extend(extra_store_paths(&argv[..archive_idx]));
    // The archive's own store path is excluded from `argv[..archive_idx]`
    // above (its argv SLOT is about to be overwritten with `"$out"` in
    // `args_for_ranlib`, so `extra_store_paths` never sees it there) --
    // but the NEW `setup_cmd` below reads it directly, so it must be
    // declared as its own `srcs` entry, or the sandboxed derivation
    // never mounts it at all (confirmed by direct reproduction: `cp:
    // cannot stat '/nix/store/...-liba.a': No such file or directory`).
    srcs.extend(extra_store_paths(std::slice::from_ref(&real_archive_path)));

    let setup_cmd = if real_archive_path.starts_with("/nix/store/") {
        // `chmod u+w` AFTER the `cp`, not before -- mirrors `cc`'s own
        // `setup_cmd` convention (`cp -r ... && chmod -R u+w . &&`) for
        // the identical reason: `cp` preserves the read-only Nix store
        // source's permissions on the destination, so `ranlib` (which
        // modifies the archive IN PLACE) fails outright without this
        // ("unable to copy file '...'; reason: Permission denied" --
        // confirmed by direct reproduction).
        Some(format!(
            "/nix/store/{coreutils_basename}/bin/cp {} $out && \
             /nix/store/{coreutils_basename}/bin/chmod u+w $out && ",
            crate::render::shell_quote(&real_archive_path)
        ))
    } else {
        None
    };

    Decision::Defer {
        record: Record {
            key: None,
            tool: real_ranlib.to_string(),
            args: args_for_ranlib,
            srcs,
            setup_cmd,
            chained_from: None,
        },
        output_arg: Some(archive_idx),
        output_path: None,
    }
}
