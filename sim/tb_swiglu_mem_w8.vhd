-- sim/tb_swiglu_mem_w8.vhd -- 2026-09-20.  TRACK GSRWIDE.
--
-- sim/tb_swiglu_mem.vhd AT LANES = 8 THROUGH THE WIDE FACE, which is the
-- configuration lever L2 puts on the card: rtl/llama_top.vhd's `gsr` with
-- SWG_LANES = 8 and SWG_WIDE, loading both operands out of the region
-- file's LANES-wide group read port in one pass and writing back through
-- its LANES-wide group write port.
--
-- WHY THIS ROW EXISTS RATHER THAN A CALCULATION.  TRACK SWGFAST MEASURED
-- swiglu_mem at LANES 1, 2 and 4 (24,588 / 12,301 / 6,157 cycles at
-- N = 12288) and stated a `2*NB + 13` law; `docs/2026-09-20_d-side-vector-
-- traffic.md` section 9 then lists LANES = 8 as "an extrapolation of
-- SWGFAST's law past its measured points", under OPEN.  An extrapolation of
-- a law fitted to three points is exactly what this project has twice
-- recorded going wrong, so the point is MEASURED here instead.
--
-- Everything else is the default row: the same seventeen value trials, the
-- same twelve wild-exponent trials, the same `swiglu -> vec_mem -> bfp_pack`
-- reference, no tolerance.  What differs is the DUT's ports and its lane
-- count, so a lane shuffle or a bank-offset fault in the wide face is a
-- value mismatch against an independent model rather than a self-agreement.
library ieee; use ieee.std_logic_1164.all;

entity tb_swiglu_mem_w8 is
end entity;

architecture tb of tb_swiglu_mem_w8 is
begin
  u : entity work.tb_swiglu_mem
    generic map(N => 128, LANES => 8, WIDE_IO => true);
end architecture;
