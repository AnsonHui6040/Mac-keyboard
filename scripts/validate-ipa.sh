#!/usr/bin/env bash
# 檢查 SideStore 用 IPA 的結構。只看 IPA 內容，不代表能在 SideStore 安裝。
set -euo pipefail

usage() {
  cat <<USAGE
用法：scripts/validate-ipa.sh <ipa> [--expect-bundle-id ID] [--expect-version V] [--expect-build B]
                              [--expect-min-ios X] [--report FILE] [-h]

每項檢查輸出一行 PASS、FAIL 或 BLOCKED。有任何 FAIL 時結束碼為 1；沒有 FAIL 但有 BLOCKED 時為 2。
USAGE
}

IPA=""
EXP_ID=""; EXP_VER=""; EXP_BUILD=""; EXP_MIN=""; REPORT=""
GROUP="group.com.ansonhui.remotekeyboard"

while [ $# -gt 0 ]; do
  case "$1" in
    --expect-bundle-id|--expect-version|--expect-build|--expect-min-ios|--report)
      [ $# -ge 2 ] || { echo "$1 需要參數" >&2; exit 64; }
      case "$1" in
        --expect-bundle-id) EXP_ID="$2" ;;
        --expect-version) EXP_VER="$2" ;;
        --expect-build) EXP_BUILD="$2" ;;
        --expect-min-ios) EXP_MIN="$2" ;;
        --report) REPORT="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "不認得的參數：$1" >&2; usage >&2; exit 64 ;;
    *) [ -z "$IPA" ] || { echo "只能指定一個 IPA" >&2; exit 64; }; IPA="$1"; shift ;;
  esac
done
[ -n "$IPA" ] || { usage >&2; exit 64; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/validate-ipa.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

LINES=()
FAILS=0; BLOCKS=0
NOTES=()
# record <PASS|FAIL|BLOCKED> <編號> <說明>
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
      echo "# IPA 結構檢查"
      echo
      echo "- 檔案：$(basename "$IPA")"
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
      echo "結構檢查不等於 SideStore 安裝測試。"
    } >"$REPORT"
  fi
  exit "$code"
}

# 1 IPA 存在且能解壓
if [ ! -f "$IPA" ]; then
  record FAIL 1 "IPA 不存在"
  for n in 2 3 4 5 6 7 8 9 10; do record BLOCKED "$n" "沒有 IPA"; done
  record BLOCKED 11 "沒有 IPA"
  finish
fi
X="$WORK/x"; mkdir -p "$X"
if ! ditto -x -k "$IPA" "$X" 2>"$WORK/unzip.err"; then
  record FAIL 1 "IPA 無法解壓"
  for n in 2 3 4 5 6 7 8 9 10; do record BLOCKED "$n" "無法解壓"; done
  record BLOCKED 11 "無法解壓"
  finish
fi
record PASS 1 "IPA 存在且可解壓"

# 2 根目錄只有 Payload/，且只有一個 .app
ROOT_ITEMS="$(ls -A "$X")"
APPS=()
while IFS= read -r a; do [ -n "$a" ] && APPS+=("$a"); done < <(find "$X/Payload" -mindepth 1 -maxdepth 1 -name '*.app' 2>/dev/null)
if [ "$ROOT_ITEMS" = "Payload" ] && [ "${#APPS[@]}" -eq 1 ] && [ -z "$(find "$X/Payload" -mindepth 1 -maxdepth 1 ! -name '*.app')" ]; then
  record PASS 2 "根目錄只有 Payload/，內有一個 $(basename "${APPS[0]}")"
else
  record FAIL 2 "根目錄項目：$(echo "$ROOT_ITEMS" | tr '\n' ' ')；.app 數量 ${#APPS[@]}"
fi
if [ "${#APPS[@]}" -ne 1 ]; then
  for n in 3 4 5 6 7 8 9; do record BLOCKED "$n" "找不到唯一的 .app"; done
  APP=""
else
  APP="${APPS[0]}"
fi

macho_ok() { file -b "$1" | grep -q 'Mach-O'; }
# 平台必須是 iOS 裝置（不是模擬器）
platform_of() { vtool -show-build "$1" 2>/dev/null | awk '$1=="platform"{print $2; exit}'; }
archs_of() { lipo -archs "$1" 2>/dev/null || true; }

if [ -n "$APP" ]; then
  INFO="$APP/Info.plist"
  APP_EXEC_NAME="$(plist_get "$INFO" CFBundleExecutable)"
  APP_EXEC="$APP/$APP_EXEC_NAME"
  APP_ID="$(plist_get "$INFO" CFBundleIdentifier)"

  # 3 主執行檔
  if [ -n "$APP_EXEC_NAME" ] && [ -f "$APP_EXEC" ] && macho_ok "$APP_EXEC"; then
    P="$(platform_of "$APP_EXEC")"
    if [ "$P" = "IOS" ]; then record PASS 3 "主執行檔 $APP_EXEC_NAME 是 Mach-O，平台 IOS"
    else record FAIL 3 "主執行檔平台是「${P:-未知}」，需要 IOS"; fi
  else
    record FAIL 3 "主執行檔不存在或不是 Mach-O"
  fi

  # 4 arm64
  APP_ARM=0; EXT_ARM=1
  if [ -f "$APP_EXEC" ] && echo " $(archs_of "$APP_EXEC") " | grep -q ' arm64 '; then APP_ARM=1; fi

  # 5 bundle ID
  if [ -z "$EXP_ID" ]; then record PASS 5 "bundle ID：${APP_ID:-空}（未指定預期值）"
  elif [ "$APP_ID" = "$EXP_ID" ]; then record PASS 5 "bundle ID：$APP_ID"
  else record FAIL 5 "bundle ID 是「$APP_ID」，預期「$EXP_ID」"; fi

  # 6 版本與 build
  V="$(plist_get "$INFO" CFBundleShortVersionString)"; B="$(plist_get "$INFO" CFBundleVersion)"
  if [ -z "$V" ] || [ -z "$B" ]; then record FAIL 6 "缺少 CFBundleShortVersionString 或 CFBundleVersion"
  elif [ -n "$EXP_VER" ] && [ "$V" != "$EXP_VER" ]; then record FAIL 6 "版本 $V，預期 $EXP_VER"
  elif [ -n "$EXP_BUILD" ] && [ "$B" != "$EXP_BUILD" ]; then record FAIL 6 "build $B，預期 $EXP_BUILD"
  else record PASS 6 "版本 $V，build $B"; fi

  # 7 MinimumOSVersion
  M="$(plist_get "$INFO" MinimumOSVersion)"
  if [ -z "$M" ]; then record FAIL 7 "缺少 MinimumOSVersion"
  elif [ -n "$EXP_MIN" ] && [ "$M" != "$EXP_MIN" ]; then record FAIL 7 "MinimumOSVersion $M，預期 $EXP_MIN"
  else record PASS 7 "MinimumOSVersion $M"; fi

  # 8 鍵盤擴充完整性
  APPEXES=()
  while IFS= read -r a; do [ -n "$a" ] && APPEXES+=("$a"); done < <(find "$APP/PlugIns" -mindepth 1 -maxdepth 1 -name '*.appex' 2>/dev/null)
  P8=1; D8=""
  if [ "${#APPEXES[@]}" -lt 1 ]; then
    P8=0; D8="沒有 PlugIns/*.appex"
  else
    for E in "${APPEXES[@]}"; do
      EI="$E/Info.plist"
      EID="$(plist_get "$EI" CFBundleIdentifier)"
      EXEC="$E/$(plist_get "$EI" CFBundleExecutable)"
      EP="$(plist_get "$EI" NSExtension.NSExtensionPointIdentifier)"
      OA="$(plist_get "$EI" NSExtension.NSExtensionAttributes.RequestsOpenAccess)"
      [ "$EP" = "com.apple.keyboard-service" ] || { P8=0; D8="$D8 擴充點是「$EP」;"; }
      case "$EID" in "$APP_ID".?*) ;; *) P8=0; D8="$D8 擴充 ID「$EID」不以「$APP_ID.」開頭;" ;; esac
      [ "$OA" = "true" ] || { P8=0; D8="$D8 RequestsOpenAccess 是「${OA:-空}」;"; }
      if [ -f "$EXEC" ] && macho_ok "$EXEC" && [ "$(platform_of "$EXEC")" = "IOS" ]; then :; else P8=0; D8="$D8 擴充執行檔無效;"; fi
      echo " $(archs_of "$EXEC") " | grep -q ' arm64 ' || EXT_ARM=0
    done
  fi
  FW_LIST=""
  while IFS= read -r FW; do
    [ -n "$FW" ] || continue
    FN="$(basename "$FW")"; FW_LIST="$FW_LIST $FN"
    case "$FN" in
      *.framework)
        FEXEC="$FW/$(plist_get "$FW/Info.plist" CFBundleExecutable)"
        if [ -f "$FEXEC" ] && macho_ok "$FEXEC" && echo " $(archs_of "$FEXEC") " | grep -q ' arm64 ' && [ "$(platform_of "$FEXEC")" = "IOS" ]; then :
        else P8=0; D8="$D8 framework $FN 的執行檔不是 iOS arm64 Mach-O;"; fi ;;
      *.dylib)
        if macho_ok "$FW" && echo " $(archs_of "$FW") " | grep -q ' arm64 '; then :; else P8=0; D8="$D8 $FN 不是 arm64 Mach-O;"; fi ;;
    esac
  done < <(find "$APP/Frameworks" "$APP"/PlugIns/*.appex/Frameworks -mindepth 1 -maxdepth 1 2>/dev/null | sort)
  BUNDLES="$(find "$APP" -name '*.bundle' -maxdepth 4 2>/dev/null | sed "s#^$APP/##" | sort | tr '\n' ' ')"

  # 4 的結果（需要 appex 迴圈之後才完整）
  if [ "$APP_ARM" -eq 1 ] && [ "$EXT_ARM" -eq 1 ] && [ "${#APPEXES[@]}" -ge 1 ]; then
    record PASS 4 "app 與 appex 都含 arm64"
  else
    record FAIL 4 "app 或 appex 缺少 arm64（或沒有 appex）"
  fi

  if [ "$P8" -eq 1 ]; then
    record PASS 8 "鍵盤擴充完整（${#APPEXES[@]} 個 appex，擴充點 keyboard-service，RequestsOpenAccess true）；frameworks：${FW_LIST:- 無}；resource bundles：${BUNDLES:-無}"
  else
    record FAIL 8 "擴充不完整：$D8"
  fi

  # 9 entitlements
  P9=1; D9=""
  ENT_TARGETS=("$APP")
  [ "${#APPEXES[@]}" -ge 1 ] && ENT_TARGETS+=("${APPEXES[@]}")
  for T in "${ENT_TARGETS[@]}"; do
    codesign -d --entitlements - --xml "$T" >"$WORK/ent.xml" 2>/dev/null || true
    if ! plutil -extract 'com\.apple\.security\.application-groups' json -o - "$WORK/ent.xml" 2>/dev/null | grep -q "\"$GROUP\""; then
      P9=0; D9="$D9 $(basename "$T") 沒有請求 $GROUP;"
    fi
  done
  if [ "${#APPEXES[@]}" -lt 1 ]; then P9=0; D9="$D9 沒有 appex 可檢查;"; fi
  if [ -n "$(find "$X" -name 'embedded.mobileprovision' -print -quit)" ]; then P9=0; D9="$D9 仍有 embedded.mobileprovision;"; fi
  if [ "$P9" -eq 1 ]; then record PASS 9 "app 與 appex 的簽章 entitlements 都請求 $GROUP，沒有 embedded.mobileprovision"
  else record FAIL 9 "$D9"; fi
else
  record BLOCKED 10 "找不到唯一的 .app"
fi

# 10 禁止內容
if [ -d "$X/Payload" ]; then
  FORBID="$(find "$X" \( -name '*.swift' -o -name '*.m' -o -name '.git' -o -name '.env' -o -name '.env.*' \
      -o -name '*.p12' -o -name '*.pem' -o -name '*.key' -o -name '*.mobileprovision' -o -name '*.xcodeproj' \
      -o -name '*.xcworkspace' -o -name '*.dSYM' -o -name 'Podfile*' -o -name 'GoogleService-Info.plist' \
      -o -name '__MACOSX' -o -name '.DS_Store' \
      -o \( -name '*.h' -not -path '*/Headers/*' \) \) 2>/dev/null | sed "s#^$X/##")"
  # ditto 解壓會把 ._ 併回 xattr，要直接看壓縮檔的項目清單。
  APPLEDOUBLE="$(unzip -Z1 "$IPA" 2>/dev/null | grep -E '(^|/)\._' || true)"
  [ -z "$APPLEDOUBLE" ] || FORBID="$FORBID AppleDouble×$(printf '%s\n' "$APPLEDOUBLE" | wc -l | tr -d ' ')"
  PK="$(find "$X" -type f \( -name '*.plist' -o -name '*.json' -o -name '*.txt' \) -exec grep -l -a 'PRIVATE KEY' {} + 2>/dev/null | sed "s#^$X/##" || true)"
  USERS=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    macho_ok "$f" || continue
    n="$({ grep -a -o '/Users/' "$f" 2>/dev/null || true; } | wc -l | tr -d ' ')"
    USERS=$((USERS + n))
  done < <(find "$X" -type f \( -perm -u+x -o -name '*.dylib' \) 2>/dev/null)
  NOTES+=("執行檔內含字串 /Users/ 共 ${USERS} 處（多半是編譯期嵌入的來源路徑，不列為失敗，發佈前請自行確認）。")
  if [ -n "$FORBID" ] || [ -n "$PK" ]; then
    record FAIL 10 "禁止內容：$(echo "$FORBID $PK" | tr '\n' ' ')"
  else
    record PASS 10 "沒有禁止的檔案與 PRIVATE KEY；執行檔內 /Users/ 出現 ${USERS} 處（只記錄，不算失敗）"
  fi
else
  record BLOCKED 10 "沒有 Payload/"
fi

# 11 SHA-256
SHAFILE="$IPA.sha256"
if [ -f "$SHAFILE" ]; then
  if (cd "$(dirname "$IPA")" && shasum -a 256 -c "$(basename "$SHAFILE")" >/dev/null 2>&1); then
    record PASS 11 "SHA-256 檔存在且與 IPA 相符：$(awk '{print $1}' "$SHAFILE")"
  else
    record FAIL 11 "SHA-256 與 IPA 不符"
  fi
else
  record BLOCKED 11 "沒有 $(basename "$SHAFILE")"
fi

finish
