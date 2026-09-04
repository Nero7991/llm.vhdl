-- sim/tb_llama_top_bstate.vhd
-- SUBSYSTEM B'S STATE TIER, at the `tb_llama_top_real` configuration.
--
-- THIS FILE INVENTS NO NUMBERS, AND THAT IS THE WHOLE DESIGN.  Every generic
-- below is `sim/tb_llama_top_real.vhd`'s, copied, with ONE changed:
-- `B_STATE_AXI => true`.  The four landmarks are that file's, unmodified.
--
-- WHY THE FLAT ARM IS A VALID ORACLE FOR THE TIERED ONE.  `llama_top`'s
-- `stmem` and `semem` initialise to zero, and zero IS the correct initial
-- recurrent state.  `sim/tb_llama_top.vhd`'s `bst_slave` starts zeroed too.
-- So both arms begin from the same state and must compute the same numbers;
-- any difference is the tier, not the model.  Re-deriving these four from a
-- run of the tiered arm would make this a round trip against itself, which
-- this project has already recorded passing for a wrong-but-consistent
-- implementation (the `m7 mutant`).
--
-- WHAT THIS ROW DOES *NOT* ESTABLISH, stated because the obvious reading is
-- wrong: it is NTOK = 1, so nothing has been SAVED yet and nothing is
-- reloaded.  It proves the wiring elaborates and that a single invocation is
-- undisturbed by the substitution.  It is NOT evidence that
-- `gdn_state_store` round-trips.  `sim/tb_llama_top_bstate_seq.vhd` is the
-- row that tests that, and it is the one that matters.
library ieee; use ieee.std_logic_1164.all;

entity tb_llama_top_bstate is
end entity;

architecture tb of tb_llama_top_bstate is
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
      B_STATE_AXI => true,
      EXP_X0      => -16364,
      EXP_XSUM    => 91622,
      EXP_XALL    => 91622,
      EXP_STEPH   => 17333);
end architecture;
