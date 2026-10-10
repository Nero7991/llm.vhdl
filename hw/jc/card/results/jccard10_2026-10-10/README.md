# jccard10: Jungle Cat 27B card bitstream with the rmsnorm fix (2026-10-10)

`jc_card.bit` for xcvu35p-fsvh2104-2L-e, one clk_core domain at **125 MHz**, built by
`hw/jc/card/run_card.sh --clk-mhz 125 --impl congestion` from HEAD cdfc0a79 plus
build12_levers_off.patch (see PROVENANCE.txt). sha256 in BITSTREAM.sha256.

Differences from jccard8 (HEAD c77ae78f): the rmsnorm_bf_mem exact mean at N = 5120
(2a9211c1; docs/debugging/2026-10-09_jc-27b-first-token-residual-gain.md, addendum 2), the RTL
fan-out fixes 2c58786b / dcb77e2d / 4b7ca527 (first card build with them), and 5 more allowed
constant inputs, bcgrant/c_awaddr[4:0] (cdfc0a79; jccard9 stopped at that check).

MEASURED (Vivado 2023.2, routed design):

| | jccard8 | jccard10 |
|---|---|---|
| WNS / TNS / WHS / THS | +0.137 / 0 / +0.009 / 0 | +0.109 ns / 0 / +0.009 ns / 0 (JCCARD_WNS gate passed) |
| route_status | 656,939 nets, 0 errors | 666,083 nets, 0 errors |
| bus skew | 0 violated | 0 violated |
| CDC report | 0 critical, 0 unexpected | 0 critical, 0 unexpected |
| BSCAN census | ok | ok post_opt and pre_write_bitstream |
| levers | NWIDE, SWEEP_PIPE, SCORE_EARLY off; FAST_POP false | same |
| netlist inputs | 15,090 checked, 729 allowed, 0 refused | 15,090 checked, 734 allowed, 0 refused |
| CLB LUT / CLB | 366,696 (42.07%) / 72,824 (66.84%) | 373,089 (42.80%) / 75,644 (69.42%) |
| CLB registers | | 306,013 (17.55%) |
| BRAM / URAM / DSP | 565 / 50 / 2024 | 565 / 50 / 2026 (34.04%) |
| memory | unit peak 20.6 GB, swap 0.56 GB | unit peak 23.7 GB, swap 0, min system MemAvailable 2.93 GB |

The two extra DSPs are consistent with the norm's constant reciprocal multiply mapping to DSPs
(ESTIMATE: not confirmed against the hierarchy).

Not yet done: the silicon gate. Program both dies (VCCINT 0.85 V: this image is timed there),
load both 27B images, then judge the fix on the residual against llama.cpp at positions 0, 3
and 22 (hw/jc/card/results/jc27b_first_token_2026-10-09/xout_vs_lout.py), not on the argmax:
with the fix the reference model still prefers 1206 over 7732 by 0.116 logit, inside the
0.16 resolution. Then the 500-token context test.
