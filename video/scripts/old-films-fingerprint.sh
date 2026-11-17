#!/usr/bin/env bash
# Fingerprint of the existing films: sha256 of chosen still frames and of the audio analysis.
# Usage (from video/): bash scripts/old-films-fingerprint.sh <outdir>   -> <outdir>/fingerprint.txt
set -euo pipefail
out="${1:?usage: old-films-fingerprint.sh <outdir>}"
mkdir -p "$out/stills"
: > "$out/fingerprint.txt"
still() { # comp frame
  local png="$out/stills/$1-$2.png"
  npx kinetograph still src/index.tsx "$2" --comp "$1" -o "$png" >/dev/null
  echo "still $1 $2 $(shasum -a 256 "$png" | cut -d' ' -f1)" >> "$out/fingerprint.txt"
}
for f in 0 114 430 660 760 950 1100 1300 1514; do still ProductFilm "$f"; done
for f in 100 1000 1700; do still ProductIntro "$f"; done
for f in 5000 9000; do still Main "$f"; done
for c in ProductFilm ProductIntro Main; do
  json="$out/audio-$c.json"
  npx kinetograph audio analyze src/index.tsx --comp "$c" --json > "$json"
  h=$(node -e '
    const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const strip = (v) => Array.isArray(v) ? v.map(strip)
      : v && typeof v === "object" ? Object.fromEntries(Object.entries(v).filter(([k]) => k !== "entry").map(([k, x]) => [k, strip(x)]))
      : v;
    process.stdout.write(JSON.stringify(strip(j)));
  ' "$json" | shasum -a 256 | cut -d' ' -f1)
  echo "audio $c $h" >> "$out/fingerprint.txt"
done
wc -l "$out/fingerprint.txt"
