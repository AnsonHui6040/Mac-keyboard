#!/usr/bin/env bash
# 檢查 RimeC.xcframework：slice 清單、標頭、_rime_get_api、無 lua/spdlog 符號、最低系統版本。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
XC="${RIME_XCFRAMEWORK:-$ROOT/Packages/RimeEngine/Artifacts/RimeC.xcframework}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }
[ -d "$XC" ] || { echo "FAIL: missing $XC" >&2; exit 1; }

# Info.plist 的 AvailableLibraries 必須剛好是這三個 slice
ids=""
i=0
while id="$(/usr/libexec/PlistBuddy -c "Print :AvailableLibraries:$i:LibraryIdentifier" "$XC/Info.plist" 2>/dev/null)"; do
  ids="$ids $id"; i=$((i + 1))
done
expected="ios-arm64 ios-arm64-simulator macos-arm64"
actual="$(printf '%s\n' $ids | sort | tr '\n' ' ' | sed 's/ $//')"
[ "$actual" = "$expected" ] || bad "Info.plist slices: '$actual' (expected '$expected')"

check_slice() {
  local id="$1" platform="$2" minos="$3"
  local lib="$XC/$id/libRimeC.a"
  [ -f "$lib" ] || { bad "$id 缺少 libRimeC.a"; return; }
  [ -f "$XC/$id/Headers/rime_api.h" ] || bad "$id 缺少 rime_api.h"
  [ -f "$XC/$id/Headers/module.modulemap" ] || bad "$id 缺少 module.modulemap"
  # 管線結果先寫檔，避免 grep -q 提早結束造成 SIGPIPE 被 pipefail 當成失敗
  nm -gU "$lib" > "$TMP/$id.defined" 2>/dev/null || true
  nm "$lib" > "$TMP/$id.all" 2>/dev/null || true
  grep -q '_rime_get_api' "$TMP/$id.defined" || bad "$id 缺少 _rime_get_api"
  if grep -E '_lua_|_luaL_|_lua[_A-Za-z]|spdlog' "$TMP/$id.all" > "$TMP/$id.hits"; then
    bad "$id 含 lua/spdlog 符號: $(head -3 "$TMP/$id.hits" | tr '\n' ' ')"
  fi
  # 最低系統版本：解出第一個 .o 讓 vtool 讀
  ar -t "$lib" > "$TMP/$id.members"
  local member
  member="$(awk '/\.o$/ {print; exit}' "$TMP/$id.members")"
  mkdir -p "$TMP/$id.x"
  (cd "$TMP/$id.x" && ar -x "$lib" "$member")
  vtool -show-build "$TMP/$id.x/$member" > "$TMP/$id.build" 2>/dev/null || true
  local got_platform got_minos
  got_platform="$(awk '$1=="platform" {print $2; exit}' "$TMP/$id.build")"
  got_minos="$(awk '$1=="minos" {print $2; exit}' "$TMP/$id.build")"
  if [ "$got_platform" != "$platform" ] || [ "$got_minos" != "$minos" ]; then
    bad "$id platform/minos = $got_platform/$got_minos (expected $platform/$minos)"
  fi
  echo "checked $id platform=$got_platform minos=$got_minos"
}

check_slice ios-arm64           IOS          18.0
check_slice ios-arm64-simulator IOSSIMULATOR 18.0
check_slice macos-arm64         MACOS        15.0

if [ "$fail" -eq 0 ]; then echo "verify: OK"; else exit 1; fi
