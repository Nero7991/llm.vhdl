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

---

## APPENDED 2026-09-05: where the area actually is, and the URAM lever is small

MEASURED, `hw/fk33/results/compose4_2026-08-29/util_hier_c4_synth.rpt`,
synthesis stage (so LUT is the 25% over-count; the RATIOS are what this table is
for, and DSP/BRAM are stage-stable).

| instance | LUT | % of top | LUTRAM | FF | RAMB36 | DSP |
|---|---|---|---|---|---|---|
| `compose4_top` | 350,283 | 100.0 | 14,382 | 355,468 | 231 | 2,177 |
| `a_eng` (A) | 134,633 | **38.4** | 4,440 | 63,704 | **192** | **1,585** |
| `c_attn` (C) | 85,592 | **24.4** | 80 | 101,046 | 3 | 298 |
| &nbsp;&nbsp;`u_arr` | 55,854 | **15.9** | 0 | 39,275 | 0 | **256** |
| `b_gdn` (B) | 75,181 | 21.5 | **9,862** | 52,470 | 36 | 253 |
| `d_norm` (D) | 48,501 | 13.8 | 0 | **133,169** | 0 | 41 |

Three things this settles.

**`u_arr` alone is 15.9% of the entire composed design** and 65% of `c_attn`,
carrying 256 of `c_attn`'s 298 DSP. It is simultaneously the largest single
block after subsystem A, the owner of 65-95% of every Level 5 congestion window,
and the block whose size is set by the `KV_BLOCK` generic that the composed top
gets **by omission**. That is three independent problems with one cause.

**The DSP relationship is exact and comes from the RTL, not from a fit:**
`DSPs(u_arr) = 2 * G * KV_BLOCK` gives 256 at `KV_BLOCK = 32` and 32 at 4, and
the report's 256 confirms it. **The LUT saving is deliberately NOT projected
here.** The recorded LEVERC48 result is that a two-parameter fit to two points
read scatter as slope and missed by a factor of five; `c4kv4` will measure the
LUT, and a number measured is worth more than a number derived from one point.

**CORRECTION to this document's own "Open" list.** It closed by saying the FF
column at 35% and the URAM column at 0% represent two uncosted levers trading
LUT for them. The URAM half is now costed and it is **small**: total LUTRAM is
**14,382 of 350,283, i.e. 4.1%** at synthesis (27,317 of 263,544, 10.4%, at
routed), and **68% of it lives in `b_gdn`**, 6,120 of that directly in `b_gdn`
itself rather than any child. `c_attn` holds 80 and `d_norm` zero. So moving
distributed RAM into the 350 free BRAM tiles and 320 idle URAM cannot address
the CLB pressure in the region that has it, and would in any case waste whole
tiles on memories this small. **The lever is real, it is in B, and it is worth
at most a few percent.** It is not the answer to a 90.3% CLB occupancy.

The FF half stands uncosted. `d_norm` is the striking row: **133,169 FF against
48,501 LUT**, 37% of every flop in the design for 13.8% of the LUT.

### Measurement trap hit, and it produced a wrong table first

`report_utilization -hierarchical` has columns
`Instance | Module | Total LUTs | Logic LUTs | LUTRAMs | SRLs | FFs | ...`, so
with `awk -F'|'` the LUTRAM column is **`$6`, not `$5`**. `$5` is Logic LUTs.
The first pass of this analysis read `$5` and produced a table in which
`compose4_top` owned "334,703 LUTRAM" out of 350,283 total LUT, and `c_attn`
"85,483". **Every number was a real number from a real report and the table was
entirely wrong**, and it is superficially plausible because Logic LUTs and Total
LUTs are the same order of magnitude. The tell was that the claimed LUTRAM was
95% of the design's LUT, which no design does. **An off-by-one field index
produces confident wrong numbers, not an error.**

---

## CORRECTION 2026-09-05, same day: the subsystem table above is A WEEK STALE

**The four-subsystem table in the previous section is WITHDRAWN.** It was read
from `hw/fk33/results/compose4_2026-08-29/`, and the date is in the path. The
composed design changed substantially in the intervening week. Corrected figures
below, from **this week's** `c4nd` run at the same synthesis stage.

| instance | STALE 2026-08-29 | CURRENT (`c4nd`) | error |
|---|---|---|---|
| `compose4_top` LUT | 350,283 | **267,202** | +31% |
| `a_eng` LUT | 134,633 | **92,134** | +46% |
| `c_attn` LUT | 85,592 | **88,576** | -3% |
| `u_arr` LUT | 55,854 | **57,927** | -4% |
| `b_gdn` LUT | 75,181 | **75,099** | 0% |
| `d_norm` LUT | 48,501 | **5,017** | **+867%** |
| `d_norm` FF | 133,169 | **2,004** | **+6547%** |
| `compose4_top` LUTRAM | 14,382 | **26,670** | -46% |

**`d_norm` was wrong by a factor of 9.7 in LUT and 66 in FF.** The claim in the
previous section that "`d_norm` is the striking row, 133,169 FF for 13.8% of the
LUT" is false: D is **1.9%** of the design and holds 2,004 flops. Everything
said about D's flop-heaviness is withdrawn.

**And the 25% stage over-count claimed in "Measured and REJECTED" item 2 is also
withdrawn.** It compared a week-old synthesis figure against this week's routed
figure and attributed the whole difference to stage. Measured on the same tree:
`c4nd` synth **267,202** against `c4nd` routed **263,544**, a stage effect of
**-1.4%**, not -25%. Synthesis LUT is still not a placement result and should
still not be used for a fit verdict, but the reason is not that it over-counts
by a quarter on this design.

**The headline fit arithmetic at the top of this document is UNAFFECTED**, because
it used the routed 263,544 throughout. Only the attribution table and the
stage-effect claim were contaminated.

### Why this was not caught, and it is not "I forgot to check the date"

The stale table was **internally consistent**. Its four subsystems summed to
343,907 against a stated top of 350,283, leaving 6,376 of glue, which is exactly
the right shape. The current table sums to 260,826 against 267,202, leaving
6,376. **Both are self-consistent, and the identical glue figure is coincidence.**
A sanity check on the arithmetic passes on stale data, because staleness does
not break arithmetic. The only thing that would have caught it is reading the
date in the path, which was visible and was not read.

This is the project's own recorded failure mode arriving in a new place: a
report was used **because it existed**, and a difference was attributed to the
mechanism under discussion (stage) rather than to the uncontrolled variable
(a week of design change). Compare the recorded case where "not the buffers"
was taken to promote a single remaining candidate. Here "synth vs routed" was
taken to explain a gap that was mostly "August vs September".

**The rule: a comparison needs BOTH ends drawn from the same tree, and the tree
identity has to be asserted, not assumed from the filename being plausible.**

## THE RESULT: KV_BLOCK = 4 measured, at synthesis

`c4kv4` synthesis completed 15:52:27. Route still running; **no WNS is quoted
here** and none should be inferred from these numbers.

Both runs are this week's tree, same stage, same directives. The ONLY difference
is `KV_BLOCK` on the `c_attn` instance, added in a scratch copy of the generator.

| metric | `c4nd` (KV=32) | `c4kv4` (KV=4) | delta |
|---|---|---|---|
| LUT | 267,202 | 252,819 | **-14,383 (-5.4%)** |
| lut_logic | 239,360 | 224,949 | -14,411 |
| lut_mem | 27,842 | 27,870 | +28 |
| FF | 237,905 | 239,960 | **+2,055 (+0.9%)** |
| CARRY8 | 12,505 | 10,601 | -1,904 |
| F7 mux | 20,212 | 19,532 | -680 |
| F8 mux | 3,961 | 8,425 | **+4,464 (+113%)** |
| BRAM | 253.5 | 253.5 | 0 |
| URAM | 0 | 0 | 0 |
| DSP | 2,177 | 1,953 | **-224** |

**The isolation is clean, and this is the part that makes the numbers usable.**
`a_eng` is **92,134 LUT in both runs, identical to the digit**. `d_norm` is
**5,017 in both**. `b_gdn` differs by **3 LUT** (75,099 against 75,096), which is
synthesis noise. Every change is inside `c_attn`. A controlled experiment that
actually controlled.

Within `c_attn`: **`u_arr` falls 57,927 to 39,905, -18,022 LUT**, and its DSP
falls **256 to 32, exactly the -224 derived from `2 * G * KV_BLOCK`**. The
derivation was right and the generator change did precisely what was intended.

**But `c_attn` as a whole only falls 14,380**, so roughly **3,642 LUT and 2,051
FF appear elsewhere in `c_attn`** to pay for it, and F8 muxes more than double
across the design. A narrower array needs deeper muxing and more sequencing.
That cost is real and was not anticipated.

**The refusal to project was worth it.** Scaling `u_arr`'s 57,927 LUT by the 8x
`KV_BLOCK` reduction predicts roughly -50,000 LUT. The measurement is **-18,022
in `u_arr` and -14,383 net**. A projection would have been wrong by **3.4x**, in
the flattering direction, and it would have been written down as a headline.
This is the LEVERC48 lesson holding on a fresh case: the saving is not
proportional to the parameter.

### What is NOT settled by this

- **The routed WNS.** That is the actual question `c4kv4` was launched to answer
  and it is still running. Area moving the right way says nothing about timing,
  and this project has two recorded cases of placed WNS ordering runs backwards
  against their routed result.
- **Whether the congestion clears.** DSP density in `u_arr` fell 8x, which is
  the stated mechanism, but congestion is a routed property and the Level 5
  windows have not been re-measured.
- **Which `KV_BLOCK` is correct.** `attn_block.vhd:223` and `llama_top.vhd:479`
  both cite spec clause 2.1.1 and disagree, 32 against 4. This experiment shows
  the composed top has been carrying the larger one by omission; it does not
  establish which the design should use. That remains a decision for Oren.
