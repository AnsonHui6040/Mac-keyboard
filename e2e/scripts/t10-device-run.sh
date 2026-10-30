#!/usr/bin/env bash
# T10 automated device acceptance: runs KeyboardT10UITests on the iPhone, one case at a time, and watches what
# arrives in a fresh TextEdit document on this Mac.
#
#   e2e/scripts/t10-device-run.sh [--list] [--skip-build] [case ...]
#
# Environment:
#   T10_UDID              device UDID (default 00008150-000C65DA26C0401C)
#   T10_OUT               scratch directory (default /tmp/t10-device-run); each run writes into run.<time>.<pid> inside it
#   T10_CASE_TIMEOUT_S    per-case limit for xcodebuild (default 480)
#   T10_NOTREADY_HOLD_S   how long the Mac stays not ready in the not-ready case (default 15)
#   T10_LOCK_WAIT_S       how long to wait for an unlock when the iPhone is locked (default 60)
#
# The script creates a new TextEdit document for each case and addresses that window by its window id only. It reads,
# wipes and closes (without saving) only that window, and never falls back to a name. The expectations of every case
# live in ONE place: the CASES table inside T10PY below.
# testFieldKinds and testDraftCap are not in the default run (deferred to T16 manual testing); name them to run them.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
UDID="${T10_UDID:-00008150-000C65DA26C0401C}"
OUT="${T10_OUT:-/tmp/t10-device-run}"
DERIVED="$OUT/derived"
CASE_TIMEOUT_S="${T10_CASE_TIMEOUT_S:-480}"
NOTREADY_HOLD_S="${T10_NOTREADY_HOLD_S:-15}"
LOCK_WAIT_S="${T10_LOCK_WAIT_S:-60}"
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
import csv, json, os, signal, string, subprocess, sys, time

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
# min_quiet: seconds after the poller started before the first text may appear. It is only a sanity bound (a draft
# sent at once would show up long before): the script has no timestamp of the real send, so "nothing on the Mac before
# the send" is NOT proven by it, only that nothing stray was typed.
# default False: not run unless named (deferred to T16 manual testing). skip_ok: a skip by the test is not a failure.
# In the "empty" cases that run with needMac False (testAccessibilityLabels, testPersistence) the Mac is not
# guaranteed ready, so an empty TextEdit only shows that nothing arrived, not that a leak would have been visible.
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
    ("testFieldKinds",                 "32-33", "empty",    {"default": False, "skip_ok": True}),
    ("testDraftCap",                   "31",    "empty",    {"default": False, "skip_ok": True}),
]
MAX_GAP_S = 3.0   # two samples further apart than this mean the poller or osascript stalled

# Fixed strings the keyboard sends or drafts. None of them may appear in the Receiver log (E2E step 40, Mac side).
TYPED = ["hello", "AABCde", "abcd", "abXcd", "abXcYd", "abXcab", "cdd", "ABC", "abc", "xzq", "mpn", LETTERS30]


def log_strings():
    return sorted({s for s in TYPED if len(s) > 2})


def load(path):
    """Every sample as (time, text or None), plus whether the poller wrote its end marker."""
    samples, ended = [], False
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        rec = json.loads(line)
        if rec.get("end"):
            ended = True
        else:
            samples.append((rec["t"], rec.get("text")))
    return samples, ended


def value_at(rows, t):
    current = None
    for ts, text in rows:
        if ts <= t:
            current = text
    return current


def coverage(samples, ended, marks):
    """Poll-quality problems that make any verdict meaningless; checked for every rule."""
    if not samples:
        return "no samples (TextEdit window not readable)"
    if not ended:
        return "poller did not end cleanly (end marker missing)"
    first = next((i for i, (_, s) in enumerate(samples) if s is not None), None)
    if first is None:
        return "TextEdit window never readable"
    lost = [t for t, s in samples[first:] if s is None]
    if lost:
        return "the test window became unreadable (None sample) %.1f s after the first read" % (lost[0] - samples[first][0])
    for (t1, _), (t2, _) in zip(samples, samples[1:]):
        if t2 - t1 > MAX_GAP_S:
            return "samples %.1f s apart (limit %.0f s), poll stalled" % (t2 - t1, MAX_GAP_S)
    if marks.get("t_end") is not None and samples[-1][0] < marks["t_end"]:
        return "polling stopped before the test ended"
    return None


def check(case, hist_path, marks):
    spec = next((c for c in CASES if c[0] == case), None)
    if spec is None:
        return False, "unknown case"
    _, _, rule, p = spec
    samples, ended = load(hist_path)
    problem = coverage(samples, ended, marks)
    if problem:
        return False, problem
    rows = [(t, s) for t, s in samples if s is not None]
    final = rows[-1][1]
    non_empty = [(t, s) for t, s in rows if s != ""]
    t0 = rows[0][0]

    if rule == "empty":
        if non_empty:
            return False, "text appeared: %r" % non_empty[0][1]
        return True, "TextEdit stayed empty"

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


def log_events(log_path, windows_path):
    """Every case that expects text on the Mac needs at least one `event kind=` line in its own time window.
    windows_path holds `case<TAB>start<TAB>end` (epoch seconds) for each case that was not skipped."""
    import datetime
    stamps = []
    for line in open(log_path, encoding="utf-8", errors="replace"):
        if "event kind=" not in line:
            continue
        try:
            stamps.append(datetime.datetime.strptime(line[:31].strip(), "%Y-%m-%d %H:%M:%S.%f%z").timestamp())
        except ValueError:
            continue
    missing, checked = [], 0
    for line in open(windows_path, encoding="utf-8"):
        name, start, end = line.rstrip("\n").split("\t")
        spec = next((c for c in CASES if c[0] == name), None)
        if spec is None or spec[2] not in ("final", "delete", "notready"):
            continue
        checked += 1
        if not any(float(start) - 1 <= t <= float(end) + 1 for t in stamps):
            missing.append(name)
    if missing:
        return False, "no 'event kind=' line in the log during: " + ", ".join(missing)
    return True, "%d event lines, every case that expects Mac text has some (%d cases)" % (len(stamps), checked)


def poller(out, window_id, limit_s):
    """Samples the text of the test window (by window id, never by name) every 0.3 s. Every sample is written.
    Stops on SIGTERM, when the parent is gone (ppid 1) or after limit_s seconds."""
    script = 'tell application "TextEdit" to get text of document of (first window whose id is %d)' % int(window_id)
    stop = []
    signal.signal(signal.SIGTERM, lambda *a: stop.append(1))
    deadline = time.time() + float(limit_s)
    with open(out, "w", buffering=1, encoding="utf-8") as f:
        while not stop and os.getppid() != 1 and time.time() < deadline:
            try:
                r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=5)
                text = None
                if r.returncode == 0:
                    text = r.stdout[:-1] if r.stdout.endswith("\n") else r.stdout
                    text = text.replace("\r\n", "\n").replace("\r", "\n")
            except subprocess.TimeoutExpired:
                text = None
            f.write(json.dumps({"t": time.time(), "text": text}) + "\n")
            time.sleep(0.3)
        f.write(json.dumps({"t": time.time(), "end": True}) + "\n")


def main(argv):
    cmd = argv[1]
    if cmd in ("list", "listall"):
        for name, steps, _, p in CASES:
            if cmd == "listall" or p.get("default", True):
                print("%s\t%s" % (name, steps))
    elif cmd == "events":
        ok, detail = log_events(argv[2], argv[3])
        print(("PASS" if ok else "FAIL") + "\t" + detail)
    elif cmd == "skipok":
        print("\n".join(name for name, _, _, p in CASES if p.get("skip_ok")))
    elif cmd == "describe":
        for name, steps, rule, p in CASES:
            print("%-34s steps %-6s %-8s %s" % (name, steps, rule, json.dumps(p, ensure_ascii=False)))
    elif cmd == "strings":
        print("\n".join(log_strings()))
    elif cmd == "now":
        print("%.3f" % time.time())
    elif cmd == "poller":
        poller(argv[2], argv[3], argv[4])
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

if [ "${#SELECTED[@]}" -gt 0 ]; then
  KNOWN="$(py listall | cut -f1)"
  for wanted in "${SELECTED[@]}"; do
    if ! printf '%s\n' "$KNOWN" | grep -qx "$wanted"; then
      echo "unknown case: $wanted (see --list)" >&2
      exit 2
    fi
  done
fi

# ---------------------------------------------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------------------------------------------
say() { printf '%s\n' "$*"; }
now() { py now; }

WIN_ID=""
POLLER_PID=""
XCODE_PID=""
STARTED_AT="$(date +%s)"
START_TS="$(date '+%Y-%m-%d %H:%M:%S')"
ABORT=0
LOCKED=0
CASES_RUN=0
RUN_DIR="$OUT/run.$(date +%Y%m%d-%H%M%S).$$"

# Runs AppleScript from stdin. Arguments are passed to `on run argv`.
osa() { osascript - "$@" 2>/dev/null; }

# The test document is an empty file in this run's directory, opened in TextEdit. TextEdit then edits it in place, so
# nothing is autosaved to iCloud Drive, the text is plain text, and ownership is checkable: a document is ours only if
# its path is inside $RUN_DIR. The test texts therefore stay under the run directory.
HANDLERS='-- Ours: the document has a path and that path is inside the run directory.
on ownsDoc(d, dirPath)
  try
    tell application "TextEdit" to set pt to path of d
    return (pt as text) starts with dirPath
  on error
    return false
  end try
end ownsDoc

on isEmptyDoc(d)
  tell application "TextEdit" to set t to text of d
  return (length of t) is 0
end isEmptyDoc
'

# Opens the (empty) file $1 in TextEdit and prints the id of the one new window, or ERR. The id is found by identity:
# the window ids before and after must differ by exactly one, that document's path must be the file, and it must be
# empty. Any window opened here that fails that is closed again (only if inside the run directory).
textedit_new_window() {
  { printf '%s\n' "$HANDLERS"; cat <<'AS'
on run argv
  set targetPath to item 1 of argv
  set dirPath to item 2 of argv
  set targetFile to POSIX file targetPath
  tell application "TextEdit"
    activate
    set beforeIds to id of every window
    open targetFile
    delay 0.8
    set afterIds to id of every window
    set newIds to {}
    repeat with k from 1 to count of afterIds
      set candidate to item k of afterIds
      if beforeIds does not contain candidate then set end of newIds to candidate
    end repeat
    set good to false
    if (count of newIds) is 1 then
      set d to document of (first window whose id is (item 1 of newIds))
      try
        tell application "TextEdit" to set pt to path of d
        if (pt as text) is targetPath and my isEmptyDoc(d) then set good to true
      end try
    end if
    if good then return (item 1 of newIds) as string
    repeat with k from 1 to count of newIds
      try
        set d to document of (first window whose id is (item k of newIds))
        if my ownsDoc(d, dirPath) then close d saving no
      end try
    end repeat
    return "ERR"
  end tell
end run
AS
  } | osa "$1" "$RUN_DIR/"
}

# Closes the test window's document without saving. Does nothing when that window no longer exists or its document
# is not inside the run directory.
textedit_close_window() {
  [ -n "$1" ] || return 0
  { printf '%s\n' "$HANDLERS"; cat <<'AS'
on run argv
  set wid to (item 1 of argv) as integer
  tell application "TextEdit"
    try
      set d to document of (first window whose id is wid)
      if my ownsDoc(d, item 2 of argv) then close d saving no
    end try
  end tell
end run
AS
  } | osa "$1" "$RUN_DIR/" >/dev/null
}

# Empties the test window's document. Fails (non-zero) when that window no longer exists or is not inside the run directory.
textedit_wipe() {
  { printf '%s\n' "$HANDLERS"; cat <<'AS'
on run argv
  set wid to (item 1 of argv) as integer
  tell application "TextEdit"
    set d to document of (first window whose id is wid)
    if not my ownsDoc(d, item 2 of argv) then error "the document is not in the run directory"
    set text of d to ""
  end tell
end run
AS
  } | osa "$1" "$RUN_DIR/" >/dev/null
}

# Brings the test window to the front and, only if it really is the front window, puts the cursor in its text.
textedit_focus() {
  osa "$1" <<'AS' >/dev/null
on run argv
  set wid to (item 1 of argv) as integer
  tell application "TextEdit"
    activate
    try
      set index of (first window whose id is wid) to 1
    end try
  end tell
  delay 0.5
  tell application "TextEdit" to set fid to id of front window
  if fid is wid then
    tell application "System Events"
      tell process "TextEdit"
        set frontmost to true
        try
          set focused of text area 1 of scroll area 1 of window 1 to true
        end try
      end tell
    end tell
  end if
end run
AS
}

# Prints ok only when TextEdit is the frontmost application and its front window is the test window.
textedit_front_ok() {
  osa "$1" <<'AS'
on run argv
  set wid to (item 1 of argv) as integer
  tell application "System Events" to set fp to name of first process whose frontmost is true
  tell application "TextEdit" to set fid to id of front window
  if fp is "TextEdit" and fid is wid then return "ok"
  return "no"
end run
AS
}

finder_front() {
  osa <<'AS' >/dev/null
tell application "Finder" to activate
AS
}

cleanup() {
  [ -n "$POLLER_PID" ] && kill "$POLLER_PID" 2>/dev/null
  # Any poller of this run that is still alive (matched by its history path under this run's directory).
  pkill -f "poller $RUN_DIR/" 2>/dev/null
  [ -n "$XCODE_PID" ] && kill "$XCODE_PID" 2>/dev/null
  textedit_close_window "$WIN_ID"
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

say "  若 TextEdit 開啟『自動修正拼字』，最終文字可能被改寫；請在 TextEdit 的 編輯 > 拼字與文法 中關閉"
say "  the first run may ask for Automation / Accessibility permission for the app running this script"
say "  Receiver idle timeout is 30 minutes; press 開始接收 again if a long run stalls"

if [ "$fail_pre" -ne 0 ]; then
  say "Preconditions failed."
  exit 2
fi

# ---------------------------------------------------------------------------------------------------------------
# Build once
# ---------------------------------------------------------------------------------------------------------------
mkdir -p "$OUT" "$RUN_DIR"
RUN_DIR="$(cd "$RUN_DIR" && pwd -P)"
say "  run directory: $RUN_DIR"
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
RESULTS="$RUN_DIR/results.tsv"
: >"$RESULTS"
OVERALL=0

case_list() {
  if [ "${#SELECTED[@]}" -eq 0 ]; then
    py list
  else
    local wanted
    for wanted in "${SELECTED[@]}"; do
      py listall | awk -F'\t' -v w="$wanted" '$1 == w'
    done
  fi
}

# True while the xcodebuild log shows the device-locked message and no test has started.
device_locked_in_log() {
  grep -qE "Unlock .* to Continue" "$XLOG" 2>/dev/null && ! grep -qE "Test [Cc]ase .* started" "$XLOG" 2>/dev/null
}

# Waits for xcodebuild to finish, but not longer than the case limit. A locked iPhone shows up in the xcodebuild log
# as "Unlock ... to Continue": say so once, wait up to T10_LOCK_WAIT_S for the unlock (the timer restarts whenever the
# message is gone or a test has started), then stop xcodebuild. If xcodebuild ends on its own with that message and
# no test started, the case is also "iPhone locked".
wait_for_xcode() {
  local deadline=$(( $(date +%s) + CASE_TIMEOUT_S )) lock_since=0 told=0
  LOCKED=0
  while kill -0 "$XCODE_PID" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      say "  timeout: stopping xcodebuild"
      kill "$XCODE_PID" 2>/dev/null
      sleep 2
      kill -9 "$XCODE_PID" 2>/dev/null
      break
    fi
    if device_locked_in_log; then
      if [ "$told" -eq 0 ]; then
        say "  請解鎖 iPhone (waiting up to ${LOCK_WAIT_S} s)"
        told=1
      fi
      [ "$lock_since" -eq 0 ] && lock_since=$(date +%s)
      if [ $(( $(date +%s) - lock_since )) -ge "$LOCK_WAIT_S" ]; then
        say "  iPhone still locked: stopping xcodebuild"
        kill "$XCODE_PID" 2>/dev/null
        sleep 2
        kill -9 "$XCODE_PID" 2>/dev/null
        break
      fi
    else
      lock_since=0
    fi
    sleep 1
  done
  wait "$XCODE_PID" 2>/dev/null
  XCODE_RC=$?
  if device_locked_in_log; then LOCKED=1; fi
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
  textedit_wipe "$WIN_ID" || FRONT_FAIL="the test window could not be wiped (it no longer exists)"
  finder_front
  say "  pulse seen: text wiped, Finder in front; Mac not ready for ${NOTREADY_HOLD_S}s"
  sleep "$NOTREADY_HOLD_S"
  textedit_focus "$WIN_ID"
  T_REFOCUS="$(now)"
  if [ "$(textedit_front_ok "$WIN_ID")" != "ok" ]; then
    FRONT_FAIL="test window not frontmost after the refocus"
  fi
  say "  TextEdit focused again"
}

# PASS needs an explicit "passed" line for this case and "Executed 1 test" in the log; zero tests run is a failure.
xcuitest_result() {
  local logfile="$1" case_name="$2" line
  line="$(grep -E "Test [Cc]ase .*${case_name}.* (passed|failed|skipped)" "$logfile" | tail -1)"
  case "$line" in
    *skipped*) echo SKIP ;;
    *failed*) echo FAIL ;;
    *passed*)
      if grep -qE "Executed 1 test,? " "$logfile"; then echo PASS; else echo FAIL; fi ;;
    *) echo FAIL ;;
  esac
}

SKIP_OK="$(py skipok)"
BAD_SKIPS=0
DESIGN_SKIPS=0

record() { # case steps xcuitest mac details
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >>"$RESULTS"
}

run_case() {
  local case_name="$1" steps="$2"
  local hist="$RUN_DIR/$case_name.history" xlog="$RUN_DIR/$case_name.xcodebuild.log"
  XLOG="$xlog"
  T_WIPE=""
  T_REFOCUS=""
  FRONT_FAIL=""
  say "== $case_name (steps $steps)"

  : >"$RUN_DIR/$case_name.txt"
  WIN_ID="$(textedit_new_window "$RUN_DIR/$case_name.txt")"
  if ! [[ "$WIN_ID" =~ ^[0-9]+$ ]]; then
    say "  could not create a TextEdit document with a new, empty window (got '$WIN_ID')"
    record "$case_name" "$steps" "NOT RUN" "FAIL" "no TextEdit document"
    OVERALL=1
    ABORT=1
    WIN_ID=""
    return
  fi
  local tries=0
  textedit_focus "$WIN_ID"
  until [ "$(textedit_front_ok "$WIN_ID")" = "ok" ]; do
    tries=$((tries + 1))
    if [ "$tries" -ge 3 ]; then
      say "  test window not frontmost"
      record "$case_name" "$steps" "NOT RUN" "FAIL" "test window not frontmost"
      OVERALL=1
      textedit_close_window "$WIN_ID"
      WIN_ID=""
      return
    fi
    textedit_focus "$WIN_ID"
  done

  python3 -I -c "$T10PY" poller "$hist" "$WIN_ID" "$((CASE_TIMEOUT_S + 60))" </dev/null >/dev/null 2>&1 &
  POLLER_PID=$!
  local t_start
  t_start="$(now)"
  sleep 1

  rm -rf "$RUN_DIR/$case_name.xcresult"
  xcodebuild test-without-building -project "$REPO_ROOT/RemoteKeyboard.xcodeproj" -scheme "$SCHEME" \
    -destination "id=$UDID" -derivedDataPath "$DERIVED" -resultBundlePath "$RUN_DIR/$case_name.xcresult" \
    -only-testing:"$TEST_CLASS/$case_name" >"$xlog" 2>&1 </dev/null &
  XCODE_PID=$!

  if [ "$case_name" = "testNotReadyGoesToDraft" ]; then
    driver_notready "$hist"
  fi
  wait_for_xcode
  XCODE_PID=""
  local t_end
  t_end="$(now)"
  if [ "$(textedit_front_ok "$WIN_ID")" != "ok" ]; then
    FRONT_FAIL="${FRONT_FAIL:+$FRONT_FAIL; }test window no longer frontmost when the case ended"
  fi
  sleep "$DRAIN_S"
  kill -TERM "$POLLER_PID" 2>/dev/null
  wait "$POLLER_PID" 2>/dev/null
  POLLER_PID=""

  local xr mac verdict detail marks
  CASES_RUN=$((CASES_RUN + 1))
  if [ "$LOCKED" -eq 1 ]; then
    say "  iPhone locked"
    record "$case_name" "$steps" "FAIL" "n/a" "iPhone locked (unlock it and run again); remaining cases aborted"
    OVERALL=1
    ABORT=1
    textedit_close_window "$WIN_ID"
    WIN_ID=""
    return
  fi
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
    verdict="$(py check "$case_name" "$hist" "$marks" 2>&1)"
    mac="${verdict%%$'\t'*}"
    detail="${verdict#*$'\t'}"
    # A checker that crashed or printed nothing must not read as a pass.
    if [ "$mac" != "PASS" ] && [ "$mac" != "FAIL" ]; then
      detail="checker produced no verdict: $(printf '%s' "$verdict" | tail -1 | cut -c1-200)"
      mac="FAIL"
    fi
  fi
  if [ -n "$FRONT_FAIL" ]; then
    mac="FAIL"
    detail="$FRONT_FAIL; $detail"
  fi
  if [ "$xr" = "FAIL" ] && [ -z "$launch_err" ]; then
    detail="$detail; $(grep -E "error:|XCTAssert|failed" "$xlog" | grep -v "Test [Cc]ase" | head -2 | cut -c1-240 | tr '\n' ' ')"
  fi
  if [ "$xr" = "SKIP" ]; then
    if printf '%s\n' "$SKIP_OK" | grep -qx "$case_name"; then
      DESIGN_SKIPS=$((DESIGN_SKIPS + 1))
    else
      xr="SKIP (counts as failure)"
      BAD_SKIPS=$((BAD_SKIPS + 1))
      OVERALL=1
    fi
  fi
  say "  xcuitest $xr, mac $mac: $detail"
  record "$case_name" "$steps" "$xr" "$mac" "$detail"
  # Anything but PASS (or n/a for a skip by design or a launch error, which already fail through xcuitest) fails.
  if [ "$xr" = "FAIL" ] || { [ "$mac" != "PASS" ] && [ "$mac" != "n/a" ]; }; then OVERALL=1; fi
  if [[ "$xr" != SKIP* ]] && [ -z "$launch_err" ]; then
    printf '%s\t%s\t%s\n' "$case_name" "$t_start" "$(now)" >>"$RUN_DIR/windows.tsv"
  fi

  textedit_close_window "$WIN_ID"
  WIN_ID=""
}

while IFS=$'\t' read -r case_name steps <&3; do
  [ -n "$case_name" ] || continue
  run_case "$case_name" "$steps"
  if [ "$ABORT" -eq 1 ]; then
    say "== Aborting: the remaining cases were not run"
    break
  fi
done 3< <(case_list)
if [ "$CASES_RUN" -eq 0 ]; then
  say "== No case ran"
  record "(none)" "-" "NOT RUN" "FAIL" "no case was run"
  OVERALL=1
fi

# ---------------------------------------------------------------------------------------------------------------
# Receiver log: none of the typed test strings may appear (E2E step 40, Mac side). Every executed case that expects
# Mac text must also have an "event kind=" line in its own time window.
# ---------------------------------------------------------------------------------------------------------------
say "== Receiver log (E2E step 40, Mac side)"
LOGFILE="$RUN_DIR/receiver.log"
if /usr/bin/log show --start "$START_TS" --info --debug \
  --predicate 'subsystem == "com.ansonhui.remotekeyboard.receiver"' >"$LOGFILE" 2>"$RUN_DIR/receiver.log.err"; then
  LINES="$(wc -l <"$LOGFILE" | tr -d ' ')"
  PATTERNS=()
  while IFS= read -r str; do PATTERNS+=(-e "$str"); done < <(py strings)
  HITS="$(grep -w -F "${PATTERNS[@]}" "$LOGFILE" | wc -l | tr -d ' ')"
  # Event lines are required only for executed cases that expect Mac text (py events); a run of empty-rule cases
  # only needs a readable log, even an empty one.
  if [ "$HITS" -eq 0 ]; then
    WINDOWS="$RUN_DIR/windows.tsv"
    [ -f "$WINDOWS" ] || : >"$WINDOWS"
    EV="$(py events "$LOGFILE" "$WINDOWS" 2>&1)"
    if [ "${EV%%$'\t'*}" = "PASS" ]; then
      say "  PASS: $LINES log lines since $START_TS, no test string in them; ${EV#*$'\t'}"
      record "Receiver log" "40 (Mac side)" "n/a" "PASS" "$LINES lines, no test string; ${EV#*$'\t'}"
    else
      say "  FAIL: ${EV#*$'\t'}"
      record "Receiver log" "40 (Mac side)" "n/a" "FAIL" "${EV#*$'\t'}"
      OVERALL=1
    fi
  else
    say "  FAIL: $HITS log lines contain a test string (see $LOGFILE)"
    record "Receiver log" "40 (Mac side)" "n/a" "FAIL" "$HITS lines contain a test string"
    OVERALL=1
  fi
else
  say "  ERROR: could not read the log: $(head -1 "$RUN_DIR/receiver.log.err")"
  record "Receiver log" "40 (Mac side)" "n/a" "ERROR" "log show failed"
  OVERALL=1
fi

# ---------------------------------------------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------------------------------------------
py csv "$RESULTS" "$RUN_DIR/summary.csv"
cp "$RUN_DIR/summary.csv" "$OUT/summary.csv"
say ""
say "== Summary ($RUN_DIR/summary.csv, copy in $OUT/summary.csv)"
awk -F'\t' '{ printf "  %-34s xcuitest %-8s mac %-6s %s\n", $1, $3, $4, substr($5, 1, 90) }' "$RESULTS"
say ""
say "iPhone-side E2E steps not covered here stay manual (see e2e/E2E-T10-KEYBOARD.md); every 結果 there stays TBD until the user confirms."
if [ "$OVERALL" -eq 0 ]; then
  say "ALL AUTOMATED CASES PASSED ($DESIGN_SKIPS skipped by design)"
else
  say "SOME CASES FAILED/SKIPPED (bad skips: $BAD_SKIPS)"
fi
exit "$OVERALL"
