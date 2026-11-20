#!/usr/bin/env bash
# Xcode build phase of RemoteKeyboardExtension: builds the Rime data (build-data.sh) and copies it into the keyboard
# bundle as rime/shared (scheme sources) and rime/shared/build (prebuilt tables).
# Both the keyboard and the app run it: with the argument "licenses" (app) it only copies the licence texts
# (RIME-LICENSES.txt, LICENSE-data.txt) into the bundle's resources root; without it also builds and copies the data.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
mode="${1:-all}"
: "${TARGET_BUILD_DIR:?run from an Xcode build phase}" "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
res="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
if [ ! -f "$root/build/rime/RIME-LICENSES.txt" ]; then
    echo "error: 先執行 scripts/rime/build-xcframework.sh（會產生 build/rime/RIME-LICENSES.txt）" >&2
    exit 1
fi
mkdir -p "$res"
cp "$root/build/rime/RIME-LICENSES.txt" "$root/ime/rime/LICENSE-data.txt" "$res/"
[ "$mode" != licenses ] || { echo "rime licences copied to $res"; exit 0; }
if [ ! -x "$root/build/rime/bin/rime_deployer" ] || [ ! -d "$root/Packages/RimeEngine/Artifacts/RimeC.xcframework" ]; then
    echo "error: 先執行 scripts/rime/fetch.sh 與 build-xcframework.sh" >&2
    exit 1
fi
: "${DERIVED_FILE_DIR:?run from an Xcode build phase}"
data="$DERIVED_FILE_DIR/rime-data"
dest="$res/rime/shared"
"$root/scripts/rime/build-data.sh" "$data"
rm -rf "$dest"
mkdir -p "$dest"
cp -R "$data"/. "$dest"/
echo "rime data copied to $dest"
