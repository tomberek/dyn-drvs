use crate::record::Record;
use crate::tonode::Decision;

fn basename(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

fn strip_last_ext(base: &str) -> &str {
    match base.rfind('.') {
        Some(idx) if idx > 0 => &base[..idx],
        _ => base,
    }
}

fn is_conftest(path: &str) -> bool {
    basename(path).starts_with("conftest")
}

/// Port of `ccToNodeBash`'s own `dyndrv_env_prefix` computation
/// (`mkAcceleratedStdenv.nix`) -- see that file's own header comment
/// for the full rationale (nixpkgs' cc-wrapper/bintools-wrapper setup
/// hooks inject extra compiler flags, e.g. boost's own `-isystem`, via
/// ENV VARS populated from `buildInputs`, not literal argv -- these
/// vanish for a registered derivation whose `env` only ever has
/// `{out: ...}` unless explicitly captured here and re-exported).
/// This binary execs directly in place of `cc` (unlike the bash
/// wrapper script, no separate process boundary), so it already
/// inherits the SAME ambient environment a real, unaccelerated compile
/// would see -- `std::env::vars()` reads it directly, no plumbing
/// through `compiledEnv` needed. Same allowlist regex as the bash
/// oracle, kept as an explicit name list here (matching Rust's own
/// idiom elsewhere in this codebase -- no regex dependency) rather
/// than a literal regex port.
fn capture_wrapper_env() -> String {
    const PREFIXES: &[&str] = &[
        "NIX_CFLAGS_COMPILE_BEFORE",
        "NIX_CFLAGS_COMPILE",
        "NIX_CFLAGS_LINK",
        "NIX_LDFLAGS_BEFORE",
        "NIX_LDFLAGS",
        "NIX_CXXSTDLIB_COMPILE",
        "NIX_CXXSTDLIB_LINK",
        "NIX_DYNAMIC_LINKER",
        "NIX_HARDENING_ENABLE",
        "NIX_ENFORCE_NO_NATIVE",
        "NIX_ENFORCE_PURITY",
    ];
    let mut out = String::new();
    for (name, value) in std::env::vars() {
        // Matches a PREFIX exactly (the bare, non-target-suffixed
        // form) OR that prefix followed by `_<salt>` (the target-
        // suffixed form, e.g. `NIX_CFLAGS_COMPILE_x86_64_unknown_
        // linux_gnu`) -- mirrors the bash oracle's own
        // `(_[A-Za-z0-9_]+)?$` suffix.
        let matches = PREFIXES.iter().any(|p| {
            name == *p || name.strip_prefix(p).is_some_and(|rest| rest.starts_with('_'))
        });
        if matches {
            out.push_str(&format!(" export {name}={};", crate::render::shell_quote(&value)));
        }
    }
    out
}

/// Scans argv for any element that's already a real store path and
/// returns their store basenames -- port of `ccToNodeBash`'s
/// `extraStorePaths`. Shared with `ar_to_node`/`ranlib_to_node` (see
/// `tonode.rs`'s own copy) -- kept as a free function there rather
/// than exported, since this file needs its own copy anyway to avoid
/// a circular module dependency; a shared `util` module would be the
/// natural home if a third caller ever needs it.
fn extra_store_paths(argv: &[String]) -> Vec<String> {
    let mut out = Vec::new();
    for a in argv {
        // Substring scan, not a whole-element prefix check -- a real
        // argv element can GLUE a store path onto a flag with no space
        // (e.g. `-I/nix/store/...-bzip2-.../include`, confirmed
        // necessary by direct reproduction against a real freetype
        // build: a `.strip_prefix`-only scan missed exactly this,
        // leaving `bzip2-...-dev` out of `srcs` and the eventual
        // compile failing with "bzlib.h: No such file or directory").
        // Matches the bash oracle's own `grep -o "/nix/store/[^/\"']*"`
        // and `toNode`'s own `builtins.match ".*(...)."` -- both
        // substring scans, not prefix checks.
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

/// Port of `ccToNodeBash` (`mkAcceleratedStdenv.nix`) -- byte-for-byte
/// the same decision logic (probe detection, implicit-output naming,
/// `-o` replacement, extra-store-path scanning, batch-key lookup),
/// operating on the RAW/relative argv `wrapCommand.nix`'s own
/// `discoverTree`-mode wrapper script passes through unmodified (see
/// that file's header comment: `discoverTree` mode never rewrites argv
/// to store paths the way the plain variant does, since that would
/// destroy the relative directory structure `-I` flags depend on).
///
/// `tree_basename`: the ALREADY-STAGED store basename covering every
/// source/header this invocation needs (computed by the CALLER before
/// this function runs, via `discover_tree`'s own scan + staging --
/// mirrors `DYNDRV_TREE_BASENAME`, but passed as a plain argument here
/// instead of an env var since this binary controls both sides of that
/// boundary itself, no env var indirection needed).
/// `tree_up_depth`: the nested "cwd" depth `wrapper::stage_tree` staged
/// the tree at for THIS invocation (see that function's own doc
/// comment) -- `0` for the common case (no leading `../` among this
/// invocation's own paths). Baked into `Record::chdir` below so the
/// eventual builder runs this compile from the matching nested
/// position, where its own unchanged relative argv (e.g. `../hash.cc`)
/// resolves correctly.
/// `batch_groups`: `{ <relative-source-path> = <group-key> }`, mirrors
/// `DYNDRV_BATCH_GROUPS`.
pub fn cc_to_node(
    argv: &[String],
    real_cc: &str,
    coreutils_basename: &str,
    stdenv_cc_basename: &str,
    tree_basename: &str,
    tree_up_depth: usize,
    batch_groups: &std::collections::HashMap<String, String>,
) -> Decision {
    let has_compile_flag = argv.iter().any(|a| a == "-c");

    // `out_idx`: -1 sentinel (bash convention, preserved exactly --
    // see this function's own module-level note on why `out_idx + 1`
    // matters even when out_idx is -1).
    let out_idx: i64 = argv
        .iter()
        .position(|a| a == "-o")
        .map(|i| i as i64)
        .unwrap_or(-1);

    // `firstSourceIdx`: first non-flag arg that isn't `-o`'s own
    // value. NOTE: this exclusion check is UNCONDITIONAL in the
    // original bash (`ccToNodeBash`) -- when `out_idx == -1`,
    // `out_idx + 1 == 0`, so index 0 is excluded from candidacy even
    // though no `-o` is present at all. This is a preserved quirk of
    // the bash sentinel arithmetic, not a Rust-specific choice --
    // confirmed by direct reading of `ccToNodeBash`'s own loop, which
    // has NO `[ "$out_idx" != -1 ]` guard on this particular check
    // (unlike `out_val`'s computation, which IS guarded). Kept
    // byte-identical rather than "fixed," since this function's whole
    // purpose is matching the proven-correct bash oracle exactly.
    let first_source_idx: i64 = argv
        .iter()
        .enumerate()
        .find(|(i, a)| !a.starts_with('-') && *i as i64 != out_idx + 1)
        .map(|(i, _)| i as i64)
        .unwrap_or(-1);

    let source_path: Option<&str> = if first_source_idx != -1 {
        Some(argv[first_source_idx as usize].as_str())
    } else {
        None
    };
    let out_val: Option<&str> = if out_idx != -1 {
        argv.get((out_idx + 1) as usize).map(String::as_str)
    } else {
        None
    };

    let implicit_output = if !has_compile_flag {
        Some("a.out".to_string())
    } else {
        source_path.map(|sp| {
            let base = basename(sp);
            format!("{}.o", strip_last_ext(base))
        })
    };

    let batch_key: Option<String> = if has_compile_flag {
        source_path.and_then(|sp| batch_groups.get(sp).cloned())
    } else {
        None
    };

    let mut is_probe = source_path.is_some_and(is_conftest);
    if let Some(ov) = out_val {
        if is_conftest(ov) {
            is_probe = true;
        }
    }

    let mut has_object_or_archive = false;
    let mut has_positional = false;
    for (i, a) in argv.iter().enumerate() {
        if a.starts_with('-') {
            continue;
        }
        // Same unconditional `i == out_idx + 1` exclusion as
        // `first_source_idx` above -- see that binding's own comment.
        if i as i64 == out_idx + 1 {
            continue;
        }
        has_positional = true;
        if a.ends_with(".o") || a.ends_with(".a") || a.ends_with(".so") {
            has_object_or_archive = true;
        }
        if is_conftest(a) {
            is_probe = true;
        }
    }

    let is_real_link = !has_compile_flag && has_object_or_archive;
    if !has_compile_flag && !is_real_link && has_positional {
        is_probe = true; // isCompileToExecutableProbe
    }
    if !has_compile_flag && !is_real_link && !has_positional {
        is_probe = true; // isInfoQuery
    }

    if is_probe {
        return Decision::Passthrough;
    }
    // PASSTHROUGH: a compile whose source is still an absolute path
    // after `wrapCommand`'s own `stripPwdPrefix` pass.
    if has_compile_flag {
        if let Some(sp) = source_path {
            if sp.starts_with('/') {
                return Decision::Passthrough;
            }
        }
    }
    if out_idx == -1 && implicit_output.is_none() {
        return Decision::Passthrough;
    }

    // `argvForCc`: replace the EXISTING "-o"'s value with the literal
    // sentinel "$out" in place (GUARDED on `out_idx != -1` here,
    // matching the bash version's own guard on this specific
    // computation -- unlike the two exclusion checks above, this one
    // IS conditional in the original), or append "-o $out" if there
    // was none.
    let mut args_for_cc: Vec<String> = argv
        .iter()
        .enumerate()
        .map(|(i, a)| {
            if out_idx != -1 && i as i64 == out_idx + 1 {
                "$out".to_string()
            } else {
                a.clone()
            }
        })
        .collect();
    if out_idx == -1 {
        args_for_cc.push("-o".to_string());
        args_for_cc.push("$out".to_string());
    }

    let mut srcs = vec![
        coreutils_basename.to_string(),
        stdenv_cc_basename.to_string(),
        tree_basename.to_string(),
    ];
    srcs.extend(extra_store_paths(argv));

    let setup_cmd = format!(
        "{env_prefix}/nix/store/{coreutils_basename}/bin/cp -r /nix/store/{tree_basename}/. . && \
         /nix/store/{coreutils_basename}/bin/chmod -R u+w . &&",
        env_prefix = capture_wrapper_env(),
    );

    // See `wrapper::stage_tree`'s own doc comment on `DYNDRV_TREE_UP_
    // DIR_NAME`/nesting -- the SAME nested-position string, here for
    // the compiled-shim code path instead of bash.
    let chdir = if tree_up_depth == 0 {
        None
    } else {
        Some(format!("{}/", crate::wrapper::DYNDRV_TREE_UP_DIR_NAME).repeat(tree_up_depth))
    };

    let record = Record {
        key: batch_key,
        tool: real_cc.to_string(),
        args: args_for_cc,
        srcs,
        setup_cmd: Some(setup_cmd),
        chdir,
        chained_from: None,
        seed_from: None,
    };

    if out_idx != -1 {
        Decision::Defer {
            record,
            output_arg: Some((out_idx + 1) as usize),
            output_path: None,
        }
    } else {
        Decision::Defer {
            record,
            output_arg: None,
            output_path: implicit_output,
        }
    }
}

/// Port of `discoverTree`'s own header-discovery scan: given the
/// ORIGINAL argv, runs a real `cc -M -MG` dependency scan (tolerant of
/// not-yet-generated headers) and returns every RELATIVE header path
/// this compile needs beyond what argv already names directly. Strips
/// `-c`/`-o <file>`/`-MF`/`-MT`/`-MQ`/`-MMD`/`-MD`/`-MP` first (this is
/// a dependency scan, not a real compile) -- see `mkAcceleratedStdenv
/// .nix`'s own `discoverTree` header comment for the full rationale
/// (leaving `-MF <file>` in place would redirect the scan's own output
/// into that file instead of stdout, silently discovering nothing).
pub fn discover_tree(argv: &[String], real_cc: &str) -> Vec<String> {
    let mut filtered = Vec::new();
    let mut skip_next = false;
    for a in argv {
        if skip_next {
            skip_next = false;
            continue;
        }
        match a.as_str() {
            "-c" | "-MMD" | "-MD" | "-MP" => continue,
            "-o" | "-MF" | "-MT" | "-MQ" => {
                skip_next = true;
                continue;
            }
            _ => filtered.push(a.clone()),
        }
    }

    let out = std::process::Command::new(real_cc)
        .args(&filtered)
        .args(["-M", "-MG"])
        .output();
    let Ok(out) = out else {
        return Vec::new();
    };
    let stdout = String::from_utf8_lossy(&out.stdout);
    // Strip backslash line-continuations, split on whitespace, drop the
    // first token (the "<target>.o:" prefix cc -M always emits first).
    let no_backslash = stdout.replace('\\', "");
    let mut tokens: Vec<&str> = no_backslash.split_whitespace().collect();
    if !tokens.is_empty() {
        tokens.remove(0);
    }
    tokens
        .into_iter()
        .filter(|t| !t.is_empty())
        .map(String::from)
        .collect()
}
