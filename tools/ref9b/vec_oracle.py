#!/usr/bin/env python3
"""Independent numeric models of the four things `rtl/llama_top.vhd` computes
in subsystem D, so a captured seam can be checked against something that is not
the machine that produced it.

WHAT EACH MODEL IS WORTH.  This differs per op and pretending otherwise would
be the whole failure this file exists to avoid.

  res       `rtl/seq_vec_res.vhd` is REAL RTL and is already claimed bit-exact
            against `ref/seq_vec_res_vec.c`, which carries six oracles and
            shares no arithmetic with it.  `recipe()` below is transcribed from
            that C file, not from the VHDL.  A disagreement here is a real
            defect in the residual.

  swg       there is NO swiglu hardware in this path in ANY configuration.
            `rtl/llama_top.vhd:903` prints "swiglu is behavioural in every
            configuration" at time zero, and `rtl/swiglu.vhd` is not
            instantiated.  So this model checks the top level's SEQUENCING,
            ADDRESSING and EXPONENT BOOKKEEPING for that op and says nothing
            whatever about SwiGLU.  It is still worth having: the exponent rule
            `e(G) + e(U) - MANT_W` is the one that was FABRICATED until
            2026-08-28 and silently masked half the FFN excursion.

  norm      three different things behind one opcode.  `NORM_REAL` is the real
            `rtl/rmsnorm_rs.vhd`; `NORM_ANCHOR` is a probe on a behavioural
            mean-removal model; the bare default is that model.  The capture
            does not record which, so the caller must pass it.

THE rmsnorm_rs MODEL IS THE ONLY ONE HERE THAT IS NEW EVIDENCE, AND IT IS ALSO
THE WEAKEST KIND.  It is a second integer path over the same recipe, and a
second integer path agrees with a wrong recipe -- which is exactly how the
l2norm collapse of 2026-08-25 survived 55 passing cases.  Two things mitigate
it and neither removes it:

  1. Everything from the reciprocal-square-root seed onward is LIFTED FROM
     `ref/rmsnorm_bf_vec.c`, which was written for a different unit against a
     double-precision oracle of its own.  Only `S_INV` and the `rq_d = rq_p - Q`
     fold are transcribed from `rtl/rmsnorm_rs.vhd`, because those are the two
     places the two units genuinely differ.
  2. `norm_rs()` also returns the DOUBLE-PRECISION value computed from the
     definition alone -- `x/sqrt(mean(x^2)) * w` -- so a recipe that is
     internally consistent and numerically absurd is visible.  That number is
     REPORTED, never gated on: the fixed-point unit has a documented 244x
     epsilon floor (docs/debugging/2026-08-26_rmsnorm-magnitude-window.md) and
     gating on the ideal would flag the design's known behaviour as a defect.

MEASURED, and it bounds what a green run from this file means: there is no
existing bit-exact independent oracle for `rmsnorm_rs` at `llama_top`'s
generics.  `sim/tb_rmsnorm_rs.vhd` compares it against `rtl/rmsnorm.vhd` at
N=128 only, and `rtl/rmsnorm.vhd` is itself checked against `ref/run_fx.c` only
to +-2 int16 LSB on one N=64 vector (`tb/tb_rmsnorm.vhd:128`).  So this file is
the first thing to compare that unit against non-VHDL at N=64.
"""

# ---------------------------------------------------------------- primitives
# numeric_std, exactly.  Transcribed from ref/rmsnorm_bf_vec.c:108-151, which
# names the VHDL construct each one stands for.

def vsrl_a(v, sh):
    """shift_right(signed, natural): arithmetic, floor, saturating at the width."""
    if sh <= 0:
        return v
    if sh >= 64:
        return -1 if v < 0 else 0
    return v >> sh                       # Python >> on int is already floor


def vsll64(v, sh):
    """shift_left(signed(63 downto 0), natural): HIGH BITS ARE DROPPED.

    The RTL relies on the drop: the rounding bias 1 << (-rq_E - 1) runs off the
    end of the word for a deeply negative rq_E and must become 0.
    """
    if sh <= 0:
        return v
    if sh >= 64:
        return 0
    return _s64((v << sh) & ((1 << 64) - 1))


def _s64(u):
    u &= (1 << 64) - 1
    return u - (1 << 64) if u >> 63 else u


def vresize(v, w):
    """resize(signed, w) when w SHRINKS: the SIGN BIT plus the low w-1 bits.

    Not a mask and not a saturation.  Every narrowing site in the RTL is
    bounded by an assert, so in a passing run this is the identity -- and
    modelling it as the identity would hide exactly the case where an assert is
    wrong.
    """
    if w >= 64:
        return v
    low = v & ((1 << (w - 1)) - 1)
    return low - (1 << (w - 1)) if v < 0 else low


def vmsb63(v):
    """The RTL's scan over bits 0..62, LAST set bit.  msb(0) = 0 is NORMATIVE."""
    p = 0
    for i in range(63):
        if (v >> i) & 1:
            p = i
    return p


def trunc_div(a, b):
    """VHDL `/` on integers: TRUNCATE TOWARD ZERO.  Python `//` floors.

    Getting this backwards is off by one on every negative element and reads
    exactly like a real defect.  The behavioural norm and swiglu models use it;
    the residual and rmsnorm_rs use arithmetic shifts, which floor.
    """
    q = abs(a) // abs(b)
    return -q if (a < 0) != (b < 0) else q


def sat16(v):
    return 32767 if v > 32767 else (-32768 if v < -32768 else v)


# ------------------------------------------------------------------- OP_VEC_RES
MANT_W, ACC_W = 16, 32
SHMAX = ACC_W - MANT_W - 1      # 15
KEEP = MANT_W - 2               # 14


def res(x, e, ex, ee):
    """`ref/seq_vec_res_vec.c:recipe()`.  REAL RTL on the other side.

    Returns (out, oexp, sh, sat).  `n = 0` is an ERROR in the RTL, not a no-op.
    """
    n = len(x)
    assert n == len(e) and n > 0
    qmax, qmin = max(ex, ee), min(ex, ee)
    q = (qmin + SHMAX) if (qmax - qmin > SHMAX) else qmax
    sx, se = q - ex, q - ee

    def rhu(v, sh):                       # round half toward +infinity
        if sh <= 0:
            return v
        return (v + (1 << (sh - 1))) >> sh

    acc, orv = [], 0
    for i in range(n):
        a = (x[i] << sx) if sx >= 0 else rhu(x[i], -sx)
        b = (e[i] << se) if se >= 0 else rhu(e[i], -se)
        s = a + b
        if s > 2147483647 or s < -2147483648:
            raise SystemExit("seq_vec_res oracle: accumulator overflowed %d -- "
                             "the SHMAX clamp is wrong" % s)
        acc.append(s)
        orv |= abs(s)
    p = vmsb63(orv)
    sh = max(p - KEEP, 0)
    oexp = q - sh
    out, sat = [], 0
    for a in acc:
        r = rhu(a, sh)
        if r > 32767:
            r, sat = 32767, 1
        elif r < -32768:
            r, sat = -32768, 1
        out.append(r)
    return out, oexp, sh, sat


# ------------------------------------------------------------------- OP_VEC_SWG
def swg(g, u, eg, eu):
    """The BEHAVIOURAL stand-in at `rtl/llama_top.vhd`'s S_WR/S_DONE.

    out[i] = sat_m((g[i]*u[i]) / 2**MANT_W)   -- VHDL `/`, truncating
    oexp   = e(G) + e(U) - MANT_W

    NO silu, NO sigmoid, NO table.  This is not SwiGLU and the model does not
    pretend it is; what it checks is that the top level read the two source
    regions in the right order, wrote n elements, and published the PRODUCT
    exponent rather than the fabricated `e(G) + op_index` it published before
    2026-08-28.
    """
    assert len(g) == len(u)
    out = [sat16(trunc_div(a * b, 1 << MANT_W)) for a, b in zip(g, u)]
    return out, eg + eu - MANT_W


# ------------------------------------------------------------------ OP_VEC_NORM
def norm_mean(x, ex):
    """The bare behavioural model: out[i] = x[i] - sum(x)/n, exponent unchanged."""
    n = len(x)
    acc = sum(x)
    m = trunc_div(acc, n)
    return [sat16(v - m) for v in x], ex


def norm_anchor(x, ex, norm_exp):
    """`NORM_ANCHOR`: the same mean removal, renormalised to a FIXED exponent.

    A PROBE, not a model of anything the hardware contains.  It gives the
    behavioural norm rmsnorm's one scale property and nothing else.
    """
    n = len(x)
    m = trunc_div(sum(x), n)
    d = [v - m for v in x]
    mx = max((abs(v) for v in d), default=0)
    pmsb = -1
    for i in range(31):
        if mx >= (1 << i):
            pmsb = i
    nsh = 0 if pmsb < 0 else pmsb - (MANT_W - 2)
    out = []
    for v in d:
        if nsh > 0:
            v = trunc_div(v, 1 << nsh)
        elif nsh < 0:
            v = v * (1 << (-nsh))
        out.append(sat16(v))
    return out, norm_exp


# rtl/fixed_luts_pkg.vhd's RSQRT_ROM, via ref/rmsnorm_bf_vec.c:82-91, where it
# is already transcribed for a unit that shares this seed.  ROM[k] =
# round((1/sqrt(1 + k/64)) * 2^30).
RSQRT_ROM = [
    1073741824, 1065450257, 1057347856, 1049427536, 1041682578, 1034106604, 1026693558, 1019437682,
    1012333500, 1005375799,  998559613,  991880210,  985333074,  978913898,  972618566,  966443148,
     960383883,  954437177,  948599586,  942867814,  937238702,  931709222,  926276469,  920937655,
     915690104,  910531246,  905458609,  900469818,  895562589,  890734723,  885984104,  881308694,
     876706528,  872175715,  867714429,  863320910,  858993459,  854730438,  850530263,  846391405,
     842312387,  838291779,  834328203,  830420321,  826566842,  822766514,  819018128,  815320510,
     811672525,  808073073,  804521086,  801015531,  797555404,  794139734,  790767575,  787438013,
     784150157,  780903145,  777696137,  774528319,  771398898,  768307107,  765252196,  762233438]
INV_SQRT2_C = 759250125
THREE_Q30 = 3 << 30


def norm_w_const(n, norm_w_exp=12):
    """`rtl/llama_top.vhd:1489-1500`'s `W_CONST`.  A SYNTHETIC RAMP, not a model
    weight.  Every `R_XN` seam the design produces today is normalised by this,
    which is why finding D2 of the 9B reference says those seams cannot be
    compared against the model at all."""
    return [(1 << norm_w_exp) + ((i * 37) % 512) - 256 for i in range(n)]


def norm_rs(xm, xe, wm, we, Q=12):
    """`rtl/rmsnorm_rs.vhd`, bit-exact, at `rtl/llama_top.vhd`'s generics.

    LANES has NO numeric content (rmsnorm_rs.vhd:39-44: the sum of squares is
    an exact integer sum and max|raw| is a maximum, both order-independent), so
    it is not a parameter here.  N must be a power of two, which the unit
    asserts.

    Returns (o, o_exp, diag) where diag carries inv32, max_raw, shift_total,
    saturations and the DOUBLE-PRECISION ideal for reporting.
    """
    import math
    N = len(xm)
    assert len(wm) == N
    LOG2N = N.bit_length() - 1
    assert (1 << LOG2N) == N, "rmsnorm_rs asserts N is a power of two"

    # ---- S_ACC
    S = sum(v * v for v in xm)
    if not (0 <= S < (1 << 46)):
        raise SystemExit("rmsnorm_rs oracle: sum of squares %d is outside the "
                         "range the RTL asserts" % S)

    # ---- S_INV1..S_INV6.  THIS IS WHERE rmsnorm_rs AND rmsnorm_bf DIFFER:
    # a fixed 2^-Q grid with a `msq < 1` floor, not a block exponent plus an
    # explicit epsilon.  The floor is a 2^-12 epsilon against the model's 1e-6
    # and it is the documented magnitude-window defect; it is modelled, not
    # corrected.
    num = _s64(S << Q)
    if xe >= 0:
        up, sh = False, min(2 * xe, 62)
    else:
        up, sh = True, min(-(2 * xe), 62)
    msq = vsrl_a(num + (N // 2), LOG2N)
    bias = 0 if (up or sh == 0) else (1 << (sh - 1))
    shifted = vsll64(msq, sh) if up else vsrl_a(msq + bias, sh)
    msq = 1 if shifted < 1 else shifted

    # ---- S_SEED1 / S_SEED2
    rq_p = vmsb63(msq)
    A = msq & ((1 << 64) - 1)
    mant = ((A << (30 - rq_p)) & ((1 << 64) - 1)) if rq_p <= 30 else (A >> (rq_p - 30))
    assert (mant >> 30) & 1, "rsqrt mantissa not normalised to Q30"
    rq_smant = mant & 0xFFFFFFFF
    rq_y = RSQRT_ROM[(mant >> 24) & 0x3F]

    # ---- S_RQ: two Newton iterations.  Lifted from ref/rmsnorm_bf_vec.c:280.
    for _ in range(2):
        y2 = vresize(vsrl_a(vresize(rq_y * rq_y, 66), 30), 32)
        my2 = vresize(rq_smant * y2, 66)
        diff = vresize(THREE_Q30 - vresize(vsrl_a(my2, 30), 34), 34)
        prod = vresize(diff * rq_y, 66)
        rq_y = vresize(vsrl_a(prod, 31), 32)

    # ---- S_RQ_FOLD.  rq_d = rq_p - Q for rmsnorm_rs (rmsnorm_bf uses e_out;
    # sim/mutate_rmsnorm_bf.sh:273 names the difference).  VHDL `/` truncates.
    rq_d = rq_p - Q
    if rq_d % 2 != 0:
        rq_yfin = vresize(vsrl_a(rq_y * INV_SQRT2_C, 30), 32)
        rq_he = trunc_div(rq_d - 1, 2)
    else:
        rq_yfin = rq_y
        rq_he = trunc_div(rq_d, 2)
    rq_E = Q - 30 - rq_he

    # ---- S_RQ_FIN1/2/3 and S_RQ_CLAMP
    rq_bias = 0 if rq_E >= 0 else vsll64(1, -rq_E - 1)
    rq_sum = rq_yfin + rq_bias
    if rq_E > 32:
        rq_shifted = 2147483647
    elif rq_E >= 0:
        rq_shifted = vsll64(rq_yfin, rq_E)
    else:
        rq_shifted = vsrl_a(rq_sum, -rq_E)
    inv32 = min(max(rq_shifted, 0), 2147483647)

    # ---- S_RAW
    raw, max_raw = [], 0
    for j in range(N):
        xi = vresize(xm[j] * inv32, 48)
        r = vresize(xi * wm[j], 64)
        raw.append(r)
        if abs(r) > max_raw:
            max_raw = abs(r)

    # ---- S_SHIFT1 / S_SHIFT2
    msb_p = vmsb63(max_raw)
    st = max(msb_p - 14, 0)
    o_exp = xe + we + Q - st
    emit_bias = 0 if st == 0 else vsll64(1, st - 1)

    # ---- S_EMIT
    o, nsat = [], 0
    for j in range(N):
        om = vsrl_a(raw[j] + emit_bias, st)
        if om > 32767:
            om, nsat = 32767, nsat + 1
        elif om < -32768:
            om, nsat = -32768, nsat + 1
        o.append(om)

    # The DOUBLE-PRECISION ideal, from the definition and from nothing in the
    # recipe above.  Reported, never gated on -- see the module docstring.
    xr = [v * 2.0 ** -xe for v in xm]
    wr = [v * 2.0 ** -we for v in wm]
    ms = sum(v * v for v in xr) / N
    ideal = [(xr[j] / math.sqrt(ms) * wr[j]) if ms > 0 else 0.0 for j in range(N)]
    got = [o[j] * 2.0 ** -o_exp for j in range(N)]
    num_e = math.sqrt(sum((got[j] - ideal[j]) ** 2 for j in range(N)))
    den_e = math.sqrt(sum(v * v for v in ideal))
    diag = dict(inv32=inv32, max_raw=max_raw, shift_total=st, saturations=nsat,
                msq=msq, rel_rms_vs_ideal=(num_e / den_e) if den_e > 0 else 0.0)
    return o, o_exp, diag


if __name__ == "__main__":
    # A smoke check with numbers, not a test suite.  The real check is
    # tools/ref9b/bisect_scaled.py against a capture.
    import random
    random.seed(7)
    x = [random.randint(-3000, 3000) for _ in range(64)]
    w = norm_w_const(64)
    o, oe, d = norm_rs(x, 3, w, 12)
    print("norm_rs  o_exp=%d st=%d inv32=%d sat=%d rel_rms_vs_ideal=%.4g"
          % (oe, d["shift_total"], d["inv32"], d["saturations"],
             d["rel_rms_vs_ideal"]))
    e = [random.randint(-3000, 3000) for _ in range(64)]
    out, oexp, sh, sat = res(x, e, 3, 5)
    print("res      oexp=%d sh=%d sat=%d out[0]=%d" % (oexp, sh, sat, out[0]))
    g = [random.randint(-30000, 30000) for _ in range(128)]
    u = [random.randint(-30000, 30000) for _ in range(128)]
    so, se = swg(g, u, 7, 9)
    print("swg      oexp=%d out[0]=%d" % (se, so[0]))
