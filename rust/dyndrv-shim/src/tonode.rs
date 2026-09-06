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

/// Port of `arToNode` (`mkAcceleratedStdenv.nix`). `ar`'s argv shape is
/// fixed: token 0 is the modifiers string, token 1 the archive path,
/// everything after is a positional object-file input. ALWAYS defers --
/// no passthrough case (see that file's own header comment).
pub fn ar_to_node(argv: &[String], real_ar: &str, bintools_basename: &str) -> Decision {
    let modifiers = argv[0].clone();
    let mut args_for_ar = vec![modifiers, "$out".to_string()];
    args_for_ar.extend(argv[2..].iter().cloned());

    Decision::Defer {
        record: Record {
            key: None,
            tool: real_ar.to_string(),
            args: args_for_ar,
            srcs: vec![bintools_basename.to_string()],
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

    Decision::Defer {
        record: Record {
            key: None,
            tool: real_ranlib.to_string(),
            args: args_for_ranlib,
            srcs: vec![bintools_basename.to_string()],
            setup_cmd: None,
            chained_from: None,
        },
        output_arg: Some(archive_idx),
        output_path: None,
    }
}
