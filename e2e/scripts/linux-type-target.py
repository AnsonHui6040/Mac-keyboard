#!/usr/bin/env python3
"""Dedicated typing target for the Linux receiver end-to-end runs.

Normal mode opens one GTK4 window titled "rk-type-target" with a multi-line text view and rewrites
/tmp/rk-wl11/target.txt on every buffer change. Reading that file is the read-back.

    linux-type-target.py                       open the window and keep running (stop it from outside)
    linux-type-target.py --check-focus FILE    write "focus=True" or "focus=False" to FILE and exit

--check-focus asks AT-SPI which window of the desktop is active. It is True only when exactly one window is active and its
title is exactly "rk-type-target"; no other title is read out or written. Every output path must be inside /tmp/rk-wl11/.
Needs python3-gi with Gtk 4.0 and (for --check-focus) Atspi 2.0 in the GNOME session, started with WAYLAND_DISPLAY set.
Exit codes: 0 done, 1 bad arguments, 2 AT-SPI unusable.
"""
import os
import posixpath
import sys

BASE_DIR = "/tmp/rk-wl11"
TARGET_FILE = BASE_DIR + "/target.txt"
WINDOW_TITLE = "rk-type-target"


def is_allowed_path(path):
    """True when path, once normalised, is a file below BASE_DIR (no dot-dot escape, not BASE_DIR itself)."""
    if not path or not posixpath.isabs(path):
        return False
    normal = posixpath.normpath(path)
    return normal.startswith(BASE_DIR + "/") and normal != BASE_DIR + "/"


def is_target_title(title):
    return title == WINDOW_TITLE


def focus_result(active_titles):
    """The file content for the titles of every active window: True only for exactly one, and it is the target."""
    return "focus=%s\n" % (len(active_titles) == 1 and is_target_title(active_titles[0]))


def ensure_base_dir():
    os.makedirs(BASE_DIR, mode=0o700, exist_ok=True)
    os.chmod(BASE_DIR, 0o700)


def checked_output_path(path):
    """The path to write to, or None. Also refuses a parent directory that resolves outside BASE_DIR (symlink)."""
    if not is_allowed_path(path):
        return None
    ensure_base_dir()
    parent = os.path.realpath(os.path.dirname(path))
    return path if parent == os.path.realpath(BASE_DIR) or parent.startswith(os.path.realpath(BASE_DIR) + os.sep) else None


def write_atomic(path, text):
    safe = checked_output_path(path)
    if safe is None:
        raise ValueError("output path outside " + BASE_DIR)
    tmp = safe + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.replace(tmp, safe)


def active_window_titles():
    import gi
    gi.require_version("Atspi", "2.0")
    from gi.repository import Atspi

    titles = []
    desktop = Atspi.get_desktop(0)
    for i in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(i)
        if app is None:
            continue
        for j in range(app.get_child_count()):
            frame = app.get_child_at_index(j)
            if frame is None or frame.get_role_name() not in ("frame", "window", "dialog"):
                continue
            if frame.get_state_set().contains(Atspi.StateType.ACTIVE):
                titles.append(frame.get_name() or "")
    return titles


def run_check_focus(result_path):
    if checked_output_path(result_path) is None:
        print("refused: the result file must be inside " + BASE_DIR + "/", file=sys.stderr)
        return 1
    try:
        titles = active_window_titles()
    except Exception:
        print("AT-SPI is not usable (python3-gi, gir1.2-atspi-2.0, accessibility bus)", file=sys.stderr)
        return 2
    write_atomic(result_path, focus_result(titles))
    return 0


def run_window():
    import gi
    gi.require_version("Gtk", "4.0")
    from gi.repository import Gtk

    ensure_base_dir()
    write_atomic(TARGET_FILE, "")

    def on_activate(app):
        window = Gtk.ApplicationWindow(application=app, title=WINDOW_TITLE)
        window.set_default_size(640, 360)
        view = Gtk.TextView()
        view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        buf = view.get_buffer()

        def on_changed(buffer):
            text = buffer.get_text(buffer.get_start_iter(), buffer.get_end_iter(), False)
            write_atomic(TARGET_FILE, text)

        buf.connect("changed", on_changed)
        window.set_child(view)
        window.present()
        view.grab_focus()

    app = Gtk.Application(application_id="local.rk.wl11.target")
    app.connect("activate", on_activate)
    return app.run([sys.argv[0]])


def main(argv):
    if len(argv) == 1:
        return run_window()
    if len(argv) == 3 and argv[1] == "--check-focus":
        return run_check_focus(argv[2])
    print(__doc__, file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
