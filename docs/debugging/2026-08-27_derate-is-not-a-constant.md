# The 16.5% VCCINT derate is not a constant, and 16.5% is its minimum

**Date:** 2026-08-27. Part `xcvu33p-fsvh2104-2L-e` synthesised, timed again on
`xcvu33p-fsvh2104-2LV-e` at VCCINT 0.717 V. Vivado 2023.2, BC-250.

## 1. The question, verbatim

From the campaign brief:

> The document explicitly refuses to just re-scale them, because scaling assumes
> the 16.5% derate measured on `matvec_core` is uniform across unit classes, and
> that is unproven. [...] An explicit statement of whether the 16.5% derate IS
> uniform across these unit classes -- that is the real scientific question here
> and the answer determines whether every other scaled estimate in the budget
> document can be trusted.

The symptom numbers that motivated it: `matvec_core` at `ROWS_IF = 58` measures
**284.90 MHz at 0.85 V and 237.81 MHz at 0.717 V**, a 16.53% derate
(`sim/ooc_sweep/results.csv:7,9`), and that single ratio was used as x0.835 to
project fourteen other verdicts.

## 2. The answer

**No. The derate ranges 16.5% to 28.0% across five unit classes and 16.5% to
24.4% across three sizes of `matvec_core` alone, against a measurement spread of
0.000. The 16.5% figure is the smallest in the entire measured set, so every
projection built on it is optimistic -- by 17 to 32 MHz on the five verdicts
checked.**

The derate is not a physical constant because it is a **ratio of two unrelated
quantities**. At 0.717 V a single shared structure binds every one of these
designs: a DSP48E2-internal multiply in the Q30 Newton rsqrt,
`ARG__N/DSP_A_B_DATA_INST/CLK -> ...`, at 4.35-4.69 ns and 84-88% logic delay.
At 0.85 V the binding path is frequently somewhere else and route-dominated.
Vivado's logic delay scales **x1.507** with this undervolt while its estimated
route delay scales only **x1.134**, so the observed derate is simply the
logic/route mix of whatever path happened to bind at 0.85 V.

`matvec_core` at `ROWS_IF = 58` is the extreme case in the "small derate"
direction: its 0.85 V critical path is **93.7% route**. It was the worst possible
choice of unit from which to generalise, and it is the one that was generalised.

## 3. The procedure

Each step isolates one thing. Run in this order.

1. **Reproduce every published 0.85 V baseline in the same session that measures
   0.717 V.** Controls for RTL drift. Without this, a changed unit shows up as a
   changed derate. Three of the fourteen baselines had in fact moved.
2. **Synthesize once, time twice.** `set_operating_conditions -voltage {VCCINT
   0.717}` after `synth_design` and `opt_design`, no placement. Controls for
   "two differently optimised netlists" -- the only variable between the two
   columns is the timing model.
3. **Check whether the two voltage paths use the same speed model.** Controls for
   the possibility that the numbers are not comparable at all. Grep the log for
   `[Vivado 12-4441]` and `[Device 21-403]`, and read the `Speed File:` header of
   the timing report.
4. **Repeat two points on each harness.** Establishes the measurement spread, so
   that a claimed difference can be tested against it.
5. **Sweep a size axis within ONE unit** (`matvec_core` at `ROWS_IF` 8, 32, 58).
   Separates "the derate is a property of the unit class" from "the derate is a
   property of one configuration". This is the step that broke the question open.
6. **Record the critical path start point, end point and logic/route split at
   BOTH voltages, for every point.** A bare Fmax cannot show a path changing
   identity, and the path changing identity is the whole mechanism.

## 4. The evidence

### 4.1 The derate spread, MEASURED

```
unit                              0.85 V     0.717 V    derate
gdn_emit_chain SILU_LANES=64      279.88     224.67     19.73%
gdn_emit_chain SILU_LANES=32      291.63     227.63     21.94%
gdn_emit_chain SILU_LANES=8       295.77     227.63     23.04%
matvec_core    ROWS_IF=32         311.53     236.29     24.15%
matvec_core    ROWS_IF=8          312.40     236.29     24.36%
micro_rmsn_lanes LANES=8          200.92     150.88     24.91%
rmsnorm_rs     N=256 LANES=2/4    281.85     211.46     24.97%
l2norm_rs      N=128 LANES=4      285.80     214.18     25.06%
l2norm_rs      N=128 LANES=1/2    300.03     224.57     25.15%
rmsnorm_rs     N=256 LANES=1      300.75     224.57     25.33%
gdn_emit_chain SILU_LANES=16      305.53     227.63     25.50%
micro_rmsn_lanes LANES=1/2/4      278.86     200.80     27.99%
matvec_core    ROWS_IF=58         284.90     237.81     16.53%   <- the one that was generalised
```

### 4.2 The size sweep inside one unit, MEASURED

```
$ tail -3 sim/ooc_sweep/results.csv
xcvu33p-fsvh2104-2L-e,3.3,-1,-1,8,264,20447,9671,28.5,0.099,312.4023742580444
xcvu33p-fsvh2104-2L-e,3.3,-1,0.717,8,264,20447,9671,28.5,-0.932,236.29489603024572
xcvu33p-fsvh2104-2L-e,3.3,-1,-1,32,1056,73599,35768,28.5,0.090,311.52647975077883
```

with the already-committed `ROWS_IF = 32` row at 0.717 V:

```
xcvu33p-fsvh2104-2L-e,3.3,-1,0.717,32,1056,73599,35768,28.5,-0.932,236.29489603024572
```

`ROWS_IF` 8 and 32 differ by 4x in size and land on **236.29489603024572 MHz,
identical to 17 significant figures**. Their 0.85 V figures are 312.40 and
311.53. At `ROWS_IF = 58` the 0.85 V figure has fallen to 284.90 while the
0.717 V figure has barely moved, to 237.81. A flat numerator over a falling
denominator is what produced the small 16.5% ratio.

### 4.3 The binding path at 0.717 V is one shared structure, MEASURED

Verbatim from the timing reports:

```
timing_l2norm_rs_v0.717_N128_LANES1_v0.717.rpt
  Source:            ARG__9/DSP_A_B_DATA_INST/CLK
  Destination:       mr_m_reg[65]/D
  Data Path Delay:   4.414ns  (logic 3.866ns (87.585%)  route 0.548ns (12.415%))

timing_rmsnorm_rs_v0.717_N256_LANES1_v0.717.rpt
  Source:            ARG__9/DSP_A_B_DATA_INST/CLK
  Destination:       mr_m_reg[65]/D
  Data Path Delay:   4.414ns  (logic 3.866ns (87.585%)  route 0.548ns (12.415%))

timing_micro_rmsn_lanes_v0.717_LANES1_v0.717.rpt
  Source:            ARG__3/DSP_A_B_DATA_INST/CLK
  Destination:       m_yy_reg/DSP_A_B_DATA_INST/A[23]
  Data Path Delay:   4.382ns  (logic 3.808ns (86.901%)  route 0.574ns (13.099%))

path_emit_SL8_v0.717.rpt
  Source:            u_rms/ARG__18/DSP_A_B_DATA_INST/CLK
  Destination:       u_rms/rq_yfin_reg[27]/D
  Data Path Delay:   4.354ns  (logic 3.812ns (87.552%)  route 0.542ns (12.448%))
```

Two separate top levels report the byte-identical `4.414ns (logic 3.866ns
(87.585%) route 0.548ns (12.415%))`. That is not a coincidence; it is the same
rsqrt netlist compiled into both.

### 4.4 The path changes identity with voltage, MEASURED

```
path_emit_SL8_default.rpt              (0.85 V)
  Source:            si_e_seg_reg[2]/C                 <- inside gdn_silu
  Destination:       u_silu/xq_reg[1][29]/D
  Data Path Delay:   3.363ns  (logic 0.927ns (27.565%)  route 2.436ns (72.435%))

path_emit_SL8_v0.717.rpt               (0.717 V)
  Source:            u_rms/ARG__18/DSP_A_B_DATA_INST/CLK   <- inside rmsnorm_bf
  Destination:       u_rms/rq_yfin_reg[27]/D
  Data Path Delay:   4.354ns  (logic 3.812ns (87.552%)  route 0.542ns (12.448%))
```

```
timing_l2norm_rs_v0.717_N128_LANES1.rpt        (0.85 V)
  Source:            msb_p_reg[2]/C
  Destination:       bias_q_reg[0]/R
  Data Path Delay:   3.216ns  (logic 1.369ns (42.568%)  route 1.847ns (57.432%))
```
versus the 0.717 V `ARG__9/DSP...` path quoted above. **Different start point,
different end point, 42.6% logic becoming 87.6% logic.** A single ratio cannot
describe that.

### 4.5 The scaling factors, MEASURED on the one design whose path does NOT move

`matvec_core` `ROWS_IF = 58`, same start and end points at both voltages
(`sim/ooc_sweep/timing_R58.rpt`, `timing_R58_v0.717.rpt`):

```
0.85 V   Data Path Delay:  3.272ns  (logic 0.205ns (6.266%)  route 3.067ns (93.734%))
0.717 V  Data Path Delay:  3.788ns  (logic 0.309ns (8.156%)  route 3.479ns (91.844%))
```

**logic x1.507, route x1.134.** A 94%-route path moves 15.8% in total delay; an
87%-logic path moves ~39%. That single pair of factors reproduces the whole
16.5-to-28.0% spread.

### 4.6 The measurement spread is zero, MEASURED

Three independent second invocations, plus one accidental duplicate (a smoke
test run 30 minutes before the sweep):

```
l2norm_rs N=128 LANES=4      run1 -1.336 / 214.17862497322764   run2 -1.336 / 214.17862497322764
micro_rmsn_lanes LANES=4     run1 -1.647 / 200.80321285140562   run2 -1.647 / 200.80321285140562
micro_rmsn_lanes LANES=1     run1 -1.647 / 200.80321285140562   run2 -1.647 / 200.80321285140562
gdn_emit_chain SILU_LANES=8  run1 -1.093 / 227.63487366264513   run2 -1.093 / 227.63487366264513
gdn_emit_chain SILU_LANES=16 run1 -1.093 / 227.63487366264513   run2 -1.093 / 227.63487366264513
```

Bit-identical. Seven of the 0.85 V baselines also reproduce the committed
workstation figures to 13+ significant figures, months apart and on a different
machine. **Every difference reported above therefore exceeds the spread by an
unlimited margin.**

## 5. Measured and REJECTED -- do not retry

- **"Apply x0.835 to a 0.85 V Fmax."** REJECTED. Checked against five direct
  measurements and optimistic on all five, by +24.5 MHz (`l2norm_rs` L4),
  +19.3 (`gdn_emit_chain` SL8), +23.9 (`rmsnorm_rs` N256 L4), +32.0
  (`micro_rmsn_lanes` 1/2/4) and +16.9 (`micro_rmsn_lanes` 8). Two of the five
  landed on the **wrong side** of the 237.8 MHz target. Do not use it, and do
  not use any single ratio.

- **"The derate is a property of the unit class, so measure one point per
  class."** REJECTED. `matvec_core` alone spans 16.53% (`ROWS_IF = 58`), 24.15%
  (`32`) and 24.36% (`8`). One point per class is not enough because the derate
  depends on the 0.85 V baseline, which depends on congestion, which depends on
  size.

- **"The post-synthesis derate and the place-and-route run use different speed
  models, so they are not comparable."** REJECTED, and this was checked before
  any conclusion was drawn. **Both** paths reload the part: the post-synthesis
  `set_operating_conditions` emits `[Vivado 12-4441] ... require changing to the
  -2LV variant` followed by `[Device 21-403] Loading part
  xcvu33p-fsvh2104-2LV-e`, exactly as the XDC path in `sim/ooc_micro_pnr.tcl`
  does. Independently confirmed in `sim/ooc_sweep/volt072.log:2704-2707` and in
  the `Speed File: -2LV PRODUCTION 1.30 05-01-2022` header of
  `sim/ooc_sweep/timing_R48_v0.717.rpt`. Comparable.

- **"Run-to-run variance could explain the spread."** REJECTED. Five repeats,
  all bit-identical. Synthesis is deterministic and this instrument adds no
  placement. Note this rejection is specific to the **synthesis-only** path;
  `sim/ooc_micro/pnr_results.csv` shows the place-and-route path genuinely does
  vary (243.72 to 281.21 MHz on nominally similar RTL), so the same claim must
  not be carried across to post-route figures.

- **"`SILU_LANES = 8` is slower than 16, so narrowing costs clock."** REJECTED at
  the operating voltage. 8, 16 and 32 all measure 227.63487366264513 MHz with the
  identical binding path. True only at 0.85 V, where the path lives in
  `gdn_silu`.

## 6. Measurement traps hit

- **`get_property PART [current_project]` does NOT change when Vivado reloads the
  part.** It still reads `xcvu33p-fsvh2104-2L-e` one line after the log says
  `Loading part xcvu33p-fsvh2104-2LV-e`. A "did the variant change" check written
  against that property reports "no change" and is wrong. The log is the
  authority. `sim/ooc_micro.tcl` now says so in a comment next to the check
  rather than silently printing a misleading line.

- **`sim/ooc_sweep/results_baseline.csv` is PRE-reclaim and the `*_v0.72` reports
  are POST-reclaim.** `ROWS_IF = 8` is 384 DSP in the baseline CSV and 264 DSP in
  `results.csv`. Pairing `timing_R8.rpt` with `timing_R8_v0.72.rpt` looks like a
  free derate measurement and is not a pair at all -- different netlists. Only
  `ROWS_IF = 58` was a valid committed pair before this campaign; the `8` and
  `32` pairs had to be produced fresh.

- **Quoting a committed 0.85 V baseline instead of re-measuring it hides RTL
  drift inside the derate.** Three of fourteen baselines had moved:
  `l2norm_rs` LANES=1 300.75 -> 300.03, `gdn_emit_chain` SILU_LANES=16
  300.75 -> 305.53, SILU_LANES=64 266.81 -> 279.88. Had the old values been used,
  the SILU_LANES=16 derate would have read 24.3% instead of the true 25.5%.

- **Identical Fmax across different designs is a signal, not a bug.** The first
  reaction to seeing `l2norm_rs` LANES=1 and LANES=2 both report exactly
  224.56770716370985 MHz was to suspect the harness had reused a netlist. It had
  not: DSP/LUT/FF differ per row. The identity is the shared rsqrt path, and
  noticing it is what located the mechanism.

- **A derate quoted without its baseline is meaningless.** `gdn_emit_chain` at
  0.717 V measures 210.26 MHz post-route elsewhere in this project; against the
  oldest of five committed baselines that is 17.3%, against the newest it is
  25.2%. Always print both columns from the same run, which is why both
  harnesses now do.

## 7. What was NOT determined

- Whether the same non-uniformity holds **post-route**. Everything here is
  synthesis-only. The 15.4% synth-to-route gap measured on `gdn_emit_chain` at
  0.85 V may itself be voltage-dependent.
- Whether Vivado's **estimated** route delay under-derates relative to real
  routed interconnect. If it does, the x1.134 route factor is an artifact of the
  unplaced model and the true spread is narrower than measured -- but in the
  direction that makes route-dominated designs *worse* than reported, not better.
- Whether adding `MREG` to the 34x32 Newton stage lifts the 4.35-4.69 ns rsqrt
  floor. C spec 3.13 item 1 names it as the expected fix and B spec `:3140` notes
  B and C share it. Not attempted here. It is now the highest-value RTL change
  available, because that one path binds `l2norm_rs`, `rmsnorm_rs`, `rmsnorm_bf`
  and `gdn_emit_chain` at once.
- Whether 237.8 MHz should remain the die target. It is `matvec_core`'s number
  and every other unit measured is below it.
