# rack — package manager for RGC

> An RGC package manager written in RGC — a mini cargo, with a hosting model
> inspired by Go modules. It supports **GitHub-hosted sources** (tags as
> versions, raw fetching, topic discovery, tokens, local cache), lock files
> recording `source` + `checksum`, `rack search --remote`, reproducible offline
> installs, the local registry, TOML manifests, sha256 verification,
> transitive dependency resolution, and self-hosting.

## Features

- `rack new <name>` — scaffold a project (`rack.toml` + `main.rg` + `.gitignore`)
- `rack init [name]` — initialize in the current directory (no subdirectory)
- `rack install <pkg>[@<ver>]` — install a dependency **and its full transitive
  closure**; when no version is given, the latest version is resolved:
  - `<pkg>` can be a local-registry package name or a **GitHub source**:
    `github.com/<owner>/<repo>`、`https://github.com/<owner>/<repo>[.git]`、`gh:<owner>/<repo>`;
  - two different exact versions of the same package **conflict**; the same name
    from different sources is a **source conflict**;
  - dependency cycles **are rejected**; direct dependencies go into `rack.toml`,
    and the full closure (version + source + sha256 + dependency edges) goes into **`rack.lock`**
- `rack install` — with **no argument**: install every direct manifest dependency
  (keeping pinned versions) and rebuild the lock file; missing packages are
  placed into `target/deps`; when everything is ready it prints `already satisfied`
- `rack update` — re-resolve all direct dependencies to the latest versions
  (cargo update semantics); GitHub sources re-fetch tag content so moved tags can
  be accepted and the lock checksum updated
- `rack build` — validates dependencies against `rack.lock` (complete closure,
  matching version/source, `target/deps` cache sha256 not tampered; a damaged cache
  is repaired with `rack install <pkg>`) → **fingerprint incremental build**:
  a fingerprint of source content + dependency content + compiler path/mtime +
  link args + prebuild script is recorded in `target/build/.fingerprint`; when
  everything matches and the artifact exists, prebuild and compilation are
  skipped (prints `fresh (unchanged)`, like cargo's no-op build) → otherwise it
  runs `[build].prebuild` → stages source and deps into `target/build/` →
  invokes `RGC` (overridable via environment; defaults to `rgc` on `PATH`), with
  extra link args via `link-args-file`
- `rack run [-- args...]` — build and run, forwarding arguments unchanged and
  propagating the exit code
- `rack test [paths...]` — run tests natively in RGC (no shell); the compiler under
  test comes from `$RGC` (default `rgc` on PATH). Case conventions, walked recursively:
  `tests/<dir>/suite.rg` self-contained harness (argv[1] = its directory, RGC/RGC_STD
  exported), `<dir>/main.rg` + `expected`/`exit` module cases, `err_*.rg` files and
  `negative/` directories that must fail to compile, `def main` end-to-end files, and
  **unit tests** — files whose `def test_*() -> int` functions are discovered and run
  one process each through a generated dispatch harness (0 = pass). Every case gets a
  memory cap and a timeout; with no path, the `tests/` directory of the current project
- `rack tree` / `rack list` — dependency tree / manifest status; GitHub deps show
  a `(github.com/...)` source
- `rack remove <pkg>` / `rack clean` / `rack publish`
- `rack search [q]` — search the local registry; `rack search --remote [q]` — GitHub topic search
- **Integrity verification** — local packages get their module sha256 recorded in
  the registry manifest by `publish`; GitHub packages write the content sha256 into
  `rack.lock` on first install and enforce it on later installs; a tampered
  registry/cache or a moved tag causes a `checksum mismatch` rejection
- `rack registry` — show local registry and GitHub cache paths
- `rack help` / `rack --version`

## Quick start

```bash
rack new demo && cd demo

# Write code: import the dependency package's module name
cat > main.rg <<'EOF'
import calcx

def main() -> int {
    print(calcx_double_add(2, 3))
    return 0
}
EOF

# Local registry package (with transitive dependencies)
rack install calcx

# GitHub-hosted package: tags are versions; transitive deps are resolved automatically
rack install github.com/alice/calcx
rack install github.com/alice/mathx@0.2.0

rack tree              # demo@0.1.0 └── calcx@0.1.0 (github.com/alice/calcx) ...
rack run               # built: ./target/bin/demo
```

## GitHub-hosted sources

### Repository layout

One GitHub repository hosts one package; the repository root contains:

```
rack.toml          # [package] name = "<repo>", version = "<version for the tag>"
<repo>.rg          # the package module: the repo name must match the module name
```

Example: the root of `github.com/alice/mathx` is `rack.toml` + `mathx.rg`,
with `name = "mathx"` and `version = "0.2.0"` in `rack.toml`.

### Versions and tags

- Versions come from git tags (like Go modules): `vX.Y.Z` is preferred, `X.Y.Z` is accepted;
- Only stable versions are accepted: `v1.2.3-rc1`, `nightly`, etc. are ignored;
  `v1.2` (fewer than three segments) also works;
- Resolving the "latest" version picks the numerically largest stable tag;
  exact-version installs probe `v<ver>` → `<ver>` in order;
- The package name comes from the repository name; the `name`/`version`
  declared in `rack.toml` must match the repo name and the target version,
  otherwise installation is rejected (prevents tag content mismatch).

### Publishing flow

```bash
# Package repository root: rack.toml + <repo>.rg
git tag v0.1.0
git push origin v0.1.0

# Make `rack search --remote` find it: add the `rgc-package` topic to the repo
# User side:
rack search --remote math
rack install github.com/<owner>/<repo>
```

`rack publish` only writes to the local registry (`$HOME/.rack/registry`);
it does not push to GitHub for you. If the manifest's `repository` points to
GitHub, publish will remind you to push and tag.

### Transitive dependencies

GitHub packages can declare dependencies in `rack.toml` using cargo-style
subtables; `git` points to another repository and `version` may be omitted
(the latest stable tag is resolved at install time):

```toml
[dependencies.mathx]
version = "0.2.0"                     # optional
git = "github.com/alice/mathx"
```

Local and GitHub dependencies can be mixed. `target/deps` is a flat module
space, so **the same package name must come from the same source**; the same
name from different sources is a `source conflict`.

### Cache and offline use

```
$HOME/.rack/cache/github.com/<owner>/<repo>/<version>/
  <name>.rg      # fetched from raw.githubusercontent.com
  rack.toml      # original manifest + rack-written checksum
```

- The first install fetches from the network and records the content sha256 in `rack.lock`;
- Later installs reuse the cache only when the cached manifest and module both
  match the lock checksum, so with a lock file installs are **fully offline** and reproducible;
- Missing/corrupt cache entries are re-fetched automatically; without a lock
  (first resolution, `rack update`) content is re-fetched to avoid stale caches
  masking tag drift;
- A moved tag that breaks the checksum raises an error and suggests `rack update`;
  update accepts the new content and rewrites the lock. First-trust is TOFU
  (like Go's go.sum first recording).

### Environment variables

| Variable | Purpose |
|------|---------|
| `RACK_GITHUB_TOKEN` / `GITHUB_TOKEN` | API token (sent only to api.github.com; higher rate limits/search) |
| `RACK_GITHUB_API` | API base URL override (default `https://api.github.com`; GitHub Enterprise/mirrors/tests) |
| `RACK_GITHUB_RAW` | raw file base URL override (default `https://raw.githubusercontent.com`) |
| `RGC` | RGC compiler path used by `rack build` and `rack test` |

Tokens are used only for API requests, never for raw file downloads. Private
repository raw fetching is not supported; this targets public repositories.

## Layout and formats

A managed project:

```
demo/
  rack.toml          # manifest: [package] metadata + direct dependency intent (exact pins + optional git source)
  rack.lock          # lock file: the resolved full dependency closure (maintained by rack; commit it)
  main.rg            # entry (entry can point to a subdirectory, e.g. src/main.rg)
  target/
    deps/            # installed dependency modules <name>.rg (cache; rebuildable anytime)
    build/           # build staging area (cleared and rebuilt before each build)
    bin/<name>       # build artifact
```

Lock file format (mirrors Cargo.lock; `source` distinguishes the local registry
from GitHub; install/update rewrite in full, remove deletes entries and prunes
orphan transitive dependencies by dependency edges):

```toml
# rack.lock — dependency closure lock file (maintained by rack; do not edit by hand; commit with the project)

[lock.calcx]
version = "0.3.0"
source = "github.com/alice/calcx"   # local-registry deps omit this line
checksum = "82354433…"              # module sha256: from publish for local, from first fetch for GitHub
dependencies = ["mathx"]

[lock.mathx]
version = "0.2.0"
source = "github.com/alice/mathx"
checksum = "0d1e12aa…"
dependencies = []
```

Manifest format (TOML subset; parser is `src/toml.rg`):

```toml
[package]
name = "demo"
version = "0.1.0"
entry = "main.rg"            # optional; a subdirectory entry makes that directory the whole module space
edition = "2024"             # metadata keys below (mirroring Cargo.toml), optional;
rust-version = "1.97"        # preserved on save by install/update and stored by publish
license = "MIT OR Apache-2.0"
repository = "https://github.com/..."
description = "..."
homepage = "https://example.com"      # all keys below are optional metadata
documentation = "https://example.com/docs"
readme = "README.md"
authors = ["Alice", "Bob"]            # array keys (toml.rg supports single-line string arrays)
keywords = ["math", "demo"]
categories = ["algorithms"]
checksum = "…"                        # rack-managed: written by publish, verified by install

[build]                      # optional: native build hooks
prebuild = "bash tools/llvm-shim.sh"       # run before compiling (cwd = project root)
link-args-file = "target/build/link-args"  # file content passed as rgc --link-args

[dependencies]               # local-registry dependencies: inline exact pins
mathx = "0.2.0"

[dependencies.utilx]         # cargo-style subtable: local (version) or GitHub (git)
version = "1.0.0"

[dependencies.textx]
git = "github.com/alice/textx"        # version optional: resolves the latest stable tag
```

Local registry (written by `rack publish`; used for offline development/bootstrap):

```
$HOME/.rack/registry/<name>/<version>/
  <name>.rg      # module file (mirrors rgc's flat import model)
  rack.toml      # the package's own manifest (stored by publish; drives transitive resolution)
```

## Install

Download `rack-0.4.3-<target>.tar.gz` from the
[releases](https://github.com/rgc-lang/rack/releases) page and put `rack` (or
`rack.exe` on Windows) on `PATH`. rack drives a released
[RGC](https://github.com/rgc-lang/rgc) compiler, found as `rgc` on `PATH` or
through `RGC=<path>`; linking generated code needs a C++ toolchain — `g++` /
`clang++` on Linux and macOS, and a `g++`-compatible driver (MinGW-w64, or the
MSYS2 `CLANGARM64` toolchain on Windows ARM64) on Windows.

Windows x64 and arm64 are supported: rgc supplies the POSIX runtime the standard
library needs on top of Winsock, Win32 threads and the MSVC CRT, so `rack.exe`
uses the same package, build and test paths as the Unix builds.

Windows also publishes `rgc-<rgc-version>-windows-<arch>.exe`, an installer that
puts `rack`, `rgc` and the standard library under *Program Files*, adds them to
the system `PATH`, and registers an uninstaller that removes the `PATH` entry it
added. On the other platforms, `rack self uninstall --yes` removes the toolchains
installed by `install.sh`.

## Self-hosting

rack manages itself (`rack.toml` at the repository root, entry `src/main.rg`):

```bash
./tests/bootstrap.sh
# == stage 0: compile rack0 with the compiler
# == stage 1: rack0 build (rack manages itself)     -> rack1
# == stage 2: rack1 build (clean tree)              -> rack2
# == stage 3: cmp rack1 rack2
# bootstrap OK: rack1 == rack2 (byte-identical fixed point)
```

Like the compiler's IR fixed-point check, rack1 and rack2 are byte-identical,
proving the build pipeline is deterministic and can reproduce itself from source.
Set `RGC=<path>` to choose the compiler; otherwise `rgc` is taken from `PATH`.

## Building and testing from source

Prerequisites: a released RGC toolchain (`rgc` plus its `lib/`) and a C++
linker driver.

```bash
./tests/bootstrap.sh     # fixed-point check -> target/bin/rack
./tests/test.sh          # end-to-end regression tests (temporary HOME + mock servers)
```

### Regression tests and mock GitHub

`tests/test.sh` runs entirely with a temporary `HOME` and never touches the
real registry/cache. GitHub-related cases start `tests/mock_github.py` (a
local HTTP server, fixtures in `tests/fixtures/github/`) and point
`RACK_GITHUB_API` / `RACK_GITHUB_RAW` at it, covering: latest/exact versions,
URL/`gh:` forms, transitive dependencies, pagination, offline cache, cache
repair, tag drift, name mismatch, source conflicts, remote search and tokens,
and `update` upgrades. No real network is needed. The same suite also covers
the web registry, `rack self`, the native test runner, TOML parsing, and the
portable helper layer against local mock servers.

## Relationship to Go / Rust

| Dimension | rack | Go modules | Cargo |
|-----------|------|------------|-------|
| Hosting | GitHub repositories (tags as versions) | any VCS repository (module path) | crates.io central index + git deps |
| Version selection | exact pins; latest stable tag by default | semver minimal version selection | semver ranges + unified solving |
| Integrity | lock-file `checksum` (TOFU) | `go.sum` | registry checksum + `Cargo.lock` |
| Discovery | GitHub topic `rgc-package` | pkg.go.dev index | `cargo search` |
| Offline | local cache + lock | module cache + `go.sum` | registry cache + `--locked` |
| Package layout | one `<repo>.rg` + `rack.toml` at repo root | multiple packages/subdirectories in a repo | multiple crates/workspace in a repo |

Design trade-offs: RGC currently has a flat `import <module>` model and the
standard library has no archive/unzip capability, so the minimal hosting
model is "one repository, one package, fetched as raw files". It keeps Go's
"module path + tag" intuition and Cargo's "lock file records sources and
checksums", without a central index.

## Implementation notes (RGC capability mapping)

| Need | Provided by RGC |
|------|----------------|
| Command-line arguments | built-in `args() -> List[str]` |
| Exit codes | the return value of `def main() -> int` is the process exit code |
| Manifest/lock I/O | built-in `read_file` / `write_file` (returning `Result`) |
| TOML parsing | `toml.rg` custom subset parser (table headers/subtables/quoted strings/escapes/comments/single-line string arrays) |
| Dependency resolution | `resolve.rg` worklist closure resolution; pure function returning a `ResolveOut` plan |
| Version comparison | per-segment `to_int` + `all_digits` validation, missing segments count as 0 |
| GitHub API/raw | standard library `http.get_with` (HTTPS + custom headers) and `json.parse` |
| Tokens/base URLs | built-in `os.getenv` (`RACK_GITHUB_*` / `GITHUB_TOKEN`) |
| Compilation and directory ops | built-in `system()` (invokes `rgc`, `mkdir -p`, staging copies) |
| Error handling | `Result[T, str]` + `match`; parse failures are never silent |
| `Manifest`/`TomlDoc` editing | `@var` mutable borrows rewrite fields across functions |
| `$HOME` / `pwd` / directory listing | `os.getenv("HOME")`; directory listing still uses a shell bypass that writes a fixed temp file and reads it back |
| sha256 integrity | shell `sha256sum` on Unix, pure-RGC sha2 on Windows (no shell dependency); recorded at publish/first fetch and verified at install |

Module layout (`rack/src/`):
`main` (dispatch) → `cmds` (commands) → `resolve` (closure resolution/conflicts/cycles/dependency tree),
`builder` (lock validation + staging + compilation), `registry` (local/GitHub
version resolution, cache, install, publish, checksum), `github` (GitHub
API/raw client), `source` (source identifier normalization), `lock` (rack.lock),
`manifest` (manifest class), `toml` (TOML subset), `testrun` (the native test
runner behind `rack test`), `util` (string/shell/version utilities).

Design highlights: `resolve_install` is a **pure function** — it does not
mutate the manifest and returns a plan that `cmds` applies, avoiding an unverified
path in RGC's borrow checker for "re-borrowing a mutable borrow parameter"; `Result`
payloads are only `str`/`None` (built-in `unwrap` is only safe for scalars/str).

## Known limitations

- Versions only support exact pins (`"x.y.z"` or the latest stable tag); semver range solving is not implemented yet
- Only tags are recognized; branch/commit revs and Go pseudo-versions are not supported; pre-release tags are ignored
- One package per repository, a single `<repo>.rg` at the repo root; archive packages, subdirectory packages, and multi-file packages are not supported
- At most 5 pages × 100 tags (500) are scanned per repository
- Private repositories are not supported (raw fetching sends no token); tokens are only used for the API
- GitHub search depends on the topic index and API rate limits; pre-release versions are not supported
- Checksums are first-trust (TOFU) without signatures/transparency logs; lock files and manifests themselves are not verified
- Cache directories have no cross-process locks; concurrent installs of the same package may download twice (content checks still catch corruption)
- `rack build` errors and suggests commands on manifest/lock mismatch (it does not re-resolve automatically like cargo)
- TOML arrays only support single-line string arrays (multi-line/nested/inline tables still error)
- Paths must not contain spaces; `rack run` does not quote-escape arguments