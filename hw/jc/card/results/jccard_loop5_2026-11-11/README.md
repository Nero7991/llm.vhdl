# jccard_loop5: first Jungle Cat card with the on-fabric token loop and the die-to-die link (2026-11-11)

`jc_card.bit` for xcvu35p-fsvh2104-2L-e, clk_core 125 MHz, built by
`JC_LINK_REFCLK=gtg JC_LINK_RATE=10.3125 hw/jc/card/run_card.sh --clk-mhz 125 --impl congestion`
from jc-loop f10d5354 plus build12_levers_off.patch (PROVENANCE.txt). sha256 in BITSTREAM.sha256.
Same bitstream on both dies; TX/RX role is a runtime register.

MEASURED (Vivado 2023.2, routed design, build.log.gz):
- JCCARD_POST_ROUTE_WNS 0.066 (WHS positive), JCCARD_DONE
- JCCARD_CDC_REPORT_CRITICAL summary=0; JCCARD_LINK_CDC_UNEXPECTED 0; JCCARD_LINK_EXC_AUDIT bad=0
- ECOA_DONE commons=1 loads=1 (QPLL1 refclk from the gtg MMCM via GTGREFCLK1); JCCARD_GT_LOC GTYE4_CHANNEL_X0Y0;
  JCCARD_GTG_MMCM LOC=MMCM_X0Y2 CDR=BACKBONE; JCCARD_CBDATA_REPL drivers 12->120
- Utilisation: 380,810 LUT (43.7%), 315,063 FF, 588 BRAM tiles, 51 URAM
- Peak memory 21.3 GB, swap 0

Builds before this one (same plan, all stopped by their own gates): loop1 netlist-const gate (seam resp
constant by design), loop2 link CDC bounds orphaned by the ECO clock rename (-2.306), loop3 CDC-10 on
Aurora status outputs, loop4 --impl default missed timing in C (-0.350). Ledger: jc-loop
.superpowers/sdd/2026-11-04-jc-on-fabric-loop-and-link/progress.md (not tracked).

Not yet run on silicon: Task 8 of docs/superpowers/plans/2026-11-04-jc-on-fabric-loop-and-link.md.
Caveat (UG578): GTGREFCLK is "reserved for internal testing purposes only"; QPLL1 via GTGREFCLK1 never measured.
