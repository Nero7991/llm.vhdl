-- sim/tb_fk33_cardtop_normhbm.vhd
-- THE NORM GAIN FROM HBM, ON THE CARD TOP.  Added 2026-09-23, plan Task 2 of
-- docs/superpowers/plans/2026-09-23-27b-two-card.md.
--
-- `sim/tb_llama_top_normhbm.vhd` against `rtl/fk33_llama_top.vhd` instead of
-- `rtl/llama_top.vhd`: the identity bench tools/gen_cardtop.py derives from
-- sim/tb_llama_top.vhd, at normw's generics, with NORM_HBM true.  The card top
-- is a mechanical fork of llama_top, and hw/fk33/gen_fk33_card.py builds the
-- card with NORM_HBM true, so this row is the one that runs the fetch and the
-- `bst_*` read mux in the file the bitstream is made from.  Pinned landmarks
-- are normw's, from the ROM path on llama_top: an independent pin.
library ieee; use ieee.std_logic_1164.all;

entity tb_fk33_cardtop_normhbm is
end entity;

architecture tb of tb_fk33_cardtop_normhbm is
begin
  u : entity work.tb_fk33_cardtop_ident
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
