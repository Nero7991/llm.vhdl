# The LUT blind spot, closed as far as it can be

**Date:** 2026-08-25
**Part:** xcvu33p-fsvh2104-2L-e on SQRL FK33
**Question:** the whole-die LUT sum was ~270-290K of 439.7K with "three terms
that have never seen synthesis". Is there a fit risk?

## The answer

**No LUT fit risk. DSP is the binding resource and LUT is not close.**

- **Whole-die LUT: 266.6K of 439.7K = 60.6%**, and **76% of that total is now
  MEASURED** rather than estimated (202.6K measured, 64.0K guessed).
- Even **doubling every remaining guess** lands at ~330K = 75%, still fitting.
- Against DSP at **87.2-88.2%**, which is the resource actually near its line.

The denominator is confirmed: `get_property` on the placed design reports
**439,680** CLB LUTs, so the spec's 439.7K was right.

## What was actually blind, and what was not

The "three unsynthesised terms" framing was misleading in both directions.
Several terms called estimates already had measured micro-benchmarks in
`sim/ooc_micro/` whose LUT columns had never been collated into the sum; and
the terms that genuinely cannot be measured are not three but five, because
**B, C, D and E do not exist in RTL at all.** Those cannot be synthesised, so
this is as closed as the question gets until subsystems are written.

| sub | term | LUT | status |
|---|---|---|---|
| A | `matvec_core`, 58 rows x 2,223 | 128,934 | MEASURED |
| A | HBM weight streamer | 10,000 | GUESS (no RTL at FK33 scale) |
| C | MAC array, 192 lanes | 59,625 | **MEASURED, 5-point PnR fit** |
| C | exp cone, pipelined | 630 | MEASURED |
| C | sigmoid cone Q15 | 1,062 | MEASURED |
| C | IMROPE rotation kernel | 2,330 | MEASURED |
| C | QK-norm `rmsnorm_rs`, narrowed | 385 | MEASURED |
| C | stream unpackers/aligners | 4,000 | GUESS |
| C | quantizer/control | 8,000 | GUESS |
| B | GDN lanes, 32 x 50 | 1,600 | MEASURED |
| B | conv/state buffers, marshalling, control | 25,000 | GUESS (no RTL) |
| D | D-vec swiglu, 8 lanes x 954 | 7,632 | MEASURED |
| D | D-vec rmsnorm, narrowed | 385 | MEASURED |
| D | sequencer FSM, descriptors, region ports | 12,000 | GUESS (no RTL) |
| E | TP collective | 5,000 | GUESS (no RTL) |
| | **total** | **266,583** | **60.6% of 439,680** |

### C's MAC array: the one term that moved on real evidence

`micro_c_array_p` was synthesised AND placed-and-routed at five lane counts:

| LANES | 4 | 8 | 16 | 32 | 64 |
|---|---|---|---|---|---|
| LUT | 1,192 | 2,511 | 4,993 | 10,029 | 19,844 |
| DSP | 8 | 16 | 32 | 64 | 128 |

Linear fit **310.5 LUT/lane with +14 fixed** -- essentially pure per-lane cost,
no array overhead term. At `MACS = 192` that is **59.6K**.

C §3.8 built its C figure from the single-LANE fit instead, `192 x (158 +
10 x ACC_N)` = 45.7K at `ACC_N = 8`, then added separate score-tree and
Q-plane-mux terms. **The array measures 30% above what the lane fit predicts**,
so the per-lane extrapolation was optimistic and the separate structural terms
were partly double-counting what the array already contains.

### The direction of error in the guesses

Where a guessed term could be checked against a measured micro, **the guess was
high, consistently and by a lot**:

| term | C §3.8 guessed | measured | ratio |
|---|---|---|---|
| cones + rope + gate | ~6,000 | 4,022 | 1.5x high |
| `rmsnorm_rs` | ~8,000 | 385 | **21x high** |

`rmsnorm_rs` is the striking one: the narrowed unit is 385 LUT and was budgeted
at 8K. That is the same narrowing lever that took swiglu from 8 DSP to 1, and
its LUT saving had not been propagated either.

Two errors in opposite directions -- array 30% under, small units several times
over -- which is why C's total (76K here vs its own ~80K) barely moved while
both of its components were wrong.

## The FK33 shell, measured for the first time

Taken from the running 30-port bandwidth design
(`bd_wrapper_utilization_placed.rpt`), so this is a real placed design on the
real part, not a datasheet figure:

| resource | shell | available | % |
|---|---|---|---|
| CLB LUTs | 14,921 | 439,680 | 3.39% |
| CLB Registers | 22,608 | 879,360 | 2.57% |
| BRAM tiles | 10.5 | 672 | 1.56% |
| URAM | 0 | 320 | 0.00% |
| **DSPs** | **0** | **2,880** | **0.00%** |

That 14,921 **includes the 30-port traffic generator**, so the pure shell
(XDMA/PCIe, HBM IP, smartconnects, clocking, SYSMON, IIC) is smaller still.

**The shell uses no DSP whatsoever**, which matters because DSP is the binding
resource: the whole 2,880 is available to the engine and the 87.2-88.2% figure
needs no shell derate. Nobody had checked this; it could easily have gone the
other way and cost several percent off the tightest budget in the project.

Engine LUT against a shell-adjusted denominator: 266.6K of ~425K = **63%**.

## Measured and REJECTED -- do not retry

- **"The LUT sum is a fit risk."** It is not. 60.6% with 76% measured, and 75%
  under a doubling of every guess. The screening number was pessimistic
  primarily because `rmsnorm_rs` was carried at 21x its measured cost.
- **Synthesising B, C, D or E to close the remaining 64K.** They have no RTL.
  The remaining guesses cannot be measured until the subsystems are written;
  this is not a missing synthesis run.

## Open, not yet answered

- **The 64K of guessed terms**, all in subsystems with no RTL: A's HBM
  streamer (10K), C's unpackers and quantizer/control (12K), B's non-lane
  logic (25K), D's sequencer (12K), E (5K). Direction of error, where it has
  ever been checkable, has been HIGH.
- **DSP remains the real constraint at 87.2-88.2%**, and B's 138-152 row has
  still never seen synthesis. That is the number worth attacking next, not LUT.
- **Whether 90% is the right congestion line for this part** -- still cited by
  B §2.8 and C §2.8 and still untested by any placed-and-routed run.
