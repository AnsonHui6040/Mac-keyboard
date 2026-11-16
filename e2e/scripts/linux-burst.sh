#!/usr/bin/env bash
# Types a burst of numbered tokens (b1 Return, b2 Return, ...) from the iPhone keyboard to the Linux computer without any manual
# step, and separates the two ways characters were lost in the WL11 rotation runs:
#   A  the link dropped while typing (the UI test saw a status other than `connected` before a key; RKBURST_GAP)
#   B? every key was sent while connected, yet the token is missing from the target window (receiver or window problem)
#
#   e2e/scripts/linux-burst.sh [COUNT] [gtk|editor]     COUNT defaults to 50 (1..200); the target defaults to gtk
#
# Targets on the Linux machine (both below /tmp/rk-wl11/, both need focus=True before and are checked again after typing):
#   gtk     linux-type-target.py's own window "rk-type-target"; the read-back is the file it rewrites on every change
#   editor  GNOME Text Editor on the empty file rk-editor-target.txt; the read-back is the text view through AT-SPI
#           (linux-type-target.py --editor-read), which refuses unless exactly one window has that exact title
# Steps: build-for-testing once; select the Linux computer on the iPhone (PairingUITests/testSelectComputer); start the target;
# require focus; read the receiver clock offset; run HostRotationUITests/testTypeBurst (prefix b); check focus again; read back;
# count the receiver log lines of the run window (UTC window of RKBURST start..end adjusted by the clock offset, +/- 3 s):
# event_in text/enter, inject ok and not ok, every disconnected reason, auth ok. Only numbers, reasons and the b<i> tokens are
# printed or saved; no other window is read.
#
# Environment:
#   RK_IPHONE_UDID   iPhone UDID (required)
#   RK_SSH_LINUX     ssh host name of the Linux machine (default rk-linux)
#   RK_HOST_LINUX    the Linux computer's name as the iPhone lists it (default Linux)
# The report goes to e2e/results/<date>-linux-burst-<target>.txt (not committed).
# Exit codes: 0 all tokens present, 2 usage, 3 setup problem or read-back refused, 4 a UI test failed, 5 ssh failed,
# 6 missing tokens, 7 no focus before typing.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
case "${1:-}" in -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}"; exit 0 ;; esac
COUNT="${1:-50}"
TARGET="${2:-gtk}"
case "$COUNT" in ''|*[!0-9]*) echo "COUNT must be a whole number from 1 to 200" >&2; exit 2 ;; esac
if [ "$COUNT" -lt 1 ] || [ "$COUNT" -gt 200 ]; then echo "COUNT must be a whole number from 1 to 200" >&2; exit 2; fi
case "$TARGET" in gtk|editor) ;; *) echo "target must be gtk or editor" >&2; exit 2 ;; esac

LINUX_SSH="${RK_SSH_LINUX:-rk-linux}"
LINUX_NAME="${RK_HOST_LINUX:-Linux}"
UDID="${RK_IPHONE_UDID:-}"
if [ -z "$UDID" ]; then
  echo "RK_IPHONE_UDID is required (xcrun devicectl list devices)" >&2
  exit 2
fi
WORKSPACE="$REPO_ROOT/RemoteKeyboard.xcworkspace"
if [ ! -d "$WORKSPACE" ]; then
  echo "RemoteKeyboard.xcworkspace is missing: run xcodegen generate and LANG=en_US.UTF-8 pod install first" >&2
  exit 3
fi

PREFIX=b
LINUX_DIR=/tmp/rk-wl11
GTK_UNIT=rk-wl11-target
EDITOR_UNIT=rk-burst-editor
EDITOR_FILE="$LINUX_DIR/rk-editor-target.txt"
READ_FILE="$LINUX_DIR/burst-read.txt"
FOCUS_FILE="$LINUX_DIR/burst-focus.txt"
LOG_DIR='${XDG_STATE_HOME:-$HOME/.local/state}/remote-keyboard/logs'
LINUX_ENV='export XDG_RUNTIME_DIR=/run/user/$(id -u); export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus'
SSH_OPTS=(-o ConnectTimeout=10 -o BatchMode=yes)

XLOG="$(mktemp -t rk-burst-xcodebuild)"
STARTED=0
NOTES=""

linux_ssh() { ssh -n "${SSH_OPTS[@]}" -- "$LINUX_SSH" "$@"; }

stop_targets() {
  [ "$STARTED" = 1 ] || return 0
  linux_ssh "$LINUX_ENV; systemctl --user stop $GTK_UNIT $EDITOR_UNIT" >/dev/null 2>&1 || \
    echo "WARNING: could not stop $GTK_UNIT / $EDITOR_UNIT on $LINUX_SSH" >&2
}
cleanup() { rm -f "$XLOG"; stop_targets; }
trap cleanup EXIT

norm_nl() { perl -0pe 's/\r\n?/\n/g'; }

# Seconds since the epoch on the Linux clock minus this Mac's.
clock_offset() {
  local before after remote
  before=$(date -u +%s)
  remote="$(linux_ssh 'date -u +%s' 2>/dev/null | tr -d '\r' | tail -1)"
  after=$(date -u +%s)
  case "$remote" in ''|*[!0-9]*) return 1 ;; esac
  echo $(( remote - (before + after) / 2 ))
}

# Runs linux-type-target.py with the desktop session's environment and waits for it: <arguments>.
linux_py() {
  linux_ssh "$LINUX_ENV; systemd-run --user --collect --wait -E WAYLAND_DISPLAY=wayland-0 python3 $LINUX_DIR/linux-type-target.py $* >/dev/null 2>&1"
}

# Prints focus=True or focus=False (anything else counts as False).
focus_now() {
  local result flag=--check-focus
  [ "$TARGET" = editor ] && flag=--editor-check-focus
  result="$(linux_ssh "$LINUX_ENV; rm -f $FOCUS_FILE; systemd-run --user --collect --wait -E WAYLAND_DISPLAY=wayland-0 python3 $LINUX_DIR/linux-type-target.py $flag $FOCUS_FILE >/dev/null 2>&1; cat $FOCUS_FILE 2>/dev/null" | tr -d '\r' | head -1)"
  [ "$result" = "focus=True" ] && echo "focus=True" || echo "focus=False"
}

# The target's text, or "refused" when the editor read-back refuses. Exit status 1 when ssh fails.
read_target() {
  if [ "$TARGET" = gtk ]; then
    linux_ssh "cat $LINUX_DIR/target.txt" | norm_nl
  else
    linux_ssh "$LINUX_ENV; rm -f $READ_FILE; systemd-run --user --collect --wait -E WAYLAND_DISPLAY=wayland-0 python3 $LINUX_DIR/linux-type-target.py --editor-read $READ_FILE >/dev/null 2>&1; cat $READ_FILE 2>/dev/null" | norm_nl
  fi
}

RESULTS_DIR="$REPO_ROOT/e2e/results"
mkdir -p "$RESULTS_DIR"
OUT_BASE="$RESULTS_DIR/$(date +%Y-%m-%d)-linux-burst-$TARGET"
OUT="$OUT_BASE.txt"
n=2
while [ -e "$OUT" ]; do OUT="$OUT_BASE-$n.txt"; n=$((n + 1)); done

# write_report <status word> <body>
write_report() {
  {
    echo "# linux-burst target=$TARGET count=$COUNT status=$1 iphone=$UDID"
    echo
    printf '%s\n' "$2"
    echo
    echo "## Notes"
    printf '%s' "${NOTES:-none
}"
  } >"$OUT"
  cat "$OUT"
  echo "saved $OUT"
}

# ---- preparation ----------------------------------------------------------------------------------------------------

echo "building the UI tests once for $UDID ..."
if ! xcodebuild build-for-testing -workspace "$WORKSPACE" -scheme RemoteKeyboardApp -destination "id=$UDID" \
  -allowProvisioningUpdates >"$XLOG" 2>&1 </dev/null; then
  grep -E "error:|BUILD FAILED|TEST BUILD FAILED" "$XLOG" | head -5 >&2
  echo "build-for-testing failed" >&2
  exit 3
fi
tail -1 "$XLOG"

echo "selecting $LINUX_NAME on the iPhone ..."
TEST_RUNNER_RK_SELECT_HOST="$LINUX_NAME" xcodebuild test-without-building -workspace "$WORKSPACE" -scheme RemoteKeyboardApp \
  -destination "id=$UDID" -only-testing:RemoteKeyboardUITests/PairingUITests/testSelectComputer >"$XLOG" 2>&1 </dev/null
if [ $? -ne 0 ]; then
  grep -E "error:|XCTAssert|RK_SELECT_HOST|no row contains" "$XLOG" | head -5 >&2
  echo "selecting \"$LINUX_NAME\" on the iPhone failed; nothing was typed" >&2
  exit 4
fi

OFFSET="$(clock_offset)" || { echo "cannot read the Linux clock over ssh ($LINUX_SSH)" >&2; exit 5; }
echo "clock offset (Linux minus Mac, s): $OFFSET"

echo "preparing the Linux $TARGET target ..."
linux_ssh "umask 077; mkdir -p -m 700 $LINUX_DIR" || { echo "cannot reach $LINUX_SSH" >&2; exit 5; }
scp -q "${SSH_OPTS[@]}" "$SCRIPT_DIR/linux-type-target.py" "$LINUX_SSH:$LINUX_DIR/linux-type-target.py" || { echo "scp to $LINUX_SSH failed" >&2; exit 5; }
STARTED=1
# GTK exposes accessibility only to apps started after it is enabled, so enable it first (this login session only).
if [ "$TARGET" = gtk ]; then
  START_CMD="systemd-run --user --collect --unit $GTK_UNIT -E WAYLAND_DISPLAY=wayland-0 python3 $LINUX_DIR/linux-type-target.py"
else
  START_CMD="umask 077; : > $EDITOR_FILE; systemd-run --user --collect --unit $EDITOR_UNIT -E WAYLAND_DISPLAY=wayland-0 gnome-text-editor --standalone $EDITOR_FILE"
fi
linux_ssh "$LINUX_ENV
systemctl --user stop $GTK_UNIT $EDITOR_UNIT >/dev/null 2>&1
if gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus --method org.freedesktop.DBus.Properties.Get org.a11y.Status IsEnabled 2>/dev/null | grep -q false; then
  gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus --method org.freedesktop.DBus.Properties.Set org.a11y.Status IsEnabled '<true>' >/dev/null 2>&1
fi
$START_CMD >/dev/null 2>&1" || { echo "could not start the Linux $TARGET target on $LINUX_SSH" >&2; exit 5; }
sleep 4

if [ "$(focus_now)" != "focus=True" ]; then
  echo "the Linux $TARGET window does not have focus; nothing was typed" >&2
  write_report "no-focus-before" "not typed"
  exit 7
fi

BASE="$(read_target)" || { echo "cannot read the $TARGET target on $LINUX_SSH" >&2; exit 5; }
case "$BASE" in refused*) echo "the $TARGET read-back refused before typing" >&2; exit 3 ;; esac
# Anything that already looks like a burst token would be miscounted, so the target must start free of them.
if printf '%s\n' "$BASE" | grep -Eq "^$PREFIX[0-9]+$"; then echo "the $TARGET target already holds $PREFIX<digits> lines; restart it" >&2; exit 3; fi

# ---- type -----------------------------------------------------------------------------------------------------------

echo "typing $COUNT tokens ..."
TEST_RUNNER_RK_TARGET_HOST="$LINUX_NAME" TEST_RUNNER_RK_TOKEN_PREFIX="$PREFIX" TEST_RUNNER_RK_COUNT="$COUNT" \
  xcodebuild test-without-building -workspace "$WORKSPACE" -scheme RemoteKeyboardApp -destination "id=$UDID" \
  -only-testing:RemoteKeyboardUITests/HostRotationUITests/testTypeBurst >"$XLOG" 2>&1 </dev/null
STATUS=$?
BURST="$(grep -h "^RKBURST count=" "$XLOG" | tail -1)"
GAPS="$(grep -ho "RKBURST_GAP token=[0-9]*" "$XLOG" | sed 's/.*=//' | sort -n -u)"
KEYS_LINE="$(grep -h "RKKEYS total=" "$XLOG" | tail -1)"
if [ "$STATUS" -ne 0 ] || [ -z "$BURST" ]; then
  grep -E "error:|XCTAssert|did not|not connected|not the current host|RK_" "$XLOG" | head -5 >&2
  echo "the UI test failed (xcodebuild exit $STATUS)" >&2
  exit 4
fi
field() { printf '%s\n' "$BURST" | sed -nE "s/.* $1=([^ ]+).*/\1/p"; }
KEYS="$(field keys)"; NOTCONN="$(field notConnected)"; T_START="$(field start)"; T_END="$(field end)"
echo "burst: $BURST"

AFTER_FOCUS="$(focus_now)"
[ "$AFTER_FOCUS" = "focus=True" ] || NOTES="${NOTES}focus_lost_after_typing target=$TARGET (read back anyway)
"

# ---- read back ------------------------------------------------------------------------------------------------------

TEXT="$(read_target)" || { echo "cannot read the $TARGET target on $LINUX_SSH" >&2; exit 5; }
case "$TEXT" in refused*)
  NOTES="${NOTES}readback_refused target=$TARGET
"
  write_report "readback-refused" "typed $COUNT tokens, keys=$KEYS notConnected=$NOTCONN; the read-back refused"
  exit 3 ;;
esac
FOUND="$(printf '%s\n' "$TEXT" | grep -E "^$PREFIX[0-9]+$" | sort -u)"

# ---- receiver log in the run window ---------------------------------------------------------------------------------

to_epoch() { date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null; }
iso19() { date -u -r "$1" +%Y-%m-%dT%H:%M:%S; }
S_EPOCH="$(to_epoch "$T_START")"; E_EPOCH="$(to_epoch "$T_END")"
case "$S_EPOCH$E_EPOCH" in ''|*[!0-9]*) echo "cannot parse the RKBURST times ($T_START, $T_END)" >&2; exit 3 ;; esac
LO="$(iso19 $(( S_EPOCH + OFFSET - 3 )))"
HI="$(iso19 $(( E_EPOCH + OFFSET + 3 )))"
LOG_LINES="$(linux_ssh "d=\"$LOG_DIR\"; for f in \$(ls \"\$d\"/rk-*.log 2>/dev/null | tail -3); do cat \"\$f\"; done | awk -v lo=$LO -v hi=$HI '\$1 ~ /^wall=/ { w = substr(\$1, 6, 19); if (w >= lo && w <= hi) print }'" | tr -d '\r')" \
  || { echo "cannot read the receiver log on $LINUX_SSH" >&2; exit 5; }
count_lines() { printf '%s\n' "$LOG_LINES" | grep -cE "$1" || true; }
EV_TEXT="$(count_lines ' ev=event_in .* kind=text ')"
EV_ENTER="$(count_lines ' ev=event_in .* kind=enter ')"
INJ_OK="$(count_lines ' ev=inject .* result=ok')"
INJ_BAD="$(count_lines ' ev=inject ' )"
INJ_BAD=$(( INJ_BAD - INJ_OK ))
AUTH_OK="$(count_lines ' ev=auth .* result=ok')"
DISCONNECTS="$(printf '%s\n' "$LOG_LINES" | awk '/ ev=disconnected / { w = substr($1, 17, 8); r = "?"; for (i = 1; i <= NF; i++) if ($i ~ /^reason=/) r = substr($i, 8); print "disconnected at=" w "Z reason=" r }')"

# ---- compare and classify -------------------------------------------------------------------------------------------

MISSING=""; MISSING_N=0; A_N=0; B_N=0; CLASS_LINES=""
for i in $(seq 1 "$COUNT"); do
  if ! printf '%s\n' "$FOUND" | grep -qx "$PREFIX$i"; then
    MISSING_N=$((MISSING_N + 1))
    if printf '%s\n' "$GAPS" | grep -qx "$i"; then cls=A; A_N=$((A_N + 1)); else cls="B?"; B_N=$((B_N + 1)); fi
    CLASS_LINES="${CLASS_LINES}missing token=$PREFIX$i class=$cls
"
  fi
done
FOUND_N=$(( COUNT - MISSING_N ))
UNEXPECTED="$(printf '%s\n' "$FOUND" | grep -c . || true)"
UNEXPECTED=$(( UNEXPECTED - FOUND_N ))
GAP_N="$(printf '%s\n' "$GAPS" | grep -c . || true)"

BODY="## Burst (iPhone)
$BURST
$KEYS_LINE
gap_tokens=$GAP_N [$(printf '%s' "$GAPS" | tr '\n' ' ')]
focus_after_typing=${AFTER_FOCUS#focus=}

## Tokens
expected=$COUNT in_window=$FOUND_N missing=$MISSING_N (class A=$A_N, class B?=$B_N) unexpected_token_lines=$UNEXPECTED
$(printf '%s' "$CLASS_LINES")
## Receiver log window $LO .. $HI (receiver clock, offset $OFFSET s)
event_in kind=text=$EV_TEXT kind=enter=$EV_ENTER (expected enter=$COUNT)
inject result=ok=$INJ_OK not_ok=$INJ_BAD
auth result=ok=$AUTH_OK
disconnected=$(printf '%s\n' "$DISCONNECTS" | grep -c . || true)
$DISCONNECTS"

if [ "$MISSING_N" -eq 0 ]; then
  write_report "pass" "$BODY"
  exit 0
fi
write_report "missing-tokens" "$BODY"
echo "tokens missing: see the Tokens section" >&2
exit 6
