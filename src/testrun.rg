# testrun.rg — the native test runner behind `rack test`
#
# Testing is toolchain work, not compiler work: rgc only compiles, rack drives it.
# The compiler under test comes from $RGC (default: rgc on PATH), like `rack build`.
#
# Directory conventions (walked recursively, deterministic listing order):
#   <dir>/suite.rg    harness case: compile and run it with argv[1] = absolute <dir>, env RGC =
#                     the compiler under test and RGC_STD extended with <dir>'s parent.
#                     Exit 0 = PASS; a first output line starting with "SKIP" skips the suite.
#   <dir>/main.rg     module case: compile + run; an `expected` file next to it is compared against
#                     combined stdout/stderr (CRLF normalized to LF on Windows), an `exit` file
#                     declares the expected exit code.
#   err_*.rg          negative case: compilation must fail with an "error:" diagnostic;
#                     every .rg file inside a "negative" directory is negative too
#   other *.rg        with `def main(`: end-to-end case, compile + run, exit 0 required.
#                     Without it but with `public def test_*() -> int` functions: UNIT TESTS —
#                     a generated harness imports the file and dispatches on argv[1], running
#                     every test function in its own process (RGC has no unwinding, so test
#                     isolation is per process). Test functions must be `public` (the harness
#                     is a separate module); return 0 = pass, nonzero = fail.
#                     Sources with neither are skipped, as are _-prefixed library files.
#
# Per case (POSIX: ulimit + timeout; Windows has neither, like cargo test):
#   - compile: 4GB virtual-memory cap + 30s timeout (suites: 60s)
#   - run:     1GB virtual-memory cap + 10s timeout (suites: 300s, no cap)
# Runaway syntax only yields a failure, never drags down the machine.
#
# RGC has no readdir; listings use `ls -1p` on POSIX and `dir /ad /b` + `dir /a-d /b`
# on Windows (directories first there, so the walk order differs between platforms).

import util

public class TestRun {
    exe: str          # compiler under test ($RGC, default rgc)
    tmp: str          # scratch directory for binaries and logs
    rc_path: str      # shared exit-code capture file (POSIX)
    pass_n: int
    fail_n: int
    skip_n: int
    env_export: str  # shell prefix exporting RGC/RGC_STD for suite/unit cases
}

def tr_q(p: str) -> str {
    return shell_quote(p)
}

# Environment prefix for a command: shell exports on POSIX, cmd `set` on Windows.
def tr_env_export(exe: str, std_dir: str) -> str {
    if is_windows() {
        s = "set \"RGC=" + exe + "\" && "
        if std_dir.len() > 0 {
            s = s + "set \"RGC_STD=" + std_dir + "\" && "
        }
        return s
    }
    s = "export RGC=" + tr_q(exe) + "; "
    if std_dir.len() > 0 {
        s = s + "export RGC_STD=" + tr_q(std_dir) + "; "
    }
    return s
}

def tr_read(path: str) -> str {
    return read_file_or(path)
}

def tr_exists(path: str) -> bool {
    return read_file(path).is_ok()
}

def tr_read_trim(path: str) -> str {
    return trim_ws(tr_read(path))
}

def tr_to_int(s: str) -> int {
    r = s.to_int()
    if r.is_ok() {
        return r.unwrap()
    }
    return -1
}

# Run cmd through the shell and capture its real exit status (echo $? sees 128+sig for signals,
# unlike system()'s >>8 which maps signal deaths to 0). On Windows sh() already captures
# ERRORLEVEL, so its return value is the process exit code.
def tr_sh_rc(r: @var TestRun, cmd: str) -> int {
    if is_windows() {
        return sh(cmd)
    }
    system(cmd + "; echo $? > " + tr_q(r.rc_path))
    return tr_to_int(tr_read_trim(r.rc_path))
}

# Lines of a directory-listing command (`dir /ad /b` etc.) captured into a scratch file.
def tr_cmd_lines(r: @var TestRun, sub: str, path: str, tag: str) -> List[str] {
    out = List[str]()
    f = r.tmp + "/" + tag + ".txt"
    sh("cmd /C " + sub + " " + shell_quote(win_path(path)) + " > " +
        shell_quote(win_path(f)) + " 2>NUL")
    for ln in tr_read(f).split("\n") {
        t = trim_ws(ln)
        if t.len() > 0 {
            out.push(t)
        }
    }
    remove_file(f)
    return out
}

# Directory listing: ls -1p on POSIX (sorted, directories carry a trailing '/');
# on Windows `dir /b` prints no markers, so directories and files are listed separately.
def tr_list(r: @var TestRun, path: str) -> List[str] {
    out = List[str]()
    if is_windows() {
        for d in tr_cmd_lines(@var r, "dir /ad /b", path, "ls-dirs") {
            out.push(d + "/")
        }
        for f in tr_cmd_lines(@var r, "dir /a-d /b", path, "ls-files") {
            out.push(f)
        }
        return out
    }
    ls_path = r.tmp + "/ls.txt"
    system("ls -1p " + tr_q(path) + " > " + tr_q(ls_path) + " 2>/dev/null")
    for ln in tr_read(ls_path).split("\n") {
        t = trim_ws(ln)
        if t.len() > 0 {
            out.push(t)
        }
    }
    return out
}

def tr_is_dir(path: str) -> bool {
    return is_dir_path(path)
}

def tr_realpath(r: @var TestRun, path: str) -> str {
    out = r.tmp + "/rp.txt"
    if is_windows() {
        # %%~fI expands to a full path without requiring the file to exist
        sh("cmd /C for %%I in (" + shell_quote(win_path(path)) + ") do @echo %%~fI > " +
            shell_quote(win_path(out)))
    } else {
        system("realpath -m " + tr_q(path) + " > " + tr_q(out) + " 2>/dev/null")
    }
    p = tr_read_trim(out)
    if p.len() > 0 {
        # rgc derives the module space by splitting on `/`, so keep paths loader-safe.
        if is_windows() {
            return string.replace(p, "\\", "/")
        }
        return p
    }
    return path
}

def tr_parent_dir(path: str) -> str {
    d = path_dir_name(path)
    if d.len() == 0 {
        return "."
    }
    return d
}

# Output captured through cmd.exe is CRLF while expected/ files are LF.
def tr_norm_eol(s: str) -> str {
    if is_windows() {
        return string.replace(s, "\r\n", "\n")
    }
    return s
}

def tr_sanitize(s: str) -> str {
    out = ""
    i = 0
    while i < s.len() {
        c = s.char_at(i)
        if c == 47 or c == 92 {
            out = out + "_"
        } else {
            out = out + s.slice(i, i + 1)
        }
        i = i + 1
    }
    return out
}

# Compile command: POSIX caps memory and time; Windows runs uncapped (cmd.exe has no ulimit).
def tr_compile_cmd(r: @var TestRun, src: str, bin_path: str, log: str, timeout_s: int) -> str {
    if is_windows() {
        return r.env_export + tr_q(r.exe) + " " + tr_q(src) + " -o " + tr_q(bin_path) +
            " > " + tr_q(log) + " 2>&1"
    }
    return "( " + r.env_export + "ulimit -v 4000000; timeout " + to_string(timeout_s) + " " +
        tr_q(r.exe) + " " + tr_q(src) + " -o " + tr_q(bin_path) + " ) > " + tr_q(log) + " 2>&1"
}

# Compile src -> bin; the compiler's own diagnostics land in log.
def tr_compile(r: @var TestRun, src: str, bin_path: str, log: str, timeout_s: int) -> bool {
    if tr_sh_rc(@var r, tr_compile_cmd(@var r, src, bin_path, log, timeout_s)) != 0 {
        return False
    }
    return tr_exists(bin_path)
}

# Run prog (optionally with one argument), capturing combined output; cap_kb = 0 disables the cap.
def tr_run_cmd(r: @var TestRun, prog: str, arg: str, out: str, timeout_s: int, cap_kb: int) -> int {
    cmd = ""
    if is_windows() {
        cmd = r.env_export + tr_q(prog)
        if arg.len() > 0 {
            cmd = cmd + " " + tr_q(arg)
        }
        cmd = cmd + " > " + tr_q(out) + " 2>&1 < NUL"
    } else {
        cmd = "( " + r.env_export
        if cap_kb > 0 {
            cmd = cmd + "ulimit -v " + to_string(cap_kb) + "; "
        }
        cmd = cmd + "timeout " + to_string(timeout_s) + " " + tr_q(prog)
        if arg.len() > 0 {
            cmd = cmd + " " + tr_q(arg)
        }
        cmd = cmd + " ) > " + tr_q(out) + " 2>&1 < /dev/null"
    }
    return tr_sh_rc(@var r, cmd)
}

def tr_head(path: str, n: int) {
    lines = tr_read(path).split("\n")
    i = 0
    while i < lines.len() and i < n {
        t = trim_ws(lines.get(i))
        if t.len() > 0 {
            print("  " + t)
        }
        i = i + 1
    }
}

def tr_tail(path: str, n: int) {
    lines = tr_read(path).split("\n")
    total = lines.len()
    start = total - n
    if start < 0 {
        start = 0
    }
    i = start
    while i < total {
        t = trim_ws(lines.get(i))
        if t.len() > 0 {
            print("  " + t)
        }
        i = i + 1
    }
}

# Show the first differing lines of two outputs, unified-diff style (max 20).
def tr_show_diff(want: str, got: str) {
    wl = want.split("\n")
    gl = got.split("\n")
    total = wl.len()
    if gl.len() > total {
        total = gl.len()
    }
    i = 0
    shown = 0
    while i < total and shown < 20 {
        w = ""
        g = ""
        if i < wl.len() {
            w = wl.get(i)
        }
        if i < gl.len() {
            g = gl.get(i)
        }
        if not (w == g) {
            print("  line " + to_string(i + 1) + ":")
            print("  - " + w)
            print("  + " + g)
            shown = shown + 1
        }
        i = i + 1
    }
    if shown == 20 and i < total {
        print("  ... (more differences)")
    }
}

# err_*.rg and err_*/main.rg: compilation must fail with an "error:" diagnostic.
# Files in a "negative" directory are all negative cases regardless of name.
def tr_negative(r: @var TestRun, src: str, label: str) {
    log = r.tmp + "/neg.log"
    bin_path = r.tmp + "/neg_bin" + exe_suffix()
    if tr_compile(@var r, src, bin_path, log, 30) {
        print("FAIL " + label + " should not compile")
        r.fail_n = r.fail_n + 1
        return
    }
    if not (tr_read(log).contains("error[") or tr_read(log).contains("error:")) {
        print("FAIL " + label + " missing error: diagnostic")
        r.fail_n = r.fail_n + 1
        return
    }
    print("PASS " + label)
    r.pass_n = r.pass_n + 1
}

# <dir>/main.rg: compile + run, honoring the `expected`/`exit` files next to it.
def tr_case_main(r: @var TestRun, dir_path: str, label: str, negative: bool) {
    src = dir_path + "/main.rg"
    if negative {
        tr_negative(@var r, src, label)
        return
    }
    name = tr_sanitize(label)
    bin_path = r.tmp + "/" + name + exe_suffix()
    clog = r.tmp + "/" + name + ".compile.log"
    if not tr_compile(@var r, src, bin_path, clog, 30) {
        print("FAIL " + label + " (compile)")
        tr_head(clog, 3)
        r.fail_n = r.fail_n + 1
        return
    }
    out = r.tmp + "/" + name + ".out"
    rc = tr_run_cmd(@var r, bin_path, "", out, 10, 1000000)
    want_rc = 0
    exit_file = dir_path + "/exit"
    if tr_exists(exit_file) {
        want_rc = tr_to_int(tr_read_trim(exit_file))
    }
    if rc != want_rc {
        print("FAIL " + label + " (run, exit=" + to_string(rc) + ", expected=" + to_string(want_rc) + ")")
        r.fail_n = r.fail_n + 1
        return
    }
    expected = dir_path + "/expected"
    if tr_exists(expected) {
        want = tr_norm_eol(tr_read(expected))
        got = tr_norm_eol(tr_read(out))
        if not (want == got) {
            print("FAIL " + label + " (output)")
            tr_show_diff(want, got)
            r.fail_n = r.fail_n + 1
            return
        }
    }
    print("PASS " + label)
    r.pass_n = r.pass_n + 1
}

def tr_is_ident_char(c: int) -> bool {
    if c >= 48 and c <= 57 {
        return True
    }
    if c >= 65 and c <= 90 {
        return True
    }
    if c >= 97 and c <= 122 {
        return True
    }
    return c == 95
}

def tr_is_ident(s: str) -> bool {
    if s.len() == 0 {
        return False
    }
    i = 0
    while i < s.len() {
        if not tr_is_ident_char(s.char_at(i)) {
            return False
        }
        i = i + 1
    }
    return True
}

def tr_is_dup(names: @List[str], s: str) -> bool {
    i = 0
    while i < names.len() {
        if names.get(i) == s {
            return True
        }
        i = i + 1
    }
    return False
}

# Collect the `def test_*` function names declared in a unit-test source file.
# An occurrence only counts when an identifier followed by '(' follows "def test_".
def tr_scan_unit_tests(src: str) -> List[str] {
    names = List[str]()
    key = "def test_"
    pos = str_find(src, key)
    while pos >= 0 {
        j = pos + 9
        tname = "test_"
        while j < src.len() {
            if tr_is_ident_char(src.char_at(j)) {
                tname = tname + src.slice(j, j + 1)
                j = j + 1
            } else {
                break
            }
        }
        while j < src.len() {
            if src.char_at(j) != 32 {
                break
            }
            j = j + 1
        }
        call_ok = False
        if j < src.len() {
            if src.char_at(j) == 40 {
                call_ok = True
            }
        }
        if call_ok and tname.len() > 5 {
            if not tr_is_dup(@names, tname) {
                names.push(tname)
            }
        }
        pos = str_find_from(src, key, j)
    }
    return names
}

# A unit-test file: no `def main`, but `def test_*() -> int` functions. A generated harness
# (written into the scratch dir) imports the file — found via RGC_STD pointing at the file's
# directory — and dispatches on argv[1]; every function runs in its own capped, timed process.
def tr_case_unit(r: @var TestRun, src: str, src_dir: str, label: str, mod: str) {
    if mod.len() == 0 {
        print("FAIL " + label + " (unit-test file name must be an identifier, got: " + mod + ")")
        r.fail_n = r.fail_n + 1
        return
    }
    c0 = mod.char_at(0)
    digit0 = c0 >= 48 and c0 <= 57
    if digit0 or not tr_is_ident(mod) {
        print("FAIL " + label + " (unit-test file name must be an identifier, got: " + mod + ")")
        r.fail_n = r.fail_n + 1
        return
    }
    names = tr_scan_unit_tests(tr_read(src))
    if names.len() == 0 {
        print("SKIP " + label + " (no tests)")
        r.skip_n = r.skip_n + 1
        return
    }
    hx = "# generated by rack test - unit harness for " + mod + " (do not edit)\n"
    hx = hx + "import " + mod + "\n\n"
    hx = hx + "def main() -> int {\n"
    hx = hx + "    a = args()\n"
    hx = hx + "    name = \"\"\n"
    hx = hx + "    if a.len() > 1 {\n"
    hx = hx + "        name = a.get(1)\n"
    hx = hx + "    }\n"
    i = 0
    while i < names.len() {
        tf = names.get(i)
        hx = hx + "    if name == \"" + tf + "\" {\n"
        hx = hx + "        return " + tf + "()\n"
        hx = hx + "    }\n"
        i = i + 1
    }
    hx = hx + "    print(\"unknown test: \" + name)\n"
    hx = hx + "    return 2\n"
    hx = hx + "}\n"
    harness = r.tmp + "/unit_" + tr_sanitize(label) + ".rg"
    wr = write_file(harness, hx)
    if wr.is_err() {
        print("FAIL " + label + " (cannot write unit harness)")
        r.fail_n = r.fail_n + 1
        return
    }
    abs_dir = tr_realpath(@var r, src_dir)
    r.env_export = tr_env_export(r.exe, abs_dir)
    bin_path = r.tmp + "/unit_" + tr_sanitize(label) + exe_suffix()
    clog = bin_path + ".compile.log"
    ok = tr_compile(@var r, harness, bin_path, clog, 30)
    r.env_export = ""
    if not ok {
        print("FAIL " + label + " (unit compile)")
        tr_head(clog, 5)
        r.fail_n = r.fail_n + 1
        return
    }
    i = 0
    while i < names.len() {
        tf = names.get(i)
        out = bin_path + "." + tr_sanitize(tf) + ".out"
        rc = tr_run_cmd(@var r, bin_path, tf, out, 10, 1000000)
        if rc == 0 {
            print("PASS " + label + "::" + tf)
            r.pass_n = r.pass_n + 1
        } else {
            print("FAIL " + label + "::" + tf + " (exit=" + to_string(rc) + ")")
            tr_head(out, 5)
            r.fail_n = r.fail_n + 1
        }
        i = i + 1
    }
}

# A bare .rg file: negative when named err_* or inside a "negative" directory; with `def main(`
# an end-to-end run; otherwise a unit-test file when it declares test_* functions.
# The `def main(` form (not bare "def main") keeps comment mentions from selecting the branch.
def tr_case_file(r: @var TestRun, src: str, dir_path: str, label: str, name: str, in_negative_dir: bool) {
    if in_negative_dir or name.startswith("err_") {
        tr_negative(@var r, src, label)
        return
    }
    body = tr_read(src)
    if str_find(body, "def main(") >= 0 {
        bin_path = r.tmp + "/" + tr_sanitize(label) + exe_suffix()
        clog = r.tmp + "/" + tr_sanitize(label) + ".compile.log"
        if not tr_compile(@var r, src, bin_path, clog, 30) {
            print("FAIL " + label + " (compile)")
            tr_head(clog, 3)
            r.fail_n = r.fail_n + 1
            return
        }
        out = r.tmp + "/" + tr_sanitize(label) + ".out"
        rc = tr_run_cmd(@var r, bin_path, "", out, 10, 1000000)
        if rc != 0 {
            print("FAIL " + label + " (run, exit=" + to_string(rc) + ")")
            r.fail_n = r.fail_n + 1
            return
        }
        print("PASS " + label)
        r.pass_n = r.pass_n + 1
        return
    }
    if str_find(body, "def test_") >= 0 {
        tr_case_unit(@var r, src, dir_path, label, name)
        return
    }
    print("SKIP " + label + " (no def main)")
    r.skip_n = r.skip_n + 1
}

# <dir>/suite.rg: a self-contained harness. It receives its absolute directory as argv[1] and
# RGC/RGC_STD in the environment; exit 0 = PASS, or SKIP via the first output line.
def tr_case_suite(r: @var TestRun, dir_path: str, label: str) {
    abs_dir = tr_realpath(@var r, dir_path)
    parent = tr_parent_dir(abs_dir)
    r.env_export = tr_env_export(r.exe, parent)

    bin_path = r.tmp + "/suite_" + tr_sanitize(label) + exe_suffix()
    clog = bin_path + ".compile.log"
    if not tr_compile(@var r, dir_path + "/suite.rg", bin_path, clog, 60) {
        print("FAIL " + label + " (suite compile)")
        tr_head(clog, 5)
        r.fail_n = r.fail_n + 1
        return
    }
    out = bin_path + ".out"
    rc = tr_run_cmd(@var r, bin_path, abs_dir, out, 300, 0)
    if rc != 0 {
        print("FAIL " + label + " (suite, exit=" + to_string(rc) + ")")
        tr_tail(out, 20)
        r.fail_n = r.fail_n + 1
        return
    }
    lines = tr_read(out).split("\n")
    first = ""
    i = 0
    while i < lines.len() {
        t = trim_ws(lines.get(i))
        if t.len() > 0 {
            first = t
            break
        }
        i = i + 1
    }
    if first.startswith("SKIP") {
        print(first)
        r.skip_n = r.skip_n + 1
        return
    }
    # The suite prints its own PASS summary as the last non-empty line.
    last = first
    i = 0
    while i < lines.len() {
        t = trim_ws(lines.get(i))
        if t.len() > 0 {
            last = t
        }
        i = i + 1
    }
    if last.len() == 0 {
        last = "PASS " + label
    }
    print(last)
    r.pass_n = r.pass_n + 1
}

def tr_walk(r: @var TestRun, path: str, label: str) {
    r.env_export = ""
    if not tr_is_dir(path) {
        dot = find_char_last(label, ".")
        name = label
        if dot >= 0 {
            name = label.slice(0, dot)
        }
        tr_case_file(@var r, path, tr_parent_dir(path), name, name, False)
        return
    }
    if tr_exists(path + "/suite.rg") {
        tr_case_suite(@var r, path, label)
        return
    }
    if tr_exists(path + "/main.rg") {
        neg = path_base_name(path).startswith("err_") or label.contains("/negative")
        tr_case_main(@var r, path, label, neg)
        return
    }
    in_negative_dir = label.contains("/negative") or label == "negative"
    for e in tr_list(@var r, path) {
        if e.endswith("/") {
            sub = e.slice(0, e.len() - 1)
            tr_walk(@var r, path + "/" + sub, label + "/" + sub)
        } else {
            if e.endswith(".rg") and not e.startswith("_") {
                name = e.slice(0, e.len() - 3)
                tr_case_file(@var r, path + "/" + e, path, label + "/" + name, name, in_negative_dir)
            }
        }
    }
}

# Entry point of `rack test <path> [...]`; rgc is the compiler under test.
public def testrun_main(rgc: str, paths: @List[str]) -> int {
    r = TestRun()
    r.exe = rgc
    r.tmp = ""
    r.rc_path = ""
    r.pass_n = 0
    r.fail_n = 0
    r.skip_n = 0
    r.env_export = ""
    r.tmp = temp_path("rack-test")
    if not mkdirs(r.tmp) {
        print("error: cannot create scratch directory")
        return 1
    }
    r.rc_path = r.tmp + "/rc"

    i = 0
    while i < paths.len() {
        p = paths.get(i)
        if is_windows() {
            # rgc's loader and the generated suite paths use forward slashes.
            p = string.replace(p, "\\", "/")
        }
        label = path_base_name(p)
        if label.len() == 0 {
            label = p
        }
        print("== " + label + " ==")
        tr_walk(@var r, p, label)
        i = i + 1
    }

    print("")
    print("passed " + to_string(r.pass_n) + ", failed " + to_string(r.fail_n) +
        ", skipped " + to_string(r.skip_n))
    remove_dir_all(r.tmp)
    if r.fail_n > 0 {
        return 1
    }
    return 0
}
