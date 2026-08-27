# Optimising this design at 0.85 V makes the 0.717 V derate WORSE, and the same netlist meets 300 MHz at one voltage and 232 at the other

## 1. The question

2026-08-27, branch `fpga`. `gdn_emit_chain` at `HEADS=24 DIM=128 SILU_LANES=16
RMS_LANES=4 Q=12`, 3.3 ns target, place-and-route, Vivado 2023.2. Part
`xcvu33p-fsvh2104-2L-e` at nominal and `-2LV-e` at 0.717 V, which is the same
die (see `2026-08-27_voltage-is-a-part-not-a-derate.md`). No hardware.

Three RTL fixes were made in one session, each chosen from the measured 0.717 V
critical path. The question asked after the third was routine bookkeeping:
**how much did each fix gain, and is the VCCINT derate stable across them?**

## 2. The answer

**The derate is not stable. It got worse as the design got better, from 18.2%
to 24.0%, and that is a direct consequence of what the fixes did.** Removing
routing delay leaves logic delay, and logic is what voltage derates. So a gain
won at 0.85 V passes through to 0.717 V at well under 100%, and one fix gained
at 0.717 V while LOSING 16.4 MHz at 0.85 V.

The starkest form: after the third fix the identical netlist reads
**305.4 MHz with POSITIVE slack (+0.026 ns) at 0.85 V** and **232.2 MHz at
0.717 V**. Judged at Vivado's default voltage this unit closes the project's
original 300 MHz target outright. On the card it misses by 23%.

**Do not tune this design at 0.85 V.** Every ranking of what to fix next must
come from a `-2LV` report.

## 3. The procedure

1. Measure post-route at 0.717 V, read the critical path, fix what it names.
2. Repeat. Three iterations.
3. **Measure BOTH voltages on each netlist, not just the target one.** This is
   the step that produced the finding. Measuring only 0.717 V gives the
   improvement and hides the mechanism; measuring only 0.85 V, which is the
   default and therefore the easy thing to do, would have ranked the fixes in a
   different and partly opposite order.

## 4. The evidence

All post-route, same generics, same 3.3 ns target. Each cell is ONE run.

| netlist | commit | 0.85 V | 0.717 V | derate | binding path at 0.717 V | logic / net at 0.717 V |
|---|---|---|---|---|---|---|
| baseline | pre-`3c2789e` | 281.21 | 210.26 | 25.2% | `u_rms/ARG__18 -> rq_yfin_reg[28]/D` | 3.674 / 0.932 |
| + fold registered and narrowed | `3c2789e` | **264.79** | 216.51 | 18.2% | `si_e_seg_reg[4]_replica/C -> u_silu/xq_reg[7][22]/D` | 1.753 / 2.812 |
| + per-lane shift control | `e9f7e6c` | **305.44** | 232.16 | 24.0% | `u_rms/ARG__21 -> p2_raw_reg[2][63]/D` | 3.600 / **0.530** |

Per-fix deltas, which is where the asymmetry shows:

| fix | gain at 0.85 V | gain at 0.717 V | pass-through |
|---|---|---|---|
| register + narrow the `1/sqrt(2)` fold | **-16.42 MHz** | +6.25 MHz | negative, opposite signs |
| per-lane shift-control registers | +40.65 MHz | +15.65 MHz | **38.5%** |
| both together | +24.23 MHz | +21.90 MHz | 90.4% |

Raw tool lines for the two extremes:

```
PNR gdn_emit_chain_v0.717_...  WNS=-1.007  Fmax=232.2 MHz  (logic 3.600 / net 0.530 ns)
PNR gdn_emit_chain_...         WNS=+0.026  Fmax=305.4 MHz  (logic 2.626 / net 0.485 ns)
```

The mechanism is visible in the logic/net columns. The campaign drove net delay
on the binding path from 0.932 to 2.812 and back down to 0.530 ns, and the
final netlist is logic-dominated at both voltages. Voltage scales logic
strongly and routing weakly, so as the routing share falls the derate rises.
**The better the design gets, the more of its remaining delay is the part
voltage punishes.**

## 5. Measured and REJECTED -- do not retry

- **Ranking fixes by a 0.85 V critical path.** At 0.85 V the baseline's binding
  path was route-bound in `gdn_silu`; at 0.717 V it was logic-bound in
  `rmsnorm_bf`. Different unit, different failure mode. A 0.85 V-driven session
  would have started with the silu path and never touched the fold multiply,
  which is where 0.717 V said the problem was.
- **Treating the fold fix as a regression.** It reads -16.42 MHz at 0.85 V. On
  that evidence alone it should be reverted. At the voltage the card runs at,
  it is +6.25 MHz and it moved the binding path off `rmsnorm_bf`, which is what
  made the next fix findable. **Judged at the wrong voltage it is a
  regression; judged at the right one it is a prerequisite.** This is the same
  lesson as `2026-08-27_rmsnorm-max-tree-measured-worse.md`, where a correct
  optimisation measured as a regression because of what it exposed, and it is
  now the second instance.
- **Quoting a single derate figure for this die.** Measured on this one unit
  across one session it is 25.2%, then 18.2%, then 24.0%. Earlier figures of
  16.5% (`matvec_core`) and 22.9% (refuted as a die constant) are in the same
  range and none of them is a property of the silicon. The derate is a
  property of the netlist's logic-to-routing ratio.

## 6. Measurement traps hit

- **Editing RTL while a comparison set was running.** The first attempt at a
  matched pair straddled a mid-flight `rmsnorm_bf` change, so runs 1-2 and 3-4
  would have used different netlists and the comparison would have been
  meaningless without saying so. Killed and restarted on settled RTL. If a
  measurement set spans more than a few minutes, freeze the tree or record the
  commit per run.
- **Choosing a baseline row from a CSV of successive versions.**
  `pnr_results.csv` holds five `gdn_emit_chain` rows at this shape spanning
  243.72 to 281.21 MHz. Reading the derate against the oldest gives 17.3%,
  against the matching one 25.2%. Always pair a voltage figure with the run of
  the SAME netlist.
- **One run per cell.** Everything above is a single place-and-route per point.
  The historical spread across RTL versions suggests placement variance alone
  can be worth several percent, so the -16.42 MHz on the fold fix is the number
  in this table least able to carry weight. The overall direction rests on two
  independent fixes agreeing, not on any one cell.

## 7. Open, not yet answered

- Whether the low pass-through generalises beyond this unit. It follows from
  logic and routing derating differently, which is not unit-specific, but it
  has been measured on one unit.
- Whether a `-2LV` build is pessimistic against a `-2L` part actually held at
  0.717 V. `-2LV` is a characterised variant with its own guarantees; the FK33
  is a `-2L` part run undervolted. Nothing here settles which way that differs.
- `DONT_TOUCH` on the per-lane registers blocks Vivado's own replication. If a
  later path is routing-bound again that attribute is the first thing to
  reconsider. Unmeasured.
