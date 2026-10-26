#!/usr/bin/env bash
# rack/tests/bootstrap.sh — rack bootstrap: manage rack with rack itself
#
# stage 0: the compiler compiles rack0 (one-time starting point; compiled to a temp directory, never into the project tree);
# stage 1: rack0 build -> rack1
# stage 2: rack1 builds rack2 from a clean tree
# stage 3: cmp rack1 rack2 — byte-level fixed point (like the compiler bootstrap's IR fixed-point check)
#
# The compiler is the released RGC toolchain: `rgc` on PATH, or RGC=<path>.
#
# Usage: ./bootstrap.sh

set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"

# MSYS/Git Bash and GitHub's Windows runners report themselves through uname;
# the OS variable also covers cmd/PowerShell invocations.
EXE=""
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) EXE=".exe" ;;
esac
if [ "${OS:-}" = "Windows_NT" ]; then
    EXE=".exe"
fi

RGC_BIN="${RGC:-}"
if [ -z "$RGC_BIN" ]; then
    if [ -x "$REPO/build/rgc$EXE" ]; then
        RGC_BIN="$REPO/build/rgc$EXE"
    else
        RGC_BIN="$(command -v "rgc$EXE" || command -v rgc || true)"
    fi
fi

# RGC may arrive in either spelling: bash needs a POSIX path for its own checks
# and direct execution, while rack builds through cmd.exe and needs a Windows
# path. cygpath translates between the two; without it, pass the value through.
RGC_RUN="$RGC_BIN"
RGC_FOR_BUILD="$RGC_BIN"
if [ -n "$EXE" ] && command -v cygpath >/dev/null 2>&1; then
    RGC_RUN="$(cygpath -u "$RGC_BIN")"
    RGC_FOR_BUILD="$(cygpath -w "$RGC_BIN")"
fi
if [ -z "$RGC_RUN" ] || [ ! -x "$RGC_RUN" ]; then
    echo "error: no RGC compiler found"
    echo "hint: install an RGC release and put rgc on PATH, or set RGC=<path>"
    exit 1
fi

WORK="$(mktemp -d)"
export HOME="$WORK/home"
mkdir -p "$HOME"
trap 'rm -rf "$WORK"' EXIT

cd "$REPO"
bash tools/platform-shim.sh

echo "== stage 0: $RGC_RUN compiles rack0 (temp directory)"
if [ -s target/platform-shim/link-args ]; then
    "$RGC_RUN" "$REPO/src/main.rg" -o "$WORK/rack0$EXE" \
        --link-args "$(cat target/platform-shim/link-args)" >/dev/null
else
    "$RGC_RUN" "$REPO/src/main.rg" -o "$WORK/rack0$EXE" >/dev/null
fi

# stages 1/2 verify the determinism of rack's build pipeline: two generations of rack
# build the same source with the same host compiler; the artifacts must be byte-identical.
echo "== stage 1: rack0 build (rack manages itself)"
RGC="$RGC_FOR_BUILD" "$WORK/rack0$EXE" build
cp "target/bin/rack$EXE" "$WORK/rack1$EXE"

echo "== stage 2: rack1 build (clean tree)"
rm -f "target/bin/rack$EXE"
rm -rf target/build
RGC="$RGC_FOR_BUILD" "$WORK/rack1$EXE" build
cp "target/bin/rack$EXE" "$WORK/rack2$EXE"

echo "== stage 3: fixed-point check"
if cmp -s "$WORK/rack1$EXE" "$WORK/rack2$EXE"; then
    echo "bootstrap OK: rack1 == rack2 (byte-identical fixed point)"
else
    echo "bootstrap FAILED: rack1 != rack2"
    exit 1
fi
"$WORK/rack2$EXE" --version
echo "binary: $REPO/target/bin/rack$EXE (same as a normal rack project; not committed)"
