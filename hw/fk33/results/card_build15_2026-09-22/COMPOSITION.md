# Build 15 composition (stated before launch, 2026-09-22 08:35)
Tree: worktree /mnt/storage/fk33_builds/wt15 at f0fcb37 (HEAD) PLUS build12_levers_off.patch
  (4 files, 6 insertions, 6 deletions): FAST_POP, NWIDE, SWEEP_PIPE, SCORE_EARLY all OFF, as 12b and 14.
What differs from build 14: ONLY the R_X shadow in rtl/region_mem.vhd (SHADOW_REGION => R_X from gen_cardtop.py,
  fk33_llama_top.vhd regenerated): one more single-write-port bank of R_X's size (4096 x 16 = 2 RAMB36 expected)
  with a registered read serving hr_data / seam window 3. Nothing else in rtl/ or the generators.
Environment: FK33_CARD=1 FK33_CB_STYLE=distributed FK33_ENG_CORE_MHZ=75 BUILD_ROOT=/mnt/storage/fk33_builds/build15/root
Cap: MemoryHigh=24G MemoryMax=26G, swap guard at 30 GB swap / 10 GB free on /mnt/storage.
Budget at launch (MEASURED): box 31 GB, used 5, available 25, swap 5 GB, ZERO Vivado by /proc/PID/exe.
PLAN: the default flow runs synthesis; when FK33_RUNDONE synth_1 appears the unit is STOPPED (the default implementation
  recipe failed to route builds 13 and 14 at this CLB fill and the rescue recipe routed 14 and card_swg from their own
  checkpoints, 2 for 2), and reimpl.tcl runs impl_1 from build 15's synth checkpoint under Congestion_SpreadLogic_high /
  ExtraNetDelay_high / AlternateCLBRouting. So this build has NO default-recipe draw; the recipe question is not asked here.
Prediction, pre-registered: synthesis reports BRAM 567 + 2 = 569 (or 4 RAMB18-equivalents), LUT within scatter of 14;
  the re-implementation routes (0 errors) and closes at 75 MHz within the 0.4 ns of 14's +0.056; congestion recorded at
  Global Iteration 0 as a figure, not a verdict. On the card: caps 0x7D, and run_prompt --dump-xout on token 248045
  must equal tok0.r9bs R_X-31 (exp 8 AND all 4,096 mantissas). Throughput identical to 14/12b to the 0.004% floor.
