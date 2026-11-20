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
[ -f "$out/build/quick5.table.bin" ] || { echo "quick5.table.bin was not produced" >&2; exit 1; }
echo "built $out/build/quick5.table.bin"
