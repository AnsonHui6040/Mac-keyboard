#!/usr/bin/env bash
# 建置 Mac Receiver 並安裝到「應用程式」資料夾。
set -euo pipefail

CONFIG="Debug"
BUILD=1
APP_NAME="MacReceiver"
DISPLAY_NAME="Remote Keyboard Receiver"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
CACHE_DIR="$HOME/Library/Caches/RemoteKeyboard"
DERIVED="$CACHE_DIR/mac-dd"
LOG="$CACHE_DIR/build.log"

usage() {
  cat <<USAGE
用法：scripts/install-mac-receiver.sh [--configuration Debug|Release] [--no-build] [-h]

  --configuration  建置組態，預設 Debug（T16 G2 驗證 burst 需要 Debug 的除錯區）
  --no-build       不建置，只複製已建置的產物
  -h, --help       顯示這段說明

安裝位置：/Applications/${DISPLAY_NAME}.app（執行檔仍為 ${APP_NAME}）；該資料夾不可寫時改用 \$HOME/Applications。
面板顯示名稱：${DISPLAY_NAME}
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --configuration)
      [ $# -ge 2 ] || { echo "--configuration 需要參數" >&2; exit 2; }
      CONFIG="$2"; shift 2 ;;
    --no-build) BUILD=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "不認得的參數：$1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$CONFIG" in
  Debug|Release) ;;
  *) echo "--configuration 只接受 Debug 或 Release" >&2; exit 2 ;;
esac

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$CACHE_DIR"

if [ "$BUILD" -eq 1 ]; then
  if [ ! -d RemoteKeyboard.xcworkspace ]; then
    echo "找不到 RemoteKeyboard.xcworkspace，先產生專案"
    xcodegen generate
    LANG=en_US.UTF-8 pod install
  fi
  echo "建置 ${APP_NAME}（${CONFIG}），記錄檔：$LOG"
  if ! xcodebuild build -workspace RemoteKeyboard.xcworkspace -scheme "$APP_NAME" \
      -configuration "$CONFIG" -derivedDataPath "$DERIVED" -allowProvisioningUpdates \
      >"$LOG" 2>&1; then
    echo "建置失敗，記錄檔最後 30 行：" >&2
    tail -n 30 "$LOG" >&2
    exit 1
  fi
fi

SRC="$DERIVED/Build/Products/$CONFIG/${APP_NAME}.app"
if [ ! -d "$SRC" ]; then
  echo "找不到建置產物：$SRC（請先不帶 --no-build 執行一次）" >&2
  exit 1
fi

if [ -w /Applications ]; then
  DEST_DIR="/Applications"
else
  DEST_DIR="$HOME/Applications"
  mkdir -p "$DEST_DIR"
  echo "/Applications 不可寫，改裝到 $DEST_DIR"
fi
DEST="$DEST_DIR/${DISPLAY_NAME}.app"
OLD_DEST="$DEST_DIR/${APP_NAME}.app"

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  pkill -x "$APP_NAME" || true
  for _ in $(seq 1 25); do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
    sleep 0.2
  done
  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "${APP_NAME} 5 秒內沒有結束，請手動結束後再執行" >&2
    exit 1
  fi
fi

if [ -d "$OLD_DEST" ]; then
  "$LSREGISTER" -u "$OLD_DEST" >/dev/null 2>&1 || true
  rm -rf "$OLD_DEST"
  echo "已移除舊名稱的版本：$OLD_DEST"
fi

rm -rf "$DEST"
ditto "$SRC" "$DEST"
echo "已安裝到：$DEST"

# 取消登記 build 產物，避免 Launchpad / Spotlight 出現重複的 MacReceiver。
"$LSREGISTER" -u "$SRC" >/dev/null 2>&1 || true

open "$DEST"
VERSION="$(stat -f '%Sm' -t '%m/%d %H:%M' "$DEST/Contents/MacOS/$APP_NAME")"
echo "版本（執行檔修改時間）：$VERSION"

cat <<MSG

第一次從這個位置開啟時，請到 系統設定 › 隱私權與安全性 › 輔助使用，重新允許「${DISPLAY_NAME}」（舊的項目可以移除）。
藍牙同理：到 系統設定 › 隱私權與安全性 › 藍牙，重新允許「${DISPLAY_NAME}」。
MSG
