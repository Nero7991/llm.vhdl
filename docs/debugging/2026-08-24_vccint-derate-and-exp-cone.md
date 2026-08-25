# The two blockers on subsystem C's MACS decision, both measured

## 1. The questions

2026-08-24. An adversarial review of the `MACS = 192` sizing raised three
blockers. One (CR-2, the unmeasured adder-tree reclaim) is answered in
`2026-08-24_adder-tree-reclaim.md`. This file answers the other two.

**CR-1.** Every Fmax figure in every spec is Vivado's default timing analysis,
which for `-1/-2/-2L` is the **0.85 V** point. The FK33 powers up at 0.678 V and
was set by hand to **0.717 V** (`2026-08-24_fk33-sysmon-vccint-undervolt.md`).
The spec's only low-voltage datum is a single `ROWS_IF=48` point at 230.1 MHz,
from which a **-17%** derate was inferred. Is -17% right?

**MA-2.** C section 1.5 records that the reused EXP cone is "a 3-state FSM,
~1 exp per 3 cycles, not a pipeline". At the 27B geometry a position needs 6
exps (one per query head in the GQA group). Does that exceed the MAC budget,
and if so what does fixing it cost?

## 2. The answers

**CR-1: the derate is -22.9% mean, -24.0% worst, not -17%.** Measured on the
same netlist across four `ROWS_IF` points, so it is a derate and not a
re-synthesis artefact. A 300 MHz design runs at **231 MHz** on the card as it is
currently set. Everything takes **+30% more time** than the specs state.

**MA-2: real, and the fix is free.** The staged cone caps C at 18 cycles per
position against 16 cycles of MAC work at `MACS=192`, and that cap is
**independent of lane count** -- `MACS=384` at 768 DSP delivers exactly what 192
delivers at 384 DSP. Properly pipelining the cone costs **one LUT** and gives 3x
throughput, measured both ways.

## 3. CR-1: the voltage derate

### Procedure

`set_operating_conditions -voltage {VCCINT 0.72}` selects the part's real
low-voltage speed data; `-2L` is dual-characterised so 0.70/0.72 are
characterised points, not an extrapolation. Applied **after** synthesis, so the
comparison is one netlist analysed twice rather than two differently-optimised
netlists. Harness: `sim/ooc_core_sweep.tcl`, now taking `volt=<V>`.

### Evidence

| ROWS_IF | 0.85 V | 0.72 V | derate |
|---|---|---|---|
| 8 | 320.0 | 244.0 | **-23.8%** |
| 16 | 318.3 | 242.0 | **-24.0%** |
| 24 | 320.4 | 244.8 | **-23.6%** |
| 32 | 345.7 | 275.3 | -20.4% |

Mean **-22.9%**, and tight across the first three points, which is what gives
confidence: a single point could be netlist-specific, four consistent ones are
the part's voltage characteristic.

### Consequence

| | at 0.85 V | at 0.72 V |
|---|---|---|
| C, `MACS=192`, exp pipelined | 3.49 ms | **4.53 ms** |
| C, `MACS=192`, exp as built | 3.93 ms | 5.10 ms |
| C, `MACS=384`, exp pipelined | 1.75 ms | 2.27 ms |

This does not change which `MACS` to pick, but it changes every throughput
number downstream by +30%, and those numbers are what the project's remaining
perf/watt case rests on. **Either the 0.85 V decision is made and cooling is
resolved, or every projection in every spec should be restated at 231 MHz.**

## 4. MA-2: the exp cone

### The defect

`softmax.vhd:63` names the states `S_EXP_A/B/C` and the comment calls the cone
"PIPELINED". It is **staged, not pipelined**: the FSM returns to `S_EXP_A` only
after `S_EXP_C`, so exactly one element is ever in flight. C section 1.5 has this
right where the source comment does not.

At `MACS=192`, per position per KV head: score is 6x256/192 = 8 cycles, PV is
another 8, so 16 cycles of MAC work -- against 6 exps x 3 cycles = **18 cycles**.
The cone is the limiter, and being a fixed 18 cycles it is a **hard floor
independent of MACS**:

| | MAC cycles | exp cycles | limiter | ms/token @0.85 V |
|---|---|---|---|---|
| `MACS=96` | 32 | 18 | 32 | 6.99 |
| `MACS=192` staged | 16 | **18** | 18 | 3.93 |
| `MACS=192` pipelined | 16 | 6 | 16 | **3.49** |
| `MACS=384` staged | 8 | **18** | **18** | **3.93** -- lanes idle |
| `MACS=384` pipelined | 8 | 6 | 8 | 1.75 |

So the review's conclusion that the optimum "sits at or below 192" is correct
**only while the cone is staged**. Fixed, 192 and 384 become genuinely different
design points.

### The fix, and its cost

The three stages already register their data between states (process variables
written in one state, read in another). A pipeline needs one register per stage
**boundary**, not per in-flight element -- the in-flight elements live in those
registers. So the staged FSM was already paying for the storage and simply not
using it. Removing the FSM is the whole change.

`sim/micro/micro_exp_cone.vhd` carries both forms behind a `PIPELINED` generic,
with the arithmetic copied verbatim from `softmax.vhd` (64-bit intermediates
included) so the two differ only in control:

| | DSP | LUT | FF | CARRY8 | Fmax |
|---|---|---|---|---|---|
| staged | 8 | 629 | 138 | 45 | 343.4 MHz |
| pipelined | 8 | **630** | 138 | 45 | 343.4 MHz |

Simulated, driving both identically with 24 back-to-back inputs:

```
pipelined returned 24,  staged returned 8      (exactly 3x)
VALUES AGREE on all 8 the staged form produced (aligned comparison)
```

## 5. Measurement traps hit

- **Identical synthesis numbers are not evidence on their own.** LUT 629 vs 630
  and the same Fmax is equally consistent with the two generate branches having
  collapsed into one netlist. Only the simulation distinguishes "free" from
  "didn't happen". Do not report a free lunch from utilisation alone.
- **The throughput test broke the value comparison, correctly.** Once the staged
  form is driven back-to-back it drops inputs, so its output `i` is the
  pipelined form's output `3i`. The first version of the comparison flagged
  mismatches at index 2 onward; that was the throughput difference showing, not
  an arithmetic error. Align before concluding.
- **A signal named `ns` collides with the VHDL time unit.** `wait for 40 ns`
  fails to parse with a confusing "unit name expected".
- **GHDL here is the mcode backend**: `-e` produces no binary, run with `-r`.
- **The sweep's CSV header and data row are written in two different places.**
  Adding the `volt` column to the header without adding `$volt` to the row would
  have shifted every field silently. Check both.

## 6. Open

- **Integrating the pipelined cone into `softmax.vhd`** still has to preserve
  `conv_q`, the `e_arr` store and the sum accumulation, which this micro-
  benchmark deliberately drops. The sum accumulator stays sequential.
- **The 0.85 V decision itself.** Reaching it needs wiper ~27 on a curve where
  one step near there moves 7-10 mV, raises VCCINT power ~45% by V^2 on a 120 A
  rail, and cooling is unresolved (die idles 38 C in-case against 30 C on the
  open bench).
- These are OOC numbers. The C-array work the same day is the caution: 246 MHz
  routed against a much healthier synthesis estimate.
