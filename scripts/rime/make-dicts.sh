#!/usr/bin/env bash
# 產生 RIME 詞典：quick5.dict.yaml、cangjie5.dict.yaml（libcangjie + words.hk 字頻）。
# 用法：scripts/rime/make-dicts.sh [輸出資料夾]（預設 ime/rime）。需要先跑 scripts/rime/fetch.sh。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
OUT="${1:-ime/rime}"
SRC="build/rime/src"

mkdir -p "$SRC/unihan"
unzip -o -q "$SRC/Unihan-18.0.0.zip" Unihan_Readings.txt -d "$SRC/unihan"

env -u SDKROOT swift run -c release --package-path scripts/rime/ImeDataTools make-ime-dicts \
  --src "$SRC" --wordshk ime/sources/wordshk --out "$OUT" --lock scripts/rime/versions.lock
