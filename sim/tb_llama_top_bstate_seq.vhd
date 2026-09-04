-- sim/tb_llama_top_bstate_seq.vhd
-- SUBSYSTEM B'S STATE TIER ACROSS THREE TOKENS.  THIS IS THE ROW THAT MATTERS.
--
-- Every generic below is `sim/tb_llama_top_seq.vhd`'s, copied, with ONE
-- changed: `B_STATE_AXI => true`.  The four landmarks are that file's,
-- unmodified and deliberately NOT re-derived here.
--
-- WHY THREE TOKENS AND NOT ONE.  At token 0 nothing has been saved, so the
-- NTOK = 1 row (`sim/tb_llama_top_bstate.vhd`) cannot see a broken round
-- trip.  Tokens 1 and 2 read state that token 0 WROTE OUT and the store
-- READ BACK, so these four numbers can only reproduce if `gdn_state_store`
-- saved and reloaded every layer correctly and `gdn_job_seq` sequenced the
-- load and the save around `gdn_block`'s invocation.  A single wrong word
-- anywhere in that round trip moves them.
--
-- THAT IS NOT A HYPOTHETICAL FAILURE MODE, IT IS A MEASURED ONE.  Defect
-- B-TOP-1, recorded in `sim/tb_llama_top_seq.vhd`: `llama_top` drove
-- `b_tk0 <= '1'` at every token, so B -- Gated DeltaNet, a RECURRENT
-- architecture -- discarded its recurrent state at every token and computed tokens 1
-- and 2 as if each were token 0.  65 to 88 of 128 mantissas per `R_Y` seam
-- were wrong at tokens 1 and 2, and TOKEN 0 WAS UNAFFECTED IN EVERY
-- CONFIGURATION.  A state tier that silently failed to round-trip would look
-- exactly like that, and a single-token row would show nothing.
--
-- So: this row passing and the NTOK = 1 row passing are DIFFERENT claims, and
-- only this one is about the store.
--
-- IF THIS ROW DISAGREES, THE TIER IS WRONG.  Do not re-pin it; re-pinning is
-- re-pinning away the only evidence.
--
-- TEETH, MEASURED 2026-09-03.  A row never shown to fail has not been shown to
-- work, and this row's whole claim is that it can see something the NTOK = 1
-- row cannot.  The control is the obvious one: make `bst_slave` in
-- sim/tb_llama_top.vhd a SINK -- accept every write, store nothing -- so every
-- reload returns zeros and every token restarts from the initial state.
--
--                          storing slave        SINK slave
--   tb_llama_top_bstate        PASS               PASS
--   tb_llama_top_bstate_seq    PASS               FAIL
--
-- The FAIL is `P14 -- R_X(0) is -1088 and the recorded landmark for ...`,
-- against the -732 pinned below.
--
-- BOTH HALVES MATTER.  The FAIL says this row discriminates, so its PASS on
-- the real slave is evidence that the store round-trips rather than evidence
-- that nothing was exercised.  The PASS in the sink column of the NTOK = 1 row
-- says that row is STRUCTURALLY BLIND to a broken round trip -- a slave that
-- discards every single write is invisible to it -- which is why it is not
-- cited as evidence about the store anywhere, and why deleting this row and
-- keeping that one would leave the tier untested while looking tested.
library ieee; use ieee.std_logic_1164.all;

entity tb_llama_top_bstate_seq is
end entity;

architecture tb of tb_llama_top_bstate_seq is
begin
  u : entity work.tb_llama_top
    generic map(
      BLOCKS      => 4,
      ATTN_INT    => 2,
      NRUNS       => 2,
      NTOK        => 3,
      C_REAL      => true,
      ATTN_HD     => 64,
      KV_BLOCK    => 16,
      N_ROT       => 16,
      MAXPOS      => 8,
      KV_AXI      => true,
      B_STATE_AXI => true,
      EXP_X0      => -732,
      EXP_XSUM    => 86454,
      EXP_XALL    => 79978,
      EXP_STEPH   => 50729);
end architecture;
