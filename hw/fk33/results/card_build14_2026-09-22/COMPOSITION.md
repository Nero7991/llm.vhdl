# Build 14 composition (stated before launch, 2026-09-21 23:40)
Tree: worktree /mnt/storage/fk33_builds/wt14 at 330b70f (HEAD) PLUS
  hw/fk33/results/card_build12_2026-09-21/build12_levers_off.patch (the exact 4-file, 8-line
  patch build 12b used): FAST_POP false (generator + fk33_engine.vhd), NWIDE false, SWEEP_PIPE
  false, SCORE_EARLY false (llama_top.vhd + fk33_llama_top.vhd). git diff --stat: 4 files, 6 insertions, 6 deletions (MEASURED after apply).
What differs from build 12b (3e344a2 + same patch): the two-card pipeline's XEXP_OUT register
  (rtl/seq_region_lock.vhd cap_* ports, llama_top x_exp_out, fk33_seam 0xA4 + caps bit 6,
  fk33_card x_exp_out pin, gen_pcieep SEAM_FROM_CARD entry; commits 863d173..f0b5412) and the
  regenerated build_fk33_pcieep.tcl carrying its GENSTAMP. Nothing else in rtl/ or the generators
  (git diff --stat 3e344a2 HEAD -- rtl hw/fk33/rtl hw/fk33/gen_*.py tools/gen_cardtop.py is those files only).
Levers: all OFF, as 12b. codebook REVERTED (same matvec_core.vhd as 12b). B_RECUR_LANES unchanged.
Environment: FK33_CARD=1 FK33_CB_STYLE=distributed FK33_ENG_CORE_MHZ=75 BUILD_ROOT=/mnt/storage/fk33_builds/build14/root
Cap: MemoryHigh=24G MemoryMax=26G, swap guard kills at 30 GB swap or 10 GB free on /mnt/storage.
Budget at launch (MEASURED free -g, /proc/PID/exe census): 31 GB box, 6 GB used, 24 GB available,
  5 GB swap in use, load 0.38, ZERO Vivado processes on the box. Build 12b closed under the identical cap and shape;
  build 13 (same shape, four levers on) peaked at 7 GB swap in place-and-route, 25 GB swap in synthesis (12b).
Prediction, pre-registered: routes legally and closes at 75 MHz like 12b (the register is ~17 flops and one
  read-mux entry on the 75 MHz side and the seam's 250 MHz side; no lever). Congestion figure to be recorded
  mid-Phase 4 in PREDICTION_congestion.md against the 12.5 threshold (12b scored 11.95). Throughput identical to
  12b to the 0.004% silicon floor. fk33ctl.py seam must show caps 0x7D (bit 6) on the loaded card.
This is Task 11 Step 1 of docs/superpowers/plans/2026-09-21-two-card-pipeline.md, branch "build 13 fails".
