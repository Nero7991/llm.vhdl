# rmsnorm silently emits ZEROS above rms 2^13, and under-normalizes below 2^-6

**Date:** 2026-08-26
**Units:** `rtl/rmsnorm.vhd` (shipped) and `rtl/rmsnorm_rs.vhd` (the 300 MHz
reimplementation). **BOTH, identically.**
**Status:** ROOT-CAUSED same day, see the RESOLVED section. Not yet fixed in
RTL. The cause is a missing epsilon, not the `Q` collapse it first looked like.
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

## RESOLVED 2026-08-26, same day: the missing `eps` IS the defect

The deciding measurement was taken. **2,741,760 samples**, 48 GDN layers x 48
value heads x 1,190 tokens over 4 prompts, Qwen3.8-27B Q4_K_M, captured through
`ggml_backend_sched_eval_callback` selecting structurally on
`op == GGML_OP_RMS_NORM and src[0]->ne[0] == 128` and reading `src[0]`, which is
the norm's input by definition rather than by name. Confirmed by checking
`rms(out) = rms(in)/sqrt(rms(in)^2 + eps)` to **2.35e-07** relative across 24
octaves, which pins the tensor exactly.

**The naive reading is that the design is hopeless:**

| quantity | value |
|---|---|
| observed span of `rms(o_h)` | **24.12 octaves** |
| the unit's window | 19 octaves |
| worst single layer's own span (layer 0) | **19.28 octaves** |

No global scale fits, and **no per-layer scale fits either**, since layer 0
alone exceeds the window. Layer 0's median also sits ~8 octaves above the rest
of the stack.

**But `1/rms` is not the function the model computes.** ggml's `LLM_NORM_RMS`
computes `x / sqrt(mean(x^2) + eps)`, and this model's
`qwen35.attention.layer_norm_rms_epsilon` is **1e-6**, which is not small
relative to these activations:

```
fraction with mean(x^2) < eps        : 72.57%   eps DOMINATES
fraction with mean(x^2) < 0.1 * eps  : 38.88%   norm is a CONSTANT gain
effective gain 1/sqrt(mean+eps): p50 = 901.2, max = 1000.0 = 1/sqrt(eps)
```

And that collapses the range requirement:

| function | span needed | fits the 19-octave window? |
|---|---|---|
| `1 / rms` -- what the RTL computes | **24.12 octaves** | **no** |
| `1 / sqrt(mean + eps)` -- what the MODEL computes | **8.84 octaves** | **yes, with 10 to spare** |

**So the fix is not a wider `Q` and not a restructured rsqrt. It is to implement
the epsilon that both units omit.** `grep -in "eps" rtl/rmsnorm.vhd
rtl/rmsnorm_rs.vhd` returns only the substring inside "steps": there is no
epsilon anywhere in either unit.

This makes the omission two defects at once, and the second was invisible until
the first was measured:

1. **Correctness.** The RTL computes a different function from the model on the
   majority of real inputs. For 38.9% of samples the model's norm is a constant
   gain of 1000 with the data playing no part, and the RTL instead divides by
   the data. That is not a rounding difference.
2. **Dynamic range.** `eps` is what bounds the divider. Without it the required
   span is the full spread of the activations, 24 octaves and growing with
   sample count; with it the output is hard-ceilinged at `1/sqrt(eps)` and the
   span is 8.84 regardless of how small the input gets.

The clamp at `rtl/rmsnorm_rs.vhd:300-302`, `if shifted_r < 1 then msq_r <= 1`,
is a *degenerate* epsilon: it bounds the divider, which is why the unit does not
divide by zero, but it does so at a value set by `Q` rather than by the model,
and it is applied to the Q-scaled mean-square rather than to the mean square.
Setting it from the model's `eps` instead of from `Q` is close to the whole fix.

### The epsilon is UNREPRESENTABLE at the current Q, and the existing clamp is 244x too large

Two arithmetic facts that decide how the fix has to be built.

**1. `Q = 12` cannot represent the epsilon at all.** `msq_r` is an integer equal
to `2^Q * mean(x^2)`, so an epsilon enters it as `2^Q * eps`:

| `Q` | `2^Q * eps` | |
|---|---|---|
| 12 (current) | 0.0041 | **below one LSB, rounds to nothing** |
| 16 | 0.0655 | below one LSB |
| 18 | 0.2621 | below one LSB |
| **20** | **1.0486** | representable, but 1 LSB of resolution |
| 24 | 16.78 | usable |
| 26 | 67.11 | comfortable |

So "add the epsilon" is not a one-line change at the current grid: **`Q` has to
move to at least 20, and realistically 24 or more, for the epsilon to exist as a
number.** The `Q` sweep measured on the BC-250 the same day says that is free up
to 20 at least: 40 DSP, 0 BRAM, 300.75 MHz and identical WNS at every `Q` in
{12, 14, 16, 18, 20}, with LUT and FF marginally LOWER at the top. Whether the
width analysis permits 24 has not been checked; `S < 2^46` and `num_r = S << Q`
in s64 is the binding relation.

**2. The existing clamp is an epsilon 244x too large.** `if shifted_r < 1 then
msq_r <= 1` floors the mean-square at `2^-Q`:

```
Q = 12:  mean_sq floor = 2^-12 = 2.4414e-04   against the model's eps = 1e-06
                                              -> 244.1x too large
         equivalently an rms floor of 1.5625e-02
```

**3. And that floor sits ABOVE the median of the real activations.** The
measured median `rms(o_h)` is 4.808e-04, i.e. a mean-square of 2.31e-07, which
is **below the clamp**. So at the median the unit is already clamped and is
applying a constant gain, but the wrong one:

```
                     divisor          gain
  model  sqrt(2.31e-07 + 1e-06) = 1.11e-03    901
  RTL    sqrt(2.4414e-04)       = 1.5625e-02   64
                                              -> 14x wrong AT THE MEDIAN
```

**This is not a tail defect.** The unit is wrong by an order of magnitude on the
typical sample, not merely on the extremes, and the all-zeros region documented
above is the far end of the same error rather than a separate bug. The reason no
test caught it is unchanged: the golden is `rmsnorm.vhd`, which is wrong in
exactly the same way.

**Scaling caveat, which is where an implementation will go wrong.** `eps` is
defined in the model's native activation units, so it is NOT scale-free. If the
fixed-point input vector is scaled by `2^k` relative to the f32 activations, the
implemented epsilon must be scaled by `2^2k`. The absolute log2 figures above
are in llama.cpp's units and must not be compared directly against the unit's
rails until the Q-format is pinned; the **spans** and the eps relation are the
transferable results.

**`z_h` needs nothing.** The silu gate input spans 6.70 octaves total
(`min 2^-3.40`, `max 2^+3.30`), per-layer spans 2.14 to 3.80. Benign.

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
