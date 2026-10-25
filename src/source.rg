import util

# source.rg — dependency source identifiers
#
# Only GitHub hosting is supported for now (modeled after Go's module path + tag model):
#   github.com/<owner>/<repo>
# Accepts `github.com/o/r`, `https://github.com/o/r(.git)`, `gh:o/r`,
# and normalizes them all to `github.com/<owner>/<repo>` for manifests, lock files, and cache directories.

public class SourceInfo {
    ok: bool
    error: str
    id: str
    owner: str
    repo: str
}

def src_allowed_char(c: int) -> bool {
    if c >= 48 and c <= 57 {
        return True
    }
    if c >= 65 and c <= 90 {
        return True
    }
    if c >= 97 and c <= 122 {
        return True
    }
    return c == 45 or c == 46 or c == 95
}

def src_valid_component(s: str) -> bool {
    if s.len() == 0 or s == "." or s == ".." {
        return False
    }
    i = 0
    while i < s.len() {
        if not src_allowed_char(s.char_at(i)) {
            return False
        }
        i = i + 1
    }
    return True
}

def src_error(msg: str) -> SourceInfo {
    r = SourceInfo()
    r.ok = False
    r.error = msg
    r.id = ""
    r.owner = ""
    r.repo = ""
    return r
}

public def source_parse(raw: str) -> SourceInfo {
    s = trim_ws(raw)
    if s.len() == 0 {
        return src_error("empty git source")
    }
    if s.startswith("gh:") {
        s = s.slice(3, s.len())
    } elif s.startswith("https://github.com/") {
        s = s.slice(19, s.len())
    } elif s.startswith("http://github.com/") {
        s = s.slice(18, s.len())
    } elif s.startswith("github.com/") {
        s = s.slice(11, s.len())
    } elif s.startswith("git@") {
        return src_error("scp-like git URL is not supported; use github.com/<owner>/<repo> or https://github.com/<owner>/<repo>")
    } else {
        return src_error("unsupported source `" + raw + "` (only GitHub is supported for now; use github.com/<owner>/<repo>)")
    }
    while s.endswith("/") {
        s = s.slice(0, s.len() - 1)
    }
    if s.endswith(".git") {
        s = s.slice(0, s.len() - 4)
    }
    parts = s.split("/")
    if parts.len() != 2 {
        return src_error("bad GitHub source `" + raw + "` (expected github.com/<owner>/<repo>)")
    }
    owner = trim_ws(parts.get(0))
    repo = trim_ws(parts.get(1))
    if not src_valid_component(owner) or not src_valid_component(repo) {
        return src_error("bad GitHub source `" + raw + "` (owner/repo may contain only letters, digits, `.`, `_`, `-`)")
    }
    r = SourceInfo()
    r.ok = True
    r.error = ""
    r.id = "github.com/" + owner + "/" + repo
    r.owner = owner
    r.repo = repo
    return r
}

public def source_is_github(id: str) -> bool {
    return id.startswith("github.com/")
}
