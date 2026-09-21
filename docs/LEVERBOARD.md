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
