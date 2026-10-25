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

WORK="$(mktemp -d)"
export HOME="$WORK/home"
mkdir -p "$HOME"
trap 'rm -rf "$WORK"' EXIT

echo "== stage 0: $RGC_BIN compiles rack0 (temp directory)"
"$RGC_BIN" "$REPO/src/main.rg" -o "$WORK/rack0" >/dev/null

cd "$REPO"
# stages 1/2 verify the determinism of rack's build pipeline: two generations of rack
# build the same source with the same host compiler; the artifacts must be byte-identical.
echo "== stage 1: rack0 build (rack manages itself)"
RGC="$RGC_BIN" "$WORK/rack0" build
cp target/bin/rack "$WORK/rack1"

echo "== stage 2: rack1 build (clean tree)"
rm -f target/bin/rack
rm -rf target/build
RGC="$RGC_BIN" "$WORK/rack1" build
cp target/bin/rack "$WORK/rack2"

echo "== stage 3: fixed-point check"
if cmp -s "$WORK/rack1" "$WORK/rack2"; then
    echo "bootstrap OK: rack1 == rack2 (byte-identical fixed point)"
else
    echo "bootstrap FAILED: rack1 != rack2"
    exit 1
fi
"$WORK/rack2" --version
echo "binary: $REPO/target/bin/rack (same as a normal rack project; not committed)"
