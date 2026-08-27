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

## CORRECTION 2026-08-26 (later): widening `Q` is the WRONG fix, measured

The open question above, "whether raising `Q` is the right fix", is now answered.
It is not. Measured with `ref/rmsnorm_eps_vec.c`, which implements both
structures against a double golden and reports the relative error of the
resulting gain.

**Withdrawn:** the working plan recorded earlier the same day, that the fix is
`Q >= 20` (ideally 24) plus tightening the RTL's `S < 2^46` assert to `S < 2^38`
to keep `S << Q` inside `s64`. That plan is sound arithmetic and still leaves a
**2% error**. Do not implement it.

### The measurement

Relative error of the gain `1/sqrt(mean + eps)`, worst case over
`log2(rms) in [-30, +6]`, N = 128, eps = 1e-6. Random mantissas, 400 draws per
octave, 14,800 vectors total. Golden is `double`.

| structure | worst rel err | where |
|---|---|---|
| absolute-grid, `Q = 12` (**as shipped**) | **1.0000e+00** | low tail |
| absolute-grid, `Q = 24` | 2.0223e-02 | crossover, `log2(rms) ~ -10` |
| floating, `Q = 12` | 8.7933e-03 | high end |
| floating, `Q = 16` | 5.1876e-04 | high end |

Read the first row as what it is: on random vectors the shipped unit is not
merely imprecise in the low range, it is **100% wrong** -- it returns the clamp,
which carries no information about the input at all.

### Why widening `Q` does not rescue it

The absolute-grid recipe rescales `mean` into a FIXED `2^-Q` grid, via
`round_shift(msq, 2*xe)`, and only THEN adds epsilon. At the crossover, which is
`rms ~ 1e-3` where `mean ~ eps` and the sum genuinely needs both terms, `mean`
has already been shifted down to a fraction of one LSB and rounded away. The
epsilon add then has nothing left to add to.

Resolving `mean` at `log2(rms) = -13` wants `Q ~ 30`. `Q <= 25` is a hard `s64`
ceiling at N = 128. The two do not meet, which is why `Q = 24` still shows 2%.

An intermediate that was tried and REJECTED: adding epsilon on a grid `EXB` bits
finer than `Q` (so that `round(2^(Q+EXB) * eps)` is accurate). This does fix the
epsilon quantization -- at `Q = 24`, `round(2^24 * 1e-6) = 17` against a true
16.777, a +1.33% error in eps and -0.66% in the gain -- but the worst-case error
only falls from 6.6e-3 to 7.4e-3, i.e. not at all. **Epsilon quantization was
never the dominant term.** Do not retry this; it treats the wrong half of the
add.

### What actually works

Do not rescale to a fixed grid at all. Carry `mean` in the block-floating form
it already arrives in, express epsilon in the same form once at build time,
align to the larger value, and add. Whichever term is negligible is then the one
that rounds away, which is correct behaviour rather than an artefact.

This is the same move `l2norm_rs` already made on this exact hazard, as the
superseded section above guessed. The measurement confirms it and adds two
things that were not obvious:

- **It needs no width change and no assert change.** The floating form is
  correct at `Q = 12`, the shipped width. `S << Q` never happens, so the
  `S < 2^46` assert stops being load-bearing rather than needing to be tightened.
- **Its residual is not the algorithm.** The 8.8e-3 at `Q = 12` is entirely the
  output grid: at `rms = 2^6` the gain is ~0.0156 and half an LSB of `2^-12` is
  7.8e-3 of it. Raising `Q` to 16 drops it 16x, exactly as pure output
  quantization should. Changing `MB` (24, 30, 36) changes nothing at all, which
  is the check that the internal precision is not the limit.

### Measurement traps hit here

- **The octave sweep with flat mantissas understated the shipped defect by two
  orders of magnitude.** Flat mantissas make `rms` exactly a power of two and
  exercise exactly one value of `S` per octave. The shipped unit scored 6.6e-3
  on that sweep and 1.0 on random vectors. Any sweep over this unit must
  randomise the mantissas.
- **A failed `cd` swallowed an entire edit.** `cd ref && python3 - <<'PY'` was
  run from inside `ref`, so `cd` failed, `&&` short-circuited, and the heredoc
  was consumed with Python never running. The subsequent build succeeded on the
  UNEDITED file and the sweep reported a new parameter having no effect --
  which is also exactly what a genuine null result looks like. Verify an edit
  landed (`grep -c` for the new symbol) before believing a null.
- **First floating implementation had sign errors in both exponents and aligned
  the wrong way**, and reported `rel = 1.0` uniformly. A uniformly perfect
  failure is a bug in the new path, not evidence about the old one.

## RESOLVED 2026-08-26: `rtl/rmsnorm_bf.vhd`, measured

### How much of the real model is actually in the bad region: 77.4%

The open question "whether the real model reaches the bad regions" is answered.
Instrumented `build_norm_gated`'s input on Qwen3.8-27B-Q4_K_M over **418,180
tokens / 963,486,720 samples** (GPU, 65/65 layers offloaded, 594.9 tok/s; the
same probe on CPU reproduces the earlier 1,190-token run bit-for-bit on every
headline number, which is what licenses the scale-up).

| metric | value |
|---|---|
| `rms(o)` range | `2^-29.63` to `2^-0.54` |
| `1/rms` span | 29.09 octaves |
| **`1/sqrt(mean+eps)` span** | **9.4282 octaves**, against a 19-octave window |
| gain range | `[1.45158, 1000]`, upper end hard-bounded |
| **fraction with `mean(x^2) < eps`** | **0.773712** |
| fraction with `mean(x^2) < 0.1*eps` | 0.440778 |

**Nearly four samples in five sit where epsilon IS the normaliser**, not the
data. That is the region the shipped clamp gets wrong by 244x in eps, i.e. a
gain of 64 where ggml applies 1000. This is not a corner case; it is the
common case.

`rms_max` saturates rather than growing: it moved 0.5932 octaves across a 351x
increase in token count, fitting at **0.0037 octaves per doubling**. Reaching
the window's upper rail would need ~10^780 tokens. The scale test was the right
test and it did not threaten the design.

An independent confirmation fell out of the probe's `nout` stream (the norm
output before the weight multiply): max `0.999998987`, min `1.20593984e-06`.
Since `nout = rms/sqrt(mean+eps)`, a max pinned at 1.0 and a min at exactly
`rms_min/sqrt(eps)` confirms the model really computes `1/sqrt(mean+eps)` with
eps = 1e-6.

### Error over the model's real range, not an arbitrary sweep

Correcting a figure from the section above: the floating form's worst error was
quoted as 8.8e-3 at `Q = 12`. That was measured over `log2(rms)` in `[-30, +6]`,
and the model never goes above `2^-0.54`. Restricted to the range the model
actually occupies:

| structure | worst rel err, MODEL range |
|---|---|
| absolute-grid `Q = 12` (**as shipped**) | **1.0000e+00** |
| floating `Q = 12` | **1.3308e-04** |
| floating `Q = 16` | 7.9347e-06 |

So the fix needs **no width change at all**: it is correct at the shipped
`Q = 12`, to 0.013%. The earlier conclusion that `Q` must rise to 20 or 24, and
that the `S < 2^46` assert must be tightened to keep `S << Q` inside `s64`, is
withdrawn in full. There is no `S << Q` in the new unit.

### What it costs: nothing that matters

OOC on `xcvu33p-fsvh2104-2L-e`, N=128, LANES=4, 3.3 ns target, both units built
in the same Vivado run against the same part and period:

| unit | Q | DSP | LUT | FF | fmax |
|---|---|---|---|---|---|
| `rmsnorm_rs` | 12 | 40 | 9042 | 3653 | 300.75 MHz |
| **`rmsnorm_bf`** | 12 | **40** | 9761 | 3660 | **300.75 MHz** |
| `rmsnorm_bf` | 16 | 40 | 9759 | 3660 | 300.75 MHz |
| `rmsnorm_bf` | 20 | 40 | 9760 | 3660 | 300.75 MHz |

**DSP-neutral and timing-identical**, at +719 LUT (+8.0%) and +7 FF. DSP is the
binding whole-die constraint at 90.5-91.9% of 2,880; LUT is not. The S_INV
chain kept its state count (6 either way) and gained no multiply -- it traded a
fixed shift, a divide-by-N and a clamp for two barrel shifts and an add.

### Measured and REJECTED -- do not retry

- **Raising `Q`.** Still 2.0e-2 worst error at `Q = 24`, because the rescale to
  a fixed grid happens BEFORE the epsilon add. Q ~ 30 would be needed; `Q <= 25`
  is a hard `s64` ceiling at N = 128.
- **Adding epsilon on a grid `EXB` bits finer than `Q`.** Fixes the epsilon
  quantization and moves the worst case from 6.6e-3 to 7.4e-3, i.e. not at all.
  Epsilon quantization was never the dominant term.
- **Rounding the alignment shift.** Rounded and truncated agree to five
  significant figures over 14,800 random vectors. The truncating form is used,
  saving a bias state and a 64-bit add state.

### Measurement traps hit

- **Synthesis will not catch this class of error, and now that is on the
  record.** The `Q` sweep on the BC-250 ran `Q` = 20, 22, 24, 25, **26**. `Q=26`
  is arithmetically impossible -- above the `s64` ceiling of 25, where `S << Q`
  overflows silently for `S` near the old assert bound -- and it synthesized
  **clean, at identical resources and the identical 300.75 MHz**:

  ```
  RESULT Q=20 dsp=40 lut=9002 ff=3637 wns=-0.025 fmax=300.75
  RESULT Q=22 dsp=40 lut=8991 ff=3633 wns=-0.025 fmax=300.75
  RESULT Q=24 dsp=40 lut=8983 ff=3629 wns=-0.025 fmax=300.75
  RESULT Q=25 dsp=40 lut=8978 ff=3627 wns=-0.025 fmax=300.75
  RESULT Q=26 dsp=40 lut=8974 ff=3625 wns=-0.025 fmax=300.75
  ```

  LUT even goes DOWN slightly as `Q` rises. Nothing in the flow pushes back.
  Resource and timing measurement cannot substitute for the arithmetic.
- **Sweeping a range the model does not occupy overstated the fix's error by
  66x** (8.8e-3 vs 1.33e-4). Pick the sweep range from measured data, not from
  round numbers.
- **A too-strict edit guard produced a false "edit failed".** After the
  swallowed-edit trap above, an `assert s.count('KLO') >= 4` was added to catch
  it -- but the symbol occurs three times, so a correct edit was rejected and
  re-debugged. Guard on `!= original`, not on a hand-counted occurrence count.

## VERIFIED 2026-08-26 (later still): and the assert I wrote was wrong

`rmsnorm_bf` is now bit-exact against `ref/rmsnorm_bf_vec.c` on 200 cases x 128
elements plus every `o_exp`, across 20 generic combinations: LANES {1,2,4,8,16,
32}, Q {8,12,16,20,22,24}, N {64,128,256,512}, eps {1e-5, 1e-6, 5e-7, 1e-8}.
`tb_rmsnorm_rs` still passes unchanged, so `rmsnorm_rs` is unregressed.

Double oracle, two paths sharing no helpers:

| metric | value |
|---|---|
| worst relative gain error, **model range** | **1.80e-5** |
| worst output error vs double | 0.77 LSB |
| worst relative gain error, whole sweep incl. out-of-envelope probes | 2.35e-3 at `log2(rms) = +4.4` |
| eps-dominated cases in the vectors | 67% (the model's own figure is 77.4%) |

The 2.35e-3 is the `2^-Q` output grid of `inv32` at small gains, not the
block-floating recipe. Same separation as before, and 1.80e-5 over the model
range is better than the design study's 1.33e-4 because that sweep was coarser.

### The defect writing the verification found: an off-by-one in MY assert

`S_INV1` asserted

```vhdl
assert S >= 0 and S < shift_left(to_signed(1, 64), 30 + LOG2N)
```

written from a comment reading `S <= N * 32767^2 < 2^(30+log2 N)`. The input is
int16, so the largest square is not `32767^2` but `(-32768)^2 = 2^30` **exactly**,
and an all-`-32768` vector attains `N * 2^30 = 2^(30+log2 N)` on the nose. The
strict `<` therefore fails on legal input. Now `<=`.

Three things about this are worth keeping:

- **The datapath was never wrong.** Only the check was, and a check that fires
  on legal input is a unit that cannot ship.
- **`tb_rmsnorm_rs` already drives `-32768`.** It never caught this because the
  bound it ran against was the old `2^46`, 512x looser, which swallowed the
  off-by-one. Replacing a loose bound with a tight one is what EXPOSED the
  error in the tight one; the loose bound was hiding a real edge.
- **It came from a comment, not from the arithmetic.** I transcribed
  `N * 32767^2` from prose instead of deriving the bound. Asymmetric integer
  ranges are exactly where prose and arithmetic diverge.

Re-mutating `<=` back to `<` is caught by the testbench.

### Mutation testing: 14 of 18 caught, and the 4 survivors are understood

Caught includes a constant rsqrt seed and a dropped Newton iteration -- the two
that `tb_rmsnorm_rs` needed a whole magnitude sweep to see -- plus
`rq_d := rq_p - Q` (i.e. reverting to `rmsnorm_rs`'s fixed grid, the entire
point of the unit), reversed alignment direction, `e_mean` sign, missing
1/sqrt2 fold, `shift_total` off by one, unsigned max, `o_exp` off by one, ROM
index shift, emit bias, and the MSB scan.

The survivors are not testbench weaknesses:

- **The `S = 0` guards are invisible at the output ports.** `S = 0` means every
  `xm` is zero, so every `raw` is zero and the output is all zeros with
  `shift_total = 0` no matter what `inv32` became. Deleting all three guards
  passes the comparison at any `x_exp`. Closed the only way available: a case
  at `xe = -12` where the ungated path truncates `M_EPS` to zero and trips the
  `S_SEED2` Q30 assert. **The handle is the assert, not the compare.**
- **Three one-LSB mutations survive at every Q tested** (rounding the alignment,
  rounding the S renormalisation, moving `M_EPS_C` by one). A `2^-30`
  perturbation of a 31-bit mean mantissa cannot resolve through a 31-bit
  `inv32`. This is the measured confirmation of the truncation decision above,
  not a gap.

### Still NOT fixed, stated plainly

**The upper rail is unchanged.** `inv32` underflows to zero at
`log2(rms) = Q`, i.e. `+12` at Q=12. That is 12.5 octaves above the model's
measured max of `2^-0.54`, so it is not reachable on this model, but
`rmsnorm_bf` fixed the low end and the epsilon and did **not** move this.

Structurally dead branches, argued rather than merely unreached: the `-32768`
emit rail (`shift_total` puts `max_raw >> st` inside `[2^14, 2^15)` and the
bias is non-negative); the `inv32` low clamp (all inputs non-negative);
`rq_E > 32` (needs Q > 52, since `e_out <= E_EPS` bounds `rq_E <= Q - 20` at
eps = 1e-6). `rq_E >= 0` and the `inv32` high clamp are NOT dead -- they appear
at Q >= 20 and Q >= 22 and are covered by the generic sweep, not by the default
vectors. The generator prints a branch-coverage table naming what it did not
reach, so this list stays honest as the vectors change.
