#!/usr/bin/env python3
"""Keeps and aggregates the Mac receiver's pointer diagnostic lines from `log show --style compact` output.

    /usr/bin/log show ... --style compact | mac_pointer_report.py --print-lines   # the kept lines
    mac_pointer_report.py < kept_lines                                           # the aggregate table

Kept: lines whose message is `pointer diag`, `pointer link`, `pointer open` or `pointer closed` (nothing else, so
`pointer open refused` and `pointer packet rejected` are dropped). A kept line is rewritten to
`<date> <time> <message>`: the process and category prefix is removed, and only `key=number` fields (an optional % or ms
unit is dropped) are kept for diag and link lines. The aggregate gives, per numeric field, the number of lines that
carry it and the median and maximum across those lines. Python 3 standard library only.
"""
import argparse
import re
import statistics
import sys

FIELDS = ["stalled", "longest", "squeezes", "cb50", "cb95", "margin10", "margin50", "gain50", "gain90", "starve", "starve95", "starvemax", "starvedt50", "starvegap50", "lag", "jit",
          "rate", "p50", "p95", "interval", "backlog"]

_LINE = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d(?:\.\d+)?)\s.*?\bpointer (diag|link|open|closed)(?=\s|$)(.*)$")
_FIELD = re.compile(r"(?:^|\s)(\w+)=(-?\d+(?:\.\d+)?)(?:%|ms)?(?=\s|$)")


def filter_lines(lines):
    """Returns the kept lines as `<date> <time> pointer <event> key=value ...` (numbers only)."""
    kept = []
    for text in lines:
        match = _LINE.match(text.rstrip("\n"))
        if not match:
            continue
        stamp, event, rest = match.groups()
        if event == "open" and rest.strip():
            continue  # `pointer open refused`
        if event in ("diag", "link"):
            fields = " ".join("%s=%s" % (k, v) for k, v in _FIELD.findall(rest))
            kept.append("%s pointer %s %s" % (stamp, event, fields))
        else:
            kept.append("%s pointer %s%s" % (stamp, event, _closed_counts(rest) if event == "closed" else ""))
    return kept


def _closed_counts(rest):
    return "".join(" %s=%s" % (k, v) for k, v in _FIELD.findall(rest))


def aggregate(kept):
    """Returns {field: (count, median, max)} over the kept diag and link lines."""
    values = {name: [] for name in FIELDS}
    for text in kept:
        if " pointer diag " not in text and " pointer link " not in text:
            continue
        for key, raw in _FIELD.findall(text):
            if key in values:
                values[key].append(float(raw))
    return {name: (len(v), statistics.median(v) if v else 0, max(v) if v else 0) for name, v in values.items()}


def _num(value):
    return str(int(value)) if float(value).is_integer() else "%.2f" % value


def format_report(agg):
    out = ["%-10s %6s %10s %10s" % ("field", "count", "median", "max")]
    for name in FIELDS:
        count, median, high = agg[name]
        out.append("%-10s %6d %10s %10s" % (name, count, _num(median), _num(high)))
    return "\n".join(out) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--print-lines", action="store_true", help="print the kept lines instead of the aggregate")
    args = parser.parse_args(argv)
    if args.print_lines:
        for kept in filter_lines(sys.stdin):
            print(kept)
        return 0
    sys.stdout.write(format_report(aggregate([l.rstrip("\n") for l in sys.stdin])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
