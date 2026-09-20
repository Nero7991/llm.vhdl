# TRACK LEVERCOST -- what the four throughput levers cost, and which of them build 11 can afford

Date: 2026-09-20. Part `xcvu33p-fsvh2104-2L-e`, Vivado 2023.2, BC-250 lane
(`cachyos-bc250`, 15.2 GB + 48 GB swap). Workstation lane was on build10's
`impl_1` throughout and was never touched. No hardware; `synth_design`,
`opt_design` and `report_*` only.

Harness: `sim/ooc_levercost.tcl` + `sim/ooc_levercost_run.sh` (new here).

---

## The question

Four levers are implemented, verified in simulation and waiting for a card
build. The shipped card is at **CLB 54,854 of 54,960 (99.81%, 106 free)** and
routed at **WNS +0.061 ns**. What does enabling each cost in area and timing,
which subset fits, and in what order should build 11 take them?

---

## The answer, up front

**The experiment the brief asked for cannot be run, and that is the first
result.** An OOC synthesis of the card top -- `fk33_card` or
`fk33_llama_top` at the 9B geometry -- **has never once cleared RTL
elaboration**: `grep -c 'Finished RTL Elaboration'` is **ZERO across twelve
attempts on two machines** (`hw/fk33/ooc_c_in_card.tcl`), and the best-behaved
of them ran **47 h under `MemoryHigh=24G` wanting at least 39.1 GiB** and still
did not finish (`hw/fk33/ooc_card_dcp.tcl`). A five-arm A/B against that top
has no recorded instance of a single arm terminating. So every lever here is
drawn in **the smallest entity that closes its logic cone**, and two of the
four turn out not to have one.

**What the levers cost, MEASURED here:**

| lever | LUT | FF | DSP | BRAM | unit WNS | drawn in |
|---|---:|---:|---:|---:|---:|---|
| `FAST_POP` | **+1** | 0 | 0 | 0 | unchanged | `matvec_int4_desc_axi` |
| `SWEEP_PIPE` | **+64** | **+23** | 0 | 0 | unchanged | `attn_block` |
| `B_RECUR_LANES=16` | **+7,742** | +8,054 | +48 | +9 | unchanged | `gdn_block` |
| `A_DRAIN_WIDE` | ESTIMATE +250..400 | ESTIMATE +156 | ? | ? | ? | **no entity exists** |

**Ranked recommendation for build 11 is in section 6.** The short form:

1. **`FAST_POP` first, and it is free.** +1 LUT in the whole of subsystem A's
   compute unit, and this track **closes** the in-context timing question TRACK
   AIDLE left open: the top-200 core-domain path lists are md5-identical
   between the arms, and 92 of those 200 run through the lever's own FIFO cone.
2. **`SWEEP_PIPE` beside it or immediately after, once plumbed.** +64 LUT and
   exactly +23 FF -- **0.084% of the free LUT sites**. Its blocker is not area:
   the generic stops at `attn_block` and **adding it to the build script today
   would be silently ignored**.
3. **`B_RECUR_LANES=16` LAST, and alone.** It is **10.1% of the free LUT sites
   against the other two's 0.08%** and is the only lever whose failure mode is
   a build that does not close.
4. **`A_DRAIN_WIDE` cannot be composed on evidence, because there is none.**
   It is the one lever with no entity smaller than the card top, so no OOC
   draw can measure it -- not for want of a Vivado lane.

**No lever moved its unit's WNS.** Three of the four are, together, under
0.61% of the free LUT sites; one is 10.1% on its own. **That is the whole shape
of the decision, and two of those three had no measured area cost this
morning.**

---

## 1. The three structural findings, which matter more than the numbers

### 1.1 `SWEEP_PIPE` cannot be enabled by a card build today, at any area cost

MEASURED, 2026-09-20 at `07184e5`:

| where | occurrences of `SWEEP_PIPE` |
|---|---:|
| `rtl/attn_block.vhd` **at HEAD** | **0** |
| `rtl/attn_block.vhd` working tree (uncommitted, +217 lines) | many |
| `rtl/llama_top.vhd` | **0** |
| `rtl/fk33_llama_top.vhd` | **0** |
| `tools/gen_cardtop.py` | **0** |
| `hw/fk33/gen_fk33_card.py` | **0** |

Two separate blockers, and the second outlives the first:

* **It is not committed.** At `07184e5` the generic exists only in a dirty
  working copy that TRACK CSWEEP owns. Drawing it would measure a half-edited
  file, which this project has already recorded as producing `FAIL 3`, `FAIL 1`
  and `PASS 1` from one bench body in a single run.
* **Even once committed, the card cannot reach it.** `hw/fk33/rtl/fk33_engine.vhd`
  states the rule outright: *"`-generic` on the synth_design line reaches the
  TOP's generics only, never a deep instance, so a lever that is not carried by
  THIS entity is not reachable from the card build or from compose4_top at
  all."* `SWEEP_PIPE` is a generic of `attn_block`, four levels down. The
  WORKLOG's "NEXT" line for CSWEEP -- *"`SWEEP_PIPE => true` at the
  `attn_block` instance in `rtl/llama_top.vhd`"* -- is necessary but **not
  sufficient**: hard-wiring `true` at the instance works, but carrying it as a
  generic (the reviewable form every other lever uses) needs
  `rtl/llama_top.vhd`, `tools/gen_cardtop.py` **and** `hw/fk33/gen_fk33_card.py`.

### 1.2 `A_DRAIN_WIDE` has no entity below the card top, so no OOC can measure it

MEASURED: the lever's logic is spread across the **architecture body** of
`rtl/fk33_llama_top.vhd` -- the `wgmux` at `:1518`, the guard at `:1803`, and
the drain traversal at `:4665` and `:5147` -- all inside the `ga_desc` generate
block, which is **not an entity**. The smallest synthesisable unit containing
it is the card top, i.e. the job in section 0 that has never finished.

`docs/2026-09-20_d-side-vector-traffic.md:1007` asks for exactly this
measurement on "whichever Vivado lane is free". **The lane being free was never
the obstacle.**

What can still be said, and it is better than nothing: the mux is
**structural, not model-dependent**. `rtl/fk33_llama_top.vhd:244` declares
`LANES : positive := 8` and the card's generic map leaves it at the default, so
`A_DW_GRP = minimum(LANES, A_ROWS_IF) = 8` (`:1347`) and the group-write mux is
`LANES*MANT_W = 128` bits whatever the model. WIDEDRAIN's own **ESTIMATE of
+250 to +400 LUT and +156 FF** is therefore derived from a width that does not
move with the shape, which makes it more trustworthy than a shape-dependent
estimate would be -- but it remains **ESTIMATE, never measured**.

### 1.3 The four levers live in four disjoint units, so there is no interaction to measure OOC

`FAST_POP` is in subsystem A's engine cell; `B_RECUR_LANES` in `gdn_block`;
`SWEEP_PIPE` in `attn_block`; `A_DRAIN_WIDE` in the card top's own architecture.
Their unit-level area costs are therefore **additive by construction**, which
is precisely why adding them up is **not a prediction of the card**: this
project has already measured `gdn_block` reporting 22 BRAM tiles alone while a
composed run attributed 5,472 elsewhere. A "combination arm" at unit level
would be arithmetic dressed as an experiment. **Only a routed `FK33_CARD=1`
build gives the combined number.**

---

## 2. The card baseline this is all measured against

MEASURED, `hw/fk33/results/card_swg_2026-09-20/bd_wrapper_utilization_placed.rpt`:

| resource | used | available | % | free |
|---|---:|---:|---:|---:|
| CLB | 54,854 | 54,960 | **99.81** | **106** |
| CLB LUTs | 363,095 | 439,680 | 82.58 | 76,585 |
| LUT as Logic | 297,323 | 439,680 | 67.62 | |
| LUT as Memory | 65,772 | 205,440 | 32.02 | |
| CLB Registers | 308,981 | 879,360 | 35.14 | 570,379 |
| CARRY8 | 12,592 | 54,960 | 22.91 | |
| F7 Muxes | 28,528 | 219,840 | 12.98 | |
| F8 Muxes | 6,107 | 109,920 | 5.56 | |
| Block RAM Tile | 567 | 672 | 84.38 | 105 |
| URAM | 32 | 320 | 10.00 | 288 |
| DSPs | 2,087 | 2,880 | 72.47 | 793 |

**THE BINDING CONSTRAINT IS NOT LUT CAPACITY.** DERIVED from the rows above:

* Free LUT sites on the part: `439,680 - 363,095 = 76,585`.
* Of those, inside **already-occupied** CLBs: `54,854*8 - 363,095 = 75,737`.
  In the 106 genuinely free CLBs: `106*8 = 848`. (`75,737 + 848 = 76,585`,
  which is the consistency check.)
* Current packing density: `363,095 / 54,854 = 6.6194` LUT per occupied CLB,
  of a maximum of 8.

So on capacity arithmetic alone, even **+76,585 LUT** "fits". What does not fit
is the *placement*: the build uses `Congestion_SpreadLogic_high`, a strategy
whose entire purpose is to **spread logic out**, and it still ended at 99.81%
CLB with **+0.061 ns** of routed slack. Every added LUT must be packed into an
already-occupied CLB, working directly against the strategy that made the route
close.

**The fit question for build 11 is a congestion and timing question, not a
capacity question, and no OOC number can answer it.** What the numbers below
give is the *relative demand* of each lever, which is what orders them.

A note on the closed form: CLAUDE.md records `CLB = F7/4 + (LUT - 2*F7)/D`.
Solving it against this one placed run gives `D = 6.4130`. That number is
**fitted to a single point and must not be used to project another** -- it is
the recorded one-parameter-model trap. It is quoted here only to say that it
exists and that this track declined to build a projection on it.

---

## 3. The arms, and what each one measures

Every arm: `synth_design -mode out_of_context -flatten_hierarchy none` +
`opt_design`, generics passed explicitly (never left to an entity default),
census after both stages, timing at the card's two periods.

**`-flatten_hierarchy none` makes these numbers an UPPER BOUND on area and a
PESSIMISTIC estimate on timing**, because it forbids cross-boundary
optimisation. It is held constant across arms, which is what makes the DELTAS
comparable; the ABSOLUTE figures are not comparable with a composed run.
**Do not carry an absolute from this file into a card budget.**

For scale: this draw reports `matvec_int4_desc_axi` at **136,919 LUT**, while
the number this project has carried for subsystem A in a composed run is
**92,134 LUT** for `a_eng`. **That comparison is offered as an order of
magnitude and nothing more, because it is doubly invalid**: the 92,134 is from
a **2026-09-05** composed run, a different tree two weeks old, and it is a
different synthesis context. Both halves of that are recorded failure modes
here -- a subsystem table read across trees was once wrong by 9.7x in LUT, and
the parts have been measured not to sum across contexts. It is quoted only to
show that the gap is large, which is the reason for the rule.

**The shipped card's own report cannot settle it**:
`bd_wrapper_utilization_placed.rpt` was written without
`-hierarchical`, so it contains no per-cell breakdown at all (`grep -c
Instance` = 0). **A current per-subsystem area figure for the card does not
exist in the tree.** Adding `report_utilization -hierarchical` to the card
build is a one-line change that would make every future comparison of this kind
same-tree.

### 3.1 `FAST_POP` -- subsystem A, `matvec_int4_desc_axi` at the card's 27-lane geometry

Generics from `hw/fk33/gen_fk33_engine.py:84-95` plus `DUAL_CLK=true`,
`USE_XEXP_PORT=true` (the card sets `CONFIG.USE_XEXP_PORT`), `CB_STYLE=regs`.

**Why this entity.** TRACK AIDLE measured `FAST_POP` on `weight_streamer` and
labelled its result a LOWER BOUND, because out of context the consumer side is
a port: in the card, `pop_w <= all_v and w_ready`
(`rtl/weight_streamer.vhd:251-264`) fans back to all 27 FIFO read enables, and
`w_ready` carries `xq_cnt > 0` from `matvec_core`. **`matvec_core` and
`weight_streamer` are both inside `matvec_int4`, inside
`matvec_int4_desc_axi`** -- so this draw closes the exact cone AIDLE left open.
`fk33_engine` would also close it and adds only the CDC wrapper and the 28 AXI
master ports, none of which `FAST_POP` touches.

**AREA, MEASURED:**

| | apop_ctrl (`FAST_POP=false`) | apop_fast (`FAST_POP=true`) | delta |
|---|---:|---:|---:|
| CLB LUTs (sites) | 136,919 | **136,920** | **+1** |
| LUT as Logic | 131,681 | 131,682 | +1 |
| LUT as Memory | 5,238 | 5,238 | 0 |
| CLB Registers | 64,031 | 64,031 | **0** |
| CARRY8 | 6,360 | 6,360 | 0 |
| F7 / F8 Muxes | 24,867 / 12,382 | 24,867 / 12,382 | 0 / 0 |
| Block RAM Tile | 192.5 | 192.5 | 0 |
| URAM | 0 | 0 | 0 |
| DSP48E2 | 1,585 | 1,585 | **0** |

**`FAST_POP` costs ONE LUT in the whole of subsystem A's compute unit.**

The census says why, and it reproduces AIDLE's mechanism exactly one scope up:

```
  LUT4   4,778 -> 4,751   (-27)
  LUT5  13,950 -> 13,979  (+29)
  LUT6  71,778 -> 71,776   (-2)
  LUT2  31,769 -> 31,770   (+1)
  ----------------------------
  total 139,506 -> 139,507 (+1 cell)
```

**27 LUT4 become LUT5 -- one per read port, 24 weight plus 3 scale** -- which
is the same signature AIDLE reported on `weight_streamer`, now measured with
the consumer logic present. `do_rd` gains one input and a LUT6 site has room
for it.

**TIMING, MEASURED (ESTIMATE as a card number), from the Intra Clock Table:**

| | apop_ctrl | apop_fast | delta |
|---|---:|---:|---:|
| `s_axi_aclk` intra WNS (13.333 ns) | 9.088 | **9.088** | **0.000** |
| `m_aclk` intra WNS (4.000 ns) | 1.103 | **1.103** | **0.000** |
| failing endpoints | 0 of 344,738 | 0 of 344,738 | |

**The `m_aclk` 1.103 reproduces TRACK AIDLE's figure to the digit, on the same
named path** -- `dut/streamer/gen_s[0].scale_port/g_dc.fsm/st_reg[2]/C` ->
`.../this_len_reg[0]/CE`, 11 logic levels (CARRY8=4 LUT1=1 LUT3=2 LUT4=1 LUT5=1
LUT6=2), 2.793 ns datapath. AIDLE named exactly that path as "the AR-throttle
FSM" and said it does not move. Two independent draws at different scopes
agreeing on a named path is a cross-check, not a coincidence.

**AN UNCHANGED WNS ALONE WOULD ONLY BE A BOUND, SO THE DISTRIBUTION WAS
MEASURED TOO.** The worst core-domain path in both arms is `dw_reg[10][56]/C`
-> `err_code_reg[0]/CE`, **16 logic levels (LUT4=2 LUT6=14), 4.141 ns
datapath** -- a descriptor-word to error-code path with **nothing to do with
the FIFO cone `FAST_POP` touches**. A lever can make its own cone slower
without becoming the worst path, and then the WNS does not move and the arm
looks free when it is merely second. So both post-opt checkpoints were
re-opened and the **top 200 intra-domain paths per clock** dumped
(`sim/ooc_levercost_timing.tcl`, ~2 minutes per netlist):

| | apop_ctrl | apop_fast |
|---|---|---|
| `s_axi_aclk` top-200 slack range | 9.088 .. 9.592 ns | 9.088 .. 9.592 ns |
| `s_axi_aclk` top-200 list md5 | `182ad57d628235c3b82154d239373c32` | `182ad57d628235c3b82154d239373c32` |
| `m_aclk` top-200 list md5 | `e63f021d513eb1e542d0f22128dddb64` | `e63f021d513eb1e542d0f22128dddb64` |
| of the 200, in the FIFO/streamer cone | **92** | **92** |

**The two lists are identical line for line -- same slack, same logic levels,
same startpoint, same endpoint -- on BOTH clocks, asserted by checksum rather
than by eye.** And **92 of the 200 worst core-domain paths run straight through
the logic this lever rewrites**:

```
9.592  6  dut/streamer/gen_w[10].port_p/g_dc.fifo/ocnt_reg[0]/C
       -> dut/core/tr_reg[0][0]/DSP_A_B_DATA_INST/CEA2
```

That is the FIFO's occupancy counter `ocnt` driving the MAC array's DSP clock
enables -- exactly the cone `after_e = ocnt + inflight - pop` feeds. So this is
no longer "the worst path is elsewhere, therefore we cannot see it". **The
lever's own cone is 92 of the 200 most critical core paths in the unit, and not
one of them moved.**

Combined with the fast arm's WNS of 9.088, which by definition means **no path
anywhere in the unit has less than 9.088 ns of slack on a 13.333 ns clock**:
**`FAST_POP` has no measurable timing cost at this scope.**

**What this still is not**: out of context, synthesis stage,
`-flatten_hierarchy none`, no placement, no routing. In the card those 27 read
enables are physically spread across a die at 99.81% CLB occupancy. This
retires the question AIDLE raised at OOC level and leaves the routed one open.

### 3.2 The generics teeth -- without this arm, section 3.1 is not a result

TRACK AIDLE's recorded trap: *"three OOC draws agreeing to the digit is
indistinguishable from a harness that ignores its generics."* `FAST_POP` is
EXPECTED to move almost nothing, so `apop_ctrl` and `apop_fast` agreeing at
+1 LUT is only informative if this harness is known to respond to generics at
all. `apop_teeth` halves the port count (`NPORTS_W` 24 -> 12, and `ROWS_IF`
48 -> 24 with it, because `weight_streamer.vhd:175` asserts
`NPORTS_W*AXI_DW = ROWS_IF*BLK*4`):

| | apop_ctrl | apop_teeth | delta |
|---|---:|---:|---:|
| CLB LUTs | 136,919 | 69,943 | **-48.9%** |
| CLB Registers | 64,031 | 33,796 | -47.2% |
| DSP48E2 | 1,585 | 793 | **-50.0%** |
| Block RAM Tile | 192.5 | 144.5 | -24.9% |
| CARRY8 | 6,360 | 3,292 | -48.2% |

**The harness moves by half when a generic is halved.** So the +1 LUT in
section 3.1 is a measurement and not a silence.

### 3.3 `B_RECUR_LANES` 4 -> 16 -- subsystem B, `gdn_block`

TRACK BRECUR measured this lever on `gdn_recur_pipe` and listed "LUT in context
rather than OOC" as its first open item. `gdn_block` is that context -- the
enclosing unit, with the conv, SiLU, L2-norm, scalar and emit chain present.
Generics from `rtl/fk33_llama_top.vhd:5654` resolved against the card's `B_*`
values. **Passing them is load-bearing: `gdn_block`'s own default
`RECUR_LANES` is 32 ("section 3.1's assumption") while the card passes 4**, so
a default-reliant draw would have measured an eight-times wider recurrence than
ships, in both arms.

| | brecur4 | brecur16 | delta |
|---|---:|---:|---:|
| CLB LUTs | 56,771 | 64,513 | **+7,742** |
| LUT as Logic | 46,612 | 54,324 | +7,712 |
| LUT as Memory | 10,159 | 10,189 | +30 |
| CLB Registers | 33,719 | 41,773 | **+8,054** |
| CARRY8 | 1,525 | 2,113 | +588 |
| F7 / F8 Muxes | 4,355 / 816 | 4,593 / 831 | +238 / +15 |
| Block RAM Tile | 22 | 31 | **+9** |
| RAMB36E2 / RAMB18E2 | 15 / 14 | 24 / 14 | +9 / 0 |
| URAM288 | 0 | 0 | 0 |
| DSP48E2 | 141 | 189 | **+48** |
| `clk` intra WNS (13.333 ns) | 8.816 | **8.816** | **0.000** |
| timed endpoints | 167,075 | 184,290 | +17,215 |

**THE UNIT-LEVEL DELTA TRANSFERS ALMOST EXACTLY FROM `gdn_recur_pipe` TO
`gdn_block`, AND THAT IS WORTH RECORDING BECAUSE THE DEFAULT EXPECTATION HERE
IS THAT IT WOULD NOT:**

| | BRECUR, `gdn_recur_pipe` | LEVERCOST, `gdn_block` | agreement |
|---|---:|---:|---|
| DSP | +48 | **+48** | **exact** |
| BRAM tiles | +9 | **+9** | **exact** |
| LUT | +7,865 | **+7,742** | **1.6%** |

This project's standing rule is that the parts do not sum across synthesis
contexts -- `gdn_block` alone reports 22 BRAM tiles while a composed run
attributed 5,472 elsewhere. **This is that rule being TESTED across one level
of nesting and coming out favourably**, which is a much weaker claim than "it
transfers to the card" and must not be read as one. What it does support: the
+7,865 LUT figure the dispatcher has been carrying is not an artefact of
drawing the pipe in isolation.

**Timing is unchanged at 8.816 ns of 13.333, with 20 logic levels in both
arms** -- and this is a single-clock unit, so unlike section 3.1 there is no
CDC artefact in the way and `-to [get_clocks clk]` returns the genuine
intra-domain worst path. The same caveat still applies in the weaker form: an
identical WNS means the lever did not create a NEW worst path, not that nothing
in the recurrence got slower.

**`[Synth 8-7186]` = 101 in BOTH arms, AND 101 IS THE MESSAGE LIMIT, NOT A
CENSUS.** The 101st line is
`INFO: [Common 17-14] Message 'Synth 8-7186' appears 100 times and further
instances of the messages will be disabled.` The warnings name
`qbuf[0][0]`..`qbuf[6][3]` at `rtl/gdn_block.vhd:396`, claiming
`ram_style = "distributed"` was ignored. The parent-level census shows **806
LUTRAM cells at exactly the level where `qbuf` is declared** (of 1,291 in the
unit: `.` 806, `u_recur` 447, `u_exp` 20, `u_emit/u_y` 10, `u_emit/u_head` 8).

**SETTLED BY A RE-DRAW, AND THE MESSAGE IS FLATLY WRONG.** `brecur4` was drawn
again with the message limit raised to 100,000 and a named-object census
(`LC_NAMED=qbuf`, tallying every cell matching `*qbuf*` by `REF_NAME`):

```
LEVERCOST_NAMED stage=opt tag=brecur4 pat=qbuf total=5251
  RAMD32=4290  RAMS32=614  RAM32M16=306  RAM32M=1
  LUT6=37  MUXF7=2  MUXF8=1
```

**`qbuf` is 5,211 distributed-RAM primitives and ZERO flip-flops**, against
**1,024** warnings (the true count, see below) insisting `ram_style =
"distributed"` was *ignored* and the object *"is not inferred as ram due to
incorrect usage"*. CLAUDE.md's cheap discriminator -- *"if a run reports
`RAM=0 FF=1024` you have registers, and `RAM=4352 FF=0` you have distributed
RAM, whatever the log said"* -- returns `RAM=5,211 FF=0`.

**This is the recorded `[Synth 8-7186]` failure reproduced with fresh
evidence**: the log denies a resource the design comprehensively did get.
The warning can be ignored for `gdn_block`, and `B_RECUR_LANES=16` does not
change that -- both arms emit it identically.

**Two further traps fell out of this re-draw, and both are this track's own.**

1. **The true warning count is 1,024, not 101 and not 1,025.** With the limit
   raised, `grep -c 'Synth 8-7186'` returns **1,025** -- and the extra match is
   **line 36 of the log, which is this script's own
   `foreach mid {{Synth 8-7186} {Synth 8-10226}}` echoed into it.**
   `grep -c '^WARNING: \[Synth 8-7186\]'` returns **1,024**. The same grep for
   `8-10226` returns **1 unanchored and 0 anchored** -- a message that never
   occurred, counted once, because the script that counts it names it.
   **This is the project's recorded "haystack contains your own needle" trap in
   a fourth place**, after `pgrep -f`, a `/proc` loop matching its own script
   text, and a log grep matching the embedded source. Anchor the pattern to
   `^WARNING: \[` and the count is a census again.

2. **The inherited LUTRAM census filter was under-counting by 4x, silently.**
   `RAM32*`/`RAM64*`/... match `RAM32M` and `RAM32M16` but **not `RAMD32`,
   `RAMS32`, `RAMD64E` or `RAMS64E`** -- the UltraScale+ single- and dual-port
   distributed-RAM primitives, which here are **94% of the array** (4,904 of
   5,211 cells missed). The `lutram` figures quoted from the first five arms
   therefore see roughly a quarter of the objects. **The area tables in this
   file are unaffected**, because they take LUT-as-Memory from
   `report_utilization` (which is correct) and use the census only for the
   1:1 primitives; but a reader must not take a `lutram=` figure out of the
   raw `result_*.csv` of batch 1. The filter now includes `RAMD*` and `RAMS*`.

`[Synth 8-10226]` = 0 in every arm, census `URAM288` = 0, reported URAM = 0 --
consistent, nothing requested, nothing refused.

### 3.4 `SWEEP_PIPE` -- subsystem C, `attn_block`

Drawn from **HEAD's committed copy** of `rtl/attn_block.vhd` (`bc4156f`,
md5 `b89ea210eb4070edab940211b74878f5`, checked on the BC-250 before the run),
**not the working tree**, which TRACK CSWEEP reopened after committing.
Generics from `rtl/fk33_llama_top.vhd:7247` resolved against `QWEN35_9B`.
Passing them matters: `attn_block`'s own `POS_W` default is 16 and the card
passes 17.

| | cswp_off | cswp_on | delta |
|---|---:|---:|---:|
| CLB LUTs | 86,660 | 86,724 | **+64** |
| LUT as Logic | 86,551 | 86,615 | +64 |
| LUT as Memory | 109 | 109 | 0 |
| CLB Registers | 101,004 | 101,027 | **+23** |
| CARRY8 | 2,741 | 2,741 | **0** |
| F7 / F8 Muxes | 16,350 / 2,992 | 16,351 / 2,992 | +1 / 0 |
| Block RAM Tile | 11 | 11 | **0** |
| RAMB36E2 / RAMB18E2 | 3 / 16 | 3 / 16 | 0 / 0 |
| URAM288 | 0 | 0 | 0 |
| DSP48E2 | 298 | 298 | **0** |
| `clk` intra WNS (13.333 ns) | 9.158 | **9.158** | **0.000** |
| timed endpoints | 249,756 | 249,793 | +37 |
| census LUT cells | 94,933 | 95,012 | +79 |

**`SWEEP_PIPE` costs +64 LUT and EXACTLY +23 flip-flops.**

TRACK CSWEEP's own pre-registered ESTIMATE was *"DERIVED ~23 FF plus a 4-bit
mux"*. **The flip-flop count is 23, exactly.** A derivation made before any
synthesis, matching the measurement to the flip-flop, is the strongest evidence
in this file that the lever is understood rather than merely working.

The worst core path is identical in both arms -- `u_arr/p_reg_reg[117]/
DSP_OUTPUT_INST/CLK` -> `u_arr/er_r_reg/D`, **18 logic levels (CARRY8=8 LUT2=1
LUT3=3 LUT4=3 LUT5=2 LUT6=1), 4.125 ns datapath** -- i.e. it is in the MAC
array, not in the sweep FSM the lever rewrites.

**The distribution was checked too**, from the two post-opt checkpoints
(~2 min each): the **top 200 intra-domain paths are md5-identical**
(`6f225dbac2eb5115a758b3c56b49c657` for both arms), spanning **9.158 to
9.540 ns**. Netlist sizes differ as expected: 220,999 cells off, 221,102 on.

**This is a weaker result than `FAST_POP`'s and the difference matters.** For
`FAST_POP`, 92 of the 200 worst paths ran through the lever's own cone, so
their being unchanged is direct evidence about the modified logic. Here **none
of the top 200 is in the sweep FSM** -- they are the MAC array, the V-header
and reference registers. So what is established for `SWEEP_PIPE` is: it adds
64 LUT and 23 FF, it creates no new critical path, and **every path it does
create or change has more than 9.540 ns of slack on a 13.333 ns period** (that
is what falling outside the 200-path window means). That is a bound, not a
measurement of the new logic -- but it is a bound with 71.6% of the period in
hand.

`[Synth 8-10226]` = 0 and `[Synth 8-7186]` = 0 in both arms; census URAM 0,
reported URAM 0. Nothing to reconcile.

**Both arms ended `rc=1` on a harness bug, AFTER every measurement above was
computed and written.** The intra-clock parser passed the report table's
`-----` separator row to `get_clocks`, which read the leading dashes as an
option (`ERROR: [Common 17-170] Unknown option '-----'`) and took the run down
at the very last step. `synth_design`, `opt_design`, both censuses,
`report_utilization`, `report_ram_utilization`, `report_timing_summary` and
the post-opt checkpoint had all already succeeded, so **the numbers above are
read from the arms' own report files and are not affected**; what was lost is
the tidy CSV and the top-50 path dump. Recorded in section 7 rather than
quietly re-run, because "a completion signal that also fires on failure is not
a completion signal" has a mirror image: **a failure signal after the work is
done does not invalidate the work, and treating it as though it did would have
cost two 735 s draws.**

---

## 4. Census versus `report_utilization`, reconciled

**They do not disagree. They count different things, and once that is stated
the two reconcile EXACTLY.** Worked through on `apop_ctrl`, whose figures are
representative of every arm:

| primitive | census (`get_cells`, CELLS) | `report_utilization` (SITES) | verdict |
|---|---:|---:|---|
| DSP48E2 | 1,585 | 1,585 | **exact** |
| RAMB36E2 | 192 | 192 | **exact** |
| RAMB18E2 | 1 | 1 | **exact** |
| URAM288 | 0 | 0 | **exact** |
| SRL* | 798 | 798 (LUT as Shift Register) | **exact** |
| FD* | 64,031 | 64,031 (CLB Registers) | **exact** |
| distributed RAM | 569 cells | 4,440 sites (LUT as Distributed RAM) | cells vs sites |
| LUT* | 139,426 cells | 131,681 sites (LUT as Logic) | cells vs sites |

The LUT row closes to the digit:

```
  139,426  LUT* cells (census: LUT1 2,835 + LUT2 31,699 + LUT3 14,386
                       + LUT4 4,778 + LUT5 13,950 + LUT6 71,778)
-   7,745  cells combined into shared LUT6 sites
= 131,681  LUT as Logic          <- report_utilization
+   5,238  LUT as Memory (4,440 distributed RAM from 569 RAM cells + 798 SRL)
= 136,919  CLB LUTs*             <- report_utilization, asterisk = "adjusted
                                    to account for LUT combining"
```

So the project's rule that **the census wins wherever they disagree** applies
to the primitives with a 1:1 cell-to-site mapping -- DSP, BRAM, URAM, FF, SRL
-- and **there they agree exactly in every arm**. For LUTs the two numbers are
both correct and answer different questions: the census says how many LUT cells
the netlist holds, `report_utilization` says how many LUT sites the device will
spend. **The site count is the one that competes for CLBs**, so it is the one
carried into section 2's arithmetic; the cell count is the one that makes a
delta attributable, which is why both are recorded per arm.

### The two messages that have lied here

| arm | `[Synth 8-10226]` (URAM refused) | `[Synth 8-7186]` (ram_style ignored) | census URAM288 | reported URAM |
|---|---:|---:|---:|---:|
| apop_ctrl | 0 | 0 | 0 | 0 |

**Neither message appears in these draws at all**, so there is nothing to
reconcile against: no URAM was requested and none was refused, and the census
agrees with the report at zero. That is a clean negative and is recorded as one
rather than being left unstated. (Had either count come back as exactly **100**,
that would have been Vivado's message LIMIT and not a census.)

### The 9x DSP trap, reproduced and avoided in this very run

The log's own `Report Cell Usage` states it outright:

```
DSP48E2 => DSP48E2 (DSP_ALU, DSP_A_B_DATA, DSP_C_DATA, DSP_MULTIPLIER,
                    DSP_M_DATA, DSP_OUTPUT, DSP_PREADD, DSP_PREADD_DATA):
                    1585 instances
```

`REF_NAME =~ DSP*` would have counted all nine and returned **14,265** against
2,880 DSP48E2 on the part -- a false "does not fit" on the resource this design
is nearest to exhausting. `REF_NAME == DSP48E2` returns **1,585**, matching
`report_utilization` exactly. The harness uses the exact form.

---

## 5. Timing and cost summary, all arms

**Every WNS here is an ESTIMATE as a card number.** All are post-`opt_design`,
out of context, unplaced and unrouted. CLAUDE.md records `phys_opt` -- a much
later stage -- over-promising by 0.428 and 0.633 ns on this part and
**inverting the verdict between two runs**, and records that nothing before
`route_design` orders two runs correctly. These figures order the ARMS against
each other and say nothing about a routed card.

| arm | target | LUT | FF | DSP | BRAM | intra WNS | worst path |
|---|---|---:|---:|---:|---:|---:|---|
| apop_ctrl | `matvec_int4_desc_axi` | 136,919 | 64,031 | 1,585 | 192.5 | 9.088 / 1.103 | `dw_reg[10][56]` -> `err_code_reg[0]/CE`, 16 levels |
| apop_fast | `matvec_int4_desc_axi` | 136,920 | 64,031 | 1,585 | 192.5 | 9.088 / 1.103 | identical |
| apop_teeth | `matvec_int4_desc_axi` | 69,943 | 33,796 | 793 | 144.5 | 9.088 / 1.013 | (control) |
| brecur4 | `gdn_block` | 56,771 | 33,719 | 141 | 22 | 8.816 | 20 levels |
| brecur16 | `gdn_block` | 64,513 | 41,773 | 189 | 31 | 8.816 | 20 levels |
| cswp_off | `attn_block` | 86,660 | 101,004 | 298 | 11 | 9.158 | `u_arr/p_reg_reg[117]/DSP_OUTPUT_INST` -> `u_arr/er_r_reg/D`, 18 levels |
| cswp_on | `attn_block` | 86,724 | 101,027 | 298 | 11 | 9.158 | identical |

(Two WNS figures where the unit has two clocks: `s_axi_aclk` at 13.333 ns /
`m_aclk` at 4.000 ns.)

**Not one lever moved its unit's WNS.** For `FAST_POP` that is backed by the
full path distribution (section 3.1). For the other two it is the weaker
statement: **no NEW worst path was created.** In all three the worst path is in
arithmetic the lever does not touch -- the MAC array for C, a descriptor/error
path for A.

### Memory per run, and which figures are honest

| arm | cgroup `memory.peak` | at cap? | max `memory.swap.current` | wall |
|---|---:|---|---:|---:|
| apop_ctrl | 8,195 MB | **YES** | 1,024 MB (last sample) | 713 s |
| apop_fast | 8,194 MB | **YES** | 497 MB (last sample) | 725 s |
| apop_teeth | 8,195 MB | **YES** | 801 MB (last sample) | 427 s |
| brecur4 | 8,194 MB | **YES** | 919 MB (last sample) | 374 s |
| brecur16 | 8,195 MB | **YES** | 963 MB (last sample) | 582 s |
| cswp_off | 8,195 MB | **YES** | **5,253 MB (max-tracked)** | 735 s |
| cswp_on | 8,196 MB | **YES** | **5,197 MB (max-tracked)** | 735 s |
| apop_ctrl (batch 3) | 8,194 MB | **YES** | **3,943 MB (max-tracked)** | 735 s |
| apop_fast (batch 3) | 8,195 MB | **YES** | **3,950 MB (max-tracked)** | 740 s |

**EVERY ARM HIT THE 8G CAP, so not one `memory.peak` above is an appetite** --
they are all the throttle, exactly as CLAUDE.md requires such a figure to be
read. The swap column is the one that carries information, and **the first five
rows are LAST SAMPLES rather than maxima** because `memory.swap.current` is a
level with no `memory.swap.peak` counterpart; the runner was fixed to track the
maximum partway through, which is why the later rows are 4-5x larger. **Do not
compare a "last sample" row against a "max-tracked" row.**

Taking only the honest rows: `attn_block` reached **8.0 GB resident + 5.25 GB
swap = about 13.2 GiB**, and `matvec_int4_desc_axi` about **11.9 GiB**. Both
would run unthrottled on the BC-250's 15.2 GB, and an 8G cap costs wall time
for no safety benefit here. **A 10G cap is the better setting for these units**
-- still well inside the box, and the documented 11G ceiling for a pcieep build
there is the limit not to cross.

Vivado's own `Memory (MB): peak` says **4,050 MB** for `matvec_int4_desc_axi`
and **5,029 MB** for `attn_block`, and its `free physical` never fell below
1,695 MB. The gap between that and the cgroup figure is page cache from reading
115 VHDL files and writing reports, which reclaims cheaply -- **the tool was
never memory-starved, and the `high` throttle events overstate the pressure.**

---

## 6. Recommendation for build 11

### 6.1 The prize, so the risk has something to be weighed against

DERIVED from the owning tracks' measured cycle counts. The striped token is
**30,123,856 cycles** (back-derived from AIDLE's `2,593,664 = 8.61%`; at 75 MHz
that is 0.4017 s/token against the 0.406 s/token recorded on silicon, a 1.1%
agreement, which is the cross-check that the baseline is the right one).

| lever | cycles/token | % of token | area cost | evidence class |
|---|---:|---:|---|---|
| `FAST_POP` | 2,593,664 | 8.61% | **+1 LUT, 0 FF, 0 DSP, 0 BRAM** | **MEASURED here, in context** |
| `B_RECUR_LANES=16` | 2,362,128 | 7.84% | **+7,742 LUT, +8,054 FF, +48 DSP, +9 BRAM** | **MEASURED here, in `gdn_block`** |
| `A_DRAIN_WIDE` | 1,248,576 | 4.14% | +250..400 LUT, +156 FF | **ESTIMATE only, unmeasurable OOC** |
| `SWEEP_PIPE` | slope -22.5% | +3.8% at 2k ctx, +24.5% at 64k | **+64 LUT, +23 FF, 0 DSP, 0 BRAM** | **MEASURED here, in `attn_block`** |

**Area cost per lever, as a fraction of the 76,585 free LUT sites:**

| lever | LUT | % of free LUT sites | FF | % of free FF |
|---|---:|---:|---:|---:|
| `FAST_POP` | +1 | 0.0013% | 0 | 0% |
| `SWEEP_PIPE` | +64 | 0.084% | +23 | 0.004% |
| `A_DRAIN_WIDE` (ESTIMATE) | +250..400 | 0.33..0.52% | +156 | 0.027% |
| `B_RECUR_LANES=16` | +7,742 | **10.1%** | +8,054 | 1.4% |

**Three of the four levers are, together, +315 to +465 LUT -- under 0.61% of
the free LUT sites. One of them is 10.1% on its own.** That is the whole
shape of the decision, and it was not visible before this track: two of those
three had no measured area cost at all this morning.

All three constant levers together: **6,204,368 cycles, 20.60% of the token**
-> 23,919,488 cycles, **0.3189 s/token, 3.14 tok/s from 2.49, a 1.26x**.
**That sum is DERIVED and additive-by-assumption**: the three live in different
subsystems and mostly different phases, which makes additivity plausible and
**not measured**. Do not promise 1.26x.

### 6.2 The ranked answer

**1. `FAST_POP`, alone, in build 11.**

* It is the **largest single win** (8.61%) and the **only one measured to be
  free**: +1 LUT of 76,585 free LUT sites, 0 FF, 0 DSP, 0 BRAM, at the card's
  own 27-lane geometry with the consumer cone closed.
* Its one stated risk was in-context core-clock timing. This track moves that
  from unmeasured to **bounded**: the unit's critical path does not change and
  the FIFO cone retains at least 9.088 ns of slack on 13.333 ns (section 3.1).
* It is **one line**: `hw/fk33/gen_fk33_engine.py:113`,
  `FAST_POP_DEFAULT = False -> True`, regenerate, `git diff` the generated
  `hw/fk33/rtl/fk33_engine.vhd` and confirm it contains that change and nothing
  else.
* **And it changes ONE thing, which is the real argument.** The card routes at
  **+0.061 ns**. Composing several levers into a build with that much slack
  produces a result nobody can attribute -- this repository has already spent a
  write-up and three documents on a "one-variable" comparison whose two runs
  differed in five things. A single-variable build 11 makes its own WNS delta
  readable.

**2. `B_RECUR_LANES=16`, LAST, and alone in its own build.**

It is the second-largest win (7.84%) and **the only lever with a large area
demand -- by two orders of magnitude**. MEASURED here on `gdn_block`:
+7,742 LUT and **+8,054 FF**. DERIVED against section 2: that takes packing
density from 6.6194 to **6.7496 LUT per CLB**, a 2.0% densification, with
**zero** new CLBs available beyond the 106 free. Its DSP and BRAM costs are
comfortable (+48 of 793 free, +9 of 105), and its FF cost is nothing in
percentage terms (+8,054 of 570,379 free) -- **but flip-flops are packed into
CLB slices too, and at 99.81% CLB occupancy the FF demand is not free even
though the FF column says 35%.**

**The risk is congestion and it is real**: the build already uses
`Congestion_SpreadLogic_high`, a strategy whose purpose is to spread logic, and
this lever densifies against it. It is one line in
`hw/fk33/gen_fk33_card.py` -- `"--generic", "B_RECUR_LANES=16",` -- which is
exactly what makes it tempting to bundle. **Do not.** It is the one lever whose
failure mode is a build that does not close, and if it is bundled with the
cheap ones nobody will know which caused it.

**1b. `SWEEP_PIPE` -- as soon as it is plumbed, and it belongs beside
`FAST_POP`, not behind `B_RECUR_LANES`.**

This track's measurement moves it: **+64 LUT and +23 FF, 0 DSP, 0 BRAM,
`clk` WNS unchanged**. Together with `FAST_POP` that is **+65 LUT, 0.085% of
the free LUT sites** and two different BD cells (`fk33_engine` and
`fk33_card`), so a WNS regression would still be attributable by which cell the
failing path lands in. Its win is the one that grows with context: **+3.8%
tok/s at 2,048 but +24.5% at 65,536**, where the card is slowest.

**It is blocked on code, not on area** (section 1.1): the generic stops at
`attn_block` and must be carried through `rtl/llama_top.vhd`,
`tools/gen_cardtop.py` and `hw/fk33/gen_fk33_card.py` first. **If build 11 is
imminent, ship `FAST_POP` alone and take `SWEEP_PIPE` in build 12 -- the
plumbing is a reviewable RTL change with its own gate run, not a build flag.**
Do not add `"--generic", "SWEEP_PIPE=true",` to `gen_fk33_card.py` ahead of
that change: it would be accepted and silently dropped.

**3. `A_DRAIN_WIDE` -- do not compose it yet, and the reason is not area.**

Its cost is **ESTIMATE in every respect and cannot be made MEASURED by any OOC
draw that exists** (section 1.2). Its mux sits between a register and a BRAM
write port, which is the kind of path a 99.81%-CLB placement punishes. Adding
an unmeasured lever to a build at +0.061 ns is the one combination that can
fail without anybody being able to say which lever did it. It is cheap to make
measurable -- see section 8 for the experiment.

**4. `SWEEP_PIPE` -- it is not a cost question, it is a plumbing question.**

`attn_block` now carries the generic at HEAD (`bc4156f`), but **nothing between
it and the card top does** (section 1.1). Adding
`"--generic", "SWEEP_PIPE=true",` to `hw/fk33/gen_fk33_card.py` today would be
**silently ignored**: `gen_fk33_card.py`'s own comment records that
*"`tools/gen_bd_wrapper.py` emits generics VERBATIM and checks nothing against
the entity"*. That is a lever that looks enabled in the build script and is not
in the bitstream -- the worst available failure mode, and exactly the class this
project keeps recording. **Plumb it through `rtl/llama_top.vhd` and
`tools/gen_cardtop.py` first, then measure, then compose.**

### 6.3 What only a routed build can settle

* Whether **any** of these fits at 99.81% CLB with +0.061 ns. Nothing before
  `route_design` orders two runs correctly on this part -- this project has
  measured `phys_opt` over-promising by 0.428 and 0.633 ns and **inverting the
  verdict**, and a synthesis-only harness (which every number in this file is)
  is worse than that.
* The in-context core-clock cost of `FAST_POP`'s 27-way gather and scatter
  **after placement and routing**, where the 27 read enables are physically
  spread across the die rather than notionally connected.
* `A_DRAIN_WIDE`'s cost at all.
* Whether the three constant levers are additive in cycles on silicon.

---

## 7. Measurement traps hit, including this track's own

**1. A WAITER WRITTEN FOR BASH, RUN THROUGH FISH, REPORTED SUCCESS INSTANTLY.**
`ssh labuser@... "until grep -q ...; do sleep 20; done; echo REMOTE_RUN_FINISHED"`
came back in under a second with exit code 0 and the line
`REMOTE_RUN_FINISHED` -- having printed `fish: Unknown command: until`,
`fish: Unknown command: do`, `fish: Unknown command: done` first. The BC-250's
login shell is fish, so the loop never existed and the `echo` ran on its own.
**A waiter that cannot express its loop still prints its success line.** This is
the project's recorded "the harness is reporting a fact about the harness"
class in a new place, and it was one glance away from being read as "all five
arms are done" while one arm had finished. CLAUDE.md already says to wrap
remote commands in `bash -c` or `ssh ... 'bash -s' < script`; the heredoc form
is the one used everywhere in this track after that.

**2. A GLOB OVER `rtl/*.vhd` DIED ON A FILE THE TARGET CANNOT REACH, AND THE
PER-FILE `catch` DID NOT PROTECT IT.** The first run of `apop_ctrl` failed in
35 s with 7 errors, all `[Synth 8-36] 'b_const_hbm' is not declared` from
`rtl/ooc_gdnadapt_top.vhd` -- another track's OOC harness top, unreachable from
`matvec_int4_desc_axi`. **`read_vhdl` accepted the file without complaint; the
failure surfaced at `synth_design`**, so the read-time `catch` reported a clean
115-file read moments before the run died. The fix excludes `rtl/ooc_*_top.vhd`
(five files) as harness tops that are never part of a unit's closure.

**This is a real breakage at HEAD, not a symptom of a dirty tree.**
`rtl/ooc_gdnadapt_top.vhd` is unmodified at `07184e5` and uses `B_CONST_HBM` at
lines 377, 604, 782, 843, 869 and 903 while declaring no such generic -- it is
stale with respect to the 2026-09-18 B-constants work. **Nothing schedules it,
which is why it has been broken invisibly.**

**3. TWO `create_clock`s WITHOUT `set_clock_groups` MAKE EVERY REPORTED PATH A
CDC CROSSING.** `apop_ctrl`'s first draw returned worst `s_axi_aclk`
slack **0.939 ns** -- with a **data path delay of 0.376 ns and ONE logic
level**, from `dfetch/g_dc.fsm/st_reg[1]/C` to `dfetch/g_dc.run_s1_reg/D`, the
first stage of a two-flop synchroniser. **A 0.376 ns path cannot have 0.939 ns
of slack on a 13.333 ns period**, and that arithmetic is the whole tell: the
requirement was never 13.333, because Vivado times two unrelated clocks against
their common period. Every "worst path per clock" in that draw was an artefact
of the two numbers chosen, and the intra-domain core-clock path -- the only path
a core-domain lever can move -- was never computed at all.

This is TRACK AIDLE's recorded trap 7 one level deeper. There, the right
domain was merely not *quoted*; here it was not *calculated*. **The discriminator
is cheap and should be standard: divide the data path delay by the slack, and
if a sub-nanosecond path is reported as nearly critical on a 13 ns clock, the
constraint is wrong, not the design.**

**4. FOUR MEMORY FIGURES FOR ONE JOB, DIFFERING BY 2.5x, ALL "CORRECT".**
`apop_ctrl` simultaneously reported:

| figure | value | what it actually means |
|---|---:|---|
| Vivado's own `Memory (MB): peak` | ~4,050 MB | the tool's heap accounting |
| cgroup `memory.peak` | 8,195 MB | resident INCLUDING page cache -- **and it is the 8G cap** |
| cgroup `memory.swap.current` | 1,024 MB | a **level at one instant**, not a peak |
| `/proc/PID/exe` RSS summed | 10.02 GB | parent + forked workers, **double-counting shared pages** |

The `at_cap=YES` flag fired correctly, so `memory.peak` here is the throttle and
not the appetite, exactly as CLAUDE.md requires it to be read. But two further
things were learned:

* **`memory.swap.current` has no `memory.swap.peak` counterpart**, so a sampler
  that merely reads it keeps whatever was in swap at the last poll.
  `apop_ctrl` recorded **1,024 MB** this way while `apop_fast` was observed
  MID-RUN at **3,891 MB** -- an understatement of nearly 3 GB, silently. The
  runner now maxes it. **A level sampled once is not a peak, and the two look
  identical in a results file.**
* **The RSS sum is the most misleading of the four.** CLAUDE.md warns against
  *counting* Vivado processes because the tool forks parallel-synthesis workers
  that inherit the parent's argv; summing their `VmRSS` inherits the same
  problem, because those workers share most of their pages with the parent.
  10.02 GB for a job whose own accounting says 4.1 GB is that double count.

**The job was never actually memory-starved**: Vivado's log reports
`free physical` never below 1,695 MB and mostly above 8,200 MB. The cap was
reached on page cache from reading 115 VHDL files and writing reports, which
reclaims cheaply. **An 8G cap is not tight for this draw**, and the `high 1975`
throttle events overstate the pressure.

**5. A CONSTRAINT BUG THAT RUNS AFTER ALL THE EXPENSIVE WORK COST FOUR DRAWS,
AND THE FIX FOR THE FIRST ONE CAUSED THE SECOND.** Two arms died at
`ERROR: [Common 17-170] Unknown option '-----'` -- the intra-clock parser
handing the report table's separator row to `get_clocks`, where `-quiet`
suppresses "no matching object" but **not** a malformed option. The obvious
repair, `get_clocks -quiet -- $nm`, failed **identically** two arms later
(`Unknown option '--'`) because `get_clocks` does not accept `--` either. A
token that could be read as a switch must be **rejected before the call**, not
passed to it defensively.

Both times `synth_design`, `opt_design`, both censuses, every `report_*` and
the post-opt checkpoint had already succeeded, so **no measurement was lost --
only the CSV and the path dump.** That is the mirror image of this project's
"a completion signal that also fires on failure is not a completion signal":
**a failure signal after the work is done does not invalidate the work.**
Treating `rc=1` as "re-run it" would have cost four more 735 s draws; reading
the arms' own report files cost nothing.

**What actually made this cheap was `write_checkpoint`.** Re-opening the two
post-opt DCPs and re-applying the constraints took **~2 minutes per netlist**
against ~12 minutes to re-synthesise
(`sim/ooc_levercost_timing.tcl`). A constraint mistake should cost a
re-analysis, not a re-synthesis, and that is only true if the netlist was
saved. **Save it.**

---

## 8. Open, NOT determined

* **`FAST_POP`'s ROUTED cost.** Closed at OOC level (section 3.1: top-200 path
  lists md5-identical on both clocks, 92 of them in the lever's own cone). What
  remains is the card, where those 27 read enables are physically spread across
  a die at 99.81% CLB occupancy. **Only build 11 answers it**, and the way to
  read the answer is the CORE-clock row of the timing summary, not the global
  WNS -- which lives in the AXI domain and will not move.

* **`A_DRAIN_WIDE` has never been synthesised in any form, and the experiment
  that would fix that is designed but not run.** Not "no lane was free" --
  there is no entity. The design:

  > Draw `fk33_llama_top` OOC with `-flatten_hierarchy none` at the card's
  > generics **except** `C_MAXPOS` and `C_CTXLEN` left at their defaults of 4,
  > A/B arms as `ooc_c_in_card.tcl` sets them, `A_DRAIN_WIDE` false then true.
  > **The point is that the lever's width does not depend on the model shape**:
  > `LANES : positive := 8` (`:244`) is a generic the card leaves at default,
  > `A_DW_GRP = minimum(LANES, A_ROWS_IF) = 8` (`:1347`), and the group-write
  > mux is `LANES*MANT_W = 128` bits at every shape. So a draw with C's cache
  > shrunk measures the SAME mux, and the A/B delta is the lever's real cost
  > even though neither absolute is the card's.

  **Its risk must be stated with it**: twelve card-top attempts on two machines
  have cleared RTL elaboration zero times, and this is a card-top draw. The
  reason to expect a different outcome is that `C_MAXPOS=4` removes the KV
  cache that `ooc_c_in_card.tcl` was written to isolate -- **a weak reason, and
  it should be time-boxed at one attempt with a hard wall-clock kill**, not
  left to run like the 47 h one.

* **`SWEEP_PIPE`'s own logic is BOUNDED, not measured.** Its top-200 path list
  is md5-identical across arms, but **none of those 200 paths is in the sweep
  FSM**, so the check says only that the new logic keeps > 9.540 ns of slack.
  Closing it properly needs a report filtered THROUGH the sweep cone rather
  than a top-N window -- `report_timing -through` on the `pk_`/`pv_`/`cidx_`
  nets. Both DCPs are on the BC-250, so it is minutes, not a re-synthesis.

* **Whether `fk33_engine` differs from `matvec_int4_desc_axi` for this lever.**
  The cone is closed at `matvec_int4_desc_axi` and `fk33_engine` adds only the
  CDC wrapper and the 28 master ports, so the expectation is "no". Not tested.

* **Every absolute in this file is out of context and at
  `-flatten_hierarchy none`.** `matvec_int4_desc_axi` reports 136,919 LUT here
  against the composed card's 92,134 for `a_eng` -- 49% apart. The deltas are
  the result; the absolutes are not a card budget.

* **Whether the three constant levers' cycle savings are additive.** Section
  6.1 sums them because they are in different subsystems and phases. That is an
  assumption, and the 1.26x it produces should not be quoted as a prediction.

* **The `-flatten_hierarchy none` penalty is not quantified.** It is held
  constant so the deltas survive, but whether a lever that costs +1 LUT with
  boundaries preserved also costs +1 LUT when the shipping flow optimises
  across them is untested. The direction is favourable (cross-boundary
  optimisation can only remove logic) but the magnitude is unknown.
