# The region file inferred ZERO BRAM, and the "~34 RAMB36" estimate was never implemented

TRACK CARDTOP, 2026-09-02. All numbers MEASURED with Vivado 2023.2,
`synth_design -mode out_of_context`, part `xcvu33p-fsvh2104-2L-e`, on the
BC-250 (results there are bit-identical to the workstation).

## The question

`docs/debugging/2026-08-31_cardtop-design-note.md` section D3 says the region
file becomes "sized per-region BRAM ... ~34 RAMB36 before aspect-ratio
rounding -- cheap", and section 3.5 concludes the card top "fits inside the
same envelope" as TRACK ROUTE3. Both were DERIVED, never measured. With
`region_mem` instantiated into `compose4_top --wire`, what does it actually
cost?

## The answer, up front

**Zero BRAM. 91,073 LUTs, of which 81,920 are LUTRAM.**

Two independent defects, and the second one explains why the estimate looked
wrong:

1. **An inference blocker: the THIRD reader.** Each bank is read at three
   sites -- the element read, and the group's `x` and `e` reads. With any two
   of them the bank infers BRAM; with all three Vivado prints
   `[Synth 8-6849] Infeasible attribute ram_style = "block" ... trying to
   implement using LUTRAM` for all fourteen banks and falls back to LUTRAM.
2. **The per-region sizing was never implemented.** `bank : bank_t` where
   `bank_t is array (0 to MAXW-1)`, so ALL FOURTEEN banks are as deep as the
   widest region (ffn, 1,536 words at 9B). `R_BETA` and `R_ALPHA` are
   `val_heads` elements each and get a 1,536-word array. Per-region the total
   is 9,480 words against 14 x 1,536 = 21,504, a **3.3x** difference.

**The "~34 RAMB36" figure was never wrong -- it was never built.** 9,480 words
x 128 bits = 1,213,440 bits = ~33.7 RAMB36, which is exactly the note's
number. The estimate described the intent in D3; the code declares uniform
`bank_t` and does something else. A DERIVED number and the RTL disagreed for
two days and nothing compared them, because nothing had ever synthesised this
file.

## The procedure

Two search directions, because the first one stalled.

**Adding features to a known-good control** (`minbram`: one bank at the FFN
geometry, 1,536 x 128, one read, one write, `ram_style = "block"`). Every
feature of `region_mem` was added in isolation:

| probe | what it adds to the control | BRAM tiles |
|---|---|---|
| control | 1 read + 1 write | 7.5 |
| E6 | three read ports | 22.5 |
| E7 | per-lane byte-enable write | 8.0 |
| E8 | bank inside a 14-way generate, attribute inside | 7.5 |
| E9 | write driven from a separate combinational process | 7.5 |
| E10 | guarded read with an `else` constant | 7.5 |
| E11 | byte-enable write + 2 reads | 16.0 |
| E12 | byte-enable write + 3 reads | 24.0 |

**Every single one infers.** That is eight probes that found nothing, and the
reason they found nothing is stated under "measurement traps" below.

**Deleting features from the failing file** -- which is what actually worked:

| probe | what it removes from `region_mem` | BRAM tiles |
|---|---|---|
| baseline | nothing | **0** |
| E1 | the element read | **0** |
| E2 | `x`/`e` merged into one read via a VARIABLE | **0** |
| E3 | range guard hoisted out of the read | **0** |
| E4 | byte enables dropped | **0** |
| R2 | the write merge bypassed | **0** |
| R4 | every region given the same depth | **0** |
| R5 | the `ram_style` attribute removed entirely | **0** |
| **R3** | **both group reads removed (element read only)** | **112** |
| **R6** | **one group read restored (element + `x`)** | **224** |

R3 is the pivot. It is the first configuration of the real file that infers,
and it turned the question from "why does nothing work" into "what does the
third read cost", which is answerable.

## The evidence

```
PROBE minbram            RAMB36=7   RAMB18=1  TILES=7.5
PROBE minbram_e12        RAMB36=24  RAMB18=0  TILES=24.0
PROBE ooc_region_mem_r3  RAMB36=112 RAMB18=0  TILES=112.0
PROBE ooc_region_mem_r6  RAMB36=224 RAMB18=0  TILES=224.0
PROBE ooc_region_mem_r2  RAMB36=0   RAMB18=0  TILES=0.0
PROBE ooc_region_mem_r4  RAMB36=0   RAMB18=0  TILES=0.0
PROBE ooc_region_mem_r5  RAMB36=0   RAMB18=0  TILES=0.0
```

`report_utilization -hierarchical`, the authoritative table:

```
| ooc_region_mem_top | (top) |  91073 |  9153 | 81920 | 0 | 5403 |   0 | 0 | 0 |
| ooc_region_mem_r3  | (top) |   2310 |  2310 |     0 | 0 |   13 | 112 | 0 | 0 |
| ooc_region_mem_r6  | (top) |   2913 |  2913 |     0 | 0 |   20 | 224 | 0 | 0 |
```

Vivado's only explanation, 84 times (14 banks x 6):

```
WARNING: [Synth 8-6849] Infeasible attribute ram_style = "block" set for
RAM "u/g_region[0].bank_reg",trying to implement using LUTRAM
```

There is no companion message. `[Synth 8-6742/7075/7078/7079/7080/638/256]`
were all checked and are licensing, threading and progress noise.

## Measured and REJECTED -- do not retry

Every one of these was a plausible cause, and each cost a synthesis run:

- **Read-port count as such.** E6 and E12 put three read ports on the control
  and got 22.5 and 24.0 tiles. Vivado REPLICATES the BRAM per reader without
  complaint. Three readers are not the problem; three readers *of this shape*
  are.
- **The per-lane byte-enable write.** E7 (8.0 tiles) and E11/E12 (16.0/24.0)
  all infer. E4 removed byte enables from the real file and BRAM stayed 0
  while LUT went UP by 17,571, so the "obvious" fix would have cost 17k LUTs
  for nothing.
- **The bank declared inside a generate with the attribute inside it.** E8,
  7.5 tiles. This is `region_mem`'s exact structure and it is fine.
- **The write driven from a separate combinational process.** E9, 7.5 tiles.
- **The guarded read with an `else` constant.** E10, 7.5 tiles.
- **Per-region depth differences.** R4 gave every region the same depth and
  still got 0.
- **The `ram_style` attribute itself.** R5 removed it entirely; Vivado did not
  choose BRAM unprompted either, so the attribute is not being refused -- the
  structure genuinely does not map.
- **Merging `x` and `e` through a VARIABLE (E2).** 0 BRAM, and `region_mem`
  already records at :286-293 that an earlier reader merge BROKE the hold
  contract and was caught by the unit bench. It is both ineffective and known
  harmful. If the merge is retried it must go through a registered SIGNAL and
  must be re-earned against the bench.
- **`word_t` being an array type (the "3D RAM" trap).** Checked, not the case:
  `subtype word_t is std_logic_vector(LANES*MANT_W-1 downto 0)`, flat.

## Measurement traps hit

- **THE CONTROL SHOULD HAVE BEEN THE FIRST PROBE, NOT THE FIFTH.** Four
  variants of `region_mem` were synthesised on the assumption that the tool
  WOULD infer BRAM if only the coding pattern were right. That assumption was
  never itself tested. `minbram` took ten minutes to write and immediately
  established that the environment was innocent and the file was at fault.
- **Adding features to a passing control cannot find an interaction.** Eight
  probes were built that way and all eight passed, which felt like progress
  and was not: it is a search that can only ever exonerate. Deleting from the
  FAILING file found the answer in three runs, because a bisection needs at
  least one endpoint that fails.
- **A rejection inside the failing file is weaker evidence than the same
  rejection on the control.** E1 "rejected" the read-port hypothesis while
  four other differences were still present. E6 rejected it properly. Both
  were run; only the second is quotable.
- **Two different tools, two different units, same word.** The `get_cells`
  census reported 92,160 LUTRAM *primitives* while `report_utilization`
  reported 81,920 *LUTRAMs*. Neither is wrong; they count different objects.
  The utilization row is the one comparable to ROUTE3's "LUT as Memory", and
  per CLAUDE.md the report is what gets quoted.
- **A DERIVED number that matches your intent will not tell you the code
  disagrees.** "~34 RAMB36" was arithmetic over `region_sizes`, and
  `region_sizes` IS what the note assumed. The code ignores it for the array
  depth. Deriving a number from the same source the design *should* use does
  not check that it *does*.

## Correction to the cardtop design note

Section 3.5 says ROUTE3 measured "BRAM 351.5/372.5" leaving +21.0, and that
the card top's region BRAM (~34) fits "inside the same envelope". ROUTE3's own
`pbutil_c3img_routed.rpt` reads:

```
| Block RAM Tile | 351.5 | 0 | 0 | 351.5 | 0 | 0 | 576 | 61.02 |
```

so the pblock holds **576** tiles and **224.5** are spare, not 21.0. Where
372.5 comes from is not established and is marked open below. The conclusion
happens to survive, but it did not follow from the numbers as written.

## The fix, MEASURED

Both defects have to be fixed; neither alone is enough.

| configuration | BRAM tiles | LUT | LUTRAM |
|---|---|---|---|
| as committed (uniform depth, 3 readers) | **0** | 91,073 | 81,920 |
| R8 sized per region, 3 readers | **0** | 84,839 | 76,800 |
| R6 uniform depth, 2 readers | 224 | 2,913 | 0 |
| **R9 sized per region, 2 readers** | **100** | **2,918** | **0** |

R8 is the one that proves they are independent: per-region sizing shaves
6,234 LUTs off the LUTRAM version and still infers no BRAM at all, because
the third reader is what blocks inference and depth has nothing to do with it.

**R9 is the target configuration: 100 RAMB36 against ROUTE3's 224.5 spare
tiles, and 91,073 LUTs returned to the pblock.** That takes pb_core's LUT
occupancy from the ~90.7% it would have been with the region file as
committed back to about 67.3%, i.e. the region file stops being a fit risk.

### A DERIVED number of my own, wrong by 47%

Before running R9 this file predicted "~68 tiles", from 9,480 words being
3.3x smaller than 21,504 and R6 measuring 224. **The measurement is 100.**

The error is that BRAM allocation is quantised by WIDTH, not just depth. A
`word_t` is 128 bits, and a RAMB36 in true-dual-port mode is at most 36 bits
wide, so every bank needs at least four tiles no matter how shallow it is.
Fourteen banks x 4 tiles x 2 reader copies = 112 as a floor before depth
enters at all -- and the measured 100 is below that only because the widest
banks amortise better than the narrow ones. Depth reduction cannot go below
the width floor, so scaling a tile count by a word ratio is invalid.

This is the same failure this project has now recorded three times: a ratio
computed over the right quantity, applied to a quantity that does not scale
that way. The rule that keeps holding is that a structural figure is a
constant and a scattered one is a mean, and a tile count is neither -- it is
a ceiling function with a floor.

## Open, not yet answered

- **Why the third read specifically.** R3 (1 read) and R6 (2 reads) infer;
  the third breaks it. On the control three reads are fine (E12). The
  difference is that `x` and `e` share ONE address with different enables
  while the control's three reads had independent addresses. That is a
  hypothesis, not a measurement: the discriminating probe is a control with
  three reads, two of which share an address signal. NOT YET RUN.
- **How to get to two readers without breaking the hold contract.** This is
  the whole remaining design question. `x` and `e` share one address and
  differ only in region select, so a bank serves at most one of them and they
  want the identical word when `rega = regb` -- the merge is sound in
  principle. But `region_mem.vhd:286-293` records that an earlier merge
  clobbered the group word with an element read, because the three registered
  words hold across DIFFERENT intervals and one shared register cannot. E2
  attempted it through a VARIABLE and inferred no BRAM. The merge has to go
  through a registered SIGNAL and be re-earned against the unit bench,
  including the mutation that caught it last time.
- **Where 372.5 came from.** Some earlier pblock budget, not the routed
  report.
- **The pad contract remains UNVERIFIED**, unchanged from increment 1: the
  unit bench never drives an out-of-size access, so mutations F, G and F+G
  all fail to bite. Per-region sizing makes an out-of-range write a real
  hazard rather than a theoretical one, because the array is now NW deep
  rather than MAXW deep, so this gap matters more than it did.
