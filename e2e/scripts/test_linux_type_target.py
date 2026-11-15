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


class CheckedOutputPath(unittest.TestCase):
    def test_refuses_outside(self):
        self.assertIsNone(target.checked_output_path("/etc/x"))


if __name__ == "__main__":
    unittest.main()
