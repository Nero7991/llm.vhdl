# B's DSP row, closed: 148 at LANES=32

**Date:** 2026-08-25
**Part:** xcvu33p-fsvh2104-2L-e, OOC synthesis at 3.333 ns (300 MHz)
**Unit:** `sim/micro/micro_b_array.vhd` (new), built from `micro_b_lane`
**Question:** B's 138-152 was the only row in the whole-die DSP sum that had
never seen synthesis, in the tightest resource on the die (87.2-88.2% of 2,880).

## The answer

**`DSP_B = 4 x LANES + 20`, exact at every point measured.**
**At `LANES = 32` that is 148 DSP**, inside B §2.8's 138-152 band and near its
top. Whole-die DSP tightens from **2,510-2,540 (87.2-88.2%)** to
**2,520-2,536 (87.5-88.1%)**, still under the 90% congestion line, and the
remaining width is now entirely D's 24-40 estimate.

| LANES | lanes only | with aux | aux | DSP/lane |
|---|---|---|---|---|
| 4 | 16 | 36 | 20 | 4.00 |
| 8 | 32 | 52 | 20 | 4.00 |
| 16 | 64 | 84 | 20 | 4.00 |
| 32 | 128 | **148** | 20 | 4.00 |

The aux term is **exactly** `rmsnorm_rs 18 + silu 2 = 20`, i.e. the sum of the
two units instantiated, so array integration adds **no hidden DSP at all**.

## Why this needed a sweep and not a multiplication

`micro_b_lane` had already measured ONE lane at 4 DSP, which looks like it
settles `DSP_B ~= 4*LANES`. It does not, and the reason is a mistake this
project had just made elsewhere: **subsystem C's array measured 310.5 LUT/lane
against a single-lane fit predicting 238** -- 30% more, because a lane in
isolation has no broadcast, no reduction tree and no shared operand registers.
Extrapolating C from its lane was wrong by 30%; extrapolating B from its lane
had to be checked, not assumed.

The check was worth running and the answer is genuinely different for B:

| | C (LUT) | B (LUT) | B (DSP) |
|---|---|---|---|
| single lane | 238 predicted | 50 | 4 |
| in the array | 310.5 (+30%) | ~57 (+16%) | **4.00 (+0%)** |

So the array-inflation effect is real for B in LUT (+16%) and **exactly zero in
DSP**. That is not luck: the reduction is an XOR tree and the broadcast nets are
routing, and neither consumes a multiplier. The lesson generalises as "check
whether the shared structure is arithmetic before assuming it costs arithmetic",
not as "arrays always cost more than lanes".

## The procedure

1. **Build an array, not a lane** -- `micro_b_array` instantiates LANES copies
   of the validated `micro_b_lane` plus the shared output path.
2. **Model the sharing from B's real geometry**, per the `micro_c_array_p` rule:
   `smant`/`k_n`/`v_in` private per lane, `eg`/`beta` broadcast. Wiring every
   operand to every lane would manufacture a fanout problem and then discover
   it.
3. **Instantiate the aux, do not estimate it.** B §1.1(g)'s output path is
   `rmsnorm(o) * silu(z)` and both exist as measured micros, so the fixed term
   is real RTL.
4. **Sweep with the aux BOTH in and out.** This is what makes the result strong:
   `a` and `b` separate *directly* by subtraction at each lane count, not only
   through a least-squares intercept. A fit alone would have given the same
   numbers with far weaker evidence, and could not have shown that the aux is
   constant rather than merely small.
5. **Keep the four sizing rules** from `micro_b_lane`: operands on top-level
   ports so nothing constant-folds to a KCM or shifter; every result XOR-folded
   into a digest so no cone is pruned with a quiet log note; no `DONT_TOUCH`
   (it blocks register-into-DSP packing and inflates FF); no `use_dsp` (natural
   inference is what the real RTL gets).

## Whole-die DSP, updated

```
A 1,914 (ROWS_IF 58, post adder-tree reclaim)   MEASURED
C   434 (384 MAC + 50 aux)                      MEASURED
B   148 (4 x 32 + 20)                           MEASURED  <-- was 138-152 est
D    24-40                                      ESTIMATE  <-- now the only guess
-----------------------------------------------
    2,520-2,536 of 2,880 = 87.5-88.1%
```

Every subsystem in that sum is now measured except D, so **D's 24-40 is the
entire remaining uncertainty in the tightest budget on the die.**

## Measured and REJECTED -- do not retry

- **"Multiply `micro_b_lane` by 32."** Gives the right DSP (128 + aux) but for
  an unverified reason, and gives the LUT 16% low. The array is the unit.
- **Assuming the array-inflation seen in C transfers to B's DSP.** It does not;
  it transfers to B's LUT only. Measured both ways.

## Measurement traps avoided

- The harness's DSP48E2 **census** cross-checks the utilisation count and warns
  if they disagree, because every past surprise in this project has been a
  *why* -- a multiplier strength-reduced to a shifter, a wide operand split
  across a DSP pair. The two agreed at all eight points.
- The sweep script's own filter (`grep ... | head -8`) was **flooded by
  `DSP Report:` lines** and truncated before the summary printed, so the first
  reading looked like the runs had produced nothing. The data was in the
  utilisation reports the whole time. Fixed to anchor on `^MICRO `.

## Open, not yet answered

- **This is a FLOOR for B, not its total.** The micro covers the state-sweep
  arithmetic and the output gate. B's spec also carries the **L2 norms** (32
  per layer), **softplus**, and the scalar path, none of which are in this
  unit. They are believed cheap -- C measured its divider at 0 DSP and the
  rsqrt lives inside `rmsnorm_rs` which is already counted -- but believed is
  not measured.
- **D's 24-40** is now the only estimated row in the DSP sum. The D-vec
  components are already measured individually (swiglu 3 DSP/lane, narrowed
  rmsnorm 18), so the same array treatment would close it.
- **Whether 90% is the right congestion line for this part** -- still cited by
  B §2.8 and C §2.8, still untested by any placed-and-routed run on this die.
