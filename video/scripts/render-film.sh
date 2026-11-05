#!/usr/bin/env bash
# Renders ProductFilm, then masters its sound: the video stream is copied, the audio gets a gain and a limiter until the
# final file measures about -14 LUFS (+-1) and at most -1.0 dBTP with ebur128. Run from anywhere: it works in video/.
set -euo pipefail
cd "$(dirname "$0")/.."

RAW=out/renders/product-film-raw.mp4
OUT=out/renders/product-film.mp4
TARGET=${TARGET_LUFS:--14}
TOL=0.4
CEIL=-1.0
mkdir -p out/renders

npx kinetograph render src/index.tsx --comp ProductFilm -o "$RAW" --concurrency 4

# prints: integrated LUFS, true peak dBTP
measure() {
  ffmpeg -hide_banner -nostats -i "$1" -vn -af ebur128=peak=true -f null - 2>&1 |
    awk '/^ +I:/ { i = $2 } /^ +Peak:/ { p = $2 } END { print i, p }'
}
db_to_lin() { awk -v d="$1" 'BEGIN { printf "%.5f", 10 ^ (d / 20) }'; }

read -r raw_i raw_tp <<<"$(measure "$RAW")"
echo "raw:   $raw_i LUFS, true peak $raw_tp dBTP"

gain=$(awk -v t="$TARGET" -v i="$raw_i" 'BEGIN { print t - i }')
limit_db=-1.6
for pass in 1 2 3 4 5 6 7 8; do
  ffmpeg -hide_banner -loglevel error -y -i "$RAW" -c:v copy \
    -af "volume=${gain}dB,alimiter=limit=$(db_to_lin "$limit_db"):attack=3:release=60:level=0" \
    -c:a aac -b:a 320k -movflags +faststart "$OUT"
  read -r i tp <<<"$(measure "$OUT")"
  echo "pass $pass: gain ${gain} dB, limit ${limit_db} dB -> $i LUFS, true peak $tp dBTP"
  ok_i=$(awk -v i="$i" -v t="$TARGET" -v tol="$TOL" 'BEGIN { d = i - t; print (d < tol && d > -tol) ? 1 : 0 }')
  ok_tp=$(awk -v p="$tp" -v c="$CEIL" 'BEGIN { print (p <= c) ? 1 : 0 }')
  if [ "$ok_i" = 1 ] && [ "$ok_tp" = 1 ]; then echo "mastered: $OUT"; exit 0; fi
  if [ "$ok_tp" = 0 ]; then limit_db=$(awk -v l="$limit_db" -v p="$tp" -v c="$CEIL" 'BEGIN { print l - (p - c) - 0.1 }'); fi
  gain=$(awk -v g="$gain" -v i="$i" -v t="$TARGET" 'BEGIN { print g + (t - i) }')
done
echo "could not reach $TARGET LUFS with a true peak of $CEIL dBTP or less" >&2
exit 1
