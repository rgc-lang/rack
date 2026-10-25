# selfmgmt.rg — RGC toolchain management (`rack self ...`)
#
# Downloads release archives from the RGC download center, verifies their sha256,
# installs them under ~/.rgc/toolchains/<version>, and keeps the ~/.rgc/bin shims
# in sync. install.sh / install.ps1 only bootstrap the first rack binary; every
# install, update, switch and removal after that runs here, in RGC.
#
# Layout:
#   ~/.rgc/bin/{rgc,rack}[.exe]              entry points (copies, not symlinks)
#   ~/.rgc/toolchains/<version>/bin/...      installed toolchains
#   ~/.rgc/toolchains/<version>/lib/*.rg     stdlib next to the compiler
#   ~/.rgc/settings.toml                     default version + channel
#
# Environment:
#   RGC_HOME        toolchain root (default: ~/.rgc)
#   RACK_DIST_URL   download center (default: https://rgc-dev.tensorplay.cn/dist)
#   RACK_PLATFORM   platform override, e.g. linux-x64

import bin
import bytes
import gzip
import http
import json
import os
import random
import sha2
import string
import tar
import time
import toml
import util

public class SelfPlatform {
    ok: bool
    error: str
    key: str
    os: str
    arch: str
    ext: str
    is_windows: bool
}

public class SelfSettings {
    ok: bool
    error: str
    default_version: str
    channel: str
}

public class SelfManifest {
    ok: bool
    error: str
    version: str
    rgc_url: str
    rgc_sha: str
    rack_url: str
    rack_sha: str
}

public class SelfResolution {
    ok: bool
    error: str
    version: str
    channel: str
}

public class SelfText {
    ok: bool
    error: str
    text: str
}

public class SelfOptions {
    ok: bool
    error: str
    rest: List[str]
    platform: str
    force: bool
    yes: bool
    shell: str
}

# ---------- environment / platform ----------

def self_env(name: str) -> str {
    v = os.getenv(name)
    if v.is_nothing() {
        return ""
    }
    return util.trim_ws(v.unwrap())
}

def self_trim_slash(s: str) -> str {
    out = s
    while out.endswith("/") and out.len() > 1 {
        out = out.slice(0, out.len() - 1)
    }
    return out
}

# Toolchain root; "" when no home directory can be found.
def self_root() -> str {
    override = self_env("RGC_HOME")
    if override.len() > 0 {
        return self_trim_slash(override)
    }
    home = self_env("HOME")
    if home.len() == 0 {
        home = self_env("USERPROFILE")
    }
    if home.len() == 0 {
        home = self_env("HOMEDRIVE") + self_env("HOMEPATH")
    }
    if home.len() == 0 {
        return ""
    }
    return self_trim_slash(home) + "/.rgc"
}

def self_dist_base() -> str {
    b = self_trim_slash(self_env("RACK_DIST_URL"))
    if b.len() == 0 {
        return "https://rgc-dev.tensorplay.cn/dist"
    }
    return b
}

def self_unique(prefix: str) -> str {
    return prefix + "-" + to_string(time.now()) + "-" + to_string(random.random_int(0, 999999))
}

def self_new_platform() -> SelfPlatform {
    p = SelfPlatform()
    p.ok = False
    p.error = ""
    p.key = ""
    p.os = ""
    p.arch = ""
    p.ext = ""
    p.is_windows = False
    return p
}

def self_normalize_arch(raw: str) -> str {
    a = raw
    if a == "x86_64" or a == "amd64" or a == "x64" {
        return "x64"
    }
    if a == "aarch64" or a == "arm64" {
        return "arm64"
    }
    return ""
}

def self_platform_from_parts(os_name: str, arch_raw: str) -> SelfPlatform {
    p = self_new_platform()
    arch = self_normalize_arch(arch_raw)
    if os_name != "linux" and os_name != "macos" and os_name != "windows" {
        p.error = "unsupported operating system: " + os_name
        return p
    }
    if arch.len() == 0 {
        p.error = "unsupported architecture: " + arch_raw
        return p
    }
    p.ok = True
    p.os = os_name
    p.arch = arch
    p.key = os_name + "-" + arch
    p.is_windows = os_name == "windows"
    if p.is_windows {
        p.ext = ".exe"
    }
    return p
}

def self_platform_from_key(key: str) -> SelfPlatform {
    p = self_new_platform()
    dash = util.find_char(key, "-")
    if dash <= 0 or dash + 1 >= key.len() {
        p.error = "invalid platform `" + key + "` (expected <os>-<arch>, e.g. linux-x64)"
        return p
    }
    return self_platform_from_parts(key.slice(0, dash), key.slice(dash + 1, key.len()))
}

# Read `uname -s` / `uname -m` through a temp file (RGC has no command-output capture).
def self_uname() -> List[str] {
    out = List[str]()
    d = self_env("TMPDIR")
    if d.len() == 0 {
        d = "/tmp"
    }
    d = self_trim_slash(d)
    path = d + "/.rack-uname-" + to_string(time.now()) + "-" + to_string(random.random_int(0, 999999))
    system("uname -s > '" + path + "' 2>/dev/null; uname -m >> '" + path + "' 2>/dev/null")
    text = util.read_file_or(path)
    if exists(path) {
        remove_file(path)
    }
    return string.lines(text)
}

def self_platform_detect(override: str) -> SelfPlatform {
    raw = override
    if raw.len() == 0 {
        raw = self_env("RACK_PLATFORM")
    }
    if raw.len() > 0 {
        return self_platform_from_key(raw)
    }

    if self_env("OS") == "Windows_NT" {
        arch = self_env("PROCESSOR_ARCHITECTURE")
        if arch.len() == 0 {
            arch = self_env("PROCESSOR_ARCHITEW6432")
        }
        return self_platform_from_parts("windows", arch)
    }

    lines = self_uname()
    if lines.len() < 2 {
        p = self_new_platform()
        p.error = "cannot detect the platform (uname failed); pass --platform <os>-<arch>"
        return p
    }
    os_raw = util.trim_ws(lines.get(0))
    arch_raw = util.trim_ws(lines.get(1))
    os_name = ""
    if os_raw == "Linux" {
        os_name = "linux"
    } elif os_raw == "Darwin" {
        os_name = "macos"
    } else {
        p = self_new_platform()
        p.error = "unsupported operating system: " + os_raw + "; pass --platform <os>-<arch>"
        return p
    }
    return self_platform_from_parts(os_name, arch_raw)
}

# ---------- shell helpers ----------

def self_quote(path: str, plat: @SelfPlatform) -> str {
    if plat.is_windows {
        return "\"" + path + "\""
    }
    return "'" + string.replace(path, "'", "'\\''") + "'"
}

def self_mkdir(path: str, plat: @SelfPlatform) -> bool {
    q = self_quote(path, @plat)
    if plat.is_windows {
        return system("cmd /C if not exist " + q + " mkdir " + q) == 0
    }
    return system("mkdir -p " + q) == 0
}

def self_remove_file(path: str, plat: @SelfPlatform) {
    q = self_quote(path, @plat)
    if plat.is_windows {
        system("cmd /C if exist " + q + " del /F /Q " + q + " >NUL 2>NUL")
    } else {
        system("rm -f " + q)
    }
}

def self_remove_dir(path: str, plat: @SelfPlatform) {
    q = self_quote(path, @plat)
    if plat.is_windows {
        system("cmd /C if exist " + q + " rmdir /S /Q " + q + " >NUL 2>NUL")
    } else {
        system("rm -rf " + q)
    }
}

def self_move(src: str, dst: str, plat: @SelfPlatform) -> bool {
    qs = self_quote(src, @plat)
    qd = self_quote(dst, @plat)
    if plat.is_windows {
        return system("cmd /C move /Y " + qs + " " + qd + " >NUL") == 0
    }
    return system("mv -f " + qs + " " + qd) == 0
}

def self_chmod_x(path: str, plat: @SelfPlatform) {
    if not plat.is_windows {
        system("chmod 755 " + self_quote(path, @plat))
    }
}

def self_tmp_file(name: str, plat: @SelfPlatform) -> str {
    root = self_root()
    dir = root + "/tmp"
    self_mkdir(dir, @plat)
    return dir + "/" + self_unique(name)
}

def self_toolchain_dir(version: str) -> str {
    return self_root() + "/toolchains/" + version
}

def self_bin_component(component: str, version: str, plat: @SelfPlatform) -> str {
    return self_toolchain_dir(version) + "/bin/" + component + plat.ext
}

def self_installed(version: str, plat: @SelfPlatform) -> bool {
    if version.len() == 0 {
        return False
    }
    dir = self_toolchain_dir(version)
    if not exists(dir + "/bin/rgc" + plat.ext) {
        return False
    }
    if not exists(dir + "/bin/rack" + plat.ext) {
        return False
    }
    return exists(dir + "/lib")
}

# ---------- settings.toml ----------

def self_settings_load() -> SelfSettings {
    s = SelfSettings()
    s.ok = True
    s.error = ""
    s.default_version = ""
    s.channel = "stable"
    path = self_root() + "/settings.toml"
    if not exists(path) {
        return s
    }
    text = util.read_file_or(path)
    doc = toml.toml_new_doc()
    err = toml.toml_parse(text, @var doc)
    if err != "" {
        s.ok = False
        s.error = "invalid " + path + ": " + err
        return s
    }
    default_version = toml.toml_get(@doc, "", "default")
    channel = toml.toml_get(@doc, "", "channel")
    if default_version.len() > 0 and self_valid_token(default_version) {
        s.default_version = default_version
    }
    if channel.len() > 0 and self_valid_token(channel) {
        s.channel = channel
    }
    return s
}

def self_settings_save(default_version: str, channel: str) -> str {
    root = self_root()
    path = root + "/settings.toml"
    tmp = path + ".tmp-" + to_string(time.now())
    text = "# Generated by rack self. Do not edit by hand.\n" +
    "default = " + toml.toml_escape_str(default_version) + "\n" +
    "channel = " + toml.toml_escape_str(channel) + "\n"
    w = write_file(tmp, text)
    if w.is_err() {
        return "cannot write " + tmp
    }
    plat = self_platform_detect("")
    if not self_move(tmp, path, @plat) {
        if exists(tmp) {
            remove_file(tmp)
        }
        return "cannot replace " + path
    }
    return ""
}

# ---------- HTTP ----------

def self_http_get_text(url: str) -> SelfText {
    r = SelfText()
    r.ok = False
    r.error = ""
    r.text = ""

    client = http.new_client()
    client.timeout_ms = 120000
    client.connect_timeout_ms = 30000
    client.max_body = 8388608
    client.headers.push("User-Agent: rack-self/0.4 (RGC)")
    response = client.get(url)
    client.close()

    if not response.ok {
        r.error = response.error + " (" + url + ")"
        return r
    }
    status = response.response.status
    if status < 200 or status >= 300 {
        r.error = "HTTP " + to_string(status) + " from " + url
        return r
    }
    r.ok = True
    r.text = response.response.body
    return r
}

def self_sha256_hex(data: @Bytes) -> str {
    digest = sha2.sha256(@data)
    return bin.to_hex(@digest)
}

def self_is_hex64(s: str) -> bool {
    if s.len() != 64 {
        return False
    }
    i = 0
    while i < s.len() {
        c = s.char_at(i)
        ok = (c >= 48 and c <= 57) or (c >= 97 and c <= 102) or (c >= 65 and c <= 70)
        if not ok {
            return False
        }
        i = i + 1
    }
    return True
}

# ---------- versions / manifest ----------

def self_valid_token(s: str) -> bool {
    if s.len() == 0 or s == "." or s == ".." {
        return False
    }
    c0 = s.char_at(0)
    if (c0 < 48 or c0 > 57) and (c0 < 65 or c0 > 90) and (c0 < 97 or c0 > 122) {
        return False
    }
    i = 0
    while i < s.len() {
        c = s.char_at(i)
        ok = (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or
        c == 46 or c == 45 or c == 43 or c == 95
        if not ok {
            return False
        }
        i = i + 1
    }
    return s.find("..") < 0
}

def self_channel_version(channel: str) -> SelfResolution {
    out = SelfResolution()
    out.ok = False
    out.error = ""
    out.version = ""
    out.channel = channel

    url = self_dist_base() + "/channels/" + channel + ".json"
    page = self_http_get_text(url)
    if not page.ok {
        out.error = page.error
        return out
    }
    parsed = json.parse(page.text)
    if not parsed.ok {
        out.error = "invalid channel metadata from " + url + ": " + parsed.error
        return out
    }
    root = parsed.value
    version = json.as_str(json.get(@root, "version"))
    if version.len() == 0 or not self_valid_token(version) {
        out.error = "channel `" + channel + "` has no valid version at " + url
        return out
    }
    out.ok = True
    out.version = version
    return out
}

def self_resolve_version(spec: str) -> SelfResolution {
    out = SelfResolution()
    out.ok = False
    out.error = ""
    out.version = ""
    out.channel = ""

    if spec.len() == 0 or spec == "stable" or spec == "nightly" {
        channel = spec
        if channel.len() == 0 {
            channel = "stable"
        }
        return self_channel_version(channel)
    }
    if not self_valid_token(spec) {
        out.error = "invalid version or channel: `" + spec + "`"
        return out
    }
    out.ok = True
    out.version = spec
    return out
}

def self_join_url(base: str, part: str) -> str {
    if part.startswith("http://") or part.startswith("https://") {
        return part
    }
    if part.startswith("/") {
        return base + part
    }
    return base + "/" + part
}

def self_fetch_manifest(version: str, plat: @SelfPlatform) -> SelfManifest {
    m = SelfManifest()
    m.ok = False
    m.error = ""
    m.version = version
    m.rgc_url = ""
    m.rgc_sha = ""
    m.rack_url = ""
    m.rack_sha = ""

    base = self_dist_base()
    url = base + "/versions/" + version + "/manifest.json"
    page = self_http_get_text(url)
    if not page.ok {
        m.error = page.error + " (is version " + version + " published?)"
        return m
    }
    parsed = json.parse(page.text)
    if not parsed.ok {
        m.error = "invalid manifest from " + url + ": " + parsed.error
        return m
    }
    root = parsed.value
    declared = json.as_str(json.get(@root, "version"))
    if declared.len() > 0 and declared != version {
        m.error = "manifest at " + url + " declares version " + declared
        return m
    }

    assets = json.get(@root, "assets")
    if not json.has_key(@assets, plat.key) {
        m.error = "release " + version + " has no assets for " + plat.key
        return m
    }
    platform_assets = json.get(@assets, plat.key)

    rgc_asset = json.get(@platform_assets, "rgc")
    rack_asset = json.get(@platform_assets, "rack")
    if json.stringify(@rgc_asset) == "null" {
        m.error = "release " + version + " has no rgc asset for " + plat.key
        return m
    }
    if json.stringify(@rack_asset) == "null" {
        m.error = "release " + version + " has no rack asset for " + plat.key
        return m
    }

    rgc_raw = json.as_str(json.get(@rgc_asset, "url"))
    rack_raw = json.as_str(json.get(@rack_asset, "url"))
    if rgc_raw.len() == 0 or rack_raw.len() == 0 {
        m.error = "release " + version + " has an asset without a URL for " + plat.key
        return m
    }
    m.rgc_url = self_join_url(base, rgc_raw)
    m.rgc_sha = json.as_str(json.get(@rgc_asset, "sha256"))
    m.rack_url = self_join_url(base, rack_raw)
    m.rack_sha = json.as_str(json.get(@rack_asset, "sha256"))
    if not self_is_hex64(m.rgc_sha) or not self_is_hex64(m.rack_sha) {
        m.error = "release " + version + " has an invalid sha256 for " + plat.key
        return m
    }
    m.ok = True
    return m
}

# ---------- download / extract ----------

def self_download(url: str, dest: str, expected_sha: str, label: str) -> str {
    want = string.to_lower(expected_sha)
    last = ""
    attempt = 1
    while attempt <= 3 {
        print("  downloading " + label)
        client = http.new_client()
        client.timeout_ms = 300000
        client.connect_timeout_ms = 30000
        client.max_body = 0
        client.headers.push("User-Agent: rack-self/0.4 (RGC)")
        response = client.get(url)
        client.close()

        if not response.ok {
            last = "cannot download " + url + ": " + response.error
        } elif response.response.status < 200 or response.response.status >= 300 {
            last = "cannot download " + url + ": HTTP " + to_string(response.response.status)
        } else {
            data = response.response.body_bytes
            actual = self_sha256_hex(@data)
            if string.to_lower(actual) == want {
                w = bytes.write_bytes(dest, @data)
                if not w.ok {
                    return "cannot write " + dest + ": " + w.error
                }
                print("  verified sha256 " + want)
                return ""
            }
            last = "checksum mismatch for " + url + ": expected " + want + ", got " + actual
        }
        if attempt < 3 {
            print("  " + last + "; retrying")
            time.sleep(1.0)
        }
        attempt = attempt + 1
    }
    return last
}

def self_archive_name_ok(name: str) -> bool {
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

def self_strip_dot_slash(name: str) -> str {
    out = name
    while out.startswith("./") {
        out = out.slice(2, out.len())
    }
    return out
}

def self_write_entry(data: @Bytes, offset: int, size: int, dest: str) -> str {
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

def self_extract_component(archive: str, component: str, stage: str, plat: @SelfPlatform) -> str {
    r = bytes.read_bytes(archive)
    if not r.ok {
        return "cannot read " + archive + ": " + r.error
    }
    compressed = r.data
    gz = gzip.decompress(@compressed)
    if not gz.ok {
        return "cannot decompress " + archive + ": " + gz.error
    }
    tar_data = gz.data
    listing = tar.list_entries(@tar_data)
    if not listing.ok {
        return "cannot read " + archive + ": " + listing.error
    }

    bin_dir = stage + "/bin"
    if not self_mkdir(bin_dir, @plat) {
        return "cannot create " + bin_dir
    }
    if component == "rgc" {
        if not self_mkdir(stage + "/lib", @plat) {
            return "cannot create " + stage + "/lib"
        }
    }

    ext = plat.ext
    target_bin = bin_dir + "/" + component + ext
    found = False
    i = 0
    while i < listing.entries.len() {
        entry = listing.entries.get(i)
        if entry.kind == 0 {
            name = self_strip_dot_slash(entry.name)
            if not self_archive_name_ok(name) {
                return "unsafe path in " + archive + ": " + entry.name
            }
            is_bin = name == component or name == component + ".exe" or
                     name == "bin/" + component or name == "bin/" + component + ".exe"
            if is_bin {
                err = self_write_entry(@tar_data, entry.offset, entry.size, target_bin)
                if err != "" {
                    return err
                }
                self_chmod_x(target_bin, @plat)
                found = True
            } elif component == "rgc" and name.startswith("lib/") {
                rel = name.slice(4, name.len())
                if rel.len() > 0 {
                    dest = stage + "/lib/" + rel
                    parent = util.dir_name(dest)
                    if parent.len() > 0 and not self_mkdir(parent, @plat) {
                        return "cannot create " + parent
                    }
                    err = self_write_entry(@tar_data, entry.offset, entry.size, dest)
                    if err != "" {
                        return err
                    }
                }
            }
        }
        i = i + 1
    }
    if not found {
        return archive + " does not contain a " + component + " binary"
    }
    return ""
}

# ---------- shims ----------

def self_install_shim(component: str, version: str, plat: @SelfPlatform) -> str {
    src = self_bin_component(component, version, @plat)
    if not exists(src) {
        return "missing " + src
    }
    bin_dir = self_root() + "/bin"
    if not self_mkdir(bin_dir, @plat) {
        return "cannot create " + bin_dir
    }
    data = bytes.read_bytes(src)
    if not data.ok {
        return "cannot read " + src + ": " + data.error
    }
    dst = bin_dir + "/" + component + plat.ext
    tmp = bin_dir + "/." + component + ".new-" + to_string(time.now())
    payload = data.data
    w = bytes.write_bytes(tmp, @payload)
    if not w.ok {
        return "cannot write " + tmp + ": " + w.error
    }
    self_chmod_x(tmp, @plat)
    if plat.is_windows and exists(dst) {
        # Windows refuses to replace a running .exe in place; move it aside first.
        old = bin_dir + "/." + component + ".old-" + to_string(time.now())
        self_move(dst, old, @plat)
    }
    if not self_move(tmp, dst, @plat) {
        self_remove_file(tmp, @plat)
        return "cannot replace " + dst
    }
    return ""
}

# The compiler searches lib/ next to its executable. bin/rgc is a copy, so the
# active toolchain's stdlib is exposed as bin/lib (symlink on Unix, junction on
# Windows); without it, installed shims cannot resolve `import string` etc.
def self_link_stdlib(version: str, plat: @SelfPlatform) -> str {
    lib_src = self_toolchain_dir(version) + "/lib"
    if not exists(lib_src) {
        return "missing " + lib_src
    }
    bin_dir = self_root() + "/bin"
    if not self_mkdir(bin_dir, @plat) {
        return "cannot create " + bin_dir
    }
    dst = bin_dir + "/lib"
    self_remove_dir(dst, @plat)
    qs = self_quote(lib_src, @plat)
    qd = self_quote(dst, @plat)
    rc = 0
    if plat.is_windows {
        rc = system("cmd /C mklink /J " + qd + " " + qs + " >NUL 2>NUL")
    } else {
        rc = system("ln -s " + qs + " " + qd)
    }
    if rc != 0 {
        return "cannot link " + dst + " -> " + lib_src
    }
    return ""
}

def self_activate(version: str, plat: @SelfPlatform) -> str {
    err = self_install_shim("rgc", version, @plat)
    if err != "" {
        return err
    }
    err = self_install_shim("rack", version, @plat)
    if err != "" {
        return err
    }
    return self_link_stdlib(version, @plat)
}

# ---------- install ----------

def self_install_toolchain(m: @SelfManifest, version: str, plat: @SelfPlatform, force: bool) -> int {
    root = self_root()
    stage = root + "/toolchains/." + version + ".tmp"
    self_remove_dir(stage, @plat)
    if not self_mkdir(stage + "/bin", @plat) {
        print("error: cannot create " + stage)
        return 1
    }

    rgc_archive = self_tmp_file("rgc-" + version + ".tar.gz", @plat)
    rack_archive = self_tmp_file("rack-" + version + ".tar.gz", @plat)

    print("installing rgc " + version + " (" + plat.key + ")")
    err = self_download(m.rgc_url, rgc_archive, m.rgc_sha, "rgc " + version)
    if err == "" {
        err = self_download(m.rack_url, rack_archive, m.rack_sha, "rack " + version)
    }
    if err == "" {
        err = self_extract_component(rgc_archive, "rgc", stage, @plat)
    }
    if err == "" {
        err = self_extract_component(rack_archive, "rack", stage, @plat)
    }
    self_remove_file(rgc_archive, @plat)
    self_remove_file(rack_archive, @plat)
    if err != "" {
        self_remove_dir(stage, @plat)
        print("error: " + err)
        return 1
    }

    final = self_toolchain_dir(version)
    if exists(final) {
        if not force {
            self_remove_dir(stage, @plat)
            print("error: toolchain directory already exists: " + final + " (use --force to reinstall)")
            return 1
        }
        self_remove_dir(final, @plat)
    }
    if not self_move(stage, final, @plat) {
        self_remove_dir(stage, @plat)
        print("error: cannot move the toolchain into " + final)
        return 1
    }
    return 0
}

def self_install_version(version: str, channel: str, plat: @SelfPlatform, force: bool) -> int {
    installed = self_installed(version, @plat)
    if installed and not force {
        print("rgc " + version + " is already installed")
    } else {
        m = self_fetch_manifest(version, @plat)
        if not m.ok {
            print("error: " + m.error)
            return 1
        }
        rc = self_install_toolchain(@m, version, @plat, force)
        if rc != 0 {
            return rc
        }
    }

    err = self_activate(version, @plat)
    if err != "" {
        print("error: " + err)
        return 1
    }
    settings = self_settings_load()
    if not settings.ok {
        print("error: " + settings.error)
        return 1
    }
    keep_channel = settings.channel
    if channel.len() > 0 {
        keep_channel = channel
    }
    err = self_settings_save(version, keep_channel)
    if err != "" {
        print("error: " + err)
        return 1
    }

    print("installed rgc " + version + " in " + self_toolchain_dir(version))
    print("default toolchain: " + version)
    bin_dir = self_root() + "/bin"
    if not self_path_has(bin_dir, @plat) {
        print("hint: add " + bin_dir + " to PATH (run `rack self env`)")
    }
    return 0
}

def self_cmd_install(spec: str, plat: @SelfPlatform, force: bool) -> int {
    res = self_resolve_version(spec)
    if not res.ok {
        print("error: " + res.error)
        return 1
    }
    return self_install_version(res.version, res.channel, @plat, force)
}

def self_cmd_update(plat: @SelfPlatform, force: bool) -> int {
    settings = self_settings_load()
    if not settings.ok {
        print("error: " + settings.error)
        return 1
    }
    channel = settings.channel
    if channel.len() == 0 {
        channel = "stable"
    }
    res = self_channel_version(channel)
    if not res.ok {
        print("error: " + res.error)
        return 1
    }
    if self_installed(res.version, @plat) and not force {
        if settings.default_version == res.version {
            print("rgc " + res.version + " is up to date")
            return 0
        }
    }
    return self_install_version(res.version, res.channel, @plat, force)
}

# ---------- inspection ----------

def self_path_has(dir: str, plat: @SelfPlatform) -> bool {
    path = self_env("PATH")
    sep = ":"
    if plat.is_windows {
        sep = ";"
    }
    want = self_trim_slash(dir)
    for entry in path.split(sep) {
        if self_trim_slash(entry) == want {
            return True
        }
    }
    return False
}

def self_sort_versions(names: List[str]) -> List[str] {
    out = List[str]()
    i = 0
    while i < names.len() {
        out.push(names.get(i))
        i = i + 1
    }
    i = 1
    while i < out.len() {
        j = i
        while j > 0 and util.version_compare(out.get(j - 1), out.get(j)) < 0 {
            tmp = out.get(j - 1)
            out.set(j - 1, out.get(j))
            out.set(j, tmp)
            j = j - 1
        }
        i = i + 1
    }
    return out
}

def self_list_versions(plat: @SelfPlatform) -> List[str] {
    out = List[str]()
    dir = self_root() + "/toolchains"
    if not exists(dir) {
        return out
    }
    tmp = self_tmp_file("ls", @plat)
    q = self_quote(dir, @plat)
    outq = self_quote(tmp, @plat)
    if plat.is_windows {
        system("cmd /C dir /b /ad " + q + " > " + outq + " 2>NUL")
    } else {
        system("ls -1 " + q + " > " + outq + " 2>/dev/null")
    }
    text = util.read_file_or(tmp)
    self_remove_file(tmp, @plat)
    for line in string.lines(text) {
        name = util.trim_ws(line)
        if name.len() > 0 and not name.startswith(".") and self_valid_token(name) {
            if exists(dir + "/" + name + "/bin/rgc" + plat.ext) {
                out.push(name)
            }
        }
    }
    return out
}

def self_cmd_list(plat: @SelfPlatform) -> int {
    settings = self_settings_load()
    if not settings.ok {
        print("error: " + settings.error)
        return 1
    }
    versions = self_list_versions(@plat)
    if versions.len() == 0 {
        print("no toolchains installed")
        return 0
    }
    sorted = self_sort_versions(versions)
    for v in sorted {
        if v == settings.default_version {
            print("  " + v + " (default)")
        } else {
            print("  " + v)
        }
    }
    return 0
}

def self_cmd_status(plat: @SelfPlatform) -> int {
    settings = self_settings_load()
    if not settings.ok {
        print("error: " + settings.error)
        return 1
    }
    root = self_root()
    print("home:     " + root)
    print("dist:     " + self_dist_base())
    print("platform: " + plat.key)
    if settings.default_version.len() == 0 {
        print("default:  (none)")
    } elif self_installed(settings.default_version, @plat) {
        print("default:  " + settings.default_version)
    } else {
        print("default:  " + settings.default_version + " (missing)")
    }
    print("channel:  " + settings.channel)
    versions = self_sort_versions(self_list_versions(@plat))
    if versions.len() == 0 {
        print("installed: (none)")
    } else {
        line = ""
        for v in versions {
            if line.len() > 0 {
                line = line + ", "
            }
            line = line + v
        }
        print("installed: " + line)
    }
    bin_dir = root + "/bin"
    if self_path_has(bin_dir, @plat) {
        print("bin:      " + bin_dir + " (on PATH)")
    } else {
        print("bin:      " + bin_dir + " (not on PATH)")
    }
    return 0
}

def self_cmd_default(version: str, plat: @SelfPlatform) -> int {
    if not self_valid_token(version) {
        print("error: invalid version: `" + version + "`")
        return 1
    }
    if not self_installed(version, @plat) {
        print("error: rgc " + version + " is not installed")
        print("hint:  run `rack self install " + version + "`")
        return 1
    }
    err = self_activate(version, @plat)
    if err != "" {
        print("error: " + err)
        return 1
    }
    settings = self_settings_load()
    if not settings.ok {
        print("error: " + settings.error)
        return 1
    }
    err = self_settings_save(version, settings.channel)
    if err != "" {
        print("error: " + err)
        return 1
    }
    print("default toolchain: " + version)
    return 0
}

def self_cmd_remove(version: str, plat: @SelfPlatform, force: bool) -> int {
    if not self_valid_token(version) {
        print("error: invalid version: `" + version + "`")
        return 1
    }
    if not self_installed(version, @plat) {
        print("error: rgc " + version + " is not installed")
        return 1
    }
    settings = self_settings_load()
    if not settings.ok {
        print("error: " + settings.error)
        return 1
    }
    is_default = settings.default_version == version
    if is_default and not force {
        print("error: refusing to remove the default toolchain " + version)
        print("hint:  switch first with `rack self default <version>`, or pass --force")
        return 1
    }
    self_remove_dir(self_toolchain_dir(version), @plat)
    if is_default {
        err = self_settings_save("", settings.channel)
        if err != "" {
            print("error: " + err)
            return 1
        }
        self_remove_file(self_root() + "/bin/rgc" + plat.ext, @plat)
        self_remove_file(self_root() + "/bin/rack" + plat.ext, @plat)
        print("removed rgc " + version + " (default cleared)")
        return 0
    }
    print("removed rgc " + version)
    return 0
}

def self_cmd_which(name: str, plat: @SelfPlatform) -> int {
    if name != "rgc" and name != "rack" {
        print("error: rack self which <rgc|rack>")
        return 1
    }
    path = self_root() + "/bin/" + name + plat.ext
    if not exists(path) {
        print("error: " + name + " is not installed (no " + path + ")")
        return 1
    }
    print(path)
    return 0
}

def self_cmd_env(shell: str) -> int {
    bin_dir = self_root() + "/bin"
    if shell == "sh" or shell == "bash" or shell == "zsh" or shell == "posix" {
        print("export PATH=\"" + bin_dir + ":$PATH\"")
        return 0
    }
    if shell == "fish" {
        print("fish_add_path \"" + bin_dir + "\"")
        return 0
    }
    if shell == "powershell" or shell == "pwsh" or shell == "ps" {
        print("$env:Path = \"" + bin_dir + ";$env:Path\"")
        return 0
    }
    print("error: unsupported shell `" + shell + "` (use sh, fish or powershell)")
    return 1
}

def self_cmd_uninstall(plat: @SelfPlatform, yes: bool) -> int {
    root = self_root()
    if not yes {
        print("this removes " + root + " and every installed toolchain")
        print("re-run with --yes to continue")
        return 1
    }
    if plat.is_windows {
        self_remove_dir(root + "/toolchains", @plat)
        self_remove_file(root + "/settings.toml", @plat)
        self_remove_dir(root + "/tmp", @plat)
        self_remove_file(root + "/bin/rgc" + plat.ext, @plat)
        self_remove_file(root + "/bin/rack" + plat.ext, @plat)
        self_remove_dir(root + "/bin", @plat)
        self_remove_dir(root, @plat)
        if exists(root) {
            print("warning: could not remove everything in " + root)
            print("hint:  close this shell and delete the directory by hand")
            return 1
        }
        print("removed " + root)
        return 0
    }
    if system("rm -rf " + self_quote(root, @plat)) != 0 or exists(root) {
        print("error: cannot remove " + root)
        return 1
    }
    print("removed " + root)
    return 0
}

# ---------- argument parsing ----------

def self_parse_options(argv: @List[str], start: int) -> SelfOptions {
    o = SelfOptions()
    o.ok = True
    o.error = ""
    o.rest = List[str]()
    o.platform = ""
    o.force = False
    o.yes = False
    o.shell = "sh"

    i = start
    while i < argv.len() {
        a = argv.get(i)
        if a == "--force" {
            o.force = True
        } elif a == "--yes" or a == "-y" {
            o.yes = True
        } elif a == "--platform" {
            if i + 1 >= argv.len() {
                o.ok = False
                o.error = "--platform needs a value (e.g. linux-x64)"
                return o
            }
            o.platform = argv.get(i + 1)
            i = i + 1
        } elif a.startswith("--platform=") {
            o.platform = a.slice(11, a.len())
        } elif a == "--shell" {
            if i + 1 >= argv.len() {
                o.ok = False
                o.error = "--shell needs a value (sh, fish or powershell)"
                return o
            }
            o.shell = argv.get(i + 1)
            i = i + 1
        } elif a.startswith("--shell=") {
            o.shell = a.slice(8, a.len())
        } elif a == "--" {
            i = i + 1
            while i < argv.len() {
                o.rest.push(argv.get(i))
                i = i + 1
            }
            return o
        } elif a.startswith("-") and a.len() > 1 {
            o.ok = False
            o.error = "unknown option `" + a + "`"
            return o
        } else {
            o.rest.push(a)
        }
        i = i + 1
    }
    return o
}

# ---------- command entry ----------

def self_usage() {
    print("rack self — manage RGC toolchains")
    print("")
    print("Usage: rack self <command> [arguments]")
    print("")
    print("Commands:")
    print("  install [stable|nightly|<version>]   install a toolchain and make it the default")
    print("  update                               install the latest stable toolchain as the default")
    print("  list                                 list installed toolchains")
    print("  default <version>                    switch the default toolchain")
    print("  remove <version>                     remove a toolchain (--force for the default)")
    print("  status                               show home, platform, default and PATH state")
    print("  which <rgc|rack>                     print the entry point that rack installed")
    print("  env [--shell sh|fish|powershell]     print the PATH setup for your shell")
    print("  uninstall --yes                      remove ~/.rgc and every toolchain")
    print("")
    print("Options: --force, --platform <os>-<arch>, --shell <name>")
    print("Environment: RGC_HOME, RACK_DIST_URL, RACK_PLATFORM")
}

public def cmd_self(argv: @List[str]) -> int {
    if argv.len() < 3 {
        self_usage()
        return 0
    }
    sub = argv.get(2)
    if sub == "help" or sub == "--help" or sub == "-h" {
        self_usage()
        return 0
    }

    opts = self_parse_options(@argv, 3)
    if not opts.ok {
        print("error: " + opts.error)
        return 1
    }

    root = self_root()
    if root.len() == 0 {
        print("error: cannot determine the home directory; set RGC_HOME")
        return 1
    }

    plat = self_platform_detect(opts.platform)
    if not plat.ok {
        print("error: " + plat.error)
        return 1
    }

    if sub == "install" {
        spec = ""
        if opts.rest.len() > 1 {
            print("error: rack self install [stable|nightly|<version>]")
            return 1
        }
        if opts.rest.len() == 1 {
            spec = opts.rest.get(0)
        }
        return self_cmd_install(spec, @plat, opts.force)
    }
    if sub == "update" {
        if opts.rest.len() != 0 {
            print("error: rack self update takes no arguments")
            return 1
        }
        return self_cmd_update(@plat, opts.force)
    }
    if sub == "list" {
        if opts.rest.len() != 0 {
            print("error: rack self list takes no arguments")
            return 1
        }
        return self_cmd_list(@plat)
    }
    if sub == "default" {
        if opts.rest.len() != 1 {
            print("error: rack self default <version>")
            return 1
        }
        return self_cmd_default(opts.rest.get(0), @plat)
    }
    if sub == "remove" {
        if opts.rest.len() != 1 {
            print("error: rack self remove <version>")
            return 1
        }
        return self_cmd_remove(opts.rest.get(0), @plat, opts.force)
    }
    if sub == "status" {
        return self_cmd_status(@plat)
    }
    if sub == "which" {
        if opts.rest.len() != 1 {
            print("error: rack self which <rgc|rack>")
            return 1
        }
        return self_cmd_which(opts.rest.get(0), @plat)
    }
    if sub == "env" {
        if opts.rest.len() != 0 {
            print("error: rack self env takes no arguments")
            return 1
        }
        return self_cmd_env(opts.shell)
    }
    if sub == "uninstall" {
        if opts.rest.len() != 0 {
            print("error: rack self uninstall takes no arguments")
            return 1
        }
        return self_cmd_uninstall(@plat, opts.yes)
    }

    print("error: unknown self command `" + sub + "`")
    print("hint: run `rack self help`")
    return 1
}
