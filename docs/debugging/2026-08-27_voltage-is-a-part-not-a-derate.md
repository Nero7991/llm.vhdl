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

- Whether the post-synthesis derate path (`sim/ooc_core_sweep.tcl`, which
  applies `set_operating_conditions` AFTER `synth_design` with no placement)
  also swaps to `-2LV`. If it does not, then every 0.717 V figure in the sweep
  CSV -- including the 237.812 MHz that the whole budget re-derivation rests on
  -- was produced against the `-2L` model and is NOT comparable to this one.
  That is being measured separately and it is the most consequential open
  question left by this document.
- The die clock is the minimum over subsystems. A is 237.8 MHz and B is now
  210.26 MHz, so the figures just re-derived at 237.8 MHz are optimistic for
  any B-bound term until B's clock is recovered.
- Whether a `-2LV` build is pessimistic relative to a card actually held at
  0.717 V. `-2LV` is a characterised variant with its own guarantees; the FK33
  is a `-2L` part being run at reduced voltage. Those are not the same
  proposition and nothing here settles which way the difference goes.
