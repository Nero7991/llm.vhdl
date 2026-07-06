library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.env.all;
library beh;
entity tb_res_cmp is end;
architecture sim of tb_res_cmp is
  constant N:integer:=64;
  signal clk:std_logic:='0'; signal rst:std_logic:='1'; signal start:std_logic:='0';
  signal a_mant,b_mant:std_logic_vector(N*16-1 downto 0):=(others=>'0');
  signal a_exp,b_exp:integer:=0;
  signal done_b,done_n:std_logic;
  signal ob,onet:std_logic_vector(N*16-1 downto 0); signal oeb,oen:integer;
  component residual_net is
    port(clk,rst,start:in std_logic; a_mant:in std_logic_vector(1023 downto 0); a_exp:in std_logic_vector(31 downto 0);
         b_mant:in std_logic_vector(1023 downto 0); b_exp:in std_logic_vector(31 downto 0);
         done:out std_logic; o_mant:out std_logic_vector(1023 downto 0); o_exp:out std_logic_vector(31 downto 0));
  end component;
  signal oen_slv:std_logic_vector(31 downto 0);
begin
  clk <= not clk after 5 ns;
  oen <= to_integer(signed(oen_slv));
  u_beh: entity beh.residual generic map(N=>N)
    port map(clk=>clk,rst=>rst,start=>start,a_mant=>a_mant,a_exp=>a_exp,b_mant=>b_mant,b_exp=>b_exp,done=>done_b,o_mant=>ob,o_exp=>oeb);
  u_net: residual_net
    port map(clk=>clk,rst=>rst,start=>start,a_mant=>a_mant,a_exp=>std_logic_vector(to_signed(a_exp,32)),
      b_mant=>b_mant,b_exp=>std_logic_vector(to_signed(b_exp,32)),done=>done_n,o_mant=>onet,o_exp=>oen_slv);
  process
    variable fails:integer:=0;
  begin
    wait until rising_edge(clk); wait until rising_edge(clk); rst<='0'; wait until rising_edge(clk);
    for t in 0 to 7 loop
      for i in 0 to N-1 loop
        a_mant((i+1)*16-1 downto i*16)<=std_logic_vector(to_signed(((t*29+i*13) mod 4001)-2000,16));
        b_mant((i+1)*16-1 downto i*16)<=std_logic_vector(to_signed(((t*41+i*7+3) mod 4001)-2000,16));
      end loop;
      a_exp<=8+(t mod 4); b_exp<=10-(t mod 3);
      wait until rising_edge(clk); start<='1'; wait until rising_edge(clk); start<='0';
      wait until (done_b='1' and done_n='1') for 50 us; wait for 1 ns;
      if ob/=onet or oeb/=oen then
        fails:=fails+1;
        report "MISMATCH t="&integer'image(t)&" oeb="&integer'image(oeb)&" oen="&integer'image(oen)&" mant_eq="&boolean'image(ob=onet) severity warning;
      else report "t="&integer'image(t)&" MATCH oe="&integer'image(oeb) severity note; end if;
      wait until rising_edge(clk);
    end loop;
    if fails=0 then report "PASS:res_cmp all match" severity note; else report "FAIL:res_cmp "&integer'image(fails) severity note; end if;
    finish;
  end process;
end architecture;
