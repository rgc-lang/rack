import github
import lock
import manifest
import source
import util

# registry.rg — package registry: local directory + GitHub-hosted source cache
#
# Local registry: $HOME/.rack/registry/<name>/<version>/
# GitHub cache: $HOME/.rack/cache/github.com/<owner>/<repo>/<version>/
#   Both contain the same content: <name>.rg + rack.toml (manifest carries a checksum).
# Remote packages are downloaded from a tag over HTTPS on first install and then
# reuse the cache offline; missing/corrupt cache entries are re-fetched, and the
# checksum in the lock file detects moved tags.

public def registry_dir() -> str {
    return path_join(detect_home(), ".rack/registry")
}

public def cache_dir() -> str {
    return path_join(detect_home(), ".rack/cache")
}

public class VersionLookup {
    ok: bool
    error: str
    version: str
}

def new_version_lookup() -> VersionLookup {
    v = VersionLookup()
    v.ok = False
    v.error = ""
    v.version = ""
    return v
}

# All versions of a package in the local registry
public def pkg_versions(name: str) -> List[str] {
    return list_dir(registry_dir() + "/" + name)
}

# Semver-latest version in the local registry; returns "" when the package is absent
public def latest_version(name: str) -> str {
    best = ""
    for v in pkg_versions(name) {
        if best == "" or version_compare(v, best) > 0 {
            best = v
        }
    }
    return best
}

# Resolve the latest version by source: local registry or GitHub tags
public def lookup_latest(name: str, src: str) -> VersionLookup {
    out = new_version_lookup()
    if src.len() == 0 {
        v = latest_version(name)
        if v.len() == 0 {
            out.error = "package `" + name + "` not found in " + registry_dir()
            return out
        }
        out.ok = True
        out.version = v
        return out
    }
    si = source_parse(src)
    if not si.ok {
        out.error = si.error
        return out
    }
    vs = gh_tags(si.owner, si.repo)
    if not vs.ok {
        out.error = vs.error
        return out
    }
    best = ""
    for v in vs.versions {
        if best == "" or version_compare(v, best) > 0 {
            best = v
        }
    }
    out.ok = True
    out.version = best
    return out
}

# Package version directory: local registry or GitHub cache
public def pkg_dir(name: str, ver: str, src: str) -> str {
    if src.len() == 0 {
        return registry_dir() + "/" + name + "/" + ver
    }
    si = source_parse(src)
    if not si.ok {
        return ""
    }
    return cache_dir() + "/" + si.id + "/" + ver
}

public def pkg_module_path(name: str, ver: str, src: str) -> str {
    d = pkg_dir(name, ver, src)
    if d.len() == 0 {
        return ""
    }
    return d + "/" + name + ".rg"
}

public def pkg_manifest_path(name: str, ver: str, src: str) -> str {
    d = pkg_dir(name, ver, src)
    if d.len() == 0 {
        return ""
    }
    return d + "/rack.toml"
}

public def pkg_manifest_text(name: str, ver: str, src: str) -> str {
    return read_file_or(pkg_manifest_path(name, ver, src))
}

# Checksum of name@ver in the registry/cache (returns "" when the manifest is missing, corrupt, or has none)
public def pkg_checksum(name: str, ver: str, src: str) -> str {
    mt = pkg_manifest_text(name, ver, src)
    if mt.len() == 0 {
        return ""
    }
    pm = new_manifest()
    if manifest_parse(mt, @var pm) != "" {
        return ""
    }
    return pm.checksum
}

public class PkgDeps {
    names: List[str]
    sources: List[str]
}

# Direct dependencies from the package manifest (name + source); legacy packages without a manifest are leaves
public def pkg_deps(name: str, ver: str, src: str) -> PkgDeps {
    out = PkgDeps()
    out.names = List[str]()
    out.sources = List[str]()
    mt = pkg_manifest_text(name, ver, src)
    if mt.len() == 0 {
        return out
    }
    pm = new_manifest()
    if manifest_parse(mt, @var pm) != "" {
        return out
    }
    i = 0
    while i < mf_dep_count(@pm) {
        out.names.push(mf_dep_name(@pm, i))
        out.sources.push(mf_dep_source(@pm, i))
        i = i + 1
    }
    return out
}

# Checksum for name@ver+source recorded in the lock file (detects moved tags)
def locked_checksum(proj_dir: str, name: str, ver: str, src: str) -> str {
    lk = lock_load(proj_dir)
    idx = lock_find(@lk, name)
    if idx < 0 {
        return ""
    }
    if lk.versions.get(idx) != ver or lk.sources.get(idx) != src {
        return ""
    }
    return lk.checksums.get(idx)
}

def checksum_mismatch_msg(name: str, ver: str, src: str, expected: str, actual: str) -> str {
    return "checksum mismatch for `" + name + "@" + ver + "` from " + src +
    "\n  expected: " + expected + "\n  actual:   " + actual +
    "\n  hint: the tag may have moved; run `rack update` to accept the new content"
}

# Ensure a remote package is cached and trustworthy; re-fetch when the cache is corrupt.
# With enforce_lock set, the lock-file checksum is the authoritative baseline (detects tag drift / supply-chain tampering).
def ensure_cached(proj_dir: str, name: str, ver: str, src: str, enforce_lock: bool) -> Result[None, str] {
    si = source_parse(src)
    if not si.ok {
        return Result[None, str].Err(si.error)
    }
    dir = pkg_dir(name, ver, src)
    mp = dir + "/" + name + ".rg"
    tf = dir + "/rack.toml"
    expected = ""
    if enforce_lock {
        expected = locked_checksum(proj_dir, name, ver, src)
    }

    mt = read_file_or(tf)
    # Trust the cache only when the checksum matches the lock file: without a lock
    # (first resolve / update) the package must be re-fetched, otherwise tag drift
    # would be masked by a stale cache and update could not accept new content.
    if expected.len() > 0 and mt.len() > 0 and try_read(mp).is_ok() {
        pm = new_manifest()
        if manifest_parse(mt, @var pm) == "" and pm.checksum == expected {
            if file_sha256(mp) == expected {
                return Result[None, str].Ok(None)
            }
        }
    }

    gp = gh_fetch_package(name, ver, si.owner, si.repo)
    if not gp.ok {
        return Result[None, str].Err(gp.error)
    }
    pm2 = new_manifest()
    perr = manifest_parse(gp.manifest, @var pm2)
    if perr != "" {
        return Result[None, str].Err("invalid rack.toml in " + src + " tag `" + gp.tag + "`: " + perr)
    }
    if pm2.name != name {
        return Result[None, str].Err("package name mismatch: " + src + " declares `" + pm2.name +
        "`, expected `" + name + "`")
    }
    if pm2.version != ver {
        return Result[None, str].Err("version mismatch: " + src + " tag `" + gp.tag +
        "` declares `" + pm2.version + "`, expected `" + ver + "`")
    }

    tmp = dir + ".tmp"
    remove_dir_all(tmp)
    if not mkdirs(tmp) {
        return Result[None, str].Err("cannot create cache directory " + tmp)
    }
    w = write_file(tmp + "/" + name + ".rg", gp.module)
    if w.is_err() {
        remove_dir_all(tmp)
        return Result[None, str].Err("cannot write cached module for " + name + "@" + ver)
    }
    actual = file_sha256(tmp + "/" + name + ".rg")
    if actual.len() == 0 {
        remove_dir_all(tmp)
        return Result[None, str].Err("cannot hash downloaded module for " + name + "@" + ver)
    }
    if expected.len() > 0 and actual != expected {
        remove_dir_all(tmp)
        return Result[None, str].Err(checksum_mismatch_msg(name, ver, src, expected, actual))
    }
    pm2.checksum = actual
    wm = mf_save(@pm2, tmp + "/rack.toml")
    if wm.is_err() {
        remove_dir_all(tmp)
        return Result[None, str].Err("cannot write cached manifest for " + name + "@" + ver)
    }
    remove_dir_all(dir)
    if not move_path(tmp, dir) {
        remove_dir_all(tmp)
        return Result[None, str].Err("cannot commit cache directory " + dir)
    }
    return Result[None, str].Ok(None)
}

# Install: copy <name>.rg from the registry/cache into target/deps/ (idempotent, repairs cache)
# Local packages are verified against the registry manifest checksum; GitHub packages are re-fetched when missing/corrupt.
# With enforce_lock set, remote package content must match the checksum recorded in rack.lock.
public def install_pkg(proj_dir: str, name: str, ver: str, src: str, enforce_lock: bool) -> Result[str, str] {
    if src.len() > 0 {
        cached = ensure_cached(proj_dir, name, ver, src, enforce_lock)
        if cached.is_err() {
            msg = "cannot fetch " + name + "@" + ver
            match cached {
                case Err(e) => msg = e
                case _ => msg = "cannot fetch " + name + "@" + ver
            }
            return Result[str, str].Err(msg)
        }
    }
    mt = pkg_manifest_text(name, ver, src)
    if mt.len() > 0 {
        pm = new_manifest()
        if manifest_parse(mt, @var pm) == "" and pm.checksum.len() > 0 {
            actual = file_sha256(pkg_module_path(name, ver, src))
            if actual.len() == 0 {
                return Result[str, str].Err("cannot verify checksum for `" + name + "@" + ver + "`")
            }
            if actual != pm.checksum {
                if src.len() > 0 {
                    return Result[str, str].Err(checksum_mismatch_msg(name, ver, src, pm.checksum, actual))
                }
                return Result[str, str].Err("checksum mismatch for `" + name + "@" + ver + "` (registry copy is corrupted)")
            }
        }
    }
    deps_dir = path_join(proj_dir, "target/deps")
    if not mkdirs(deps_dir) {
        return Result[str, str].Err("cannot create " + deps_dir)
    }
    dst = path_join(deps_dir, name + ".rg")
    c = copy_file(pkg_module_path(name, ver, src), dst)
    if c.is_err() {
        if src.len() > 0 {
            return Result[str, str].Err("package `" + name + "@" + ver + "` is not cached from " + src)
        }
        return Result[str, str].Err("package `" + name + "@" + ver +
        "` not found in registry " + registry_dir())
    }
    return Result[str, str].Ok(ver)
}

# Publish: publish <name>.rg from the project root, along with rack.toml (if present), to the local registry
public def publish_pkg(proj_dir: str, name: str, ver: str) -> Result[None, str] {
    src = path_join(proj_dir, name + ".rg")
    r = read_file(src)
    if r.is_err() {
        return Result[None, str].Err("no module file `" + src + "` in project root")
    }
    dir = registry_dir() + "/" + name + "/" + ver
    if not mkdirs(dir) {
        return Result[None, str].Err("cannot create " + dir)
    }
    w = write_file(path_join(dir, name + ".rg"), r.unwrap())
    if w.is_err() {
        return Result[None, str].Err("cannot write to " + dir)
    }
    # Store the manifest too: transitive resolution depends on it; the checksum records the module file digest
    mf = read_file(path_join(proj_dir, "rack.toml"))
    if mf.is_ok() {
        pm = new_manifest()
        if manifest_parse(mf.unwrap(), @var pm) == "" {
            pm.checksum = file_sha256(src)
            wm = mf_save(@pm, path_join(dir, "rack.toml"))
            if wm.is_err() {
                return Result[None, str].Err("cannot write manifest to " + dir)
            }
        } else {
            # Non-standard manifest: store as-is
            wm = write_file(path_join(dir, "rack.toml"), mf.unwrap())
            if wm.is_err() {
                return Result[None, str].Err("cannot write manifest to " + dir)
            }
        }
    }
    return Result[None, str].Ok(None)
}

# Checksum of name@ver in the registry/cache (for writing to the lock file)
public def registry_checksum(name: str, ver: str, src: str) -> str {
    return pkg_checksum(name, ver, src)
}
