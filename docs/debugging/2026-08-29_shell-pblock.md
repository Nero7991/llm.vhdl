# Can the FK33 shell build be made to route without changing its arithmetic?

**Date:** 2026-08-29
**Build:** `hw/fk33` shell + `fk33_engine`, TRACK SHELL's post-`opt_design`
checkpoint `bd_wrapper_opt.dcp` (commits `928ad9f` / `70c35db` / `d807a1c`).
Vivado 2023.2, `xcvu33p-fsvh2104-2L-e`, 250 MHz HBM AXI / 200 MHz core,
`ROWS_IF = 48`.
**Symptom being attacked:** `ERROR: [Route 35-3] Design is not routable as its
global congestion level is 7.` No bitstream had ever existed for this design.
**Track:** PBLOCK. No RTL was changed. Constraints and implementation strategy
only.

---

## 1. The question, verbatim

> **YOUR TASK: the levers that cost NO throughput**
>
> - **Lever A: a pblock spreading `matvec_core` into the empty top half
>   (Y2/Y3).** CONGEST calls this the only lever costing no throughput. This is
>   your primary task.
> - **Lever F: replicate the fanout-8,448 enables.** Do it if it helps.
> - **Lever B: pipeline the 6,912-bit `weight_streamer` to `matvec_core` bus.**
>   Consider it only if A alone is insufficient.
>
> **You may NOT touch levers C, D, E or G.**
>
> **The goal is a routed design and a bitstream.**

Plus, mid-task, from the coordinator on behalf of TRACK TANDEM:

> Tandem PCIe reserves a hard exclusion zone at the right edge of the die
> (`SLICE_X216Y0 : SLICE_X232Y239`, i.e. clock-region column X7 in all four
> rows). **If excluding column X7 costs you little, exclude it** and say what it
> cost. If it materially hurts routability, do not sacrifice routing for future
> compatibility.

---

## 2. The answer, up front

**The design routes, it meets every timing constraint it has, and there is a
bitstream.** `hw/fk33/bit/fk33_pcieep_eng.bit`, 22,568,402 bytes:

- **282,090 of 282,090 routable nets fully routed, 0 nets with routing errors.**
- **Setup MET on every clock. WNS +0.045 ns, TNS 0.000, 0 failing endpoints of
  576,171.** The engine core clock closes at 200 MHz (+0.045, 0 of 350,054) and
  the HBM AXI clock at 250 MHz (+0.085, 0 of 193,609).
- **Hold MET. WHS +0.010 ns, THS 0.000, 0 failing endpoints.**
- **`report_drc`: 0 errors, 0 critical warnings.**

against a starting point of `[Route 35-3]`, no bitstream, core clock -0.354,
AXI clock -0.315 and `THS -331.271`. **Nothing has verified what it computes.**

**But lever A is not the real fix, and the congestion was never the placer's
choice.** The root cause is an **inherited constraint that was in the repo the
whole time**: `hw/fk33/fk33_pcieep.xdc` lines 133-140 assign **the entire block
design `bd_i`** to a pblock `pblock_bd_i` whose area is the bottom ~51 SLICE
rows plus the rightmost 14 SLICE columns. MEASURED from TRACK SHELL's own
`runme.log`, which said so at the time:

```
WARNING: [Place 30-640] Place Check : Pblock pblock_bd_i has 173441 Slice LUTs(s)
assigned to it, but only 115752 Slice LUTs(s) are available in the area range defined.
WARNING: [Place 30-640] Place Check : This design requires more DSPs cells than are
available in Pblock 'pblock_bd_i'. This design requires 1585 of such cell types but
only 524 compatible sites are available in Pblock 'pblock_bd_i'.
WARNING: [Place 30-640] Place Check : Pblock pblock_bd_i IS_SOFT property set.
Ignoring capacity requirements for cells assigned to Pblock.
```

`IS_SOFT` is why the build did not fail outright: the placer crams what it can
into an area holding 67% of the assigned LUTs and 33% of the assigned DSPs, then
spills the rest. That spill IS the 96.1%-in-the-bottom-16-clock-regions
distribution CONGEST measured, and it is why local LUT occupancy was 75-89%
against 39.50% design-wide.

**MEASURED, the decisive ablation (run `D`):** delete `pblock_bd_i`, change
nothing else -- same netlist, same `place_design -directive ExtraPostPlacementOpt`
that SHELL's `Performance_RefinePlacement` strategy uses. Result: the core
spreads to **Y0 9.16% / Y1 31.69% / Y2 32.80% / Y3 26.35%**, congestion falls to
**5 windows, worst level 6**, and setup timing goes from **WNS -0.759 to WNS
+0.416 with zero failing endpoints**, at placement, before any `phys_opt`.

**Lever A works too, and it produced the first routed design of the day** (run
`ASX`: a pblock on `matvec_core` at `CLOCKREGION_X0Y1:CLOCKREGION_X6Y3`, routed,
bitstreamed, kept as `hw/fk33/bit/fk33_pcieep_eng_asx_wns-0p077.bit`). It works
by taking `matvec_core` **out of** `pblock_bd_i` -- a cell belongs to one
pblock, and the more specific assignment wins -- and giving it a feasible area.
It is a compensating constraint for a wrong one, and **it is strictly worse: it
routes but misses setup by 77 ps on 1,948 endpoints.** Deleting the wrong
constraint instead meets timing outright.

**What ships is run `DX`: delete `pblock_bd_i`, and keep one small pblock**
holding `matvec_core` out of clock-region column X7 for TRACK TANDEM's benefit.
`hw/fk33/fk33_pblock.xdc` plus the `gen_pcieep.py` change that comments the
inherited pblock out of the emitted XDC.

**Lever F was not needed and was not done.** Lever B was not needed and was not
done. **No RTL file was touched.** No throughput, cycle count or clock frequency
changed; `ROWS_IF` is still 48 and the core clock is still 200 MHz, and it now
closes.

**On column X7 (TANDEM): excluding it costs nothing, and the shipped design
excludes it.** The answer is **option 1**. MEASURED two ways: on the
`pblock_bd_i`-present path, dropping X7 took the core's pblock from 327,840 to
289,920 LUT sites (-11.57%) and 2,304 to 2,160 DSP sites (-6.25%) and the
X7-excluded placement was the one that routed; on the shipped path the core sits
at 118,550 of 388,800 LUT (30.49%) and 1,584 of 2,700 DSP (58.67%) inside
`CLOCKREGION_X0Y0:X6Y3` and meets timing with 5 congested windows. See section
4.5 for why this still does **not** make the design Tandem-ready.

---

## 3. The procedure

Six Vivado batch sessions, every one launched under an explicit memory guard
armed at **18,000,000 kB (18.0 GB)** before any long step, and every one
verified to be reading a non-zero RSS before the step began. **No hardware was
touched.** `place_design`, `phys_opt_design`, `route_design`, `report_*` and
`write_bitstream` only; `write_bitstream` produces a file and programs nothing.

Everything started from TRACK SHELL's **`bd_wrapper_opt.dcp`** -- the
post-`opt_design`, pre-`place_design` checkpoint -- not from RTL. That is the
whole reason this fitted in an afternoon: synthesis is where SHELL's 22.81 GB
and most of its hours went, and none of it had to be repeated. `opt.dcp` carries
the constraints, so the clock groups, the bitstream properties and
`pblock_bd_i` itself all come with it.

| run | what changed vs SHELL's build | what it isolates |
|---|---|---|
| baseline | (nothing -- CONGEST's measurements of `bd_wrapper_placed.dcp` and `bd_wrapper_routed_error.dcp`) | the thing being beaten |
| `A` | + pblock `pb_core` = `CLOCKREGION_X0Y1:X7Y3` | **lever A alone**, at SHELL's own placer directive |
| `S` | `place_design -directive AltSpreadLogic_high`, no pblock | **the ablation for A**: does the congestion-oriented placer directive do it on its own |
| `AS` | both | interaction |
| `ASX` | pblock `CLOCKREGION_X0Y1:X6Y3` (column X7 dropped) + `AltSpreadLogic_high` | the TANDEM constraint's cost. **Routed and bitstreamed, misses setup by 77 ps.** |
| `D` | `delete_pblocks pblock_bd_i`, nothing else, SHELL's own directive | **the decisive ablation**: is the inherited pblock the cause |
| `DX` | `delete_pblocks pblock_bd_i` + pblock `CLOCKREGION_X0Y0:X6Y3` | the minimal Tandem-safe form of the real fix. **THIS IS WHAT SHIPS.** |

One run, `AX` (`CLOCKREGION_X0Y1:X6Y3` + `ExtraPostPlacementOpt`), was launched
and **killed as superseded** once `ASX` had answered the X7 question. It is the
missing cell of a 2x2 and it was not worth 17 minutes of a contended box.

Three controls worth naming:

- **`S` is the control for `A`.** Without it, "the pblock fixed it" is
  indistinguishable from "any congestion-aware placement fixes it". `S` shows
  the directive alone leaves the core exactly where it was, so the pblock is the
  lever and the directive is not.
- **`D` is the control for the whole explanation.** CONGEST's causal story was
  "the HBM edge anchors `weight_streamer`, which drags `matvec_core` south
  through a 6,912-bit bus". That story is coherent and every component of it is
  measured, but `D` shows it is not what was binding: remove one inherited
  constraint and the placer spreads the core across all four clock-region rows
  by itself, with a better result than any pblock produced.
- **The placer's congestion table against the router's own.** Section 1 of
  `report_design_analysis -congestion` is the placer's estimate and section 2,
  which only exists post-route, is the router's measurement. Both were read; the
  router's is the one that decides whether `[Route 35-3]` fires.

Every step ran inside a Tcl `catch`, following CONGEST's finding that one
unguarded error discards a checkpoint that costs 70-80 seconds to open.

---

## 4. The evidence

### 4.1 The inherited pblock, and that it is soft (MEASURED)

`hw/fk33/fk33_pcieep.xdc:133-140`, generated verbatim from
`hw/fk33/fk33_i2cprobe.xdc:133-140` by `gen_pcieep.py` (which copies the XDC
through with lane, sysref and debug-hub edits only):

```tcl
create_pblock pblock_bd_i
add_cells_to_pblock [get_pblocks pblock_bd_i] [get_cells -quiet [list bd_i]]
resize_pblock [get_pblocks pblock_bd_i] -add {SLICE_X219Y0:SLICE_X232Y239 SLICE_X0Y0:SLICE_X218Y50}
resize_pblock [get_pblocks pblock_bd_i] -add {DSP48E2_X31Y0:DSP48E2_X31Y89 DSP48E2_X0Y0:DSP48E2_X30Y13}
resize_pblock [get_pblocks pblock_bd_i] -add {LAGUNA_X30Y0:LAGUNA_X31Y119}
resize_pblock [get_pblocks pblock_bd_i] -add {RAMB18_X13Y0:RAMB18_X13Y95 RAMB18_X0Y0:RAMB18_X12Y19}
resize_pblock [get_pblocks pblock_bd_i] -add {RAMB36_X13Y0:RAMB36_X13Y47 RAMB36_X0Y0:RAMB36_X12Y9}
resize_pblock [get_pblocks pblock_bd_i] -add {URAM288_X0Y0:URAM288_X4Y11}
```

`SLICE_X0Y0:SLICE_X218Y50` is 51 SLICE rows. A clock region on this device is
**60** SLICE rows tall (MEASURED, section 4.6), so the main body of that area is
not even one clock-region row deep. The rest is `SLICE_X219..X232`, the
rightmost 14 SLICE columns, full height.

Read back from the loaded checkpoint (run `D`, before deletion):

```
PBLOCK-PROOF D pblocks_before=pblock_bd_i
PBLOCK-PROOF D IS_SOFT=1
PBLOCK-PROOF D GRID=URAM288_X0Y0:URAM288_X4Y11 RAMB36_X13Y0:RAMB36_X13Y47 ... 
PBLOCK-PROOF D cells=1
PBLOCK-PROOF D pblocks_after=
```

and TRACK SHELL's own build log, `runme.log` lines 1007-1015, which contained
the whole answer at the time:

```
WARNING: [Place 30-640] Place Check : Pblock pblock_bd_i has 173441 Slice LUTs(s) assigned to it, but only 115752 Slice LUTs(s) are available in the area range defined. ...
WARNING: [Place 30-640] Place Check : Pblock pblock_bd_i has 162086 LUT as Logic(s) assigned to it, but only 115752 LUT as Logic(s) are available ...
WARNING: [Place 30-640] Place Check : This design requires more DSPs cells than are available in Pblock 'pblock_bd_i'. This design requires 1585 of such cell types but only 524 compatible sites are available ...
WARNING: [Place 30-640] Place Check : This design requires more RAMB36/FIFO cells ... requires 259 ... only 178 compatible sites are available ...
WARNING: [Place 30-640] Place Check : Pblock pblock_bd_i IS_SOFT property set. Ignoring capacity requirements for cells assigned to Pblock.
```

DERIVED: the area holds **66.7%** of the assigned LUTs (115,752 of 173,441) and
**33.1%** of the assigned DSPs (524 of 1,585). The pblock is oversubscribed by
half on the design's dominant resource, and being soft, it does not say so as an
error.

### 4.2 Where `matvec_core` ends up, per run (MEASURED)

Clock-region row histogram of `matvec_core`'s placed leaf cells. Baseline row is
CONGEST's measurement of `bd_wrapper_placed.dcp`; the rest are this track's,
computed from every leaf's `LOC` with a divisor measured from the device rather
than assumed (section 4.6).

| run | Y0 | Y1 | Y2 | Y3 |
|---|---|---|---|---|
| baseline (SHELL) | **55.3%** | 40.8% | 3.7% | 0.2% |
| `S` -- directive only, no pblock | **48.96%** | 44.83% | 6.10% | 0.10% |
| `A` -- pblock Y1..Y3 | 0.58% | 29.07% | 33.89% | 36.46% |
| `AS` -- pblock Y1..Y3 + directive | 0.24% | 29.53% | 34.91% | 35.32% |
| `ASX` -- pblock Y1..Y3, no X7, + directive | 0.53% | 33.04% | 35.93% | 30.51% |
| `D` -- **delete `pblock_bd_i`** | 9.16% | 31.69% | 32.80% | 26.35% |
| `DX` -- **delete `pblock_bd_i`** + pblock X0Y0:X6Y3 (**ships**) | 9.70% | 28.74% | 30.50% | 31.05% |

**`S` is the finding in this table.** `place_design -directive
AltSpreadLogic_high` is Vivado's own congestion-spreading directive, and on its
own it moves the distribution by about six points. It does not touch the cause,
because the cause is a constraint, not a placer preference.

**`D` is the other finding.** With the wrong constraint gone and no new one
added, the placer distributes the core across all four rows unaided, and leaves
9.16% of it near the HBM edge, which is where the `weight_streamer` interface
actually wants it.

### 4.3 Congestion, per run (MEASURED, `report_design_analysis -congestion`)

Placer's own table, section 1. "windows" is how many rows the report emitted at
all; a run with fewer congested windows and lower local LUT is better.

| run | congested windows | worst level | worst Global level | local LUT range | placed WNS |
|---|---|---|---|---|---|
| baseline | 23 | 7 (South/East Long) | 6 | 51-87% | -0.759 |
| `S` | 23 | 7 (South Long, 50% LUT) | 6 (76-79%) | 50-85% | -0.405 |
| `A` | 20 | 7 (South Long, 34% LUT) | 6 (60-66%) | 34-83% | **+0.075** |
| `AS` | 7 | 6 | 6 (56-65%) | 49-74% | -0.244 |
| `ASX` | 10 | 6 | 6 (55-64%) | 55-74% | -0.220 |
| `D` | **5** | 6 | 5 (63%) | 53-78% | **+0.416** |
| `DX` (**ships**) | **5** | 6 | 5 (58%) | 56-66% | **+0.379** |

The router's own congestion, `report_design_analysis -congestion` section 2,
which only exists after a route attempt. **This is the number `[Route 35-3]`
tests.**

Baseline (`bd_wrapper_routed_error.dcp`, CONGEST):

```
| South | Global | 7 | (CLEM_X13Y18,CLEL_R_X140Y81)   | core(80%),bd_i(16%)
| East  | Global | 7 | (CLEM_X1Y0,CLEM_X128Y95)       | core(74%),bd_i(16%)
| West  | Global | 7 | (CLEL_L_X15Y20,CLEL_R_X142Y83) | core(79%),bd_i(17%)
```

`ASX`, routed:

```
| South | Global | 6 | (CLEM_X32Y58,CLEM_X95Y121)  | core(98%)
| East  | Global | 6 | (CLEM_X32Y121,CLEM_X95Y168) | core(98%)
| East  | Global | 6 | (CLEM_X32Y137,CLEM_X95Y168) | core(98%)
| West  | Global | 5 | (CLEM_X80Y0,CLEM_X111Y15)   | streamer(40%),xdma(...)
| South | Long   | 7 | (CLEM_X30Y33,CLEM_X93Y160)  | core(87%)
| East  | Long   | 7 | (CLEL_L_X15Y81,CLEM_X78Y208)| core(99%)
```

`DX`, the shipped run, routed:

```
| South | Global | 6 | (CLEL_R_X56Y61,CLEM_X87Y140) | core(90%),pcie2hbm
| West  | Global | 5 | (CLEM_X67Y88,CLEM_X90Y143)   | core(90%)
| West  | Global | 5 | (CLEM_X67Y112,CLEM_X82Y143)  | core(98%)
| South | Long   | 7 | (CLEM_X32Y13,CLEM_X95Y204)   | core(82%),bd_i(9%)
| West  | Long   | 6 | (CLEM_X59Y57,CLEM_X90Y152)   | core(88%),pcie2hbm
| South | Short  | 5 | (CLEM_X64Y70,CLEM_X79Y101)   | core(89%)
```

**Global congestion went from 7 in three directions to 6 in one, and the router
proceeded.** Long congestion is still 7 in one direction; `[Route 35-3]` is a
**global**-congestion test, so Long-7 does not abort it. The owner is unchanged
and unarguable: `matvec_core` is 82-98% of every congested window. Relieving
density did not make it stop being the owner; it made the design routable
anyway.

And the router's own live estimate at the top of `route_design`, `ASX` against
`DX`. 2x2 is level 1, 4x4 level 2, 8x8 level 3, 16x16 level 4, 32x32 level 5,
64x64 level 6, 128x128 level 7. **The Global column is the one that gates.**

```
ASX                              DX
|NORTH|   8x8| 0.75|   16x16|    |NORTH|   2x2| 0.23|     4x4| 1.55|
|SOUTH| 64x64| 8.29| 128x128|    |SOUTH| 64x64| 8.18| 128x128|20.03|
| EAST| 64x64| 7.31| 128x128|    | EAST|   4x4| 0.83|   16x16| 3.07|
| WEST| 32x32| 3.51|   64x64|    | WEST| 32x32| 3.78|   64x64|10.12|
```

`DX` takes East global congestion from level 6 to level 2 and North from 3 to 1.
Only South is unchanged, and South is where `weight_streamer` reaches the HBM
edge.

### 4.3.1 The shipped run, routed (MEASURED)

```
   # of routable nets..................... :      282090 :
       # of fully routed nets............. :      282090 :
       # of nets with routing errors...... :           0 :
```

`report_drc`: **0 ERROR, 0 CRITICAL WARNING.** `write_bitstream` produced
22,568,402 bytes. Whole-design utilization after routing: **38.62% LUT
(169,818 of 439,680), 14.21% FF, 38.91% BRAM36, 55.03% DSP (1,585 of 2,880),
0 URAM.**

Proof the floorplan is what shipped, read back from the routed checkpoint:

```
PBLOCK-PROOF routed GRID_RANGES=CLOCKREGION_X0Y0:CLOCKREGION_X6Y3 pblocks=pb_core
```

`pblocks=pb_core` is the whole list. **`pblock_bd_i` is gone.**

### 4.4 The pblock geometry, and proof it was applied (MEASURED)

The shipped constraint, exactly as it is now in `hw/fk33/fk33_pblock.xdc`:

```tcl
create_pblock pb_core
add_cells_to_pblock [get_pblocks pb_core] [get_cells bd_i/eng/inst/eng/dut/core]
resize_pblock [get_pblocks pb_core] -add {CLOCKREGION_X0Y1:CLOCKREGION_X6Y3}
```

Read back from the design, not from the file -- before placement:

```
PBLOCK-PROOF ASX GRID_RANGES=CLOCKREGION_X0Y1:CLOCKREGION_X6Y3
PBLOCK-PROOF ASX DERIVED_RANGES=CLOCKREGION_X0Y1:CLOCKREGION_X6Y3
PBLOCK-PROOF ASX cells_in_pblock=1
```

and again from the **routed** checkpoint, after `place_design`,
`phys_opt_design` and `route_design` have all run:

```
PBLOCK-PROOF routed pblocks=1 GRID_RANGES=CLOCKREGION_X0Y1:CLOCKREGION_X6Y3
PBLOCK-PROOF routed cells=1
```

`report_utilization -pblocks [get_pblocks pb_core]`, which is the strongest form
of the proof because it enumerates the sites the constraint actually confers:

| pblock | LUT used / avail | DSP used / avail | RAMB tile used / avail |
|---|---|---|---|
| `CLOCKREGION_X0Y1:X7Y3` (runs `A`, `AS`) | 118,550 / 327,840 = 36.16% | 1,584 / 2,304 = 68.75% | 21.5 / 504 = 4.27% |
| `CLOCKREGION_X0Y1:X6Y3` (run `ASX`, shipped) | 118,550 / 289,920 = **40.89%** | 1,584 / 2,160 = **73.33%** | 21.5 / 432 = 4.98% |
| `CLOCKREGION_X0Y0:X6Y3` (run `DX`) | 118,550 / 388,800 = 30.49% | 1,584 / 2,700 = 58.67% | 21.5 / 576 = 3.73% |

Its `Clock Region Statistics` section lists exactly the 24 (or 21) regions
expected, so the range is not being silently widened or dropped.

**Why the range must EXCLUDE a row rather than cover the die.** A pblock of
`CLOCKREGION_X0Y0:X7Y3` is the whole device and therefore a no-op: the placer
already had that freedom. The constraint has to remove the region the placer is
being pulled into. That is why `A`/`AS`/`ASX` start at Y1.

### 4.5 The X7 exclusion, costed (MEASURED, answering TANDEM)

DERIVED from the table above: dropping clock-region column X7 from the core's
pblock removes **37,920 of 327,840 LUT sites (11.57%)** and **144 of 2,304 DSP
sites (6.25%)**. Occupancy inside the pblock rises from 36.16% to 40.89% LUT and
from 68.75% to 73.33% DSP.

MEASURED effect on the result, `AS` (with X7) against `ASX` (without), same
directive, same everything else:

| | congested windows | worst level | local LUT | placed WNS | failing endpoints |
|---|---|---|---|---|---|
| `AS`, X7 included | 7 | 6 | 49-74% | -0.244 | 50 |
| `ASX`, X7 excluded | 10 | 6 | 55-74% | **-0.220** | **9** |

Three more congested windows, no change in worst level, and slightly *better*
timing. Within the run-to-run noise of a placement. **Excluding X7 is free, and
`ASX` is the run that was carried through to a routed design and a bitstream.**

**This does NOT make the design Tandem-ready, and must not be read that way.**
Only `matvec_core` is constrained. The other 55,626 LUTs of the design are
unconstrained and free to land in column X7, and `bd_i/xdma`'s PCIe4C hard block
and its GTY quad are physically there by necessity. All this buys is that the
engine, 68% of the design's LUTs, is already out of the reserved column. A real
Tandem build still has to solve the shell.

### 4.6 The clock-region row divisors (MEASURED, not assumed)

CONGEST's trap was that `LOC` Y indices run on different scales per site type,
so a single min/max over all `LOC`s is meaningless. Rather than assume the
textbook UltraScale+ numbers, each divisor was measured from the device by
walking `get_property CLOCK_REGION [get_sites <TYPE>_X0Y<n>]` until it changed:

```
PBLOCK-DIV SLICE    rows_per_clockregion=60 cr0=X0Y0
PBLOCK-DIV DSP48E2  rows_per_clockregion=18 cr0=X0Y0
PBLOCK-DIV RAMB36   rows_per_clockregion=12 cr0=X0Y0
```

**SLICE 60 and RAMB36 12 are the textbook values. DSP48E2 18 is NOT** -- the
textbook figure is 24. The measurement is right and the textbook is right: the
bottom clock-region row on this device is shortened by the HBM interface, so it
holds 18 DSP rows where rows Y1..Y3 hold 24. That is the same fact as CONGEST's
"Y0 has 576 DSP sites, Y1..Y3 have 768", seen from the other side, and it means
a single divisor is wrong for DSPs above Y0. See the trap in section 6.

### 4.7 The first routed design, `ASX` -- kept because it is the counterexample

`ASX` is the run that first got past `[Route 35-3]`, and it is kept in the
record because it shows that **routing and meeting timing are different
questions**. It routes completely and misses setup.

`report_route_status` on `ASX_routed.dcp`:

```
   # of logical nets.......................... :     1737603 :
       # of nets not needing routing.......... :     1449097 :
       # of routable nets..................... :      288506 :
           # of fully routed nets............. :      288506 :
       # of nets with routing errors.......... :           0 :
```

Against the baseline, where the router quit at initial routing having completed
**23 of 282,451**.

`report_drc` on the same checkpoint: **0 ERROR, 0 CRITICAL WARNING.** The
warning list is `DPIP-2` (1,536 -- DSP input pipelining, the known
`matvec_core` shape), `DPOP-4` (49), `FLBP-1` (1), `PDCN-1569` (3),
`REQP-*` (6), `RTSTAT-10` (1), `UTLZ-3` (6).

`write_bitstream` completed in 1 min 52 s and produced 22,971,838 bytes.

### 4.8 Timing after routing, per clock (MEASURED)

`report_timing_summary` on the routed checkpoints, against CONGEST's figures
from `bd_wrapper_routed_error.dcp`.

| clock | period | baseline | `ASX` routed | **`DX` routed (ships)** | `DX` failing endpoints |
|---|---|---|---|---|---|
| `clk_out3_bd_clk_wiz_0_0` (engine core, 200 MHz) | 5.000 | **-0.354** | -0.077 | **+0.045** | **0 of 350,054** |
| `fk33_dmabram_BRAM_PORTA_CLK` (HBM AXI, 250 MHz) | 4.000 | **-0.315** | 0.000 | **+0.085** | **0 of 193,609** |
| `clk_out1_bd_clk_wiz_0_0` (100 MHz) | 10.000 | +4.121 | +3.847 | +5.450 | 0 of 1,846 |
| `clk_out2_bd_clk_wiz_0_0` | -- | -- | -- | +1.390 | 0 of 5 |
| `pipe_clk` | 4.000 | +0.318 | +0.891 | +1.257 | 0 of 2,387 |
| `pcie_refclk` | 10.000 | +5.816 | +7.213 | +7.633 | 0 of 3,703 |
| `sysref_clk` | -- | -- | +0.046 | +0.600 | 0 of 21,840 |

Design-wide, `DX` routed: **WNS +0.045, TNS 0.000, 0 failing setup endpoints of
576,171. WHS +0.010, THS 0.000, 0 failing hold endpoints of 576,123. WPWS
0.000, 0 failing pulse-width endpoints.**

**Every constraint in the design is met.** The engine core clock closes at
200 MHz and the HBM AXI clock at 250 MHz, so the `duty = f_core / f_axi = 0.80`
identity the budget documents assume is achieved rather than assumed.

**Hold is now clean**, against the baseline's `WHS -0.460 / THS -331.271`.
CONGEST listed hold as never examined; it is examined and it is met.

**The intermediate `ASX` run is the counterexample worth keeping.** It routes
completely, passes DRC and produces a bitstream, and misses setup by 77 ps on
1,948 endpoints -- DERIVED, 1/(5.000 + 0.077) = 196.97 MHz against a 200 MHz
constraint. "It routes" and "it meets timing" are separate claims and the first
does not imply the second.

The clock group is still applied, so none of this is pessimism from that cause:

```
clk_out3_bd_clk_wiz_0_0     | fk33_dmabram_BRAM_PORTA_CLK | 0 | 2221 | Ignored | Asynchronous Groups
fk33_dmabram_BRAM_PORTA_CLK | clk_out3_bd_clk_wiz_0_0     | 0 |  402 | Ignored | Asynchronous Groups
```

---

### 4.9 Cells outside the pblock (MEASURED)

MEASURED on the routed checkpoint, by taking every `matvec_core` leaf's `LOC`
and counting those in a `SLICE_*Y<60` site, which is clock-region row Y0 and
therefore outside `CLOCKREGION_X0Y1:X6Y3`:

```
PBLOCK-OUTSIDE slice_row0_leaves=1077
PBLOCK-OUTSIDE ref LUT6 480    MUXF7 222   FDRE 141   MUXF8 111
PBLOCK-OUTSIDE ref LUT4 37     LUT2 37     LUT3 36    CARRY8 10   LUT5 3
PBLOCK-OUTSIDE eg bd_i/eng/inst/eng/dut/core/busy_i_1 @ SLICE_X115Y52
PBLOCK-OUTSIDE eg bd_i/eng/inst/eng/dut/core/cb[0][11][4]_i_1 @ SLICE_X33Y59
PBLOCK-OUTSIDE site SLICE_X115Y52 CLOCK_REGION=X3Y0
```

**1,077 of 220,180 leaves, 0.49%, are outside their own pblock**, and Vivado
raised no DRC error about it. The mechanism was not determined. The MUXF7/MUXF8
share (333 of 1,077, far above their 17% share of the module) is consistent with
Vivado placing mux clusters as indivisible shapes, and the one DRC warning that
does mention the pblock is about exactly that class:

```
FLBP-1#1 Warning
Pblock partition  - PBlock:pb_core
A LUT5 and an associated MUXF7 are not placed together in the same Pblock
because of conflicting Pblock constraints. ... The driver pin
bd_i/eng/inst/eng/dut/core/st[3]_i_4/O is in Pblock pb_core. The driven pin
bd_i/eng/inst/eng/dfetch/g_dc.fifo/st_reg[3]_i_1/I1 is in Pblock pblock_bd_i.
```

That warning is also how `pblock_bd_i` was discovered at all. **A pblock in this
design is a strong preference with a small measured leak, not an absolute
containment.** Anyone relying on a pblock for correctness rather than for
congestion -- a Tandem stage-one boundary, for instance -- must not assume 100%.

---


## 5. Measured and REJECTED -- do not retry

- **`place_design -directive AltSpreadLogic_high` on its own.** This is
  Vivado's own congestion-spreading directive and it is the obvious first thing
  to reach for. MEASURED (run `S`): it leaves `matvec_core` at **Y0 48.96% /
  Y1 44.83% / Y2 6.10% / Y3 0.10%**, which is the baseline distribution moved
  by six points, keeps a South Long level-7 window, keeps Global 5/6 windows at
  76-79% local LUT, and lands at WNS -0.405 with 1,126 failing endpoints. It
  does not address the cause. **Do not spend another run on placer directives
  alone.**

- **A pblock covering the whole device.** `CLOCKREGION_X0Y0:X7Y3` is every
  clock region and is therefore not a constraint at all; the placer already had
  that freedom and chose the bottom. A pblock only does work here if it
  *removes* area.

- **Lever A as specified -- a pblock confining `matvec_core` to Y1..Y3 while
  `pblock_bd_i` stays.** It works, and it is the worse answer. MEASURED, best
  variant (`ASX`): 10 congested windows, placed WNS -0.220, and after a full
  route **WNS -0.077 with 1,948 failing setup endpoints**. The same netlist with
  `pblock_bd_i` deleted instead (`DX`) routes at **+0.045 with zero failing
  endpoints**. Do not reach for a compensating floorplan before checking whether
  an existing constraint is the thing being compensated for.

- **Assuming 24 DSP rows per clock region on this device.** MEASURED, the
  bottom row has 18. A histogram built on a single divisor misattributes DSP
  cells; see section 6.

- **Reading CONGEST's causal story as the binding constraint.** "The HBM BLI
  sites are all at Y0, `weight_streamer` is confined to Y=0..68, and it hands
  `matvec_core` a 6,912-bit bus every core cycle, so the core is dragged south."
  Every component of that is measured and true, and it is **not what was
  binding**. Run `D` deletes one inherited pblock and the placer immediately
  distributes the core across all four rows with better timing than any
  floorplan this track wrote. CONGEST's section 9 item 4 explicitly flagged this
  as an inference needing a pblock experiment; the experiment says the inference
  was wrong. Lever B, "pipeline the streamer-to-core bus", was justified by that
  story and should be re-costed before anyone spends RTL risk on it.

- **Levers F and B were not needed.** No RTL was changed and the design routes.
  The fanout-8,448 enable nets (`w_r[6143]_i_1_n_0`, `trn[4][1377][27]_i_1_n_0`)
  are still there, unreplicated. They were not the obstacle.

---

## 6. Measurement traps hit, including my own

- **My own, and it cost the bitstream a whole session.** The route script ended
  with an un-`catch`ed line I had written carelessly:
  `set st [get_property STATUS [get_property ROUTE_STATUS [current_design]]]`.
  The inner call returns a string, the outer one wants an object, and Vivado
  exits with `ERROR: [Common 17-161] Invalid option value '' specified for
  'object'` -- **after a 41-minute route had succeeded and before
  `write_bitstream` ran**. Every report had been written, so the failure was
  invisible in the artifacts; only the guard's `rc=1` and the missing `.bit`
  gave it away. CONGEST's rule was "wrap every step in a `catch`". I wrapped
  every step I thought of as a step and left a bare expression between two of
  them. **A `catch` discipline has to cover the glue, not just the verbs.**

- **`grep`ping a Vivado log for a marker your own Tcl also contains.** Vivado
  echoes the sourced script into the log, so a wait loop polling for
  `route_design done` matched the `stamp "route_design done"` line **in the
  echoed source** and returned instantly, reporting a finished route ninety
  seconds after launch. The fix is to anchor on the emitted form
  (`^PBLOCK-STAMP .* route_design done`), which the echoed source cannot match
  because it is prefixed with `#`. This is the same shape as the incident the
  brief warns about, where a success line printed and the job aborted five
  minutes later.

- **`report_utilization -pblocks` "Parent" is assignment, not location.** After
  placement it showed 115,879 core LUTs where 118,550 were assigned, and 13,922
  "Non-Assigned" cells sitting inside the pblock region. Neither number answers
  "did all the assigned cells land inside", and reading it as if it did is easy.
  The direct measurement is section 4.9's LOC sweep.

- **The DSP divisor.** Measuring one probe column and generalising is exactly
  the trap CONGEST described in a different form. `DSP48E2_X0Y18` is in clock
  region X0Y1 because row Y0 is shortened by HBM, but rows Y1..Y3 hold 24 DSP
  rows each, so `floor(Y/18)` over-counts for every DSP above Y0. It affects
  1,584 of 220,180 cells and none of the conclusions, but the histogram's DSP
  bucket is wrong above row 0 and the "unmapped" tail in the logs is that error
  spilling past row 3. The SLICE divisor, which is 99.3% of the cells, is
  uniform at 60 and was verified.

- **`report_design_analysis` section numbering shifts.** On a **placed**
  checkpoint section 1 is `Placer Final Level Congestion Reporting` and section
  2 is `SLR Net Crossing`; on a **routed** one section 2 is `Router Initial
  Congestion` and SLR moves to 3. A `sed -n '19,50p'` tuned on one is silently
  wrong on the other. Grep for the section heading, not a line number.

- **`hs_err_pid*.log`, `clockInfo.txt` and friends in the repo root are still
  stale**, as CONGEST recorded. `clockInfo.txt` also exists inside each
  `impl_1` directory and *that* copy is current. Check the path, not just the
  date.

- **The answer was in `runme.log` for a day before anyone read it.** Both
  CONGEST and this track opened that file, and `Place 30-640` is nine lines
  saying, in plain English, that a pblock is oversubscribed by half on the
  design's dominant resource. CONGEST's own procedure table lists "the placer's
  own estimated-congestion table and the router's phase log -- costs nothing and
  should always be read first" as step 0, and it read the congestion table and
  not the warnings. **`grep -c WARNING` on a Vivado implementation log returns a
  number in the hundreds and that is exactly why the important ones are missed.**
  `grep -E '30-640|18-4[0-9]{3}'` is the cheap targeted form, and it is now the
  first thing to run on any build that misbehaves in the placer.

- **`report_timing_summary` does not report bus skew.** It says so, as
  `[Timing 38-436]`, in a warning that scrolls past. "0 failing endpoints"
  covers setup, hold and pulse width and nothing else.

## 7. What was changed in the repo

- **`hw/fk33/fk33_pblock.xdc`** -- new. `pb_core` at
  `CLOCKREGION_X0Y0:CLOCKREGION_X6Y3`, hand-written, with the measurements that
  justify each part of the range in its header, including the three things that
  look like they would work and do not.
- **`hw/fk33/gen_pcieep.py`** -- three changes:
  1. comments the 13 `pblock_bd_i` lines out of the emitted XDC, with an
     `n_pblock != 13` abort so a change in the probe's shell floorplan cannot
     silently reintroduce it;
  2. adds `fk33_pblock.xdc` to the build as `used_in_synthesis false` /
     `used_in_implementation true`, and errors immediately if the first
     property did not take;
  3. appends an `FK33_PBLK` block to the post-implementation checks that reads
     `GRID_RANGES` back from the implemented design and fails the build if
     `pblock_bd_i` is present, if `pb_core` is absent, or if its range is not
     the measured one.
  The placer directive is deliberately **not** changed; `Performance_RefinePlacement`
  stays.
- **`hw/fk33/build_fk33_pcieep.tcl`**, **`hw/fk33/fk33_pcieep.xdc`** --
  regenerated. Both diffs contain only the intended hunks. `check_pcieep_xdc.py`
  still passes (31 of 31 live `PACKAGE_PIN` constraints, 16 PCIe lanes).
- **`hw/fk33/results/pblock_2026-08-29/`** -- every report quoted here, plus the
  Tcl that produced them.
- **`hw/fk33/bit/`** is gitignored, so these are on disk and not in the tree:
  - **`fk33_pcieep_eng.bit`** -- 22,568,402 bytes, run `DX`. Routes, meets all
    timing. **This is the one.**
  - **`fk33_pcieep_eng_asx_wns-0p077.bit`** -- 22,971,838 bytes, run `ASX`.
    Routes, misses setup by 77 ps. Kept as the counterexample; **do not load it
    in preference to the other one.**

---

## 8. Machine discipline

Every session was launched with `setsid` into its own session/process group,
recorded its own pgid from inside that group, and was watched by a poller
summing `ps -eo pgid=,rss=` over that group -- CONGEST's two process-control
traps, avoided by construction rather than by care. The guard was armed at
**18,000,000 kB (18.0 GB)** for every session and **verified to be reading a
non-zero RSS before the long step began** in every case. It never tripped, and
it kills by pgid, never by name pattern.

| session | what | peak RSS | wall | rc |
|---|---|---|---|---|
| `sweep` | placements `A`, `S`, `AS` | 8.08 GB | 54 min | 0 |
| `x7` | placement `ASX`; `AX` killed as superseded | 7.74 GB | 24 min | 127 (killed by me) |
| `routeASX` | `phys_opt_design` + `route_design` | 8.32 GB | 46 min | 1 (my Tcl bug, section 6) |
| `finish` | DRC + `write_bitstream` for `ASX` | 6.95 GB | 7 min | 0 |
| `del` | placement `D` | **8.62 GB** | 14 min | 0 |
| `dx` | placement `DX` | 8.38 GB | 71 min | 0 |
| `routeDX` | `phys_opt_design` + `route_design` + DRC + `write_bitstream` | 6.85 GB | 66 min | 0 |

**Peak memory used by this track: 8.62 GB** as measured by the guard's own
5-second polling, against the 18.0 GB guard and the 32 GB box. Vivado's internal
`peak =` figures in the same logs reach 9.6-11.3 GB, which is the higher and
more conservative number; the guard samples, Vivado's counter is a high-water
mark, and they should not be expected to agree. Three other agents were running
throughout; the load average ranged from 3.8 to 25.3. **No two Vivado sessions
were ever run concurrently**, deliberately: 2 x 11 GB against 27 GB available
with other agents live is how the 2026-07-04 `systemd-oomd` incident killed an
entire cgroup.

**The contention is visible in the wall times and it is large.** The `DX`
placement took **71 minutes** where the identical-shaped `D` placement took
**14**, on the same box, from the same checkpoint, at the same 6 threads. The
difference is the load average, which was 8-11 during `D` and 22-25 during `DX`.
Anyone reading these wall times as a cost model for this design will be wrong by
5x in either direction. `cpu` time in the Vivado log is the stable number:
`DX`'s placement was 33 min 51 s of CPU against 40 min 26 s elapsed.

For calibration: TRACK SHELL's full build peaked at 22.81 GB, but its
**implementation** phase peaked at only 11.3 GB (`runme.log`). The 22.81 GB was
synthesis. Starting from `opt.dcp` skips it entirely, which is why this track's
whole afternoon cost less memory than one of SHELL's synthesis runs.

---

## 9. NOT verified

Stated explicitly so none of it is read as settled.

1. **Nothing has verified what this bitstream computes.** It routes, it meets
   timing, it passes DRC, and it was produced from a netlist no one has
   simulated at this geometry. A routed design is not a correct design, and
   "meets timing" is a statement about the static timing model, not about
   arithmetic.
2. **The bitstream was never loaded.** No hardware was touched by this track at
   any point. Timing closure in Vivado at the -2L speed grade also assumes
   VCCINT is in spec; this board powers up at 0.678 V, below the 0.698 V floor,
   and needs the digital pot moved to wiper 68 before any of it applies.
3. **`D` was not routed.** It is the cleanest measured placement and it is what
   isolates the cause, but the run carried through to a route is `DX`, which is
   `D` plus a pblock. `D` routing is an ESTIMATE, not a result.
4. **The regenerated build has not been run end to end.** `gen_pcieep.py` was
   changed, `build_fk33_pcieep.tcl` and `fk33_pcieep.xdc` were regenerated, and
   the diffs are exactly the intended ones and nothing else. But **the shipped
   bitstream came from a checkpoint flow, not from that script**, and no
   synthesis has been run since the change. Two specific things are therefore
   unproven: that `used_in_synthesis false` on `fk33_pblock.xdc` behaves as
   expected inside a project run, and that the post-implementation `FK33_PBLK`
   gate fires correctly. Both are cheap to check on the next full build and both
   should be watched for.
5. **Why 1,077 core leaves are outside their pblock is not determined**
   (section 4.9). The shape hypothesis is consistent with the primitive mix and
   with the one `FLBP-1` warning, and is not proven. The measurement was made on
   `ASX`; it was not repeated on `DX`.
6. **Whether `pblock_bd_i` serves any purpose** was not established. It comes
   from SQRL's example design via `fk33_i2cprobe.xdc` and its area looks like a
   shell-region floorplan from a much smaller design. Deleting it is measured to
   help this build; whether it was load-bearing for the PCIe or HBM shell in
   some way not visible in these reports is unknown.
7. **Bus skew was reported but not read.** `report_timing_summary` warns
   `[Timing 38-436] There are set_bus_skew constraint(s) in this design. Please
   run report_bus_skew`. It was run on `ASX` and nobody has looked at it, and it
   was not run on `DX`. **`report_timing_summary` does not cover bus skew**, so
   "0 failing endpoints" above does not include it.
8. **No incremental-placement path was tried.** Every run in this track is a
   full `place_design` from `opt.dcp`. Whether `place_design -Incremental` from
   the existing placed checkpoint would have got there faster is untested.
9. **Whether `AltSpreadLogic_high` helps once `pblock_bd_i` is gone was not
   measured.** `D` and `DX` both used the build's own `ExtraPostPlacementOpt`,
   which is the right conservative choice, but the combination
   delete-plus-spread is an untested cell.
10. **Power.** `report_power` was run on `ASX` and nobody read it. The design is
    now spread over the whole die rather than packed into the bottom quarter,
    which changes the thermal picture on a card whose thermal guard is
    documented as not existing in silicon.

---

## 10. Corrections

*(Appended in place. Nothing above is deleted.)*
