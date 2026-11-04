#!/usr/bin/env bash
# Copy the Noto Sans TC weights used by the video into public/fonts/.
set -u
cd "$(dirname "$0")/.."
src="$HOME/Library/Fonts"
files=(NotoSansTC-Regular.ttf NotoSansTC-Medium.ttf NotoSansTC-Bold.ttf)
missing=0
for f in "${files[@]}"; do
  if [ ! -f "$src/$f" ]; then
    echo "missing: $f (expected in $src)" >&2
    missing=1
  fi
done
[ "$missing" -eq 0 ] || exit 1
mkdir -p public/fonts
for f in "${files[@]}"; do
  cp "$src/$f" public/fonts/
  echo "copied: $f"
done
