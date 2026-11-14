#!/usr/bin/env bash
# Measures reconnect time against a Windows or Linux receiver: runs ReconnectUITests on the iPhone, then asks the
# receiver's own log for the numbers (rk-diag stats) and saves both sides into e2e/results/<date>-<target>.txt.
#
#   e2e/scripts/measure-reconnect.sh <win|linux> [N]
#
# N is the number of keyboard reopens (default 100). Environment:
#   RK_IPHONE_UDID   iPhone UDID (default: the first connected device in `xcrun devicectl list devices`)
#   RK_SSH_WIN       ssh host name of the Windows machine (default rk-win)
#   RK_SSH_LINUX     ssh host name of the Linux machine (default rk-linux)
#   RK_SINCE_SKEW_S  seconds to subtract from the start time when the receiver's clock runs behind (default 0)
#
# The test reads RK_REOPEN_COUNT from the test process environment. xcodebuild forwards only environment variables
# of its own process that start with TEST_RUNNER_, so the count is set that way here. The same NAME=value written as a
# trailing argument is a build setting, not an environment variable: the test never sees it and runs the default 100.
# The script counts the reopens that really ran and stops with an error when they differ from N.
#
# Needs: the receiver armed and the iPhone paired with it; Remote Keyboard selected as the keyboard; rk-diag installed
# (Windows %LOCALAPPDATA%\Programs\RemoteKeyboard\rk-diag.exe, Linux ~/.local/bin/rk-diag); the iPhone unlocked.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="${1:-}"
COUNT="${2:-100}"

case "$TARGET" in
  win|linux) ;;
  -h|--help|"") sed -n '2,19p' "${BASH_SOURCE[0]}"; [ -n "$TARGET" ] && exit 0; exit 2 ;;
  *) echo "target must be win or linux" >&2; exit 2 ;;
esac
case "$COUNT" in
  ''|*[!0-9]*|0) echo "N must be a positive whole number" >&2; exit 2 ;;
esac

WIN_HOST="${RK_SSH_WIN:-rk-win}"
LINUX_HOST="${RK_SSH_LINUX:-rk-linux}"
SKEW="${RK_SINCE_SKEW_S:-0}"

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
BASE="$RESULTS_DIR/$(date +%Y-%m-%d)-$TARGET"
OUT="$BASE.txt"
n=2
while [ -e "$OUT" ]; do OUT="$BASE-$n.txt"; n=$((n + 1)); done
XLOG="$(mktemp -t rk-reconnect-xcodebuild)"
trap 'rm -f "$XLOG"' EXIT

START_EPOCH=$(( $(date -u +%s) - SKEW ))
SINCE="$(date -u -r "$START_EPOCH" +%Y-%m-%dT%H:%M:%SZ)"
echo "start $SINCE  target=$TARGET  reopens=$COUNT  iphone=$UDID"

TEST_RUNNER_RK_REOPEN_COUNT="$COUNT" xcodebuild test -workspace "$WORKSPACE" -scheme RemoteKeyboardApp \
  -destination "id=$UDID" -allowProvisioningUpdates \
  -only-testing:RemoteKeyboardUITests/ReconnectUITests/testHundredReopens >"$XLOG" 2>&1 </dev/null
XCODE_STATUS=$?
grep -E "TEST (SUCCEEDED|FAILED)|Test Case .* (passed|failed)" "$XLOG" | tail -3

# RKTIMING n=<done>/<asked> per app and metric: the two apps' keyboardToConnected counts add up to the reopens that ran.
RAN="$(grep -h "RKTIMING .*metric=keyboardToConnected" "$XLOG" | sed -E 's/.* n=([0-9]+)\/([0-9]+) .*/\2/' | awk '{s += $1} END {print s + 0}')"

case "$TARGET" in
  win)
    SSH_HOST="$WIN_HOST"
    REMOTE_CMD='"%LOCALAPPDATA%\Programs\RemoteKeyboard\rk-diag.exe" stats "%LOCALAPPDATA%\RemoteKeyboard\logs" --since '"$SINCE"
    ;;
  linux)
    SSH_HOST="$LINUX_HOST"
    REMOTE_CMD='"$HOME/.local/bin/rk-diag" stats "${XDG_STATE_HOME:-$HOME/.local/state}/remote-keyboard/logs" --since '"$SINCE"
    ;;
esac
RECEIVER_SUMMARY="$(ssh -o ConnectTimeout=10 -o BatchMode=yes "$SSH_HOST" "$REMOTE_CMD" 2>&1)"
SSH_STATUS=$?

{
  echo "# measure-reconnect target=$TARGET since=$SINCE reopens_asked=$COUNT reopens_ran=$RAN xcodebuild_exit=$XCODE_STATUS"
  echo
  echo "## iPhone (RKTIMING)"
  grep -h "RKTIMING" "$XLOG" || echo "none"
  echo
  echo "## Receiver (rk-diag stats, ssh $SSH_HOST, exit $SSH_STATUS)"
  echo "$RECEIVER_SUMMARY"
} >"$OUT"

cat "$OUT"
echo "saved $OUT"

if [ "$RAN" -ne "$COUNT" ]; then
  echo "WARNING: $RAN reopens ran, $COUNT were asked for" >&2
  exit 4
fi
[ "$SSH_STATUS" -eq 0 ] || exit 5
exit "$XCODE_STATUS"
