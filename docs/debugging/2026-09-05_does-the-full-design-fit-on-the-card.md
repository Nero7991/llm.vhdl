# Does the full inference design fit on the card alongside the PCIe shell?

Date: 2026-09-05. Part: `xcvu33p-fsvh2104-2L-e` (SQRL FK33). Monolithic, not SSI.

## The question, verbatim

Nobody had asked it. The bitstream goal has been pursued as a timing problem for
weeks, and the shipping bitstream contains the shell plus subsystem A only. The
question is whether the thing being aimed at can physically be placed at all:

> Does shell + subsystem A + B + C + D fit on the xcvu33p?

## The answer, up front

**On hard resources, yes, with room. On CLB occupancy, only if the placer packs
7.7% tighter than it has ever had to on this design.**

| resource | shell | A+B+C+D | TOTAL | device | % |
|---|---|---|---|---|---|
| LUT  | 50,999 | 263,544 | 314,543 | 439,680 | **71.5** |
| FF   | 62,065 | 245,425 | 307,490 | 879,360 | 35.0 |
| BRAM | 69.0   | 253.5   | 322.5   | 672     | 48.0 |
| URAM | 0      | 0       | 0       | 320     | 0.0 |
| DSP  | 0      | 2,177   | 2,177   | 2,880   | **75.6** |
| CLB sites | 10,446 | 49,620 | 60,066 | 54,960 | *109.3 (see trap 1)* |

DSP is the tightest hard resource at 75.6% and LUT is next at 71.5%. Neither is
a blocker. **The binding constraint is CLB occupancy, and it does not appear in
any percentage above**, because CLB sites are not additive (trap 1).

The composed design ALONE already occupies **49,620 of 54,960 CLB sites, 90.3%
of the device**, at a packing density of 5.31 LUT/CLB. Fitting 314,543 total LUT
into 54,960 CLBs requires **5.72 LUT/CLB**. That is achievable, since the
architectural maximum is 8, but it means the placer is left with essentially no
freedom to spread. In a design that is already at **congestion Level 5** in
`c_attn/u_arr` and missing 200 MHz by 0.4 ns, removing the placer's spreading
freedom is the opposite of what the timing needs.

**So the fit is real but the margin is not where the LUT percentage suggests.**
71.5% LUT reads comfortable; 90.3% CLB on the engine alone does not.

## The procedure

Every figure below is same-stage. That is the whole method, and getting it wrong
is what would have produced a wrong answer (trap 2).

1. Read the shipping build's full-design utilization at `Physopt postRoute`.
2. Read subsystem A's utilization **from the same run, same stage**, via
   `report_utilization -cells [get_cells bd_i/eng]`. This is what makes the
   subtraction legitimate.
3. Derive the shell alone as (2) subtracted from (1).
4. Read the composed A+B+C+D design's **routed** utilization from the `c4nd`
   run's `C4_UTIL ... routed` sentinel. Not synthesis (trap 3).
5. Sum (3) and (4) and compare against the part.

Cross-check that steps 1-2 and step 4 describe the same subsystem A: the DSP
count is **1,585 in both** the shipping build and the composed top's `a_eng`
hierarchy row. Hard blocks are stage-stable and design-specific, so an exact
match is strong evidence the two contexts hold the same A. Had these differed,
the subtraction would have been meaningless.

## The evidence

Shipping build, `Physopt postRoute`, full design:

```
| CLB LUTs                   | 182249 |     0 |          0 |    439680 | 41.45 |
| CLB Registers              | 125824 |     0 |          0 |    879360 | 14.31 |
| CLB                        |  34113 |     0 |          0 |     54960 | 62.07 |
| Block RAM Tile    | 261.5 |     0 |          0 |       672 | 38.91 |
| URAM              |     0 |     0 |          0 |       320 |  0.00 |
| DSPs           | 1585 |     0 |          0 |      2880 | 55.03 |
```

Same run, same stage, `-cells [get_cells bd_i/eng]` (subsystem A alone):

```
| Command      : report_utilization -cells [get_cells bd_i/eng] -file fk33_pcieep_engine_util.rpt
| Design State : Physopt postRoute
| CLB LUTs                   | 131250 |     0 |          0 |    439680 | 29.85 |
| CLB Registers              |  63759 |     0 |          0 |    879360 |  7.25 |
| CLB                        |  23667 |     0 |          0 |     54960 | 43.06 |
| Block RAM Tile    | 192.5 |     0 |          0 |       672 | 28.65 |
| DSPs           | 1585 |     0 |          0 |      2880 | 55.03 |
```

Composed A+B+C+D, `c4nd` run, routed:

```
C4_UTIL c4nd routed lut 263544 lut_logic 236227 lut_mem 27317 ff 245425 \
        carry8 12505 f7 20212 f8 3961 bram 253.5 uram 0 dsp 2177 clb 49620
```

Derived shell (DERIVED, same-stage subtraction):
`lut 50999  ff 62065  bram 69.0  uram 0  dsp 0  clb 10446`

Packing densities achieved when each was placed with room to spread:
composed **5.31** LUT/CLB, A alone **5.55**, shell alone **4.88**.
Density required to fit the sum: **5.72**.

## Measured and REJECTED, do not retry

- **Do not read 109.3% CLB as a proof of non-fit.** It is the sum of two
  independently-placed designs' occupancy and the placer does not work that way.
  It is a signal about placer freedom, not a capacity verdict. The capacity
  verdict comes from LUT (71.5%) and DSP (75.6%).
- **Do not use the composed design's SYNTHESIS utilization for this.** It reports
  350,283 LUT against the routed 263,544, a 25% over-count. Substituting it gives
  a total of 401,282 LUT = **91.3%**, which reads as "nearly full" and is wrong
  by 87,000 LUT. The fit question and the timing question both get a different
  answer from it. Synthesis LUT is not a placement result.
- **Do not derive the shell by subtracting a synthesis A from a placed shell+A.**
  It mixes stages in the direction that under-states the shell.

## Measurement traps hit

1. **CLB site counts are not additive, and no percentage column says so.** Every
   other row in `report_utilization` is a count of instantiated primitives and
   sums correctly. `CLB` is a count of *occupied sites*, which is a placement
   outcome that depends on how much room the placer had. Summing it is the one
   arithmetic the table invites and does not support. It is still the most
   informative row here, because 90.3% for the engine alone is the fact that the
   comfortable 71.5% LUT figure conceals.
2. **The stage discipline this project already records applies to area, not only
   to timing.** The file already says synth / opt / placed / phys_opt / routed are
   different quantities for WNS. They are different quantities for LUT count too,
   by 25% on this design. The same rule, a second place it bites.
3. **The subtraction needed a same-run, same-stage report of the sub-cell**, and
   one existed only because the shipping build happened to emit
   `fk33_pcieep_engine_util.rpt`. Without it the honest answer would have been
   "not determinable from the record", not an estimate.

## Consequence, and what it makes urgent

The `c4kv4` experiment now in flight is not only a timing experiment. `c_attn`'s
array carries `DSPs(u_arr) = 2 * G * KV_BLOCK`, which is 256 at the composed
top's `KV_BLOCK = 32` and 32 at the design's actual `KV_BLOCK = 4`. That is 224
of the 2,177 DSP, and the accompanying LUT and CLB reduction lands precisely in
the region that owns 65-95% of every Level 5 congestion window.

So the same one-line generator gap is the leading candidate for the timing miss
**and** for the CLB pressure. That was not visible before this arithmetic.

## Open, not yet answered

- Whether the placer actually reaches 5.72 LUT/CLB on this design. Nothing here
  measures that; the only way to know is to build shell + composed engine, which
  has never been done.
- Whether `c_attn` at `KV_BLOCK = 4` changes the CLB figure enough to matter.
  The `c4kv4` run will report `clb` in its `C4_UTIL ... routed` line and that
  number should be read alongside the WNS, not after it.
- The FF column is at 35% and the URAM column at 0%. Two levers exist that trade
  LUT for those, and neither has been costed against this budget.
