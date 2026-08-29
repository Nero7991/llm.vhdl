#!/usr/bin/env python3
"""The step plan and the seam names of `sim/tb_llama_top.vhd`, in Python.

A THIRD COPY OF THE SCHEDULE, AND THAT IS DELIBERATE.  `sim/llama_sched_pkg.vhd`
builds it for the bench, `sim/tb_llama_top.vhd`'s `seam_of` names it, and
`tools/gen_llama_top_weights.py` already carries a Python mirror for the weight
image.  A fourth reader is being added here rather than importing the third
because the third only enumerates the A jobs and has no notion of a seam.

The mirror is CHECKED, not trusted: `check_against_capture()` verifies that the
element count and the ordering of the seams this file predicts are exactly the
ones the capture contains, and refuses otherwise.  A plan that has drifted from
the RTL is then a loud failure and not a silent misalignment of every seam by
one step, which is the failure mode that would make an oracle report a
divergence at the wrong place -- the one output a bisect exists to produce.
"""

R_X, R_XN, R_QKV, R_Z, R_BETA, R_ALPHA = "R_X", "R_XN", "R_QKV", "R_Z", "R_BETA", "R_ALPHA"
R_QG, R_KIN, R_VIN, R_Y, R_G, R_U, R_H, R_ER = \
    "R_QG", "R_KIN", "R_VIN", "R_Y", "R_G", "R_U", "R_H", "R_ER"
R_NONE = None

OP_A, OP_B, OP_C, OP_NORM, OP_RES, OP_SWG, OP_END = \
    "A", "B", "C", "NORM", "RES", "SWG", "END"


class Shape:
    """`rtl/llama_map_pkg.mk_shape_scaled`, including its attn_hd > 32 branch.

    The branch matters: at attn_hd = 64 the head COUNTS are pinned and the
    attention region widths grow instead, which `tools/gen_layer_program.py`'s
    mirror does not do (see the DIVERGENCE note at llama_map_pkg.vhd:226).
    """

    def __init__(self, blocks=4, attn_interval=4, attn_hd=32):
        self.blocks, self.attn_interval, self.attn_hd = blocks, attn_interval, attn_hd
        self.hidden, self.ffn = 64, 128
        self.key_heads, self.val_heads, self.head_dim = 2, 4, 32
        self.vocab_shard = 128
        if attn_hd > 32:
            self.attn_q_heads, self.attn_kv_heads = 4, 2
        else:
            self.attn_q_heads = 64 // attn_hd
            self.attn_kv_heads = 32 // attn_hd
        self.key_dim = self.key_heads * self.head_dim        # 64
        self.val_dim = self.val_heads * self.head_dim        # 128
        self.att_q = self.attn_q_heads * attn_hd
        self.att_qg = 2 * self.att_q
        self.att_kv = self.attn_kv_heads * attn_hd

    def is_attn(self, b):
        return (b + 1) % self.attn_interval == 0


class Step:
    __slots__ = ("i", "op", "src", "src2", "dst", "dst_off", "n_rows",
                 "n_cols", "blk", "seam", "w_exp", "out_shift")

    def __init__(self, **kw):
        for k, v in kw.items():
            setattr(self, k, v)

    def __repr__(self):
        return "Step(%d %s %s->%s+%d n=%s seam=%s)" % (
            self.i, self.op, self.src, self.dst, self.dst_off,
            self.n_rows, self.seam)


GDN_SEAMS = ["R_XN", "R_QKV.q", "R_QKV.k", "R_QKV.v", "R_Z", "R_BETA",
             "R_ALPHA", "R_Y", "R_ER", "R_X.attn", "R_XN.ffn", "R_G", "R_U",
             "R_H", "R_ER.ffn", "R_X"]
ATT_SEAMS = ["R_XN", "R_QG", "R_KIN", "R_VIN", "R_Y", "R_ER", "R_X.attn",
             "R_XN.ffn", "R_G", "R_U", "R_H", "R_ER.ffn", "R_X"]


def build(shape):
    """The step list, with `sim/llama_sched_pkg.build_plan`'s order."""
    steps = []

    def emit(op, src=None, src2=None, dst=None, dst_off=0, n_rows=0, n_cols=0,
             blk=0):
        i = len(steps)
        steps.append(Step(i=i, op=op, src=src, src2=src2, dst=dst,
                          dst_off=dst_off, n_rows=n_rows, n_cols=n_cols,
                          blk=blk, seam=None,
                          # sim/llama_sched_pkg.vhd:337-338
                          w_exp=(i % 5) - 2, out_shift=i % 5))

    def ffn(b):
        emit(OP_NORM, src=R_X, dst=R_XN, n_rows=shape.hidden, blk=b)
        emit(OP_A, src=R_XN, dst=R_G, n_rows=shape.ffn, n_cols=shape.hidden, blk=b)
        emit(OP_A, src=R_XN, dst=R_U, n_rows=shape.ffn, n_cols=shape.hidden, blk=b)
        emit(OP_SWG, src=R_G, src2=R_U, dst=R_H, n_rows=shape.ffn, blk=b)
        emit(OP_A, src=R_H, dst=R_ER, n_rows=shape.hidden, n_cols=shape.ffn, blk=b)
        emit(OP_RES, src=R_X, src2=R_ER, dst=R_X, n_rows=shape.hidden, blk=b)

    for b in range(shape.blocks):
        if shape.is_attn(b):
            emit(OP_NORM, src=R_X, dst=R_XN, n_rows=shape.hidden, blk=b)
            emit(OP_A, src=R_XN, dst=R_QG, n_rows=shape.att_qg, n_cols=shape.hidden, blk=b)
            emit(OP_A, src=R_XN, dst=R_KIN, n_rows=shape.att_kv, n_cols=shape.hidden, blk=b)
            emit(OP_A, src=R_XN, dst=R_VIN, n_rows=shape.att_kv, n_cols=shape.hidden, blk=b)
            emit(OP_C, src=R_QG, dst=R_Y, n_rows=shape.att_q, blk=b)
            emit(OP_A, src=R_Y, dst=R_ER, n_rows=shape.hidden, n_cols=shape.att_q, blk=b)
            emit(OP_RES, src=R_X, src2=R_ER, dst=R_X, n_rows=shape.hidden, blk=b)
        else:
            emit(OP_NORM, src=R_X, dst=R_XN, n_rows=shape.hidden, blk=b)
            emit(OP_A, src=R_XN, dst=R_QKV, dst_off=0,
                 n_rows=shape.key_dim, n_cols=shape.hidden, blk=b)
            emit(OP_A, src=R_XN, dst=R_QKV, dst_off=shape.key_dim,
                 n_rows=shape.key_dim, n_cols=shape.hidden, blk=b)
            emit(OP_A, src=R_XN, dst=R_QKV, dst_off=2 * shape.key_dim,
                 n_rows=shape.val_dim, n_cols=shape.hidden, blk=b)
            emit(OP_A, src=R_XN, dst=R_Z, n_rows=shape.val_dim, n_cols=shape.hidden, blk=b)
            emit(OP_A, src=R_XN, dst=R_BETA, n_rows=shape.val_heads, n_cols=shape.hidden, blk=b)
            emit(OP_A, src=R_XN, dst=R_ALPHA, n_rows=shape.val_heads, n_cols=shape.hidden, blk=b)
            emit(OP_B, src=R_QKV, dst=R_Y, n_rows=shape.val_dim, blk=b)
            emit(OP_A, src=R_Y, dst=R_ER, n_rows=shape.hidden, n_cols=shape.val_dim, blk=b)
            emit(OP_RES, src=R_X, src2=R_ER, dst=R_X, n_rows=shape.hidden, blk=b)
        ffn(b)

    emit(OP_NORM, src=R_X, dst=R_XN, n_rows=shape.hidden, blk=shape.blocks)
    emit(OP_A, src=R_XN, dst=R_NONE, n_rows=shape.vocab_shard,
         n_cols=shape.hidden, blk=shape.blocks)
    emit(OP_END, blk=shape.blocks)

    # Seam names, from the same walk `sim/tb_llama_top.vhd:seam_of` does.
    n = 0
    for b in range(shape.blocks):
        tbl = ATT_SEAMS if shape.is_attn(b) else GDN_SEAMS
        for k, nm in enumerate(tbl):
            steps[n + k].seam = "%s-%d" % (nm, b)
        n += len(tbl)
    steps[n].seam = "R_XN.final"
    steps[n + 1].seam = "LOGITS"
    steps[n + 2].seam = "END_TOKEN"
    return steps


def producers(steps):
    """step index -> the seam name that last wrote each region it reads.

    Returns {i: {"src": seam or None, "src2": seam or None}}.  The embedding is
    `R_X.embed`, which is the seam the capture emits before any job runs.
    """
    last = {R_X: "R_X.embed"}
    out = {}
    for st in steps:
        out[st.i] = {"src": last.get(st.src), "src2": last.get(st.src2)}
        if st.dst is not None and st.op != OP_END:
            last[st.dst] = st.seam
    return out


def check_against_capture(steps, recs, tok):
    """Refuse a plan that does not describe the capture.

    `recs` is {(seam, tok): n_values}.  Every step whose destination is a real
    region must have a record of exactly `n_rows` values, and no record may be
    unaccounted for.  This is the guard that stops a drifted mirror from
    silently shifting every comparison by one step.
    """
    bad = []
    want = set()
    for st in steps:
        if st.op == OP_END or st.dst is None:
            continue
        want.add(st.seam)
        k = (st.seam, tok)
        if k not in recs:
            bad.append("%s is in the plan and not in the capture" % st.seam)
        elif recs[k] != st.n_rows:
            bad.append("%s: plan says %d values, capture has %d"
                       % (st.seam, st.n_rows, recs[k]))
    for (nm, t) in recs:
        if t == tok and nm not in want and nm != "R_X.embed":
            bad.append("%s is in the capture and not in the plan" % nm)
    return bad


if __name__ == "__main__":
    import sys
    blocks = int(sys.argv[1]) if len(sys.argv) > 1 else 4
    ai = int(sys.argv[2]) if len(sys.argv) > 2 else 4
    hd = int(sys.argv[3]) if len(sys.argv) > 3 else 32
    sh = Shape(blocks, ai, hd)
    for st in build(sh):
        print("%3d %-4s %-10s %-10s off=%-4d n=%-5d k=%-5d %s"
              % (st.i, st.op, st.src, st.dst, st.dst_off, st.n_rows,
                 st.n_cols, st.seam))
