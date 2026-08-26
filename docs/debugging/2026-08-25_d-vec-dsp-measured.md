# D-vec's DSP row, measured: 28 built to share, 52 if not, and every corner fits

**Date:** 2026-08-25
**Part:** xcvu33p-fsvh2104-2L-e, OOC, 3.333 ns (300 MHz), Vivado 2023.2
**Sources:** `sim/micro/micro_d_vec.vhd`, `sim/micro/micro_d_rsqrt.vhd`, harness `sim/ooc_micro.tcl`

## 1. The question

D section 12 carried `DSP48E2 | 24-40` for the whole of D, qualified with "depends on
`LANES_V` (8 assumed) and on whether swiglu shares the norm lanes (phases are
disjoint, so sharing is expected; 40 is the no-sharing bound)". On 2026-08-25 the
whole-die reconciliation superseded that upward to "~40 if the norm and swiglu
phases share one multiply chain, ~56 if they do not", and listed the sharing itself
as open: *"Whether D-vec can actually share one multiply chain between the norm and
swiglu phases. The whole difference between 40 and 56 DSP rests on it, it has not
been synthesised."*

D was the last unsynthesised DSP row in the whole-die sum. This closes it.

## 2. The answer

**D-vec at `LANES_V = 8` is 28 DSP48E2 when built to share, 52 when not.**
Both are below both prior figures. The whole-die DSP sum is
**2,524 of 2,880 = 87.6%** under sharing and **88.5%** at the worst corner, so
**every corner of D's coding style now fits under the 90% congestion line** -- the
sharing question is worth 0.9 percentage points, not a fit decision.

Two separately measured terms:

| term | shared | not shared | scaling |
|---|---|---|---|
| per-element lane (norm p1, norm p2, residual requant, swiglu) | **3/lane -> 24** | 5/lane -> 40 | x `LANES_V` |
| rsqrt, one per vector | **4** | 12 | fixed |
| **D-vec total** | **28** | 52 | |

**Sharing is a property of how the RTL is written, not something synthesis
provides.** Both numbers came out of the same tool on the same part; the only
difference is whether the phases are expressed as one mode-muxed datapath or as
separate per-phase datapaths. D section 12's "sharing is expected" must therefore be
read as a normative requirement on D-vec's RTL.

## 3. Procedure

Two skeletons, priced the same way `micro_b_lane` / `micro_c_lane` priced units that
did not exist yet: the multiply *shapes* are real, control is a free-running counter
so synthesis cannot fold an operand to a constant, and the output is an XOR-fold
digest so nothing is pruned. Neither is functional.

**`micro_d_vec.vhd`** -- the per-element lane. Generics `LANES_V` and `SHARE`.
The critical modelling decision: **`mode` is a top-level port, not a generic.** As a
generic it would constant-fold and the mux would vanish, which would have measured
the shared cost by construction -- the exact failure mode this whole exercise exists
to avoid. The three phases as modelled:

| `mode` | phase | concurrent multiplies |
|---|---|---|
| `00` | RMSNorm | `x*x` (sum of squares), `x*scale` (apply) -- 2 |
| `01` | residual requant | `x*scale`, `u*scale` -- 2 |
| `10` | swiglu | ROM interp `x*i`, silu `g*sigmoid`, then `*u` -- 3 |

Peak concurrency is 3, set by swiglu, which is why the muxed lane costs exactly what
the swiglu lane alone was already measured to cost.

`SHARE = 1` muxes operands into 3 physical multiply sites; `SHARE = 0` instantiates
each phase's multiplies separately (5 sites: 2 norm + 3 swiglu, residual reusing
norm's). rsqrt is deliberately **excluded** from the lane -- it is one per vector,
not per element, and pricing it inside the lane would multiply a fixed cost by 8.

**`micro_d_rsqrt.vhd`** -- the excluded fixed term, so it is added rather than
guessed. `y <- y*(3 - s*y^2)/2` in Q30 at `micro_rmsn_narrow`'s narrowed widths
(33x32 rather than 64x64). Generic `SHARE_ND` asks the same coding-style question of
the three Newton multiplies. **There is deliberately no iteration-count generic:**
the real unit runs several Newton steps through one datapath, so DSP cost is set by
the number of physical multiply *sites*, not by iteration count.

Sweep: `LANES_V` in {2,4,8,16} x `SHARE` in {1,0}, then `SHARE_ND` in {1,0}. The
four `LANES_V` points exist to confirm the per-lane cost is actually constant -- a
single point at 8 cannot distinguish a per-lane term from a fixed one.

## 4. Evidence

```
MICRO micro_d_vec_LANES_V2_SHARE1   DSP=6  (census 6)   LUT=96   FF=192   WNS=1.084  Fmax=444.6 MHz
MICRO micro_d_vec_LANES_V4_SHARE1   DSP=12 (census 12)  LUT=160  FF=320   WNS=1.084  Fmax=444.6 MHz
MICRO micro_d_vec_LANES_V8_SHARE1   DSP=24 (census 24)  LUT=320  FF=576   WNS=1.084  Fmax=444.6 MHz
MICRO micro_d_vec_LANES_V16_SHARE1  DSP=48 (census 48)  LUT=608  FF=1088  WNS=1.084  Fmax=444.6 MHz
MICRO micro_d_vec_LANES_V2_SHARE0   DSP=10 (census 10)  LUT=128  FF=96    WNS=1.054  Fmax=438.8 MHz
MICRO micro_d_vec_LANES_V4_SHARE0   DSP=20 (census 20)  LUT=224  FF=160   WNS=1.054  Fmax=438.8 MHz
MICRO micro_d_vec_LANES_V8_SHARE0   DSP=40 (census 40)  LUT=448  FF=288   WNS=1.054  Fmax=438.8 MHz
MICRO micro_d_vec_LANES_V16_SHARE0  DSP=80 (census 80)  LUT=864  FF=544   WNS=1.054  Fmax=438.8 MHz

MICRO micro_d_rsqrt_SHARE_ND1  DSP=4  (census 4)   LUT=214  FF=229  CARRY8=11  WNS=0.603  Fmax=366.3 MHz
MICRO micro_d_rsqrt_SHARE_ND0  DSP=12 (census 12)  LUT=239  FF=232  CARRY8=23  WNS=0.920  Fmax=414.4 MHz
```

DSP census reconciled with utilisation at all ten points, so the counts are
believable in the sense `sim/ooc_micro.tcl` was built to check.

Exactly linear in `LANES_V` at 3 and 5 DSP/lane, with zero intercept -- so the
per-element term is genuinely per-element and the fixed term is genuinely all in
rsqrt. LUT is likewise linear (~40/lane shared, ~56/lane unshared) after a small
offset.

**Sharing is also cheaper in LUT and free in timing.** 320 vs 448 LUT at
`LANES_V = 8`: the mode mux costs less than the extra multipliers' support logic.
Fmax is *higher* shared (444.6 vs 438.8 MHz) because fewer DSPs means less routing,
so the usual "sharing costs speed" intuition does not apply at this scale. The one
place it does apply is the rsqrt, where muxing drops 414.4 -> 366.3 MHz -- still
comfortably over 300.

## 5. Whole-die DSP, with the last estimate removed

| corner | D-vec | whole-die of 2,880 |
|---|---|---|
| **lane + rsqrt both shared** (the design obligation) | **28** | **2,524 = 87.6%** |
| lanes shared, rsqrt not | 36 | 2,532 = 87.9% |
| lanes not shared, rsqrt shared | 44 | 2,540 = 88.2% |
| neither shared | 52 | 2,548 = 88.5% |

A 1,914 (`ROWS_IF = 58`, post-reclaim) + C 434 (384 MAC + 50 aux) + B 148
(`LANES = 32`) + D. **Every term in this sum is now measured.** E is absent from it
because it is 0 DSP by construction, its accumulator being an adder tree
(A section 15.4b) -- a construction argument, not a synthesis result.

## 6. Measured and REJECTED -- do not retry

- **"D-vec is ~40 shared / ~56 unshared"** (the 2026-08-25 whole-die reconciliation,
  earlier the same day). Withdrawn. It was arithmetic over separately-measured
  pieces: swiglu's 3/lane was measured, but the norm half was decomposed from C's
  narrowed `rmsnorm` skeleton as "8 norm per-element chains x ~3 = ~24" and the
  rsqrt as "~6-9". Both were too high. The norm phase needs **2** concurrent
  multiplies per element, not 3, and -- the part arithmetic over parts cannot see --
  **both of them fit inside swiglu's 3 when muxed, so the norm half adds zero.**
  The rsqrt is 4, below the 6-9 low end. Summing separately-measured parts
  systematically overcounts a datapath whose phases are disjoint; only synthesising
  the phases together measures the collapse.
- **Pricing rsqrt inside the lane.** It is one per vector. At `LANES_V = 8` that
  would have inflated a 4-DSP fixed term to 32 and put D-vec at 56 -- which is
  approximately how the superseded 56 arose.
- **`rmsnorm.vhd` as shipped for any of this.** 78 DSP, N-independent, 138.4 MHz
  (measured 2026-08-25). Already rejected for C's QK-norm; it is equally
  disqualifying here, and D section 7.1 was right to refuse to instantiate it.

## 7. Measurement traps hit

- **A generic `mode` would have measured the answer by construction.** With `mode`
  as a generic, every `case` arm but one is dead code, the mux disappears, and
  `SHARE = 1` reports 3 DSP/lane for a reason that has nothing to do with sharing.
  Making it a port is the entire validity of the shared number. The same trap
  applies to any future skeleton with a phase selector.
- **A single `LANES_V` point cannot separate per-lane from fixed cost.** 24 DSP at
  `LANES_V = 8` is equally consistent with 3/lane + 0 fixed and with 2/lane + 8
  fixed. The four-point sweep is what shows the intercept is zero, and it is what
  justifies quoting the rsqrt separately rather than assuming it was already
  included.
- **Fewer DSPs came out *faster*, in both the lane sweep and against intuition.**
  Reading Fmax as evidence against sharing would have been wrong here. The multiply
  was not the critical path at these widths; routing was.

## 8. Open, not yet answered

- **The lane models D-vec's arithmetic as D section 7 describes it.** If the real
  unit needs a fourth concurrent multiply in some phase -- for instance a residual
  add live at the same time as swiglu rather than sequenced after it -- the shared
  number rises above 3/lane. The measurement bounds the coding-style question, which
  was the open one; it does not validate the phase decomposition itself.
- **D-ctrl is asserted at 0 DSP and has not been synthesised.** D section 12 states
  it; nothing here tests it.
- **E is not in the whole-die sum.** Assumed ~0 DSP, unmeasured.
- **rsqrt's seed is taken from the input stream, not a LZC + ROM.** A real seed
  table is BRAM/LUT and would not move the DSP answer, but it does mean the LUT and
  Fmax figures for `micro_d_rsqrt` are floors.
- **Nothing here is placed and routed.** These are OOC synthesis numbers on a part,
  at a clock, with no neighbours. Whether 90% is even the right congestion line for
  this part remains untested by any full build.
