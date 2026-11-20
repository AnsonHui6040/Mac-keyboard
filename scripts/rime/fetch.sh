#!/usr/bin/env bash
# 依 versions.lock 下載原始碼到 build/rime/src/，逐一核對 SHA-256。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
LOCK="${RIME_LOCK:-scripts/rime/versions.lock}"
DEST="build/rime/src"
mkdir -p "$DEST"

fname() {
  case "$1" in
    librime)          echo "librime-$2.tar.gz" ;;
    boost)            echo "boost-$2.tar.bz2" ;;
    leveldb)          echo "leveldb-$2.tar.gz" ;;
    marisa-trie)      echo "marisa-trie-$2.tar.gz" ;;
    yaml-cpp)         echo "yaml-cpp-$2.tar.gz" ;;
    opencc)           echo "opencc-$2.tar.gz" ;;
    libcangjie-table) echo "libcangjie-table.txt" ;;
    *)                echo "$1-$2.src" ;;
  esac
}

fail=0
while read -r name version url sha || [ -n "${name:-}" ]; do
  if [ -z "${name:-}" ]; then continue; fi
  case "$name" in \#*) continue ;; esac
  f="$DEST/$(fname "$name" "$version")"
  if [ -f "$f" ] && [ "$(shasum -a 256 "$f" | cut -d' ' -f1)" = "$sha" ]; then
    echo "ok     $name $version (cached)"
    continue
  fi
  echo "fetch  $name $version"
  if ! curl -fsSL --retry 3 -o "$f.part" "$url" </dev/null; then
    echo "FAIL   $name: download error" >&2; rm -f "$f.part"; fail=1; continue
  fi
  got="$(shasum -a 256 "$f.part" | cut -d' ' -f1)"
  if [ "$got" != "$sha" ]; then
    echo "FAIL   $name: sha256 mismatch (expected $sha, got $got)" >&2
    rm -f "$f.part"; fail=1; continue
  fi
  mv "$f.part" "$f"
done < "$LOCK"

[ "$fail" -eq 0 ] || exit 1
echo "fetch: all verified"
