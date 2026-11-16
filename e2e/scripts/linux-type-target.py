#!/usr/bin/env python3
"""Dedicated typing target for the Linux receiver end-to-end runs.

Normal mode opens one GTK4 window titled "rk-type-target" with a multi-line text view and rewrites
/tmp/rk-wl11/target.txt on every buffer change. Reading that file is the read-back.

    linux-type-target.py                       open the window and keep running (stop it from outside)
    linux-type-target.py --check-focus FILE    write "focus=True" or "focus=False" to FILE and exit
    linux-type-target.py --editor-check-focus FILE   same, for the GNOME Text Editor target (see below)
    linux-type-target.py --editor-read FILE    write the text of the GNOME Text Editor target to FILE, or "refused"

--check-focus asks AT-SPI which window of the desktop is active. It is True only when exactly one window is active and its
title is exactly "rk-type-target"; no other title is read out or written. Every output path must be inside /tmp/rk-wl11/.
Second target kind: GNOME Text Editor opened on /tmp/rk-wl11/rk-editor-target.txt (started from outside, for example
`gnome-text-editor --standalone`). --editor-check-focus is True only when exactly one window is active, it belongs to the Text
Editor application and its title is the file name and its folder, `rk-editor-target.txt (/tmp/rk-wl11)`, optionally behind one
modified marker ("\u2022" or "*", optionally one space) and optionally followed by the app name after U+2015, " - " or " \u2014 "
(the zh_TW session shows `rk-editor-target.txt (/tmp/rk-wl11)\u2015文字編輯器`).
--editor-read writes the content of the one multi-line text view of the one window with that title, and writes "refused" instead
when there is not exactly one such window or not exactly one such text view. No other window is read.
Needs python3-gi with Gtk 4.0 and (for --check-focus) Atspi 2.0 in the GNOME session, started with WAYLAND_DISPLAY set.
Exit codes: 0 done, 1 bad arguments, 2 AT-SPI unusable, 3 --editor-read refused.
"""
import os
import posixpath
import re
import sys

BASE_DIR = "/tmp/rk-wl11"
TARGET_FILE = BASE_DIR + "/target.txt"
WINDOW_TITLE = "rk-type-target"
EDITOR_NAME = "rk-editor-target.txt"
EDITOR_FILE = BASE_DIR + "/" + EDITOR_NAME
# AT-SPI application names GNOME Text Editor may register under (program name, display name, application id).
EDITOR_APPS = ("gnome-text-editor", "Text Editor", "org.gnome.TextEditor")
EDITOR_TITLE_RE = re.compile(
    r"^(?:[\u2022*] ?)?" + re.escape(EDITOR_NAME) + r" \(" + re.escape(BASE_DIR) + r"\)(?:(?:\u2015| - | \u2014 )\S.*)?\Z"
)


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


def is_editor_title(title):
    """The Text Editor window title for the dedicated file: its name, behind at most one modified marker."""
    return isinstance(title, str) and EDITOR_TITLE_RE.match(title) is not None


def is_editor_window(app_name, title):
    return app_name in EDITOR_APPS and is_editor_title(title)


def editor_focus_result(active_windows):
    """The file content for the (application, title) pairs of every active window: True only for exactly one, the target."""
    return "focus=%s\n" % (len(active_windows) == 1 and is_editor_window(*active_windows[0]))


def editor_read_refusal(windows, text_view_count):
    """None when reading is allowed, otherwise a short reason. windows: (application, title) of every window of the desktop."""
    matching = sum(1 for app, title in windows if is_editor_window(app, title))
    if matching != 1:
        return "windows=%d" % matching
    if text_view_count != 1:
        return "text_views=%d" % text_view_count
    return None


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


def _frames():
    """Yields (application name, frame accessible, is active) for every top-level window of the desktop."""
    import gi
    gi.require_version("Atspi", "2.0")
    from gi.repository import Atspi

    desktop = Atspi.get_desktop(0)
    for i in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(i)
        if app is None:
            continue
        for j in range(app.get_child_count()):
            frame = app.get_child_at_index(j)
            if frame is None or frame.get_role_name() not in ("frame", "window", "dialog"):
                continue
            yield app.get_name() or "", frame, frame.get_state_set().contains(Atspi.StateType.ACTIVE)


def active_windows():
    return [(app, frame.get_name() or "") for app, frame, active in _frames() if active]


def multi_line_text_views(frame):
    """Every showing multi-line text widget below the frame (the document view; a search entry is single-line)."""
    import gi
    gi.require_version("Atspi", "2.0")
    from gi.repository import Atspi

    found, stack = [], [frame]
    while stack:
        node = stack.pop()
        for k in range(node.get_child_count()):
            child = node.get_child_at_index(k)
            if child is None:
                continue
            states = child.get_state_set()
            if (child.get_role_name() in ("text", "textbox", "text view") and states.contains(Atspi.StateType.MULTI_LINE)
                    and states.contains(Atspi.StateType.SHOWING) and child.get_text_iface() is not None):
                found.append(child)
            stack.append(child)
    return found


def run_editor_check_focus(result_path):
    if checked_output_path(result_path) is None:
        print("refused: the result file must be inside " + BASE_DIR + "/", file=sys.stderr)
        return 1
    try:
        windows = active_windows()
    except Exception:
        print("AT-SPI is not usable (python3-gi, gir1.2-atspi-2.0, accessibility bus)", file=sys.stderr)
        return 2
    write_atomic(result_path, editor_focus_result(windows))
    return 0


def run_editor_read(out_path):
    if checked_output_path(out_path) is None:
        print("refused: the output file must be inside " + BASE_DIR + "/", file=sys.stderr)
        return 1
    try:
        frames = list(_frames())
        windows = [(app, frame.get_name() or "") for app, frame, _ in frames]
        matching = [frame for app, frame, _ in frames if is_editor_window(app, frame.get_name() or "")]
        views = multi_line_text_views(matching[0]) if len(matching) == 1 else []
        reason = editor_read_refusal(windows, len(views))
        if reason is not None:
            write_atomic(out_path, "refused\n")
            print("refused: " + reason, file=sys.stderr)
            return 3
        import gi
        gi.require_version("Atspi", "2.0")
        from gi.repository import Atspi
        text = Atspi.Text.get_text(views[0].get_text_iface(), 0, Atspi.Text.get_character_count(views[0].get_text_iface()))
    except Exception:
        print("AT-SPI is not usable (python3-gi, gir1.2-atspi-2.0, accessibility bus)", file=sys.stderr)
        return 2
    write_atomic(out_path, text)
    return 0


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
    if len(argv) == 3 and argv[1] == "--editor-check-focus":
        return run_editor_check_focus(argv[2])
    if len(argv) == 3 and argv[1] == "--editor-read":
        return run_editor_read(argv[2])
    print(__doc__, file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
