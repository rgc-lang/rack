import toml
import util

# lock.rg — the standalone rack.lock file (mirrors the role of Cargo.lock)
#
# rack.toml [dependencies] = direct dependency intent (exact pins, editable by hand);
# rack.lock = the resolved full closure (direct + transitive), maintained by rack and committed with the project:
#
#   [lock.calcx]
#   version = "0.1.0"
#   checksum = "…"                      # module sha256 recorded at publish time
#   dependencies = ["mathx"]            # direct dependencies of this package (used for remove pruning)
#
# install/update rewrite the file in full; remove deletes entries and prunes orphan
# transitive dependencies by reverse reachability; build validates manifest deps against the target/deps cache.
# Storage convention: each package's direct dependency names are joined into one string with "," to avoid List[List[str]].

public class Lock {
    names: List[str]
    versions: List[str]
    sources: List[str]
    checksums: List[str]
    depsJoined: List[str]
}

public def lock_new() -> Lock {
    l = Lock()
    l.names = List[str]()
    l.versions = List[str]()
    l.sources = List[str]()
    l.checksums = List[str]()
    l.depsJoined = List[str]()
    return l
}

# Load rack.lock; returns an empty lock when missing or corrupt (callers check names.len())
public def lock_load(proj_dir: str) -> Lock {
    l = lock_new()
    tr = try_read(path_join(proj_dir, "rack.lock"))
    if tr.is_err() {
        return l
    }
    doc = toml_new_doc()
    if toml_parse(tr.unwrap(), @var doc) != "" {
        return l
    }
    i = 0
    while i < toml_table_count(@doc) {
        p = toml_table_path(@doc, i)
        if p.startswith("lock.") {
            name = p.slice(5, p.len())
            if name.len() > 0 and not name.contains(".") {
                l.names.push(name)
                l.versions.push(toml_table_value(@doc, i, "version"))
                l.sources.push(toml_table_value(@doc, i, "source"))
                l.checksums.push(toml_table_value(@doc, i, "checksum"))
                elems = toml_array_elems(toml_table_value(@doc, i, "dependencies"))
                joined = ""
                j = 0
                while j < elems.len() {
                    if j > 0 {
                        joined = joined + ","
                    }
                    joined = joined + elems.get(j)
                    j = j + 1
                }
                l.depsJoined.push(joined)
            }
        }
        i = i + 1
    }
    return l
}

def quote_list(xs: List[str]) -> str {
    out = "["
    i = 0
    while i < xs.len() {
        if i > 0 {
            out = out + ", "
        }
        out = out + toml_escape_str(xs.get(i))
        i = i + 1
    }
    return out + "]"
}

# Order entries by package name (insertion sort) for byte-level deterministic lock files
def sorted_order(l: @Lock) -> List[int] {
    order = List[int]()
    i = 0
    while i < l.names.len() {
        order.push(i)
        i = i + 1
    }
    i = 1
    while i < order.len() {
        j = i
        while j > 0 and str_less(l.names.get(order.get(j)), l.names.get(order.get(j - 1))) {
            t = order.get(j)
            order.set(j, order.get(j - 1))
            order.set(j - 1, t)
            j = j - 1
        }
        i = i + 1
    }
    return order
}

# Direct dependency list of the idx-th entry
public def lock_entry_deps(l: @Lock, idx: int) -> List[str] {
    out = List[str]()
    joined = l.depsJoined.get(idx)
    if joined.len() == 0 {
        return out
    }
    for part in joined.split(",") {
        t = trim_ws(part)
        if t.len() > 0 {
            out.push(t)
        }
    }
    return out
}

public def lock_save(l: @Lock, path: str) -> Result[None, str] {
    s = "# rack.lock — dependency closure lock file (maintained by rack; do not edit by hand; commit with the project)\n"
    order = sorted_order(@l)
    i = 0
    while i < order.len() {
        idx = order.get(i)
        s = s + "\n[lock." + l.names.get(idx) + "]\n"
        s = s + "version = " + toml_escape_str(l.versions.get(idx)) + "\n"
        if l.sources.get(idx).len() > 0 {
            s = s + "source = " + toml_escape_str(l.sources.get(idx)) + "\n"
        }
        if l.checksums.get(idx).len() > 0 {
            s = s + "checksum = " + toml_escape_str(l.checksums.get(idx)) + "\n"
        }
        s = s + "dependencies = " + quote_list(lock_entry_deps(@l, idx)) + "\n"
        i = i + 1
    }
    return write_file(path, s)
}

# Entry index by name; -1 when absent
public def lock_find(l: @Lock, name: str) -> int {
    i = 0
    while i < l.names.len() {
        if l.names.get(i) == name {
            return i
        }
        i = i + 1
    }
    return -1
}

# Add or overwrite an entry
public def lock_set(l: @var Lock, name: str, ver: str, src: str, checksum: str, deps_joined: str) {
    i = lock_find(@l, name)
    if i >= 0 {
        l.versions.set(i, ver)
        l.sources.set(i, src)
        l.checksums.set(i, checksum)
        l.depsJoined.set(i, deps_joined)
        return
    }
    l.names.push(name)
    l.versions.push(ver)
    l.sources.push(src)
    l.checksums.push(checksum)
    l.depsJoined.push(deps_joined)
}

# Remove an entry; returns whether it was actually removed
public def lock_remove(l: @var Lock, name: str) -> bool {
    idx = lock_find(@l, name)
    if idx < 0 {
        return False
    }
    i = idx
    while i < l.names.len() - 1 {
        l.names.set(i, l.names.get(i + 1))
        l.versions.set(i, l.versions.get(i + 1))
        l.sources.set(i, l.sources.get(i + 1))
        l.checksums.set(i, l.checksums.get(i + 1))
        l.depsJoined.set(i, l.depsJoined.get(i + 1))
        i = i + 1
    }
    l.names.pop()
    l.versions.pop()
    l.sources.pop()
    l.checksums.pop()
    l.depsJoined.pop()
    return True
}

# Reachable from roots (direct dependencies) along dependencies; remove unreachable entries (orphan transitive deps)
public def lock_prune(l: @var Lock, roots: List[str]) {
    reach = List[str]()
    queue = List[str]()
    for r in roots {
        if lock_find(@l, r) >= 0 and not reach.contains(r) {
            reach.push(r)
            queue.push(r)
        }
    }
    while queue.len() > 0 {
        n = queue.get(0)
        pop_front(@var queue)
        idx = lock_find(@l, n)
        if idx < 0 {
            continue
        }
        for d in lock_entry_deps(@l, idx) {
            if not reach.contains(d) and lock_find(@l, d) >= 0 {
                reach.push(d)
                queue.push(d)
            }
        }
    }
    # Compact in place: remove unreachable entries in reverse order.
    # Note two RGC borrow restrictions: you cannot re-@var a @var parameter and pass it to another
    # function (it silently fails), nor rebind fields of a borrowed parameter (l.names = n2 does not
    # propagate back to the caller) — only shared-list mutations like set/pop are allowed.
    i = l.names.len() - 1
    while i >= 0 {
        if not reach.contains(l.names.get(i)) {
            j = i
            while j < l.names.len() - 1 {
                l.names.set(j, l.names.get(j + 1))
                l.versions.set(j, l.versions.get(j + 1))
                l.sources.set(j, l.sources.get(j + 1))
                l.checksums.set(j, l.checksums.get(j + 1))
                l.depsJoined.set(j, l.depsJoined.get(j + 1))
                j = j + 1
            }
            l.names.pop()
            l.versions.pop()
            l.sources.pop()
            l.checksums.pop()
            l.depsJoined.pop()
        }
        i = i - 1
    }
}
