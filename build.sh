#!/usr/bin/env bash
# build.sh — compile the Live Photo tools into bin/.
# Sources live in tools/; the compiled binaries are what the pipeline calls.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/bin"

# SwiftPM/clang write their module caches outside the workspace by default,
# which some sandboxes block. Keep them local.
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/modulecache"
export SWIFT_MODULECACHE_PATH="$ROOT/.build/swiftmodule"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULECACHE_PATH"

for t in mkstill mkmov pairtest validate; do
    echo "==> swiftc $t"
    swiftc -O "$ROOT/tools/$t.swift" -o "$ROOT/bin/$t"
done

chmod +x "$ROOT/tools/make_livephoto_still.py" "$ROOT/tools/motion2live.py"
echo
echo "built:"
ls -1 "$ROOT/bin"
