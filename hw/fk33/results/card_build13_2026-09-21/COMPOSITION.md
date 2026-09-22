# Build 13 composition (stated before launch, 2026-09-21 19:20)
Tree: worktree /mnt/storage/fk33_builds/wt13 at 9de6ee4 (HEAD), NO patch.
  = build 12b's tree (3e344a2) plus docs/results-only commits; RTL and generators
    identical (git diff --stat 3e344a2 HEAD over rtl/, hw/fk33/rtl, generators: empty).
Levers, all as committed at HEAD:
  FAST_POP     ON   (hw/fk33/gen_fk33_engine.py:114 FAST_POP_DEFAULT = True)
  NWIDE        ON   (rtl/llama_top.vhd:5548)
  SWEEP_PIPE   ON   (rtl/llama_top.vhd:6997)
  SCORE_EARLY  ON   (rtl/llama_top.vhd:6997)
  codebook     REVERTED (rtl/matvec_core.vhd md5 b616c7822f93154b08200f9418489012, same as 12b)
  B_RECUR_LANES unchanged (OFF)
Environment: FK33_CARD=1 FK33_CB_STYLE=distributed FK33_ENG_CORE_MHZ=75 BUILD_ROOT=/mnt/storage/fk33_builds/build13/root
Cap: MemoryHigh=24G MemoryMax=26G, swap guard kills at 30 GB swap or 10 GB free on /mnt/storage.
Budget at launch: box 31 GB, 5 GB resident, 25 GB available, 4.9 GB swap in use, load 0.19, no Vivado on the box
  (/proc/PID/exe census empty). Build 12b closed under the identical cap and shape.
Difference from build 12b: exactly the four levers. One-variable? NO: four levers at once, by Oren's choice
  ("Launch build 13"); the per-lever OOC area is recorded in attndraw_2026-09-21 and hdrcost results.
Prediction, pre-registered: closes at 75 MHz (each lever has routed OOC at the card generics with positive WNS;
  12b has 509 free CLB tiles and the four levers cost +69 LUT sites net in ATTNDRAW's measurement).
  Decode intercept should fall (FAST_POP, NWIDE act on A/D), slope 2796 -> ~1818 cycles/pos (SWEEP_PIPE+SCORE_EARLY).
CORRECTION 19:35: NWIDE is a B-mover lever (gdn_state_store, 748ff91), not A/D. PIPE and WIDE were already ON in 12b
  (14fa888). Prediction: B_JOB from 324k to ~234k per job (-2.15 M cycles/token, -9.7% at p=0); FAST_POP acts on A/D
  descriptor pop; SWEEP_PIPE+SCORE_EARLY on the C slope (2796 -> ~1818 cycles/pos).
