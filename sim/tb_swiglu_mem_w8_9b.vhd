-- sim/tb_swiglu_mem_w8_9b.vhd -- 2026-09-20.  TRACK GSRWIDE.
--
-- sim/tb_swiglu_mem_w8.vhd AT THE 9B SHAPE, N = 12288 = SHAPE.ffn, LANES 8,
-- WIDE FACE.  This is the exact swiglu_mem instance lever L2 elaborates on
-- the card, and it is the one the cycle claim is made about: NB = 1536, so
-- the unit is 2*NB + 13 = 3,085 cycles and the parent's load and store are
-- 1,536 beats each instead of 24,576 and 12,288.
--
-- N = 12288 is where the address width (14), the bank depth (1536) and the
-- position of the last write all differ from the N = 128 row, and a fault
-- in the wide face's bank-offset slice `gw_addr(LOG2N-1 downto LB)` is
-- invisible at a shape where LOG2N - LB is small.
--
-- NWILD => 2 for the reason sim/tb_swiglu_mem_9b.vhd gives: the
-- exponent-clamp cases are shape-independent and the N = 128 rows run all
-- twelve.
library ieee; use ieee.std_logic_1164.all;

entity tb_swiglu_mem_w8_9b is
end entity;

architecture tb of tb_swiglu_mem_w8_9b is
begin
  u : entity work.tb_swiglu_mem
    generic map(N => 12288, LANES => 8, WIDE_IO => true, NWILD => 2);
end architecture;
