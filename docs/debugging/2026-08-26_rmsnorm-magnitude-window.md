# rmsnorm silently emits ZEROS above rms 2^13, and under-normalizes below 2^-6

**Date:** 2026-08-26
**Units:** `rtl/rmsnorm.vhd` (shipped) and `rtl/rmsnorm_rs.vhd` (the 300 MHz
reimplementation). **BOTH, identically.**
**Status:** OPEN. Not fixed. No RTL changed by this investigation.
**Found by:** a scoping review of B's output stage, which predicted the failure
from the algebra before any measurement existed.

## The question

`rmsnorm_rs` is the output norm for subsystem B (site 12 feeds it) and is also
the unit C's QK-norm is meant to reuse. It collapses the reciprocal square root
to a **Q-scaled 32-bit integer** `inv32 ~ 2^Q / rms_real`, `Q = 12` by default.

Is there an input magnitude at which that collapse fails, and is it reachable?

## The answer

**Yes, at both ends, and the upper one is catastrophic and silent.**

Measured, `N = 128`, `LANES = 4`, flat mantissas so `rms_real` is exact, against
a real-valued expectation of 1.0:

| `rms_real` | `o_exp` | nonzero out | worst abs err vs the true 1.0 |
|---|---|---|---|
| 2^-14 | 22 | 128/128 | 0.996 |
| 2^-8 | 16 | 128/128 | 0.750 |
| 2^-7 | 15 | 128/128 | 0.500 |
| **2^-6 .. 2^12** | 14 | 128/128 | **8.88e-16 (exact)** |
| 2^13 | 13 | 128/128 | 1.000 |
| **2^14 .. 2^25** | 24 down to 13 | **0/128** | **1.000, output is ALL ZEROS** |
| 2^26 | -18 | 128/128 | 4.29e9 |
| 2^30 | -22 | 128/128 | 6.87e10 |

Three distinct failure regimes, none of which raises an error flag:

1. **Below `rms_real = 2^-6`:** the unit under-normalizes by a factor of two per
   octave. `msq` is Q12-scaled mean-square, and `if shifted_r < 1 then msq_r <= 1`
   (`rtl/rmsnorm_rs.vhd:300-302`) floors it at `2^-12`, i.e. clamps the divisor at
   `rms = 2^-6`. The output is then `x_real / 2^-6`, not `x_real / rms_real`.
2. **`rms_real` in [2^14, 2^25]:** **every output element is zero.** `inv32`
   underflows to 0 through `rq_shifted <= shift_right(rq_sum_r, rq_sh_r)` with a
   large negative `rq_E` (`rtl/rmsnorm_rs.vhd:405-412`), and `S_RQ_CLAMP` clamps
   the result to 0 rather than flagging it.
3. **`rms_real` >= 2^26:** `inv32` saturates at 2^31-1 and the output blows up by
   ~4e9, with `o_exp` going negative.

**The usable window is `rms_real` in [2^-6, 2^12]. Nineteen octaves, hard
boundaries, silent on both sides.**

## Why no existing test sees it

`sim/tb_rmsnorm_rs.vhd:7-8` states its own design: *"A stored golden vector
would freeze one N, one exponent pair and one input distribution; instantiating
the original means every case below is checked."* The golden is
**`rmsnorm.vhd` itself**.

That proves transcription, and this measurement proves the two units are
**bit-identical in the failure**: at `rms_real = 2^14` both report `o_exp = 24`
and 0/128 nonzero. So the testbench passes at every magnitude, correctly, while
both units emit zeros.

This is the same shape as `docs/debugging/2026-08-25_l2norm-recipe-collapse.md`,
where the golden shared `fixed_pkg.rsqrt_q` with the DUT and certified a unit
that emitted all zeros for every input with `ssq >= 2^33` through 55 passing
cases. That document's own lesson is being repeated here in a second unit.

`tb_rmsnorm_rs.vhd:194-215` DOES contain a magnitude sweep, added after mutation
testing showed the random cases "barely exercise" the rsqrt. It reaches roughly
`x_real ~ 10^6` and it is a genuine improvement, but it is a bit-exactness
comparison, so no magnitude it reaches can ever fail.

## Measurement traps hit, mine

- **My first sweep stopped at 2^10 and I reported the upper rail as REFUTED.**
  The rail starts at 2^13. Two octaves short of a hard failure, and the data up
  to that point is perfectly clean (8.88e-16), so the wrong conclusion looked
  well supported. The review that predicted it from the algebra was right and
  the measurement that "refuted" it was simply too narrow.
- **The first side-by-side against `rmsnorm.vhd` was entirely stale.** The probe
  waited on `rmsnorm_rs`'s `done`, which fires at 142 cycles, while the original
  takes 645, so every "ORIG" row reported the PREVIOUS case's output. It produced
  a clean, plausible table showing the two units diverging, which would have been
  exactly the wrong conclusion. Fixed by waiting on the SLOWER unit's `done`.
- **`wait until done = '1' and done0 = '1'` never fires**, because the two are
  pulses at different times and are never simultaneously high. It hangs rather
  than failing, which reads as a slow simulation.

## What is NOT yet established

- **Whether the real model reaches the bad regions.** `|o_h|` for Qwen3.8-27B
  has never been measured. This is the whole question: a window of 19 octaves may
  be ample, or it may not. Instrumenting `build_norm_gated`'s input in llama.cpp
  for a few hundred tokens settles it and is the next step.
- **Whether C's QK-norm reuse is affected.** C's inputs are a different
  distribution and have not been measured either.
- **Whether raising `Q` is the right fix.** It moves the window without removing
  it. Widths permit up to about `Q = 20`. The alternative, which `l2norm_rs`
  already proved on this exact hazard, is to keep the Q30 Newton rsqrt MANTISSA
  and apply its exponent as a scalar shift at emit, at which point both rails and
  `Q` itself disappear. That is not bit-exact with `rmsnorm.vhd`, so it would
  have to be a new unit with its own real-valued golden.

## Do not

- **Do not "fix" this by widening the tolerance in any testbench.** The failure is
  a hard zero, not a precision loss.
- **Do not treat the bit-exactness of `rmsnorm_rs` against `rmsnorm` as
  reassurance.** It is the reason the defect is invisible.
