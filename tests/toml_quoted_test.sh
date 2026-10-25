#!/usr/bin/env bash
# toml_quoted_test.sh — compile and run the TOML quoted-key parser test.
# Usage: ./toml_quoted_test.sh   (or RGC=<path> ./toml_quoted_test.sh)
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
    echo "error: no RGC compiler found" >&2
    echo "hint: install an RGC release and put rgc on PATH, or set RGC=<path>" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Stage the real parser modules next to the test entry so imports resolve.
cp "$REPO/src/toml.rg" "$REPO/src/util.rg" "$WORK/"
cp "$REPO/tests/toml_quoted_test.rg" "$WORK/main.rg"

"$RGC_BIN" "$WORK/main.rg" -o "$WORK/toml_quoted_test"
"$WORK/toml_quoted_test"
