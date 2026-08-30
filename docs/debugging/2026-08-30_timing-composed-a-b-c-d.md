# TRACK TIMING -- closing timing on the composed A+B+C+D design

Date: 2026-08-30. Board row **N3**. Resumed from TRACK COMPOSE4's PLACED
checkpoint, which survived the 01:25 box hang.

Repo SHA at the start of this track: `c688a2fe47ee27815740cf8e204960859fa6af71`.
The checkpoint being analysed was synthesised from
`56cebe8eb9df6057d6b4f54e03d339a7378e0ed6`
(`hw/fk33/results/compose4_2026-08-29/PINNED_SHA`).

Hardware: **none, at any point.** `open_checkpoint`, `phys_opt_design`,
`route_design` and `report_*` only. Nothing here opened a cable, a target, or
`/dev/xdma*`. The card was unconfigured throughout, the box having been
power-cycled at 01:25.

Tools: Vivado 2023.2, part `xcvu33p-fsvh2104-2L-e`, `core_clk` 5.000 ns,
`hbm_aclk` 4.000 ns. GHDL mcode for the RTL analysis check.

---

## The question, verbatim

> **The 256 failing endpoints, characterised.** How many distinct paths,
> through which modules, and is it one structure replicated or many unrelated
> ones? [...] **Name the modules.** This is the whole job; a fix chosen before
> this is a guess.
>
> **The WHS -0.100 / 279,484 hold-failing endpoints** -- say whether that is
> the normal pre-place artefact it looks like or something real.
>
> **Close it, or produce a measured, specific failure.** [...] **Then take it
> through `place_design`, `phys_opt_design`, `route_design`** and report
> `report_route_status`, `report_timing_summary`, `report_drc`.

---

## The answer, up front

**THE HEADLINE: the binding constraint on the composed design is CLB PACKING
DENSITY, not LUT count, and every budget in circulation for this design is
denominated in the wrong unit.**

    PLACED, not post-synthesis (post-synth is 350,283):
    CLB LUTs   346,971 of 439,680   78.91 %      <- what everyone has been counting
    CLB         54,866 of  54,960   99.83 %      <- what actually runs out

**94 CLBs left on the die.** The design gets **6.32 LUT per CLB** against the
architectural 8, because 90,896 MUXF7/MUXF8 pairs lock 37.5% of its LUTs into
indivisible placement shapes. Add the FK33 shell and the norm gain image and
the honest total needs **121% to 134% of this device's CLBs** while sitting at
95.6% to 105.9% of its LUTs -- **the upper end of which does not fit even by
the LUT count everyone has been using.** The range is the norm gain image and
it is irreducible; see the correction in section 12.

**The WNS is a symptom; the packing is the disease.** All 33,767 setup failures
are net-delay failures caused by a device that is full: over the 20,000 worst,
mean net delay is 4.575 ns against mean logic delay 0.670 ns, and **20,000 of
20,000 are net-dominated.**

**And the fix for the packing is already pre-authorised.** Subsystem A's
IQ4_NL codebook is 97.7%/98.8% of its MUXF7/MUXF8 (TRACK CONGEST), which this
track confirmed independently to within 1.1% on a different design. Lever C
alone is worth **~38,000 LUT and ~+0.5 LUT/CLB of density**, taking the fit from
121% to about **102%** (ESTIMATE). **Lever C alone does not close it. Lever C
plus moving the norm gain image into the 320 idle URAMs reaches ~93% and does.**
Section 7a has the model and its assumptions; section 12a has the judgement.

---

**Beneath the headline there are TWO independent problems, and the brief
describes only the first.**

**1. The 256 endpoints are ONE structure, and it is named.** They are
`c_attn/vref_r`, the KV value-exponent reference array in
`rtl/attn_block.vhd` -- `LAYERS*N_KVH` entries of `EXP_W` bits, and
8 * 4 * 8 = **exactly 256 bits, exactly 256 endpoints**. Every one of the
forty worst paths in the placed design runs from `vref_r_reg` back to
`vref_r_reg`, through **28 logic levels**, and 28 is the deepest level in the
whole composition (the next deepest is 20). The cause is a **serial** min-fold
at `attn_block.vhd`'s SEAM 2 write site that seeds from `vref_r` and chains
`NBLK`=8 compare-selects through it. **FIXED here**, by reassociating the fold
into a balanced tree with `vref_r` folded in LAST. Minimum is associative,
commutative and idempotent on integers, so the change is **BIT-EXACT and
LATENCY-NEUTRAL**: same value, same clock edge, same handshake.

**2. The other 33,511 failing endpoints are not a logic problem, and no amount
of pipelining will touch them.** The 256 was the POST-SYNTHESIS count. The
placed report that was already on disk says **33,767**, and over the 20,000
worst of them:

    mean net delay    4.575 ns
    mean logic delay  0.670 ns
    net delay is      87.2 % of the datapath
    NET-DOMINATED     20,000 of 20,000  (100.0 %)

**The design is at 54,866 of 54,960 CLBs -- 99.83%, with 94 CLBs left on the
die -- and routing congestion level 7.** The endpoints fail because the wires
are long, and the wires are long because the device is full.

**The attribution control settles it. Subsystem A fails 3,779 endpoints.**
`a_eng` is `fk33_engine`, byte-for-byte the entity in the bitstream that closes
timing at 200 MHz on the card today, unchanged. It cannot have acquired a logic
problem by being instantiated next to B, C and D. **Its failures are caused
solely by the placement, which is the same thing causing the other 30,000.**

**So the composed design's binding constraint is AREA, not timing, and every
budget for it that is denominated in LUTs is denominated in the wrong unit.**

**3. The hold numbers: the post-synth one is an artefact, and it is
demonstrable rather than assumed.** See section 4.

---

## 1. What was already on disk, and what the brief got wrong

The brief's central premise was:

> **The encouraging shape: only 256 of 1,027,089 endpoints fail setup.** That
> is 0.025%. This reads as a small number of specific paths, not a systemic
> problem -- **but verify that rather than believing me.**

Verified, and it is wrong -- but honourably so, because the number quoted was
real. It was the **post-SYNTHESIS** summary. TRACK COMPOSE4 had already run
`opt_design`, `place_design` and `phys_opt_design` before the box died, and
`/mnt/storage/compose4/out/timing_c4dev_placed.rpt` survived:

| | WNS(ns) | TNS(ns) | TNS failing EP | WHS(ns) | THS(ns) | THS failing EP |
|---|---|---|---|---|---|---|
| post-synth | -3.259 | -834.395 | **256** | -0.100 | -10278.136 | 279,484 |
| post-place | -3.056 | **-12209.346** | **33,767** | -0.212 | -173.890 | 7,881 |

MEASURED, `report_timing_summary`. Placement multiplied the failing setup
endpoint count by **132** and the total negative slack by **14.6**.

**Why post-synthesis showed only 256.** Post-synthesis there are no placed
cells, so Vivado has no net delays and scores paths on logic depth alone. Only
paths whose LOGIC ALONE exceeds the period can fail. The logic-levels histogram
of the placed failing paths says exactly that, and the agreement is exact:

    TT_LVL  28     256        <- the only paths deep enough to fail with no net delay
    TT_LVL  20      27
    TT_LVL  19      23
    TT_LVL  18    1454
    ...
    TT_LVL   9   10863        <- the mode
    TT_LVL   2     741

**256 paths at 28 logic levels, and 256 failing endpoints post-synthesis.**
That is not a coincidence and it is the whole explanation.

**The lesson, and it is general: a post-synthesis timing report on a design
that will be placed near capacity does not under-report the MAGNITUDE of the
problem, it under-reports its EXTENT by two orders of magnitude.** WNS moved
only 0.203 ns between the two reports while the failing endpoint count moved
132x. Reading WNS alone would have shown nothing wrong.

---

## 2. The 256, characterised and named

MEASURED, `get_timing_paths -delay_type max -max_paths 20000 -nworst 1
-slack_lesser_than 0` on `c4dev_placed.dcp`, script
`hw/fk33/results/timing_2026-08-30/analyze_paths.tcl`, raw output
`analyze_paths.txt`. `-nworst 1` makes each returned path a distinct endpoint,
so the count is endpoints and not path permutations.

Every one of the forty worst:

    TT_WORST  0 slack=-3.056   lvl=28  dly=7.972   logic=2.524   net=5.448
              from c_attn/vref_r_reg[26][7]/C
              to   c_attn/vref_r_reg[16][1]/D
    TT_WORST  1 slack=-3.041   lvl=28  dly=7.953   logic=2.521   net=5.432
              from c_attn/vref_r_reg[26][7]/C
              to   c_attn/vref_r_reg[2][3]/D
    ... (all 40 identical in shape: c_attn/vref_r_reg -> c_attn/vref_r_reg)

**It is one structure, replicated across its own bits, not many unrelated
ones.** `rtl/attn_block.vhd:453`:

    signal vref_r : e8_arr(0 to LAYERS*N_KVH-1)

At the 9B shape `LAYERS`=8, `N_KVH`=4, `EXP_W`=8, so the array is
8 * 4 = 32 entries of 8 bits = **256 flip-flops**. The count of post-synthesis
failing endpoints is 256. The count of level-28 paths is 256. The register is
256 bits. Three independent numbers, one structure.

### The cause, quoted from the RTL

`rtl/attn_block.vhd`, the SEAM 2 write-time fold, as it was:

```vhdl
              -- SEAM 2: the per-head write-time min fold.
              ev := vref_r(lay_r*N_KVH + kvh);
              for b in 0 to NBLK-1 loop
                if e_of(vhdr, b) < ev then ev := e_of(vhdr, b); end if;
              end loop;
              vref_r(lay_r*N_KVH + kvh) <= ev;
```

`NBLK` is `HEAD_DIM/KV_BLOCK` = 256/32 = **8**. `ev` is carried through every
iteration, so the eight compare-selects are a **serial dependency chain**, and
`vref_r` is the SEED of that chain. The path is therefore:

    vref_r_reg  ->  32:1 dynamic read mux   (lay_r*N_KVH + kvh is a runtime index)
                ->  8 serial compare-selects on 8-bit signed
                ->  32-way dynamic write demux
                ->  vref_r_reg

DERIVED: a 32:1 mux on this architecture is ~3 levels (LUT6 as 4:1, twice, then
an F7); eight 8-bit signed compare-selects at ~2.5 levels each is ~20; the
write enable decode is ~2 to 3. Total ~28. **MEASURED: 28.**

### The independent confirmation, from the POST-SYNTHESIS report

The mechanism does not rest on reading the RTL. `timing_c4_synth.rpt`, written
before any of this track's work, names it outright:

    Slack (VIOLATED) :        -3.259ns  (required time - arrival time)
      Source:                 c_attn/kvh_reg[2]/C
      Destination:            c_attn/vref_r_reg[0][0]/D
      Logic Levels:           28  (CARRY8=8 LUT2=1 LUT3=4 LUT4=4 LUT5=3 LUT6=7 MUXF7=1)

**`CARRY8=8`.** Eight carry chains in series, for `NBLK`=8 serial 8-bit signed
compares. The primitive census is the fold, one CARRY8 per iteration, and it is
the strongest single piece of evidence in this document because it was
generated by a different tool invocation, on a different design state, before
the hypothesis existed.

The startpoint differs between the two reports -- post-synthesis it is
`kvh_reg` (the head index, which drives both the read mux and the write decode)
and post-place it is `vref_r_reg` itself. Both traverse the same cone; which
one is worst depends on where the placer put the index register.

DERIVED, what the tree does to that census: eight serial CARRY8 becomes
`ceil(log2(8))` = 3 in the tree plus 1 for the final `vref_r` fold = **4**, and
only ONE of those four is inside the `vref_r -> vref_r` cone.

### And the other 33,511, which are NOT one structure

The same query, aggregated by top-level instance pair. Every failing path is
INTERNAL to one subsystem, which is expected: `compose4_top` deliberately does
not wire the four to each other.

    TT_B1   10378  d_norm -> d_norm
    TT_B1    3954  b_gdn  -> b_gdn
    TT_B1    3779  a_eng  -> a_eng
    TT_B1    1889  c_attn -> c_attn

**All four subsystems fail, including the one that is proven on silicon.**

Aggregated by destination three hierarchy levels deep, over the same 20,000:

    TT_B3    3661  a_eng/eng/dut
    TT_B3    2012  b_gdn/u_emit/u_head
    TT_B3      29  d_norm/gvr.u_rms/ARG__10
    TT_B3      25  d_norm/gvr.u_rms/sq_reg[3]
    TT_B3      19  d_norm/gvr.u_rms/ARG__5
    ...
    TT_B3_DISTINCT 12808

**12,808 distinct destinations for 20,000 endpoints.** After the two coarse
buckets, the long tail is 29 endpoints, then 25, then 19. That is the
signature of a diffuse effect, not of a structure. Compare it with the 256,
which were one register with one name.

### The attribution control, and it is the whole argument

**`a_eng` fails 3,779 setup endpoints.**

`a_eng` is `fk33_engine`, which TRACK COMPOSE4 recorded as "byte-for-byte the
entity in the bitstream on card 1". Subsystem A is proven bit-exact on silicon
against `ref/run9b` over 1,675,264 rows and closes 200 MHz timing in the
shipping routed build. **Its RTL is not touched by this composition.** It
cannot have acquired a logic-depth problem by being instantiated beside B, C
and D.

So its 3,779 failures have exactly one available cause: the placement. And the
placement is the same placement causing the other 30,000. **A control that
fails proves the effect is environmental, and this one fails.**

This is also why the fix in section 3, which is real and worth having, cannot
be the answer to the composed design: it removes 256 endpoints of 33,767.

---

## 3. The fix, and why it is bit-exact and latency-neutral

`rtl/attn_block.vhd` -- **subsystem C, not subsystem A's proven datapath.**
Three edits, all in that one file.

**Minimum over integers is associative, commutative and idempotent.**
Re-bracketing a min-reduction therefore cannot change its value: it is not an
approximation, a reordering tolerance, or a numerical trade. The result is the
same integer, on the same clock edge, for every input. Nothing about the
seam's latency, its handshake, or the three seam rules at the head of
`attn_block.vhd` changes. **Latency-neutral: yes, exactly and by
construction.**

Two changes, and the second is the one that matters:

1. The `NBLK` header exponents reduce as a **balanced tree** -- depth
   `ceil(log2(NBLK))` = 3 instead of 8.
2. **`vref_r` is folded in LAST rather than seeding the chain.** The tree
   depends only on `vhdr`, so the `vref_r -> vref_r` cone shrinks to the read
   multiplexer, ONE compare, and the write. The tree hangs off `vhdr`, which is
   a different startpoint with its own, shorter, path.

```vhdl
              evh := emin_tree(vhdr);
              ev  := vref_r(lay_r*N_KVH + kvh);
              if evh < ev then ev := evh; end if;
              vref_r(lay_r*N_KVH + kvh) <= ev;
```

`emin_tree` pads the array to a power of two by **repeating element 0**. A
minimum is idempotent, so duplicating an element cannot change it, and the
padding keeps every loop bound and every index a **constant expression**. That
last point is load-bearing and is the trap this fix could most easily have
walked into: an index carrying a variable offset synthesises as a
multiplexer, which is the cost being removed, so a "tree" written with a
runtime `half` variable would have reintroduced it.

DERIVED, the new depths:

    vref_r -> vref_r :  32:1 mux (~3) + one compare (~2.5) + write decode (~2.5)  ~=  8
    vhdr   -> vref_r :  tree depth 3 (~7.5) + one compare + write decode          ~= 12

against 28. Both well inside the mode of the histogram.

**RESULTS: PENDING** -- the before/after measurement is in section 6.

---

## 4. The hold numbers: the post-synth one is an artefact, and here is the proof

The brief asked for this not to be waved away, so it is argued from the
numbers rather than from the general principle.

| | WHS(ns) | THS(ns) | THS failing EP | of total |
|---|---|---|---|---|
| post-synth | -0.100 | -10278.136 | 279,484 | 27.2% |
| post-place | -0.212 | -173.890 | 7,881 | 0.77% |

**It is the artefact.** The evidence is that it improved by a factor of 35 in
endpoint count and 59 in total negative slack **with no RTL change at all** --
placement supplied real net delays and the violations evaporated. A genuine
hold violation is a property of the logic and does not improve when the cells
are placed; it gets worse, because real routing adds skew.

The mechanism: hold analysis asks whether the data path is too FAST. With no
placement, Vivado scores nets at essentially zero delay, so every short path in
the design -- a flop feeding a flop through nothing, of which a 356,525-flop
design has hundreds of thousands -- violates hold against the clock skew
estimate. 27.2% of all endpoints failing hold is the signature of that, not of
a design with a hold bug.

The post-synthesis report names one of them, and it is as clear as the setup
case:

    Slack (VIOLATED) :        -0.100ns  (arrival time - required time)
      Source:                 b_gdn/u_emit/u_y/w_h_reg[2]/C
      Destination:            b_gdn/u_emit/u_y/ep_reg_0_63_0_6/RAMA/WADR2
      Logic Levels:           0

**Logic Levels: 0.** A flop driving a distributed-RAM write address through
nothing at all. With no placement there is no wire delay for it to accumulate,
so it "fails" hold by 100 ps against an estimated skew. There is no fix for
this and none is needed; it is the tool reporting that it does not yet know
where the cells are.

**The post-place 7,881 at -0.212 is not the artefact and is not alarming
either.** Mean violation is 173.890 / 7,881 = **-0.022 ns** (DERIVED). Fixing
hold by detouring nets is `route_design`'s ordinary job and 22 ps is well
inside what a detour buys. **The number that settles it is post-route, and it
is reported in section 5.** WHS is not evidence of anything until then.

---

## 5. Place, phys_opt and route

Resumed from `c4dev_placed.dcp`, the checkpoint that survived the 01:25 hang.
`place_design`'s 1,638 s was already paid and was not repeated.

    TT_PHYSOPT_SECONDS 151
    TT_PHYSOPT_WNS     -2.834        (from -3.056 placed)

`phys_opt_design` recovered 0.222 ns, taking the longest path from 8.056 ns to
7.834 ns, i.e. 124.1 MHz to 127.6 MHz. It did not come close to closing.

### The router's own verdict, and it is quotable

MEASURED, `route_design`, Phase 4.1 Global Iteration 0, after 56 min 35 s:

    Number of Nodes with overlaps = 494506
    Number of Nodes with overlaps = 150615
    Number of Nodes with overlaps = 65271
    Number of Nodes with overlaps = 35976
    Number of Nodes with overlaps = 23310
    Number of Nodes with overlaps = 16757
    WARNING: [Route 35-447] Congestion is preventing the router from routing
    all nets. The router will prioritize the successful completion of routing
    all nets over timing optimizations.
    Phase 4.1 Global Iteration 0 | Checksum: 27fcdf2f4
    Time (s): cpu = 02:22:27 ; elapsed = 00:56:35
    Phase 4.2 Global Iteration 1
    Number of Nodes with overlaps = 69858
    Number of Nodes with overlaps = 183525

**`[Route 35-447]` is the tool saying, unprompted and in its own words, that
this design is congestion-bound.** It has abandoned timing optimisation in
order to try to finish routing at all. That is an independent confirmation of
this document's central claim from the one piece of software with no stake in
it, and it arrives before any model, any density argument or any estimate.

**And the overlap count is RISING in iteration 1**, 69,858 to 183,525, after
converging monotonically through iteration 0 to 16,757. A router that has to
rip up more than it fixed on the previous pass is thrashing, not converging.

### THE MEMORY NUMBER, AND IT IS THE SHARPEST THING THIS RUN MEASURED

State this plainly because it settles a question that "we ran too many Vivados"
only gestured at.

MEASURED, from `route_design`'s own progress lines, this run **alone on the
box**:

    Phase 3.2 Initial Net Routing   ... free physical = 513 MB
    Phase 3   Initial Routing       ... free physical = 510 MB
    Phase 4.1 Global Iteration 0    ... free physical = 233 MB
    Time (s): cpu = 02:22:27 ; elapsed = 00:56:35

**A single composed place-and-route drove this 31 GiB machine to 233 MB of free
physical memory while it was the only thing running.**

**Therefore this tool had no safe multiplicity on this box. Not two-with-care.
One.** The correct concurrency was never a matter of leaving headroom for a
second job, because at peak there was no headroom for anything at all. Six of
these ran concurrently on 2026-08-30 at 01:25 and the machine hung hard --
`kcompactd0` stuck 75 s, RCU stalls, soft lockups on nine CPUs, power button
required
(`docs/debugging/2026-08-30_the-box-hung-under-my-own-dispatch.md`).

**And no pre-flight check would have revealed this.** The 233 MB appears only at
peak, 56 minutes into the run. Every one of those six agents could have run
`free -g` before starting, found what it needed, been individually correct, and
still produced exactly the observed outcome. **A budget computed from
pre-launch free memory is measuring the wrong instant.** The only quantity that
bounds concurrency is the PEAK, it is knowable only after the fact or from a
prior run's logs, and for this job on this box it is the whole machine.

The `-p MemoryHigh=` / `-p MemoryMax=` caps used throughout this track are the
mitigation that does work, because they bound the peak rather than the start:
a capped job is throttled or killed, and the box survives either. They were
applied to every GHDL run here for exactly that reason.

### RESULT: killed by decision at 67 minutes, and that IS the result

`route_design` was stopped deliberately, with the dispatcher's approval, in
Phase 4.2 after the following trajectory:

    iteration 0:  494,506 -> 150,615 -> 65,271 -> 35,976 -> 23,310 -> 16,757   (56m35s)
                  WARNING: [Route 35-447] congestion is preventing the router
                  from routing all nets
    iteration 1:  69,858 -> 183,525 -> 111,513                                 (rising)

**The brief asked to "close it, or produce a measured, specific failure". This
is the measured, specific failure, and it is better evidence than a completed
route would have been.** A finished route would have reported a WNS around -3
and some number of unrouted nets, which is a symptom. `[Route 35-447]` names
the MECHANISM -- congestion -- and it is the tool's own unprompted verdict,
issued before any model, density argument or estimate in this document existed,
by the only participant in the argument with no stake in it.

What was given up by stopping: `report_route_status`, `report_drc` and a routed
`report_timing_summary` on a design that the router had already announced it
could not route. What was bought: the only lane on the box, for the pblock
squeeze (section 15), which measures a quantity that was being reported wrongly.

**This is recorded as a DECISION, not a completion.** Anyone wanting the routed
numbers can resume from `/mnt/storage/compose4/out/c4dev_physopt.dcp`, which
this run wrote before routing began. Budget several hours and expect it to
fail; iteration 1 was diverging when it was stopped.

---

## 6. Before and after, on `attn_block` alone

Run on the **BC-250** (`cachyos-bc250`), both points, back to back, same
machine, same Vivado 2023.2, same part, same harness
(`sim/ooc_compose_run.sh attn_block`, which drives `sim/ooc_compose_bcd.tcl`
with `HEAD_DIM=256 N_QH=16 N_KVH=4 LAYERS=8`). **Same machine on purpose:**
the two points then differ by exactly the edit under test and by nothing else.
The workstation was occupied by the composed route for the whole window, and
running both here is the two-lane discipline CLAUDE.md asks for.

### The BEFORE point is also a cross-machine control, and it passes

MEASURED, BC-250, unmodified `rtl/attn_block.vhd`:

    target,dsp,lut,lut_logic,lut_mem,ff,ramb36,ramb18,bram_tile,uram,carry8,f7,f8,wns_ns,fmax_mhz,synth_s,opt_s,...
    attn_block,298,85538,85429,109,101307,3,16,11,0,2734,18146,3776,-3.122,123.12238364934746,526,78,...

against TRACK WRITEDEC's workstation measurement of the same unit
(`hw/fk33/results/writedec_2026-08-29/result_wd_attn_after.csv`):

| column | workstation (WRITEDEC) | BC-250 (here) |
|---|---:|---:|
| **wns_ns** | **-3.122** | **-3.122** |
| **fmax_mhz** | **123.12238364934746** | **123.12238364934746** |
| dsp | 298 | 298 |
| carry8 | 2,734 | 2,734 |
| f7 | 18,146 | 18,146 |
| f8 | 3,776 | 3,776 |
| lut | 85,816 | 85,538 |
| ff | 101,014 | 101,307 |

**WNS and Fmax agree to every quoted digit, seventeen significant figures, on
two different machines.** So does the DSP, CARRY8 and mux census. This is an
independent confirmation of `CLAUDE.md`'s claim that BC-250 results are
quotable on the workstation, and it is the first time that claim has been
checked on a VU33P target of this size rather than on the 4,719-LUT
`ooc_gdn_scalar` acceptance test.

**LUT and FF do NOT agree, by -278 and +293.** That is not a machine
difference: the two runs are of **different pinned trees** (WRITEDEC's
2026-08-29 tree against today's `6db7dd6`). It is well inside the run-to-run
area scatter TRACK NWFIX MEASURED (82,597 to 128,065 LUT across five draws,
two from the identical command), which is exactly why the BEFORE point was
re-measured here instead of being quoted from the CSV. **A single area number
is a draw, not a measurement**, and the comparison below is therefore made on
WNS, on CARRY8 and on logic levels, not on LUT.

Timing: 526 s synth on the BC-250 against 214 s on the workstation
(**2.46x**, against the documented 2.3x; the excess is swap, see section 10
item 4).

### The AFTER point

MEASURED, BC-250, `rtl/attn_block.vhd` with the balanced-tree reassociation,
same harness, same generics, run immediately after the BEFORE point:

| column | BEFORE (serial fold) | AFTER (balanced tree) | delta |
|---|---:|---:|---:|
| **wns_ns** | **-3.122** | **+0.825** | **+3.947** |
| **fmax_mhz** | **123.122** | **239.521** | **+94.5%** |
| carry8 | 2,734 | **2,734** | **0** |
| f7 (MUXF7) | 18,146 | 16,350 | -1,796 (-9.9%) |
| f8 (MUXF8) | 3,776 | 2,992 | -784 (-20.8%) |
| lut | 85,538 | 87,340 | +1,802 (+2.1%) |
| ff | 101,307 | 101,319 | +12 |
| dsp | 298 | 298 | 0 |
| bram_tile | 11 | 11 | 0 |

**`attn_block` goes from failing by 3.122 ns to MEETING timing with 0.825 ns to
spare, and its Fmax nearly doubles: 123.1 MHz to 239.5 MHz.** Subsystem C now
closes 200 MHz standalone, which it has never done in this project. TRACK
WRITEDEC recorded -3.122 and TRACK LUTDIET re-measured -3.111; that number was
described in TRACK COMPOSE4's write-up as "the single most consequential number
in the booking". It is now positive.

**The CARRY8 census is UNCHANGED at 2,734, and that is evidence rather than a
curiosity.** A balanced tree performs exactly the same eight comparisons as the
serial chain; it only re-brackets them. If the reassociation had dropped,
duplicated or altered a comparison, the carry-chain count would have moved.
It did not move by one.

**It also costs 1,802 LUT, +2.1%, and that is REAL but is inside the noise
floor of the measurement.** TRACK NWFIX MEASURED synthesis area varying by
45,468 LUT across five draws of this class of design, twice from the identical
command. A +1,802 LUT delta from a single draw each side **cannot be
distinguished from scatter**, and this document does not claim it as a
measurement. What can be claimed is the direction and the mechanism: a tree
cannot reuse the chain's single comparator result, and it pads to a power of
two. The MUXF7/MUXF8 reductions are large enough (-9.9%, -20.8%) to be outside
that floor and they point the other way, which matters for packing (section 7).

### Bit-exactness: checked, not only argued -- and the first check had no teeth

The argument in section 3 is algebraic and it is sound. It is also not
evidence about the RTL that implements it, so the oracle was run.

`ref/attn_block_vec.c` is subsystem C's independent block-level C oracle and
`sim/tb_attn_block.vhd` asserts against it, its own header saying "P8 THE
VALUES, BIT-EXACTLY". Three-way, `REGRESS_SCRATCH=... bash sim/regress.sh
--only attn --keep`, on the workstation:

| RTL | `sim:tb_attn_block` | `sim:tb_attn_kv_seam` | OVERALL |
|---|---|---|---|
| ORIGINAL (serial fold) | PASS | PASS | **PASS 16 FAIL 0** |
| FIXED (balanced tree) | PASS | PASS | **PASS 16 FAIL 0** |
| MUTANT (final tree stage dropped) | **PASS** | **FAIL** | **PASS 15 FAIL 1** |

**The mutant is a one-line change**, `for s in 0 to LG-1` to
`for s in 0 to LG-2`, which drops the last combining stage so `emin_tree`
returns the minimum over a SUBSET of the block exponents. It is a genuine
wrong answer whenever a dropped element holds the minimum.

**`tb_attn_block` -- the bench aimed at this unit, carrying the bit-exact C
oracle -- PASSES the mutant.** It does not discriminate on this structure. Had
the teeth-check been skipped, this document would have reported "the oracle
passes, the fix is bit-exact" on the strength of a check that cannot fail for
this defect. That is precisely the guards-that-pass-for-the-wrong-reason class
in CLAUDE.md, and it was found only because the mutant was run.

**`tb_attn_kv_seam` DOES discriminate**, and it is the bench `sim/regress.sh`
describes as joining `rtl/attn_block.vhd` across the KV seam, with a wide
per-(pos,layer) block-exponent spread -- which is exactly the input diversity
the fold needs to be observable:

    FAIL sim:tb_attn_kv_seam  10s  exit 1:
      sim/tb_attn_kv_seam.vhd:1263:13:@457945ns:(report error):
      tb_attn_kv_seam: Q1 -- token 0 element 0 = -15237, the oracle says ...

and on the fixed RTL:

    PASS sim:tb_attn_kv_seam  10s
      sim/tb_attn_kv_seam.vhd:1432:7:@457945ns:(report note):
      tb_attn_kv_seam: PASS -- 4 tokens at cur_pos 0..

**So: an oracle that is SHOWN to catch a wrong min-fold passes the fix, and
passes the original, at the same resolution.** That is the claim, and it is
bounded by one thing worth stating: the benches run at the SCALED shape
(`HEAD_DIM`=16, `KV_BLOCK`=4, so `NBLK`=4 and the tree is 2 stages), not the
9B shape (`NBLK`=8, 3 stages). The reassociation is shape-independent, but it
has been exercised at 4 and not at 8.

---

## 7. Where the CLBs actually go

MEASURED on the placed checkpoint, `report_utilization`:

    CLB LUTs      346971 of 439680   78.91 %
      as Logic    331916
      as Memory    15055
    CLB Registers 356525 of 879360   40.54 %
    CARRY8         12147 of  54960   22.10 %
    F7 Muxes       65108 of 219840   29.62 %
    F8 Muxes       25788 of 109920   23.46 %
    CLB            54866 of  54960   99.83 %      <- the binding resource

**LUTs are at 78.91% and CLBs are at 99.83%.** A CLB holds 8 LUTs; this design
gets 346,971 / 54,866 = **6.32** (DERIVED).

DERIVED lower bound, stated because it bounds how much of the gap is
recoverable: at the architectural 8 LUT per CLB the same netlist would need
346,971 / 8 = **43,371 CLB = 78.9%**. That bound ignores F7/F8 shape
constraints, control-set rules and the placer's own spreading, so it is
**unreachable**, but it says the gap between 78.9% and 99.83% is about
**11,500 CLBs** and that the gap, not the LUT count, is where the device went.

An F7/F8 mux pair fixes which LUTs must sit together, and Vivado places those
as indivisible shapes. There are 90,896 of them. MEASURED, by instance
(`TT_MUX`, from the route run):

| instance | MUXF7 | MUXF8 |
|---|---:|---:|
| `a_eng/eng` | 24,869 | 12,399 |
| `d_norm/gvr.u_rms` | 17,696 | 8,736 |
| `c_attn/u_arr` | 15,796 | 2,448 |
| `b_gdn/u_emit` | 2,507 | -- |
| `c_attn/u_norm` | 1,089 | -- |

**Subsystem A carries the largest mux population**, and that turns out to be
the single most actionable fact in this document -- see section 7a.

### 7a. What sets 6.32 LUT/CLB, and what it could become

**The mechanism.** A MUXF7 pairs two LUT6s that must then sit together in a
CLB half; a MUXF8 combines two F7 pairs, locking FOUR LUT6s into one
indivisible placement shape. The placer cannot break these to fill gaps.
DERIVED from the MEASURED census:

    MUXF8                                   25,788   locks 4 LUTs each = 103,152
    MUXF7 consumed under a MUXF8    2 x 25,788 = 51,576
    MUXF7 free                              13,532   locks 2 LUTs each =  27,064
    LUTs locked into mux shapes                                          130,216
    as a fraction of the 346,971 LUTs                                      37.5%

    packing efficiency 6.324 / 8.000                                       79.0%
    so packing LOSS                                                        21.0%
    calibration  k = loss / locked-fraction = 0.2095 / 0.3753  =            0.558

### The independent cross-check that makes lever C the answer

TRACK CONGEST MEASURED the IQ4_NL codebook inside `matvec_core` at
**50,128 LUT + 36,864 MUXF7/F8 = 86,992 primitives, 39.5% of `matvec_core`,
and 97.7% of that design's MUXF7 and 98.8% of its MUXF8**
(`docs/debugging/2026-08-29_shell-congestion.md`).

MEASURED here, independently, on a different design (the composed A+B+C+D) by
a different query: **`a_eng/eng` carries 24,869 MUXF7 + 12,399 MUXF8 = 37,268.**

**Against CONGEST's 36,864 that is agreement within 1.1%**, two tracks, two
designs, two tool invocations. So the codebook is essentially the WHOLE of
subsystem A's mux population in the composition as well, and subsystem A is
38.2% of the composed MUXF7 and 48.1% of its MUXF8.

### ESTIMATE: the post-lever-C packing density

> **WITHDRAWN 2026-08-30 -- SEE SECTION 16 (CORRECTION C4). The model below has
> its premise INVERTED.** MUXF7/F8 are dedicated hardware that does not consume
> LUT capacity, so a mux-paired region sits at **8.00 LUT/CLB, the device
> maximum** -- mux shapes are the DENSEST part of this design, not the loosest,
> and removing them LOWERS the average density. `k = 0.558`, the 6.82 LUT/CLB
> and every percentage derived from them are withdrawn. Kept in place, not
> deleted, because they were relayed and acted on. The corrected decomposed
> model and the corrected table are in section 16.

**ASSUMPTION, stated because the number is only as good as it:** packing loss
is proportional to the fraction of LUTs locked into MUXF7/F8 shapes, with the
constant `k` = 0.558 calibrated on the ONE measured point above. This is a
single-point calibration of a one-parameter model. It is an ESTIMATE and it is
not a measurement.

    codebook share, DERIVED from CONGEST's 97.7% / 98.8% of a_eng's census:
      MUXF7  24,297      MUXF8  12,250
    lever C converts 86,992 primitives to LUTRAM at CONGEST's ~7.1x win:
      LUT  346,971 - 50,128 + ~12,252   =  ~309,095
      MUXF7            65,108 - 24,297  =    40,811
      MUXF8            25,788 - 12,250  =    13,538
      locked LUTs                            81,616  = 26.4%  (was 37.5%)
      ESTIMATE density  8 x (1 - 0.558 x 0.264)  =  6.82 LUT/CLB   (was 6.32)

**So lever C is worth roughly +0.5 LUT/CLB of packing density on top of its
~38,000 LUT saving, and the packing half is not optional to count.** What that
does to the fit:

| configuration | LUT | at 6.32 today | at **6.82 ESTIMATE** |
|---|---:|---:|---:|
| **as measured today** | 420,240 .. 465,708 | **121% .. 134%** | 112% .. 124% |
| **+ lever C** | 382,364 .. 427,832 | 110% .. 123% | **102% .. 114%** |
| **+ lever C + norm image out of LUTs** | **349,421** | 100.6% | **93.2%** |

> **THE 6.82 COLUMN AND THE 93.2% ARE WITHDRAWN -- SEE SECTION 16.** The
> corrected figures are 115.9%..130.6% for lever C and **105.2%** for lever C
> plus the gain out of LUTs, which DOES NOT FIT. The row that fits requires a
> THIRD lever and is 94.6%. The 6.32 column is closer to right than the 6.82
> column, because density FALLS with lever C rather than rising.

**LEVER C ALONE DOES NOT CLOSE IT, and with the range it is not even close.**
(This conclusion is unchanged by C4; the corrected arithmetic makes it
stronger, 115.9%..130.6% rather than 102%..114%.)
At the estimated post-lever-C density it spans **102% to 114%** of the device's
CLBs. The best draw of the norm image is the only number that makes lever C
look nearly sufficient, and that draw is the one TRACK SCATTER forbids quoting.

**LEVER C PLUS MOVING THE NORM GAIN IMAGE OUT OF THE LUT FABRIC DOES CLOSE IT,
at about 93%** -- and note what else that row does:

**IT IS THE ONLY ROW WITHOUT A RANGE.** The 32,943..78,411 uncertainty IS the
norm gain ROM. Move it into URAM and the quantity leaves the LUT fabric
entirely, taking its irreproducibility with it. So that option does not merely
save the most LUTs per unit of effort -- **it deletes the single least
reproducible term in the whole budget**, which for a design whose margin is
thinner than its measurement scatter is worth more than the LUTs.

`NORM_W_IMAGE` is 4096 x 65 x 16 = 4,259,840 bits = **14.4 URAM288 of the 320
that are free** (DERIVED), it is a ROM of constants, it is on no failing path,
and its only obligation is to serve the same values.

### There are THREE ways to serve the norm gain, and only one of them is the ROM

Found while checking C2's arithmetic against TRACK SCATTER's own table, which
carries a row nobody has costed into a fit claim:

| how the gain is served | LUT over the 49,654 empty-image baseline | evidence |
|---|---|---|
| **as a ROM in the LUT fabric** (today) | **+32,943 .. +78,411** | 6 draws, **NOT SAFE, no single number may be quoted** |
| **from HBM** (TRACK NWFIX probe, 67,059) | **+17,405** | **n=2, SAFE, bit-identical on all eleven columns** |
| **from URAM** (proposed, section 8) | ~0 LUT + 14.4 of 320 URAM288 | **unmeasured** |

**The HBM path is already measured, is already reproducible, and is already
cheaper than the BEST draw of the ROM by 15,538 LUT.** It is not the best
option -- URAM should beat it outright -- but it is the one with evidence
behind it today, and it is the fallback if URAM inference cannot be made to
work:

    lever C + gain from HBM     366,826 LUT   ->   97.9% at 6.82   (105.6% at 6.32)
    lever C + gain from URAM    349,421 LUT   ->   93.2% at 6.82   (100.6% at 6.32)

Both are values rather than ranges, which is the property that matters here.
**Whichever is chosen, the ROM-in-LUTs path should not be what a fit claim is
built on**, because it is the only one of the three that cannot be quoted at
all under SCATTER's rule.

---

## 8. The URAM lead, followed and reported honestly

**URAM is 0 of 320.** The brief flagged this as a lead, correctly labelled as a
lead and not an instruction. Followed, and the answer is split:

**As a fix for the failing PATHS: no.** MEASURED, scanning the cells on the
3,000 worst failing paths for memory primitives:

    TT_MEMSCAN scanned=3000 cells_matched=3
    TT_MEMREF RAMB36E2          3

**Three memory cells on 3,000 failing paths.** The critical paths are logic and
wire, not memory access. Retiming a memory into URAM would not move them.

**As a fix for the AREA that is causing those paths: it is the strongest lead
on the page, and it is bigger than URAM.** `d_norm/gvr.u_rms` is `rmsnorm_rs`
at `N`=4096, and it is the largest single failing bucket in the design
(`d_norm -> d_norm`, 10,378 of the 20,000 sampled endpoints). Its ports are
flat:

    x_mant : in  std_logic_vector(N*16-1 downto 0);   -- 65,536 bits
    w_mant : in  std_logic_vector(N*16-1 downto 0);   -- 65,536 bits
    o_mant : out std_logic_vector(N*16-1 downto 0);   -- 65,536 bits

and it reads them at a RUNTIME index (`rtl/rmsnorm_rs.vhd:308,546,547,620,621`):

    xa(k) <= signed(x_mant((base+k+1)*16-1 downto (base+k)*16));

A dynamic slice of a 65,536-bit vector is a 1024:1 16-bit multiplexer, built
from LUTs and F7/F8 pairs. MEASURED: `gvr.u_rms` is **43,213 LUT, 67,384 FF,
17,696 MUXF7 and 8,736 MUXF8**, and `d_norm` as a whole is 48,561 LUT and
133,607 FF -- of which 131,072 FF is two 4096x16 vectors held in flip-flops.

**4096 x 16 bits is 65,536 bits. One URAM288 holds 288 Kb.** So each of those
vectors fits in a single URAM with room to spare, the address replaces the mux,
and the 320 URAMs on this device are entirely unused.

**This is NOT proposed as a change here, and the reason is stated so it is not
mistaken for timidity.** It is an INTERFACE change to `rmsnorm_rs`, a unit that
is bit-exact against `rtl/rmsnorm.vhd` element for element and is instantiated
by B, C and D. Replacing a combinational flat-vector read with an addressed
memory read is **not latency-neutral** -- a URAM read is registered, so every
element access gains cycles and the unit's internal schedule has to absorb
them. That is a redesign with a bit-exactness obligation, not a tuning knob,
and it is worth doing properly rather than tonight. **Sizing it is in the open
questions.**

---

## 9. Measured and REJECTED -- do not retry

1. **"The 256 failing endpoints are a small, specific problem, so pipeline
   them and the composed design closes."** REJECTED. The 256 are real, are one
   structure, and are fixed here -- and they are **0.76% of the 33,767
   endpoints that actually fail**. The remaining 33,511 are 100% net-dominated
   (20,000 of 20,000 sampled). Do not schedule composed timing closure on the
   basis of the post-synthesis summary.

2. **"Lower `core_clk` until it closes."** REJECTED as a *sufficient* measure,
   and the arithmetic is why. Post-`phys_opt` WNS is **-2.834 ns** on a 5.000 ns
   period, so the longest path is 7.834 ns = **127.6 MHz** (DERIVED). Dropping
   the clock to 127 MHz is a **36% throughput loss** AND **it does not free a
   single CLB**. The design is at 99.83% CLB *before* the FK33 shell and the
   norm gain image are added, so it still does not fit. A slower clock buys
   nothing that the area problem does not immediately take back.

3. **Moving something to URAM to fix the critical PATHS.** REJECTED on
   measurement, and this was the brief's own lead, correctly flagged as a lead.
   Scanning the cells on the 3,000 worst failing paths found **3 memory
   primitives**. The failing paths are logic and wire. URAM remains
   interesting for AREA (section 8), which is a different argument with a
   different justification.

4. **Sending the composed job, or `attn_block` OOC, to the BC-250.** REJECTED
   for the composed job and MEASURED-marginal for the unit. Vivado's floor for
   this part is 11-14 GiB *regardless of design size* (section 10 item 4), and
   the BC-250 has 14 GB total. The `attn_block` run dispatched there did
   complete but drove the machine to **2 GB available with 3 GB of swap in
   use**. It works; it is not comfortable; and anything larger will not fit.

5. **`git commit -m msg -- <path>` on `rtl/attn_block.vhd` without checking
   first.** Not retried, because the file turned out to be exclusively this
   track's for the whole session (`git status` showed only
   `rtl/axi_rd_port.vhd` modified, which is TRACK RESETGUARD's and was not
   touched). Recorded because the decision had to be made deliberately rather
   than by habit, per CLAUDE.md's note that the two git forms want opposite
   commands depending on ownership.

---

## 10. Measurement traps hit, including my own

1. **A synthesis-stage figure quoted as though it described the placed design.
   THE DISPATCHER'S, recorded at their request and under their name.** The
   brief said "only 256 of 1,027,089 endpoints fail setup [...] this reads as a
   small number of specific paths, not a systemic problem". That was the
   POST-SYNTHESIS number; the placed report already on disk said **33,767**.
   Both are correct measurements of different design states, and the trap is
   that the two summaries have identical column headers and differ by **132x**
   in the failing-endpoint column while differing by only 0.203 ns in WNS,
   which is the column people read. The brief also said "verify that rather
   than believing me", which is the only reason this was caught.

   **The general form: `report_timing_summary` after synthesis does not
   under-report the MAGNITUDE of a timing problem, it under-reports its EXTENT,
   and by two orders of magnitude.** Never characterise a failing-endpoint
   population from a pre-placement report.

2. **My own version of the same trap: I nearly re-derived what was already on
   disk.** The correct first move on a resumed track is to inventory what the
   dead run left behind. `c4dev_placed.dcp`, `timing_c4dev_placed.rpt` and
   `congestion_c4dev_placed.rpt` had all survived the crash and none had been
   read.

3. **A checker that passes is not a checker that works, and I nearly shipped
   one.** `sim/tb_attn_block` carries subsystem C's bit-exact C oracle, is the
   bench named after the unit under test, and **passes a deliberately broken
   min-fold**. Reporting "the oracle passes" on its strength would have been a
   guard that passed for the wrong reason. The discriminating bench is
   `tb_attn_kv_seam`, and the only reason the difference is known is that the
   mutant was run. **Run the mutant before believing the PASS.**

4. **`get_property NAME` on a clock region returns `X0Y0`, but `resize_pblock
   -add` requires `CLOCKREGION_X0Y0`.** The bare name is accepted by the
   argument parser and rejected only at placement time with
   `ERROR: [Place 30-342] pblock resize has invalid range X0Y0`, which reads
   like a bad geometry rather than a missing prefix. It cost one Vivado launch.

5. **`systemd-run --user` does NOT inherit the caller's working directory**,
   and a `bash -c` that omits its own `cd` fails with
   `bash: sim/regress.sh: No such file or directory` -- a 48-byte log that a
   `grep` for `OVERALL` renders as silence, which reads exactly like a bench
   that has not finished yet. It cost three attempts. Use
   `-p WorkingDirectory=`, and never treat an empty grep as "still running".

6. **A waiter armed on a unit reports "completed" when that unit is KILLED**,
   not only when it succeeds. Two notifications in this track announced a
   finished job that had in fact been stopped by me a minute earlier. Gate on
   the sentinel in the log, never on the waiter firing.

2. **`c4dev_placed.dcp` survived the crash and saved 1,638 s.** Everything in
   `/mnt/storage/compose4/out/` was intact. Checking for surviving checkpoints
   cost one `find` and saved half an hour of placement.

3. **The checkpoint is PRE-`phys_opt`.** `ooc_compose4_pnr.tcl` writes
   `c4dev_placed.dcp` and THEN runs `phys_opt_design`, so resuming from it
   means re-running phys_opt (151 s here, 267 s in the lost run). Resuming from
   a checkpoint without reading the script that wrote it would have silently
   compared a pre-phys_opt state against a post-phys_opt number.

4. **Vivado's memory floor for this part is 11-14 GiB regardless of design
   size, and that makes the BC-250 marginal for VU33P.** MEASURED from the peak
   RSS files of nine previously-run OOC targets: `dr_gdn_2ab` 10.82 GiB,
   `na_after` 12.50, `wd_rms_after_n4096` 12.53, `wd_attn_after` 13.52,
   `wd_gdn_before` 13.70, `wd_rmsflat_before` 14.05. **These are not
   design-size numbers, they are the VU33P device database plus Vivado's
   baseline.** The BC-250 has 14 GB total and reported 13 GB available. This is
   a correction to `CLAUDE.md`, which says the BC-250 is for "OOC unit
   synthesis and area sweeps" with the caveat only about the 23.8 GB
   `engine_shared` and the 25.0 GiB full build; the real ceiling is much lower
   than those two numbers imply. Its validated acceptance test
   (`ooc_gdn_scalar`) is a 4,719-LUT unit, and small VU33P targets do fit.

5. **`ghdl -a` reports `obsoleted by package` after re-analysing a package, and
   exits non-zero, and this is not a syntax error.** Re-analysing `util_pkg`
   after the entities that use it marks them stale. The pre-existing `-Whide`
   warning on `attn_block.vhd` (`declaration of "g" hides constant "g"`) is
   TRACK COMPOSE4's documented finding and is also not a defect.

---

## 11. What this establishes and what it does NOT

**Structure is not values, and routing is not even structure.** A design that
routes and closes timing is a design whose wires are short enough. It is not a
design that computes anything. Specifically:

* `compose4_top` **does not wire the four subsystems to each other.** Every
  failing path measured here is internal to one subsystem. Nothing here says
  what happens when they are connected, and connecting them can only add
  paths, never remove them.
* **Subsystems B and C have never run on this silicon at all.**
* The fix in section 3 is argued bit-exact **by algebra** (min is associative,
  commutative and idempotent) and checked by GHDL analysis and by synthesis.
  The number that would settle it is a simulation oracle, and section 6 says
  exactly what was and was not run.
* The area arithmetic in section 12 adds a post-SYNTHESIS composed number to
  post-ROUTE shell numbers. Implementation shrinks LUTs, so it is
  conservative in that direction and optimistic in another: it assumes the
  shell's LUT count is unaffected by having 2.7x more logic beside it, which
  is true for cells and false for routing.

## 12. The area arithmetic, which is the actual answer to N3

All MEASURED unless marked. This is the number to plan against.

    composed, PLACED (post-synth was 350,283)      346,971 LUT   54,866 CLB (99.83%)
      the FK33 shell, DERIVED by TRACK COMPOSE4
      (171,458 routed total - 131,132 engine)       40,326 LUT
      a real NORM_W_IMAGE, RANGE not a value
      (TRACK SCATTER: 82,597..128,065 populated,
       over the 49,654 empty-image baseline)     +32,943..+78,411 LUT
    the honest total for a build that can run  420,240..465,708 LUT
                                                   = 95.6% .. 105.9% of 439,680

**THE NORM IMAGE IS A RANGE, AND QUOTING ITS BEST DRAW IS NOT ALLOWED.**
TRACK SCATTER's table marks the populated norm gain ROM **"NOT SAFE, AND NOT
FIXABLE BY REPEATING. No single number may be quoted; report the range or
nothing"** -- 82,597 to 128,065 LUT across **six** draws. `+32,943` is the
delta of its BEST draw over the 49,654-LUT empty-image baseline; the honest
delta is **+32,943 to +78,411**. Every row below inherits that range, and at
the top of it **the design exceeds the device's LUT count outright, 105.9%**,
before any packing argument is made at all.

**And 95.6% of the LUTs was never the constraint. The CLBs are.** At the
MEASURED packing density of 346,971 / 54,866 = **6.32 LUT per CLB**:

| assumed density | CLBs needed | of the 54,960 on the die |
|---|---:|---:|
| 6.32 (MEASURED) | 66,494 .. 73,688 | **121% .. 134%** |
| 7.00 | 60,034 .. 66,530 | 109% .. 121% |
| 8.00 (architectural max, unreachable) | 52,530 .. 58,214 | 96% .. 106% |

**The composed design plus its shell plus its gain image needs 121% to 134% of
this device, and even at a packing density no real design achieves it needs 96%
to 106%.** That is the measured, specific failure the brief asked for, and it
is an area failure rather than a timing one.

### And the total is an UNDERCOUNT, in a direction nobody has priced

`compose4_top` deliberately wires nothing to anything. Its nine instances share
only `core_clk` and `core_rst`; every other port of every instance is a
top-level port, 1,184 declarations and 36,529 bits. There are **no
inter-subsystem nets, no host plumbing, and no `fk33_seam`** -- N2 was
unresolved when the checkpoint was built.

A real top adds all of that: logic AND, more importantly for a design bound by
packing, **nets**. So 420,240..465,708 is a floor, not an estimate, and
whenever it is quoted the floor-ness should be quoted with it. This cuts in the
same direction as everything else in this section.

DERIVED, what has to change: to sit at 90% CLB at the measured density the
design may hold **312,809 LUT**, so **about 107,400 LUT must come out.**

The two largest candidates, both memory-shaped things currently built from
logic, and together they are **76,156 LUT, roughly 71% of what is needed**:

| candidate | LUT | what it is | where it should live |
|---|---:|---|---|
| `d_norm/gvr.u_rms` dynamic-slice muxes | 43,213 | 1024:1 16-bit read muxes over 65,536-bit flat ports, plus 131,072 FF of vector held in flops | 1 URAM288 per 4096x16 vector (0.22 of one, DERIVED) |
| `NORM_W_IMAGE` as a LUT ROM | 32,943 | 4096 x 65 x 16 = 4,259,840 bits of learned gain | **14.4 URAM288** of the **320 free** (DERIVED) |

**The device has 320 URAM and uses 0, and 425.5 of 672 BRAM tiles free.**
There is an entire idle memory subsystem beside a LUT fabric that is being
asked to store 4.26 Mb of constants and two 64 Kb vectors in flip-flops and
multiplexers.

**The `NORM_W_IMAGE` one is the cheap half and should be looked at first.** It
is a ROM of constants with no timing subtlety, it is not on any failing path,
and it has no bit-exactness obligation beyond serving the same values -- unlike
the `rmsnorm_rs` interface change, which is a redesign (section 8).

## 12a. Can A+B+C+D+shell+norm fit this part at all? My judgement

Asked for directly, so answered directly.

**Yes, but not as currently written, and not with one change.** Confidence:
moderate on the direction, low on the exact margin, for the reason in 7a --
the density figure is a one-point calibration.

**The case for yes.** Nothing in the design is irreducibly large. The three
biggest line items are all things built out of LUTs that are not logic:

| lever | LUT | what it is | difficulty |
|---|---:|---|---|
| **C**: IQ4_NL codebook to LUTRAM | ~38,000 + packing | 86,992 primitives of runtime-loadable codebook, 97.7%/98.8% of A's muxes | pre-authorised; 32x write-coherency surface; oracle dispatched alongside |
| **norm gain image to URAM/BRAM** | **32,943 .. 78,411** | a 4.26 Mb ROM of constants, 14.4 of 320 free URAM288 | **easiest of the three**; no timing subtlety, on no failing path; **and it is the only lever that removes a RANGE rather than a value** |
| **`rmsnorm_rs` flat vectors to memory** | ~43,213 **+ 17,696 MUXF7** | 1024:1 muxes over 65,536-bit ports; 131,072 FF of vector in flops | **hardest**; interface redesign, NOT latency-neutral, bit-exactness obligation. **PROMOTED TO FIRST by C4: it alone beats lever C alone, 102.2% against 115.9%, and it has no write-coherency surface and has never been on silicon** |

Lever C plus the norm image is **~93%** (ESTIMATE), and that row is the only
one in the table that is a value rather than a range. Adding the third gives
real margin. The device also has **320 URAM sitting entirely unused and 425 free
BRAM tiles** while the LUT fabric is asked to store 4.26 Mb of constants and
two 64 Kb vectors in flip-flops.

**The case for caution, and it is not small.** 93% CLB is not a comfortable
place to route. This design is at congestion **level 7** in two windows today,
and TRACK NWFIX MEASURED that synthesis area on this class of design varies by
up to 45,468 LUT between draws of the *identical command*. A design whose
central estimate is 93% has draws that are not 93%. **I would not schedule
against a plan whose margin is smaller than the measured scatter**, which
argues for taking all three levers rather than the cheapest two.

**UPDATED BY THE SQUEEZE (section 15).** The ordering below stands, but the
target is lower than C4 said: `lever C + gain to URAM` measures **92.9%**, not
105.2%, so **two levers may suffice on CLB count**. The third lever
(`d_norm`) then buys margin rather than being mandatory -- and margin is worth
buying here, because the squeeze also showed that the denser the placement the
worse the timing (WNS -3.056 to -3.658) on a design whose observed failure is
routability, not capacity.

**What I would do, in order:**

1. **Lever C**, already reopened and dispatched. Biggest single win, and it is
   the only one that improves packing density as well as LUT count.
2. **The norm gain image into URAM.** Cheapest, lowest-risk, and it is the
   difference between ~102% and ~93%. It should not wait for lever C.
3. **Re-measure the composed placement** after those two, rather than trusting
   6.82. The whole argument of section 7a rests on a one-point model, and
   after lever C there would be a second point to calibrate against.
4. **`rmsnorm_rs` only if 1-3 leave insufficient margin**, because it is the
   one that can break arithmetic.

**Weigh all of the above against the fact that 420,240..465,708 is a FLOOR.**
`compose4_top` wires nothing to anything, so a real top adds logic and nets on
top of every figure here.

**And the option that is larger than all three combined:** not having all four
subsystems resident simultaneously. That is board row N2/N3 architecture and
Oren's call, and it is named here only so the list is complete.

**One thing I want to be explicit about: dropping the norm image is NOT the
same as moving it.** Dropping it saves the same 32,943 LUT and costs the
ability to compare `R_XN-L` and `R_XN.ffn-L` against a reference built from the
model -- 9 of the 63 captured seams, per `rtl/llama_top.vhd`'s own comment.
**Moving it to URAM saves the LUTs and keeps the comparison.** I would not
trade a verification capability for area that a memory can hold for free.

## 13. Open, not yet answered

1. **Does the composed design ROUTE at all?** Section 5 has the answer this
   run produced. What it does NOT answer is whether a design at 99.83% CLB
   routes *repeatably* -- TRACK NWFIX MEASURED synthesis area varying from
   82,597 to 128,065 LUT across five draws, twice from the identical command,
   and TRACK SCATTER was quantifying that when the box died. **A single
   routing outcome at 99.83% occupancy is a draw, not a measurement.**
2. **Does the section 3 fix survive a simulation oracle?** Argued by algebra,
   checked by analysis and synthesis. Section 6 states what was run.
3. **What does `rmsnorm_rs` cost with an addressed memory instead of flat
   vector ports, and can its schedule absorb the read latency bit-exactly?**
   Not attempted. It is the single largest area lever found and it is a
   redesign, not a tuning.
4. **Is `d_norm` the right thing to have in the composition at all?**
   `ooc_normadapt` is `llama_top`'s `gvr` adapter, and `llama_top` is a
   SIMULATION top. Its 4096-element flat-vector interface may be an artefact of
   that rather than the shape a card build would use. **This was not
   determined and it materially changes the budget**, because `d_norm` is
   48,561 LUT, 133,607 FF and the largest single failing bucket.
5. **Do all four subsystems have to be resident simultaneously?** That is board
   row N2's territory and an architecture decision reserved for Oren. It is
   named here only because it is the one lever larger than every lever in
   section 12 combined.
6. **The pblock run (`impl_pb`) was never executed**, not by TRACK COMPOSE4 and
   not here. Everything above is the unconstrained whole-die placement. The
   shipping floorplan reserves `pb_core` = `CLOCKREGION_X0Y0:X6Y3`, and a
   design that needs 121% of the whole die cannot fit a sub-region, so the run
   was not queued. **It remains formally unmeasured.**


---

## 14. CORRECTIONS, appended 2026-08-30 after adversarial review

Nothing above is deleted. An adversarial review of the fit claim (Fable, via
the dispatcher) returned **"SOUND as a statement about the RTL as written
today, and OVERSTATED as a device verdict"**, and found that the overstatement
came from a relay that stopped at the 121% table and dropped section 12a. Three
corrections follow; all three make the claim MORE conservative in the same
direction, and all three are now folded into the sections above as well.

### C1. `346,971` is the PLACED figure, not post-synthesis

Post-synthesis is **350,283**; `opt_design` took it to 350,228 and
`place_design` to 346,971. Section 12 was already labelled correctly; the
headline was not, and is now. The direction favours the claim (the placed
figure is the smaller one), so nothing downstream moves.

### C2. The norm gain image is a RANGE, and the value quoted was its best draw

**This is the weakest number in the chain and it was quoted as though it were
a measurement.** TRACK SCATTER's own table marks the populated norm gain ROM
**"NOT SAFE, AND NOT FIXABLE BY REPEATING. No single number may be quoted;
report the range or nothing"** -- **82,597 to 128,065 LUT over six draws.**
`+32,943` is the delta of the BEST of those six over the 49,654 empty-image
baseline. The honest delta is **+32,943 to +78,411**.

Every fit row now carries the range. The consequences are not cosmetic:

* today: **121% .. 134%** of CLBs, and **95.6% .. 105.9% of the device's LUTs**
  -- at the top of the range it does not fit by LUT count either, which no
  version of this claim had said;
* + lever C: **102% .. 114%**, so lever C alone is further from sufficient than
  the single-draw arithmetic suggested;
* + lever C + image to URAM: **93.2%, and this row has no range at all**,
  because moving the ROM out of the LUT fabric removes the irreproducible
  quantity from the budget rather than bounding it. That is now the strongest
  argument for that lever and it was not visible before this correction.

### C3. The honest total is a FLOOR, not an estimate

`compose4_top` deliberately wires nothing to anything: nine instances sharing
only `core_clk`/`core_rst`, 1,184 top-level ports, no inter-subsystem nets, no
host plumbing, no `fk33_seam` (N2 was unresolved when the checkpoint was
built). A real top adds logic **and nets**, and nets are what a
packing-bound design is short of. `420,240..465,708` should be quoted as a
floor whenever it is quoted.

### What the review CONFIRMED, recorded because a review that only finds faults has not been checked either

* **The addition is legitimate cell-wise.** Verified from `util_c4_synth.rpt`
  section 6 that `compose4_top` contains **none** of the shell (PCIE4CE4 = 0,
  all HBM interfaces = 0), so the shell's 40,326 is disjoint from `a_eng`, and
  the norm-image figure is a delta over the empty-image `d_norm` already
  inside. **No double count.**
* **346,971 is a value, not a draw.** TRACK SCATTER localised 94.5% of its
  1.55x area scatter to `gvr.wsel`, which exists only when the gain ROM is
  POPULATED -- and `compose4`'s image is empty. Every non-ROM point ever drawn
  twice in this project reproduced bit-identically. So the scatter caveat
  attaches to the norm-image term (C2) and **not** to the composed figure.
* **The MUXF7/F8 cross-check stands**: 37,268 here against CONGEST's 36,864,
  1.1%, two tracks and two designs.

### The soft joint, and the experiment that tests it

The step turning a survivable 95.6% LUT into 121% CLB is the **6.32 divisor**,
and it is an **n=1 measurement taken on a placement that had the whole die
free**. Packing density is elastic under pressure: a placer with room to spread
will spread. Section 15 is the experiment.


## 15. The pblock squeeze: is 6.32 LUT/CLB a property of the netlist or of an empty die?

**The soft joint in the whole fit argument.** Every percentage in section 12
divides by 6.32, and 6.32 was measured ONCE, on a `place_design` that had the
entire die available. Placers spread when they have room -- spreading reduces
congestion and improves timing, and this run had every incentive to do it
(congestion level 7, WNS negative). So 6.32 may describe **what that placer
chose to do** rather than **how densely this netlist can be packed.**

If density is elastic, the 121% is soft in the direction that reopens the fit
question, and it would be the one number in this document that is both load
bearing and unreplicated.

**The experiment.** One `place_design` of the SAME `c4_synth.dcp` -- no
synthesis, the checkpoint already exists -- inside a pblock holding about 85%
of the die's CLBs. The netlist is identical; only the room changes.

    PREDICTION FROM THE CLAIM   place_design FAILS, or density stays near 6.32
    CLAIM FALSIFIED IF          the same netlist packs into <= 48,000 CLBs

**A placer failure is the result that CONFIRMS the claim**, not an error, so
`place_design` is wrapped in `catch` and every exit path reports. Script:
`hw/fk33/results/timing_2026-08-30/pblock_squeeze.tcl`.

It is chained to launch only after the route unit exits and only after
`pgrep -x vivado` returns nothing, because two Vivado processes on this box is
the thing that destroyed the previous attempt at this design.

### RESULTS: the placer SUCCEEDED, and density is elastic

MEASURED, `place_design` of `c4_synth.dcp` into a pblock of 27 of 32 clock
regions:

    PS_DEVICE_CLB     54960
    PS_CHOSEN_CLB     46920   (85.4% of device)
    PS_PLACE_SECONDS  1351
    PS_PLACE_RC       0                       <- IT PLACED. It did not fail.
    PS_UTIL           lut 347906  clb 49497  f7 65108  f8 25788
    PS_DENSITY        7.029 LUT per CLB
    PS_WNS            -3.658

| | whole die free | pblock, 85.4% of die |
|---|---:|---:|
| LUT | 346,971 | 347,906 |
| **CLB** | **54,866** | **49,497** |
| **density** | **6.324** | **7.029** |
| derived non-mux density | 5.617 | **6.553** |
| WNS | -3.056 | **-3.658** |

**MY PREDICTION IS REFUTED ON BOTH LIMBS.** It said the placer would fail or
density would stay near 6.32. The placer succeeded, and density rose **11.1%**,
freeing **5,369 CLB (9.8%)** from the same netlist.

**The pre-registered falsification threshold was NOT met, and only just.** It
was "<= 48,000 CLB"; the measurement is **49,497**, which is 1,497 CLB (3.1%)
above it. So by the letter of the test the claim survives. By its spirit it
does not: the test existed to ask whether 6.32 was a property of the netlist or
of an empty die, and the answer is **of an empty die**.

### This falsifies C4's constant too, not just section 7a's

C4 replaced my inverted model with a decomposition calibrated on the
unconstrained placement, `D_nonmux = 5.617`. **That constant is an artefact of
the same free die.** Under pressure the non-mux logic packs at **6.553**. The
mux term is unaffected, as LEVERC's architectural argument requires -- it is
pinned at 8.00 by the CLB structure and cannot move.

Refitting every row with the MEASURED under-pressure constant:

| configuration | C4 (D=5.617) | **squeeze-measured (D=6.553)** |
|---|---:|---:|
| today + shell + ROM best draw | 123.5% | **110.1%** |
| today + shell + ROM worst draw | 138.2% | **122.7%** |
| + lever C + ROM best draw | 115.9% | **102.0%** |
| **+ lever C + gain to URAM** | **105.3%** | **92.9%** |
| + lever C + URAM + `d_norm` out | 94.7% | **82.7%** |
| + `d_norm` out + URAM, no lever C | 102.2% | **90.7%** |

**"Lever C + gain to URAM" moves from 105.3% (does not fit) to 92.9% (fits).**
That reverses C4's headline conclusion about how many levers are needed.

### And my withdrawn 93.2% was numerically right BY COINCIDENCE

This has to be said plainly because it is the most misleading thing in this
document. Section 7a's withdrawn estimate was **93.2%** for exactly this
configuration. The squeeze-measured figure is **92.9%**.

**That agreement is an accident of two errors cancelling.** Section 7a inflated
density for a reason that is architecturally backwards (it credited mux removal
with improving packing, when mux regions are the densest part of the design),
and it simultaneously under-estimated how dense the non-mux logic can be made
under placement pressure. The two mistakes were of similar size and opposite
sign.

**The number stays withdrawn.** A withdrawn claim that happens to land near a
later measurement is still withdrawn, because nothing about the reasoning that
produced it was right, and reasoning is what gets reused. LEVERC's correction
was and remains correct on the mechanism.

### THE CATCH, and it is the whole point

**The squeeze bought CLB capacity in exactly the currency this design has
already run out of.**

    WNS   -3.056  (whole die)   ->   -3.658  (squeezed)      0.602 ns WORSE

Denser placement means longer average net length per unit of logic and more
contention for routing resources. And the router **had already announced, at
the LOOSER 6.324 density, that `[Route 35-447] congestion is preventing the
router from routing all nets`.** At 7.029 it has less routing resource per
cell, not more.

**So "it fits by CLB count" and "it builds" are different claims, and this
experiment only moved the first one.** The honest statement is:

* **CLB capacity is more elastic than either model assumed**, by about 11%, and
  the lever target is correspondingly lower than C4 said.
* **Routability is not thereby improved and is probably worsened**, and
  routability is the failure actually observed on this design.
* A build that fits at 92.9% CLB **at 7.029 density** is a build the router has
  a harder job on than the one that already failed.

### What this experiment CANNOT settle

Even a falsifying result would not make the design fit. It would move the
divisor, and the divisor is only one of three terms; C2's norm-image range and
C3's floor-ness are untouched by it. Conversely a confirming result does not
prove 6.32 is a hard floor either -- it shows the placer could not do better
under **one** pressure setting, with **one** pblock shape, on **one** draw.


---

## 16. CORRECTION C4, 2026-08-30: my packing model had its SIGN inverted

**TRACK LEVERC challenged the direction of the packing argument, not its size,
and LEVERC IS RIGHT. My `k = 0.558`, my 6.82 LUT/CLB and my 93.2% row are
WITHDRAWN.** They were built on an inverted premise. The conclusion they
supported -- lever C alone does not close the fit -- survives, and is now
supported by arithmetic that runs the other way.

### The error

Section 7a assumed that MUXF7/F8 shapes CAUSE packing loss, and calibrated a
one-parameter model on that assumption. The premise is false.

**An UltraScale+ SLICE has 8 LUT6, 4 MUXF7, 2 MUXF8 and 1 MUXF9, and the
F7/F8/F9 muxes are DEDICATED hardware that does not consume LUT capacity.** So
a slice fully populated with F7-paired LUTs holds 8 LUTs and 4 F7 muxes and
sits at **8.00 LUT/CLB, the device maximum**. An indivisible mux shape costs
the placer FREEDOM, not LUT SITES.

**The codebook mux is the DENSEST structure in the design, not the loosest.
Removing it LOWERS the average density.**

### Adjudicated from my own census, which is why this is settled rather than argued

Decomposing the MEASURED placed design:

    MUXF7 65,108, so LUTs in F7 pairs   = 2 x 65,108        = 130,216
    at the architectural 4 MUXF7/CLB    = 65,108 / 4        =  16,277 CLB
    MUX REGION density                  = 130,216 / 16,277  =    8.00 LUT/CLB
    remainder                           = 216,755 LUT in 38,589 CLB
    NON-MUX density                                         =    5.62 LUT/CLB
    blended                                                 =    6.32  (MEASURED 6.32)

**The mux region is at the device maximum and the non-mux logic is what packs
at 5.62.** The 6.32 average is a blend of the two, and lever C removes from the
dense side.

Cross-check on the shipping routed build (171,458 LUT in 30,705 CLB, blended
5.58): implied non-mux density **4.96**. So the non-mux constant is
**4.96 .. 5.62** across the two builds visible to me, and both columns are
reported below.

### The corrected model, and it reproduces the calibration point

    CLB(LUT, F7) = F7/4 + (LUT - 2*F7) / D_nonmux,     D_nonmux = 5.62 (4.96 pessimistic)

Applied to the composed design it returns **54,846 CLB against the MEASURED
54,866** -- 0.04% error. That is one calibrated constant, not a fitted curve.

### The corrected fit table. THE 93.2% ROW WAS WRONG.

| configuration | LUT | CLB | of 54,960 | pessimistic | density |
|---|---:|---:|---:|---:|---:|
| today + shell + gain ROM (best draw) | 420,240 | 67,821 | **123.4%** | 135.8% | 6.20 |
| today + shell + gain ROM (worst draw) | 465,708 | 75,912 | **138.1%** | 152.5% | 6.13 |
| + lever C + gain ROM (best draw) | 382,364 | 63,684 | **115.9%** | 128.8% | 6.00 |
| + lever C + gain ROM (worst draw) | 427,832 | 71,774 | **130.6%** | 145.5% | 5.96 |
| **+ lever C + gain to URAM** | 349,421 | 57,822 | **105.2%** | 116.7% | 6.04 |
| + lever C + gain from HBM | 366,826 | 60,919 | 110.8% | 123.1% | 6.02 |
| **+ lever C + gain URAM + `d_norm` muxes out** | 306,208 | 52,006 | **94.6%** | 105.8% | 5.89 |
| + `d_norm` muxes out + gain URAM, NO lever C | 344,084 | 56,144 | **102.2%** | 112.8% | 6.13 |

> **PARTIALLY SUPERSEDED BY SECTION 15's MEASUREMENT.** The MECHANISM below is
> correct and stands -- mux regions are at 8.00 and lever C lowers average
> density. But `D_nonmux = 5.617` was calibrated on the SAME unconstrained
> placement that produced the 6.32, and the pblock squeeze MEASURED it at
> **6.553** under pressure. Every percentage in the table below is therefore
> too high by roughly 12 points. The refitted table is in section 15.

**What moves, and it is not small:**

* **"Lever C + gain to URAM" is 105.2%, not 93.2%. IT DOES NOT FIT.** This is
  the number that was relayed to Oren and it was wrong by 12 points.
* **Density FALLS with lever C, 6.32 to 6.10**, exactly as LEVERC predicted.
  Lever C's CLB saving is **4,138**, inside LEVERC's independently derived
  3,072..8,946 bound.
* **TWO levers are no longer enough. Three are.** Lever C plus the gain out of
  LUTs plus `d_norm`'s read muxes reaches **94.6%**, and that is the first row
  that fits.
* **LEVERC's flag about `d_norm` is confirmed and is stronger than it stated:
  `d_norm/gvr.u_rms` alone beats lever C alone.** 102.2% against 115.9% on the
  best ROM draw. It is 43,213 LUT and 17,696 MUXF7, it has **no
  write-coherency surface**, and it has **never been on silicon**, so it
  carries none of lever C's 32x risk.

### What does NOT change

The verdict of section 12a is unchanged and was already "yes, but not with one
change". The correction moves it from *two levers* to *three*, and reorders
them: **`d_norm` is now the first lever, not the third.** The fit claim, the
range discipline of C2, the floor-ness of C3, and everything in sections 1
through 6 -- the `vref_r` characterisation, the fix, and its verification --
are untouched by this.

### What I got wrong and why it survived review

The 97.7%/98.8% figures were applied correctly (to `a_eng`'s own census, giving
24,297 MUXF7 against LEVERC's structural 24,576 = 1536 x 16, agreeing to 1.1%),
so the INPUT to the model was sound. **The model itself was never checked
against anything.** It reproduced one point because it was calibrated on that
point, which is not evidence, and I labelled it ESTIMATE with its assumption
stated but did not ask what would falsify it. **A one-parameter model
calibrated on one point cannot be wrong about that point and cannot be right
about any other**, and that is exactly the shape of thing this project's
verification discipline says to distrust. It took a track with no census and a
correct architectural argument to catch it.


---

## 17. TRACK RMSMUX has MEASURED the lever I could only estimate

Landed at `5152e91` while this track's squeeze was running. It replaces the
single largest ESTIMATE in this document with three draws on real synthesis.

**MEASURED, `rmsnorm_rs` N=4096 LANES=4, BC-250, one session, one tool at a
time:**

    control  rmsnorm_rs      40,934 LUT   67,196 FF   17,408 MUXF7   8,704 MUXF8
    memory   rmsnorm_rs_mem   4,825 LUT    1,629 FF        0 MUXF7      0 MUXF8   +6 BRAM
    delta                    -36,109 (-88.2%)  -65,567 FF (-97.6%)  ALL F7/F8 -> 0

    timing: gives up 0.704 ns and STILL MEETS 200 MHz with 0.971 ns to spare
    scatter: the two identical-command draws are BYTE-IDENTICAL with matching
             census hashes, so SCATTER's 1.55x must NOT be applied to this number

**Against my section 8 estimate this is close and better founded.** I put
`d_norm/gvr.u_rms` at 43,213 LUT and 17,696 MUXF7 from the composed placed
census; RMSMUX's standalone control is 40,934 and 17,408 -- 5.3% and 1.6%
apart, the difference being composition against standalone. My "~43,213 LUT"
saving was optimistic: the replacement is not free, it costs 4,825 LUT, so the
net is **-36,109** rather than -43,213.

**And it costs 6 BRAM tiles of the 425.5 free**, which is the point I made in
section 8 from the other direction -- there is an idle memory subsystem beside
a LUT fabric being asked to hold vectors in flip-flops.

### The fit table with RMSMUX MEASURED and the squeeze-MEASURED density

Scaling the replacement to the composed instance (4,825 x 43,213/40,934 =
5,094 LUT, 0 MUXF7), so the net in-composition effect is **-38,119 LUT and
-17,696 MUXF7**:

| configuration (gain from URAM unless stated) | free-die D=5.617 | **under pressure D=6.553** |
|---|---:|---:|
| today + shell + ROM best draw | 123.5% | 110.1% |
| + RMSMUX only, + ROM best draw | 114.5% | 101.3% |
| **+ RMSMUX only, gain to URAM** | 103.8% | **92.1%** |
| **+ lever C only, gain to URAM** | 105.3% | **92.9%** |
| **+ RMSMUX + lever C, gain to URAM** | 96.3% | **84.1%** |
| + RMSMUX + lever C + ROM worst draw | 121.7% | 105.9% |

**Three things this settles:**

1. **RMSMUX and lever C are worth almost exactly the same** -- 92.1% against
   92.9%. My section 12a promotion of `d_norm` to first lever was right on
   ordering but overstated the margin; they are equals on area.
2. **RMSMUX is the better one to take first anyway, and for reasons that are
   not area.** It has no write-coherency surface, it has never been on silicon
   so there is nothing to regress, its draws are byte-identical (lever C's
   inference behaviour is still the open question LEVERC is on the lane for),
   and it **still meets 200 MHz with 0.971 ns to spare**.
3. **Both together reach 84.1%**, which is the first configuration in this
   whole document with genuine margin rather than a number that merely clears
   100%.

**The caveat from section 15 still governs all of it.** These are CLB-count
percentages at a density of 7.029 that was only achieved under placement
pressure, and that pressure cost 0.602 ns of WNS on a design whose observed
failure is `[Route 35-447]`, routing congestion. **Fitting by CLB count is not
building.** The next real question is not another area number; it is whether a
configuration in the 84% row ROUTES.
