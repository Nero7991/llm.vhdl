-- RTL-side stand-in for sim/rope_ps_wrap.vhd, which wraps the post-synthesis
-- NETLIST (all-vector ports).  tb_rope_ps drives `rope_ps`, so the RTL needs
-- an equivalent; against the RTL it is a straight passthrough because rope's
-- descriptor ports are already integers.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
entity rope_ps is
  generic(DIM:integer:=64; HEAD:integer:=8; KVDIM:integer:=32);
  port(clk,rst,start:in std_logic; pos:in integer;
       q_mant:in std_logic_vector(DIM*16-1 downto 0); q_exp:in integer;
       k_mant:in std_logic_vector(KVDIM*16-1 downto 0); k_exp:in integer;
       done:out std_logic; qo_mant:out std_logic_vector(DIM*16-1 downto 0); qo_exp:out integer;
       ko_mant:out std_logic_vector(KVDIM*16-1 downto 0); ko_exp:out integer);
end;
architecture w of rope_ps is
begin
  -- NEOX defaults false: this is the v1.0 path, and that is the point of the test.
  u : entity work.rope
    generic map(DIM=>DIM, HEAD=>HEAD, KVDIM=>KVDIM)
    port map(clk=>clk, rst=>rst, start=>start, pos=>pos,
             q_mant=>q_mant, q_exp=>q_exp, k_mant=>k_mant, k_exp=>k_exp,
             done=>done, qo_mant=>qo_mant, qo_exp=>qo_exp,
             ko_mant=>ko_mant, ko_exp=>ko_exp);
end;
