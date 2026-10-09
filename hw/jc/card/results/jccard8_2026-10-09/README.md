# jccard8: first Jungle Cat 27B card bitstream (2026-10-09)

`jc_card.bit` for xcvu35p-fsvh2104-2L-e, one clk_core domain at **125 MHz**, built by
`hw/jc/card/run_card.sh --clk-mhz 125 --impl congestion` from HEAD c77ae78f plus
build12_levers_off.patch (see PROVENANCE.txt). sha256 in BITSTREAM.sha256.

MEASURED (Vivado 2023.2, routed design):

| | value |
|---|---|
| WNS / WHS | +0.137 ns / +0.009 ns or better (JCCARD_WNS gate passed) |
| route_status | 656,939 nets fully routed, 0 routing errors |
| bus skew | 16 constraints, 16 with paths, 0 violated, worst +7.256 ns |
| CDC report | 0 critical crossings; ctl CDC audit 0 unexpected |
| BSCAN census | hub on chain 1, ctl on chain 3, loader on chain 4, one jtag_hbm |
| levers | NWIDE, SWEEP_PIPE, SCORE_EARLY bound off; FAST_POP false |
| netlist inputs | 15,090 checked, 729 allowed constants, 0 refused |
| CLB LUT / CLB | 366,696 (42.07%) / 72,824 (66.84%) |
| BRAM / URAM / DSP | 565 (42.04%) / 50 (7.81%) / 2024 (34.01%) |
| memory | unit peak 20.6 GB, swap 0.56 GB |

Implementation strategy `congestion`: opt ExploreWithRemap, place AltSpreadLogic_high,
phys_opt and route AggressiveExplore. The same tree with the default strategy (jccard7,
2026-10-08) placed at WNS +0.513 but routed at -8.833 ns (49,432 endpoints, routing
congestion in C's u_arr and A's core).

Not yet done: the silicon gate (program, identify, load both 27B images, first-token argmax
against the CPU reference, the 500-token context test). VCCINT on the card is 0.65 V at the
time of this build and must be returned to 0.85 V before programming: this image is timed
at 0.85 V only.
