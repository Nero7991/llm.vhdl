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
