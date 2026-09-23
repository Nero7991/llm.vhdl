-- sim/tb_llama_top_normhbm.vhd
-- THE NORM GAIN FROM HBM.  Added 2026-09-23, plan Task 2 of
-- docs/superpowers/plans/2026-09-23-27b-two-card.md.
--
-- `sim/tb_llama_top_normw.vhd` exactly, with NORM_HBM true: `rtl/llama_top.vhd`
-- elaborates NO gain table (the bench passes it an empty NORM_W_IMAGE) and
-- fetches each norm's row over `bst_*` from the bench's memory model, where
-- the bench has placed the same image's rows at bst_const_base + NORM_OFF.
-- The pinned landmarks are normw's, so this row asserts that the HBM path
-- reproduces the table path BIT FOR BIT; the bench's `bst_bad` counter (AXI3
-- length cap, beat alignment, 4 KB crossing, bounds) is folded into the
-- verdict.  At this shape a row is 4 beats (hidden 64), so the fetch's
-- short-burst arm is what runs here; the model shapes use 16-beat bursts.
library ieee; use ieee.std_logic_1164.all;

entity tb_llama_top_normhbm is
end entity;

architecture tb of tb_llama_top_normhbm is
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
      NORM_W_IMAGE => "llama_top_nw_b4_mean.hex",
      NORM_HBM     => true,
      EXP_X0       => -16350,
      EXP_XSUM     => 90889,
      EXP_XALL     => 90889,
      EXP_STEPH    => 18618);
end architecture;
