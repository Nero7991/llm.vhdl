-- sim/tb_llama_top_bconst.vhd
-- SUBSYSTEM B ON THE MODEL'S OWN INPUTS AND CONSTANTS, ACROSS THREE TOKENS.
--
-- Every generic below is `sim/tb_llama_top_bstate.vhd`'s (which is
-- `sim/tb_llama_top_real.vhd`'s plus B_STATE_AXI), with FOUR changed:
--
--   NTOK => 3, MAXPOS => 8   three tokens, so the state tier round-trips and
--                            the recurrence is exercised (the reason
--                            `sim/tb_llama_top_bstate_seq.vhd` exists)
--   B_SRC_REAL => true       conv taps, alpha and beta from the regions, not
--                            the m12 stand-ins
--   B_CONST_HBM => true      the conv weights, ssm_dt_bias, ssm_a and the
--   B_CONST_IMAGE => ...     ssm_norm weight of blk.0..2 of the shipped 9B
--                            gguf, sliced to this shape by
--                            tools/pack_gdn_consts.py --shape sim, loaded
--                            from sim/llama_top_const_b4.hex by the state
--                            store's fourth phase (docs/2026-09-18_b-
--                            constants-path.md, tracks A, B and D)
--
-- THE FLAT ARM IS NOT AN ORACLE FOR THIS ROW.  `sim/tb_llama_top_bstate.vhd`
-- could carry its flat sibling's landmarks unchanged because the flat
-- `stmem` and the tiered slave both start from zero and zero is the correct
-- initial state.  The flat arm has NO PATH for these constants at all -- with
-- B_CONST_HBM false every configuration of rtl/llama_top.vhd computes on
-- `m12` stand-ins -- so there is nothing to copy the four numbers from.
-- sim/tb_llama_top.vhd's own B_CONST_HBM comment says the same.
--
-- SO THE FOUR LANDMARKS BELOW ARE PINNED TO WHAT THIS CONFIGURATION PRODUCES,
-- AND THEY ARE CHANGE DETECTORS, NOT A VERDICT ON VALUES.  MEASURED
-- 2026-09-18 at 14289cf (GHDL mcode, `P14 landmarks measured` from a run
-- with none of them pinned):
--
--   EXP_X0 => 10278, EXP_XSUM => 68620, EXP_XALL => 18522, EXP_STEPH => 61131
--
-- They say "this number moved from what was written down", and that is all.
-- THE VERDICT ON VALUES IS `sim:seamgate_bconst` (tools/ref9b/seamgate.sh
-- bconst): the same configuration captured, every non-B seam checked by
-- tools/ref9b/bisect_scaled.py against its independent model, and the nine
-- R_Y seams (3 GDN layers x 3 tokens) checked by
-- `tools/ref9b/gdn_oracle.py --b-src-real --b-const sim/llama_top_const_b4.bin`
-- -- MEASURED 9 of 9 bit for bit, and 0 of 9 with `--b-const` removed, so the
-- agreement is the constants and not a loose comparison.  Read this row's
-- PASS as "the numbers have not moved since they were last judged there",
-- and when this row disagrees, re-run that one before re-pinning here.
--
-- WHAT THIS ROW ADDS OVER THAT ONE, and why it exists at all: the seam row
-- checks the seams it has models for and passes an unmodelled or unchanged
-- value forward AS GIVEN; a landmark over R_X and over every completion's
-- exponent (EXP_STEPH) sees the whole token, including the parts nothing
-- models, and it costs nothing beyond the run.  The two are the two
-- instruments this family always carries.
--
-- WHY the image is opened by bare name: sim/regress.sh symlinks every
-- sim/*.hex into a row's run directory, the same rule that serves
-- sim/llama_top_w_b4_pool.hex to tb_llama_top_real and
-- sim/llama_top_nw_b4_mean.hex to tb_llama_top_normw.  The committed image
-- is held to today's packer by `sim:constimage`.
library ieee; use ieee.std_logic_1164.all;

entity tb_llama_top_bconst is
end entity;

architecture tb of tb_llama_top_bconst is
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
      EXP_X0        => 10278,
      EXP_XSUM      => 68620,
      EXP_XALL      => 18522,
      EXP_STEPH     => 61131);
end architecture;
