-- sim/tb_swiglu_mem_9b.vhd -- 2026-09-19.
--
-- sim/tb_swiglu_mem.vhd AT THE 9B SHAPE, N = 12288 = SHAPE.ffn, which is
-- the N rtl/llama_top.vhd's `gsr` elaborates swiglu_mem at on the card.
-- The unit's address width, its bank depth, its pass length and the
-- position of the last write (the `done` condition) all depend on N, and a
-- fault in any of them at 12288 is invisible at 128.
--
-- NWILD => 2 rather than the default 12: the exponent-clamp cases are
-- shape-independent and the N = 128 row runs all twelve; two are kept here
-- so the sweep path itself is exercised at this N.  MEASURED 2026-09-19 on
-- the workstation (GHDL 1.0.0 mcode): 15 trials, 184,336 checks, 98 s.
library ieee; use ieee.std_logic_1164.all;

entity tb_swiglu_mem_9b is
end entity;

architecture tb of tb_swiglu_mem_9b is
begin
  u : entity work.tb_swiglu_mem
    generic map(N => 12288, NWILD => 2);
end architecture;
