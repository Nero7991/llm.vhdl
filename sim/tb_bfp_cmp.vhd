library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.env.all;
library beh;
entity tb_bfp_cmp is end;
architecture sim of tb_bfp_cmp is
  constant N:integer:=172;
  signal clk:std_logic:='0'; signal rst:std_logic:='1'; signal start:std_logic:='0';
  signal inq:std_logic_vector(N*32-1 downto 0):=(others=>'0');
  signal done_b,done_n:std_logic; signal ob,onet:std_logic_vector(N*16-1 downto 0); signal oeb,oen:integer;
  component bfp_pack_net is
    port(clk,rst,start:in std_logic; in_q:in std_logic_vector(N*32-1 downto 0); done:out std_logic;
         o_mant:out std_logic_vector(N*16-1 downto 0); o_exp:out std_logic_vector(31 downto 0));
  end component;
  signal oen_slv:std_logic_vector(31 downto 0);
begin
  clk<=not clk after 5 ns; oen<=to_integer(signed(oen_slv));
  u_beh: entity beh.bfp_pack generic map(N=>N,Q=>12) port map(clk=>clk,rst=>rst,start=>start,in_q=>inq,done=>done_b,o_mant=>ob,o_exp=>oeb);
  u_net: bfp_pack_net port map(clk=>clk,rst=>rst,start=>start,in_q=>inq,done=>done_n,o_mant=>onet,o_exp=>oen_slv);
  process variable fails:integer:=0; begin
    wait until rising_edge(clk); wait until rising_edge(clk); rst<='0'; wait until rising_edge(clk);
    for t in 0 to 5 loop
      for i in 0 to N-1 loop inq((i+1)*32-1 downto i*32)<=std_logic_vector(to_signed(((t*131+i*997) mod 2000001)-1000000,32)); end loop;
      wait until rising_edge(clk); start<='1'; wait until rising_edge(clk); start<='0';
      wait until (done_b='1' and done_n='1') for 50 us; wait for 1 ns;
      if ob/=onet or oeb/=oen then fails:=fails+1; report "MISMATCH t="&integer'image(t)&" oeb="&integer'image(oeb)&" oen="&integer'image(oen)&" meq="&boolean'image(ob=onet) severity warning;
      else report "t="&integer'image(t)&" MATCH oe="&integer'image(oeb) severity note; end if;
      wait until rising_edge(clk);
    end loop;
    if fails=0 then report "PASS:bfp_cmp all match" severity note; else report "FAIL:bfp_cmp "&integer'image(fails) severity note; end if;
    finish;
  end process;
end architecture;
