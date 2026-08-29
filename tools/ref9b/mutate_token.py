#!/usr/bin/env python3
"""mutate_token.py -- teeth for check_token.py, applied to the STREAM.

A checker never shown to fail has not been shown to work.  `mutate_logits.sh`
mutates the RTL and re-captures; this file mutates the .r9bs bytes instead,
because the thing under test here is `ref/run9b.c`'s TOKEN record and the
comparison built on it, and the 9B reference costs ~30 s per token to re-run
while a byte edit costs nothing.  The two are complementary and neither
replaces the other: an RTL mutation prices the WHOLE chain, a stream mutation
prices only the checker.  Say which you ran.

Every mutation writes a COPY.  The input file is opened read-only.

Mutations:

    T1  reported-token  the TOKEN record's payload, at one position, + delta
    T2  logit-below-gap the winning logit reduced by LESS than its margin over
                        the runner-up.  EXPECTED NOT TO BITE -- and that is the
                        measurement, not a failure: it fixes how much a logit
                        may move before the token notices
    T3  logit-over-gap  the same logit reduced by just MORE than the margin.
                        The token moves to the runner-up
    T4  swap-runner-up  the top two values exchanged.  The token moves and the
                        logits' multiset does not, which is the shape of an
                        index/window permutation
    T5  tie             the runner-up raised to exactly the winner's value.
                        EXERCISES THE FIRST-MAX RULE, which agreement on the
                        reference prompt never does: all 248,320 values there
                        are distinct

Usage:
    python3 mutate_token.py IN.r9bs OUT.r9bs --tok N --mut T1 [--delta D]
"""
import argparse
import struct
import sys

import numpy as np

MAGIC = b"R9BS"
_HDR = struct.Struct("<IIiiii")
_DT = {0: np.float32, 1: np.int16, 2: np.int32}


def rewrite(inp, outp, tok, mut, delta):
    with open(inp, "rb") as fp:
        blob = fp.read()
    if blob[:4] != MAGIC:
        raise SystemExit("%s: not an r9bs stream" % inp)
    out = bytearray(blob[:8])
    off = 8
    hits = 0
    while off < len(blob):
        h = _HDR.unpack_from(blob, off)
        name_len, n, rtok, layer, kind, exp = h
        nstart = off + _HDR.size
        name = blob[nstart:nstart + name_len].decode()
        pstart = nstart + name_len
        nbytes = n * np.dtype(_DT[kind]).itemsize
        payload = bytearray(blob[pstart:pstart + nbytes])

        if rtok == tok:
            arr = np.frombuffer(bytes(payload), dtype=_DT[kind]).copy()
            if mut == "T1" and name == "TOKEN":
                arr[0] += delta
                payload = bytearray(arr.tobytes()); hits += 1
            elif mut in ("T2", "T3", "T4", "T5") and name in ("LOGITS",
                                                              "result_output"):
                v = arr.astype(np.float64)
                if kind != 0:
                    v = v * (2.0 ** -exp)
                i1 = int(np.argmax(v))
                w = v.copy(); w[i1] = -np.inf
                i2 = int(np.argmax(w))
                gap = v[i1] - v[i2]
                # The SMALLEST change that moves the token, at this stream's
                # own storage precision.  Not `gap * 1.0000001`: the first
                # version of this file used that, and on an f32 payload it
                # rounded back to an exact TIE, which the first-max rule then
                # resolved to the ORIGINAL winner -- so the mutation looked
                # like a survivor when it had simply not been applied.  One ULP
                # below the runner-up is the honest smallest step.
                below = float(np.nextafter(np.float32(v[i2]),
                                           np.float32(-np.inf)))
                print("# %s tok %d: winner %d = %.9g, runner-up %d = %.9g, "
                      "gap %.9g, smallest move-the-token change = %.9g"
                      % (mut, tok, i1, float(v[i1]), i2, float(v[i2]), gap,
                         below - float(v[i1])))
                if mut == "T2":
                    v[i1] -= gap * 0.5
                elif mut == "T3":
                    v[i1] = below
                elif mut == "T4":
                    v[i1], v[i2] = v[i2], v[i1]
                elif mut == "T5":
                    v[i2] = v[i1]
                if kind != 0:
                    v = np.rint(v * (2.0 ** exp))
                arr = v.astype(_DT[kind])
                payload = bytearray(arr.tobytes()); hits += 1

        out += blob[off:pstart]
        out += payload
        off = pstart + nbytes
    if not hits:
        raise SystemExit("%s: mutation %s matched NOTHING at token %d.  A "
                         "mutation that did not apply is not a survivor; it "
                         "is a broken experiment." % (inp, mut, tok))
    with open(outp, "wb") as fp:
        fp.write(bytes(out))
    print("# wrote %s (%d record(s) mutated)" % (outp, hits))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("inp")
    ap.add_argument("outp")
    ap.add_argument("--tok", type=int, default=0)
    ap.add_argument("--mut", required=True,
                    choices=["T1", "T2", "T3", "T4", "T5"])
    ap.add_argument("--delta", type=int, default=1)
    a = ap.parse_args()
    rewrite(a.inp, a.outp, a.tok, a.mut, a.delta)
    return 0


if __name__ == "__main__":
    sys.exit(main())
