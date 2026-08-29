#!/usr/bin/env python3
"""The integration-level model for subsystem C's `R_Y`.

WHAT THIS CLOSES.  `docs/debugging/2026-08-29_first-bisect.md` names four `R_Y`
seams as the largest remaining coverage hole:

    NOT CHECKED  R_Y-3   subsystem C has no integration-level model

and records that mutation R7 -- the `v_ref` sequence reset issued per TOKEN
instead of per SEQUENCE -- survives every value oracle in the repository for
exactly that reason.  This module builds the missing model.

HOW IT IS POSSIBLE AT ALL.  Subsystem C's entire input at the integration level
is three regions the capture already emits -- `R_QG`, `R_KIN`, `R_VIN` -- plus
two layer constants (`rtl/llama_top.vhd`'s `qkn_const` gains).  The KV cache it
reads at token t is the records tokens 0..t-1 wrote from THEIR `R_KIN`/`R_VIN`,
so the whole sequence state is reconstructible from the capture with nothing
taken from the RTL.  `ref/attn_block_cap_vec.c` runs `ref/attn_block_vec.c`'s
`attn_token()` over that reconstruction, layer-major, with one cache and one
`v_ref` fold per attention layer.

WHAT THE MODEL DOES NOT COVER.  Three things, all stated rather than implied:

  * subsystem B.  `R_Y-0`, `R_Y-1`, `R_Y-2` at a GDN block come from
    `rtl/gdn_block.vhd`, whose input is `R_QKV` plus a RECURRENT STATE that no
    region holds and the capture cannot see.  That is a different problem and
    this module does not pretend to solve it; it reports those seams as still
    NOT CHECKED.
  * the per-site fixed-point numerics, which `ref/attn_block_vec.c`'s own
    header already declares shared.  What is checked is the COMPOSITION and,
    new here, the cache across tokens.
  * a capture whose attention positions are not 0, 1, ... in order.  The C
    driver refuses that rather than guessing a cache for it.

usage:
  attn_oracle.py capture.txt --blocks 4 --attn-int 4 --attn-hd 16 \
      [--kv-block 4] [--n-rot 8] [--qkn-exp 12] [-v]
"""
import argparse
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
REPO = os.path.dirname(os.path.dirname(HERE))

import scaled_plan as SP           # noqa: E402


def qkn_const(head_dim, seed, qkn_exp):
    """`rtl/llama_top.vhd:qkn_const`, a testbench constant and not arithmetic.

    Transcribed rather than derived because it IS a constant of the stimulus,
    the same standing as `vec_oracle.norm_w_const`.  Held in Python so that
    `ref/attn_block_cap_vec.c` contains no copy of any RTL constant.
    """
    return [(1 << qkn_exp) + ((i * seed) % 512) - 256 for i in range(head_dim)]


def build_oracle(verbose=False):
    """Compile `ref/attn_block_cap_vec.c` into a scratch binary."""
    out = os.path.join(tempfile.mkdtemp(prefix="attn_cap_"), "attn_block_cap_vec")
    src = os.path.join(REPO, "ref", "attn_block_cap_vec.c")
    cmd = ["gcc", "-O2", "-o", out, src, "-lm"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit("attn_oracle: could not build the oracle\n" + r.stderr)
    if verbose:
        print("# built %s" % out)
    return out


def attn_layers(shape):
    """(block index, attention-layer ordinal) for every attention block.

    The ordinal is `rtl/llama_top.vhd:3575`'s
    `c_layer = (j_blk + 1) / attn_interval - 1`, which is the ordinal among
    attention blocks and NOT the block index.
    """
    out = []
    for b in range(shape.blocks):
        if shape.is_attn(b):
            out.append((b, (b + 1) // shape.attn_interval - 1))
    return out


def predict(recs_by_key, shape, toks, kv_block, n_rot, qkn_exp, verbose=False,
            fold="perlayer"):
    """Run the oracle over the capture.  Returns {(seam, tok): (exp, mant)}."""
    lays = attn_layers(shape)
    if not lays:
        return {}, [], []
    N = shape.attn_hd
    N_QH, N_KVH = shape.attn_q_heads, shape.attn_kv_heads
    NTOK = len(toks)
    if toks != list(range(NTOK)):
        raise SystemExit("attn_oracle: the capture's token indices are %s; "
                         "this model assumes one contiguous sequence starting "
                         "at 0." % toks)

    d = tempfile.mkdtemp(prefix="attn_cap_")
    stim, pred = os.path.join(d, "stim.txt"), os.path.join(d, "pred.txt")
    qnw = qkn_const(N, 37, qkn_exp)
    knw = qkn_const(N, 53, qkn_exp)
    missing = []
    with open(stim, "w") as fp:
        fp.write("%d %d %d %d %d %d %d\n"
                 % (N, N_QH, N_KVH, kv_block, n_rot, len(lays), NTOK))
        fp.write("%d %d\n" % (qkn_exp, qkn_exp))
        fp.write(" ".join(str(v) for v in qnw) + "\n")
        fp.write(" ".join(str(v) for v in knw) + "\n")
        for (b, _l) in lays:
            for t in toks:
                need = ["R_QG-%d" % b, "R_KIN-%d" % b, "R_VIN-%d" % b]
                if any((nm, t) not in recs_by_key for nm in need):
                    missing.append((b, t))
                    raise SystemExit(
                        "attn_oracle: block %d token %d is missing one of %s "
                        "in the capture, so no prediction can be made for it."
                        % (b, t, need))
                qg = recs_by_key[("R_QG-%d" % b, t)]
                ki = recs_by_key[("R_KIN-%d" % b, t)]
                vi = recs_by_key[("R_VIN-%d" % b, t)]
                for nm, r, want in (("R_QG", qg, 2 * N * N_QH),
                                    ("R_KIN", ki, N * N_KVH),
                                    ("R_VIN", vi, N * N_KVH)):
                    if len(r.v) != want:
                        raise SystemExit(
                            "attn_oracle: %s-%d tok %d has %d values, the shape "
                            "says %d.  The shape flags are wrong, or the plan "
                            "has drifted; either way a comparison here would be "
                            "a misalignment reported as a defect."
                            % (nm, b, t, len(r.v), want))
                fp.write("%d %d %d %d\n" % (t, qg.exp, ki.exp, vi.exp))
                fp.write(" ".join(str(v) for v in qg.v) + "\n")
                fp.write(" ".join(str(v) for v in ki.v) + "\n")
                fp.write(" ".join(str(v) for v in vi.v) + "\n")

    exe = build_oracle(verbose)
    r = subprocess.run([exe, stim, pred, fold], capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit("attn_oracle: the oracle refused the stimulus\n"
                         + r.stdout + r.stderr)

    out, vtrace = {}, []
    with open(pred) as fp:
        cur = None
        for line in fp:
            if line.startswith("#"):
                continue
            f = line.split()
            if not f:
                continue
            if f[0] == "Y":
                cur = (int(f[1]), int(f[2]), int(f[3]), int(f[4]))
            elif f[0] == "VREF":
                vtrace.append((int(f[1]), int(f[2]),
                               [int(x) for x in f[3:]]))
            elif cur is not None:
                li, t, ye, n = cur
                v = [int(x) for x in f]
                if len(v) != n:
                    raise SystemExit("attn_oracle: prediction for layer %d "
                                     "token %d has %d values, header says %d"
                                     % (li, t, len(v), n))
                b = lays[li][0]
                out[("R_Y-%d" % b, t)] = (ye, v)
                cur = None
    return out, [b for (b, _l) in lays], vtrace


def compare(recs_by_key, pred):
    """Bit-for-bit, in the shape `bisect_scaled.py`'s reports already use."""
    rows = []
    for (nm, t), (ye, v) in sorted(pred.items(), key=lambda kv: (kv[0][1], kv[0][0])):
        if (nm, t) not in recs_by_key:
            rows.append((nm, t, "MISSING", None))
            continue
        r = recs_by_key[(nm, t)]
        if len(r.v) != len(v):
            rows.append((nm, t, "LENGTH %d vs %d" % (len(v), len(r.v)), None))
            continue
        bad = [i for i in range(len(v)) if v[i] != r.v[i]]
        if r.exp == ye and not bad:
            rows.append((nm, t, "ok", None))
        else:
            first = bad[0] if bad else None
            rows.append((nm, t,
                         "exp %d expected vs %d captured, %d of %d mantissas differ"
                         % (ye, r.exp, len(bad), len(v)),
                         None if first is None
                         else (first, v[first], r.v[first])))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("--blocks", type=int, default=4)
    ap.add_argument("--attn-int", type=int, default=4)
    ap.add_argument("--attn-hd", type=int, default=16)
    ap.add_argument("--kv-block", type=int, default=4)
    ap.add_argument("--n-rot", type=int, default=8)
    ap.add_argument("--qkn-exp", type=int, default=12)
    ap.add_argument("--fold", default="perlayer",
                    choices=("perlayer", "shared", "pertoken"),
                    help="which v_ref fold to model: perlayer is C spec "
                         "2.1.4, shared is one fold per KV head across every "
                         "attention layer in the machine schedule order, "
                         "pertoken is mutation R7")
    ap.add_argument("--tok", type=int, default=None)
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()

    from bisect_scaled import read_capture
    recs = read_capture(a.capture)
    by = {(r.name, r.tok): r for r in recs}
    toks = sorted(set(r.tok for r in recs))
    shape = SP.Shape(a.blocks, a.attn_int, a.attn_hd)

    pred, blks, vtrace = predict(by, shape, toks, a.kv_block, a.n_rot,
                                a.qkn_exp, a.verbose, a.fold)
    print("# subsystem C's R_Y against ref/attn_block_cap_vec.c, driven from")
    print("# the machine's own captured R_QG / R_KIN / R_VIN.")
    print("# shape HEAD_DIM=%d N_QH=%d N_KVH=%d KV_BLOCK=%d N_ROT=%d "
          "attention blocks %s, %d token(s), v_ref fold '%s'"
          % (shape.attn_hd, shape.attn_q_heads, shape.attn_kv_heads,
             a.kv_block, a.n_rot, blks, len(toks), a.fold))
    for (li, t, vs) in vtrace:
        print("  v_ref after layer %d token %d: %s"
              % (li, t, " ".join(str(v) for v in vs)))
    rows = compare(by, pred)
    firstbad = None
    for (nm, t, msg, det) in rows:
        if msg == "ok":
            if a.verbose:
                print("  ok           %-12s tok %d" % (nm, t))
            continue
        extra = ""
        if det:
            extra = ", first at %d (expected %d, captured %d)" % det
        print("  %-12s tok %d  %s%s" % (nm, t, msg, extra))
        if firstbad is None:
            firstbad = (nm, t, det)
    if a.tok is not None:
        rows = [r for r in rows if r[1] == a.tok]
    nok = sum(1 for r in rows if r[2] == "ok")
    print("# %d of %d R_Y seams match the model bit for bit" % (nok, len(rows)))
    if firstbad is None:
        print("EVERY MODELLED R_Y MATCHES ITS MODEL BIT FOR BIT, given the "
              "machine's own inputs.")
        return 0
    nm, t, det = firstbad
    if det:
        print("FIRST DIVERGENCE: %s tok %d at element %d -- expected %d, "
              "captured %d" % (nm, t, det[0], det[1], det[2]))
    else:
        print("FIRST DIVERGENCE: %s tok %d" % (nm, t))
    return 1


if __name__ == "__main__":
    sys.exit(main())
