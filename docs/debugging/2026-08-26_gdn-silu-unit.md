# Building B's silu unit: two width bugs, a signed slice, and a metric that lied

**Date:** 2026-08-26
**Hardware/build:** `xcvu33p-fsvh2104-2L-e`, Vivado 2023.2, OOC synth at a
3.0 ns period. GHDL 5.x for simulation.
**Unit:** `rtl/gdn_silu.vhd`, new. Reference `ref/gdn_silu_vec.c`, new.
Testbench `sim/tb_gdn_silu.vhd`, new. Sweep `sim/ooc_gdn_silu.tcl`, new.

## The question

B spec §2.1.3 pins silu as

```
x_q12 = Q12(sm, e)                                 -- site 3's conversion rule
sm'   = round_shift( sm * sigma_q15(x_q12), 15 )   -- exponent PRESERVED
```

§3.2 prices it at a 3-cycle FSM rate, 1,179,648 cycles = 3.93 ms per token per
card, the second largest term in B's whole budget. §3.3 argues the rate must be
"at least 1 per cycle and preferably 4" and budgets 98,304 cycles = 0.33 ms,
but says plainly of its own schedule: **"Neither figure is a demonstration."**
Nothing in this repo implemented it.

So: what does a real silu unit cost, and does the assumed rate hold?

## The answer

**2 DSP and 0.5 BRAM36 per lane, 391.8 MHz, II = 1, bit-exact against a C
reference at every lane count in {1, 2, 4, 8, 16, 32}.** At `LANES = 4` that is
**8 DSP, 2 BRAM, 98,304 cycles = 0.33 ms**, which confirms §3.3's assumed rate
and §2.8's DSP row exactly, and improves on §2.8's BRAM row by 2x.

| `LANES` | DSP | LUT | FF | BRAM36 | Fmax | cycles/token/card | ms @ 300 MHz |
|---|---|---|---|---|---|---|---|
| 1 | 2 | 1,336 | 112 | 0.5 | 391.8 | 393,216 | 1.311 |
| 2 | 4 | 2,478 | 217 | 1.0 | 391.8 | 196,608 | 0.655 |
| **4** | **8** | **4,818** | **419** | **2.0** | **391.8** | **98,304** | **0.328** |
| 8 | 16 | 9,394 | 831 | 4.0 | 391.8 | 49,152 | 0.164 |
| 16 | 32 | 19,122 | 1,655 | 8.0 | 391.8 | 24,576 | 0.082 |

`DSP = 2 x LANES`, `BRAM = 0.5 x LANES`, and Fmax is flat to 16 lanes.

## The procedure that produced it

1. **Write the C reference first, with a DOUBLE oracle.** Not a second integer
   path: a second integer path agrees with a wrong recipe. `ref/gdn_silu_vec.c`
   emits the vectors and separately measures the recipe against
   `x / (1 + exp(-x))` in double.
2. **Sweep `e` over a band that reaches both branches and both rails**, not
   just the comfortable middle. The generator stratifies `e` at -30, -12, 12
   and 40 plus a random band. This is what the `gdn_scalar` work already paid
   for: an independent golden over a biased input distribution still certifies
   broken guards.
3. **Testbench checks bit-exactness ONLY.** Accuracy is measured in the
   generator and printed there. Keeping them apart is deliberate: a testbench
   that checks accuracy cannot detect a wrong recipe, because a wrong recipe
   that is accurate enough passes.
4. **Simulate at every lane count** before believing any of them. `LANES` is
   the one parameter that can silently drop elements from a group loop.
5. **Synthesize across `LANES` and read DSP, BRAM and Fmax**, because the cost
   model (`2 x LANES`) is the deliverable, not the single configuration.

## The evidence

```
gdn_silu: bit-exact with the C reference on all 8192 groups (32768 elements),
          LANES=4 ARG_Q=12
```

Generator, over 256 cases x 128 elements:

```
worst abs err vs double oracle: 1.8442 LSB
worst rel err where |y| >= 16 LSB: 4.949e-02
Q12 saturations: 13228   nonzero flushed to zero: 7464
```

## Measured and REJECTED -- do not retry

- **Narrowing the interpolation delta ALONE does not reduce DSP.** The delta was
  declared 32 bits; the table's largest adjacent difference is 16,771,757, just
  under 2^24, so 25 bits signed is exact. Narrowing it moved LUT 1,436 -> 1,336
  and FF 162 -> 116 and left **DSP at 3 per lane, unchanged**. Anyone stopping
  there would correctly conclude "narrowing does not help" and would be wrong.
- **The `--pinned`-style "measure one thing at a time" instinct is what makes
  this trap dangerous.** There were TWO over-wide declarations, each costing one
  DSP per lane. `sig` held 0..32768 but was declared 32 bits, so `sm * sig` was
  16x32 and needed two DSP48E2s; at 18 bits it is 16x18, exactly the
  primitive's B port. Only after **both** narrowings is it 2 DSP per lane.
- **A naive scaling from D's swiglu lane gives the wrong number.** D's lane is
  3 DSP because it is `silu(g) * u`; B needs the bare `x * sigmoid(x)`, which
  §2.8 already recorded as `micro_silu_narrow` with `SILU = 1` at 2 DSP. §3.3
  cites the 3-DSP figure **without that qualifier**, which is what made 12 look
  plausible when this unit first measured 12. The two spec sections do not
  contradict each other, but only §2.8 carries the distinction.

## Measurement traps hit, including my own

- **Relative error reported 33% on a correct result.** The first metric in the
  generator was plain relative error against the oracle. It flagged a case whose
  true value is **1.5 LSB of its own grid**, where half-LSB rounding is
  arithmetically 33%. That is the quantizer working, not an error. This is the
  same shape as measuring a grid defect in LSB of the grid it corrupts, which
  this project hit two days earlier on `gdn_recur`'s `eg = 0` site. The fix is
  two metrics: **absolute LSB always**, relative **only** where the magnitude is
  clear of the grid.
- **The 4.9% relative error that survives is real but must be quoted with its
  qualifier.** A full-domain sweep over every `(sm, e)` pair, 3.3M samples,
  puts the worst at `sm = -30418, e = 12`, i.e. `x = -7.426`:

  ```
  true sigma  = 5.9505e-4
  sigma_q15   = 20        (= 6.1035e-4)     <- 19.5 rounded up
  y = -19                 true = -18.100
  ```

  **Q15 cannot resolve sigma in the deep negative tail**: at sigma ~ 6e-4 the
  grid step is 4% of the value. It does not threaten the pinned Q15 choice,
  because `|silu(x)|` there is 0.06% of `|x|` and the absolute error stays under
  1.85 LSB. But "5% relative error on silu" without the qualifier would lead a
  reader to the wrong conclusion.
- **A signed slice produced a negative ROM index for half the table.** `off` was
  computed as `signed` and sliced; `to_integer` then read the top bit as a sign,
  so every argument in the upper half of the table indexed negative. GHDL caught
  it as a bound check. **In hardware it would have been a silently wrong ROM
  address**, and the output would have been plausible. It is `unsigned` now,
  with the reason written at the site.

## Two things worth keeping from the design

- **The index needs no multiply.** `fx.h` computes `idx_fp = (z + 16*one_q)*16`
  then `k = idx_fp >> q` and `frac = idx_fp - (k << q)`. At `q = 12` that is
  exactly `k = off >> 8` and `frac = off(7 downto 0) & "0000"`. Bit-identical,
  and it removes a multiply and a wide shift from every lane.
- **The delta bound is asserted at elaboration, not trusted.** A regenerated
  `SIG_ROM` at a coarser grid or a wider Q would overflow the 25-bit path; the
  unit fails the build rather than wrapping.

## Open, not yet answered

- **`ARG_Q` is a generic and only Q12 has been measured.** §2.1 pins 12 and
  argues silu's error does not compound, unlike the scalar path's, which was
  moved to Q18. That argument has not been tested here the way `SP_Q`'s was.
- **The lane count is not chosen.** §3.3's bundle assumes 4. At 8 lanes silu
  costs 8 more DSP and buys 49,152 cycles, which would take the bundle's margin
  from +36% to roughly +53%. The die is at 90.5-91.9%, so that is not free and
  the trade has not been made.
- **`sigma_q15` is Q12-in / Q15-out, which the shipped `fixed_pkg` table is
  not.** This unit reads the same Q30 `SIG_ROM` with a Q12 index and rounds to
  Q15, so nothing needs regenerating and nothing needs keeping in step. B's
  reuse table still describes the shipped Q12-in/Q12-out form as needing
  regeneration; that item is discharged by construction, not by a new table.
- **No schedule has been exhibited.** This unit's rate makes §3.3's budget
  arithmetic sound, but §3.3's own caveat stands: nothing has yet demonstrated
  that silu, the norms, the L2 and conv actually overlap under the sweep.
