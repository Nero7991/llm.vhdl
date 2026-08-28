# The clock verdicts, measured at 0.717 V instead of scaled

**Date:** 2026-08-27. Part `xcvu33p-fsvh2104-2L-e` synthesised, re-analysed at
VCCINT 0.717 V on the `-2LV` variant. Vivado 2023.2. All runs on the BC-250.

**What this replaces.** `docs/2026-08-27_budgets-at-the-measured-clock.md`
section 7.1 lists a set of "clock verdicts that change side". Every one of them
compared a **0.85 V** synthesis Fmax against a 0.85 V-era target of 299.04 MHz,
and the document offered a scaled estimate -- multiply by 0.835, the 16.5%
derate measured once on `matvec_core` at `ROWS_IF = 58` -- while explicitly
refusing to treat that scaling as settled. This document measures each of those
units at 0.717 V instead. Every figure below is labelled MEASURED, DERIVED or
ESTIMATE.

---

## 0. The answer, up front

**1. The 16.5% derate is NOT uniform. It is not even uniform within one unit.**
Measured across five unit classes it ranges **16.5% to 28.0%**, and across three
sizes of `matvec_core` alone it ranges **16.5% to 24.4%**. The 16.5% that was
generalised is the **smallest** number in the whole measured set, so every
scaled estimate built on it is optimistic. Section 3.

**2. Two of the four scaled verdicts flip the wrong way, and all five scaled
numbers are optimistic by 17 to 32 MHz.** `l2norm_rs` at `LANES = 4` was
estimated at 238.6 MHz (clears 237.8) and measures **214.2** (misses by 23.6).
`gdn_emit_chain` at `SILU_LANES = 8` was estimated at 247.0 (clears) and
measures **227.6** (misses by 10.2). Section 2.

**3. Nothing measured here reaches 237.8 MHz.** Not one of the fourteen
configurations clears the target, including the `LANES = 1` fallbacks that B and
C's budgets fall back on when a wider form is rejected. Section 2.4.

**4. The reason is structural and it is more useful than any ratio.** At 0.717 V
every one of these units is bound by the **same** path: a DSP48E2-internal
multiply in the Q30 Newton rsqrt, `ARG__N/DSP_A_B_DATA_INST/CLK -> ...`, which
is 84-88% logic delay. At 0.85 V the binding path is frequently somewhere else
and route-dominated. A design's "derate" is therefore the ratio of a shared
low-voltage floor to whatever unrelated path happened to bind it at 0.85 V.
Section 3.2, and `docs/debugging/2026-08-27_derate-is-not-a-constant.md`.

**5. One decision is unblocked, on a different argument than the one that was
expected.** At 0.717 V, `SILU_LANES` 8, 16 and 32 all measure
**227.63487366264513 MHz -- bit-identical, same critical path, same 4.354 ns**.
Silu width does not touch the clock at the operating voltage. So
`SILU_LANES = 8` is available for **-16 DSP, -9,763 LUT, -1,005 FF, -4.0 BRAM**
against the adopted 16, at **zero** clock cost. Section 4.

---

## 1. Method, and why these numbers are comparable to 237.8 MHz

Each point synthesises once and is then timed twice: at the part default, and
again after `set_operating_conditions -voltage {VCCINT 0.717}`. No placement, no
re-synthesis. The two columns are therefore a **pure voltage re-analysis of one
netlist**, which is the same instrument that produced the 237.8 MHz target
(`sim/ooc_sweep/results.csv:7`).

Harnesses, both extended for this campaign rather than replaced:

- `sim/ooc_micro.tcl` -- new `volt=<V>` argument, plus a `volt_results.csv`
  with both rows per point. Used for `l2norm_rs`, `rmsnorm_rs`,
  `micro_rmsn_lanes`.
- `sim/ooc_gdn_emit_chain_silu.tcl` -- new leading voltage argument, and it now
  dumps `report_timing` at both voltages so the binding path is recorded rather
  than inferred.
- `sim/ooc_core_sweep.tcl` -- unchanged; used as-is for the `matvec_core`
  control points.
- Driver: `sim/run_volt_verdicts.sh`.

**Both voltage paths use the same timing model, so the comparison is valid.**
The post-synthesis constraint triggers `[Vivado 12-4441] ... require changing to
the -2LV variant` followed by `[Device 21-403] Loading part
xcvu33p-fsvh2104-2LV-e`, exactly as the place-and-route path does. Confirmed in
this campaign's own logs and, independently, in `sim/ooc_sweep/volt072.log:2704`
plus the `-2LV` speed-file header of `sim/ooc_sweep/timing_R48_v0.717.rpt`
(commit `c87003b`). The one residual asymmetry is that synthesis runs on `-2L`
and only the analysis runs on `-2LV`, so the netlist is optimised for the wrong
part -- that makes these numbers, if anything, slightly pessimistic.

**Every 0.85 V baseline was re-measured in the same run** rather than quoted
from the committed CSVs, so RTL drift cannot hide inside a derate. Three
baselines moved because the RTL moved since they were first published, and they
are flagged in section 2.

### 1.1 Run-to-run spread is zero on this path, MEASURED

The coordinator's warning about baseline choice is real for **place-and-route**
figures (`sim/ooc_micro/pnr_results.csv` holds five `gdn_emit_chain` rows at the
same shape spanning 243.72 to 281.21 MHz). It does not apply to this instrument.
Three independent second invocations were run:

| point | run 1 WNS / Fmax @0.717 | run 2 WNS / Fmax @0.717 |
|---|---|---|
| `l2norm_rs` N=128 LANES=4 | -1.336 / 214.17862497322764 | -1.336 / 214.17862497322764 |
| `micro_rmsn_lanes` LANES=4 | -1.647 / 200.80321285140562 | -1.647 / 200.80321285140562 |
| `gdn_emit_chain` SILU_LANES=8 | -1.093 / 227.63487366264513 | -1.093 / 227.63487366264513 |
| `gdn_emit_chain` SILU_LANES=16 | -1.093 / 227.63487366264513 | -1.093 / 227.63487366264513 |
| `micro_rmsn_lanes` LANES=1 (smoke run + sweep) | -1.647 / 200.80321285140562 | -1.647 / 200.80321285140562 |

**Spread = 0.000 MHz, bit-identical to 17 significant figures.** Synthesis is
deterministic and the voltage re-analysis adds no placement, so there is nothing
to vary. Additionally, seven of the 0.85 V baselines reproduce the committed
workstation figures exactly (`285.7959416976279`, `281.8489289740699`,
`300.7518796992481`, `278.8622420524261`, `200.92425155716293`,
`295.77048210588583`), which is a cross-machine and cross-month reproduction on
top of the within-session one. **Every derate difference reported below exceeds
the spread, because the spread is zero.**

---

## 2. The measured table

Target: **237.8 MHz** (MEASURED, `matvec_core` `ROWS_IF = 58` at 0.717 V,
`sim/ooc_sweep/results.csv:7`). "scaled" is the section 7.1 estimate,
0.85 V Fmax x 0.835.

### 2.1 `l2norm_rs`, N = 128, period 3.333 ns

| LANES | DSP | LUT | FF | BRAM | Fmax @0.85 | Fmax @0.717 | derate | vs 237.8 | scaled | agrees? |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 21 | 7,143 | 4,650 | 0 | 300.03 | **224.57** | 25.15% | **MISS** -13.2 | -- | -- |
| 2 | 26 | 8,813 | 4,694 | 0 | 300.03 | **224.57** | 25.15% | **MISS** -13.2 | -- | -- |
| **4** | 36 | 16,497 | 4,796 | 0 | **285.80** | **214.18** | 25.06% | **MISS** -23.6 | 238.6 CLEARS | **NO** |

All MEASURED. The `LANES = 4` 0.85 V figure reproduces B spec `:2034`'s 285.8
exactly. The `LANES = 1` and `2` rows read 300.03 rather than the committed
300.75 (and 7,143 LUT rather than 6,905) because `rtl/l2norm_rs.vhd` has changed
since; the 0.717 V column is paired with the re-measured baseline, not the old
one.

**Verdict.** B `:2034-2036` rejected `LANES = 4` and forced the closing point to
`LANES = 2`. The rejection of `LANES = 4` **stands**, but the fallback does not
help: `LANES = 2` misses 237.8 by 13.2 MHz as well. There is no closing point in
this sweep. The scaled estimate was optimistic by **24.5 MHz** and put the
verdict on the wrong side.

### 2.2 `rmsnorm_rs`, N = 256, Q = 12, period 3.322 ns

| LANES | DSP | LUT | FF | Fmax @0.85 | Fmax @0.717 | derate | vs 237.8 | scaled | agrees? |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 22 | 11,046 | 5,413 | 300.75 | **224.57** | 25.33% | **MISS** -13.2 | -- | -- |
| 2 | 28 | 11,769 | 5,574 | 281.85 | **211.46** | 24.97% | **MISS** -26.4 | -- | -- |
| **4** | 40 | 13,499 | 5,857 | **281.85** | **211.46** | 24.97% | **MISS** -26.4 | 235.3 MISSES | side yes, number no |

All MEASURED, all three 0.85 V figures reproducing the committed ones exactly.

**Verdict.** As predicted, `LANES = 4` does **not** flip -- a confirmed
non-flip. But the scaled number was optimistic by **23.9 MHz**, so the agreement
is on the side of the inequality only, not on the quantity. **The consequential
new result is `LANES = 1`**: C skeleton 3.4 and C spec 3.8 both reject `LANES = 4`
partly on the grounds that `LANES = 1` closes at 300.8 MHz and is "not needed
anyway". At the operating voltage `LANES = 1` measures **224.57 MHz and misses
237.8 by 13.2**. The QK-norm has no closing configuration at 0.717 V, and C's
"a unit that misses the clock is not a budget option" rule, applied consistently,
disqualifies its own chosen fallback.

### 2.3 `micro_rmsn_lanes`, period 3.333 ns

| LANES | DSP | LUT | FF | Fmax @0.85 | Fmax @0.717 | derate | vs 237.8 | scaled | agrees? |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 18 | 385 | 248 | 278.86 | **200.80** | 27.99% | **MISS** -37.0 | 232.9 MISSES | side yes |
| 2 | 24 | 480 | 312 | 278.86 | **200.80** | 27.99% | **MISS** -37.0 | 232.9 MISSES | side yes |
| 4 | 36 | 554 | 440 | 278.86 | **200.80** | 27.99% | **MISS** -37.0 | 232.9 MISSES | side yes |
| 8 | 60 | 756 | 696 | 200.92 | **150.88** | 24.91% | **MISS** -86.9 | 167.8 MISSES | side yes |

All MEASURED, all four 0.85 V figures reproducing B spec `:3122-3125` exactly.

**Verdict.** Confirmed non-flip, as predicted. **27.99% is the largest derate in
the campaign** and the scaled estimate was optimistic by **32.0 MHz**, the worst
error of the five. This is the smallest design in the set (385 LUT), which is
exactly why: there is almost nothing but logic on its critical path.

### 2.4 `gdn_emit_chain`, HEADS = 24, DIM = 128, RMS_LANES = 4, Q = 12, period 3.3 ns

| `SILU_LANES` | `SI_BEATS` | DSP | LUT | FF | BRAM | Fmax @0.85 | Fmax @0.717 | derate | vs 237.8 | scaled | agrees? |
|---|---|---|---|---|---|---|---|---|---|---|---|
| **8** | 16 | **57** | **23,910** | **14,005** | **11.5** | **295.77** | **227.63** | 23.04% | **MISS** -10.2 | 247.0 CLEARS | **NO** |
| 16 (adopted) | 8 | 73 | 33,673 | 15,010 | 15.5 | 305.53 | **227.63** | 25.50% | **MISS** -10.2 | -- | -- |
| 32 | 4 | 105 | 52,735 | 16,963 | 23.5 | 291.63 | **227.63** | 21.94% | **MISS** -10.2 | -- | -- |
| 64 | 2 | 169 | 90,680 | 20,768 | 39.5 | 279.88 | **224.67** | 19.73% | **MISS** -13.1 | -- | -- |

All MEASURED. `SILU_LANES = 8` reproduces `sim/gdn_emit_chain_silu.csv`'s
295.77048210588583 exactly; the 16, 32 and 64 rows have moved (300.75 -> 305.53,
288.68 -> 291.63, 266.81 -> 279.88) because the RTL under them has changed since
that CSV was written. This is the reason the 0.85 V column is re-measured every
run rather than quoted.

**Verdict.** `SILU_LANES = 8` does **not** clear 237.8 MHz. The scaled estimate
was optimistic by **19.3 MHz** and put it on the wrong side. **But the rejection
it was meant to overturn is void anyway, for a reason a ratio could never have
shown: at 0.717 V, 8, 16 and 32 lanes are indistinguishable.** See section 4.

### 2.5 `matvec_core` control, period 3.3 ns

Run to test whether 16.5% is a property of this unit class or of one
configuration. Both new points are MEASURED in this campaign; the `ROWS_IF = 58`
pair is the committed one.

| `ROWS_IF` | DSP | LUT | Fmax @0.85 | Fmax @0.717 | derate |
|---|---|---|---|---|---|
| 8 | 264 | 20,447 | 312.40 | **236.29** | **24.36%** |
| 32 | 1,056 | 73,599 | 311.53 | **236.29** | **24.15%** |
| 58 | 1,914 | 134,675 | 284.90 | **237.81** | **16.53%** |

`ROWS_IF = 8` and `ROWS_IF = 32` land on **236.29489603024572 MHz, identical to
17 significant figures** despite a 4x difference in size, and identical to the
already-committed `ROWS_IF = 32` row at 0.717 V.

**This is the single most important row in the document.** The 16.5% that the
whole scaling exercise rests on is not a property of `matvec_core`. It is a
property of `ROWS_IF = 58` **at 0.85 V**, where congestion had already pulled the
0.85 V number down from ~312 to 284.9. The 0.717 V number barely moved. Divide a
flat floor by a degraded baseline and you get a small ratio.

---

## 3. Is the 16.5% derate uniform? No.

### 3.1 The direct answer, MEASURED

| unit class | derate at 0.717 V |
|---|---|
| `gdn_emit_chain` SILU_LANES=64 | 19.73% |
| `gdn_emit_chain` SILU_LANES=32 | 21.94% |
| `gdn_emit_chain` SILU_LANES=8 | 23.04% |
| `matvec_core` ROWS_IF=32 | 24.15% |
| `matvec_core` ROWS_IF=8 | 24.36% |
| `gdn_emit_chain` SILU_LANES=16 | 25.50% |
| `rmsnorm_rs` N=256 | 24.97-25.33% |
| `l2norm_rs` N=128 | 25.06-25.15% |
| `micro_rmsn_lanes` 1/2/4 | **27.99%** |
| `matvec_core` ROWS_IF=58 | **16.53%** |

**Range 16.5% to 28.0%, an 11.5 point spread, against a measurement spread of
0.000.** The difference is real by an unlimited margin. Within `matvec_core`
alone the range is 16.5% to 24.4%, a 7.9 point spread, so the non-uniformity is
not even a between-unit effect.

**Consequence: no scaled estimate anywhere in
`docs/2026-08-27_budgets-at-the-measured-clock.md` that uses 0.835 can be
trusted, and all of them err in the same direction -- optimistic.** The five
estimates checked here were optimistic by 17, 19, 24, 24 and 32 MHz.

### 3.2 Why, MEASURED

The derate is a ratio of two numbers that are set by different physics.

**At 0.717 V there is a shared floor.** In every unit measured, the binding path
is a DSP48E2-internal multiply inside the Q30 Newton rsqrt:

| unit | binding path at 0.717 V | delay | logic share |
|---|---|---|---|
| `l2norm_rs` L1/L2 | `ARG__9/DSP_A_B_DATA_INST/CLK -> mr_m_reg[65]/D` | 4.414 ns | 87.6% |
| `l2norm_rs` L4 | `ARG__5/DSP_A_B_DATA_INST/CLK -> mr_m_reg[61]/D` | 4.630 ns | 84.9% |
| `rmsnorm_rs` N256 L1 | `ARG__9/DSP_A_B_DATA_INST/CLK -> mr_m_reg[65]/D` | 4.414 ns | 87.6% |
| `rmsnorm_rs` N256 L2/L4 | `ARG__14` / `ARG__24` `/DSP_A_B_DATA_INST/CLK -> mr_m_reg[65]/D` | 4.690 ns | 83.7% |
| `micro_rmsn_lanes` L1/2/4 | `ARG__3/DSP_A_B_DATA_INST/CLK -> m_yy_reg/DSP_A_B_DATA_INST/A[23]` | 4.382 ns | 86.9% |
| `gdn_emit_chain` SL8/16 | `u_rms/ARG__18/DSP_A_B_DATA_INST/CLK -> u_rms/rq_yfin_reg[27]/D` | 4.354 ns | 87.6% |

Six different designs, four different top levels, one structure, 4.35 to 4.69 ns.
That is why `l2norm_rs` at 1 and 2 lanes and `rmsnorm_rs` at N=256 LANES=1 all
report **exactly 224.57 MHz**: they are all reporting the same rsqrt path.

**At 0.85 V the binding path is often elsewhere, and route-dominated.** The
identity change is measured directly:

| design | 0.85 V path | logic share | 0.717 V path | logic share |
|---|---|---|---|---|
| `l2norm_rs` L1 | `msb_p_reg[2]/C -> bias_q_reg[0]/R` | 42.6% | `ARG__9/DSP...` | 87.6% |
| `gdn_emit_chain` SL8 | `si_e_seg_reg[2]/C -> u_silu/xq_reg[1][29]/D` | 27.6% | `u_rms/ARG__18/DSP...` | 87.6% |
| `matvec_core` R58 | (committed) 6.3% logic, 93.7% route | 6.3% | same endpoints, 8.2% logic | 8.2% |

**A single derate ratio cannot describe a design whose binding path changes
identity between the two conditions.** And the mechanism behind the spread is
visible in the one design where the path does *not* change, `matvec_core` R58:
logic delay scales **x1.507** with the undervolt while Vivado's estimated route
delay scales only **x1.134**. A path that is 94% route therefore barely moves
(16.5%); a path that is 87% logic moves almost the full amount (28.0%).

Root-cause write-up with the procedure and the rejected hypotheses:
`docs/debugging/2026-08-27_derate-is-not-a-constant.md`.

### 3.3 What to use instead of a ratio

Do not scale. For any unit that contains the shared rsqrt, the 0.717 V figure is
set by that path, and the useful statement is **not** "x% slower" but "**pinned
between 200 and 238 MHz by `ARG__N/DSP_A_B_DATA_INST`**". Where a real number is
needed and no measurement exists, an ESTIMATE of **-25%** is a better default
than -16.5%, and even that was 3 points optimistic on `micro_rmsn_lanes`.

---

## 4. Unblocked and actionable: `SILU_LANES = 8`

**The number that unblocks it:** at 0.717 V, `SILU_LANES` = 8, 16 and 32 all
measure **227.63487366264513 MHz**, WNS **-1.093 ns**, and the identical
critical path `u_rms/ARG__18/DSP_A_B_DATA_INST/CLK -> u_rms/rq_yfin_reg[27]/D`
at 4.354 ns. MEASURED, reproduced in two independent runs.

The original rejection (B spec `:2277`, restated `:2967-2969`) reads
"`SILU_LANES = 8` measures 295.8 MHz and misses 299.04", and the closing point
was set at 16 lanes. That comparison was made at 0.85 V, where the emit chain's
binding path lives **inside `gdn_silu`** (`si_e_seg_reg[2]/C ->
u_silu/xq_reg[1][29]/D`, 27.6% logic, route-bound). At 0.717 V the binding path
has moved **out of `gdn_silu` entirely** into `rmsnorm_bf`'s rsqrt, so the silu
width no longer touches the clock at all.

**What `SILU_LANES = 16 -> 8` buys** (MEASURED, from the table in 2.4):

| | 16 (adopted) | 8 | delta |
|---|---|---|---|
| DSP | 73 | 57 | **-16** |
| LUT | 33,673 | 23,910 | **-9,763** |
| FF | 15,010 | 14,005 | **-1,005** |
| BRAM | 15.5 | 11.5 | **-4.0** |
| Fmax @0.717 V | 227.63487366264513 | 227.63487366264513 | **0.000** |

**What it costs.** `SI_BEATS` goes 8 -> 16, and `S_GATE` is serial with the
norm, so +8 cycles per head. DERIVED, using B spec `:2277`'s own arithmetic form
(`+4 cycles per head = 4 x 24 x 48 = 4,608` for the 32 -> 16 move): **+8 x 24 x
48 = 9,216 cycles per token**, which at 227.635 MHz is **+0.0405 ms**.

**So the decision is no longer a timing question.** It is a straight trade of
16 DSP, 9.8K LUT and 4 BRAM against 0.0405 ms per token, and it should be
decided on the die budget rather than on the clock. Given that the whole-die
ceiling discussion in B spec `:2960-2969` turns on exactly this 16-to-32 DSP
band, the reclaim looks worth 0.04 ms -- but that is a recommendation, not a
measurement, and the owner of the die budget should make it.

**Caveat, stated plainly.** This is a synthesis-only figure. `gdn_emit_chain`
loses 15.4% between synthesis and post-route at 0.85 V (300.75 -> 254.32). The
claim proven here is the **equality** of 8, 16 and 32 at 0.717 V, and equality of
a synthesis number does not guarantee equality after routing -- a 23,910 LUT
design and a 52,735 LUT design will not route alike. The DSP and BRAM savings
are unconditional; the "zero clock cost" claim should be re-checked post-route
before it is written into a spec.

---

## 5. What section 7.1 should now say

| section 7.1 row | old status | measured status |
|---|---|---|
| `l2norm_rs` LANES=4 at 285.8, "does not close"; closing point forced to LANES=2 | "no longer safe either way; needs a 0.717 V measurement" | **214.2 MHz, misses 237.8 by 23.6.** The rejection stands. **And LANES=2 also misses, by 13.2, so the stated closing point is void.** No form of this unit closes |
| `SILU_LANES = 8` at "295.8 -- misses 299.04"; "the 32-DSP saving may be available" | "conditional on measurement" | **227.6 MHz, misses 237.8 by 10.2 -- so it does not clear.** But 16 and 32 measure **the same 227.6**, so the saving is available anyway. See section 4 |
| `rmsnorm_rs` N=256 LANES=4 at 281.8, "misses both targets"; "does NOT flip" | predicted non-flip | **211.5 MHz, confirmed non-flip.** New: **LANES=1 also misses, at 224.6**, so C's chosen fallback does not close either |
| `micro_rmsn_lanes` 278.9 at 1/2/4, 200.9 at 8; "none reaches 300 MHz" | predicted non-flip | **200.8 and 150.9 MHz, confirmed non-flip**, by a far wider margin than the scaling suggested |
| the mechanical rule "x 0.835" | offered with a caveat | **withdrawn.** The derate is 16.5-28.0% and 16.5% is its minimum |

---

## 6. Open, not determined here

- **Everything above is synthesis-only.** No place-and-route was run at 0.717 V
  in this campaign. `gdn_emit_chain` loses 15.4% synth-to-route at 0.85 V; if
  anything similar holds at 0.717 V these units are in the 180-195 MHz band, and
  A's own 237.8 MHz target is itself a synthesis number that has never been
  placed at `ROWS_IF = 58`.
- **Whether the rsqrt floor can be lifted.** The path is a DSP48E2 internal
  multiply, `ARG__N/DSP_A_B_DATA_INST/CLK -> ...`, at 4.35-4.69 ns with 84-88%
  logic. C spec 3.13 item 1 already names `MREG` on the 34x32 Newton stage as
  the expected fix and B spec `:3140` notes B and C share it. **That single
  pipeline register is now the highest-value RTL change in the project**: it
  binds `l2norm_rs`, `rmsnorm_rs`, `rmsnorm_bf` and `gdn_emit_chain`
  simultaneously, and until it lands no norm unit closes 237.8 MHz at any lane
  count.
- **Whether 237.8 MHz is the right target at all.** It is `matvec_core`'s number.
  Every other unit measured here is below it, so the die clock is set by the
  slowest of them, not by A. On today's measurements that is 200.8 MHz
  (`micro_rmsn_lanes`, a skeleton) or 211.5 MHz (`rmsnorm_rs` at N=256, real
  RTL). Re-deriving the budgets at 211 MHz is not attempted here.
- **`gdn_emit_chain` at `SILU_LANES = 64` was not repeated**, so it rests on one
  run. Given that every other repeat was bit-identical this is a formality, but
  it is stated rather than assumed.

---

## 7. Raw data on disk

| file | contents |
|---|---|
| `sim/volt_verdicts_0717.csv` | 25 rows: both voltages for every `l2norm_rs`, `rmsnorm_rs`, `micro_rmsn_lanes` point, plus the repeats |
| `sim/volt_verdicts_paths.txt` | start point, end point and logic/route split for every point at both voltages |
| `sim/gdn_emit_chain_silu_volt.csv` | the `SILU_LANES` repeat pair with both voltages and the derate column |
| `sim/ooc_sweep/results.csv:12-14` | the `matvec_core` `ROWS_IF` 8 and 32 control points |
| `sim/run_volt_verdicts.sh` | the driver that produced all of it |

`sim/ooc_micro/` is gitignored as run output, so the per-point Vivado reports
themselves live only on the BC-250 at
`/home/orencollaco/GitHub/llama.vhdl/sim/ooc_micro/` (logs under
`voltlogs/`). Everything quoted in this document is reproduced in the two
tracked files above.

---

## CORRECTION, 2026-08-27, same day

**The citation "C spec 3.13 item 1 already names `MREG` on the 34x32 Newton
stage as the expected fix" is WRONG and is withdrawn. C spec section 3.13 item 1
says the opposite.** Its own words are that "`MREG` was NOT the fix, and this
item predicted that it was" -- worth 26 MHz of 183, with an MREG-cadence version
measuring **117.2 MHz against 138.4**. So the citation recommended, on this
document's authority, the one change that spec had already measured and
rejected. It was repeated from here into two work assignments before anyone
checked it.

**The real diagnosis, which is better than the one this document offered:**
`mr_m` (MREG) and `mr_p` (PREG) were ALREADY present in both `l2norm_rs` and
`rmsnorm_rs`, and the three-step cadence exists precisely to buy them -- both
file headers say so. A DSP48E2 multiplier is 27x18, so the 34x32 Newton
multiply spans TWO tiles, and what was unregistered was the **hop between
them**. That is why the path starts at `DSP_A_B_DATA_INST` and reads 84-88%
logic. `rmsnorm_rs:333-346` had already written down the residual in as many
words: "its 34x32 form spans two DSPs with nothing between them."

The fix that landed is a third register level, `mr_m -> mr_m2 -> mr_p`, giving
the tool somewhere to put a flop inside that span. It costs +6 cycles per
rsqrt, and `l2norm_rs` pays it twice because `S_NEXT` returns to `S_ARG` for a
second rsqrt on the q path. Full account in
`docs/debugging/2026-08-27_newton-rsqrt-cascade-hop.md`.

**Consequence for the numbers in this document: they are PRE-`mr_m2`.** The
224.57 and 211.46 MHz figures were measured before that change, so they are the
floor this fix is meant to lift, not a result that includes it. Its Fmax effect
at 0.717 V is UNMEASURED.

The lesson is narrower than "check citations": a spec item that names a fix and
a spec item that names a *rejected* fix read almost identically when quoted at
one line of context, and this one was quoted at one line of context.
