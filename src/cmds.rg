import builder
import github
import lock
import manifest
import registry
import registry_api
import resolve
import testrun
import time
import util
import bytes

# cmds.rg — rack subcommand implementations

public def cmd_help() -> int {
    print("rack — RGC package manager (mini cargo)")
    print("")
    print("Usage: rack <command> [arguments]")
    print("")
    print("Commands:")
    print("  new <name>             scaffold a new project (rack.toml + main.rg + .gitignore)")
    print("  init [name]            initialize a rack project in the current directory")
    print("  build                  compile the current project (stage deps into target/build, then invoke rgc)")
    print("  run [-- <args>...]     build and run, forwarding arguments to the program")
    print("  test [path ...]        run tests natively (compiler from $RGC): suite.rg harness dirs,")
    print("                         main.rg + expected/exit cases, err_* / negative/ compile failures,")
    print("                         def main end-to-end files, and def test_*() -> int unit functions;")
    print("                         with no path, the tests/ directory of the current project")
    print("  install [pkg[@<ver>]]  install a dependency and its full transitive closure, writing the manifest;")
    print("                         pkg can be a local registry name or github.com/<owner>/<repo>;")
    print("                         with no argument, install every manifest dependency (keeping pinned versions)")
    print("  update                 re-resolve all direct dependencies to the latest versions")
    print("  remove <pkg>           remove a dependency and update the manifest")
    print("  tree                   print the dependency tree (with sources)")
    print("  clean                  clear target/build and target/bin")
    print("  list                   show manifest and dependency install status")
    print("  login                  device login: opens the registry's /device page and finishes")
    print("                         automatically after you confirm (fallback: `rack login --code <code>`)")
    print("  login --token <token>  save the web registry API token to ~/.rack/credentials.toml")
    print("  publish                publish <name>.rg and rack.toml to the web registry")
    print("  fetch <pkg>[@ver]      download a web-registry package and extract it locally")
    print("  yank <pkg>@<ver>       yank a version from the web registry (needs login)")
    print("  logout                 remove the saved registry token")
    print("  search [--remote] [q]  search the local registry; --remote uses GitHub topic search")
    print("  registry               show local registry and GitHub cache paths")
    print("  self <command>         manage RGC toolchains (install, update, list, default, remove,")
    print("                         status, which, env, uninstall); run `rack self help`")
    print("  help                   show this help")
    print("")
    print("GitHub source: github.com/<owner>/<repo>[@<ver>], https://github.com/..., gh:<owner>/<repo>")
    print("          tag is vX.Y.Z or X.Y.Z (pre-release tags are ignored)")
    print("Manifest: [dependencies.x] git = \"github.com/<owner>/<repo>\" version = \"x.y.z\"")
    print("Environment: RACK_GITHUB_TOKEN / RACK_GITHUB_API / RACK_GITHUB_RAW / RACK_REGISTRY_API / RACK_PUBLISH_TOKEN")
    print("")
    print("Local registry: $HOME/.rack/registry/<name>/<version>/{<name>.rg, rack.toml}")
    print("GitHub cache: $HOME/.rack/cache/github.com/<owner>/<repo>/<version>/")
    return 0
}

def write_gitignore(dir_path: str) -> Result[None, str] {
    return write_file(path_join(dir_path, ".gitignore"), "target/\na.out\n")
}

def hello_template(name: str) -> str {
    return "# " + name + " — rack project entry point\n\ndef main() {\n    print(\"hello from " + name + "\")\n}\n"
}

public def cmd_new(name_arg: str) -> int {
    if name_arg.len() == 0 {
        print("error: rack new <name>")
        return 1
    }
    if not mkdirs(name_arg) {
        print("error: cannot create directory " + name_arg)
        return 1
    }
    name = path_base_name(name_arg)
    if name.len() == 0 {
        name = name_arg
    }
    m = new_manifest()
    m.name = name
    m.version = "0.1.0"
    m.entry = "main.rg"
    w = mf_save(@m, path_join(name_arg, "rack.toml"))
    if w.is_err() {
        print("error: cannot write " + name_arg + "/rack.toml")
        return 1
    }
    wr = write_file(path_join(name_arg, "main.rg"), hello_template(name))
    if wr.is_err() {
        print("error: cannot write " + name_arg + "/main.rg")
        return 1
    }
    wg = write_gitignore(name_arg)
    if wg.is_err() {
        print("error: cannot write " + name_arg + "/.gitignore")
        return 1
    }
    print("created " + name_arg + "/ (rack.toml, main.rg, .gitignore)")
    print("next: cd " + name_arg + " && rack install <pkg> && rack run")
    return 0
}

public def cmd_init(name_arg: str) -> int {
    if try_read("rack.toml").is_ok() {
        print("error: rack.toml already exists in current directory")
        return 1
    }
    name = name_arg
    if name.len() == 0 {
        name = path_base_name(cwd_path())
    }
    if name.len() == 0 {
        print("error: cannot infer project name; run `rack init <name>`")
        return 1
    }
    m = new_manifest()
    m.name = name
    m.version = "0.1.0"
    m.entry = "main.rg"
    w = mf_save(@m, "rack.toml")
    if w.is_err() {
        print("error: cannot write rack.toml")
        return 1
    }
    if try_read("main.rg").is_err() {
        wr = write_file("main.rg", hello_template(name))
        if wr.is_err() {
            print("error: cannot write main.rg")
            return 1
        }
    }
    wg = write_gitignore(".")
    if wg.is_err() {
        print("error: cannot write .gitignore")
        return 1
    }
    print("initialized rack project `" + name + "` (rack.toml)")
    return 0
}

# Load the current project manifest, printing the error on failure (returns False)
public def require_manifest(proj_dir: str, m: @var Manifest) -> bool {
    mm = manifest_load(proj_dir)
    if not manifest_valid(@mm) {
        print("error: no valid rack.toml in " + proj_dir + " (run `rack init` or `rack new` first)")
        return False
    }
    m.name = mm.name
    m.version = mm.version
    m.entry = mm.entry
    m.edition = mm.edition
    m.rustVersion = mm.rustVersion
    m.license = mm.license
    m.repository = mm.repository
    m.description = mm.description
    m.homepage = mm.homepage
    m.documentation = mm.documentation
    m.readme = mm.readme
    m.authors = mm.authors
    m.keywords = mm.keywords
    m.categories = mm.categories
    m.checksum = mm.checksum
    m.prebuild = mm.prebuild
    m.linkArgsFile = mm.linkArgsFile
    m.depNames = mm.depNames
    m.depVersions = mm.depVersions
    m.depSources = mm.depSources
    return True
}

public def cmd_build(proj_dir: str) -> int {
    m = new_manifest()
    if not require_manifest(proj_dir, @var m) {
        return 1
    }
    return build_project(proj_dir, @m)
}

public def cmd_run(proj_dir: str, rest: @List[str]) -> int {
    m = new_manifest()
    if not require_manifest(proj_dir, @var m) {
        return 1
    }
    return run_project(proj_dir, @m, @rest)
}

# rack test [path ...] — run tests with the compiler under test ($RGC, default rgc on PATH).
# Testing is toolchain work: the compiler only compiles, rack drives it. Conventions live in
# testrun.rg (suite.rg harnesses, main.rg + expected/exit, err_* negatives, def main e2e files,
# and def test_*() -> int unit functions run one process each).
public def cmd_test(argv: @List[str]) -> int {
    paths = List[str]()
    i = 2
    while i < argv.len() {
        paths.push(argv.get(i))
        i = i + 1
    }
    if paths.len() == 0 {
        if is_dir_path("tests") {
            paths.push("tests")
        } else {
            print("error: rack test [path ...]   # no path given and no tests/ directory here")
            return 1
        }
    }
    return testrun_main(env_or("RGC", "rgc"), @paths)
}

# Accumulate the resolution plan into the lock (update resolves dependencies one by one, accumulating across iterations)
def lock_add_plan(lk: @var Lock, out: @ResolveOut) {
    i = 0
    while i < out.names.len() {
        n = out.names.get(i)
        v = out.versions.get(i)
        s = out.sources.get(i)
        pd = pkg_deps(n, v, s)
        deps = pd.names
        joined = ""
        j = 0
        while j < deps.len() {
            if j > 0 {
                joined = joined + ","
            }
            joined = joined + deps.get(j)
            j = j + 1
        }
        lock_set(@var lk, n, v, s, registry_checksum(n, v, s), joined)
        i = i + 1
    }
}

# Write the dependency closure plan as rack.lock (used by install: a single resolution yields the full closure)
def save_lock(proj_dir: str, out: @ResolveOut) -> int {
    lk = lock_new()
    lock_add_plan(@var lk, @out)
    wl = lock_save(@lk, path_join(proj_dir, "rack.lock"))
    if wl.is_err() {
        print("error: cannot save rack.lock")
        return 1
    }
    return 0
}

def spec_is_github(spec: str) -> bool {
    return spec.startswith("github.com/") or spec.startswith("https://github.com/") or
    spec.startswith("http://github.com/") or spec.startswith("gh:")
}

def spec_looks_like_source(spec: str) -> bool {
    return spec.contains("/") or spec.contains("://") or spec.startswith("git@")
}

public def cmd_install(proj_dir: str, spec: str) -> int {
    if spec.len() == 0 {
        # No argument: install every direct manifest dependency (keeping pinned versions) and rebuild the lock file.
        return install_all(proj_dir)
    }

    name = ""
    ver = ""
    src = ""
    if spec_is_github(spec) {
        base = spec
        at = find_char_last(spec, "@")
        if at >= 0 {
            base = spec.slice(0, at)
            ver = spec.slice(at + 1, spec.len())
            verr = check_version(ver)
            if verr != "" {
                print("error: invalid version in spec: " + verr)
                return 1
            }
        }
        si = source_parse(base)
        if not si.ok {
            print("error: " + si.error)
            return 1
        }
        name = si.repo
        src = si.id
    } elif spec_looks_like_source(spec) {
        print("error: unsupported source `" + spec + "` (only GitHub is supported for now; use github.com/<owner>/<repo>)")
        return 1
    } else {
        name = split_head(spec, "@")
        if spec.contains("@") {
            ver = split_first(spec, "@")
            verr = check_version(ver)
            if verr != "" {
                print("error: invalid version in spec: " + verr)
                return 1
            }
        }
    }

    m = new_manifest()
    if not require_manifest(proj_dir, @var m) {
        return 1
    }

    if ver == "" {
        lv = lookup_latest(name, src)
        if not lv.ok {
            print("error: " + lv.error)
            return 1
        }
        ver = lv.version
        print("  resolved " + name + " -> " + name + "@" + ver + source_suffix(src))
    }

    # Resolve the transitive closure (pure function): the manifest only records direct dependency intent; the closure goes into rack.lock
    out = resolve_install(proj_dir, name, ver, src, @m, True)
    if out.err != "" {
        print("error: " + out.err)
        return 1
    }
    mf_set_dep_src(@var m, name, ver, src)
    w = mf_save(@m, path_join(proj_dir, "rack.toml"))
    if w.is_err() {
        print("error: cannot save rack.toml")
        return 1
    }
    if save_lock(proj_dir, @out) != 0 {
        return 1
    }
    if out.added.len() == 0 {
        print("  already satisfied: " + name + "@" + ver + source_suffix(src))
    } else {
        print("  Installed " + to_string(out.added.len()) + " package(s)")
    }
    return 0
}

# No-argument install: resolve each direct manifest dependency (pinned versions) one by one,
# write the closure into rack.lock, and place missing packages into target/deps. Equivalent to cargo install --locked.
public def install_all(proj_dir: str) -> int {
    m = new_manifest()
    if not require_manifest(proj_dir, @var m) {
        return 1
    }
    if mf_dep_count(@m) == 0 {
        print("deps: (none)")
        return 0
    }
    lk = lock_new()
    installed = 0
    i = 0
    while i < mf_dep_count(@m) {
        n = mf_dep_name(@m, i)
        ver = mf_dep_version(@m, i)
        src = mf_dep_source(@m, i)
        if ver.len() == 0 {
            lv = lookup_latest(n, src)
            if not lv.ok {
                print("error: " + lv.error)
                return 1
            }
            ver = lv.version
            print("  resolved " + n + " -> " + n + "@" + ver + source_suffix(src))
            mf_set_dep_src(@var m, n, ver, src)
        }
        out = resolve_install(proj_dir, n, ver, src, @m, True)
        if out.err != "" {
            print("error: " + out.err)
            return 1
        }
        installed = installed + out.copied
        lock_add_plan(@var lk, @out)
        i = i + 1
    }
    w = mf_save(@m, path_join(proj_dir, "rack.toml"))
    if w.is_err() {
        print("error: cannot save rack.toml")
        return 1
    }
    wl = lock_save(@lk, path_join(proj_dir, "rack.lock"))
    if wl.is_err() {
        print("error: cannot save rack.lock")
        return 1
    }
    if installed == 0 {
        print("  already satisfied: " + to_string(mf_dep_count(@m)) + " direct dependency(ies)")
    } else {
        print("  Installed " + to_string(installed) + " package(s)")
    }
    return 0
}

public def cmd_update(proj_dir: str) -> int {
    m = new_manifest()
    if not require_manifest(proj_dir, @var m) {
        return 1
    }
    if mf_dep_count(@m) == 0 {
        print("deps: (none)")
        return 0
    }
    # Snapshot direct dependencies, clear the pins, and re-resolve each to the latest (cargo update semantics)
    names = List[str]()
    srcs = List[str]()
    i = 0
    while i < mf_dep_count(@m) {
        names.push(mf_dep_name(@m, i))
        srcs.push(mf_dep_source(@m, i))
        i = i + 1
    }
    m.depNames = List[str]()
    m.depVersions = List[str]()
    m.depSources = List[str]()
    lk = lock_new()
    i = 0
    while i < names.len() {
        n = names.get(i)
        s = srcs.get(i)
        lv = lookup_latest(n, s)
        if not lv.ok {
            print("error: " + lv.error)
            return 1
        }
        print("  updating " + n + source_suffix(s) + " -> " + lv.version)
        out = resolve_install(proj_dir, n, lv.version, s, @m, False)
        if out.err != "" {
            print("error: " + out.err)
            return 1
        }
        j = 0
        while j < out.names.len() {
            mf_set_dep_src(@var m, out.names.get(j), out.versions.get(j), out.sources.get(j))
            j = j + 1
        }
        lock_add_plan(@var lk, @out)
        i = i + 1
    }
    w = mf_save(@m, path_join(proj_dir, "rack.toml"))
    if w.is_err() {
        print("error: cannot save rack.toml")
        return 1
    }
    wl = lock_save(@lk, path_join(proj_dir, "rack.lock"))
    if wl.is_err() {
        print("error: cannot save rack.lock")
        return 1
    }
    print("  Updated " + to_string(names.len()) + " direct dependencies")
    return 0
}

public def cmd_remove(proj_dir: str, name: str) -> int {
    m = new_manifest()
    if not require_manifest(proj_dir, @var m) {
        return 1
    }
    if not mf_remove_dep(@var m, name) {
        print("error: `" + name + "` is not a dependency in rack.toml")
        return 1
    }
    w = mf_save(@m, path_join(proj_dir, "rack.toml"))
    if w.is_err() {
        print("error: cannot save rack.toml")
        return 1
    }
    # Lock file sync: delete entries and prune orphan transitive deps by reverse reachability from the remaining direct dependencies
    lk = lock_load(proj_dir)
    if lk.names.len() > 0 {
        lock_remove(@var lk, name)
        remain = List[str]()
        i = 0
        while i < mf_dep_count(@m) {
            remain.push(mf_dep_name(@m, i))
            i = i + 1
        }
        lock_prune(@var lk, remain)
        wl = lock_save(@lk, path_join(proj_dir, "rack.lock"))
        if wl.is_err() {
            print("error: cannot save rack.lock")
            return 1
        }
    }
    # Leaving module files in target/deps is harmless (build only stages manifest deps), but removing them is cleaner
    remove_file(proj_dir + "/target/deps/" + name + ".rg")
    print("  Removed " + name)
    return 0
}

public def cmd_clean(proj_dir: str) -> int {
    ok = remove_dir_all(proj_dir + "/target/build")
    if not remove_dir_all(proj_dir + "/target/bin") {
        ok = False
    }
    if not ok {
        print("error: cannot clean target/build target/bin")
        return 1
    }
    print("  Cleaned target/build target/bin")
    return 0
}

public def cmd_list(proj_dir: str) -> int {
    m = new_manifest()
    if not require_manifest(proj_dir, @var m) {
        return 1
    }
    print(m.name + "@" + m.version, "(entry: " + m.entry + ")")
    if mf_dep_count(@m) == 0 {
        print("deps: (none)")
        return 0
    }
    print("deps:")
    i = 0
    while i < mf_dep_count(@m) {
        name = mf_dep_name(@m, i)
        ver = mf_dep_version(@m, i)
        src = mf_dep_source(@m, i)
        state = "missing"
        if try_read(proj_dir + "/target/deps/" + name + ".rg").is_ok() {
            state = "installed"
        }
        print("  " + name + "@" + ver + source_suffix(src), "(" + state + ")")
        i = i + 1
    }
    return 0
}

public def cmd_tree(proj_dir: str) -> int {
    m = new_manifest()
    if not require_manifest(proj_dir, @var m) {
        return 1
    }
    print_tree(@m)
    return 0
}

public def cmd_login(token: str) -> int {
    return finish_login(token)
}

# §10 设备登录（Device Flow，OAuth 2.0 Device Grant）：CLI 申请 device_code +
# user_code，打印确认页 URL 并自动打开浏览器；用户网页确认后 CLI 自动完成登录。
# 旧的 `--code` 手动流程（/cli/login）仍保留为 fallback。
public def cmd_login_browser() -> int {
    res = reg_device_start()
    if not res.ok {
        print("error: cannot start device login: " + res.error)
        print("  fallback: open " + reg_login_url() + " and run `rack login --code <code>`")
        return 1
    }
    print("  Browser login (OAuth Device Flow):")
    print("  1. Open " + res.verification_uri + " and sign in with GitHub")
    print("     (complete two-factor if enabled)")
    print("  2. Confirm the code on that page: " + res.user_code)
    print("")
    print("  Waiting for confirmation — this command finishes automatically...")
    # `start` is a cmd builtin (there is no start.exe); the empty title keeps a quoted URL
    # from being taken as the window title.
    if is_windows() {
        system("cmd /C start \"\" \"" + res.verification_uri_complete + "\"")
    } elif exists("/usr/bin/xdg-open") {
        system("xdg-open '" + res.verification_uri_complete + "' > /dev/null 2>&1 &")
    } elif exists("/usr/bin/open") {
        system("open '" + res.verification_uri_complete + "' > /dev/null 2>&1 &")
    }

    deadline = time.now() + res.expires_in
    while True {
        r = reg_device_poll(res.device_code)
        if r.status == "ok" {
            print("  Approved! Saving your registry token...")
            return finish_login(r.token)
        }
        if r.status == "error" {
            print("error: " + r.error)
            print("  fallback: open " + reg_login_url() + " and run `rack login --code <code>`")
            return 1
        }
        if time.now() >= deadline {
            print("error: device code expired; run `rack login` to start again")
            return 1
        }
        time.sleep(res.interval)
    }
    return 0
}

public def cmd_login_code(code: str) -> int {
    r = reg_exchange_code(code)
    if r.is_err() {
        print("error: code exchange failed (invalid, expired, or already used)")
        print("  try `rack login` for the automatic device flow, or generate a new code at " + reg_login_url())
        return 1
    }
    return finish_login(r.unwrap())
}

def finish_login(token: str) -> int {
    w = reg_save_token(token)
    if w.is_err() {
        print("error: cannot save the registry token")
        return 1
    }
    print("  Saved registry token to " + path_join(detect_home(), ".rack/credentials.toml"))
    return 0
}

# §10：删除本地 token（credentials.toml）。
public def cmd_logout() -> int {
    path = path_join(detect_home(), ".rack/credentials.toml")
    if not exists(path) {
        print("  No saved token (" + path + ")")
        return 0
    }
    r = remove_file(path)
    if r.is_err() {
        print("error: cannot remove " + path)
        return 1
    }
    print("  Removed " + path)
    return 0
}

# §4.7：yank <scope>/<name>@<version>（需 token）。
public def cmd_yank(spec: str) -> int {
    at = find_char_last(spec, "@")
    if at <= 0 or at >= spec.len() - 1 {
        print("error: rack yank <scope>/<name>@<version>")
        return 1
    }
    name = spec.slice(0, at)
    version = spec.slice(at + 1, spec.len())
    err = reg_yank(name, version)
    if err.len() > 0 {
        print("error: " + err)
        return 1
    }
    print("  Yanked " + name + "@" + version)
    return 0
}

# 从 web 注册表拉取包版本并解压到本地目录（多文件包/单文件包都支持）。
# Usage: rack fetch <scope>/<name>[@<version>]
public def cmd_fetch(spec: str) -> int {
    name = util.split_head(spec, "@")
    ver = ""
    if spec.contains("@") {
        ver = util.split_first(spec, "@")
    }
    if name.len() == 0 or not name.contains("/") {
        print("error: rack fetch <scope>/<name>[@<version>]")
        return 1
    }
    resolved = registry_api.reg_resolve(name, ver)
    if not resolved.ok {
        print("error: " + resolved.error)
        return 1
    }
    base = name
    slash = find_char_last(name, "/")
    if slash >= 0 {
        base = name.slice(slash + 1, name.len())
    }
    dest = base + "-" + resolved.version
    r = fetch_registry_package(name, resolved.version, dest)
    if r.is_err() {
        msg = ""
        match r {
            case Err(e) => msg = e
            case _ => msg = "cannot fetch " + name + "@" + resolved.version
        }
        print("error: " + msg)
        return 1
    }
    print("  Fetched " + name + "@" + resolved.version + " (" + resolved.format + ")")
    print("  Location: " + dest)
    print("  Next: cd " + dest + " && rack build")
    return 0
}

public def cmd_publish(proj_dir: str) -> int {
    m = new_manifest()
    if not require_manifest(proj_dir, @var m) {
        return 1
    }
    repository = util.trim_ws(m.repository)
    if repository.len() == 0 or not spec_is_github(repository) {
        print("error: publishing to the web registry requires a GitHub repository in rack.toml")
        print("  set `repository = \"https://github.com/<owner>/<repo>\"` (or `github.com/<owner>/<repo>`)")
        return 1
    }
    manifest_text = util.read_file_or(util.path_join(proj_dir, "rack.toml"))
    if manifest_text.len() == 0 {
        print("error: no rack.toml in " + proj_dir)
        return 1
    }

    # 多文件包：把整个项目源码树打成 tar.gz 上传（rack 本身也是多文件包）。
    # 若打包失败（例如没有可读文件），回退旧的单 `.rg` 文件发布。
    archive_b64 = ""
    module_text = ""
    ar = reg_build_archive(proj_dir)
    if ar.ok {
        d = ar.data
        # 调试/审计钩子：设 RACK_PUBLISH_DEBUG_ARCHIVE 时把待上传归档写到本地。
        debug_out = util.env_or("RACK_PUBLISH_DEBUG_ARCHIVE", "")
        if debug_out.len() > 0 {
            w = bytes.write_bytes(debug_out, @d)
            if not w.ok {
                print("warning: cannot write debug archive: " + w.error)
            } else {
                print("debug: wrote publish archive to " + debug_out)
            }
        }
        archive_b64 = reg_b64_encode_bytes(@d)
    } else {
        module_name = m.name
        slash = find_char_last(m.name, "/")
        if slash >= 0 {
            module_name = m.name.slice(slash + 1, m.name.len())
        }
        src = util.path_join(proj_dir, module_name + ".rg")
        r = util.try_read(src)
        if r.is_err() {
            print("error: cannot package project: " + ar.error)
            print("error: no module file `" + src + "` in project root")
            return 1
        }
        module_text = r.unwrap()
    }

    res = reg_publish(m.name, m.version, module_text, manifest_text,
                    m.description, m.homepage, m.repository, m.keywords, archive_b64)
    if not res.ok {
        print("error: " + res.error)
        return 1
    }
    print("  Published " + res.name + "@" + res.version + " -> " + reg_api_base())
    return 0
}

# Search the local registry by package-name substring, listing the latest version and description
public def cmd_search(query: str, remote: bool) -> int {
    if remote {
        return cmd_search_remote(query)
    }
    rd = registry_dir()
    if not is_dir_path(rd) {
        print("error: cannot read registry " + rd)
        return 1
    }
    found = 0
    for name in list_dir(rd) {
        if name.len() == 0 {
            continue
        }
        if query.len() > 0 and not name.contains(query) {
            continue
        }
        ver = latest_version(name)
        if ver.len() == 0 {
            continue
        }
        desc = ""
        mt = pkg_manifest_text(name, ver, "")
        if mt.len() > 0 {
            pm = new_manifest()
            if manifest_parse(mt, @var pm) == "" {
                desc = pm.description
            }
        }
        if desc.len() > 0 {
            print(name + "@" + ver, desc)
        } else {
            print(name + "@" + ver)
        }
        found = found + 1
    }
    if found == 0 {
        if query.len() > 0 {
            print("no packages matched `" + query + "`")
        } else {
            print("registry is empty: " + registry_dir())
        }
    }
    return 0
}

# GitHub topic `rgc-package` search (a discovery entry point like cargo search / pkg.go.dev)
def cmd_search_remote(query: str) -> int {
    r = gh_search(query)
    if not r.ok {
        print("error: " + r.error)
        return 1
    }
    if r.fullNames.len() == 0 {
        if query.len() > 0 {
            print("no packages matched `" + query + "` on GitHub (topic: rgc-package)")
        } else {
            print("no packages found on GitHub (topic: rgc-package)")
        }
        return 0
    }
    i = 0
    while i < r.fullNames.len() {
        line = "github.com/" + r.fullNames.get(i)
        desc = r.descriptions.get(i)
        if desc.len() > 0 {
            line = line + "  " + desc
        }
        line = line + "  (stars: " + to_string(r.stars.get(i)) + ")"
        print(line)
        i = i + 1
    }
    print("hint: rack install github.com/<owner>/<repo>")
    return 0
}
