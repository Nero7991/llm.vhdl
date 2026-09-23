# Build 17 composition (prepared 2026-09-22 18:22, NOT launched; awaits draw 3b's verdict and Oren's choice)
Tree: worktree /mnt/storage/fk33_builds/wt17 at f14121d (HEAD) + build12_levers_off.patch (levers OFF: FAST_POP,
  NWIDE, SWEEP_PIPE, SCORE_EARLY false; codebook as committed). RTL = build 15's tree + ONE change:
  rtl/attn_kv_axi.vhd keeps (record, chunk, slot) as per-beat counters instead of dividing the beat counter by 17
  (commit f14121d). C_KV_BLOCK stays 32. Nothing else differs from build 15 (same generators, same env).
Env (recorded, launch.sh): FK33_CARD=1 FK33_CB_STYLE=distributed FK33_ENG_CORE_MHZ=75 BUILD_ROOT=build17/root.
Cap: MemoryHigh=24G MemoryMax=26G; swap guard 30 GB / 10 GB free; default flow, chain.sh re-implements with the
  rescue recipe only if the default fails to route.
PREDICTIONS, pre-registered:
  - Synthesis: LUT fewer than build 15's by roughly 4,000 in u_attn/u_kv (ESTIMATE from the OOC pair 33,259 -> 29,217;
    the parts do not sum across contexts, so the composed delta is to be MEASURED, not assumed). FF +7 in u_kv,
    BRAM 569 unchanged, DSP 2,087 unchanged. Placed CLB below build 15 draw 3's 54,537.
  - Timing: the routed worst path is NOT in u_kv's r_beat/ph_ch -> mbank CE cone (that path no longer exists; the
    OOC arm puts the bank-enable path at 17 levels, +0.59 ns at a 5 ns target). Whether the card CLOSES at 75 MHz
    is NOT predicted: draw 3's 597 failing endpoints were the ten reported paths' family, but the full census of
    the 597 was not taken (draw 3b's failing_paths_before.rpt takes it; read it before quoting anything here).
  - Routing: a lottery, as builds 13/14/15 were (1 of 3 default draws routed on these netlists); congestion trigger
    withdrawn. If it fails to route: rescue recipe from the synth DCP (chain.sh), then build 16 (KV_BLOCK 16 +
    the same counters) as the area lever.
  - Silicon, if it closes: caps 0x7D, x_exp_out 8 and --dump-xout == tok0.r9bs R_X-31 on token 248045, argmax 846,
    control run_chunk 24.578 s within 0.004% (the counters change no cycle: the write index is the same value one
    beat earlier in registers, and the bench's AR/beat counts are identical to the divider's).

## PLACED, 20:50 (MEASURED, `bd_wrapper_utilization_placed.rpt`; build 15 draw 3 in brackets)
LUT 361,488 (362,286: -798) | FF 310,004 (310,573: -569) | CARRY8 12,232 (12,539: -307) | F7 28,609 (28,176) |
F8 6,046 (5,966) | CLB 54,746 (54,537: +209, 99.61%) | BRAM 569 (569) | DSP 2,087 (2,087).
Predictions scored: BRAM and DSP unchanged HIT. "LUT fewer by roughly 4,000" MISSED in the composed context (-798
composed against -4,042 in OOC: the parts do not sum across contexts, exactly the pre-registered caveat); the
CARRY8 delta -307 is the divider's chains and is the honest structural signature. "Placed CLB below 54,537" MISSED:
+209 tiles, i.e. a different packing draw, not more logic (LUT, FF and CARRY8 all fell). Placer's own congestion
table (region sizes, smaller is better): N 16x16 (draw 3: 8x8), S 32x32 (32x32), E 16x16 (32x32), W 32x32 (64x64).
The router's `% Tiles` figure (the withdrawn CONGABORT trigger, draw 3 read 9.15 WEST) is appended when the
router prints it. Placement took 20:09 to 20:50.

## ROUTER CONGESTION TABLE, 21:01 (the withdrawn CONGABORT figure, recorded for the series, not as a prediction)
Global % Tiles: N 1.48 (4x4), S 9.64 (32x32), E 4.56 (16x16), W 9.16 (32x32); max 9.64 SOUTH. Draw 3 (routed) read
9.15 WEST; draws 1/2 (failed) 11.75/11.92; build 14 default (failed) 11.73. Long congestion S 19.63 at 64x64 is the
largest long-region figure in the series. Timing congestion level 6 (64x64), as every build so far.

## ROUTED, 23:27 (MEASURED, `bd_wrapper_route_status.rpt` and `bd_wrapper_timing_summary_routed.rpt`)
Route: 678,393 of 678,393 nets fully routed, 0 routing errors, 0 `[Route 35-162]` warnings, Phase 8 clean; global
iterations ended at 0 / 0 / 0 overlaps (three iterations; draw 3 needed four). Design Timing Summary: WNS 0.118
TNS 0.000, 0 failing of 1,527,254; WHS 0.009 THS 0.000, 0 failing; pulse width 0 failing. Per clock: the 75 MHz core
clock `clk_out3` WNS **+0.373** (0 failing of 1,291,859), `pipe_clk` +0.118 (the design's WNS, PCIe IP),
`sysref_clk` +0.286, `clk_out1` +5.112, `pcie_refclk` +6.820. The 75 MHz worst path is now in B:
`gen_vstub[2].gsr.u_swg/a_vq_reg -> u_swg DSP B input`, 31 levels, +0.373; nothing in u_kv appears among the
reported worst paths.
Predictions scored: "worst path NOT in u_kv's r_beat/ph_ch -> mbank CE cone" HIT; "closure NOT predicted" and it
closed, with the largest 75 MHz margin of any card build (12b +0.046, 14 rescue +0.056, 15 draw 3 -0.254);
routing lottery: routed on the first default draw. Timeline: launch 19:38, synthesis to 20:07, placed 20:50,
routed 23:27.
