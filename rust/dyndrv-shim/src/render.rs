use crate::collect::Stub;
use crate::record::Record;
use std::collections::{BTreeMap, HashMap};

/// Single-quotes a string for safe embedding in a `/bin/sh -c` command
/// line -- port of `dyndrv_sq`/`mkAcceleratedStdenv.nix`'s `shellQuote`.
pub fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// Renders ONE record into its own `(setup_fragment, cmd_line_fragment)`
/// pair -- the single shared atomic unit every one of dyndrv's script-
/// construction call sites (`render_member` below, `drv.rs::
/// record_to_derivation`, `drv_thunk.rs::write_drv_thunk`, `group.rs::
/// append_member`) now builds a derivation's builder script from,
/// instead of each independently re-implementing this same setup_cmd/
/// seed_from/tool-args/`"; "` pattern. Confirmed necessary by direct
/// reproduction (`cross_mode_check.rs`): a mismatched trailing `"; "`
/// between two of these call sites' own hand-written copies produced
/// two DIFFERENT ATerm byte strings for the logically-identical
/// single-record case -- unifying the construction into one function
/// makes that class of divergence a compile-time impossibility rather
/// than something a test has to keep re-confirming.
///
/// `own_out_var`: the literal token (`"$out"` for a solo derivation or
/// a chain's own single output, `"$<outputName>"` for a merged
/// group/unit member) this record's own `"$out"` sentinel -- and, if
/// `apply_seed_from`, its `seed_from`'s destination -- resolves to.
///
/// `apply_seed_from`: whether THIS record's own `seed_from` (if any)
/// should render its `cp`/`chmod` prelude. `false` for a chained
/// record that isn't the chain's first step -- see `render_member`'s
/// own per-chain-step call for why a CHAINED `ranlib` following `ar`
/// at the same output path needs no seeding at all (the preceding
/// chain step already populated `own_out_var`). Every OTHER caller
/// here renders exactly one record with no chain, so always passes
/// `true`.
///
/// `resolve_ref`: given a non-`"$out"` arg element (or a `seed_from`
/// reference), returns the token to substitute if it names a known
/// dependency, else `None` (falls through to a shell-quoted literal).
/// Each caller supplies its own resolution strategy (a `HashMap`
/// lookup + `Placeholder::ca_output` render for the three single-record
/// callers, `render_unit`'s own same-unit-vs-cross-unit closure for
/// `render_member`) but this function only ever sees the already-
/// resolved token string, never the resolution mechanism itself.
pub fn render_record_line<F>(
    record: &Record,
    own_out_var: &str,
    apply_seed_from: bool,
    mut resolve_ref: F,
) -> (String, String)
where
    F: FnMut(&str) -> Option<String>,
{
    let mut setup = String::new();
    if let Some(s) = &record.setup_cmd {
        setup.push_str(s);
    }
    if apply_seed_from {
        if let Some(seed) = &record.seed_from {
            let source_token = resolve_ref(&seed.from).unwrap_or_else(|| seed.from.clone());
            setup.push_str(&format!(
                "/nix/store/{cu}/bin/cp {} {out} && /nix/store/{cu}/bin/chmod u+w {out} && ",
                shell_quote(&source_token),
                cu = seed.coreutils_basename,
                out = own_out_var,
            ));
        }
    }

    let mut cmd_line = String::new();
    // `record.chdir` (see `record.rs`'s own doc comment on why this is
    // a SEPARATE field, not baked into `setup_cmd` as a bare `cd`):
    // wraps ONLY this record's own `tool $args` invocation in a
    // `( cd ... && ... )` subshell, so a merged unit's LATER member's
    // own `setup_cmd` (its `cp -r`, run in the shared, unmodified build
    // root) is never affected by an EARLIER member's nested cwd -- the
    // subshell's own cwd change is invisible outside it. Port of
    // `collectStubs.nix`'s own identical `dyndrv_render_member` fix.
    if let Some(chdir) = &record.chdir {
        cmd_line.push_str("( cd ");
        cmd_line.push_str(&shell_quote(chdir));
        cmd_line.push_str(" && ");
    }
    cmd_line.push_str(&record.tool);
    for a in &record.args {
        cmd_line.push(' ');
        // The literal sentinel "$out" must stay UNQUOTED so the
        // builder's own shell expands it -- confirmed by direct
        // reproduction: quoting it (`'$out'`) makes `/bin/sh -c` pass
        // the literal three-character string through unexpanded, so
        // the builder wrote to a file actually named `$out` instead of
        // the real output path.
        if a == "$out" {
            cmd_line.push_str(own_out_var);
        } else if let Some(token) = resolve_ref(a) {
            cmd_line.push_str(&token);
        } else {
            cmd_line.push_str(&shell_quote(a));
        }
    }
    if record.chdir.is_some() {
        cmd_line.push_str(" )");
    }
    cmd_line.push_str("; ");

    (setup, cmd_line)
}

/// Renders one unit's combined script -- port of `dyndrv_render_member`
/// applied to every member, then concatenated (Phase 7's own per-unit
/// loop). `own_out_var` maps a stub path to the literal token
/// (`"$out"` for a solo unit, `"$<outputName>"` for a merged member) its
/// own args' "$out" sentinel resolves to.
///
/// `resolve_ref`: given an argv element that names another discovered
/// stub, returns the token to substitute -- `$<outputName>` for a
/// fellow member of the SAME unit, or the already-known real
/// cross-unit placeholder string for a stub in a DIFFERENT unit
/// (computed by the caller via `Placeholder::ca_output`, since Rust
/// has the dependency's real, already-registered `StorePath` in hand
/// by the time a later unit renders -- no string-sentinel indirection
/// needed here, unlike the bash version's two-pass sentinel-substitute
/// scheme).
pub fn render_member<F>(
    stub: &Stub,
    own_out_var: &str,
    mut resolve_ref: F,
) -> (String, String, Vec<String>)
where
    F: FnMut(&str) -> Option<String>,
{
    let mut setup_cmd = String::new();
    let mut cmd_line = String::new();
    let mut srcs = Vec::new();

    for (i, rec) in stub.chain.iter().enumerate() {
        srcs.extend(rec.srcs.iter().cloned());

        // Wraps `resolve_ref` so it's called with THIS record's own arg
        // joined against its own `cwd` (already normalized to
        // `build_root`-relative by `collect::discover_stubs` -- see
        // that function's own doc comment), not the raw text --
        // reconciles a link step's own `args` (relative to ITS cwd)
        // with an earlier compile step's own discovered stub path
        // (relative to `build_root`), mirroring `collectStubs.nix`'s
        // own identical join. Scoped to THIS caller (`render_unit`'s
        // own `unit_of`/self-reference lookups all expect a `build_
        // root`-relative key) rather than folded into `render_record_
        // line` itself, which is ALSO called by `drv.rs`/`drv_thunk.rs`/
        // `group.rs` -- those callers' own `deps` maps are keyed by raw
        // argv text (resolved via `stub::read_pending_symlink`, not a
        // `build_root`-relative discovery pass), so joining there would
        // corrupt an already-correct lookup.
        let rec_cwd = rec.cwd.as_deref().unwrap_or("");
        let joined_resolve_ref = |a: &str| resolve_ref(&crate::collect::join_rel(rec_cwd, a));

        // A `seed_from` reference (`ranlib_to_node`'s own "index this
        // archive in place" need) only applies to a STANDALONE,
        // non-chained invocation -- i.e. this is the FIRST record in
        // the chain. A CHAINED `ranlib` following `ar` at the SAME
        // output path needs no seeding at all: the chain's own
        // preceding member already populated `own_out_var` moments
        // earlier in THIS combined script, and (confirmed by direct
        // reproduction) `seed.from` in that exact case is the stub's
        // OWN self-referential relative-path text (rewrite_argv_element
        // leaves it untouched, since the archive is itself still-
        // pending at rewrite time) -- resolving it via `resolve_ref`
        // would wrongly substitute a per-member output token
        // (`$<sanitized-name>`) that's never actually set as an env var
        // for a solo unit's own `$out`.
        let (setup, cmd) = render_record_line(rec, own_out_var, i == 0, joined_resolve_ref);
        setup_cmd.push_str(&setup);
        cmd_line.push_str(&cmd);
    }

    (setup_cmd, cmd_line, srcs)
}

/// Builds the record args-derived reference: given a unit's own members
/// and their assigned output names, resolves a fellow-member reference
/// to `$<outputName>` -- port of the "same unit" branch of
/// `dyndrv_render_member`'s ref resolution.
pub fn member_ref_token(output_name: &str) -> String {
    format!("${output_name}")
}

/// Full per-unit render, folding every member's own `render_member`
/// output together -- port of Phase 7's per-unit loop
/// (`_dcs_memberList` handling for both the solo and merged cases).
pub struct UnitRender {
    pub combined_script: String,
    pub srcs: Vec<String>,
    /// `output_name -> stub path` for this unit's own members (one entry
    /// for a solo unit's "out", one per member for a merged unit).
    pub outputs: Vec<(String, String)>,
}

pub fn render_unit<F>(
    members: &[String],
    stubs: &BTreeMap<String, Stub>,
    output_name_of_stub: &HashMap<String, String>,
    mut resolve_cross_unit: F,
    unit_of: &HashMap<String, String>,
    this_unit: &str,
) -> UnitRender
where
    F: FnMut(&str) -> Option<String>,
{
    let is_solo = members.len() == 1;
    let mut combined_script = String::new();
    let mut all_srcs = Vec::new();
    let mut outputs = Vec::new();

    for p in members {
        let stub = &stubs[p];
        let own_out_var = if is_solo {
            "$out".to_string()
        } else {
            member_ref_token(&output_name_of_stub[p])
        };
        let (setup, cmd, srcs) = render_member(stub, &own_out_var, |a| {
            // `a == p`: this argv element is a REFERENCE TO THIS SAME
            // MEMBER'S OWN OUTPUT PATH (e.g. `-MQ <objpath>` alongside
            // `-o <objpath>`, both naming the identical real path --
            // ninja/meson generate this pair directly, no `"$out"`
            // sentinel involved) -- confirmed by direct reproduction
            // against a real meson build (NixOS/nix's own `nix-util`
            // component, via the bash `collectStubs.nix` equivalent of
            // this exact function): a compile's own output path is
            // ITSELF a discovered stub the moment its `.o` gets
            // written, so without this check the generic `unit_of`
            // lookup below matches it and returns the MERGED-unit
            // member-reference form even for a SOLO unit, where
            // `$out` is never bound under that sanitized name at all.
            // Checked BEFORE the generic same-unit lookup, which would
            // otherwise match this exact case first (correctly, by
            // coincidence, for a merged unit -- `own_out_var` already
            // equals what that lookup would return there -- but wrong
            // for a solo unit, where they differ).
            if a == p {
                return Some(own_out_var.clone());
            }
            if let Some(du) = unit_of.get(a) {
                if du == this_unit {
                    return Some(member_ref_token(&output_name_of_stub[a]));
                }
            }
            resolve_cross_unit(a)
        });
        combined_script.push_str(&setup);
        combined_script.push_str(&cmd);
        all_srcs.extend(srcs);
        outputs.push((
            if is_solo {
                "out".to_string()
            } else {
                output_name_of_stub[p].clone()
            },
            p.clone(),
        ));
    }

    all_srcs.sort();
    all_srcs.dedup();

    UnitRender {
        combined_script,
        srcs: all_srcs,
        outputs,
    }
}

/// Recovers `cross_mode_check.rs` (a one-off dev-time diff tool, run
/// once, never checked into the repo -- see `docs/rust-status.md`'s
/// "Cross-mode substitution" section for the mismatch it originally
/// caught) as a PERMANENT regression suite: feeds the same synthetic
/// `Record` shapes through `drv.rs::record_to_derivation` (`Rpc`
/// mode's own construction) and through this module's `render_member`
/// (`Sandbox` mode's, via `dyndrv-collect`'s solo-unit path) and
/// asserts the two produce byte-identical ATerm.
///
/// Now that both paths delegate to the ONE shared `render_record_line`
/// (see that function's own doc comment), these assertions are
/// expected to hold structurally rather than by coincidence -- this
/// module exists so a FUTURE change that reintroduces per-call-site
/// divergence (e.g. a new field added to only one of the four render
/// call sites) is caught by `cargo test`, not by another one-off
/// script someone has to remember to write and run by hand.
#[cfg(test)]
mod cross_mode_tests {
    use crate::collect::Stub;
    use crate::record::{Record, SeedFrom};
    use crate::render::{render_member, render_record_line};
    use harmonia_store_aterm::print_derivation_aterm;
    use harmonia_store_content_address::ContentAddressMethodAlgorithm;
    use harmonia_store_derivation::derivation::{Derivation, DerivationOutput};
    use harmonia_store_derivation::derived_path::{OutputName, SingleDerivedPath};
    use harmonia_store_derivation::placeholder::Placeholder;
    use harmonia_store_path::{StoreDir, StorePath};
    use std::collections::HashMap;

    fn out_name() -> OutputName {
        "out".parse().unwrap()
    }

    /// A representative already-registered dependency, for cases that
    /// exercise `deps`-based cross-reference resolution (an `ar`/
    /// `ranlib` positional arg that's really an earlier compile's own
    /// drv). The hash is an arbitrary, syntactically valid nix32 store
    /// hash -- its own VALUE doesn't matter, only that both render
    /// paths resolve the SAME dependency arg to the SAME placeholder.
    fn dummy_dep() -> (StorePath, OutputName) {
        (
            StorePath::from_base_path("00ljmhbmf3d12aq4l5l7yr7bxn03yqvv-main.o.drv").unwrap(),
            out_name(),
        )
    }

    /// Builds the `Rpc`-side `Derivation` for `record`, via
    /// `drv.rs::record_to_derivation` -- the exact function `rpc_tail.rs`
    /// calls in a real devShell registration.
    fn rpc_side(record: &Record, deps: &HashMap<String, (StorePath, OutputName)>) -> Vec<u8> {
        let drv = crate::drv::record_to_derivation(record, "cross-mode-check", deps).unwrap();
        print_derivation_aterm(&StoreDir::default(), &drv)
    }

    /// Builds the `Sandbox`-side `Derivation` for `record`, via THIS
    /// module's `render_member` (a single-record, unchained `Stub`) --
    /// the exact function `dyndrv-collect.rs`'s Phase 7 calls for a
    /// real solo unit. Deliberately reconstructs the surrounding
    /// `Derivation` (env/outputs/inputs) by hand here rather than
    /// calling `dyndrv-collect.rs`'s own Phase-7 code directly, since
    /// that logic isn't exposed as a library function -- this mirrors
    /// what `dyndrv-collect.rs` itself does closely enough (same
    /// `render_member` call, same env/outputs/inputs shape) to be a
    /// faithful stand-in, and keeps this test from needing a 5th
    /// generalized entry point solely for its own sake.
    fn sandbox_side(record: &Record, deps: &HashMap<String, (StorePath, OutputName)>) -> Vec<u8> {
        let stub = Stub {
            chain: vec![record.clone()],
            key: None,
            deps: Vec::new(),
            eager_drv: None,
        };
        let (setup, cmd, srcs) = render_member(&stub, "$out", |a| {
            let (dep_drv_path, dep_out_name) = deps.get(a)?;
            Some(
                Placeholder::ca_output(dep_drv_path, dep_out_name)
                    .render()
                    .to_string_lossy()
                    .into_owned(),
            )
        });
        let mut script = setup;
        script.push_str(&cmd);

        let mut drv = Derivation::new(
            "cross-mode-check".parse().unwrap(),
            bytes::Bytes::from_static(b"x86_64-linux"),
            bytes::Bytes::from_static(b"/bin/sh"),
        );
        drv.args = vec![
            bytes::Bytes::from_static(b"-c"),
            bytes::Bytes::copy_from_slice(script.as_bytes()),
        ];
        let ph = Placeholder::standard_output(&out_name()).render();
        drv.env.insert(
            bytes::Bytes::from_static(b"out"),
            bytes::Bytes::copy_from_slice(ph.as_os_str().as_encoded_bytes()),
        );
        drv.outputs.insert(
            out_name(),
            DerivationOutput::CAFloating(ContentAddressMethodAlgorithm::NixArchive(
                harmonia_utils_hash::Algorithm::SHA256,
            )),
        );
        for src_basename in &srcs {
            if let Ok(sp) = StorePath::from_base_path(src_basename) {
                drv.inputs.insert(SingleDerivedPath::Opaque(sp));
            }
        }
        for (dep_drv_path, dep_out_name) in deps.values() {
            drv.inputs.insert(SingleDerivedPath::Built {
                drv_path: std::sync::Arc::new(SingleDerivedPath::Opaque(dep_drv_path.clone())),
                output: dep_out_name.clone(),
            });
        }

        print_derivation_aterm(&StoreDir::default(), &drv)
    }

    /// The exact shape that first caught the missing-trailing-`"; "`
    /// bug this whole test module exists to guard against: a plain
    /// compile-shaped record, no `deps`, no `seed_from` -- the simplest
    /// case, and (per `docs/rust-status.md`'s own account) the ONE case
    /// that happened to still match even with the bug present, since a
    /// solo unchained record's own missing trailing separator has
    /// nothing after it to misalign. Kept as a baseline, not because
    /// it's the interesting case on its own.
    #[test]
    fn solo_record_matches() {
        let record = Record {
            key: None,
            tool: "/nix/store/xxx-gcc/bin/cc".to_string(),
            args: vec!["-c".to_string(), "main.c".to_string(), "-o".to_string(), "$out".to_string()],
            srcs: vec!["xxx-gcc".to_string()],
            setup_cmd: None,
            chdir: None,
            cwd: None,
            chained_from: None,
            seed_from: None,
        };
        let deps = HashMap::new();
        assert_eq!(rpc_side(&record, &deps), sandbox_side(&record, &deps));
    }

    /// A record referencing an earlier dependency's own drv (the `ar`
    /// case: `.o` positional args that are really other compiles'
    /// outputs) -- exercises the `resolve_ref`/`deps`-lookup branch
    /// both `record_to_derivation` and `render_member`'s caller-supplied
    /// closure share via `render_record_line`.
    #[test]
    fn record_with_dep_reference_matches() {
        let (dep_path, dep_out) = dummy_dep();
        let record = Record {
            key: None,
            tool: "/nix/store/xxx-binutils/bin/ar".to_string(),
            args: vec![
                "rcs".to_string(),
                "$out".to_string(),
                "main.o.drv".to_string(),
            ],
            srcs: vec!["xxx-binutils".to_string()],
            setup_cmd: None,
            chdir: None,
            cwd: None,
            chained_from: None,
            seed_from: None,
        };
        let mut deps = HashMap::new();
        deps.insert("main.o.drv".to_string(), (dep_path, dep_out));
        assert_eq!(rpc_side(&record, &deps), sandbox_side(&record, &deps));
    }

    /// A standalone (unchained) record with `seed_from` set -- the
    /// `ranlib`-shaped case: `$out` must be seeded via `cp`/`chmod`
    /// BEFORE the tool line runs. This is the shape `ranlib_to_node`
    /// produces for a solo, non-chained `ranlib` invocation (the ONLY
    /// caller of `seed_from` today) -- both `record_to_derivation` and
    /// `render_member` (called with `apply_seed_from = true` for a
    /// chain's first/only record) must render the identical `cp && ...
    /// chmod && ...` prelude.
    #[test]
    fn standalone_seed_from_matches() {
        let (dep_path, dep_out) = dummy_dep();
        let record = Record {
            key: None,
            tool: "/nix/store/xxx-binutils/bin/ranlib".to_string(),
            args: vec!["$out".to_string()],
            srcs: vec!["xxx-binutils".to_string()],
            setup_cmd: None,
            chdir: None,
            cwd: None,
            chained_from: None,
            seed_from: Some(SeedFrom {
                from: "archive.a.drv".to_string(),
                coreutils_basename: "yyy-coreutils".to_string(),
            }),
        };
        let mut deps = HashMap::new();
        deps.insert("archive.a.drv".to_string(), (dep_path, dep_out));
        assert_eq!(rpc_side(&record, &deps), sandbox_side(&record, &deps));
    }

    /// A CHAINED pair (`ar` then `ranlib` on the same output) -- the
    /// exact multi-step-chain shape `docs/rust-status.md` says the
    /// original bug would have silently broken (a solo record happened
    /// to still match; only a real chain exposed the missing trailing
    /// `"; "`). `record_to_derivation` has no chain concept of its own
    /// (`Rpc`/eager-`Sandbox` modes never defer, so a real `ranlib`
    /// following a real `ar` always sees an already-real archive, never
    /// a chain to render) -- this test instead compares `render_member`
    /// against ITSELF called on the two records independently versus
    /// as a two-step chain, confirming the chain-rendering concatenation
    /// itself is exactly "render each step, concatenate, in order" with
    /// no cross-step interaction beyond that.
    #[test]
    fn two_step_chain_is_exact_concatenation() {
        let ar_record = Record {
            key: None,
            tool: "/nix/store/xxx-binutils/bin/ar".to_string(),
            args: vec!["rcs".to_string(), "$out".to_string(), "main.o".to_string()],
            srcs: vec!["xxx-binutils".to_string()],
            setup_cmd: None,
            chdir: None,
            cwd: None,
            chained_from: None,
            seed_from: None,
        };
        let ranlib_record = Record {
            key: None,
            tool: "/nix/store/xxx-binutils/bin/ranlib".to_string(),
            args: vec!["$out".to_string()],
            srcs: vec!["xxx-binutils".to_string()],
            setup_cmd: None,
            chdir: None,
            cwd: None,
            chained_from: None,
            // A CHAINED ranlib's own `seed_from.from` is the stub's OWN
            // self-referential relative-path text (see `render_member`'s
            // own doc comment on why `apply_seed_from` is `false` for a
            // non-first chain step) -- deliberately set here to confirm
            // it's correctly ignored, not just absent.
            seed_from: Some(SeedFrom {
                from: "archive.a".to_string(),
                coreutils_basename: "yyy-coreutils".to_string(),
            }),
        };

        let deps: HashMap<String, (StorePath, OutputName)> = HashMap::new();
        let chained_stub = Stub {
            chain: vec![ar_record.clone(), ranlib_record.clone()],
            key: None,
            deps: Vec::new(),
            eager_drv: None,
        };
        let (chained_setup, chained_cmd, _) = render_member(&chained_stub, "$out", |a| {
            deps.get(a).map(|(p, o)| {
                Placeholder::ca_output(p, o).render().to_string_lossy().into_owned()
            })
        });

        let (ar_setup, ar_cmd) =
            render_record_line(&ar_record, "$out", true, |_| None);
        let (ranlib_setup, ranlib_cmd) =
            render_record_line(&ranlib_record, "$out", false, |_| None);

        assert_eq!(chained_setup, format!("{ar_setup}{ranlib_setup}"));
        assert_eq!(chained_cmd, format!("{ar_cmd}{ranlib_cmd}"));
    }
}
