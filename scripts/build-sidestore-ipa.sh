#!/usr/bin/env bash
# 建置給 SideStore 用的 IPA：Release、無發佈簽章，只用 ad-hoc 簽章寫入 entitlements。
set -euo pipefail

FORCE=0
usage() {
  cat <<USAGE
用法：scripts/build-sidestore-ipa.sh [--force] [-h]

  --force   輸出資料夾已存在時覆蓋

輸出：release/sidestore/v<版本>-b<build>/（IPA、.sha256、build.log、metadata.json、validation-report.md）
USAGE
}
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "不認得的參數：$1" >&2; usage >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MISSING=()
for t in xcodebuild xcodegen pod codesign plutil ditto shasum lipo git; do
  command -v "$t" >/dev/null 2>&1 || MISSING+=("$t")
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "缺少工具：${MISSING[*]}" >&2
  exit 1
fi

# 隨版本附上的文件來源缺了就先停，不浪費一次建置。
GUIDE_SRC="docs/distribution/sidestore-install-guide.md"
PLAN_SRC="docs/distribution/sidestore-test-plan.md"
for f in "$GUIDE_SRC" "$PLAN_SRC"; do
  [ -f "$f" ] || { echo "找不到文件來源：$f" >&2; exit 1; }
done

xcodegen generate
LANG=en_US.UTF-8 pod install

# 封存前先讀版本，輸出資料夾已存在時不必建置；封存後再核對 app 內的值。
SETTINGS="$(xcodebuild -showBuildSettings -workspace RemoteKeyboard.xcworkspace -scheme RemoteKeyboardApp -configuration Release 2>/dev/null)"
EARLY_VERSION="$(echo "$SETTINGS" | awk '$1=="MARKETING_VERSION"{print $3; exit}')"
EARLY_BUILD="$(echo "$SETTINGS" | awk '$1=="CURRENT_PROJECT_VERSION"{print $3; exit}')"
if [ -z "$EARLY_VERSION" ] || [ -z "$EARLY_BUILD" ]; then
  echo "讀不到 MARKETING_VERSION 或 CURRENT_PROJECT_VERSION" >&2
  exit 1
fi
EARLY_OUT="release/sidestore/v${EARLY_VERSION}-b${EARLY_BUILD}"
if [ -e "$EARLY_OUT" ] && [ "$FORCE" -ne 1 ]; then
  echo "輸出資料夾已存在：$EARLY_OUT（要覆蓋請加 --force）" >&2
  exit 1
fi

# 只清這次建置的暫存資料夾。
TMP="build/sidestore"
rm -rf "$TMP"
mkdir -p "$TMP"
ARCHIVE="$TMP/RemoteKeyboard.xcarchive"
LOG="$TMP/build.log"

echo "封存 Release（無簽章），記錄檔：$LOG"
if ! xcodebuild archive -workspace RemoteKeyboard.xcworkspace -scheme RemoteKeyboardApp \
    -configuration Release -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$LOG"; then
  echo "封存失敗，記錄檔：$LOG" >&2
  exit 1
fi

APP="$(find "$ARCHIVE/Products/Applications" -mindepth 1 -maxdepth 1 -name '*.app' 2>/dev/null | head -n 1)"
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  echo "封存裡找不到 .app：$ARCHIVE/Products/Applications" >&2
  exit 1
fi

plist() { plutil -extract "$2" raw -o - "$1"; }
VERSION="$(plist "$APP/Info.plist" CFBundleShortVersionString)"
BUILD="$(plist "$APP/Info.plist" CFBundleVersion)"
APP_ID="$(plist "$APP/Info.plist" CFBundleIdentifier)"
MIN_IOS="$(plist "$APP/Info.plist" MinimumOSVersion)"
APPEX="$(find "$APP/PlugIns" -mindepth 1 -maxdepth 1 -name '*.appex' | head -n 1)"
EXT_ID="$(plist "$APPEX/Info.plist" CFBundleIdentifier)"

if [ "$VERSION" != "$EARLY_VERSION" ] || [ "$BUILD" != "$EARLY_BUILD" ]; then
  echo "app 內的版本 v${VERSION}-b${BUILD} 與建置設定 v${EARLY_VERSION}-b${EARLY_BUILD} 不一致" >&2
  exit 1
fi
OUT="$EARLY_OUT"

IPA_NAME="RemoteKeyboard-v${VERSION}-unsigned.ipa"
STAGE="$TMP/stage"
mkdir -p "$STAGE/Payload"
ditto "$APP" "$STAGE/Payload/$(basename "$APP")"
PAYLOAD_APP="$STAGE/Payload/$(basename "$APP")"

# 清掉不屬於發佈內容的東西。
find "$PAYLOAD_APP" \( -name '*.dSYM' -o -name '*.swiftmodule' -o -name '*.swiftdoc' \
  -o -name '*.bcsymbolmap' -o -name '.DS_Store' \) -prune -exec rm -rf {} +
if [ -d "$PAYLOAD_APP/PlugIns" ]; then
  find "$PAYLOAD_APP/PlugIns" -mindepth 1 -maxdepth 1 ! -name '*.appex' -exec rm -rf {} +
fi
# 避免 ditto 產生 __MACOSX 項目。
xattr -cr "$STAGE/Payload" 2>/dev/null || true

# ad-hoc 簽章，由內而外。SideStore 從簽章讀出要申請的 entitlements，沒有簽章就不會申請 App Group。
sign() { codesign --force --sign - --timestamp=none "$@"; }
PAYLOAD_APPEX="$(find "$PAYLOAD_APP/PlugIns" -mindepth 1 -maxdepth 1 -name '*.appex' | head -n 1)"
for d in "$PAYLOAD_APPEX/Frameworks" "$PAYLOAD_APP/Frameworks"; do
  [ -d "$d" ] || continue
  while IFS= read -r item; do sign "$item"; done < <(find "$d" -mindepth 1 -maxdepth 1 | sort)
done
sign --entitlements iOS/RemoteKeyboardExtension/RemoteKeyboardExtension.entitlements "$PAYLOAD_APPEX"
sign --entitlements iOS/RemoteKeyboardApp/RemoteKeyboardApp.entitlements "$PAYLOAD_APP"

# 打包：zip 根目錄是 Payload/。不用 --sequesterRsrc：它會把 xattr 寫成 __MACOSX/ 項目，弄髒根目錄。
(cd "$STAGE" && ditto -c -k --norsrc --noextattr --keepParent Payload "$IPA_NAME")
if unzip -Z1 "$STAGE/$IPA_NAME" | grep -v '^Payload/' | grep -q .; then
  echo "IPA 根目錄含 Payload/ 以外的項目" >&2
  exit 1
fi
(cd "$STAGE" && shasum -a 256 "$IPA_NAME" >"$IPA_NAME.sha256")
SHA="$(awk '{print $1}' "$STAGE/$IPA_NAME.sha256")"

# 先在暫存區驗證，通過才放進輸出資料夾。
if ! scripts/validate-ipa.sh "$STAGE/$IPA_NAME" --expect-bundle-id "$APP_ID" \
    --expect-version "$VERSION" --expect-build "$BUILD" --expect-min-ios "$MIN_IOS" \
    --report "$STAGE/validation-report.md"; then
  echo "驗證沒有通過，不產生輸出資料夾。暫存：$STAGE" >&2
  exit 1
fi

[ -e "$OUT" ] && rm -rf "$OUT"
mkdir -p "$OUT"
mv "$STAGE/$IPA_NAME" "$STAGE/$IPA_NAME.sha256" "$STAGE/validation-report.md" "$OUT/"

# 記錄檔去掉個人路徑。
LC_ALL=C sed -e "s#$ROOT#<repo>#g" -e "s#$HOME#~#g" -E -e 's#/Users/[^/ ]+#/Users/<user>#g' "$LOG" >"$OUT/build.log"

DIRTY=false
[ -n "$(git status --porcelain)" ] && DIRTY=true
cat >"$OUT/metadata.json" <<JSON
{
  "version": "$VERSION",
  "build": "$BUILD",
  "appBundleId": "$APP_ID",
  "extensionBundleId": "$EXT_ID",
  "minimumIOS": "$MIN_IOS",
  "gitCommit": "$(git rev-parse HEAD)",
  "workingTreeDirty": $DIRTY,
  "xcodeVersion": "$(xcodebuild -version | tr '\n' ' ' | sed 's/ *$//')",
  "builtAtUTC": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "ipa": "$IPA_NAME",
  "sha256": "$SHA",
  "signingNote": "unsigned 指沒有發佈簽章；app 與 appex 只有 ad-hoc 簽章，用來讓 SideStore 讀到要申請的 entitlements，由測試者重新簽章。"
}
JSON

GIT_COMMIT="$(git rev-parse HEAD)"
cat >"$OUT/VERSION.txt" <<TXT
version: $VERSION
build: $BUILD
appBundleId: $APP_ID
extensionBundleId: $EXT_ID
minimumIOS: $MIN_IOS
gitCommit: $GIT_COMMIT
workingTreeDirty: $DIRTY
sha256: $SHA
TXT

NOTES_SRC="release-notes/v${VERSION}-b${BUILD}.md"
if [ -f "$NOTES_SRC" ]; then
  cp "$NOTES_SRC" "$OUT/RELEASE-NOTES.md"
else
  printf '# v%s (build %s)\n\n## 本版變更\n\n尚未填寫\n' "$VERSION" "$BUILD" >"$OUT/RELEASE-NOTES.md"
  echo "警告：沒有 $NOTES_SRC，RELEASE-NOTES.md 是空白草稿" >&2
fi
cp "$GUIDE_SRC" "$OUT/INSTALL-GUIDE.md"
cp docs/distribution/privacy-note.md "$OUT/PRIVACY-NOTE.md"
cp docs/distribution/risk-note.md "$OUT/RISK-NOTE.md"
# 第三方授權全文隨成品提供：CocoaPods 彙整的授權、ML Kit 的 NOTICES、速成字碼表授權。
{
  cat "Pods/Target Support Files/Pods-RemoteKeyboardApp/Pods-RemoteKeyboardApp-acknowledgements.markdown"
  printf '\n\n# Google ML Kit NOTICES\n\n'
  cat Pods/MLKitDigitalInkRecognition/NOTICES
  printf '\n\n# 速成字碼表\n\n'
  cat iOS/RemoteKeyboardExtension/Resources/quick-table-LICENSE.txt
} >"$OUT/THIRD-PARTY-NOTICES.txt"
sed -e "s#^| 版本 | .*#| 版本 | v${VERSION} (build ${BUILD}) |#" \
    -e "s#^| IPA SHA-256 | .*#| IPA SHA-256 | ${SHA} |#" "$PLAN_SRC" >"$OUT/TEST-CHECKLIST.md"

echo
echo "完成："
echo "  $OUT/$IPA_NAME"
echo "  $OUT/$IPA_NAME.sha256"
echo "  $OUT/metadata.json"
echo "  $OUT/validation-report.md"
echo "  $OUT/build.log"
echo "  $OUT/VERSION.txt"
echo "  $OUT/RELEASE-NOTES.md"
echo "  $OUT/INSTALL-GUIDE.md"
echo "  $OUT/THIRD-PARTY-NOTICES.txt"
echo "  $OUT/PRIVACY-NOTE.md"
echo "  $OUT/RISK-NOTE.md"
echo "  $OUT/TEST-CHECKLIST.md"
