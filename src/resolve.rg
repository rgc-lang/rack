import lock
import manifest
import registry
import util

# resolve.rg — dependency resolution: transitive expansion, version/source conflict detection, dependency tree
#
# Resolution strategy: exact-version closure (semver range solving is not implemented yet).
# Every dependency carries a source ("" = local registry; github.com/<owner>/<repo> = GitHub);
# a package with the same name must come from the same source (target/deps is a flat module space).
# Algorithm: worklist iteration, first-seen wins — a package seen a second time with a different
# version/source is a conflict; ancestor chains ("A -> B" strings) drive cycle detection and conflict reports.
# Conflict baseline prefers the full rack.lock closure (cargo semantics: resolve against the lock file);
# without a lock file it falls back to manifest pins (for legacy projects).
#
# resolve_install is a pure function: it does not mutate the manifest and returns a ResolveOut plan
# that the caller (cmds) applies to the real manifest — this avoids an unverified path in RGC's
# borrow checker for "re-borrowing a mutable borrow parameter".

public class ResolveOut {
    err: str
    names: List[str]
    versions: List[str]
    sources: List[str]
    added: List[str]
    copied: int
}

def new_resolve_out() -> ResolveOut {
    o = ResolveOut()
    o.err = ""
    o.names = List[str]()
    o.versions = List[str]()
    o.sources = List[str]()
    o.added = List[str]()
    o.copied = 0
    return o
}

# Whether the ancestor chain contains name (chain format "A -> B -> C")
def chain_has(chain: str, name: str) -> bool {
    if chain.len() == 0 {
        return False
    }
    parts = chain.split(" -> ")
    return parts.contains(name)
}

# Resolve name@ver (from src) and all of its transitive dependencies.
# On success err == "", names/versions/sources form the complete pin set, and added lists the newly installed (in order);
# on failure err describes the reason.
public def resolve_install(proj_dir: str, name: str, ver: str, src: str, m: @Manifest,
use_lock_pins: bool) -> ResolveOut {
    out = new_resolve_out()

    # Working copy = existing pins + new additions during the walk (conflict detection applies to the transitive closure too)
    # Pin baseline: rack.lock closure first; update re-resolves around the lock (allowing newer versions)
    wm = new_manifest()
    wm.name = m.name
    i = 0
    lk = lock_load(proj_dir)
    if use_lock_pins and lk.names.len() > 0 {
        while i < lk.names.len() {
            mf_set_dep_src(@var wm, lk.names.get(i), lk.versions.get(i), lk.sources.get(i))
            i = i + 1
        }
    } else {
        while i < mf_dep_count(@m) {
            mf_set_dep_src(@var wm, mf_dep_name(@m, i), mf_dep_version(@m, i), mf_dep_source(@m, i))
            i = i + 1
        }
    }

    qn = List[str]()
    qv = List[str]()
    qs = List[str]()
    qc = List[str]()
    visited = List[str]()
    qn.push(name)
    qv.push(ver)
    qs.push(src)
    qc.push("")

    while qn.len() > 0 {
        n = qn.get(0)
        v = qv.get(0)
        s = qs.get(0)
        chain = qc.get(0)
        pop_front(@var qn)
        pop_front(@var qv)
        pop_front(@var qs)
        pop_front(@var qc)

        # Cycle detection: require that the chain already contains us
        if chain_has(chain, n) {
            out.err = "dependency cycle: " + chain + " -> " + n
            return out
        }

        # Conflict: already pinned with a different version or source
        pi = mf_find_dep(@wm, n)
        if pi >= 0 {
            pv = mf_dep_version(@wm, pi)
            ps = mf_dep_source(@wm, pi)
            if pv != v {
                if chain == "" {
                    out.err = "version conflict on `" + n + "`: pinned " + pv +
                    ", requested " + v
                } else {
                    out.err = "version conflict on `" + n + "`: pinned " + pv +
                    ", but `" + chain + "` requires " + v
                }
                return out
            }
            if ps != s {
                out.err = "source conflict on `" + n + "`: pinned " + source_label(ps) +
                ", requested " + source_label(s)
                return out
            }
        }

        fresh = not visited.contains(n)
        target = proj_dir + "/target/deps/" + n + ".rg"
        had_file = try_read(target).is_ok()
        if pi < 0 {
            # Not pinned: install and pin
            r = install_pkg(proj_dir, n, v, s, use_lock_pins)
            if r.is_err() {
                match r {
                    case Err(msg) => out.err = msg
                    case _ => out.err = "install failed for " + n
                }
                return out
            }
            if not had_file {
                out.copied = out.copied + 1
            }
            mf_set_dep_src(@var wm, n, v, s)
            out.added.push(n)
            print("  + " + n + "@" + v + source_suffix(s))
        } elif fresh {
            # Already pinned and consistent: still copy the file (fresh clone with no cache)
            r = install_pkg(proj_dir, n, v, s, use_lock_pins)
            if r.is_err() {
                match r {
                    case Err(msg) => out.err = msg
                    case _ => out.err = "install failed for " + n
                }
                return out
            }
            if not had_file {
                out.copied = out.copied + 1
            }
        }

        if fresh {
            visited.push(n)
            # Expand the package's own dependencies (registry/cache manifest; legacy packages without a manifest are leaves)
            mtext = pkg_manifest_text(n, v, s)
            if mtext.len() > 0 {
                dm = new_manifest()
                perr = manifest_parse(mtext, @var dm)
                if perr != "" {
                    out.err = "bad manifest of " + n + "@" + v + ": " + perr
                    return out
                }
                j = 0
                while j < mf_dep_count(@dm) {
                    dn = mf_dep_name(@dm, j)
                    dv = mf_dep_version(@dm, j)
                    ds = mf_dep_source(@dm, j)
                    if dv.len() == 0 {
                        lv = lookup_latest(dn, ds)
                        if not lv.ok {
                            out.err = lv.error
                            return out
                        }
                        dv = lv.version
                        print("  resolved " + dn + " -> " + dn + "@" + dv + source_suffix(ds))
                    }
                    qn.push(dn)
                    qv.push(dv)
                    qs.push(ds)
                    if chain == "" {
                        qc.push(n)
                    } else {
                        qc.push(chain + " -> " + n)
                    }
                    j = j + 1
                }
            }
        }
    }

    i = 0
    while i < mf_dep_count(@wm) {
        out.names.push(mf_dep_name(@wm, i))
        out.versions.push(mf_dep_version(@wm, i))
        out.sources.push(mf_dep_source(@wm, i))
        i = i + 1
    }
    return out
}

# Dependency tree: direct deps come from the manifest; deeper levels read registry/cache manifests; cycles are marked (cycle)
public def print_tree(m: @Manifest) {
    path = List[str]()
    path.push(m.name)
    print(m.name + "@" + m.version)
    i = 0
    while i < mf_dep_count(@m) {
        n = mf_dep_name(@m, i)
        v = mf_dep_version(@m, i)
        s = mf_dep_source(@m, i)
        if i == mf_dep_count(@m) - 1 {
            print("└── " + n + "@" + v + source_suffix(s))
            tree_walk(n, v, s, "    ", @var path)
        } else {
            print("├── " + n + "@" + v + source_suffix(s))
            tree_walk(n, v, s, "│   ", @var path)
        }
        i = i + 1
    }
}

def tree_walk(name: str, ver: str, src: str, prefix: str, path: @var List[str]) {
    if path.contains(name) {
        print(prefix + "└── " + name + "@" + ver + source_suffix(src) + " (cycle)")
        return
    }
    path.push(name)
    mtext = pkg_manifest_text(name, ver, src)
    if mtext.len() > 0 {
        dm = new_manifest()
        if manifest_parse(mtext, @var dm) != "" {
            print(prefix + "└── <bad manifest>")
            path.pop()
            return
        }
        i = 0
        while i < mf_dep_count(@dm) {
            n = mf_dep_name(@dm, i)
            v = mf_dep_version(@dm, i)
            s = mf_dep_source(@dm, i)
            if i == mf_dep_count(@dm) - 1 {
                print(prefix + "└── " + n + "@" + v + source_suffix(s))
                tree_walk(n, v, s, prefix + "    ", @var path)
            } else {
                print(prefix + "├── " + n + "@" + v + source_suffix(s))
                tree_walk(n, v, s, prefix + "│   ", @var path)
            }
            i = i + 1
        }
    }
    path.pop()
}
