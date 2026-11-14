#!/bin/sh
# Finds the receiver's zenity pairing question (title 「配對新手機」／"Pair new phone") through AT-SPI and presses Yes (or No).
# Usage: linux-confirm-pairing.sh <timeout_seconds> <result_file> <expect_sas|--any>
#   expect_sas  exactly 6 digits (123456 or "123 456"): answer Yes only when the dialog shows that code, otherwise No
#   --any       answer Yes whatever the code is (must be said explicitly; a missing or malformed value is an error)
# It only acts on a window titled 「配對新手機」／"Pair new phone" that has BOTH the 相符/Same code and the 不相符/Different
# buttons and shows exactly one standalone 6-digit code (not part of a longer digit run).
# Run it inside the GNOME session, e.g.:
#   systemd-run --user --collect --wait -E WAYLAND_DISPLAY=wayland-0 /path/linux-confirm-pairing.sh 120 /tmp/r.txt
# Needs python3-gi with Atspi 2.0 and the accessibility bus. Exit: 0 Yes, 3 No (code mismatch), 2 no dialog, 4 AT-SPI unusable or button missing, 1 bad arguments.
if [ "$#" -ne 3 ]; then
    echo "RKLINUX usage: linux-confirm-pairing.sh <timeout_seconds> <result_file> <6-digit code|--any>"
    exit 1
fi
TIMEOUT=$1
RESULT=$2
EXPECT=$3
case "$TIMEOUT" in ''|*[!0-9]*) echo "RKLINUX usage: timeout must be a whole number"; exit 1 ;; esac
if [ "$EXPECT" != "--any" ]; then
    if ! printf '%s' "$EXPECT" | grep -Eq '^([0-9]{6}|[0-9]{3} [0-9]{3})$'; then
        echo "RKLINUX usage: the expected code must be exactly 6 digits, or --any"
        exit 1
    fi
fi
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
export DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}

if ! python3 -c 'import gi; gi.require_version("Atspi","2.0")' 2>/dev/null; then
    echo "RKLINUX atspi-missing: need python3-gi and gir1.2-atspi-2.0; or press the zenity Yes button on the laptop yourself."
    exit 2
fi
# GTK only exposes accessibility to apps started after this is true; it resets when the accessibility bus restarts.
if gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus --method org.freedesktop.DBus.Properties.Get org.a11y.Status IsEnabled 2>/dev/null | grep -q false; then
    echo "RKLINUX note: accessibility was off; enabling it for this session only. A zenity opened before this will not be visible."
    gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus --method org.freedesktop.DBus.Properties.Set org.a11y.Status IsEnabled '<true>' >/dev/null 2>&1
fi

exec python3 - "$TIMEOUT" "$RESULT" "$EXPECT" <<'PY'
import re, sys, time
import gi
gi.require_version("Atspi", "2.0")
from gi.repository import Atspi

timeout, result = int(sys.argv[1]), sys.argv[2]
any_code = sys.argv[3] == "--any"
expect = None if any_code else sys.argv[3].replace(" ", "")
CODE = re.compile(r"(?<!\d)(\d{6}|\d{3} \d{3})(?!\d)")
YES = {"相符", "same code"}
NO = {"不相符", "different"}

def walk(node, depth=0):
    if depth > 12:
        return
    yield node
    for i in range(node.get_child_count()):
        try:
            child = node.get_child_at_index(i)
        except Exception:
            continue
        if child is not None:
            yield from walk(child, depth + 1)

def text_of(node):
    parts = [node.get_name() or ""]
    try:
        iface = node.get_text_iface()
        if iface:
            parts.append(Atspi.Text.get_text(iface, 0, iface.get_character_count()))
    except Exception:
        pass
    return "\n".join(parts)

def norm(name):
    return (name or "").replace("_", "").lower()

def find():
    desktop = Atspi.get_desktop(0)
    for app in (desktop.get_child_at_index(i) for i in range(desktop.get_child_count())):
        if app is None:
            continue
        for frame in (app.get_child_at_index(i) for i in range(app.get_child_count())):
            if frame is None or (frame.get_name() or "") not in ("配對新手機", "Pair new phone"):
                continue
            nodes = list(walk(frame))
            buttons = {norm(n.get_name()) for n in nodes if n.get_role_name() in ("button", "push button")}
            if not (buttons & YES and buttons & NO):
                continue
            codes = set()
            for n in nodes:
                for m in CODE.finditer(text_of(n)):
                    codes.add(m.group(1).replace(" ", ""))
            if len(codes) == 1:
                return codes.pop(), nodes
    return None

def press(nodes, names):
    for n in nodes:
        if n.get_role_name() in ("button", "push button") and norm(n.get_name()) in names:
            n.do_action(0)
            return True
    return False

deadline = time.time() + timeout
while time.time() < deadline:
    try:
        found = find()
    except Exception as e:
        found = None
    if found:
        digits, nodes = found
        yes = any_code or expect == digits
        if not press(nodes, YES if yes else NO):
            print("RKLINUX button-not-found"); sys.exit(4)
        open(result, "w").write("sas=%s\nanswer=%s\n" % (digits, "yes" if yes else "no"))
        print("RKLINUX sas=%s answer=%s" % (digits, "yes" if yes else "no"))
        sys.exit(0 if yes else 3)
    time.sleep(0.4)
print("RKLINUX no-dialog")
sys.exit(2)
PY
