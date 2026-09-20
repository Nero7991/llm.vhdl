-- sim/tb_llama_top_kvport.vhd
-- THE KV BASES REACH attn_kv_axi THROUGH llama_top's PORTS, NOT ITS GENERICS.
--
-- TRACK KVREG, 2026-09-20.  MEASURED on silicon that day: subsystem C's KV
-- base was a build-time generic taken from the FLAT manifest, the loaded
-- image was the lane-striped one, and every C job wrote its records into 40
-- weight objects (docs/debugging/2026-09-20_the-kv-cache-base-is-compiled-
-- into-the-bitstream.md).  The fix makes the pair a pair of input ports on
-- `rtl/llama_top.vhd` (`kv_k_base`/`kv_v_base`, defaulting to the compiled
-- generics) which the card's seam drives from the manifest.
--
-- sim/tb_fk33_seam.vhd's P6g shows the seam's registers reach its output
-- pins.  It cannot show the ENGINE reads them: its llama_top runs the
-- behavioural cache, which has no base at all.  This row is that half.  It
-- is `tb_llama_top_seq` -- the multi-token configuration over the real
-- rtl/attn_kv_axi.vhd, three modelled AXI slaves, two attention layers --
-- with ONE generic changed: KV_PORT_BASES => true, which hands the DUT's
-- C_K_BASE_CH/C_V_BASE_CH DECOY values (two regions the bench's checkers do
-- not accept) and drives the real bases through the ports.  Every KV check
-- in sim/tb_llama_top.vhd is written against the bench's own bases, so a DUT
-- that still took its base from the generic writes every record "inside
-- neither region" (P7), fails P11, and moves the four landmarks.
--
-- THE LANDMARKS ARE tb_llama_top_seq's, UNCHANGED, and that is the point:
-- the ports carry the same addresses the generics used to, so the numbers
-- must not move.  A run of this row that prints different landmarks from
-- tb_llama_top_seq is a DUT whose port path and generic path disagree.
--
-- Teeth (TRACK KVREG, MEASURED 2026-09-20): mutant B -- llama_top's u_kv
-- port map put back to the compiled constants, the ports ignored -- fails
-- this row on P7 ("inside neither region") at the first record and
-- passes tb_llama_top_seq unchanged, which is the attribution control.
library ieee; use ieee.std_logic_1164.all;

entity tb_llama_top_kvport is
end entity;

architecture tb of tb_llama_top_kvport is
begin
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
      KV_PORT_BASES => true,
      EXP_X0    => -732,
      EXP_XSUM  => 86454,
      EXP_XALL  => 79978,
      EXP_STEPH => 50729);
end architecture;
