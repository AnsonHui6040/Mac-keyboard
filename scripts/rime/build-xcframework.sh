#!/usr/bin/env bash
# 建置 librime 靜態庫（iOS arm64、iOS 模擬器 arm64、macOS arm64）並合成 RimeC.xcframework。
# 同時產出 build/rime/bin/rime_deployer（macOS arm64）。
# marisa：只使用單獨建置的 marisa-trie 0.3.1；OpenCC 以 USE_SYSTEM_MARISA=ON 指向它，
# 因此 libRimeC.a 內只有一份 marisa。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
LOCK="${RIME_LOCK:-scripts/rime/versions.lock}"
SRC="$ROOT/build/rime/src"
WORK="$ROOT/build/rime/work"
OUT="$ROOT/Packages/RimeEngine/Artifacts/RimeC.xcframework"
JOBS="$(sysctl -n hw.ncpu)"

ver() {
  local v
  v="$(awk -v n="$1" '$1==n {print $2}' "$LOCK")"
  [ -n "$v" ] || { echo "versions.lock 缺少 $1" >&2; exit 1; }
  printf '%s\n' "$v"
}
LIBRIME_V="$(ver librime)"; BOOST_V="$(ver boost)"; LEVELDB_V="$(ver leveldb)"
MARISA_V="$(ver marisa-trie)"; YAML_V="$(ver yaml-cpp)"; OPENCC_V="$(ver opencc)"

command -v cmake >/dev/null || { echo "需要 cmake（brew install cmake）" >&2; exit 1; }

# ---- 先驗證原始碼（缺檔或雜湊不符就中止） ----
RIME_LOCK="$LOCK" "$ROOT/scripts/rime/fetch.sh"

# ---- 解壓縮與修補（只做一次） ----
EX="$WORK/src"
# 戳記 = lock 與 patches 的雜湊；任何一個改變就重新解壓縮
STAMP="$( { cat "$LOCK"; cat "$ROOT"/scripts/rime/patches/*.patch 2>/dev/null || true; } | shasum -a 256 | cut -d' ' -f1)"
if [ ! -f "$EX/.done" ] || [ "$(cat "$EX/.done")" != "$STAMP" ]; then
  echo "extract (lock stamp ${STAMP:0:12})"
  rm -rf "$EX"; mkdir -p "$EX"
  tar xzf "$SRC/librime-$LIBRIME_V.tar.gz"     -C "$EX"
  tar xzf "$SRC/leveldb-$LEVELDB_V.tar.gz"     -C "$EX"
  tar xzf "$SRC/marisa-trie-$MARISA_V.tar.gz"  -C "$EX"
  tar xzf "$SRC/yaml-cpp-$YAML_V.tar.gz"       -C "$EX"
  tar xzf "$SRC/opencc-$OPENCC_V.tar.gz"       -C "$EX"
  # Boost 只要標頭
  tar xjf "$SRC/boost-$BOOST_V.tar.bz2" -C "$EX" "boost_${BOOST_V//./_}/boost"
  for p in "$ROOT"/scripts/rime/patches/*.patch; do
    [ -f "$p" ] || continue
    echo "patch  $(basename "$p")"
    patch -p1 -d "$EX/librime-$LIBRIME_V" < "$p"
  done
  printf '%s' "$STAMP" > "$EX/.done"
fi
LIBRIME_SRC="$EX/librime-$LIBRIME_V"
LEVELDB_SRC="$EX/leveldb-$LEVELDB_V"
MARISA_SRC="$EX/marisa-trie-$MARISA_V"
YAML_SRC="$EX/yaml-cpp-yaml-cpp-$YAML_V"
OPENCC_SRC="$EX/OpenCC-ver.$OPENCC_V"
BOOST_INC="$EX/boost_${BOOST_V//./_}"
for d in "$LIBRIME_SRC" "$LEVELDB_SRC" "$MARISA_SRC" "$YAML_SRC" "$OPENCC_SRC" "$BOOST_INC/boost"; do
  [ -d "$d" ] || { echo "解壓縮後找不到 $d" >&2; exit 1; }
done

# ---- 合併授權檔（內容取自上面解壓縮的原始碼壓縮檔，不手打）→ build/rime/RIME-LICENSES.txt ----
LICENSES="$ROOT/build/rime/RIME-LICENSES.txt"
license_section() { # 名稱 版本 授權 說明
  printf '\n================================================================\n'
  printf '%s %s\n授權：%s\n' "$1" "$2" "$3"
  [ -z "${4:-}" ] || printf '%s\n' "$4"
  printf '================================================================\n\n'
}
{
  printf 'Remote Keyboard 內含的 librime 及其依賴，授權文字取自各自原始碼壓縮檔。\n'
  license_section librime "$LIBRIME_V" BSD-3-Clause
  cat "$LIBRIME_SRC/LICENSE"
  license_section Boost "$BOOST_V" BSL-1.0
  tar xjOf "$SRC/boost-$BOOST_V.tar.bz2" "boost_${BOOST_V//./_}/LICENSE_1_0.txt"
  license_section LevelDB "$LEVELDB_V" BSD-3-Clause
  cat "$LEVELDB_SRC/LICENSE"
  license_section marisa-trie "$MARISA_V" BSD-2-Clause "上游為 BSD-2-Clause 或 LGPL-2.1-or-later 雙授權；本專案選用 BSD-2-Clause。"
  sed -n '/^#### The BSD 2-clause license/,/^#### The LGPL/{/^#### The LGPL/d;p;}' "$MARISA_SRC/COPYING.md"
  license_section yaml-cpp "$YAML_V" MIT
  cat "$YAML_SRC/LICENSE"
  license_section OpenCC "$OPENCC_V" Apache-2.0 "OpenCC $OPENCC_V 的原始碼壓縮檔沒有 NOTICE 檔，因此沒有 NOTICE 內容可附。"
  cat "$OPENCC_SRC/LICENSE"
} > "$LICENSES"
echo "licenses: $LICENSES"
[ "${RIME_LICENSES_ONLY:-0}" != 1 ] || exit 0

build_slice() {
  local slice="$1" sysname="$2" sysroot="$3" deploy="$4"
  local w="$WORK/$slice" prefix="$WORK/$slice/prefix"
  echo "=== slice $slice ==="
  rm -rf "$w"; mkdir -p "$prefix"
  local common=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    -DCMAKE_OSX_ARCHITECTURES=arm64
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$deploy"
    -DCMAKE_OSX_SYSROOT="$sysroot"
    -DCMAKE_INSTALL_PREFIX="$prefix"
    -DCMAKE_PREFIX_PATH="$prefix"
    -DCMAKE_FIND_ROOT_PATH="$prefix"
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    -DBUILD_SHARED_LIBS=OFF
    -DCMAKE_CXX_STANDARD=17
    "-DCMAKE_CXX_FLAGS=-I$prefix/include -I$BOOST_INC"
    "-DCMAKE_C_FLAGS=-I$prefix/include"
  )
  if [ "$sysname" = iOS ]; then
    common+=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY)
  fi

  cmake -S "$LEVELDB_SRC" -B "$w/leveldb" "${common[@]}" \
    -DLEVELDB_BUILD_TESTS=OFF -DLEVELDB_BUILD_BENCHMARKS=OFF -DLEVELDB_INSTALL=ON \
    -DHAVE_CRC32C=0 -DHAVE_SNAPPY=0 -DHAVE_TCMALLOC=0
  cmake --build "$w/leveldb" -j "$JOBS"
  cmake --install "$w/leveldb"

  cmake -S "$MARISA_SRC" -B "$w/marisa" "${common[@]}" \
    -DENABLE_TOOLS=OFF -DBUILD_TESTING=OFF
  cmake --build "$w/marisa" -j "$JOBS"
  cmake --install "$w/marisa"

  cmake -S "$YAML_SRC" -B "$w/yaml-cpp" "${common[@]}" \
    -DYAML_CPP_BUILD_TESTS=OFF -DYAML_CPP_BUILD_TOOLS=OFF -DYAML_CPP_BUILD_CONTRIB=OFF \
    -DYAML_BUILD_SHARED_LIBS=OFF
  cmake --build "$w/yaml-cpp" -j "$JOBS"
  cmake --install "$w/yaml-cpp"

  # OpenCC：只建 libopencc 目標（字典資料要在主機執行 opencc_dict，交叉編譯用不到），
  # OPENCC_ENABLE_INSTALL=OFF 避免安裝 CLI 工具的規則讓 iOS configure 失敗
  cmake -S "$OPENCC_SRC" -B "$w/opencc" "${common[@]}" \
    -DOPENCC_ENABLE_INSTALL=OFF -DENABLE_GTEST=OFF -DENABLE_BENCHMARK=OFF \
    -DBUILD_OPENCC_JIEBA_PLUGIN=OFF -DUSE_SYSTEM_MARISA=ON
  cmake --build "$w/opencc" -j "$JOBS" --target libopencc
  mkdir -p "$prefix/include/opencc" "$prefix/lib"
  cp "$w/opencc/src/libopencc.a" "$prefix/lib/"
  cp "$OPENCC_SRC"/src/*.hpp "$OPENCC_SRC"/src/*.h "$prefix/include/opencc/"
  cp "$w/opencc/src/Opencc_Export.h" "$prefix/include/opencc/"
  [ -f "$prefix/include/opencc/Config.hpp" ] && [ -f "$prefix/include/opencc/Opencc_Export.h" ] \
    || { echo "OpenCC 標頭不完整" >&2; exit 1; }

  cmake -S "$LIBRIME_SRC" -B "$w/librime" "${common[@]}" \
    -DBUILD_STATIC=ON -DBUILD_TEST=OFF -DENABLE_LOGGING=OFF \
    -DBUILD_MERGED_PLUGINS=ON -DENABLE_EXTERNAL_PLUGINS=OFF -DBUILD_DATA=OFF \
    -DBUILD_SEPARATE_LIBS=OFF -DCMAKE_CXX_FLAGS="-I$prefix/include -I$BOOST_INC -DBOOST_DLL_USE_STD_FS"
  cmake --build "$w/librime" -j "$JOBS"

  mkdir -p "$w/merged"
  libtool -static -o "$w/merged/libRimeC.a" \
    "$w/librime/lib/librime.a" "$prefix/lib/libleveldb.a" "$prefix/lib/libmarisa.a" \
    "$prefix/lib/libyaml-cpp.a" "$prefix/lib/libopencc.a"
}

build_slice ios      iOS    iphoneos        18.0
build_slice ios-sim  iOS    iphonesimulator 18.0
build_slice macos    Darwin macosx          15.0

# ---- rime_deployer（macOS arm64）：BUILD_SHARED_LIBS=OFF 不建 tools，自行編譯 ----
mkdir -p "$ROOT/build/rime/bin"
MP="$WORK/macos/prefix"
clang++ -std=c++17 -O2 -arch arm64 -mmacosx-version-min=15.0 -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
  -DRIME_IMPORTS -DBOOST_DLL_USE_STD_FS \
  -I"$LIBRIME_SRC/src" -I"$WORK/macos/librime/src" -I"$LIBRIME_SRC/tools" -I"$LIBRIME_SRC/include" \
  -I"$MP/include" -I"$BOOST_INC" \
  "$LIBRIME_SRC/tools/rime_deployer.cc" "$WORK/macos/merged/libRimeC.a" \
  -o "$ROOT/build/rime/bin/rime_deployer"

# ---- libcangjie 表（已在 fetch 驗證）已在 build/rime/src/libcangjie-table.txt ----
[ -f "$SRC/libcangjie-table.txt" ] || { echo "缺少 $SRC/libcangjie-table.txt" >&2; exit 1; }

# ---- xcframework ----
HDR="$WORK/headers"; rm -rf "$HDR"; mkdir -p "$HDR"
cp "$LIBRIME_SRC"/src/rime_api.h "$LIBRIME_SRC"/src/rime_api_stdbool.h "$LIBRIME_SRC"/src/rime_api_deprecated.h \
   "$LIBRIME_SRC"/src/rime_levers_api.h "$HDR/"
cp "$ROOT/scripts/rime/module.modulemap" "$HDR/"
rm -rf "$OUT"; mkdir -p "$(dirname "$OUT")"
xcodebuild -create-xcframework \
  -library "$WORK/ios/merged/libRimeC.a"     -headers "$HDR" \
  -library "$WORK/ios-sim/merged/libRimeC.a" -headers "$HDR" \
  -library "$WORK/macos/merged/libRimeC.a"   -headers "$HDR" \
  -output "$OUT"
echo "built: $OUT"
