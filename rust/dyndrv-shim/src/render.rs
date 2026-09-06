use crate::collect::Stub;
use std::collections::{BTreeMap, HashMap};

/// Single-quotes a string for safe embedding in a `/bin/sh -c` command
/// line -- port of `dyndrv_sq`/`mkAcceleratedStdenv.nix`'s `shellQuote`.
pub fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
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

    for rec in &stub.chain {
        if let Some(s) = &rec.setup_cmd {
            setup_cmd.push_str(s);
        }
        srcs.extend(rec.srcs.iter().cloned());

        let mut args_line = String::new();
        for a in &rec.args {
            args_line.push(' ');
            if a == "$out" {
                args_line.push_str(own_out_var);
            } else if let Some(token) = resolve_ref(a) {
                args_line.push_str(&token);
            } else {
                args_line.push_str(&shell_quote(a));
            }
        }
        cmd_line.push_str(&rec.tool);
        cmd_line.push_str(&args_line);
        cmd_line.push_str("; ");
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
