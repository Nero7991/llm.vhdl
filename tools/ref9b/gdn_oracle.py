#!/usr/bin/env python3
"""The integration-level model for subsystem B's `R_Y`.

WHAT THIS CLOSES.  `tools/ref9b/seamgate.sh` records the hole in its own floor
table and repeats it in every PASS line:

    Every unchecked seam is subsystem B's `R_Y`, which has no
    integration-level model.

`tools/ref9b/bisect_scaled.py`'s header gave the reason it was believed
unreachable -- "its input includes a recurrent state no region holds" -- and
`tools/ref9b/attn_oracle.py` repeated it.  That reason is about subsystem B's
PORT LIST and says nothing about what the top level feeds it; the top level's
own inputs are all captured or all deterministic, so `R_Y` has a model.  This
module computes it, with `ref/gdn_block_cap_vec.c` driving
`ref/gdn_block_vec.c`'s `gdn_block_token()`.

THE RECURRENCE NOW RUNS, AND THIS MODEL CARRIES IT.  When this file was
written, `rtl/llama_top.vhd` drove `b_tk0 <= '1'` at every token ("one token
only; there is no token loop yet") and pulsed `b_seq_rst` on every `go`, so
`rtl/gdn_recur_pipe.vhd`'s TK0_ED masked the state read on every token and
`gdn_exp_capture`'s `tvalid` marked only tap `KCONV-1` valid.  `R_Y` was then
a pure function of ONE token's inputs -- which is what made this model easy
and what made every defect downstream of the recurrent state invisible
(`mutate_seamgate.sh` S10 and S11, both survivors).

Defect candidate B-TOP-1 fixed both drivers on 2026-08-29:

  * `b_tk0` follows `tok_pos`, so it is high only at the first token of a
    sequence and the state carries.
  * `b_seq_rst` fires only at `tok_pos = 0`, which is what
    `rtl/gdn_exp_capture.vhd`'s own header says the port is for, so at token
    n the newest min(n+1, KCONV) conv taps are valid.

`ref/gdn_block_cap_vec.c` already allocated one state per layer and carried it
across tokens layer-major, so nothing there had to change; what changed here
is the `tk0`, `tvalid` and `e_t` this file WRITES into the stimulus.  See
`docs/debugging/2026-08-29_btop1-b-recurrence.md`.

WHAT `R_Y` ACTUALLY DEPENDS ON HERE, stated plainly because it bounds the
check.  `B_SRC_REAL` defaults FALSE and none of the three `seamgate.sh`
configurations sets it (`tools/ref9b/capture_llama_top.sh`'s `G` strings), so
of subsystem B's inputs only TWO come from the capture:

    R_Z            the output gate, mantissas and exponent.  Always real:
                   `rtl/llama_top.vhd:2745` -- "z, the output gate, IS READ
                   FROM REGION R_Z, which subsystem A produced".
    R_QKV.{q,k,v}  their EXPONENTS only, via `qkv_exp(seg)` (:4061), which the
                   adapter hands to `gdn_exp_capture` as `cap_exp` (:3102) and
                   which becomes the conv's `e_ref`.  The MANTISSAS are the
                   `m12` stand-in unless `B_SRC_REAL`.

The conv taps, the conv weights, `ssm_dt_bias`, `ssm_a`, alpha, beta and the
`ssm_norm` weight are `m12` stand-ins -- deterministic functions of an index.
They are transcribed BELOW, in Python, for the same reason `attn_oracle.py`
holds `qkn_const`: they are constants of the STIMULUS, not arithmetic, and
`ref/gdn_block_cap_vec.c` therefore contains no copy of any RTL constant.

That the stand-ins are constant does not make the check weak.  Every stage of
the composition still has to reproduce them exactly to land on the same `R_Y`,
which is what a wiring or rounding defect inside `gdn_block` breaks.  It does
mean the STIMULUS COVERAGE is narrow, and that is enumerated in
`docs/debugging/2026-08-29_ry-model-subsystem-b.md` rather than implied here.

usage:
  gdn_oracle.py capture.txt --blocks 4 --attn-int 4 [--kmap mod|div] [-v]
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

SEGS = 3
KCONV = 4                          # llama_map_pkg.vhd's scaled shape: conv_kernel => 4


# --------------------------------------------------------------------- m12
def m12(a, b):
    """`rtl/llama_top.vhd`'s `m12`, the unit-B stand-in generator.

    Transcribed rather than derived, and held HERE rather than in the C
    oracle, because it is a constant of the bench's stimulus -- the same
    standing as `attn_oracle.qkn_const`.  Every step is the VHDL's, in order:

        t := to_unsigned(a mod 1048576, 32) * to_unsigned(1103515245, 32);
        x := t(31 downto 0) + to_unsigned((b mod 100000) * 12345, 32);
        x := x xor shift_right(x, 15);
        t := x * to_unsigned(668265261, 32);
        x := t(31 downto 0);
        x := x xor shift_right(x, 13);
        return to_signed(to_integer(x(11 downto 0)) - 2048, 16);

    The 32-bit truncations are the load-bearing part: `x` is a 32-bit unsigned
    throughout, so both multiplies keep only the low half and the addition
    wraps.  A Python transcription without the masks agrees with the VHDL on
    small arguments and diverges silently on large ones.
    """
    t = (a % 1048576) * 1103515245
    x = ((t & 0xFFFFFFFF) + (((b % 100000) * 12345) & 0xFFFFFFFF)) & 0xFFFFFFFF
    x ^= x >> 15
    x = ((x * 668265261) & 0xFFFFFFFF)
    x ^= x >> 13
    return (x & 0xFFF) - 2048


# ------------------------------------------------------- the bench constants
def conv_weights(shape, lanes):
    """`rtl/llama_top.vhd:2985-2991`, the conv weight for (segment, channel, tap).

    The channel is split into (group, lane) exactly as the adapter's own
    address arithmetic splits it at :3003 -- `ch := sbase + cvq_grp*LANES + ln`
    -- so `lanes` is `B_CONV_LANES` and a wrong value here is a wrong weight,
    not a shape error.  It is a generic of `rtl/llama_top.vhd` and it is NOT in
    the capture; the same hazard `attn_oracle.py` documents for `--kv-block`.
    """
    out = []
    for s in range(SEGS):
        nch = seg_nch(shape, s)
        seg = []
        for c in range(nch):
            grp, ln = c // lanes, c % lanes
            seg.append([m12(s * 65537 + grp * 13, t * 101 + ln + 5)
                        for t in range(KCONV)])
        out.append(seg)
    return out


def conv_taps_synth(shape, lanes):
    """`rtl/llama_top.vhd:3016-3021`, the conv tap when `B_SRC_REAL` is false.

    Every tap of every channel, including the masked ones.  `gdn_conv` zeroes a
    tap `tvalid` excludes, so what is written into those slots cannot reach the
    products -- but writing the bench's own values rather than zero keeps this
    function a transcription of one process rather than a transcription plus a
    rule about which entries matter.
    """
    out = []
    for s in range(SEGS):
        nch = seg_nch(shape, s)
        seg = []
        for c in range(nch):
            grp, ln = c // lanes, c % lanes
            seg.append([m12(s * 104729 + grp * 31, t * 17 + ln)
                        for t in range(KCONV)])
        out.append(seg)
    return out


def scalars_synth(shape):
    """`rtl/llama_top.vhd:3059-3079`, the four per-head scalars.

    Order is `ref/gdn_block_vec.c`'s: al_m al_e dt_m dt_e a_m a_e b_m b_e.
    `ssm_a` is `-abs(...)` in the RTL and the comment there says why: the model
    has `ssm_a = -exp(A_log)`, so a positive one would exercise a case the
    model cannot produce.
    """
    out = []
    for h in range(shape.val_heads):
        out.append([m12(h * 31 + 1, 2), 12,
                    m12(h * 31 + 2, 3), 12,
                    -abs(m12(h * 31 + 3, 4)), 12,
                    m12(h * 31 + 4, 5), 12])
    return out


def ssm_norm_w(shape):
    """`rtl/llama_top.vhd:3086-3090`: w_mant(j) = m12(4242, j), w_exp = 12."""
    return [m12(4242, j) for j in range(shape.head_dim)]


def seg_nch(shape, s):
    return shape.val_dim if s == 2 else shape.key_dim


def gdn_layers(shape):
    """(block index, GDN layer ordinal) for every GDN block.

    The ordinal is `rtl/llama_top.vhd`'s `job_ordinal`, the index among GDN
    blocks and not the block index -- the field defect ORD-1 was about.  It is
    carried here because the per-layer state is indexed by it; at `tk0` it
    cannot change a value, but a driver that got it wrong would be wrong the
    first day there is a token loop.
    """
    out, n = [], 0
    for b in range(shape.blocks):
        if not shape.is_attn(b):
            out.append((b, n))
            n += 1
    return out


# ------------------------------------------------------------------ the run
def build_oracle(verbose=False):
    out = os.path.join(tempfile.mkdtemp(prefix="gdn_cap_"), "gdn_block_cap_vec")
    src = os.path.join(REPO, "ref", "gdn_block_cap_vec.c")
    r = subprocess.run(["gcc", "-O2", "-o", out, src, "-lm"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit("gdn_oracle: could not build the oracle\n" + r.stderr)
    if verbose:
        print("# built %s" % out)
    return out


def predict(recs_by_key, shape, toks, conv_lanes=4, b_src_real=False,
            kmap="mod", verbose=False, tk0="seq"):
    """Run the oracle over the capture.  Returns {(seam, tok): (exp, mant)}."""
    lays = gdn_layers(shape)
    if not lays:
        return {}, []
    NTOK = len(toks)
    if toks != list(range(NTOK)):
        raise SystemExit("gdn_oracle: the capture's token indices are %s; this "
                         "model assumes one contiguous sequence starting at 0."
                         % toks)

    KH, VH, D = shape.key_heads, shape.val_heads, shape.head_dim
    CHTOT = 2 * shape.key_dim + shape.val_dim
    if CHTOT != 2 * KH * D + VH * D:
        raise SystemExit("gdn_oracle: the shape's qkv width %d is not "
                         "2*KH*D + VH*D = %d" % (CHTOT, 2 * KH * D + VH * D))

    wt = conv_weights(shape, conv_lanes)
    xt = conv_taps_synth(shape, conv_lanes)
    sc = scalars_synth(shape)
    wm = ssm_norm_w(shape)

    def flat_chan(tbl):
        """[seg][ch][tap] -> the channel-major flat order `blk_t.xtap` wants."""
        out = []
        for s in range(SEGS):
            for c in range(len(tbl[s])):
                out.extend(tbl[s][c])
        return out

    wt_flat = flat_chan(wt)
    xt_flat = flat_chan(xt)

    d = tempfile.mkdtemp(prefix="gdn_cap_")
    stim, pred = os.path.join(d, "stim.txt"), os.path.join(d, "pred.txt")
    with open(stim, "w") as fp:
        fp.write("%d %d %d %d %d %d %d %d\n"
                 % (KH, VH, D, KCONV, len(lays), NTOK, 12,
                    1 if kmap == "div" else 0))
        # cw_exp: rtl/llama_top.vhd:3044 -- to_signed(12 + cv_seg, 8)
        fp.write(" ".join(str(12 + s) for s in range(SEGS)) + "\n")
        fp.write(" ".join(str(v) for v in wm) + "\n")
        for (b, _ord) in lays:
            for t in toks:
                need = ["R_QKV.q-%d" % b, "R_QKV.k-%d" % b,
                        "R_QKV.v-%d" % b, "R_Z-%d" % b]
                for nm in need:
                    if (nm, t) not in recs_by_key:
                        raise SystemExit(
                            "gdn_oracle: block %d token %d is missing %s in the "
                            "capture, so no prediction can be made for it."
                            % (b, t, nm))
                q = recs_by_key[("R_QKV.q-%d" % b, t)]
                k = recs_by_key[("R_QKV.k-%d" % b, t)]
                v = recs_by_key[("R_QKV.v-%d" % b, t)]
                z = recs_by_key[("R_Z-%d" % b, t)]
                for nm, r, want in (("R_QKV.q", q, shape.key_dim),
                                    ("R_QKV.k", k, shape.key_dim),
                                    ("R_QKV.v", v, shape.val_dim),
                                    ("R_Z", z, shape.val_dim)):
                    if len(r.v) != want:
                        raise SystemExit(
                            "gdn_oracle: %s-%d tok %d has %d values, the shape "
                            "says %d.  The shape flags are wrong, or the plan "
                            "has drifted; either way a comparison here would be "
                            "a misalignment reported as a defect."
                            % (nm, b, t, len(r.v), want))

                # tk0.  THE DEFAULT MODELS THE RTL, NOT THE SPEC, AND THAT
                # IS A CHOICE THAT HAS TO BE NAMED.
                #
                #   'seq' (default)  tk0 = 1 only at token 0, so the recurrent
                #                    state carries -- and the conv tap
                #                    validity grows with the sequence position
                #                    (see e_t below).  This is what
                #                    `rtl/llama_top.vhd` drives TODAY, and it
                #                    is also B spec 2.1.4's recurrence; since
                #                    defect B-TOP-1 was fixed the two agree.
                #   'pre-btop1'      tk0 = 1 at EVERY token and only tap
                #                    KCONV-1 ever valid, which is what
                #                    `rtl/llama_top.vhd` drove BEFORE
                #                    2026-08-29.  It models a design that no
                #                    longer exists and is kept for one reason:
                #                    so a report can quantify what the defect
                #                    cost instead of only asserting it moved.
                #
                # THE OLD SPELLING 'top' IS DELIBERATELY NOT ACCEPTED.  It
                # meant "what the top level does", and after B-TOP-1 that is
                # 'seq'; a caller passing 'top' from a stale document or
                # script would otherwise silently model the pre-fix machine
                # against the fixed one and read the difference as a defect.
                # argparse rejects it by name, which is the loud failure.
                #
                # This is the same shape as `attn_oracle.py`'s `--fold`, and it
                # exists for the same reason: a model that only implemented the
                # spec could say the RTL disagrees with it and could not say
                # what the RTL does instead.
                pre = (tk0 == "pre-btop1")
                fp.write("%d %d\n" % (1 if (pre or t == 0) else 0, z.exp))

                # e_t and tvalid: `rtl/gdn_exp_capture.vhd` as a SHIFT, one
                # capture per (layer, segment) per token, counters cleared once
                # per SEQUENCE by `b_seq_rst`.
                #
                #   tap kk holds the exponent captured `age = KCONV-1-kk`
                #   tokens ago, so it is valid iff `t - age >= 0`.
                #
                # DERIVED from that file's header ("new_word = cap_exp &
                # old_word(K*8-1 downto 8)", "after `n` captures the valid taps
                # are the newest `n`") and from `rtl/llama_top.vhd`'s S_CAPW /
                # S_CAPR loop, which captures all three segments before every
                # `b_start`.  At token 0 exactly one tap is valid, which is the
                # `tk = 0` case B spec 2.1.4's test list calls for.
                #
                # The masked slots are given a wild exponent for the reason
                # ref/gdn_block_vec.c states: if a failure to mask ever let one
                # into the e_ref minimum, the segment would move 40 octaves and
                # say so, rather than drifting by one bit.
                et, tv = [], []
                for seg_nm in ("R_QKV.q", "R_QKV.k", "R_QKV.v"):
                    for kk in range(KCONV):
                        age = KCONV - 1 - kk
                        src = t - age
                        if src < 0 or (pre and age > 0):
                            et.append(-47)
                            tv.append(0)
                            continue
                        key = ("%s-%d" % (seg_nm, b), src)
                        if key not in recs_by_key:
                            raise SystemExit(
                                "gdn_oracle: block %d token %d needs %s from "
                                "token %d for conv tap %d, and the capture has "
                                "no such record.  The tap history is real now; "
                                "a model that substituted the CURRENT token's "
                                "exponent there would be a plausible wrong "
                                "answer." % (b, t, seg_nm, src, kk))
                        et.append(recs_by_key[key].exp)
                        tv.append(1)
                fp.write(" ".join(str(x) for x in et) + "\n")
                fp.write(" ".join(str(x) for x in tv) + "\n")

                if b_src_real:
                    # THE SAME REFUSAL `rtl/llama_top.vhd`'s S_GO MAKES, and it
                    # has to be here too or this model would quietly agree with
                    # a machine that cannot run.  `cvdata_p` writes ZERO into
                    # every tap but the newest, which was inert while `tvalid`
                    # masked those slots; from token 1 it no longer does, and a
                    # zero mantissa at a real captured exponent is a plausible
                    # wrong answer on both sides at once.
                    # THE CONV TAP HISTORY, 2026-09-05.  This used to REFUSE at
                    # t > 0, because `rtl/llama_top.vhd`'s `cvdata_p` wrote
                    # ZERO into every tap but the newest and a zero mantissa at
                    # a real captured exponent is a plausible wrong answer on
                    # both sides at once.  `llama_top` now sources those slots
                    # from `gdn_state_store` under B_STATE_AXI, so the refusal
                    # would model a machine that no longer exists.
                    #
                    # DERIVED FROM THE DEFINITION OF A CAUSAL CONVOLUTION, NOT
                    # FROM THE RTL, and that distinction is the whole value of
                    # this file.  A kernel of width KCONV at token `t` sees
                    # columns `t-(KCONV-1) .. t`, so tap `j` holds the qkv
                    # column of token `t - (KCONV-1-j)`; tap KCONV-1 is the
                    # current token, which is exactly what the previous code
                    # wrote as its only non-zero entry.  Columns before the
                    # start of the sequence do not exist and stay zero --
                    # `gdn_exp_capture`'s `tvalid` excludes them at token n for
                    # all but the newest min(n+1, KCONV) taps, as this file's
                    # header already states.
                    #
                    # The model reaches for them by CAPTURE KEY, `R_QKV.*` at
                    # an earlier token, so it never consults the store, the
                    # rotation, or anything else the implementation does.  If
                    # the RTL's stored taps and this arithmetic agree, that is
                    # two independent routes to the same number.
                    real = [0] * (CHTOT * KCONV)
                    for j in range(KCONV):
                        src_t = t - (KCONV - 1 - j)
                        if src_t < 0:
                            continue          # before the sequence: no column
                        if src_t == t:
                            col = list(q.v) + list(k.v) + list(v.v)
                        else:
                            hq = recs_by_key.get(("R_QKV.q-%d" % b, src_t))
                            hk = recs_by_key.get(("R_QKV.k-%d" % b, src_t))
                            hv = recs_by_key.get(("R_QKV.v-%d" % b, src_t))
                            if hq is None or hk is None or hv is None:
                                raise SystemExit(
                                    "gdn_oracle: --b-src-real at token %d needs "
                                    "the R_QKV columns of token %d for conv tap "
                                    "%d, and the capture has no such record.  "
                                    "Capture the whole sequence, or the history "
                                    "cannot be modelled." % (t, src_t, j))
                            col = list(hq.v) + list(hk.v) + list(hv.v)
                        for c in range(CHTOT):
                            real[c * KCONV + j] = col[c]
                    fp.write(" ".join(str(x) for x in real) + "\n")
                else:
                    fp.write(" ".join(str(x) for x in xt_flat) + "\n")
                fp.write(" ".join(str(x) for x in wt_flat) + "\n")

                if b_src_real:
                    for nm in ("R_ALPHA-%d" % b, "R_BETA-%d" % b):
                        if (nm, t) not in recs_by_key:
                            raise SystemExit("gdn_oracle: --b-src-real needs %s "
                                             "and the capture has no such "
                                             "record" % nm)
                    al = recs_by_key[("R_ALPHA-%d" % b, t)]
                    be = recs_by_key[("R_BETA-%d" % b, t)]
                    row = []
                    for h in range(VH):
                        row += [al.v[h], al.exp, sc[h][2], sc[h][3],
                                sc[h][4], sc[h][5], be.v[h], be.exp]
                    fp.write(" ".join(str(x) for x in row) + "\n")
                else:
                    fp.write(" ".join(str(x) for h in range(VH)
                                      for x in sc[h]) + "\n")
                fp.write(" ".join(str(x) for x in z.v) + "\n")

    exe = build_oracle(verbose)
    r = subprocess.run([exe, stim, pred, kmap], capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit("gdn_oracle: the oracle refused the stimulus\n"
                         + r.stdout + r.stderr)

    out, flags = {}, []
    # A prediction spans several lines (the C writer wraps at 16 values), so
    # the parser accumulates until the header's declared count is reached and
    # REFUSES a short one.  A silently short record would be compared against
    # a longer capture and reported as a LENGTH mismatch at an innocent seam.
    with open(pred) as fp:
        cur, acc = None, []
        for line in fp:
            if line.startswith("#"):
                continue
            f = line.split()
            if not f:
                continue
            if f[0] == "Y":
                if cur is not None:
                    raise SystemExit("gdn_oracle: prediction for layer %d token "
                                     "%d ended after %d of %d values"
                                     % (cur[0], cur[1], len(acc), cur[3]))
                cur, acc = tuple(int(x) for x in f[1:9]), []
                continue
            if cur is None:
                raise SystemExit("gdn_oracle: values before any Y header")
            acc.extend(int(x) for x in f)
            li, t, ye, n, ec, eg, es, ys = cur
            if len(acc) < n:
                continue
            if len(acc) != n:
                raise SystemExit("gdn_oracle: prediction for layer %d token %d "
                                 "has %d values, header says %d"
                                 % (li, t, len(acc), n))
            b = lays[li][0]
            out[("R_Y-%d" % b, t)] = (ye, acc)
            if ec or eg or es or ys:
                flags.append(("R_Y-%d" % b, t, ec, eg, es, ys))
            cur, acc = None, []
        if cur is not None:
            raise SystemExit("gdn_oracle: the prediction file ends mid-record "
                             "(layer %d token %d, %d of %d values)"
                             % (cur[0], cur[1], len(acc), cur[3]))
    want = len(lays) * NTOK
    if len(out) != want:
        raise SystemExit("gdn_oracle: the oracle produced %d predictions and "
                         "the stimulus asked for %d" % (len(out), want))
    return out, flags


def compare(recs_by_key, pred):
    """Bit-for-bit, in the shape `bisect_scaled.py`'s reports already use."""
    rows = []
    for (nm, t), (ye, v) in sorted(pred.items(),
                                   key=lambda kv: (kv[0][1], kv[0][0])):
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
                         "exp %d expected vs %d captured, %d of %d mantissas "
                         "differ" % (ye, r.exp, len(bad), len(v)),
                         None if first is None
                         else (first, v[first], r.v[first])))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("--blocks", type=int, default=4)
    ap.add_argument("--attn-int", type=int, default=4)
    # ACCEPTED AND IGNORED, so that the exact argument string
    # `LIST_BISECT=1 capture_llama_top.sh <cfg>` emits can be passed to this
    # tool unchanged.  A caller that had to strip the C-side and norm-side
    # flags by hand would be a second, hand-maintained copy of that string --
    # which is precisely the drift `capture_llama_top.sh`'s own header calls
    # "one fact written twice".  They are grouped and named so that a reader
    # can see they are inert here rather than silently applied.
    for _dead in ("--norm", "--norm-exp", "--norm-w-exp", "--norm-q",
                  "--w-image", "--kv-block", "--n-rot", "--qkn-exp",
                  "--attn-fold"):
        ap.add_argument(_dead, default=None,
                        help="accepted and IGNORED: subsystem B does not read "
                             "it.  Present so the capture's own bisect "
                             "argument string can be passed through unchanged")
    ap.add_argument("--attn-hd", type=int, default=16,
                    help="not used by subsystem B's arithmetic; it still "
                         "selects the SHAPE, and SP.Shape needs it")
    # NOT RECORDED IN THE CAPTURE, AND GUESSING THEM IS A TRAP -- the same
    # hazard attn_oracle.py documents for --kv-block.  A wrong --conv-lanes is
    # a legal shape and a small wrong answer, because it only changes how a
    # channel index splits into (group, lane) inside m12.
    ap.add_argument("--conv-lanes", type=int, default=4,
                    help="rtl/llama_top.vhd's B_CONV_LANES.  NOT in the "
                         "capture; a wrong legal value is a wrong weight, not "
                         "an error")
    ap.add_argument("--b-src-real", action="store_true",
                    help="rtl/llama_top.vhd's B_SRC_REAL.  Defaults FALSE "
                         "because that is what all three seamgate.sh "
                         "configurations elaborate")
    ap.add_argument("--kmap", default="mod", choices=("mod", "div"),
                    help="which key head feeds value head h.  'mod' is the "
                         "model (ggml_repeat tiles); 'div' is the contiguous "
                         "GQA grouping that was defect B-BLK-1")
    ap.add_argument("--tk0", default="seq", choices=("seq", "pre-btop1"),
                    help="'seq' (the default) is tk0 = 1 only at token 0 with "
                         "the conv tap validity growing with the sequence "
                         "position -- what rtl/llama_top.vhd drives today and "
                         "also B spec 2.1.4's recurrence.  'pre-btop1' is tk0 "
                         "= 1 at EVERY token and only tap KCONV-1 ever valid, "
                         "which is what that file drove before defect B-TOP-1 "
                         "was fixed on 2026-08-29; it models a design that no "
                         "longer exists and is kept so a report can quantify "
                         "the defect.  The old spelling 'top' is REJECTED on "
                         "purpose: it meant 'what the machine does', which is "
                         "now 'seq', so accepting it would silently compare "
                         "the fixed machine against the broken model")
    ap.add_argument("--tok", type=int, default=None)
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()

    from bisect_scaled import read_capture
    recs = read_capture(a.capture)
    by = {(r.name, r.tok): r for r in recs}
    toks = sorted(set(r.tok for r in recs))
    shape = SP.Shape(a.blocks, a.attn_int, a.attn_hd)

    pred, flags = predict(by, shape, toks, a.conv_lanes, a.b_src_real,
                          a.kmap, a.verbose, a.tk0)
    print("# subsystem B's R_Y against ref/gdn_block_cap_vec.c, driven from the")
    print("# machine's own captured R_Z and R_QKV exponents.")
    print("# shape KH=%d VH=%d D=%d KCONV=%d, GDN blocks %s, %d token(s), "
          "kmap '%s', conv lanes %d, B_SRC_REAL %s, tk0 '%s'"
          % (shape.key_heads, shape.val_heads, shape.head_dim, KCONV,
             [b for (b, _o) in gdn_layers(shape)], len(toks), a.kmap,
             a.conv_lanes, a.b_src_real, a.tk0))
    for (nm, t, ec, eg, es, ys) in flags:
        print("  MODEL FLAG %-10s tok %d  err_conv=%d err_g=%d err_se=%d "
              "y_sat=%d" % (nm, t, ec, eg, es, ys))
    rows = compare(by, pred)
    if a.tok is not None:
        rows = [r for r in rows if r[1] == a.tok]
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
