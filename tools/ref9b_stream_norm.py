#!/usr/bin/env python3
"""tools/ref9b_stream_norm.py -- measure the NORMALISATION SIGNATURE of every
BFP record in a .r9bs seam stream.

WHY.  `rtl/bfp_pack.vhd` and `ref/matvec_int4.c`'s BFP path both compute the
block shift as

    sh = max(0, msb_pos(max_i |x_i|) - 14)

so the shift is CLAMPED AT ZERO: a quiet block, whose maximum already sits
below bit 14 on the input grid, is left UNDER-NORMALISED and its max mantissa
comes out below 16384.  `ref/run9b.c`'s `reg_put` computes instead

    exp = 14 - floor(log2(max_i |v_i|))

with no clamp, so it ALWAYS places the maximum in bit 14 and its max mantissa
is always in [16384, 32767].

Those two rules leave different fingerprints in the stream, and the fingerprint
is visible without knowing anything about the producer.  This script reads it:

    NORMALISED    max|mant| in [16384, 32767]   -- the max is in bit 14
    UNDER         max|mant| in [1, 16383]       -- a clamped shift left it low
    ZERO          every mantissa is 0

A stream whose records are ALL `NORMALISED` was written by the unclamped rule.
A stream containing `UNDER` records was written by the clamped one.  A hardware
capture and a reference that disagree on this are not comparable bit-exactly at
those seams no matter how correct the arithmetic upstream of them is.

Usage:
    python3 tools/ref9b_stream_norm.py <file.r9bs> [--tok N] [--per-seam]
"""

import sys
import struct
import argparse
from collections import OrderedDict

MAGIC = b"R9BS"
KIND_F32, KIND_BFP16 = 0, 1
HDR = struct.Struct("<IIiiii")   # name_len, n, tok, layer, kind, exp


def records(path, want_tok=None):
    """Yield (name, tok, layer, kind, exp, n, payload_bytes).

    Streams the file rather than loading it: the committed 9B references are
    26 to 293 MB and this box has been OOM-killed before.
    """
    with open(path, "rb") as fh:
        head = fh.read(8)
        if len(head) < 8 or head[:4] != MAGIC:
            raise SystemExit("%s: not an r9bs stream" % path)
        ver = struct.unpack("<I", head[4:])[0]
        if ver != 1:
            raise SystemExit("%s: unsupported version %d" % (path, ver))
        while True:
            raw = fh.read(HDR.size)
            if not raw:
                return
            if len(raw) < HDR.size:
                raise SystemExit("truncated record header")
            name_len, n, tok, layer, kind, exp = HDR.unpack(raw)
            name = fh.read(name_len).decode("utf-8", "replace")
            width = 4 if kind == KIND_F32 else 2
            payload = fh.read(n * width)
            if len(payload) < n * width:
                raise SystemExit("truncated payload in %s" % name)
            if want_tok is not None and tok != want_tok:
                continue
            yield name, tok, layer, kind, exp, n, payload


def classify(payload, n):
    """Return (bucket, max_abs_mantissa) for a BFP16 payload."""
    if n == 0:
        return "ZERO", 0
    mants = struct.unpack("<%dh" % n, payload)
    amax = 0
    for m in mants:
        a = -m if m < 0 else m
        if a > amax:
            amax = a
    if amax == 0:
        return "ZERO", 0
    if amax >= 16384:
        return "NORMALISED", amax
    return "UNDER", amax


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("stream")
    ap.add_argument("--tok", type=int, default=None,
                    help="restrict to one token index")
    ap.add_argument("--per-seam", action="store_true",
                    help="print one line per seam name")
    ap.add_argument("--list-under", action="store_true",
                    help="print every UNDER-normalised record")
    args = ap.parse_args()

    buckets = OrderedDict((k, 0) for k in ("NORMALISED", "UNDER", "ZERO"))
    per_seam = OrderedDict()
    n_f32 = 0
    exp_min, exp_max = None, None
    under_rows = []

    for name, tok, layer, kind, exp, n, payload in records(args.stream, args.tok):
        if kind == KIND_F32:
            n_f32 += 1
            continue
        bucket, amax = classify(payload, n)
        buckets[bucket] += 1
        exp_min = exp if exp_min is None else min(exp_min, exp)
        exp_max = exp if exp_max is None else max(exp_max, exp)
        slot = per_seam.setdefault(name, {"NORMALISED": 0, "UNDER": 0, "ZERO": 0})
        slot[bucket] += 1
        if bucket == "UNDER":
            under_rows.append((name, tok, exp, n, amax))

    total = sum(buckets.values())
    print("stream          : %s" % args.stream)
    if args.tok is not None:
        print("token filter    : %d" % args.tok)
    print("BFP16 records   : %d   (F32 records skipped: %d)" % (total, n_f32))
    if total == 0:
        return 0
    print("exponent range  : %d .. %d" % (exp_min, exp_max))
    for k, v in buckets.items():
        print("  %-11s : %6d  (%.2f%%)" % (k, v, 100.0 * v / total))

    verdict = ("UNCLAMPED (always normalise to bit 14) -- reg_put's rule"
               if buckets["UNDER"] == 0 else
               "MIXED: %d records are under-normalised, so at least one "
               "producer clamps the shift at zero" % buckets["UNDER"])
    print("signature       : %s" % verdict)

    if args.list_under:
        for name, tok, exp, n, amax in under_rows:
            print("UNDER %-22s tok %d exp %4d n %6d max|mant| %6d"
                  % (name, tok, exp, n, amax))

    if args.per_seam:
        print()
        print("%-24s %10s %8s %6s" % ("seam", "NORMALISED", "UNDER", "ZERO"))
        for name, slot in per_seam.items():
            print("%-24s %10d %8d %6d"
                  % (name, slot["NORMALISED"], slot["UNDER"], slot["ZERO"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
