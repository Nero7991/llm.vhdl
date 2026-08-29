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
      W_IMAGE     => "llama_top_w_b4_pool.hex");
end architecture;
