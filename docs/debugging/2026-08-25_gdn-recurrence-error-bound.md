# Is int16 sufficient for the Gated DeltaNet recurrent state, or does requantization error compound?

Date: 2026-08-25
Build: `ref/gdn_err.c` (new, standalone; reuses `ref/mv4i_arith.h` verbatim),
`cc -O2 -Wall -Wextra -fopenmp -o gdn_err gdn_err.c -lm`, gcc x86-64, zero
warnings. No tracked file was modified; `sim/run_matvec.sh`'s chain is
untouched.
Defect under test: B spec §2.10, "Nothing in this spec bounds that error",
named the gating deliverable for §3.
Shapes: Qwen3.8-27B GDN. S=128, 48 value heads, 16 key heads (3 v-heads per
k-head), d_inner=6144, conv kernel 4, 48 GDN layers of 64. **Verified against
the GGUF this date**, not assumed: `qwen35.ssm.state_size=128`,
`ssm.group_count=16`, `ssm.time_step_rank=48`, `ssm.inner_size=6144`,
`ssm.conv_kernel=4`, `block_count=64`, `full_attention_interval=4`, read from
`/mnt/storage/llama-models/Qwen3.8-27B-Q4_K_M.gguf` via gguf-py. This closes
B §2.9's "GDN dims NOT verified against the GGUF" caveat for the 27B.

## The question

B spec §2.10, verbatim:

> The state is requantized to int16 **every token**, and the result feeds back
> through the recurrence, so quantization error compounds across a sequence in
> a way that C's write-once KV cache never does. Over a 2048-token sequence
> that is 2,048 successive requantizations of the same state. Nothing in this
> spec bounds that error.

If int16 is insufficient, the state format widens (traffic 18.9 -> 28-38
MB/token at 0.8B scale, 151 -> 227-302 MB/token at 27B), the DDR-residency
argument weakens, and the one-DSP48E2-per-product result of §2.8 may not
survive.

## The answer

**int16 is sufficient. The error is BOUNDED, not compounding: it reaches an
equilibrium of ~5e-4 relative output error by token ~1000 and stays flat
through 16,384 tokens even with the decay gate pinned at exp(g) = 1.0 (zero
contraction), the worst the gate can do.** Under individually pessimistic
regimes (persistent beta = 0.02, 2% of v channels 30x outliers) it is bounded
at ~5e-3; with every adversarial knob stacked at once it is bounded at ~2%,
and in that regime widening the state to 18 or 20 bits changes nothing
(2.06%/2.04% vs 2.27%), because the residual is set by the spec's pinned
16-bit working formats (sites 7/9/12), not by the state width. Against the
project yardstick (A's weight format: ~8% relative weight error = +1.69%
perplexity, `2026-08-24_subsystem-a-format-perplexity.md`), 5e-4 .. 5e-3 is
noise. No format change; §2.8's co-fit and §2.3's traffic numbers stand.

**One spec defect found and measured, with a one-line fix.** As written,
§2.1.4's `e_u = min(se[j] + 2, e_kd)` with `SE_INIT = 0` destroys the first
token's state: at tk = 0 the update lives on grid `e_kd ≈ 28` but is floored
to grid 2, so the entire first write-back is quantization noise (relative
output error **62x at t = 1**, still 1% at t ≈ 1100, under 1e-3 only from
t ≈ 1900). The fix: at tk = 0 exclude the masked zero state from the min,
i.e. `e_u = e_kd` (equivalently `SE_INIT >= +100`; both forms measured
identical). With the fix, token 1 error is 1.7e-3 max and the sequence is
clean from the start. The spec edit is owed to §2.1.4 and the §1.6/§2.1.4
SE_INIT paragraphs; not made here, this is a measurement task.

## The procedure

`ref/gdn_err.c` runs the same recurrence three ways over identical driving
inputs, per token, per head:

1. **ORACLE**, double precision throughout: the truth.
2. **FLOAT**, IEEE binary32: the error floor an fp32 implementation would
   have, so the fixed-point number has a reference scale.
3. **FIXED**, exactly §2.1.4 stages 1-6, all six rounding-site modes as
   pinned (half+inf where specified, floor for the min-referenced
   alignments), `int64_t` intermediates, shifts through `mv4i_floor_shr` /
   `mv4i_round_shift` (the generated primitives, reused verbatim, so this
   reference and subsystem A's share one arithmetic), `msb_pos(0)=0`, state
   in `--wbits` mantissas (16 = spec) with one int8 exponent per column.

What each control isolates:

- **`--inq exact` (default): the oracle is fed the DEQUANTIZED fixed-point
  inputs**, so the reported divergence is caused by the feedback path alone.
  `--inq-real` feeds the true float inputs instead, adding the per-token
  input-quantization term for comparison. This is the load-bearing control:
  without it, input error rides along and the compounding question is blurred.
- **`--eg 1.0`** pins the gate fully open. This is the guard against the
  contractive-regime trap: `g = ssm_a * softplus(alpha + ssm_dt)` with
  `ssm_a < 0`, so a very negative per-token `alpha` drives `g -> 0`,
  `exp(g) -> 1` in production regardless of the boot constants. A run that is
  bounded at eg = 1.0 cannot be depending on the gate to contract the error.
- **`--eg-worst`** takes the 48 slowest-decaying real heads of the model
  (exp(g) at alpha = 0 in [0.999664, 0.999969]), from
  `ref/gdn_eg_qwen3_27b.txt`, extracted from the GGUF's `ssm_a` /
  `ssm_dt.bias` tensors (spot-verified against the raw tensors this date:
  layer 0 head 0, `ssm_a = -0.04063502`, `dt = -3.46875`,
  exp(g) = 0.9987541).
- **`--rho-k/--rho-v`** give the inputs token-to-token correlation (AR(1)),
  since real activations are not white; **`--outlier`** makes a fraction of v
  channels 30x hot, stressing the shared per-segment v exponent;
  **`--beta`** pins beta (small beta = small corrections against a large
  persistent state, the regime where update bits are floored against the
  state grid).
- Metrics per token: relative RMS error of the full state and of the head
  output (what the next layer sees), **mean and worst across all 48 heads**.

No real Qwen3.8-27B GDN activations exist in this repo (the golden vectors
are stories260K, subsystem A's plain-transformer model), so the drive is
synthetic gaussians with the knobs above as the sensitivity sweep. Stated as
an assumption, bounded by the stacked-worst run.

## The evidence

All runs T = 4096 tokens, 48 heads, seed 12345 unless noted. Columns are the
END-of-run values; trend shown where it matters. "out max" = worst-head
relative RMS error of the head output.

**Spec as written (SE_INIT = 0 entering `e_u`), the defect:**

```
   token   state_rel_mu  state_rel_max     out_rel_mu    out_rel_max
       1     6.0665e+00     4.3830e+01     1.0085e+01     6.1917e+01
       8     1.0167e+00     1.7595e+00     9.0066e-01     3.1491e+00
     128     1.0150e-01     3.1709e-01     8.4451e-02     4.7091e-01
    1024     2.3806e-03     1.6598e-02     2.9202e-03     2.3049e-02
    2048     2.8935e-04     8.9876e-04     2.9680e-04     1.0203e-03
    4096     2.6362e-04     5.0212e-04     2.6481e-04     5.2786e-04
first out_rel_max < 1e-2 at t=1093;  < 1e-3 at t=1880
```

**With the tk=0 grid fix (`--fix-init`), same seed:** token 1 is 1.7e-3 max
and the run is flat at equilibrium from ~t=16:

```
       1     1.2270e-04     8.3888e-04     2.2808e-04     1.6786e-03
      16     1.5421e-04     1.9231e-04     1.8768e-04     3.2984e-04
    4096     2.6319e-04     4.9946e-04     2.6380e-04     5.1513e-04
```

`--se-init 100` (the constant-only alternative fix) reproduces the fix-init
numbers digit for digit at t = 1..4.

**Boundedness at the worst gate** (`--eg 1.0 --fix-init`, 16,384 tokens):

```
t=16     out_rel_max 2.83e-4      t=4096   out_rel_max 6.03e-4
t=256    out_rel_max 4.66e-4      t=8192   out_rel_max 6.32e-4
t=1024   out_rel_max 6.12e-4      t=16384  out_rel_max 6.12e-4
```

Rises to equilibrium by ~t=1024, then flat for 15,000 more tokens. The same
shape holds in every other run. Mechanism: with eg = 1 the state norm grows
as sqrt(t) (random-walk accumulation) while the requantization noise also
accumulates as a sqrt(t) random walk; the ratio saturates. With eg < 1 both
sides are further contracted every token. Error is bounded, not linear, not
unbounded.

**Regime sensitivity, W = 16, fix-init, end-of-run worst head:**

| run | out_rel_max | note |
|---|---|---|
| base (real eg random, beta = sigmoid(N(0,1)), iid inputs) | 5.2e-4 | seed 999: 5.4e-4 |
| eg = 1.0, 16,384 tokens | 6.1e-4 | worst possible gate |
| eg-worst (48 slowest real heads) | 7.1e-4 | |
| rho_k = rho_v = 0.9 (correlated inputs), eg = 1.0 | 1.4e-3 | |
| beta = 0.98, eg-worst | 5.1e-4 | |
| beta = 0.02, eg-worst | 5.1e-3 | worst single knob |
| 2% of v channels 30x outliers, eg-worst | 5.6e-3 | shared v exponent stress |
| v_scale = 0.001, eg-worst | 7.3e-4 | scale-invariant as designed; early transient 2.4e-2 at t=1 decays by t~100 |
| `--inq-real` (true float inputs to oracle) | 3.3e-3 | input quantization alone is ~6x the loop's own error |

**Stacked adversarial** (eg = 1.0, beta = 0.02, rho 0.9, 2% outliers, 8192
tokens), the width question answered in the regime where it matters most:

| state width | out_rel_max at t=8192 | trend |
|---|---|---|
| W = 16 | 2.27e-2 | flat from t~16 (5.0e-2 at t=16, 1.9e-2 at t=256, 2.3e-2 at t=8192) |
| W = 18 | 2.06e-2 | flat |
| W = 20 | 2.04e-2 | flat |

**Width sweep, base regime, fix-init:**

| W | out_rel_max | state_rel_max | sat16 events |
|---|---|---|---|
| 12 | 1.38e-2 | 1.55e-2 | 4105 |
| 14 | 2.08e-3 | 2.26e-3 | 999 |
| 16 | 5.15e-4 | 4.99e-4 | 229 |
| 18 | 2.45e-4 | 2.32e-4 | 68 |
| 20 | 2.42e-4 | 2.31e-4 | 9 |

Each 2 bits buys ~4x down to the ~2.4e-4 floor at W >= 18. The floor is in
the STATE error too (state_rel_max 2.3e-4 at both 18 and 20), so it is set by
the in-loop 16-bit working formats the spec pins independently of the state
width: the site-7 skm normalize to 16 bits, the s18 d_m at site 9, and the
site-12 output requantize. Same at eg = 1.0: W12 9.2e-3, W14 2.2e-3,
W16 6.0e-4.

**Housekeeping counters, all runs:** `se_new` out-of-int8 events: **0**
everywhere (the int8 exponent header holds). sat16 events: tens-to-thousands
out of ~25 billion write-back quantizations per run, the biased-path corner
`bfp_pack` semantics expect; benign. fp32 floor: out_rel_max ~5e-7, i.e. the
int16 loop sits ~1000x above an fp32 loop and both are flat.

Raw logs and per-token CSVs: scratchpad `gdn/` of this session
(`base_w16`, `base_w16_fix`, `eg1_long`, `egworst_w16`, `eg1_rho`, `beta_hi`,
`beta_lo`, `outlier`, `inq_real`, `stack_w16/18/20`, `w12/14/18/20_fix`,
`w12/14_eg1`, `seinit100`, `vscale_small`, `seed999`). Regenerate any row
from the command lines embedded in each log's header lines.

## Measured and REJECTED (do not retry)

- **"int16 state feedback compounds without bound."** Rejected by direct
  measurement: flat from t~1024 to t=16,384 at eg = 1.0, the least
  contractive gate possible. The compounding intuition ignores that the state
  norm grows (eg = 1) or the old error is decayed (eg < 1) at the same rate
  the noise accumulates.
- **Widening the state to int24/int32 (the §2.10 contingency).** Buys nothing
  past W = 16 in the regimes that produce large error: W18/W20 match W16
  within 10% in the stacked-adversarial run, because sites 7/9/12 are 16-bit
  by contract regardless. The §2.10 traffic/DSP contingency does not trigger.
- **W = 12 as a traffic saving:** 1.4e-2 base / 9.2e-3 at eg = 1 with 18x the
  saturation events. Not catastrophic, but 27x worse than W16 for a 25%
  traffic cut that §2.3 shows is only ~1-5% of token time anyway. int8
  (§2.1.1's rejected option) extrapolates to several 10s of percent error;
  stays rejected.
- **`SE_INIT = 0` as written.** 62x output error at t=1, 1% at t~1100. The
  first ~1900 tokens of every sequence are corrupted before the equilibrium
  masks it. Fix measured and equivalent in both forms (tk=0 min exclusion, or
  SE_INIT >= 100).

## Measurement traps hit

- **A short run of the spec-as-written config reads as "int16 fails."** At
  t = 256 the error is still 4-25%, decaying. Anyone measuring 256 or 1024
  tokens would conclude the format diverges when they are watching the tk=0
  grid defect wash out. The trend (decaying vs flat) distinguishes them, and
  the fix-init control confirms it: same equilibrium, clean start.
- **Relative error at t = 1..4 is inflated by the tiny state norm.** seed 999
  shows out_rel_max 4.7e-3 at t=1 even for fp32-level effects (fp32 itself
  reads 1.4e-5 there vs 5e-7 later). Single-token early numbers are not the
  bound; the equilibrium is.
- **The oracle must eat the dequantized inputs, not the true floats.**
  Running `--inq-real` first would have reported 3.3e-3 and attributed to the
  recurrence what is actually per-token input quantization (non-compounding).
  The exact-input control puts the loop's own contribution at 5e-4.
- **`--wbits` above 16 does not widen sites 7/9/12** (they are pinned by the
  spec, not derived from the state width), which is exactly why the W18/W20
  runs are informative: they isolate state-width error from seam error. Read
  them as "state width is not the limiter", not "precision is free".
- The eg table was extracted at **alpha = 0**; real
  alpha varies per token and can push exp(g) to 1.0. Runs keyed only to the
  table would inherit the contractive-regime trap; the `--eg 1.0` runs are
  the cover.

## Open, not yet answered

- **Real activation drive.** No Qwen3.8-27B GDN activations exist here; the
  bound under production activations lies somewhere between the base (5e-4)
  and stacked-adversarial (2%) regimes. If a llama.cpp activation dump for
  one GDN layer is ever captured, re-run with it. The per-head beta
  distribution in production is likewise unmeasured.
- **The end-to-end acceptability threshold.** 5e-4 .. 5e-3 relative output
  error is far below A's measured +1.69%-perplexity weight format, but B's
  own perplexity cost has not been measured and will not be until the full
  B reference exists (§3 work).
- **The feed-forward path** (conv, silu, L2 norms, softplus/exp/sigmoid
  LUTs, rmsnorm + z gate) is deliberately outside this measurement: per-site,
  non-compounding, §3 per-site rounding work. The `--inq-real` run hints the
  input side will dominate the loop's own error by ~6x.
- **Q15 vs Q12 decay factor (§1.5's insurance argument)** was not isolated:
  the exact-input control dequantizes eg for the oracle too, and `--inq-real`
  bundles it with all input quantization. A dedicated A/B (eg quantized Q12
  vs Q15, oracle on true eg) would settle whether Q15 was necessary; at the
  measured error levels it is moot for the verdict.
- The site-7 corner `skm = 32768` (half+inf rounding of an amax exactly at
  the boundary) exceeds s16 by one count; the reference asserts it, the spec
  text calls skm s16 without a sat. One-line spec clarification owed to §2.1.4
  stage 2 (sat16 or s17 declaration); no measurable effect here.

## Spec edits owed (not made in this task)

1. §2.1.4 tk=0 rule: `e_u = e_kd` at tk = 0 (or SE_INIT >= +100), with the
   measured 62x/t=1 defect as the reason.
2. §2.10: mark RESOLVED, int16 confirmed, pointing here.
3. §2.9: the 27B GDN dims caveat can cite the GGUF verification above.
4. §2.1.4 stage 2: the skm boundary count (previous section).
