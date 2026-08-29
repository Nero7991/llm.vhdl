#!/usr/bin/env python3
"""Emit server/qwen35_unicode_data.c from llama.cpp's OWN generated tables.

WHY THIS EXISTS, AND WHY IT DOES NOT DOWNLOAD ANYTHING.

The qwen35 pre-tokenizer's every decision is a Unicode category decision:
\\p{L}, \\p{M}, \\p{N} and White_Space.  Get the categories from a different
Unicode version than the oracle and you get a different tokenization.  That is
not hypothetical: the Python tokenizer's first cut classified codepoints with
this interpreter's `unicodedata` (Unicode 13.0.0) and disagreed with llama.cpp
on 4,704 of 1,112,064 codepoints.  See
docs/debugging/2026-08-28_qwen35-tokenizer.md section 6.2.

llama.cpp's scripts/gen-unicode-data.py downloads
https://www.unicode.org/Public/UCD/latest/ucd/UnicodeData.txt at generation
time, so "the same UCD" is not a version number you can write down -- it is
whatever was current when THAT checkout's src/unicode-data.cpp was generated.
Re-downloading "latest" today would be a DIFFERENT table.

So this script does not download and does not use `unicodedata`.  It parses
the literal C++ initialiser lists out of

    <llama.cpp checkout>/src/unicode-data.cpp

which is the exact translation unit compiled into the libllama.so that
tools/tok_oracle_batch links.  The tables are therefore identical to the
oracle's by construction, not by agreement, and the skew above cannot recur
without the parse failing loudly.

Three tables are extracted:

  unicode_ranges_flags   (start, flags) run-length table over U+0000..U+10FFFF.
                         Flag bits are unicode_cpt_flags in src/unicode.h:
                         UNDEFINED 0x0001, NUMBER 0x0002, LETTER 0x0004,
                         SEPARATOR 0x0008, ACCENT_MARK 0x0010,
                         PUNCTUATION 0x0020, SYMBOL 0x0040, CONTROL 0x0080.
                         Note Cn maps to UNDEFINED = 0x0001, which is NON-zero,
                         so flags != 0 for every codepoint in range.  The
                         splitter's `flags.as_uint()` test therefore means
                         "is this index inside the string", not "is this
                         codepoint assigned".

  unicode_set_whitespace Unicode White_Space, an explicit list.  NOT category
                         Z: \\t \\n \\v \\f \\r are Cc, and U+180E is excluded.

  unicode_map_lowercase  used only by unicode_tolower(), which the splitter
                         calls on the two codepoints after an apostrophe.

The lowercase/uppercase/NFD *flag bits* that unicode_cpt_flags_array() also
ORs in are deliberately NOT reproduced: unicode_regex_split_custom_qwen35()
reads only is_number, is_letter, is_accent_mark, is_whitespace and
as_uint()!=0, and as_uint() is already non-zero for every in-range codepoint
because of UNDEFINED.  That claim is not taken on trust -- the exhaustive
1,112,064-codepoint sweep in tools/verify_tokenizer_c.py is what proves it.

Usage:
    gen_tokenizer_unicode_tables.py [--src PATH/src/unicode-data.cpp] \\
        [--out server/qwen35_unicode_data.c]
"""

import argparse
import os
import re
import subprocess
import sys

DEFAULT_SRC = os.path.expanduser("~/GitHub/llama.cpp.upstream/src/unicode-data.cpp")
DEFAULT_OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                           "server", "qwen35_unicode_data.c")

MAX_CODEPOINTS = 0x110000


def _block(src, name):
    m = re.search(r"\b" + re.escape(name) + r"\s*=\s*\{(.*?)\n\};", src, re.S)
    if m is None:
        raise SystemExit(f"could not find `{name}` in the source -- has llama.cpp's "
                         f"unicode-data.cpp changed shape?")
    return m.group(1)


def parse(path):
    with open(path, "r", encoding="utf-8") as f:
        src = f.read()

    ranges = [(int(a, 16), int(b, 16)) for a, b in
              re.findall(r"\{0x([0-9A-Fa-f]{6}),\s*0x([0-9A-Fa-f]{4})\}",
                         _block(src, "unicode_ranges_flags"))]
    ws = sorted(int(a, 16) for a in
                re.findall(r"0x([0-9A-Fa-f]{6}),", _block(src, "unicode_set_whitespace")))
    lower = [(int(a, 16), int(b, 16)) for a, b in
             re.findall(r"\{0x([0-9A-Fa-f]{6}),\s*0x([0-9A-Fa-f]{6})\}",
                        _block(src, "unicode_map_lowercase"))]

    # the same invariants unicode_cpt_flags_array() asserts
    if not ranges or ranges[0][0] != 0:
        raise SystemExit("unicode_ranges_flags does not start at 0")
    if ranges[-1][0] != MAX_CODEPOINTS:
        raise SystemExit(f"unicode_ranges_flags does not end at 0x{MAX_CODEPOINTS:X}")
    if any(ranges[i][0] >= ranges[i + 1][0] for i in range(len(ranges) - 1)):
        raise SystemExit("unicode_ranges_flags is not strictly ascending")
    # unicode_tolower() binary-searches this, so it must be sorted by key
    if any(lower[i][0] >= lower[i + 1][0] for i in range(len(lower) - 1)):
        raise SystemExit("unicode_map_lowercase is not strictly ascending")
    return ranges, ws, lower


def provenance(path):
    d = os.path.dirname(os.path.dirname(os.path.abspath(path)))
    try:
        h = subprocess.run(["git", "-C", d, "rev-parse", "HEAD"],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           text=True, check=True).stdout.strip()
    except Exception:
        h = "<not a git checkout>"
    return d, h


def emit(ranges, ws, lower, src_path, out_path):
    repo, head = provenance(src_path)
    lines = []
    a = lines.append
    a("/* GENERATED by tools/gen_tokenizer_unicode_tables.py -- do not edit by hand.")
    a(" *")
    a(" * Transcribed verbatim from the initialiser lists in")
    a(f" *   {src_path}")
    a(f" * checkout {repo}")
    a(f" * at commit {head}")
    a(" *")
    a(" * That is the translation unit compiled into the libllama.so that")
    a(" * tools/tok_oracle_batch links, so these tables are the ORACLE'S tables, not")
    a(" * a re-derivation from some UCD release.  Regenerating them from a newer UCD")
    a(" * would reintroduce the 4,704-codepoint skew documented in")
    a(" * docs/debugging/2026-08-28_qwen35-tokenizer.md section 6.2.")
    a(" *")
    a(" * Flag bits are unicode_cpt_flags in llama.cpp's src/unicode.h:")
    a(" *   UNDEFINED 0x0001  NUMBER 0x0002  LETTER   0x0004  SEPARATOR 0x0008")
    a(" *   MARK      0x0010  PUNCT  0x0020  SYMBOL   0x0040  CONTROL   0x0080")
    a(" * Category Cn is UNDEFINED = 0x0001, which is NON-ZERO, so every codepoint")
    a(" * below 0x110000 has non-zero flags.")
    a(" */")
    a("")
    a('#include "qwen35_unicode_data.h"')
    a("")
    a(f"const int qwen35_uni_n_ranges = {len(ranges)};")
    a("")
    a("/* start of each run; the run ends where the next one starts */")
    a("const uint32_t qwen35_uni_range_start[] = {")
    for i in range(0, len(ranges), 8):
        a("    " + " ".join("0x%06Xu," % c for c, _ in ranges[i:i + 8]))
    a("};")
    a("")
    a("const uint16_t qwen35_uni_range_flags[] = {")
    for i in range(0, len(ranges), 12):
        a("    " + " ".join("0x%04Xu," % f for _, f in ranges[i:i + 12]))
    a("};")
    a("")
    a("/* Unicode White_Space, llama.cpp's table_whitespace verbatim.  NOT \\p{Z}. */")
    a(f"const int qwen35_uni_n_whitespace = {len(ws)};")
    a("const uint32_t qwen35_uni_whitespace[] = {")
    for i in range(0, len(ws), 8):
        a("    " + " ".join("0x%06Xu," % c for c in ws[i:i + 8]))
    a("};")
    a("")
    a("/* unicode_map_lowercase, used only by unicode_tolower() */")
    a(f"const int qwen35_uni_n_lower = {len(lower)};")
    a("const uint32_t qwen35_uni_lower_from[] = {")
    for i in range(0, len(lower), 8):
        a("    " + " ".join("0x%06Xu," % c for c, _ in lower[i:i + 8]))
    a("};")
    a("const uint32_t qwen35_uni_lower_to[] = {")
    for i in range(0, len(lower), 8):
        a("    " + " ".join("0x%06Xu," % c for _, c in lower[i:i + 8]))
    a("};")
    a("")

    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    return len("\n".join(lines))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--src", default=DEFAULT_SRC,
                    help="llama.cpp's src/unicode-data.cpp (default: %(default)s)")
    ap.add_argument("--out", default=DEFAULT_OUT)
    args = ap.parse_args()

    if not os.path.isfile(args.src):
        raise SystemExit(f"{args.src}: not found.  Point --src at the llama.cpp "
                         f"checkout whose build tools/tok_oracle_batch links.")
    ranges, ws, lower = parse(args.src)
    n = emit(ranges, ws, lower, args.src, args.out)
    print(f"ranges     : {len(ranges)}")
    print(f"whitespace : {len(ws)}")
    print(f"lowercase  : {len(lower)}")
    print(f"wrote {args.out}  {n} bytes")
    print(f"binary cost: {len(ranges) * 6 + len(ws) * 4 + len(lower) * 8} bytes of .rodata "
          f"(DERIVED from the element widths)", file=sys.stderr)


if __name__ == "__main__":
    main()
