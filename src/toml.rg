import util

# toml.rg — minimal TOML subset parser (rack-specific)
#
# Supported: [tables], [dotted.nested.tables], escaped "strings", single-line string arrays ["a", "b"],
# bare scalars (numbers/bool), and trailing # comments.
# Unsupported (errors on encounter): [[array-of-tables]], multi-line arrays, nested arrays/inline tables,
# inline tables {..}, date literals, and multi-line strings '''/""".
# rack.toml only uses [package] and [dependencies] tables.
#
# Parse model: a document is an ordered list of tables; each table is (dotted path, parallel keys/values).
# Array values are stored as raw text (starting with [) in values; elements are read via
# toml_get_list / toml_array_elems; the scalar accessor toml_get returns the raw text for array keys.
# Errors use "pre-constructed object + error string" ("" = success) to avoid Result carrying an object.

public class TomlTable {
    path: str
    keys: List[str]
    values: List[str]
}

public class TomlDoc {
    tables: List[TomlTable]
}

public def toml_new_doc() -> TomlDoc {
    d = TomlDoc()
    d.tables = List[TomlTable]()
    return d
}

public class TomlKeyPath {
    value: str
}

# Index of the first ch outside double-quoted strings (or -1). Used to find the
# `=` / `#` separators without being confused by quoted keys such as "a=b#c".
def toml_find_unquoted(s: str, ch: str) -> int {
    i = 0
    in_quote = False
    while i < s.len() {
        c = s.char_at(i)
        if in_quote {
            if c == 92 {
                i = i + 2
                continue
            }
            if c == 34 {
                in_quote = False
            }
        } else {
            if c == 34 {
                in_quote = True
            } elif c == ch.char_at(0) {
                return i
            }
        }
        i = i + 1
    }
    return -1
}

# Normalize a TOML key or dotted table path by unquoting quoted segments and
# joining the segments with '.'. Quoted segments must not contain '.' (rack
# coordinates never do); this keeps the normalized form unambiguous.
def toml_normalize_key(raw: str, out: @var TomlKeyPath) -> str {
    out.value = ""
    s = trim_ws(raw)
    if s.len() == 0 {
        return "empty key"
    }
    joined = ""
    i = 0
    while i < s.len() {
        while i < s.len() and (s.char_at(i) == 32 or s.char_at(i) == 9) {
            i = i + 1
        }
        if i >= s.len() {
            return "empty key segment"
        }
        seg = ""
        if s.char_at(i) == 34 {
            start = i + 1
            i = start
            closed = -1
            while i < s.len() {
                c = s.char_at(i)
                if c == 92 {
                    i = i + 2
                    continue
                }
                if c == 34 {
                    closed = i
                    break
                }
                i = i + 1
            }
            if closed < 0 {
                return "unterminated quoted key"
            }
            seg = toml_unescape(s.slice(start, closed))
            if find_char(seg, ".") >= 0 {
                return "quoted key segment must not contain '.'"
            }
            i = closed + 1
        } else {
            start = i
            while i < s.len() {
                c = s.char_at(i)
                if c == 46 or c == 32 or c == 9 {
                    break
                }
                if c == 34 {
                    return "unexpected quote in bare key"
                }
                i = i + 1
            }
            seg = s.slice(start, i)
        }
        if seg.len() == 0 {
            return "empty key segment"
        }
        if joined.len() > 0 {
            joined = joined + "."
        }
        joined = joined + seg
        while i < s.len() and (s.char_at(i) == 32 or s.char_at(i) == 9) {
            i = i + 1
        }
        if i < s.len() {
            if s.char_at(i) != 46 {
                return "expected '.' between key segments"
            }
            i = i + 1
            if i >= s.len() {
                return "trailing '.' in key"
            }
        }
    }
    out.value = joined
    return ""
}

# Parse TOML text into @var doc; returns "" on success or an error message
public def toml_parse(text: str, doc: @var TomlDoc) -> str {
    tables = List[TomlTable]()
    cur = TomlTable()
    cur.path = ""
    cur.keys = List[str]()
    cur.values = List[str]()
    started = False

    for line in text.split("\n") {
        t = trim_ws(line)
        if t.len() == 0 {
            continue
        }
        if t.startswith("#") {
            continue
        }
        if t.startswith("[[") {
            return "unsupported syntax: array of tables `[[...]]`"
        }
        if t.startswith("[") {
            # Table headers allow trailing comments: truncate before validating
            hc = toml_find_unquoted(t, "#")
            if hc >= 0 {
                t = trim_ws(t.slice(0, hc))
            }
            if not t.endswith("]") {
                return "bad table header: `" + t + "`"
            }
            kp = TomlKeyPath()
            perr = toml_normalize_key(trim_ws(t.slice(1, t.len() - 1)), @var kp)
            if perr != "" {
                return "bad table header `" + t + "`: " + perr
            }
            if started {
                tables.push(cur)
            }
            cur = TomlTable()
            cur.path = kp.value
            cur.keys = List[str]()
            cur.values = List[str]()
            started = True
            continue
        }
        eq = toml_find_unquoted(t, "=")
        if eq < 0 {
            return "bad line: `" + t + "` (expected `key = value`)"
        }
        key_raw = trim_ws(t.slice(0, eq))
        rest = trim_ws(t.slice(eq + 1, t.len()))
        if key_raw.len() == 0 {
            return "empty key in line: `" + t + "`"
        }
        kp = TomlKeyPath()
        kerr = toml_normalize_key(key_raw, @var kp)
        if kerr != "" {
            return "bad key `" + key_raw + "`: " + kerr
        }
        key = kp.value
        if cur.keys.contains(key) {
            return "duplicate key `" + key + "` in [" + cur.path + "]"
        }
        started = True
        if rest.startswith("[") {
            # Single-line string array: ["a", "b"]; skip strings and escapes while scanning for the top-level ]
            close = -1
            si = 1
            while si < rest.len() {
                c = rest.char_at(si)
                if c == 34 {
                    si = si + 1
                    while si < rest.len() {
                        d = rest.char_at(si)
                        if d == 92 {
                            si = si + 2
                            continue
                        }
                        if d == 34 {
                            break
                        }
                        si = si + 1
                    }
                    si = si + 1
                    continue
                }
                if c == 93 {
                    close = si
                    break
                }
                si = si + 1
            }
            if close < 0 {
                return "unsupported syntax: multi-line array for `" + key + "`"
            }
            v = rest.slice(0, close + 1)
            tail = trim_ws(rest.slice(close + 1, rest.len()))
            if tail.len() > 0 and not tail.startswith("#") {
                return "trailing characters after array: `" + tail + "`"
            }
            aerr = toml_array_error(v)
            if aerr != "" {
                return "array `" + key + "`: " + aerr
            }
            cur.keys.push(key)
            cur.values.push(v)
            continue
        }
        if rest.startswith("{") {
            return "unsupported syntax: inline table for `" + key + "`"
        }

        v = ""
        if rest.startswith("\"") {
            # Scan for the closing quote (skipping \" escapes); only a comment may follow the quote
            i = 1
            closed = -1
            while i < rest.len() {
                c = rest.char_at(i)
                if c == 92 {
                    i = i + 2
                    continue
                }
                if c == 34 {
                    closed = i
                    break
                }
                i = i + 1
            }
            if closed < 0 {
                return "unterminated string for key `" + key + "`"
            }
            v = toml_unescape(rest.slice(1, closed))
            tail = trim_ws(rest.slice(closed + 1, rest.len()))
            if tail.len() > 0 and not tail.startswith("#") {
                return "trailing characters after string: `" + tail + "`"
            }
        } else {
            # Bare scalar: after stripping the `#` comment it must be non-empty and contain no spaces
            h = find_char(rest, "#")
            if h >= 0 {
                rest = trim_ws(rest.slice(0, h))
            }
            if rest.len() == 0 {
                return "missing value for key `" + key + "`"
            }
            if find_char(rest, " ") >= 0 {
                return "bare value must be a single token: `" + rest + "`"
            }
            v = rest
        }
        cur.keys.push(key)
        cur.values.push(v)
    }
    if started {
        tables.push(cur)
    }
    doc.tables = tables
    return ""
}

def toml_unescape(s: str) -> str {
    out = ""
    i = 0
    while i < s.len() {
        c = s.char_at(i)
        if c == 92 and i + 1 < s.len() {
            n = s.char_at(i + 1)
            if n == 110 {
                out = out + "\n"
            } elif n == 116 {
                out = out + "\t"
            } elif n == 34 {
                out = out + "\""
            } elif n == 92 {
                out = out + "\\"
            } else {
                out = out + s.slice(i, i + 2)
            }
            i = i + 2
        } else {
            out = out + s.slice(i, i + 1)
            i = i + 1
        }
    }
    return out
}

# Strictly validate the raw array text (matching "[" and stripped comments); returns "" if valid, otherwise an error message
def toml_array_error(raw: str) -> str {
    if not raw.startswith("[") or not raw.endswith("]") {
        return "malformed array"
    }
    inner = raw.slice(1, raw.len() - 1)
    i = 0
    while i < inner.len() {
        c = inner.char_at(i)
        if c == 32 or c == 9 {
            i = i + 1
            continue
        }
        if c != 34 {
            return "elements must be quoted strings: `" + inner + "`"
        }
        j = i + 1
        closed = -1
        while j < inner.len() {
            d = inner.char_at(j)
            if d == 92 {
                j = j + 2
                continue
            }
            if d == 34 {
                closed = j
                break
            }
            j = j + 1
        }
        if closed < 0 {
            return "unterminated string in array"
        }
        i = closed + 1
        while i < inner.len() {
            c2 = inner.char_at(i)
            if c2 == 32 or c2 == 9 {
                i = i + 1
                continue
            }
            if c2 == 44 {
                i = i + 1
                break
            }
            return "expected `,` between array elements: `" + inner + "`"
        }
    }
    return ""
}

# Split the raw array text into a list of elements (assumes toml_array_error already validated); non-arrays return an empty list
public def toml_array_elems(raw: str) -> List[str] {
    out = List[str]()
    if raw.len() < 2 or not raw.startswith("[") or not raw.endswith("]") {
        return out
    }
    inner = raw.slice(1, raw.len() - 1)
    i = 0
    while i < inner.len() {
        c = inner.char_at(i)
        if c == 32 or c == 9 or c == 44 {
            i = i + 1
            continue
        }
        if c == 34 {
            j = i + 1
            closed = -1
            while j < inner.len() {
                d = inner.char_at(j)
                if d == 92 {
                    j = j + 2
                    continue
                }
                if d == 34 {
                    closed = j
                    break
                }
                j = j + 1
            }
            if closed < 0 {
                return out
            }
            out.push(toml_unescape(inner.slice(i + 1, closed)))
            i = closed + 1
        } else {
            j = i
            while j < inner.len() and inner.char_at(j) != 44 {
                j = j + 1
            }
            out.push(trim_ws(inner.slice(i, j)))
            i = j
        }
    }
    return out
}

# Encode as a TOML string literal (including the surrounding quotes)
public def toml_escape_str(s: str) -> str {
    out = "\""
    i = 0
    while i < s.len() {
        c = s.char_at(i)
        if c == 34 {
            out = out + "\\\""
        } elif c == 92 {
            out = out + "\\\\"
        } else {
            out = out + s.slice(i, i + 1)
        }
        i = i + 1
    }
    return out + "\""
}

# Whether a string is valid as a TOML bare key (A-Za-z0-9_- only)
def toml_is_bare_key(s: str) -> bool {
    if s.len() == 0 {
        return False
    }
    i = 0
    while i < s.len() {
        c = s.char_at(i)
        ok = (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or
             (c >= 48 and c <= 57) or c == 95 or c == 45
        if not ok {
            return False
        }
        i = i + 1
    }
    return True
}

# Encode a key for TOML output: bare when possible, otherwise a quoted string
public def toml_quote_key(key: str) -> str {
    if toml_is_bare_key(key) {
        return key
    }
    return toml_escape_str(key)
}

# Encode a dotted table path, quoting only the segments that need it
public def toml_quote_path(path: str) -> str {
    segs = path.split(".")
    out = ""
    i = 0
    while i < segs.len() {
        if i > 0 {
            out = out + "."
        }
        out = out + toml_quote_key(segs.get(i))
        i = i + 1
    }
    return out
}

# ---------- Accessors (all read-only; accessed across modules through functions to avoid borrow details) ----------

public def toml_table_count(doc: @TomlDoc) -> int {
    return doc.tables.len()
}

public def toml_table_path(doc: @TomlDoc, i: int) -> str {
    return doc.tables.get(i).path
}

# Table index by dotted path; -1 when absent
public def toml_find(doc: @TomlDoc, path: str) -> int {
    i = 0
    while i < doc.tables.len() {
        if doc.tables.get(i).path == path {
            return i
        }
        i = i + 1
    }
    return -1
}

# Key list of the i-th table (copy)
public def toml_table_keys(doc: @TomlDoc, i: int) -> List[str] {
    t = doc.tables.get(i)
    out = List[str]()
    j = 0
    while j < t.keys.len() {
        out.push(t.keys.get(j))
        j = j + 1
    }
    return out
}

public def toml_table_value(doc: @TomlDoc, i: int, key: str) -> str {
    t = doc.tables.get(i)
    j = 0
    while j < t.keys.len() {
        if t.keys.get(j) == key {
            return t.values.get(j)
        }
        j = j + 1
    }
    return ""
}

public def toml_get(doc: @TomlDoc, path: str, key: str) -> str {
    i = toml_find(@doc, path)
    if i < 0 {
        return ""
    }
    return toml_table_value(@doc, i, key)
}

# Element list of an array key; returns an empty list when the key is missing or not an array
public def toml_get_list(doc: @TomlDoc, path: str, key: str) -> List[str] {
    raw = toml_get(@doc, path, key)
    if not raw.startswith("[") {
        return List[str]()
    }
    return toml_array_elems(raw)
}
