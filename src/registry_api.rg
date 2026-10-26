import http
import json
import os
import toml
import util
import bytes
import gzip
import tar

# registry_api.rg — web registry publish client (RGC-REGISTRY §8)
#
# `rack publish` pushes <name>.rg + rack.toml to the web registry instead of
# the local directory. The API base URL comes from RACK_REGISTRY_API (default
# https://registry.example.com); the publish token comes from RACK_PUBLISH_TOKEN
# or ~/.rack/credentials.toml (`[registry] token = "..."`, written by `rack login`).

public class RegResult {
    ok: bool
    error: str
    name: str
    version: str
}

def new_reg_result() -> RegResult {
    r = RegResult()
    r.ok = False
    r.error = ""
    r.name = ""
    r.version = ""
    return r
}

def reg_env(name: str) -> str {
    v = os.getenv(name)
    if v.is_nothing() {
        return ""
    }
    return util.trim_ws(v.unwrap())
}

public def reg_api_base() -> str {
    b = reg_env("RACK_REGISTRY_API")
    if b.len() == 0 {
        return "https://registry.example.com"
    }
    while b.endswith("/") {
        b = b.slice(0, b.len() - 1)
    }
    return b
}

# Read the publish token: RACK_PUBLISH_TOKEN wins, then ~/.rack/credentials.toml.
public def reg_token() -> str {
    t = reg_env("RACK_PUBLISH_TOKEN")
    if t.len() > 0 {
        return t
    }
    home = util.detect_home()
    path = util.path_join(home, ".rack/credentials.toml")
    text = util.read_file_or(path)
    if text.len() == 0 {
        return ""
    }
    doc = toml.toml_new_doc()
    err = toml.toml_parse(text, @var doc)
    if err.len() > 0 {
        return ""
    }
    return toml.toml_get(@doc, "registry", "token")
}

# Save the token to ~/.rack/credentials.toml ([registry] token = "...").
public def reg_save_token(token: str) -> Result[None, str] {
    home = util.detect_home()
    dir = util.path_join(home, ".rack")
    if not util.mkdirs(dir) {
        return Result[None, str].Err("cannot create " + dir)
    }
    text = "[registry]\ntoken = " + toml.toml_escape_str(token) + "\n"
    w = write_file(util.path_join(dir, "credentials.toml"), text)
    if w.is_err() {
        return Result[None, str].Err("cannot write credentials.toml")
    }
    return Result[None, str].Ok(None)
}

# PUT /api/v1/packages/new：单文件上传 module（UTF-8 文本），
# 多文件包额外携带 archive（base64 编码的 tar.gz 源码树）。
public def reg_publish(name: str, version: str, module: str, manifest: str,
                      description: str, homepage: str, repository: str,
                      keywords: List[str], archive_base64: str) -> RegResult {
    out = new_reg_result()
    token = reg_token()
    if token.len() == 0 {
        out.error = "no publish token: set RACK_PUBLISH_TOKEN or run `rack login --token <token>`"
        return out
    }
    obj = json.object()
    json.set(@obj, "name", json.str_value(name))
    json.set(@obj, "version", json.str_value(version))
    if description.len() > 0 {
        json.set(@obj, "description", json.str_value(description))
    }
    if homepage.len() > 0 {
        json.set(@obj, "homepage", json.str_value(homepage))
    }
    if repository.len() > 0 {
        json.set(@obj, "repository", json.str_value(repository))
    }
    if keywords.len() > 0 {
        arr = json.array()
        i = 0
        while i < keywords.len() {
            json.push(@arr, json.str_value(keywords.get(i)))
            i = i + 1
        }
        json.set(@obj, "keywords", arr)
    }
    if archive_base64.len() > 0 {
        json.set(@obj, "archive", json.str_value(archive_base64))
    } else {
        json.set(@obj, "module", json.str_value(module))
    }
    json.set(@obj, "manifest", json.str_value(manifest))
    body = json.stringify(@obj)

    headers = List[str]()
    headers.push("Authorization: Bearer " + token)
    headers.push("Content-Type: application/json")
    headers.push("User-Agent: rack/0.4 (RGC)")
    r = http.request_with("PUT", reg_api_base() + "/api/v1/packages/new", body, headers)
    if not r.ok {
        out.error = r.error
        return out
    }
    if r.response.status == 201 {
        out.ok = True
        out.name = name
        out.version = version
        return out
    }
    out.error = reg_error_message(r.response.status, r.response.body)
    return out
}

# ---- 多文件包：把项目目录打成 tar.gz 并 base64 ----

# 打包结果：与 TarResult/GzipResult 同风格（类承载 ok/error/data）。
public class RegArchiveResult {
    ok: bool
    error: str
    data: Bytes
}

def new_reg_archive() -> RegArchiveResult {
    r = RegArchiveResult()
    r.ok = False
    r.error = ""
    r.data = bytes.bytes_new(0)
    return r
}

# 顶层目录黑名单：这些目录不进发布归档（与 cargo package 的排除规则一致）。
def reg_skip_dir(name: str) -> bool {
    if name == "target" or name == ".git" or name == ".rack" or name == "node_modules" {
        return True
    }
    if name == ".docusaurus" or name == ".cache" or name == ".DS_Store" {
        return True
    }
    return False
}

# 递归添加目录内容到 tar；`rel` 以 `/` 分隔（tar 规范路径）。
def reg_add_dir_entries(b: @var TarBuilder, root: str, dir: str, depth: int) -> str {
    names = util.list_dir(dir)
    for name in names {
        if depth == 0 and reg_skip_dir(name) {
            continue
        }
        full = util.path_join(dir, name)
        rel = full.slice(root.len() + 1, full.len())
        if util.is_dir_path(full) {
            b.add_dir(rel)
            err = reg_add_dir_entries(@b, root, full, depth + 1)
            if err.len() > 0 {
                return err
            }
        } else {
            r = bytes.read_bytes(full)
            if not r.ok {
                return "cannot read " + full + ": " + r.error
            }
            d = r.data
            b.add_file(rel, @d)
        }
    }
    return ""
}

# 打包项目目录：根目录 rack.toml + 全部源码/构建文件（排除 target/.git 等）。
public def reg_build_archive(proj_dir: str) -> RegArchiveResult {
    out = new_reg_archive()
    mt = util.read_file_or(util.path_join(proj_dir, "rack.toml"))
    if mt.len() == 0 {
        out.error = "no rack.toml in " + proj_dir
        return out
    }
    b = tar.builder()
    b.add_file("rack.toml", bytes.bytes_from_str(mt))
    err = reg_add_dir_entries(@b, proj_dir, proj_dir, 0)
    if err.len() > 0 {
        out.error = err
        return out
    }
    t = b.finish()
    if not t.ok {
        out.error = t.error
        return out
    }
    td = t.data
    gz = gzip.compress(@td)
    if not gz.ok {
        out.error = gz.error
        return out
    }
    out.ok = True
    out.data = gz.data
    return out
}

# 对二进制字节做 base64（RGC stdlib 只公开了解码；编码逻辑与 http.rg 内部实现一致）。
public def reg_b64_encode_bytes(b: @Bytes) -> str {
    table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    out = ""
    n = b.len
    i = 0
    while i + 2 < n {
        b0 = b.get(i)
        b1 = b.get(i + 1)
        b2 = b.get(i + 2)
        out = out + chr(table.char_at(b0 / 4))
        out = out + chr(table.char_at((b0 % 4) * 16 + b1 / 16))
        out = out + chr(table.char_at((b1 % 16) * 4 + b2 / 64))
        out = out + chr(table.char_at(b2 % 64))
        i = i + 3
    }
    left = n - i
    if left == 1 {
        b0 = b.get(i)
        out = out + chr(table.char_at(b0 / 4))
        out = out + chr(table.char_at((b0 % 4) * 16))
        out = out + "=="
    } elif left == 2 {
        b0 = b.get(i)
        b1 = b.get(i + 1)
        out = out + chr(table.char_at(b0 / 4))
        out = out + chr(table.char_at((b0 % 4) * 16 + b1 / 16))
        out = out + chr(table.char_at((b1 % 16) * 4))
        out = out + "="
    }
    return out
}

# Parse the registry error body: {"error": {"code": "...", "message": "..."}}.
public def reg_error_message(status: int, body: str) -> str {
    p = json.parse(body)
    if p.ok {
        root = p.value
        err = json.get(@root, "error")
        if json.has_key(@err, "code") and json.has_key(@err, "message") {
            code = json.as_str(json.get(@err, "code"))
            msg = json.as_str(json.get(@err, "message"))
            return "HTTP " + to_string(status) + " " + code + ": " + msg
        }
    }
    if body.len() > 0 {
        return "HTTP " + to_string(status) + ": " + body
    }
    return "HTTP " + to_string(status)
}

# §10 CLI 登录（浏览器验证）：{registry}/cli/login 页面显示一次性 code（60s），
# CLI 用它换一个可命名、可撤销的 API token（POST /api/v1/auth/cli/token）。
public def reg_login_url() -> str {
    return reg_api_base() + "/cli/login"
}

public def reg_exchange_code(code: str) -> Result[str, str] {
    obj = json.object()
    json.set(@obj, "code", json.str_value(code))
    body = json.stringify(@obj)
    headers = List[str]()
    headers.push("Content-Type: application/json")
    headers.push("User-Agent: rack/0.4 (RGC)")
    r = http.request_with("POST", reg_api_base() + "/api/v1/auth/cli/token", body, headers)
    if not r.ok {
        return Result[str, str].Err(r.error)
    }
    if r.response.status != 200 {
        return Result[str, str].Err(reg_error_message(r.response.status, r.response.body))
    }
    p = json.parse(r.response.body)
    if not p.ok {
        return Result[str, str].Err("invalid login response")
    }
    root = p.value
    if not json.has_key(@root, "token") {
        return Result[str, str].Err("invalid login response")
    }
    token = json.as_str(json.get(@root, "token"))
    if token.len() == 0 {
        return Result[str, str].Err("invalid login response")
    }
    return Result[str, str].Ok(token)
}

# §10 OAuth 2.0 Device Flow（CLI 自动轮询 + 浏览器 /device 确认）。
# `rack login` 调用此函数启动设备流，然后按 interval 轮询 token。
public class DeviceFlow {
    device_code: str
    user_code: str
    verification_uri: str
    verification_uri_complete: str
    interval: int
    expires_in: int
}

# 启动结果（RGC 的 Result 泛型不支持自定义类载荷，且类中类字段访问存在
# 编译器缺陷，因此把 DeviceFlow 的字段全部拍平到结果类里）。
public class DeviceFlowResult {
    ok: bool
    error: str
    device_code: str
    user_code: str
    verification_uri: str
    verification_uri_complete: str
    interval: int
    expires_in: int
}

# 单次轮询结果：status 为 "ok"（拿到 token）/ "pending"（等待确认）/ "error"。
public class DevicePoll {
    status: str
    token: str
    error: str
}

def new_device_flow_result() -> DeviceFlowResult {
    r = DeviceFlowResult()
    r.ok = False
    r.error = ""
    r.device_code = ""
    r.user_code = ""
    r.verification_uri = ""
    r.verification_uri_complete = ""
    r.interval = 5
    r.expires_in = 0
    return r
}

def new_device_poll() -> DevicePoll {
    p = DevicePoll()
    p.status = "error"
    p.token = ""
    p.error = ""
    return p
}

public def reg_device_start() -> DeviceFlowResult {
    out = new_device_flow_result()
    headers = List[str]()
    headers.push("Content-Type: application/json")
    headers.push("User-Agent: rack/0.4 (RGC)")
    r = http.request_with("POST", reg_api_base() + "/api/v1/auth/device/codes", "", headers)
    if not r.ok {
        out.error = r.error
        return out
    }
    if r.response.status != 200 {
        out.error = reg_error_message(r.response.status, r.response.body)
        return out
    }
    p = json.parse(r.response.body)
    if not p.ok {
        out.error = "invalid device flow response"
        return out
    }
    root = p.value
    out.device_code = json.as_str(json.get(@root, "device_code"))
    out.user_code = json.as_str(json.get(@root, "user_code"))
    out.verification_uri = json.as_str(json.get(@root, "verification_uri"))
    out.verification_uri_complete = json.as_str(json.get(@root, "verification_uri_complete"))
    out.interval = json.as_int(json.get(@root, "interval"))
    out.expires_in = json.as_int(json.get(@root, "expires_in"))
    if out.device_code.len() == 0 or out.user_code.len() == 0 or out.verification_uri.len() == 0 {
        out.error = "invalid device flow response"
        return out
    }
    if out.interval <= 0 {
        out.interval = 5
    }
    out.ok = True
    return out
}

public def reg_device_poll(device_code: str) -> DevicePoll {
    out = new_device_poll()
    obj = json.object()
    json.set(@obj, "device_code", json.str_value(device_code))
    body = json.stringify(@obj)
    headers = List[str]()
    headers.push("Content-Type: application/json")
    headers.push("User-Agent: rack/0.4 (RGC)")
    r = http.request_with("POST", reg_api_base() + "/api/v1/auth/device/token", body, headers)
    if not r.ok {
        out.error = r.error
        return out
    }
    if r.response.status == 200 {
        p = json.parse(r.response.body)
        if p.ok {
            root = p.value
            token = json.as_str(json.get(@root, "access_token"))
            if token.len() > 0 {
                out.status = "ok"
                out.token = token
                return out
            }
        }
        out.error = "invalid token response"
        return out
    }
    # 非 200：解析 OAuth 设备流错误码。
    p = json.parse(r.response.body)
    if p.ok {
        root = p.value
        err = json.get(@root, "error")
        if json.has_key(@err, "code") {
            code = json.as_str(json.get(@err, "code"))
            if code == "authorization_pending" or code == "slow_down" {
                out.status = "pending"
                return out
            }
            out.error = reg_error_message(r.response.status, r.response.body)
            return out
        }
    }
    out.error = reg_error_message(r.response.status, r.response.body)
    return out
}

# §4.7 yank：DELETE /api/v1/packages/{name}/{version}/yank（需 token）。
# 成功返回空串，失败返回错误信息。
public def reg_yank(name: str, version: str) -> str {
    token = reg_token()
    if token.len() == 0 {
        return "no token: set RACK_PUBLISH_TOKEN or run `rack login`"
    }
    headers = List[str]()
    headers.push("Authorization: Bearer " + token)
    headers.push("User-Agent: rack/0.4 (RGC)")
    url = reg_api_base() + "/api/v1/packages/" + name + "/" + version + "/yank"
    r = http.request_with("DELETE", url, "", headers)
    if not r.ok {
        return r.error
    }
    if r.response.status == 200 {
        return ""
    }
    return reg_error_message(r.response.status, r.response.body)
}

# ---- 安装端：注册表包查询 / 下载（公开只读 API）----

public class RegVersion {
    version: str
    cksum: str
    format: str
    yanked: bool
}

public class RegPackage {
    ok: bool
    error: str
    versions: List[RegVersion]
}

def new_reg_package() -> RegPackage {
    r = RegPackage()
    r.ok = False
    r.error = ""
    r.versions = List[RegVersion]()
    return r
}

# GET /api/v1/packages/{scope}/{name}：包信息 + 版本列表（含 cksum / publish_format）。
public def reg_lookup(name: str) -> RegPackage {
    out = new_reg_package()
    url = reg_api_base() + "/api/v1/packages/" + name
    headers = List[str]()
    headers.push("Accept: application/json")
    headers.push("User-Agent: rack/0.4 (RGC)")
    r = http.request_with("GET", url, "", headers)
    if not r.ok {
        out.error = r.error
        return out
    }
    if r.response.status != 200 {
        out.error = reg_error_message(r.response.status, r.response.body)
        return out
    }
    p = json.parse(r.response.body)
    if not p.ok {
        out.error = "invalid package response from " + url
        return out
    }
    root = p.value
    vs = json.get(@root, "versions")
    n = json.len(@vs)
    i = 0
    while i < n {
        item = json.at(@vs, i)
        v = RegVersion()
        v.version = json.as_str(json.get(@item, "version"))
        v.cksum = json.as_str(json.get(@item, "cksum"))
        v.format = json.as_str(json.get(@item, "publish_format"))
        v.yanked = json.as_bool(json.get(@item, "yanked"))
        out.versions.push(v)
        i = i + 1
    }
    out.ok = True
    return out
}

public class RegResolve {
    ok: bool
    error: str
    version: str
    cksum: str
    format: str
}

def new_reg_resolve() -> RegResolve {
    r = RegResolve()
    r.ok = False
    r.error = ""
    r.version = ""
    r.cksum = ""
    r.format = ""
    return r
}

# 解析包版本：`ver` 为空时取 semver 最新（跳过 yank）。
public def reg_resolve(name: str, ver: str) -> RegResolve {
    out = new_reg_resolve()
    pkg = reg_lookup(name)
    if not pkg.ok {
        out.error = pkg.error
        return out
    }
    best = ""
    best_cksum = ""
    best_format = ""
    i = 0
    while i < pkg.versions.len() {
        v = pkg.versions.get(i)
        if not v.yanked {
            if ver.len() > 0 {
                if v.version == ver {
                    best = v.version
                    best_cksum = v.cksum
                    best_format = v.format
                    break
                }
            } else {
                if best == "" or util.version_compare(v.version, best) > 0 {
                    best = v.version
                    best_cksum = v.cksum
                    best_format = v.format
                }
            }
        }
        i = i + 1
    }
    if best.len() == 0 {
        if ver.len() > 0 {
            out.error = "package `" + name + "@" + ver + "` not found in the registry"
        } else {
            out.error = "package `" + name + "` has no versions in the registry"
        }
        return out
    }
    out.ok = True
    out.version = best
    out.cksum = best_cksum
    out.format = best_format
    return out
}

public class RegDownload {
    ok: bool
    error: str
    version: str
    cksum: str
    format: str
    data: Bytes
    manifest: str
}

def new_reg_download() -> RegDownload {
    r = RegDownload()
    r.ok = False
    r.error = ""
    r.version = ""
    r.cksum = ""
    r.format = ""
    r.data = bytes.bytes_new(0)
    r.manifest = ""
    return r
}

# 下载包产物（tar.gz 归档或单 .rg）并取清单；校验和由调用方计算核对。
# HTTP 客户端自动跟随 302（GitHub Releases 存储会重定向到 CDN）。
public def reg_download(name: str, ver: str) -> RegDownload {
    out = new_reg_download()
    resolved = reg_resolve(name, ver)
    if not resolved.ok {
        out.error = resolved.error
        return out
    }
    out.version = resolved.version
    out.cksum = resolved.cksum
    out.format = resolved.format

    url = reg_api_base() + "/api/v1/packages/" + name + "/" + resolved.version + "/download"
    headers = List[str]()
    headers.push("Accept: application/octet-stream")
    headers.push("User-Agent: rack/0.4 (RGC)")
    r = http.request_with("GET", url, "", headers)
    if not r.ok {
        out.error = r.error
        return out
    }
    if r.response.status != 200 {
        out.error = reg_error_message(r.response.status, r.response.body)
        return out
    }
    out.data = r.response.body_bytes

    # 单文件包：清单在独立端点；归档包的清单在 tar.gz 内部。
    if out.format != "archive" {
        mheaders = List[str]()
        mheaders.push("Accept: text/plain")
        mheaders.push("User-Agent: rack/0.4 (RGC)")
        m = http.request_with("GET", reg_api_base() + "/api/v1/packages/" + name + "/" + resolved.version + "/manifest", "", mheaders)
        if m.ok and m.response.status == 200 {
            out.manifest = m.response.body
        }
    }
    out.ok = True
    return out
}