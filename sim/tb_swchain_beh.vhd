-- GHDL-only sanity bench for the behavioral sw_chain (controller + wiring).
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.env.all; use std.textio.all;
use work.golden_pkg.all;
entity tb_swchain_beh is end;
architecture sim of tb_swchain_beh is
  constant N : integer := 172;
  signal clk : std_logic := '0'; signal rst : std_logic := '1'; signal start : std_logic := '0';
  signal hb_mant, hb2_mant : std_logic_vector(N*16-1 downto 0) := (others=>'0');
  signal hb_exp, hb2_exp : std_logic_vector(31 downto 0) := (others=>'0');
  signal done : std_logic; signal o_mant : std_logic_vector(N*16-1 downto 0); signal o_exp : std_logic_vector(31 downto 0);
begin
  clk <= not clk after 5 ns;
  uut: entity work.sw_chain generic map(N=>N,Q=>12)
    port map(clk=>clk,rst=>rst,start=>start,hb_mant=>hb_mant,hb_exp=>hb_exp,
             hb2_mant=>hb2_mant,hb2_exp=>hb2_exp,done=>done,o_mant=>o_mant,o_exp=>o_exp);
  process
    file f : text; variable nh,nh2,no,eh,eh2,eo : integer;
    variable dh,dh2,do : integer_vector(0 to N-1); variable s : integer;
  begin
    wait until rising_edge(clk); wait until rising_edge(clk); rst<='0'; wait until rising_edge(clk);
    file_open(f,"../mem/golden/fx_swiglu_l0.txt",read_mode);
    read_bfp_block(f,nh,eh,dh); read_bfp_block(f,nh2,eh2,dh2); read_bfp_block(f,no,eo,do); file_close(f);
    for j in 0 to N-1 loop
      hb_mant((j+1)*16-1 downto j*16)<=std_logic_vector(to_signed(dh(j),16));
      hb2_mant((j+1)*16-1 downto j*16)<=std_logic_vector(to_signed(dh2(j),16));
    end loop;
    hb_exp<=std_logic_vector(to_signed(eh,32)); hb2_exp<=std_logic_vector(to_signed(eh2,32));
    wait until rising_edge(clk); start<='1'; wait until rising_edge(clk); start<='0';
    wait until done='1' for 200 us; wait for 1 ns;
    s:=0; for j in 0 to N-1 loop s:=s+to_integer(signed(o_mant((j+1)*16-1 downto j*16))); end loop;
    report "beh o_exp="&integer'image(to_integer(signed(o_exp)))
         &" m0="&integer'image(to_integer(signed(o_mant(15 downto 0))))
         &" m1="&integer'image(to_integer(signed(o_mant(31 downto 16))))
         &" m171="&integer'image(to_integer(signed(o_mant(N*16-1 downto (N-1)*16))))
         &" chksum="&integer'image(s) severity note;
    finish;
  end process;
end architecture;
