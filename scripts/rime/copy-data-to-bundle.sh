#!/usr/bin/env bash
# Xcode build phase of RemoteKeyboardExtension: builds the Rime data (build-data.sh) and copies it into the keyboard
# bundle as rime/shared (scheme sources) and rime/shared/build (prebuilt tables).
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
if [ ! -x "$root/build/rime/bin/rime_deployer" ] || [ ! -d "$root/Packages/RimeEngine/Artifacts/RimeC.xcframework" ]; then
    echo "error: 先執行 scripts/rime/fetch.sh 與 build-xcframework.sh" >&2
    exit 1
fi
: "${DERIVED_FILE_DIR:?run from an Xcode build phase}" "${TARGET_BUILD_DIR:?}" "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
data="$DERIVED_FILE_DIR/rime-data"
dest="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/rime/shared"
"$root/scripts/rime/build-data.sh" "$data"
rm -rf "$dest"
mkdir -p "$dest"
cp -R "$data"/. "$dest"/
echo "rime data copied to $dest"
