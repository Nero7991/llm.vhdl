# 2026-11-15: a450 split-on card build misses aclk_a by 1.262 ns and fails report_cdc

## The question

Task 9 diagnosis brief (2026-11-15), verbatim in substance: the split-on card build
`/mnt/storage/fk33_builds/jccard_a450s1b` (commit 1d040e50, `JC_A_TILED=1 JC_A_CLK_SPLIT=1`,
`--clk-mhz 125 --impl congestion`, xcvu35p-fsvh2104-2L-e, Vivado 2023.2) routed with

    aclk_a (clk_out1_jcc_clk_wiz_a_0, 2.222 ns) WNS -1.262, TNS -19202, 46,911 of 792,746 endpoints failing
    clk_core +0.072
    JCCARD_CDC_REPORT_CRITICAL summary=49 rows=49 unknown=49 named=0 named_refused=0
    JCCARD_FAIL report_cdc: 49 critical crossing(s) whose destination is not a named synchroniser

while the Task 7b A+HBM gate (`hw/jc/a450/`, run a450_hbm_7b_r6) closed the same A at +0.014
with explore directives and `a450_pblocks.tcl`. Questions: (1) were A's tiles floorplanned,
and is tile spread the cause of the tile-internal failures; (2) the utilisation counters
`gu.gdc.uctr`; (3) any other failing cluster; (4) the 49 CDC rows; (5) the fix set, its
effect, and whether one more card build is enough.

## The answer

The card build never floorplanned A: `build_card.tcl` sources `a450_cdc.tcl` but not
`a450_pblocks.tcl` (no pblock exists in the routed checkpoint), and with
`place_design -directive AltSpreadLogic_high` in an SLR0 that also holds C's attention array
the 24 tiles were smeared over 2 to 13 clock regions each, so register-to-register paths inside
one tile carry 2.5 to 3.4 ns of route (81% of the failing endpoints are inside A's fast half).
Three smaller clusters are independent of the floorplan and need their own fixes: the
utilisation counters (a 27x48-bit counter bank fed straight from 27 HBM RVALID pins spread
across the die), the descriptor fetch FSM on SAXI_29 (11 LUT levels, a logic-depth failure
at 450 MHz), and the Xilinx converters/smartconnect whose aclk_a side now runs at 450 MHz.
Of the 49 CDC rows, 48 are safe by construction and need allowed-list entries; one (CDC-10,
the `run` decode into `dfetch/g_dc.run_s1`) is a real defect known since 2026-08-29.

## The procedure

All read-only on `proj/jc_card_routed.dcp`, nothing written back, one Vivado at a time under
`systemd-run --user -p MemoryHigh=24G` with a swap guard (peak 12.0 GB resident, 0 swap).
Scripts and outputs: `/mnt/storage/fk33_builds/jccard_a450s1b_diag9/` (`diag.tcl`,
`diag2.tcl`, `hist.py`).

1. **Build log and Tcl source**: grep `build_card.tcl` and the log for any pblock. Isolates
   "floorplan applied but ineffective" from "floorplan never applied".
2. **`get_pblocks`** on the checkpoint: the authoritative answer to (1).
3. **SAXI -> tile map from the netlist** (a450_pblocks' own method: the leaf driver of each
   HBM `AXI_nn_ARVALID` boundary pin, and the HBM interface cell's LOC and clock region).
   Controls for "the card wired the tiles to different ports than the gate".
4. **Per-tile clock-region histogram** of each tile's placed sites (current_instance on
   `g_t[p].tile`, sites of leaf cells, `CLOCK_REGION`), against the tile's port column.
5. **Every failing aclk_a endpoint**: `get_timing_paths -setup -max_paths 60000 -nworst 1
   -slack_lesser_than 0 -to aclk_a`, dumped as slack / levels / datapath / start / end,
   then histogrammed by hierarchy prefix and per tile (`hist.py`).
6. **Correlation**: regions per tile vs failing endpoints per tile.
7. **Path reports** for the worst of each cluster (uctr CE and carry, tile 9 (the one compact
   tile), dfetch, the crossings both directions, rst->ar1, tog->s1), with site columns,
   clock skew and clock uncertainty, compared with r6's `timing_aclk_top10.rpt`.
8. **SLR utilisation and congestion** (`report_utilization -slr`,
   `report_design_analysis -congestion`) to see what shares SLR0 with A.
9. **CDC rows** read against the RTL and against `a450_cdc_rules` (the gate's allowed list).

## Evidence

### Floorplan (MEASURED, Vivado on the routed checkpoint)

    DIAG_PBLOCKS 0
    build_card.tcl:  `source $repo/hw/jc/a450/a450_cdc.tcl` (line 462); a450_pblocks.tcl is
                     sourced only by hw/jc/a450/build_a450.tcl:77 (grep over hw/jc)
    build_card.tcl:596  place_design -directive AltSpreadLogic_high   (-impl congestion)
    gate r6:           place_design -directive ExtraTimingOpt + 7 pblocks pb_a450_x0..x6

Port map traced from the netlist (identical to the gate's portmap {1..15 17..25}):

    SAXI 1..15  <- g_t[0..14].tile/wport/fsm/arv_reg     SAXI 17..25 <- g_t[15..23].tile
    SAXI 26..28 <- dist/gen_s[0..2].sport                SAXI 29 <- dfetch/g_dc.fsm
    SAXI 0 ld_cdc, 16 hbm_sc, 30/31 bc_cdc0/1;  site X<n>Y0 = SAXI n, regions X0..X7 Y0

Per tile (sites in clock regions; "in col" = share of sites in the port's own column):

| tile | port col | regions | cols | in col | failing endpoints | worst |
|---|---|---|---|---|---|---|
| 0 | X0 | 4 | 2 | 85% | 994 | -1.086 |
| 9 | X2 | 2 | 1 | 100% | 348 | -0.532 |
| 12 | X3 | 11 | 4 | 33% | 1741 | -1.128 |
| 15 | X4 | 13 | 5 | 19% | 2387 | -1.252 |
| 16 | X4 | 12 | 4 | 22% | 3274 | -1.260 |
| 21 | X5 | 5 | 4 | 11% | 2043 | -1.207 |
| 22 | X5 | 4 | 3 | 2% | 1566 | -1.250 |
| 23 | X6 | 6 | 4 | 3% | 1889 | -1.241 |

(all 24 rows in `tile_regions.txt`; Pearson r(regions, failing endpoints) = 0.71 over 24 tiles,
DERIVED by `hist.py`; the gate's pblocks hold each tile in ONE column, Y0..Y3.)

Worst tile-internal paths, 0 logic levels:

    -1.260  g_t[10].tile/rst_l_reg (SLICE_X97Y31) -> flitq/g_seg[3].ob_rp_reg[3][0]/R (SLICE_X102Y99)  route 3.128 of 3.204
    -1.260  g_t[13].tile/flitq/mem_q_v_reg (X115Y111) -> flitq/g_seg[5].ob_wp_reg[5][0]/CE (X124Y162)  route 3.325 of 3.405
    -0.532  g_t[9].tile/c_reg[63] DSP48E2_X11Y31 -> s_sp_reg[1] DSP48E2_X10Y14, 5 lvl inside the DSP, route 0.944
            (r6 closed this same path at +0.014; here the two DSPs sit in different columns, 17 rows apart)

### Failing aclk_a endpoints by hierarchy (MEASURED, 46,911 paths, all launched by aclk_a)

    count   worst  lvl_med  prefix
    15899  -1.260  1  A/fast/g_t[*].tile/flitq
     7853  -1.250  1  A/fast/g_t[*].tile/wport
     2678  -1.213  1  A/fast/dist
     1950  -1.259  0  A/fast/tree
     1449  -1.262  1  eng/gu.gdc.uctr
     1136  -1.145  5  A/fast/g_t[*].tile/s_sp_reg[0]
     1075  -1.122  5  A/fast/g_t[*].tile/s_sp_reg[1]
      937  -0.876  1  hbm_sc/inst
      542  -0.942  1  bc_cdc1/inst
      385  -1.256  2  A/fast/chain
      385  -1.026  1  A/fast/g_t[*].tile/resq
      319  -1.121  1  A/fast/g_t[*].tile/c_reg[0]
      263  -0.456  1  bc_cdc0/inst
      223  -1.107  1  A/fast/g_t[*].tile/c_reg[32]
      217  -0.594  1  ld_cdc/inst
      124  -1.230  1  eng/dfetch
    (A = eng/inst/eng/g_tiled.dut/g_split.u; endpoints inside a g_t[p].tile: 38,019 = 81.0%; A total incl. dist,
     tree, chain 43,032 = 91.7%; uctr 3.1%; IP converters/smartconnect 1,959 = 4.2%)
    slack buckets: -1.3:44 -1.2:760 -1.1:1104 -1.0:1637 -0.9:1890 -0.8:2483 -0.7:2777
                   -0.6:3469 -0.5:3972 -0.4:4652 -0.3:5514 -0.2:6929 -0.1:7447 0.0:4233
    levels: 1:25764 0:11505 2:4136 5:2505 3:2114 4:650

Placement, not routing, set the WNS (build.log):

    INFO: [Place 30-746] Post Placement Timing Summary WNS=-1.862
    JCCARD_POST_ROUTE_WNS -1.290   JCCARD_POST_ROUTE_PHYSOPT_WNS -1.262

What shares SLR0 (MEASURED): SLR0 LUT 60.2%, DSP 64.2% (1848), SLR1 DSP 6.2%. Three of the four
router-initial level-5 congestion windows name A tiles beside `card/inst/u/gcr.u_attn` (u_arr 55-66% of two windows)
and `gcr.gkvaxi.u_kv`.

### Class (a), gu.gdc.uctr (MEASURED)

    -1.262  HBM_ONE_STACK_INTF<1>/HBM_SNGLBLI_INTF_AXI<10>/ACLK -> gu.gdc.uctr/cnt_reg[24][1]/CE
            LUT2, route 2.676 of 3.316
    -1.261  uctr/cnt_reg[26][37] (SLICE_X123Y44) -> CARRY8 SLICE_X66Y52/53 -> cnt_reg[26][46] (SLICE_X117Y34)
            route 2.972 of 3.311: the counter's own flops and its carry chain 57 columns apart
    DIAG_UCTR cells 2239, sites in 9 clock regions (X0..X5, Y0..Y3)

RTL: `rtl/matvec_int4_desc_axi.vhd:1481-1511` (gdc arm, `clk => m_aclk`, `rbeat => u_beat`,
`u_beat <= m_rvalid and m_rready_i` at 1475), `rtl/a_util_ctr.vhd` (27+1 counters x 48 bits,
CE from `rbeat`). Reader: the host only (`hw/jc/host/jc_seam.py util`, AXI-Lite UTIL_SEL 0x40 /
UTIL_DATA 0x44, a toggle request/acknowledge). Nothing in inference reads it. Under split
`m_aclk` is aclk_a, so the bank must count at 450 MHz from 27 RVALID pins that span HBM sites
X1..X29 (clock regions X0..X6).

### Class (c), the descriptor fetch (MEASURED)

    -1.230  HBM AXI<13> (SAXI_29) ACLK -> dfetch/g_dc.fsm/this_len_reg[0]/CE
            11 levels (LUT4=1 LUT5=4 LUT6=6), logic 1.566 + route 1.693 = 3.259, placed compactly
            (SLICE_X187..190 Y7..10)
    -0.247  aclk_a -> clk_core: dfetch/g_dc.fsm/st_reg[0]_replica_2 -> dfetch/g_dc.run_s1_reg/D,
            LUT3, MaxDelay 2.222 (a450_cdc's aclk_a->clk_core bound), route 2.376
            (the one failing endpoint of the inter-clock table)

`axi_rd_fsm`'s AR handshake was rated at the core clock; logic alone is 1.566 of 2.222 ns.

### The crossings that ARE fine (MEASURED)

    A450CDC bound rst->ar1 2.222 ...   rst->ar1  slack +1.301 (REQ 2.222, LUT1, route 0.767)
    A450CDC bound tog->s1  2.222 ...   tog->s1   slack +1.180 (REQ 2.222, route 0.988)
    clk_core -> aclk_a 2,645 endpoints, worst +0.146 (dw_reg[36] -> g_t[21] p_beats, REQ 4.444)
    Clock Uncertainty 0.065 ns on aclk_a in BOTH the card and r6 (TSJ 0.071, DJ 0.110)

### The 49 CDC rows

| rows | rule | src -> dst | verdict | why (RTL) |
|---|---|---|---|---|
| 29 | CDC-13 | `g_split.u/back/rows_r_reg[i]` -> `fast/dist/prod_r_reg/DSP_A_B_DATA_INST/B[i]`, `DSP_C_DATA_INST/C[i]` | SAFE | `rows_r` written only at `start` (rtl/mv_back.vhd:250) and held to the next start; `y_r` (absorbed into prod_r's DSP input registers) loads only in D_IDLE on `go` (rtl/mv_dist.vhd:284-288), and `go` reaches aclk_a only through mv_tsync after the toggle; the path is bounded at 2 aclk_a periods by a450_cdc. CDC-13 fires only because the destination register is a DSP. Already ruled `job_rows_r` in `a450_cdc_rules`. |
| 16 | CDC-1 | `eng/u_sel_h_reg[0]` -> `gu.gdc.uctr/hi_q_reg[0..15]/CE` | SAFE | `u_sel_h` captured in clk_core on the same edge that toggles `u_req_t` (matvec_int4_desc_axi.vhd:1329-1337) and held until the next request; aclk_a uses it only when `u_rden = req_s(2) xor req_s(1)`, at least 2 aclk_a edges after the toggle lands; bounded at 2 aclk_a periods. Moot if uctr is dropped under split. |
| 3 | CDC-11 | `core_reset/U0/ACTIVE_LOW_PR_OUT_DFF[0].FDRE_PER_N_replica` -> `g_split.u/ar1_reg/D`, `dfetch/g_dc.rst_s1_reg/D`, `gu.gdc.rst_s_reg[0]/D` | SAFE | one reset into three independent ASYNC_REG two-flop synchronisers (axi_rd_port.vhd:189-191,344-347; matvec_int4_desc_axi.vhd:1470,1484-1486; ar1 is mv4i_tcore's designed start-crossing reset, bounded at one period). The three consumers do not interact in the cycles after release: each starts work only on a later clk_core toggle. |
| 1 | CDC-10 | `dfetch/g_dc.fsm/st_reg[0]_replica_2` -> `dfetch/g_dc.run_s1_reg/D` | DEFECT | `run <= '1' when st = S_RUN` (rtl/axi_rd_fsm.vhd:122) feeds the synchroniser through a LUT; a multi-bit state transition can glitch S_RUN into `run_s1` and open the output gate for a cycle. Recorded OPEN in docs/debugging/2026-08-29_cdc-static-analysis.md 2.3; it became live on the JC card only now, because split-off the port is single-clock. Also the -0.247 timing failure above. |

Why the card gate saw them and the a450 gate did not fail: `build_card.tcl:670-695` accepts a
Critical row only when its DESTINATION matches a loader/ctl/tok synchroniser glob
(`jccard_cdc_scan`); it never loads `a450_cdc_rules`, and the gate design had neither the
counters nor dfetch.

## Recommended fix set (for the next card build)

1. **Floorplan A in the card**: in `build_card.tcl`, under `JCCARD_A450_SPLIT on`, source
   `hw/jc/a450/a450_pblocks.tcl` and call
   `a450_pblocks {.*/g_split\.u/fast} "u_bd/jcc_i/hbm/*" {1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 17 18 19 20 21 22 23 24 25}`
   before opt_design; run `a450_pblocks_verify` after place and refuse on a mismatch.
2. **Directives for split builds**: the r6 recipe (opt ExploreWithRemap, place
   ExtraTimingOpt, phys_opt/route AggressiveExplore, post-route phys_opt), not
   AltSpreadLogic_high, which is what spread the counter's carry chain and the tile DSP pairs.
3. **Keep C out of A's columns**: pblock `card/inst/u/gcr.u_attn` (u_arr) to SLR1 (SLR1 DSP
   is 6% used), so A's pblock columns are not contested. Optional if 1 and 2 suffice; it is
   the congestion co-tenant named in every level-5 window.
4. **uctr under split**: do not build the counter bank when `A_CLK_SPLIT` (gate `gdc`'s
   `uctr` on `not A_CLK_SPLIT`, UTIL_DATA reads 0, `jc_seam.py util` documented as
   unavailable split-on). The proper version (a registered per-tile beat strobe, counted in
   the tile's pblock, carry pipelined) is a follow-up, not on this build's critical path.
5. **dfetch**: put SAXI_29 behind an `axi_clock_converter` (the ld_cdc pattern in
   gen_jc_card.py) and instantiate dfetch single-clock on clk_core (its own `DUAL_CLK`
   generic false under split). Removes the 11-level aclk_a path, the CDC-10 defect, the
   CDC-11 dfetch row and the -0.247 crossing in one change. Alternative if the BD must not
   change: register `run` in aclk (re-measure the abandon residue, 2026-08-29 4.7) AND
   pipeline axi_rd_fsm's AR decode.
6. **CDC allowed list**: under split, scan Critical rows with `a450_cdc_scan` against
   `a450_cdc_rules` (src+dst anchored regexps) plus card rules for the CDC-11 reset fan-out
   (`core_reset/.../ACTIVE_LOW_PR_OUT_DFF\[0\]\.FDRE_PER_N(_replica)?/C$` -> each of the three
   named D pins) and, only if uctr stays, `eng/u_sel_h_reg\[\d+\]/C$` ->
   `gu\.gdc\.uctr/hi_q_reg\[\d+\]/CE$`. Keep CDC-10 refused everywhere.
7. **The IP on aclk_a** (hbm_sc m00_exit, ld_cdc, bc_cdc0/1; 1,959 endpoints, worst -0.942,
   HBM ACLK -> FIFO dout CE and FIFO read pointer -> dout, 1 level): add an
   `axi_register_slice` at 450 MHz between each and its HBM port, or pblock each converter's
   read side beside its port (X0, X4, X7). Untested at 450 by any gate so far.

### Effect (ESTIMATE)

- Items 1-3 on the A clusters (43,032 endpoints): back to the gate's regime, -0.15..+0.08.
  Assumption: with each tile pinned to its column and C moved out, A sees the placement r4..r6
  saw (r4 default -0.146, r5/r6 explore +0.08/+0.014). The card's extra SLR0 tenants
  (loader, hbm_sc, bcgrant, kv axi) are the unmeasured difference.
- Item 4 and 5 remove their clusters outright (structural, not a slack estimate).
- Item 7: unknown. If no fix lands, the converters' -0.46..-0.94 stays the WNS. With register
  slices they become 0-level FIFO-internal paths; ESTIMATE -0.2..0 (assumption: their
  remaining paths are route-dominated like now, 1 level, and the slice removes the HBM-pin
  leg).
- Overall after one build with all seven: ESTIMATE WNS -0.3..+0.05.

### Is one more card build enough?

Probably not. Items 4-6 are structural and will hold; item 1-3's outcome rests on a margin
that was +0.014..+0.08 with A ALONE in SLR0, and item 7 has no measurement at 450 MHz at all.
Plan for two: the next build to confirm the floorplan and measure the IP clusters, a second to
trim what is left. A cheaper intermediate that de-risks item 7: add the converters/
smartconnect and a register slice to the a450 gate design (`hw/jc/a450/a450_bd.tcl`), which
routes in about 1/3 of a card build.

## Measured and REJECTED (do not retry)

- **"The card's aclk_a has more jitter (cascaded MMCM), so the same RTL loses slack."**
  Clock Uncertainty is 0.065 ns in the card and in r6 (identical TSJ/DJ). Not the cause.
- **"The card wired tiles to different HBM ports than the gate."** The netlist trace gives
  tile p -> SAXI {1..15,17..25}[p], identical to the gate's portmap.
- **"Router congestion detours, not placement."** Post-placement WNS was already -1.862;
  route moved WNS to -1.290 (physopt -1.262). Placement set it; routing only spread TNS.
- **"The CDC bounds were not applied."** A450CDC lines present; rst->ar1 +1.301, tog->s1
  +1.180 at REQ 2.222; clk_core->aclk_a worst +0.146 at REQ 4.444.
- **"A compact tile closes without a pblock."** Tile 9 (one column, 2 regions, 100% in its
  port column) still fails -0.532 on the c_reg -> s_sp DSP pair, split across DSP columns
  X11 and X10, 17 rows apart. Compactness at clock-region grain is not enough; the pblock
  plus timing-driven placement is what kept that pair together in r6.

## Measurement traps hit

- **`run_capped.sh` lost its unit when launched with `nohup ... &` from this agent's shell**:
  `systemd-run --wait` returned 1 at once (`RC=1`, peaks 0) while the transient unit kept
  running with its MemoryHigh cap but with NO swap sampler or guard. Caught only because the
  samples log was empty. Worked around with a separate cgroup-reading guard loop
  (`guard.sh`); for later runs, launch run_capped.sh via the tool's background mode (not
  `nohup &`) and check that its samples log grows.
- **Vivado overrides Tcl `lsort`**: `lsort -stride 2 -index 1` raised inside Vivado's
  wrapper and the batch exited after 2 minutes. Use plain dict output.
- **`fail_aclk_a.tsv` uses `-to aclk_a`**: it holds paths ENDING in aclk_a. The one
  aclk_a -> clk_core failure (-0.247) is not in it; it comes from the inter-clock report.
- **Site X coordinates mix site types** (SLICE vs DSP48E2 numbering), so an X span across a
  tile's sites is not a distance; the clock-region histogram is the comparable measure.
- **`DIAG_UCTR ... regions` counts distinct SITES per region**, not cells.

## Open, not yet answered

- Whether the SLR0 co-tenants other than C (loader, hbm_sc, bcgrant, kv axi, ~SLR0 LUT 60%)
  leave A's pblock columns enough room; r6 had none of them.
- The converters/smartconnect at 450 MHz: no gate has measured them.
- What `hbm_sc` (smartconnect crossing to aclk_a) does with a register slice vs a dedicated
  clock converter in front of it.
- The utilisation counters' proper split-on design (per-tile strobe, pipelined carry): not
  designed or measured here.

## 2026-11-15 (Task 9b): fixes 1-7 implemented; the a450 gate with the card's aclk_a IP closes at 450 MHz

### The question

Task 9b brief: make the split-on card closable at 450 MHz with fixes 1-7 above (split off and
the FK33 renders byte-identical), and prove it first on the a450 gate extended with the
aclk_a-side IP the card has under the split (the four clock converters, register slices, the
HBM smartconnect hbm_sc, the port-29 converter), on the card's HBM ports, routed with the
explore directives.  Expected: routed aclk_a WNS >= 0, 0 failing endpoints, CDC list clean.

### The answer

MEASURED, run `a450_hbm_9b_r2` (HEAD b9ba8f30, xcvu35p-fsvh2104-2L-e, Vivado 2023.2,
explore): `A450RUN_PASS 0.028`, `A450HBM_FAILING_ACLK 0`, WNS_CORE +0.253, WHS +0.009,
report_cdc 1553 flagged rows, all on the allowed list.  Every converter, slice and the
smartconnect closes with +0.12 ns or more (worst bc_cdc1 +0.122).  This is the gate, not the
card: C, B, the loader, ctl and tok logic are absent (the masters are traffic generators), so
the card's SLR0 co-tenants (Open question 1 above) are still unmeasured.

### What was done (commits 7b982331, b9ba8f30, 37602cb3, a91e2fee)

| fix | where | what |
|---|---|---|
| 1 | build_card.tcl | under the split, `a450_pblocks` (the gate's call, ports 1..15 17..25) and `a450_ip_pblocks`; after place, `a450_pblocks_verify` + `a450_pblocks_placed`, refused before routing (`JCCARD_A450_PBLOCKS`) |
| 2 | build_card.tcl, run_card.sh | `-impl explore` (r6's directives), the default and the only choice with JC_A_CLK_SPLIT=1; `JCCARD_DIRECTIVES`, PROVENANCE `impl`/`impl_directives` |
| 3 | not done | the gate has no C, so it cannot show SLR0 contention, and no placement-only card probe was run; left to the card build's own placement report |
| 4 | matvec_int4_desc_axi.vhd | `U_ON` false under A_TILED and A_CLK_SPLIT: no counters; UTIL_SEL[31] (UTIL_NONE) reads 1, UTIL_DATA 0 OKAY; `jc_seam.py util` prints `JCUTIL_NONE ... seam_cycles_last_go N` |
| 5 | matvec_int4_desc_axi.vhd, gen_jc_card.py | `D_DUAL` false: dfetch single-clock on clk_core; eng/m27_axi on core_clk's ASSOCIATED_BUSIF, through d_cdc + d_rs to SAXI_29 |
| 6 | build_card.tcl, jccard_post.tcl | Critical rows at no named synchroniser read against a450_cdc_rules (less the gate stub's) + jccard_a450_rules (core_reset -> ar1); CDC-10 refused by id before any rule |
| 7 | gen_jc_card.py, a450_pblocks.tcl | axi_register_slice (all channels REG 1, AXI3) on aclk_a between each converter / hbm_sc and its port; converter + slice in the port's column pblock (pb_a450_ip_x7 for 30/31) |

Cadence under the split (Task 8 Step 11): port_beats is not available on a split-on card
(no counters); the cadence is measured from the seam's cycles only.

### Procedure

1. Extend the gate: `hw/jc/a450/a450_tg.vhd` (an AXI3/AXI4 traffic generator whose read data
   and responses are folded into `led`, so synthesis keeps both channels), six of them on
   clk_core in `a450_hbm_top` (x_ld, x_d read-only, x_bc0/1, x_ctl, x_tok), the card's IP
   chains in `a450_bd.tcl`, all 32 SAXI enabled with the card's switch clocks.  The CONFIG
   sets are pinned equal to the card render by `test_a450.py::test_gate_ip_is_the_cards`.
2. `run_a450.sh` (explore) under run_capped in the foreground of a background shell.
3. When r1 refused its own placement (below), validate the placed-floorplan check on
   r6's routed checkpoint before spending another run (probes under run_capped, 16G cap).

### Evidence

    a450_hbm_9b_r2 (build.log, run_a450.out in hw/jc/a450/results/a450_hbm_9b_r2/)
    A450HBM_PLACED pblocks 8 tiles_inside 24 ip_inside 10 min_in_column 0.910 failures 0
    INFO: [Place 30-746] Post Placement Timing Summary WNS=-0.383
    INFO: [Route 35-20] Post Routing Timing Summary | WNS=0.028  | TNS=0.000  | WHS=0.009  | THS=0.000  |
    A450HBM_WNS_ACLK 0.028 LEVELS 0 START .../fast/tree/r_x_reg[125]/C END .../fast/tree/m_x_reg[0][125]/D
    A450HBM_WNS_CORE 0.253
    A450HBM_FAILING_ACLK 0
    A450HBM_IP ld_cdc +0.192  ld_rs +0.410  d_cdc +0.253  d_rs +0.360  bc_cdc0 +0.241  bc_rs0 +0.301
               bc_cdc1 +0.122  bc_rs1 +0.243  hbm_sc +0.145  sc_rs +0.139   (REQ 2.222 each)
    A450HBM_RSTAR1 SLACK 1.784   A450HBM_TOGS1 SLACK 1.443
    A450HBM_UTIL LUT 116180 FF 140495 BRAM 155 DSP 1585      (r6: LUT 102287 FF 109810 BRAM 151)
    A450HBM_CDC flagged_summary 1553 flagged_rows 1553 unlisted 0
      (hbm_sc_node_fifo 682, dbg_hub_fifo 4, stub_base 459, stub_beats 200, job_cbk 128, ...)
    A450RUN_PASS 0.028
    samples: sampled_peak_current=21742964736 sampled_peak_swap=1392484352 sys_min_MemAvailable=2075115520

The IP's worst paths are converter-internal (s_ready replica -> FIFO dout, 1 level) and the
HBM ACLK -> slice payload CE paths, 0.12 to 0.41 ns positive; the diagnosis's -0.46..-0.94
on the card were HBM ACLK -> converter FIFO paths with no slice and no pblock.

Placed-floorplan check on r6's routed checkpoint (probe3, MEASURED): pblocks `IS_SOFT 1`; all
24 tiles have no unplaced primitive; in_column 0.906 (tile 6) to 1.000; 19 of 24 tiles have
some sites in the neighbouring column.  Teeth: the same proc with tile 0 assigned to column X3
prints `in_column 0.000 ... BAD`.

GHDL (tb_matvec_fk33_desc_tiled): GREEN `OVERALL PASS 1`, `23 cases run, 0
failures`, `UTIL counters NOT BUILT ... for all 56 selections, and at once with mclk stopped`.
RED: HEAD's RTL and the mutant `D_DUAL := DUAL_CLK` both stop at 41559 ns with `descriptor
port moved off a clk edge`; the mutant `U_ON := true` reports `UTIL_SEL (not built) read back
00000000 ... MISMATCH` and `UTIL_DATA ... read 00000480`.

### Measured and REJECTED (do not retry)

- **"Every primitive of a tile inside its pblock after placement" as the card's gate.** The
  pblocks are soft: r6, the run that closed, has 19 of 24 tiles partly in the next column
  (in_column down to 0.906 after route) and r2 has 0.910 at placement.  The check is a share,
  >= 0.80 (`A450PB_MIN_IN`), with no unplaced primitive; the unfloorplanned card's typical
  tile was 0.11 to 0.33.

### Measurement traps hit

- **a450_hbm_9b_r1 refused its own placement (my bug, ~25 min lost):** the first
  `a450_pb_regions` found leaf cells with a NAME glob, which reads `g_t[0]` as a character
  class, and filtered on `IS_PLACED`, which cells do not have (`get_cells -quiet` turns the
  bad filter into an empty list, so the IP cells, with no bracket, also matched 0).  Fixed to
  `current_instance` + `LOC`, items looked up by exact `NAME ==`, and validated on r6's
  checkpoint before r2.
- **The gate's memory peak is no longer r6's 11.4 GB:** r1 and r2 reached memory.peak 19.4
  and 21.7 GB under the 24G cap (r2: 1.39 GB unit swap; the box's MemAvailable fell to 2.07 GB
  with two GHDL benches beside it).  Budget the extended gate at about 22 GB.
- **Post-placement WNS -0.383 (r1 and r2, identical)** routed to +0.028: placed WNS ranked
  this run below r6 (-0.166 placed, +0.014 routed); not a result before route_design.

### Deviations from the brief, stated

- Fix 6 asked for "the three reset fan-out rules from the diagnosis".  Only the ar1 one is a
  rule (`core_reset_fanout_ar1`; a450's `rst_ar1` matches it too).  The other two
  destinations (`dfetch/g_dc.rst_s1`, `gu.gdc.rst_s`) do not exist under the split (fixes 4
  and 5), and a rule nobody can match is not kept (a450_cdc.tcl policy); a row into either
  is now unknown, i.e. refused, which is the regression signal.
- The pblock check is a share, not "every tile inside" (Measured and REJECTED above).

### Open, not yet answered

- The card itself: C's attention array and the other SLR0 tenants beside the floorplanned A.
- Whether fix 3 (C into SLR1) is needed: no measurement either way.

### CORRECTION 2026-11-15 (Task 9b fix round 1, review m4)

WITHDRAWN: "the unfloorplanned card's typical tile was 0.11 to 0.33" (in the Measured and
REJECTED entry of the section above).  MEASURED from diag9 `tile_regions.txt` with the same
per-site clock-region share a450_pblocks_placed computes: jccard_a450s1b's tiles were 0.022 to
1.000 in their port's column, 19 of 24 below 0.80, and 5 (tiles 0, 1, 3, 5, 9: 0.850, 0.899,
0.896, 0.950, 1.000) above it.  So the 0.80 per-tile threshold does not separate a floorplanned
tile from an unfloorplanned one near the HBM's left end; the build-level verdict (any failing
tile refuses) does, and refuses that card on 19 tiles.  The share is a column test only (no Y
distance).  Pinned by `hw/jc/a450/test_a450.py::test_placed_share_refuses_the_unfloorplanned_card_and_accepts_the_closing_runs`
on `hw/jc/a450/testdata/placed_shares.txt` (jccard_a450s1b refused 19/24, r6 and 9b_r2 accepted
24/24); a threshold-0.0 mutant accepts the card (RED).

Also (review findings 2 and 6, recorded, not changed):
- Fix 5 is covered AROUND d_cdc, not through it: GHDL runs the fetch single-clock against an
  ideal slave on clk; latency, backpressure through the converter and the reset window
  (aclk_reset asserts before core_reset, so d_cdc's m side is in reset while dfetch can still
  issue) are covered only by Xilinx's IP and the routed timing.  OPEN.  d_cdc's two resets are
  now pinned by test (`test_split_on_d_cdc_resets_are_the_engine_and_hbm_port_resets`, five
  mutants refused): s side on eng/core_aresetn's net, m side on the HBM ports' ARESET_N net.
- `core_reset_fanout_ar1` narrows nothing on the card: a450's `rst_ar1` accepts any source into
  ar1/D; the backstop is a450_cdc's fan-in check (every rst source on clk_core).
