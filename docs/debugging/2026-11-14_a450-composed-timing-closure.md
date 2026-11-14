# 2026-11-14: a450 composed A at 450 MHz, timing closure (Task 7b)

## The question

Task 7's honest gate (2026-11-14, `hw/jc/a450/run_a450.sh`, run `a450_hbm_r2`, commit
54baf4aa) routed subsystem A as 24 per-port tiles plus the real HBM IP on xcvu35p-fsvh2104-2L-e
(Vivado 2023.2, 0.85 V, -2 timing model) at aclk_a 2.222 ns (450 MHz):

    A450RUN_TIMING_FAIL -0.747 (WNS_CORE 0.814, WHS 0.010)
    72,273 failing aclk_a endpoints, routed TNS -17,923.055 ns

Oren (2026-11-14): "Closure round, then go on." Goal: routed WNS >= 0 on aclk_a in that
same design, every output bit unchanged.

## The answer

Met. Gate run `a450_hbm_7b_r1` (HEAD 77cd08c1: reset tree, tile margin, R-channel register
stage) routed aclk_a at WNS 0.000 ns, TNS 0.000, 0 failing endpoints, WNS_CORE +0.680, WHS
+0.009, 0 routing errors; its only failure was the run's own CDC allowed list naming the
stub's base registers wrongly (fixed by name in 92ca5d42, the same report rescanned clean).
Gate run `a450_hbm_7b_r2` on 92ca5d42 printed `A450RUN_PASS 0.000` (identical
implementation; top-10 paths identical to run 1). Gate run `a450_hbm_7b_r3` with
`--directives explore` printed `A450RUN_PASS 0.019`. The single largest lever was
the reset: one aclk_a reset net (ar2, fanout 3,611) gated every LUTRAM write enable in every
tile, and taking it off the datapath took the composed fast half alone from -0.605 to +0.002
before any other change. The margin is near zero: default directives stop at 0.000 with a
wall of paths there, explore directives at +0.019 (Open, below).

## The procedure

Each step measured before the next, values re-proven after each RTL group.

1. **Baseline the tile at a harder clock.** New manifest row `a450_tile_2ns` (mv_tile alone,
   2.0 ns; the 2.222 ns row kept). `rate.py run a450_tile_2ns --mem 8G`, ~3 min, 4.8 GB. This
   isolates the tile's own paths from composition and placement.
2. **Group A, reset tree** (21c8e551). Measured with the tile at 2.0 ns AND with
   `a450_afast` (mv_afast alone, no HBM, no pblocks, 2.222 ns, ~22 min, 9.2 GB). a450_afast is
   the control for "is it the HBM/pblocks or the composition": in Task 7 it failed by -0.605
   on its own, so the composition was already broken without the HBM.
3. **Group B, tile margin** (e43b54da): tile at 2.0 ns.
4. **Group C, R-channel register stage** (77cd08c1): tile at 2.0 ns plus a scratch
   throughput bench of mv_rdport alone (2048 beats, no R gaps, always-ready consumer: span
   in cycles, first-beat cycle).
5. **Values after every group**: tb_mv_tile, tb_mv_dist, tb_mv_rchain, tb_mv4i_tiled (three
   DUTs beat-identical) and the unit mutant files touched.
6. **Gate run 1** with A+B+C and the Task 7 review fixes (anchored CDC list, registered stub
   bases, pblock verify that refuses skips). D (chain afull) was conditional on d_afull still
   failing; it passed (+0.063), so D was not done.
7. **Gate run 2** on the CDC rule fix; implementation inputs identical to run 1, so the
   same route is expected (Vivado is deterministic for identical inputs and thread count),
   and it is the run's own PASS sentinel on HEAD.
8. **Gate run 3** (group E): the same tree with `--directives explore`, to measure what
   margin the directives buy. The third and last gate run allowed by the brief.

## Evidence

### Ratings (rate.py, MEASURED, one draw each)

| step | row | WNS | worst path |
|---|---|---|---|
| baseline (HEAD cefb3c75) | a450_tile_2ns (2.0 ns) | +0.072 | cbw_d -> cbl LUTRAM D, 0 lvl |
| A | a450_tile_2ns | +0.099 | tap -> DSP A, 0 lvl |
| A | a450_afast (2.222 ns) | **-0.605 -> +0.002** | tap -> DSP A in g_t[7], 0 lvl |
| A+B | a450_tile_2ns | +0.027 | c_reg[31] (DSP P) -> s_sp DSP, 5 lvl inside the DSPs, route 0.267 |
| A+B+C | a450_tile_2ns | +0.098 | mode_r -> e6_d, 1 lvl |

All tile differences are inside the 0.4-0.75 ns routed noise floor; what moved is which
path limits. a450_afast: peak 9.21 GB (12G cap, not reached), swap 0.

### Throughput (scratch bench, group C)

    old mv_rdport: THR beats 2048 first 13 span 2048
    new mv_rdport: THR beats 2048 first 14 span 2048

### Gate run 1, a450_hbm_7b_r1 (HEAD 77cd08c1), `hw/jc/a450/results/a450_hbm_7b_r1/`

    A450RUN_FAIL 1 post-route check(s) failed, WNS_ACLK 0.000: A450HBM_CHECK_FAIL report_cdc: 459 crossing(s) not on the allowed list
    A450HBM_ROUTE routing_errors 0
    A450HBM_WNS_ACLK 0.000 LEVELS 1 START .../HBM_SNGLBLI_INTF_AXI<1>_INST/ACLK END .../g_t[0].tile/wport/fsm/ar_left_reg[19]/CE
    A450HBM_WNS_CORE 0.680
    A450HBM_WHS 0.009
    A450HBM_UTIL LUT 102098 FF 111148 BRAM 151 DSP 1585
    A450HBM_RSTAR1 SLACK 0.837 REQ 2.222 DELAY 1.410 ROUTE_PCT 84 LEVELS 1 FANOUT 373
    A450HBM_TOGS1  SLACK 0.625 REQ 2.222 DELAY 1.622 ROUTE_PCT 95 LEVELS 0 FANOUT 2
    A450HBM_RSTSKEW 0.212 PERIOD 2.222
    A450HBM_DAFULL k=12 SLACK 0.200 ... FANOUT 108
    A450HBM_DAFULL_WORST SLACK 0.063 ... g[10].lk/ua_r_reg -> g_t[11].tile/outst_reg[1]/D
    A450HBM_CDC flagged_summary 898 flagged_rows 898 unlisted 459
    timing_routed.rpt: WNS 0.000  TNS 0.000  failing endpoints 0 of 797,362
    memory.peak 18.61 GB, swap peak 3.64 GB, system MemAvailable minimum 3.30 GB

Top 10 aclk_a paths all at 0.000: HBM ACLK -> wport/fsm/ar_left CE (the AR handshake,
arready), p0_w/tap -> DSP B/A inputs, flitq ob_rp -> DSP A, hi_r -> e3_w (fanout 96),
wport/fifo/ob_rp -> tap SRL D (fanout 259), dist b -> xmem BRAM address.

The 459 unlisted rows were all `stub/wb_r_reg` / `stub/sb_r_reg` -> `fsm/p_base_reg`: the
rule named `w_base_reg`/`s_base_reg`. Rescan of this run's own report with the fixed rule
(`cdc_rescan.txt`): 898/898 matched, 0 unlisted, verdict clean.

Carried bounds: rst->ar1 and tog->s1 both read back at REQUIREMENT 2.222 (one aclk_a
period) and met; their skew 0.212 ns < 2.222 (ar3's one edge of margin holds).

### Gate run 2, a450_hbm_7b_r2 (HEAD 92ca5d42)

    A450RUN_PASS 0.000
    A450HBM_WNS_ACLK 0.000 (same first path as run 1)   A450HBM_WNS_CORE 0.680   A450HBM_WHS 0.009
    A450HBM_CDC flagged_summary 898 flagged_rows 898 unlisted 0
    A450PB_VERIFY 24 of 24 ok;  A450HBM_TOP lines byte-identical to run 1
    memory.peak 19.37 GB, swap peak 2.82 GB

### Gate run 3, a450_hbm_7b_r3 (HEAD d57b6701, `--directives explore`)

    A450RUN_PASS 0.019
    A450HBM_DIRECTIVES explore
    A450HBM_WNS_ACLK 0.019 LEVELS 1 START .../g_split.u/ar2_reg/C END .../g_split.u/ar_ts_reg/D
    A450HBM_WNS_CORE 0.517   A450HBM_WHS 0.006   routing_errors 0
    A450HBM_RSTAR1 SLACK 1.669 REQ 2.222 (source: proc_sys_reset output flop, REPLICATED by phys_opt)
    A450HBM_TOGS1  SLACK 1.748 REQ 2.222   A450HBM_RSTSKEW 0.079
    A450HBM_DAFULL_WORST SLACK 0.164
    A450HBM_CDC flagged_summary 898 flagged_rows 898 unlisted 0
    memory.peak 20.58 GB, swap peak 1.86 GB, system MemAvailable minimum 3.11 GB

Top 10: ar2 (fanout 265: mv_dist, mv_xbcast, the four mid registers, ar3/ar_ts) -> ar_ts,
tree l_v R, rst_m at +0.019..+0.022; flitq ob_rp -> bias_r (fanout 71); mode_r -> e6_d
(fanout 97); tap -> DSP B; ob_rp -> td SRL. The directives bought 0.019 ns over run 2: a
measured pass, inside the routed noise floor, not a margin to plan on.

### Values (GHDL 1.0.0 mcode, MEASURED)

| after | tb_mv_tile | tb_mv_dist | tb_mv_rchain | tb_mv4i_tiled | mutants |
|---|---|---|---|---|---|
| A | 93 / 26 PASS | 259144 PASS | 1970 PASS | 150 PASS (853 s) | mv_tile 8, attr 5, mv_dist 7, mv_rchain 7 |
| B | 93 / 26 PASS | | | 150 PASS (870 s) | mv_tile 8, attr 5 |
| C | 93 / 26 PASS | 259144 PASS | | 150 PASS (857 s) | mv_tile 8, mv_dist 7 |
| final (RTL of 77cd08c1) | (C row) | (C row) | (A row; closure unchanged since) | (C row) | mv4i_tiled 7, mv_tile_attr 5 MUTANTS_OK |

Full suite on the final tree (`sim/regress.sh --keep`): OVERALL PASS 198, FAIL 2 (sim:pcieep
stale build Tcl, sim:ratestale), NOCHECK 4, SKIPPED 6: the same two pre-existing failures
Tasks 4 and 6 reported. ratestale lists a450_tile and a450_afast STALE at that moment (rated
before B/C); both were re-rated on the final RTL afterwards:

| row | WNS | worst |
|---|---|---|
| a450_tile (2.222 ns) | +0.092 (469.5 MHz; Task 3 had +0.156 on the old tile) | flitq g_seg[7] rp -> mem_q, 1 lvl |
| a450_afast (2.222 ns) | +0.009 (451.9 MHz), peak 9.25 GB, swap 0 | tap -> DSP A, 0 lvl |

## Measured and REJECTED (do not retry)

- **"Fixing ar2's fan-out would move WNS to roughly -0.73, not 0"** (Task 7 report's reading
  of the r2 endpoint groups). WITHDRAWN by measurement: group A alone moved a450_afast from
  -0.605 to +0.002. The tile-internal groups that looked independent (flitq rp/ob_rp,
  cbw_*, tap) were mostly the same reset: in mv_lfifo the memory write, the registered read
  and the output-stage write sat in the reset's else branch, so `rst` was an input of every
  LUTRAM write enable and every mem_q/ob enable in every tile. Do not size a reset fix by
  grouping failing endpoints by STARTPOINT; the reset was in their enable logic, not their
  startpoints.

## Measurement traps hit

- **My own CDC rule named ports, not registers.** The stub's bases are registers `wb_r`/
  `sb_r` driving output ports `w_base`/`s_base`; report_cdc names the register. Run 1
  spent its CDC verdict on it. Name a rule from a run's report (or a synthesized netlist),
  never from the HDL port.
- **GHDL 1.0.0 crashes** (`trans.adb:553`, TYPES.INTERNAL_ERROR) on an aggregate actual
  `(NT-1 downto 0 => rst)` in a port map; the regress row reported `exit 2` with no
  message in the summary. Use a signal.
- **A scratch bench constant `N` and a variable `n` are the same name in VHDL** (case
  insensitive): the variable hid the constant and the throughput loop exited at once
  (`beats 0`). Caught because 0 beats is impossible.
- **A wall of 0.000 paths is the router stopping at met**, not slack that happens to be
  zero; it says nothing about how much margin exists.

## Open, not yet answered

- **Margin.** Runs 1/2 have no positive slack on aclk_a; run 3 has 0.019 ns. Any change in the card
  (Task 8/9: more logic, the sequencer, different placement) can push it negative. Levers
  not yet measured: ar2's own fan-out (265 after the tree: give mv_dist and mv_xbcast
  their own mid register; the first-start margin after a reset in SAME must be re-argued,
  see mv4i_tcore's RESETS header), an AR-channel register slice (arready reaches ar_left's CE straight from the HBM, the
  first path of run 1), the s_sp multiply split (the tile-alone limiter after B), hi_r/
  mode_r replication (fanout 96).
- Whether the same placement holds when the A pblocks share SLR0 with the card's other
  subsystems.
