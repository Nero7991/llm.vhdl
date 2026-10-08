# jcooc27_2: 27B OOC route at 200 MHz, xcvu35p-fsvh2104-2L-e (2026-10-07)

Tree: HEAD 4b8c8206 + build12_levers_off.patch (NWIDE/SWEEP_PIPE/SCORE_EARLY bound false,
read back from build.log). Run: `hw/jc/card/run_ooc27.sh /mnt/storage/fk33_builds/jcooc27_2
xcvu35p-fsvh2104-2L-e 20G`, MemoryHigh 20G read back from the cgroup, swap guard 4 GiB.

MEASURED (Vivado 2023.2, report_timing_summary on the routed design):

| | value |
|---|---|
| route_status | 626,572 nets fully routed, 0 routing errors |
| WNS / TNS | -2.431 ns / -135,820 ns, 286,285 of 1,493,147 endpoints failing |
| WHS / THS | +0.010 ns / 0 |
| CLB LUT | 354,718 (40.69%) |
| CLB | 73,502 (67.46%) |
| CLB registers | 283,380 (16.25%) |
| BRAM tiles | 524.5 (39.03%) |
| URAM | 50 (7.81%) |
| DSP | 2,023 (33.99%) |
| congestion (placer/router estimate) | level 6 global and timing |

DERIVED: Fmax = 1 / (5.000 + 2.431) ns = 134.6 MHz.

Worst paths are route-dominated (about 6.0-6.6 ns of 7.1-7.4 ns data path is routing,
8-15 logic levels), in two families:
- C, `u_card/u/gcr.u_attn/u_arr`: `blk2_reg[*]_replica_*` -> `ov_r_reg` / `acc_reg[*]`,
  and `acc_reg[i]` -> `acc_reg[j]` across accumulator indices.
- B, `u_card/u/u_fetch/cur_unit_reg[0]_rep__0` -> `gb_real.z_mant_reg[*]` and the
  `gb_real.bp.zbw_reg_*` LUTRAM write ports (DP/SP I and WE): one high-fanout select.

Memory: peak resident hit the 20G cap (synthesis), sampled peak swap 2.18 GB, minimum system
MemAvailable 3.96 GB. Wall time about 4 h 15 min.
