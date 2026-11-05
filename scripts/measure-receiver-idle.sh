#!/usr/bin/env bash
# 量測 Mac Receiver 閒置時的 CPU 用量。
set -euo pipefail

usage() {
  cat <<USAGE
用法：scripts/measure-receiver-idle.sh [秒數] [上限百分比]

  秒數         取樣時間，預設 30（每 2 秒取一次樣）
  上限百分比   平均 CPU 超過此值時以 1 結束，預設 5

找不到 MacReceiver 行程時以 2 結束。第一筆樣本固定為 0，會丟掉。
USAGE
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

SECONDS_TOTAL="${1:-30}"
LIMIT="${2:-5}"

PID="$(pgrep -x MacReceiver | head -1 || true)"
[ -n "$PID" ] || { echo "找不到 MacReceiver 行程" >&2; exit 2; }

# 第一筆樣本是 0，所以多取一筆。
COUNT=$(( SECONDS_TOTAL / 2 + 1 ))
[ "$COUNT" -ge 2 ] || COUNT=2

SAMPLES="$(top -l "$COUNT" -s 2 -pid "$PID" -stats cpu | awk '/^[0-9]+\.[0-9]+[[:space:]]*$/ { print $1 }' | tail -n +2)"
[ -n "$SAMPLES" ] || { echo "沒有取得樣本" >&2; exit 2; }

echo "MacReceiver (pid $PID) CPU %："
echo "$SAMPLES" | sed 's/^/  /'
echo "$SAMPLES" | awk -v limit="$LIMIT" '
  { sum += $1; if ($1 > max) max = $1; n++ }
  END {
    avg = sum / n
    printf "平均 %.1f%%，最大 %.1f%%，上限 %s%%\n", avg, max, limit
    exit (avg > limit) ? 1 : 0
  }'
