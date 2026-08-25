# Subsystem A adder-tree reclaim: 46.34 -> 33.00 DSP per row, measured

## 1. The question

2026-08-24. Subsystem A §15.4a proposed pushing adder-tree levels >= 2 out of
DSP48E2 ALUs into LUT fabric, with an **"Expected effect: 46.5 -> ~34.5 DSP/row"**
that had never been synthesized. Everything downstream rested on it:

> Is 34.5 DSP/row real, and what does it cost in LUT?

It gates the whole-die allocation. An adversarial review of the `MACS` sizing
put it as the pivot: at the *measured* 46.5/row, `ROWS_IF=58` alone is 94% of the
device and the proposed A+B+C allocation does not exist.

## 2. The answer

**33.00 DSP per row, exactly, with a zero intercept and zero residual** at all
four sweep points. Better than the 34.5 predicted, because 33 is precisely the
number of multiplies the array contains (32 products + 1 scale multiply): the
reclaim removes **every DSP that was not a multiplier**.

Cost is **+346 LUT/row and +367 FF/row**, and **no Fmax penalty**. The design
remains bit-exact against the C reference on the full verification chain.

| | baseline | reclaim | |
|---|---|---|---|
| DSP/row | 46.34 | **33.00** | -28.8% |
| DSP intercept | 10.0 | **0.0** | |
| max residual (DSP) | 3.4 | **0.0** | perfectly linear |
| LUT/row | 1,877 | 2,223 | +346 |
| FF/row | 721 | 1,088 | +367 |
| Fmax range | 312-378 MHz | 318-346 MHz | no penalty |
| DSP-only ceiling | 62.2 rows | **87.3 rows** | §15.4a predicted ~83 |

The 13.34 DSP/row removed matches §15.4a's independently measured **13.1
`(PCIN+A:B)` nodes per row** almost exactly, which is the cross-check that the
attribute hit the intended cells and nothing else.

## 3. The procedure

1. **Measure the baseline FIRST, in the same tool session**, with the pristine
   RTL. Do not compare against numbers recorded in a document from an earlier
   session; that is how tool-version and setting differences get attributed to
   the change under test.
2. Sweep `ROWS_IF` over 8/16/24/32 so `DSP = a + b*ROWS_IF` can be fitted. One
   point cannot separate fixed overhead from per-row cost.
3. Apply the reclaim, re-run **identical** points, fit again, compare slopes.
4. **Run the functional verification chain before believing any of it.** The
   change rewires the adder tree; a synthesis result for arithmetic that no
   longer computes the right answer is worthless.

Harness: `sim/ooc_core_sweep.tcl`, part `xcvu33p-fsvh2104-2L-e`, period 3.333 ns.
Verification: `sh sim/run_matvec.sh` (RTL vs C reference stage by stage over
shapes, end to end from real packed bytes, plus the AXI-Lite PS sequence).

## 4. The evidence

```
BASELINE  DSP/row 46.34  intercept 10.0   R= 8:384  16:748  24:1119  32:1496
RECLAIM   DSP/row 33.00  intercept -0.0   R= 8:264  16:528  24: 792  32:1056
                                          per-row: 33.00 33.00 33.00 33.00
```

Whole-die at `ROWS_IF=58`, `MACS=192` (VU33P: 2,880 DSP), with the adversarial
review's corrected terms (C aux 15-40, B 138-152):

```
baseline : A=2698  C=384+aux  B=138-152 -> 3235-3274 = 112-114%   DOES NOT FIT
reclaim  : A=1914  C=384+aux  B=138-152 -> 2451-2490 = 85.1-86.5%
```

Verification after the change: **all green**, 0 mismatches everywhere -- 4,178
arithmetic vectors, act_mem across five geometries, seven end-to-end shapes,
five AXI-Lite shapes.

## 5. The implementation, and the two traps §15.4a named

Both were real and both are load-bearing.

1. **Levels 0..LVL shared one signal `tr`.** A blanket `use_dsp = "no"` on it
   would have stripped the level-0 **multipliers** along with the adders, which
   is the opposite of the intent. Levels >= 2 are split onto a separate signal
   `trn`, and the attribute targets only that.
2. **Level 1 must stay in the DSP.** It costs zero DSPs today because it fuses
   onto the multiply as `(PCIN+(A2*B)')` and rides the cascade for free. Forcing
   it into fabric spends LUTs to save nothing.

The tree loop branches on `l`, which is a loop constant, so every branch
elaborates statically and no runtime mux is created.

## 6. Measurement traps hit

- **The sweep harness does `read_vhdl` INSIDE its per-`ROWS_IF` loop.** Editing
  the RTL while a sweep is running silently gives a mixed result where the early
  points are baseline and the later ones are not. The patch was therefore
  prepared against a copy and applied only after the baseline finished. Same
  class as the order-dependent I2C scan found earlier the same day: a result
  that looks clean and is quietly wrong.
- **A concurrent assertion cannot go in the declarative region.** The first
  version of the patch put the `LVL >= 2` guard next to the signal declarations,
  which does not compile. It belongs after the architecture's `begin`.
- **Synthesis Fmax is noisy and non-monotonic.** The baseline reads 378 MHz at
  `ROWS_IF=24` against 318 at 32. Do not read a trend into single points; the
  reclaim's tighter 318-346 spread is the more trustworthy signal, and even it
  is OOC, not placed and routed.

## 7. Open, not yet answered

- **This is OOC synthesis, not place-and-route.** The C-array work earlier the
  same day is the cautionary case: 246 MHz routed against a much healthier
  synthesis estimate, fixed only by registering operand muxes into `AREG`/`BREG`,
  and visible only after PnR. Treat the DSP and LUT counts as solid and the Fmax
  column as an upper bound.
- **Every Fmax figure here is Vivado's default 0.85 V analysis.** The card on the
  bench runs at **0.717 V**, where the one measured datum is a **17% cut**. At
  that voltage 320 MHz is ~266 MHz. See
  `2026-08-24_fk33-sysmon-vccint-undervolt.md`.
- **LUT is now the resource that grew, and its whole-die sum has never been
  computed.** A at `ROWS_IF=58` goes 110,677 -> 131,357 (+20,680, below the
  +23-35K estimated). Against 439,680 on the VU33P that is fine alone, but the
  device total across A, B, C, D and the HBM/XDMA shell is still unbudgeted, and
  the 90% occupancy cap the allocation is checked against bounds **DSP only**.
