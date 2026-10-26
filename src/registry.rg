import github
import lock
import manifest
import source
import util
import bytes
import gzip
import tar
import registry_api
import bin
import sha2

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

# web 注册表源标识：与 GitHub 源（github.com/...）并列。
public def registry_source() -> str {
    return "registry"
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

# Resolve the latest version by source: local registry, web registry or GitHub tags
public def lookup_latest(name: str, src: str) -> VersionLookup {
    out = new_version_lookup()
    if src == registry_source() {
        resolved = registry_api.reg_resolve(name, "")
        if not resolved.ok {
            out.error = resolved.error
            return out
        }
        out.ok = True
        out.version = resolved.version
        return out
    }
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

# Package version directory: local registry, web registry cache or GitHub cache
public def pkg_dir(name: str, ver: str, src: str) -> str {
    if src == registry_source() {
        return cache_dir() + "/registry/" + name + "/" + ver
    }
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
    base = name
    slash = find_char_last(name, "/")
    if slash >= 0 {
        base = name.slice(slash + 1, name.len())
    }
    return d + "/" + base + ".rg"
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

# ---- web 注册表包：下载 / 校验 / 解压 ----

def reg_strip_dot_slash(name: str) -> str {
    out = name
    while out.startswith("./") {
        out = out.slice(2, out.len())
    }
    return out
}

def reg_archive_name_ok(name: str) -> bool {
    if name.len() == 0 or name.startswith("/") {
        return False
    }
    parts = name.split("/")
    for part in parts {
        if part == ".." {
            return False
        }
    }
    return True
}

def reg_write_entry(data: @Bytes, offset: int, size: int, dest: str) -> str {
    if offset < 0 or size < 0 or offset + size > data.len {
        return "truncated entry for " + dest
    }
    payload = data.slice(offset, offset + size)
    w = bytes.write_bytes(dest, @payload)
    if not w.ok {
        return "cannot write " + dest + ": " + w.error
    }
    return ""
}

# 把内存中的 tar.gz 完整解压到 dest 目录（带路径安全校验）。
def reg_extract_archive(data: @Bytes, dest: str) -> str {
    gz = gzip.decompress(@data)
    if not gz.ok {
        return "cannot decompress archive: " + gz.error
    }
    tar_data = gz.data
    listing = tar.list_entries(@tar_data)
    if not listing.ok {
        return "cannot read archive: " + listing.error
    }
    i = 0
    while i < listing.entries.len() {
        entry = listing.entries.get(i)
        name = reg_strip_dot_slash(entry.name)
        if not reg_archive_name_ok(name) {
            return "unsafe path in archive: " + entry.name
        }
        if entry.kind == 5 {
            if not util.mkdirs(dest + "/" + name) {
                return "cannot create " + dest + "/" + name
            }
        } elif entry.kind == 0 {
            dest_path = dest + "/" + name
            parent = util.dir_name(dest_path)
            if parent.len() > 0 and not util.mkdirs(parent) {
                return "cannot create " + parent
            }
            err = reg_write_entry(@tar_data, entry.offset, entry.size, dest_path)
            if err != "" {
                return err
            }
        }
        i = i + 1
    }
    return ""
}

# 计算内存字节的 sha256（hex）。
def reg_sha256_hex(data: @Bytes) -> str {
    h = sha2.sha256(@data)
    return bin.to_hex(@h)
}

# 从 web 注册表下载包版本，校验 sha256，解压/落盘到 dest_dir。
# 归档包：完整源码树；单文件包：<name>.rg + rack.toml。
# 返回错误串（空=成功）。
public def fetch_registry_package(name: str, ver: str, dest_dir: str) -> Result[str, str] {
    dl = registry_api.reg_download(name, ver)
    if not dl.ok {
        return Result[str, str].Err(dl.error)
    }
    d = dl.data
    actual = reg_sha256_hex(@d)
    if actual != dl.cksum {
        return Result[str, str].Err("checksum mismatch for `" + name + "@" + dl.version + "`" +
            "\n  expected: " + dl.cksum + "\n  actual:   " + actual)
    }
    if dl.format == "archive" {
        err = reg_extract_archive(@d, dest_dir)
        if err != "" {
            return Result[str, str].Err(err)
        }
    } else {
        if not util.mkdirs(dest_dir) {
            return Result[str, str].Err("cannot create " + dest_dir)
        }
        mname = name
        slash = find_char_last(name, "/")
        if slash >= 0 {
            mname = name.slice(slash + 1, name.len())
        }
        w = bytes.write_bytes(dest_dir + "/" + mname + ".rg", @d)
        if not w.ok {
            return Result[str, str].Err("cannot write " + mname + ".rg: " + w.error)
        }
        if dl.manifest.len() > 0 {
            wm = write_file(dest_dir + "/rack.toml", dl.manifest)
            if wm.is_err() {
                return Result[str, str].Err("cannot write rack.toml")
            }
        }
    }
    # 记录校验和标记（离线缓存复用 / 锁文件校验用）。
    wc = write_file(dest_dir + "/.cksum", dl.cksum)
    if wc.is_err() {
        return Result[str, str].Err("cannot write checksum marker")
    }
    return Result[str, str].Ok(dl.version)
}

# web 注册表源：确保缓存里有已校验的包内容（下载一次，后续离线复用）。
# 缓存有效性用 `.cksum` 标记文件 + 锁文件校验和判断（与 GitHub 源的 manifest.checksum 同理）。
def ensure_registry_cached(proj_dir: str, name: str, ver: str, enforce_lock: bool) -> Result[None, str] {
    dir = pkg_dir(name, ver, registry_source())
    expected = ""
    if enforce_lock {
        expected = locked_checksum(proj_dir, name, ver, registry_source())
    }
    marker = dir + "/.cksum"
    if expected.len() > 0 and read_file_or(marker) == expected {
        return Result[None, str].Ok(None)
    }
    tmp = dir + ".tmp"
    remove_dir_all(tmp)
    if not mkdirs(tmp) {
        return Result[None, str].Err("cannot create cache directory " + tmp)
    }
    r = fetch_registry_package(name, ver, tmp)
    if r.is_err() {
        msg = "cannot fetch " + name + "@" + ver + " from the registry"
        match r {
            case Err(e) => msg = e
            case _ => msg = "cannot fetch " + name + "@" + ver + " from the registry"
        }
        remove_dir_all(tmp)
        return Result[None, str].Err(msg)
    }
    actual = read_file_or(tmp + "/.cksum")
    if expected.len() > 0 and actual != expected {
        remove_dir_all(tmp)
        return Result[None, str].Err(checksum_mismatch_msg(name, ver, registry_source(), expected, actual))
    }
    remove_dir_all(dir)
    if not move_path(tmp, dir) {
        remove_dir_all(tmp)
        return Result[None, str].Err("cannot commit cache directory " + dir)
    }
    return Result[None, str].Ok(None)
}
# Local packages are verified against the registry manifest checksum; GitHub packages are re-fetched when missing/corrupt.
# With enforce_lock set, remote package content must match the checksum recorded in rack.lock.
public def install_pkg(proj_dir: str, name: str, ver: str, src: str, enforce_lock: bool) -> Result[str, str] {
    if src == registry_source() {
        cached = ensure_registry_cached(proj_dir, name, ver, enforce_lock)
        if cached.is_err() {
            msg = "cannot fetch " + name + "@" + ver + " from the registry"
            match cached {
                case Err(e) => msg = e
                case _ => msg = "cannot fetch " + name + "@" + ver + " from the registry"
            }
            return Result[str, str].Err(msg)
        }
        # 多文件归档包是完整项目源码树（rack 本身），不是单 `.rg` 依赖；
        # 用 `rack fetch <pkg>@<ver>` 拉取后在其目录里直接 `rack build`。
        dir = pkg_dir(name, ver, registry_source())
        if try_read(pkg_module_path(name, ver, registry_source())).is_err() {
            return Result[str, str].Err(
                "package `" + name + "@" + ver + "` is a multi-file archive (use `rack fetch " +
                name + "@" + ver + "` to download and build it)")
        }
    } elif src.len() > 0 {
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
