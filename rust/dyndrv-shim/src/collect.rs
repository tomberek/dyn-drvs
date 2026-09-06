use crate::record::Record;
use crate::stub;
use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};

/// A discovered stub, keyed by its path relative to `buildRoot` -- port
/// of `collectStubs.nix`'s Phase 1/2 discovery + dependency-scan.
pub struct Stub {
    /// Full record chain, OLDEST first (see `Record.chained_from`'s own
    /// doc comment -- an `ar` step chained under a later `ranlib` step
    /// must still render both, in order).
    pub chain: Vec<Record>,
    pub key: Option<String>,
    pub deps: Vec<String>,
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
        chained_from: None,
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
/// `{ relative_path -> Stub }` -- port of `collectStubs.nix` Phases 1+2.
pub fn discover_stubs(build_root: &Path) -> BTreeMap<String, Stub> {
    let mut chains: BTreeMap<String, Vec<Record>> = BTreeMap::new();
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
        stubs.insert(rel, Stub { chain, key, deps });
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
            if path.is_dir() {
                queue.push(path);
            } else if path.is_file() {
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
