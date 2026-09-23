-- sim/tb_llama_top_bconst_normhbm.vhd
-- THE NORM GAIN FETCH SHARING `bst_*` WITH A LIVE STATE STORE.  Added
-- 2026-09-23, plan Task 2 of docs/superpowers/plans/2026-09-23-27b-two-card.md.
--
-- `sim/tb_llama_top_bconst.vhd` exactly (B's state tiered to the bench's HBM
-- model, B's constants from it, NTOK 3 so the state round-trips), with
-- NORM_HBM true: every norm's gain row is ALSO read over `bst_*`, through the
-- read mux in `rtl/llama_top.vhd` (`gnm`).  The rows are
-- `llama_top_nw_b4_ramp.hex`, the DUT's own synthetic ramp (`W_CONST`)
-- written out nine times, because bconst runs on that ramp; so bconst's four
-- pinned landmarks must hold BIT FOR BIT.  A beat delivered to the wrong
-- master, a store burst cut by the mux, or a protocol fault (`bst_bad`)
-- fails this row.
library ieee; use ieee.std_logic_1164.all;

entity tb_llama_top_bconst_normhbm is
end entity;

architecture tb of tb_llama_top_bconst_normhbm is
begin
  u : entity work.tb_llama_top
    generic map(
      BLOCKS        => 4,
      ATTN_INT      => 4,
      NRUNS         => 1,
      NTOK          => 3,
      C_REAL        => true,
      ATTN_HD       => 16,
      NORM_REAL     => true,
      NORM_ANCHOR   => false,
      W_IMAGE       => "llama_top_w_b4_pool.hex",
      MAXPOS        => 8,
      B_STATE_AXI   => true,
      B_SRC_REAL    => true,
      B_CONST_HBM   => true,
      B_CONST_IMAGE => "llama_top_const_b4.hex",
      NORM_W_IMAGE  => "llama_top_nw_b4_ramp.hex",
      NORM_HBM      => true,
      EXP_X0        => 10278,
      EXP_XSUM      => 68620,
      EXP_XALL      => 18522,
      EXP_STEPH     => 61131);
end architecture;
