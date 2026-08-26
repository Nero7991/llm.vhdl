# Overnight status, 2026-08-25 into 2026-08-26

Written for someone who was asleep. Three things need a decision; everything
else is measured and committed.

## The three decisions owed

### 1. Amend B §2.1.4, or keep it as pinned

**One amendment, covering two sites, not two amendments.** Both are implemented
behind generics defaulting FALSE, both units are bit-exact in all four
combinations, and the corrected form has been synthesized.

| mode | median | p95 | max | `eg=0` mid-seq max | `eg < 0.85` median |
|---|---|---|---|---|---|
| **pinned (today's spec)** | 0.65 | 4,799 | 5,245 | 25.55 | **78.33** |
| `D_NORM` alone | 0.60 | 18,067 | **11,662,306** | 1.05 | 12.90 |
| `TK0_ED` alone | 0.68 | 26.54 | 1,218 | 25.55 | 0.75 |
| **both** | **0.59** | **1.27** | **8.96** | **1.05** | **0.71** |

State error in LSB of the unit's own grid, over the 288 physically realizable
columns.

**These numbers replace the ones circulated earlier tonight, and the earlier
ones were measured on a vector set that excluded almost a quarter of the real
model.** `ref/gdn_recur_vec.c` drew `eg` from [0.85, 1.0] on the stated grounds
that the measured per-head table "ranges over roughly 0.85..0.99997". The table
it cited says otherwise: **522 of 2,304 heads (22.7%) are below 0.85** at
alpha = 0, 162 are below 0.5, 25 are below 0.05, and the minimum is 1.17e-4.
The generator now samples that file directly instead of asserting a range over
it. Credit for spotting it goes to the review, not to me.

The correction does not change the ranking, so **decision 1 is unaffected**.
What it changes is the size of the numbers, in both directions:

- **The pinned recipe is worse than reported where it was never measured.** In
  the newly included `eg < 0.85` region its median error is **78.33 LSB against
  0.59** in the region the old draw covered -- a factor of 130.
- **"Do not adopt `D_NORM` alone" is now a much stronger warning.** Its worst
  case is 11.7 million LSB, not the 37,414 measured on the narrow draw.
- **The corrected recipe holds up across the whole distribution**, but its
  worst case is 8.96 LSB rather than the 3.47 reported earlier. Still two to
  three orders below every alternative.

**The third site the review predicted is real, it is small, and the amendment
already covers it.** At `eg = 0` the decayed state term is identically zero for
a whole column mid-sequence -- structurally the same masked operand as
`tk = 0`, but `tk0` does not gate it, so `se_j` still enters `e_u`'s minimum.
That case had never been generated. Isolating it properly (16 columns that are
both `eg = 0` and mid-sequence):

| mode | median | max |
|---|---|---|
| pinned | 1.00 | **25.55** |
| `TK0_ED` alone | 1.00 | 25.55 |
| `D_NORM` alone | 0.99 | **1.05** |
| both | 0.99 | **1.05** |

Three things follow, and the first two correct what I wrote an hour ago:

- **It is 25.55 LSB, not the 4,799 I first reported.** That larger figure was
  the max over ALL `eg = 0` columns, 8 of which are also `tk = 0` -- so it was
  the first-token defect's size wearing the new site's label. Two classes,
  conflated.
- **It is fixed by `D_NORM`, not `TK0_ED`**, which is what the mechanism
  predicts: `TK0_ED` only touches `tk = 0`, and these columns are
  mid-sequence.
- **It is the pinned recipe's entire steady-state tail.** Pinned's worst
  steady-state column across all 288 is also 25.55, so the worst non-first-token
  error in the whole set IS an `eg = 0` column. The site was invisible before
  because the old draw could not generate it.

So the amendment as scoped is sufficient and does NOT need a third correction
-- which was the open worry, since adopting a half-scoped amendment is exactly
the `D_NORM`-alone mistake.

- **`D_NORM`**: quantize `d` on its own grid instead of inheriting `e_d`.
- **`TK0_ED`**: at `tk = 0`, take `e_d = e_v` instead of `min(e_v, ske)`,
  because `ske` there is `se_j + 17` computed from a state that does not exist.

**Cost of adopting both: nothing.** Synthesized at `LANES = 32`: 129 DSP,
24.5 BRAM, **305.6 MHz** -- identical DSP and BRAM to the pinned form and
slightly better timing, for +81 LUT and +154 FF.

**Do not adopt only the first one.** It is seven times worse than the pinned
recipe: normalizing `d` amplifies the error the phantom grid has already
introduced. That is the reason this is one decision.

What adoption costs elsewhere: `gdn_err.c` re-derivation, §2.10's precision
result re-run, and deleting the `TOL_S_TK0`/`TOL_O_TK0` generics that currently
exist only to hold known defects.

### 2. B's `LANES` for the recurrence sweep

`LANES = 32` and `LANES = 64` are both now measured, not projected:

| `LANES` | DSP | Fmax | II | sweep | BRAM |
|---|---|---|---|---|---|
| 32 | 129 | 302.5 MHz | 4 cyc/col | 1.95 ms (2.18 with the head drain) | 24.5 |
| 64 | 257 | 301.9 MHz | 2 cyc/col | 0.98 ms | 48.5 |

`LANES = 64` works, but +128 DSP takes the die from its ~90.3% floor to roughly
94%. My read is that 32 is the right choice and 64 is not affordable, but the
DSP budget is yours.

### 3. Move B's scalar grid from Q12 to Q18, or keep it pinned

`SP_Q` is a generic on `rtl/gdn_scalar.vhd`, defaulting to the pinned 12.
Measured end to end on the real Qwen3.8-27B `ssm_a`/`ssm_dt_bias` weights (all
2,304 GDN heads) against a double oracle, on the slow heads where a per-token
error compounds:

| scalar grid | slow-band worst rel err | compounded over 4,096 tokens |
|---|---|---|
| **Q12 (pinned)** | 1.92e-04 | **2.196** |
| Q15 | 5.05e-05 | 1.230 |
| **Q18** | **3.06e-05** | **1.133** |
| Q20 | 3.01e-05 | 1.131 (saturated) |

**Cost: nothing.** 7 DSP, 0 BRAM, 327.8 MHz at all three grids -- no datapath
width depends on `SP_Q`, only constant shift amounts, and the generic was
verified to actually apply rather than assumed from the identical numbers.

Q18 reaches the floor set by the exp table's own interpolation error, measured
independently by a different route as 3.04e-05, so past Q18 the grid is no
longer the limit. Two mechanisms make Q12 bad, and the second is the larger:
`g` itself is unrepresentable for the slowest heads (4 of 2,304 lose their
decay entirely), and **`softplus`'s output underflows Q12 and is then amplified
by `|ssm_a|`, which reaches 139 in this model.**

This is a change to a pinned numeric contract, so it is yours, not mine. My
read is that it is the cheapest accuracy the project has been offered.

## What was built

Five real RTL units. Four are verified two ways -- bit-exact against a C
reference in a different language, AND real-valued against a double-precision
oracle in a different number system. **`l2norm_rs` is the exception and the
blanket claim was false for it:** it has no C reference, and is verified
against a VHDL `math_real` golden plus a mutation campaign. That is a weaker
guarantee, and it is the unit whose recipe was found broken in the first place.

| unit | what | headline | verified by |
|---|---|---|---|
| `rtl/gdn_recur.vhd` | §2.1.4 recurrence, sequential | 4·LANES+1 DSP, 318.9 MHz | C + oracle |
| `rtl/gdn_recur_pipe.vhd` | same, column-pipelined | **II = NB exactly**, same DSP | C + oracle |
| `rtl/gdn_conv.vhd` | §2.1.3 depthwise conv | 4·LANES DSP, 447 MHz, 0 BRAM | C + oracle |
| `rtl/gdn_scalar.vhd` | §2.1.3 scalar path (new) | 7 DSP, 0 BRAM, 327.8 MHz | C + oracle |
| `rtl/l2norm_rs.vhd` | fixed (see below) | 26 DSP, 300.0 MHz | VHDL golden + mutation |

## What was wrong and is now right

- **The L2 norm recipe pinned in `87fc976` was numerically broken** and its
  testbench certified it, because the golden was a second transcription of the
  same recipe. The q path emitted all zeros for `ssq >= 2^33`. Fixed, and the
  testbench rewritten against real arithmetic and mutation-tested.
- **B's schedule looked 14.5x out of reach and is not.** The sequential
  recurrence takes 58 cycles/column against §3.1's assumed 4; the pipelined one
  hits exactly 4. The budget's arithmetic was right all along -- the first unit
  was measuring its own control structure.
- **Three defects in §2.1.4's first-token handling**, of which the spec had
  already found one. See decision 1.
- **B §2.6's BRAM table is dimensioned for Qwen3.5-0.8B, not the 27B** -- every
  `2048` is the 0.8B's `key_dim` and "18 layers" is its layer count, while the
  target has 48 GDN layers and `inner_size = 6144`. Honest figure ~50-60 BRAM36
  per card against the ~18-20 written.
- **"Every term in the 89.5% is measured" was false** and is retracted. The
  replacement range I then published, 90.3% to 92.7%, was **also wrong**, twice:
  collapsing conv from an assumed 0-32 to a measured 16 moves BOTH ends and I
  moved only the floor, and the old ceiling never followed from its own
  components (base 2,578 plus every published delta at maximum gives 2,660, not
  2,670 -- ten DSP with nothing behind them). Rebuilt from components with the
  scalar path now measured at 7: **2,606 to 2,648 of 2,880 = 90.5% to 91.9%**.
  The spread narrows from 86 DSP to 42, of which all but 4 is D's unwritten RTL.
- **That 90% line is folklore for this part.** Every citation traces to AXU3EG
  (360 DSP) incidents, and the flagship one was an uninitialized inferred
  distributed RAM. Marked unvalidated.
- **C's QK-norm row was an 18-DSP skeleton**; the real unit is 22 at N=256, and
  a schedule check (never previously done) confirms 1 lane meets C's budget.
- **B's scalar path is built and is 7 DSP, not the "+2 to +4, believed cheap"
  §2.8 guessed.** `softplus` did not exist in the reference at all. Two defects
  in §2.1.3 as written, both of which turn a shut decay gate into a wide-open
  one: converting `alpha` and `dt` to Q separately and adding "in s32"
  saturates each term first, and two opposite-sign saturations cancel (a true
  argument of -34826 computes as -1); and the positive tail of the softplus
  argument must not be clamped, because there softplus is the identity and the
  magnitude is exactly what propagates into `g`. See
  `docs/debugging/2026-08-26_gdn-scalar-path.md`.
- **The scalar grid, not the exp table, is what limits `eg`'s accuracy.** On the
  real weights Q12 costs 1.92e-4 relative on the slow heads, compounding to
  **2.196x over 4,096 tokens**; Q18 gives 1.133x and reaches the floor set by
  the exp table itself. Free in DSP, BRAM and timing -- measured at all three
  grids, not argued. Defaulted OFF, so this is a third thing you could decide.
- **§2.1.3's "2048 acc values per segment" is the 0.8B's `key_dim`**, a second
  instance of the stale dimensioning already found in §2.6's BRAM table. The
  real segments are q 1,024 / k 1,024 / v 3,072, so `gdn_conv`'s channel count
  is now a runtime port. The 16-DSP row survives the real shape (DSP is set by
  `LANES` alone, one instance serves all three segments), but its **"0 BRAM"
  does not: the v segment costs 4 BRAM36.**
- **§3.3's "72% margin" is stale**: the bundle prices conv at `LANES = 32` while
  the decision is `LANES = 4`. Substituting gives **+36%**, and no schedule has
  actually been exhibited in which any of it overlaps.

## Open, and honestly open

- The **rate** of the `tk = 0` defects in the real model is unknown. Their size
  is measured; how often `beta` reaches the range that triggers them is not,
  because `beta` is activation-dependent and no weight table settles it.
  Instrumenting llama.cpp's delta-net op to histogram `beta` would close it.
- **The head-boundary drain**, 11.7%, is measured and not eliminated: `k_n`,
  `q_s`, `eg` and `beta` are read off the ports, so a head boundary needs a
  ~60-cycle drain. Double-buffering removes it for ~4 Kbit. That is the 1.95 vs
  2.18 ms difference.
- **`gdn_recur_pipe` is stall-intolerant by construction.** It needs an elastic
  column buffer and a drain interlock in front of it before D's sequencer is
  designed against its port. Nobody has written that piece down.
- **No die-wide BRAM sum exists** the way the DSP sum finally does.
- The FK33 is still at wiper 68 / 0.717 V. Nothing was changed on the hardware.

## Where to read more

- `docs/debugging/2026-08-26_gdn-first-token-dm-grid.md` -- the defect cluster,
  the measurements, and the rejected alternatives.
- `docs/debugging/2026-08-26_gdn-recurrence-column-pipelining.md` -- the 14.5x
  miss, and the GAP-bisect procedure that found the pipelining bugs.
- `docs/debugging/2026-08-25_l2norm-recipe-collapse.md` -- the broken recipe and
  why its testbench could not see it.
