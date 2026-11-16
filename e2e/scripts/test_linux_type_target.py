import importlib.util
import os
import unittest

_SPEC = importlib.util.spec_from_file_location("linux_type_target", os.path.join(os.path.dirname(__file__), "linux-type-target.py"))
target = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(target)  # gi is imported only inside the functions that need it


class AllowedPath(unittest.TestCase):
    def test_file_inside_base_dir(self):
        self.assertTrue(target.is_allowed_path("/tmp/rk-wl11/target.txt"))
        self.assertTrue(target.is_allowed_path("/tmp/rk-wl11/focus.txt"))

    def test_outside_base_dir(self):
        for path in ("/tmp/other/x.txt", "/etc/passwd", "/tmp/rk-wl11", "/tmp/rk-wl11/", "/tmp/rk-wl11-evil/x", "/home/u/x"):
            self.assertFalse(target.is_allowed_path(path), path)

    def test_dot_dot_escape(self):
        self.assertFalse(target.is_allowed_path("/tmp/rk-wl11/../x.txt"))
        self.assertFalse(target.is_allowed_path("/tmp/rk-wl11/a/../../x.txt"))

    def test_relative_and_empty(self):
        self.assertFalse(target.is_allowed_path("target.txt"))
        self.assertFalse(target.is_allowed_path(""))
        self.assertFalse(target.is_allowed_path(None))


class FocusResult(unittest.TestCase):
    def test_exactly_the_target_window_is_active(self):
        self.assertEqual(target.focus_result(["rk-type-target"]), "focus=True\n")

    def test_other_window_active(self):
        self.assertEqual(target.focus_result(["Terminal"]), "focus=False\n")

    def test_nothing_active(self):
        self.assertEqual(target.focus_result([]), "focus=False\n")

    def test_two_active_windows_is_not_focus(self):
        self.assertEqual(target.focus_result(["rk-type-target", "rk-type-target"]), "focus=False\n")
        self.assertEqual(target.focus_result(["rk-type-target", "Other"]), "focus=False\n")

    def test_title_must_match_exactly(self):
        for title in ("rk-type-target - x", "Rk-Type-Target", " rk-type-target", ""):
            self.assertEqual(target.focus_result([title]), "focus=False\n", title)

    def test_result_never_contains_a_foreign_title(self):
        self.assertNotIn("secret", target.focus_result(["secret document"]))


EDITOR = "gnome-text-editor"
NAME = "rk-editor-target.txt"
DIR = "(/tmp/rk-wl11)"
REAL = NAME + " " + DIR + "\u2015\u6587\u5b57\u7de8\u8f2f\u5668"


class EditorTitle(unittest.TestCase):
    def test_real_title_and_variants(self):
        for title in (REAL, NAME + " " + DIR, "\u2022 " + REAL, "\u2022" + REAL, "* " + REAL, "*" + NAME + " " + DIR,
                      NAME + " " + DIR + " - Text Editor", NAME + " " + DIR + " \u2014 Text Editor"):
            self.assertTrue(target.is_editor_title(title), title)

    def test_other_file_or_directory_is_refused(self):
        for title in ("other.txt " + DIR + "\u2015x", NAME + " (/tmp)\u2015x", NAME + " (/tmp/rk-wl11/sub)\u2015x",
                      NAME + " (/home/u)\u2015x", "x" + NAME + " " + DIR, NAME + ".bak " + DIR, "notes.txt (/tmp/rk-wl11)"):
            self.assertFalse(target.is_editor_title(title), title)

    def test_malformed_titles_are_refused(self):
        for title in ("", NAME, NAME + " ", " " + REAL, NAME + " " + DIR + " ", NAME + " " + DIR + "\u2015", NAME + " " + DIR + "\u2015 ",
                      NAME + " " + DIR + " - ", NAME + " " + DIR + "x", NAME + " " + DIR + " Text Editor", "Rk-Editor-Target.txt " + DIR,
                      "\u2022 \u2022 " + REAL, "** " + REAL, "\u2022  " + REAL, NAME + " " + DIR + "\u2015\n"):
            self.assertFalse(target.is_editor_title(title), repr(title))


class EditorFocus(unittest.TestCase):
    def test_exactly_the_editor_window_is_active(self):
        self.assertEqual(target.editor_focus_result([(EDITOR, REAL)]), "focus=True\n")
        self.assertEqual(target.editor_focus_result([("Text Editor", "\u2022 " + REAL)]), "focus=True\n")

    def test_wrong_app_with_the_right_title(self):
        self.assertEqual(target.editor_focus_result([("gedit", REAL)]), "focus=False\n")
        self.assertEqual(target.editor_focus_result([("rk-type-target", REAL)]), "focus=False\n")

    def test_wrong_title_nothing_or_two_windows(self):
        self.assertEqual(target.editor_focus_result([(EDITOR, "notes.txt")]), "focus=False\n")
        self.assertEqual(target.editor_focus_result([]), "focus=False\n")
        self.assertEqual(target.editor_focus_result([(EDITOR, REAL), (EDITOR, REAL)]), "focus=False\n")
        self.assertEqual(target.editor_focus_result([(EDITOR, REAL), ("Terminal", "t")]), "focus=False\n")

    def test_result_never_contains_a_foreign_title(self):
        self.assertNotIn("secret", target.editor_focus_result([(EDITOR, "secret document")]))


class EditorReadRefusal(unittest.TestCase):
    def test_one_window_one_text_view_is_allowed(self):
        self.assertIsNone(target.editor_read_refusal([(EDITOR, REAL)], 1))

    def test_no_matching_window(self):
        self.assertIsNotNone(target.editor_read_refusal([], 0))
        self.assertIsNotNone(target.editor_read_refusal([(EDITOR, "notes.txt")], 1))
        self.assertIsNotNone(target.editor_read_refusal([("gedit", REAL)], 1))

    def test_two_matching_windows(self):
        self.assertIsNotNone(target.editor_read_refusal([(EDITOR, REAL), (EDITOR, "\u2022 " + REAL)], 1))

    def test_other_editor_windows_do_not_matter_but_a_second_match_does(self):
        self.assertIsNone(target.editor_read_refusal([(EDITOR, REAL), (EDITOR, "notes.txt")], 1))

    def test_text_view_count_must_be_exactly_one(self):
        self.assertIsNotNone(target.editor_read_refusal([(EDITOR, REAL)], 0))
        self.assertIsNotNone(target.editor_read_refusal([(EDITOR, REAL)], 2))


class EditorPaths(unittest.TestCase):
    def test_editor_file_is_inside_base_dir(self):
        self.assertTrue(target.is_allowed_path(target.EDITOR_FILE))
        self.assertTrue(target.EDITOR_FILE.endswith("/" + NAME))


class CheckedOutputPath(unittest.TestCase):
    def test_refuses_outside(self):
        self.assertIsNone(target.checked_output_path("/etc/x"))


if __name__ == "__main__":
    unittest.main()
