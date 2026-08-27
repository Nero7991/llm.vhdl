# Vivado does not derate for VCCINT 0.717 V, it changes the part -- and the critical path moves with it

## 1. The question

2026-08-27, branch `fpga`, Vivado 2023.2, part `xcvu33p-fsvh2104-2L-e`, FK33,
VCCINT measured at 0.717 V. Unit under test `gdn_emit_chain` at
`HEADS=24 DIM=128 SILU_LANES=16 RMS_LANES=4 Q=12`, target period 3.3 ns.

`docs/2026-08-27_budgets-at-the-measured-clock.md` section 6.1 ranks one
measurement above every other open item: **what does B's emit chain actually
reach post-route at 0.717 V?** It had 300.75 MHz synthesis and 254.32 MHz
post-route, both at 0.85 V, and an ESTIMATE of ~212 MHz from applying
`matvec_core`'s measured 16.5% derate. If the estimate held, B and not A would
set the die clock and every budget number was 12% optimistic.

The question in front of the tool was narrower and turned out to be the
interesting one: **where in a place-and-route flow may
`set_operating_conditions -voltage` be applied?** Three placements had already
failed three different ways.

## 2. The answer

**Nowhere, because it is not a derate. At 0.717 V Vivado RELOADS the part as the
`-2LV` variant, and that is a speed-grade change, so wherever the command lands
the part underneath the placer is not the part the design was opened on.** Open
the design on `xcvu33p-fsvh2104-2LV-e` directly and the problem does not arise.

The measurement it unblocked: **210.26 MHz post-route at 0.717 V**, WNS
-1.456 ns. The ~212 MHz estimate was good to under 1%. B's emit chain, not A,
is the binding clock.

And the finding that was not predicted at all: **the critical path is a
different path at the two voltages.**

## 3. The procedure

1. **Try the command in the flow and read the errors as data rather than as
   obstacles.** The three failures are not three bugs, they are three views of
   one cause:

   | placement | result |
   |---|---|
   | after `route_design` | `[Constraints 18-11797]` cells at `RAMB18_*` assigned to site type `RAMB180`, for every block RAM, then `Abnormal program termination (11)` |
   | between `opt_design` and `place_design` | `ERROR: [Place 46-21] Placer has detected the speed grade changed since the design was opened and cannot continue` |
   | right after `create_project -in_memory` | `ERROR: [Common 17-53] No open design` |

   The middle one names the cause outright: **speed grade changed**. A voltage
   is not a multiplier applied to a timing model, it selects one.

2. **Put it in the XDC instead, and read the log rather than the result.** This
   runs further and prints the mechanism:

   ```
   WARNING: [Vivado 12-4441] The operating conditions provided require changing
   to the -2LV variant of this part to ensure that accurate timing and power
   data is provided.
   INFO: [Device 21-403] Loading part xcvu33p-fsvh2104-2LV-e
   ```

   It still fails at `place_design` with the same `[Place 46-21]`, because the
   XDC is applied after the design is created.

3. **Open on the low-voltage part from the start.** `sim/ooc_micro_pnr.tcl`
   now derives `opened_part` by rewriting a trailing `-2L-e` to `-2LV-e`
   whenever `volt=` is given, and uses it for both `create_project` and
   `synth_design`. The XDC still pins the exact 0.717 V, which is now a 3 mV
   adjustment inside the correct model rather than a model change.

4. **Read the critical path at both voltages, not just the frequency.** This is
   the step that produced the finding that matters.

## 4. The evidence

From `sim/ooc_micro/pnr_results.csv`, same unit, same generics, same 3.3 ns
target:

| VCCINT | part loaded | DSP | LUT | FF | WNS ns | Fmax MHz | logic ns | net ns | logic share |
|---|---|---|---|---|---|---|---|---|---|
| 0.85 (default) | `-2L-e` | 73 | 29,829 | 15,190 | -0.256 | **281.21** | 1.178 | 2.340 | 33.5% |
| **0.717** | **`-2LV-e`** | 73 | 30,175 | 15,091 | -1.456 | **210.26** | 3.674 | 0.932 | **79.8%** |

Critical paths, verbatim from the two `critpath_*.txt` reports:

```
0.85 V   startpoint: si_e_seg_reg[4]_replica/C
         endpoint:   u_silu/xq_reg[14][20]/D
         slack: -0.256   logic 1.178   net 2.340

0.717 V  startpoint: u_rms/ARG__18/DSP_A_B_DATA_INST/CLK
         endpoint:   u_rms/rq_yfin_reg[28]/D
         slack: -1.456   logic 3.674   net 0.932
```

**Different startpoint, different endpoint, different unit, and the logic/net
split inverts.** At 0.85 V the binding path is route-dominated and lives in
`gdn_silu`. At 0.717 V it is logic-dominated and lives in `rmsnorm_bf`.

That path was then read and found to be a whole DSP multiply combinationally,
then a bit select, then a 2:1 mux, then the destination flop, all inside one
FSM state, with no MREG/PREG -- fixed in commit `3c2789e`.

## 5. Measured and REJECTED -- do not retry

- **`set_operating_conditions -voltage` after `route_design`.** Segfaults after
  emitting a `RAMB18` site-type error per block RAM. Signal 11, no report
  written. Do not retry at any point in a P&R flow.
- **The same command between `opt_design` and `place_design`.** `[Place 46-21]`.
- **The same command immediately after `create_project -in_memory`.**
  `[Common 17-53] No open design`. There is no window: before the design exists
  it is too early, after it exists it is too late.
- **The same constraint in the XDC, with the part left at `-2L-e`.** Gets
  furthest and is the run that reveals the mechanism, but still dies at
  `[Place 46-21]`. Useful once, as a diagnostic; not a working configuration.
- **Treating the 0.85 V critical path as the thing to optimise.** The budget
  document reasoned from the 0.85 V post-route split (33.2% logic / 66.8%
  route) that "the true post-route derate is probably smaller than 16.5%,
  which argues 212 MHz is pessimistic". Measured, the derate is LARGER, because
  at low voltage the design stops being route-bound and a different,
  logic-heavy path binds. **The prediction was directionally wrong and the
  reasoning behind it does not survive.** Do not extrapolate a low-voltage
  result from a nominal-voltage path decomposition.

## 6. Measurement traps hit

- **A run that completes is not a run that measured what you asked for.** The
  XDC form loaded `-2LV` and would have produced a number; it happened to fail
  later. Had it not, the number would have been from a design placed for one
  part and analysed for another.
- **Choosing the wrong baseline by one CSV row.** `pnr_results.csv` holds five
  `gdn_emit_chain` rows at this shape, from successive versions:
  254.32 / 260.55 / 243.72 / 266.45 / 281.21 MHz. The budget document quotes
  254.32, which is the OLDEST. Against 254.32 the derate reads as 17.3%;
  against 281.21, the row for the same RTL, it reads as **25.2%**. The spread
  between 243.72 and 281.21 on nominally similar RTL also shows run-to-run
  placement variance is large enough that a single pair cannot pin a derate at
  all. A matched set of four runs, two per voltage on one netlist, is running
  for that reason.
- **A derate measured on one unit does not transfer.** 16.5% came from
  `matvec_core`. 22.9% was measured earlier and refuted as a die constant. This
  unit gives 17.3% or 25.2% depending on baseline. The quantity is not a
  property of the die.

## 7. Open, not yet answered

- ~~Whether the post-synthesis derate path also swaps to `-2LV`.~~
  **ANSWERED the same day, from logs already in the repo. It does.**
  `sim/ooc_sweep/volt072.log:2704-2707` carries the identical `[Vivado 12-4441]`
  warning and `[Device 21-403] Loading part xcvu33p-fsvh2104-2LV-e`, and every
  report header confirms it:
  `sim/ooc_sweep/util_R48_v0.717.rpt` says `Device: xcvu33p-fsvh2104-2LV-e`
  and `Speed File: -2LV`, `timing_R48_v0.717.rpt` says
  `Speed File: -2LV PRODUCTION 1.30 05-01-2022`. So the 237.812 MHz and the
  210.26 MHz here are analysed against the SAME timing model and the comparison
  stands. One difference remains and it favours the P&R run: the sweep
  synthesises on `-2L` and re-analyses on `-2LV`, so its netlist was optimised
  for the wrong part, whereas the P&R run optimises for `-2LV` throughout.

- **The comparison that replaces it, and it is worse news.** A's 237.812 MHz is
  a SYNTHESIS number with no placement or routing. B's 210.26 MHz is
  POST-ROUTE. Those are not the same kind of measurement, and on this very unit
  the gap between them is large: `gdn_emit_chain` measured 300.75 MHz at
  synthesis and 254.32 MHz post-route at 0.85 V, a loss of **15.4%**. A has
  NEVER been placed and routed at 0.717 V, or at any voltage at
  `ROWS_IF = 58`. If A loses a comparable fraction, its post-route figure is
  near 200 MHz and the die clock is lower than either number currently in use.
  A post-route run at `ROWS_IF = 58`, both voltages, is queued.
- The die clock is the minimum over subsystems. A is 237.8 MHz and B is now
  210.26 MHz, so the figures just re-derived at 237.8 MHz are optimistic for
  any B-bound term until B's clock is recovered.
- Whether a `-2LV` build is pessimistic relative to a card actually held at
  0.717 V. `-2LV` is a characterised variant with its own guarantees; the FK33
  is a `-2L` part being run at reduced voltage. Those are not the same
  proposition and nothing here settles which way the difference goes.

---

## CORRECTION, 2026-08-27, same day

**Withdrawn: the claim that the 2 cycles added to `rmsnorm_bf` by commit
`3c2789e` are absorbed by the chain.** That claim was made in `3c2789e`'s
commit message and in a message to the B owner, on this reasoning:

> tb_gdn_emit_chain's finish time moves 82,058.5 ns -> 82,060.5 ns, which is
> 2 ns, not the 288 ns that 2 cycles x 144 invocations would cost if rmsnorm
> sat on the per-head critical chain. It does not; the column bank does.

**It does sit on the per-head chain.** Re-measured directly by moving the
column arrival period one cycle at a time, the deadline went from **366 drops /
367 passes** to **368 drops / 369 passes** -- exactly two cycles, one for one,
which is the opposite of absorbed.

The inference was invalid, not merely unlucky. `tb_gdn_emit_chain` runs 512
cycles per head, well above the deadline, so it is in the arrival-bound regime
where per-head service time is hidden entirely and only the final drain is
visible. In that regime a 2 ns move is what you would observe **whether or not**
rmsnorm is on the critical chain, so the observation cannot distinguish the two
cases and never could. **An aggregate finish time taken in the arrival-bound
regime carries no information about per-head service.** The measurement that
answers the question is the deadline sweep, and it was available.

What survives: the column bank is still the binding resource, and
`RECUR_LANES=32` still has margin -- now +143 cycles, 27.9%, down from 28%.
`RECUR_LANES=64` is short by 113 cycles per head and no finite buffer fixes a
sustained rate deficit.

The two rmsnorm cycles are therefore a real cost against the per-head budget
and not free. They are still worth paying while the 0.717 V critical path runs
through that multiply, but that trade should be re-checked once the matched
place-and-route set reports, because if the fix does not buy clock it is now
known to cost schedule.
