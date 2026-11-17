# 結構檢查腳本共用的函式，供 validate-ipa.sh、validate-mac-app.sh source 使用。
# 呼叫端要先設定 REPORT（可為空），再呼叫 check_init <暫存目錄前綴>。
# 結束前要設定 REPORT_TITLE（標題）、REPORT_TARGET（受檢檔案路徑）、REPORT_FOOTER（最後一句）。

# check_init <前綴>：建立暫存目錄 $WORK（結束時自動刪除），並歸零計數。
check_init() {
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/$1.XXXXXX")"
  trap 'rm -rf "$WORK"' EXIT
  LINES=(); NOTES=()
  FAILS=0; BLOCKS=0
}

# record <PASS|FAIL|BLOCKED> <編號> <說明>
record() {
  local line="$1 [$2] $3"
  LINES+=("$line"); echo "$line"
  case "$1" in FAIL) FAILS=$((FAILS+1)) ;; BLOCKED) BLOCKS=$((BLOCKS+1)) ;; esac
}

# block_rest <編號...>：用 $BLOCK_WHY 把其餘項目記為 BLOCKED。
block_rest() { local n; for n in "$@"; do record BLOCKED "$n" "$BLOCK_WHY"; done; }

plist_get() { plutil -extract "$2" raw -o - "$1" 2>/dev/null || true; }
macho_ok() { file -b "$1" | grep -q 'Mach-O'; }
# 平台名稱，例如 IOS、MACOS
platform_of() { vtool -show-build "$1" 2>/dev/null | awk '$1=="platform"{print $2; exit}'; }

# finish：寫報告（有 --report 時）並以 0／1／2 結束。
finish() {
  local code=0
  [ "$BLOCKS" -gt 0 ] && code=2
  [ "$FAILS" -gt 0 ] && code=1
  if [ -n "$REPORT" ]; then
    {
      echo "# $REPORT_TITLE"
      echo
      echo "- 檔案：$(basename "$REPORT_TARGET")"
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
      echo "$REPORT_FOOTER"
    } >"$REPORT"
  fi
  exit "$code"
}

# scan_forbidden <解壓目錄> <壓縮檔>：設定 FORBID（禁止的檔案）與 PK（含 PRIVATE KEY 的檔案）。
scan_forbidden() {
  local x="$1" archive="$2"
  FORBID="$(find "$x" \( -name '*.swift' -o -name '*.m' -o -name '.git' -o -name '.env' -o -name '.env.*' \
      -o -name '*.p12' -o -name '*.pem' -o -name '*.key' -o -name '*.mobileprovision' -o -name '*.xcodeproj' \
      -o -name '*.xcworkspace' -o -name '*.dSYM' -o -name 'Podfile*' -o -name 'GoogleService-Info.plist' \
      -o -name '__MACOSX' -o -name '.DS_Store' \
      -o \( -name '*.h' -not -path '*/Headers/*' \) \) 2>/dev/null | sed "s#^$x/##")"
  # ditto 解壓會把 ._ 併回 xattr，要直接看壓縮檔的項目清單。
  APPLEDOUBLE="$(unzip -Z1 "$archive" 2>/dev/null | grep -E '(^|/)\._' || true)"
  [ -z "$APPLEDOUBLE" ] || FORBID="$FORBID AppleDouble×$(printf '%s\n' "$APPLEDOUBLE" | wc -l | tr -d ' ')"
  PK="$(find "$x" -type f \( -name '*.plist' -o -name '*.json' -o -name '*.txt' \) -exec grep -l -a 'PRIVATE KEY' {} + 2>/dev/null | sed "s#^$x/##" || true)"
}

# count_users_strings <目錄>：印出目錄內執行檔含 /Users/ 字串的總數。
count_users_strings() {
  local total=0 f n
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    macho_ok "$f" || continue
    n="$({ grep -a -o '/Users/' "$f" 2>/dev/null || true; } | wc -l | tr -d ' ')"
    total=$((total + n))
  done < <(find "$1" -type f \( -perm -u+x -o -name '*.dylib' \) 2>/dev/null)
  echo "$total"
}

# check_sha256 <編號> <受檢檔案> <名稱>：檢查 <檔案>.sha256。
check_sha256() {
  local n="$1" target="$2" noun="$3" shafile="$2.sha256"
  if [ -f "$shafile" ]; then
    if (cd "$(dirname "$target")" && shasum -a 256 -c "$(basename "$shafile")" >/dev/null 2>&1); then
      record PASS "$n" "SHA-256 檔存在且與 $noun 相符：$(awk '{print $1}' "$shafile")"
    else
      record FAIL "$n" "SHA-256 與 $noun 不符"
    fi
  else
    record BLOCKED "$n" "沒有 $(basename "$shafile")"
  fi
}
