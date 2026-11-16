#!/usr/bin/env python3
"""tools/check_mv_dist_div.py -- exhaustive proof for rtl/mv_dist.vhd's reciprocal-multiply
ceil-divide (a450 Task 4 fix round 2, item 2).

rtl/mv_dist.vhd no longer computes `ceil(j_rows / ROWS_IF)` with a combinational divide in
the `go` cycle (a wide divide on a 450 MHz path).  Instead it computes, over two pipelined
register stages (D_SET1, D_SET2):

    y    = j_rows + ROWS_IF - 1
    ntl0 = (y * DIV_M) >> DIV_S

where DIV_S and DIV_M are elaboration-time constants derived from the generics:

    DIV_YBITS = clog2(MAXROWS + ROWS_IF)
    DIV_DBITS = clog2(ROWS_IF)
    DIV_S     = DIV_YBITS + DIV_DBITS + 4        -- 4 guard bits, generous not minimal
    DIV_M     = ceil(2**DIV_S / ROWS_IF)

This script is the SAME formula, run in Python, checked against the true
`ceil(j_rows / ROWS_IF)` for every j_rows in 1..MAXROWS (the full range the fixed
`j_rows` port now accepts).  It is not a sampling check: every value is tried.  If this
script prints PASS, the VHDL formula is exact over the whole range for the generics
given; if MAXROWS or ROWS_IF ever change, re-run it before trusting a new DIV_S/DIV_M.

Usage: python3 tools/check_mv_dist_div.py [MAXROWS] [ROWS_IF]
Defaults match rtl/mv_dist.vhd's shipped generics: MAXROWS=248320 (model_cfg_pkg vocab,
the 27B LM head's raw-mode row count, spec 7.6 -- NOT MAXROWS_BFP=17408, which bounds only
BFP-mode jobs), ROWS_IF=48.
"""
import sys


def clog2(n):
    if n <= 1:
        return 0
    b = 0
    while (1 << b) < n:
        b += 1
    return b


def derive(maxrows, rows_if):
    ybits = clog2(maxrows + rows_if)
    dbits = clog2(rows_if)
    s = ybits + dbits + 4
    m = (2**s + rows_if - 1) // rows_if  # ceil(2**s / rows_if)
    return s, m


def main(argv):
    maxrows = int(argv[1]) if len(argv) > 1 else 248320
    rows_if = int(argv[2]) if len(argv) > 2 else 48

    s, m = derive(maxrows, rows_if)
    print("MAXROWS=%d ROWS_IF=%d -> DIV_S=%d DIV_M=%d" % (maxrows, rows_if, s, m))

    bad = 0
    for j_rows in range(1, maxrows + 1):
        y = j_rows + rows_if - 1
        want = -(-j_rows // rows_if)  # ceil(j_rows / rows_if), exact in Python integers
        got = (y * m) >> s
        if got != want:
            bad += 1
            if bad <= 10:
                print("MISMATCH j_rows=%d want=%d got=%d" % (j_rows, want, got))

    if bad == 0:
        print("PASS: exact for every j_rows in 1..%d" % maxrows)
        return 0
    else:
        print("FAIL: %d mismatches out of %d" % (bad, maxrows))
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
