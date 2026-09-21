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
