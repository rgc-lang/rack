#!/usr/bin/env bash
# rack/test.sh — rack end-to-end regression tests
#
# Covers: --version / TOML manifests (quotes, comments, [dependencies.x] subtables, arrays) /
#         web publish (login/credentials, JSON plain-text module, flat-name hint, repository
#         required, github_app_not_installed, repo_not_owned, version_exists) /
#         seeded local registry / search / new (+.gitignore) / init /
#         install (latest + locked + already satisfied + transitive deps) / tree / version conflicts /
#         dependency cycles / update / remove / fresh-clone missing deps / clean / error paths /
#         registry tampering -> checksum mismatch /
#         GitHub-hosted sources (mock server): latest/exact/URL/gh: forms, transitive deps,
#         manifest git subtables, source conflicts, offline cache, cache repair, tag drift,
#         name mismatch, pagination, remote search and tokens, update upgrades
# Uses a temporary HOME and temporary directories throughout; the real environment is never touched.
#
# Usage: ./test.sh   (point RACK_BIN=... to the binary under test)

set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
RACK="${RACK_BIN:-$REPO/target/bin/rack}"
# Compiler: `rgc` on PATH, or RGC=<path>; passed to rack build via RGC.
RGC_BIN="${RGC:-}"
if [ -z "$RGC_BIN" ]; then
    if [ -x "$REPO/build/rgc" ]; then
        RGC_BIN="$REPO/build/rgc"
    else
        RGC_BIN="$(command -v rgc || true)"
    fi
fi
if [ -z "$RGC_BIN" ] || [ ! -x "$RGC_BIN" ]; then
    echo "error: no RGC compiler found"
    echo "hint: install an RGC release and put rgc on PATH, or set RGC=<path>"
    exit 1
fi
export RGC="$RGC_BIN"
export PATH="$(dirname "$RGC_BIN"):$PATH"

if [ ! -x "$RACK" ]; then
    echo "error: rack binary not found at $RACK"
    echo "hint: run rack/bootstrap.sh first (or set RACK_BIN=<path>)"
    exit 1
fi

PASS=0
FAIL=0
check() { # <name> <expected substring> <actual output>
    if grep -qF "$2" <<<"$3"; then
        PASS=$((PASS + 1))
        echo "PASS $1"
    else
        FAIL=$((FAIL + 1))
        echo "FAIL $1"
        echo "  expected to contain: $2"
        echo "  actual output: $(head -5 <<<"$3")"
    fi
}
checkrc() { # <name> <expected exit code> <actual exit code>
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1))
        echo "PASS $1"
    else
        FAIL=$((FAIL + 1))
        echo "FAIL $1 (expected exit code $2, got $3)"
    fi
}

WORK="$(mktemp -d)"
export HOME="$WORK/home"
mkdir -p "$HOME"
GH_PID=""
REG_PID=""
SELF_PID=""
cleanup() {
    if [ -n "$GH_PID" ]; then
        kill "$GH_PID" 2>/dev/null
        wait "$GH_PID" 2>/dev/null
    fi
    if [ -n "$REG_PID" ]; then
        kill "$REG_PID" 2>/dev/null
        wait "$REG_PID" 2>/dev/null
    fi
    if [ -n "$SELF_PID" ]; then
        kill "$SELF_PID" 2>/dev/null
        wait "$SELF_PID" 2>/dev/null
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT
cd "$WORK"

# ---------- basics ----------
OUT="$($RACK --version)"
check version "rack 0.4.2" "$OUT"

# ---------- TOML quoted keys (namespace prerequisite) ----------
OUT="$(RGC="$RGC_BIN" "$REPO/tests/toml_quoted_test.sh" 2>&1)"
check toml-quoted-keys "ok" "$OUT"

# ---------- portable util helpers (Windows build-driver foundation) ----------
OUT="$(RGC="$RGC_BIN" "$REPO/tests/util_test.sh" 2>&1)"
check util-helpers "util-ok" "$OUT"

# ---------- rack test: suite / main+expected/exit / negative / unit dispatch ----------
RT="$WORK/rtest"
mkdir -p "$RT/tests/negative" "$RT/tests/suite" "$RT/tests/with_expected"
cat > "$RT/tests/unit_sample.rg" <<'EOF'
public def test_ok() -> int {
    print("unit-one")
    return 0
}

public def test_fail() -> int {
    return 3
}
EOF
cat > "$RT/tests/plain.rg" <<'EOF'
def main() {
    print("plain")
}
EOF
cat > "$RT/tests/with_expected/main.rg" <<'EOF'
def main() -> int {
    print("bye")
    return 7
}
EOF
printf 'bye\n' > "$RT/tests/with_expected/expected"
printf '7\n' > "$RT/tests/with_expected/exit"
cat > "$RT/tests/negative/err_bad.rg" <<'EOF'
def main() {
    x: int = "text"
}
EOF
cat > "$RT/tests/suite/suite.rg" <<'EOF'
def main() -> int {
    a = args()
    print("suite-ok " + a.get(1))
    return 0
}
EOF
OUT="$("$RACK" test "$RT/tests" 2>&1)"
RC=$?
checkrc rack-test-exit 1 "$RC"
check rack-test-plain "PASS tests/plain" "$OUT"
check rack-test-expected "PASS tests/with_expected" "$OUT"
check rack-test-negative "PASS tests/negative/err_bad" "$OUT"
check rack-test-suite "suite-ok $RT/tests/suite" "$OUT"
check rack-test-unit-pass "PASS tests/unit_sample::test_ok" "$OUT"
check rack-test-unit-fail "FAIL tests/unit_sample::test_fail (exit=3)" "$OUT"

# ---------- seed the local registry (web publish is tested below against the mock registry) ----------
seed_pkg() { # <name> <version> <source-dir>
    local name="$1" version="$2" srcdir="$3"
    local dir="$HOME/.rack/registry/$name/$version"
    mkdir -p "$dir"
    cp "$srcdir/$name.rg" "$dir/$name.rg"
    local ck
    ck="$(sha256sum "$dir/$name.rg" | awk '{print $1}')"
    # Insert `checksum` into the (first) [package] table: the registry install
    # path reads it via toml_get(doc, "package", "checksum").
    awk -v ck="$ck" '
        /^\[package\]/ && !done { print; print "checksum = \"" ck "\""; done = 1; next }
        { print }
    ' "$srcdir/rack.toml" > "$dir/rack.toml"
}

mkdir -p "$WORK/mathx010"
cp "$REPO/examples/mathx/mathx.rg" "$WORK/mathx010/mathx.rg"
sed 's/version = "0.2.0"/version = "0.1.0"/' "$REPO/examples/mathx/rack.toml" > "$WORK/mathx010/rack.toml"
seed_pkg mathx 0.1.0 "$WORK/mathx010"
seed_pkg mathx 0.2.0 "$REPO/examples/mathx"
seed_pkg calcx 0.1.0 "$REPO/examples/calcx"

if [ -f "$HOME/.rack/registry/mathx/0.2.0/rack.toml" ]; then
    PASS=$((PASS + 1)); echo "PASS seed-manifest-stored"
else
    FAIL=$((FAIL + 1)); echo "FAIL seed-manifest-stored"
fi

# the registry manifest records the module sha256
if grep -qF 'checksum = "' "$HOME/.rack/registry/mathx/0.2.0/rack.toml"; then
    PASS=$((PASS + 1)); echo "PASS seed-checksum-recorded"
else
    FAIL=$((FAIL + 1)); echo "FAIL seed-checksum-recorded"
    cat "$HOME/.rack/registry/mathx/0.2.0/rack.toml"
fi

# ==================== web registry publish (mock server) ====================
echo
echo "== web registry publish"
REG_LOG="$WORK/reg-requests.log"
REG_PORT_FILE="$WORK/reg.port"
if ! command -v python3 >/dev/null 2>&1; then
    echo "error: python3 is required for the mock registry server"
    exit 1
fi
python3 "$REPO/tests/mock_registry.py" --port-file "$REG_PORT_FILE" --log "$REG_LOG" &
REG_PID=$!
for _ in $(seq 1 100); do
    [ -s "$REG_PORT_FILE" ] && break
    sleep 0.05
done
if [ ! -s "$REG_PORT_FILE" ]; then
    echo "error: mock registry server did not start"
    exit 1
fi
REG_PORT="$(cat "$REG_PORT_FILE")"
export RACK_REGISTRY_API="http://127.0.0.1:$REG_PORT"

# `rack login --token` saves the token; publish then authenticates via credentials.toml
OUT="$($RACK login --token secret-reg-token)"
check login-saved "Saved registry token" "$OUT"
if grep -qF 'token = "secret-reg-token"' "$HOME/.rack/credentials.toml"; then
    PASS=$((PASS + 1)); echo "PASS login-credentials-file"
else
    FAIL=$((FAIL + 1)); echo "FAIL login-credentials-file"
    cat "$HOME/.rack/credentials.toml"
fi

# §10 device login: automatic Device Flow (codes → token), one-time code fallback, bad code rejection
OUT="$($RACK login)"
check login-device-flow "Approved" "$OUT"
check login-device-flow-saved "Saved registry token" "$OUT"
if grep -qF 'token = "rgc_mock_device"' "$HOME/.rack/credentials.toml"; then
    PASS=$((PASS + 1)); echo "PASS login-device-token-saved"
else
    FAIL=$((FAIL + 1)); echo "FAIL login-device-token-saved"
    cat "$HOME/.rack/credentials.toml"
fi
OUT="$($RACK login --code goodcode)"
check login-code-exchanged "Saved registry token" "$OUT"
if grep -qF 'token = "rgc_mock_goodcode"' "$HOME/.rack/credentials.toml"; then
    PASS=$((PASS + 1)); echo "PASS login-code-token-saved"
else
    FAIL=$((FAIL + 1)); echo "FAIL login-code-token-saved"
    cat "$HOME/.rack/credentials.toml"
fi
OUT="$($RACK login --code badcode 2>&1)"
check login-code-rejected "code exchange failed" "$OUT"

# §4.7 yank: happy path (uses the token from the code login), missing version, then logout
OUT="$($RACK yank alice/webpkg@0.1.0)"
check yank-ok "Yanked alice/webpkg@0.1.0" "$OUT"
OUT="$($RACK yank alice/webpkg@0.0.0 2>&1)"
check yank-missing-version "version_not_found" "$OUT"
OUT="$($RACK logout)"
check logout-removed "Removed" "$OUT"
OUT="$($RACK yank alice/webpkg@0.1.0 2>&1)"
check yank-no-token "no token" "$OUT"
# restore the manual token for the remaining publish cases
$RACK login --token secret-reg-token > /dev/null

# scoped package publish (module as plain UTF-8 text, JSON body, credentials token)
mkdir -p webpkg && cd webpkg
cat > rack.toml <<'EOF'
[package]
name = "alice/webpkg"
version = "0.1.0"
entry = "webpkg.rg"
repository = "https://github.com/alice/webpkg"
description = "web registry publish test"
keywords = ["web", "demo"]
EOF
cat > webpkg.rg <<'EOF'
public def web_add(a: int, b: int) -> int {
    return a + b
}
EOF
OUT="$($RACK publish)"
check web-publish "Published alice/webpkg@0.1.0" "$OUT"
check web-publish-url "http://127.0.0.1:$REG_PORT" "$OUT"
cd "$WORK"

# the publish token is sent as Authorization: Bearer
if grep -qF 'auth=Bearer secret-reg-token' "$REG_LOG"; then
    PASS=$((PASS + 1)); echo "PASS web-publish-token"
else
    FAIL=$((FAIL + 1)); echo "FAIL web-publish-token"
fi

# RACK_PUBLISH_TOKEN env var works too
mkdir -p envpkg && cd envpkg
cat > rack.toml <<'EOF'
[package]
name = "alice/envpkg"
version = "0.2.0"
entry = "envpkg.rg"
repository = "github.com/alice/envpkg"
EOF
cat > envpkg.rg <<'EOF'
public def env_add(a: int, b: int) -> int {
    return a + b
}
EOF
OUT="$(RACK_PUBLISH_TOKEN=env-token $RACK publish)"
check env-publish "Published alice/envpkg@0.2.0" "$OUT"
cd "$WORK"

# flat package name -> 400 invalid_name with a scope/name hint
mkdir -p flatpkg && cd flatpkg
cat > rack.toml <<'EOF'
[package]
name = "flat"
version = "0.1.0"
entry = "flat.rg"
repository = "https://github.com/alice/flat"
EOF
cat > flat.rg <<'EOF'
public def flat_fn() -> int { return 0 }
EOF
RC=0; OUT="$(RACK_PUBLISH_TOKEN=t $RACK publish)" || RC=$?
check flat-name-error "invalid_name" "$OUT"
check flat-name-hint "scope/name" "$OUT"
checkrc flat-name-exit 1 "$RC"
cd "$WORK"

# missing repository -> rejected locally before any HTTP call
mkdir -p norepo && cd norepo
cat > rack.toml <<'EOF'
[package]
name = "alice/norepo"
version = "0.1.0"
entry = "norepo.rg"
EOF
cat > norepo.rg <<'EOF'
public def norepo_fn() -> int { return 0 }
EOF
RC=0; OUT="$(RACK_PUBLISH_TOKEN=t $RACK publish)" || RC=$?
check norepo-error "requires a GitHub repository" "$OUT"
checkrc norepo-exit 1 "$RC"
cd "$WORK"

# GitHub App not installed -> 403 github_app_not_installed
mkdir -p nosuch && cd nosuch
cat > rack.toml <<'EOF'
[package]
name = "alice/nosuch"
version = "0.1.0"
entry = "nosuch.rg"
repository = "https://github.com/alice/nosuch-repo"
EOF
cat > nosuch.rg <<'EOF'
public def nosuch_fn() -> int { return 0 }
EOF
RC=0; OUT="$(RACK_PUBLISH_TOKEN=t $RACK publish)" || RC=$?
check app-not-installed "github_app_not_installed" "$OUT"
checkrc app-not-installed-exit 1 "$RC"
cd "$WORK"

# repository not owned -> 403 repo_not_owned
mkdir -p notowned && cd notowned
cat > rack.toml <<'EOF'
[package]
name = "alice/notowned"
version = "0.1.0"
entry = "notowned.rg"
repository = "https://github.com/bob/notowned"
EOF
cat > notowned.rg <<'EOF'
public def notowned_fn() -> int { return 0 }
EOF
RC=0; OUT="$(RACK_PUBLISH_TOKEN=t $RACK publish)" || RC=$?
check repo-not-owned "repo_not_owned" "$OUT"
checkrc repo-not-owned-exit 1 "$RC"
cd "$WORK"

# version already exists -> 409 version_exists
mkdir -p verdup && cd verdup
cat > rack.toml <<'EOF'
[package]
name = "alice/verdup"
version = "9.9.9"
entry = "verdup.rg"
repository = "https://github.com/alice/verdup"
EOF
cat > verdup.rg <<'EOF'
public def verdup_fn() -> int { return 0 }
EOF
RC=0; OUT="$(RACK_PUBLISH_TOKEN=t $RACK publish)" || RC=$?
check version-exists "version_exists" "$OUT"
checkrc version-exists-exit 1 "$RC"
cd "$WORK"

unset RACK_REGISTRY_API

# ---------- search ----------
OUT="$($RACK search mathx)"
check search-hit "mathx@0.2.0" "$OUT"
check search-desc "fib and other small math utilities" "$OUT"
OUT="$($RACK search zz-no-such-pkg)"
check search-miss "no packages matched" "$OUT"

# ---------- new: scaffold + .gitignore ----------
OUT="$($RACK new demo)"
check new "created demo/" "$OUT"
if [ -f demo/.gitignore ] && [ -f demo/rack.toml ] && [ -f demo/main.rg ]; then
    PASS=$((PASS + 1)); echo "PASS new-files"
else
    FAIL=$((FAIL + 1)); echo "FAIL new-files"
fi

cat > demo/main.rg <<'EOF'
import calcx

def main() -> int {
    print("double_add(2, 3) =", double_add(2, 3))
    print("fib_sq(10) =", fib_sq(10))
    return 0
}
EOF

# ---------- install: transitive deps (calcx -> mathx@0.2.0) ----------
OUT="$(cd demo && $RACK install calcx)"
check install-transitive "+ calcx@0.1.0" "$OUT"
check install-transitive-dep "+ mathx@0.2.0" "$OUT"
if grep -qF 'calcx = "0.1.0"' demo/rack.toml && ! grep -qF 'mathx' demo/rack.toml; then
    PASS=$((PASS + 1)); echo "PASS manifest-records-direct"
else
    FAIL=$((FAIL + 1)); echo "FAIL manifest-records-direct"; cat demo/rack.toml
fi
if [ -f demo/rack.lock ]; then
    PASS=$((PASS + 1)); echo "PASS lock-created"
else
    FAIL=$((FAIL + 1)); echo "FAIL lock-created"
fi
if grep -qF '[lock.calcx]' demo/rack.lock && grep -qF '[lock.mathx]' demo/rack.lock && \
   grep -qF 'checksum = "' demo/rack.lock && grep -qF 'dependencies = ["mathx"]' demo/rack.lock; then
    PASS=$((PASS + 1)); echo "PASS lock-closure"
else
    FAIL=$((FAIL + 1)); echo "FAIL lock-closure"; cat demo/rack.lock
fi

# ---------- tree ----------
OUT="$(cd demo && $RACK tree)"
check tree-root "demo@0.1.0" "$OUT"
check tree-calcx "└── calcx@0.1.0" "$OUT"
check tree-nested "    └── mathx@0.2.0" "$OUT"

# ---------- build + run ----------
OUT="$(cd demo && $RACK build)"
check build "built:" "$OUT"
OUT="$(cd demo && $RACK run)"
check run "double_add(2, 3) = 10" "$OUT"
check run-fib "fib_sq(10) = 3025" "$OUT"

# already satisfied
OUT="$(cd demo && $RACK install mathx@0.2.0)"
check install-satisfied "already satisfied: mathx@0.2.0" "$OUT"

# ---------- version conflict ----------
RC=0; OUT="$(cd demo && $RACK install mathx@0.1.0)" || RC=$?
check conflict "version conflict" "$OUT"
checkrc conflict-exit 1 "$RC"

# ---------- dependency cycle ----------
mkdir -p "$HOME/.rack/registry/loopa/0.1.0"
printf 'public def ping() -> int {\n    return 1\n}\n' > "$HOME/.rack/registry/loopa/0.1.0/loopa.rg"
cat > "$HOME/.rack/registry/loopa/0.1.0/rack.toml" <<'EOF'
[package]
name = "loopa"
version = "0.1.0"
entry = "loopa.rg"

[dependencies]
loopa = "0.1.0"
EOF
OUT="$(cd demo && $RACK install loopa)"
check cycle "dependency cycle" "$OUT"

# ---------- TOML subtables + trailing comments ----------
mkdir -p proj3 && cd proj3
cat > rack.toml <<'EOF'
# comment line
[package]
name = "proj3"
version = "0.1.0"

[dependencies.mathx]   # trailing comment
version = "0.2.0"
EOF
cat > main.rg <<'EOF'
import mathx

def main() -> int {
    print("fib(6) =", fib(6))
    return 0
}
EOF
OUT="$($RACK install mathx)"
check toml-subtable "already satisfied: mathx@0.2.0" "$OUT"
OUT="$($RACK run)"
check toml-subtable-run "fib(6) = 8" "$OUT"
cd "$WORK"

# ---------- init ----------
mkdir -p inited && cd inited
OUT="$($RACK init)"
check init "initialized rack project" "$OUT"
if [ -f .gitignore ] && [ -f rack.toml ] && [ -f main.rg ]; then
    PASS=$((PASS + 1)); echo "PASS init-files"
else
    FAIL=$((FAIL + 1)); echo "FAIL init-files"
fi
RC=0; OUT="$($RACK init)" || RC=$?
check init-again "already exists" "$OUT"
checkrc init-again-exit 1 "$RC"
cd "$WORK"

# ---------- update: re-resolve direct deps to latest, upgrade the closure into the lock ----------
OUT="$(cd demo && $RACK update)"
check update "Updated 2 direct dependencies" "$OUT"
if grep -A1 -F '[lock.mathx]' demo/rack.lock | grep -qF 'version = "0.2.0"'; then
    PASS=$((PASS + 1)); echo "PASS update-lock-bumps"
else
    FAIL=$((FAIL + 1)); echo "FAIL update-lock-bumps"; cat demo/rack.lock
fi
OUT="$(cd demo && $RACK run)"
check update-run "double_add(2, 3) = 10" "$OUT"

# ---------- fresh clone: manifest has deps but the cache is missing ----------
rm -rf demo/target
OUT="$(cd demo && $RACK build)"
check build-missing-dep "is not installed" "$OUT"
check build-missing-hint "rack install" "$OUT"
OUT="$(cd demo && $RACK install calcx)"
check install-recovery "already satisfied: calcx@0.1.0" "$OUT"
OUT="$(cd demo && $RACK run)"
check install-recovery-run "double_add(2, 3) = 10" "$OUT"

# ---------- [package] metadata keys: parse + preserved on install round-trips ----------
mkdir -p meta && cd meta
cat > rack.toml <<'MANIFEST'
[package]
name = "meta"
version = "0.1.0"
edition = "2024"
rust-version = "1.97"       # MSRV
license = "MIT OR Apache-2.0"
repository = "https://example.com/meta"
homepage = "https://example.com/meta"
documentation = "https://example.com/meta/docs"
readme = "README.md"
description = "metadata roundtrip test"
authors = ["Alice", "Bob"]      # array metadata
keywords = ["math", "demo"]
categories = ["algorithms"]

[dependencies]
mathx = "0.2.0"
MANIFEST
cat > main.rg <<'MAINRG'
import mathx

def main() -> int {
    print("fib(5) =", fib(5))
    return 0
}
MAINRG
OUT="$($RACK install mathx)"
check metadata-parse "already satisfied: mathx@0.2.0" "$OUT"
if grep -qF 'edition = "2024"' rack.toml && grep -qF 'rust-version = "1.97"' rack.toml && \
   grep -qF 'license = "MIT OR Apache-2.0"' rack.toml && grep -qF 'description = "metadata roundtrip test"' rack.toml; then
    PASS=$((PASS + 1)); echo "PASS metadata-roundtrip"
else
    FAIL=$((FAIL + 1)); echo "FAIL metadata-roundtrip"; echo "  rack.toml after install:"; cat rack.toml
fi
if grep -qF 'homepage = "https://example.com/meta"' rack.toml && \
   grep -qF 'documentation = "https://example.com/meta/docs"' rack.toml && \
   grep -qF 'readme = "README.md"' rack.toml && \
   grep -qF 'authors = ["Alice", "Bob"]' rack.toml && \
   grep -qF 'keywords = ["math", "demo"]' rack.toml && \
   grep -qF 'categories = ["algorithms"]' rack.toml; then
    PASS=$((PASS + 1)); echo "PASS metadata-roundtrip-arrays"
else
    FAIL=$((FAIL + 1)); echo "FAIL metadata-roundtrip-arrays"; echo "  rack.toml after install:"; cat rack.toml
fi
OUT="$($RACK run)"
check metadata-run "fib(5) = 5" "$OUT"
cd "$WORK"

# ---------- checksum: tampered registry -> install rejected ----------
printf '\n# tampered\n' >> "$HOME/.rack/registry/mathx/0.2.0/mathx.rg"
mkdir -p chk && cd chk
printf '[package]\nname = "chk"\nversion = "0.1.0"\n' > rack.toml
RC=0; OUT="$($RACK install mathx@0.2.0)" || RC=$?
check checksum-mismatch "checksum mismatch" "$OUT"
checkrc checksum-mismatch-exit 1 "$RC"
cd "$WORK"
# re-seeding fixes it (recomputes sha256 over the original copy)
cp "$REPO/examples/mathx/mathx.rg" "$HOME/.rack/registry/mathx/0.2.0/mathx.rg"
CK="$(sha256sum "$HOME/.rack/registry/mathx/0.2.0/mathx.rg" | awk '{print $1}')"
sed -i "s/^checksum = .*/checksum = \"$CK\"/" "$HOME/.rack/registry/mathx/0.2.0/rack.toml"
OUT="$(cd chk && $RACK install mathx@0.2.0)"
check checksum-recovery "+ mathx@0.2.0" "$OUT"

# ---------- lock validation of target/deps: tampered cache -> build rejects -> install repairs ----------
printf '\n# tampered\n' >> demo/target/deps/mathx.rg
RC=0; OUT="$(cd demo && $RACK build)" || RC=$?
check lock-cache-guard "checksum mismatch for \`mathx\` in target/deps" "$OUT"
checkrc lock-cache-guard-exit 1 "$RC"
OUT="$(cd demo && $RACK install mathx@0.2.0)"
check lock-repair "already satisfied: mathx@0.2.0" "$OUT"
OUT="$(cd demo && $RACK build)"
# Repaired deps match the first build: fingerprint hits -> fresh skip; otherwise a full rebuild.
if echo "$OUT" | grep -qE "built:|fresh \(unchanged\)"; then
    PASS=$((PASS + 1)); echo "PASS lock-repair-build"
else
    FAIL=$((FAIL + 1)); echo "FAIL lock-repair-build"; echo "  got: $OUT"
fi

# ---------- remove ----------
OUT="$(cd demo && $RACK remove calcx)"
check remove "Removed calcx" "$OUT"
if grep -qF "calcx" demo/rack.toml; then
    FAIL=$((FAIL + 1)); echo "FAIL manifest-cleaned"
else
    PASS=$((PASS + 1)); echo "PASS manifest-cleaned"
fi
if grep -qF '[lock.calcx]' demo/rack.lock; then
    FAIL=$((FAIL + 1)); echo "FAIL lock-entry-removed"; cat demo/rack.lock
else
    PASS=$((PASS + 1)); echo "PASS lock-entry-removed"
fi
if grep -qF '[lock.mathx]' demo/rack.lock; then
    PASS=$((PASS + 1)); echo "PASS lock-keeps-direct"
else
    FAIL=$((FAIL + 1)); echo "FAIL lock-keeps-direct"; cat demo/rack.lock
fi
OUT="$(cd demo && $RACK remove mathx)"
check remove-mathx "Removed mathx" "$OUT"
if grep -qF '[lock.' demo/rack.lock; then
    FAIL=$((FAIL + 1)); echo "FAIL lock-pruned"; cat demo/rack.lock
else
    PASS=$((PASS + 1)); echo "PASS lock-pruned"
fi
RC=0; OUT="$(cd demo && $RACK build)" || RC=$?
checkrc build-after-remove 1 "$RC"

# ---------- clean ----------
OUT="$(cd demo && $RACK clean)"
check clean "Cleaned" "$OUT"
if [ -e demo/target/bin ]; then
    FAIL=$((FAIL + 1)); echo "FAIL clean-removed-bin"
else
    PASS=$((PASS + 1)); echo "PASS clean-removed-bin"
fi

# ---------- error paths ----------
$RACK frobnicate >/dev/null 2>&1
checkrc unknown-command-exit 1 "$?"

OUT="$(cd demo && $RACK install nosuchpkg)"
check install-missing "not found in" "$OUT"

OUT="$(cd demo && $RACK install mathx@1)"
check install-badver "invalid version" "$OUT"

# ==================== GitHub-hosted sources (mock server) ====================
echo
echo "== GitHub source"
GH_FIX="$WORK/github"
cp -R "$REPO/tests/fixtures/github" "$GH_FIX"
GH_LOG="$WORK/gh-requests.log"
GH_PORT_FILE="$WORK/gh.port"
if ! command -v python3 >/dev/null 2>&1; then
    echo "error: python3 is required for the mock GitHub server"
    exit 1
fi
python3 "$REPO/tests/mock_github.py" --fixtures "$GH_FIX" \
    --port-file "$GH_PORT_FILE" --log "$GH_LOG" &
GH_PID=$!
for _ in $(seq 1 100); do
    [ -s "$GH_PORT_FILE" ] && break
    sleep 0.05
done
if [ ! -s "$GH_PORT_FILE" ]; then
    echo "error: mock GitHub server did not start"
    exit 1
fi
GH_PORT="$(cat "$GH_PORT_FILE")"
export RACK_GITHUB_API="http://127.0.0.1:$GH_PORT"
export RACK_GITHUB_RAW="http://127.0.0.1:$GH_PORT/raw"

# ---------- latest-version install (pre-release tags ignored) + manifest/lock/cache ----------
mkdir -p gh1 && cd gh1
printf '[package]\nname = "gh1"\nversion = "0.1.0"\nentry = "main.rg"\n' > rack.toml
cat > main.rg <<'EOF'
import mathx

def main() -> int {
    print("remote sum =", mathx_add(2, 3))
    return 0
}
EOF
OUT="$($RACK install github.com/alice/mathx)"
check github-install-latest "+ mathx@0.2.0 (github.com/alice/mathx)" "$OUT"
check github-resolve-latest "resolved mathx -> mathx@0.2.0" "$OUT"
if grep -qF '[dependencies.mathx]' rack.toml && \
   grep -qF 'version = "0.2.0"' rack.toml && \
   grep -qF 'git = "github.com/alice/mathx"' rack.toml; then
    PASS=$((PASS + 1)); echo "PASS github-manifest-git"
else
    FAIL=$((FAIL + 1)); echo "FAIL github-manifest-git"; cat rack.toml
fi
if grep -qF '[lock.mathx]' rack.lock && \
   grep -qF 'source = "github.com/alice/mathx"' rack.lock && \
   grep -qF 'checksum = "' rack.lock; then
    PASS=$((PASS + 1)); echo "PASS github-lock-source"
else
    FAIL=$((FAIL + 1)); echo "FAIL github-lock-source"; cat rack.lock
fi
if [ -f "$HOME/.rack/cache/github.com/alice/mathx/0.2.0/mathx.rg" ]; then
    PASS=$((PASS + 1)); echo "PASS github-cache-layout"
else
    FAIL=$((FAIL + 1)); echo "FAIL github-cache-layout"
fi
OUT="$($RACK run)"
check github-run "remote sum = 5" "$OUT"
OUT="$($RACK install github.com/alice/mathx)"
check github-satisfied "already satisfied: mathx@0.2.0 (github.com/alice/mathx)" "$OUT"

# ---------- offline cache: with a lock + complete cache, no network ----------
rm -rf target/deps
OUT="$(RACK_GITHUB_API=http://127.0.0.1:1 RACK_GITHUB_RAW=http://127.0.0.1:1/raw $RACK install)"
check github-cache-offline "Installed 1 package(s)" "$OUT"
if [ -f target/deps/mathx.rg ]; then
    PASS=$((PASS + 1)); echo "PASS github-cache-offline-files"
else
    FAIL=$((FAIL + 1)); echo "FAIL github-cache-offline-files"
fi

# ---------- corrupt cache: detected by lock checksum and re-fetched ----------
printf '\n# tampered cache\n' >> "$HOME/.rack/cache/github.com/alice/mathx/0.2.0/mathx.rg"
rm -rf target/deps
OUT="$($RACK install)"
check github-cache-repair "Installed 1 package(s)" "$OUT"
if ! grep -qF '# tampered cache' target/deps/mathx.rg; then
    PASS=$((PASS + 1)); echo "PASS github-cache-repaired"
else
    FAIL=$((FAIL + 1)); echo "FAIL github-cache-repaired"
fi
OUT="$($RACK list)"
check github-list "mathx@0.2.0 (github.com/alice/mathx)" "$OUT"

# lock source inconsistent with the manifest -> build rejects
cp rack.lock rack.lock.bak
sed -i 's#source = "github.com/alice/mathx"#source = "github.com/alice/other"#' rack.lock
RC=0; OUT="$($RACK build)" || RC=$?
check github-lock-source-guard "locked from github.com/alice/other but rack.toml wants github.com/alice/mathx" "$OUT"
checkrc github-lock-source-guard-exit 1 "$RC"
mv rack.lock.bak rack.lock
cd "$WORK"

# ---------- GitHub transitive deps (calcx -> mathx) ----------
mkdir -p gh2 && cd gh2
printf '[package]\nname = "gh2"\nversion = "0.1.0"\nentry = "main.rg"\n' > rack.toml
cat > main.rg <<'EOF'
import calcx

def main() -> int {
    print("double =", calcx_double_add(2, 3))
    return 0
}
EOF
OUT="$($RACK install github.com/alice/calcx)"
check github-transitive "+ calcx@0.3.0 (github.com/alice/calcx)" "$OUT"
check github-transitive-dep "+ mathx@0.2.0 (github.com/alice/mathx)" "$OUT"
if grep -qF '[dependencies.calcx]' rack.toml && ! grep -qF 'mathx' rack.toml; then
    PASS=$((PASS + 1)); echo "PASS github-manifest-direct-only"
else
    FAIL=$((FAIL + 1)); echo "FAIL github-manifest-direct-only"; cat rack.toml
fi
if grep -A3 '[lock.calcx]' rack.lock | grep -qF 'source = "github.com/alice/calcx"' && \
   grep -A3 '[lock.mathx]' rack.lock | grep -qF 'source = "github.com/alice/mathx"'; then
    PASS=$((PASS + 1)); echo "PASS github-lock-closure-sources"
else
    FAIL=$((FAIL + 1)); echo "FAIL github-lock-closure-sources"; cat rack.lock
fi
OUT="$($RACK tree)"
check github-tree "└── calcx@0.3.0 (github.com/alice/calcx)" "$OUT"
check github-tree-dep "    └── mathx@0.2.0 (github.com/alice/mathx)" "$OUT"
OUT="$($RACK run)"
check github-transitive-run "double = 10" "$OUT"
cd "$WORK"

# ---------- URL / gh: forms and exact versions (non-v tag fallback) ----------
mkdir -p gh3 && cd gh3
printf '[package]\nname = "gh3"\nversion = "0.1.0"\nentry = "main.rg"\n' > rack.toml
OUT="$($RACK install https://github.com/alice/mathx.git@0.1.0)"
check github-url-form "+ mathx@0.1.0 (github.com/alice/mathx)" "$OUT"
if grep -qF 'git = "github.com/alice/mathx"' rack.toml; then
    PASS=$((PASS + 1)); echo "PASS github-url-normalized"
else
    FAIL=$((FAIL + 1)); echo "FAIL github-url-normalized"; cat rack.toml
fi
cd "$WORK"
mkdir -p gh4 && cd gh4
printf '[package]\nname = "gh4"\nversion = "0.1.0"\nentry = "main.rg"\n' > rack.toml
OUT="$($RACK install gh:alice/mathx@0.1.0)"
check github-gh-form "+ mathx@0.1.0 (github.com/alice/mathx)" "$OUT"
cd "$WORK"
mkdir -p gh5 && cd gh5
printf '[package]\nname = "gh5"\nversion = "0.1.0"\nentry = "main.rg"\n' > rack.toml
OUT="$($RACK install github.com/alice/calcx@0.3.0)"
check github-plain-tag "+ calcx@0.3.0 (github.com/alice/calcx)" "$OUT"
cd "$WORK"

# ---------- manifest git subtables (version optional; install fills in the latest tag) ----------
mkdir -p gh6 && cd gh6
cat > rack.toml <<'EOF'
[package]
name = "gh6"
version = "0.1.0"
entry = "main.rg"

[dependencies.mathx]
git = "github.com/alice/mathx"
EOF
OUT="$($RACK install)"
check github-manifest-git-only "resolved mathx -> mathx@0.2.0" "$OUT"
if grep -A3 '[dependencies.mathx]' rack.toml | grep -qF 'version = "0.2.0"'; then
    PASS=$((PASS + 1)); echo "PASS github-manifest-git-version-filled"
else
    FAIL=$((FAIL + 1)); echo "FAIL github-manifest-git-version-filled"; cat rack.toml
fi
cd "$WORK"

# ---------- same name from different sources => source conflict ----------
mkdir -p gh7 && cd gh7
printf '[package]\nname = "gh7"\nversion = "0.1.0"\nentry = "main.rg"\n' > rack.toml
$RACK install mathx@0.2.0 >/dev/null
RC=0; OUT="$($RACK install github.com/alice/mathx@0.2.0)" || RC=$?
check github-source-conflict "source conflict on \`mathx\`" "$OUT"
checkrc github-source-conflict-exit 1 "$RC"
cd "$WORK"

# ---------- tag drift: lock checksum rejects -> update accepts new content ----------
mkdir -p gh8 && cd gh8
printf '[package]\nname = "gh8"\nversion = "0.1.0"\nentry = "main.rg"\n' > rack.toml
OUT="$($RACK install github.com/alice/drift@1.0.0)"
check github-drift-install "+ drift@1.0.0 (github.com/alice/drift)" "$OUT"
OLD_SUM="$(sed -n '/\[lock.drift\]/,/^$/p' rack.lock | sed -n 's/^checksum = "\(.*\)"$/\1/p')"
printf '\n# moved tag\n' >> "$GH_FIX/repos/alice/drift/v1.0.0/drift.rg"
rm -rf "$HOME/.rack/cache/github.com/alice/drift/1.0.0"
RC=0; OUT="$($RACK install)" || RC=$?
check github-drift "checksum mismatch for \`drift@1.0.0\`" "$OUT"
check github-drift-hint "tag may have moved" "$OUT"
checkrc github-drift-exit 1 "$RC"
OUT="$($RACK update)"
check github-drift-update "updating drift (github.com/alice/drift) -> 1.0.0" "$OUT"
NEW_SUM="$(sed -n '/\[lock.drift\]/,/^$/p' rack.lock | sed -n 's/^checksum = "\(.*\)"$/\1/p')"
if [ -n "$NEW_SUM" ] && [ "$OLD_SUM" != "$NEW_SUM" ]; then
    PASS=$((PASS + 1)); echo "PASS github-drift-lock-updated"
else
    FAIL=$((FAIL + 1)); echo "FAIL github-drift-lock-updated (old=$OLD_SUM new=$NEW_SUM)"
fi
OUT="$($RACK install)"
check github-drift-accepted "already satisfied: 1 direct dependency(ies)" "$OUT"
cd "$WORK"

# ---------- name mismatch / missing repo / missing tag / unsupported source ----------
mkdir -p gh9 && cd gh9
printf '[package]\nname = "gh9"\nversion = "0.1.0"\nentry = "main.rg"\n' > rack.toml
RC=0; OUT="$($RACK install github.com/alice/evil)" || RC=$?
check github-name-mismatch "package name mismatch" "$OUT"
checkrc github-name-mismatch-exit 1 "$RC"
RC=0; OUT="$($RACK install github.com/alice/nosuch)" || RC=$?
check github-missing-repo "repository not found" "$OUT"
checkrc github-missing-repo-exit 1 "$RC"
RC=0; OUT="$($RACK install github.com/alice/mathx@9.9.9)" || RC=$?
check github-missing-tag "not found in github.com/alice/mathx" "$OUT"
checkrc github-missing-tag-exit 1 "$RC"
RC=0; OUT="$($RACK install gitlab.com/a/b)" || RC=$?
check github-unsupported-source "unsupported source" "$OUT"
checkrc github-unsupported-source-exit 1 "$RC"
cd "$WORK"

# ---------- tag pagination (101 tags -> second page) ----------
mkdir -p gh10 && cd gh10
printf '[package]\nname = "gh10"\nversion = "0.1.0"\nentry = "main.rg"\n' > rack.toml
OUT="$($RACK install github.com/alice/many)"
check github-pagination "+ many@0.1.0 (github.com/alice/many)" "$OUT"
if grep -qF '/repos/alice/many/tags?per_page=100&page=2' "$GH_LOG"; then
    PASS=$((PASS + 1)); echo "PASS github-pagination-page2"
else
    FAIL=$((FAIL + 1)); echo "FAIL github-pagination-page2"
fi
cd "$WORK"

# ---------- remote search + token (sent only to API, not raw) ----------
OUT="$($RACK search --remote math)"
check github-search "github.com/alice/mathx  remote math helpers  (stars: 42)" "$OUT"
check github-search-hint "hint: rack install github.com/<owner>/<repo>" "$OUT"
OUT="$($RACK search --remote zz-no-match)"
check github-search-miss "no packages matched" "$OUT"
OUT="$(RACK_GITHUB_TOKEN=secret-token $RACK search --remote math)"
if grep -qF 'auth=Bearer secret-token' "$GH_LOG"; then
    PASS=$((PASS + 1)); echo "PASS github-token-api"
else
    FAIL=$((FAIL + 1)); echo "FAIL github-token-api"
fi
if grep '/raw/' "$GH_LOG" | grep -qF 'Bearer'; then
    FAIL=$((FAIL + 1)); echo "FAIL github-token-not-on-raw"
else
    PASS=$((PASS + 1)); echo "PASS github-token-not-on-raw"
fi
OUT="$($RACK registry)"
check registry-cache "cache:" "$OUT"

# ---------- update: upgrade when a new tag appears and update the lock ----------
mkdir -p gh11 && cd gh11
printf '[package]\nname = "gh11"\nversion = "0.1.0"\nentry = "main.rg"\n' > rack.toml
OUT="$($RACK install github.com/alice/evolve@0.1.0)"
check github-evolve-initial "+ evolve@0.1.0 (github.com/alice/evolve)" "$OUT"
cp -R "$GH_FIX/repos/alice/evolve/v0.1.0" "$GH_FIX/repos/alice/evolve/v0.2.0"
sed -i 's/version = "0.1.0"/version = "0.2.0"/' "$GH_FIX/repos/alice/evolve/v0.2.0/rack.toml"
OUT="$($RACK update)"
check github-update "updating evolve (github.com/alice/evolve) -> 0.2.0" "$OUT"
if grep -A3 '[dependencies.evolve]' rack.toml | grep -qF 'version = "0.2.0"' && \
   sed -n '/\[lock.evolve\]/,/^$/p' rack.lock | grep -qF 'version = "0.2.0"'; then
    PASS=$((PASS + 1)); echo "PASS github-update-lock"
else
    FAIL=$((FAIL + 1)); echo "FAIL github-update-lock"; cat rack.toml; cat rack.lock
fi
cd "$WORK"

# ==================== rack self: toolchain install from the download center ====================
echo
echo "== rack self"
case "$(uname -s)" in
    Linux)  SELF_OS=linux ;;
    Darwin) SELF_OS=macos ;;
    *) echo "error: unsupported test OS for rack self" >&2; exit 1 ;;
esac
case "$(uname -m)" in
    x86_64|amd64) SELF_ARCH=x64 ;;
    arm64|aarch64) SELF_ARCH=arm64 ;;
    *) echo "error: unsupported test architecture for rack self" >&2; exit 1 ;;
esac
SELF_PLATFORM="$SELF_OS-$SELF_ARCH"

SELF_WWW="$WORK/self-www"
SELF_FIX="$SELF_WWW/dist"
mkdir -p "$SELF_FIX/channels" "$SELF_FIX/files" \
         "$SELF_FIX/versions/0.1.0" "$SELF_FIX/versions/0.2.0" "$SELF_FIX/versions/0.3.0" \
         "$SELF_WWW/stage/rgc/bin" "$SELF_WWW/stage/rgc/lib" "$SELF_WWW/stage/rack/bin"
printf '#!/bin/sh\nexit 0\n' > "$SELF_WWW/stage/rgc/bin/rgc"
printf '# fake stdlib\n' > "$SELF_WWW/stage/rgc/lib/core.rg"
printf '#!/bin/sh\nexit 0\n' > "$SELF_WWW/stage/rack/bin/rack"
tar czf "$SELF_FIX/files/rgc-$SELF_PLATFORM.tar.gz" -C "$SELF_WWW/stage/rgc" bin lib
tar czf "$SELF_FIX/files/rack-$SELF_PLATFORM.tar.gz" -C "$SELF_WWW/stage/rack" bin
for v in 0.1.0 0.2.0 0.3.0; do
    cp "$SELF_FIX/files/rgc-$SELF_PLATFORM.tar.gz" "$SELF_FIX/files/rgc-$v.tar.gz"
    cp "$SELF_FIX/files/rack-$SELF_PLATFORM.tar.gz" "$SELF_FIX/files/rack-$v.tar.gz"
done

SELF_PORT_FILE="$WORK/self.port"
python3 "$REPO/tests/mock_dist.py" --dir "$SELF_WWW" --port-file "$SELF_PORT_FILE" \
    >"$WORK/self-server.log" 2>&1 &
SELF_PID=$!
for _ in $(seq 1 100); do
    [ -s "$SELF_PORT_FILE" ] && break
    sleep 0.05
done
if [ ! -s "$SELF_PORT_FILE" ]; then
    echo "error: mock download-center server did not start"
    exit 1
fi
SELF_PORT="$(cat "$SELF_PORT_FILE")"

python3 - "$SELF_FIX" "$SELF_PORT" "$SELF_PLATFORM" <<'PY'
import hashlib
import json
import pathlib
import sys

fix = pathlib.Path(sys.argv[1])
port = sys.argv[2]
platform = sys.argv[3]
base = f"http://127.0.0.1:{port}"

def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

for version in ("0.1.0", "0.2.0", "0.3.0"):
    assets = {platform: {}}
    for component in ("rgc", "rack"):
        path = fix / "files" / f"{component}-{version}.tar.gz"
        digest = sha256(path)
        if version == "0.3.0" and component == "rgc":
            digest = "0" * 64
        assets[platform][component] = {
            "file": path.name,
            "url": f"{base}/dist/files/{path.name}",
            "sha256": digest,
            "size": path.stat().st_size,
        }
    manifest = {
        "version": version,
        "date": "2026-10-25",
        "toolchain": {"rgc": version, "rack": version},
        "assets": assets,
    }
    (fix / "versions" / version / "manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )

channel = {
    "channel": "stable",
    "version": "0.2.0",
    "date": "2026-10-25",
    "manifest_url": f"{base}/dist/versions/0.2.0/manifest.json",
}
(fix / "channels" / "stable.json").write_text(
    json.dumps(channel, indent=2) + "\n", encoding="utf-8"
)
PY

SELF_ROOT="$WORK/rgc home"
export RGC_HOME="$SELF_ROOT"
export RACK_DIST_URL="http://127.0.0.1:$SELF_PORT/dist/"

OUT="$($RACK self status)"
check self-status-platform "platform: $SELF_PLATFORM" "$OUT"
check self-status-empty "installed: (none)" "$OUT"

OUT="$($RACK self install)"
check self-install "installed rgc 0.2.0" "$OUT"
check self-install-default "default toolchain: 0.2.0" "$OUT"
if [ -f "$SELF_ROOT/settings.toml" ] && \
   grep -qF 'default = "0.2.0"' "$SELF_ROOT/settings.toml" && \
   grep -qF 'channel = "stable"' "$SELF_ROOT/settings.toml"; then
    PASS=$((PASS + 1)); echo "PASS self-settings"
else
    FAIL=$((FAIL + 1)); echo "FAIL self-settings"; cat "$SELF_ROOT/settings.toml" 2>/dev/null
fi
if [ -x "$SELF_ROOT/bin/rgc" ] && [ -x "$SELF_ROOT/bin/rack" ] && \
   [ -f "$SELF_ROOT/toolchains/0.2.0/lib/core.rg" ]; then
    PASS=$((PASS + 1)); echo "PASS self-layout"
else
    FAIL=$((FAIL + 1)); echo "FAIL self-layout"; find "$SELF_ROOT" -maxdepth 3 2>/dev/null
fi
if [ -e "$SELF_ROOT/bin/lib/core.rg" ]; then
    PASS=$((PASS + 1)); echo "PASS self-stdlib-link"
else
    FAIL=$((FAIL + 1)); echo "FAIL self-stdlib-link"; ls -la "$SELF_ROOT/bin" 2>/dev/null
fi

OUT="$($RACK self list)"
check self-list-default "0.2.0 (default)" "$OUT"

OUT="$($RACK self install 0.1.0)"
check self-install-version "default toolchain: 0.1.0" "$OUT"
if [ "$(readlink "$SELF_ROOT/bin/lib")" = "$SELF_ROOT/toolchains/0.1.0/lib" ]; then
    PASS=$((PASS + 1)); echo "PASS self-stdlib-link-switched"
else
    FAIL=$((FAIL + 1)); echo "FAIL self-stdlib-link-switched"; ls -la "$SELF_ROOT/bin" 2>/dev/null
fi
OUT="$($RACK self default 0.2.0)"
check self-default "default toolchain: 0.2.0" "$OUT"
if [ "$(readlink "$SELF_ROOT/bin/lib")" = "$SELF_ROOT/toolchains/0.2.0/lib" ]; then
    PASS=$((PASS + 1)); echo "PASS self-stdlib-link-restored"
else
    FAIL=$((FAIL + 1)); echo "FAIL self-stdlib-link-restored"; ls -la "$SELF_ROOT/bin" 2>/dev/null
fi
OUT="$($RACK self remove 0.1.0)"
check self-remove "removed rgc 0.1.0" "$OUT"

RC=0; OUT="$($RACK self remove 0.2.0)" || RC=$?
check self-remove-default-refused "refusing to remove the default toolchain" "$OUT"
checkrc self-remove-default-refused-exit 1 "$RC"
OUT="$($RACK self update)"
check self-update-current "rgc 0.2.0 is up to date" "$OUT"

RC=0; OUT="$($RACK self install 0.3.0)" || RC=$?
check self-checksum "checksum mismatch" "$OUT"
checkrc self-checksum-exit 1 "$RC"
if [ -e "$SELF_ROOT/toolchains/0.3.0" ]; then
    FAIL=$((FAIL + 1)); echo "FAIL self-checksum-no-partial"
else
    PASS=$((PASS + 1)); echo "PASS self-checksum-no-partial"
fi

OUT="$($RACK self env --shell fish)"
check self-env-fish "fish_add_path \"$SELF_ROOT/bin\"" "$OUT"
OUT="$($RACK self which rgc)"
check self-which "$SELF_ROOT/bin/rgc" "$OUT"

RC=0; OUT="$($RACK self uninstall)" || RC=$?
check self-uninstall-guard "re-run with --yes" "$OUT"
checkrc self-uninstall-guard-exit 1 "$RC"
OUT="$($RACK self uninstall --yes)"
check self-uninstall "removed $SELF_ROOT" "$OUT"
if [ -e "$SELF_ROOT" ]; then
    FAIL=$((FAIL + 1)); echo "FAIL self-uninstall-removed"
else
    PASS=$((PASS + 1)); echo "PASS self-uninstall-removed"
fi

unset RGC_HOME RACK_DIST_URL

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
