# TRACK HDRCOST -- what `SCORE_HDR_TREE` costs, and why build 11 keeps `SCORE_EARLY`

Date: 2026-09-20. Part `xcvu33p-fsvh2104-2L-e`, Vivado 2023.2, BC-250 lane
(`cachyos-bc250`, 15.2 GB + 48 GB swap). No hardware. Workstation lane was
never given a Vivado. Tree: 114 `rtl/*.vhd` blobs from `git show HEAD:<path>`
at **`cc5f92f`**, staged into a standalone remote root and manifest-verified
sha256-identical on both boxes before every launch
(`d88f8e7...` for the pristine tree, `baa1173...` for the one-line-fix tree).

Harness: `sim/ooc_scorehdr.tcl` (synth + opt + validated census + DCP),
`sim/ooc_scorehdr_pnr.tcl` (place + route + score-cone timing),
`sim/ooc_scorehdr_run.sh` (driver). Full analysis:
`docs/debugging/2026-09-20_the-header-tree-does-not-synthesise.md`.

---

## The answer, up front

**`SCORE_HDR_TREE=1` AS COMMITTED AT `56d13e3` DOES NOT SYNTHESISE.** The
first Vivado ever run on it killed `synth_design` in 49 seconds:
`ERROR: [Synth 8-11324] array index 8 out of range
[rtl/attn_score_q12.vhd:488]`, at `NBLK = 8`, the card's own geometry. So the
area-and-timing question the brief asked is unreachable as posed: there is no
netlist to measure.

**BUILD 11 KEEPS `SCORE_EARLY`, and that costs +5 LUT and +2 FF.**

**The defect is one loop bound.** `for i in 0 to NBLK-1` should be
`for i in 0 to TW-1`. With that one line changed the tree synthesises, places
and routes, and costs what SCOREHDR estimated it would -- **+512 LUT sites and
+136 flip-flops, the FF figure exact** -- with the routed WNS unchanged to
three decimals.

**AND THE FIX DOES NOT CHANGE THE RECOMMENDATION.** The two levers are
cycle-equivalent (231.11 against 231.17) and are **102x apart in LUT**:

| lever | cycles/position | CLB LUT sites | flip-flops | routed WNS |
|---|---:|---:|---:|---:|
| `SCORE_EARLY` | 231.17 | **+5** | **+2** | within noise |
| `SCORE_HDR_TREE=1`, fixed | 231.11 | **+512** | **+136** | 0.000 |

SCOREHDR called the tree "the smaller change". That was true of the source
diff and is false of the device. On a card bound by CLB occupancy at 99.81%,
0.06 cycles does not buy 507 LUT. Build 11 takes `SCORE_EARLY`;
`SCORE_HDR_TREE` stays at 0.

---

## The arms

All five draw `attn_block` at the card's 9B generics from
`rtl/fk33_llama_top.vhd`'s `u_attn` generic map resolved against
`QWEN35_9B` -- `HEAD_DIM=256 N_QH=16 N_KVH=4 KV_BLOCK=32 N_ROT=64 LAYERS=8
POS_W=17 MANT_W=16 CM_W=8 EXP_W=8 NORM_LANES=1 STRICT_PRODUCER=true`, giving
`G = 4` score units and `NBLK = 8`. Passing them is load-bearing:
`attn_block`'s own `POS_W` default is 16 and the card passes 17.

| arm | generics beyond the shared set | what it is |
|---|---|---|
| `base` | `SWEEP_PIPE=true` | the shared control |
| `tree` | + `SCORE_HDR_TREE=1` | the proposal, as committed |
| `early` | + `SCORE_EARLY=true` | the incumbent in build 11 |
| `treefix` | + `SCORE_HDR_TREE=1`, on the one-line-fix tree | the proposal, repaired |
| `basereport` | (none) | `base`'s routed checkpoint, re-reported |

`tree` and `early` each differ from `base` in **exactly one generic**. They
are deliberately not compared to each other directly -- that pair differs in
two -- each is compared to the shared control and the two deltas are what is
quoted.

---

## Area

Post-`opt_design`, object census and `report_utilization` agreeing on every
validated row:

| | base | early | treefix | early-base | treefix-base |
|---|---:|---:|---:|---:|---:|
| CLB LUTs (sites) | 86,891 | 86,896 | 87,403 | **+5** | **+512** |
| LUT as Logic | 86,798 | 86,803 | 87,310 | +5 | +512 |
| LUT as Memory | 93 | 93 | 93 | 0 | **0** |
| CLB Registers | 101,242 | 101,244 | 101,378 | **+2** | **+136** |
| CARRY8 | 2,741 | 2,741 | 2,753 | 0 | **+12** |
| F7 Muxes | 16,375 | 16,375 | 16,343 | 0 | **-32** |
| F8 Muxes | 2,992 | 2,992 | 2,992 | 0 | **0** |
| Block RAM Tile | 11 | 11 | 11 | 0 | **0** |
| RAMB36E2 / RAMB18E2 | 3 / 16 | 3 / 16 | 3 / 16 | 0 / 0 | **0 / 0** |
| URAM288 | 0 | 0 | 0 | 0 | 0 |
| DSP48E2 | 298 | 298 | 298 | 0 | **0** |
| census LUT *cells* | 95,055 | 95,061 | 95,827 | +6 | **+772** |
| census FD* | 101,242 | 101,244 | 101,378 | +2 | **+136** |

### SCOREHDR's ESTIMATE, against the measurement

| | ESTIMATE (2026-09-20) | MEASURED | |
|---|---|---|---|
| flip-flops per `attn_block` | **+136** | **+136** | **exact** |
| flip-flops per score unit | +34 | +34 | exact |
| LUT per `attn_block` | **+520 to +800** | **+512 sites / +772 cells** | sites 1.5% under the low end; cells inside the range |

The estimate derived +32 FF for the `tv` working set, +5 for `tn`/`tl0` and
-3 for the trimmed `blk`. **It is right to the flip-flop, four times over.**
The LUT figure straddles the range because a census counts LUT *cells* and
`CLB LUTs*` counts *sites* after LUT combining; they measure different things
and **the site count is the one that competes for CLBs.**

### The control, and it did not move

`SCORE_HDR_TREE` has exactly one functional occurrence in
`rtl/attn_block.vhd` (`:1123`, `HDR_TREE => SCORE_HDR_TREE` in `u_sq`'s
generic map), so everything outside `gen_head[*].u_sq` must be identical
between `base` and `treefix`. MEASURED, the `u_sq` cone census:

| cone, by REF_NAME | base | early | treefix |
|---|---:|---:|---:|
| total cells | 5,404 | **5,404** | 6,292 |
| LUT cells | 3,460 | **3,460** | 4,232 |
| FD* | 1,780 | **1,780** | 1,916 |
| CARRY8 | 92 | **92** | 104 |
| MUXF7 | 56 | **56** | 24 |

**`early`'s cone is byte-identical to `base`'s on every REF_NAME**, which is
what makes the cone census admissible as evidence about a generic inside the
cone. And for `treefix` the attribution is exact:

* block LUT cells `95,827 - 95,055 = +772`; cone LUT cells
  `4,232 - 3,460 = +772`. **Every added LUT cell is inside `u_sq`.**
* block FD* `+136`; cone FD* `+136`. **Every added flip-flop is inside
  `u_sq`.**

Nothing leaked outside the cone, in either direction.

---

## Timing, routed

`place_design` + `route_design` in a second Vivado process from the post-opt
checkpoint. No `phys_opt_design`, deliberately: it is directive-sensitive and
its WNS on this part has over-promised by 0.4 to 0.6 ns twice and once
inverted the verdict, so it would add a stage that can differ between arms for
reasons unrelated to the generic.

| | base | early | treefix |
|---|---:|---:|---:|
| **CLB (sites)** | 20,377 | 20,276 | **20,519** |
| CLB LUTs (sites) | 86,164 | 86,171 | 86,683 |
| LUT as Logic | 86,079 | 86,086 | 86,598 |
| CLB Registers | 101,241 | 101,244 | 101,378 |
| CARRY8 | 2,741 | 2,741 | 2,753 |
| **routed WNS (13.333 ns)** | **3.101** | **2.735** | **3.101** |
| failing endpoints | 0 of 250,281 | 0 of 250,285 | 0 of 250,542 |
| fully routed / routable nets | 176,751 / 176,751 | fully routed | 177,416 / 177,416 |
| routing errors | **0** | **0** | **0** |
| place / route seconds | 505 / 911 | 500 / 776 | 503 / 774 |

`treefix`'s routed WNS is **identical to `base`'s to three decimals**, and its
own deepest new path -- `gen_head[0].u_sq/tl0_reg/C` -> `e_min_reg[1]/D`, the
register-mux-compare-mux-register chain SCOREHDR predicted -- routes at
**5 logic levels with 10.292 ns of slack**, 7.19 ns more margin than the
block's critical path. `score_tv` is **128 cells**, exactly the estimated
32 flip-flops per unit times four.

### The headline could never have answered this, and here is the number

```
SCOREHDR_CONESHARE tag=basereport top=200 in_score_cone=0
SCOREHDR_CONESHARE tag=early      top=200 in_score_cone=0
SCOREHDR_CONESHARE tag=treefix    top=200 in_score_cone=0
```

**Zero of the top 200 routed paths touches `u_sq`, in any of the three arms --
including the one that adds 772 LUT cells and 136 flip-flops to that cone**, which
confirms TRACK LEVERCOST's post-synthesis finding at the routed stage. The
two arms' worst paths are not even in the same module:

| arm | routed worst path | levels |
|---|---|---:|
| base | `ar_rsb_reg[0]/C` -> `u_arr/p_reg_reg[22]/DSP_A_B_DATA_INST/A[16]` | 3 |
| early | `u_quant/raddr_r_reg[0]/C` -> `vs2_q_reg[15]/D` | 6 |

The cone's own worst path into it: **9.355 ns (base) and 9.514 ns (early)**,
against a 3.101 / 2.735 ns headline. **The score cone carries about 6.3 ns
more slack than the block's critical path.**

### THE NOISE FLOOR OF THIS HARNESS IS ABOUT 0.4 ns, MEASURED

`base` and `early` differ by **+5 LUT and +2 FF** and their routed WNS differs
by **0.366 ns**, on different critical paths in different modules. A 5-LUT
change cannot move a critical path in the quantiser, so **0.366 ns is
placement-and-routing variance and no WNS difference below roughly 0.4 ns in
this flow is a result.** Clear that bar before claiming a timing effect here.

---

## Memory, and which figures are honest

| arm / phase | cgroup `memory.peak` | at cap? | max `memory.swap.current` | wall |
|---|---:|---|---:|---:|
| base synth | 11,266 MB | **YES** | **7,064 MB** | 995 s |
| early synth | 11,267 MB | **YES** | **6,680 MB** | 995 s |
| treefix synth | 11,267 MB | **YES** | **6,858 MB** | 998 s |
| tree synth (failed) | 2,966 MB | no | 0 MB | 49 s |
| base pnr | 6,794 MB | no | 0 MB | 1,416 s |
| early pnr | **6,807 MB** | **no** | **0 MB** | 1,453 s |
| treefix pnr | **6,809 MB** | **no** | **0 MB** | 1,459 s |
| basereport (report-only) | 3,725 MB | no | 0 MB | 121 s |

Cap was `MemoryHigh=11G` and was **not raised**: a build at 12G on that 14 GB
box once left it completely unreachable and it is on no WoL watchdog.

**Both synthesis arms hit the cap, so neither 11,266 nor 11,267 MB is an
appetite** -- they are the throttle. DERIVED true footprint at least ~18 GB;
the actual peak is UNKNOWN. **The place-and-route arms did not reach the cap
and those figures ARE appetites: 6,807 MB with zero swap.** Routing this block
costs 40% of what synthesising it costs, which is the opposite of the
intuition that set the cap.

---

## Files

`arms/` carries, per arm: `synth_*.csv` and `pnr_*.csv` (one row each),
`census_opt_*.txt` and `cone_*_*.txt` (the object censuses),
`optutil_*.rpt` / `routeutil_*.rpt` (+ hierarchical),
`tsum_*.rpt` (routed timing summary), `routestatus_*.rpt`,
`paths_*.txt` (top-200 routed path distribution, diffable between arms),
`cone_score_*_*.txt` (the cone distributions), `mem*_*.txt`, and the
generated `clk_*.xdc`.
