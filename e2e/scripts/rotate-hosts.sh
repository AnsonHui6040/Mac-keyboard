#!/usr/bin/env bash
# Rotates the iPhone keyboard between the Windows and the Linux computer, round after round, without any manual step: each
# round the keyboard's host-name cell is tapped until the round's computer is current, the time to `connected` is measured
# (HostRotationUITests/testRotateAndType), and a test token is typed. At the end each computer's own text is read back and
# must hold exactly its own rounds' tokens and none of the other computer's.
#
#   e2e/scripts/rotate-hosts.sh [ROUNDS]        ROUNDS defaults to 20; odd rounds Windows, even rounds Linux
#
# Environment:
#   RK_IPHONE_UDID   iPhone UDID (required)
#   RK_SSH_WIN       ssh host name of the Windows machine (default rk-win)
#   RK_SSH_LINUX     ssh host name of the Linux machine (default rk-linux)
#   RK_HOST_WIN      the Windows computer's name as the iPhone lists it (default Windows)
#   RK_HOST_LINUX    the Linux computer's name as the iPhone lists it (default Linux)
# The Mac is paired too, so the rotation passes through it; nothing is typed while it is selected, and the Mac receiver is
# neither stopped nor touched. Before every round the target computer's text window must report focus=True (Windows:
# win-focus-target.ps1 through a scheduled task in the user's desktop session; Linux: linux-type-target.py --check-focus),
# otherwise the run stops with exit code 7 and nothing is typed.
# The result goes to e2e/results/<date>-rotation.txt (not committed): numbers and PASS/FAIL only, never typed text beyond the
# wl11 tokens. Needs: Windows and Linux receivers running and paired, the iPhone unlocked, Remote Keyboard installed,
# python3-gi with Gtk 4.0 and Atspi on the Linux machine, the Linux desktop session logged in.
# Exit codes: 0 pass, 2 usage, 3 setup problem, 4 a UI test failed, 5 ssh failed, 6 token mismatch, 7 no focus.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ROUNDS="${1:-20}"
case "$ROUNDS" in
  -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}"; exit 0 ;;
  ''|*[!0-9]*|0) echo "ROUNDS must be a positive whole number" >&2; exit 2 ;;
esac

WIN_SSH="${RK_SSH_WIN:-rk-win}"
LINUX_SSH="${RK_SSH_LINUX:-rk-linux}"
WIN_NAME="${RK_HOST_WIN:-Windows}"
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

LINUX_DIR=/tmp/rk-wl11
LINUX_UNIT=rk-wl11-target
LINUX_ENV='export XDG_RUNTIME_DIR=/run/user/$(id -u); export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus'
SSH_OPTS=(-o ConnectTimeout=10 -o BatchMode=yes)

XLOG="$(mktemp -t rk-rotate-xcodebuild)"
ROWS=""           # one line per round: <i> <host> <taps> <switch_ms>
LINUX_STARTED=0
NOTES=""          # lines for the report: focus_lost and the like
WIN_BASE=""       # text of the Windows test file before the first round (content is never printed)
LINUX_BASE=""

stop_linux_target() {
  [ "$LINUX_STARTED" = 1 ] || return 0
  ssh -n "${SSH_OPTS[@]}" -- "$LINUX_SSH" "$LINUX_ENV; systemctl --user stop $LINUX_UNIT" >/dev/null 2>&1 || \
    echo "WARNING: could not stop $LINUX_UNIT on $LINUX_SSH" >&2
}
cleanup() { rm -f "$XLOG"; stop_linux_target; }
trap cleanup EXIT

# ---- remote helpers -------------------------------------------------------------------------------------------------

# CRLF and a bare CR (Notepad's UI Automation text separates lines with CR alone) both become LF.
norm_nl() { perl -0pe 's/\r\n?/\n/g'; }

# Runs a PowerShell script read from stdin on the Windows machine (no quoting through the remote shell).
win_ps() { ssh "${SSH_OPTS[@]}" -- "$WIN_SSH" 'powershell -NoProfile -NonInteractive -Command -' 2>/dev/null | norm_nl; }

# The task runs under conhost --headless: Windows 11 would otherwise open a visible terminal window that steals the focus.
# win_task <script file in rk-build\e2e> <result file name> [extra script arguments]: runs the script in the user's desktop session through a
# scheduled task (/IT) and prints the result file. Prints "rkwl11: no-result" when the file never appears.
win_task() {
  {
    printf "\$script = '%s'\n\$outName = '%s'\n\$extra = '%s'\n" "$1" "$2" "${3:-}"
    cat <<'PS'
$d = Join-Path $env:USERPROFILE 'rk-build\e2e'
$out = Join-Path $d $outName
Remove-Item $out -ErrorAction SilentlyContinue
$tr = 'conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $d $script) + '" -Out "' + $out + '" ' + $extra
schtasks /Create /TN rkwl11 /SC ONCE /ST 00:00 /IT /F /TR $tr | Out-Null
schtasks /Run /TN rkwl11 | Out-Null
for ($i = 0; $i -lt 60 -and -not (Test-Path $out); $i++) { Start-Sleep -Milliseconds 500 }
Start-Sleep -Milliseconds 300
schtasks /Delete /TN rkwl11 /F | Out-Null
if (Test-Path $out) { Get-Content -Raw -Encoding UTF8 $out } else { 'rkwl11: no-result' }
PS
  } | win_ps
}

linux_ssh() { ssh -n "${SSH_OPTS[@]}" -- "$LINUX_SSH" "$@"; }

# Seconds since the epoch on a machine's clock minus this Mac's: <ssh host> <date command>.
clock_offset() {
  local before after remote
  before=$(date -u +%s)
  remote="$(ssh -n "${SSH_OPTS[@]}" -- "$1" "$2" 2>/dev/null | tr -d '\r' | tail -1)"
  after=$(date -u +%s)
  case "$remote" in ''|*[!0-9]*) return 1 ;; esac
  echo $(( remote - (before + after) / 2 ))
}

# ---- report ---------------------------------------------------------------------------------------------------------

# Nearest-rank percentile of the numbers on stdin: <percent>.
percentile() { sort -n | awk -v p="$1" '{a[NR]=$1} END {if (NR == 0) {print "n/a"; exit} i = int((p * NR + 99) / 100); if (i < 1) i = 1; print a[i]}'; }
max_of() { sort -n | tail -1; }

host_summary() { # <host name>
  local ms
  ms="$(printf '%s' "$ROWS" | awk -v h="$1" '$2 == h {print $4}')"
  if [ -z "$ms" ]; then echo "$1 rounds=0"; return; fi
  echo "$1 rounds=$(printf '%s\n' "$ms" | wc -l | tr -d ' ') switch_ms p50=$(printf '%s\n' "$ms" | percentile 50) p95=$(printf '%s\n' "$ms" | percentile 95) max=$(printf '%s\n' "$ms" | max_of)"
}

auth_counts() { # <name> <ssh host> <receiver stats command prefix>: "<name> auth_ok=<n> connections=<n> rounds=<n>"
  local stats ok conn rounds
  stats="$(ssh -n "${SSH_OPTS[@]}" -- "$2" "$3" 2>&1 | tr -d '\r')" || { echo "$1 stats unavailable"; return; }
  ok="$(printf '%s\n' "$stats" | awk '$1 == "auth_result" {for (i = 2; i <= NF; i++) if ($i ~ /^ok=/) {sub("ok=", "", $i); print $i}}')"
  conn="$(printf '%s\n' "$stats" | awk '$1 == "connections" {print $2}')"
  rounds="$(printf '%s' "$ROWS" | awk -v h="$1" '$2 == h' | wc -l | tr -d ' ')"
  echo "$1 auth_ok=${ok:-0} connections=${conn:-0} rounds=$rounds"
}

RESULTS_DIR="$REPO_ROOT/e2e/results"
mkdir -p "$RESULTS_DIR"
OUT_BASE="$RESULTS_DIR/$(date +%Y-%m-%d)-rotation"
OUT="$OUT_BASE.txt"
n=2
while [ -e "$OUT" ]; do OUT="$OUT_BASE-$n.txt"; n=$((n + 1)); done

# write_report <status word> <token check line for Windows> <token check line for Linux> <auth lines>
write_report() {
  {
    echo "# rotate-hosts rounds_asked=$ROUNDS rounds_done=$(printf '%s' "$ROWS" | grep -c .) status=$1 iphone=$UDID"
    echo
    echo "## Per round: round host taps switch_ms"
    printf '%s' "$ROWS"
    echo
    echo "## Switch time"
    host_summary "$WIN_NAME"
    host_summary "$LINUX_NAME"
    echo
    echo "## Tokens"
    echo "$2"
    echo "$3"
    echo
    echo "## Notes"
    printf '%s' "${NOTES:-none
}"
    echo
    echo "## Receiver connections in the run window"
    echo "$4"
  } >"$OUT"
  cat "$OUT"
  echo "saved $OUT"
}

fail_partial() { # <exit code> <message>
  echo "$2" >&2
  write_report "aborted" "windows not checked" "linux not checked" "not read"
  exit "$1"
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

WIN_OFFSET="$(clock_offset "$WIN_SSH" 'powershell -NoProfile -Command "[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()"')" || { echo "cannot read the Windows clock over ssh ($WIN_SSH)" >&2; exit 5; }
LINUX_OFFSET="$(clock_offset "$LINUX_SSH" 'date -u +%s')" || { echo "cannot read the Linux clock over ssh ($LINUX_SSH)" >&2; exit 5; }
echo "clock offsets (receiver minus Mac, s): windows=$WIN_OFFSET linux=$LINUX_OFFSET"
RUN_START=$(date -u +%s)

echo "preparing the Windows target ..."
ssh "${SSH_OPTS[@]}" -- "$WIN_SSH" 'powershell -NoProfile -NonInteractive -Command -' >/dev/null 2>&1 <<'PS' || { echo "cannot prepare rk-build\\e2e on $WIN_SSH" >&2; exit 5; }
New-Item -ItemType Directory -Force (Join-Path $env:USERPROFILE 'rk-build\e2e') | Out-Null
PS
scp -q "${SSH_OPTS[@]}" "$SCRIPT_DIR/win-focus-target.ps1" "$SCRIPT_DIR/win-read-target.ps1" "$WIN_SSH:rk-build/e2e/" || { echo "scp to $WIN_SSH failed" >&2; exit 5; }

[ "$(win_task win-focus-target.ps1 focus.txt | head -1)" = "focus=True" ] || { echo "the Windows test window could not be opened with focus" >&2; exit 7; }

echo "preparing the Linux target ..."
linux_ssh "umask 077; mkdir -p -m 700 $LINUX_DIR" || { echo "cannot reach $LINUX_SSH" >&2; exit 5; }
scp -q "${SSH_OPTS[@]}" "$SCRIPT_DIR/linux-type-target.py" "$LINUX_SSH:$LINUX_DIR/linux-type-target.py" || { echo "scp to $LINUX_SSH failed" >&2; exit 5; }
LINUX_STARTED=1
# GTK exposes accessibility only to apps started after it is enabled, so enable it first (this login session only).
linux_ssh "$LINUX_ENV
systemctl --user stop $LINUX_UNIT >/dev/null 2>&1
if gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus --method org.freedesktop.DBus.Properties.Get org.a11y.Status IsEnabled 2>/dev/null | grep -q false; then
  gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus --method org.freedesktop.DBus.Properties.Set org.a11y.Status IsEnabled '<true>' >/dev/null 2>&1
fi
systemd-run --user --collect --unit $LINUX_UNIT -E WAYLAND_DISPLAY=wayland-0 python3 $LINUX_DIR/linux-type-target.py >/dev/null 2>&1" \
  || { echo "could not start the Linux target window on $LINUX_SSH" >&2; exit 5; }
sleep 3

# ---- baselines ------------------------------------------------------------------------------------------------------

# Text of each test file before the first round: Notepad may restore an older unsaved tab, so emptying the file is not enough.
# Only the type-target.txt tab is read (win-read-target.ps1 refuses otherwise); the text is kept in memory, never printed.
WIN_BASE="$(win_task win-read-target.ps1 np.txt)"
case "$WIN_BASE" in refused*|rkwl11:*) echo "cannot read the Windows test file for the baseline: ${WIN_BASE%%$'\n'*}" >&2; exit 3 ;; esac
LINUX_BASE="$(linux_ssh "cat $LINUX_DIR/target.txt" | norm_nl)" || { echo "cannot read $LINUX_DIR/target.txt on $LINUX_SSH" >&2; exit 5; }

# ---- focus checks ---------------------------------------------------------------------------------------------------

# Prints focus=True or focus=False (anything else counts as False). -KeepContent: the Windows file is never emptied.
focus_of() { # <host name>
  local result
  if [ "$1" = "$WIN_NAME" ]; then
    result="$(win_task win-focus-target.ps1 focus.txt -KeepContent | head -1)"
  else
    result="$(linux_ssh "$LINUX_ENV; rm -f $LINUX_DIR/focus.txt; systemd-run --user --collect --wait -E WAYLAND_DISPLAY=wayland-0 python3 $LINUX_DIR/linux-type-target.py --check-focus $LINUX_DIR/focus.txt >/dev/null 2>&1; cat $LINUX_DIR/focus.txt 2>/dev/null" | tr -d '\r' | head -1)"
  fi
  [ "$result" = "focus=True" ] && echo "focus=True" || echo "focus=False"
}

# Tokens (wl11r<number>) found in the text on stdin, one per line, in order.
tokens_in() { grep -o 'wl11r[0-9][0-9]*'; }
# Whether a round number is a Windows round (odd) or a Linux round (even).
is_windows_round() { [ $(( $1 % 2 )) -eq 1 ]; }

# ---- rounds ---------------------------------------------------------------------------------------------------------

i=1
while [ "$i" -le "$ROUNDS" ]; do
  if is_windows_round "$i"; then HOST="$WIN_NAME"; OTHER="$LINUX_NAME"; else HOST="$LINUX_NAME"; OTHER="$WIN_NAME"; fi
  TOKEN="wl11r$i"

  # Both windows must hold focus: a token that leaked to the other computer would land in an unknown window.
  for checked in "$HOST" "$OTHER"; do
    if [ "$(focus_of "$checked")" != "focus=True" ]; then
      fail_partial 7 "round $i: $checked's test window does not have focus; nothing was typed in this round. Fix the window and run again."
    fi
  done

  TEST_RUNNER_RK_TARGET_HOST="$HOST" TEST_RUNNER_RK_TOKEN="$TOKEN" xcodebuild test-without-building -workspace "$WORKSPACE" \
    -scheme RemoteKeyboardApp -destination "id=$UDID" \
    -only-testing:RemoteKeyboardUITests/HostRotationUITests/testRotateAndType >"$XLOG" 2>&1 </dev/null
  STATUS=$?
  LINE="$(grep -h "RKROT host=" "$XLOG" | tail -1)"
  TAPS="$(printf '%s\n' "$LINE" | sed -nE 's/.* taps=([0-9]+) .*/\1/p')"
  MS="$(printf '%s\n' "$LINE" | sed -nE 's/.* switch_ms=([0-9]+).*/\1/p')"
  if [ "$STATUS" -ne 0 ] || [ -z "$TAPS" ] || [ -z "$MS" ]; then
    grep -E "error:|XCTAssert|did not|not connected|RK_TARGET_HOST|RK_TOKEN" "$XLOG" | head -5 >&2
    fail_partial 4 "round $i ($HOST): the UI test failed (xcodebuild exit $STATUS)"
  fi
  ROWS="$ROWS$i $HOST $TAPS $MS
"
  echo "round $i $HOST taps=$TAPS switch_ms=$MS"

  # Focus must still be where it was: a window that took it during the round may have received the token.
  for checked in "$HOST" "$OTHER"; do
    if [ "$(focus_of "$checked")" != "focus=True" ]; then
      NOTES="${NOTES}round $i focus_lost host=$checked
"
      fail_partial 7 "focus was lost during round $i; the token may have gone to another window"
    fi
  done

  i=$((i + 1))
done

# ---- read back and compare ------------------------------------------------------------------------------------------

EXPECT_LINUX=""
EXPECT_WIN=""
for r in $(seq 1 "$ROUNDS"); do
  if is_windows_round "$r"; then EXPECT_WIN="${EXPECT_WIN}wl11r$r
"; else EXPECT_LINUX="${EXPECT_LINUX}wl11r$r
"; fi
done

# token_line <name> <text read back> <baseline> <expected tokens>: PASS only when the text starts with the baseline and the
# rest is exactly the expected tokens, one per line (newlines between the baseline and the first token are ignored).
token_line() {
  local verdict=FAIL rest="" found missing unexpected
  case "$2" in "$3"*) rest="${2#"$3"}"; rest="${rest#"${rest%%[!$'\n']*}"}"; rest="$(printf '%s' "$rest")"; [ "$rest" = "$(printf '%s' "$4")" ] && verdict=PASS ;; *) rest="$2" ;; esac
  found="$(printf '%s\n' "$rest" | tokens_in)"
  missing="$(printf '%s' "$4" | grep -vxFf <(printf '%s\n' "$found") | grep . || true)"
  unexpected="$(printf '%s\n' "$found" | grep -vxFf <(printf '%s' "$4") | grep . || true)"
  echo "$1 token_check $verdict baseline_len=${#3} tokens_after_baseline=[$(printf '%s' "$found" | tr '\n' ' ')] expected_count=$(printf '%s' "$4" | grep -c .) missing=$(printf '%s' "$missing" | grep -c .) [$(printf '%s' "$missing" | tr '\n' ' ')] unexpected=$(printf '%s' "$unexpected" | grep -c .) [$(printf '%s' "$unexpected" | tr '\n' ' ')]"
}

WIN_RAW="$(win_task win-read-target.ps1 np.txt)"
WIN_LINE="$(token_line "$WIN_NAME" "$WIN_RAW" "$WIN_BASE" "$EXPECT_WIN")"
LINUX_RAW="$(linux_ssh "cat $LINUX_DIR/target.txt" | norm_nl)" || fail_partial 5 "cannot read $LINUX_DIR/target.txt on $LINUX_SSH"
LINUX_LINE="$(token_line "$LINUX_NAME" "$LINUX_RAW" "$LINUX_BASE" "$EXPECT_LINUX")"

# One connection per round: the receivers' own count of authenticated connections since the run began.
win_since="$(date -u -r $(( RUN_START + WIN_OFFSET - 10 )) +%Y-%m-%dT%H:%M:%SZ)"
linux_since="$(date -u -r $(( RUN_START + LINUX_OFFSET - 10 )) +%Y-%m-%dT%H:%M:%SZ)"
AUTH_LINES="$(auth_counts "$WIN_NAME" "$WIN_SSH" "\"%LOCALAPPDATA%\\Programs\\RemoteKeyboard\\rk-diag.exe\" stats \"%LOCALAPPDATA%\\RemoteKeyboard\\logs\" --since $win_since")
$(auth_counts "$LINUX_NAME" "$LINUX_SSH" "rk-diag stats \"\${XDG_STATE_HOME:-\$HOME/.local/state}/remote-keyboard/logs\" --since $linux_since")"

case "$WIN_LINE$LINUX_LINE" in *FAIL*) ;; *) PASSED=1 ;; esac
if [ "${PASSED:-0}" = 1 ]; then
  write_report "pass" "$WIN_LINE" "$LINUX_LINE" "$AUTH_LINES"
  exit 0
fi
write_report "token-mismatch" "$WIN_LINE" "$LINUX_LINE" "$AUTH_LINES"
echo "token check failed: see the Tokens section" >&2
exit 6
