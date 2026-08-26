# The L2 norm recipe pinned in 87fc976 was numerically broken, and its
# testbench certified it

Date: 2026-08-25
Unit: `rtl/l2norm_rs.vhd` (B section 2.1.3, the Gated DeltaNet L2 norm)
Commit that introduced it: `87fc976`
Found by: a Fable review of the direction, then verified independently before acting

## The question

Commit `87fc976` claimed to pin B section 2.1.3's deferred fixed-point recipe and
close the item, with 55 passing cases at every LANES in {1,2,4,8}. Is the recipe
it pinned correct?

## The answer

No. The recipe collapses the reciprocal square root into a single integer
`inv = round(2^Q / sqrt(ssq))`, and across the unit's normal operating range that
integer rounds to 1 or to 0. The q path emits all zeros for every input with
ssq >= 2^33; the k path errs by up to 41% before it, too, reaches zero.

The testbench did not catch it because the golden was computed from the same
recipe, using the same `work.fixed_pkg` rsqrt_q. Both sides of the comparison
were wrong in the same direction, so they agreed. The commit message itself
names the hazard ("this golden is WEAKER than tb_rmsnorm_rs's ... the recipe is
transcribed twice rather than once") and then does not act on it.

The fix keeps the Q30 rsqrt MANTISSA and a separate scalar shift, never forming
the collapsed integer at all. Q cancels out of the corrected algebra entirely,
which means the commit's "Q = 18 is forced, not chosen" derivation was an
artifact of the broken form and not a real constraint.

## The procedure that produced it

1. **Evaluate the pinned recipe numerically, away from the RTL.** A few lines of
   Python over the plausible ssq range, comparing `x * round(2^Q/sqrt(ssq))`
   against the real-valued `x/sqrt(ssq) * 2^exp`. This isolates the RECIPE from
   its implementation and from its testbench, which is the only way to see the
   fault at all: every VHDL-side check in the repo shared the defect.
2. **Locate the operating range independently.** xm is int16 and N = 128, so
   ssq spans roughly 2^24 (small activations) to 2^37 (saturated). The failure is
   not at a corner; the collapse point sits in the middle of that span.
3. **Rewrite the golden to be INDEPENDENT.** Real-valued `sqrt` accumulated in a
   parallel `real` variable, not the fixed-point path under test, and not
   `fixed_pkg`. This is the step that makes every subsequent result meaningful.
4. **Mutation-test the new testbench** before trusting it. A golden that agrees
   with the DUT proves nothing until it is shown to DISAGREE when the DUT is
   wrong.

## The evidence

Pinned recipe vs. real-valued truth, uniform |x| across N = 128:

```
         ssq  |x| unif   sqrt(ssq)  inv_k=r(2^15/s)  inv_q=r(2^18/(s*sqrt128))     k err    q err
    16777216       362      4096.0                8                          6      0.0%     6.1%
   268435456      1448     16384.0                2                          1      0.0%   -29.3%
  1073741824      2896     32768.0                1                          1      0.0%    41.4%
  8589934592      8192     92681.9                0                          0   -100.0%  -100.0%
 34359738368     16384    185363.8                0                          0   -100.0%  -100.0%
 68719476736     23170    262144.0                0                          0   -100.0%  -100.0%
137438953472     32768    370727.6                0                          0   -100.0%  -100.0%
```

The corrected recipe, which is what the file now implements:

```
ssq    = sum xm[i]^2
m_k    = msb(ssq)            he_k = m_k/2   (fold by 1/sqrt(2) if m_k is odd)
k_n[i] = sat16( round_shift( xm[i] * y_k, 15 + he_k ) )    -- exp 15
m_q    = msb(ssq << 7)       he_q = m_q/2
q_s[i] = sat16( round_shift( xm[i] * y_q, 12 + he_q ) )    -- exp 18
```

where y_k, y_q are the Q30 Newton mantissas normalised to [1,2). No Q generic.

Mutation campaign against the rewritten testbench, 56 cases per run, **each one
re-run at every `LANES` in {1,2,4,8}** because the emit-gating defect class is
LANES-sensitive and a campaign at a single lane count would not see it:

| # | Mutation | Result (cases caught, L1/L2/L4/L8) |
|---|---|---|
| M1 | collapse the rsqrt to an integer (the original bug's exact shape) | CAUGHT, 49, worst 2896 LSB |
| M2 | k-path shift off by one | CAUGHT, 56/56/56/56 |
| M3 | q-path shift off by one | CAUGHT, 56/56/56/56 |
| M4 | parity fold (1/sqrt(2)) dropped | CAUGHT, 56/56/56/56 |
| M5 | rounding bias dropped | CAUGHT, 36/36/36/36 (only after TOL was tightened) |
| M6 | `rq_d := rq_p - 18`, i.e. the withdrawn Q = 18 form | CAUGHT, 56 |
| M7 | emit gated on `v2/idx2` instead of `v1/idx1` | CAUGHT, 39/38/38/38 |

M6 is the decisive one: the testbench now rejects the exact recipe the previous
testbench certified. M7 is the regression guard for the placement bug that
actually occurred in this file during development, and the reason the sweep runs
at four lane counts rather than one.

## Two further defects, found by review AFTER the fix was committed

The correction above was reviewed adversarially once it was already in, and the
review found two things in the shipped state. Both are recorded here because
"the fix was reviewed and was clean" would be the false claim:

1. **The testbench header still described the withdrawn golden.** The body had
   been rewritten to real arithmetic but lines 1-11 still said the golden was
   "computed directly from `work.fixed_pkg`'s own `rsqrt_q`, which is the
   sanctioned reference implementation", and the file still imported
   `work.fixed_pkg` although nothing used it. A reader six months out would have
   taken the header as the house rule and repeated the bug. The header now states
   the rule the incident produced, and says explicitly not to restore the old
   golden.

2. **The `1/sqrt(N)` fold was hardcoded to `<< 7` while `N` was generic.**
   Instantiating at `N = 256` would have silently computed `1/sqrt(128 * ssq)`,
   and the u38 assert would have fired on legal input. The shift is now
   `LOG2N`, the bound is `2^(30 + LOG2N)`, `N` being a power of two is asserted
   rather than assumed, and the testbench's golden derives `sqrt(N)` from the
   generic too -- otherwise a hardcoded golden would have agreed with a
   hardcoded DUT, which is this document's whole subject in miniature. Verified
   passing at `N` in {64, 128, 256} x `LANES` in {1,2,4}. This also unblocks
   the N=256 case C's QK-norm needs, which had never been exercised.

## Measured and REJECTED -- do not retry

- **`inv = round(2^Q / sqrt(ssq))` for any Q.** Q <= 19 is forced by the s63
  headroom on the q path's `ssq << 7 << Q`, and the collapse to 0/1 happens for
  every Q in that range. There is no value of Q that rescues this form; the
  problem is the collapse, not the constant. Withdrawn along with the whole
  "Q = 18 is forced, not chosen" argument that followed from it.
- **Q = 12 (rmsnorm's) "would need a LEFT shift on the output".** Also withdrawn:
  it is a statement about the collapsed form, which no longer exists.
- **Two bad mutations that briefly looked like testbench blind spots.** M1 as
  first written was `shift_right(shift_right(pk, sh_k - 3), 3)`, a double shift
  that is arithmetically within 1 LSB of the single shift it replaced, so it did
  not reproduce the collapse and correctly did not fire. The faithful version
  folds the shift into the multiplier operand and rounds it to an integer, then
  undoes the shift so the emit cancels -- that one fires immediately. Do not
  conclude "not caught" from a mutant until the mutant is shown to be
  semantically distinct.

## Measurement traps hit

- **A testbench whose golden shares the DUT's recipe measures nothing but
  self-consistency.** This is the whole finding. The A/B form used by
  `tb_rmsnorm_rs` (instantiate the unit being replaced, compare) is structurally
  immune; no such prior unit existed here, and the substitute chosen -- transcribe
  the recipe a second time -- has none of that immunity. When there is no prior
  unit, the independent golden must come from a DIFFERENT number system, which
  here means real arithmetic.
- **Tolerance can hide a real defect.** `TOL = 2.0` LSB admitted a mutation that
  dropped the rounding bias entirely, because truncation costs at most 1 LSB. The
  unit measures 0.4995 LSB worst case, so the tolerance was four times looser than
  the thing it was checking. Now 0.75, which separates correct round-half-up from
  truncation. Set tolerance from the MEASURED error, not from a round number.
- **`to_integer` overflows on ssq near 2^37** in the testbench while computing the
  golden. Accumulate a parallel `real` alongside the exact integer sum.
- **Uniform-magnitude test vectors are blind to placement bugs.** An earlier
  emit-misalignment defect in this same file passed every uniform case and only
  appeared once |x| varied across lanes. Random draws are not enough either: the
  magnitude sweep is what exercises the rsqrt.

## Open, not yet answered

- The recurrence error bound in `2026-08-25_gdn-recurrence-error-bound.md` assumes
  `k_n` is accurately unit-norm. A k scale error enters the delta rule as k*k^T,
  i.e. squared, so that document needs re-checking against the corrected unit
  rather than the one it was written against.
- The corrected unit measures 21 DSP / 300.0 MHz / 313 cycles at `LANES=1`,
  26 / 300.0 / 185 at 2, and 36 / 285.8 / 121 at 4. DSP is unchanged from the
  broken version; the first synthesis of the CORRECTED unit came in at
  272.3 MHz because the `1/sqrt(2)` fold multiply and its shift shared a cycle
  with the lane multiplier's DSP B-input register, and splitting the fold into
  two states returned the full 300 MHz for 2 cycles of 313.
- **The same transcription weakness exists elsewhere in this repo and is the
  more valuable finding.** It is confined to APPROXIMATION kernels, where
  "correct" means close to a real function: for exact primitives the recipe IS
  the definition and transcription is legitimate. Named suspects: the A-chain
  goldens from `ref/run_fx.c` (anchored end-to-end at stories260K's dims only,
  never against real math at Qwen3.8's operating points), `tb_silu_cone`, and
  above all B's gating nonlinearities (`softplus_q12`, `exp_q15`,
  `sigmoid_q16`), which stories260K never exercises at all and whose testbenches
  do not yet exist. `eg` is the sharp case: the state is multiplied by it every
  token, so a half-ULP Q15 error becomes a percent-level error in the weighting
  of old context for the slow heads. That is a compounding term; the k-norm
  error is not.
