# Build 18 composition (prepared 2026-09-23 00:20, NOT launched; Oren's call)
Tree: worktree /mnt/storage/fk33_builds/wt18 at HEAD (the commit withdrawing the shadow) + build12_levers_off.patch.
RTL over build 14 (the last image that computes correctly on silicon): (1) the KV fetcher counters (f14121d; exonerated
on silicon by draw 3b, bit-exact in every bench, OOC 37 -> 17 levels); (2) the card window via the element read port
(this commit) in place of the withdrawn shadow. region_mem is byte-identical to build 14's except a header comment.
Env: FK33_CARD=1 FK33_CB_STYLE=distributed FK33_ENG_CORE_MHZ=75 (launch.sh); cap 24G/26G; guard 30 GB; default flow,
rescue chained on a route failure.
NEW IN THE FLOW: FK33_REGION0_WE census after synthesis (validated FAIL on build 17's netlist, OK on build 14's).
PREDICTIONS, pre-registered:
  - FK33_REGION0_WE OK, 4 region-0 BRAMs, 8 live write pins each (build 14's shape). If it says FAIL the build stops
    at synthesis and the window design is wrong in a way GHDL cannot see; do not override it.
  - BRAM 567 (build 14's), not 569: the shadow's two tiles are gone. LUT within a few hundred of build 17's 361,488;
    the window mux costs tens of LUTs. DSP 2,087. FF within tens of build 17's.
  - Timing: worst 75 MHz path not in u_kv; closure not predicted (build 17 closed at +0.373 on this netlist minus
    the shadow, so the routing lottery is the main risk, as ever).
  - Silicon: control argmax 32 / exp 15, run_chunk 24.578 s within 0.004% (the counters change no cycle; the window
    adds reads on idle cycles only); token 0 argmax 846, XEXP_OUT 8, and --dump-xout == tok0.r9bs R_X-31 on all
    4,096 mantissas (xout_vs_ref.py PASS). That last line is the two-card hop's precondition.

## RELAUNCH 00:38 after the swap guard killed the first attempt (MEASURED)
Attempt 1 (00:25): killed by the guard at swap 30G / avail 740 MB at 00:35, ten minutes into synthesis (after RTL
elaboration, in RTL optimisation). Build 17 peaked at 26G in the same phase from a 4G baseline; this box now sits at
7-8G of stale swap (no Ollama model loaded, no llama-server; Shmem 9.6 GB was present for build 17 too), so the same
footprint crosses the line. ONE recorded parameter differs from build 17's launch: FK33_SYNTH_THREADS=1 (build 17:
the card default 2), which drops one ~2.4 GB synthesis worker; synthesis is expected ~30% slower. Everything else
identical. Guard stays at 30G. The killed attempt's root is at build18/root_killed_0035 (256 MB).

## SYNTHESIS + FK33_REGION0_WE, 01:19 (MEASURED)
Synthesis done 01:17 (one thread; swap peaked 29G against the 30G guard, MemAvailable down to 1.6 GB, Vivado's own
peak 32.26 GB). FK33_REGION0_WE: bank_reg_1_0 / 1_1 / 2_0 / 2_1 live_write_pins = 8 / 8 / 8 / 8, OK. Prediction HIT:
the engine's R_X has its write port back, in the netlist, before a minute of place-and-route was spent on it.

## PLACED, 02:17 (MEASURED; build 17 in brackets)
LUT 358,846 (361,488: -2,642) | FF 310,214 (310,004: +210) | CARRY8 12,252 (12,232) | F7 28,408 (28,609) | F8 5,950 (6,046) |
CLB 54,726 (54,746: -20, 99.57%) | **BRAM 567 (569: -2, the shadow's tiles gone: prediction HIT)** | DSP 2,087 (2,087).
"LUT within a few hundred of build 17" MISSED low: -2,642; the shadow's write decode was 155 LUTs, the rest is the
window mux replacing a duplicate and packing variance. Placer congestion regions (smaller is better): N 8x8 (17: 16x16),
S 32x32 (32x32), E 32x32 (16x16), W 64x64 (32x32): a less favourable draw than build 17 in the West. Placement 01:23
to 02:17 at one thread. Router `% Tiles` appended when printed.

## ROUTER, 02:38 (MEASURED)
Global % Tiles: N 1.48 (8x8), S 10.47 (32x32), E 5.21 (32x32), W 7.49 (16x16); max 10.47 SOUTH (build 17: 9.64; the
rescue that routed build 14: 10.37; the failed draws 11.73-11.92). Global Iteration 0 ended at 0 overlaps (build 17: 0;
build 15 draw 3: 530), intermediate WNS +0.561 (17: +0.330 at the same point).

## ROUTED, 04:26 (MEASURED)
677,082 of 677,082 nets routed, 0 routing errors, 0 failed-net warnings, Phase 8 clean; iterations ended 0 / 1 / 1 / 0.
Design Timing Summary: WNS 0.096, TNS 0.000, 0 failing of 1,527,886; WHS 0.009, 0 failing. Core clock clk_out3 WNS
**+0.225** (0 failing of 1,292,476), pipe_clk +0.578, sysref +0.204. CLOSED at 75 MHz on the first default draw
(build 17: +0.373 on the core clock; the difference is within the routing-draw floor and the window mux sits on the
element read path). Bitstream written 04:25.
