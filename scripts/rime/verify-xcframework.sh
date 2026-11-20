#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
XC="$ROOT/Packages/RimeEngine/Artifacts/RimeC.xcframework"
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }
[ -d "$XC" ] || { echo "FAIL: missing $XC" >&2; exit 1; }
for id in ios-arm64 ios-arm64-simulator macos-arm64; do
  grep -q "<string>$id</string>" "$XC/Info.plist" || bad "Info.plist 缺少 slice $id"
  lib="$XC/$id/libRimeC.a"
  [ -f "$lib" ] || { bad "$id 缺少 libRimeC.a"; continue; }
  [ -f "$XC/$id/Headers/rime_api.h" ] || bad "$id 缺少 rime_api.h"
  [ -f "$XC/$id/Headers/module.modulemap" ] || bad "$id 缺少 module.modulemap"
  nm -gU "$lib" 2>/dev/null | grep -q "_rime_get_api" || bad "$id 缺少 _rime_get_api"
  if nm "$lib" 2>/dev/null | grep -E 'lua[_A-Z]|Lua[_A-Za-z]|spdlog' >/dev/null; then bad "$id 含 lua/spdlog 符號"; fi
  echo "checked $id"
done
[ "$fail" -eq 0 ] && echo "verify: OK" || exit 1
