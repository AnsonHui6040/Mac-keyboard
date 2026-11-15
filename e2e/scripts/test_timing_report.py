"""Unit tests for timing_report.py (python3 -m unittest e2e/scripts/test_timing_report.py)."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import timing_report as tr  # noqa: E402

BOUNDS = ["b2", "b5", "b10", "b15", "b20", "b30", "b40", "b50", "b75", "b150", "bover"]


def line(ev, wall="2026-11-15T00:20:15.529Z", **fields):
    """Build a receiver log line; fields are written in insertion order."""
    kv = " ".join("%s=%s" % (k, v) for k, v in fields.items())
    return "wall=%s mono_ms=12770256 lvl=info ev=%s conn=40 %s" % (wall, ev, kv)


def hist(n_buckets, **extra):
    """n_buckets: counts for b2..bover in order (11 values). n is their sum."""
    fields = {"n": sum(n_buckets), "p50_us": 1000, "p90_us": 2000, "p99_us": 3000, "max_us": 4000}
    fields.update(zip(BOUNDS, n_buckets))
    fields.update(extra)
    return fields


class ParseLineTests(unittest.TestCase):
    def test_pointer_timing_line_is_parsed_into_event_and_integer_fields(self):
        got = tr.parse_line(line("pointer_timing", **hist([1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0], idle=7)))
        self.assertEqual(got[0], "pointer_timing")
        self.assertEqual(got[1]["n"], 3)
        self.assertEqual(got[1]["b5"], 2)
        self.assertEqual(got[1]["idle"], 7)

    def test_meta_fields_are_not_counted(self):
        _, fields = tr.parse_line(line("pointer_timing", **hist([1] + [0] * 10)))
        for meta in ("conn", "mono_ms", "wall", "lvl"):
            self.assertNotIn(meta, fields)

    def test_event_names_starting_with_pointer_timing_are_accepted(self):
        got = tr.parse_line(line("pointer_timing_send", n=1, b2=1))
        self.assertEqual(got[0], "pointer_timing_send")

    def test_ble_rx_timing_is_accepted(self):
        self.assertEqual(tr.parse_line(line("ble_rx_timing", n=1, b2=1))[0], "ble_rx_timing")

    def test_portal_motion_timing_is_found_behind_a_stamped_prefix(self):
        stamped = "2026-11-15 00:20:16 [injector] " + line("portal_motion_timing", n=2, b5=2)
        got = tr.parse_line(stamped)
        self.assertEqual(got[0], "portal_motion_timing")
        self.assertEqual(got[1]["b5"], 2)

    def test_other_events_are_ignored(self):
        self.assertIsNone(tr.parse_line(line("pointer_move", n=1)))
        self.assertIsNone(tr.parse_line("not a log line at all"))
        self.assertIsNone(tr.parse_line(""))

    def test_non_integer_values_are_skipped(self):
        _, fields = tr.parse_line(line("pointer_timing", n=1, b2=1, note="abc", ratio="1.5"))
        self.assertNotIn("note", fields)
        self.assertNotIn("ratio", fields)


class AggregateTests(unittest.TestCase):
    def setUp(self):
        self.lines = [
            line("pointer_timing", **hist([10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], idle=1, p50_us=100)),
            line("pointer_timing", **hist([0, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0], idle=2, p50_us=300)),
            line("pointer_timing", **hist([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 10], idle=4, p50_us=200, max_us=9000)),
            "garbage",
        ]

    def test_strokes_are_counted_per_event(self):
        agg = tr.aggregate(self.lines)
        self.assertEqual(agg["pointer_timing"]["lines"], 3)

    def test_buckets_and_n_are_summed(self):
        h = tr.aggregate(self.lines)["pointer_timing"]["hists"][""]
        self.assertEqual(h["n"], 30)
        self.assertEqual(h["buckets"][0], 10)
        self.assertEqual(h["buckets"][1], 10)
        self.assertEqual(h["buckets"][10], 10)

    def test_plain_integer_keys_are_summed_as_counts(self):
        self.assertEqual(tr.aggregate(self.lines)["pointer_timing"]["counts"]["idle"], 7)

    def test_us_keys_report_median_and_max_across_strokes(self):
        us = tr.aggregate(self.lines)["pointer_timing"]["us"]
        self.assertEqual(us["p50_us"], (200, 300))
        self.assertEqual(us["max_us"], (4000, 9000))

    def test_events_are_kept_apart(self):
        agg = tr.aggregate(self.lines + [line("ble_rx_timing", n=1, b2=1)])
        self.assertEqual(set(agg), {"pointer_timing", "ble_rx_timing"})
        self.assertEqual(agg["ble_rx_timing"]["lines"], 1)

    def test_prefixed_histograms_are_aggregated_separately(self):
        fields = {"n": 2, "b2": 2, "call_n": 3, "call_b5": 1, "call_b10": 2, "call_p50_us": 800}
        agg = tr.aggregate([line("pointer_timing", **fields)])["pointer_timing"]
        self.assertEqual(agg["hists"][""]["n"], 2)
        self.assertEqual(agg["hists"]["call"]["n"], 3)
        self.assertEqual(agg["hists"]["call"]["buckets"][1], 1)
        self.assertEqual(agg["hists"]["call"]["buckets"][2], 2)
        self.assertIn("call_p50_us", agg["us"])
        self.assertNotIn("call_n", agg["counts"])
        self.assertNotIn("call_b5", agg["counts"])

    def test_no_matching_lines_gives_empty_aggregate(self):
        self.assertEqual(tr.aggregate(["x", "y"]), {})


class PercentileTests(unittest.TestCase):
    def test_percentile_is_the_upper_bound_of_the_bucket_holding_the_rank(self):
        # 10 samples <=2 ms, 80 in (5,10], 10 in (30,40]
        buckets = [10, 0, 80, 0, 0, 0, 10, 0, 0, 0, 0]
        self.assertEqual(tr.percentile_label(buckets, 0.50), "<=10ms")
        self.assertEqual(tr.percentile_label(buckets, 0.05), "<=2ms")
        self.assertEqual(tr.percentile_label(buckets, 0.99), "<=40ms")

    def test_samples_over_the_last_bound_are_reported_as_over_150(self):
        buckets = [0] * 10 + [5]
        self.assertEqual(tr.percentile_label(buckets, 0.5), ">150ms")

    def test_empty_histogram_has_no_percentile(self):
        self.assertEqual(tr.percentile_label([0] * 11, 0.5), "n/a")


class ReportTests(unittest.TestCase):
    def test_report_shows_strokes_shares_percentiles_and_counts(self):
        lines = [
            line("pointer_timing", **hist([50, 0, 50, 0, 0, 0, 0, 0, 0, 0, 0], idle=3, p50_us=100)),
            line("pointer_timing", **hist([0] * 11, idle=4, p50_us=300)),
        ]
        text = tr.format_report(tr.aggregate(lines))
        self.assertIn("pointer_timing", text)
        self.assertIn("strokes=2", text)
        self.assertIn("50.0%", text)
        self.assertIn("p50<=2ms", text)
        self.assertIn("p99<=10ms", text)
        self.assertIn("idle=7", text)
        self.assertIn("p50_us", text)

    def test_empty_aggregate_says_so(self):
        self.assertIn("no timing lines", tr.format_report({}))

    def test_report_never_contains_log_text_beyond_numbers_and_names(self):
        text = tr.format_report(tr.aggregate([line("pointer_timing", **hist([1] + [0] * 10))]))
        self.assertNotIn("wall=", text)
        self.assertNotIn("2026-", text)


class WindowTests(unittest.TestCase):
    def at(self, wall):
        return line("pointer_timing", wall=wall, n=1, b2=1)

    def test_only_lines_inside_the_window_are_kept(self):
        lines = [self.at("2026-11-15T00:00:09.000Z"), self.at("2026-11-15T00:00:10.500Z"),
                 self.at("2026-11-15T00:00:30Z"), self.at("2026-11-15T00:00:33.000Z")]
        kept = tr.filter_window(lines, "2026-11-15T00:00:10.000Z", "2026-11-15T00:00:30.000Z", 0, 2)
        self.assertEqual(kept, lines[1:3])

    def test_receiver_clock_offset_shifts_the_window(self):
        lines = [self.at("2026-11-15T00:00:15.000Z")]
        self.assertEqual(tr.filter_window(lines, "2026-11-15T00:00:10.000Z", "2026-11-15T00:00:12.000Z", 5, 0), lines)
        self.assertEqual(tr.filter_window(lines, "2026-11-15T00:00:10.000Z", "2026-11-15T00:00:12.000Z", 0, 0), [])

    def test_window_crosses_midnight(self):
        lines = [self.at("2026-11-16T00:00:01.000Z")]
        self.assertEqual(tr.filter_window(lines, "2026-11-15T23:59:50.000Z", "2026-11-15T23:59:59.000Z", 0, 3), lines)

    def test_lines_without_a_wall_stamp_are_dropped(self):
        self.assertEqual(tr.filter_window(["ev=pointer_timing n=1 b2=1"], "2026-11-15T00:00:00Z", "2026-11-16T00:00:00Z", 0, 0), [])

    def test_wall_stamp_behind_a_prefix_is_found(self):
        stamped = "[injector] " + self.at("2026-11-15T00:00:11.000Z")
        self.assertEqual(tr.filter_window([stamped], "2026-11-15T00:00:10Z", "2026-11-15T00:00:12Z", 0, 0), [stamped])

    def test_main_filters_then_reports_and_can_print_the_kept_lines(self):
        import io
        from unittest import mock
        text = self.at("2026-11-15T00:00:11.000Z") + "\n" + self.at("2026-11-15T01:00:00.000Z") + "\n"
        base = ["--from", "2026-11-15T00:00:10Z", "--to", "2026-11-15T00:00:12Z", "--offset-s", "0", "--grace-s", "0"]
        with mock.patch("sys.stdin", io.StringIO(text)), mock.patch("sys.stdout", new=io.StringIO()) as out:
            tr.main(base)
        self.assertIn("strokes=1", out.getvalue())
        with mock.patch("sys.stdin", io.StringIO(text)), mock.patch("sys.stdout", new=io.StringIO()) as out:
            tr.main(base + ["--print-lines"])
        self.assertEqual(out.getvalue().strip(), text.splitlines()[0])


if __name__ == "__main__":
    unittest.main()
