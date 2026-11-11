# JC die A: A's HBM inefficiency is lateral traffic across the HBM switch (2026-11-11)

## Question
Backlog 12 (2026-11-10): "A sits at 0.327 of its HBM port ceiling on JC die A. Find where A stalls."
Hardware: Jungle Cat, die A, bitstream jccard10 (sha256 d00e237e..., 125 MHz, levers off, FAST_POP=false),
27B card0 image (blocks 0-32) reloaded 2026-11-11 (JCVERIFY_PASS 7170 pieces, side image 3 pieces).

## Answer
Confirmed (MEASURED): A's cycles per weight word depend on how the tensor's lanes sit across the HBM
pseudo-channels. A tensor with 15/27 lanes on their own pseudo-channel and at most 1 lane per lateral
switch boundary runs at 1.51 c/word (util 0.662); a tensor with 0/27 on their own pseudo-channel and 7 lanes
per boundary runs at 4.76-4.85 c/word (util 0.21). The layout, not the RTL, is the dominant loss. Next: P1,
repack die A so each lane's weights sit on its own pseudo-channel (no RTL, no bitstream).

## Procedure
1. `tools/jc/jc_run_job.py plan` (branch worktree-agent-a958032c600c34199, bf7554e3): lane-to-PC census per
   tensor from the die's manifest. attn_gate: own_pc 15/27, max 1 lane per boundary; ffn_gate: own_pc 0/27,
   max 7. Isolates layout as the variable between the two jobs.
2. `jc_run_job.py run --rows 2048 --repeat 3 --accept-lost-beat-fault` on die A for each tensor: runs the
   descriptor the card already runs every token (slot 3 / slot 17), util-clear before each job, reads
   CYCLES, BEATS, STARVED and the 27 per-port beat counters, and compares 2048 y rows against
   ref/mv_fk33_tr.c. The compare is the value control (the job really computed); the per-port beat counts
   (all 27 equal) show every lane did its share; three repeats give the run-to-run scatter.

## Evidence (raw, hw/jc/card/results/jc27b_p0_hbm_lateral_2026-11-11/)
```
JCJOB tensor=blk.0.attn_gate.weight rows=6144 cycles=30932 beats=20480 c_per_word=1.5104 starved=10445 match=2048/2048 util=0.6621 verdict=PASS
JCJOB tensor=blk.0.attn_gate.weight rows=6144 cycles=30941 beats=20480 c_per_word=1.5108 starved=10460 match=2048/2048 util=0.6619 verdict=PASS
JCJOB tensor=blk.0.attn_gate.weight rows=6144 cycles=30951 beats=20480 c_per_word=1.5113 starved=10471 match=2048/2048 util=0.6617 verdict=PASS
JCJOB tensor=blk.1.ffn_gate.weight rows=17408 cycles=276711 beats=58080 c_per_word=4.7643 starved=218631 match=2048/2048 util=0.2099 verdict=PASS
JCJOB tensor=blk.1.ffn_gate.weight rows=17408 cycles=276754 beats=58080 c_per_word=4.7650 starved=218674 match=2048/2048 util=0.2099 verdict=PASS
JCJOB tensor=blk.1.ffn_gate.weight rows=17408 cycles=281661 beats=58080 c_per_word=4.8495 starved=223581 match=2048/2048 util=0.2062 verdict=PASS
```
1.51 c/word is the RTL ideal-memory figure (~1.5, FAST_POP=false cadence) from the 2026-11-10 study: with
the good layout, A runs at its own cadence limit and memory supply is not binding.

## Measured and REJECTED, do not retry
- "A's 0.327 is the RTL's FIFO cadence" (FAST_POP=false, 2/3 cap): rejected, attn_gate reaches 0.66 on the
  same bitstream, so the cadence cap is not what holds ffn_gate at 0.21.
- The study's STARVED prediction (STARVED ~ CYCLES - 1.5 x BEATS as the discriminator): rejected in review
  (STARVED tracks CYCLES - BEATS whatever the cause); CYCLES/BEATS is the gate used here.

## Traps hit
- After a JC power cycle, reloading the weights is not enough: the side image (token program + image record
  at 0x1FFA03E00) must be reloaded too, or jc_run_job refuses with "no record: magic is ff..ff".
- The BC-250 reboot drops enp4s0's static address and dnsmasq; the BMC is unreachable until both are
  restored (docs/boards/jungle-cat/2026-09-27_bringup.md section 4). One module did not enumerate on the
  first JC power-up ("I2C did not respond ... Switching to Slot B", 1 FPGA); a second restart fixed it.
- Each host-started job sets seam FAULTS bit 1 (LOST_BEAT) until reconfiguration; accepted for this run.

## Open, not yet answered
- The two tensors differ in two layout variables at once (own-PC fraction and lanes per boundary) and in
  shape (6144 vs 17408 rows). A control tensor with own_pc low but max 1 per boundary (or the reverse)
  would separate "own PC" from "boundary crowding". Not run.
- Whether the HBM global switch is clocked by AXI_ACLK (125 MHz) or its own clock (PG276): not checked.
- Die B not measured (its program sends A results to the sampler; the tool refuses die B).
- P1 (repack die A, one lane per PC) gain is still an ESTIMATE (~1.38x per die from the study).
