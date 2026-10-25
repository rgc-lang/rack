#!/usr/bin/env bash
# Build the platform link shim used by rack's own build.
#
# The released RGC standard library targets glibc; on Darwin its net/event
# modules reference __errno_location, which libSystem does not export. Compile
# a tiny alias object and pass it through link-args-file. Other platforms need
# no extra object, so the file stays empty.
set -euo pipefail

out=target/platform-shim
mkdir -p "$out"
: > "$out/link-args"

if [ "$(uname -s)" = "Darwin" ]; then
    cc -c -O2 -o "$out/errno_shim.o" tools/errno_shim.c
    echo "$out/errno_shim.o" > "$out/link-args"
fi
