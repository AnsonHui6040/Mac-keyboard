#!/usr/bin/env bash
# Copies ime/rime/*.yaml into an output folder and precompiles it with rime_deployer.
# Usage: scripts/rime/build-data.sh [output dir]   (default: build/rime/data)
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="${1:-$root/build/rime/data}"
deployer="$root/build/rime/bin/rime_deployer"
[ -x "$deployer" ] || { echo "rime_deployer not found at $deployer" >&2; exit 1; }
rm -rf "$out"
mkdir -p "$out"
cp "$root"/ime/rime/*.yaml "$out"/
"$deployer" --build "$out" "$out" "$out/build"
missing=0
for scheme in quick5 cangjie5 zhuyin pinyin jyutping; do
    for ext in table.bin prism.bin; do
        [ -f "$out/build/$scheme.$ext" ] || { echo "missing $scheme.$ext" >&2; missing=1; }
    done
done
[ "$missing" -eq 0 ] || exit 1
echo "built $out/build (5 schemes)"
