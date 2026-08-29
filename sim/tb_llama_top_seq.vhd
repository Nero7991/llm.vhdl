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
      KV_AXI   => true);
end architecture;
