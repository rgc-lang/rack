# util.rg — rack common utilities: string processing, shell wrappers, file copy, version comparison

import bin
import bytes
import os
import sha2
import string
import time

# Index of the first occurrence of ch, or -1 if not found
public def find_char(s: str, ch: str) -> int {
    i = 0
    while i < s.len() {
        if s.char_at(i) == ch.char_at(0) {
            return i
        }
        i = i + 1
    }
    return -1
}

# Trim leading/trailing whitespace (space / tab / CR / LF)
public def trim_ws(s: str) -> str {
    n = s.len()
    start = 0
    while start < n {
        c = s.char_at(start)
        if c != 32 and c != 9 and c != 10 and c != 13 {
            break
        }
        start = start + 1
    }
    end = n
    while end > start {
        c = s.char_at(end - 1)
        if c != 32 and c != 9 and c != 10 and c != 13 {
            break
        }
        end = end - 1
    }
    return s.slice(start, end)
}

# Index of the first occurrence of sub at or after `start`; -1 when absent.
public def str_find_from(s: str, sub: str, start: int) -> int {
    if sub.len() == 0 {
        if start > s.len() {
            return -1
        }
        return start
    }
    i = start
    if i < 0 {
        i = 0
    }
    while i + sub.len() <= s.len() {
        if s.slice(i, i + sub.len()) == sub {
            return i
        }
        i = i + 1
    }
    return -1
}

# Index of the first occurrence of sub; -1 when absent.
public def str_find(s: str, sub: str) -> int {
    return str_find_from(s, sub, 0)
}

# Split at the first ch: split_head returns the first part, split_first returns the rest
public def split_head(s: str, ch: str) -> str {
    i = find_char(s, ch)
    if i < 0 {
        return s
    }
    return s.slice(0, i)
}

public def split_first(s: str, ch: str) -> str {
    i = find_char(s, ch)
    if i < 0 {
        return s
    }
    return s.slice(i + 1, s.len())
}

public def path_join(a: str, b: str) -> str {
    return a + "/" + b
}

# Read a file; returns an empty string on failure (for callers that ignore errors)
public def read_file_or(path: str) -> str {
    r = read_file(path)
    if r.is_err() {
        return ""
    }
    return r.unwrap()
}

public def try_read(path: str) -> Result[str, str] {
    return read_file(path)
}

# Copy a text file by reading then writing
public def copy_file(src: str, dst: str) -> Result[None, str] {
    r = read_file(src)
    if r.is_err() {
        return Result[None, str].Err("cannot read " + src)
    }
    w = write_file(dst, r.unwrap())
    if w.is_err() {
        return Result[None, str].Err("cannot write " + dst)
    }
    return Result[None, str].Ok(None)
}

# Run a shell command and return its exit code (0 = success).
# On Windows, cmd.exe has no POSIX wait-status encoding and the compiler decodes
# system() the POSIX way, so the command runs from a scratch batch file and the
# real ERRORLEVEL is read back from a file (same trick as `echo $?` on POSIX).
public def sh(cmd: str) -> int {
    if is_windows() {
        bat = temp_path("sh") + ".bat"
        rc = bat + ".rc"
        body = "@echo off\r\n" + cmd + "\r\necho %ERRORLEVEL% > " +
            shell_quote(win_path(rc)) + "\r\n"
        w = write_file(bat, body)
        if w.is_err() {
            return -1
        }
        system("cmd /C " + shell_quote(win_path(bat)))
        code = trim_ws(read_file_or(rc))
        # raw system(): remove_file/sh would recurse into this wrapper
        system("cmd /C del /F /Q " + shell_quote(win_path(bat)) + " " +
            shell_quote(win_path(rc)) + " >NUL 2>NUL")
        if code.len() == 0 {
            return -1
        }
        r = code.to_int()
        if r.is_err() {
            return -1
        }
        return r.unwrap()
    }
    return system(cmd)
}

# Windows detection: cmd.exe is the shell behind system() there, so every
# command built by rack must use its own quoting and path rules.
public def is_windows() -> bool {
    v = os.getenv("OS")
    if v.is_nothing() {
        return False
    }
    return v.unwrap() == "Windows_NT"
}

# Quote one argument for the platform shell used by system().
public def shell_quote(p: str) -> str {
    if is_windows() {
        return "\"" + p + "\""
    }
    return "'" + string.replace(p, "'", "'\\''") + "'"
}

# Convert / separators to \ for commands interpreted by cmd.exe.
public def win_path(p: str) -> str {
    return string.replace(p, "/", "\\")
}

# Path spelled the way the platform shell expects it.
public def shell_path(p: str) -> str {
    if is_windows() {
        return win_path(p)
    }
    return p
}

# A scratch directory for files rack needs only to capture command output.
public def temp_dir() -> str {
    t = env_or("TMPDIR", "")
    if t.len() == 0 {
        t = env_or("TEMP", "")
    }
    if t.len() == 0 {
        t = env_or("TMP", "")
    }
    if t.len() == 0 {
        if is_windows() {
            return "."
        }
        return "/tmp"
    }
    return t
}

# Unique-ish capture path; concurrent rack processes must not share it.
public def temp_path(tag: str) -> str {
    return temp_dir() + "/.rack-" + tag + "-" + to_string(time.now())
}

# Ensure a directory (and its parents) exists.
public def mkdirs(path: str) -> bool {
    if is_windows() {
        q = shell_quote(win_path(path))
        return sh("cmd /C if not exist " + q + " mkdir " + q) == 0
    }
    return sh("mkdir -p " + shell_quote(path)) == 0
}

public def remove_file(path: str) -> bool {
    if is_windows() {
        q = shell_quote(win_path(path))
        return sh("cmd /C if exist " + q + " del /F /Q " + q + " >NUL 2>NUL") == 0
    }
    return sh("rm -f " + shell_quote(path)) == 0
}

public def remove_dir_all(path: str) -> bool {
    if is_windows() {
        q = shell_quote(win_path(path))
        return sh("cmd /C if exist " + q + " rmdir /S /Q " + q + " >NUL 2>NUL") == 0
    }
    return sh("rm -rf " + shell_quote(path)) == 0
}

public def move_path(src: str, dst: str) -> bool {
    if is_windows() {
        return sh("cmd /C move /Y " + shell_quote(win_path(src)) + " " +
            shell_quote(win_path(dst)) + " >NUL") == 0
    }
    return sh("mv -f " + shell_quote(src) + " " + shell_quote(dst)) == 0
}

public def is_dir_path(path: str) -> bool {
    if is_windows() {
        # "dir\NUL" exists exactly when dir exists (works for empty directories too)
        return sh("cmd /C if exist " + shell_quote(win_path(path) + "\\NUL") +
            " (exit 0) else (exit 1)") == 0
    }
    return sh("test -d " + shell_quote(path)) == 0
}

# Copy every *.rg file from src_dir into dst_dir. False when there is nothing
# to copy or the copy fails (callers report "no source files" on False).
public def copy_rg_files(src_dir: str, dst_dir: str) -> bool {
    if is_windows() {
        return sh("cmd /C copy /Y " + shell_quote(win_path(src_dir) + "\\*.rg") + " " +
            shell_quote(win_path(dst_dir)) + " >NUL 2>NUL") == 0
    }
    return sh("cp " + shell_quote(src_dir) + "/*.rg " + shell_quote(dst_dir) + "/ 2>/dev/null") == 0
}

# Remove *.rg staging leftovers; missing directory or no matches is fine.
public def remove_rg_files(dir: str) {
    if is_windows() {
        sh("cmd /C if exist " + shell_quote(win_path(dir)) + " del /Q " +
            shell_quote(win_path(dir) + "\\*.rg") + " >NUL 2>NUL")
        return
    }
    sh("rm -f " + shell_quote(dir) + "/*.rg")
}

# Split captured command output into non-empty, trimmed lines.
public def output_lines(text: str) -> List[str] {
    out = List[str]()
    for ln in text.split("\n") {
        t = trim_ws(ln)
        if t.len() > 0 {
            out.push(t)
        }
    }
    return out
}

# List a directory's entries (names only); missing directories yield an empty list.
public def list_dir(path: str) -> List[str] {
    tmp = temp_path("ls")
    if is_windows() {
        sh("cmd /C dir /b " + shell_quote(win_path(path)) + " > " +
            shell_quote(win_path(tmp)) + " 2>NUL")
    } else {
        sh("ls -1 " + shell_quote(path) + " > " + shell_quote(tmp) + " 2>/dev/null")
    }
    out = output_lines(read_file_or(tmp))
    remove_file(tmp)
    return out
}

# Resolve $HOME portably; never shells out (Windows has no /tmp).
public def detect_home() -> str {
    h = env_or("HOME", "")
    if h.len() == 0 {
        h = env_or("USERPROFILE", "")
    }
    if h.len() == 0 {
        h = env_or("HOMEDRIVE", "") + env_or("HOMEPATH", "")
    }
    if h.len() == 0 {
        if is_windows() {
            return temp_dir()
        }
        return "/tmp"
    }
    return h
}

# Read an environment variable; return fallback when unset or empty.
public def env_or(name: str, fallback: str) -> str {
    v = os.getenv(name)
    if v.is_nothing() {
        return fallback
    }
    t = trim_ws(v.unwrap())
    if t.len() == 0 {
        return fallback
    }
    return t
}

# ---------- Version comparison: numeric per segment, missing segments count as 0 ----------

# Returns -1 if a < b, 0 if equal, 1 if a > b
public def version_compare(a: str, b: str) -> int {
    pa = trim_ws(a).split(".")
    pb = trim_ws(b).split(".")
    n = pa.len()
    if pb.len() > n {
        n = pb.len()
    }
    i = 0
    while i < n {
        va = seg_int(@pa, i)
        vb = seg_int(@pb, i)
        if va < vb {
            return -1
        }
        if va > vb {
            return 1
        }
        i = i + 1
    }
    return 0
}

def seg_int(parts: @List[str], i: int) -> int {
    if i >= parts.len() {
        return 0
    }
    r = parts.get(i).to_int()
    if r.is_err() {
        return 0
    }
    return r.unwrap()
}

# ---------- Path and list helpers ----------

# Index of the last occurrence of ch, or -1 if not found
public def find_char_last(s: str, ch: str) -> int {
    i = s.len() - 1
    while i >= 0 {
        if s.char_at(i) == ch.char_at(0) {
            return i
        }
        i = i - 1
    }
    return -1
}

# base_name("src/main.rg") = "main.rg"; returns the input unchanged when there is no /
public def base_name(p: str) -> str {
    i = find_char_last(p, "/")
    if i < 0 {
        return p
    }
    return p.slice(i + 1, p.len())
}

# dir_name("src/main.rg") = "src"; returns "" when there is no /
public def dir_name(p: str) -> str {
    i = find_char_last(p, "/")
    if i < 0 {
        return ""
    }
    return p.slice(0, i)
}

# basename accepting either separator (Windows cwd and user args use \)
public def path_base_name(p: str) -> str {
    return base_name(string.replace(p, "\\", "/"))
}

# dirname accepting either separator
public def path_dir_name(p: str) -> str {
    return dir_name(string.replace(p, "\\", "/"))
}

# Pop index 0 (only for non-empty lists)
public def pop_front(xs: @var List[str]) {
    i = 0
    while i < xs.len() - 1 {
        xs.set(i, xs.get(i + 1))
        i = i + 1
    }
    xs.pop()
}

# Return whether the whole string is a non-empty sequence of digits
public def all_digits(s: str) -> bool {
    if s.len() == 0 {
        return False
    }
    i = 0
    while i < s.len() {
        c = s.char_at(i)
        if c < 48 or c > 57 {
            return False
        }
        i = i + 1
    }
    return True
}

# Lexicographic a < b (character by character; a shorter prefix is smaller).
# The built-in < is not used: Sema does not fully allow string relational operators, and codegen would fail.
public def str_less(a: str, b: str) -> bool {
    n = a.len()
    if b.len() < n {
        n = b.len()
    }
    i = 0
    while i < n {
        ca = a.char_at(i)
        cb = b.char_at(i)
        if ca < cb {
            return True
        }
        if ca > cb {
            return False
        }
        i = i + 1
    }
    return a.len() < b.len()
}

# Executable suffix for the current platform (rgc appends .exe on Windows).
public def exe_suffix() -> str {
    if is_windows() {
        return ".exe"
    }
    return ""
}

# Current working directory (physical path, no shell round-trip)
public def cwd_path() -> str {
    r = os.getcwd()
    if r.is_err() {
        return "."
    }
    return r.unwrap()
}

# Source label for display: "" means local registry
public def source_label(src: str) -> str {
    if src.len() == 0 {
        return "local registry"
    }
    return src
}

public def source_suffix(src: str) -> str {
    if src.len() == 0 {
        return ""
    }
    return " (" + src + ")"
}

# Hex sha256 digest of a file; returns "" on failure.
# Pure RGC (sha2), so it works on Windows where sha256sum does not exist.
public def file_sha256(path: str) -> str {
    r = bytes.read_bytes(path)
    if not r.ok {
        return ""
    }
    data = r.data
    digest = sha2.sha256(@data)
    return bin.to_hex(@digest)
}
