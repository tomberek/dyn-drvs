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
        if let Some(rest) = a.strip_prefix("/nix/store/") {
            if let Some(basename) = rest.split('/').next() {
                let basename = basename.to_string();
                if !out.contains(&basename) {
                    out.push(basename);
                }
            }
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
pub fn ranlib_to_node(argv: &[String], real_ranlib: &str, bintools_basename: &str) -> Decision {
    let archive_idx = argv.len() - 1;
    let mut args_for_ranlib = argv.to_vec();
    args_for_ranlib[archive_idx] = "$out".to_string();

    let mut srcs = vec![bintools_basename.to_string()];
    srcs.extend(extra_store_paths(&argv[..archive_idx]));

    Decision::Defer {
        record: Record {
            key: None,
            tool: real_ranlib.to_string(),
            args: args_for_ranlib,
            srcs,
            setup_cmd: None,
            chained_from: None,
        },
        output_arg: Some(archive_idx),
        output_path: None,
    }
}
