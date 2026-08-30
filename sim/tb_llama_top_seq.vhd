-- sim/tb_llama_top_seq.vhd
-- THE INTEGRATION BENCH AT THE MULTI-TOKEN KV-CACHE CONFIGURATION.
--
-- WHY THIS FILE EXISTS AND WHY IT CONTAINS NO CHECKS.  `sim/regress.sh` keys
-- a test by NAME and cannot run one testbench twice at two generic sets --
-- the same reason `sim/tb_matvec_fk33_desc.vhd`'s `DUAL=true` configuration
-- is a manual run rather than a second gate row.  A configuration that has to
-- be GATED therefore needs its own top level.  Every property, every fault
-- counter and the PASS line all belong to `sim/tb_llama_top.vhd`; this file
-- only pins the generics.  Duplicating any of it here would create a second
-- copy of a checker that nothing compares against the first.
--
-- WHAT THIS CONFIGURATION ADDS OVER THE `tb_llama_top` GATE ROW, which runs
-- one token at the default shape with the attention stub:
--
--   * FOUR TOKENS OF ONE SEQUENCE, so `cur_pos` reaches 3 and `attn_block`
--     leaves its bypass path.  At `cur_pos = 0` the block never reads the KV
--     cache at all, which is why one token proves nothing about it.
--   * THE REAL `rtl/attn_kv_axi.vhd`, over three modelled AXI slaves, with
--     `attn_block`'s four seam handshakes connected instead of left at their
--     '1' defaults.
--   * TWO ATTENTION LAYERS in one token (`ATTN_INT = 2`), so the `layer` term
--     of C spec 2.2's address equation is exercised by two layers actually
--     interleaving.  `sim/tb_attn_kv_seam.vhd` runs one layer and lists this
--     as an open item.
--   * TWO LATENCY POINTS, and the sweep moves the KV read latency as well as
--     the descriptor memory, so a seam race shows up as a per-token skew
--     difference rather than as a deterministic wrong answer nothing can see.
--
-- THE SHAPE IS FORCED, not chosen: `attn_kv_axi` needs CM_W = 8, a 16-byte
-- record granule (KV_BLOCK >= 16) and N_KVH >= 2, and `attn_block` needs an
-- even power-of-two HEAD_DIM, HEAD_DIM/KV_BLOCK >= 2 and a GQA group >= 2.
-- ATTN_HD = 64 with KV_BLOCK = 16 is the smallest shape satisfying all six.
-- Every landmark measured at ATTN_HD 16 or 32 is at a DIFFERENT shape and is
-- not comparable with anything this run prints.
--
-- Teeth: `sim/mutate_llama_top_kv.sh`.
--
-- THE VALUE GATE.  Four landmarks, MEASURED 2026-08-29 on the unmutated tree
-- at commit 35e0ed0 (GHDL 1.0.0 mcode), pinned here because until this file
-- pinned them THIS ROW COULD NOT FAIL ON A WRONG NUMBER.  MEASURED, and
-- reproduced by TRACK OI3B at commit 4736950: this row PASSED with
-- `rtl/attn_block.vhd`'s v_ref fold reverted to defect C1 at all four of its
-- index sites, and PASSED again with the fold collapsed to a single register
-- shared across every layer AND every KV head.  Both mutants moved
-- R_X(0) from -14252 to -14240 and hash(R_X) from 7668 to 97483, so the
-- numbers were there to be compared and nothing compared them.
--
-- Teeth: `sim/mutate_llama_top_land.sh` rows P1 and P2 are exactly those two
-- mutants, and both are KILLED here now.  See
-- docs/debugging/2026-08-29_oi3b-top-level-value-gate.md.
--
-- A LANDMARK IS A CHANGE DETECTOR, NOT AN ORACLE.  It says the numbers are
-- what they were when a human last looked, never that they are attention.
-- The independent value oracle for this seam is `ref/attn_block_seq_vec.c`
-- through `sim/tb_attn_kv_seam.vhd`, at the BLOCK level.  If a legitimate
-- change moves these four, say in the commit message WHY and record both the
-- old and the new values; a landmark updated silently is worth nothing.
library ieee; use ieee.std_logic_1164.all;

entity tb_llama_top_seq is
end entity;

architecture tb of tb_llama_top_seq is
begin
  -- NTOK 3 rather than 4, and NRUNS 2 rather than 3, is a GATE COST choice
  -- and it is stated because it is the one thing here that is not forced:
  -- 4 tokens at 3 latency points is 13 minutes and 3 at 2 is about 5.  The
  -- larger point is run by hand; see the header of sim/tb_llama_top.vhd.
  u : entity work.tb_llama_top
    generic map(
      BLOCKS   => 4,
      ATTN_INT => 2,
      NRUNS    => 2,
      NTOK     => 3,
      C_REAL   => true,
      ATTN_HD  => 64,
      KV_BLOCK => 16,
      N_ROT    => 16,
      MAXPOS   => 8,
      KV_AXI   => true,
      -- RE-PINNED 2026-08-29 by TRACK BTOP1, and all four moved.  The OLD
      -- values were EXP_X0 -14252, EXP_XSUM 7668, EXP_XALL 96762,
      -- EXP_STEPH 57526, measured at 35e0ed0.
      --
      -- WHY: defect B-TOP-1.  `rtl/llama_top.vhd` drove `b_tk0 <= '1'` at
      -- every token and pulsed `b_seq_rst` on every `go`, so subsystem B --
      -- Gated DeltaNet, a RECURRENT architecture -- discarded its recurrent
      -- state and its conv tap history at every token and computed tokens 1
      -- and 2 as if each were token 0.  Both drivers now follow `tok_pos`.
      -- MEASURED: 65 to 88 of 128 mantissas per `R_Y` seam were wrong at
      -- tokens 1 and 2.  Token 0 is unaffected in every configuration, which
      -- is why `tb_llama_top_real` and `tb_llama_top_normw` -- both NTOK = 1
      -- -- print exactly their old values and were NOT re-pinned.
      --
      -- THIS IS NOT A RE-PIN THAT ASKS TO BE TRUSTED.  `sim:seamgate_seq`
      -- ran on the same tree and reports all 61 seams of all three tokens
      -- bit-identical to an independent model driven by the machine's own
      -- captured inputs, and it reports `R_X(0) = -732 hash(R_X) = 86454` --
      -- the same two numbers EXP_X0 and EXP_XSUM pin below, from a separate
      -- run. The new numbers are checked, not merely different.
      -- docs/debugging/2026-08-29_btop1-b-recurrence.md.
      EXP_X0    => -732,
      EXP_XSUM  => 86454,
      EXP_XALL  => 79978,
      EXP_STEPH => 50729);
end architecture;
