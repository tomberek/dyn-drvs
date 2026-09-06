use anyhow::Context;
use dyndrv_shim::collect::{self, output_name_of};
use dyndrv_shim::render::{render_unit, shell_quote};
use harmonia_store_content_address::ContentAddressMethodAlgorithm;
use harmonia_store_derivation::derivation::{Derivation, DerivationOutput};
use harmonia_store_derivation::derived_path::{OutputName, SingleDerivedPath};
use harmonia_store_derivation::placeholder::Placeholder;
use harmonia_store_path::{StoreDir, StorePath};
use nix_builder_rpc_client::BuilderRpcClient;
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::Arc;

/// Entrypoint for the end-of-`buildPhase` collection pass -- native port
/// of `collectStubs.nix`'s whole-tree resolution algorithm (topo-sort,
/// unit-merge, per-unit registration, cross-unit placeholder
/// substitution, final tree assembly, submission), replacing every
/// internal `jq`/`nix` CLI subprocess with native code + the raw
/// worker-protocol client, running in ONE process for the whole pass.
///
/// Usage: `dyndrv-collect <buildRoot> <name>` -- same two positional
/// arguments `collectStubs.nix`'s own Nix-level `buildRoot`/`name`
/// params configure.
fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let build_root = args.get(1).map(String::as_str).unwrap_or(".");
    let name = args
        .get(2)
        .cloned()
        .context("usage: dyndrv-collect <buildRoot> <name>")?;

    let client = BuilderRpcClient::connect_from_env().context("connect_from_env")?;
    let store_dir = StoreDir::default();

    // Phase 1+2: discover every stub + its deps.
    let stubs = collect::discover_stubs(Path::new(build_root));
    let stub_paths: Vec<String> = stubs.keys().cloned().collect();

    // Phase 3: global topo order.
    let deps_map: HashMap<String, Vec<String>> = stubs
        .iter()
        .map(|(p, s)| (p.clone(), s.deps.clone()))
        .collect();
    let order = collect::topo_sort(&stub_paths, &deps_map);

    // Phase 4+5: unit assignment + grouping.
    let unit_of = collect::assign_units(&order, &stubs);
    let unit_groups = collect::group_by_unit(&order, &unit_of);

    // Output name per stub (only meaningful for merged units, computed
    // for every stub uniformly like the bash version does).
    let output_name_of_stub: HashMap<String, String> = stub_paths
        .iter()
        .map(|p| (p.clone(), output_name_of(p)))
        .collect();

    // Phase 6: unit-level deps, for the unit-level topo sort.
    let unit_keys: Vec<String> = unit_groups.iter().map(|(u, _)| u.clone()).collect();
    let mut unit_deps: HashMap<String, Vec<String>> = HashMap::new();
    for (u, members) in &unit_groups {
        let mut ds = Vec::new();
        for p in members {
            for d in &stubs[p].deps {
                let du = &unit_of[d];
                if du != u && !ds.contains(du) {
                    ds.push(du.clone());
                }
            }
        }
        unit_deps.insert(u.clone(), ds);
    }
    let unit_order = collect::topo_sort(&unit_keys, &unit_deps);
    let members_by_unit: HashMap<String, Vec<String>> = unit_groups.into_iter().collect();

    // Phase 7: register one derivation per unit, in unit-topo order.
    let mut drv_path_by_unit: HashMap<String, StorePath> = HashMap::new();

    for u in &unit_order {
        let members = &members_by_unit[u];
        let is_solo = members.len() == 1;

        let unit_render = render_unit(
            members,
            &stubs,
            &output_name_of_stub,
            |dep_stub_path| {
                let du = unit_of.get(dep_stub_path)?;
                let drv_path = drv_path_by_unit.get(du)?;
                let out_name: OutputName = output_name_for_cross_ref(
                    &members_by_unit[du],
                    dep_stub_path,
                    &output_name_of_stub,
                )
                .parse()
                .ok()?;
                Some(
                    Placeholder::ca_output(drv_path, &out_name)
                        .render()
                        .display()
                        .to_string(),
                )
            },
            &unit_of,
            u,
        );

        let drv_name = if is_solo {
            format!("dyndrv-{}", output_name_of_stub[&members[0]])
        } else {
            format!("dyndrv-batch-{u}")
        };

        let mut drv = Derivation::new(
            drv_name.parse().context("drv name")?,
            bytes::Bytes::copy_from_slice(store_dir_system().as_bytes()),
            bytes::Bytes::from_static(b"/bin/sh"),
        );
        drv.args = vec![
            bytes::Bytes::from_static(b"-c"),
            bytes::Bytes::copy_from_slice(unit_render.combined_script.as_bytes()),
        ];

        for (out_name, _stub_path) in &unit_render.outputs {
            let out_name_parsed: OutputName = out_name.parse().context("output name")?;
            let ph = Placeholder::standard_output(&out_name_parsed).render();
            drv.env.insert(
                bytes::Bytes::copy_from_slice(out_name.as_bytes()),
                bytes::Bytes::copy_from_slice(ph.as_os_str().as_encoded_bytes()),
            );
            drv.outputs.insert(
                out_name_parsed,
                DerivationOutput::CAFloating(ContentAddressMethodAlgorithm::NixArchive(
                    harmonia_utils_hash::Algorithm::SHA256,
                )),
            );
        }

        for src_basename in &unit_render.srcs {
            if let Ok(sp) = StorePath::from_base_path(src_basename) {
                drv.inputs.insert(SingleDerivedPath::Opaque(sp));
            }
        }
        for du in &unit_deps[u] {
            if let Some(dep_drv_path) = drv_path_by_unit.get(du) {
                let dep_members = &members_by_unit[du];
                let is_dep_solo = dep_members.len() == 1;
                let outs: HashSet<String> = members[..]
                    .iter()
                    .flat_map(|p| stubs[p].deps.iter())
                    .filter(|d| &unit_of[*d] == du)
                    .map(|d| {
                        if is_dep_solo {
                            "out".to_string()
                        } else {
                            output_name_of_stub[d].clone()
                        }
                    })
                    .collect();
                for out_str in outs {
                    if let Ok(out_name) = out_str.parse::<OutputName>() {
                        drv.inputs.insert(SingleDerivedPath::Built {
                            drv_path: Arc::new(SingleDerivedPath::Opaque(dep_drv_path.clone())),
                            output: out_name,
                        });
                    }
                }
            }
        }

        let drv_path = client
            .add_drv_to_store(&store_dir, &drv)
            .context("add_drv_to_store")?;
        drv_path_by_unit.insert(u.clone(), drv_path);
    }

    // Phase 8: final tree -- original tree minus stubs, with each stub
    // path replaced by a symlink to its owning unit's real output.
    let orig_tree_parent = std::env::temp_dir().join(format!("dyndrv-orig-tree-{}", std::process::id()));
    std::fs::create_dir_all(&orig_tree_parent)?;
    copy_dir_all(Path::new(build_root), &orig_tree_parent)?;
    for p in &stub_paths {
        let _ = std::fs::remove_file(orig_tree_parent.join(p));
    }
    let orig_tree_path = client
        .add_to_store_nar("dyndrv-orig-tree", &orig_tree_parent)
        .context("add_to_store_nar orig tree")?;
    std::fs::remove_dir_all(&orig_tree_parent).ok();

    let coreutils_bin = std::env::var("DYNDRV_COREUTILS_BIN")
        .context("DYNDRV_COREUTILS_BIN (absolute path to coreutils' bin dir)")?;
    // `StorePath`'s own `Display`/`to_base_path()` prints just
    // `<hash>-<name>` (see `wrapper.rs::rewrite_argv_element`'s own
    // identical note) -- the full absolute path must be reconstructed
    // explicitly, or the rendered `cp -r` here resolves against the
    // CALLING derivation's own relative cwd instead of the real store
    // path (confirmed by direct reproduction against a real freetype
    // build: "cp: cannot stat '<hash>-dyndrv-orig-tree/.': No such file
    // or directory").
    let mut final_copy_lines = format!(
        "{cu}/mkdir -p $out; {cu}/cp -r /nix/store/{tree}/. $out/; {cu}/chmod -R u+w $out; ",
        cu = coreutils_bin,
        tree = orig_tree_path.to_base_path(),
    );
    for p in &stub_paths {
        final_copy_lines.push_str(&format!(
            "{cu}/mkdir -p \"$({cu}/dirname \"$out/{p}\")\"; {cu}/ln -s {ph} \"$out/{p}\"; ",
            cu = coreutils_bin,
            ph = shell_quote(&placeholder_for_stub(
                p,
                &unit_of,
                &members_by_unit,
                &output_name_of_stub,
                &drv_path_by_unit,
            ))
        ));
    }

    let mut final_drv = Derivation::new(
        name.parse().context("final drv name")?,
        bytes::Bytes::copy_from_slice(store_dir_system().as_bytes()),
        bytes::Bytes::from_static(b"/bin/sh"),
    );
    final_drv.args = vec![
        bytes::Bytes::from_static(b"-c"),
        bytes::Bytes::copy_from_slice(final_copy_lines.as_bytes()),
    ];
    let out_name: OutputName = "out".parse().unwrap();
    let self_ph = Placeholder::standard_output(&out_name).render();
    final_drv.env.insert(
        bytes::Bytes::from_static(b"out"),
        bytes::Bytes::copy_from_slice(self_ph.as_os_str().as_encoded_bytes()),
    );
    final_drv.outputs.insert(
        out_name.clone(),
        DerivationOutput::CAFloating(ContentAddressMethodAlgorithm::NixArchive(
            harmonia_utils_hash::Algorithm::SHA256,
        )),
    );
    final_drv.inputs.insert(SingleDerivedPath::Opaque(orig_tree_path));
    // `coreutils_bin` is `<store-path>/bin` -- the store path itself
    // (its PARENT) is what needs declaring as an input, matching the
    // bash version's own `coreutilsSrc` (basename of the coreutils
    // package, not its `/bin` subdir).
    if let Some(coreutils_store_path) = coreutils_bin
        .strip_suffix("/bin")
        .and_then(|p| p.rsplit('/').next())
        .and_then(|basename| StorePath::from_base_path(basename).ok())
    {
        final_drv
            .inputs
            .insert(SingleDerivedPath::Opaque(coreutils_store_path));
    }

    for p in &stub_paths {
        let u = &unit_of[p];
        if let Some(dep_drv_path) = drv_path_by_unit.get(u) {
            let is_dep_solo = members_by_unit[u].len() == 1;
            let out = if is_dep_solo {
                "out".to_string()
            } else {
                output_name_of_stub[p].clone()
            };
            if let Ok(out_name) = out.parse::<OutputName>() {
                final_drv.inputs.insert(SingleDerivedPath::Built {
                    drv_path: Arc::new(SingleDerivedPath::Opaque(dep_drv_path.clone())),
                    output: out_name,
                });
            }
        }
    }

    let final_drv_path = client
        .add_drv_to_store(&store_dir, &final_drv)
        .context("add_drv_to_store final")?;

    let single = SingleDerivedPath::Opaque(final_drv_path);
    client
        .submit_output(&single, &out_name)
        .context("submit_output")?;

    Ok(())
}

fn output_name_for_cross_ref(
    dep_members: &[String],
    dep_stub_path: &str,
    output_name_of_stub: &HashMap<String, String>,
) -> String {
    if dep_members.len() == 1 {
        "out".to_string()
    } else {
        output_name_of_stub[dep_stub_path].clone()
    }
}

fn placeholder_for_stub(
    p: &str,
    unit_of: &HashMap<String, String>,
    members_by_unit: &HashMap<String, Vec<String>>,
    output_name_of_stub: &HashMap<String, String>,
    drv_path_by_unit: &HashMap<String, StorePath>,
) -> String {
    let u = &unit_of[p];
    let drv_path = &drv_path_by_unit[u];
    let is_solo = members_by_unit[u].len() == 1;
    let out_name_str = if is_solo {
        "out".to_string()
    } else {
        output_name_of_stub[p].clone()
    };
    let out_name: OutputName = out_name_str.parse().unwrap();
    Placeholder::ca_output(drv_path, &out_name)
        .render()
        .display()
        .to_string()
}

fn store_dir_system() -> &'static str {
    // Matches `builtins.currentSystem` for the platform this binary is
    // built for -- x86_64-linux only for now (this project's own
    // established target, matching every existing example/benchmark).
    "x86_64-linux"
}

fn copy_dir_all(src: &Path, dst: &Path) -> std::io::Result<()> {
    for entry in std::fs::read_dir(src)? {
        let entry = entry?;
        let ty = entry.file_type()?;
        let dst_path = dst.join(entry.file_name());
        if ty.is_dir() {
            std::fs::create_dir_all(&dst_path)?;
            copy_dir_all(&entry.path(), &dst_path)?;
        } else if ty.is_file() {
            std::fs::copy(entry.path(), &dst_path)?;
        }
    }
    Ok(())
}
