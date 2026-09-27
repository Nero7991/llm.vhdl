-- sim/tb_swiglu_mem_nb4.vhd -- 2026-09-27.  fmax-limiters final review.
--
-- sim/tb_swiglu_mem.vhd AT NB = N/LANES = 4, FEWER BEATS THAN THE SIGMOID
-- PIPE IS DEEP.  swiglu_mem's stage B is sigmoid_q_pipe (five registers),
-- and pass 1's `drained` must include the pipe's `busy`: with NB <= 5 the
-- whole batch can sit inside the pipe while vf, va, vc and vd are all 0.
-- Every other row has NB >= 16, where the busy term is never the last one
-- to clear, so dropping it survived them all.  MEASURED by the review:
-- the mutant without sg_busy(0) fails 74 of 511 checks here.
library ieee; use ieee.std_logic_1164.all;

entity tb_swiglu_mem_nb4 is
end entity;

architecture tb of tb_swiglu_mem_nb4 is
begin
  u : entity work.tb_swiglu_mem
    generic map(N => 16, LANES => 4);
end architecture;
