#!/usr/bin/env python3
"""Compare the RKSTRESS A lines of ChineseSchemesDeviceUITests with the Rime dictionaries.

For every line with cands=0 and a non-empty code it asks whether the scheme's dictionary has that code, and prints how
many typed codes were "dictionary has it, keyboard shows nothing" (a possible product bug) with examples.

  python3 -I e2e/scripts/check-stress-codes.py <log file>... [--rime-dir ime/rime] [--examples 8]

The log files are the xcodebuild output (or the attached rkstress-*.txt); only lines holding "RKSTRESS A " are read.

How exact the verdict is:
  quick, cangjie   table_translator: the code is looked up as a whole; with `enable_completion: true` in the schema a
                   prefix of a dictionary code counts too. Exact.
  zhuyin, pinyin,  script_translator: the code has to be cut into syllables the dictionary knows (a Daqian syllable may
  jyutping         leave its tone off; pinyin `nue` is also `nve`). Whole-word codes without spaces are accepted when the
                   cut works. Librime can also answer a code that only has a valid beginning, and the speller's
                   algebra is simplified here, so this verdict is APPROXIMATE and said so in the output.
"""
import argparse
import os
import re
import sys
from collections import defaultdict

LINE = re.compile(r"RKSTRESS A scheme=(\w+) i=(\d+) code=(\S*) preedit_len=(\d+) cands=(\d+)")
TABLE = {"quick": "quick5", "cangjie": "cangjie5"}
PHONETIC = {"zhuyin": "zhuyin", "pinyin": "pinyin", "jyutping": "jyutping"}
ZHUYIN_TONES = "3467"


def dictionary_codes(path):
    """The set of codes (spaces removed) and the set of syllables (every space-separated part) of a *.dict.yaml."""
    codes, syllables = set(), set()
    started = False
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.rstrip("\n")
            if not started:
                started = line == "..."
                continue
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                continue
            code = parts[1]
            codes.add(code.replace(" ", ""))
            for syllable in code.split(" "):
                if syllable:
                    syllables.add(syllable)
    return codes, syllables


def completion_enabled(rime_dir, schema):
    path = os.path.join(rime_dir, schema + ".schema.yaml")
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                if re.match(r"\s*enable_completion:\s*true", line):
                    return True
    except OSError:
        pass
    return False


def segmentable(code, syllables):
    """True when `code` can be cut into known syllables."""
    longest = max((len(s) for s in syllables), default=1)
    reachable = [False] * (len(code) + 1)
    reachable[0] = True
    for start in range(len(code)):
        if not reachable[start]:
            continue
        for end in range(start + 1, min(len(code), start + longest) + 1):
            if code[start:end] in syllables:
                reachable[end] = True
    return reachable[len(code)]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("logs", nargs="+")
    here = os.path.dirname(os.path.abspath(__file__))
    parser.add_argument("--rime-dir", default=os.path.join(here, "..", "..", "ime", "rime"))
    parser.add_argument("--examples", type=int, default=8)
    args = parser.parse_args()

    rows = defaultdict(list)
    for path in args.logs:
        with open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                match = LINE.search(line)
                if match:
                    scheme, i, code, preedit, cands = match.groups()
                    rows[scheme].append((int(i), code, int(preedit), int(cands)))

    if not rows:
        print("no RKSTRESS A lines found", file=sys.stderr)
        return 2

    for scheme in sorted(rows):
        samples = rows[scheme]
        zero = [row for row in samples if row[3] == 0 and row[1]]
        if scheme in TABLE:
            schema = TABLE[scheme]
            codes, _ = dictionary_codes(os.path.join(args.rime_dir, schema + ".dict.yaml"))
            prefix = completion_enabled(args.rime_dir, schema)
            exactness = "exact (table lookup, completion=%s)" % ("on" if prefix else "off")

            def has(code):
                if code in codes:
                    return True
                return prefix and any(c.startswith(code) for c in codes)
        elif scheme in PHONETIC:
            schema = PHONETIC[scheme]
            codes, syllables = dictionary_codes(os.path.join(args.rime_dir, schema + ".dict.yaml"))
            known = set(syllables)
            if scheme == "zhuyin":
                known |= {s[:-1] for s in syllables if len(s) > 1 and s[-1] in ZHUYIN_TONES}
            if scheme == "pinyin":
                known |= {s.replace("ve", "ue") for s in syllables if re.match(r"^[nl]ve$", s)}
            exactness = "APPROXIMATE (cut into known syllables; librime may also answer a valid beginning)"

            def has(code, known=known, codes=codes):
                return code in codes or segmentable(code, known)
        else:
            print("%s: unknown scheme, skipped" % scheme)
            continue

        in_dictionary = [row for row in zero if has(row[1])]
        not_in_dictionary = [row for row in zero if not has(row[1])]
        print("== %s: %d key taps, %d with a code and no candidate, verdict %s" % (scheme, len(samples), len(zero), exactness))
        print("   dictionary has the code but the keyboard shows nothing: %d" % len(in_dictionary))
        for i, code, preedit, _ in in_dictionary[: args.examples]:
            print("     i=%d code=%s preedit_len=%d" % (i, code, preedit))
        print("   no candidate and the dictionary has no such code (expected): %d" % len(not_in_dictionary))
        for i, code, preedit, _ in not_in_dictionary[: args.examples]:
            print("     i=%d code=%s preedit_len=%d" % (i, code, preedit))
        # The opposite direction: candidates shown for a code the dictionary does not know (also worth a look).
        shown = [row for row in samples if row[3] > 0 and row[1] and not has(row[1])]
        print("   candidates shown although the dictionary has no such code%s: %d" % (
            " (partial codes may be legitimate)" if scheme in PHONETIC else "", len(shown)))
        for i, code, preedit, cands in shown[: args.examples]:
            print("     i=%d code=%s cands=%d" % (i, code, cands))
    return 0


if __name__ == "__main__":
    sys.exit(main())
