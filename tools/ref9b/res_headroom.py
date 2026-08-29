#!/usr/bin/env python3
"""How much of the residual's second operand survives the BFP add.

WHY THIS EXISTS.  `docs/debugging/2026-08-29_first-bisect.md` section 5.6 records
a DERIVED observation: at the KV configuration, token 2, `R_ER-3` carries
exponent 0 against the residual's -10, a 7-LSB change in `R_ER-3` leaves
`R_X.attn-3` bit-identical, and therefore "subsystem C's entire contribution to
the residual is quantised away at that position".  That was read off two
exponents.  This tool MEASURES it instead, and measures it everywhere.

WHAT IT MEASURES.  For every `OP_VEC_RES` step it takes the machine's own two
operands and asks, for each element of the second operand (`R_ER`, the
subsystem output), the smallest positive delta that changes the residual's
output at all.  `D = 1` means that element's least significant bit survives the
add.  `D = 1024` means the ten low bits of that element are discarded and the
producing subsystem would have to move the value by 1024 LSB before the
residual noticed.

The scan holds the output shift `sh` at its unperturbed value, which is exact
for any delta small enough not to move the vector's maximum.  `--exact` runs the
full scalar model per element instead and is the control for that assumption;
they agree on every scaled capture measured on 2026-08-29.

WHAT IT DOES NOT MEASURE.  Whether the values themselves are right.  A residual
whose second operand is 400x smaller than its first is arithmetically correct
BFP; whether that ratio is what the model should produce is a separate question
and belongs to whatever oracle covers the producing subsystem.

usage:
  res_headroom.py capture.txt --blocks 4 --attn-int 4 --attn-hd 16   # a GHDL capture
  res_headroom.py ref.r9bs --r9bs [--layers 0,1,31] [--tok 0]        # the 9B reference
"""
import argparse
import math
import os
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import scaled_plan as SP           # noqa: E402
import vec_oracle as VO            # noqa: E402


# ------------------------------------------------------------------ the operands
class Pair:
    """One residual step: the running residual, the subsystem output, a label."""

    __slots__ = ("label", "tok", "src", "x", "ex", "e", "ee")

    def __init__(self, label, tok, src, x, ex, e, ee):
        self.label, self.tok, self.src = label, tok, src
        self.x, self.ex, self.e, self.ee = x, ex, e, ee


def pairs_from_capture(path, blocks, attn_int, attn_hd):
    from bisect_scaled import read_capture
    recs = read_capture(path)
    d = {(r.name, r.tok): r for r in recs}
    toks = sorted(set(r.tok for r in recs))
    steps = SP.build(SP.Shape(blocks, attn_int, attn_hd))
    prod = SP.producers(steps)
    out = []
    for st in steps:
        if st.op != SP.OP_RES:
            continue
        sn, s2 = prod[st.i]["src"], prod[st.i]["src2"]
        for t in toks:
            if (sn, t) not in d or (s2, t) not in d:
                continue
            X, E = d[(sn, t)], d[(s2, t)]
            # R_ER.ffn-b is subsystem A's down projection; R_ER-b is the one fed
            # by subsystem B or C, and it is the one the question is about.
            src = "A(ffn)" if s2.startswith("R_ER.ffn") else "B/C"
            out.append(Pair(st.seam, t, src, list(X.v), X.exp, list(E.v), E.exp))
    return out


def pairs_from_r9bs(path, layers, toks):
    import r9bs
    recs = {}
    for r in r9bs.read(path):
        if r.kind != r9bs.KIND_BFP16:
            continue
        recs[(r.name, r.tok)] = r
    lay = sorted(set(l for (n, t) in recs for l in [_layer_of(n)] if l is not None))
    if layers:
        lay = [l for l in lay if l in layers]
    tk = sorted(set(t for (_, t) in recs))
    if toks:
        tk = [t for t in tk if t in toks]
    out = []
    for b in lay:
        for t in tk:
            # the attention/GDN residual: R_X.attn-b = R_X(prev) + R_ER-b
            prev = "R_X-%d" % (b - 1) if b > 0 else "R_X.embed"
            for (xn, en, ln, src) in ((prev, "R_ER-%d" % b, "R_X.attn-%d" % b, "B/C"),
                                      ("R_X.attn-%d" % b, "R_ER.ffn-%d" % b,
                                       "R_X-%d" % b, "A(ffn)")):
                if (xn, t) not in recs or (en, t) not in recs:
                    continue
                X, E = recs[(xn, t)], recs[(en, t)]
                out.append(Pair(ln, t, src, [int(v) for v in X.raw], X.exp,
                                [int(v) for v in E.raw], E.exp))
    return out


def _layer_of(name):
    if "-" not in name:
        return None
    try:
        return int(name.rsplit("-", 1)[1])
    except ValueError:
        return None


# -------------------------------------------------------------------- the scan
def _rhu(v, sh):
    if sh <= 0:
        return v
    return (v + (1 << (sh - 1))) >> sh


def scan(p, dmax_log=26, exact=False):
    """Per element, the smallest delta to `e` that moves the residual output.

    Returns (dmin list, sh, dead, oexp).  `dead = sh - se` is the DERIVED number
    of low bits of `e` the alignment plus renormalisation throws away; the dmin
    list is the MEASURED consequence, and the two are not the same thing because
    round-half-up lets a single LSB cross a rounding boundary.
    """
    out0, oexp0, sh, _sat = VO.res(p.x, p.e, p.ex, p.ee)
    qmax, qmin = max(p.ex, p.ee), min(p.ex, p.ee)
    q = (qmin + VO.SHMAX) if (qmax - qmin > VO.SHMAX) else qmax
    sx, se = q - p.ex, q - p.ee
    dead = sh - se

    n = len(p.e)
    if exact:
        dmin = []
        for i in range(n):
            v = list(p.e)
            D, found = 1, None
            while D <= (1 << dmax_log):
                v[i] = p.e[i] + D
                o, oe, _, _ = VO.res(p.x, v, p.ex, p.ee)
                if o != out0 or oe != oexp0:
                    found = D
                    break
                D <<= 1
            dmin.append(found if found is not None else (1 << (dmax_log + 1)))
        return dmin, sh, dead, oexp0

    a = [(p.x[i] << sx) if sx >= 0 else _rhu(p.x[i], -sx) for i in range(n)]
    b = [(p.e[i] << se) if se >= 0 else _rhu(p.e[i], -se) for i in range(n)]
    base = [VO.sat16(_rhu(a[i] + b[i], sh)) for i in range(n)]
    dmin = [None] * n
    D = 1
    while D <= (1 << dmax_log):
        for i in range(n):
            if dmin[i] is not None:
                continue
            ev = p.e[i] + D
            bp = (ev << se) if se >= 0 else _rhu(ev, -se)
            if VO.sat16(_rhu(a[i] + bp, sh)) != base[i]:
                dmin[i] = D
        if all(x is not None for x in dmin):
            break
        D <<= 1
    lim = 1 << (dmax_log + 1)
    return [x if x is not None else lim for x in dmin], sh, dead, oexp0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("--r9bs", action="store_true",
                    help="the input is a binary .r9bs stream, not a GHDL capture")
    ap.add_argument("--blocks", type=int, default=4)
    ap.add_argument("--attn-int", type=int, default=4)
    ap.add_argument("--attn-hd", type=int, default=16)
    ap.add_argument("--layers", default="")
    ap.add_argument("--tok", default="")
    ap.add_argument("--exact", action="store_true")
    ap.add_argument("--label", default="")
    a = ap.parse_args()

    if a.r9bs:
        lay = [int(x) for x in a.layers.split(",") if x != ""] or None
        tks = [int(x) for x in a.tok.split(",") if x != ""] or None
        ps = pairs_from_r9bs(a.capture, lay, tks)
    else:
        ps = pairs_from_capture(a.capture, a.blocks, a.attn_int, a.attn_hd)

    print("# residual headroom: how much of the SECOND operand survives the add")
    print("# %s%s   %d residual steps%s"
          % (a.label + "  " if a.label else "", os.path.basename(a.capture),
             len(ps), "  (--exact)" if a.exact else ""))
    print("# ratio = max|X| / max|ER|.  dead = sh - se, the low bits of ER the")
    print("#   alignment plus renormalisation discards.  D is MEASURED: the")
    print("#   smallest delta to one element of ER that moves the output.")
    print("%-14s %-3s %-7s %5s %5s %5s %5s %10s %8s %8s %8s"
          % ("residual", "tok", "src", "e(X)", "e(ER)", "sh", "dead",
             "ratio", "D=1 frac", "D med", "D max"))
    worst = []
    for p in ps:
        dmin, sh, dead, oexp = scan(p, exact=a.exact)
        mx = max(abs(v) for v in p.x) * 2.0 ** -p.ex
        me = max(abs(v) for v in p.e) * 2.0 ** -p.ee
        n1 = sum(1 for v in dmin if v == 1)
        med = int(statistics.median(dmin))
        print("%-14s %-3d %-7s %5d %5d %5d %5d %10.4g %5d/%-4d %8d %8d"
              % (p.label, p.tok, p.src, p.ex, p.ee, sh, dead,
                 (mx / me) if me else float("inf"), n1, len(dmin), med, max(dmin)))
        worst.append((med, p.label, p.tok, p.src))
    if worst:
        bc = [w for w in worst if w[3] == "B/C"]
        ff = [w for w in worst if w[3] == "A(ffn)"]
        print("# median-of-medians  B/C branch: %s   A(ffn) branch: %s"
              % (int(statistics.median([w[0] for w in bc])) if bc else "-",
                 int(statistics.median([w[0] for w in ff])) if ff else "-"))
        worst.sort(reverse=True)
        print("# worst: %s" % ", ".join("%s tok%d D_med=%d" % (w[1], w[2], w[0])
                                        for w in worst[:5]))


if __name__ == "__main__":
    main()
