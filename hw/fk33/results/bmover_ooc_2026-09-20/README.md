# bmover_ooc_2026-09-20: gdn_state_store at 9B, OOC, four configurations

TRACK BMOVERSYN, 2026-09-20. Four out-of-context synthesis draws of
`rtl/gdn_state_store.vhd` on the BC-250 (`cachyos-bc250`, Vivado 2023.2,
`xcvu33p-fsvh2104-2L-e`), one Vivado at a time under
`systemd-run --user --scope -p MemoryHigh=8G`, by `sim/ooc_bmover_run.sh`
driving `sim/ooc_bmover.tcl`. No hardware was touched.

## The question

TRACK BMOVER (0fb7d40, ba81e58; `docs/debugging/2026-09-20_b-job-660k-cycles.md`)
put `PIPE` and `WIDE` behind generics on the store, its movers and the
mantissa memory and cut a 9B B job from 644k to 308k cycles in GHDL, with no
Vivado. Open: does Vivado still infer 32 URAM288 for the BANKED
`gdn_state_mem` (four banks of 32,768 x 64), what do WIDE and PIPE cost, and
does the unit meet 13.333 ns (the 75 MHz card) and 5.0 ns (200 MHz)?

## The answer

**Yes to all three.** The banked memory is 32 URAM288 (4 banks x 8, named
per bank in `report_ram_utilization`), WIDE+PIPE costs +1,004 LUT and
+1,040 FF (0.23 and 0.12 points of the device) with BRAM/URAM/DSP unchanged,
and the synthesis-stage timing estimate is 0.36 ns BETTER than the shipping
control at both periods. `MAXOUT 8` costs one flip-flop over `MAXOUT 4`.

## The table (MEASURED, post-`opt_design`, `report_utilization`; WNS is a synthesis ESTIMATE, unplaced, unrouted)

| config | PIPE | WIDE | MAXOUT | LUT | LUT logic | LUTRAM | FF | BRAM | URAM | DSP | WNS @13.333 | WNS @5.0 | levels | cgroup peak MB | at cap | wall s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| ctrl (shipping) | false | false | 4 | 4,530 | 2,610 | 1,920 | 5,468 | 28 | 32 | 4 | +9.733 | +1.400 | 9 | 4,390 | no | 121 |
| w4 | false | true | 4 | 4,715 | 2,647 | 2,068 | 5,160 | 28 | 32 | 4 | +10.096 | +1.763 | 7 | 3,458 | no | 121 |
| wp4 | true | true | 4 | 5,534 | 3,466 | 2,068 | 6,508 | 28 | 32 | 4 | +10.096 | +1.763 | 7 | 3,689 | no | 127 |
| wp8 | true | true | 8 | 5,425 | 3,357 | 2,068 | 6,509 | 28 | 32 | 4 | +10.096 | +1.763 | 7 | 3,355 | no | 127 |

Deltas against ctrl (DERIVED): w4 +185 LUT / -308 FF; wp4 +1,004 / +1,040;
wp8 +895 / +1,041. wp8 against wp4: -109 LUT / +1 FF. The LUT difference
between wp4 and wp8 is in `u_cdma` (555 -> 452) whose behaviour `MAXOUT`
does not change, so it is draw-to-draw scatter, not a saving; the +1 FF is
the outstanding-burst counter's extra bit.

Peak memory: cgroup `memory.peak` of each draw's own scope, cap 8 GiB, none
within 1% of the cap so each figure is the job's, not the throttle's. The
/proc RSS sampler (5 s cadence) read 3.59 GB for all four. Wall is the
whole `vivado -mode batch` process.

The other generics, on every draw, are `llama_top`'s `u_state` map at 9B
(`rtl/llama_top.vhd:4951`, `BST_*` from `SHAPE`; `hw/fk33/rtl/fk33_card.vhd`
sets `B_CONST_HBM => true`): `VAL_HEADS=32 DIM=128 RECUR_LANES=4 LAYERS=24
KEY_HEADS=16 KCONV=4 CONV_LANES=4 MANT_BYTES=1048576 EXP_BYTES=4096
CONV_BYTES=49152 LAYER_STRIDE=1101824 MAXB=16 CONST_EN=true
CONST_STRIDE=66048 CONST_BYTES=66048`. `-flatten_hierarchy none` on all four.

## Where the delta is (MEASURED, `util_hier_*.rpt`, Total LUTs / FFs)

| instance | ctrl | w4 | wp4 | wp8 |
|---|---|---|---|---|
| u_mem (gdn_state_mem) | 130 / 3 | 210 / 2 | 210 / 2 | 210 / 2 |
| u_dma (mantissa mover) | 267 / 703 | 372 / 396 | 372 / 396 | 373 / 397 |
| u_edma (exp mover) | 229 / 605 | 229 / 605 | 509 / 1,137 | 508 / 1,139 |
| u_cdma (conv-tap mover) | 310 / 632 | 310 / 632 | 555 / 1,167 | 452 / 1,165 |
| gconst.u_kdma (const mover) | 228 / 366 | 228 / 366 | 522 / 647 | 516 / 647 |
| u_exp | 2,466 / 8 | same | same | same |
| u_conv | 253 / 8 | same | same | same |
| gconst.u_cw | 25 / 0 | same | same | same |

- WIDE: `u_mem` +80 LUT (bank decode and the 4:1 post-register mux);
  `u_dma` +105 LUT / -307 FF, because the 256-bit `wbuf` register is
  replaced by the `wfifo`, which is 19 `RAM32M16` (258 `RAMD32` + 38
  `RAMS32` leaves = the +148 in the LUT-as-memory row).
- PIPE: nothing in `u_dma` (its wide path is already one beat per cycle,
  372/396 with or without PIPE), and about +250 to +295 LUT and +280 to
  +535 FF in each of the three narrow movers. That is where PIPE's 8,711
  cycles on top of WIDE come from, and where its area goes.

## URAM: the log, the census and the RAM report all agree

- `[Synth 8-10226]` (URAM request refused): **0** occurrences in all four
  `vivado_*.log`. `[Synth 8-7186]` (ram_style ignored): **0** in all four.
- `[Synth 8-5780]` names each bank: `Default cascade height of 8 will be
  used for URAM '"u_mem/gwide.gb[k].bank_reg"'` for k = 0..3 (wp4/wp8/w4)
  and `'"u_mem/gflat.mem_reg"'` (ctrl).
- Census (`get_cells -hier -filter {REF_NAME =~ URAM*}`, `census_opt_*.txt`):
  32 cells in every draw, all under `u_mem`, named
  `u_mem/gwide.gb[k].bank_reg_uram_0..7` (banked) or
  `u_mem/gflat.mem_reg_uram_0..31` (flat).
- `ram_*.rpt`: each `u_mem/gwide.gb[k].bank` is `RAM_SDP 32768x64` in 8
  URAM288 of `4096x64`.
- The 28 RAMB36E2 are `gconst.u_cw` 16 and `u_conv` 12 in every draw; the
  1,920 `RAMD64E` are `u_exp` (distributed, as its `EXP_STYLE` asks).

## Timing (ESTIMATE: post-opt, no placement, no routing; orders the four against each other and says nothing about a routed card)

The same netlist is timed at both periods (`create_clock` replaces the
clock), so the datapath delay is identical at 13.333 and 5.0 ns and only the
slack moves.

- ctrl: worst path `u_mem/gflat.mem_reg_uram_8/CLK` -> `u_dma/wbuf_reg[130]/D`,
  datapath 3.527 ns (logic 2.995, route 0.532), 9 levels = 7 URAM288 cascade
  hops + 2 LUT5 (the narrow-word select into `wbuf`).
- w4 / wp4 / wp8: worst path `u_mem/gwide.gb[3].bank_reg_uram_0/CLK` ->
  `u_dma/wfifo_reg_0_3_196_209/RAMF/I`, datapath 3.062 ns (logic 2.789,
  route 0.273), 7 levels, all URAM288 cascade hops; the URAM output lands
  directly on the FIFO's LUTRAM write data.

So in every configuration the path is the URAM's own read cascade
(`cascade_height` 8 = 7 `CAS_IN -> CAS_OUT` hops, ~2.8 ns), which the RTL
does not control; WIDE removes the two LUT levels after it. CLAUDE.md
records phys_opt over-promising by 0.4 to 0.6 ns on this part and synthesis
estimates being worse; the 1.4 ns margin at 5.0 ns is therefore not a
200 MHz result, but the ORDER (WIDE variants ahead of the control) is the
claim, and nothing here says the levers make the unit slower.

## Against the 75 MHz card (`hw/fk33/results/card_swg_2026-09-20/bd_wrapper_utilization_placed.rpt`, MEASURED, placed)

Card: 363,095 LUT of 439,680 (82.58%), 308,981 FF (35.14%), 567 BRAM of
672 (84.38%), 32 URAM of 320 (10.00%), 2,087 DSP of 2,880. wp8 adds
+895 LUT (DERIVED: 82.58% -> 82.78%), +1,041 FF (35.14% -> 35.26%) and
nothing in BRAM, URAM or DSP. The parts do not sum across synthesis
contexts (CLAUDE.md), so the card-level delta is not this number exactly;
it is the right order of magnitude and there is no resource it could
exhaust.

## Verdict

**WIDE+PIPE is safe to enable in the next card build**: URAM inferred (32,
named), area delta about a thousand LUT and a thousand FF against 76,585
free LUT on the placed card, BRAM/URAM/DSP unchanged, timing estimate not
worse than the control (better, by 0.36 ns, same path family). `MAXOUT 8`
is free (one FF) and is what BMOVER's doc asks for, so the recommended
change is `PIPE => true, WIDE => true, MAXOUT => 8` in `rtl/llama_top.vhd`'s
`u_state` generic map (not this track's file).

What this does NOT establish: routed timing on the card, and the B-job
cycle count on silicon (GHDL says 307,784 per job; the card is the
measurement).

## Measurement traps hit

- `get_cells -hier -filter {REF_NAME =~ DSP*}` returns **36** on a netlist
  with **4** DSP48E2: the hierarchical walk sees the macro AND its eight
  `DSP_*` leaf cells (`DSP_ALU`, `DSP_A_B_DATA`, ...). The census file lists
  them by name so this is visible; `REF_NAME == DSP48E2` is the count.
  Likewise `REF_NAME =~ RAM32*|RAM64*` counts `RAM32M16`/`RAM64M8` macros,
  not LUTs, and the LUT-as-memory row differs from it by the packing (two
  `RAMD32` per LUT).
- `REF_NAME =~ LUT*` gives 3,058 for ctrl against `LUT as Logic` 2,610:
  the report counts physical LUT sites after packing, the census counts
  primitives. Both are in the files; the table quotes the report.
- The BC-250 tree has no `.git` (the sync copies tracked files only), so
  `BMOVER_ENV sha=unknown`. Tree identity was established instead by
  md5 of the nine files the draw reads (`sim/ooc_bmover.tcl`,
  `sim/ooc_bmover_run.sh`, `rtl/{util_pkg,gdn_state_mem,gdn_exp_mem,
  gdn_conv_tap_mem,gdn_conv_w_mem,gdn_state_axi,gdn_state_store}.vhd`),
  identical on both boxes at workstation HEAD 99e5d99 before launch.

## Files

`result_<tag>.csv` (one row each), `util_<tag>.rpt`, `util_hier_<tag>.rpt`,
`synthutil_*` (pre-opt), `ram_<tag>.rpt`, `census_{synth,opt}_<tag>.txt`,
`timing_{13p333,5p0}_<tag>.rpt`, `worst_{13p333,5p0}_<tag>.rpt`,
`mem_<tag>.txt`, `cgroup_<tag>.txt`, `run_<tag>.log` (stdout),
`vivado_<tag>.log`, `runner.log`.
