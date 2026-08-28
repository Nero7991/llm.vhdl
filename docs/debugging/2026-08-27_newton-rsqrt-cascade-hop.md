# The Newton rsqrt path: the MREG was already there, the DSP-to-DSP hop was not

**Date:** 2026-08-27
**Build:** `llama.vhdl` branch `fpga`, on top of `aaac5d3`. Changed:
`rtl/l2norm_rs.vhd`, `rtl/rmsnorm_rs.vhd`.
**Tools:** GHDL 1.0.0 mcode, `ghdl -r` direct, `--stop-time` on every run.
**Vivado was NOT run.** The 0.717 V numbers quoted are the coordinator's
synthesis sweep. No Fmax claim is made here.

---

## The question

Verbatim, from the coordinator, 2026-08-27:

> At 0.717 V, `l2norm_rs`, `rmsnorm_rs`, `micro_rmsn_lanes` and
> `gdn_emit_chain` are ALL bound by the SAME path: a DSP48E2-internal multiply
> in the Q30 Newton rsqrt, `ARG__N/DSP_A_B_DATA_INST`, measured at 4.35 to
> 4.69 ns and 84 to 88% logic. [...] C spec 3.13 item 1 already names `MREG` on
> the 34x32 Newton stage as the fix. **Until it lands, no norm unit closes
> 237.8 MHz at any lane count.**
>
> **TASK 1 [...] apply the MREG/PREG treatment to the Newton rsqrt multiply in
> `rtl/l2norm_rs.vhd` and `rtl/rmsnorm_rs.vhd`.**
>
> **TASK 2 [...] tell me what it costs in the place I cannot see from a
> synthesis number: the per-head deadline. [...] Measure it at 8 and report the
> new boundary and margin.**

---

## The answer

### Task 1: the MREG and the PREG were already there. What is missing is a third level.

`mr_m` (MREG) and `mr_p` (PREG) have been in both files since they were
written, and the three-step Newton cadence exists precisely to buy them. Both
files say so in their own headers. `rmsnorm_rs:333-346` goes further and names
the residual outright:

> its 34x32 form **spans two DSPs with nothing between them**

That is the real defect, and it is not a missing MREG. A DSP48E2 multiplier is
27x18; a 34x32 multiply spans two of them. Registering the operands, which the
three-step cadence already did, fixed the logic in FRONT of the first DSP and
left the hop BETWEEN the two unregistered. A path that starts at
`DSP_A_B_DATA_INST` and is 84 to 88% logic is made of that hop.

**Fix: `mr_m2`, a third register level, so the tool has somewhere to put a
register in that span.** `mr_m` -> `mr_m2` -> `mr_p`, and the Newton cadence
goes from three steps per multiply to four, consuming at N+3 instead of N+2.

**Narrowing is not an alternative here** and was checked: both operands are Q30
quantities of 31 to 34 bits, neither can be cut to the 27x18 a single DSP
takes, so the two-DSP span is structural. This is the half of the `rmsnorm_bf`
fold fix that does not transfer -- and `l2norm_rs:306-309` already multiplies at
32x32 and says why, as the brief noted. `rmsnorm_rs` has no 64x32 waste either;
its Newton operands are already 32 and 34 bits.

**Cost: +6 cycles per rsqrt, and `l2norm_rs` pays it TWICE.** Measured:

| unit | before | after | delta |
|---|---|---|---|
| `rmsnorm_rs` N=256 | 142 cycles | 148 | **+6** |
| `l2norm_rs` N=128 | 121 cycles | 133 | **+12** |

`l2norm_rs` is +12 rather than +6 because `S_NEXT` returns to `S_ARG` for a
**second rsqrt on the q path** -- the k path and the q path each run the full
Newton. That is not obvious from the state list and it doubles the cost of any
change inside `S_RQ`.

### Task 2: halving SILU_LANES costs 6 cycles of deadline, and it still clears

Measured by the same bisection, `DIM=128 RMS_LANES=4 RECUR_LANES=64`:

| `SILU_LANES` | deadline | margin at `RECUR_LANES=32` (arrival 512) |
|---|---|---|
| 16 | 369 dropped / 370 passing | +142 cycles, 27.7% |
| 8 | 374 dropped / **375 passing** | **+137 cycles, 26.8%** |

**`RECUR_LANES=32` still clears with 137 cycles of margin, so the -16 DSP,
-9,763 LUT, -1,005 FF, -4.0 BRAM at `SILU_LANES` = 8 does NOT come out of the
deadline.** The 5-cycle cost is 3.5% of the margin.

**The measured cost is 5, not the 8 the obvious model predicts.** `SI_BEATS` is
`DIM/SILU_LANES`, so halving lanes doubles it from 8 to 16 and lengthens
`S_GATE` by 8 cycles, all of which is inside the per-head chain. Three of those
eight do not reach the boundary. That is the third time today an arithmetic
model of this deadline has over-predicted it (419 against 367, then a 2-cycle
invocation cost landing as 1); the bisection is the only thing that has been
right.

---

## The procedure

1. Read the Newton in both files before changing either. Both already have
   `mr_m`/`mr_p` and both say so.
2. Read the cadence note in `rmsnorm_rs:333-346`, which names the two-DSP span
   and is the actual diagnosis.
3. Check whether narrowing is available: it is not, both operands exceed 27x18.
4. Add `mr_m2` and re-map twelve step numbers from `1,3,4,6,7,9,10,12,13,15,16,18`
   to `1,4,5,8,9,12,13,16,17,20,21,24`, so every issue-to-consume gap is 3 and
   every consume-to-next-issue gap is 1. Widen `rq_step` from 19 to 25.
5. Verify both units against their own testbenches.
6. Measure the cycle delta against the committed versions, in the same
   testbench, rather than counting states.
7. For Task 2, run the SILU_LANES=8 bisection INCLUDING a teeth check at
   arrival 256, which must drop.

---

## The evidence

```
l2norm_rs is within tolerance of x/||x|| on every case      (133 cycles, was 121)
rmsnorm_rs is BIT-EXACT with rmsnorm on every case          (rs 148 cycles, was 142)
```

`l2norm_rs` is a tolerance check rather than a bit-exact one, so the stronger
evidence is that the reported error is IDENTICAL to 16 significant figures
across the change -- the same case, the same value, only the cycle count moves:

```
before:  random 9: within 4.994412767232461e-1 LSB of x/||x|| (121 cycles)
after:   random 9: within 4.994412767232461e-1 LSB of x/||x|| (133 cycles)
```

SILU_LANES=8 bisection, with the teeth check first:

```
SILU_LANES=8 arrival 256 cycles/head: COLUMN DROPPED     <- teeth check
SILU_LANES=8 arrival 356 cycles/head: COLUMN DROPPED
SILU_LANES=8 arrival 368 cycles/head: COLUMN DROPPED
SILU_LANES=8 arrival 372 cycles/head: COLUMN DROPPED
SILU_LANES=8 arrival 374 cycles/head: COLUMN DROPPED
SILU_LANES=8 arrival 375 cycles/head: no column refused    <- the boundary
SILU_LANES=8 arrival 376 cycles/head: no column refused
SILU_LANES=8 arrival 377 cycles/head: no column refused
SILU_LANES=8 arrival 378 cycles/head: no column refused
SILU_LANES=8 arrival 379 cycles/head: no column refused
```

### The block: values identical, +48 cycles, and the deadline untouched

`gdn_block` at the default shape, same tree, differing only in `l2norm_rs`:

```
HEAD                     CYCLES token 0 = 2219
with the cascade hop     CYCLES token 0 = 2267        +48
VALUES IDENTICAL across the l2norm_rs cascade-hop change
```

+48 is exactly `KEY_HEADS(2) x 2 invocations x +12`: two `l2norm_rs` calls per
key head, one for the q vector and one for the k vector, each paying the
doubled cost.

All eleven `gdn_block` skew configurations are bit-identical to the reference
(`z1 z7 z31 wmove scmove cwmove capbusy cvgap1 cvgap3 all`, plus
`fastall` against `fastref`).

And the per-head deadline at `SILU_LANES=16` is **unchanged at 369 dropped /
370 passing**, which is the direct evidence that `l2norm_rs` sits outside the
per-head loop -- it runs in the block's `P_L2` phase, before the sweep starts.
Only the token total moves.

---

## Measured and REJECTED -- do not retry

### Do not "add the MREG" to these two files -- it is already there

The brief's premise was that `MREG` is missing. It is not, in either file, and
has not been since they were written. Adding a second `mr_m`-shaped register
without understanding why the first one did not help would have produced the
same change by accident and the wrong explanation on the commit. The diagnosis
that matters is in `rmsnorm_rs`'s own cadence note: the span is between two
DSPs, not in front of one.

This is the second time in two tasks that the brief's description of the RTL
was wrong in a way that would have sent the fix to the wrong place -- the
previous one had `si_e_seg` assigned in `S_RMS` when it was in `S_GATE`. Read
the state, not the summary of the state.

### Do not narrow the Newton operands to fit one DSP

Checked and unavailable. `rq_y` and `rq_smant` are Q30 values in [1,2), so 31
bits; `rq_y2` is Q30 in [1,4), 32 bits; `rq_diff` is `3*2^30 - s*y^2`, 33 to 34
bits. A DSP48E2 takes 27x18. Nothing here cuts to that without splitting the
multiply by hand, which is a bigger change with a bit-exactness risk and no
measurement to justify it.

### Do not count the l2norm_rs cost as +6

`S_NEXT` runs the whole Newton a second time for the q path. Any per-rsqrt cost
in this file is doubled. Measured 121 -> 133, not 121 -> 127.

---

## Measurement traps hit

* **A deadline bisection with no teeth check is not a measurement.** The first
  `SILU_LANES=8` run returned "no column refused" at 376 through 379, which is
  the wrong direction from the 370 measured at 16 lanes and looked like the
  harness had silently stopped exercising anything. Adding arrival 256, which
  must drop, confirmed the harness was live and the boundary was simply below
  the window swept. It was: 374 drops, 376 passes.
* **`tb_gdn_block`'s default `SILU_LANES` is 8, not 16.** Every deadline figure
  quoted for "16" was taken with `-gSILU_LANES=16` passed explicitly. A run
  that forgets the flag silently measures the other configuration.
* `tb_rmsnorm_rs` instantiates `rmsnorm` as its reference model, so
  `rms_weights_pkg` and `rmsnorm` must be analysed first or the testbench fails
  to elaborate with `unit "rmsnorm" not found`.

---

## Open, not yet answered

* **No synthesis, so no Fmax result.** Whether the tool puts a register in the
  DSP-to-DSP span given a third level is the whole question and it is
  unmeasured. The evidence that it CAN is that the same file's operand-register
  fix moved 205.2 MHz once already.
* **`micro_rmsn_lanes` was checked, and it is NOT a valid proxy for the two
  real units on this path.** `sim/micro/micro_rmsn_lanes.vhd:99-106` carries its
  own inline Newton chain with `m_yy`, `m_sy` and `m_yd`, and each is a SINGLE
  register after its multiply -- no MREG/PREG pair at all, where the shipped
  units have had two since they were written and now have three. Its Fmax is
  therefore expected to be worse than theirs for a reason that has nothing to
  do with the shipped RTL, and pooling it with them as "all bound by the same
  path" is right about the path but cannot be used to predict the units'
  numbers.

  It is a synthesis COST probe, not shippable RTL, so it was deliberately NOT
  changed: pipelining it would change what the instrument measures, and that is
  the coordinator's call rather than a silent edit. If it is being used as a
  timing proxy it needs the same three levels to be comparable; if it is being
  used for DSP and LUT cost, it should be left exactly as it is.
* Carried forward: `DONT_TOUCH` on `gdn_silu`'s per-lane control blocks
  Vivado's own further replication, so if a later path is routing-bound again
  that attribute is the first thing to reconsider. And the x0.835 derate rule
  is withdrawn -- the measured derate runs 16.5% to 28.0% -- so no 0.85 V
  figure in this file should be scaled to reason about 0.717 V.
