import lock
import manifest
import util

# builder.rg — dependency checks, native prebuild, source staging, invoking rgc, and running
#
# Build flow (modeled after cargo's build isolation):
#   1. Verify every manifest dependency is installed in target/deps/
#   2. Run [build].prebuild (e.g. compile the LLVM shim) and read [build].link-args-file
#   3. Clear and rebuild target/build/, staging the *.rg files from the entry directory and dependency modules
#      (rgc resolves imports from the entry file's directory, which is the whole module space,
#       so a project with entry = "src/main.rg" only needs src/*.rg staged)
#   4. Invoke `<RGC or rgc> <build>/<entry basename> -o target/bin/<name>` via the shell
#      The RGC environment variable switches compilers (used during self-hosted bootstrap stages)

# Compiler command: the RGC env var wins, otherwise use rgc from PATH
def compiler_bin() -> str {
    return env_or("RGC", "rgc")
}

# Native prebuild step (e.g. compile the LLVM shim); returns non-zero on failure
def run_prebuild(proj_dir: str, m: @Manifest) -> int {
    if m.prebuild.len() == 0 {
        return 0
    }
    rc = 0
    if is_windows() {
        # /d switches drives too; the prebuild command itself is cmd syntax there
        rc = sh("cmd /C cd /d " + shell_quote(win_path(proj_dir)) + " && " + m.prebuild)
    } else {
        rc = sh("cd " + shell_quote(proj_dir) + " && " + m.prebuild)
    }
    if rc != 0 {
        print("error: prebuild failed (exit " + to_string(rc) + "): " + m.prebuild)
        return 1
    }
    return 0
}

# Lock consistency check: every package in the lock closure must be installed; manifest dependencies must be in the lock with matching versions;
# when the lock records a checksum, also verify the target/deps cache files have not been tampered with.
# Skipped when there is no lock file (legacy project / never installed). Returns 0 on success.
def verify_lock(proj_dir: str, m: @Manifest) -> int {
    lk = lock_load(proj_dir)
    if lk.names.len() == 0 {
        return 0
    }
    i = 0
    while i < lk.names.len() {
        if try_read(proj_dir + "/target/deps/" + lk.names.get(i) + ".rg").is_err() {
            print("error: package `" + lk.names.get(i) + "` is not installed")
            print("hint:  run `rack install " + lk.names.get(i) + "`")
            return 1
        }
        i = i + 1
    }
    i = 0
    while i < mf_dep_count(@m) {
        name = mf_dep_name(@m, i)
        ver = mf_dep_version(@m, i)
        idx = lock_find(@lk, name)
        if idx < 0 {
            print("error: `" + name + "` not in rack.lock (run `rack install " + name + "`)")
            return 1
        }
        lv = lk.versions.get(idx)
        if lv != ver {
            print("error: `" + name + "` locked at " + lv + " but rack.toml wants " + ver +
            " (run `rack install " + name + "@" + ver + "`)")
            return 1
        }
        lsrc = lk.sources.get(idx)
        msrc = mf_dep_source(@m, i)
        if lsrc != msrc {
            print("error: `" + name + "` locked from " + source_label(lsrc) +
            " but rack.toml wants " + source_label(msrc) +
            " (run `rack remove " + name + " && rack install " + name + "@" + ver + "`)")
            return 1
        }
        ck = lk.checksums.get(idx)
        if ck.len() > 0 {
            actual = file_sha256(proj_dir + "/target/deps/" + name + ".rg")
            if actual != ck {
                print("error: checksum mismatch for `" + name + "` in target/deps" +
                " (run `rack install " + name + "@" + ver + "` to repair)")
                return 1
            }
        }
        i = i + 1
    }
    return 0
}

# Returns the first missing dependency name; returns "" when everything is ready
public def first_missing_dep(proj_dir: str, m: @Manifest) -> str {
    i = 0
    while i < mf_dep_count(@m) {
        name = mf_dep_name(@m, i)
        p = proj_dir + "/target/deps/" + name + ".rg"
        if try_read(p).is_err() {
            return name
        }
        i = i + 1
    }
    return ""
}

# ---------- Incremental build fingerprint ----------
#
# Fingerprint = source content sha256 + dependency module content + compiler path/mtime + link args + prebuild script.
# When everything matches and the artifact exists, compilation is skipped (prebuild too), matching cargo's no-op build.

# Hash of every staged .rg in the module space. Windows concatenates with
# `type` (no sha256sum there) and hashes the result with the RGC sha2 module.
def source_digest(proj_dir: str, src_dir: str) -> str {
    deps = proj_dir + "/target/deps"
    tmp = fingerprint_path(proj_dir) + ".src"
    parts = ""
    if is_windows() {
        sh("cmd /C type " + shell_quote(win_path(src_dir) + "\\*.rg") + " " +
            shell_quote(win_path(deps) + "\\*.rg") + " > " +
            shell_quote(win_path(tmp)) + " 2>NUL")
        parts = file_sha256(tmp)
    } else {
        sh("cat " + shell_quote(src_dir) + "/*.rg " + shell_quote(deps) +
            "/*.rg 2>/dev/null | sha256sum > " + shell_quote(tmp) + " 2>/dev/null")
        parts = trim_ws(read_file_or(tmp))
    }
    remove_file(tmp)
    if parts.len() == 0 {
        parts = "no-sources"
    }
    return parts
}

# Compiler identity: resolved path + mtime (size fallback), so a compiler
# upgrade triggers a rebuild. Works without `stat -c` on macOS and Windows.
def compiler_stamp(proj_dir: str, compiler: str) -> str {
    tmp = fingerprint_path(proj_dir) + ".compiler"
    cpath = compiler
    if is_windows() {
        if find_char(cpath, "/") < 0 and find_char(cpath, "\\") < 0 {
            wtmp = fingerprint_path(proj_dir) + ".where"
            sh("cmd /C where " + shell_quote(cpath) + " > " +
                shell_quote(win_path(wtmp)) + " 2>NUL")
            lines = output_lines(read_file_or(wtmp))
            remove_file(wtmp)
            if lines.len() > 0 {
                cpath = lines.get(0)
            }
        }
        # sh() runs this line from a generated .bat, so for-variables need %%.
        sh("cmd /C for %%I in (" + shell_quote(win_path(cpath)) + ") do @echo %%~zI %%~tI > " +
            shell_quote(win_path(tmp)) + " 2>NUL")
    } else {
        if find_char(cpath, "/") < 0 {
            wtmp = fingerprint_path(proj_dir) + ".which"
            sh("command -v " + shell_quote(cpath) + " > " + shell_quote(wtmp) + " 2>/dev/null")
            lines = output_lines(read_file_or(wtmp))
            remove_file(wtmp)
            if lines.len() > 0 {
                cpath = lines.get(0)
            }
        }
        sh("stat -c %Y " + shell_quote(cpath) + " > " + shell_quote(tmp) + " 2>/dev/null" +
            " || stat -f %m " + shell_quote(cpath) + " > " + shell_quote(tmp) + " 2>/dev/null")
    }
    out = trim_ws(read_file_or(tmp))
    remove_file(tmp)
    if out.len() == 0 {
        return "unknown"
    }
    return out
}

def build_fingerprint(proj_dir: str, m: @Manifest, src_dir: str) -> str {
    parts = source_digest(proj_dir, src_dir)
    compiler = compiler_bin()
    parts = parts + "|" + compiler + "@" + compiler_stamp(proj_dir, compiler)
    # Link-args file content (a prebuild artifact; reuse the file from the previous build when skipping).
    if m.linkArgsFile.len() > 0 {
        la = try_read(proj_dir + "/" + m.linkArgsFile)
        if la.is_ok() {
            parts = parts + "|link:" + trim_ws(la.unwrap())
        }
    }
    parts = parts + "|prebuild:" + m.prebuild
    return parts
}

def fingerprint_path(proj_dir: str) -> str {
    return proj_dir + "/target/build/.fingerprint"
}

# Compile the current project; returns 0 on success, non-zero on failure
public def build_project(proj_dir: str, m: @Manifest) -> int {
    missing = first_missing_dep(proj_dir, @m)
    if missing != "" {
        print("error: package `" + missing + "` is not installed")
        print("hint:  run `rack install " + missing + "`")
        return 1
    }

    if verify_lock(proj_dir, @m) != 0 {
        return 1
    }

    build_dir = proj_dir + "/target/build"
    bin_dir = proj_dir + "/target/bin"
    if not mkdirs(build_dir) {
        print("error: cannot create " + build_dir)
        return 1
    }
    if not mkdirs(bin_dir) {
        print("error: cannot create " + bin_dir)
        return 1
    }

    bin_path = bin_dir + "/" + m.name + exe_suffix()

    # The entry directory is the module space (rgc resolves all imports from the entry directory)
    edir = dir_name(m.entry)
    src_dir = proj_dir
    if edir != "" {
        src_dir = proj_dir + "/" + edir
    }

    # Fingerprint matches and the artifact exists: skip prebuild and compilation.
    fp = build_fingerprint(proj_dir, @m, src_dir)
    stored = read_file_or(fingerprint_path(proj_dir))
    if stored == fp {
        br = try_read(bin_path)
        if br.is_ok() {
            print("  fresh (unchanged): " + bin_path)
            return 0
        }
    }

    if run_prebuild(proj_dir, @m) != 0 {
        return 1
    }

    # Clear the previous build leftovers (removed deps must not participate in linking)
    remove_rg_files(build_dir)
    remove_file(fingerprint_path(proj_dir))

    # Stage the project source
    if not copy_rg_files(src_dir, build_dir) {
        print("error: no source files (*.rg) in " + src_dir)
        return 1
    }
    # Stage dependency modules (nothing to copy when there are no deps)
    if mf_dep_count(@m) > 0 {
        if not copy_rg_files(proj_dir + "/target/deps", build_dir) {
            print("error: cannot stage dependency modules")
            return 1
        }
    }

    compiler = compiler_bin()
    # rgc derives the module space by splitting the entry path on `/` (modules.rg),
    # so pass forward slashes even on Windows; Win32 file APIs accept them.
    cmd = shell_quote(shell_path(compiler)) + " " +
        shell_quote(build_dir + "/" + base_name(m.entry)) +
        " -o " + shell_quote(bin_path)
    if m.linkArgsFile.len() > 0 {
        lr = try_read(proj_dir + "/" + m.linkArgsFile)
        if lr.is_err() {
            print("error: cannot read link args file " + m.linkArgsFile)
            return 1
        }
        la = trim_ws(lr.unwrap())
        if la.len() > 0 {
            cmd = cmd + " --link-args \"" + la + "\""
        }
    }
    rc = sh(cmd)
    # 127: not found on POSIX shells; 9009: unrecognized command in cmd.exe
    if rc == 127 or rc == 9009 {
        print("error: compiler `" + compiler + "` not found (exit " + to_string(rc) + ")")
        return 1
    }
    if rc != 0 {
        print("error: build failed (rgc exit " + to_string(rc) + ")")
        return 1
    }
    # rgc prints `built: <path>` itself on success; rack does not repeat it
    wf = write_file(fingerprint_path(proj_dir), fp)
    if wf.is_err() {
        print("warning: cannot write build fingerprint")
    }
    return 0
}

# Build and run, forwarding the rest arguments to the program; returns the program exit code
public def run_project(proj_dir: str, m: @Manifest, rest: @List[str]) -> int {
    rc = build_project(proj_dir, m)
    if rc != 0 {
        return rc
    }
    bin_path = proj_dir + "/target/bin/" + m.name + exe_suffix()
    cmd = shell_quote(shell_path(bin_path))
    for a in rest {
        cmd = cmd + " " + a
    }
    return sh(cmd)
}
