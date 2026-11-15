#!/usr/bin/env bash
# Measures trackpad timing against a Windows or Linux receiver without any manual step: the iPhone draws fixed strokes on the
# Remote Keyboard trackpad (TrackpadSmokeUITests/testFixedStrokes), then the receiver's timing summary lines (pointer_timing*,
# ble_rx_timing, portal_motion_timing) are pulled over ssh, filtered to the run and aggregated by timing_report.py.
#
#   e2e/scripts/measure-trackpad.sh <win|linux> [N]
#
# N is the number of strokes (default 20). Environment:
#   RK_IPHONE_UDID   iPhone UDID (default: the first connected device in `xcrun devicectl list devices`)
#   RK_SSH_WIN       ssh host name of the Windows machine (default rk-win)
#   RK_SSH_LINUX     ssh host name of the Linux machine (default rk-linux)
#   RK_HOST_NAME     the computer's name as the iPhone lists it under 已配對電腦 (linux default: Linux; win: required)
#   RK_LABEL         label added to the result file name, for example before or after
# The Mac receiver app is quit for the run (it would compete for the iPhone's link) and opened again on every exit path.
# The receiver's UTC clock is read over ssh first and its difference to this Mac is applied to the time window.
#
# The test reads RK_STROKE_COUNT and PairingUITests reads RK_SELECT_HOST from the test process environment. xcodebuild forwards
# only environment variables of its own process that start with TEST_RUNNER_, so they are set that way here.
# The result is written to e2e/results/<date>-trackpad-<target>[-<label>].txt (not committed): the aggregated table, then the
# raw timing lines (numbers only). Nothing typed or any pointer displacement is read or stored.
#
# Needs: the receiver armed with 「允許觸控板控制」 on and the iPhone paired with it; Remote Keyboard selected as the keyboard;
# the iPhone unlocked.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="${1:-}"
COUNT="${2:-20}"

case "$TARGET" in
  win|linux) ;;
  -h|--help|"") sed -n '2,21p' "${BASH_SOURCE[0]}"; [ -n "$TARGET" ] && exit 0; exit 2 ;;
  *) echo "target must be win or linux" >&2; exit 2 ;;
esac
case "$COUNT" in
  ''|*[!0-9]*|0) echo "N must be a positive whole number" >&2; exit 2 ;;
esac

WIN_HOST="${RK_SSH_WIN:-rk-win}"
LINUX_HOST="${RK_SSH_LINUX:-rk-linux}"
LABEL="$(printf '%s' "${RK_LABEL:-}" | tr -c 'A-Za-z0-9._-' '_')"
MAC_RECEIVER_APP="/Applications/Remote Keyboard Receiver.app"

case "$TARGET" in
  win)
    SSH_HOST="$WIN_HOST"
    HOST_NAME="${RK_HOST_NAME:-}"
    if [ -z "$HOST_NAME" ]; then
      echo "RK_HOST_NAME is required for win: the Windows computer's name as listed on the iPhone under 已配對電腦" >&2
      exit 2
    fi
    ;;
  linux)
    SSH_HOST="$LINUX_HOST"
    HOST_NAME="${RK_HOST_NAME:-Linux}"
    ;;
esac

UDID="${RK_IPHONE_UDID:-}"
if [ -z "$UDID" ]; then
  UDID="$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone.*physical/ && !/Watch/ && /available|connected/ {for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-Fa-f]{8}-[0-9A-Fa-f-]{27}$|^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}$/) { print $i; exit }}')"
fi
if [ -z "$UDID" ]; then
  echo "no iPhone found: connect it or set RK_IPHONE_UDID (xcrun devicectl list devices)" >&2
  exit 3
fi

WORKSPACE="$REPO_ROOT/RemoteKeyboard.xcworkspace"
if [ ! -d "$WORKSPACE" ]; then
  echo "RemoteKeyboard.xcworkspace is missing: run xcodegen generate and LANG=en_US.UTF-8 pod install first" >&2
  exit 3
fi

RESULTS_DIR="$REPO_ROOT/e2e/results"
mkdir -p "$RESULTS_DIR"
BASE="$RESULTS_DIR/$(date +%Y-%m-%d)-trackpad-$TARGET${LABEL:+-$LABEL}"
OUT="$BASE.txt"
n=2
while [ -e "$OUT" ]; do OUT="$BASE-$n.txt"; n=$((n + 1)); done

XLOG_SELECT="$(mktemp -t rk-trackpad-select)"
XLOG_RUN="$(mktemp -t rk-trackpad-run)"
RAW="$(mktemp -t rk-trackpad-raw)"
KEPT="$(mktemp -t rk-trackpad-kept)"

restore_mac_receiver() {
  rm -f "$XLOG_SELECT" "$XLOG_RUN" "$RAW" "$KEPT"
  open -a "$MAC_RECEIVER_APP" >/dev/null 2>&1 || echo "WARNING: could not reopen $MAC_RECEIVER_APP" >&2
}
trap restore_mac_receiver EXIT

# The receiver's clock against this Mac's (mid-point of the ssh round trip).
case "$TARGET" in
  win)   REMOTE_CLOCK='powershell -NoProfile -Command "[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()"' ;;
  linux) REMOTE_CLOCK='date -u +%s' ;;
esac
LOCAL_BEFORE=$(date -u +%s)
REMOTE_EPOCH="$(ssh -n -o ConnectTimeout=10 -o BatchMode=yes -- "$SSH_HOST" "$REMOTE_CLOCK" 2>/dev/null | tr -d '\r' | tail -1)"
LOCAL_AFTER=$(date -u +%s)
case "$REMOTE_EPOCH" in
  ''|*[!0-9]*) echo "cannot read the receiver's clock over ssh ($SSH_HOST); nothing was run" >&2; exit 5 ;;
esac
CLOCK_OFFSET=$(( REMOTE_EPOCH - (LOCAL_BEFORE + LOCAL_AFTER) / 2 ))
echo "target=$TARGET host=\"$HOST_NAME\" strokes=$COUNT receiver_clock_offset_s=$CLOCK_OFFSET iphone=$UDID"

# The Mac receiver would hold the iPhone's link: quit it (the EXIT trap opens it again) and make sure the process is gone.
osascript -e 'quit app "Remote Keyboard Receiver"' >/dev/null 2>&1 || true
for _ in $(seq 1 20); do
  pgrep -f "Remote Keyboard Receiver.app/" >/dev/null 2>&1 || break
  sleep 0.5
done
if pgrep -f "Remote Keyboard Receiver.app/" >/dev/null 2>&1; then
  pkill -f "Remote Keyboard Receiver.app/" >/dev/null 2>&1 || true
  sleep 1
  if pgrep -f "Remote Keyboard Receiver.app/" >/dev/null 2>&1; then
    echo "the Mac receiver app is still running; quit it by hand and run again" >&2
    exit 3
  fi
fi

TEST_RUNNER_RK_SELECT_HOST="$HOST_NAME" xcodebuild test -workspace "$WORKSPACE" -scheme RemoteKeyboardApp \
  -destination "id=$UDID" -allowProvisioningUpdates \
  -only-testing:RemoteKeyboardUITests/PairingUITests/testSelectComputer >"$XLOG_SELECT" 2>&1 </dev/null
SELECT_STATUS=$?
grep -E "TEST (SUCCEEDED|FAILED)|Test Case .* (passed|failed)" "$XLOG_SELECT" | tail -3
if [ "$SELECT_STATUS" -ne 0 ]; then
  echo "selecting \"$HOST_NAME\" on the iPhone failed (xcodebuild exit $SELECT_STATUS); no strokes were drawn" >&2
  grep -E "error:|XCTAssert|RK_SELECT_HOST|no row contains" "$XLOG_SELECT" | head -5 >&2
  exit 3
fi

TEST_RUNNER_RK_STROKE_COUNT="$COUNT" xcodebuild test -workspace "$WORKSPACE" -scheme RemoteKeyboardApp \
  -destination "id=$UDID" -allowProvisioningUpdates \
  -only-testing:RemoteKeyboardUITests/TrackpadSmokeUITests/testFixedStrokes >"$XLOG_RUN" 2>&1 </dev/null
RUN_STATUS=$?
grep -E "TEST (SUCCEEDED|FAILED)|Test Case .* (passed|failed)" "$XLOG_RUN" | tail -3

RKTP="$(grep -h "RKTP strokes=" "$XLOG_RUN" | tail -1)"
if [ -z "$RKTP" ]; then
  echo "no RKTP line in the test output (xcodebuild exit $RUN_STATUS): the strokes did not run; is the pad ready and the receiver connected?" >&2
  grep -E "error:|XCTSkip|skipped|did not become usable|never reported ready" "$XLOG_RUN" | head -5 >&2
  exit 4
fi
RAN="$(printf '%s\n' "$RKTP" | sed -E 's/.* strokes=([0-9]+) .*/\1/')"
T_START="$(printf '%s\n' "$RKTP" | sed -E 's/.* start=([^ ]+) .*/\1/')"
T_END="$(printf '%s\n' "$RKTP" | sed -E 's/.* end=([^ ]+).*/\1/')"

sleep 2

# Receiver log lines of the three timing events, from the newest few log files; the time window is applied locally.
case "$TARGET" in
  win)
    FETCH='powershell -NoProfile -Command "Get-ChildItem (Join-Path $env:LOCALAPPDATA '"'"'RemoteKeyboard\logs'"'"') -Filter '"'"'*.log'"'"' | Sort-Object LastWriteTime -Descending | Select-Object -First 3 | ForEach-Object { Select-String -Path $_.FullName -Pattern '"'"'ev=pointer_timing'"'"','"'"'ev=ble_rx_timing'"'"','"'"'ev=portal_motion_timing'"'"' | ForEach-Object { $_.Line } }"'
    ssh -n -o ConnectTimeout=10 -o BatchMode=yes -- "$SSH_HOST" "$FETCH" 2>/dev/null | tr -d '\r' >"$RAW"
    SSH_STATUS=${PIPESTATUS[0]}
    ;;
  linux)
    ssh -o ConnectTimeout=10 -o BatchMode=yes -- "$SSH_HOST" 'sh -s' >"$RAW" 2>/dev/null <<'REMOTE'
d="${XDG_STATE_HOME:-$HOME/.local/state}/remote-keyboard/logs"
for f in $(ls -t "$d"/*.log 2>/dev/null | head -3); do
  grep -a -h -e 'ev=pointer_timing' -e 'ev=ble_rx_timing' -e 'ev=portal_motion_timing' "$f"
done
exit 0
REMOTE
    SSH_STATUS=$?
    ;;
esac
if [ "$SSH_STATUS" -ne 0 ]; then
  echo "could not read the receiver's log over ssh ($SSH_HOST, exit $SSH_STATUS)" >&2
  exit 5
fi

python3 "$SCRIPT_DIR/timing_report.py" --from "$T_START" --to "$T_END" --offset-s "$CLOCK_OFFSET" --grace-s 2 --print-lines <"$RAW" >"$KEPT"
KEPT_LINES="$(wc -l <"$KEPT" | tr -d ' ')"

{
  echo "# measure-trackpad target=$TARGET host=\"$HOST_NAME\"${LABEL:+ label=$LABEL} strokes_asked=$COUNT strokes_drawn=$RAN window=$T_START..$T_END (Mac clock) receiver_clock_offset_s=$CLOCK_OFFSET xcodebuild_exit=$RUN_STATUS timing_lines=$KEPT_LINES"
  echo
  echo "## Aggregated"
  python3 "$SCRIPT_DIR/timing_report.py" <"$KEPT"
  echo "## Raw timing lines (numbers only)"
  cat "$KEPT"
} >"$OUT"

cat "$OUT"
echo "saved $OUT"

if [ "$RAN" -ne "$COUNT" ]; then
  echo "WARNING: $RAN strokes were drawn, $COUNT were asked for" >&2
  exit 4
fi
if [ "$KEPT_LINES" -eq 0 ]; then
  echo "WARNING: no timing lines on the receiver in the run window; check the receiver build, the clock offset and the pairing" >&2
  exit 6
fi
exit "$RUN_STATUS"
