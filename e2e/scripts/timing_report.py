#!/usr/bin/env python3
"""Aggregates receiver timing summary lines (one line per stroke) into a plain-text report.

    ... | timing_report.py [--from ISO --to ISO [--offset-s S] [--grace-s S] [--print-lines]]

Reads receiver log lines on stdin. Lines whose event is pointer_timing* , ble_rx_timing or portal_motion_timing
(the event may sit behind a stamped prefix) are aggregated per event:
  - histograms: keys n and b2 b5 b10 b15 b20 b30 b40 b50 b75 b150 bover (a key prefix such as call_ makes a separate
    histogram) are summed; the report gives the share per bucket and approximate p50/p90/p99 (bucket upper bound)
  - keys ending in _us are per-stroke statistics: the report gives their median and max across strokes
  - every other integer key is a count and is summed
With --from/--to only lines whose wall= stamp (receiver clock) lies in [from + offset, to + offset + grace] are used; lines
without a wall= stamp are dropped. --print-lines prints the kept lines instead of the report.
Only numbers and event names are printed; nothing else from the log is kept. Python 3 standard library only.
"""
import argparse
import re
import statistics
import sys
from datetime import datetime, timedelta, timezone

BOUNDS_MS = [2, 5, 10, 15, 20, 30, 40, 50, 75, 150]
BUCKET_KEYS = ["b%d" % b for b in BOUNDS_MS] + ["bover"]
META_KEYS = {"conn", "mono_ms"}

_EVENT = re.compile(r"(?:^|\s)ev=(pointer_timing\w*|ble_rx_timing|portal_motion_timing)(?=\s|$)")
_INT_FIELD = re.compile(r"(?:^|\s)(\w+)=(-?\d+)(?=\s|$)")
_WALL = re.compile(r"(?:^|\s)wall=(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d+))?Z(?=\s|$)")
_HIST_KEY = re.compile(r"^(?:(?P<prefix>.*)_)?(?P<kind>n|b\d+|bover)$")


def parse_line(text):
    """Returns (event, {key: int}) for a timing line, otherwise None."""
    match = _EVENT.search(text)
    if not match:
        return None
    fields = {k: int(v) for k, v in _INT_FIELD.findall(text) if k not in META_KEYS}
    return match.group(1), fields


def _new_event():
    return {"lines": 0, "hists": {}, "us": {}, "counts": {}}


def _hist_slot(event, prefix):
    return event["hists"].setdefault(prefix, {"n": 0, "buckets": [0] * len(BUCKET_KEYS)})


def aggregate(lines):
    result = {}
    for text in lines:
        parsed = parse_line(text)
        if parsed is None:
            continue
        name, fields = parsed
        event = result.setdefault(name, _new_event())
        event["lines"] += 1
        per_stroke_us = {}
        for key, value in fields.items():
            hist_match = _HIST_KEY.match(key)
            if hist_match and (hist_match.group("kind") == "n" or hist_match.group("kind") in BUCKET_KEYS):
                slot = _hist_slot(event, hist_match.group("prefix") or "")
                if hist_match.group("kind") == "n":
                    slot["n"] += value
                else:
                    slot["buckets"][BUCKET_KEYS.index(hist_match.group("kind"))] += value
            elif key.endswith("_us"):
                per_stroke_us[key] = value
            else:
                event["counts"][key] = event["counts"].get(key, 0) + value
        for key, value in per_stroke_us.items():
            event["us"].setdefault(key, []).append(value)
    for event in result.values():
        event["us"] = {k: (statistics.median(v), max(v)) for k, v in event["us"].items()}
    return result


def _bound_label(index):
    return ">%dms" % BOUNDS_MS[-1] if index == len(BOUNDS_MS) else "<=%dms" % BOUNDS_MS[index]


def percentile_label(buckets, q):
    total = sum(buckets)
    if total == 0:
        return "n/a"
    cumulative = 0
    for index, count in enumerate(buckets):
        cumulative += count
        if cumulative / total >= q:
            return _bound_label(index)
    return _bound_label(len(buckets) - 1)


def _fmt_number(value):
    return "%d" % value if float(value).is_integer() else "%.1f" % value


def format_report(agg):
    if not agg:
        return "no timing lines found\n"
    out = []
    for name in sorted(agg):
        event = agg[name]
        out.append("event %s  strokes=%d" % (name, event["lines"]))
        for prefix in sorted(event["hists"]):
            hist = event["hists"][prefix]
            total = sum(hist["buckets"])
            title = "histogram" if not prefix else "histogram %s" % prefix
            out.append("  %s  n=%d (sum of buckets %d)" % (title, hist["n"], total))
            if total:
                for index, count in enumerate(hist["buckets"]):
                    out.append("    %-8s %8d  %5.1f%%" % (_bound_label(index), count, 100.0 * count / total))
                out.append("    approx  p50%s  p90%s  p99%s" % (
                    percentile_label(hist["buckets"], 0.50),
                    percentile_label(hist["buckets"], 0.90),
                    percentile_label(hist["buckets"], 0.99)))
        if event["us"]:
            out.append("  per-stroke statistics (median / max across strokes)")
            for key in sorted(event["us"]):
                median, peak = event["us"][key]
                out.append("    %-16s %10s / %s" % (key, _fmt_number(median), _fmt_number(peak)))
        if event["counts"]:
            out.append("  counts  " + " ".join("%s=%d" % (k, event["counts"][k]) for k in sorted(event["counts"])))
        out.append("")
    return "\n".join(out)


def parse_time(text):
    """ISO 8601 UTC ('...Z', optional fraction) to an aware datetime; None when it does not fit."""
    match = re.fullmatch(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d+))?Z", text.strip())
    if not match:
        return None
    base = datetime.strptime(match.group(1), "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
    return base + timedelta(microseconds=int((match.group(2) or "0")[:6].ljust(6, "0")))


def wall_time(line_text):
    match = _WALL.search(line_text)
    return parse_time(match.group(1) + ("." + match.group(2) if match.group(2) else "") + "Z") if match else None


def filter_window(lines, start, end, offset_s, grace_s):
    """Lines stamped within [start + offset, end + offset + grace] (start/end ISO UTC strings, offsets in seconds)."""
    low = parse_time(start) + timedelta(seconds=offset_s)
    high = parse_time(end) + timedelta(seconds=offset_s + grace_s)
    kept = []
    for text in lines:
        stamp = wall_time(text)
        if stamp is not None and low <= stamp <= high:
            kept.append(text)
    return kept


def main(argv=None):
    parser = argparse.ArgumentParser(description="Aggregate receiver timing lines read from stdin.")
    parser.add_argument("--from", dest="start", help="window start, ISO 8601 UTC (Mac clock)")
    parser.add_argument("--to", dest="end", help="window end, ISO 8601 UTC (Mac clock)")
    parser.add_argument("--offset-s", type=int, default=0, help="receiver clock minus Mac clock, seconds")
    parser.add_argument("--grace-s", type=int, default=2, help="seconds added after --to")
    parser.add_argument("--print-lines", action="store_true", help="print the kept lines instead of the report")
    args = parser.parse_args(argv)
    lines = [text.rstrip("\n") for text in sys.stdin]
    if args.start or args.end:
        if not (args.start and args.end and parse_time(args.start) and parse_time(args.end)):
            parser.error("--from and --to must both be ISO 8601 UTC times ending in Z")
        lines = filter_window(lines, args.start, args.end, args.offset_s, args.grace_s)
    if args.print_lines:
        kept = [text for text in lines if parse_line(text)]
        sys.stdout.write("".join(text + "\n" for text in kept))
    else:
        sys.stdout.write(format_report(aggregate(lines)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
