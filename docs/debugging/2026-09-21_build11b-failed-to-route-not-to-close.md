# Build 11b did not miss timing. It failed to route, and the codebook owns it.

Date root-caused: 2026-09-21. Build: FK33_CARD=1, `xcvu33p-fsvh2104-2L-e`,
Vivado 2023.2, detached worktree `/mnt/storage/fk33_builds/wt11` at `5dc3ee5`,
core clock `clk_out3` 13.333 ns. Ran 2026-09-20 19:00 to 23:25.

## The question, verbatim

> Build 11b loop. It is failing comprehensively and will not close: post-place
> WNS -5.136 / TNS -236,998, routing iteration 1 WNS -4.491 / TNS -202,959,
> against build 9 (placed +0.533, shipped +0.061) and build 10 (placed +0.421,
> failed -5.819 / TNS -14,030). Build 11b's TNS is thirteen times worse than
> build 10's final. [...] DO NOT ATTRIBUTE WITHOUT THE REPORT.
>
> THREE live hypotheses: (a) the codebook change, (b) FAST_POP, (c) the placer's
> response to a netlist 19,344 flops SMALLER at 99.81% occupancy.

## The answer

**Hypothesis (a).** The per-row codebook (`0b34200`) exhausted the
interconnect, and Vivado named it: of the 40 nets listed as contending at the
top ten signal-overlap nodes, **38 are `bd_i/eng/inst/eng/dut/core/cb[][][]`**.

**And the question's own premise needs correcting. Build 11b never produced a
legal route, so it has no TNS comparable to build 10's.** It failed at
`write_bitstream` with 146,948 of 669,216 routable nets in resource conflict.
"Thirteen times worse TNS" compares a legal route against an illegal one; the
honest comparison is categorical.

**(b) is not exonerated and (c) is untouched.** Both changes were in this build
and no single-lever control was run.

## The procedure, in the order it was run, and what each step isolates

1. **Line-anchored `grep -E '^(FK33_BUILD_DONE|FK33_TIMING|ERROR)'`.** Gave
   `[DRC RTSTAT-13] Insufficient Routing`, `[Vivado 12-1345] Bitgen not run`.
   Isolates WHICH STAGE refused, and it was not the timing gate.
2. **`grep -nE '^(Phase|route_design|...)'` plus the unrouted-net counts.**
   This produced a contradiction worth keeping: `route_design completed
   successfully` and `Number of Unrouted Nets = 0` on one hand, RTSTAT-13 on
   the other. Isolates the fact that the log's summary lines cannot be trusted
   here.
3. **`report_route_status`, the authority.** Resolved the contradiction: 146,948
   nets have RESOURCE CONFLICTS, and a conflicted net counts as routed. Controls
   for the misleading "0 unrouted".
4. **`report_utilization` placed.** CLB 99.75% (138 of 54,960 tiles free) while
   CLB LUTs are only 92.21%. Isolates occupancy, not capacity, as the regime.
5. **Intra Clock Table.** clk_out3 holds -884,240 of the design's -884,687 TNS,
   99.95%. Controls for the possibility that a peripheral clock was the story.
6. **Worst-path grouping by source and destination.** Gave `gcr.gkvaxi.u_kv`,
   which is neither lever. **This step was a near-miss and step 8 is why it
   must not be read as an attribution.**
7. **Congestion search in the log.** Level 6 global/short, level 7 effective in
   three of four directions, `[Route 35-447] Congestion is preventing the
   router from routing all nets`. Isolates the failure MODE as routability.
8. **The top-ten signal-overlap table, counting the named nets.** 38 of 40 are
   `core/cb`. This is the attribution, and it is a naming table rather than an
   inference from a total.
9. **Provenance from the run's own tree, not from intent.** `wt11` at `5dc3ee5`,
   `FAST_POP := true`, per-row codebook present, SWEEP_PIPE and SCORE_EARLY
   absent AND defaulted false at `attn_block.vhd:259,285`. Controls the
   what-differs question.
10. **Build 10's recorded parameters.** `b71a6d9`, `FAST_POP := false`,
    `0b34200` NOT an ancestor, built from the LIVE repo. Establishes that the
    build-10-to-build-11b delta is multi-variable and cannot carry the
    codebook's cost.

## The evidence, as captured output

```
ERROR: [DRC RTSTAT-13] Insufficient Routing: A signficant portion of the design is not routed.
ERROR: [Vivado 12-1345] Error(s) found during DRC. Bitgen not run.
CRITICAL WARNING: [Route 35-162] 146948 signals failed to route due to routing congestion.
WARNING: [Route 35-447] Congestion is preventing the router from routing all nets.
INFO: [Route 35-448] Estimated Global/Short routing congestion is level 6 (64x64).
WARNING: [Place 46-14] The placer has determined that this design is highly congested.
route_design completed successfully          <-- and it did not
  Number of Unrouted Nets             = 0   <-- and this is true and useless
```

```
   # of routable nets..................... :      669216 :
       # of fully routed nets............. :      522268 :
   # of nets with routing errors.......... :      146948 :
       # of nets with resource conflicts.. :      146948 :
```

Contending nets across all ten top overlap nodes, counted with indices
collapsed:

```
     38 bd_i/eng/inst/eng/dut/core/cb[][][]
      1 bd_i/jtag_axil/inst/jtag_axi_engine_u/cmd_valid_wr_ch
      1 bd_i/eng/inst/eng/dut/core/xq_reg_0_1_84_97/DOE1
```

Placed area, build 10 against build 11b (MULTI-VARIABLE, see the traps):

```
CLB          54,751 (99.62%) -> 54,822 (99.75%)
CLB LUTs        361,361 -> 405,434   (+44,073)
LUT as Logic    295,786 -> 352,163   (+56,377)
LUT as Memory    65,575 ->  53,271   (-12,304)
CLB Registers   308,213 -> 296,396   (-11,817)
F7 Muxes         28,422 ->  53,022   (+24,600)
F8 Muxes          6,027 ->  18,315   (+12,288)   <-- CBRAM predicted 0 -> 12,288
DSP               2,087 ->   2,087   (0)         <-- control, did not move
URAM                 32 ->      32   (0)         <-- control, did not move
```

## Measured and REJECTED -- do not retry

- **Do not use `route_design completed successfully` as a completion signal, and
  do not use `Number of Unrouted Nets = 0` as a routing result.** Both appear in
  this build and both are wrong about the outcome, because a net with a resource
  conflict is counted as routed. Only `report_route_status`'s
  "nets with routing errors" row settles it. This is the project's recorded
  "a completion signal that also fires on failure" trap, in a new place: here
  the tool reports that IT finished, not that the WORK is valid.
- **Do not attribute from `report_timing_summary`'s worst-path list.** It
  samples ten paths per clock group. Here it yields 65 paths against 494,527
  failing endpoints, and all ten worst point at `gcr.gkvaxi.u_kv` in subsystem
  C, which is neither lever and which had nothing to do with the failure. Had
  the investigation stopped at step 6 it would have written up C's KV reader.
  **In a design with 146,948 conflicted nets, the worst path is wherever the
  conflict landed hardest, not where the cause lives.**
- **Do not compare build 11b's routed WNS/TNS with build 9's or build 10's.**
  -9.762 / -884,687 is computed over overlapping routes. It is not a slack. The
  intermediate figures tracked during the run (-5.136 / -236,998 placed,
  -4.491 / -202,959 at routing iteration 1) are pre-legality numbers and this
  project already records that nothing before a clean route orders two runs.
- **Do not quote +44,073 LUT as the codebook's area cost.** Build 10 and build
  11b differ in FAST_POP (false to true), in the codebook, and in five RTL
  files totalling +896 lines; and build 10 read the LIVE repo tree so its exact
  input is not recoverable from a commit. Two live variables.
- **Do not conclude FAST_POP is fine.** It is absent from the congestion
  evidence, which is not the same as cleared. Its three clearances on
  2026-09-20 (POPCOVER, POPPORT, DESCARM) are all FUNCTIONAL; none is an area
  or timing result, and it has never been placed on the card alone.
- **Memory was not a factor and does not need investigating.** Swap flat at
  13G, MemAvailable 11,966-13,814 MB throughout, Vivado peak 15,012 MB against
  a 24G cap, guard never fired.

## Measurement traps hit, including my own

- **I was tracking the wrong quantity for four hours.** The loop was watching a
  timing series and comparing TNS against build 10, and the build was never
  going to be judged on timing. The intermediate WNS values were real and
  irrelevant. The tell was available at the first anchored grep: the error is a
  DRC on routing, not a timing report.
- **The worst-path grouping produced a confident, specific, wrong answer**
  (`gcr.gkvaxi.u_kv/GEN_RD[0].r_beat_reg[5]`, ten paths, one startpoint, a
  clean story about a register fanning to a bank of clock enables). It looked
  exactly like an attribution. What saved it was asking why a ten-path list
  should describe 494,527 endpoints.
- **An earlier session quoted 672,531 core-clock endpoints for "build 9".**
  That figure belongs to the 200 MHz ENGINE-ONLY pcieep build and to no card
  build. Build 11b's core clock has 1,147,256 endpoints and the design 1,382,636.
  Cross-configuration borrowing, already recorded, done again.
- **The build-10 comparison's controls are good and on a neighbouring axis.**
  DSP 2,087 in both to the digit and URAM 32 in both are genuine same-stage
  controls, and they justify the SHAPE argument (memory LUTs and flops down,
  logic LUTs and muxes up). They do not license the MAGNITUDE, because the two
  runs differ in more than one live variable. This is the recorded "a control
  on the wrong axis reads as rigour" trap: the right controls for a shape claim
  are not the right controls for a cost claim.
- **`grep -E '^(...)'` was anchored, and that mattered.** The build log embeds
  the script that writes it.

## Open, not yet answered

- The codebook's isolated area, flop and fanout cost. TRACK CBOOC's two-arm OOC
  at `CBO_TARGET=matvec_int4_desc_axi` was launched on the workstation on
  2026-09-21 06:50 with the registered predictions FF -19,344, LUT 0, and max
  `cbw_*` fanout 1,537 to 49. TRACK CBRUN is running four arms
  (old/new/fan/bcast) at `matvec_core` on the BC-250.
- Whether `bcast` restores routability. Registered falsifier: if it does not,
  CBRAM's mechanism is wrong and must be redone rather than patched.
- FAST_POP's area and timing cost on the card, alone.
- Whether a revert is SUFFICIENT for build 12, which also proposes FAST_POP,
  SWEEP_PIPE and SCORE_EARLY, none of which has been placed on this card.
- What share of the 146,948 conflicts is `cb`. 38 of 40 is a top-ten sample.

## Artefacts

`hw/fk33/results/card_build11b_FAILED_2026-09-20/` holds the route status, the
congestion report, the overlap table, the placed utilization and the gzipped
routed timing summary. Placed-stage area analysis of the same build is in
`hw/fk33/results/card_build11b_2026-09-20/` (TRACK PLACEDIFF). Synthesis,
placed and routed checkpoints with sha256sums are at
`/mnt/storage/fk33_builds/KEEP_build11b_dcp/`.

---

# CORRECTION 2026-09-21, same day: the answer above named the wrong cause

Appended in place. The superseded claim is marked withdrawn, not deleted,
because it was committed (`166a32d`) and reported.

**WITHDRAWN: "Hypothesis (a). The per-row codebook (`0b34200`) exhausted the
interconnect."**

**The cause is `CB_STYLE=regs`, a launch-environment value that nobody chose.
`0b34200` was the identity function in build 11b and did nothing.**

MEASURED, two instruments, three builds (TRACK CBREVERT `1cc7cbf`):
`^FK33_CB_STYLE` sentinel 1/1/**0**, and Vivado's `Parameter CB_STYLE bound to`
`distributed` x4 / `distributed` x4 / **`regs` x4**. At `regs`, `matvec_core`
sets `dont_touch=true` and `ram_style=registers` on `cb` so the inference is
FORBIDDEN, and `CB_COPIES` is 48 rather than 1,536, making
`CB_RANKS = min(48,48) = 48` and `cb_rank_of(c) = c`.

MEASURED from the netlist (TRACK CBCENSUS `e240fbb`, preserved synthesis DCP,
sha256 verified): `core/cb` is 6,144 FDRE behind 24,576 MUXF7 + 12,288 MUXF8.
DERIVED: 6,144 = 48 x 16 x 8 is the `regs` geometry; a 16:1 one-bit mux is
4 LUT6 + 2 MUXF7 + 1 MUXF8, so 1,536 lanes x 8 bits is exactly the measured
12,288 / 24,576. DERIVED: 18,315 - 12,288 = 6,027 = build 10's whole-design F8
total, so build 10 cannot have held this tree.

The routing failure, the 146,948 conflicts, and the 38-of-40 attribution to
`core/cb` all STAND. What falls is only the step from "the codebook object
congested" to "the codebook commit did it".

## Add to "Measured and REJECTED -- do not retry"

- **Do not enumerate what differs between two card builds from their commits
  and RTL diff alone. The LAUNCH ENVIRONMENT is part of the configuration and
  it is not in any commit.** This file's own "MULTI-VARIABLE" section listed
  two commits and five RTL files and was still wrong, because `CB_STYLE` lives
  in a `systemd-run --setenv` list. Read `Parameter <NAME> bound to` out of both
  logs and diff THAT. Build 11b's full parameter diff against build 10 is four
  entries (`CB_STYLE`, `CLKOUT2_DIVIDE` 16->6, `FAST_POP` 0->1, `HDR_TREE`
  added), and only the first mattered.
- **Do not treat the absence of a `[Synth 8-5859]` message as evidence about an
  inference.** I wrote that build 11b's log "says nothing either way" and
  presented it as a finding. Build 10 carries
  `[Synth 8-5859] Recognized 3D RAM cb_reg [rtl/matvec_core.vhd:692]`; build
  11b lacks it because no inference was ATTEMPTED. An absence distinguishes
  "declined", "not attempted" and "not reported" not at all.
- **A sentinel nothing refuses on is decoration.** `^FK33_CB_STYLE` existed,
  already read 0 for this build, and was printed into a log nobody gated on.
  The fix is a refusal, not a better sentinel. TRACK CBGUARD owns it.

## Add to "Measurement traps hit, including my own"

- **I attributed the failure to the change the build was FOR.** The build was
  launched to test `0b34200`, the congestion named `core/cb`, and the two were
  joined without checking whether the commit was even active. It was not. This
  is the same shape as the withdrawal at `a3cb844` the previous night, which
  this file cites as a warning three sections above, committed one hour before
  making the same error.
- **Naming the object correctly is not naming the cause.** 38 of 40 overlap nets
  being `core/cb` was a sound measurement and remains one. It bounds WHERE, and
  says nothing about WHY that object had the shape it had.
- **The OOC's "context divergence" conclusion was also wrong, and for the same
  reason.** `hw/fk33/results/cbooc_descaxi_2026-09-21/README.md` concluded that
  Vivado maps the same RTL differently in and out of context, because the OOC
  reported `cb_ram=26112` while the card had a mux tree. There was no context
  effect: the OOC ran at `distributed` (its 1,537 fanout proves it) and the card
  ran at `regs`. A real recorded phenomenon was invoked to explain a plain
  parameter difference, which made the wrong answer feel well-grounded.

## Open items updated

- The codebook lever's cost in the card context is still UNKNOWN. Builds 9 and
  10 predate it; 11b drew it as the identity. The only measurement of it is
  CBOOC's out-of-context `FF -19,345`, and that is a SAVING.
- Build 10's -5.819 legal-route timing failure remains unattributed. It is now
  the only unexplained card failure.
- Build 12 (launched 2026-09-21 08:2x) is the control Oren chose: build 9's
  lever state at current HEAD plus `FK33_CB_STYLE=distributed`, with NWIDE,
  FAST_POP, SWEEP_PIPE and SCORE_EARLY all OFF, to re-establish that HEAD routes
  at all before any lever is charged for a failure.

---

# CORRECTION 2, 2026-09-21: `[Synth 8-5859]` IS NOT AN INSTRUMENT, AND MY OWN CORRECTION REASONED FROM ITS ABSENCE

Appended in place. This corrects CORRECTION 1 above, not the original text.

CORRECTION 1 says build 11b "lacks it because at `regs` no inference was ever
ATTEMPTED". **The conclusion is right and the reason given for it is not
supported**, and it is the same error CORRECTION 1 was written to fix: drawing
an inference from the absence of a message.

MEASURED by TRACK CBRUN (`e89ca12`), four OOC arms at `CB_STYLE=distributed`
and the card's geometry: the anchored count of `8-5859` naming `cb_reg` is
**0 in all four arms**, while the same runs' mapping reports name **1,536
RAM32M16 copies** in each and `get_cells` gives `cb_ram=26112, cb_ff=0`
identically. So **the recognizer message is absent in runs where the inference
DEMONSTRABLY SUCCEEDED.** Its absence is compatible with success, with refusal
and with non-attempt alike, measured four times.

`26,112 = 1,536 x 17` = 14 RAMD32 + 2 RAMS32 + 1 RAM32M16 per copy (DERIVED).

**What still stands, on different evidence:** that `cb` is registers-plus-mux
in build 11b. That rests on TRACK CBCENSUS's object-level census of the
preserved synthesis checkpoint (6,144 FDRE, 24,576 MUXF7, 12,288 MUXF8, and a
distributed-RAM count anchored exactly against `report_utilization`), not on any
message being present or absent. The census was always the load-bearing
evidence; the sentence about 8-5859 was decoration that asserted a mechanism.

**The rule: `[Synth 8-5859]` may be quoted as evidence only when PRESENT, and
never as evidence when absent.** CLAUDE.md already records that Vivado's
inference log lies in both directions and that only the mapping report and an
object-level census are authoritative. This is that rule applying to a message
this project had started treating as a reliable negative.

## Also measured and worth keeping

- **CBRAM's mechanism is REFUTED.** The codebook's write-statement FORM does not
  gate the RAM inference in either direction: `old`, `new`, `bcast` and `fan`
  all infer identically to the digit. The registered `MUXF8 0 -> 12,288`
  measured **0 -> 0** at `distributed`, which is itself confirmation that the
  12,288 belonged to `regs`.
- **Two arms were secretly one.** `fan` is byte-equivalent to `new` in the
  netlist: identical cells, nets and pins (171,716 / 2,046,259 / 4,708,060) and
  `cbx_any=0`, so its aliases do not exist after elaboration. Same shape as the
  `regs` null where two arms are provably the same design, and the same lesson:
  **an arm that cannot differ is not a control.**
- **The outlier command net is the VALID bit, and it is outlying because it is
  SHARED.** Of its 128 loads at `matvec_core`, exactly 48 (`= CB_RANKS`) are
  `cbw_v` flops and **80 are pins elsewhere in the core**; the twelve
  address/data bits are top-level ports with `to_other=0` and fall to exactly
  48 as predicted. That is why the measured figure is context-dependent -- 108
  at `matvec_int4_desc_axi`, 128 at `matvec_core`, never the registered 49.
  **The prediction was not wrong about the mechanism, it was wrong to assume
  the net had only the loads the lever creates.**
- **All four arms HIT their 8G cap** (`cgroup_peak=8195 MB`, `at_cap=YES`), so
  none of their `memory.peak` figures is a footprint. Vivado's own accounting
  gives 3,941 MB for `old`.

## Registered before build 12 lands

At `CB_STYLE=distributed`, HEAD's codebook infers as 1,536 RAM32M16 with
**MUXF8 = 0** in the codebook. So build 12's synthesis should NOT carry the
12,288-MUXF8 tree. **If it does, the cause is not `0b34200` and not `CB_STYLE`,
and this whole line of attribution fails.** Recorded here before the report
exists.

---

# CORRECTION 3, 2026-09-21: BUILD 11b ALSO RAN AT 200 MHz. ITS TIMING NUMBERS ARE AGAINST A 5.000 ns PERIOD, NOT 13.333.

Appended in place. This is the third correction to this document and the second
to find a silent default nobody chose.

**WITHDRAWN: the Intra Clock Table section's statement that `clk_out3` had a
period of 13.333 ns in build 11b, and every comparison of build 11b's WNS or TNS
against build 9's or build 10's.**

MEASURED by TRACK CBGUARD (`3e344a2`), from each build's own generated Tcl and
its own routed report:

```
build 10   CLKOUT3_REQUESTED_OUT_FREQ {75.000}    Clock Summary: 13.333  75.000
build 11b  CLKOUT3_REQUESTED_OUT_FREQ {200.000}   Clock Summary:  5.000 200.000
build 11   CLKOUT3_REQUESTED_OUT_FREQ {200.000}
```

`FK33_ENG_CORE_MHZ` defaults to `200.000` at `hw/fk33/gen_pcieep.py:515`, and
`hw/fk33/pcieep_build.sh` never sets it. **The card has never closed above
75 MHz.** Ground truth across the twelve recorded implementation runs: 7 of 7
that produced a bitstream ran at 75 MHz, and build 11b is the sole outlier.

So build 11b was retargeted to a clock **2.67x faster** than the design has ever
met, by a default, silently.

DERIVED, and it changes the magnitude entirely: WNS -9.762 against a 5.000 ns
requirement puts the failing path at about 14.762 ns. Against the real 13.333 ns
period that is a WNS of roughly **-1.4 ns**, not -9.8. (Approximate: clock
uncertainty and skew are not strictly period-independent. The point is the order
of magnitude, not the digit.) **Build 11b's timing was never the catastrophe this
document reported. It was an over-constraint.**

## And this is now the SECOND candidate cause of the routing failure

CORRECTION 1 established `CB_STYLE=regs` and a 12,288-MUXF8 mux tree, measured
in the netlist by CBCENSUS, which is not in doubt. But a **200 MHz target at
99.75% CLB occupancy is a first-order congestion mechanism in its own right**:
the placer packs for timing, and the router said outright that it was abandoning
timing to route at all. No document had considered it, including CORRECTION 1.

**So why build 11b failed to route is LESS settled than it was this morning, not
more.** Two silent defaults, both first-order, both plausible, and they are not
separable from the evidence that exists. A 75 MHz control needs a fresh
synthesis, because the preserved checkpoint was synthesised at 200.

## The parameter that three tracks published as noise

CBCENSUS listed build 11b's parameter diff as four entries and called
`CLKOUT2_DIVIDE 16 -> 6` unexplained. **That WAS the retarget.** DERIVED:
`250 / DIVCLK 5 = 50`, `x MULT 24 = VCO 1200`, and `1200/16 = 75` against
`1200/6 = 200`, exactly. The number was printed, sorted, and published as drift
by three separate tracks, including by me.

## Measured and REJECTED, added

- **Do not read a WNS without reading the REQUIREMENT it was measured against.**
  This document's per-clock table carried a period taken from what the card's
  clock is SUPPOSED to be, not from the run's own Clock Summary, which was in
  the same report and said 5.000. The requirement is a recorded parameter like
  any other.
- **Two silent defaults in one launch are not twice as easy to find as one -
  they are harder, because the first one found explains the symptom well enough
  to stop the search.** `CB_STYLE=regs` produced a measured, netlist-visible,
  arithmetically exact mux tree. It was a satisfying answer and it ended the
  investigation with a second, equally silent, equally first-order variable
  still in place.
- **A configuration is not diffable from the commits, the RTL, OR the generated
  file.** MEASURED by CBGUARD, and this is the most damning number in the whole
  episode: under the pre-change generator, an explicit
  `FK33_CB_STYLE=regs FK33_ENG_CORE_MHZ=200` and stating NOTHING AT ALL emit Tcl
  differing in **8 lines, all of them inside the GENSTAMP comment** - and build
  11b has no GENSTAMP at all, because `wt11` predates `952e70a` by 78 minutes.
  **Every byte Vivado executed was identical.** No diff of any artefact could
  have found this. Only a refusal at launch could, which is what now exists.

## Status

Build 12 was launched at 08:19 and **was also at 200.000**, because I set
`FK33_CB_STYLE` and not `FK33_ENG_CORE_MHZ`. It was killed at ~09:05 after ~46
minutes rather than spending 3.5 more hours on an uninterpretable result. Build
12b relaunched from worktree `wt12b` at `3e344a2` with BOTH stated, verified from
the emitted Tcl: `CLKOUT3_REQUESTED_OUT_FREQ {75.000}` and `CONFIG.CB_STYLE`
count 3, matching build 10 exactly where build 11b had 200.000 and 0.

CBGUARD's refusal was teeth-tested on the real path and **would have refused
build 12's original launch**: omitting `FK33_ENG_CORE_MHZ` gives rc=1 naming
that lever, omitting both gives rc=1 naming two, and stating both gives rc=0.
