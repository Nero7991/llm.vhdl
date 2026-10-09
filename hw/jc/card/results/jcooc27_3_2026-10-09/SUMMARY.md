# jcooc27_3: 27B OOC route at 200 MHz with the RTL fan-out fixes (2026-10-09)

One variable against jcooc27_2 (`../jcooc27_2_2026-10-07/`): the RTL fan-out fixes
2c58786b, dcb77e2d, a552b74f, 4b7ca527 (attention S2 write-control replication, matvec
row-group copies, the pre-decoded job issue pulse). Tree: `rtl/` at 4b7ca527 (the three
touched files compared byte-equal against `git show 4b7ca527:`), plus
build12_levers_off.patch (NWIDE/SWEEP_PIPE/SCORE_EARLY bound false, read back from
build.log). Run: `hw/jc/card/run_ooc27.sh /mnt/storage/fk33_builds/jcooc27_3
xcvu35p-fsvh2104-2L-e 20G`, MemoryHigh 20G read back from the cgroup, swap guard 4 GiB.

MEASURED (Vivado 2023.2, report_timing_summary on the routed design):

| | jcooc27_2 | jcooc27_3 |
|---|---|---|
| route_status | 626,572 nets, 0 errors | 638,780 nets, 0 errors |
| WNS | -2.431 ns | -1.290 ns |
| TNS | -135,820 ns | -41,609 ns |
| failing endpoints | 286,285 of 1,493,147 | 120,514 of 1,512,899 |
| WHS / THS | +0.010 / 0 | +0.010 / 0 |
| CLB LUT | 354,718 (40.69%) | 363,397 (41.69%) |
| CLB | 73,502 (67.46%) | 77,026 (70.69%) |
| CLB registers | 283,380 (16.25%) | 287,873 (16.51%) |
| BRAM / URAM / DSP | 524.5 / 50 / 2,023 | 524.5 / 50 / 2,023 |

DERIVED: Fmax = 1 / (5.000 + 1.290) ns = 159.0 MHz (jcooc27_2: 134.6 MHz). The 1.14 ns
WNS change is above the ~0.75 ns routed-noise floor, so it is a result; it is still
1.29 ns short of 200 MHz.

The two families named in jcooc27_2 have moved: `u_arr` is down to 1 of the 20 reported
worst endpoints. The worst paths now:
- B LUTRAM writes: `u_regmem/g_region[11|12].bank_reg_2_*` (BRAM CLKBWRCLK) ->
  `gb_real.bp.zbw_reg_*` DP/SP I, slack -1.26 to -1.29 ns.
- C header: `gcr.u_attn/vhdr_reg[96]` -> `vref_r_reg[*][7]`, about -1.27 ns.
- Of the 20 endpoints in timing_routed.rpt: u_eng 32 path lines, gcr.gkvaxi.u_kv 20,
  gb_real.gen_st_tier.u_state 20, gb_real.bp 12 (a count of Destination lines, not a
  census of the 120,514 failures).

Memory: sampled peak resident 21.47 GB (the 20G cap: not an appetite), sampled peak swap
2.53 GB, minimum system MemAvailable 5.73 GB.
