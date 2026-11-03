#!/usr/bin/env bash
# 建置 Mac Receiver 的發佈 zip：Release、ad-hoc 簽章，沒有 Developer ID、沒有公證。
# 不用個人的 Apple Development 憑證簽，免得開發者身分跟著 App 流出去。
set -euo pipefail

FORCE=0
SMOKE=0
usage() {
  cat <<USAGE
用法：scripts/build-mac-receiver-release.sh [--force] [--launch-smoke] [-h]

  --force         輸出資料夾已存在時覆蓋
  --launch-smoke  打包後在暫存資料夾啟動一份改了 bundle ID 的複本，確認 5 秒後仍在執行（不動已安裝的 Receiver）

輸出：release/mac-receiver/v<版本>-b<build>/
USAGE
}
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --launch-smoke) SMOKE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "不認得的參數：$1" >&2; usage >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MISSING=()
for t in xcodebuild xcodegen pod codesign plutil ditto shasum lipo git xattr; do
  command -v "$t" >/dev/null 2>&1 || MISSING+=("$t")
done
[ -x /usr/sbin/spctl ] || MISSING+=("spctl")
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "缺少工具：${MISSING[*]}" >&2
  exit 1
fi

xcodegen generate
LANG=en_US.UTF-8 pod install

# 封存前先讀版本，輸出資料夾已存在時不必建置；封存後再核對 app 內的值。
SETTINGS="$(xcodebuild -showBuildSettings -workspace RemoteKeyboard.xcworkspace -scheme MacReceiver -configuration Release 2>/dev/null)"
EARLY_VERSION="$(echo "$SETTINGS" | awk '$1=="MARKETING_VERSION"{print $3; exit}')"
EARLY_BUILD="$(echo "$SETTINGS" | awk '$1=="CURRENT_PROJECT_VERSION"{print $3; exit}')"
if [ -z "$EARLY_VERSION" ] || [ -z "$EARLY_BUILD" ]; then
  echo "讀不到 MARKETING_VERSION 或 CURRENT_PROJECT_VERSION" >&2
  exit 1
fi
OUT="release/mac-receiver/v${EARLY_VERSION}-b${EARLY_BUILD}"
if [ -e "$OUT" ] && [ "$FORCE" -ne 1 ]; then
  echo "輸出資料夾已存在：$OUT（要覆蓋請加 --force）" >&2
  exit 1
fi

TMP="build/mac-receiver"
rm -rf "$TMP"
mkdir -p "$TMP"
ARCHIVE="$TMP/MacReceiver.xcarchive"
LOG="$TMP/build.log"

echo "封存 Release（無簽章），記錄檔：$LOG"
if ! xcodebuild archive -workspace RemoteKeyboard.xcworkspace -scheme MacReceiver \
    -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO 2>&1 | tee "$LOG"; then
  echo "封存失敗，記錄檔：$LOG" >&2
  exit 1
fi

APP="$(find "$ARCHIVE/Products/Applications" -mindepth 1 -maxdepth 1 -name '*.app' 2>/dev/null | head -n 1)"
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  echo "封存裡找不到 .app：$ARCHIVE/Products/Applications" >&2
  exit 1
fi

plist() { plutil -extract "$2" raw -o - "$1"; }
VERSION="$(plist "$APP/Contents/Info.plist" CFBundleShortVersionString)"
BUILD="$(plist "$APP/Contents/Info.plist" CFBundleVersion)"
APP_ID="$(plist "$APP/Contents/Info.plist" CFBundleIdentifier)"
MIN_MAC="$(plist "$APP/Contents/Info.plist" LSMinimumSystemVersion)"
EXEC_NAME="$(plist "$APP/Contents/Info.plist" CFBundleExecutable)"
if [ "$VERSION" != "$EARLY_VERSION" ] || [ "$BUILD" != "$EARLY_BUILD" ]; then
  echo "app 內的版本 v${VERSION}-b${BUILD} 與建置設定 v${EARLY_VERSION}-b${EARLY_BUILD} 不一致" >&2
  exit 1
fi

ZIP_NAME="RemoteKeyboardReceiver-v${VERSION}-macOS.zip"
STAGE="$TMP/stage"
mkdir -p "$STAGE"
# 對使用者顯示的名稱與安裝腳本一致；執行檔仍是 $EXEC_NAME。
STAGE_APP="$STAGE/Remote Keyboard Receiver.app"
ditto "$APP" "$STAGE_APP"

find "$STAGE_APP" \( -name '*.dSYM' -o -name '*.swiftmodule' -o -name '*.swiftdoc' \
  -o -name '*.bcsymbolmap' -o -name '.DS_Store' \) -prune -exec rm -rf {} +
xattr -cr "$STAGE_APP" 2>/dev/null || true

# ad-hoc 簽章，由內而外，開 hardened runtime。沒有 entitlements：App 不開 sandbox，也沒有額外權限。
sign() { codesign --force --options runtime --timestamp=none --sign - "$@"; }
for d in Contents/Frameworks Contents/PlugIns Contents/XPCServices Contents/Library/LoginItems Contents/Library/LaunchServices; do
  [ -d "$STAGE_APP/$d" ] || continue
  while IFS= read -r item; do sign "$item"; done < <(find "$STAGE_APP/$d" -mindepth 1 -maxdepth 1 | sort)
done
sign "$STAGE_APP"

# 打包：zip 根目錄是 .app。
(cd "$STAGE" && ditto -c -k --norsrc --noextattr --keepParent "Remote Keyboard Receiver.app" "$ZIP_NAME")
if unzip -Z1 "$STAGE/$ZIP_NAME" | grep -v '^Remote Keyboard Receiver\.app/' | grep -q .; then
  echo "zip 根目錄含 .app 以外的項目" >&2
  exit 1
fi
(cd "$STAGE" && shasum -a 256 "$ZIP_NAME" >"$ZIP_NAME.sha256")
SHA="$(awk '{print $1}' "$STAGE/$ZIP_NAME.sha256")"

if ! scripts/validate-mac-app.sh "$STAGE/$ZIP_NAME" --expect-bundle-id "$APP_ID" \
    --expect-version "$VERSION" --expect-build "$BUILD" --expect-min-macos "$MIN_MAC" \
    --report "$STAGE/validation-report.md"; then
  echo "驗證沒有通過，不產生輸出資料夾。暫存：$STAGE" >&2
  exit 1
fi

# Gatekeeper：帶隔離標記的複本拿去評估。沒有公證，預期被拒；這行只是記錄事實，不影響結果。
GK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rk-gatekeeper.XXXXXX")"
ditto "$STAGE_APP" "$GK_DIR/Remote Keyboard Receiver.app"
xattr -w com.apple.quarantine "0081;$(printf '%x' "$(date +%s)");Safari;" "$GK_DIR/Remote Keyboard Receiver.app"
GK_OUT="$(/usr/sbin/spctl --assess --type execute -vv "$GK_DIR/Remote Keyboard Receiver.app" 2>&1 || true)"
GK_OUT="$(echo "$GK_OUT" | sed "s#$GK_DIR#<tmp>#g")"
rm -rf "$GK_DIR"

# 啟動煙霧測試（選用）。已安裝的 Receiver 正在執行，所以用另一個 bundle ID 的複本，只結束自己啟動的那個 PID。
SMOKE_RESULT="未執行（加 --launch-smoke 才會跑）"
SMOKE_FAIL=0
if [ "$SMOKE" -eq 1 ]; then
  BEFORE="$(pgrep -x "$EXEC_NAME" | sort | tr '\n' ' ' || true)"
  SM_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rk-smoke.XXXXXX")"
  SM_APP="$SM_DIR/Smoke.app"
  ditto "$STAGE_APP" "$SM_APP"
  plutil -replace CFBundleIdentifier -string "${APP_ID}.smoke" "$SM_APP/Contents/Info.plist"
  codesign --force --options runtime --timestamp=none --sign - "$SM_APP"
  "$SM_APP/Contents/MacOS/$EXEC_NAME" >/dev/null 2>&1 &
  SM_PID=$!
  sleep 5
  if kill -0 "$SM_PID" 2>/dev/null; then ALIVE=yes; else ALIVE=no; fi
  if [ "$ALIVE" = yes ]; then
    kill "$SM_PID" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$SM_PID" 2>/dev/null || break; sleep 0.5; done
    kill -0 "$SM_PID" 2>/dev/null && kill -9 "$SM_PID" 2>/dev/null || true
  fi
  wait "$SM_PID" 2>/dev/null || true
  rm -rf "$SM_DIR"
  AFTER="$(pgrep -x "$EXEC_NAME" | sort | tr '\n' ' ' || true)"
  if [ "$ALIVE" = yes ] && [ "$BEFORE" = "$AFTER" ]; then
    SMOKE_RESULT="PASS：複本啟動 5 秒後仍在執行，已結束；啟動前後的 ${EXEC_NAME} 程序 ID 相同（${BEFORE:-無}）"
  else
    SMOKE_RESULT="FAIL：5 秒後存活=${ALIVE}；啟動前 ${BEFORE:-無}，結束後 ${AFTER:-無}"
    SMOKE_FAIL=1
  fi
  echo "啟動煙霧測試 $SMOKE_RESULT"
fi

{
  echo
  echo "## Gatekeeper（資訊）"
  echo
  echo "帶隔離標記的複本執行 \`spctl --assess --type execute -vv\`。沒有公證，預期被拒絕；使用者需要照安裝指南手動放行。"
  echo
  echo '```'
  echo "$GK_OUT"
  echo '```'
  echo
  echo "## 啟動煙霧測試"
  echo
  echo "$SMOKE_RESULT"
} >>"$STAGE/validation-report.md"
# 結語要留在最後。
sed -i '' -e '/^結構檢查不等於 Gatekeeper 放行/d' "$STAGE/validation-report.md"
printf '\n結構檢查不等於 Gatekeeper 放行，也不是啟動測試。\n' >>"$STAGE/validation-report.md"

[ -e "$OUT" ] && rm -rf "$OUT"
mkdir -p "$OUT"
mv "$STAGE/$ZIP_NAME" "$STAGE/$ZIP_NAME.sha256" "$STAGE/validation-report.md" "$OUT/"

LC_ALL=C sed -e "s#$ROOT#<repo>#g" -e "s#$HOME#~#g" -E -e 's#/Users/[^/ ]+#/Users/<user>#g' "$LOG" >"$OUT/build.log"

DIRTY=false
[ -n "$(git status --porcelain)" ] && DIRTY=true
GIT_COMMIT="$(git rev-parse HEAD)"
cat >"$OUT/metadata.json" <<JSON
{
  "version": "$VERSION",
  "build": "$BUILD",
  "bundleId": "$APP_ID",
  "minimumMacOS": "$MIN_MAC",
  "gitCommit": "$GIT_COMMIT",
  "workingTreeDirty": $DIRTY,
  "xcodeVersion": "$(xcodebuild -version | tr '\n' ' ' | sed 's/ *$//')",
  "builtAtUTC": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "zip": "$ZIP_NAME",
  "sha256": "$SHA",
  "signingNote": "ad-hoc 簽章，沒有 Developer ID，沒有公證。Gatekeeper 會擋，使用者需要手動放行；輔助使用與藍牙權限要重新授權。"
}
JSON
cat >"$OUT/VERSION.txt" <<TXT
version: $VERSION
build: $BUILD
bundleId: $APP_ID
minimumMacOS: $MIN_MAC
gitCommit: $GIT_COMMIT
workingTreeDirty: $DIRTY
sha256: $SHA
TXT

echo
echo "完成："
for f in "$ZIP_NAME" "$ZIP_NAME.sha256" metadata.json validation-report.md build.log VERSION.txt; do
  echo "  $OUT/$f"
done
[ "$SMOKE_FAIL" -eq 0 ] || { echo "啟動煙霧測試失敗" >&2; exit 1; }
