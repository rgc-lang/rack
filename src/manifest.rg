import source
import toml
import util

# manifest.rg — rack.toml manifest: parse, edit, save (TOML subset; see toml.rg for the parser)
#
# [package]
# name = "demo"
# version = "0.1.0"
# entry = "main.rg"            # optional, defaults to main.rg
# edition = "2024"             # metadata (mirrors Cargo.toml; preserved on save/round-trip)
# rust-version = "1.97"        # metadata, MSRV semantics
# license = "MIT OR Apache-2.0"
# repository = "https://..."
# homepage = "https://..."
# documentation = "https://..."
# readme = "README.md"
# description = "..."
# authors = ["A", "B"]         # array metadata
# keywords = ["math"]          # array metadata
# categories = ["algorithms"]  # array metadata
# checksum = "abc..."          # rack-managed: written at publish time, verified at install
#
# [build]                      # optional: native build hooks (compiler bootstrap, etc.)
# prebuild = "bash tools/llvm-shim.sh"   # shell step executed before compiling
# link-args-file = "target/build/link-args"  # file content passed as rgc --link-args
#
# [dependencies]               # the two forms can be mixed
# mathx = "0.2.0"
#
# [dependencies.utilx]         # cargo-style subtable
# version = "1.0.0"
#
# [dependencies] = direct dependency intent (exact pins, editable by hand); the resolved full closure
# (with checksums) is written to the separate lock file rack.lock — rewritten by install/update, pruned by remove.
# Error handling: parsing uses a "pre-constructed object + error string" pattern ("" = success)
# to avoid Result carrying an object payload — the built-in unwrap is only safe for scalars/str.

public class Manifest {
    name: str
    version: str
    entry: str
    edition: str
    rustVersion: str
    license: str
    repository: str
    description: str
    homepage: str
    documentation: str
    readme: str
    authors: List[str]
    keywords: List[str]
    categories: List[str]
    checksum: str
    prebuild: str
    linkArgsFile: str
    depNames: List[str]
    depVersions: List[str]
    depSources: List[str]
}

public def new_manifest() -> Manifest {
    m = Manifest()
    m.name = ""
    m.version = "0.0.0"
    m.entry = "main.rg"
    m.edition = ""
    m.rustVersion = ""
    m.license = ""
    m.repository = ""
    m.description = ""
    m.homepage = ""
    m.documentation = ""
    m.readme = ""
    m.authors = List[str]()
    m.keywords = List[str]()
    m.categories = List[str]()
    m.checksum = ""
    m.prebuild = ""
    m.linkArgsFile = ""
    m.depNames = List[str]()
    m.depVersions = List[str]()
    m.depSources = List[str]()
    return m
}

# Exact version validation: x.y (same for x.y.z), purely numeric segments; returns "" if valid, otherwise an error message
public def check_version(v: str) -> str {
    segs = v.split(".")
    if segs.len() < 2 {
        return "version must be `x.y.z` (got `" + v + "`)"
    }
    for s in segs {
        if not all_digits(s) {
            return "bad version segment `" + s + "` in `" + v + "`"
        }
    }
    return ""
}

# Parse manifest text into @var m; returns "" on success or an error message
public def manifest_parse(text: str, m: @var Manifest) -> str {
    doc = toml_new_doc()
    err = toml_parse(text, @var doc)
    if err != "" {
        return err
    }

    name = toml_get(@doc, "package", "name")
    if name.len() == 0 {
        return "missing `name` in [package]"
    }
    version = toml_get(@doc, "package", "version")
    if version.len() == 0 {
        version = "0.0.0"
    }
    entry = toml_get(@doc, "package", "entry")
    if entry.len() == 0 {
        entry = "main.rg"
    }
    edition = toml_get(@doc, "package", "edition")
    rustVersion = toml_get(@doc, "package", "rust-version")
    if rustVersion.len() > 0 {
        verr = check_version(rustVersion)
        if verr != "" {
            return "`rust-version`: " + verr
        }
    }
    license = toml_get(@doc, "package", "license")
    repository = toml_get(@doc, "package", "repository")
    description = toml_get(@doc, "package", "description")
    homepage = toml_get(@doc, "package", "homepage")
    documentation = toml_get(@doc, "package", "documentation")
    readme = toml_get(@doc, "package", "readme")
    authors = toml_get_list(@doc, "package", "authors")
    keywords = toml_get_list(@doc, "package", "keywords")
    categories = toml_get_list(@doc, "package", "categories")
    checksum = toml_get(@doc, "package", "checksum")
    prebuild = toml_get(@doc, "build", "prebuild")
    linkArgsFile = toml_get(@doc, "build", "link-args-file")

    depNames = List[str]()
    depVersions = List[str]()
    depSources = List[str]()

    # Form 1: inline key in [dependencies] `name = "x.y.z"` (local registry)
    di = toml_find(@doc, "dependencies")
    if di >= 0 {
        for k in toml_table_keys(@doc, di) {
            v = toml_table_value(@doc, di, k)
            if v.len() == 0 {
                return "dependency `" + k + "` has empty version"
            }
            if depNames.contains(k) {
                return "duplicate dependency: " + k
            }
            depNames.push(k)
            depVersions.push(v)
            depSources.push("")
        }
    }

    # Form 2: [dependencies.<name>] subtable (cargo style)
    #   Local: version = "x.y.z"
    #   GitHub: git = "github.com/<owner>/<repo>", version optional (resolves the latest tag)
    i = 0
    while i < toml_table_count(@doc) {
        p = toml_table_path(@doc, i)
        pre = "dependencies."
        if p.startswith(pre) {
            n = p.slice(pre.len(), p.len())
            if n.len() == 0 or n.contains(".") {
                return "unsupported table: [" + p + "]"
            }
            v = toml_table_value(@doc, i, "version")
            git = toml_table_value(@doc, i, "git")
            if git.len() > 0 {
                si = source_parse(git)
                if not si.ok {
                    return "dependency `" + n + "`: " + si.error
                }
                git = si.id
            }
            if v.len() == 0 and git.len() == 0 {
                return "dependency `" + n + "` missing `version` in [" + p + "]"
            }
            if v.len() > 0 {
                verr = check_version(v)
                if verr != "" {
                    return "dependency `" + n + "`: " + verr
                }
            }
            if depNames.contains(n) {
                return "duplicate dependency: " + n
            }
            depNames.push(n)
            depVersions.push(v)
            depSources.push(git)
        }
        i = i + 1
    }

    # The inline form must be an exact version; subtables allow an empty version with a git source (latest is resolved later)
    i = 0
    while i < depNames.len() {
        if depSources.get(i).len() == 0 and depVersions.get(i).len() == 0 {
            return "dependency `" + depNames.get(i) + "` has empty version"
        }
        if depVersions.get(i).len() > 0 {
            verr = check_version(depVersions.get(i))
            if verr != "" {
                return "dependency `" + depNames.get(i) + "`: " + verr
            }
        }
        i = i + 1
    }

    m.name = name
    m.version = version
    m.entry = entry
    m.edition = edition
    m.rustVersion = rustVersion
    m.license = license
    m.repository = repository
    m.description = description
    m.homepage = homepage
    m.documentation = documentation
    m.readme = readme
    m.authors = authors
    m.keywords = keywords
    m.categories = categories
    m.checksum = checksum
    m.prebuild = prebuild
    m.linkArgsFile = linkArgsFile
    m.depNames = depNames
    m.depVersions = depVersions
    m.depSources = depSources
    return ""
}

# Load the manifest from a project directory; on failure returns an unnamed empty manifest (check manifest_valid)
public def manifest_load(proj_dir: str) -> Manifest {
    m = new_manifest()
    tr = try_read(path_join(proj_dir, "rack.toml"))
    if tr.is_err() {
        return m
    }
    err = manifest_parse(tr.unwrap(), @var m)
    if err != "" {
        bad = new_manifest()
        return bad
    }
    return m
}

# Whether the manifest exists and is valid (use after manifest_load)
public def manifest_valid(m: @Manifest) -> bool {
    return m.name.len() > 0
}

public def mf_dep_count(m: @Manifest) -> int {
    return m.depNames.len()
}

public def mf_dep_name(m: @Manifest, i: int) -> str {
    return m.depNames.get(i)
}

public def mf_dep_version(m: @Manifest, i: int) -> str {
    return m.depVersions.get(i)
}

# Dependency source: "" = local registry; "github.com/<owner>/<repo>" = GitHub-hosted
public def mf_dep_source(m: @Manifest, i: int) -> str {
    return m.depSources.get(i)
}

# Dependency index by name; -1 when absent
public def mf_find_dep(m: @Manifest, name: str) -> int {
    i = 0
    while i < m.depNames.len() {
        if m.depNames.get(i) == name {
            return i
        }
        i = i + 1
    }
    return -1
}

# Add or update a dependency pin and source
public def mf_set_dep_src(m: @var Manifest, name: str, ver: str, src: str) {
    i = 0
    while i < m.depNames.len() {
        if m.depNames.get(i) == name {
            m.depVersions.set(i, ver)
            m.depSources.set(i, src)
            return
        }
        i = i + 1
    }
    m.depNames.push(name)
    m.depVersions.push(ver)
    m.depSources.push(src)
}

# Remove a dependency; returns whether it was actually removed
public def mf_remove_dep(m: @var Manifest, name: str) -> bool {
    idx = -1
    i = 0
    while i < m.depNames.len() {
        if m.depNames.get(i) == name {
            idx = i
        }
        i = i + 1
    }
    if idx < 0 {
        return False
    }
    while idx < m.depNames.len() - 1 {
        m.depNames.set(idx, m.depNames.get(idx + 1))
        m.depVersions.set(idx, m.depVersions.get(idx + 1))
        m.depSources.set(idx, m.depSources.get(idx + 1))
        idx = idx + 1
    }
    m.depNames.pop()
    m.depVersions.pop()
    m.depSources.pop()
    return True
}

# Serialize a string array as a TOML array literal (without the key name)
def join_quoted(xs: List[str]) -> str {
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

# Serialize and write back to rack.toml (metadata keys are emitted only when present, preserving round-trips; the closure lives in rack.lock)
public def mf_save(m: @Manifest, path: str) -> Result[None, str] {
    s = "# rack.toml — rack manifest (maintained by rack; hand edits are fine)\n\n[package]\n"
    s = s + "name = " + toml_escape_str(m.name) + "\n"
    s = s + "version = " + toml_escape_str(m.version) + "\n"
    s = s + "entry = " + toml_escape_str(m.entry) + "\n"
    if m.edition.len() > 0 {
        s = s + "edition = " + toml_escape_str(m.edition) + "\n"
    }
    if m.rustVersion.len() > 0 {
        s = s + "rust-version = " + toml_escape_str(m.rustVersion) + "\n"
    }
    if m.description.len() > 0 {
        s = s + "description = " + toml_escape_str(m.description) + "\n"
    }
    if m.license.len() > 0 {
        s = s + "license = " + toml_escape_str(m.license) + "\n"
    }
    if m.repository.len() > 0 {
        s = s + "repository = " + toml_escape_str(m.repository) + "\n"
    }
    if m.homepage.len() > 0 {
        s = s + "homepage = " + toml_escape_str(m.homepage) + "\n"
    }
    if m.documentation.len() > 0 {
        s = s + "documentation = " + toml_escape_str(m.documentation) + "\n"
    }
    if m.readme.len() > 0 {
        s = s + "readme = " + toml_escape_str(m.readme) + "\n"
    }
    if m.authors.len() > 0 {
        s = s + "authors = " + join_quoted(m.authors) + "\n"
    }
    if m.keywords.len() > 0 {
        s = s + "keywords = " + join_quoted(m.keywords) + "\n"
    }
    if m.categories.len() > 0 {
        s = s + "categories = " + join_quoted(m.categories) + "\n"
    }
    if m.checksum.len() > 0 {
        s = s + "checksum = " + toml_escape_str(m.checksum) + "\n"
    }
    if m.prebuild.len() > 0 or m.linkArgsFile.len() > 0 {
        s = s + "\n[build]\n"
        if m.prebuild.len() > 0 {
            s = s + "prebuild = " + toml_escape_str(m.prebuild) + "\n"
        }
        if m.linkArgsFile.len() > 0 {
            s = s + "link-args-file = " + toml_escape_str(m.linkArgsFile) + "\n"
        }
    }
    if m.depNames.len() > 0 {
        # Local dependencies use inline keys; GitHub dependencies use [dependencies.<name>] subtables (with git)
        has_local = False
        i = 0
        while i < m.depNames.len() {
            if m.depSources.get(i).len() == 0 {
                has_local = True
            }
            i = i + 1
        }
        if has_local {
            s = s + "\n[dependencies]\n"
            i = 0
            while i < m.depNames.len() {
                if m.depSources.get(i).len() == 0 {
                    s = s + toml_quote_key(m.depNames.get(i)) + " = " + toml_escape_str(m.depVersions.get(i)) + "\n"
                }
                i = i + 1
            }
        }
        i = 0
        while i < m.depNames.len() {
            if m.depSources.get(i).len() > 0 {
                s = s + "\n[" + toml_quote_path("dependencies." + m.depNames.get(i)) + "]\n"
                if m.depVersions.get(i).len() > 0 {
                    s = s + "version = " + toml_escape_str(m.depVersions.get(i)) + "\n"
                }
                s = s + "git = " + toml_escape_str(m.depSources.get(i)) + "\n"
            }
            i = i + 1
        }
    }
    return write_file(path, s)
}
