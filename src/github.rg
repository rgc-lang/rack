import http
import json
import os
import util

# github.rg — GitHub-hosted source client
#
# Version = repository tag (Go-style): `vX.Y.Z` preferred, falls back to `X.Y.Z`;
# Package layout = rack.toml + <name>.rg at the repository root (same as rack publish's local layout).
# API/raw base URLs can be overridden with RACK_GITHUB_API / RACK_GITHUB_RAW (GitHub Enterprise and tests);
# Token comes from RACK_GITHUB_TOKEN, falling back to GITHUB_TOKEN.

public class GhFile {
    ok: bool
    notFound: bool
    error: str
    text: str
}

public class GhPackage {
    ok: bool
    notFound: bool
    error: str
    tag: str
    manifest: str
    module: str
}

public class GhVersions {
    ok: bool
    notFound: bool
    error: str
    versions: List[str]
}

public class GhSearch {
    ok: bool
    error: str
    fullNames: List[str]
    descriptions: List[str]
    stars: List[int]
}

def new_gh_file() -> GhFile {
    f = GhFile()
    f.ok = False
    f.notFound = False
    f.error = ""
    f.text = ""
    return f
}

def new_gh_package() -> GhPackage {
    p = GhPackage()
    p.ok = False
    p.notFound = False
    p.error = ""
    p.tag = ""
    p.manifest = ""
    p.module = ""
    return p
}

def new_gh_versions() -> GhVersions {
    v = GhVersions()
    v.ok = False
    v.notFound = False
    v.error = ""
    v.versions = List[str]()
    return v
}

def gh_env(name: str) -> str {
    v = os.getenv(name)
    if v.is_nothing() {
        return ""
    }
    return util.trim_ws(v.unwrap())
}

def gh_trim_base(b: str) -> str {
    s = util.trim_ws(b)
    while s.endswith("/") {
        s = s.slice(0, s.len() - 1)
    }
    return s
}

public def gh_api_base() -> str {
    b = gh_trim_base(gh_env("RACK_GITHUB_API"))
    if b.len() == 0 {
        return "https://api.github.com"
    }
    return b
}

public def gh_raw_base() -> str {
    b = gh_trim_base(gh_env("RACK_GITHUB_RAW"))
    if b.len() == 0 {
        return "https://raw.githubusercontent.com"
    }
    return b
}

def gh_token() -> str {
    t = gh_env("RACK_GITHUB_TOKEN")
    if t.len() == 0 {
        t = gh_env("GITHUB_TOKEN")
    }
    return t
}

def gh_api_headers() -> List[str] {
    hs = List[str]()
    hs.push("Accept: application/vnd.github+json")
    hs.push("X-GitHub-Api-Version: 2022-11-28")
    hs.push("User-Agent: rack/0.4 (RGC)")
    tok = gh_token()
    if tok.len() > 0 {
        hs.push("Authorization: Bearer " + tok)
    }
    return hs
}

def gh_raw_headers() -> List[str] {
    hs = List[str]()
    hs.push("Accept: application/vnd.github.raw")
    hs.push("User-Agent: rack/0.4 (RGC)")
    return hs
}

def gh_message(body: str) -> str {
    p = json.parse(body)
    if not p.ok {
        return ""
    }
    v = p.value
    if json.has_key(@v, "message") {
        return json.as_str(json.get(@v, "message"))
    }
    return ""
}

def gh_http_error(status: int, body: str) -> str {
    msg = gh_message(body)
    if status == 403 or status == 429 {
        out = "GitHub API rate limit or access denied (HTTP " + to_string(status) + ")"
        if msg.len() > 0 {
            out = out + ": " + msg
        }
        if gh_token().len() == 0 {
            out = out + " (set RACK_GITHUB_TOKEN to raise the limit)"
        }
        return out
    }
    if status == 401 {
        return "GitHub authentication failed (HTTP 401; check RACK_GITHUB_TOKEN)"
    }
    if msg.len() > 0 {
        return "GitHub HTTP " + to_string(status) + ": " + msg
    }
    return "GitHub HTTP " + to_string(status)
}

def gh_get(url: str, headers: List[str], out: @var GhFile) {
    r = http.get_with(url, headers)
    if not r.ok {
        out.error = r.error
        return
    }
    status = r.response.status
    if status == 404 {
        out.notFound = True
        out.error = "not found: " + url
        return
    }
    if status < 200 or status >= 300 {
        out.error = gh_http_error(status, r.response.body)
        return
    }
    out.ok = True
    out.text = r.response.body
}

# tag name -> exact version; non-stable semver (e.g. nightly, v1.2.3-rc1) returns ""
def gh_tag_version(tag: str) -> str {
    t = util.trim_ws(tag)
    if t.startswith("v") or t.startswith("V") {
        t = t.slice(1, t.len())
    }
    segs = t.split(".")
    if segs.len() < 2 {
        return ""
    }
    for s in segs {
        if not util.all_digits(s) {
            return ""
        }
    }
    return t
}

# All stable versions of the repository (deduplicated, unordered); on failure ok=false and error explains why
public def gh_tags(owner: str, repo: str) -> GhVersions {
    out = new_gh_versions()
    base = gh_api_base()
    page = 1
    while page <= 5 {
        url = base + "/repos/" + owner + "/" + repo + "/tags?per_page=100&page=" + to_string(page)
        f = new_gh_file()
        gh_get(url, gh_api_headers(), @var f)
        if not f.ok {
            if f.notFound {
                out.notFound = True
                out.error = "repository not found: github.com/" + owner + "/" + repo
            } else {
                out.error = f.error
            }
            return out
        }
        p = json.parse(f.text)
        if not p.ok {
            out.error = "invalid GitHub tags response for github.com/" + owner + "/" + repo + ": " + p.error
            return out
        }
        arr = p.value
        n = json.len(@arr)
        i = 0
        while i < n {
            item = json.at(@arr, i)
            ver = gh_tag_version(json.as_str(json.get(@item, "name")))
            if ver.len() > 0 and not out.versions.contains(ver) {
                out.versions.push(ver)
            }
            i = i + 1
        }
        if n < 100 {
            break
        }
        page = page + 1
    }
    if out.versions.len() == 0 {
        out.error = "no stable semver tags in github.com/" + owner + "/" + repo + " (expected vX.Y.Z or X.Y.Z)"
        return out
    }
    out.ok = True
    return out
}

# Read a single file under a tag (path relative to the repository root)
public def gh_fetch_file(owner: str, repo: str, tag: str, path: str) -> GhFile {
    f = new_gh_file()
    url = gh_raw_base() + "/" + owner + "/" + repo + "/" + tag + "/" + path
    gh_get(url, gh_raw_headers(), @var f)
    return f
}

# Download name@ver: probe the tag for rack.toml first (vX.Y.Z -> X.Y.Z), then fetch <name>.rg
public def gh_fetch_package(name: str, ver: str, owner: str, repo: str) -> GhPackage {
    out = new_gh_package()
    tags = List[str]()
    tags.push("v" + ver)
    tags.push(ver)
    i = 0
    while i < tags.len() {
        tag = tags.get(i)
        mf = gh_fetch_file(owner, repo, tag, "rack.toml")
        if mf.ok {
            mod = gh_fetch_file(owner, repo, tag, name + ".rg")
            if not mod.ok {
                if mod.notFound {
                    out.error = "github.com/" + owner + "/" + repo + " has rack.toml at tag `" + tag +
                    "` but no `" + name + ".rg`"
                } else {
                    out.error = mod.error
                }
                return out
            }
            out.ok = True
            out.tag = tag
            out.manifest = mf.text
            out.module = mod.text
            return out
        }
        if not mf.notFound {
            out.error = mf.error
            return out
        }
        i = i + 1
    }
    out.notFound = True
    out.error = "package `" + name + "@" + ver + "` not found in github.com/" + owner + "/" + repo +
    " (tried tags `v" + ver + "` and `" + ver + "`)"
    return out
}

# Search remote packages by GitHub topic `rgc-package` (results have no version; resolved at install time)
public def gh_search(query: str) -> GhSearch {
    out = GhSearch()
    out.ok = False
    out.error = ""
    out.fullNames = List[str]()
    out.descriptions = List[str]()
    out.stars = List[int]()

    q = "topic:rgc-package"
    if query.len() > 0 {
        q = q + " " + query
    }
    url = gh_api_base() + "/search/repositories?q=" + http.url_encode(q) + "&per_page=20"
    f = new_gh_file()
    gh_get(url, gh_api_headers(), @var f)
    if not f.ok {
        out.error = f.error
        return out
    }
    p = json.parse(f.text)
    if not p.ok {
        out.error = "invalid GitHub search response: " + p.error
        return out
    }
    root = p.value
    items = json.get(@root, "items")
    n = json.len(@items)
    i = 0
    while i < n {
        item = json.at(@items, i)
        full = json.as_str(json.get(@item, "full_name"))
        if full.len() > 0 {
            out.fullNames.push(full)
            out.descriptions.push(json.as_str(json.get(@item, "description")))
            out.stars.push(json.as_int(json.get(@item, "stargazers_count")))
        }
        i = i + 1
    }
    out.ok = True
    return out
}
