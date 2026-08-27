# Every cycle and time budget, re-derived at the measured clock

**Date:** 2026-08-27. Branch `fpga`. Part `xcvu33p-fsvh2104-2L-e`, FK33, VCCINT 0.717 V.

**Status: ANALYSIS ONLY. No Vivado was run.** No RTL and no spec was modified.
Every arithmetic result below came from a script kept in a session scratchpad,
which is ephemeral, so the formulas and the inputs are reproduced inline. The
script was validated against three independently published results before any
new number was produced (section 1.4).

**Labelling discipline, following the D, C and 9B-envelope documents.** Each
number is MEASURED (a tool was run and the output recorded, with the file
named), DERIVED (arithmetic shown here from MEASURED or spec-normative inputs),
or ESTIMATE (a judgement with its assumption stated). Where two documents
disagree, both are quoted and the resolution is called open.

---

## 0. The answer, up front

**The clock shortfall is real and it is 20.5%. The token-time shortfall is
18%, not 20.5% and not the 26% a flat scaling gives, because two of the six
budget terms do not scale with the core clock at all.**

| | 9B N=1 | 27B N=2 |
|---|---|---|
| token time at **237.8 MHz** | **26.5 ms** | **41.0 ms** |
| token time at 299.04 MHz | 22.3 ms | 34.6 ms |
| delta | **+4.2 ms, +18.9%** | **+6.3 ms, +18.3%** |
| **tok/s at 237.8 MHz** | **37.7** | **24.4** |
| tok/s at 299.04 MHz | 44.9 | 28.9 |

Both at `ROWS_IF = 58`, `LANES = 32`, ctx 2048, `MACS = 128` (9B) / 192 (27B),
serial across subsystems, B taken at its emit-bound estimate. Full assumption
list in section 2.4.

**Four findings that change what should be done next:**

- **F1. `docs/debugging/2026-08-27_clock-at-the-real-voltage.md:65`'s "a 39 ms
  token budget derived at 299.04 MHz is a 49 ms token at 237.8 MHz" is wrong
  and should be withdrawn.** It multiplies the whole token by 1.258. Subsystem
  A is HBM-floor-bound at 299.04 MHz, so it does not scale by 1.258 -- it
  scales by 1.160. Subsystem E is PCIe-bound, so it scales by 1.058. The
  correct 27B answer is **41.0 ms**, not 49. See sections 1.2 and 2.1.

- **F2. 39 ms is an inherited assumption, not a requirement.** It is the
  self-sum of this project's own estimated component times, printed under a
  heading that reads "informative, derived -- nothing here is measured" and a
  closing sentence that reads "it is not a promise". No external latency or
  throughput requirement exists anywhere in the repo. Section 3.

- **F3. The 17-24% A disagreement partly dissolves and mostly does not.** The
  two derivations were at different clocks: D skeleton's 23.18 ms is at
  300 MHz, and the ~30.5 ms implied by D section 11 descends from A spec 15.4c,
  whose table is at **276 MHz**. Normalised to a common clock the disagreement
  collapses from a 17-to-24% *range* to a single **~16%**. The range was the
  clock; the gap is not. Section 4.

- **F4. A is no longer the binding clock. B's emit chain probably is, and its
  0.717 V number has never been taken.** `gdn_emit_chain` measures 300.75 MHz
  at synthesis and **254.32 MHz post-route**, both at 0.85 V. Applying the
  16.5% derate measured on `matvec_core` gives roughly **212 MHz**, which is
  below A's 237.8 MHz. That number is an ESTIMATE and the measurement has not
  been run, but it is the single most consequential unmeasured quantity in this
  document. Section 6.1.

---

## 1. Method

### 1.1 The clock

MEASURED, `sim/ooc_sweep/results.csv`, identical netlist, derate applied after
synthesis so this is a pure voltage re-analysis of one netlist:

| `ROWS_IF` | DSP | LUT | period | VCCINT | WNS ns | Fmax MHz | on disk |
|---|---|---|---|---|---|---|---|
| 58 | 1,914 | 134,675 | 3.3 ns | 0.85 (default) | -0.210 | **284.90** | yes, line 9 |
| 58 | 1,914 | 134,675 | 3.3 ns | **0.717** | -0.905 | **237.812** | yes, line 7 |
| 48 | 1,584 | 112,712 | 3.3 ns | **0.717** | -0.935 | **236.128** | yes, line 8 |

**237.8 MHz is the primary figure** used throughout, since it is the only
at-voltage measurement of the design's largest block. Where a range is quoted
it is **236 to 241 MHz**, the spread of the four points in
`docs/debugging/2026-08-27_clock-at-the-real-voltage.md:38-41`.

**Caveat on that four-point table, recorded because it matters.** Only two of
its four rows are reproducible from the repo. `ROWS_IF = 48` (236.1) and 58
(237.8) are in `sim/ooc_sweep/results.csv` with matching timing reports
(`sim/ooc_sweep/timing_R48_v0.717.rpt`, `timing_R58_v0.717.rpt`). The rows for
`ROWS_IF = 32` (236.3) and 40 (240.6) are **not present in any file I could
find**. The flatness conclusion rests on all four; the 16.5% derate rests only
on the 58 pair, which is clean (same netlist, same 3.3 ns constraint, voltage
the only variable). See section 7 item 1.

**Every figure at 299.04 MHz is reported alongside**, so the delta is visible
without recomputation. The scale factor between them is **x1.25753**.

### 1.2 What scales with the core clock, and what does not

This is the whole reason the answer is not "multiply by 1.258", and it is the
first thing every re-derivation below has to establish.

| term | scales with `f_core`? | why |
|---|---|---|
| B state sweep, conv, silu, norms | **yes, fully** | pure cycle counts on the core clock, and B has feed margin at every clock (below) |
| C, all six rows | **yes, fully** | pure cycle counts; C is compute-bound, `docs/superpowers/specs/2026-08-20-int4-streaming-matvec-design.md:1987` |
| D-vec, D-ctrl | **yes, fully** | pure cycle counts |
| **A** | **NO** | array time scales, but A is clamped below by an HBM floor that does not |
| **E** | **almost not at all** | 128 PCIe collectives; only `t_tail` (320 core cycles) is on the core clock |

**The HBM clock is a different clock and it does not derate.** The 288.0 GB/s
device supply is `30 ports x 32 B x 300 MHz` MEASURED **on the card at
0.717 V** (`hw/fk33/results/hbmbw_30port_300mhz.txt`, via D skeleton `:371`;
the on-card pass at 0.717 V is
`docs/debugging/2026-08-25_voltage-derate-on-hardware.md:35-40`). HBM ACLK is
independent of the core clock (A spec `:1654`: "The HBM AXI clock (~450 MHz) is
not the core clock (~300 MHz)"). So when the core clock falls, **A's demand
falls and A's supply does not**.

At `ROWS_IF = 58`, demand is `58 x 18 B x f`:

| `f_core` | A demand | supply | fed? |
|---|---|---|---|
| 300.00 MHz | 313.2 GB/s | 288.0 | **no, -8.4%** |
| 299.04 MHz | 312.2 GB/s | 288.0 | **no, -8.4%** |
| 276.00 MHz | 288.1 GB/s | 288.0 | exactly balanced |
| **237.80 MHz** | **248.3 GB/s** | 288.0 | **yes, 13.8% spare** |

DERIVED. Consequence: the bandwidth-balanced `ROWS_IF` moves from 53.3 at
300 MHz to **67.3 at 237.8 MHz**. The undervolt did not merely cost clock; it
**dissolved F2 of the D skeleton** (`:41-47`, "weight prefetch does NOT close
at `ROWS_IF = 58`"). At the real clock it closes with 13.8% to spare.

### 1.3 The cost model, and its inputs

A, per D skeleton `:94`: `cycles_A(M, K) = ceil(M / ROWS_IF) x ceil(K / BLOCK)`
with `BLOCK = 32`. A's time is `max(array time, HBM floor)`, the same rule
D skeleton `:202` and the 9B envelope `:346-348` apply. The HBM floor is
`cycles x ROWS_IF x 18 B / 288.0 GB/s`, which is clock-invariant.

Shapes, 27B N=2 per card: D skeleton `:109` (key 1024, value 3072, FFN 8704,
hidden 5120, 24 value heads, 12 query heads, 2 KV heads, vocab shard 124,160).
Shapes, 9B N=1: `docs/2026-08-27_9b-single-card-resource-envelope.md:121-135`,
from `rtl/model_cfg_pkg.vhd:64-79` (hidden 4096, key 2048, value 4096, FFN
12288, 32 value heads, 16 query heads, 4 KV heads, vocab 248,320).

Anchor cycle counts, all verified and used unchanged:

| quantity | cycles | source |
|---|---|---|
| B state sweep, 9B N=1, `LANES=32` | **393,216** | `rtl/model_cfg_pkg.vhd:141-149`, pinned `sim/tb_model_cfg.vhd:53` |
| B state sweep, 27B N=2, `LANES=32` | **589,824** | same, pinned `sim/tb_model_cfg.vhd:36` |
| C KV sweep, 9B `MACS=128` ctx 2048 | **1,048,576** | 9B envelope `:274`; C skeleton `:521` gives the same number at 27B `MACS=192` |
| C total, 27B `MACS=192` | **1,310,400** | C skeleton `:527` |
| C total, 9B `MACS=128` | **1,217,484** | 9B envelope `:280` |
| A, 27B N=2, `ROWS_IF=58` | **6,954,528** | D skeleton `:201` |
| D-vec, 27B | **468,224** | D skeleton `:205` |

### 1.4 Validation of the method before any new number is used

The script was made to reproduce three published results it was not fitted to:

| check | this document | must match |
|---|---|---|
| 27B A per GDN block, `ROWS_IF=58` | 104,112 | D skeleton `:132` |
| 27B A per attention block | 100,912 | D skeleton `:174` |
| 27B lm_head | 342,560 | D skeleton `:187` |
| 27B A total per token | **6,954,528** | D skeleton `:201`, exact |
| 9B A total, `ROWS_IF=32`, at 254.32 MHz | 30.47 ms | 9B envelope `:326`, exact |
| 9B token total, `ROWS_IF=58`, at 254.32 MHz | 24.80 ms | 9B envelope `:330`, exact |
| 9B token total, `ROWS_IF=32`, at 254.32 MHz | 38.38 ms | 9B envelope `:326`, exact |

That agreement is the licence to trust the 237.8 MHz columns, which are the
same functions with a different divisor.

New DERIVED cycle counts this document adds, not previously published:

| quantity | cycles | arithmetic |
|---|---|---|
| A, 9B N=1, `ROWS_IF=58` | **4,293,888** | `24 x 118,272 + 8 x 113,408 + 548,096` |
| A, 9B N=1, `ROWS_IF=32` | **7,749,632** | `24 x 213,248 + 8 x 204,800 + 993,280` |
| D-vec, 9B N=1 | **230,400** | `32 x 7,168 + 1,024`; per block `1024 + 1024 + 1024 + 3072 + 1024` at `LANES_V = 8` |

The 9B `ROWS_IF = 58` A figure is confirmed independently: at 254.32 MHz it
gives 16.88 ms, which is the 9B envelope's own `:330` row.

---

## 2. The headline token-time table

### 2.1 Per subsystem, 27B N=2, `ROWS_IF = 58`, `MACS = 192`, `LANES = 32`, ctx 2048

| subsystem | cycles/token | ms @ **237.8 MHz** | ms @ 299.04 MHz | delta ms | delta % |
|---|---|---|---|---|---|
| **A**, array-limited | 6,954,528 | 29.25 | 23.26 | | |
| **A**, HBM floor (clock-invariant) | -- | 25.21 | 25.21 | | |
| **A = max of the two** | | **29.25** | **25.21** | **+4.04** | **+16.0%** |
| **B**, emit-bound (ESTIMATE) | 828,144 | **3.48** | 2.77 | +0.71 | +25.8% |
| B, state sweep only (floor) | 589,824 | 2.48 | 1.97 | +0.51 | +25.8% |
| B, fully serialized worst case | 1,725,216 | 7.25 | 5.77 | +1.49 | +25.8% |
| **C**, with group overlap | 1,310,400 | **5.51** | 4.38 | +1.13 | +25.8% |
| C, without group overlap | 1,388,544 | 5.84 | 4.64 | +1.20 | +25.8% |
| **D-vec** | 468,224 | **1.97** | 1.57 | +0.40 | +25.8% |
| **D-ctrl** | ~27,650 | **0.12** | 0.09 | +0.02 | +25.8% |
| **E**, D skeleton's own row | (179,968) | **0.64** | 0.60 | **+0.04** | **+5.8%** |
| **TOKEN, B at emit-bound** | | **40.97** | **34.62** | **+6.34** | **+18.3%** |
| token, B at sweep only | | 39.96 | 33.82 | +6.13 | +18.1% |
| token, B at worst case | | 44.74 | 37.62 | +7.11 | +18.9% |
| **tok/s** | | **24.4** | **28.9** | | **-15.5%** |

**A's row is the entire reason the token does not scale by 1.258.** Its
+16.0% is exact and it is the same at 9B: the ratio is
`(1/237.8e6) / (58 x 18 / 288.0e9)` = `1211.1 / 1044` = **1.1601**, with the
cycle count cancelling out. Any design that sits on the HBM floor at the target
clock loses exactly this much and no more.

**E's row scales by 5.8%, not 25.8%.** `T_coll = t_lat + S/BW_eff + t_tail`
(E skeleton `:243`). Only `t_tail` is core-clock work: 5,120 rows at
`LANES = 16` is 320 cycles, 1.070 us at 300 MHz and 1.346 us at 237.8 MHz
(E skeleton `:250`). Across 128 collectives that is **+0.035 ms**, not the
+0.155 ms a flat scaling would charge. DERIVED.

**E's own model disagrees with D's row and this document does not resolve it.**
D skeleton `:206` books E at 179,968 cycles = 0.60 ms. E skeleton `:261-269`
gives `T_token` between 0.73 and 5.64 ms depending on `BW_eff`, with 1.06 ms at
`BW_eff = 7.88 GB/s` (Gen4 x4, this box's chipset slots). D's own `:464` records
a third value, 0.42 ms, sourced to a line that does not exist in E. **Nothing in
E has been measured; no FK33 has ever enumerated on PCIe** (E skeleton `:243`,
`:249`). The table above uses D's 0.60 ms for like-for-like comparison; at E's
own middle case the token is 41.4 ms rather than 41.0.

### 2.2 Per subsystem, 9B N=1, `ROWS_IF = 58`, `MACS = 128`, `LANES = 32`, ctx 2048

| subsystem | cycles/token | ms @ **237.8 MHz** | ms @ 299.04 MHz | delta ms | delta % |
|---|---|---|---|---|---|
| **A**, array-limited | 4,293,888 | 18.06 | 14.36 | | |
| **A**, HBM floor (clock-invariant) | -- | 15.57 | 15.57 | | |
| **A = max of the two** | | **18.06** | **15.57** | **+2.49** | **+16.0%** |
| **B**, emit-bound (ESTIMATE) | 552,096 | **2.32** | 1.85 | +0.48 | +25.8% |
| B, state sweep only (floor) | 393,216 | 1.65 | 1.31 | +0.34 | +25.8% |
| **C**, `MACS = 128` | 1,217,484 | **5.12** | 4.07 | +1.05 | +25.8% |
| **D-vec** | 230,400 | **0.97** | 0.77 | +0.20 | +25.8% |
| **D-ctrl** | ~12,275 | **0.05** | 0.04 | +0.01 | +25.8% |
| **E** | 0 | **0** | 0 | 0 | -- |
| **TOKEN, B at emit-bound** | | **26.52** | **22.29** | **+4.22** | **+18.9%** |
| token, B at sweep only | | 25.85 | 21.76 | +4.09 | +18.8% |
| **tok/s** | | **37.7** | **44.9** | | **-15.9%** |

The `ROWS_IF = 32` fallback, for completeness (A = 7,749,632 cycles, never
HBM-bound at any clock):

| | ms @ **237.8 MHz** | ms @ 299.04 MHz | ms @ 254.32 MHz |
|---|---|---|---|
| A | 32.59 | 25.92 | 30.47 |
| **token** | **41.05** | 32.64 | 38.38 |
| tok/s | **24.4** | 30.6 | 26.1 |

**`ROWS_IF = 32` no longer meets 39 ms at the measured clock.** The 9B
envelope `:357` names it as "the minimum parallelism to hit 39 ms" at
254.32 MHz (38.38 ms). At 237.8 MHz it is **41.05 ms**. That recommendation
(9B envelope `:780-784`, "If it does not close, drop to `ROWS_IF = 32` without
further analysis") is now a fallback that misses the budget it was chosen for.
Since 39 ms is not a requirement (section 3), that is a re-labelling rather than
a failure, but the sentence as written is no longer true.

### 2.3 Serial versus overlapped, stated explicitly

**All totals above are SERIAL sums.** That is the correct model, not a
conservative one, and it comes from two independent normative statements:

- D O13 and A spec `:1993`'s premise: A, B and C are **never simultaneously
  active** but all three are resident, so their times ADD and their DSP costs
  ADD (A spec `:1974-1976`).
- D skeleton `:230-233`: "At batch 1 every post-collective operation is
  data-dependent on the collective. **The token is a chain.**"

What D does overlap is descriptor prefetch (free) and E's output stream into
the residual, and the second is recorded as **unsafe as specified** (D skeleton
hazard B7, `:649`). Nothing else overlaps. If B7 is resolved by dropping the
pipelining and landing in ER, D skeleton `:649` prices that at 655,360
cycles/token, which at 237.8 MHz is **2.76 ms**, not the 2.18 ms it states at
300 MHz.

Within B, the emit-bound row already assumes the state sweep, the nonlinear
bundle and the emit chain overlap as far as B's own analysis allows; that is
what makes 828,144 rather than 1,725,216 the working figure.

### 2.4 Assumptions carried into the headline numbers

Each of these moves the total and each is stated so it can be attacked.

1. **B's emit-chain cycle cost is an ESTIMATE, not a measurement.** The MEASURED
   figure is 17,253 cycles for 24 heads at a 1 ns testbench clock
   (`docs/debugging/2026-08-27_gdn-emit-chain-w-latch.md`, via D skeleton
   `:144-148`). The per-token figures 828,144 and 552,096 assume the cost is
   linear in heads with a zero intercept. DSP, LUT and Fmax were swept flat
   across HEADS 8/16/24/32 (`gdn-emit-chain-sizing.md:78-81`); the **cycle**
   count was measured only at 24. B is emit-bound in both configurations, so
   this term sets B's whole row.
2. **C assumes the group-overlap control exists.** C skeleton `:755` says it is
   "priced but not designed". Without it C is 1,388,544 cycles, +0.33 ms at
   237.8 MHz.
3. **ctx 2048 everywhere.** C's sweep is linear in context and C skeleton
   `:283-288` records that `MAXCTX` is pinned at 2,048 in every width in the C
   spec. Section 5.3 gives the context ladder.
4. **The 9B shapes could not be re-verified** (no 9B GGUF on this box, no
   network). Same limitation as 9B envelope `:800-807`.
5. **D-ctrl at 25 cycles/step**, midpoint of D skeleton `:207`'s 20-30, over
   1,106 steps (27B) and 491 steps (9B, no collective so 16-step GDN and
   13-step attention blocks). The 9B step count is DERIVED here and is not in
   any spec.
6. **Everything is out-of-context synthesis.** No two units have ever been
   synthesised together and no whole-die build exists at any scale.

---

## 3. The 39 ms reference: requirement or inherited assumption?

**Inherited assumption. It is an output of this project's own arithmetic, not
an input imposed on it, and its own author says so twice on the same page.**

Provenance, traced to the bottom:

| step | file and line | what it says |
|---|---|---|
| origin | `docs/superpowers/specs/2026-08-24-transformer-sequencer-design.md:816` | section heading: "**Timing budget (informative, derived -- nothing here is measured)**" |
| the sum | same, `:821-827` | five rows: A+C ~35.1, B ~2.0, E ~0.42, D-vec ~1.6, D-ctrl ~0.1 |
| the number | same, `:829` | "Roughly **~39 ms => ~26 tok/s at N=2**" |
| the disclaimer | same, `:833` | "This table exists so the whole-token sum finally includes the seams; **it is not a promise.**" |
| restated | `docs/superpowers/specs/2026-08-27-E-tp-collective-skeleton.md:255` | quotes it with the same caveat and adds that the real budget is "likely **larger** than 39 ms" |
| restated | `docs/2026-08-27_9b-single-card-resource-envelope.md:297` | "39 ms is used, and **it is the only sourced figure available**" |
| challenged | `docs/2026-08-27_direction-review-fable.md:250-257` | the tok/s ladder "has not been re-derived and is now misleading by ~2-3x" |

**There is no external requirement anywhere in the repo.** The only other
throughput figures are the recon's roadmap rows, and they are ceilings derived
from a refuted bandwidth:

- `docs/fpga-hardware-recon.md:32` "`v3.0` ... ~43-61 tok/s"
- `docs/fpga-hardware-recon.md:70-71` "7.57 GB per token; **at 460 GB/s** that
  is 16.5 ms, a 61 tok/s ceiling, and roughly 43 tok/s at 70% efficiency"

Both inputs to that are now refuted: the supply is **288.0 GB/s MEASURED**, not
460 (A spec `:1262-1269`), and the 70% efficiency derate "does not exist --
measured efficiency is 100.0% at every port count from 1 to 30" (A spec
`:1271-1272`). The correct HBM-bound ceiling at 27B N=2 is
`7.2605 GB / 288.0 GB/s` = **25.21 ms = 39.7 tok/s**, and that is a ceiling no
clock can beat, not a budget.

**The verdict against 39 ms, stated both ways so the reader can pick:**

- **As a number to hit:** 27B N=2 at 237.8 MHz lands at **41.0 ms**, so it
  misses by **2.0 ms, 5.1%**. With B at its sweep-only floor it lands at
  39.96 ms and misses by 2.5%. With B at its worst case it lands at 44.7 ms and
  misses by 15%. **The miss is inside the width of B's own unresolved range**,
  which spans 4.8 ms at this clock. Claiming either "meets" or "misses" is
  claiming more than the evidence supports.
- **As a reference at all:** it should be retired. It is a 27B N=2 figure whose
  largest term (A at ~30.5 ms) is disputed by 16% within the project's own
  documents (section 4), whose B term is a floor its author flagged as a floor,
  whose E term is cited from a line that does not exist, and whose derivation
  clock is 276-300 MHz. It is not wrong so much as it is not a measurement of
  anything. The replacement is the two tables in section 2, quoted in **cycles**
  with the clock named, which is the discipline B spec `:2605-2606` already
  demands of itself.

9B is a separate question the reference never addressed. 9B envelope `:856`
already lists "whether the 39 ms budget should apply to 9B at all" as open.

---

## 4. The A disagreement: how much of it was the clock

The task asked whether the 17-24% disagreement partly dissolves once the clocks
are normalised. **It does, but what dissolves is the range, not the gap.**

The three A figures, with the clock each was derived at:

| # | figure | value as published | clock it was derived at | source |
|---|---|---|---|---|
| A(i) | array-limited tile arithmetic | **23.18 ms** | **300 MHz** | D skeleton `:201` |
| A(ii) | feed-limited tile arithmetic | **25.21 ms** | 300 MHz nominally, but it is `7.2605 GB / 288.0 GB/s` and therefore **clock-invariant** | D skeleton `:202-203` |
| A(iii) | implied by D section 11 | **~30.5 ms** | **276 MHz** | D skeleton `:214`, subtracting C from A spec `:1999` |

A(iii)'s clock is the crux and it is not stated in the place the figure is
used. D section 11's header reads "at the section 15.4c 'balanced' point
(`ROWS_IF ~ 58`, C `MACS = 192`, **276-300 MHz**)"
(`2026-08-24-transformer-sequencer-design.md:818-819`). Its A+C row is sourced
to A spec 15.4c's balanced row, `2026-08-20-int4-streaming-matvec-design.md:1999`,
"**~58 | ~180 | ~2,590 | ~34 | ~17**". That table's own C anchor is stated at
276 MHz: `:1982-1984`, "201.3M per card = 11.4 ms at `MACS=64` and **276 MHz**",
and its A anchor likewise, "A's **31.7 ms** at `ROWS_IF=48`".

So A(iii) decomposes as `~34 ms` (276 MHz) minus C at `MACS = 180`
(`11.4 x 64/180` = 4.05 ms at 276 MHz) = **A ~= 29.9 ms at 276 MHz**. DERIVED.

**Normalising all three to one clock:**

| | at 276 MHz | at 300 MHz | at **237.8 MHz** |
|---|---|---|---|
| A(i) array-limited | 25.20 | 23.18 | 29.25 |
| A(ii) HBM floor | 25.21 | 25.21 | 25.21 |
| A(iii) D section 11 implied | 29.90 | 27.51 | 34.70 |
| **A(iii) over A(i)** | **+18.7%** | +18.7% | +18.7% |
| **A(iii) over A(ii)** | **+18.6%** | +9.1% | +37.6% |

**What the clock explains:** the published spread was "17 to 24%" because
A(iii) at 276 MHz was compared against A(i) and A(ii) at 300 MHz, and A(i) and
A(ii) diverge only because A(ii) does not scale. At a common 276 MHz -- which is
where A(iii) was actually derived -- the two comparisons **collapse onto each
other at 18.6-18.7%**, because 276 MHz is almost exactly the bandwidth-balanced
clock for `ROWS_IF = 58` (demand 288.1 GB/s against supply 288.0). Expressed as
D skeleton expresses it, as a fraction of the larger figure, that is **15.7%**,
against the published "17 to 24%".

**What the clock does not explain:** a residual ~19% on the largest term in the
token. **This document does not resolve it and does not pick a side.** Two
observations that narrow where to look, neither of them a resolution:

1. **A spec 15.4c does not decompose into its own stated components.** Its
   `ROWS_IF = 48` anchor, 31.7 ms at 276 MHz, is within 4.4% of the tile
   arithmetic (8,381,664 cycles = 30.37 ms at 276 MHz, DERIVED here), so the
   model and the spec agree at 48. At `ROWS_IF = 58` the same model gives
   6,954,528 cycles = 25.20 ms, but 15.4c's balanced row implies ~29.9. **The
   disagreement appears between 48 and 58 and not before**, which is where the
   spec stops printing per-term arithmetic. D skeleton `:714-722` says the same
   thing from the other direction: "a two-variable optimisation whose per-term
   breakdown is not printed anywhere".
2. **A(ii) is not an estimate and cannot be argued down.** 25.21 ms is
   `7.2605 GB / 288.0 GB/s` with both inputs MEASURED (the byte count from A's
   own tile geometry, the bandwidth from the card). Whatever A's real time is,
   it is at least 25.21 ms at 27B N=2 and at least 15.57 ms at 9B N=1, at every
   clock. That is the one A number in this project that no re-derivation moves.

**Carried forward:** section 2's tables use A(i)/A(ii). If A(iii) is right the
27B token at 237.8 MHz is **46.4 ms, 21.5 tok/s** rather than 41.0 ms and
24.4 tok/s. The 9B side has no A(iii) equivalent -- A spec 15.4c was never
evaluated at 9B shapes -- so the 9B numbers carry only this one model.

---

## 5. What the shortfall costs, as a user would feel it

### 5.1 Tokens per second

| configuration | tok/s @ **237.8 MHz** | tok/s @ 299.04 MHz | loss |
|---|---|---|---|
| **9B N=1**, `ROWS_IF=58`, `MACS=128` | **37.7** | 44.9 | **-7.2 tok/s, -15.9%** |
| 9B N=1, `ROWS_IF=32` fallback | 24.4 | 30.6 | -6.2, -20.3% |
| **27B N=2**, `ROWS_IF=58`, `MACS=192` | **24.4** | 28.9 | **-4.5 tok/s, -15.5%** |
| 27B N=2, with A(iii) instead of A(i) | 21.5 | 26.7 | -5.2, -19.4% |
| 27B N=2, B at its worst case | 22.4 | 26.6 | -4.2, -15.8% |

**The throughput loss is 15.5-16%, not 20.5%.** The clock fell 20.5% and the
token grew 18%, so tok/s fell 15.5%. The gap between 20.5 and 15.5 is entirely
A's HBM floor and E's PCIe floor.

For context, and because the project's stated comparison point is the
workstation: `docs/fpga-hardware-recon.md:74` gives **70 tok/s** for
Qwen3.8-27B on 2x RTX 3090. At 24.4 tok/s the 27B FK33 pair is a **2.9x
slowdown**, where the recon roadmap's "43-61 tok/s" implied 1.1-1.6x. The
direction review already said this (`:250-257`, "v3.0 is a ~3x slowdown, not
the ~1x the ladder implies") and estimated 20-22 tok/s by applying a bounded
derate; this document reaches **21.5-24.4** by deriving it, which is consistent
and slightly better than the estimate.

**The recon's roadmap rows at `:32` and `:33` are the figures a reader will
quote and they are the most wrong numbers in the project.** `v3.0 ~43-61 tok/s`
should read **~22-24 tok/s**. `v4.0 ~140-170 tok/s` rests on the same 460 GB/s
and 70% inputs and has not been re-derived here.

### 5.2 Where the lost milliseconds went, 27B N=2

Of the +6.34 ms the clock costs:

| term | ms lost | share of the loss |
|---|---|---|
| A | +4.04 | 63.7% |
| C | +1.13 | 17.8% |
| B (emit-bound) | +0.71 | 11.2% |
| D-vec | +0.40 | 6.3% |
| D-ctrl | +0.02 | 0.3% |
| E | +0.04 | 0.6% |

**A is still where the clock hurts most, but it is where it hurts least per
cycle.** A gives up 16% where everything else gives up 25.8%.

### 5.3 Context, re-derived at the measured clock

C's sweep is linear in context and it is the only term that is. At 9B N=1,
`MACS = 128`, with everything else held at section 2.2:

| ctx | C ms @237.8 | token ms @237.8 | token ms @299.04 |
|---|---|---|---|
| 2,048 | 5.12 | 26.52 | 22.29 |
| 4,096 | 9.53 | 30.93 | 25.80 |
| **8,192** | 18.35 | **39.75** | **32.81** |
| 16,384 | 35.99 | 57.39 | 46.84 |
| 32,768 | 71.27 | 92.67 | 74.89 |

DERIVED, by scaling the KV-sweep row (1,048,576 cycles at ctx 2048) linearly
and holding the other five C rows fixed, the same construction as 9B envelope
`:638-646`. **The context that fits inside 39 ms falls from "between 4,096 and
8,192" (9B envelope `:648`, at 254.32 MHz) to just under 8,192 at 237.8 MHz.**
That conclusion survives the clock change almost unchanged, which is worth
saying because it was the one place the 9B envelope's context finding could
have moved.

Everything above ctx 2,048 is arithmetic on a design that has not been
dimensioned for it (C skeleton `:283-288`).

---

## 6. What would buy the clock back, ranked by evidence

Ranked by how much MEASURED evidence supports the lever, not by how plausible it
sounds. Every item states what is measured and what is assumed.

### 6.1 Rank 1 -- MEASURE B's emit chain at 0.717 V, before anything else

**Evidence: strong, and it is the only item here that could make the whole
section moot.** This is not a lever that buys clock; it is the measurement that
decides whether 237.8 MHz is even the right number to have re-derived against.

MEASURED, `gdn_emit_chain` at `HEADS=24 DIM=128 SILU_LANES=16 RMS_LANES=4`:

| | Fmax | source |
|---|---|---|
| synthesis, 0.85 V | **300.75 MHz** | B spec `:2342`, `gdn-emit-chain-sizing.md:55` |
| **post-route, 0.85 V** | **254.32 MHz** | B spec `:2342`, `sim/ooc_micro/pnr_results.csv:12` |
| post-route, **0.717 V** | **never taken** | -- |

Applying the 16.5% derate MEASURED on `matvec_core` gives **~212 MHz**
(ESTIMATE, and the transfer of one unit's derate to another is exactly the
assumption `docs/debugging/2026-08-25_voltage-derate-on-hardware.md:210-215`
warns against: "whether the derate is path-type dependent ... not established
either way"). If it holds, **B, not A, sets the die clock, and every number in
section 2 is 12% optimistic.**

Two facts make the estimate more credible than a bare extrapolation:

- The binding path is `u_rms/ARG__21/DSP_A_B_DATA_INST/CLK ->
  u_rms/mr_m_reg[60]/D` at **84.9% logic** in synthesis
  (`gdn-emit-chain-sizing.md:99-106`). Logic delay is what voltage derates.
  `matvec_core`'s -22.9% figure also came from "DSP and carry-chain-heavy"
  logic (`voltage-derate-on-hardware.md:212-214`). Same path class.
- Post-route the same path flips to **33.2% logic / 66.8% route** (B spec
  `:2343`). Route delay derates less. So the true post-route derate is probably
  smaller than 16.5% -- which argues 212 MHz is pessimistic, not that it is
  wrong.

**Cost: one OOC re-analysis at `set_operating_conditions -voltage {VCCINT
0.717}` on an existing netlist.** No new build. `sim/ooc_core_sweep.tcl`
already carries the `volt=` argument for exactly this, and
`clock-at-the-real-voltage.md:96-99` records that it was not used for the
figures the budgets were built on.

**Caveat that could block it outright:** the 0.72 V timing library **crashes on
any HBM-facing design** (`voltage-derate-on-hardware.md:47-56`, an internal
delay-calculator exception). `gdn_emit_chain` is OOC with no hard IP, so it
should work; a whole-die re-analysis will not.

### 6.2 Rank 2 -- Split the `rmsnorm_bf` DSP-to-`mr_m` path

**Evidence: strong on where the path is, none on what a split would win.**

MEASURED: the bound is inside `rmsnorm_bf`'s mantissa path and it is
**independent of `SILU_LANES`, `RMS_LANES` and `HEADS`** -- Fmax is identical to
14 significant figures (300.75187969924815 MHz) across HEADS 8, 16, 24 and 32
(`gdn-emit-chain-sizing.md:78-81`, `:107-110`). That is the strongest evidence
in this list that a specific, named, single path is the constraint.

`gdn-emit-chain-sizing.md:113-115` states the consequence directly: "Any further
headroom has to come from splitting that DSP-to-`mr_m` path, not from resizing
anything measured here."

**What is not evidence:** nobody has tried it, and this project has a recorded
history of confident pipeline predictions failing. B spec `:2622` and C spec
`:1574-1576`: `MREG` "was confidently predicted to be the fix" and was worth
26 MHz of 183, and a version written to the MREG cadence measured **117.2 MHz,
worse than the original 138.4**. Treat any predicted gain as unknown until
measured.

### 6.3 Rank 3 -- Take the 5 to 9 rows that the HBM floor now makes free

**Evidence: strong, and it is arithmetic rather than a bet.**

At 237.8 MHz the bandwidth-balanced `ROWS_IF` is **67.3**, not 53.3 (section
1.2). `ROWS_IF = 58` sits 13.8% inside the supply. Rows are the one lever that
converts DSP directly into A time with no timing term, because
**Fmax is MEASURED flat in `ROWS_IF`**: 236.3 / 240.6 / 236.1 / 237.8 MHz across
a 1.8x array-size change (`clock-at-the-real-voltage.md:38-41`).

| `ROWS_IF` | A DSP | A cycles (27B) | A ms @237.8 | demand | fed? |
|---|---|---|---|---|---|
| 58 | 1,914 | 6,954,528 | 29.25 | 248.3 | yes |
| 62 | 2,046 | 6,509,536 | 27.37 | 265.4 | yes |
| 66 | 2,178 | 6,106,176 | 25.68 | 282.5 | yes, 1.9% spare |
| 67 | 2,211 | 6,016,704 | 25.30 | 286.8 | yes, 0.4% spare |

DERIVED. Going from 58 to 66 buys **3.57 ms of a 41.0 ms token, 8.7%**, for
264 DSP. That takes the 27B die from 2,600 to 2,864 of 2,880 = **99.4%**, which
is not affordable. At 9B, where the die is at 2,472 of 2,880, going to 66 buys
2.09 ms for 264 DSP and lands at **2,736 = 95.0%**, which is also almost
certainly not affordable.

**So the honest form of this item is: the rows are free in bandwidth and not
free in DSP, and DSP is the binding resource.** It is ranked third because the
arithmetic is certain and the resource verdict is negative. It becomes real only
at N=4, where per-card A work halves.

**Also note the parity constraint, which rules out several of these points.**
D skeleton `:513-520`: `NPORTS_W = ROWS_IF x 128 / 256` must be an integer, so
legal `ROWS_IF` values are **even**. 67 is not legal; 66 is.

### 6.4 Rank 4 -- Raise VCCINT above 0.717 V

**Evidence: the sensitivity is measured; the headroom is measured to be
absent.**

The sensitivity is the strongest number in this document: 0.85 V to 0.717 V is
-16.5% of Fmax on one netlist, so roughly **0.35 MHz per mV** in that range
(DERIVED, and non-linear, so do not extrapolate far).

The headroom is not there. `docs/debugging/2026-08-24_fk33-sysmon-vccint-
undervolt.md` and the commit history record the card powering up at 0.678 V
against a 0.698 V floor, raised by hand to 0.717 V, with the recent commits
`f7dc122` ("settled at wiper 68 / 0.717 V, SQRL's 0.85 V claim refuted by
measurement") and `7db7ff4` ("VCCINT raised 0.678 -> 0.706 V, in spec, alarm
cleared"). 0.717 V is 19 mV above the alarm floor and it is where the regulator
was left after the claim of 0.85 V was refuted by measurement.

`docs/2026-08-27_direction-review-fable.md:250-257` (section 4 item 1) adds the
reason not to push it: nobody has estimated what ~2,600 active DSPs plus ~282K
LUT plus 30 HBM ports draw on a rail rated 0.85 V at 120 A, and the INFERRED
50-80 W is 70-110 A at 0.717 V, the same order as the rating. **Raising the
voltage raises the current draw on a rail already near its rating, and droop
under the real engine would make the derate worse non-linearly.** This is
ranked fourth because the lever exists and is measured but the operating point
is not negotiable and the risk is documented.

### 6.5 Rank 5 -- Establish what the 0.717 V critical path actually is

**Evidence: one negative result only.**

`clock-at-the-real-voltage.md:102-104` states it plainly: the flatness across
`ROWS_IF` rules out the array **and nothing else**. Nobody has read the failing
path out of `timing_R58_v0.717.rpt`, which is on disk. Until that is done, every
proposal to buy clock back inside A is aimed at an unknown target.

**Cost: reading a file that already exists.** It is ranked fifth rather than
first only because rank 1 may make A's clock irrelevant.

### 6.6 Explicitly NOT proposed

- **Reducing `ROWS_IF`.** MEASURED not to help:
  `clock-at-the-real-voltage.md:80-82`, 32 versus 58 is **858 fewer DSP for
  1.5 MHz**. Do not retry.
- **Quoting `ROWS_IF = 32` at 275.3 MHz.** `clock-at-the-real-voltage.md:83-85`
  withdraws it. But see section 7 item 1: the replacement measurement is not on
  disk, and the two runs it compares differ in constraint period (3.333 ns
  versus 3.3 ns) as well as voltage.
- **Raising HBM ACLK to 450 MHz to un-feed-bind A.** Now moot at the measured
  clock -- A is fed with 13.8% spare at 237.8 MHz. D skeleton `:724-726` records
  that nobody has attempted 450 MHz and that 350 MHz misses by 0.395-0.467 ns.
  The entire section 3.3 fork of the D skeleton is dissolved by the undervolt
  rather than solved by it.

---

## 7. Per-document list of every figure that is now wrong

**Do not apply these here. This is the list; another pass applies it.**

The mechanical rule for the bulk: **a figure stated as `cycles / f` at 300 MHz
is multiplied by 1.26156; at 299.04 MHz by 1.25753; at 302.5 MHz by 1.27208; at
305.6 MHz by 1.28511; at 254.32 MHz by 1.06947; at 231 MHz by 0.97140.** The
two exceptions where the rule does NOT apply are A's HBM floor and E's PCIe
terms, both flagged individually below.

**Count: 96 figures across 7 files.** Broken down as 63 mechanical ms
conversions, 17 "closes at N MHz" verdicts that change side, 9 bandwidth or
feed-bound verdicts, and 7 tok/s or budget-fraction statements.

**Line numbers are as the files stand today** and were each re-read before
being quoted. Note that other documents' citations into the B spec have drifted:
the 9B envelope `:880` names line 1820 for the "nonlinear + conv = 342,144" row,
which today is at **1941**. Verify by quoted text, not by line number alone.

### 7.1 `docs/superpowers/specs/2026-08-21-gated-deltanet-design.md` (B) -- 41 figures

Time figures. All are `cycles / f`; the cycle count is the invariant and is
unchanged.

| line | says | at | should say at 237.8 MHz |
|---|---|---|---|
| 1230 | norm term 2.48 ms | 300 | **3.125 ms** |
| 1230-1231 | "3.22 ms at the 231 MHz this card reaches at 0.717 V" | 231 | **3.125 ms at the MEASURED 237.8 MHz**; the 231 MHz itself is superseded, it came from the -22.9% derate that `voltage-derate-on-hardware.md` refuted as a die constant |
| 1231, 1249-1251 | "the 231 MHz this card reaches at 0.717 V"; "-22.9% VCCINT derate" | -- | **237.8 MHz MEASURED**; the -22.9% is superseded by a direct -16.5% measurement on the same unit class |
| 1232 | silu 0.74 ms / 2.2 ms | 300 | **0.934 / 2.775 ms** |
| 1242-1243 | 495,360 cycles = 1.65 ms | 300 | **2.083 ms** |
| 1245 | 743,040 cycles = 2.48 ms | 300 | **3.125 ms** |
| 1254-1255 | "derate no worse than -15.8%, i.e. >= 252.6 MHz" | -- | still a valid bound for **that** design (the HBM test bitstream); it is not this unit's number, and `matvec_core` measures -16.5%, outside the bound. Both stand; they measure different things |
| 1259-1260 | "the real figure is between 2.48 and 2.94 ms" | 300-252.6 | **3.125 ms**, above the top of that range |
| 1263 | serialized worst case ~7.5-8.5 ms | mixed | **9.5-10.7 ms** |
| 1265 | "the target is ~3.5-4.5 ms/token" | mixed | **4.4-5.7 ms** |
| 1267 | "A at 35-53 ms and C at ~4-4.4 ms" | mixed | superseded entirely; A is 29.25 ms and C 5.51 ms (27B, section 2.1) |
| 1268 | "`v3.0` at ~16-23 tok/s" | -- | **21.5-25.0 tok/s** (section 5.1) |
| 1450 | 0.74 ms; 0.49 ms at 300 | 300 | 0.934; **0.618 ms** |
| 1535-1536 | "~0.49 ms/token" at LANES=32 | 300 | **0.618 ms** |
| 1760 | LANES 8 sweep 7.86 ms | 300 | **9.921 ms** |
| 1761 | LANES 16 sweep 3.93 ms | 300 | **4.961 ms** |
| **1762** | **LANES 32 sweep 1.97 ms** | 300 | **2.480 ms** |
| 1763 | LANES 64 sweep 0.98 ms | 300 | **1.240 ms** |
| 1793 | "38.4 GB/s at LANES=32 and 300 MHz" | 300 | **30.4 GB/s**; the +23% port margin becomes **+55%** |
| 1816-1821 | port table margins +23% / +7% | 300 | **+55% / +23%**; B's 4-port allocation gains headroom |
| 1827 | "the traffic is 1.97 ms and co-limiting" | 300 | the traffic time is set by the 47.1 GB/s port supply and is **clock-invariant at 1.60 ms**; the sweep moves to 2.480 ms, so B becomes **more** compute-bound, not co-limited |
| 1838 | sweep 589,824 = 1.97 ms | 300 | **2.480 ms** |
| 1839 | rmsnorm 743,040 = 2.48 ms | 300 | **3.125 ms** |
| 1840 | L2 495,360 = 1.65 ms | 300 | **2.083 ms** |
| 1845 | silu 1,179,648 = 3.93 ms | 300 | **4.961 ms** |
| 1846 | serial total 3,007,872 = 10.03 ms | 300 | **12.649 ms** |
| 1857-1858 | perfect schedule 8.06 ms | 300 | **10.17 ms** |
| 1909-1912 | rmsnorm forms 4.13 / 1.12 / 0.71 / 0.51 ms | 300 | **5.208 / 1.413 / 0.896 / 0.638 ms** |
| 1919-1921 | 4.62 / 1.55 / 1.14 ms | 300 | **5.829 / 1.956 / 1.439 ms** |
| 1927 | softmax cone 3.93 ms | 300 | **4.961 ms** |
| 1937-1942 | the whole overlapped table: 1.97 / 0.71 / 0.33 / 0.06 / 1.14 / **~1.97** | 300 | **2.480 / 0.896 / 0.413 / 0.077 / 1.439 / 2.480** |
| **1941** | nonlinear+conv = 342,144 | -- | **329,808 cycles = 1.387 ms** (the 342,144 uses the conv figure struck through at `:1940`; this is the 9B envelope `:880`'s correction, independent of the clock) |
| 2020-2021 | "B lands at ~2.0 ms/token" | 300 | **~2.5 ms/token** |
| 2102-2103 | 1,367,424 = 4.56 ms | 300 | **5.750 ms** |
| 2185-2186 | serial worst case 10.09 ms | 300 | **12.73 ms** |
| 2187 | "superseded downward to ~2.0 ms" | 300 | **~2.5 ms** |
| 2405 | 401,664 cycles = 1.34 ms | 300 | **1.689 ms** |
| 2496-2502 | `gdn_recur` sequential table, 43.3 / 32.9 / **28.5 ms** | 300 | **54.6 / 41.5 / 35.96 ms** (unit superseded, but the table is still printed) |
| 2535-2536 | LANES 64 = 0.98 ms | 300 | **1.240 ms** |
| 2557 | "589,824 cycles = 1.95 ms at 302.5 MHz" | 302.5 | **2.480 ms** |
| **2596-2597** | "1.97 ms at the 299.04 MHz measured here" | 299.04 | **2.480 ms** |
| 2904-2905 | 182,336 cycles = 0.61 ms | 300 | **0.767 ms** |
| 3032-3034 | conv table 0.83 / 0.42 / 0.21 ms | 300 | **1.044 / 0.528 / 0.270 ms** |
| 3142-3143 | "B's token time scales by 300/278.9 = 1.076 and ~2.0 becomes ~2.1 ms" | 300 | the scaling base is now 237.8; the sentence's logic survives, its arithmetic does not |

Clock verdicts that change side. **All of these compare a 0.85 V synthesis Fmax
against a 0.85 V-era target of 299.04 MHz. The correct comparison is a
0.717 V Fmax against 237.8 MHz, and no unit below has a 0.717 V number.** The
verdicts flip only if the derate is uniform, which is unproven -- so each should
be restated as conditional, not simply reversed.

| line | says | new status |
|---|---|---|
| 2034-2036 | `l2norm_rs` LANES=4 at 285.8 MHz "does not close B's 299.04 MHz clock"; closing point forced to LANES=2 at 185 cycles | 285.8 x 0.835 = **238.6 MHz**, which clears 237.8 by 0.8 MHz. **The LANES=4 rejection is no longer safe either way**; it needs a 0.717 V measurement, not a re-comparison |
| 2277 | `SILU_LANES=8` at "295.8 -- misses 299.04" | 295.8 x 0.835 = **247.0 MHz**, clears 237.8. The 32-DSP saving that was rejected on timing may be available. Conditional on measurement |
| 2967-2969 | same finding restated, closing point "16 lanes = 32 DSP" | same |
| 2902-2903 | `rmsnorm_rs` at N=256 LANES=4, 281.8 MHz, "misses both C's 300 MHz target and B's 299.04 MHz" | 281.8 x 0.835 = **235.3 MHz**, which **misses 237.8**. This one does NOT flip |
| 3122-3125, 3137-3140 | `micro_rmsn_lanes` 278.9 MHz at 1/2/4 lanes, 200.9 at 8; "none of these forms reaches 300 MHz" | 278.9 x 0.835 = **232.9 MHz**, misses 237.8. Does NOT flip |
| 2339-2346 | `gdn_emit_chain` 300.75 synth / **254.32 post-route**; "a 15% miss" against 299.04 | at 0.717 V the estimate is **~212 MHz post-route, a 11% miss against 237.8**. Section 6.1 |
| 2932-2941 | "A is feed-bound by 8.75%"; "balanced point 53.3, so 53" | at 237.8 MHz A is **fed with 13.8% spare** and the balanced point is **67.3**. This paragraph inverts |
| 2947-2949 | "`ROWS_IF = 52` demands 280.8 GB/s and fits" | at 237.8 MHz, `ROWS_IF = 66` demands 282.6 GB/s and fits |
| 2960-2961 | "the HBM ACLK must reach 450 MHz, at which point 58 fits with 27% margin" | moot at the measured clock |

### 7.2 `docs/superpowers/specs/2026-08-21-gated-attention-design.md` (C) -- 15 figures

C already carries a two-column form (`:866-868`, "times are given at both
300 MHz (0.85 V analysis) and 231 MHz (0.717 V as the card runs, the measured
-22.9% mean derate)"). **The second column's clock is wrong**: 231 MHz came
from the derate that `voltage-derate-on-hardware.md` refuted as a die constant.
The measured figure is 237.8 MHz, so **every entry in that column is multiplied
by 0.97140**.

| line | says (300 / 231) | should say (300 / **237.8**) |
|---|---|---|
| 1318 | KV sweep 1,048,576 cyc, 3.50 / **4.54** | 3.50 / **4.409** |
| 1319 | rescale ~12K, 0.04 / **0.05**; worst +524K = 1.75 / **2.27** | 0.04 / **0.049**; 1.75 / **2.204** |
| 1320 | QK-norm 166K, 0.55 / **0.72**; fallback 290K = 0.97 / **1.26** | 0.55 / **0.698**; 0.97 / **1.220**. Note the 166K is separately superseded by C skeleton `:557`'s 104,192 |
| 1321 | IMROPE 8K, 0.03 / **0.03** | 0.03 / **0.034** |
| 1322 | KV quantize 34K, 0.11 / **0.15** | 0.11 / **0.143** |
| 1323 | gate+output 107K, 0.36 / **0.46** | 0.36 / **0.451** |
| **1324** | **C total ~1.38M, ~4.59 / ~5.95** | **~4.59 / ~5.78** by the column rule, or **5.80** from the row's own ~1.38M cycles; and with the C skeleton `:527`'s corrected 1,310,400 cycles, **4.37 / 5.511** |
| 866-868 | "231 MHz (0.717 V as the card runs, the measured -22.9% mean derate)" | **237.8 MHz MEASURED at 0.717 V**; -22.9% is superseded |
| 1106 | "all synthesis at 3.333 ns on the real part, restated at 0.717 V" | the restatement rule is right and the constant it uses is wrong |
| 282 | `MACS=192` reaches 3.49 ms; `MACS=384` 1.75 ms | **4.403 / 2.208 ms** |
| 888-889 | `MACS = 96` sweep 6.98 ms at 300 MHz | **8.807 ms** |
| 901 | `MACS = 192` sweep 3.50 ms at 300 MHz | **4.415 ms** |
| 1069-1073 | sigmoid cone ~0.16 ms/token instead of ~3 ms | **0.202 ms** |
| 1380 | 182,336 cycles = 0.61 ms at 300 MHz | **0.767 ms** |
| 1626 | "the serial fallback costs +0.42 ms at 300 MHz" | **+0.530 ms** |
| 1528-1531 | acceptance gate "routed Fmax >= 300 MHz at the 0.85 V analysis, restated at 0.717 V" | the gate should be **routed Fmax >= 237.8 MHz measured at 0.717 V**. A gate expressed at a voltage the card does not run at is the exact failure this whole exercise is about |

### 7.3 `docs/superpowers/specs/2026-08-20-int4-streaming-matvec-design.md` (A) -- 11 figures

| line | says | should say |
|---|---|---|
| 1979 | B "~4 ms, context-independent" | **~2.5 to 3.5 ms** at 237.8 MHz (section 2.1) |
| 1980, 1982-1984 | C "11.4 ms at `MACS=64` and 276 MHz" | at `MACS=192` and 237.8 MHz, **5.51 ms**. The 11.4 is a `MACS=64` figure still being quoted next to a `MACS=180` recommendation |
| 1984-1985 | "36% on top of A's 31.7 ms at `ROWS_IF=48`" | A at `ROWS_IF=48` and 237.8 MHz is **35.25 ms** (8,381,664 cycles), and C is 15.6% on top, not 36% |
| 1998-2000 | the balanced table: A-maximal ~36, **balanced ~34**, baseline ~47 ms at N=2 | at 237.8 MHz the balanced row is **41.0 ms** by the tile model, or **46.4 ms** if 15.4c's own A term is right. The 17 ms N=4 column becomes **~21 ms**. See section 4: this table is the origin of the disputed A(iii) |
| 2007 | "~29 tok/s at N=2 and ~58 at N=4" | **~24.4 at N=2**, and N=4 not re-derived here |
| 1697-1698 | port tables at 276 / 288 MHz | superseded twice: by D skeleton `:396-403`'s 9.6 GB/s per port, and now by the clock. At 237.8 MHz, `ROWS_IF=58` wants 236.0 GB/s of weights and 29.5 of scales -- 28 ports at 1.0x, 36 at the spec's 1.3x, against 30 available. **The port count still does not close**, which is the one A verdict the lower clock does NOT fix |
| 1706-1710 | "at 66% this configuration would run about 21 tok/s" | the 66% DDR figure does not apply; HBM measures 100.0% |
| 1750 | "`v4.0`'s 91 tok/s becomes roughly 50-61 tok/s" | single-card 9B is **37.7 tok/s** (section 5.1); the 27B `v4.0` row is not re-derived here |
| 1774-1782 | the voltage table: 0.850 V = 276.1, 0.720 V = 230.1 MHz, "the low-power point costs 17% of Fmax" | these are **pre-reclaim `ROWS_IF=48`** figures. The post-reclaim `ROWS_IF=48` measurement is 236.1 MHz at 0.717 V (`results.csv:8`). The 17% is close to the 16.5% now measured at `ROWS_IF=58`, so this row is the one A figure that **holds up** |
| 1781-1782 | "roughly 26 tok/s against 31.5 at N=2" | **24.4 against 28.9** (section 5.1) |
| 1279-1283 | "memory-bound at 300 MHz by 1.5x"; "balance needs `ROWS_IF ~ 53`" | at 237.8 MHz it is **not** memory-bound, and balance is at 67.3 |

### 7.4 `docs/superpowers/specs/2026-08-27-D-sequencer-skeleton.md` -- 12 figures

| line | says | should say |
|---|---|---|
| 199-208 | the whole token table at 300 MHz: A 23.18 / 25.21, C 4.59, B 1.97-5.75, D-vec 1.56, D-ctrl 0.07-0.11, total **34.00-37.82** | at 237.8 MHz: A **29.25** (the feed-limited row **becomes 25.21 and is no longer binding**), C **5.51**, B **2.48-7.25**, D-vec **1.97**, D-ctrl **0.09-0.14**, E **0.64**, total **39.97-44.74** |
| **202** | "A, feed-limited 7,563,049 cycles, 25.21 ms, x1.0875" | **the multiplier is 1.0 at 237.8 MHz.** 25.21 ms survives as the clock-invariant HBM floor, but it stops being the binding term |
| 204 | B "1.97 to 5.75 ms" | **2.48 to 7.25 ms** |
| 205 | D-vec 468,224 = 1.56 ms | **1.969 ms** |
| 206 | E 179,968 = 0.60 ms | **0.635 ms** -- and only 0.035 of that is the clock, see section 2.1 |
| 207 | D-ctrl 0.07-0.11 ms | **0.09-0.14 ms** |
| 210-218 | "Against the project's ~39 ms reference ... a 17 to 24% disagreement" | the range is **~16% at a common clock**; see section 4. Add that D section 11's A term is derived at 276 MHz and this table's at 300 MHz |
| 220-224 | "1.97 ms checks out at both clocks quoted in B's own document" | **2.480 ms**, and the coincidence-of-rounding observation is still the right lesson |
| 41-47 (F2) | "weight prefetch does NOT close at `ROWS_IF = 58`; A is feed-bound by 8.75%" | **it closes at 237.8 MHz with 13.8% spare.** F2 is dissolved by the undervolt |
| 372-376 | demand 313.2 GB/s, shortfall 1.0875, balanced 53.3 | **248.3 GB/s, no shortfall, balanced 67.3** |
| 396-403 | the port table at 300 MHz: `ROWS_IF=58` wants 43 of 30 at 1.3x | at 237.8 MHz it wants **36 of 30 at 1.3x, 28 of 30 at 1.0x**. Still does not close. Section 7.3 |
| 649 (B7) | "pay ~5,120 cycles per collective = 655,360 cycles/token = 2.18 ms, which is 6% of the token" | **2.756 ms, 6.7% of the token** |
| 439-443 | grant-switch cost "~3,200 cycles, 0.03% of the token" / "~65,000 cycles, 0.6%" | cycle counts unchanged; as ms they are 0.013 and 0.273 at 237.8 MHz, and the percentages are 0.03% and 0.67% |

### 7.5 `docs/superpowers/specs/2026-08-24-transformer-sequencer-design.md` -- 6 figures

| line | says | should say |
|---|---|---|
| 818-819 | budget header "at the 15.4c balanced point ... 276-300 MHz" | the operating clock is **237.8 MHz MEASURED**; the 276-300 band is a 0.85 V band |
| 821 | "A jobs + C ~34 -> ~35.1 ms" | see section 4. At 237.8 MHz the tile model gives A+C = **34.76 ms**, and 15.4c's own A term gives **40.21 ms**. Open |
| 821 | "~4.59 ms at 300 MHz / ~5.95 ms at the 231 MHz the card reaches at 0.717 V" | **4.37 ms at 300 MHz** (C skeleton `:527`'s corrected cycles) and **5.51 ms at the measured 237.8 MHz** |
| 823 | B "~2.0 ms" | **~2.5 to 3.5 ms** |
| 824 | E "~0.42 ms" | E's own document gives 0.60 (D skeleton `:206`) or 0.73-5.64 (E skeleton `:261-269`); 0.42 has no source. Unrelated to the clock, but it is in the same sum |
| 825 | D-vec "~1.6 ms" | **1.97 ms** |
| **829** | **"Roughly ~39 ms => ~26 tok/s at N=2"** | **~41.0 ms => ~24.4 tok/s** by the tile model, **~46.4 ms => ~21.5 tok/s** by this table's own A term. And it should stop being quoted as a budget; see section 3 |

### 7.6 `docs/superpowers/specs/2026-08-27-C-gated-attention-skeleton.md` -- 5 figures

| line | says | should say |
|---|---|---|
| 521-529 | the six-row table with columns "ms @300" and "ms @299.04", total **4.368 / 4.382** | add a **ms @237.8** column: rows 4.409 / 0.041 / 0.438 / 0.034 / 0.138 / 0.451, total **5.511** |
| 558 | "C's total is 1,388,544 cycles = 4.643 ms @299.04" | **5.839 ms @237.8** |
| 411 | "C's clock target is 300 MHz at the 0.85 V analysis and the die's shared achieved clock is B's 299.04 MHz. A unit that misses the clock is not a budget option" | the shared clock is now **237.8 MHz at 0.717 V**, or lower if section 6.1's estimate holds. The sentence's logic is right and its constant is wrong -- and the `LANES = 4` rejection it justifies is re-opened (section 7.1) |
| 459-460 | "96 ... doubles the sweep from 3.51 to 7.01 ms at 299.04 MHz, which is +3.5 ms on a ~4.4 ms subsystem" | **4.41 to 8.82 ms, +4.4 ms on a ~5.5 ms subsystem** |
| 470-476 | the rescale-array table's "extra ms @299.04" column: 0.033 / 0.065 / 0.130 / 0.260 / 0.781 | **0.041 / 0.082 / 0.163 / 0.327 / 0.982** |
| 755 | "4.382 to 4.643 ms at 299.04 MHz. That is a 6% cost" | **5.511 to 5.839 ms**; the 6% is a ratio and survives |

### 7.7 `docs/2026-08-27_9b-single-card-resource-envelope.md` -- 6 figures

This document is already correct in structure -- it computes at two clocks and
names both. What changes is that **neither of its clocks is the measured one**,
and one of its two is now known to be unreachable.

| line | says | should say |
|---|---|---|
| 320-331 | the 254.32 MHz table | 254.32 MHz is `gdn_emit_chain` post-route **at 0.85 V** and is not achievable at 0.717 V. Replace with the 237.8 MHz column: at `ROWS_IF=58`, A **18.06**, B **2.32**, C **5.12**, D-vec **0.97**, D-ctrl **0.05**, total **26.52 ms, 37.7 tok/s** |
| 333-344 | the 299.04 MHz table | keep as the 0.85 V reference; label it as such |
| 78-81 (F4) | "The whole 9B token fits the 39 ms budget with room to spare ... 24.80 ms at 254.32 MHz, 22.29 at 299.04" | **26.52 ms at 237.8 MHz.** F4's conclusion survives with a wider margin than it claims for the wrong reason, and 39 ms is not a budget |
| 352-358 | "Minimum parallelism to hit 39 ms": 26 rows at 299.04, **32 at 254.32**, 40 at 214.1 | at 237.8 MHz the minimum is **`ROWS_IF = 34`** (DERIVED). The 214.1 MHz row is `254.32 x (1-0.158)`, a bound built on a derate that a direct measurement has now replaced -- **delete it** |
| 69-76 (F3) | "at 254.32 MHz demand is 265.5 GB/s ... A has 7.8% of the device spare" | at 237.8 MHz demand is **248.3 GB/s, 13.8% spare** |
| 97-107 (F7), 751-755, 780-784 | "`ROWS_IF = 32` is simultaneously the smallest A that meets the 39 ms budget at 9B and the largest A ever synthesised"; the fallback recommendation | **`ROWS_IF = 32` is 41.05 ms at 237.8 MHz and no longer meets 39 ms.** The first half of the coincidence is gone. The second half is superseded outright: `ROWS_IF = 58` post-reclaim **has now been synthesised** (`results.csv:7`, 1,914 DSP exactly as extrapolated), so recommendation 1 at `:769-773` is discharged |
| 638-651 | the context ladder at 254.32 MHz | see section 5.3; the "between 4,096 and 8,192" conclusion survives |

### 7.8 `docs/fpga-hardware-recon.md` -- and the one figure most likely to be quoted

| line | says | should say |
|---|---|---|
| 32 | "`v3.0` ... **~43-61 tok/s**" | **~22-24 tok/s** (section 5.1). Both inputs to 43-61 are refuted: 460 GB/s (measured 288.0) and 70% efficiency (measured 100.0%) |
| 33 | "`v4.0` ... ~140-170 tok/s" | rests on the same two refuted inputs. **Not re-derived here** |
| 70-71 | "at 460 GB/s that is 16.5 ms, a 61 tok/s ceiling" | at the MEASURED 288.0 GB/s it is **25.21 ms, a 39.7 tok/s ceiling** -- and that is a floor on time, not an achievable rate |

---

## 8. What I could not determine

Required section. Each item is open and each changes a number above.

1. **Two of the four 0.717 V sweep points cited as the flatness evidence are
   not on disk.** `sim/ooc_sweep/results.csv` carries `ROWS_IF` 48 and 58 at
   0.717 V, with matching `timing_R48_v0.717.rpt` and `timing_R58_v0.717.rpt`.
   The 32 (236.3 MHz) and 40 (240.6 MHz) rows quoted at
   `clock-at-the-real-voltage.md:38-41` are in no file I could find. The 16.5%
   derate rests only on the 58 pair and is clean; **the flatness claim rests on
   all four**. Separately, the withdrawal of "275.3 MHz at `ROWS_IF = 32`"
   compares a 3.333 ns / 0.72 V run against a claimed 3.3 ns / 0.717 V run, so
   the constraint period changed as well as the voltage. Neither the flatness
   nor the withdrawal is wrong; both are unverifiable from the repo as it
   stands.

2. **B's emit chain at 0.717 V.** The ~212 MHz in section 6.1 is an ESTIMATE
   built on transferring `matvec_core`'s derate to a different path mix, which
   `voltage-derate-on-hardware.md:212-214` explicitly declines to license. If it
   is right, B sets the clock and every figure in section 2 is ~12% optimistic.
   **This is the single most consequential unmeasured quantity here** and it is
   one re-analysis on an existing netlist.

3. **The 0.717 V critical path.** Not read. The flatness across `ROWS_IF` rules
   out the array and nothing else (`clock-at-the-real-voltage.md:102-104`). The
   report is on disk and was not opened.

4. **The ~19% residual A disagreement.** Section 4 shows the clock explains the
   17-24% spread but not the gap. A spec 15.4c's balanced row does not
   decompose into its own stated components and the per-term breakdown is
   printed nowhere. **I did not pick a side and this document carries both.**

5. **Whether any 0.717 V figure survives place and route.** Every number in
   section 1.1 is out-of-context synthesis. The one post-route measurement the
   project owns lost **46.4 MHz** against its synthesis figure (300.75 to
   254.32, both 0.85 V). If a comparable gap applies at 0.717 V, 237.8 MHz is
   itself optimistic by roughly that much, and this document's re-derivation
   would need doing again. No composed, routed design exists at any scale.

6. **Whether the derate is uniform across path types.** All 17 "closes at N MHz"
   flips in section 7.1 assume a single 16.5% factor applies to every unit.
   That is precisely what `voltage-derate-on-hardware.md` refutes as a die
   constant. Each flip is therefore **conditional and needs its own
   measurement**; none should be acted on as written.

7. **E, entirely.** No FK33 has enumerated on PCIe, one-way P2P latency is a
   published-literature figure, the card-edge width is unresolved between the
   vendor's own board file and its XDC, and three documents give three values
   for E's per-token cost (0.42, 0.60, 0.73-5.64 ms). Section 2.1 uses 0.60 for
   comparability and nothing supports it over the others.

8. **B's emit-chain cycle cost as a function of HEADS.** Measured only at 24.
   Both 828,144 and 552,096 are linear extrapolations with an assumed zero
   intercept, and B is emit-bound in both configurations, so this term sets B's
   whole row and moves the token by up to 4.8 ms at 237.8 MHz.

9. **The 9B shapes.** Taken from `rtl/model_cfg_pkg.vhd:64-71` on the package's
   authority; no 9B GGUF on this box and no network. Same limitation as
   9B envelope `:800-807`. Every 9B number scales off them.

10. **Whether `ROWS_IF = 58` post-reclaim closes at 237.8 MHz once placed.** It
    now exists in synthesis (1,914 DSP, matching `33.00 x 58` to the unit) and
    it has not been placed or routed. The 9B envelope's `ROWS_IF = 32` fallback
    is named for a budget it no longer meets, so if 58 fails there is currently
    no named alternative that does.

11. **Power.** `direction-review-fable.md` section 4 item 1 estimates 50-80 W on
    VCCINT, which is 70-110 A at 0.717 V against a rail rated 120 A. Nobody has
    run `report_power`. If the rail droops under the real engine, the derate
    gets worse non-linearly and everything above moves in the wrong direction.
    Not modelled here at all.

12. **Whether 39 ms should be replaced by anything, rather than simply
    retired.** Section 3 establishes it is not a requirement. It does not
    establish what the requirement should be, and nothing in the repo does.
