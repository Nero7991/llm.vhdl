# The clock target was set at a voltage the card does not run at

**Date:** 2026-08-27. Part `xcvu33p-fsvh2104-2L-e`, OOC synthesis, 3.3 ns.

## The question

Subsystem A's DSP budget rests on `matvec_core` at `ROWS_IF = 58`, a
configuration that had **never been synthesised**. The 1,914 DSP figure was
`33.00 x 58` extrapolated 1.8x past the last real data point, with no Fmax at
all. Does it fit, and does it close?

## The answer

**The DSP extrapolation is exactly right and the clock is not.** `ROWS_IF = 58`
measures **DSP = 1914**, matching `33.00 x 58` to the unit. But it reaches only
**237.8 MHz at the voltage the FK33 actually runs at**, against a 299.04 MHz
target, and **Fmax barely moves with `ROWS_IF` at all**.

The dominant term is not the array size. It is the undervolt.

## The evidence

Identical netlist, `ROWS_IF = 58`, DSP 1914, LUT 134675, FF 64089, BRAM 26.
Only the analysis voltage differs, applied after synthesis so this is a pure
voltage derate of one netlist rather than two differently-optimised ones:

| VCCINT | WNS ns | Fmax MHz |
|---|---|---|
| 0.85 (Vivado default) | -0.210 | **284.9** |
| 0.717 (the FK33's actual operating point) | -0.905 | **237.8** |

**The undervolt costs 47.1 MHz, 16.5%.**

And at 0.717 V, across a 1.8x change in array size:

| `ROWS_IF` | DSP | LUT | Fmax MHz |
|---|---|---|---|
| 32 | 1,056 | 73,599 | 236.3 |
| 40 | 1,320 | 92,133 | 240.6 |
| 48 | 1,584 | 112,712 | 236.1 |
| 58 | 1,914 | 134,675 | 237.8 |

**A 1.8x change in size moves Fmax by 4.5 MHz, under 2%.** DSP per row is
exactly 33.00 at every point, so the array scales perfectly in area and not at
all in speed.

## Why this matters more than any single unit's timing

Every Fmax in the master spec is a **0.85 V, synthesis-only** number. The card
does not run at 0.85 V and it will not: `docs/debugging/2026-08-24_fk33-sysmon-
vccint-undervolt.md` records it powering up at 0.678 V against a 0.698 V floor,
raised by hand to **0.717 V**, and a later measurement refuted SQRL's own
0.85 V claim outright. 0.717 V is the operating point, not a conservative
choice that can be walked back.

So the 299.04 MHz target was set in a regime the hardware never occupies. At
the real voltage:

- A's `matvec_core` reaches 237.8 MHz.
- B's emit chain reaches 254.3 MHz **post-route at 0.85 V**, so its real number
  is lower again and has not yet been measured at 0.717 V.

The whole-design clock is therefore set by A at roughly **238 MHz**, which is
**20.5% below** the figure every cycle budget in the spec is divided by. A
39 ms token budget derived at 299.04 MHz is a **49 ms** token at 237.8 MHz
before anything else is counted.

## What this does NOT say

- It does not say the design is infeasible. It says the budgets are indexed to
  the wrong clock and need re-deriving at ~238 MHz.
- It does not say `ROWS_IF = 58` is wrong. Since Fmax is flat, the DSP is the
  only thing `ROWS_IF` buys or costs, so the choice is a pure area-versus-cycles
  trade with no clock term. 58 remains the right pick if the DSP fits, and at
  9B it does: 1,914 + C 303 + B 227 + D 28 = 2,472 of 2,880, **85.8%**.
- It does not establish what the 0.717 V critical path IS. The flatness across
  `ROWS_IF` says only that it is not the array.

## Measured and REJECTED -- do not retry

- **Reducing `ROWS_IF` to recover clock.** 32 versus 58 is 858 fewer DSP for
  **1.5 MHz**. Whatever the argument for a smaller array, it is not timing.
- **The claim that `ROWS_IF = 32` reaches 275.3 MHz at 0.717 V**, which appears
  in `docs/2026-08-27_9b-single-card-resource-envelope.md` section 6. Measured
  here at **236.3 MHz**. That figure should be treated as withdrawn.
- **Quoting a 0.85 V Fmax as if it were achievable.** Every such number in this
  project carries a hidden 16.5%.

## Measurement traps hit

- **An extrapolation can be exactly right on one axis and silent on another.**
  `33.00 x 58 = 1914` was correct to the unit. The same extrapolation carried no
  Fmax at all, and Fmax is where the problem was. A model that fits one output
  is not validated for the outputs it never predicted.
- **Vivado's default analysis voltage is not the board's voltage**, and nothing
  in a normal report says so. The `volt=` argument to `sim/ooc_core_sweep.tcl`
  exists for exactly this and should be used for every number that will be
  quoted. Its own header says so and it was still not used for the figures the
  budgets were built on.

## Open, not yet answered

- **What the 0.717 V critical path is.** Not measured. Flat across `ROWS_IF`,
  which rules out the array and nothing else.
- **B's emit chain at 0.717 V.** All of its numbers are 0.85 V. Its post-route
  254.3 MHz is therefore optimistic by an unknown amount up to about 16.5%.
- **Whether the target should be lowered deliberately** rather than chased.
  At 9B the state sweep is 393,216 cycles, which is 1.65 ms even at 238 MHz, so
  B has ample margin; the question is entirely about A and C.
- **Nothing here is post-route.** These are OOC synthesis figures, and the one
  post-route measurement taken today lost 46 MHz against its synthesis number.
