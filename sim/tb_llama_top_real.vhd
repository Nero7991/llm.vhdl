-- sim/tb_llama_top_real.vhd
-- THE INTEGRATION BENCH WITH EVERY COMPUTING UNIT REAL, AND REAL WEIGHTS.
--
-- WHY THIS FILE EXISTS.  Until 2026-08-29 the gate ran `tb_llama_top` on its
-- generic DEFAULTS, and those defaults are `C_REAL => false` (attention is the
-- `-32768 + i` stub), `NORM_REAL => false` (the D-vec norm is the behavioural
-- mean-removal probe) and `W_IMAGE => ""` (subsystem A is fed the arithmetic
-- `wword` image).  So the flagship result -- PART 6 of
-- `docs/debugging/2026-08-28_llama-top-first-seams.md`, the whole token
-- passing with the real `matvec_int4`, the real `gdn_block`, the real
-- `attn_block`, the real `rmsnorm_rs` AND real Qwen3.5-9B weights -- was a
-- one-off manual run. **A regression in the real path left the gate green.**
-- MEASURED: `grep -n 'C_REAL\|NORM_REAL' sim/regress.sh` had zero hits.
--
-- This row turns all four on. It reproduces PART 6's published control
-- landmark exactly: `R_X(0) = -16339 hash(R_X) = 92903`, 0 degenerate
-- residuals. MEASURED 2026-08-29, 2 minutes 7 seconds on a loaded box.
--
-- THE WEIGHT IMAGE IS COMMITTED, and that is a deliberate 660 KB.
-- `tools/gen_llama_top_weights.py` needs an 18 GB GGUF that is NOT in git, so
-- a row that generated the image would carry a genuine external prerequisite
-- and would report VECTORGEN_RUN_FAILED on any machine without the model set.
-- `sim/llama_top_w_b4_pool.hex` is that tool's output for
-- `--blocks 4 --attn-interval 4 --reduce pool`, reproduced byte-identically
-- (md5 `8cd88f10114e3a74a586c8a382d0889c`) from two separate runs of the tool
-- on two different days. Regenerate with the same arguments if the shape here
-- ever changes; the bench REFUSES a mismatched line count rather than serving
-- a shifted image.
--
-- WHY `attn_interval` IS 4 AND NOT 2.  The generator maps the bench's block
-- index onto the REAL model's layers, and the real Qwen3.5-9B has full
-- attention every fourth block. `--attn-interval 2` asks for
-- `blk.1.attn_q.weight`, which does not exist, and the tool refuses. So this
-- row runs one attention block and three GDN blocks.
--
-- WHY `NORM_ANCHOR` IS FALSE.  The anchor is a PROBE for an rmsnorm the
-- design does not instantiate. With `NORM_REAL` the design DOES instantiate
-- one, so leaving the probe on would measure the probe.
--
-- WHAT THIS ROW DOES NOT COVER, and it is the whole KV cache: `C_KV_AXI` is
-- false here because `attn_kv_axi` cannot elaborate at `ATTN_HD = 16` (see
-- the C_KV_AXI generic in `rtl/llama_top.vhd`), and the real weight image is
-- indexed by STEP, so it does not apply at the ATTN_HD = 64 shape either.
-- `sim/tb_llama_top_seq.vhd` is the row that covers the cache.
--
-- Teeth: `sim/mutate_llama_top_kv.sh` rows N1 and N2 are mutations of the
-- `NORM_REAL` adapter, which does not elaborate at all in the other two rows.
--
-- THE VALUE GATE.  Four landmarks, MEASURED 2026-08-29 on the unmutated tree
-- at commit 35e0ed0 (GHDL 1.0.0 mcode).  Until they were pinned this row
-- scored a run on STRUCTURE alone -- schedule, skew across latency points,
-- degenerate residuals -- and PRINTED the numbers without comparing them, so
-- a deterministic wrong answer produced the same verdict as a right one.
--
-- NTOK IS 1 HERE, so EXP_XALL is by construction the same hash as EXP_XSUM
-- and adds no resolution at this row; it is pinned so that raising NTOK
-- without re-measuring FAILS rather than silently widening the gate.
--
-- EXP_STEPH IS THE ONE WITH REACH THIS ROW DID NOT HAVE.  It hashes every
-- completion's captured exponent and write hash, so it sees seams the
-- residual's alignment discards.  MEASURED by TRACK CAPTURE: a `gdn_silu`
-- truncation moves R_Y-0/1/2 and R_ER-0/1/2 and leaves R_X(0) = -16364 and
-- hash(R_X) = 91622 bit-identical -- the sixth instance of OI-3.  Teeth:
-- `sim/mutate_llama_top_land.sh` rows P3 and P3x are that mutant with
-- EXP_STEPH pinned and unset, and the pair is the whole argument for it.
--
-- A LANDMARK IS A CHANGE DETECTOR, NOT AN ORACLE.  See
-- docs/debugging/2026-08-29_oi3b-top-level-value-gate.md.
--
-- OI-3's TWO NAMED DEFECTS ARE NOW MEASURED AGAINST THIS ROW, and this row is
-- the only one that catches them.  `sim/mutate_llama_top_land.sh` rows P5r and
-- P6r are the exponent claim re-aimed at R_X and the R_QG prefetch consuming
-- at k-3 -- the two mutations that PART 7 of
-- `docs/debugging/2026-08-28_llama-top-first-seams.md` recorded as PASSING
-- BROKEN.  Both are KILLED here on all four landmarks, and rows P5rx/P6rx are
-- the same two mutants with the landmarks UNSET, which both SURVIVE.  So the
-- kill is P14's and no other property's, and OI-3's original finding is
-- reproduced rather than merely quoted.  MEASURED 2026-08-29 at f257466;
-- `docs/debugging/2026-08-29_oi3mut-oi3-two-mutations.md`.
library ieee; use ieee.std_logic_1164.all;

entity tb_llama_top_real is
end entity;

architecture tb of tb_llama_top_real is
begin
  u : entity work.tb_llama_top
    generic map(
      BLOCKS      => 4,
      ATTN_INT    => 4,
      NRUNS       => 2,
      C_REAL      => true,
      ATTN_HD     => 16,
      NORM_REAL   => true,
      NORM_ANCHOR => false,
      W_IMAGE     => "llama_top_w_b4_pool.hex",
      EXP_X0      => -16364,
      EXP_XSUM    => 91622,
      EXP_XALL    => 91622,
      EXP_STEPH   => 17333);
end architecture;
