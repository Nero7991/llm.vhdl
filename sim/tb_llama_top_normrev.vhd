-- sim/tb_llama_top_normrev.vhd
-- THE NORM GAIN IS SELECTED BY THE DESCRIPTOR, NOT BY COUNTING NORM OPS.
-- Added 2026-09-23, plan Task 2 of
-- docs/superpowers/plans/2026-09-23-27b-two-card.md.
--
-- WHY THIS FILE EXISTS.  `rtl/llama_top.vhd` used to serve the RMSNorm gain
-- of the k-th OP_VEC_NORM of a token from row k of the gain image, a per-token
-- counter.  That is right for every program that starts at step 0 and wrong
-- for every other, and every bench ran only programs that start at step 0.
-- The two-card split does not (card 1 starts at block 16), and on silicon its
-- first norm got block 0's gain: docs/debugging/2026-09-23_the-norm-gain-is-
-- indexed-by-a-per-token-counter.md.  Now each OP_VEC_NORM names its row in
-- `const_base` (2*blk, 2*blk+1, 2*blocks for the final norm).
--
-- WHAT IT CHECKS.  `sim/tb_llama_top_normw.vhd` exactly, with two changes
-- that cancel for a correct design and not for the counter:
--   * NORM_W_IMAGE is `llama_top_nw_b4_mean_rev.hex`, the same nine rows in
--     REVERSE order (row r of it is row 8-r of the forward image), and
--   * NORM_ROW_REV names the rows in reverse (`const_base` = 8 - r).
-- A design that selects by `const_base` applies the same gain to every op and
-- must reproduce normw's four pinned landmarks BIT FOR BIT.  The pinned values
-- below are normw's, not a fresh measurement of this row, so this row's
-- expected result is an independent pin and not a self-measurement.  The
-- nine rows are pairwise distinct (checked when this file was written), so a
-- design that counts applies a different gain to every op except the middle
-- one and moves the landmarks.
--
-- TEETH.  MEASURED 2026-09-23 against the pre-fix counter: see the plan's
-- Task 2 section and the WORKLOG.
library ieee; use ieee.std_logic_1164.all;

entity tb_llama_top_normrev is
end entity;

architecture tb of tb_llama_top_normrev is
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
      NORM_W_IMAGE => "llama_top_nw_b4_mean_rev.hex",
      NORM_ROW_REV => true,
      EXP_X0       => -16350,
      EXP_XSUM     => 90889,
      EXP_XALL     => 90889,
      EXP_STEPH    => 18618);
end architecture;
