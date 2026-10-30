#!/usr/bin/env bash
# T10 automated device acceptance: runs KeyboardT10UITests on the iPhone, one case at a time, and watches what
# arrives in a fresh TextEdit document on this Mac.
#
#   e2e/scripts/t10-device-run.sh [--list] [--skip-build] [case ...]
#
# Environment:
#   T10_UDID              device UDID (default 00008150-000C65DA26C0401C)
#   T10_OUT               scratch directory for logs, histories and the summary (default /tmp/t10-device-run)
#   T10_CASE_TIMEOUT_S    per-case limit for xcodebuild (default 480)
#   T10_NOTREADY_HOLD_S   how long the Mac stays not ready in the not-ready case (default 15)
#   T10_DISABLE_AUTOCORRECT=1  turn TextEdit's spelling autocorrect off for the run and restore it afterwards
#
# The script only creates new TextEdit documents. It never edits or closes any other document, and it closes its own
# documents without saving. The expectations of every case live in ONE place: the CASES table inside T10PY below.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
UDID="${T10_UDID:-00008150-000C65DA26C0401C}"
OUT="${T10_OUT:-/tmp/t10-device-run}"
DERIVED="$OUT/derived"
CASE_TIMEOUT_S="${T10_CASE_TIMEOUT_S:-480}"
NOTREADY_HOLD_S="${T10_NOTREADY_HOLD_S:-15}"
DRAIN_S=3
SCHEME=RemoteKeyboardApp
TEST_CLASS=RemoteKeyboardUITests/KeyboardT10UITests

SKIP_BUILD=0
LIST_ONLY=0
SELECTED=()
for arg in "$@"; do
  case "$arg" in
    --list) LIST_ONLY=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *) SELECTED+=("$arg") ;;
  esac
done

# ---------------------------------------------------------------------------------------------------------------
# Expectations, poller and checker (python3 -I, standard library only).
# ---------------------------------------------------------------------------------------------------------------
read -r -d '' T10PY <<'PY'
import csv, json, signal, string, subprocess, sys, time

LETTERS30 = (string.ascii_lowercase * 2)[:30]   # the 30 letters typed by testRemoteLongPressDelete

# One row per case, in run order: (name, E2E steps, rule, parameters).
#   final     the exact text TextEdit must hold at the end
#   empty     TextEdit must never hold any text
#   delete    long-press delete: what is left is a prefix of `base` with min_left..max_left characters. A 1.0 s hold
#             deletes 1 at touch-down and then about one per 0.1 s after 0.5 s (about 6 in all); touch timing
#             jitter and the Receiver's queue move that by a few, so 3 to 15 deleted is accepted. At least 3 proves
#             the key repeats, and at most 15 leaves letters behind.
#   notready  the Mac loses focus after the pulse letter and gets it back later (see the driver in the script)
# Every non-empty text seen on the way must be a prefix of the final text (nothing stray, no early leak).
# min_quiet: seconds after the poller started before the first text may appear (the draft is only sent at the end).
CASES = [
    ("testShiftAndInstant",            "2-8",   "final",    {"final": "AABCde hello\n"}),
    ("testRemoteLongPressDelete",      "9",     "delete",   {"base": LETTERS30, "min_left": 15, "max_left": 27}),
    ("testLocalModeAndLongPressDelete", "10-13", "empty",    {}),
    ("testDraftEditing",               "14-21", "final",    {"final": "abXcab\ncdd", "min_quiet": 12.0}),
    ("testInstantWithDraftEditsDraft", "22-25", "final",    {"final": "xzq"}),
    ("testNotReadyGoesToDraft",        "26-27", "notready", {"final": "abc", "pulse": "k", "settle": 2.0}),
    ("testModeSwitchKeepsDraft",       "29-30", "empty",    {}),
    ("testSymbolsAndPages",            "34-35", "final",    {"final": "1@"}),
    ("testAccessibilityLabels",        "1,38",  "empty",    {}),
    ("testPersistence",                "28,37", "empty",    {}),
    ("testFieldKinds",                 "32-33", "empty",    {}),
    ("testDraftCap",                   "31",    "empty",    {}),
]

# Fixed strings the keyboard sends or drafts. None of them may appear in the Receiver log (E2E step 40, Mac side).
TYPED = ["hello", "AABCde", "abcd", "abXcd", "abXcYd", "abXcab", "cdd", "ABC", "abc", "xzq", "mpn", LETTERS30]


def log_strings():
    return sorted({s for s in TYPED if len(s) > 2})


def load(path):
    rows, ended = [], False
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        rec = json.loads(line)
        if rec.get("end"):
            ended = True
        elif rec.get("text") is not None:
            rows.append((rec["t"], rec["text"]))
    return rows, ended


def value_at(rows, t):
    current = None
    for ts, text in rows:
        if ts <= t:
            current = text
    return current


def check(case, hist_path, marks):
    spec = next((c for c in CASES if c[0] == case), None)
    if spec is None:
        return False, "unknown case"
    _, _, rule, p = spec
    rows, ended = load(hist_path)
    if not rows:
        return False, "no text history (TextEdit not readable)"
    notes = [] if ended else ["poller did not end cleanly"]
    final = rows[-1][1]
    non_empty = [(t, s) for t, s in rows if s != ""]
    t0 = rows[0][0]

    if rule == "empty":
        if non_empty:
            return False, "text appeared: %r" % non_empty[0][1]
        return True, "TextEdit stayed empty" + ("; " + "; ".join(notes) if notes else "")

    if rule == "delete":
        base = p["base"]
        longest = max(len(s) for _, s in rows)
        stray = [s for _, s in rows if not base.startswith(s)]
        if stray:
            return False, "stray text %r" % stray[0]
        if longest != len(base):
            return False, "only %d of %d letters arrived" % (longest, len(base))
        if not (p["min_left"] <= len(final) <= p["max_left"]):
            return False, "%d letters left, accepted %d-%d" % (len(final), p["min_left"], p["max_left"])
        return True, "%d of %d letters left" % (len(final), len(base))

    want = p["final"]

    if rule == "notready":
        wipe, refocus = marks.get("t_wipe"), marks.get("t_refocus")
        if wipe is None or refocus is None:
            return False, "the pulse letter %r never reached TextEdit, so focus was never taken away" % p["pulse"]
        if not any(s == p["pulse"] and t <= wipe + 1.5 for t, s in rows):
            return False, "the pulse letter %r is missing from the history" % p["pulse"]
        # The poller lags the wipe by up to about a second (osascript start-up plus its 0.3 s sleep).
        start, stop = wipe + 1.5, refocus + p["settle"]
        if value_at(rows, start) != "":
            return False, "text still there 1.5 s after the wipe"
        early = [s for t, s in non_empty if start < t < stop]
        if early:
            return False, "text %r appeared before the Mac was ready and settled" % early[0]
        if final != want:
            return False, "final %r, expected %r" % (final, want)
        return True, "empty while Finder was frontmost, final %r" % final

    stray = [s for _, s in non_empty if not want.startswith(s)]
    if stray:
        return False, "stray text %r on the way to %r" % (stray[0], want)
    if final != want:
        return False, "final %r, expected %r (spelling autocorrect on?)" % (final, want)
    quiet = p.get("min_quiet")
    if quiet and non_empty and non_empty[0][0] - t0 < quiet:
        return False, "text appeared after %.1f s, before the draft could have been sent" % (non_empty[0][0] - t0)
    return True, "final %r" % final


def poller(out, name):
    base = name.replace('"', "")
    # TextEdit renames the document once it holds text (for example "Untitled 2" -> "Untitled 2.rtf"), so match the
    # base name with or without an extension. "Untitled" does not match "Untitled 2" this way.
    script = ('tell application "TextEdit" to get text of (first document whose (name is "%s") or '
              '(name starts with ("%s" & ".")))' % (base, base))
    last = object()
    stop = []
    signal.signal(signal.SIGTERM, lambda *a: stop.append(1))
    with open(out, "w", buffering=1, encoding="utf-8") as f:
        while not stop:
            try:
                r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=5)
                text = None
                if r.returncode == 0:
                    text = r.stdout[:-1] if r.stdout.endswith("\n") else r.stdout
                    text = text.replace("\r\n", "\n").replace("\r", "\n")
            except subprocess.TimeoutExpired:
                text = None
            if text != last:
                f.write(json.dumps({"t": time.time(), "text": text}) + "\n")
                last = text
            time.sleep(0.3)
        f.write(json.dumps({"t": time.time(), "end": True}) + "\n")


def main(argv):
    cmd = argv[1]
    if cmd == "list":
        for name, steps, _, _ in CASES:
            print("%s\t%s" % (name, steps))
    elif cmd == "describe":
        for name, steps, rule, p in CASES:
            print("%-34s steps %-6s %-8s %s" % (name, steps, rule, json.dumps(p, ensure_ascii=False)))
    elif cmd == "strings":
        print("\n".join(log_strings()))
    elif cmd == "now":
        print("%.3f" % time.time())
    elif cmd == "poller":
        poller(argv[2], argv[3])
    elif cmd == "check":
        ok, detail = check(argv[2], argv[3], json.loads(argv[4]))
        print(("PASS" if ok else "FAIL") + "\t" + detail.replace("\n", "\\n").replace("\t", " "))
    elif cmd == "csv":
        with open(argv[2], encoding="utf-8") as src, open(argv[3], "w", newline="", encoding="utf-8") as dst:
            w = csv.writer(dst)
            w.writerow(["case", "e2e_steps", "xcuitest", "mac_check", "details"])
            for line in src:
                w.writerow(line.rstrip("\n").split("\t"))


main(sys.argv)
PY

py() { python3 -I -c "$T10PY" "$@"; }

if [ "$LIST_ONLY" -eq 1 ]; then
  py describe
  exit 0
fi

# ---------------------------------------------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------------------------------------------
say() { printf '%s\n' "$*"; }
now() { py now; }

DOC_NAME=""
POLLER_PID=""
XCODE_PID=""
STARTED_AT="$(date +%s)"
AUTOCORRECT_RESTORE=""

# Runs AppleScript from stdin. Arguments are passed to `on run argv`.
osa() { osascript - "$@" 2>/dev/null; }

textedit_new_document() {
  osa <<'AS'
tell application "TextEdit"
  activate
  set d to make new document
  return name of d
end tell
AS
}

textedit_close_document() {
  [ -n "$1" ] || return 0
  osa "$1" <<'AS' >/dev/null
on run argv
  tell application "TextEdit"
    try
      close (first document whose (name is (item 1 of argv)) or (name starts with ((item 1 of argv) & "."))) saving no
    end try
  end tell
end run
AS
}

textedit_wipe() {
  osa "$1" <<'AS' >/dev/null
on run argv
  tell application "TextEdit" to set text of (first document whose (name is (item 1 of argv)) or (name starts with ((item 1 of argv) & "."))) to ""
end run
AS
}

# Brings the test document's window to the front and puts the cursor in its text, so the Receiver sees a focused field.
textedit_focus() {
  osa "$1" <<'AS' >/dev/null
on run argv
  tell application "TextEdit"
    activate
    try
      set index of (first window whose (name is (item 1 of argv)) or (name starts with ((item 1 of argv) & "."))) to 1
    end try
  end tell
  delay 0.5
  tell application "System Events"
    tell process "TextEdit"
      set frontmost to true
      try
        set focused of text area 1 of scroll area 1 of window 1 to true
      end try
    end tell
  end tell
end run
AS
}

finder_front() {
  osa <<'AS' >/dev/null
tell application "Finder" to activate
AS
}

# Best effort: Format > Make Plain Text is Shift-Command-T, sent only while TextEdit is the frontmost process.
textedit_plain_text() {
  local rich
  rich="$(defaults read com.apple.TextEdit RichText 2>/dev/null || echo 1)"
  [ "$rich" = "0" ] && return 0
  osa <<'AS' >/dev/null
tell application "System Events"
  if name of first process whose frontmost is true is "TextEdit" then
    keystroke "t" using {command down, shift down}
  end if
end tell
AS
}

cleanup() {
  [ -n "$POLLER_PID" ] && kill "$POLLER_PID" 2>/dev/null
  # Any poller of this run that is still alive (matched by its history path under $OUT).
  pkill -f "poller $OUT/" 2>/dev/null
  [ -n "$XCODE_PID" ] && kill "$XCODE_PID" 2>/dev/null
  textedit_close_document "$DOC_NAME"
  if [ -n "$AUTOCORRECT_RESTORE" ]; then
    if [ "$AUTOCORRECT_RESTORE" = "__absent__" ]; then
      defaults delete com.apple.TextEdit NSAutomaticSpellingCorrectionEnabled 2>/dev/null
    else
      defaults write com.apple.TextEdit NSAutomaticSpellingCorrectionEnabled -bool "$AUTOCORRECT_RESTORE"
    fi
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------------------------------------------
say "== Preconditions"
fail_pre=0

DEVICES="$(xcrun xctrace list devices 2>/dev/null)"
if printf '%s\n' "$DEVICES" | grep -q "$UDID"; then
  say "  device           $UDID  listed"
else
  say "  device           $UDID  NOT listed (connect and unlock the iPhone, or set T10_UDID)"
  fail_pre=1
fi

RECEIVER_PID="$(pgrep -x MacReceiver | head -1)"
if [ -n "$RECEIVER_PID" ]; then
  say "  MacReceiver      running (pid $RECEIVER_PID); it must already be armed with 開始接收"
else
  say "  MacReceiver      NOT running (start it and press 開始接收)"
  fail_pre=1
fi

if [ -d /System/Applications/TextEdit.app ] || [ -d /Applications/TextEdit.app ]; then
  say "  TextEdit         available"
else
  say "  TextEdit         NOT found"
  fail_pre=1
fi

for tool in xcodegen xcodebuild osascript python3; do
  command -v "$tool" >/dev/null 2>&1 || { say "  $tool        NOT found"; fail_pre=1; }
done

CORRECT="$(defaults read com.apple.TextEdit NSAutomaticSpellingCorrectionEnabled 2>/dev/null || echo unset)"
if [ "$CORRECT" = "0" ]; then
  say "  autocorrect      off in TextEdit"
elif [ "${T10_DISABLE_AUTOCORRECT:-0}" = "1" ]; then
  AUTOCORRECT_RESTORE="${CORRECT/unset/__absent__}"
  defaults write com.apple.TextEdit NSAutomaticSpellingCorrectionEnabled -bool false
  say "  autocorrect      switched off for this run (was: $CORRECT), restored on exit"
else
  say "  autocorrect      TextEdit value is '$CORRECT'; spelling autocorrect can change typed words."
  say "                   Turn off Edit > Spelling and Grammar > Correct Spelling Automatically,"
  say "                   or run with T10_DISABLE_AUTOCORRECT=1"
fi
say "  the first run may ask for Automation / Accessibility permission for the app running this script"
say "  Receiver idle timeout is 30 minutes; press 開始接收 again if a long run stalls"

if [ "$fail_pre" -ne 0 ]; then
  say "Preconditions failed."
  exit 2
fi

# ---------------------------------------------------------------------------------------------------------------
# Build once
# ---------------------------------------------------------------------------------------------------------------
mkdir -p "$OUT"
if [ "$SKIP_BUILD" -eq 1 ]; then
  say "== Build skipped (--skip-build), using $DERIVED"
else
  say "== Build (log: $OUT/build.log)"
  (cd "$REPO_ROOT" && xcodegen generate) >"$OUT/xcodegen.log" 2>&1 || { say "xcodegen failed, see $OUT/xcodegen.log"; exit 3; }
  xcodebuild build-for-testing -project "$REPO_ROOT/RemoteKeyboard.xcodeproj" -scheme "$SCHEME" \
    -destination "id=$UDID" -allowProvisioningUpdates -derivedDataPath "$DERIVED" >"$OUT/build.log" 2>&1 </dev/null
  if ! grep -q "TEST BUILD SUCCEEDED" "$OUT/build.log"; then
    say "Build failed, see $OUT/build.log"
    say "If signing for the UI tests asks for it, run Product > Build For Testing once in Xcode with the iPhone selected."
    exit 3
  fi
  say "  build ok"
fi

# ---------------------------------------------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------------------------------------------
RESULTS="$OUT/results.tsv"
: >"$RESULTS"
OVERALL=0

case_list() {
  if [ "${#SELECTED[@]}" -eq 0 ]; then
    py list
  else
    local wanted
    for wanted in "${SELECTED[@]}"; do
      py list | awk -F'\t' -v w="$wanted" '$1 == w'
    done
  fi
}

# Waits for xcodebuild to finish, but not longer than the case limit.
wait_for_xcode() {
  local deadline=$(( $(date +%s) + CASE_TIMEOUT_S ))
  while kill -0 "$XCODE_PID" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      say "  timeout: stopping xcodebuild"
      kill "$XCODE_PID" 2>/dev/null
      sleep 2
      kill -9 "$XCODE_PID" 2>/dev/null
      break
    fi
    sleep 1
  done
  wait "$XCODE_PID" 2>/dev/null
  XCODE_RC=$?
}

# Not-ready case: wait for the pulse letter, wipe it, take the focus away, give it back later.
driver_notready() {
  local hist="$1" deadline=$(( $(date +%s) + CASE_TIMEOUT_S ))
  until grep -q '"text": "k"}' "$hist" 2>/dev/null; do
    kill -0 "$XCODE_PID" 2>/dev/null || return 0
    [ "$(date +%s)" -ge "$deadline" ] && return 0
    sleep 0.3
  done
  T_WIPE="$(now)"
  textedit_wipe "$DOC_NAME"
  finder_front
  say "  pulse seen: text wiped, Finder in front; Mac not ready for ${NOTREADY_HOLD_S}s"
  sleep "$NOTREADY_HOLD_S"
  textedit_focus "$DOC_NAME"
  T_REFOCUS="$(now)"
  say "  TextEdit focused again"
}

xcuitest_result() {
  local logfile="$1" case_name="$2" line
  line="$(grep -E "Test [Cc]ase .*${case_name}.* (passed|failed|skipped)" "$logfile" | tail -1)"
  case "$line" in
    *skipped*) echo SKIP ;;
    *passed*) echo PASS ;;
    *failed*) echo FAIL ;;
    *) if [ "${XCODE_RC:-1}" -eq 0 ] && grep -q "TEST EXECUTE SUCCEEDED" "$logfile"; then echo PASS; else echo FAIL; fi ;;
  esac
}

run_case() {
  local case_name="$1" steps="$2"
  local hist="$OUT/$case_name.history" xlog="$OUT/$case_name.xcodebuild.log"
  T_WIPE=""
  T_REFOCUS=""
  say "== $case_name (steps $steps)"

  DOC_NAME="$(textedit_new_document)"
  if [ -z "$DOC_NAME" ]; then
    say "  could not create a TextEdit document"
    printf '%s\t%s\t%s\t%s\t%s\n' "$case_name" "$steps" "NOT RUN" "FAIL" "no TextEdit document" >>"$RESULTS"
    OVERALL=1
    return
  fi
  textedit_focus "$DOC_NAME"
  textedit_plain_text
  textedit_focus "$DOC_NAME"

  python3 -I -c "$T10PY" poller "$hist" "$DOC_NAME" </dev/null >/dev/null 2>&1 &
  POLLER_PID=$!
  local t_start
  t_start="$(now)"
  sleep 1

  rm -rf "$OUT/$case_name.xcresult"
  xcodebuild test-without-building -project "$REPO_ROOT/RemoteKeyboard.xcodeproj" -scheme "$SCHEME" \
    -destination "id=$UDID" -derivedDataPath "$DERIVED" -resultBundlePath "$OUT/$case_name.xcresult" \
    -only-testing:"$TEST_CLASS/$case_name" >"$xlog" 2>&1 </dev/null &
  XCODE_PID=$!

  if [ "$case_name" = "testNotReadyGoesToDraft" ]; then
    driver_notready "$hist"
  fi
  wait_for_xcode
  XCODE_PID=""
  local t_end
  t_end="$(now)"
  sleep "$DRAIN_S"
  kill -TERM "$POLLER_PID" 2>/dev/null
  wait "$POLLER_PID" 2>/dev/null
  POLLER_PID=""

  local xr mac verdict detail marks
  xr="$(xcuitest_result "$xlog" "$case_name")"
  marks="$(printf '{"t_start": %s, "t_end": %s, "t_wipe": %s, "t_refocus": %s}' \
    "$t_start" "$t_end" "${T_WIPE:-null}" "${T_REFOCUS:-null}")"
  local launch_err=""
  if [ "$xr" = "FAIL" ] && ! grep -qE "Test [Cc]ase .*${case_name}.* started" "$xlog"; then
    launch_err="$(grep -m1 "encountered an error" "$xlog" | cut -c1-240)"
    [ -n "$launch_err" ] || launch_err="$(grep -m1 -E "Failed to (launch|install)|could not (be )?(launch|install|open)|bundle" "$xlog" | cut -c1-240)"
  fi
  if [ -n "$launch_err" ]; then
    mac="n/a"
    detail="xcodebuild could not start the test: $launch_err"
  elif [ "$xr" = "SKIP" ]; then
    mac="n/a"
    detail="skipped by the test: $(grep -E "skipped|XCTSkip" "$xlog" | head -1 | cut -c1-160)"
  else
    verdict="$(py check "$case_name" "$hist" "$marks")"
    mac="${verdict%%$'\t'*}"
    detail="${verdict#*$'\t'}"
  fi
  if [ "$xr" = "FAIL" ] && [ -z "$launch_err" ]; then
    detail="$detail; $(grep -E "error:|XCTAssert|failed" "$xlog" | grep -v "Test [Cc]ase" | head -2 | cut -c1-240 | tr '\n' ' ')"
  fi
  say "  xcuitest $xr, mac $mac: $detail"
  printf '%s\t%s\t%s\t%s\t%s\n' "$case_name" "$steps" "$xr" "$mac" "$detail" >>"$RESULTS"
  if [ "$xr" = "FAIL" ] || [ "$mac" = "FAIL" ]; then OVERALL=1; fi

  textedit_close_document "$DOC_NAME"
  DOC_NAME=""
}

while IFS=$'\t' read -r case_name steps <&3; do
  [ -n "$case_name" ] || continue
  run_case "$case_name" "$steps"
done 3< <(case_list)

# ---------------------------------------------------------------------------------------------------------------
# Receiver log: none of the typed test strings may appear (E2E step 40, Mac side)
# ---------------------------------------------------------------------------------------------------------------
say "== Receiver log (E2E step 40, Mac side)"
MINUTES=$(( ( $(date +%s) - STARTED_AT ) / 60 + 2 ))
LOGFILE="$OUT/receiver.log"
if /usr/bin/log show --last "${MINUTES}m" --info --debug \
  --predicate 'subsystem == "com.ansonhui.remotekeyboard.receiver"' >"$LOGFILE" 2>"$OUT/receiver.log.err"; then
  LINES="$(wc -l <"$LOGFILE" | tr -d ' ')"
  PATTERNS=()
  while IFS= read -r s; do PATTERNS+=(-e "$s"); done < <(py strings)
  HITS="$(grep -w -F "${PATTERNS[@]}" "$LOGFILE" | wc -l | tr -d ' ')"
  if [ "$HITS" -eq 0 ]; then
    say "  PASS: $LINES log lines from the last ${MINUTES} min, no test string in them"
    printf '%s\t%s\t%s\t%s\t%s\n' "Receiver log" "40 (Mac side)" "n/a" "PASS" "$LINES lines, no test string" >>"$RESULTS"
  else
    say "  FAIL: $HITS log lines contain a test string (see $LOGFILE)"
    printf '%s\t%s\t%s\t%s\t%s\n' "Receiver log" "40 (Mac side)" "n/a" "FAIL" "$HITS lines contain a test string" >>"$RESULTS"
    OVERALL=1
  fi
else
  say "  ERROR: could not read the log: $(head -1 "$OUT/receiver.log.err")"
  printf '%s\t%s\t%s\t%s\t%s\n' "Receiver log" "40 (Mac side)" "n/a" "ERROR" "log show failed" >>"$RESULTS"
  OVERALL=1
fi

# ---------------------------------------------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------------------------------------------
py csv "$RESULTS" "$OUT/summary.csv"
say ""
say "== Summary ($OUT/summary.csv)"
awk -F'\t' '{ printf "  %-34s xcuitest %-8s mac %-6s %s\n", $1, $3, $4, substr($5, 1, 90) }' "$RESULTS"
say ""
say "iPhone-side E2E steps not covered here stay manual (see e2e/E2E-T10-KEYBOARD.md); every 結果 there stays TBD until the user confirms."
if [ "$OVERALL" -eq 0 ]; then say "ALL AUTOMATED CASES PASSED"; else say "SOME CASES FAILED"; fi
exit "$OVERALL"
