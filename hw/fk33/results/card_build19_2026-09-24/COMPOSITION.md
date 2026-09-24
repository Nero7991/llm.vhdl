# Build 19: 9B card with NORM_HBM (plan Task 2), tree 8af98b8

Launched 2026-09-23 15:00:41, same recipe as build 18 (FK33_CARD=1, CB_STYLE=distributed,
ENG_CORE_MHZ=75, SYNTH_THREADS=1, MemoryHigh=24G MemoryMax=26G, swap guard 30G).

## Default flow (MEASURED)
- synth_design done ~15:47 (43 min elapsed, Vivado peak 13,661 MB). FK33_REGION0_WE OK (4 of 4).
- Placed utilisation (same stage as build 18's 358,846 / 310,214 / 567 / 2,087):
  LUT 358,660 (81.57%), FF 308,595, Block RAM tiles 496 (73.81%, -71), URAM 32, DSP 2,087.
- place_design 41 min (ExtraPostPlacementOpt), phys_opt 2 min, route_design (Explore) from ~16:56.
- Router congestion estimate: global/short level 6 (64x64), timing level 7 (128x128).
  Build 18: level 5 and 6. Both printed Route 35-447 (congestion preventing routing all nets).
- Route FAILED at ~21:29: `ERROR: [DRC RTSTAT-6] Partial route conflicts: 21809 net(s)`;
  write_bitstream not run. Checkpoints and logs kept in KEEP_build19_dcp/draw1.
- Not established: WHY build 19 is more congested than build 18 at near-identical LUT and fewer
  BRAM. One draw each; the placement differs. Do not attribute it to NORM_HBM without a control.

## Rescue (from the SAME synth checkpoint, so one netlist)
Congestion_SpreadLogic_high, place ExtraNetDelay_high, route AlternateCLBRouting (the recipe that
rescued card_swg_2026-09-20). Chain launch at 21:29:44 FAILED with status 126: the build 19 scripts
were copied from build 18 with sed, which dropped the execute bit (my error). Relaunched by hand
~21:33 after chmod +x, same caps.

## Rescue result (MEASURED, 2026-09-24 00:18)
FAILED to route: `ERROR: [DRC RTSTAT-6] Partial route conflicts: 264 net(s)` (default draw: 21,809).
Last intermediate route WNS -1.661 ns, TNS -151.288 (not a result). Build 18's same flow routed.
So TWO implementations of this ONE netlist (identical synth checkpoint) do not route, on two recipes.

## Next: location before cause
`cong/cong.tcl`: report_design_analysis -congestion on the placed checkpoints of build 18 (control),
build 19 draw 1 and the rescue, plus the clock regions of the new norm-fetch cells (`gvr.gwh`) and
the bst read mux (`gnm`). Hypothesis registered BEFORE the result, not yet tested: the 256-bit
bst_rdata now fans out to a second consumer (the fetch's holding register) as well as the state
store. Naming a region does not name a cause.

## Congestion location (MEASURED 2026-09-24, cong/cong_*.rpt, placer-level report_design_analysis)
| placement | L7 windows | L6 windows | routed |
|---|---|---|---|
| build 18 (control) | 2 | 6 | yes |
| build 19 draw 1 | 3 | 11 | no, 21,809 conflicts |
| build 19 rescue | 2 | 8 | no, 264 conflicts |
Every level-6/7 window is led by bd_i/eng/.../core (A), gcr.u_attn/u_arr (C), gkvaxi.u_kv or
pcie2hbm; the norm fetch (gvr.gwh, 744 cells) and the bst mux (gnm, 23) are named in none.
The registered hypothesis (the 256-bit fetch bus) is NOT SUPPORTED by this location. The rescue's
placer congestion is the control's; this card is at the routability edge and build 18 routed.
The norm-fetch cells ARE spread over 5-7 clock regions in both draws (e.g. X2Y0 496, X4Y3 171),
i.e. pulled between the norm unit and the HBM side; small, not implicated, noted.

## Rescue 2: reroute the rescue's routed checkpoint (reroute/rr.tcl)
route_design -directive AggressiveExplore on KEEP_build19_dcp/bd_wrapper_routed_rescue.dcp,
bitstream only if 0 conflicting / unrouted / partial nets. Launched 2026-09-24 ~00:50.

## Rescue 2 RESULT (MEASURED 2026-09-24 ~02:20, reroute/rr.log)
Routed clean: `RR_AFTER conflicts/unrouted/partial=0 0 0`, report_route_status 677,170 fully routed
nets, 0 with routing errors. Timing met: WNS +0.008 ns, TNS 0, WHS +0.010 ns, 0 failing of 1,522,649
setup / 1,522,601 hold endpoints ("All user specified timing constraints are met"). DRC: warnings
only (DPIP/DPOP pipelining, PDCN-1569, REQP collision advisories, RTSTAT-10 x1). Bitstream written
from the checkpoint (bitstream settings are XDC properties, so they travel in it): 24,853,834 B,
sha256 9366b396d3603bf66aab72625250fcb407a77573dd46d103661167df64057c18.
So: same synthesis netlist as the default draw, the rescue's placement, and a second router pass.
The WNS margin is 8 ps, a BOUND and not a comparison with build 18's +0.096.
Trap hit: the background waiter on this run was reaped by Claude Code under memory pressure; the
Vivado unit was unaffected and ran to its sentinel.
