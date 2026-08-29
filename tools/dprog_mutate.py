#!/usr/bin/env python3
"""tools/dprog_mutate.py -- teeth for `tools/dprog_oracle.py`.

A checker never shown to fail has not been shown to work, so every claim the
oracle makes is worth exactly as much as this table.  Each row breaks the
EMITTED PROGRAM in one specific way and asks whether the oracle notices.

THE ROWS ARE NOT INVENTED HERE.  They are the twenty program mutations and
the seven subsystem A descriptor mutations of
`docs/debugging/2026-08-29_layer-descriptor-program.md` sections 6, 6.1 and
6.2, replayed against this oracle instead of against the RTL, so the two
tables are directly comparable and the SIX SILENT PASSES recorded there are
the rows that matter.  A mutation that does NOT bite here is reported under
its own name: that is the oracle's resolution floor and it is the most
valuable line in the output, not the least.

Verdicts:
  KILL     the oracle failed at least one check
  SURVIVE  the oracle passed a program that is broken
  NOCHANGE the mutation did not alter any byte -- NOT a survival, a harness
           defect.  The layer-program write-up hit exactly this and recorded
           it as a measurement trap: "a silent pass whose mutation changed
           nothing is not a silent pass".

    tools/dprog_mutate.py --prog OUT            # OUT holds d_table.hex + a*.hex
"""

import argparse
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import dprog_oracle as O                                       # noqa: E402


# --------------------------------------------------------------- byte tools
def rd(path):
    with open(path) as fh:
        return [ln.strip() for ln in fh if ln.strip()]


def wr(path, words):
    with open(path, "w") as fh:
        for w in words:
            fh.write("%016x\n" % (w & ((1 << 64) - 1)))


def words_of(path):
    return [int(s, 16) for s in rd(path)]


def setf(w, hi, lo, val):
    m = ((1 << (hi - lo + 1)) - 1) << lo
    return (w & ~m) | ((val << lo) & m)


def getf(w, hi, lo):
    return (w >> lo) & ((1 << (hi - lo + 1)) - 1)


class Prog(object):
    """The emitted program, as mutable words plus the A descriptor files."""

    def __init__(self, d):
        self.dir = d
        self.dpath = os.path.join(d, "d_table.hex")
        self.dw = words_of(self.dpath)
        self.steps = O.decode_d_table(self.dw)

    def flush(self):
        wr(self.dpath, self.dw)

    def w(self, step, word):
        return self.dw[8 * step + word]

    def setw(self, step, word, val):
        self.dw[8 * step + word] = val

    def find(self, pred, n=0):
        hits = [d for d in self.steps if pred(d)]
        if len(hits) <= n:
            raise RuntimeError("no such step")
        return hits[n].idx

    def afile(self, step):
        for fn in os.listdir(self.dir):
            if fn.startswith("a%02d_" % step) and fn.endswith(".hex"):
                return os.path.join(self.dir, fn)
        raise RuntimeError("no A descriptor for step %d" % step)


# ==========================================================================
# The mutations.  Each takes a Prog and edits it in place.
# ==========================================================================
def m01_order(p):
    """step ORDER: swap two adjacent A jobs of block 0."""
    a = p.find(lambda d: d.opcode == O.OP_A_JOB, 1)
    b = p.find(lambda d: d.opcode == O.OP_A_JOB, 2)
    for j in range(8):
        p.dw[8 * a + j], p.dw[8 * b + j] = p.dw[8 * b + j], p.dw[8 * a + j]


def m02_region(p):
    """REGION id: the v segment writes R_Z, not R_QKV."""
    s = p.find(lambda d: d.dst == O.RID["R_QKV"], 2)
    p.setw(s, 0, setf(p.w(s, 0), 31, 24, O.RID["R_Z"]))


def m02b_beta_alpha(p):
    """REGION id: BETA and ALPHA destinations swapped.  SILENT on the RTL --
    the two regions have the SAME width, so every structural check the region
    lock makes is satisfied and the values reach subsystem B on the wrong
    ports."""
    sb = p.find(lambda d: d.dst == O.RID["R_BETA"])
    sa = p.find(lambda d: d.dst == O.RID["R_ALPHA"])
    p.setw(sb, 0, setf(p.w(sb, 0), 31, 24, O.RID["R_ALPHA"]))
    p.setw(sa, 0, setf(p.w(sa, 0), 31, 24, O.RID["R_BETA"]))


def m03_dstoff(p):
    """DST OFFSET: the k segment's dst_off + 8."""
    s = p.find(lambda d: d.dst == O.RID["R_QKV"], 1)
    p.setw(s, 0, setf(p.w(s, 0), 63, 32, getf(p.w(s, 0), 63, 32) + 8))


def m04_ordinal(p):
    """ORDINAL: the first B_JOB's ordinal + 1."""
    s = p.find(lambda d: d.opcode == O.OP_B_JOB)
    p.setw(s, 3, setf(p.w(s, 3), 15, 8, getf(p.w(s, 3), 15, 8) + 1))


def m04b_norm_ordinal(p):
    """ORDINAL: block 0's norm claims ordinal 3.  SILENT on the RTL: on a
    VEC_NORM the field selects a norm WEIGHT that nothing loads."""
    s = p.find(lambda d: d.opcode == O.OP_VEC_NORM)
    p.setw(s, 3, setf(p.w(s, 3), 15, 8, 3))


def m05_src(p):
    """SRC region: the first qkv job reads R_X, not R_XN.  On the RTL this is
    DIFFERENT, not REFUSED: caught only because a reference program existed."""
    s = p.find(lambda d: d.dst == O.RID["R_QKV"])
    p.setw(s, 0, setf(p.w(s, 0), 23, 16, O.RID["R_X"]))


def m06_src2(p):
    """SRC2: the first residual's second operand is R_H, not R_ER."""
    s = p.find(lambda d: d.opcode == O.OP_VEC_RES)
    p.setw(s, 3, setf(p.w(s, 3), 55, 48, O.RID["R_H"]))


def m07_nrows(p):
    """N_ROWS: the first qkv job halved."""
    s = p.find(lambda d: d.dst == O.RID["R_QKV"])
    p.setw(s, 1, setf(p.w(s, 1), 31, 0, getf(p.w(s, 1), 31, 0) // 2))


def m08_opcode(p):
    """OPCODE: an A_JOB becomes a B_JOB."""
    s = p.find(lambda d: d.opcode == O.OP_A_JOB, 4)
    p.setw(s, 0, setf(p.w(s, 0), 7, 0, O.OP_B_JOB))


def m09_wexp(p):
    """W_EXP: the first qkv job + 1."""
    s = p.find(lambda d: d.dst == O.RID["R_QKV"])
    p.setw(s, 2, setf(p.w(s, 2), 31, 0, getf(p.w(s, 2), 31, 0) + 1))


def m10_outshift(p):
    """OUT_SHIFT + 1.  SILENT on the RTL: the BFP exponent absorbs it and
    even the differential could not see it."""
    s = p.find(lambda d: d.dst == O.RID["R_QKV"])
    p.setw(s, 2, setf(p.w(s, 2), 63, 32, getf(p.w(s, 2), 63, 32) + 1))


def m11_constbase(p):
    """CONST_BASE: block 0's norm names block 3.  SILENT on the RTL."""
    s = p.find(lambda d: d.opcode == O.OP_VEC_NORM)
    p.setw(s, 4, setf(p.w(s, 4), 31, 0, 3))


def m12_constexp(p):
    """CONST_EXP + 1 on every step.  SILENT on the RTL: published by
    seq_desc_fetch and consumed by nothing."""
    for i in range(len(p.steps)):
        p.setw(i, 4, setf(p.w(i, 4), 63, 32, getf(p.w(i, 4), 63, 32) + 1))


def m13_nsubw(p):
    """NSUB_W 24 -> 23 on every step.  SILENT on the RTL: D only range-checks
    it against NSUB_MAX.  The FK33 A wrapper refuses a mismatch with
    ERR_GEOM, so the field has real teeth in A and none at all in D."""
    for i in range(len(p.steps)):
        if p.steps[i].nsub_w:
            p.setw(i, 3, setf(p.w(i, 3), 31, 16, p.steps[i].nsub_w - 1))


def m14_pad(p):
    """PAD: word 3 [63:56] nonzero."""
    p.setw(1, 3, setf(p.w(1, 3), 63, 56, 0x5A))


def m15_end(p):
    """END_TOKEN removed."""
    del p.dw[8 * (len(p.steps) - 1):]


def m16_drop(p):
    """STEP DROPPED: block 0's first residual."""
    s = p.find(lambda d: d.opcode == O.OP_VEC_RES)
    del p.dw[8 * s:8 * s + 8]


def m19_lm_window_dropped(p):
    """One lm_head row window dropped.  The remaining windows still tile a
    PREFIX of the vocabulary, every descriptor is still well formed, and the
    machine computes an argmax over part of the vocabulary -- a silent wrong
    token, which is the failure the layer program's own window check exists
    to prevent and which no gateware check can reach."""
    s = p.find(lambda d: (d.flags & O.FLG_TO_SMP) != 0, 3)
    del p.dw[8 * s:8 * s + 8]


def m20_lm_one_job(p):
    """The lm_head as ONE 248,320-row job, which is what BOTH VHDL generators
    encode and what `matvec_int4_desc_axi:721-726` refuses in EVERY
    out_mode."""
    first = p.find(lambda d: (d.flags & O.FLG_TO_SMP) != 0)
    n = sum(1 for d in p.steps if d.flags & O.FLG_TO_SMP)
    total = sum(d.n_rows for d in p.steps if d.flags & O.FLG_TO_SMP)
    p.setw(first, 1, setf(p.w(first, 1), 31, 0, total))
    del p.dw[8 * (first + 1):8 * (first + n)]


# ---- subsystem A descriptor mutations ------------------------------------
def _a_edit(p, step, fn):
    path = p.afile(step)
    w = words_of(path)
    fn(w)
    wr(path, w)


def a01_bases_of_another_step(p):
    """The ffn_up step's bases pasted into the ffn_gate step.  ACCEPTED and
    SILENT by the gateware: both descriptors are perfectly well formed and
    only the bases differ.  'Nothing binds an A descriptor to the step it
    belongs to.'"""
    g = p.find(lambda d: d.dst == O.RID["R_G"])
    u = p.find(lambda d: d.dst == O.RID["R_U"])
    src = words_of(p.afile(u))
    dst = words_of(p.afile(g))
    npw, nps = dst[3] >> 16 & 0xFFFF, dst[3] >> 32 & 0xFFFF
    dst[8:8 + npw + nps] = src[8:8 + npw + nps]
    wr(p.afile(g), dst)


def a02_subregion_swap(p):
    """w_base[7] aimed at sub-region 8.  ACCEPTED and SILENT (worklog OI-1):
    nothing in the descriptor says what a sub-region should CONTAIN."""
    g = p.find(lambda d: d.dst == O.RID["R_G"])
    _a_edit(p, g, lambda w: w.__setitem__(8 + 7, w[8 + 8]))


def a03_xexp(p):
    """x_exp + 1.  ACCEPTED and SILENT."""
    g = p.find(lambda d: d.dst == O.RID["R_G"])

    def f(w):
        npw, nps = (w[3] >> 16) & 0xFFFF, (w[3] >> 32) & 0xFFFF
        e = 8 + npw + nps
        w[e + 2] = setf(w[e + 2], 31, 0, getf(w[e + 2], 31, 0) + 1)
    _a_edit(p, g, f)


def a04_dstoff(p):
    """dst_offset = 777 in the A descriptor.  A field subsystem A IGNORES,
    so the gateware accepts it and is CORRECT to.  It still disagrees with
    the D step, which is what makes it visible here."""
    g = p.find(lambda d: d.dst == O.RID["R_G"])
    _a_edit(p, g, lambda w: w.__setitem__(0, setf(w[0], 63, 32, 777)))


def a05_wbeats(p):
    """w_beats halved.  The one A mutation the gateware DOES refuse
    (err_code 0xF, ERR_SHAPE)."""
    g = p.find(lambda d: d.dst == O.RID["R_G"])

    def f(w):
        npw, nps = (w[3] >> 16) & 0xFFFF, (w[3] >> 32) & 0xFFFF
        e = 8 + npw + nps
        w[e + 1] = setf(w[e + 1], 31, 0, getf(w[e + 1], 31, 0) // 2)
    _a_edit(p, g, f)


def a06_base_plus_4k(p):
    """Every base + 4096, i.e. a wrong hbm_offset.  ACCEPTED and SILENT by
    the gateware: still 4 KB aligned, still inside the weight store."""
    g = p.find(lambda d: d.dst == O.RID["R_G"])

    def f(w):
        npw, nps = (w[3] >> 16) & 0xFFFF, (w[3] >> 32) & 0xFFFF
        for i in range(8, 8 + npw + nps):
            w[i] += 4096
    _a_edit(p, g, f)


def a07_codebook(p):
    """One codebook entry changed in the A descriptor.  flags bit 2 is
    `cb_load`, so this LOADS a codebook that disagrees with the one the
    packed file was quantised against.  Nothing in the repository compared
    the two before."""
    g = p.find(lambda d: d.dst == O.RID["R_G"])
    _a_edit(p, g, lambda w: w.__setitem__(5, w[5] ^ 0x01))


MUTATIONS = [
    ("m01 step order swapped",          m01_order),
    ("m02 region id: v -> R_Z",         m02_region),
    ("m02b BETA/ALPHA swapped",         m02b_beta_alpha),
    ("m03 dst_offset + 8",              m03_dstoff),
    ("m04 B_JOB ordinal + 1",           m04_ordinal),
    ("m04b norm ordinal = 3",           m04b_norm_ordinal),
    ("m05 src R_XN -> R_X",             m05_src),
    ("m06 src2 R_ER -> R_H",            m06_src2),
    ("m07 n_rows halved",               m07_nrows),
    ("m08 opcode A_JOB -> B_JOB",       m08_opcode),
    ("m09 w_exp + 1",                   m09_wexp),
    ("m10 out_shift + 1",               m10_outshift),
    ("m11 const_base = 3",              m11_constbase),
    ("m12 const_exp + 1 everywhere",    m12_constexp),
    ("m13 nsub_w 24 -> 23",             m13_nsubw),
    ("m14 word 3 pad nonzero",          m14_pad),
    ("m15 END_TOKEN removed",           m15_end),
    ("m16 residual step dropped",       m16_drop),
    ("m19 one lm_head window dropped",  m19_lm_window_dropped),
    ("m20 lm_head as one job",          m20_lm_one_job),
    ("a01 another step's bases",        a01_bases_of_another_step),
    ("a02 w_base[7] -> sub-region 8",   a02_subregion_swap),
    ("a03 x_exp + 1",                   a03_xexp),
    ("a04 A dst_offset = 777",          a04_dstoff),
    ("a05 w_beats halved",              a05_wbeats),
    ("a06 every base + 4096",           a06_base_plus_4k),
    ("a07 codebook entry changed",      a07_codebook),
]


def snapshot(d):
    out = {}
    for fn in sorted(os.listdir(d)):
        if fn.endswith(".hex"):
            with open(os.path.join(d, fn), "rb") as fh:
                out[fn] = fh.read()
    return out


def run_one(src, manifest, fn):
    tmp = tempfile.mkdtemp(prefix="dprog_mut_")
    try:
        for f in os.listdir(src):
            if f.endswith(".hex"):
                shutil.copy(os.path.join(src, f), tmp)
        before = snapshot(tmp)
        p = Prog(tmp)
        fn(p)
        p.flush()
        after = snapshot(tmp)
        if before == after:
            return "NOCHANGE", 0, "the mutation changed no byte"
        o = O.Oracle(manifest)
        try:
            o.run(os.path.join(tmp, "d_table.hex"), adir=tmp)
        except O.OracleError as e:
            return "KILL", 1, "decode refused: %s" % e
        if o.fails:
            tags = sorted(set(t for t, _ in o.fails))
            return "KILL", len(o.fails), ",".join(tags)
        return "SURVIVE", 0, ""
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--prog", required=True,
                    help="directory holding d_table.hex and a*.hex")
    ap.add_argument("--manifest", default=O.DEF_MANIFEST)
    ap.add_argument("--only", help="substring filter")
    a = ap.parse_args(argv)

    o = O.Oracle(a.manifest)
    o.run(os.path.join(a.prog, "d_table.hex"), adir=a.prog)
    print("CONTROL (unmutated): %d checks, %d FAIL -> %s"
          % (o.checks, len(o.fails), "PASS" if not o.fails else "FAIL"))
    if o.fails:
        for t, m in o.fails[:5]:
            print("   %s %s" % (t, m))
        print("control does not pass; the table below would be meaningless")
        return 2

    print()
    print("%-34s %-9s %-6s %s" % ("mutation", "verdict", "fails", "checks hit"))
    print("-" * 92)
    kills = surv = noch = 0
    survivors = []
    for name, fn in MUTATIONS:
        if a.only and a.only not in name:
            continue
        try:
            v, n, tags = run_one(a.prog, a.manifest, fn)
        except Exception as e:                              # noqa: BLE001
            v, n, tags = "ERROR", 0, "%s: %s" % (type(e).__name__, e)
        print("%-34s %-9s %-6s %s" % (name, v, n or "", tags))
        if v == "KILL":
            kills += 1
        elif v == "SURVIVE":
            surv += 1
            survivors.append(name)
        elif v == "NOCHANGE":
            noch += 1
    print("-" * 92)
    print("KILLED %d   SURVIVED %d   NOCHANGE %d" % (kills, surv, noch))
    if survivors:
        print("\nSURVIVORS -- the oracle's resolution floor, name them in the "
              "write-up:")
        for s in survivors:
            print("  * %s" % s)
    return 0


if __name__ == "__main__":
    sys.exit(main())
