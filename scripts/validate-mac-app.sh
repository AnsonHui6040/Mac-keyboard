#!/usr/bin/env bash
# 檢查 Mac Receiver 發佈 zip 的結構。只看 zip 內容，不代表能通過 Gatekeeper，也不是啟動測試。
set -euo pipefail

usage() {
  cat <<USAGE
用法：scripts/validate-mac-app.sh <zip> [--expect-bundle-id ID] [--expect-version V] [--expect-build B]
                                  [--expect-min-macos X] [--report FILE] [-h]

每項檢查輸出一行 PASS、FAIL 或 BLOCKED。有任何 FAIL 時結束碼為 1；沒有 FAIL 但有 BLOCKED 時為 2。
USAGE
}

ZIP=""
EXP_ID="com.ansonhui.remotekeyboard.receiver"; EXP_VER=""; EXP_BUILD=""; EXP_MIN="15.0"; REPORT=""
# 只在 #if DEBUG 內定義或使用的識別字；Release 的執行檔不得含有。用 strings 只認得 ASCII，所以不選中文介面文字。
# 這些字在 Debug 的 MacReceiver.debug.dylib 都找得到，Release 找不到，所以檢查有鑑別力。
DEBUG_ONLY=("rkMeasureMode" "BurstVerifier" "MeasurementEcho" "MeasureCursorMover" "MeasureFlashWindow" "MeasureCSVFile")

while [ $# -gt 0 ]; do
  case "$1" in
    --expect-bundle-id|--expect-version|--expect-build|--expect-min-macos|--report)
      [ $# -ge 2 ] || { echo "$1 需要參數" >&2; exit 64; }
      case "$1" in
        --expect-bundle-id) EXP_ID="$2" ;;
        --expect-version) EXP_VER="$2" ;;
        --expect-build) EXP_BUILD="$2" ;;
        --expect-min-macos) EXP_MIN="$2" ;;
        --report) REPORT="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "不認得的參數：$1" >&2; usage >&2; exit 64 ;;
    *) [ -z "$ZIP" ] || { echo "只能指定一個 zip" >&2; exit 64; }; ZIP="$1"; shift ;;
  esac
done
[ -n "$ZIP" ] || { usage >&2; exit 64; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/validate-mac.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

LINES=(); NOTES=()
FAILS=0; BLOCKS=0
record() {
  local line="$1 [$2] $3"
  LINES+=("$line"); echo "$line"
  case "$1" in FAIL) FAILS=$((FAILS+1)) ;; BLOCKED) BLOCKS=$((BLOCKS+1)) ;; esac
}
plist_get() { plutil -extract "$2" raw -o - "$1" 2>/dev/null || true; }

finish() {
  local code=0
  [ "$BLOCKS" -gt 0 ] && code=2
  [ "$FAILS" -gt 0 ] && code=1
  if [ -n "$REPORT" ]; then
    {
      echo "# Mac Receiver zip 結構檢查"
      echo
      echo "- 檔案：$(basename "$ZIP")"
      echo "- 結果：FAIL ${FAILS}、BLOCKED ${BLOCKS}"
      echo
      echo '```'
      printf '%s\n' "${LINES[@]}"
      echo '```'
      if [ "${#NOTES[@]}" -gt 0 ]; then
        echo
        echo "## 備註"
        printf -- '- %s\n' "${NOTES[@]}"
      fi
      echo
      echo "密鑰檢查只掃描已知樣式，不能證明沒有任何機密。"
      echo
      echo "結構檢查不等於 Gatekeeper 放行，也不是啟動測試。"
    } >"$REPORT"
  fi
  exit "$code"
}
block_rest() { local n; for n in "$@"; do record BLOCKED "$n" "$BLOCK_WHY"; done; }

# 1 zip 存在且能解壓
BLOCK_WHY="沒有 zip"
if [ ! -f "$ZIP" ]; then
  record FAIL 1 "zip 不存在"; block_rest 2 3 4 5 6 7 8 9 10 11 12 13 14; finish
fi
X="$WORK/x"; mkdir -p "$X"
if ! ditto -x -k "$ZIP" "$X" 2>/dev/null; then
  record FAIL 1 "zip 無法解壓"; BLOCK_WHY="無法解壓"; block_rest 2 3 4 5 6 7 8 9 10 11 12 13 14; finish
fi
record PASS 1 "zip 存在且可解壓"

# 2 根目錄只有一個 .app，沒有 __MACOSX
ROOT_ITEMS="$(ls -A "$X")"
APPS=()
while IFS= read -r a; do [ -n "$a" ] && APPS+=("$a"); done < <(find "$X" -mindepth 1 -maxdepth 1 -name '*.app')
if [ "${#APPS[@]}" -eq 1 ] && [ "$(echo "$ROOT_ITEMS" | wc -l | tr -d ' ')" -eq 1 ]; then
  record PASS 2 "根目錄只有 $(basename "${APPS[0]}")"
else
  record FAIL 2 "根目錄項目：$(echo "$ROOT_ITEMS" | tr '\n' ' ')；.app 數量 ${#APPS[@]}"
fi
if [ "${#APPS[@]}" -ne 1 ]; then
  BLOCK_WHY="找不到唯一的 .app"; block_rest 3 4 5 6 7 8 9 10 11 12 13
  APP=""
else
  APP="${APPS[0]}"
fi

macho_ok() { file -b "$1" | grep -q 'Mach-O'; }
platform_of() { vtool -show-build "$1" 2>/dev/null | awk '$1=="platform"{print $2; exit}'; }

if [ -n "$APP" ]; then
  INFO="$APP/Contents/Info.plist"
  EXEC_NAME="$(plist_get "$INFO" CFBundleExecutable)"
  EXEC="$APP/Contents/MacOS/$EXEC_NAME"

  # 3 主執行檔
  if [ -n "$EXEC_NAME" ] && [ -f "$EXEC" ] && macho_ok "$EXEC"; then
    P="$(platform_of "$EXEC")"
    if [ "$P" = "MACOS" ]; then record PASS 3 "主執行檔 $EXEC_NAME 是 Mach-O，平台 MACOS"
    else record FAIL 3 "主執行檔平台是「${P:-未知}」，需要 MACOS"; fi
  else
    record FAIL 3 "主執行檔不存在或不是 Mach-O"
  fi

  # 4 架構
  ARCHS="$(lipo -archs "$EXEC" 2>/dev/null || true)"
  if echo " $ARCHS " | grep -q ' arm64 '; then
    if echo " $ARCHS " | grep -q ' x86_64 '; then record PASS 4 "架構：$ARCHS（含 arm64，含 x86_64）"
    else record PASS 4 "架構：$ARCHS（含 arm64，不含 x86_64）"; fi
  else
    record FAIL 4 "架構：${ARCHS:-無法讀取}，缺少 arm64"
  fi

  # 5 bundle ID
  ID="$(plist_get "$INFO" CFBundleIdentifier)"
  if [ "$ID" = "$EXP_ID" ]; then record PASS 5 "bundle ID：$ID"; else record FAIL 5 "bundle ID 是「$ID」，預期「$EXP_ID」"; fi

  # 6 版本與 build
  V="$(plist_get "$INFO" CFBundleShortVersionString)"; B="$(plist_get "$INFO" CFBundleVersion)"
  if [ -z "$V" ] || [ -z "$B" ]; then record FAIL 6 "缺少版本或 build"
  elif [ -n "$EXP_VER" ] && [ "$V" != "$EXP_VER" ]; then record FAIL 6 "版本 $V，預期 $EXP_VER"
  elif [ -n "$EXP_BUILD" ] && [ "$B" != "$EXP_BUILD" ]; then record FAIL 6 "build $B，預期 $EXP_BUILD"
  else record PASS 6 "版本 $V，build $B"; fi

  # 7 LSMinimumSystemVersion
  M="$(plist_get "$INFO" LSMinimumSystemVersion)"
  if [ "$M" = "$EXP_MIN" ]; then record PASS 7 "LSMinimumSystemVersion $M"
  else record FAIL 7 "LSMinimumSystemVersion 是「${M:-空}」，預期 $EXP_MIN"; fi

  # 8 LSUIElement
  UI="$(plist_get "$INFO" LSUIElement)"
  if [ "$UI" = "true" ]; then record PASS 8 "LSUIElement true"; else record FAIL 8 "LSUIElement 是「${UI:-空}」"; fi

  # 9 藍牙用途說明
  BT="$(plist_get "$INFO" NSBluetoothAlwaysUsageDescription)"
  if [ -n "$BT" ]; then record PASS 9 "NSBluetoothAlwaysUsageDescription 存在（${#BT} 字）"
  else record FAIL 9 "缺少 NSBluetoothAlwaysUsageDescription"; fi

  # 10 簽章：深度驗證通過、ad-hoc、沒有 TeamIdentifier
  if codesign --verify --deep --strict "$APP" 2>"$WORK/verify.err"; then
    DESC="$(codesign -dv "$APP" 2>&1 || true)"
    SIG="$(echo "$DESC" | sed -n 's/^Signature=//p')"
    TEAM="$(echo "$DESC" | sed -n 's/^TeamIdentifier=//p')"
    if [ "$SIG" = "adhoc" ] && [ "$TEAM" = "not set" ]; then
      record PASS 10 "codesign --verify --deep --strict 通過；Signature=adhoc；TeamIdentifier=not set"
    else
      record FAIL 10 "簽章不是 ad-hoc 或帶有 TeamIdentifier（Signature=${SIG:-?}，TeamIdentifier=${TEAM:-?}）"
    fi
  else
    record FAIL 10 "codesign --verify --deep --strict 失敗：$(head -n 1 "$WORK/verify.err" | sed "s#$WORK#<tmp>#g")"
  fi

  # 11 禁止內容
  FORBID="$(find "$X" \( -name '*.swift' -o -name '*.m' -o -name '.git' -o -name '.env' -o -name '.env.*' \
      -o -name '*.p12' -o -name '*.pem' -o -name '*.key' -o -name '*.mobileprovision' -o -name '*.xcodeproj' \
      -o -name '*.xcworkspace' -o -name '*.dSYM' -o -name 'Podfile*' -o -name 'GoogleService-Info.plist' \
      -o -name '__MACOSX' -o -name '.DS_Store' \
      -o \( -name '*.h' -not -path '*/Headers/*' \) \) 2>/dev/null | sed "s#^$X/##")"
  # ditto 解壓會把 ._ 併回 xattr，要直接看壓縮檔的項目清單。
  APPLEDOUBLE="$(unzip -Z1 "$ZIP" 2>/dev/null | grep -E '(^|/)\._' || true)"
  [ -z "$APPLEDOUBLE" ] || FORBID="$FORBID AppleDouble×$(printf '%s\n' "$APPLEDOUBLE" | wc -l | tr -d ' ')"
  PK="$(find "$X" -type f \( -name '*.plist' -o -name '*.json' -o -name '*.txt' \) -exec grep -l -a 'PRIVATE KEY' {} + 2>/dev/null | sed "s#^$X/##" || true)"
  if [ -n "$FORBID" ] || [ -n "$PK" ]; then record FAIL 11 "禁止內容：$(echo "$FORBID $PK" | tr '\n' ' ')"
  else record PASS 11 "沒有禁止的檔案與 PRIVATE KEY（只掃描已知樣式）"; fi

  # 12 /Users/ 字串（只記錄）
  USERS=0
  while IFS= read -r f; do
    [ -n "$f" ] && macho_ok "$f" || continue
    n="$({ grep -a -o '/Users/' "$f" 2>/dev/null || true; } | wc -l | tr -d ' ')"
    USERS=$((USERS + n))
  done < <(find "$APP" -type f \( -perm -u+x -o -name '*.dylib' \) 2>/dev/null)
  NOTES+=("執行檔內含字串 /Users/ 共 ${USERS} 處，只記錄不列為失敗。")
  record PASS 12 "執行檔內 /Users/ 出現 ${USERS} 處（只記錄）"

  # 13 DEBUG 專用內容不得出現
  FOUND=""
  for id in "${DEBUG_ONLY[@]}"; do
    if strings -a "$EXEC" | grep -qF -- "$id"; then FOUND="$FOUND $id"; fi
  done
  if [ -z "$FOUND" ]; then record PASS 13 "執行檔 strings 找不到 DEBUG 專用字串：${DEBUG_ONLY[*]}"
  else record FAIL 13 "Release 執行檔含有 DEBUG 專用字串：$FOUND"; fi
fi

# 14 SHA-256
SHAFILE="$ZIP.sha256"
if [ -f "$SHAFILE" ]; then
  if (cd "$(dirname "$ZIP")" && shasum -a 256 -c "$(basename "$SHAFILE")" >/dev/null 2>&1); then
    record PASS 14 "SHA-256 檔存在且與 zip 相符：$(awk '{print $1}' "$SHAFILE")"
  else record FAIL 14 "SHA-256 與 zip 不符"; fi
else
  record BLOCKED 14 "沒有 $(basename "$SHAFILE")"
fi

finish
