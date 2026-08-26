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
2. **D's 24-40 DSP row lands at its ceiling, and only conditionally.**
   **CORRECTED the same day**: the first version of this section read the
   measured 8-DSP sigmoid cone as implying ~64 DSP for D's swiglu alone. That
   was right about the verbatim cone and wrong about the conclusion - the
   narrowed cone is **1 DSP** and a full swiglu lane is **3**, both measured
   and bit-identical to the wide form. D-vec is ~40 DSP if the norm and
   swiglu phases share one multiply chain and ~56 if they do not.

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
copies `fixed_pkg.sigmoid_q` verbatim including its 64/128-bit intermediates.

> **MEASURED 2026-08-25, later the same day. The lever works, and D's row
> survives at its upper bound.** `sim/micro/micro_silu_narrow.vhd`, same part
> and clock, verified **bit-identical** to the verbatim-width cone over 5,769
> outputs including both saturation corners (`sim/tb_silu_cone.vhd`).
>
> | form | DSP | Fmax | vs verbatim |
> |---|---|---|---|
> | `micro_sig_cone`, verbatim widths | 8 | 343.4 MHz | - |
> | narrowed, sigmoid only (`SILU=0`) | **1** | 510.7 MHz | **8x fewer DSP, 1.5x faster** |
> | narrowed silu, `x * sigmoid(x)` (`SILU=1`) | 2 | 646.0 MHz | |
> | narrowed **full swiglu lane**, `silu(g) * u` (`SILU=2`) | **3** | 646.0 MHz | |
>
> **The saving is not a tradeoff.** It is not an accuracy change (bit-identical
> by test, not by argument) and it is not a timing cost (the narrow form is
> *faster*, because the 64x64 multiply was also the critical path). The one
> thing that moves is 1 BRAM per lane, which SIG_ROM now infers instead of
> spending LUTs on; BRAM is not the constrained resource here.
>
> Why the bound is exact rather than a guess: over the shipped 513-entry
> SIG_ROM the table deltas are **monotone positive, min 8, max 16,771,757 <
> 2^24**, and `frac` is in `[0, 2^Q)` = `[0, 4096)` at Q=12. So the true
> product needs **2^36**, and a 25x13 multiply holds it exactly in **one
> DSP48E2** (27x18). The verbatim form declares `signed(64) * signed(64) ->
> signed(128)`, which is why it burns 8. No value is lost at any input.
>
> **So D's swiglu at `LANES_V = 8` is 24 DSP, not the ~64 this section
> feared.** The revised D-vec arithmetic, with the measured terms marked:
>
> | term | DSP | basis |
> |---|---|---|
> | 8 swiglu lanes x 3 | 24 | MEASURED per lane |
> | rsqrt, **shared** across lanes (one per vector, not per element) | ~6-9 | DERIVED from the 18-DSP 1-lane narrowed `rmsnorm` skeleton |
> | 8 norm per-element chains x ~3 | ~24 | DERIVED, same skeleton |
> | 2 residual adds | 0 | adders, no multiply |
>
> Norm and swiglu are **disjoint phases of the same per-lane multiply
> chain**, so D's sharing argument does hold for those 24 - the part it does
> not reach is the sigmoid interpolation, and that is now 1 DSP per lane
> rather than 8. Sharing: `24 + 8 + 8 = ~40`. No sharing: `24 + 24 + 8 = ~56`.
>
> **D's 24-40 therefore lands at its ceiling if the sharing is built, and
> ~40% over it if it is not.** That is a design obligation on D-vec, not a
> spare margin. Whole-die at the sharing figure is unchanged at 87.2-88.2%;
> at the no-sharing figure it is ~88.8%.

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

- **The rsqrt/per-element split inside D-vec is DERIVED, not measured.** The
  swiglu lane is measured at 3 DSP; the norm half is decomposed from C's
  1-lane skeleton by an argument about what is shared per vector versus per
  element. An 8-lane D-vec skeleton would settle it, and is the obvious next
  measurement now that the silu one is done.
- **Whether D-vec can actually share one multiply chain between the norm and
  swiglu phases.** The whole difference between 40 and 56 DSP rests on it, it
  is asserted in D §12 and nothing has been built.
- **`rmsnorm` at N=5120 will not be measured, and the failure is the answer.**
  The run was launched and died ~2 minutes into timing optimization having
  driven free physical memory from 8,396 MB to **243 MB**. At N=5120 the
  entity declares `x_mant`, `w_mant` and `o_mant` as `N*16` = **81,920 bits
  each**, three of them, which is precisely the parallel-bus wall A §5
  prohibits and precisely why D §7.3 refuses to instantiate this entity and
  specifies a streaming reimplementation instead. Retrying it would spend an
  hour and the whole box to price a configuration nobody will build. The DSP
  cost is already known to be N-independent from the N=128 and N=256 points,
  which is the number that mattered. **Do not retry.**
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

---

## CORRECTION 2026-08-25 (later the same day): D-vec is 28, not 40-56; the sum closes at 87.6%

**Withdrawn:** every "D-vec is ~40 shared / ~56 unshared" and every
"D, `LANES_V = 8` | 24-40" figure above. **Superseded by measurement.**

D-vec synthesised OOC on `xcvu33p-fsvh2104-2L-e` at 3.333 ns
(`sim/micro/micro_d_vec.vhd` + `sim/micro/micro_d_rsqrt.vhd`):

| term | shared | not shared |
|---|---|---|
| per-element lane, `LANES_V = 8` | 3/lane -> **24** | 5/lane -> 40 |
| rsqrt, one per vector | **4** | 12 |
| **D-vec** | **28** | 52 |

Linear in `LANES_V` with zero intercept over {2,4,8,16}; DSP census reconciled
with utilisation at all ten points.

**Corrected whole-die:**

```
1,914 (A) + 434 (C) + 148 (B, measured 2026-08-25) + 28 (D) = 2,524 of 2,880 = 87.6%
worst corner, D built with no sharing at all:                 2,548          = 88.5%
```

Both conditions in the summary above still stand, but condition 2 is now
resolved rather than open: **every corner of D's coding style fits under the
90% line**, so D is a 24-DSP efficiency question, not a fit risk. Condition 1
(C's QK-norm must not use `rmsnorm.vhd` as shipped) is unchanged and remains
the load-bearing one.

**Why the 40/56 was wrong, and it is a methodological error worth keeping.**
It was arithmetic over separately-measured parts: swiglu's 3/lane was real,
but the norm half was decomposed as "8 norm per-element chains x ~3 = ~24" and
the rsqrt as "~6-9". Synthesising the three phases *together* -- with `mode` as
a top-level PORT so the mux cannot constant-fold -- shows the norm phase needs
**2** concurrent multiplies, not 3, and that **both fit inside swiglu's 3 when
muxed, so the norm half adds zero DSP at all**. The rsqrt is 4, below the 6-9
low end. Summing separately-measured parts systematically overcounts a datapath
whose phases are disjoint, because the sum cannot see the collapse; that is
exactly the error the "open" item below anticipated when it said an 8-lane
D-vec skeleton would settle it.

The two "open, not yet answered" items above that this closes:
**"The rsqrt/per-element split inside D-vec is DERIVED, not measured"** and
**"Whether D-vec can actually share one multiply chain between the norm and
swiglu phases"** -- it can, and the sharing is a property of how the RTL is
written rather than something synthesis provides, so D §12's "sharing is
expected" is now recorded as normative.

Full procedure, evidence and traps:
`docs/debugging/2026-08-25_d-vec-dsp-measured.md`.
