#!/bin/sh
# Finds the receiver's zenity pairing question ("Remote Keyboard") through AT-SPI and presses Yes (or No).
# Usage: linux-confirm-pairing.sh [timeout_seconds=120] [result_file=/tmp/rk-pair-result.txt] [expect_sas]
# Run it inside the GNOME session, e.g.:
#   systemd-run --user --collect --wait -E WAYLAND_DISPLAY=wayland-0 /path/linux-confirm-pairing.sh 120 /tmp/r.txt
# Needs python3-gi with Atspi 2.0 and the accessibility bus. Exit: 0 Yes, 3 No (code mismatch), 2 no dialog, 4 AT-SPI unusable.
TIMEOUT=${1:-120}
RESULT=${2:-/tmp/rk-pair-result.txt}
EXPECT=${3:-}
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

timeout, result, expect = int(sys.argv[1]), sys.argv[2], re.sub(r"\D", "", sys.argv[3])

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

def find():
    desktop = Atspi.get_desktop(0)
    for app in (desktop.get_child_at_index(i) for i in range(desktop.get_child_count())):
        if app is None:
            continue
        for frame in (app.get_child_at_index(i) for i in range(app.get_child_count())):
            if frame is None or (frame.get_name() or "") != "Remote Keyboard":
                continue
            nodes = list(walk(frame))
            digits = None
            for n in nodes:
                m = re.search(r"(\d{3})\s?(\d{3})", text_of(n))
                if m:
                    digits = m.group(1) + m.group(2)
                    break
            if digits:
                return digits, nodes
    return None

def press(nodes, names):
    for n in nodes:
        if n.get_role_name() in ("button", "push button") and (n.get_name() or "").replace("_", "").lower() in names:
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
        yes = not expect or expect == digits
        names = {"yes", "是", "是(y)", "確定", "ok"} if yes else {"no", "否", "否(n)", "取消", "cancel"}
        if not press(nodes, names):
            print("RKLINUX button-not-found"); sys.exit(4)
        open(result, "w").write("sas=%s\nanswer=%s\n" % (digits, "yes" if yes else "no"))
        print("RKLINUX sas=%s answer=%s" % (digits, "yes" if yes else "no"))
        sys.exit(0 if yes else 3)
    time.sleep(0.4)
print("RKLINUX no-dialog")
sys.exit(2)
PY
