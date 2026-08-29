# What is congested in the FK33 shell build?

**Date:** 2026-08-29
**Build:** `hw/fk33` shell + `fk33_engine` (subsystem A's descriptor plane), commits
`928ad9f` / `70c35db` / `d807a1c`. Vivado 2023.2, `xcvu33p-fsvh2104-2L-e`, 250 MHz
HBM AXI / 200 MHz core.
**Symptom:** `ERROR: [Route 35-3] Design is not routable as its global congestion
level is 7.` Six initial-routing attempts over 7 min 47 s, then abandoned. No
bitstream. Whole-design utilization at that point 39.50% LUT, 55.03% DSP,
38.91% BRAM36, 0 URAM.
**Track:** CONGEST. No RTL was changed and no fix was implemented; this is a
measurement and a set of costed options.

---

## 1. The question, verbatim

> **YOUR TASK: FIND OUT WHAT IS CONGESTED. DO NOT FIX IT YET.**
>
> 1. Where the congestion is, physically and logically. Which SLR, which clock
>    region(s), which cells or nets.
> 2. Which subsystem or structure owns it. The engine has 28 AXI masters (27
>    weight/scale lanes plus a descriptor fetch) funnelling into the HBM ports.
>    A 28-way crossbar into 32 HBM segments is the obvious suspect, but
>    suspicion is not measurement. Name the hierarchy, with numbers.
> 3. The candidate levers, each with an estimated cost and what it would break.
> 4. Whether the CDC clock group was actually APPLIED rather than merely matched.

---

## 2. The answer, up front

**`bd_i/eng/inst/eng/dut/core` -- `matvec_core`, one flat RTL module -- owns the
congestion. It is 68.0% of the design's LUTs and 99.9% of its DSPs, and Vivado's
own congestion report names it as 69% to 88% of the cells in every congested
window the router found, in every direction, at every level.** The AXI read path
is not the problem: the 28 masters plus the streamer plus the HBM IP are 7.6% of
the design's LUTs, and **there is no crossbar at all** -- the block design wires
`eng/mNN_axi` straight to `hbm/SAXI_NN`, 1:1 (`hw/fk33/gen_pcieep.py:833`).

**Physically: there is exactly ONE SLR, so no SLR lever exists.** The device has
32 clock regions in an 8x4 grid, and **96.1% of `matvec_core`'s 218,611 placed
leaf cells sit in the bottom 16 of them (rows Y0 and Y1).** The top half of the
die is essentially empty: it holds 3.9% of the core, 1.7% of the block RAM and
22.7% of the DSPs, and has 1,176 free DSP sites and 663 free RAMB18 sites, more
than the whole design's BRAM demand. The design is 39.50% LUT globally and
**75% to 89% LUT locally** in the windows the router could not route.

**Logically, inside the flat module, one structure dominates: the IQ4_NL
codebook lookup.** `cb(idx)` is a 16-entry x 8-bit runtime-loadable table
decoded once per lane, and at `ROWS_IF = 48`, `BLK = 32` there are 1,536 lanes,
each an 8-bit 16:1 mux feeding a DSP. Measured, per lane: **exactly 16.0 MUXF7,
exactly 8.0 MUXF8 and 32.6 LUTs** -- the textbook cost of that mux. In total
**50,128 LUT + 36,864 MUXF7/MUXF8 = 86,992 primitives, 39.5% of `matvec_core`,
97.7% of the whole design's MUXF7 and 98.8% of its MUXF8.** In the single worst
window the router reported (West Short level 5) MUXF occupancy is 53% and
`matvec_core` is 88% of the cells.

**The CDC clock group WAS applied, not merely matched.**
`report_clock_interaction` reports the engine's core-clock-to-HBM-AXI pair as
`Asynchronous Groups` / `Ignored` in both directions, 2,221 and 402 endpoints.
So the WNS figures are **not** pessimistic from that cause, and the per-clock
split that OI-13 said did not exist is now measured: at the post-`phys_opt`
checkpoint the **core clock owns the miss at WNS -0.354** (433 failing endpoints
of 350,285) while the AXI clock is at **-0.315** (19 of 194,477).

---

## 3. The procedure

Everything below ran on the two checkpoints TRACK SHELL left behind. **No place
or route was re-run.** Four Vivado batch sessions, each with an explicit
memory guard armed at 18.0 GB before launch (see section 8). Peak RSS across all
four: **8.29 GB**.

| # | on | what it isolates |
|---|---|---|
| 0 | `runme.log`, free | the placer's own estimated-congestion table and the router's phase log. Costs nothing and should always be read first. |
| 1 | `bd_wrapper_placed.dcp` | `get_slrs`, `get_clock_regions`, `report_utilization -slr`. Answers the SLR question before any lever that assumes SLRs is considered. |
| 2 | `bd_wrapper_placed.dcp` | `write_xdc -constraints ALL` (was the clock group applied), `report_clock_utilization` (per-region resource occupancy), `report_utilization -hierarchical` (who owns the area), a per-leaf `get_clock_regions` sweep of `matvec_core` (where it physically is), `report_design_analysis -congestion`. |
| 3 | `bd_wrapper_placed.dcp` | batched `get_property {NAME,REF_NAME,LOC}` over all 220,238 leaves of `matvec_core`, so the flat module can be attributed by structure and primitive type. Plus `report_high_fanout_nets` and `report_clock_interaction`. |
| 4 | `bd_wrapper_routed_error.dcp` | the **router's** own congestion (`report_design_analysis -congestion` section 2, which only exists post-route), `report_clock_interaction` after `phys_opt`, `report_route_status`. |

Two controls worth naming:

- **`report_utilization -slr` as the SLR control.** It emitted no SLR section at
  all, and `report_design_analysis` printed `* The current part is not an SSI
  device`. Two independent commands agreeing beats reading a datasheet.
- **The placer's estimate against the router's actual.** Sections 1 and 2 of
  `report_design_analysis -congestion` on the routed_error checkpoint are the
  placer's prediction and the router's measurement of the same design. They name
  the same owner with the same magnitude, so the placed-checkpoint numbers can
  be trusted for anything that has to be evaluated before a route.

Every step was wrapped in a Tcl `catch` after the first session aborted on one
bad command and threw away a checkpoint that took 72 s to open.

---

## 4. The evidence

### 4.1 The device has one SLR (MEASURED, session 1 and 4)

```
CONGEST-SLR-LIST: SLR0
CONGEST-SLR SLR0 index=0 config_order=0
CONGEST-CLOCKREGIONS: 32
```

```
3. SLR Net Crossing Reporting
-----------------------------
+------------+-----------------------------+
| Cell Names | Number of Nets crossing SLR |
+------------+-----------------------------+
* The current part is not an SSI device
```

`report_utilization -slr` produced no SLR table. Clock regions are X0..X7 by
Y0..Y3.

### 4.2 Who owns the area (MEASURED, `report_utilization -hierarchical`)

| instance | module | LUT | FF | RAMB36 | DSP |
|---|---|---|---|---|---|
| `bd_wrapper` | (top) | **173,694** | 125,015 | 259 | 1,585 |
| `bd_i/eng` | `bd_eng_0` | 132,065 | 63,733 | 192 | 1,585 |
| `bd_i/eng/inst/eng` | `matvec_int4_desc_axi` | 132,021 | 63,652 | 192 | 1,585 |
| `.../eng/dfetch` | `axi_rd_port` (descriptor master) | 395 | 205 | 4 | 0 |
| `.../eng/dut` | `matvec_int4` | 129,836 | 60,737 | 145 | 1,584 |
| `.../dut/core` | **`matvec_core`** | **118,068** | 52,819 | 21 | **1,584** |
| `.../dut/streamer` | `weight_streamer` | 11,754 | 7,918 | 108 | 0 |
| `.../dut/actmem` | `act_mem_striped` | 16 | 0 | 16 | 0 |
| `bd_i/xdma` | `bd_xdma_0` | 15,039 | 18,911 | 38 | 0 |
| `bd_i/hbm` | `bd_hbm_0` | 996 | 874 | 4 | 0 |

`matvec_core` is **67.98%** of the design's LUTs and **99.94%** of its DSPs.
The entire AXI read path -- `streamer` + `dfetch` + `hbm` -- is 13,145 LUT,
**7.57%**.

`matvec_core` has no sub-hierarchy: `get_cells .../core/*` returns 220,238 leaf
primitives and no child instances. It is one flat RTL module.

### 4.3 The congestion, as Vivado reports it

`report_design_analysis -congestion` on the **placed** checkpoint, worst rows
(the `Cell Names` column is the tool's own attribution, not mine):

```
| Direction |  Type  | Level |                Window               | LUT | MUXF | RAMB |  DSP |  Cell Names
| South     | Long   |     7 | (CLEL_R_X20Y13,CLEL_R_X84Y140)      | 51% |  16% |  62% |  95% |  core(81%),streamer(5%),bd_i(4%)
| East      | Long   |     7 | (CLEM_X11Y4,CLEL_R_X74Y131)         | 53% |  15% |  66% |  92% |  core(75%),streamer(8%),pcie2hbm(6%)
| South     | Global |     6 | (CLEL_R_X53Y24,CLEM_X85Y87)         | 79% |  27% |  96% | 100% |  core(80%),streamer(7%)
| East      | Global |     6 | (CLEL_R_X49Y22,URAM_URAM_FT_X80Y75) | 79% |  27% |  96% | 100% |  core(80%),streamer(8%)
| West      | Short  |     6 | (CLEL_R_X49Y8,URAM_URAM_FT_X80Y60)  | 75% |  34% |  98% |  97% |  core(81%),streamer(10%)
```

All 22 rows name `bd_i/eng/inst/eng/dut/core` as the top owner, at 51% to 88%.

`report_design_analysis -congestion` section **2. Router Initial Congestion** on
the **routed_error** checkpoint -- this is the router's own measurement, not an
estimate:

```
| Direction |  Type  | Level |             Window             | Avg LUT In | LUT | MUXF | RAMB |  DSP |  Cell Names
| South     | Global |     7 | (CLEM_X13Y18,CLEL_R_X140Y81)   |      4.819 | 85% |  30% |  96% |  98% |  core(80%),bd_i(16%)
| East      | Global |     7 | (CLEM_X1Y0,CLEM_X128Y95)       |      4.545 | 80% |  26% |  91% |  96% |  core(74%),bd_i(16%)
| West      | Global |     7 | (CLEL_L_X15Y20,CLEL_R_X142Y83) |      4.795 | 85% |  29% |  94% |  98% |  core(79%),bd_i(17%)
| South     | Long   |     7 | (CLEM_X19Y5,CLEM_R_X146Y132)   |      4.700 | 75% |  24% |  86% |  90% |  core(69%),bd_i(25%)
| East      | Long   |     7 | (CLEL_R_X0Y20,CLEL_L_X127Y147) |      4.558 | 52% |  16% |  55% |  89% |  core(80%),bd_i(15%)
| West      | Long   |     7 | (CLEM_X32Y3,CLEL_L_X127Y98)    |      4.537 | 81% |  28% |  94% |  99% |  core(77%),bd_i(16%)
| East      | Short  |     6 | (CLEM_X33Y0,CLEM_X128Y63)      |      4.954 | 86% |  42% |  98% |  99% |  core(83%),pcie2hbm(5%)
| West      | Short  |     5 | (CLEL_L_X84Y16,CLEM_X115Y79)   |      5.266 | 89% |  53% | 100% | 100% |  core(88%),bd_i(4%)
```

The **worst single window is West Short level 5, `(CLEL_L_X84Y16,
CLEM_X115Y79)`: 89% LUT, 53% MUXF, 100% RAMB, 100% DSP, `matvec_core` 88%.**
`Combined LUTs` is 2% there and never exceeds 6% anywhere -- there is no packing
slack to recover.

Level N is a 2^N tile window: the South Long level-7 window spans Y13..Y140,
which is 128 rows. "Global congestion level 7" therefore means a 128-tile window
is congested, i.e. roughly half the die, not a local hot spot.

For completeness, `report_route_status` on the same checkpoint:

```
   # of routable nets..................... :      282451 :
       # of unrouted nets................. :      282428 :
       # of fully routed nets............. :          23 :
```

The router got 23 nets done. Nothing is salvageable from that checkpoint.

### 4.4 Where `matvec_core` physically is (MEASURED, per-leaf `get_clock_regions`)

218,611 placed leaves, bucketed by clock region:

```
        X0     X1     X2     X3     X4     X5     X6     X7
Y0:  11738  13811  22435  14344  17548  18099  13884   9083     120,942  (55.3%)
Y1:   8375  10090  15826   8267  11124  13379  14680   7420      89,161  (40.8%)
Y2:      0     15    189    840    275    547   4274   2035       8,175  ( 3.7%)
Y3:      0      0      0      0      0      0     60    273         333  ( 0.2%)
```

**96.1% of the module is in the bottom 16 of 32 clock regions.**

Per-clock-region resource occupancy, from `report_clock_utilization` section 5
(the whole design, not just the core):

| region row | DSP used / avail | RAMB18 used / avail | FF used / avail |
|---|---|---|---|
| Y0 | 529 / 576 = **91.8%** | 295 / 336 = **87.8%** | 62,744 / 223,680 = 28.05% |
| Y1 | 696 / 768 = **90.6%** | 219 / 336 = 65.2% | 47,728 / 223,680 = 21.34% |
| Y2 | 351 / 768 = 45.7% | 9 / 336 = 2.7% | 8,963 / 223,680 = 4.01% |
| Y3 | 9 / 768 = **1.2%** | 0 / 336 = **0.0%** | 5,580 / 208,320 = 2.68% |

DERIVED from that table: the top half of the die (Y2+Y3) holds **1,176 free DSP
sites** and **663 free RAMB18 sites**, against a whole-design demand of 1,585 DSP
and 523 RAMB18. **The half of the die the design is avoiding could hold nearly
three quarters of its DSPs and all of its block RAM.**

The anchor that holds everything down is measured too. The HBM AXI interface
sites are all on the bottom edge:

```
CONGEST-HBMSITES n=66 : BLI_HBM_APB_INTF_X0Y0 BLI_HBM_AXI_INTF_X0Y0
                        BLI_HBM_APB_INTF_X1Y0 BLI_HBM_AXI_INTF_X1Y0 ...
```

and `weight_streamer`, which must reach them, is confined to the bottom of the
fabric:

```
CONGEST-BBOX bd_i/eng/inst/eng/dut/streamer n=18431 X=0..216 Y=0..68
```

`weight_streamer` hands `matvec_core` a **6,144-bit `wd` bus plus a 768-bit `sd`
bus** every core cycle (`rtl/matvec_int4.vhd:127-128`, `ROWS_IF*BLK*4` and
`ROWS_IF*16`). That 6,912-bit interface between a module pinned to the HBM edge
and a module that is 68% of the design is what drags `matvec_core` south.

### 4.5 What is inside the flat module (MEASURED, 220,238 leaves by REF_NAME)

Primitive mix of `matvec_core`:

```
  68555 LUT6      52819 FDRE      26951 LUT2      24576 MUXF7     12415 LUT3
  12288 MUXF8     11344 LUT5       5471 CARRY8     2343 LUT4       1584 DSP48E2
   1021 LUT1        798 SRL16E       37 RAM32M16     21 RAMB36E2      8 BUFGCE
```

Grouped by the RTL signal each leaf belongs to:

| structure | cells | LUT | MUXF | FF | CARRY | DSP | what it is |
|---|---|---|---|---|---|---|---|
| `tr` | **88,654** | 50,128 | **36,864** | 0 | 126 | 1,536 | codebook mux + the DSP multiply, levels 0..1 |
| `trn` | 40,330 | 18,821 | 0 | 18,819 | 2,688 | 0 | adder-tree levels 2..LVL, `use_dsp="no"` |
| `re2_shv` | 16,324 | 13,684 | 0 | 2,304 | 336 | 0 | 48-bit variable shift x ROWS_IF |
| `cb` | 12,288 | 6,144 | 0 | 6,144 | 0 | 0 | 48 replicas of the 16x8 codebook |
| `em_shv` | 10,378 | 8,601 | 0 | 1,536 | 240 | 0 | 32-bit variable shift x ROWS_IF |
| `y_data` | 8,072 | 5,575 | 0 | 2,304 | 192 | 0 | the 3,072-bit output bus |
| `w_r` | 6,146 | 2 | 0 | 6,144 | 0 | 0 | the 6,144-bit weight register |
| `re3_mag` | 6,135 | 4,230 | 0 | 1,584 | 320 | 0 | row-end magnitude |
| `re1_acc` | 5,760 | 3,168 | 0 | 2,304 | 288 | 0 | row-end accumulator |
| `fold` | 4,974 | 3,249 | 0 | 1,584 | 141 | 0 | the amax fold tree |
| `acc` | 4,897 | 2,305 | 0 | 2,304 | 288 | 0 | tile accumulator |

**The `tr` row is the finding.** DERIVED, per lane (`ROWS_IF * BLK = 48 * 32 =
1,536` lanes):

```
  50,128 LUT   / 1536 = 32.6
  24,576 MUXF7 / 1536 = 16.000   exactly
  12,288 MUXF8 / 1536 =  8.000   exactly
```

An 8-bit-wide 16:1 mux costs, per output bit, 4 LUT6 + 2 MUXF7 + 1 MUXF8; times
8 bits that is 32 LUT6 + 16 MUXF7 + 8 MUXF8. The MUXF counts match **exactly**,
so the attribution is not a guess. The RTL is `rtl/matvec_core.vhd:695-705`:

```vhdl
idx := to_integer(unsigned(w_r((rr*BLK + j)*4 + 3 downto (rr*BLK + j)*4)));
...
tr(0)(rr*BLK + j) <= resize(cb(rr / CB_ROWS_PER_COPY)(idx) * xw, 28);
```

and the file's own header already predicted it, at `rtl/matvec_core.vhd:133-139`:

> `cb` is the 16-entry runtime-loadable IQ4_NL codebook. Every lane of the
> product stage decodes its 4-bit weight nibble through it, so at the FK33's
> ROWS_IF = 48 and BLK = 32 ONE 16-entry table has 1,536 consumers, each a
> 16:1 8-bit mux feeding a DSP.

That structure is **86,992 primitives, 39.5% of `matvec_core`, 97.7% of the
design's MUXF7 and 98.8% of its MUXF8.** Each MUXF8 locks a CLB half (its 4
LUT6 and 2 MUXF7 must be in the same half-slice), so 12,288 MUXF8 tie down
6,144 of the 27,789 CLBs the design uses -- which is why CLB occupancy is 50.56%
while LUT occupancy is 39.50%.

### 4.6 The high-fanout enable nets (MEASURED, `report_high_fanout_nets`)

```
| bd_i/eng/inst/eng/dut/core/trn[2][835][27]_i_1_n_0    |   9408 | BUFGCE |
| bd_i/eng/inst/eng/dut/core/w_r[6143]_i_1_n_0         |   8448 | LUT6   |
| bd_i/eng/inst/eng/dut/core/re2_acc[17][47]_i_1_n_0   |   4333 | BUFGCE |
| bd_i/eng/inst/eng/dut/core/trn[3][1379][27]_i_1_n_0  |   4300 | BUFGCE |
| bd_i/eng/inst/eng/dut/core/trn[4][1377][27]_i_1_n_0  |   2688 | LUT2   |
| bd_i/eng/inst/eng/dut/core/re1_acc[0]_71             |   2332 | BUFGCE |
| bd_i/eng/inst/eng/dut/core/acc[26][0]_i_1_n_0        |   2304 | LUT2   |
| bd_i/eng/inst/eng/dut/core/tr_reg[0][980]_i_1_n_0    |   2304 | LUT2   |
| bd_i/eng/inst/eng/dut/core/os_rep[37][5]_i_1_n_0     |   2090 | BUFGCE |
| bd_i/eng/inst/eng/dut/core/y_data[3071]_i_1_n_0      |   1800 | BUFGCE |
```

These are the `if tg(l).v = '1' then` clock enables gating whole array levels.
**All 8 of the engine's BUFGCEs are already spent inside `matvec_core`** on
them, and the two largest that were NOT promoted -- `w_r[6143]_i_1_n_0` at
fanout 8,448 off a single LUT6, and `trn[4][1377][27]_i_1_n_0` at 2,688 off a
LUT2 -- are still routed as ordinary fabric nets.

### 4.7 The clock group question (MEASURED, two independent commands)

`write_xdc -constraints ALL` on the placed checkpoint, line 17134 -- the
constraint is in the design, not merely in the source file:

```
set_clock_groups -asynchronous -group [get_clocks -of_objects [get_pins bd_i/eng/core_clk]] -group [get_clocks -of_objects [get_pins bd_i/eng/hbm_aclk]]
```

Both lookups resolve to exactly one clock each in that checkpoint, so neither
group is empty:

```
CONGEST-ENGCLK core='clk_out3_bd_clk_wiz_0_0' axi='fk33_dmabram_BRAM_PORTA_CLK'
CONGEST-CLOCK clk_out3_bd_clk_wiz_0_0       period=5.000
CONGEST-CLOCK fk33_dmabram_BRAM_PORTA_CLK   period=4.000
```

(The AXI clock's auto-generated name is `fk33_dmabram_BRAM_PORTA_CLK`, which is
Vivado naming the 250 MHz `xdma/axi_aclk` after an unrelated BRAM port. It is
the right clock -- 4.000 ns -- with a misleading name.)

And the direct test, `report_clock_interaction` on the **routed_error**
checkpoint, which is the one the WNS figures came from:

```
clk_out3_bd_clk_wiz_0_0     | clk_out3_bd_clk_wiz_0_0     | rise-rise | -0.354 | -14.635 | 433 | 350285 | 5.000 | Clean | Partial False Path
clk_out3_bd_clk_wiz_0_0     | fk33_dmabram_BRAM_PORTA_CLK |           |      0 |    2221 |     | Ignored | Asynchronous Groups
fk33_dmabram_BRAM_PORTA_CLK | clk_out3_bd_clk_wiz_0_0     |           |      0 |     402 |     | Ignored | Asynchronous Groups
fk33_dmabram_BRAM_PORTA_CLK | fk33_dmabram_BRAM_PORTA_CLK | rise-rise | -0.315 |  -2.831 |  19 | 194477 | 4.000 | Clean | Partial False Path
```

**Both crossing directions are `Asynchronous Groups` and `Ignored`, 2,623
endpoints in total.** The group was applied. The WNS numbers are not pessimistic
from that cause.

The same command on the **placed** checkpoint, for the before/after pair:

| clock | period | WNS placed | WNS post-phys_opt | endpoints failing (post) |
|---|---|---|---|---|
| `clk_out3` (engine core, 200 MHz) | 5.000 | **-0.759** | **-0.354** | 433 of 350,285 |
| `fk33_dmabram_BRAM_PORTA_CLK` (HBM AXI, 250 MHz) | 4.000 | -0.339 | -0.315 | 19 of 194,477 |
| `clk_out1` (100 MHz) | 10.000 | +4.121 | -- | 0 of 2,698 |
| `pipe_clk` | 4.000 | +0.318 | -- | 0 of 2,456 |
| `pcie_refclk` | 10.000 | +5.816 | -- | 0 of 3,863 |

DERIVED: the core clock achieves 1/(5.000+0.354) = **186.8 MHz** and the AXI
clock 1/(4.000+0.315) = **231.8 MHz** at the routed_error checkpoint. This is
the per-clock split OI-13 said did not exist.

---

## 5. The candidate levers, costed. NONE IS IMPLEMENTED, NONE IS RECOMMENDED

Ordered by (measured benefit) / (cost + risk). Every "would remove" figure is
DERIVED from the measurements above; every claim about what happens after a
re-place is an ESTIMATE, because no place or route was run.

### Lever A -- floorplan `matvec_core` into the empty top half of the die

- **Change:** a `pblock` on `bd_i/eng/inst/eng/dut/core` spanning `X0Y0:X7Y2` or
  the full `X0Y0:X7Y3`, so the placer stops packing 96.1% of it into 16 regions.
- **MEASURED headroom:** 1,176 free DSP sites and 663 free RAMB18 sites in
  Y2+Y3, against a whole-design demand of 1,585 DSP and 523 RAMB18. Local LUT
  occupancy in the congested windows would fall from 75-89% toward the
  design-wide 39.50%.
- **Cost:** ~50 min of machine time per attempt (SHELL's impl run was 40 min to
  the router's exit). No arithmetic changes, no cycle budget changes, no RTL.
- **What it would break:** nothing functionally. The risk is timing: the core
  clock is already at -0.354 and stretching a module whose internal buses are
  6,144 bits wide over twice the area will make some of its nets longer. The
  measured counter-argument is that **360 of the core's 1,584 DSPs are already
  stranded in Y2/Y3 while only 3.9% of its other cells are there**, so the
  placer has *already* created long DSP-to-fabric nets without getting any
  density relief for them.
- **Confidence: this is the cheapest thing to try and the only lever that costs
  no throughput at all.**

### Lever B -- pipeline the `weight_streamer` -> `matvec_core` bus

- **Change:** one or two register stages on the 6,144-bit `wd` and 768-bit `sd`
  buses, so `matvec_core` is not timing-anchored to the HBM edge where
  `weight_streamer` must live (`streamer` bbox is Y=0..68, HBM BLI sites are all
  at Y0).
- **Cost:** 6,912 FFs per stage. FF is at **14.22%** of 879,360, so this is
  free in area. One or two cycles of pipeline latency on a stream that runs for
  thousands of cycles.
- **What it would break:** the cycle accounting in `matvec_core`'s tag pipeline
  (`tg` / `PIPE`) has to absorb the extra stages; the file's own `P_PART` /
  `P_CONTRIB` / `P_ACC` offsets are derived from `LVL` and would need to move.
  That is exactly the class of change that has produced silent off-by-one
  defects in this file before.
- **Confidence: ESTIMATE.** Pipelining removes the *timing* reason to stay
  south; it does not by itself change the placer's wirelength cost. Lever B is
  only worth doing together with Lever A.

### Lever C -- build the codebook lookup as distributed RAM instead of a mux tree

- **MEASURED cost today:** 50,128 LUT + 36,864 MUXF7/F8 = **86,992 primitives**,
  39.5% of `matvec_core`, 28.9% of the design's LUT sites, and 97.7% / 98.8% of
  all its MUXF7 / MUXF8.
- **ESTIMATE of the replacement:** a 16-deep x 8-bit runtime-writable table per
  lane as distributed RAM is 8 LUT6-as-LUTRAM. 1,536 lanes x 8 = **12,288 cells,
  a 7.1x reduction** on this structure, and it removes every MUXF8 in the
  design, freeing the ~6,144 half-CLBs they lock.
- **What it would break, and this is serious.** `cb` carries `dont_touch` and is
  deliberately built as 48 lockstep-written replicas with a runtime equality
  assertion (`assert cb(c) = cb(0)`, `rtl/matvec_core.vhd:525`), because the
  file's own comment says a half-written codebook is "a silently wrong answer,
  not a failure". Going to 1,536 per-lane copies multiplies that write-coherency
  surface by 32x and the equality assertion has no cheap form at that width.
  LUTRAM also lives only in SLICEM, so 12,288 LUTRAM cells would pin those lanes
  to SLICEM columns -- a new placement constraint on the very module that is
  already the placement problem.
- **Confidence:** the attribution is certain (the 16.0 / 8.0 MUXF-per-lane match
  is exact). The replacement cost is an ESTIMATE; nothing was synthesised, and
  whether Vivado infers LUTRAM here at all is unverified.

### Lever D -- reduce `ROWS_IF` below 48

- **Change:** `ROWS_IF` in `hw/fk33/gen_fk33_engine.py:85`. Everything that
  dominates `matvec_core` scales with `ROWS_IF * BLK`: the 1,536 codebook muxes,
  the 1,584 DSPs, `trn`, `re2_shv`, `em_shv`, `cb`, `acc`.
- **DERIVED at `ROWS_IF = 32`:** core LUT 118,068 x 32/48 = ~78,700, DSP 1,584 x
  32/48 = 1,056. Design LUT would fall from 173,694 to ~134,300 (30.5%) and DSP
  from 55.03% to 36.7%.
- **What it would break:** every cycle budget in
  `docs/2026-08-27_budgets-at-the-measured-clock.md` and
  `docs/2026-08-27_9b-single-card-resource-envelope.md`. The matvec cycle count
  goes as `ceil(n_rows / ROWS_IF)`, so 48 -> 32 is **1.5x more cycles** for the
  same work at the same clock.
- **It also changes the port arithmetic, and that must be re-derived rather than
  scaled.** `NPORTS_S = lcm(ROWS_IF*16, AXI_DW) / AXI_DW` gives 2 at
  `ROWS_IF = 32`, not 3; and the weight demand per core cycle changes from
  `48*32*4 = 6,144` bits to `32*32*4 = 4,096` bits, which changes `NPORTS_W`
  and therefore the `duty = f_core / f_axi` identity's clean form (it is exact
  today only because `27 x 256 = 864 B` exactly). **Do not assume the identity
  survives.**
- **Confidence: MEASURED scaling, ESTIMATE that it is enough.** Halving the
  module still leaves it as the largest thing in the design by a wide margin.

### Lever E -- lower the core clock

- **Change:** `clk_wiz_0` `clk_out3` from 200 MHz.
- **MEASURED:** `duty = f_core / f_axi` = 200/250 = **80.0%** today. At 150 MHz
  it is 60.0%. The period grows from 5.000 to 6.667 ns, which covers the
  measured -0.354 core-clock miss with 1.3 ns to spare.
- **Cost:** throughput is linear in `f_core`. 200 -> 150 MHz is a **25% loss**
  on every matvec in the model.
- **What it would break:** nothing structurally. It would remove the
  timing-driven replication the congestion partly consists of -- 8 BUFGCEs and
  the `_rep__N` copies inside `matvec_core`, plus the 185 extra control sets
  OI-12 recorded.
- **Confidence: ESTIMATE, and the weakest lever of the set.** What is MEASURED
  is that **congestion, not timing, is what stopped the router**: the router quit
  at initial routing having routed 23 of 282,451 nets, with WNS at -0.354.
  A longer period relieves congestion only indirectly, by letting the router
  take detours it currently cannot afford. Do not expect it to be sufficient
  alone.

### Lever F -- replicate the high-fanout array enables per row

- **Change:** give each `tg(l).v` enable per-row registered replicas with
  `dont_touch`, exactly the pattern `ns_rep` and `os_rep` already use in this
  file for the same shape.
- **MEASURED target:** `w_r[6143]_i_1_n_0` at fanout **8,448** off one LUT6 and
  `trn[4][1377][27]_i_1_n_0` at 2,688 off a LUT2, neither promoted to a BUFG,
  with all 8 BUFGCEs already spent on the others.
- **Cost:** ROWS_IF flops per enable. Negligible against FF at 14.22%.
- **What it would break:** each replica is a place a stale copy can be read.
  The file's own `ns_rep` comment shows the argument that has to be made for
  each one (a one-cycle margin that is "sufficient, not generous"), and getting
  it wrong is a silent wrong answer.
- **Confidence:** MEASURED that the nets exist at those fanouts; ESTIMATE that
  fixing them moves the congestion number.

### Lever G -- reverse the adder-tree DSP reclaim

- **Change:** drop `use_dsp = "no"` from `trn` (`rtl/matvec_core.vhd:237`), so
  levels 2..LVL go back into DSP ALUs.
- **MEASURED benefit:** removes 18,821 LUT primitives, **10.8% of the design's
  LUTs**. Smaller than it sounds.
- **DERIVED cost:** the file states the array is 46.5 DSP per row without the
  reclaim; at `ROWS_IF = 48` that is 2,232 DSP, **77.5% of the device's 2,880**,
  up from 55.03%.
- **What it would break:** MEASURED, the bottom two clock-region rows are
  already **91.8% and 90.6% DSP-occupied**, and the congestion report shows DSP
  at 89-100% in every congested window. Adding 648 DSPs there is adding to the
  saturated resource. It only makes sense **after** Lever A has moved the design
  into Y2/Y3, where 1,176 DSP sites are free.
- **Confidence: measured, and probably a wash or worse on its own.** Listed
  because it is the one lever that trades the congested resource for the free
  one, and because it is a one-line RTL change to measure.

---

## 6. Measured and REJECTED -- do not retry

- **"A 28-way crossbar into 32 HBM segments is the obvious suspect."**
  **REFUTED. There is no crossbar.** `hw/fk33/gen_pcieep.py:833` connects
  `eng/mNN_axi` directly to `hbm/SAXI_NN`, one to one. And the whole AXI read
  path is small: `weight_streamer` 11,754 LUT + `dfetch` 395 + `hbm` 996 =
  **13,145 LUT, 7.57% of the design.** `streamer` never appears as the top owner
  in any congested window, and in the two level-7 windows it is 5% and 8%.
  Do not spend another run on interconnect topology.

- **Any lever that assumes SLRs.** `xcvu33p-fsvh2104-2L-e` has **one SLR**.
  Confirmed twice: `get_slrs` returns `SLR0` alone and
  `report_utilization -slr` emits no SLR section; `report_design_analysis`
  prints `* The current part is not an SSI device`. There is no SLR-crossing
  net count to reduce and no "put the engine in an SLR" floorplan to write.

- **Attacking the barrel shifters (`re2_shv`, `em_shv`) as a mux problem.**
  MEASURED: they contain **zero MUXF7 and zero MUXF8**. `re2_shv` is 13,684 LUT
  + 336 CARRY over 48 rows = **285 LUT per row for a 48-bit shift**, against
  6 x 48 = 288 for a textbook 6-stage 2:1 barrel shifter. They are already at
  the minimum for their width. The only levers on them are fewer bits or fewer
  rows, i.e. Lever D. Narrowing the shift range does not help either: `os_r` is
  already asserted to 0..40 and `ns` to 0..22, and both still need 6 bits.

- **Reading `matvec_core`'s area as a hierarchy problem.** It has no
  sub-hierarchy at all: `get_cells .../core/*` returns 220,238 leaf primitives
  and no child instances. No amount of `-hierarchical_depth` will subdivide it;
  the only way in is by signal name and REF_NAME, which is what section 4.5 did.

- **`get_clock_groups`.** Not a Vivado command (`invalid command name`). It
  exists in other tools. The Vivado way to check an applied clock group is
  `write_xdc -constraints ALL` plus `report_clock_interaction`.

---

## 7. Measurement traps hit, including my own

- **`report_design_analysis -congestion` DOES terminate: 14 seconds on the
  placed checkpoint, 24 seconds on the routed_error one.** OI-12 records that it
  "did not complete in the time available", and that is the single reason this
  question stayed open. The most likely trap is that
  **`report_design_analysis` with no switches runs the timing and logic-level
  analysis as well**, and on a design with 350,285 endpoints on one clock that
  is what is slow. `-congestion` alone skips it. SHELL's own build log even
  contains `report_design_analysis: Time (s): cpu = 00:00:32 ; elapsed =
  00:00:13` from the run's automatic post-route report. See the CORRECTION in
  section 10.

- **The same applies to `report_clock_interaction`: 15-18 seconds.** OI-13
  correctly measured that `get_timing_paths -from <core> -to <axi>` does not
  terminate, and then generalised from that to the whole per-clock question.
  The generalisation was wrong. `report_clock_interaction` answers exactly what
  the enumeration was trying to answer, is the tool built for it, and is cheap.

- **My own trap, cost 33 minutes.** I wrote
  `get_cells bd_i/eng/inst/eng/dut/core/*` expecting the module's children.
  `matvec_core` is flat, so the glob matched **220,238 leaf primitives** and my
  per-cell `get_clock_regions` loop ran for 32 min 40 s. The batched form --
  `get_property NAME $cs` and `get_property REF_NAME $cs` on the whole
  collection at once -- returned the same information in **2 seconds**. Never
  loop `get_property` over a large collection in Vivado Tcl; pass the collection.

- **My own trap, cost one checkpoint open (72 s).** An unguarded Tcl error
  (`get_clock_groups`) aborted the batch session and discarded the loaded
  design. Every later step went inside a `catch`. On a checkpoint that costs
  over a minute to open, a `catch` per step is not defensive style, it is the
  difference between one session and five.

- **My own trap, twice, on process control.** `ps -o rss= -g <pgid>` does not
  select by process group (`-g` takes session leaders or group *names*); the
  correct form is `ps -eo pgid,rss` filtered in awk. And `setsid bash -c 'exec
  vivado ...'` does **not** give the vivado process the pgid that `$!` reports;
  the guard was watching the wrong group and silently did nothing for the first
  session. Verify a guard is reading a non-zero RSS before trusting it.

- **The engine's HBM AXI clock is named `fk33_dmabram_BRAM_PORTA_CLK`.** That is
  Vivado naming the auto-derived clock on `xdma/axi_aclk` after an unrelated
  BRAM controller port. Its period is 4.000 ns and it is the right clock. Do not
  read the name as evidence that something is wired to the DMA BRAM.

- **Mixed site coordinate spaces in a bounding box.** My `CONGEST-BBOX` step
  took `min`/`max` over the `LOC` of every leaf, but `LOC` values are
  `SLICE_XnYm`, `DSP48E2_XnYm` and `RAMB36_XnYm`, whose Y indices run on
  different scales (SLICE to ~239, DSP to ~95). The bbox numbers are therefore
  **not** a usable extent and are quoted here only for `streamer`, where the
  point being made (it is at the bottom) survives the contamination. The
  clock-region histogram in 4.4 is the reliable spatial measurement.

- **`iter_100_CongestedCLBsAndNets.txt`, `clockInfo.txt` and
  `tight_setup_hold_pins.txt` in the repo root are from an Aug-27 `u_rms` run,
  not this build.** They name `u_rms/p_0_out0` and three CLB tiles and look
  exactly like what this investigation wanted. They are stale. Check `ls -la`
  dates before believing a stray Vivado artifact.

---

## 8. Machine discipline

Four Vivado batch sessions, each launched with `setsid` and each watched by an
explicit memory guard armed at **18,000,000 kB (18.0 GB)** on the session's own
process group before any long step. Guard kills by pgid, never by name pattern.

| session | peak RSS | wall |
|---|---|---|
| 1 (aborted on a Tcl error) | 7.16 GB | 1 min |
| 2 (utilization, regions, congestion) | 7.32 GB | 34 min |
| 3 (refs, fanout, clock interaction) | 7.30 GB | 2 min |
| 4 (routed_error checkpoint) | **8.29 GB** | 2 min |

**Peak memory used by this track: 8.29 GB.** The guard never tripped. Nothing
was placed or routed. For comparison, SHELL's build peaked at 22.81 GB, so
reading a checkpoint is roughly a third the memory and a fortieth the time of
producing one.

---

## 9. NOT verified

Stated explicitly so none of it is read as settled.

1. **That any lever works.** No place or route was run. Every "would fall to"
   and "would remove" number is arithmetic on measured cell counts, not a
   result.
2. **Whether Vivado will infer distributed RAM for `cb(idx)` at all** (Lever C).
   The primitive count for the replacement is a hand calculation.
3. **Whether relieving density actually relieves this congestion.** The
   correlation is strong -- 75-89% local LUT in the congested windows against
   39.50% design-wide -- but congestion is a routing-demand problem and density
   is a proxy for it, not the same thing.
4. **Why the placer left Y2/Y3 empty.** The HBM anchor at Y0, the `streamer`
   bbox at Y=0..68 and the 6,912-bit `streamer`-to-`core` interface are a
   coherent explanation and each part of it is measured, but the causal claim is
   an inference. A pblock experiment would settle it.
5. **The post-`phys_opt` per-clock WNS is from the `routed_error` checkpoint**,
   which also contains 23 routed nets. It is not the same snapshot as the
   `-0.260` the router printed at its last update, and the two differ (-0.354
   vs -0.260). I did not reconcile them.
6. **Hold.** `WHS = -0.460`, `THS = -331.271` appear in the router's first
   intermediate summary and nothing in this investigation looked at hold at all.
7. **`bd_i/pcie2hbm/inst`** appears at 19% of one level-5 window and 4-8% of
   several others. It was not investigated.
8. **Whether the codebook mux is on any critical path now.** The RTL header
   records it as the critical path at one point (`cb_reg[4][6]_replica_1/C ->
   tr_reg[0][1220]/...`, -2.041 ns) but that was a different build; I did not
   re-measure which paths fail today. The 433 failing endpoints on the core
   clock were counted, not examined.
9. **Whether `hw/fk33/gen_fk33_engine.py`'s `ROWS_IF = 48` and the
   `rtl/matvec_core.vhd` header's references to `ROWS_IF = 58`, 1,914 DSPs and
   135k LUTs describe the same build.** They do not -- this build measures 1,584
   DSP and 118,068 LUT in `matvec_core` at `ROWS_IF = 48`. The header comment is
   stale. I did not fix it (RTL is not this track's to edit) and it is recorded
   here so the next reader does not take those numbers as current.

---

## 10. Corrections

### CORRECTION 2026-08-29 -- OI-12's "report_design_analysis -congestion did not complete"

**WITHDRAWN.** `report_design_analysis -congestion` completes in **14 seconds**
on `bd_wrapper_placed.dcp` and **24 seconds** on `bd_wrapper_routed_error.dcp`,
measured this session with the timestamps in section 3. The sentence in OI-12
that begins "What is NOT known is what is congested" is superseded by sections
4.3, 4.4 and 4.5 of this file.

The probable cause of the original observation is that
`report_design_analysis` **without** `-congestion` performs the timing and
logic-level analysis, which on this design's 350,285-endpoint clock is what does
not terminate. This is the same shape as the OI-13 trap -- an expensive default
mistaken for an expensive report.

### CORRECTION 2026-08-29 -- OI-13's "nothing currently proves the per-port CDC is being treated as asynchronous"

**WITHDRAWN.** `report_clock_interaction` proves it directly, in 15-18 seconds,
and is shown in section 4.7: both directions of the engine's core-to-AXI
crossing are reported as `Asynchronous Groups` / `Ignored`, 2,221 and 402
endpoints. The consequence OI-13 drew -- "if the group did NOT apply, every WNS
above is pessimistic" -- does not arise. The per-clock WNS figures OI-13 said
did not exist are in the table in section 4.7.

OI-13's underlying measurement stands and should not be retried: `get_timing_paths
-from <core> -to <axi> -max_paths 8` genuinely does not terminate here. What was
wrong was concluding that no cheap check existed. `gen_pcieep.py` already writes
`report_clock_interaction` to `fk33_pcieep_clkint.rpt` for a human; that file is
a stronger check than the script credits it with, and the build should assert on
it rather than merely emit it -- **but note it never got written in this build**,
because the whole post-implementation reporting block sits after `wait_on_run
impl_1`, which errored.

---

## 11. Where the raw reports live

The two checkpoints are in a session scratchpad and will not survive:

```
<shell-scratch>/eng_full/fk33_pcieep/fk33_pcieep.runs/impl_1/bd_wrapper_placed.dcp
<shell-scratch>/eng_full/fk33_pcieep/fk33_pcieep.runs/impl_1/bd_wrapper_routed_error.dcp
```

Everything this file quotes was therefore copied into
**`hw/fk33/results/congestion_2026-08-29/`**:

| file | what it is |
|---|---|
| `placed_congestion.rpt` | `report_design_analysis -congestion` on the placed checkpoint |
| `routed_error_congestion.rpt` | the same, on routed_error -- **section 2 is the router's own congestion** |
| `routed_error_route_status.rpt` | 23 of 282,451 nets routed |
| `placed_high_fanout_nets.rpt` | the enable nets of section 4.6 |
| `placed_util_engine.rpt` / `placed_util_matvec_core.rpt` / `placed_util_weight_streamer.rpt` | `report_utilization -cells` per module |
| `placed_util_hierarchy_engine.rpt` | the engine subtree of `report_utilization -hierarchical` |
| `placed_clock_region_loads.rpt` | `report_clock_utilization` sections 5 and 6, the per-region DSP/BRAM/FF table of section 4.4 |
| `placed_core_clock_region_histogram.txt` | the 8x4 histogram of section 4.4 |
| `placed_core_structure_breakdown.txt` | the by-signal, by-primitive-class table of section 4.5 |
| `placed_clock_interaction.rpt` / `routed_error_clock_interaction.rpt` | the clock-group evidence of section 4.7 |
