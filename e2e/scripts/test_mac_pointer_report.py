"""Unit tests for mac_pointer_report.py (python3 -m unittest e2e/scripts/test_mac_pointer_report.py)."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import mac_pointer_report as mp  # noqa: E402

PREFIX = "2026-11-15 16:30:%02d.123 I  MacReceiver[812:9a1] [com.ansonhui.remotekeyboard.receiver:pointer] "
DIAG = ("pointer diag stalled=%d%% longest=%d squeezes=%d cb50=8ms cb95=17ms margin10=3ms margin50=9ms "
        "gain50=0.25 gain90=1.50 starve=%d starve95=%dms starvemax=%dms starvedt50=%dms starvegap50=%dms lag=30ms jit=%dms")
LINK = "pointer link rate=%d p50=15ms p95=31ms interval=15ms backlog=%dms"


def diag(sec, stalled, longest=2, squeezes=0, starve=(0, 0, 0, 0, 0), jit=0):
    return (PREFIX % sec) + DIAG % ((stalled, longest, squeezes) + tuple(starve) + (jit,))


def link(sec, rate, backlog=0):
    return (PREFIX % sec) + LINK % (rate, backlog)


class FilterTests(unittest.TestCase):
    def test_keeps_only_the_four_pointer_events_and_drops_the_log_prefix(self):
        lines = [
            "Timestamp               Ty Process[PID:TID]",
            diag(1, 3),
            (PREFIX % 2) + "pointer open",
            (PREFIX % 3) + "pointer packet rejected reason=bad",
            link(4, 66),
            (PREFIX % 5) + "pointer closed reason=lost packets=10 rejected=0",
            (PREFIX % 6) + "pointer open refused",
        ]
        kept = mp.filter_lines(lines)
        self.assertEqual([k.split(" ")[3] for k in kept], ["diag", "open", "link", "closed"])
        self.assertEqual(len(kept), 4)
        self.assertTrue(all(k.startswith("2026-11-15 16:30:") for k in kept))
        self.assertTrue(all("MacReceiver" not in k for k in kept))
        self.assertIn("pointer diag stalled=3 longest=2", kept[0])


class AggregateTests(unittest.TestCase):
    def test_count_median_and_max_per_numeric_field(self):
        kept = mp.filter_lines([diag(1, 2, 1), diag(2, 10, 5, 3), diag(3, 4, 2), link(4, 60, 5), link(5, 66, 20)])
        agg = mp.aggregate(kept)
        self.assertEqual(agg["stalled"], (3, 4, 10))
        self.assertEqual(agg["longest"], (3, 2, 5))
        self.assertEqual(agg["squeezes"], (3, 0, 3))
        self.assertEqual(agg["rate"], (2, 63, 66))
        self.assertEqual(agg["backlog"], (2, 12.5, 20))
        self.assertEqual(agg["gain50"], (3, 0.25, 0.25))

    def test_starvation_fields_are_aggregated(self):
        kept = mp.filter_lines([diag(1, 0, starve=(4, 10, 14, 80, 85)), diag(2, 0, starve=(8, 20, 40, 17, 85)), diag(3, 0, starve=(0, 0, 0, 0, 0))])
        self.assertIn("starve=4 starve95=10 starvemax=14 starvedt50=80 starvegap50=85", kept[0])
        agg = mp.aggregate(kept)
        self.assertEqual(agg["starve"], (3, 4, 8))
        self.assertEqual(agg["starve95"], (3, 10, 20))
        self.assertEqual(agg["starvemax"], (3, 14, 40))
        self.assertEqual(agg["starvedt50"], (3, 17, 80))
        self.assertEqual(agg["starvegap50"], (3, 85, 85))

    def test_jitter_allowance_is_aggregated(self):
        kept = mp.filter_lines([diag(1, 0, jit=0), diag(2, 0, jit=36), diag(3, 0, jit=60)])
        self.assertIn("lag=30 jit=36", kept[1])
        self.assertEqual(mp.aggregate(kept)["jit"], (3, 36, 60))

    def test_report_lists_every_known_field_and_marks_missing_ones(self):
        text = mp.format_report(mp.aggregate(mp.filter_lines([link(1, 60)])))
        for name in mp.FIELDS:
            self.assertIn(name, text)
        self.assertIn("rate", text)
        self.assertRegex(text, r"stalled\s+0")

    def test_no_text_beyond_numbers_and_event_names_is_kept(self):
        kept = mp.filter_lines([(PREFIX % 1) + "pointer diag stalled=1% secret=hello longest=2"])
        self.assertEqual(len(kept), 1)
        self.assertNotIn("hello", kept[0])


if __name__ == "__main__":
    unittest.main()
