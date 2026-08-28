#!/usr/bin/env python3
"""Emit a REAL-WEIGHT memory image for sim/tb_llama_top.vhd.

WHY THIS EXISTS.  `sim/tb_llama_top.vhd`'s AXI read slaves answer every address
from `wword()`, an arithmetic function: the INT4 nibbles are a byte hash and the
per-block scales are masked into [16384, 32767].  That is sufficient for the
SEAM properties the bench checks, and it is NOT sufficient for any claim about
magnitude, because the resulting weight matrix has an rms row norm of about
2^4.8 while a trained one has an rms row norm of about 2^0.  The residual
stream's magnitude is a product of those row norms, so the synthetic image
drives it up about five octaves per matvec.

This script packs REAL Qwen3.5-9B weights into the bench's own geometry
(ROWS_IF=4, BLK=32, AXI_DW=128, NPORTS_W=4, NPORTS_S=1) using tools/pack_int4's
own `pack()`, so the byte layout is 6.5a's and not a second copy of it, and
writes one hex word per line for the bench to read with textio.

THE DIMENSION REDUCTION IS THE ONE MODELLING CHOICE, AND IT IS STATED.
The bench runs `mk_shape_scaled`: hidden 64 against the model's 4096, ffn 128
against 12288.  A real weight matrix cannot be used at that width unchanged, so
one of two reductions is applied, selected by --reduce:

  slice  W[:n_rows, :n_cols].  The literal real weights, at 1/64 the width.
         Its row norm is the real one times sqrt(n_cols/K), i.e. EXACTLY three
         octaves smaller at K=4096, n_cols=64.  Honest but biased LOW.
  pool   sum adjacent groups of K/n_cols columns.  Preserves the l2 row norm
         of the real layer (up to the correlation between columns), which is
         the quantity that decides magnitude propagation.  DEFAULT.

Neither is tuned: `pool` is fixed by the arithmetic of preserving a row norm,
not chosen to make a number come out, and both are reported side by side.

w_exp is NOT free.  `sim/llama_sched_pkg.vhd` emits `(i mod 5) - 2` per step and
the descriptor carries it, so the quantizer is given that value rather than
choosing its own.  out_shift is likewise the schedule's `i mod 5`.

The CODEBOOK is `rtl/llama_top.vhd`'s `cb_int4`, the two's-complement int4
identity (i for i<8, i-16 otherwise), NOT IQ4_NL.  It is not ascending, so the
value-to-index step is `code & 15` and not a searchsorted.
"""

import argparse, os, sys
import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
import pack_int4 as P
from gguf import GGUFReader

BLOCK    = 32
ROWS_IF  = 4
AXI_DW   = 128
NPORTS_W = 4
HDR      = 4096
SUB      = 4096          # bench: port p is at base + p*4096, scales at +4*4096
# BEATS is what is EMITTED, not what the sub-region holds.  A sub-region is 256
# sixteen-byte beats, but at this shape no job ever reads past beat 63:
# tiles*NB is at most 32*2 (rows 128, cols 64) or 16*4 (rows 64, cols 128), and
# the scale region needs ceil(64/2) = 32 superwords.  Emitting 256 would
# quadruple both the file and the bench's elaborated array for zeros.
BEATS    = 64

# ---- the scaled shape, mirroring rtl/llama_map_pkg.mk_shape_scaled ----------
HIDDEN, FFN = 64, 128
KEY_HEADS, VAL_HEADS, HEAD_DIM = 2, 4, 32
ATTN_Q_HEADS, ATTN_KV_HEADS, ATTN_HEAD_DIM = 2, 1, 32
VOCAB_SHARD = 128
KEY_DIM = KEY_HEADS * HEAD_DIM          # 64
VAL_DIM = VAL_HEADS * HEAD_DIM          # 128
ATT_Q   = ATTN_Q_HEADS * ATTN_HEAD_DIM  # 64
ATT_QG  = 2 * ATT_Q                     # 128
ATT_KV  = ATTN_KV_HEADS * ATTN_HEAD_DIM # 32

# ---- the real model, mirroring rtl/model_cfg_pkg.QWEN35_9B -----------------
R_HIDDEN, R_FFN = 4096, 12288
R_KEY_DIM = 16 * 128     # lin_key_heads * lin_head_dim
R_VAL_DIM = 32 * 128     # lin_val_heads * lin_head_dim

OP_A, OP_B, OP_C, OP_NORM, OP_RES, OP_SWG, OP_END = 0, 1, 2, 4, 5, 6, 7


def build_plan(blocks, attn_interval):
    """The A jobs of sim/llama_sched_pkg.build_plan, in step order.

    Returns a list of one entry per step: None for a non-A step, else a dict
    with the shape and the real tensor it stands for.
    """
    plan = []

    def emit(op, **kw):
        plan.append(dict(op=op, **kw))

    def ffn(b):
        emit(OP_NORM)
        emit(OP_A, rows=FFN, cols=HIDDEN, tens=f"blk.{b}.ffn_gate.weight", r0=0)
        emit(OP_A, rows=FFN, cols=HIDDEN, tens=f"blk.{b}.ffn_up.weight", r0=0)
        emit(OP_SWG)
        emit(OP_A, rows=HIDDEN, cols=FFN, tens=f"blk.{b}.ffn_down.weight", r0=0)
        emit(OP_RES)

    for b in range(blocks):
        if (b + 1) % attn_interval == 0:
            emit(OP_NORM)
            # att_qg is Q AND the gate, and in this model they are ONE tensor:
            # `blk.N.attn_q.weight` has 8192 rows against attn_q_heads *
            # attn_head_dim = 4096, i.e. exactly the 2*att_q the schedule
            # allocates for R_QG.  The attention layers have no separate
            # attn_gate tensor -- only the 24 GDN layers do -- and assuming
            # otherwise is what this comment exists to stop.
            emit(OP_A, rows=ATT_QG, cols=HIDDEN, r0=0,
                 tens=f"blk.{b}.attn_q.weight")
            emit(OP_A, rows=ATT_KV, cols=HIDDEN, tens=f"blk.{b}.attn_k.weight", r0=0)
            emit(OP_A, rows=ATT_KV, cols=HIDDEN, tens=f"blk.{b}.attn_v.weight", r0=0)
            emit(OP_C)
            emit(OP_A, rows=HIDDEN, cols=ATT_Q,
                 tens=f"blk.{b}.attn_output.weight", r0=0)
            emit(OP_RES)
        else:
            emit(OP_NORM)
            emit(OP_A, rows=KEY_DIM, cols=HIDDEN,
                 tens=f"blk.{b}.attn_qkv.weight", r0=0)
            emit(OP_A, rows=KEY_DIM, cols=HIDDEN,
                 tens=f"blk.{b}.attn_qkv.weight", r0=R_KEY_DIM)
            emit(OP_A, rows=VAL_DIM, cols=HIDDEN,
                 tens=f"blk.{b}.attn_qkv.weight", r0=2 * R_KEY_DIM)
            emit(OP_A, rows=VAL_DIM, cols=HIDDEN,
                 tens=f"blk.{b}.attn_gate.weight", r0=0)
            emit(OP_A, rows=VAL_HEADS, cols=HIDDEN,
                 tens=f"blk.{b}.ssm_beta.weight", r0=0)
            emit(OP_A, rows=VAL_HEADS, cols=HIDDEN,
                 tens=f"blk.{b}.ssm_alpha.weight", r0=0)
            emit(OP_B)
            emit(OP_A, rows=HIDDEN, cols=VAL_DIM,
                 tens=f"blk.{b}.ssm_out.weight", r0=0)
            emit(OP_RES)
        ffn(b)

    emit(OP_NORM)
    emit(OP_A, rows=VOCAB_SHARD, cols=HIDDEN, tens="output.weight", r0=0)
    emit(OP_END)
    return plan


def reduce_cols(W, cols, mode):
    K = W.shape[1]
    if K == cols:
        return W
    if mode == "slice":
        return W[:, :cols]
    assert K % cols == 0, f"pool needs cols|K, got {cols} and {K}"
    return W.reshape(W.shape[0], cols, K // cols).sum(axis=2)


def quantize_fixed(W, w_exp):
    """(rows, cols) f32 -> (idx uint8 (rows,NB,32), scale uint16 (rows,NB)).

    The codebook is the two's-complement int4 identity, so the mapping is a
    plain round-and-clip and the index is `code & 15`.  w_exp is GIVEN, because
    the descriptor already carries the schedule's value.
    """
    M, K = W.shape
    NB = (K + BLOCK - 1) // BLOCK
    Wp = np.zeros((M, NB * BLOCK), dtype=np.float64)
    Wp[:, :K] = W
    tgt = Wp.reshape(M, NB, BLOCK) * (2.0 ** w_exp)
    valid = np.zeros(NB * BLOCK, dtype=bool)
    valid[:K] = True
    valid = valid.reshape(NB, BLOCK)
    amax = (np.abs(tgt) * valid[None]).max(axis=2)
    # the codebook extreme is 8 in magnitude (-8), and scale/2^15 < 1
    sc = np.clip(np.rint(amax * (32768.0 / 8.0)), 0, 32767).astype(np.uint16)
    assert (amax * (32768.0 / 8.0) <= 32767.0).all(), \
        "w_exp too large for uint15 scale: a block needs scale > 32767"
    s = np.where(sc > 0, sc.astype(np.float64), 1.0) / 32768.0
    code = np.clip(np.rint(tgt / s[:, :, None]), -8, 7).astype(np.int64)
    code[np.broadcast_to((sc == 0)[:, :, None], code.shape)] = 0
    code[np.broadcast_to((~valid)[None], code.shape)] = 0
    return (code & 15).astype(np.uint8), sc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gguf", default="/mnt/storage/llama-models/qwen35-9b/"
                                      "Qwen3.5-9B-BF16.gguf")
    ap.add_argument("--blocks", type=int, default=32)
    ap.add_argument("--attn-interval", type=int, default=4)
    ap.add_argument("--reduce", choices=["pool", "slice"], default="pool")
    ap.add_argument("--out", required=True)
    ap.add_argument("--stats", default=None)
    a = ap.parse_args()

    plan = build_plan(a.blocks, a.attn_interval)
    nstep = len(plan)

    # name -> (set of column widths used, max row index touched)
    need = {}
    def want(nm, cols, hi):
        c, r = need.get(nm, (set(), 0))
        c.add(cols); need[nm] = (c, max(r, hi))
    for st in plan:
        if st["op"] != OP_A:
            continue
        t = st["tens"]
        if isinstance(t, str):
            want(t, st["cols"], st["r0"] + st["rows"])
        else:
            for nm, o, n in t:
                want(nm, st["cols"], o + n)

    sys.stderr.write(f"reading {len(need)} tensors from {a.gguf}\n")
    rd = GGUFReader(a.gguf, "r")
    # Reduce EVERY needed tensor to the small shapes it is used at, one at a
    # time, so the 200 MB f32 transient never coexists with another.
    small = {}
    for t in rd.tensors:
        if t.name not in need:
            continue
        cols_set, rowcap = need[t.name]
        W = P.tensor_as_mk(t)[:rowcap]
        red = {}
        for cols in sorted(cols_set):
            red[cols] = reduce_cols(W, cols, a.reduce).astype(np.float32)
        small[t.name] = red
        del W
    missing = set(need) - set(small)
    assert not missing, f"tensors not in the gguf: {sorted(missing)[:5]}"

    cb = np.array([i if i < 8 else i - 16 for i in range(16)], dtype=np.int8)

    words = np.zeros((nstep, NPORTS_W + 1, BEATS, 16), dtype=np.uint8)
    stats = []
    for i, st in enumerate(plan):
        if st["op"] != OP_A:
            continue
        rows, cols = st["rows"], st["cols"]
        w_exp = (i % 5) - 2
        out_shift = i % 5
        t = st["tens"]
        if isinstance(t, str):
            W = small[t][cols][st["r0"]:st["r0"] + rows, :]
        else:
            parts = [small[nm][cols][o:o + n, :] for nm, o, n in t]
            W = np.concatenate(parts, axis=0)
        assert W.shape == (rows, cols), (W.shape, rows, cols)
        idx, scl = quantize_fixed(W.astype(np.float64), w_exp)
        blob = P.pack(idx, scl, w_exp, rows, cols, ROWS_IF, out_shift, cb,
                      axi_dw=AXI_DW)
        NB, tiles, nports, sub_sz, nss, scl_sub_sz, total = \
            P.packed_layout(rows, cols, ROWS_IF, AXI_DW)
        assert nports == NPORTS_W and nss == 1 and sub_sz == SUB \
            and scl_sub_sz == SUB, (nports, nss, sub_sz, scl_sub_sz)
        assert tiles * NB <= BEATS, \
            f"step {i} needs {tiles*NB} beats, BEATS is {BEATS}"
        body = np.frombuffer(blob[HDR:], dtype=np.uint8)
        assert body.size == SUB * (NPORTS_W + 1), body.size
        full = body.reshape(NPORTS_W + 1, SUB // 16, 16)
        words[i] = full[:, :BEATS, :]
        rn = float(np.sqrt((W.astype(np.float64) ** 2).sum(axis=1).mean()))
        stats.append((i, rows, cols, w_exp, out_shift, rn,
                      float(np.log2(rn)) if rn > 0 else float("-inf")))

    # NO header line: sim/tb_llama_top.vhd reads this with `hread`, one
    # 32-character word per line and nothing else.  The provenance lives in the
    # --stats CSV beside it.
    with open(a.out, "w") as f:
        for i in range(nstep):
            for p in range(NPORTS_W + 1):
                for b in range(BEATS):
                    # one 128-bit word, MSB byte first, so the bench can read it
                    # straight into a std_logic_vector(127 downto 0)
                    f.write(words[i, p, b][::-1].tobytes().hex())
                    f.write("\n")
    sys.stderr.write(f"wrote {a.out}: {nstep} steps x {NPORTS_W+1} ports x "
                     f"{BEATS} beats\n")

    if a.stats:
        with open(a.stats, "w") as f:
            f.write("step,rows,cols,w_exp,out_shift,rownorm,log2_rownorm\n")
            for s in stats:
                f.write(",".join(str(x) for x in s) + "\n")
    ln = [s[6] for s in stats]
    sys.stderr.write(f"A jobs {len(ln)}  mean log2 row norm "
                     f"{np.mean(ln):.3f}  min {min(ln):.3f}  max {max(ln):.3f}\n")


if __name__ == "__main__":
    main()
