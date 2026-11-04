#!/usr/bin/env bash
# 發佈前自動檢查：每一項都會跑，即使前面失敗。結果寫入 release/prerelease-report.md。
# 有任何 FAIL 時結束碼為 1。這些檢查是自動驗證；真機（iPhone、藍牙）項目不在其中。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LOGDIR="build/prerelease"
rm -rf "$LOGDIR"
mkdir -p "$LOGDIR" release
REPORT="release/prerelease-report.md"

NAMES=(); STATUS=(); DETAIL=()
# add <PASS|FAIL|BLOCKED> <項目> <說明>：說明不得含個人路徑
add() { STATUS+=("$1"); NAMES+=("$2"); DETAIL+=("$3"); printf '%-8s %s  %s\n' "$1" "$2" "$3"; }
scrub() { LC_ALL=C sed -e "s#$ROOT#<repo>#g" -e "s#$HOME#~#g" -E -e 's#/Users/[^/ ]+#/Users/<user>#g'; }

# run_logged <log 名稱> <命令...>：輸出存到 build/prerelease/<名稱>.log，回傳命令的結束碼
run_logged() {
  local name="$1"; shift
  "$@" >"$LOGDIR/$name.log" 2>&1
}

# 啟動時已在監聽的程序不算這次執行留下的。
LISTEN_BEFORE="$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $2}' | sort -u)"

IOS_DEST='platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0'
MAC_DEST='platform=macOS,arch=arm64'

# 1 Core 測試
if run_logged core swift test --package-path Packages/RemoteKeyboardCore; then
  add PASS "Core 測試" "$(grep -E 'Executed [0-9]+ tests' "$LOGDIR/core.log" | tail -n 1 | sed 's/^[[:space:]]*//')"
else
  add FAIL "Core 測試" "見 build/prerelease/core.log"
fi

# 2 MacReceiver 測試
if run_logged mac-tests xcodebuild test -workspace RemoteKeyboard.xcworkspace -scheme MacReceiver \
    -destination "$MAC_DEST" -allowProvisioningUpdates; then
  add PASS "MacReceiver 測試" "$(grep -E 'Executed [0-9]+ tests' "$LOGDIR/mac-tests.log" | tail -n 1 | sed 's/^[[:space:]]*//')"
else
  add FAIL "MacReceiver 測試" "見 build/prerelease/mac-tests.log"
fi

# 3 iOS 模擬器建置、4 模擬器 UI 測試
if ! xcrun simctl list devices available 2>/dev/null | grep -q 'iPhone 18 Pro ('; then
  add BLOCKED "iOS 模擬器建置" "找不到 iPhone 18 Pro 模擬器"
  add BLOCKED "模擬器 UI 測試 HitAreaUITests" "找不到 iPhone 18 Pro 模擬器"
else
  if run_logged ios-build xcodebuild build -workspace RemoteKeyboard.xcworkspace -scheme RemoteKeyboardApp \
      -destination "$IOS_DEST" CODE_SIGNING_ALLOWED=NO; then
    add PASS "iOS 模擬器建置" "BUILD SUCCEEDED"
  else
    add FAIL "iOS 模擬器建置" "見 build/prerelease/ios-build.log"
  fi
  # 這個測試要鍵盤已加入模擬器的鍵盤清單，否則第一步就打不出字；這不是 App 的問題，所以找不到時標 BLOCKED。
  # 模擬器重置後兩項設定都會還原：鍵盤清單沒有這個鍵盤，軟鍵盤也會自動縮到螢幕外，所以每次都先設定一次。
  PREP_SIM="$(xcrun simctl list devices available | grep 'iPhone 18 Pro (' | head -n 1 | grep -oE '[0-9A-F-]{36}')"
  if [ -n "$PREP_SIM" ]; then
    xcrun simctl boot "$PREP_SIM" 2>/dev/null || true
    xcrun simctl bootstatus "$PREP_SIM" >/dev/null 2>&1 || true
    if ! xcrun simctl spawn "$PREP_SIM" defaults read -g AppleKeyboards 2>/dev/null | grep -q 'com.ansonhui.remotekeyboard.keyboard'; then
      xcrun simctl spawn "$PREP_SIM" defaults write -g AppleKeyboards -array-add com.ansonhui.remotekeyboard.keyboard
    fi
    xcrun simctl spawn "$PREP_SIM" defaults write com.apple.keyboard.preferences AutomaticMinimizationEnabled -bool NO
    # 縮小鍵盤的設定要重開機才生效；讀鍵盤清單也要模擬器開著，所以測試完才關機。
    xcrun simctl shutdown "$PREP_SIM" 2>/dev/null || true
    xcrun simctl boot "$PREP_SIM" 2>/dev/null || true
    xcrun simctl bootstatus "$PREP_SIM" >/dev/null 2>&1 || true
  fi
  KEYBOARD_SIM=""
  while read -r udid; do
    if xcrun simctl spawn "$udid" defaults read -g AppleKeyboards 2>/dev/null | grep -q 'com.ansonhui.remotekeyboard.keyboard'; then
      KEYBOARD_SIM="$udid"
      break
    fi
  done < <(xcrun simctl list devices available | grep -E 'iPhone .*\((Booted|Shutdown)\)' | grep -oE '[0-9A-F-]{36}')
  if [ -z "$KEYBOARD_SIM" ]; then
    add BLOCKED "模擬器 UI 測試 HitAreaUITests" "沒有模擬器加入 Remote Keyboard 鍵盤"
  elif run_logged ios-ui xcodebuild test -workspace RemoteKeyboard.xcworkspace -scheme RemoteKeyboardApp \
      -destination "platform=iOS Simulator,id=$KEYBOARD_SIM" -only-testing:RemoteKeyboardUITests/HitAreaUITests CODE_SIGNING_ALLOWED=NO; then
    N="$(grep -E "Executed [0-9]+ tests?" "$LOGDIR/ios-ui.log" | tail -n 1 | sed 's/^[[:space:]]*//')"
    if echo "$N" | grep -qE 'Executed [1-9][0-9]* test'; then add PASS "模擬器 UI 測試 HitAreaUITests" "$N"
    else add FAIL "模擬器 UI 測試 HitAreaUITests" "沒有執行任何測試"; fi
  else
    add FAIL "模擬器 UI 測試 HitAreaUITests" "見 build/prerelease/ios-ui.log"
  fi
  [ -n "$PREP_SIM" ] && { xcrun simctl shutdown "$PREP_SIM" 2>/dev/null || true; }
fi

# 5 兩個打包腳本、6 兩個驗證腳本
IPA_DIR=""; MAC_DIR=""
if run_logged pack-ios scripts/build-sidestore-ipa.sh --force; then
  IPA_DIR="$(ls -dt release/sidestore/v*/ 2>/dev/null | head -n 1)"
  add PASS "打包 IPA" "$IPA_DIR"
else
  add FAIL "打包 IPA" "見 build/prerelease/pack-ios.log"
fi
if run_logged pack-mac scripts/build-mac-receiver-release.sh --force; then
  MAC_DIR="$(ls -dt release/mac-receiver/v*/ 2>/dev/null | head -n 1)"
  add PASS "打包 Mac Receiver" "$MAC_DIR"
else
  add FAIL "打包 Mac Receiver" "見 build/prerelease/pack-mac.log"
fi
IPA_FILE="$(ls "$IPA_DIR"*.ipa 2>/dev/null | head -n 1 || true)"
MAC_ZIP="$(ls "$MAC_DIR"*.zip 2>/dev/null | head -n 1 || true)"
if [ -z "$IPA_FILE" ]; then add BLOCKED "驗證 IPA" "沒有 IPA"
elif run_logged validate-ipa scripts/validate-ipa.sh "$IPA_FILE"; then add PASS "驗證 IPA" "$(grep -c '^PASS' "$LOGDIR/validate-ipa.log") 項 PASS"
else add FAIL "驗證 IPA" "見 build/prerelease/validate-ipa.log"; fi
if [ -z "$MAC_ZIP" ]; then add BLOCKED "驗證 Mac zip" "沒有 zip"
elif run_logged validate-mac scripts/validate-mac-app.sh "$MAC_ZIP"; then add PASS "驗證 Mac zip" "$(grep -c '^PASS' "$LOGDIR/validate-mac.log") 項 PASS"
else add FAIL "驗證 Mac zip" "見 build/prerelease/validate-mac.log"; fi

# 7 secure field 測試類別：用名稱指定，改名或刪除會讓這項失敗
SECURE_CLASSES=(SecureFieldClassificationTests InputBlockedFocusTests SecureFieldPipelineTests)
ARGS=()
for c in "${SECURE_CLASSES[@]}"; do ARGS+=("-only-testing:MacReceiverTests/$c"); done
run_logged secure xcodebuild test -workspace RemoteKeyboard.xcworkspace -scheme MacReceiver \
  -destination "$MAC_DEST" -allowProvisioningUpdates "${ARGS[@]}"
SECURE_OK=1; SECURE_DETAIL=""
for c in "${SECURE_CLASSES[@]}"; do
  if grep -q "Test Suite '$c' passed" "$LOGDIR/secure.log"; then
    n="$(awk -v c="$c" '$0 ~ "Test Suite \x27"c"\x27 started"{f=1} f && /Executed [0-9]+ test/{print $2; exit}' "$LOGDIR/secure.log")"
    SECURE_DETAIL="$SECURE_DETAIL $c=${n:-?}"
  else
    SECURE_OK=0; SECURE_DETAIL="$SECURE_DETAIL $c=缺少或失敗"
  fi
done
if [ "$SECURE_OK" -eq 1 ]; then add PASS "secure field 測試類別" "$SECURE_DETAIL"; else add FAIL "secure field 測試類別" "$SECURE_DETAIL"; fi

# 8 log 隱私：樣式掃描，不是證明
LOG_CALL='(Logger|logger|[Ll]og\.(info|debug|error|notice|warning|fault|log)|os_log|NSLog|print|[^A-Za-z_.]log)\('
TYPED='\\\((text|typed|typedText|input|inputText|string|content|candidate|candidates|composition|composed|word|phrase|committed|inserted|chunk|value)\b'
# 長度與數量（.count、.isEmpty）不是文字本身：先把這種內插從該行拿掉，再找剩下的文字變數內插。
VARS='text|typed|typedText|input|inputText|string|content|candidate|candidates|composition|composed|word|phrase|committed|inserted|chunk|value'
DERIVED="\\\\\\(($VARS)(\\.[A-Za-z0-9]+)*\\.(count|isEmpty)[^)]*\\)"
LOG_HITS="$(grep -rnE --include='*.swift' "$LOG_CALL" iOS macOS Packages/*/Sources 2>/dev/null | grep -v '/Tests/' \
  | sed -E "s/$DERIVED//g" | grep -E "$TYPED" || true)"
if [ -z "$LOG_HITS" ]; then
  add PASS "log 隱私樣式掃描" "沒有 log 呼叫內插輸入文字變數（樣式掃描，不是證明）；樣式：${LOG_CALL} 同一行含 ${TYPED}"
else
  add FAIL "log 隱私樣式掃描" "$(echo "$LOG_HITS" | wc -l | tr -d ' ') 處：$(echo "$LOG_HITS" | head -n 3 | cut -c1-120 | tr '\n' '|')"
fi

# 9 機密與個人資料
FILES="$( { git ls-files; git ls-files -o --exclude-standard; } | sort -u)"
BAD_NAMES="$(echo "$FILES" | grep -E '(^|/)\.env($|\.)|\.p12$|\.pem$|\.mobileprovision$' || true)"
BAD_KEY="$(echo "$FILES" | grep -vE '^scripts/' | while IFS= read -r f; do [ -f "$f" ] && grep -Il 'PRIVATE KEY' "$f" 2>/dev/null; done || true)"
EMAILS=""
for e in "$(git config user.email 2>/dev/null || true)" "$(git config --global user.email 2>/dev/null || true)"; do
  [ -n "$e" ] && EMAILS="$EMAILS $e"
done
EMAIL_HITS=""
if [ -n "$EMAILS" ] && [ -n "$IPA_DIR$MAC_DIR" ]; then
  X="$(mktemp -d "${TMPDIR:-/tmp}/prerelease.XXXXXX")"
  [ -n "$IPA_FILE" ] && { mkdir "$X/ipa"; ditto -x -k "$IPA_FILE" "$X/ipa"; }
  [ -n "$MAC_ZIP" ] && { mkdir "$X/mac"; ditto -x -k "$MAC_ZIP" "$X/mac"; }
  for e in $EMAILS; do
    EMAIL_HITS="$EMAIL_HITS $(grep -rFal -- "$e" "$X" $IPA_DIR $MAC_DIR 2>/dev/null | sed "s#$X/##" | tr '\n' ' ')"
  done
  rm -rf "$X"
fi
if [ -z "$BAD_NAMES$BAD_KEY" ] && [ -z "$(echo "$EMAIL_HITS" | tr -d ' ')" ]; then
  if [ -z "$EMAILS" ]; then add BLOCKED "機密與個人資料" "git config 沒有 user.email，無法掃描電郵；檔名與 PRIVATE KEY 掃描沒有發現"
  else add PASS "機密與個人資料" "專案檔與兩個發佈產物（含解壓內容）沒有 .env、.p12、.pem、.mobileprovision、PRIVATE KEY，也沒有開發者電郵（樣式掃描，不是證明）"; fi
else
  add FAIL "機密與個人資料" "檔名：${BAD_NAMES:-無} 金鑰：${BAD_KEY:-無} 電郵出現在：${EMAIL_HITS:-無}"
fi

# 10 兩個產物版本一致
IV="$(plutil -extract version raw -o - "$IPA_DIR/metadata.json" 2>/dev/null || true)"
IB="$(plutil -extract build raw -o - "$IPA_DIR/metadata.json" 2>/dev/null || true)"
MV="$(plutil -extract version raw -o - "$MAC_DIR/metadata.json" 2>/dev/null || true)"
MB="$(plutil -extract build raw -o - "$MAC_DIR/metadata.json" 2>/dev/null || true)"
if [ -z "$IV" ] || [ -z "$MV" ]; then add BLOCKED "iOS 與 Mac 版本一致" "缺少其中一個產物"
elif [ "$IV" = "$MV" ] && [ "$IB" = "$MB" ]; then add PASS "iOS 與 Mac 版本一致" "v$IV build $IB"
else add FAIL "iOS 與 Mac 版本一致" "iOS v$IV-b$IB，Mac v$MV-b$MB"; fi

# 11 授權檔在 IPA 內
if [ -z "$IPA_FILE" ]; then add BLOCKED "IPA 內有授權檔" "沒有 IPA"
elif IPA_LIST="$(unzip -Z1 "$IPA_FILE")"; echo "$IPA_LIST" | grep -q 'quick-table-LICENSE\.txt$'; then add PASS "IPA 內有授權檔" "quick-table-LICENSE.txt"
else add FAIL "IPA 內有授權檔" "IPA 內沒有 quick-table-LICENSE.txt"; fi

# 12 release/ 與 build/ 被 git 忽略
if git check-ignore -q release/prerelease-report.md && git check-ignore -q build/prerelease/core.log; then add PASS "release/ 與 build/ 被忽略" "git check-ignore 確認"
else add FAIL "release/ 與 build/ 被忽略" "其中一個沒有被 .gitignore 忽略"; fi

# 13 文件用詞：台灣受眾文件不得混入廣東話用字
CANT="$(grep -nE '咗|嘅|唔' docs/distribution/*.md 2>/dev/null || true)"
if [ -z "$CANT" ]; then add PASS "docs/distribution 用詞" "沒有 咗、嘅、唔"
else add FAIL "docs/distribution 用詞" "$(echo "$CANT" | wc -l | tr -d ' ') 行含廣東話用字：$(echo "$CANT" | head -n 3 | cut -c1-60 | tr '\n' '|')"; fi

# 14 沒有殘留的 listener：只看這次執行之後新出現的程序
LISTEN_NEW=""
while read -r pid cmd; do
  [ -n "$pid" ] || continue
  echo "$LISTEN_BEFORE" | grep -qx "$pid" || LISTEN_NEW="$LISTEN_NEW $cmd($pid)"
done < <(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $2, $1}' | sort -u)
if [ -z "$LISTEN_NEW" ]; then add PASS "沒有殘留 listener" "lsof 顯示這次執行沒有新增任何 TCP LISTEN 程序（執行前已存在的不算）"
else add FAIL "沒有殘留 listener" "新增：$LISTEN_NEW"; fi

# 輸出表格與報告
FAILS=0; BLOCKS=0
for s in "${STATUS[@]}"; do
  [ "$s" = FAIL ] && FAILS=$((FAILS+1))
  [ "$s" = BLOCKED ] && BLOCKS=$((BLOCKS+1))
done
{
  echo "# 發佈前自動檢查"
  echo
  echo "產生時間（UTC）：$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Git commit：$(git rev-parse --short HEAD)，工作目錄有未提交變更：$([ -n "$(git status --porcelain)" ] && echo 是 || echo 否)"
  echo "結果：FAIL ${FAILS}，BLOCKED ${BLOCKS}，共 ${#NAMES[@]} 項"
  echo
  echo "| 項目 | 結果 | 說明 |"
  echo "|---|---|---|"
  i=0
  while [ "$i" -lt "${#NAMES[@]}" ]; do
    echo "| ${NAMES[$i]} | ${STATUS[$i]} | $(echo "${DETAIL[$i]}" | tr '|' '/') |"
    i=$((i+1))
  done
  echo
  echo "這是自動驗證。iPhone 真機、藍牙、輔助使用權限與 SideStore 安裝都不在內，仍是 TBD，要親手測完才算 PASS。"
  echo "密鑰、電郵與 log 檢查只掃描已知樣式，不能證明沒有問題。"
} | scrub >"$REPORT"

echo
echo "FAIL ${FAILS}，BLOCKED ${BLOCKS}，報告：$REPORT"
[ "$FAILS" -eq 0 ]
