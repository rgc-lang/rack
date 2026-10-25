import os
import toml

# Standalone parser test for TOML quoted keys (run via toml_quoted_test.sh).
# The real toml.rg + util.rg are staged next to this file before compiling.

def fail(msg: str) -> int {
    print("FAIL: " + msg)
    os.exit(1)
    return 1
}

def check_eq(got: str, want: str, what: str) -> int {
    if got != want {
        return fail(what + ": got `" + got + "`, want `" + want + "`")
    }
    return 0
}

def main() -> int {
    text = "[package]\nname = \"demo\"\nversion = \"0.1.0\"\n\n[dependencies]\n\"alice/calcx\" = \"0.1.0\"\nplain = \"2.0.0\"\n\n[dependencies.\"bob/mathx\"]\nversion = \"0.2.0\"\ngit = \"github.com/bob/mathx\"\n"
    doc = toml_new_doc()
    err = toml_parse(text, @var doc)
    if err != "" {
        return fail("parse: " + err)
    }
    check_eq(toml_get(@doc, "package", "name"), "demo", "package.name")
    check_eq(toml_get(@doc, "dependencies", "alice/calcx"), "0.1.0", "quoted dependency key")
    check_eq(toml_get(@doc, "dependencies", "plain"), "2.0.0", "bare dependency key")
    check_eq(toml_table_path(@doc, 2), "dependencies.bob/mathx", "quoted table path")
    check_eq(toml_get(@doc, "dependencies.bob/mathx", "version"), "0.2.0", "quoted table version")

    # '#' and '=' inside a quoted key must not confuse the comment / separator scanners.
    punct = "[dependencies]\n\"a#b=c\" = \"1.0.0\"\n"
    d2 = toml_new_doc()
    e2 = toml_parse(punct, @var d2)
    if e2 != "" {
        return fail("quoted punctuation: " + e2)
    }
    check_eq(toml_get(@d2, "dependencies", "a#b=c"), "1.0.0", "quoted punctuation key")

    # Bare and quoted spellings normalize to the same key, so duplicates are rejected.
    dup = "[dependencies]\n\"a/b\" = \"1.0.0\"\na/b = \"2.0.0\"\n"
    d3 = toml_new_doc()
    e3 = toml_parse(dup, @var d3)
    if e3 == "" {
        return fail("duplicate normalized key accepted")
    }

    # A quoted segment containing '.' is ambiguous with a dotted path; reject it.
    dot = "[dependencies.\"a.b\"]\nversion = \"1.0.0\"\n"
    d4 = toml_new_doc()
    e4 = toml_parse(dot, @var d4)
    if e4 == "" {
        return fail("quoted segment with dot accepted")
    }

    # Serialization helpers used by manifest save.
    check_eq(toml_quote_key("alice/calcx"), "\"alice/calcx\"", "quote namespaced key")
    check_eq(toml_quote_key("plain-key"), "plain-key", "bare key stays bare")
    check_eq(toml_quote_path("dependencies.alice/calcx"), "dependencies.\"alice/calcx\"", "quote dotted path")

    # Round-trip: serialize a dependency key, then parse it back.
    out = "[dependencies]\n" + toml_quote_key("alice/calcx") + " = \"0.1.0\"\n"
    d5 = toml_new_doc()
    e5 = toml_parse(out, @var d5)
    if e5 != "" {
        return fail("round-trip parse: " + e5)
    }
    check_eq(toml_get(@d5, "dependencies", "alice/calcx"), "0.1.0", "round-trip value")

    # Root-level keys (settings.toml): a file with no table header still yields the root table.
    settings = "# generated\ndefault = \"0.2.0\"\nchannel = \"stable\"\n"
    d6 = toml_new_doc()
    e6 = toml_parse(settings, @var d6)
    if e6 != "" {
        return fail("root keys parse: " + e6)
    }
    check_eq(toml_get(@d6, "", "default"), "0.2.0", "root default")
    check_eq(toml_get(@d6, "", "channel"), "stable", "root channel")

    print("ok")
    return 0
}
