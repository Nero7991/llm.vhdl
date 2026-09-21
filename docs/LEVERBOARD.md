# LEVERBOARD -- the seven levers on the table for build 12, in one place

TRACK LEVERBOARD, 2026-09-20. Reading and arithmetic only: **no hardware, no
Vivado, no GHDL was run by this track.** Every number below was read back from
its source file, its commit, or its results directory, and every one is
labelled MEASURED (with the tool named), DERIVED (with the arithmetic shown) or
ESTIMATE (with the assumption stated). Where a document and the RTL disagreed,
the RTL won and the disagreement is recorded.

Card: FK33 `xcvu33p-fsvh2104-2L-e`, Qwen3.5-9B, 75 MHz core clock, lane-striped
image. Baseline is build 9, `hw/fk33/results/card_kvreg_2026-09-20`, routed
**WNS +0.061 ns**, 2.46 tok/s on silicon.

---

## 0. What is already committed, and what build 11b is actually building

This matters first, because three of the seven levers are already in the tree
at HEAD and it is easy to double-count them.

**MEASURED, from the build's own source worktree.** Build 11b reads its RTL
from `/mnt/storage/fk33_builds/wt11` (`build.stdout:162`, `add_files -norecurse
/mnt/storage/fk33_builds/wt11/rtl/...`). That worktree is at commit **`5dc3ee5`**,
clean on `rtl/`, and in it:

| probe | result |
|---|---|
| `grep -n FAST_POP_DEFAULT hw/fk33/gen_fk33_engine.py` | `113:FAST_POP_DEFAULT = True` |
| `grep -c CB_RANKS rtl/matvec_core.vhd` | 17 |
| `grep -c SWEEP_PIPE rtl/llama_top.vhd rtl/fk33_llama_top.vhd` | **0 and 0** |
| `grep -n 'SWG_WIDE  : boolean' rtl/llama_top.vhd` | no match (the generic does not exist there yet) |

So **build 11b = FAST_POP + the per-row codebook, and nothing else.** It was
launched at 19:00:59; `9cdf13b` (SWG generics) landed at 19:01:30 and
`a95017c` (SWEEP_PIPE + SCORE_EARLY wired) at 19:49:14, both after the source
snapshot. It was in `Phase 2.1.1 Partition Driven Placement` at 19:50.

At HEAD (`38d2f79`) the tree additionally carries, all reachable by a card
build without further RTL work:

* `rtl/llama_top.vhd:6997` `SWEEP_PIPE => true, SCORE_EARLY => true` on
  `u_attn`, hardcoded in the architecture body, so it needs no `--generic`.
* `rtl/llama_top.vhd:507-508` `SWG_LANES : positive := 1; SWG_WIDE : boolean
  := false`, and the same pair on `rtl/fk33_llama_top.vhd:542-543`.
* `rtl/llama_top.vhd:849` / `rtl/fk33_llama_top.vhd:884` `B_RECUR_LANES :
  positive := 4`.
* `rtl/llama_top.vhd:840` / `rtl/fk33_llama_top.vhd:875` `A_DRAIN_WIDE :
  boolean := false`.

MEASURED: `hw/fk33/gen_fk33_card.py` passes `B_STATE_AXI=true`,
`B_CONST_HBM=true` and `SWG_REAL=true` and sets **none** of `SWG_WIDE`,
`SWG_LANES`, `B_RECUR_LANES` or `A_DRAIN_WIDE`, so all four take their
defaults today. Turning any of them on is one `--generic` line each.

---

## 1. The board

One row per lever. "Scope" is the entity the area was drawn in; **no figure in
this table is a card figure**, and section 2 says why none can be.

| # | lever | commit | in 11b? | cycles/token saved | slope or intercept | area (resource by resource) | routed timing evidence | harness and scope | confidence |
|---|---|---|---|---|---|---|---|---|---|
| L-A | **FAST_POP** (`gen_fk33_engine.py:113`) | `bf0ea15` | **YES** | **2,593,664** (8.61% of the token) DERIVED | intercept, in `A_JOB` | **+1 CLB LUT** (136,919 -> 136,920), 0 FF, 0 DSP, 0 BRAM. Census: LUT4 -27, LUT5 +29, one per read port. MEASURED | none on the card. OOC: intra-clock WNS 9.088 / 1.103 unchanged, **top 200 intra-domain paths md5-IDENTICAL on both clocks**, 92 of them in the lever's own cone. MEASURED, `synth_design`+`opt_design`, no route | `sim/ooc_levercost_run.sh` on `matvec_int4_desc_axi` at the card's 27-lane geometry (the smallest entity that closes the cone). BC-250, Vivado 2023.2 | **HIGH** on area, MEDIUM on cycles (a fitted slope, see 3.2), open on routed timing. **But see 4.5: no `.vhd` bench in the tree sets `FAST_POP=true`, so the card ships an arm nothing exercises** |
| L-CB | **per-row codebook** (`CB_RANKS = 48`) | `0b34200`, `5dc3ee5`, `9435942` | **YES** | **0** (provably value- and cycle-neutral, `CB_WR_LAT` stays 1) | neither | **-19,344 FF** DERIVED, cross-checked: it is the only decomposition reproducing `a4828ab`'s MEASURED lever-C `CLB FF +13,195` as `+19,344 - 6,144` (residual -5 in 13,195). LUT delta **UNKNOWN, not drawn** | **none.** CBFANOUT declines to quote a WNS and says so. What is DERIVED is the input: max fanout per command bit **1,536 -> 48** on the net carrying all ten of build 10's worst paths | no synthesis at all. Value oracle `tb_matvec_core` vs `ref/matvec_int4.c`, 464+343 values, 0 mismatches in all four of {OLD,NEW} x {regs,distributed}; card geometry elaborated in both directions; 7 gate rows PASS | **HIGH** that it is safe, **UNMEASURED** that it helps |
| L-C1 | **SWEEP_PIPE** | `bc4156f` | no (HEAD yes) | slope 355.17 -> 275.11 per position per C job; **-641 cycles/position** DERIVED | **slope** | **+64 LUT, exactly +23 FF**, 0 DSP, 0 BRAM. MEASURED. CSWEEP pre-registered "~23 FF plus a 4-bit mux"; the FF count is 23 | OOC WNS unchanged, top-200 md5-identical, **but none of the top 200 is in the sweep FSM**, so it is a bound (>9.540 ns slack) and not a measurement | `ooc_levercost` on `attn_block` from HEAD's committed copy (`bc4156f`), md5 verified. Synthesis only, `route_design` count **zero** in that script | HIGH on cycles (bench reproduces silicon to 0.14%), MEDIUM on area, LOW on timing |
| L-C2 | **SCORE_EARLY** | `4e9915b` | no (HEAD yes) | with SWEEP_PIPE: 275.11 -> 231.17; **-992 cycles/position for the pair** DERIVED | **slope** | **+5 CLB LUT sites, +2 FF**, everything else bit-identical: CARRY8, F7, F8, BRAM, DSP all 0, and the whole `u_sq` cone census byte-identical by REF_NAME. MEASURED | **ROUTED.** base 3.101 ns vs early 2.735 ns on a 13.333 ns clock, 0 failing endpoints of 250,285, 0 routing errors. **But the harness noise floor is ~0.4 ns, MEASURED**, so -0.366 ns is not a result | `sim/ooc_scorehdr*.tcl` on `attn_block` at the card's 9B generics, BC-250, synth + opt + place + route | **HIGH.** The only C lever with a routed number and a measured noise floor |
| L-C3 | **SCORE_HDR_TREE=1** | `56d13e3` | no (HEAD: present, set to 0) | as committed: **none, it cannot be built.** Fixed: 231.17 -> 219.87 beside SP+SE; **-90 cycles/position more** DERIVED | **slope** | **AS COMMITTED: NO AREA EXISTS.** `ERROR: [Synth 8-11324] array index 8 out of range [rtl/attn_score_q12.vhd:488]`, `synth_design` dead in 49 s at `NBLK=8`. MEASURED. **With HDRCOST's one-line fix (`for i in 0 to TW-1`): +512 CLB LUT sites, +136 FF, +12 CARRY8, -32 F7, 0 DSP, 0 BRAM**, all of it inside `u_sq` (block +772 LUT cells = cone +772; block +136 FD* = cone +136). MEASURED | **HOLE. TRACK HDRCOST is routing the `treefix` arm now.** `arms/synth_treefix.csv` and `pnr_treefix.csv` do not exist yet; the README's routed row reads "(see arms/)" | same harness as L-C2. **The fix is NOT in the repo**: `rtl/attn_score_q12.vhd` still reads `for i in 0 to NBLK-1` at the fold | **cycles HIGH, area HIGH (for the fix), timing PENDING** |
| L-S1 | **SWG_WIDE=true, SWG_LANES=1** | `9cdf13b` | no | **393,280** DERIVED exactly (step 61,473 -> 49,183, x32) | intercept, in `VEC_SWG` | **ESTIMATE only, no synthesis of any kind has seen this RTL.** `wgmux` 2:1 -> 3:1 +0..20 LUT, `rgmux` +12 LUT, group-face flops "~160" in one place of the write-up and "+365 FF net" in another. 0 DSP (no lane replication) | **none** | `sim:tb_swiglu_mem_w8_9b` and `tb_llama_top_swgw` under GHDL mcode. Cycle model exact at three deltas in `llama_top` (82,329 / 79,653 / 76,173 / 75,405 over 3 tokens, all four landmarks including `EXP_STEPH` identical) | cycles **HIGH**, area **LOW** (undrawn, and the doc contradicts itself 160 vs 365 FF) |
| L-S8 | **SWG_WIDE=true, SWG_LANES=8** | `9cdf13b` + `7ed6535` | no | **1,769,504** (5.88% of the token). Unit MEASURED, adapter DERIVED from the FSM | intercept, in `VEC_SWG` | **UNKNOWN.** Two ESTIMATEs 2x apart: DSIDE **+112 DSP / +16k LUT**, GSRWIDE **+56 DSP**. Neither drawn. A second undrawn risk: if the `lane0` run-time slice does not constant-fold at `SWG_GRP = LANES = 8`, the lever builds two 8-way 128-bit barrel shifters | **none** | as L-S1. `swiglu_mem` at LANES 8 through the wide face is **3,085 cycles at N=12288**, MEASURED, which turns DSIDE's extrapolation into a measurement | cycles **HIGH**, area **UNKNOWN and it is the whole cost** |
| L-B | **B_RECUR_LANES = 16** | generic pre-existing; value set in `gen_fk33_card.py` | no | **2,362,128** DERIVED = 24 x 98,422; `gdn_block` 149,579 -> 51,157 MEASURED | intercept, in `B_JOB` | **+7,688 LUT, +8,000 FF, +9 RAMB36, +48 DSP, +588 CARRY8, +238 F7, +15 F8, +0 URAM.** MEASURED **in the card's own configuration** (`B_STATE_AXI=true B_CONST_HBM=true`) | none. The harness's core WNS is **-4.008 in all four arms to three decimals**, across a 63,000-LUT difference, so it has **no demonstrated resolution**; and its `create_clock` runs after `synth_design`, so synthesis was never timing-driven | `sim/ooc_gdnadapt.tcl` tier arm, BC-250. Quote the tier row only: **the LUT delta inverts sign** between arms (flat **-7,545**, tier **+7,688**), same tree, one variable | cycles **HIGH**, area **HIGH for its scope**, timing **NONE** |
| L-AD | **A_DRAIN_WIDE** | `6f4458a` | no | **1,248,576** (4.15% of the token) DERIVED from the card's plan; 2,178 MEASURED in `llama_top` at the bench shape, model and integration agreeing **to the cycle** | intercept, in `A_JOB` | **ESTIMATE +250 to 400 LUT, +156 FF.** **UNBUILDABLE AS MEASURED**: its logic is in the architecture body of `rtl/fk33_llama_top.vhd` inside `ga_desc`, which is not an entity, so **no OOC draw that exists can close its cone** | **none, and none is reachable** | `sim/tb_llama_top_real`, GHDL. All four landmarks bit-identical across the two arms, `EXP_STEPH` included | cycles **HIGH**, area **NOT MEASURABLE by any existing harness** |

### Cone sharing, which is what decides whether two levers can be attributed apart

MEASURED by TRACK GDNSYNTH: the transitive RTL closure of B's mover is 18
entities (`gdn_block gdn_conv gdn_conv_tap_mem gdn_conv_w_mem gdn_emit_chain
gdn_exp_capture gdn_exp_mem gdn_head_emit gdn_job_seq gdn_recur_pipe
gdn_scalar gdn_silu gdn_state_axi gdn_state_mem gdn_state_store gdn_y_emit
l2norm_rs rmsnorm_bf`) and **none of them contains `FAST_POP`, `SWEEP_PIPE` or
`SCORE_EARLY`**.

| group | levers | shared files |
|---|---|---|
| A read path | L-A | `stream_fifo`, `async_fifo`, `axi_rd_port`, `matvec_int4_desc_axi` |
| A codebook | L-CB | `matvec_core` (architecture only; the entity is byte-identical, md5 `054989ed` both sides) |
| C sweep | L-C1, L-C2, L-C3 | `attn_block`, and L-C3 alone also `attn_score_q12` |
| D region file | L-S1, L-S8, L-AD | **`llama_top` / `fk33_llama_top`, and all three drive the same group WRITE port.** GSRWIDE: "`A_DRAIN_WIDE` and `SWG_WIDE` both drive the group write port ... every row here has `A_DRAIN_WIDE` false" |
| B recurrence | L-B | the 18 entities above |

**The one real collision is L-AD against L-S1/L-S8.** They share `wgmux` and
have never been elaborated together. That is a synthesis-reachable question
nobody has asked, and it is cheap to answer (one `ghdl -e` of `llama_top` with
both true).

---

## 2. Scope, stated honestly: no lever has a card figure, and none can get one cheaply

**MEASURED by TRACK LEVERCOST: a card-top OOC has never once cleared RTL
elaboration.** `hw/fk33/ooc_c_in_card.tcl` records `grep -c 'Finished RTL
Elaboration'` = **zero across twelve attempts on two machines**, and
`hw/fk33/ooc_card_dcp.tcl` records the best of them at **47 hours under
`MemoryHigh=24G` wanting at least 39.1 GiB** and still not finishing.

Two consequences that must be carried into every decision below:

1. **Every area figure in section 1 is from a smaller entity, and the parts do
   not sum across synthesis contexts.** This project has already measured that
   directly: `gdn_block` alone reports 22 BRAM tiles while the composed block
   attributes 5,472 to one other object, and LUT-as-memory goes 10,161 ->
   35,078 for the same RTL.
2. **GSRWIDE's own cheapest-settling plan is a job that cannot run.** Section
   4.5 of `docs/debugging/2026-09-20_the-swiglu-on-the-group-port.md` asks for
   "one OOC synthesis of `fk33_llama_top` at `A_DESC => true`, `SWG_REAL =>
   true`, with `(SWG_LANES, SWG_WIDE)` at four points". **That is the same
   entity LEVERCOST failed to elaborate twelve times.** The two write-ups
   landed the same day and neither knew about the other. The substitute is in
   section 6.

**What an OOC number IS good for** is a one-variable A/B inside one entity,
and both the L-C2 pair and the L-B pair are exactly that. What none of them
can answer is placement, which is the thing build 10 died of.

---

## 3. The cycle arithmetic, done once

### 3.1 The model

**MEASURED on silicon** (`docs/debugging/2026-09-20_token-cost-grows-2793-cycles-per-position.md`,
the seam's own cycle counter, four tokens, the line fitted from the two
endpoints and tested on the two interior points at +0.0054% and +0.0198%):

```
token_cycles(p) = 30,115,217 + 2,793.4 * p        core cycles at 75 MHz
```

and the opcode partition at p = 0, which **sums to the intercept exactly** and
is therefore a partition and not a sample:

```
B_JOB      15,854,364   52.6%      C_JOB         594,472    2.0%
A_JOB      10,890,053   36.2%      VEC_SWG     1,967,136    6.5%
VEC_NORM      736,840    2.4%      VEC_RES        67,712    0.2%
                                   TOTAL      30,115,217
```

**100% of the slope is subsystem C** (MEASURED by differencing two per-step
profiles with identical step counts: `C_JOB +664,852`, `A_JOB -104`, `B_JOB
+44`, every vector opcode +0).

### 3.2 Which levers cut which, and why mixing them is the trap

| lever | what it cuts | where it lands in the partition |
|---|---|---|
| L-A FAST_POP | intercept | inside `A_JOB` |
| L-AD A_DRAIN_WIDE | intercept | inside `A_JOB` |
| L-S1 / L-S8 SwiGLU | intercept | inside `VEC_SWG` |
| L-B B_RECUR_LANES | intercept | inside `B_JOB` |
| L-C1/C2/C3 | **slope** | inside `C_JOB` |
| L-CB codebook | neither | |

**Additivity: the honest split.** TRACK LEVERCOST's open list says "whether the
three constant levers' cycle savings are additive (assumed, not measured -- do
not quote the 1.26x)". That warning can be sharpened rather than repeated:

* **Across opcodes it is structural, not assumed.** The profiler's opcode
  table is a partition of the token into disjoint serial steps and it sums to
  the total exactly. A saving inside `A_JOB` and a saving inside `VEC_SWG`
  cannot overlap, because the two never run at the same time. So L-A, L-S*,
  L-B and L-C* add across groups. DERIVED.
* **Within `A_JOB` it is NOT measured.** L-A shortens the weight-streaming
  phase and L-AD shortens the drain phase. They are plausibly disjoint and
  nobody has run the pair. Their sum, 3,842,240, is 35.3% of `A_JOB`'s
  10,890,053. **Treat any composition containing both as carrying one
  unmeasured additivity assumption**, and read the per-opcode profile after
  the build rather than the token total.
* **Within C the sub-additivity is MEASURED and must not be summed.**
  SCORE_EARLY alone is 32.00 cycles, HDR_TREE alone 44.00, the pair 64.00 and
  not 76.00: they attack the same 14 cycles from opposite ends and 12.00 are
  claimed twice. SWEEP_PIPE and HDR_TREE, by contrast, are additive to the
  digit. **Never add two C numbers; read the combination out of SCOREHDR's
  grid.**

### 3.3 Converting a bench slope to a card slope, and the 1% I refuse to resolve

The C benches report cycles per position per C job at RD_LAT 100. The card
reports 2,793.4 cycles per position across 8 C jobs, i.e. 349.175 per job,
against the bench's 355.17 -- the bench over-reads by 1.7%.

Two ways to carry a bench saving across, and they disagree by under 1.1%:

| C combination | bench | ratio method (what the existing documents quote) | absolute-subtraction (the conservative form) | spread |
|---|---:|---:|---:|---:|
| none | 355.17 | 2,793.4 | 2,793.4 | -- |
| SWEEP_PIPE | 275.11 | 2,163.7 | 2,152.9 | +0.50% |
| SCORE_EARLY | 323.17 | 2,541.7 | 2,537.4 | +0.17% |
| **SWEEP_PIPE + SCORE_EARLY** | **231.17** | **1,818.1** | **1,801.4** | +0.93% |
| SWEEP_PIPE + HDR_TREE=1 | 231.11 | 1,817.7 | 1,800.9 | +0.93% |
| **all three** | **219.87** | **1,729.3** | **1,711.0** | +1.07% |

**I do not know which is right and I am not going to pick by argument.** The
ratio method assumes the bench/card discrepancy is proportional; the absolute
method assumes it is a fixed offset (a plausible mechanism exists -- MIDGAP
measured 7.17 cycles per position per job of modelled cache latency that the
card may not pay). **Only a card build with the levers on settles it, and the
difference is smaller than the thing being measured.** Every table below uses
the **absolute-subtraction** number because it is the smaller claim; the
documents' ratio figures are 0.9-1.1% more optimistic.

### 3.4 The compositions, tok/s at five positions

DERIVED throughout, from 3.1 and the per-lever savings in section 1.

| composition | intercept | slope | p=0 | p=512 | p=2,048 | p=8,192 | p=32,768 |
|---|---:|---:|---:|---:|---:|---:|---:|
| **B0** build 9, shipping (MEASURED 2.46 on silicon) | 30,115,217 | 2,793.4 | **2.490** | 2.378 | 2.093 | 1.415 | 0.617 |
| **B11b** FAST_POP + codebook (in flight) | 27,521,553 | 2,793.4 | 2.725 | 2.591 | 2.256 | 1.488 | 0.630 |
| | | | +9.4% | +9.0% | +7.8% | +5.1% | +2.2% |
| **K1** B11b + SWEEP_PIPE + SCORE_EARLY | 27,521,553 | 1,801.4 | 2.725 | 2.637 | 2.403 | 1.774 | 0.867 |
| | | | +9.4% | +10.9% | +14.8% | +25.4% | +40.6% |
| **K2** K1 + SWG_WIDE / SWG_LANES=1 | 27,128,273 | 1,801.4 | 2.765 | 2.674 | 2.434 | 1.791 | 0.871 |
| | | | +11.0% | +12.5% | +16.3% | +26.5% | +41.2% |
| **K3** K2 + B_RECUR_LANES=16 | 24,766,145 | 1,801.4 | 3.028 | 2.920 | 2.636 | 1.898 | 0.895 |
| | | | +21.6% | +22.8% | +25.9% | +34.1% | +45.2% |
| **K4** K3 + A_DRAIN_WIDE | 23,517,569 | 1,801.4 | 3.189 | 3.069 | 2.757 | 1.960 | 0.909 |
| | | | +28.1% | +29.1% | +31.7% | +38.5% | +47.4% |
| **K5** everything, SWG_LANES=8, HDR_TREE fixed | 22,141,345 | 1,711.0 | 3.387 | 3.258 | 2.924 | 2.074 | 0.959 |
| | | | +36.0% | +37.1% | +39.7% | +46.6% | +55.5% |

**Read the shape, not the headline.** The intercept levers are worth 9-28% and
that number SHRINKS with context; the slope levers are worth 0% at p=0 and
**+40% at p=32,768** and that number GROWS. A single "tok/s" figure for this
card is meaningless without a position, and a composition chosen on the p=0
column is chosen on the wrong column for any real chat.

---

## 4. The binding constraint, and the codebook does not relieve it

### 4.1 It is CLB occupancy

MEASURED, `hw/fk33/results/card_swg_2026-09-20/bd_wrapper_utilization_placed.rpt`
(Vivado's own header: `Sun Sep 20 01:14:38 2026`, `Design State: Fully
Placed`, `Design: bd_wrapper`):

| resource | used | available | % | free |
|---|---:|---:|---:|---:|
| **CLB** | **54,854** | **54,960** | **99.81** | **106** |
| CLB LUTs | 363,095 | 439,680 | 82.58 | 76,585 |
| CLB Registers | 308,981 | 879,360 | 35.14 | 570,379 |
| DSP48E2 | 2,087 | 2,880 | 72.47 | 793 |
| Block RAM Tile | 567 | 672 | 84.38 | 105 |
| URAM288 | 32 | 320 | 10.00 | 288 |
| CARRY8 | 12,592 | 54,960 | 22.91 | 42,368 |

DERIVED from those two rows, and it reproduces LEVERCOST's split exactly:

```
LUT per occupied CLB      363,095 / 54,854      =   6.6193  of 8
free LUT sites in occupied CLBs  54,854*8 - 363,095 =  75,737
free LUT sites in the 106 free CLBs   106*8         =     848
                                          total     =  76,585   (matches)
FF per occupied CLB       308,981 / 54,854      =   5.6328  of 16
```

**At today's packing density the 106 free CLBs absorb 702 LUTs.** Everything
beyond that has to pack denser into CLBs that are already occupied, against a
placer running `Congestion_SpreadLogic_high`, whose entire purpose is to
spread logic out.

| lever | +LUT | % of the 76,585 free LUT sites | CLBs at today's 6.62/CLB |
|---|---:|---:|---:|
| L-A FAST_POP | 1 | 0.00% | 0.2 |
| L-C2 SCORE_EARLY | 5 | 0.01% | 0.8 |
| L-C1 SWEEP_PIPE | 64 | 0.08% | 9.7 |
| L-C1+L-C2 | 69 | 0.09% | 10.4 |
| L-C3 HDR_TREE (fixed) | 512 | 0.67% | 77.3 |
| **L-B B_RECUR_LANES=16** | **7,688** | **10.04%** | **1,161.5** |
| **L-S8 SWG_LANES=8** (DSIDE ESTIMATE) | ~16,000 | ~20.9% | ~2,417 |

**The cliff is between 512 and 7,688.** The first five rows fit in the free
CLBs at today's density and are placement noise. L-B needs 1,161 CLBs' worth of
space and there are 106, so it can only land by raising the average density
from 6.6193 to 6.7593 LUT per CLB. That is arithmetically possible and is
exactly the question no OOC answers.

### 4.2 The codebook fix removes 19,344 flip-flops and that does NOT create CLB headroom

The brief asks how `-19,344 FF` changes this arithmetic. **DERIVED: on the
capacity axis, it does not.**

* 19,344 is **2.20%** of the 879,360 FF sites, in a design using **35.14%** of
  them. FF was never the binding row, so freeing more of it frees nothing.
* FF occupancy per occupied CLB is **5.63 of 16**. A CLB filled by those flops
  alone would have to be an FF-only CLB.
* **Upper bound on CLBs freed: 1,209** (19,344 / 16, if every one of those
  flops sat in a CLB containing nothing else). **Lower bound: 0** (if each sat
  beside the LUTs of the codebook copy it serves, which is what a `dont_touch`
  replica placed near its consumer looks like). **The actual value is UNKNOWN
  and only a placed report answers it.**

**What the fix does relieve is routing, not capacity**, and CBFANOUT is right
to refuse a number: max fanout per command bit **1,536 -> 48** on the net that
carried all ten of build 10's worst paths, with `CB_WR_LAT` unchanged at 1.
That is a factor of 32 on the input to the problem and zero measurements of the
output.

### 4.3 A caution the tree does not support, and it should be checked before it is repeated

Build 10's postmortem says the failure came from "the levers grew the `card`
block", and build 12 planning has inherited that. **The two placed reports in
the tree do not support it**, MEASURED:

| | card_swg (01:14) | build 10 (14:39) | delta |
|---|---:|---:|---:|
| CLB | 54,854 | **54,751** | **-103** |
| CLB LUTs | 363,095 | **361,361** | **-1,734** |
| LUT as Logic | 297,323 | 295,786 | -1,537 |
| LUT as Memory | 65,772 | 65,575 | -197 |
| CLB Registers | 308,981 | **308,213** | **-768** |
| CARRY8 | 12,592 | 12,597 | +5 |
| Block RAM Tile | 567 | **595** | **+28** |
| DSPs | 2,087 | 2,087 | 0 |
| URAM | 32 | 32 | 0 |

Build 10 placed **smaller** than the card_swg build on CLB, LUT and FF, and
larger only in BRAM.

**This is not proof that the postmortem is wrong, and I am not claiming it
is.** It is a same-tree failure of exactly the kind CLAUDE.md records: the
right baseline for build 10 is **build 9**, and **build 9 has no utilization
report in the tree at all** (`hw/fk33/results/card_kvreg_2026-09-20/` holds
`build.stdout`, `timing.txt` and profiles, and `grep -c 'CLB LUTs'
build.stdout` = 0). The pair that would settle it is missing, and the pair that
exists points the other way. **Do not quote "build 10 failed by adding area"
again without the build-9 report**, and note that if it is wrong the fix in
build 11b may be addressing a real net with a wrong story attached to it -- the
fanout of 1,536 is measured either way, so the change stands regardless.

### 4.4 A risk that is not area at all: build 11b's one lever is unbenched

**MEASURED by TRACK SHAPEAUDIT (`92ba3ec`), landed while this board was being
written:** `grep -rn FAST_POP sim/` hits five Vivado area and timing scripts
and **no `.vhd` at all**. The card is `FAST_POP => true`
(`hw/fk33/rtl/fk33_engine.vhd:139`); every RTL default is false. Its 2x2 with
both attribution controls: a planted `after_e < 2` -> `< 4` in the `FAST_POP`
arm only of `rtl/async_fifo.vhd:382` gives `PASS` at `FAST_POP=false` on four
benches including `tb_async_fifo`, the dedicated bench for the file carrying
the defect, and `FAIL` at `FAST_POP=true` on `tb_matvec_fk33_desc_dual`.

**This does not change L-A's area or cycle numbers.** It changes what a green
gate means for build 11b: the gate is silent on the arm the card builds. It is
the cheapest open item on this board to close, because the bench that
discriminates already exists and merely needs the generic set.

### 4.5 The cheapest permanent repair for all of this

LEVERCOST found that `bd_wrapper_utilization_placed.rpt` is written without
`-hierarchical` (`grep -c Instance` = 0), so **no current per-subsystem area
figure for the card exists anywhere in the tree.** Adding that one flag to the
card build makes every future comparison same-tree and costs nothing. It is the
single highest-leverage line of build 12's setup and it is not a lever.

---

## 5. Three candidate compositions for build 12

Build 10 failed at **-5.819 ns** by changing several things at once, so risk is
a column and not a formality. Each candidate names what it would prove, and
what it costs if it fails.

### Candidate 1 -- C ONLY. "The slope, for 69 LUTs."

**Contents:** build 11b's tree plus `SWEEP_PIPE` and `SCORE_EARLY`, which are
**already at HEAD** (`a95017c`, `rtl/llama_top.vhd:6997`). Nothing else
changes. `SCORE_HDR_TREE` stays 0.

* **Cost:** +69 LUT, +25 FF, 0 DSP, 0 BRAM (MEASURED, two OOC one-variable
  A/Bs). 0.09% of the free LUT sites, 10.4 CLBs at today's density, against
  106 free.
* **Gain (DERIVED):** slope 2,793.4 -> 1,801.4. **+14.8% at p=2,048, +25.4% at
  p=8,192, +40.6% at p=32,768**, and **zero at p=0**.
* **Argument:** it is the only composition whose entire area cost has been
  measured, one variable at a time, and one of its two levers has a routed
  number with a published noise floor. It changes the axis the shipping card is
  worst on and that no previous build has touched.
* **Risk: LOW, and quantified.** 69 LUTs cannot move a placer that has 106 free
  CLBs and 75,737 free in-CLB LUT sites. The residual risk is that
  `SWEEP_PIPE`'s cone was never timed (0 of 200 top paths are in it, so its OOC
  WNS is a bound, not a measurement).
* **What it does not do:** nothing for the intercept, so the p=0 column is
  identical to build 11b's. If the card is mostly used at short contexts this
  candidate is invisible.

### Candidate 2 -- C + the cheap D lever. "Candidate 1, plus 393k cycles for two muxes."

**Contents:** Candidate 1 plus one `--generic SWG_WIDE=true` in
`hw/fk33/gen_fk33_card.py`. `SWG_LANES` stays **1**.

* **Cost:** ESTIMATE +12 to +32 LUT and 160 to 365 FF. **Undrawn.** 0 DSP,
  because there is no lane replication.
* **Gain (DERIVED, exact FSM arithmetic):** intercept -393,280.
  **+16.3% at p=2,048** against build 9, +11.0% at p=0.
* **Argument:** GSRWIDE's own recommendation, in its own words: "if the next
  build needs cycles and cannot afford area, that is the point to take". The
  saving comes from the group READ port already carrying two operand regions at
  one address, which is a property of the port and not of the unit's width.
* **Risk: LOW-MEDIUM.** Two things are unmeasured and both are named by
  GSRWIDE: (a) no synthesis of any kind has seen this RTL, and the same
  document gives two different FF figures for it; (b) if the `lane0` run-time
  slice does not constant-fold, the lever builds two 8-way 128-bit barrel
  shifters instead of two wires. At `SWG_GRP = LANES = 8` it should fold; that
  is an ESTIMATE with no evidence, and the one-line insurance
  (`if SWG_GRP = LANES then lane0 := 0;`) was deliberately not applied.
* **Prerequisite that costs 20 minutes:** `SWG_WIDE` and `A_DRAIN_WIDE` both
  drive the same group write port and have never been elaborated together. If
  build 12 takes both, elaborate the pair first.

### Candidate 3 -- B ALONE. "The biggest single win, and the one that can fail."

**Contents:** build 11b's tree plus one `--generic B_RECUR_LANES=16`.
**Nothing else. Not Candidate 1, not Candidate 2.**

* **Cost:** +7,688 LUT, +8,000 FF, +48 DSP, +9 RAMB36, +588 CARRY8 (MEASURED,
  and in the card's own `B_STATE_AXI`/`B_CONST_HBM` configuration). DSP and
  BRAM fit comfortably (6.1% of 793 free DSP, 8.6% of 105 free tiles). **The
  LUT is 10.04% of the free in-CLB LUT sites and needs the packer to raise
  average density from 6.6193 to 6.7593 per CLB.**
* **Gain (DERIVED):** intercept -2,362,128, the largest single intercept lever
  on the board. **+21.6% at p=0** when composed with build 11b's FAST_POP.
* **Argument:** B is 52.6% of the token and this removes 14.9% of it for one
  line in a generator, with the HBM arena, the manifest and the host image
  **byte-identical** because the state word count and the lane width cancel.
* **Risk: HIGH, and it is the only candidate whose failure mode is a build that
  does not close.** GDNSYNTH says outright that its OOC pair "does not license
  `B_RECUR_LANES=16` into build 12 ... the composition risk really is PLACEMENT
  and congestion, not synthesis, and an OOC pair cannot answer a placement
  question". Its harness's WNS is -4.008 in all four arms to three decimals,
  so it has no resolution on this lever at all.
* **Why alone:** if it is composed with Candidates 1 and 2 and the build fails,
  the 7,688 LUTs and the 69 LUTs are indistinguishable in the postmortem, and
  that is precisely how build 10 spent a place-and-route. LEVERCOST reached the
  same conclusion independently: "`B_RECUR_LANES=16` LAST and ALONE".

### What none of the three contains, and why

| excluded | why |
|---|---|
| `SCORE_HDR_TREE=1` | **It does not synthesise as committed** (MEASURED, 49 s). The one-line fix is not in the repo and its routed arm is still running. And beside `SCORE_EARLY` it buys **231.11 vs 231.17** cycles per position, i.e. nothing. Take it only if `SCORE_EARLY` is dropped, and only after HDRCOST's `treefix` route lands. |
| `SWG_LANES=8` | +1,376,224 cycles more than `SWG_LANES=1`, for an area cost that is **unknown to a factor of 2** by its own authors, at 99.81% CLB. GSRWIDE: "asking for `SWG_LANES = 8` on the next card build without an OOC draw first would be exactly the uncontrolled change that failure argues against." |
| `A_DRAIN_WIDE` | 1,248,576 cycles is the second-largest intercept lever, and **no harness that exists can price it** (its logic is in an architecture body, not an entity). Taking it means taking an ESTIMATE of +250-400 LUT on faith into a 99.81%-CLB build. It also collides with `SWG_WIDE` on `wgmux`. **Hold until either an entity exists or a build has spare CLBs.** |

**Do not run all three candidates as one build.** Candidates 1 and 2 can
compose (their cones are disjoint, +69 LUT and ~+32 LUT), and that is a
reasonable single build. Candidate 3 is a separate build.

### If exactly one build fits before the next decision point

**Candidate 1, composed with Candidate 2.** It is the most measured area on
the board, it is 0.1% of the free LUT sites, and it moves the axis that grows
with use. Then Candidate 3 alone, reading the **CORE-clock** row of the timing
summary and never the global WNS, which lives in the AXI domain and will not
move.

---

## 6. Where I refused to project, and what I refused to do instead

1. **I did not scale `SWG_LANES=8`'s area from `SWG_LANES=1`'s.** The two
   published estimates differ by 2x (+112 vs +56 DSP) and neither is drawn. The
   cell says UNKNOWN. This is the recorded "an exact relationship for one
   resource is not a licence to scale a different resource" failure, which cost
   3.4x on `u_arr`'s LUT.
2. **I did not fit a curve to the `SWG_LANES` area series.** There is no area
   series; there are four CYCLE points and zero area points.
3. **I did not resolve the ratio-vs-absolute slope conversion by argument.**
   Both are shown, the conservative one is used, and the 0.9-1.1% spread is
   labelled unresolved. A one-parameter choice between two models with one
   calibration point is exactly the shape that has been wrong here twice.
4. **I did not convert `-19,344 FF` into freed CLBs.** Bounds are given (0 to
   1,209) and the value is called UNKNOWN, because the answer depends on
   placement, which no report in the tree contains.
5. **I did not add the C levers' individual savings.** SCORE_EARLY + HDR_TREE
   is 64.00 measured against 76.00 summed; the grid is read, not the addends.
6. **I did not treat FAST_POP and A_DRAIN_WIDE as additive without saying so.**
   Both live inside `A_JOB`. The composition table's K4 row carries that one
   assumption and it is flagged at the row and in 3.2.
7. **I did not quote a WNS for the codebook fix.** CBFANOUT deliberately did
   not, and no ratio may be taken from build 9's +0.061 against build 10's
   -5.819 because those builds differ in the levers as well as the area.
8. **I did not repair the build-10 area story, only flagged it.** The correct
   control (build 9's placed report) does not exist and I did not run Vivado to
   make one.

---

## 7. Open, not determined

1. **HDRCOST's `treefix` routed timing.** Its area is MEASURED (+512 LUT sites,
   +136 FF, all inside `u_sq`); its routed WNS is the hole. `arms/synth_treefix.csv`
   and `arms/pnr_treefix.csv` do not exist yet and the README's routed row reads
   "(see arms/)". **TRACK HDRCOST will fill this**, and the bar it must clear is
   its own measured ~0.4 ns noise floor.
2. **The one-line fix is not in the repository.** `rtl/attn_score_q12.vhd`
   still reads `for i in 0 to NBLK-1` at the fold loop. Until it lands,
   `SCORE_HDR_TREE=1` is an RTL setting that kills `synth_design` in 49 seconds
   and nothing in the gate can see it.
3. **Build 9's placed utilization report does not exist**, so the single most
   quoted area comparison in this project (build 9 vs build 10) has never been
   made. See 4.3.
4. **No per-subsystem card area figure exists at all** -- the card build writes
   `report_utilization` without `-hierarchical`.
5. **FAST_POP's and the codebook's routed cost on the card.** Build 11b answers
   both, and the specific rows to read when it lands are in section 8.
6. **Whether `SWG_WIDE` and `A_DRAIN_WIDE` elaborate together.** They share
   `wgmux` and the pair has never been run in any form.
7. **Whether the `lane0` slice constant-folds at `SWG_GRP = LANES`.** ESTIMATE
   that it does, no evidence either way, and the failure mode is two barrel
   shifters rather than two wires.
8. **Why `B_RECUR_LANES=16`'s LUT delta inverts sign between the flat and tier
   state arms.** Measured, not explained.
9. **Whether FAST_POP and A_DRAIN_WIDE are additive inside `A_JOB`.**
10. **Whether the bench-to-card slope conversion is proportional or offset.**
    Section 3.3.
11. **No `.vhd` bench sets `FAST_POP=true`**, the arm the card ships. SHAPEAUDIT
    demonstrated a planted defect that four benches pass and
    `tb_matvec_fk33_desc_dual` fails the instant the generic is flipped. The
    discriminating bench exists; nothing schedules it at the card's value.
12. **Whether fixing the codebook net lets build 10's B-mover levers (WIDE,
    PIPE, MAXOUT8, NWIDE) close**, or merely moves the failure to the next
    structure. Inherited unchanged from the build-10 postmortem, and it is a
    separate question from every lever on this board.

---

## 8. What to read when build 11b lands, in order

Three of this board's open items are answered by a report that is being written
right now, and they are easy to miss in a timing summary.

1. **`utilization_placed.rpt`, the CLB row.** Against 54,854 (card_swg) and
   54,751 (build 10). This is the first measurement of whether removing 19,344
   flip-flops frees CLBs, and section 4.2's bounds are 0 and 1,209.
2. **The CORE-clock row of the intra-clock table**, `clk_out3_bd_clk_wiz_0_0`,
   never the global WNS, which lives in the AXI domain and will not move.
   Against build 9's +0.061 and build 10's -5.819.
3. **The worst-path list.** If `cb_addr_reg -> cbw_a_reg` is gone, the codebook
   fix worked; if it is still there at rank 1, `CB_RANKS = 48` did not reach
   the build and that is a generator question, not a timing one.
4. **The engine's `CYCLES`/`BEATS` registers per job**, which nobody has ever
   read on the card. FAST_POP predicts a ratio of about **1.01** against
   today's **1.51**. That is the only direct confirmation the 2,593,664-cycle
   figure will ever get, and without it the number stays DERIVED forever.
5. **A per-opcode profile at a known position.** `A_JOB` should fall by about
   2,593,664 and every other opcode should be unchanged. The unchanged rows are
   the control and they are the reason to capture the profile at all.

---

## Appendix: sources, so every cell can be re-derived

| lever | primary source |
|---|---|
| L-A FAST_POP | `docs/debugging/2026-09-20_a-accept-port-idle.md`; area in `docs/WORKLOG.md` TRACK LEVERCOST; `hw/fk33/results/levercost_2026-09-20/` |
| L-CB codebook | `docs/debugging/2026-09-20_codebook-command-fanout-per-row.md`; `docs/debugging/2026-09-20_codebook-teeth-and-the-repinned-landmark.md` |
| L-C1 SWEEP_PIPE | `docs/debugging/2026-09-20_c-sweeps-at-5-cycles-per-beat.md`; area in TRACK LEVERCOST |
| L-C2 SCORE_EARLY | `docs/debugging/2026-09-20_the-attention-midgap.md`; area and routing in `hw/fk33/results/hdrcost_2026-09-20/README.md` |
| L-C3 SCORE_HDR_TREE | `docs/debugging/2026-09-20_the-score-header-pass.md` (cycles); `docs/debugging/2026-09-20_the-header-tree-does-not-synthesise.md` (the defect, the fix, the area) |
| L-S1 / L-S8 SwiGLU | `docs/debugging/2026-09-20_the-swiglu-on-the-group-port.md`; `docs/debugging/2026-09-20_vec-swg-5-cycles-per-element.md` |
| L-B B_RECUR_LANES | `docs/debugging/2026-09-20_the-gdn-recurrence.md`; `docs/WORKLOG.md` TRACK GDNSYNTH |
| L-AD A_DRAIN_WIDE | `docs/2026-09-20_d-side-vector-traffic.md` sections 10.1-10.4 |
| the cycle model | `docs/debugging/2026-09-20_token-cost-grows-2793-cycles-per-position.md` |
| the placed report | `hw/fk33/results/card_swg_2026-09-20/bd_wrapper_utilization_placed.rpt`; `hw/fk33/results/card_build10_FAILED_2026-09-20/utilization_placed.rpt` |

---

## CORRECTION, 2026-09-20 22:15, TRACK HDRCOST: L-C3's two open items are closed

Appended rather than edited in place, per this project's correction rule.
Nothing above is withdrawn; two items it lists as PENDING have landed.

**Open item 1, "HDRCOST's `treefix` routed timing", is CLOSED.**
`arms/synth_treefix.csv` and `arms/pnr_treefix.csv` now exist. MEASURED:
**routed CLB 20,519 against base's 20,377, and routed WNS 3.101 against
base's 3.101 -- identical to three decimals**, 0 failing endpoints of
250,542, fully routed (177,416 of 177,416 routable, 0 routing errors).
`treefix`'s own deepest new path, `gen_head[0].u_sq/tl0_reg/C` ->
`e_min_reg[1]/D`, routes at **5 logic levels with 10.292 ns of slack**, 7.19 ns
more margin than the block's critical path. So the L-C3 row's timing cell
should read **MEASURED, no movement**, not HOLE.

**Open item 2, "the one-line fix is not in the repository", is CLOSED.**
`rtl/attn_score_q12.vhd` reads `for i in 0 to TW-1` at the fold as of commit
`e1d5898`. `SCORE_HDR_TREE=1` no longer kills `synth_design`. The gate after
the fix: `tb_attn_score_q12` PASS 1, `tb_attn` PASS 16 / NOCHECK 1 /
SKIPPED 4, `tb_csweep_rate` PASS 1, `cardtop` PASS 3, FAIL 0 everywhere; the
fix is simulation-identical at 20 of 20 points of SCOREHDR's grid and
teeth-tested with attribution controls.

**THE BOARD'S RECOMMENDATION DOES NOT CHANGE, AND THE ROUTED ARM STRENGTHENS
IT.** `SCORE_HDR_TREE` stays excluded. The two levers are cycle-equivalent
(231.11 against 231.17) and **102x apart in LUT and 68x in flip-flops**
(`SCORE_EARLY` +5 / +2 against the fixed tree's +512 / +136). Section 4's
cliff arithmetic already placed +512 inside the 702 LUT the 106 free CLBs
absorb, so it was never an area refusal -- it is that 0.06 cycles does not
buy 507 LUT.

**ONE CAUTION ON L-C1 + L-C2's "+69 LUT and +25 FF MEASURED".** That sums
LEVERCOST's `SWEEP_PIPE` +64 (tree `bc4156f`, `create_clock` AFTER
`synth_design`) with HDRCOST's `SCORE_EARLY` +5 (tree `cc5f92f`, clock read
BEFORE it). **MEASURED, the uncontrolled term is larger than one of the
addends:** LEVERCOST's `cswp_on` and HDRCOST's `base` are the SAME
configuration and read **86,724 against 86,891, a 167 LUT gap**, 2.6x the +64
being quoted. Each pair is sound inside its own harness; the SUM is not a
same-tree measurement and should not carry the MEASURED label. **The order of
magnitude is not in doubt and recommendation (1) does not turn on it** -- both
figures are far inside the cliff -- but a same-tree pair would need one
harness to draw `SWEEP_PIPE` off as well, which no arm did.

Evidence: `hw/fk33/results/hdrcost_2026-09-20/README.md` and
`docs/debugging/2026-09-20_the-header-tree-does-not-synthesise.md`.

---

## CORRECTION 2, 2026-09-20 21:45, TRACK LEVERBOARD2: **L-CB WAS BELIEVED FREE AND IT IS THE MOST EXPENSIVE ROW ON THE BOARD**

Appended, not edited. Nothing above this line is deleted, including the
claims this section withdraws: the point of leaving them is that a reader can
see that L-CB was recorded as "0 cycles, LUT UNKNOWN, HIGH that it is safe"
and was then measured at **+44,073 CLB LUT**.

**No hardware, no Vivado, no GHDL was run by this track either.** Everything
below is read back from a committed report, a commit, or arithmetic shown in
place.

### C2.0 What landed between CORRECTION 1 and this one

| event | commit / source | effect on this board |
|---|---|---|
| build 11b's **placed** utilization report committed | `7743d6b` | L-CB's area cell is no longer UNKNOWN |
| TRACK PLACEDIFF's analysis | `0b7a457`, `hw/fk33/results/card_build11b_2026-09-20/README.md` | +44,073 LUT, and the 99.81% / 106-free provenance correction |
| TRACK CBOOC's harness and pre-registration | `7502fdd`, `docs/debugging/2026-09-20_cbooc-the-codebook-has-never-met-a-synthesiser.md` | names `CB_STYLE=regs` in LEVERCOST's `FAST_POP` draw as a wrong-configuration risk |
| TRACK BUILDREPORT | `952e70a` | **closes open item 4** below: `report_utilization -hierarchical` and report retention are now in `gen_pcieep.py` / `pcieep_build.sh`. Build 11b predates it and does not have it |
| TRACK HDRCOST | `e1d5898`, `f58a075` | CORRECTION 1 above |

### C2.1 L-CB, corrected: the cost is +44,073 CLB LUT, and it buys zero cycles

**WITHDRAWN from the L-CB row:** the area cell's *"LUT delta UNKNOWN, not
drawn"* and the scope cell's *"no synthesis at all"*. Both were true when
written and are now superseded. **The confidence cell's "HIGH that it is safe"
is NOT withdrawn** -- it was a statement about VALUES (464+343 oracle values, 0
mismatches, four configurations) and nothing here touches it. What is withdrawn
is any reading of the row as a free change.

**MEASURED**, `hw/fk33/results/card_build11b_2026-09-20/utilization_placed.rpt`
against `hw/fk33/results/card_build10_FAILED_2026-09-20/utilization_placed.rpt`,
both `Design State: Fully Placed`, same Vivado 2023.2 build, same part:

| resource | build 10 | build 11b | delta |
|---|---:|---:|---:|
| CLB LUTs | 361,361 (82.19%) | **405,434 (92.21%)** | **+44,073** |
| LUT as Distributed RAM | 64,478 | 52,174 | **-12,304** |
| MUXF7 | 28,422 | 53,022 | **+24,600** |
| MUXF8 | 6,027 | 18,315 | **+12,288** |
| CLB Registers | 308,213 | 296,396 | -11,817 |
| CLB | 54,751 (99.62%) | 54,822 (99.75%) | **+71** |

`MUXF8 +12,288 = 1,536 x 8` exactly, where 1,536 is `CB_COPIES` at the card
geometry. The growth is a **synthesis** result, not a placement one: build
11b's own `utilization_synth.rpt` already carries the identical
`MUXF8 = 18,315`, so the differing placer directive cannot reach it.

**CBFANOUT's `delta LUT = 0` is falsified by its own registered falsifier**
(`docs/WORKLOG.md:19`, *"If LUT moves, the folding argument is wrong"*).

#### C2.1a A lead the board can state cheaply: build 11b's codebook signature IS the `CB_STYLE=regs` signature

**DERIVED.** TRACK LEVERC48 (`a4828ab`, 2026-08-30) measured `matvec_core` OOC
at `ROWS_IF = 48`, `regs` against `distributed`, and that table is reproduced
in `docs/WORKLOG.md:5454`. Set it beside build 11b minus build 10:

| resource | LEVERC48, `regs` minus `distributed` (OOC `matvec_core`, `a4828ab`) | build 11b minus build 10 (card, placed) | agreement |
|---|---:|---:|---:|
| CLB LUT | +42,633 | +44,073 | 3.4% |
| MUXF7 | +24,583 | +24,600 | 0.07% |
| **MUXF8** | **+12,288** | **+12,288** | **exact** |
| LUT as memory | -12,288 | -12,304 | 0.13% |
| CLB FF | -13,195 | -11,817 | 10.4% |

**Every sign agrees; four of five magnitudes agree to better than 3.4%; MUXF8
agrees to the unit.** The one that does not, FF, is the resource build 11b's
pair cannot isolate anyway, because that pair carries seven RTL changes.

**The leading mechanism, ESTIMATE, and it is TRACK CBRAM's to settle, not
mine.** At `CB_STYLE = "distributed"`, `rtl/matvec_core.vhd:465` sets
`dont_touch of cb` to **"false"** (`cb_dt_f` returns "false" for distributed,
because a `dont_touch` signal is not a RAM-inference candidate), while
`cbw_v/a/d` stay `dont_touch = "true"`. Before `0b34200`, `cb(c)` was written
from `cbw_a(c)` -- **1,536 distinct undeletable drivers**, so the 1,536 `cb`
copies could not be merged. After it, `cb(c)` is written from
`cbw_a(cb_rank_of(c))` -- **48 drivers, 32 copies sharing each**, and 32 arrays
with byte-identical write ports and no `dont_touch` are mergeable. What
replaces a per-lane RAM32M16 read port is a per-lane 16:1 read mux, which is
4 LUT6 + 2 MUXF7 + 1 MUXF8 per bit, 1,536 x 8 times over. **That is the `regs`
netlist, and the table above is what it looks like.**

It also upgrades PLACEDIFF's FF reconciliation. That file offers
`-19,344 + 6,144 = -13,200` as *"arithmetic that fits, not evidence ... one
free parameter and one data point"*. It is no longer one data point:
**LEVERC48 independently MEASURED +13,195 for the same decomposition at the
same geometry** (its own note records the DERIVED +13,200 with a residual of
-5). Two independent routes to 13,200 is corroboration, not a fit.

**THE FALSIFIER, REGISTERED HERE BEFORE ANY SYNTHESISER RUNS.** TRACK CBOOC's
harness at `CBO_TARGET=matvec_core`, `CB_STYLE=distributed`, `0b34200^`
against HEAD, at the card geometry: **if the NEW arm does not show
`MUXF8 0 -> 12,288` and `LUT as memory -12,288`, this signature match is a
coincidence and section C2.1a is withdrawn in full.** The measured L-CB cost
in C2.1 does not depend on it; only the mechanism does. **TRACK CBRAM owns
`rtl/matvec_core.vhd` and
`docs/debugging/2026-09-20_the-codebook-stopped-being-ram.md` tonight; when
that file lands, cite it here and treat it as the authority over this
subsection.**

#### C2.1b What the per-row codebook is being traded against

**DERIVED, and it is the reason this row cannot be left in the tree by
default.** LEVERC48's `distributed` is worth **-42,633 CLB LUT** against
`regs` at this geometry, and it is the reason `FK33_CB_STYLE=distributed` is
set on every card build. If C2.1a is right, the per-row codebook **gives that
entire lever back**. It would be the most expensive change ever made to this
design for a cycle saving of zero.

**REFUSAL, and it is the one this project has already paid for: I am NOT
netting 44,073 against 42,633.** The two numbers come from different synthesis
contexts (an OOC `matvec_core` draw 264 commits old, and a card placed report),
and *the parts do not sum across synthesis contexts*. They are a **signature
match**, which is a statement about SHAPE, and they are not an accounting
identity.

### C2.2 L-C3, corrected: see CORRECTION 1, plus one withdrawal it did not make

CORRECTION 1 (TRACK HDRCOST, `f58a075`) already closes both of L-C3's open
items and already records the **+512 CLB LUT sites / +136 FF** for the fixed
tree against `SCORE_EARLY`'s **+5 / +2**. The L-C3 row and CORRECTION 1
together are accurate and this track changes neither.

**The one thing neither says in so many words:** SCOREHDR recommended
`SCORE_HDR_TREE` over `SCORE_EARLY` as *"the smaller change"*. That is **true
in cycles** (231.11 against 231.17 beside `SWEEP_PIPE`, a difference of 0.06
cycles per position per job) and **102x false in LUT and 68x false in FF**.
**"The smaller change" is WITHDRAWN as a recommendation.** The lever it
recommended against is the cheaper one by two orders of magnitude on the
resource that is binding.

Also note, because it is the same defect class as L-CB: L-C3 **as committed**
had never met a synthesiser either, and the first Vivado ever pointed at it
killed `synth_design` in 49 s. That is now two levers in one day whose scope
cell read "no synthesis" and whose first synthesis was a surprise. See C2.6.

### C2.3 The binding constraint, re-derived on a report that belongs to this design

**PROVENANCE CORRECTION, MEASURED by TRACK PLACEDIFF.** Section 4.1's
`99.81% CLB, 106 free, 76,585 free LUT sites` is
**`card_swg_2026-09-20`'s figure, not build 9's.** Section 8 item 1 of this
board attributes it correctly; section 4.1 does not say whose it is, and
downstream briefs collapsed it onto build 9. **Build 9 has no placed report of
any kind** (`hw/fk33/results/card_kvreg_2026-09-20/` holds no `.rpt`;
`grep -c 'CLB LUTs' build.stdout` = 0). Section 4.1's table is not wrong; it is
`card_swg`'s, and it must be labelled that way wherever it is quoted.

**The two card placed reports that DO belong to the levers under discussion**,
MEASURED, with the derived packing arithmetic shown once:

| | build 10 (codebook OUT) | build 11b (codebook IN) |
|---|---:|---:|
| CLB LUTs | 361,361 | 405,434 |
| LUT occupancy | 82.19% | **92.21%** |
| CLB | 54,751 (99.62%) | 54,822 (99.75%) |
| free CLB tiles | 209 | **138** |
| LUT per occupied CLB | 6.6001 of 8 | **7.3955 of 8** |
| free LUT sites in occupied CLBs | 76,647 | 33,142 |
| free LUT sites in free CLBs | 1,672 | 1,104 |
| **total free LUT sites** | **78,319** | **34,246** |
| LUTs the free CLBs absorb at that density | 1,379 | 1,021 |

DERIVED, and each column closes: `54,751*8 - 361,361 = 76,647` and
`76,647 + 209*8 = 78,319 = 439,680 - 361,361`; `54,822*8 - 405,434 = 33,142`
and `33,142 + 138*8 = 34,246 = 439,680 - 405,434`.

**The cliff moved, and the codebook moved it.** Section 4.1's lever table,
re-derived against both:

| lever | +LUT | % of 78,319 (codebook out) | % of 34,246 (codebook in) |
|---|---:|---:|---:|
| L-A FAST_POP | 1 | 0.00% | 0.00% |
| L-C2 SCORE_EARLY | 5 | 0.01% | 0.01% |
| L-C1 SWEEP_PIPE | 64 | 0.08% | 0.19% |
| L-C1 + L-C2 | 69 | 0.09% | 0.20% |
| L-C3 HDR_TREE (fixed) | 512 | 0.65% | 1.50% |
| **L-B B_RECUR_LANES=16** | **7,688** | **9.82%** | **22.45%** |
| **L-S8 SWG_LANES=8** (ESTIMATE) | ~16,000 | ~20.4% | ~46.7% |
| **L-CB per-row codebook** | **44,073 MEASURED** | **56.27%** | **128.70%** |

**L-CB alone is 128.70% of the free LUT sites build 11b has left.** It is
larger than every other lever on this board added together, and it is the only
one that buys nothing.

**Section 4.2's bound is not withdrawn as arithmetic and IS withdrawn as
guidance.** "0 to 1,209 CLBs freed" was a correct bound on the **FF term**.
The measured value is **-71 CLBs, i.e. 71 consumed**, outside the interval on
the low side, because **the FF term was never the whole change**: a bound
derived from one resource says nothing once a second resource moves by 44,073.
This is the board's own recorded lesson (*an exact relationship for one
resource is not a licence to scale a different resource*) arriving from the
direction nobody watched -- the bound was not used to scale anything, it was
used to reason about a change whose largest term had not been measured.

The `+71` itself is confounded (three implementation directives differ between
the two builds). **The 92.21% LUT, the 138 free tiles and the 7.3955 density
are not confounded in the way that matters**, and the primitive census is a
synthesis result that the directives cannot reach at all.

**One further MEASURED fact about build 11b, read from its own live log**
(`.../impl_1/runme.log`, read-only, nothing written into that tree):
`[Route 35-448] Estimated Global/Short routing congestion is level 6 (64x64)`
and `[Route 35-581] Estimated Timing congestion is level 6`, with
`[Route 35-445] at least 1610 CLBs have high pin utilization`. Vivado's own
text is that *"congestion levels of 5 and greater can reduce routability and
impact timing closure."* That is what 92.21% LUT at 99.75% CLB looks like from
inside the router.

### C2.4 The compositions, re-derived once, with the arithmetic shown

The **cycle** model is unchanged and this track re-derived it rather than
copying it. From section 3.1, MEASURED on silicon:

```
token_cycles(p) = 30,115,217 + 2,793.4 * p        core cycles at 75 MHz
tok/s(p)        = 75,000,000 / token_cycles(p)
```

Intercept levers, subtracted from 30,115,217 (DERIVED, section 1):

```
L-A  FAST_POP              -2,593,664   ->  27,521,553
L-S1 SWG_WIDE, LANES=1       -393,280   ->  27,128,273
L-B  B_RECUR_LANES=16      -2,362,128   ->  24,766,145
L-AD A_DRAIN_WIDE          -1,248,576   ->  23,517,569
L-S8 SWG_LANES=8, extra    -1,376,224   ->  22,141,345   (1,769,504 - 393,280)
L-CB per-row codebook               0   ->  unchanged
```

Slopes, by the **absolute-subtraction** conversion of section 3.3 (the smaller
claim; the ratio method is 0.9 to 1.1% more optimistic and this track does not
pick between them either):

```
none                  2,793.4
SWEEP_PIPE + SCORE_EARLY              1,801.4
all three C levers (HDR_TREE fixed)   1,711.0
```

**The one thing that changes is which rows are legitimate.** `B11b` is not a
baseline: it is a build that has not closed timing. Every composition below is
re-stated against **build 9** and with the codebook **reverted**, because a
composition that carries L-CB carries +44,073 LUT for no cycles.

| composition | codebook | intercept | slope | p=0 | p=512 | p=2,048 | p=8,192 | p=32,768 |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| **B0** build 9, shipping (2.46 MEASURED on silicon) | out | 30,115,217 | 2,793.4 | **2.490** | 2.378 | 2.093 | 1.415 | 0.617 |
| **B11b** as actually built, **DOES NOT CLOSE** | **in** | 27,521,553 | 2,793.4 | 2.725 | 2.591 | 2.256 | 1.488 | 0.630 |
| **N1** build 9 + FAST_POP, codebook REVERTED | out | 27,521,553 | 2,793.4 | 2.725 | 2.591 | 2.256 | 1.488 | 0.630 |
| | | | | +9.4% | +9.0% | +7.8% | +5.1% | +2.2% |
| **N2** N1 + SWEEP_PIPE + SCORE_EARLY | out | 27,521,553 | 1,801.4 | 2.725 | 2.637 | 2.403 | 1.774 | 0.867 |
| | | | | +9.4% | +10.9% | +14.8% | +25.4% | +40.6% |
| **N3** N2 + SWG_WIDE (LANES=1) | out | 27,128,273 | 1,801.4 | 2.765 | 2.674 | 2.434 | 1.791 | 0.871 |
| | | | | +11.0% | +12.5% | +16.3% | +26.5% | +41.2% |
| **N4** N3 + B_RECUR_LANES=16 | out | 24,766,145 | 1,801.4 | 3.028 | 2.920 | 2.636 | 1.898 | 0.895 |
| | | | | +21.6% | +22.8% | +25.9% | +34.1% | +45.2% |
| **N5** N4 + A_DRAIN_WIDE + SWG_LANES=8 + HDR_TREE | out | 22,141,345 | 1,711.0 | 3.387 | 3.258 | 2.924 | 2.074 | 0.959 |
| | | | | +36.0% | +37.1% | +39.7% | +46.6% | +55.5% |

Every figure reproduces section 3.4's to the digit, which is the check that
this track re-derived rather than transcribed. **`B11b` and `N1` are the same
row in cycles**, and that is the whole finding: the codebook contributes
nothing to any column of this table and 128.70% of build 11b's remaining LUT
headroom.

**The shape argument from section 3.4 stands and is worth repeating, because
it is what makes a single headline wrong.** N1's intercept win over B0 is +9.4% at
p=0 and decays to +2.2% by p=32,768. N2's slope win **over N1** is +0.0% at
p=0 and grows without bound. **DERIVED: the two are equal at p = 2,431**
(+7.56% each); below that the intercept lever is worth more, above it the
slope pair is, and by p=8,192 the slope pair is worth +19.2% against the
intercept lever's +5.1%. A composition chosen on the p=0 column is chosen on
the wrong column for any real chat.

**One number this board should stop quoting without a caveat:** the model says
2.490 tok/s at p=0 and the silicon figure is **2.46**, a 1.2% gap. The 2.46 was
measured at a position nobody recorded, so the gap is unattributed. Every "+x%"
above is model-against-model and is therefore internally consistent; **none of
them is a prediction of what a wall clock will show.**

### C2.5 What is UNBUILT and UNMEASURED, stated plainly

**NO LEVER ON THIS BOARD HAS LANDED ON SILICON. The shipping bitstream is
still build 9 at 2.46 tok/s, and every row of section 1's "cycles/token saved"
column is a number from a bench or a model.**

| build | contents | outcome | MEASURED |
|---|---|---|---|
| build 9 `card_kvreg` | baseline | **SHIPPING** | routed WNS +0.061, 2.46 tok/s |
| build 10 | KV seam reg + PIPE/WIDE/MAXOUT8/NWIDE | **FAILED** | placed +0.421, routed **-5.819**, 17,248 failing endpoints |
| build 11b | FAST_POP + per-row codebook | **FAILING, in flight** | placed **-5.136 / TNS -236,998**; router at Phase 4.2 with intermediate **-4.491**, congestion level 6 |

Three builds today. One shipping bitstream, from yesterday. **Build 11b's
placed WNS is worse than build 10's ROUTED WNS was**, and build 10 is the one
this project calls a failure.

This board must not be read as though six levers are ready. What each lever
actually has:

| lever | value oracle | synthesised | placed | routed | on the card |
|---|---|---|---|---|---|
| L-A FAST_POP | benches, but **none at `FAST_POP=true`** | yes, at `CB_STYLE=regs` | no | no | build 11b, unfinished |
| L-CB codebook | yes, 4 configurations | **first time tonight, and it cost 44,073 LUT** | yes | no | build 11b, unfinished |
| L-C1 SWEEP_PIPE | yes | yes | no | no | no |
| L-C2 SCORE_EARLY | yes | yes | yes | **yes** | no |
| L-C3 HDR_TREE (fixed) | yes, 20/20 grid | yes (after `e1d5898`) | yes | **yes** | no |
| L-S1 SWG_WIDE | GHDL only | **never** | no | no | no |
| L-S8 SWG_LANES=8 | GHDL only | **never** | no | no | no |
| L-B B_RECUR_LANES=16 | yes | yes | no | no | no |
| L-AD A_DRAIN_WIDE | GHDL only | **never, and no harness can** | no | no | no |

### C2.6 What build 12 should carry, and what it must not

#### The rule tonight actually produced

**DO NOT PUT RTL ON A CARD BUILD THAT NO SYNTHESISER HAS EVER DRAWN.**

Two levers had a scope cell reading "no synthesis at all" this morning. The
first Vivado pointed at **L-C3** killed `synth_design` in 49 seconds. The first
Vivado pointed at **L-CB** produced +44,073 LUT that every document about it
said could not exist. Two for two, in one day, and in both cases every value
oracle, every mutation suite and every gate row was green while it happened.

This is not "compose fewer levers". Build 10 composed five and failed; build
11b composed two and is failing. **The discriminator that separates tonight's
two failures from L-C2, which routed cleanly, is not the count -- it is
whether a synthesiser had ever seen the RTL.** That rule excludes L-S1, L-S8
and L-AD from build 12 outright, and would have excluded L-CB.

#### Build 12, recommended

**MANDATORY, whichever levers are chosen: revert the per-row codebook.**
`rtl/matvec_core.vhd` at HEAD carries `0b34200` / `5dc3ee5` / `9435942`, so
**a card build started from HEAD today builds the +44,073 LUT netlist by
default.** This is not a lever to decline; it is a change to take out. It costs
44,073 LUT and 0 cycles, and on the C2.1a lead it gives back lever C's entire
-42,633. `CB_RANKS` is a derived constant (`matvec_core.vhd:324`), not a
generic, so **the revert is an RTL change and not a `--generic`** -- which is
TRACK CBRAM's file, not this track's.

What reverting restores is build 9's exact codebook netlist, including the
1,536-sink command net that carried all ten of build 10's worst paths. **Build
9 closed at +0.061 with that net**, so it is a known-good configuration and
not a known-bad one. The fanout of 1,536 is a real defect with a real fix
available; the fix that was written is not it.

**CONTENTS: revert L-CB, plus L-A `FAST_POP`, plus L-C1 `SWEEP_PIPE` and L-C2
`SCORE_EARLY`.** That is row **N2**: 2.725 tok/s at p=0 (+9.4%), 2.403 at
p=2,048 (+14.8%), 1.774 at p=8,192 (+25.4%).

* **Area: ESTIMATE +70 LUT**, against build 10's 78,319 free LUT sites
  (0.09%). **Not MEASURED**, and CORRECTION 1 is why: the +64 and the +5 come
  from two harnesses whose same-configuration points differ by 167 LUT, which
  is larger than the +64 addend. The order of magnitude is not in doubt.
* **All three have been synthesised.** L-C2 has been **routed**, twice, with a
  published ~0.4 ns noise floor. L-C1 and L-C2 are already at HEAD
  (`rtl/llama_top.vhd:6997`), so they need no `--generic`.
* **The three cones are disjoint** (A's read path; `attn_block`'s sweep FSM;
  `attn_score_q12`), so a failure is attributable, which is the property build
  10 and build 11b both lacked.
* **It moves the slope**, the axis no build has ever touched and the only one
  that grows with use.

**Considered and rejected: a single-lever build (revert + `FAST_POP` only,
row N1).** It is the most conservative thing available and it is the wrong
trade here, because the +70 LUT of the C pair is 0.09% of the headroom and the
pair is better evidenced than `FAST_POP` is -- `SCORE_EARLY` has a routed
number and `FAST_POP` has no bench at the arm the card ships. Dropping the C
pair would cost the entire slope win to buy 0.09% of a budget. **If Oren
prefers the single-lever build anyway, take N1 -- the argument above is a
judgement, not a measurement, and the mandatory part of this recommendation is
the revert, not the composition.**

#### What build 12 must NOT carry, with the argument

| excluded | argument |
|---|---|
| **L-CB per-row codebook, as written** | +44,073 LUT MEASURED, 0 cycles, 128.70% of build 11b's remaining LUT headroom. Revert it. |
| **L-S1 `SWG_WIDE`** | **No synthesiser has ever seen this RTL**, and the write-up gives two different FF figures for it (160 and 365). Exactly L-CB's evidence class. 393,280 cycles is not worth repeating tonight's experiment. One OOC draw of `llama_top` promotes it; nothing else does. |
| **L-S8 `SWG_LANES=8`** | Same, and its area is unknown to a factor of 2 by its own authors. |
| **L-AD `A_DRAIN_WIDE`** | Same, and **worse**: its logic is in an architecture body, so **no harness that exists can draw it**. It also collides with `SWG_WIDE` on `wgmux` and the pair has never been elaborated together. |
| **L-B `B_RECUR_LANES=16`** | **NOT excluded on evidence** -- it is MEASURED in the card's own configuration, and it is the largest intercept lever on the board. Excluded on **size**: 7,688 LUT is 9.82% of build 10's free LUT sites and needs the packer to raise average density. **Take it alone, in build 13**, which is what LEVERCOST and GDNSYNTH both concluded independently. If it is composed with the C pair and fails, the 7,688 and the 70 are indistinguishable in the postmortem, and that is exactly how build 10 spent a place-and-route. |
| **L-C3 `SCORE_HDR_TREE=1`** | Unchanged from CORRECTION 1: cycle-equivalent to `SCORE_EARLY` (231.11 against 231.17) at 102x the LUT. Not an area refusal; 0.06 cycles does not buy 507 LUT. |

#### One setup item that is not a lever and is now free

TRACK BUILDREPORT (`952e70a`) put `report_utilization -hierarchical` and
report retention into `gen_pcieep.py` and `pcieep_build.sh`. **Build 11b
predates it.** Build 12 gets a per-subsystem area table and keeps its reports
at zero marginal cost, which closes open item 4 below and is the single
cheapest thing on this board. Three attribution questions failed this evening
on exactly that missing evidence.

### C2.7 Refusals to project: the eight kept, and four added

All eight refusals in section 6 are kept. Refusal 4 ("I did not convert
-19,344 FF into freed CLBs") turned out to be the right call for the wrong
reason: the bound was sound and the quantity it bounded was not the one that
mattered. That is recorded, not celebrated.

Four added:

9. **I did not net +44,073 against LEVERC48's -42,633.** They agree in shape
   and they are different synthesis contexts 264 commits apart. C2.1b says so
   at the point of temptation.
10. **I did not predict build 11b's routed WNS from its placed -5.136 or from
    its intermediate -4.491.** This file already records that nothing before
    `route_design` orders two runs correctly, and that a placed WNS can have
    the opposite sign from the routed one. Build 10 placed at +0.421 and routed
    at -5.819. **The direction of that error is the flattering one, which is
    why a bad placed number is not reassuring either.** Build 11b's outcome is
    an open item, not a forecast.
11. **I did not scale the C pair's +69 LUT to the card.** It is an ESTIMATE
    drawn in `attn_block`, and CORRECTION 1 measured a 167 LUT gap between the
    two harnesses that contributed its addends. The recommendation does not
    turn on the value, only on its order of magnitude, and that is said in
    place rather than left implied.
12. **I did not convert the `-5.136` placed WNS into an attribution.** That
    +44,073 LUT caused it is a plausible mechanism and nothing more. **Build 10
    failed at -5.819 with 82.19% LUT occupancy**, which is direct evidence that
    this design can fail timing badly with no LUT explosion at all.

### C2.8 Evidence on this board that comes from a configuration the card does not build

The brief asked for this explicitly, after three tracks found the same defect
class in three different places today (GDNSYNTH's flat arm, SHAPEAUDIT's
`FAST_POP`, KVGEOM's `C_KV_BLOCK`). One board row is affected and one is not.

1. **L-A `FAST_POP`'s area cell is drawn at `CB_STYLE=regs`, and the card
   builds `distributed`.** MEASURED: `sim/ooc_levercost_run.sh:107`'s `AGEN`
   carries `CB_STYLE=regs`; the card build runs
   `FK33_CARD=1 FK33_CB_STYLE=distributed FK33_ENG_CORE_MHZ=75`. At `regs`,
   `CB_COPIES = 48`; at `distributed`, **1,536**. So the entity the `+1 CLB
   LUT` was drawn in contains **one thirty-second** of the card's codebook
   structure. TRACK CBOOC states it in its own words: *"LEVERCOST's `+1 CLB
   LUT` is a `regs` number and the contexts do not sum."*
   **What survives:** the +1 is a one-variable A/B inside its own arm and is
   sound as that. **What does not:** it is not a card figure and it was never
   drawn in the netlist the card builds. Given that the SAME generic is what
   C2.1a says collapsed, this is not a hypothetical concern.
2. **L-A also still has no bench at the arm the card ships**, section 4.4,
   MEASURED by SHAPEAUDIT and unchanged. It is the cheapest open item here.
3. **L-B's `-7,545` flat-arm LUT figure must never be quoted**; only the tier
   row. The board already says this and it is restated because the LUT delta
   **inverts sign** between the arms.
4. **KVGEOM's `C_KV_BLOCK` split: CHECKED, and no row on this board rests on
   it.** No lever here is parameterised by `KV_BLOCK`, and KVGEOM MEASURED
   that no setter for `FK33_C_KV_BLOCK` exists anywhere in the tree. Recorded
   as checked rather than assumed.

### C2.9 Open, not determined (superseding section 7's list where noted)

**CLOSED since section 7 was written:** items 1 and 2 (by CORRECTION 1),
item 4 (by `952e70a`), and the *area* half of item 5 -- the codebook's cost is
now MEASURED at +44,073 LUT and `FAST_POP`'s is not separable from it.

**STILL OPEN, unchanged:** 3 (build 9 has no placed report, and it is still the
control that would settle the most), 6, 7, 8, 9, 10, 11, 12.

**NEWLY OPEN:**

13. **Build 11b's routed outcome.** In flight at Phase 4.2, intermediate
    -4.491 from a placed -5.136, congestion level 6. Not forecast here.
14. **Why `cb` stopped inferring as RAM.** C2.1a is a lead with a registered
    falsifier and a named owner (TRACK CBRAM); it is not a measurement. One OOC
    `matvec_core` draw at `distributed`, `0b34200^` against HEAD, settles it in
    minutes.
15. **Where the 196,608 bits of codebook content live in build 11b.** Not
    flip-flops (FF fell), not the LUTRAM that vanished. C2.1a predicts a
    merged `48 x 16 x 8 = 6,144` flops, which a `get_cells` census on
    `cb_reg*` in the placed checkpoint would confirm or kill.
16. **Whether reverting the codebook is sufficient**, or whether build 11b's
    -5.136 has a second cause. Nothing separates them today.
17. **Whether the 1,536-sink command net needs fixing at all.** Build 9 closed
    at +0.061 with it. The build-10 postmortem's CORRECTION already withdrew
    the claim that area displaced it, and *why that net became unroutable in
    build 10 and not in build 9 is NOT DETERMINED.* **The fix that was built
    for a problem whose cause is undetermined turned out to cost 44,073 LUT.**
18. **The 2.46 against 2.490 gap at p=0**, because the position at which 2.46
    was measured was never recorded.
19. **`BUFGCE 15 -> 16` in build 11b.** Unexplained, inherited from PLACEDIFF.

**Sources added by this correction:**
`hw/fk33/results/card_build11b_2026-09-20/README.md` (`0b7a457`, `7743d6b`);
`hw/fk33/results/card_build10_FAILED_2026-09-20/README.md` including its
CORRECTION (`a3cb844`); `docs/debugging/2026-09-20_cbooc-the-codebook-has-never-met-a-synthesiser.md`
(`7502fdd`); `docs/WORKLOG.md:5454` (TRACK LEVERC48, `a4828ab`);
`rtl/matvec_core.vhd:258-334, 423-480, 795-830` read but not modified;
`hw/fk33/gen_pcieep.py` (`952e70a`).
