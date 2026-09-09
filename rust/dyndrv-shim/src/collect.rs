use crate::record::Record;
use crate::stub;
use harmonia_store_derivation::derived_path::OutputName;
use harmonia_store_path::StorePath;
use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};

/// A discovered stub, keyed by its path relative to `buildRoot` -- port
/// of `collectStubs.nix`'s Phase 1/2 discovery + dependency-scan, plus
/// (task #85) `Sandbox` mode's own eager file-granularity representation.
pub struct Stub {
    /// Full record chain, OLDEST first (see `Record.chained_from`'s own
    /// doc comment -- an `ar` step chained under a later `ranlib` step
    /// must still render both, in order). Empty for an eager stub (see
    /// `eager_drv` below) -- there's no on-disk record to chain, since
    /// `run_sandbox_eager_tail` never wrote one.
    pub chain: Vec<Record>,
    pub key: Option<String>,
    pub deps: Vec<String>,
    /// `Some((drv_path, output_name))` for a stub that's a real symlink
    /// into `/nix/store/*.drv` (`run_sandbox_eager_tail`'s own
    /// file-granularity representation, or task #86's own module-
    /// granularity group-accumulation representation) -- its derivation
    /// is ALREADY registered, so Phase 7 (`dyndrv-collect.rs`) must skip
    /// building/registering a NEW one for it and reuse this `StorePath`/
    /// `OutputName` directly. `output_name` is `"out"` for a solo eager
    /// stub (task #85's own representation, always single-output) but
    /// may be any sanitized-relative-path name for a GROUP member (task
    /// #86: one combined multi-output derivation per batch group, each
    /// member owning its own named output within it). `None` for an
    /// ordinary text-stub (the ONLY kind before task #85), which still
    /// needs the full render+register pass.
    pub eager_drv: Option<(StorePath, OutputName)>,
}

/// Walks a HEAD record's own `chainedFrom` pointer back to every earlier
/// record on disk -- port of `dyndrv_record_chain`. Returns OLDEST first.
fn record_chain(head: Record) -> Vec<Record> {
    let mut newest_first = vec![head];
    loop {
        let Some(from) = newest_first.last().unwrap().chained_from.clone() else {
            break;
        };
        newest_first.push(read_record(Path::new(&from)));
    }
    newest_first.into_iter().rev().collect()
}

fn read_record(path: &Path) -> Record {
    let bytes = std::fs::read(path).unwrap_or_default();
    serde_json::from_slice(&bytes).unwrap_or(Record {
        key: None,
        tool: String::new(),
        args: Vec::new(),
        srcs: Vec::new(),
        setup_cmd: None,
        chdir: None,
        chained_from: None,
        seed_from: None,
    })
}

/// Kahn's-algorithm topological sort -- port of `dyndrv_topo_sort`.
/// Panics (matching the bash version's own `exit 1`) on a real cycle.
pub fn topo_sort(nodes: &[String], deps: &HashMap<String, Vec<String>>) -> Vec<String> {
    let mut in_degree: HashMap<&str, usize> = nodes.iter().map(|n| (n.as_str(), 0)).collect();
    let mut dependents: HashMap<&str, Vec<&str>> = HashMap::new();
    for n in nodes {
        for d in deps.get(n).into_iter().flatten() {
            *in_degree.get_mut(n.as_str()).unwrap() += 1;
            dependents.entry(d.as_str()).or_default().push(n.as_str());
        }
    }
    let mut queue: VecDeque<&str> = nodes
        .iter()
        .map(|n| n.as_str())
        .filter(|n| in_degree[n] == 0)
        .collect();
    let mut order = Vec::new();
    while let Some(n) = queue.pop_front() {
        order.push(n.to_string());
        for &dep_on_n in dependents.get(n).into_iter().flatten() {
            let deg = in_degree.get_mut(dep_on_n).unwrap();
            *deg -= 1;
            if *deg == 0 {
                queue.push_back(dep_on_n);
            }
        }
    }
    if order.len() != nodes.len() {
        panic!("dyndrv-collect: dependency cycle detected");
    }
    order
}

/// Sanitizes a relative path into a valid derivation output name -- port
/// of `collectStubs.nix`'s `tr -c 'a-zA-Z0-9' '_'`.
pub fn output_name_of(rel_path: &str) -> String {
    rel_path
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '_' })
        .collect()
}

/// Discovers every batch-pending stub under `build_root`, returning
/// `{ relative_path -> Stub }` -- port of `collectStubs.nix` Phases 1+2,
/// extended (task #85) to also discover `Sandbox` mode's own eager
/// file-granularity representation: a real symlink into `/nix/store/
/// *.drv`, written directly by `run_sandbox_eager_tail` with NO on-disk
/// JSON record at all (unlike a text stub, whose whole POINT is that a
/// record still needs re-reading for chaining/merge). An eager stub's
/// `deps` are computed the SAME way a text stub's cross-references are
/// (scanning for other discovered stub paths as substrings of a plain
/// positional arg) -- but since there's no record to scan args from,
/// scanning ISN'T needed: `run_sandbox_eager_tail` already resolved and
/// wired every dependency into the derivation itself at write time.
/// `deps` stays empty for an eager stub; correctness doesn't need it
/// here since eager stubs never enter Phase 4's merge rule (see
/// `assign_units`' own doc comment) -- a keyless record only joins a
/// dependency's unit if that dependency is itself a MERGEABLE
/// (non-solo) unit, which no eager stub (always registered as its own
/// solo derivation) can ever be.
pub fn discover_stubs(build_root: &Path) -> BTreeMap<String, Stub> {
    let mut chains: BTreeMap<String, Vec<Record>> = BTreeMap::new();
    let mut eager: BTreeMap<String, (StorePath, OutputName)> = BTreeMap::new();
    let mut is_stub = HashSet::new();

    for entry in walk_files(build_root) {
        let rel = entry
            .strip_prefix(build_root)
            .unwrap_or(&entry)
            .to_string_lossy()
            .into_owned();
        if let Some(record_path) = stub::read_batch_stub(&entry) {
            let head = read_record(&record_path);
            is_stub.insert(rel.clone());
            chains.insert(rel, record_chain(head));
        } else if let Some(dep) = stub::read_pending_symlink(&entry) {
            is_stub.insert(rel.clone());
            eager.insert(rel, dep);
        }
    }

    let mut stubs = BTreeMap::new();
    for (rel, chain) in chains {
        let key = chain
            .last()
            .and_then(|r| r.key.clone())
            .filter(|k| !k.is_empty());
        let mut deps = Vec::new();
        for rec in &chain {
            for a in &rec.args {
                if a != rel.as_str() && is_stub.contains(a) {
                    deps.push(a.clone());
                }
            }
        }
        stubs.insert(
            rel,
            Stub {
                chain,
                key,
                deps,
                eager_drv: None,
            },
        );
    }
    for (rel, dep) in eager {
        stubs.insert(
            rel,
            Stub {
                chain: Vec::new(),
                key: None,
                deps: Vec::new(),
                eager_drv: Some(dep),
            },
        );
    }

    stubs
}

fn walk_files(root: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut queue = vec![root.to_path_buf()];
    while let Some(dir) = queue.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            // `DirEntry::file_type()` reports the entry's OWN type (no
            // extra syscall following the link), unlike `path.is_dir()`/
            // `is_file()` (which call `fs::metadata`, following
            // symlinks) -- confirmed necessary by direct reproduction:
            // an eager stub (task #85's `run_sandbox_eager_tail`) is a
            // symlink into `/nix/store/*.drv`, and a store path
            // registered mid-build is NOT locally `stat`-able from
            // inside the SAME sandbox that registered it (task #83's
            // spike), so `path.is_file()` on it returns `false` and the
            // ORIGINAL `is_dir()`/`is_file()`-only version silently
            // dropped every eager stub from discovery entirely --
            // confirmed by direct reproduction against example 05's
            // compiled variant: `prog`'s own final tree never got
            // `main.o`/`lib_a.o`/`lib_b.o` copied in, "cp: cannot stat
            // 'prog': No such file or directory".
            let Ok(file_type) = entry.file_type() else {
                continue;
            };
            if file_type.is_symlink() {
                out.push(path);
            } else if file_type.is_dir() {
                queue.push(path);
            } else if file_type.is_file() {
                out.push(path);
            }
        }
    }
    out
}

/// Assigns each stub to a UNIT -- port of Phase 4's merge rule: a stub
/// with its own `key` joins that unit directly; a keyless stub (e.g. an
/// `ar`/link step) joins its deps' shared unit IFF every dep already
/// belongs to that SAME real (non-solo) unit; otherwise it's its own
/// solo unit. `order` must be a valid topological order over `stubs`'
/// keys (deps assigned before dependents).
pub fn assign_units(order: &[String], stubs: &BTreeMap<String, Stub>) -> HashMap<String, String> {
    let mut unit_of: HashMap<String, String> = HashMap::new();
    let is_solo_unit = |u: &str| u.starts_with("__dyndrv_solo:");
    for p in order {
        let stub = &stubs[p];
        if let Some(k) = &stub.key {
            unit_of.insert(p.clone(), k.clone());
            continue;
        }
        let mut shared: Option<String> = None;
        let mut all_same = true;
        let mut has_deps = false;
        for d in &stub.deps {
            has_deps = true;
            let du = unit_of[d].clone();
            match &shared {
                None => shared = Some(du),
                Some(s) if *s != du => all_same = false,
                _ => {}
            }
        }
        if has_deps && all_same && !is_solo_unit(shared.as_deref().unwrap_or("")) {
            unit_of.insert(p.clone(), shared.unwrap());
        } else {
            unit_of.insert(p.clone(), format!("__dyndrv_solo:{p}"));
        }
    }
    unit_of
}

/// Groups stub paths by unit, preserving `order`'s own relative
/// ordering within each unit -- port of Phase 5.
pub fn group_by_unit(order: &[String], unit_of: &HashMap<String, String>) -> Vec<(String, Vec<String>)> {
    let mut members: HashMap<String, Vec<String>> = HashMap::new();
    let mut unit_order = Vec::new();
    let mut seen = HashSet::new();
    for p in order {
        let u = &unit_of[p];
        members.entry(u.clone()).or_default().push(p.clone());
        if seen.insert(u.clone()) {
            unit_order.push(u.clone());
        }
    }
    unit_order
        .into_iter()
        .map(|u| (u.clone(), members.remove(&u).unwrap()))
        .collect()
}
