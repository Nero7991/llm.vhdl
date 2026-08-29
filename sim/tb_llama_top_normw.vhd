-- sim/tb_llama_top_normw.vhd
-- THE INTEGRATION BENCH WITH THE REAL RMSNorm GAIN, NOT THE SYNTHETIC RAMP.
--
-- WHY THIS FILE EXISTS.  `sim/tb_llama_top_real.vhd` runs every computing unit
-- real AND real Qwen3.5-9B weights for subsystem A, and it still normalises
-- with `rtl/llama_top.vhd`'s `W_CONST`, the ramp
-- `2**NORM_W_EXP + ((i*37) mod 512) - 256`.  Two tracks found that
-- independently on 2026-08-29 -- REF9B's finding D2 and SPECREC's observation
-- that `attn_norm` appears zero times in `rtl/llama_top.vhd` -- and its
-- consequence is specific: `R_XN-L`, `R_XN.ffn-L` and `R_XN.final` are 9 of
-- the 63 seams a token captures and NONE of them could be compared against
-- anything derived from the model, because the model's gain was not what
-- produced them.
--
-- This row is `tb_llama_top_real` plus `NORM_W_IMAGE`, and nothing else.
-- Every other generic is copied from that wrapper rather than re-decided, so
-- the pair is a controlled comparison: the ONLY difference between the two
-- rows' numbers is the norm gain.
--
-- THE GAIN IMAGE IS COMMITTED, for the same reason the weight image is:
-- `tools/gen_llama_top_weights.py` needs an 18 GB GGUF that is not in git.
-- `sim/llama_top_nw_b4_mean.hex` is
--
--   tools/gen_llama_top_weights.py --blocks 4 --attn-interval 4 \
--       --reduce pool --out sim/llama_top_w_b4_pool.hex \
--       --norm-out sim/llama_top_nw_b4_mean.hex
--
-- (md5 27bd00db0c2a466c040d4d734ab442bc), 9 norm ops x 64 elements, in
-- schedule order: `blk.L.attn_norm.weight`, `blk.L.post_attention_norm.weight`
-- and `output_norm.weight`, which is `tools/ref9b/seam_map.py`'s own mapping.
--
-- THE REDUCTION IS THE ONE MODELLING CHOICE.  A 4096-element gain becomes a
-- 64-element one by MEAN over groups of 64, which is the partner of the A
-- image's `--reduce pool` (sum over the same groups); the arithmetic that
-- fixes it is in `reduce_gain()` in the generator.  A KNOWN CONSEQUENCE,
-- stated rather than discovered later: averaging 64 real gains collapses the
-- element-to-element spread to about 2% of the mean (MEASURED, the
-- --norm-stats CSV), so this image is close to a per-layer SCALAR gain.  A
-- bit-exact oracle still resolves a permuted or reversed gain vector at that
-- spread; a tolerance-based one would not.
--
-- WHAT MOVES.  Everything downstream of the first norm, so this row has its
-- OWN landmark and does not share `tb_llama_top_real`'s.  That row's
-- `R_X(0) = -16339 hash(R_X) = 92903` is untouched and was re-MEASURED after
-- this change.
--
-- WHAT THIS ROW DOES NOT ESTABLISH.  It is stimulus, not a design change.
-- There is still no weight region, descriptor field or packing by which a
-- norm gain could reach `rmsnorm_rs` on the card; see the `NORM_W_IMAGE`
-- generic in `rtl/llama_top.vhd`.
library ieee; use ieee.std_logic_1164.all;

entity tb_llama_top_normw is
end entity;

architecture tb of tb_llama_top_normw is
begin
  u : entity work.tb_llama_top
    generic map(
      BLOCKS       => 4,
      ATTN_INT     => 4,
      NRUNS        => 2,
      C_REAL       => true,
      ATTN_HD      => 16,
      NORM_REAL    => true,
      NORM_ANCHOR  => false,
      W_IMAGE      => "llama_top_w_b4_pool.hex",
      NORM_W_IMAGE => "llama_top_nw_b4_mean.hex");
end architecture;
