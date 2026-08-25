# Reconciling the whole-die budget across A, B, C, D and E

Date: 2026-08-25. Part `xcvu33p-fsvh2104-2L-e` (SQRL FK33), two cards.
Written after four subsystem work items landed on the same day, each of which
moved a number the others were quoting.

## The question

Four specs each carry a resource figure, and each was written against a
snapshot of the others. After 2026-08-24/25 the snapshots disagree. Does the
design still fit, and which terms in the sum are actually load-bearing?

## The answer

**DSP fits, at 87.2-88.2% of 2,880, but only conditionally and the margin is
thinner than any single spec says.** The two conditions are:

1. **C's QK-norm must use a width-narrowed RMSNorm.** With `rmsnorm.vhd` as
   shipped the die is 89.2-90.3%, at or over the 90% congestion line both
   B §2.8 and C §2.8 cite.
2. **D's 24-40 DSP row is the weakest term in the sum and is probably low.**
   It is the only row with no measurement behind it, and the one measured
   number that bears on it (a sigmoid cone at 8 DSP per lane) implies D's
   swiglu alone could be ~64 DSP at `LANES_V = 8`.

**Timing is the bigger finding, and it is not C's problem alone.**
`rmsnorm.vhd` as shipped runs at **138.4 MHz**. That is not merely short of
the 300 MHz nominal; it is short of the **~231 MHz the card can actually
reach at its measured 0.717 V**. The unit misses timing everywhere it is
instantiated, and D reuses its arithmetic for the layer norms.

## The sum, with provenance per row

| Subsystem | DSP | Basis |
|---|---|---|
| A, `ROWS_IF = 58` post-reclaim | 1,914 | **MEASURED.** 33.00 DSP/row exactly, intercept 0, zero residual at four sweep points (A §15.4a) |
| C, `MACS = 192` + aux 50 | 434 | MAC array DERIVED from a measured per-lane fit; aux row **MEASURED** unit by unit (C §3.8) |
| B, `LANES = 32` | 138-152 | ESTIMATE, no B RTL synthesised |
| D, `LANES_V = 8` | **24-40** | **ESTIMATE, no D RTL, and see below** |
| **total** | **2,510-2,540 of 2,880** | **87.2-88.2%** |
| with `rmsnorm` as shipped | 2,570-2,600 | **89.2-90.3%, at/over the line** |

E is 0 DSP by construction (its accumulator is an adder tree, A §15.4b).

This supersedes D §12's 2,460-2,490 (85.4-86.5%), which predated C's §3
auxiliary row by one day. The delta is entirely C's aux row moving from an
assumed 15-40 to a measured 50, plus the 384 MAC figure it already carried.

## What was measured, and reproduced

All OOC, `xcvu33p-fsvh2104-2L-e`, 3.333 ns, via `sim/ooc_micro.tcl`, whose
DSP48E2 census is reconciled against the utilisation count on every run (a
disagreement invalidates the number regardless of which is larger).

```
MICRO rmsnorm_N256    DSP=78 (census 78)  LUT=11766  FF=4694  WNS=-3.890  Fmax=138.4 MHz
MICRO rmsnorm_N128    DSP=78 (census 78)  LUT=7076   FF=2546  WNS=-4.208  Fmax=132.6 MHz
MICRO micro_sig_cone  DSP=8  (census 8)   LUT=1062   FF=121   WNS=+0.421  Fmax=343.4 MHz
```

**`rmsnorm`'s DSP cost is N-INDEPENDENT** (78 at both N=128 and N=256, and the
LUT term is the only one that scales). That is the diagnostic: the cost is not
the per-element work, it is the fixed rsqrt pipeline. Three 64x64 `mulshr`
sites in `S_RQ_I1M1..I2M3`, plus `rmsnorm.vhd:355`:

```vhdl
om_32 := scale_mul(raw_j, to_signed(1, 32), shift_total);
```

a 64x32 multiply by the literal constant **1**, which Vivado implements rather
than strength-reduces because `scale_mul` is an opaque function call. The
identical waste class A's own review caught in a different unit.

## The load-bearing conditional: D's row

D §7.1 correctly refuses to instantiate `rmsnorm.vhd` (its `N*16` parallel
ports are an 81,920-bit bus at N=5120, the exact wall A §5 prohibits), so
there is **no double-count** of the 78 DSP inside D. D-vec is a streaming
reimplementation. That part is sound.

The problem is swiglu. D §7.3 says "silu reuses the Q15 sigmoid regeneration
B §1.5 already commissions". At `LANES_V = 8`, pass 1 produces 8 elements per
cycle, so swiglu needs **8 sigmoid evaluations per cycle**. The only sigmoid
in this project that has ever been synthesised is C's cone at **8 DSP per
lane**. Eight of those is **64 DSP for the nonlinearity alone**, against a
whole-D-vec estimate of 24-40 that also has to cover two norms and two
residual adds.

D's stated escape is that "swiglu shares the norm lanes (phases are disjoint,
so sharing is expected; 40 is the no-sharing bound)". **Sharing does not
reach this term.** It can share multipliers, but the norm phase contains no
sigmoid interpolator to share with, so the sigmoid is additive to whatever
the norm costs, not absorbed into it.

The available lever is the same one that saved C: **narrowing**. C's cone
copies `fixed_pkg.sigmoid_q` verbatim including its 64/128-bit intermediates,
and the analogous narrowing took `rmsnorm` from 78 DSP to 18, a 4.3x cut. A
Q15-in/Q15-out silu with 32-bit intermediates is plausibly 1-2 DSP per lane,
which would put 8 lanes at 8-16 and D's row back inside its estimate. **This
has not been built or measured, and D's estimate does not cite it.** Until it
is, treat 24-40 as a target rather than a budget.

## Measured and REJECTED, do not retry

- **Reusing `rmsnorm.vhd` verbatim for C's QK-norm.** 78 DSP and 138.4 MHz.
  A fifth of C's entire 384-DSP MAC array for a unit §2.8 had budgeted inside
  a 15-40 "auxiliary" line, and it misses timing by more than 2x.
- **Assuming `rmsnorm`'s cost scales with N.** It does not: 78 DSP at both
  N=128 and N=256. Sizing it from the vector length gives the wrong answer in
  both directions.
- **Treating D's "phases are disjoint, so sharing is expected" as covering
  swiglu's sigmoid.** Disjoint phases share multipliers, not function units
  that only one phase contains.
- **Reading D §12's 85.4-86.5% as current.** It predates C §3 by a day and
  omits the aux row's measured value. Use 87.2-88.2%.

## Measurement traps hit

- **`sim/ooc_micro.tcl` needs `fixed_luts_pkg.vhd` before `fixed_pkg.vhd`.**
  Omitting it fails as `package 'fixed_luts_pkg' not found`, immediately
  followed by `module 'rmsnorm' not found`, and the second error is the one
  that looks like the problem. It is not.
- **Every Fmax here is Vivado's 0.85 V analysis.** The card runs 0.717 V,
  where the measured derate is **-22.9%**
  (`2026-08-24_vccint-derate-and-exp-cone.md`). So 343 MHz becomes ~265 and
  138 becomes ~107. Any figure in this file compared against a 300 MHz target
  is being compared against a clock the card cannot supply.
- **OOC is not placed and routed.** These are synthesis estimates on isolated
  units, and the whole-die interaction (congestion above ~90%, which is why
  the line exists) is exactly what OOC cannot show.

## Open, not yet answered

- **The narrowed silu has not been measured.** It is the single measurement
  that would convert D's row from an estimate to a budget, and it is cheap:
  the same skeleton treatment `micro_rmsn_narrow.vhd` gave RMSNorm.
- **`rmsnorm` at N=5120** (D's layer-norm size) was launched and had not
  finished when this was written. The N-independence at 128/256 predicts 78
  again with a larger LUT term, but it is a prediction.
- **B's 138-152 has never seen synthesis.** It is the second-weakest row and
  nothing here improved it.
- **LUT is now the resource that grew and it is still a screening number.**
  C §3.8 moves the whole-die sum to ~270-290K of 439.7K (~62-66%), but three
  terms in it have never been synthesised. The adder-tree reclaim traded DSP
  for LUT (+346 LUT/row over 58 rows = +20K in A alone), so the direction of
  travel is against the weakest-measured resource.
- **Whether 90% is the right congestion line for this part.** It is cited by
  B §2.8 and C §2.8 and has been carried forward unexamined ever since; no
  placed-and-routed run on this die has tested it.
