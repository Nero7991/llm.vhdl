# Build 10, 2026-09-20: FAILED TIMING at -5.819 ns on the core clock

## The question

Build 10 carried the KV-base seam register plus PIPE, WIDE, MAXOUT8 and
NWIDE on `u_state`, on top of build 9 (`card_kvreg_2026-09-20`, which
shipped at WNS +0.061 ns and runs the card at 2.46 tok/s). Expected
B_JOB 15.85M -> ~5.7M cycles and the token 30.1M -> ~20M, i.e. ~3.7 tok/s.
Did it close timing?

## The answer

**No. MEASURED routed `WNS -5.819 ns, TNS -14,030.521, 17,248 failing
endpoints of 1,523,409`, hold met at 0.000.** 17,194 of the 17,248 are on
`clk_out3_bd_clk_wiz_0_0`, the 75 MHz core clock.

**The failure is NOT in the blocks the levers touched.** Every one of the
ten worst paths runs from a single register in subsystem A's engine:

    SRC  bd_i/eng/inst/eng/cb_addr_reg[2]/C
    DST  bd_i/eng/inst/eng/dut/core/cbw_a_reg[894][2]/D      -5.819 ns
         ... [701], [486], [859], [852], [1119] ...

Register to register with no logic between, so the 5.819 ns is **pure net
delay**. `rtl/matvec_core.vhd` last changed at `a4828ab` on 2026-08-30,
three weeks before build 9, so this RTL is IDENTICAL in both builds. What
changed is the area around it: the levers grew the `card` block, and A's
codebook command net could no longer be routed inside the period.

DERIVED, and it accounts for nearly the whole failure: `matvec_core.vhd:260`
sets `CB_COPIES = (ROWS_IF*BLK + CB_LANES_PER_COPY - 1) / CB_LANES_PER_COPY`,
up to 1,536 replicas at `ROWS_IF=48, BLK=32`. Each holds a 4-bit address,
8-bit data and a valid, so about **19,968 flop D-inputs fed from one
source**, against 17,194 failing endpoints.

## Procedure, in the order run

1. `grep -nE 'Intermediate Timing Summary'` on both builds' logs, ALIGNED BY
   ROUTE PHASE rather than by position. Build 9: +0.533 post-place, then
   -0.818, -0.383, -0.012, +0.061 across global iterations 1-4, improving
   monotonically. Build 10: **+0.421 post-place** (so synthesis and
   placement were HEALTHY), then -1.372, **-10.110**, -7.614. It got an
   order of magnitude worse between iterations 1 and 2.
2. A second control, `card_seqrst_2026-09-19_ROUTEFAIL`, to see what a
   *routability* failure looks like: it died at -1.194 with 9,293
   partially-conflicted nets. Build 10 drove overlaps to **0**, so it is a
   pure timing failure and did produce a bitstream.
3. The **Intra Clock Table**, not the headline, to find which clock carries
   it. `clk_out1` +4.574, `pcie_refclk` +7.146, `sysref_clk` +0.165,
   `fk33_dmabram_BRAM_PORTA_CLK` -0.109 (54 endpoints, minor), and
   `clk_out3` **-5.819 with 17,194 failing**.
4. The violated paths' sources and destinations, grouped, to attribute.
5. `git log -1 -- rtl/matvec_core.vhd` to establish the RTL did not move.

## Measured and REJECTED -- do not retry

- **A route directive will not fix this.** `[Physopt 32-745]` states the
  negative slack is too large to improve, and its own advice threshold is
  "WNS above -0.5ns" against -5.819. The failing path is ONE net with
  ~1,536 sinks and no logic in it; directives change wire choices and do
  not shrink a fanout.
- **Do not read the -7.262 figure.** It appears in the post-route physopt
  "Current Timing Summary" and in the phase logs, and it is an INTERMEDIATE
  value. The final routed report says -5.819. This dispatcher reported
  -7.262 to Oren before the routed report was written.
- **Do not attribute this to PIPE, WIDE, MAXOUT8 or NWIDE individually.**
  The evidence supports only that their combined AREA displaced A's
  codebook net. No single-lever control was run.

## Measurement traps hit, including this dispatcher's own

- **The "endpoint count doubled" claim was WRONG and is withdrawn.** It
  compared build 10's 1,287,987 core-clock endpoints against "672,531",
  which comes from `docs/debugging/2026-09-05_cross-machine-bitstream-identity.md`
  -- the **engine-only `pcieep` build at 200 MHz**, not a card build. That
  is precisely the cross-configuration borrowing CLAUDE.md warns about, and
  it was done while that file was open. **Build 9's endpoint count is
  UNKNOWN**, because only the `FK33_TIMING` sentinel was committed.
- **Build 9 committed no timing report**, only `timing.txt` holding two
  sentinel lines. So the most useful control for this failure did not
  exist and had to be reconstructed from its `build.stdout`. **Commit the
  routed timing summary for every build from now on**; that is why this
  directory exists for a build that failed.
- The build log contains the Tcl that writes it, so every sentinel grep
  here is line-anchored (`^FK33_`). An unanchored grep matches the script's
  own echoed source.

## Open, not determined

- Whether fixing the codebook fanout lets build 10's levers close, or
  merely moves the failure to the next-worst structure. The levers grew the
  design; the codebook is where it broke FIRST, not necessarily the only
  place it would break.
- Which individual lever contributes most area. Never measured.
- Whether `cb_addr -> cbw_a` can take a multicycle constraint.
  `matvec_core.vhd:266-278` states the invariant that all replicas are
  written in the SAME cycle, deliberately, because a master-then-broadcast
  window is a silent-wrong-answer defect. `cbw_a(c) <= cb_addr` is also
  unconditional every cycle, so a multicycle is not constraint-only work.
- Build 9's endpoint count and worst path, both unrecorded.

## Artefacts

    timing_summary_routed.rpt.gz   the full routed report
    utilization_placed.rpt         placed utilization
    build.stdout.tail.gz           last 3 MB of the build log

Checkpoints kept OUTSIDE the repo, on a separate device, because build 9's
were destroyed by a drive cleanup:

    /mnt/storage/fk33_builds/KEEP_build10_dcp/build10_synth_bd_wrapper.dcp   571 MB
    /mnt/storage/fk33_builds/KEEP_build10_dcp/build10_placed_bd_wrapper.dcp  318 MB

---

## CORRECTION 2026-09-20, appended in place: THE AREA ATTRIBUTION ABOVE IS NOT SUPPORTED BY THE TREE

This file says the levers "grew the `card` block, and A's codebook command
net could no longer be routed inside the period." **That claim was never
measured and the one piece of evidence available contradicts its direction.**

MEASURED by TRACK LEVERBOARD (`3caad6a`) against `card_swg`'s placed report,
build 10 placed:

    CLB   -103
    LUT   -1,734
    FF    -768
    BRAM  +28

**Smaller, not larger, in every logic resource.** Only BRAM grew.

**And the control that would actually settle it does not exist.**
`grep -c 'CLB LUTs' hw/fk33/results/card_kvreg_2026-09-20/build.stdout`
returns **0**: build 9, the build immediately before this one and the only
honest comparison, **committed no placed report at all**. So the pair that
would test "the levers grew the card block" has never been made, and
`card_swg` is a DIFFERENT build, which makes it the same
cross-configuration borrowing this file already records itself committing
once (the 672,531-endpoint figure).

### What survives, and what is withdrawn

SURVIVES, all MEASURED and unaffected:
  * routed WNS -5.819 ns, TNS -14,030.521, 17,248 failing endpoints of
    1,523,409, 17,194 of them on `clk_out3`;
  * every one of the ten worst paths running from `eng/cb_addr_reg` to the
    codebook command replicas, register to register with no logic between,
    so the slack is pure net delay;
  * `rtl/matvec_core.vhd` unchanged since `a4828ab` on 2026-08-30, so that
    RTL is identical in builds 9 and 10;
  * the DERIVED ~19,968 flop D-inputs from one source against 17,194
    failing endpoints, which is why the codebook is the right thing to fix.

WITHDRAWN: that the levers' AREA is what displaced the net. The mechanism
is plausible and remains the leading hypothesis, but it is a HYPOTHESIS and
this file stated it as the cause.

### The honest statement

The failure is the codebook command net. **Why that net became unroutable
in build 10 and not in build 9 is NOT DETERMINED.** Area is one candidate;
placement seed, the SpreadLogic directive interacting with a different
netlist, and the BRAM growth are others, and none has been tested.

### Why it happened, which is the reusable part

This is the project's own recorded failure repeated: *"ENUMERATE WHAT
DIFFERS BETWEEN TWO RUNS FROM THE RUNS' OWN RECORDED PARAMETERS, NEVER FROM
THE INTENT OF WHOEVER LAUNCHED THEM."* The dispatcher knew what build 10
was FOR -- adding four levers -- and reached for area because area was the
thing being added. It then found a real defect (the 1,536-sink net), and an
agreeing downstream result made the whole chain feel settled. **A correct
diagnosis of the SYMPTOM does not validate the story about the CAUSE**, and
this file had already written that same lesson down two sections earlier
about a different number.

**The fix is infrastructural, not a resolution to be more careful.** Three
attribution questions failed this evening on the same missing evidence --
a per-subsystem area figure that `report_utilization` never emitted because
nobody passed `-hierarchical`, and a placed report build 9 never committed.
Both are kilobytes, produced at zero marginal cost by a build that already
ran four hours. TRACK BUILDREPORT is making every `FK33_CARD=1` build emit
and commit them.

---

## CORRECTION 2026-09-21, appended in place: THE FAILURE IS SPREAD, AND THE CODEBOOK IS NOT THE WHOLE ACCOUNT

Full write-up and procedure:
`docs/debugging/2026-09-21_build10-is-spread-not-the-codebook.md` (TRACK B10WHY,
no Vivado run).

This file says "**The failure is NOT in the blocks the levers touched**" and
that the codebook fanout "**accounts for nearly the whole failure**". The first
half stands. The second is **WITHDRAWN**: the codebook owns the WNS and is not
the whole failure.

MEASURED, from artefacts that already existed:

* `bd_wrapper_methodology_drc_routed.rpt`, written from the SAME fully-routed
  design two minutes before the timing summary, lists **1,000 TIMING-16
  violations of which all 1,000 are in `bd_i/card/inst/u/gcr.gkvaxi.u_kv`**
  (subsystem C), from ONE source pin `GEN_RD[1].ph_ch_reg[0]/C`, at -1.000 to
  -2.131 ns. `grep -c 'cbw_a\|cb_addr'` on that file is **0**. That module is
  the WNS owner in BOTH card builds that closed (+0.452 and +0.299) and its
  path is a **34-level, 17-deep CARRY8 chain**, not a fanout problem. Extract
  committed here as `timing16_violations.tsv`.
* A **second clock domain** failed: `fk33_dmabram_BRAM_PORTA_CLK` (250 MHz) is
  **-0.109 ns on 54 endpoints** against **+0.054** and **+0.049** in the two
  builds that closed -- with its endpoint count **202,652 against 202,657 and
  202,658**, a difference of five in 202,658. Nothing in that domain changed.
* DERIVED: `TNS -14,026.255 / 17,194 = -0.816 ns mean violation`. The 17,194 are
  a long tail, not 17,194 paths at -5.8.

**The area claim is now refuted with a SECOND control, not merely unsupported.**
`card_seqrst_bfnorm_2026-09-19` closed at **+0.452** with **54,839 CLB /
367,685 CLB LUTs / 308,140 FF**, all larger than build 10's 54,751 / 361,361 /
308,213. Two larger builds closed on the **same three directives**
(`AltSpreadLogic_high` / `AggressiveExplore` / `AlternateCLBRouting`, MEASURED
identical in build 9, build 10 and seqrst) at the same 75 MHz.

**"Build 10 = build 9 + four levers" is also wrong.** Build 9 is `3180646`
(DERIVED from a commit 4 minutes before its 07:37:34 start; build 9 read the
LIVE tree and recorded no HEAD, so this is an identification, not its input).
`git diff --name-only 3180646 b71a6d9 -- 'rtl/*.vhd' 'hw/fk33/rtl/*.vhd'`
returns **19 files**, six of them in subsystem A. `rtl/matvec_core.vhd` is
indeed unchanged; `rtl/matvec_int4.vhd` gains an unconditional `dbg_sstarve`
output and `async_fifo`/`stream_fifo` restructure their pop condition.

**AND THE ROUTED DCP EXISTS.** This file and `KEEP_build10_dcp/README.txt` both
imply only synth and placed checkpoints survive. The whole build tree at
`/mnt/storage/fk33_builds/build10/root` survived, routed DCP, bitstream and all
reports included; the bitstream's md5 matches this build's `FK33_AUTOSAVE`
sentinel. The routed DCP is now preserved as
`KEEP_build10_dcp/build10_routed_bd_wrapper.dcp`.

Also committed here, from that tree: `fk33_pcieep_congestion.rpt` (the pressure
is `gcr.u_attn/u_arr` at 31-74% of every level-5/6/7 window with `RAMB 100%`),
`fk33_pcieep_pblock_util.rpt`, `fk33_pcieep_engine_util.rpt`, `route_status.rpt`
(0 nets with routing errors).

### What the evidence now supports

The failure is **SPREAD**: three independent structures in three subsystems and
two clock domains, one of whose contents provably did not change. The common
factor is placement/routing pressure -- build 10's timing congestion is
**level 6 (64x64)** against build 9's **level 5 (32x32)**, route time 1.88x, and
the intermediate WNS collapsed -1.372 -> -10.110 in one global iteration where
build 9 recovered monotonically. **Which of the nineteen commits caused that is
still NOT DETERMINED**, and on this evidence fixing the codebook fanout should
be expected to move the WNS rather than to close the design.
