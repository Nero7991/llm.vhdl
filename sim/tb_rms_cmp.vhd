library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.env.all;
library beh;
entity tb_rms_cmp is end;
architecture sim of tb_rms_cmp is
  constant N:integer:=64;
  signal clk:std_logic:='0'; signal rst:std_logic:='1'; signal start:std_logic:='0';
  signal xm,wm:std_logic_vector(N*16-1 downto 0):=(others=>'0');
  signal xe,we:integer:=0;
  signal db,dn:std_logic; signal ob,onet:std_logic_vector(N*16-1 downto 0); signal oeb,oen:integer;
  signal oen_slv:std_logic_vector(31 downto 0);
begin
  clk<=not clk after 5 ns; oen<=to_integer(signed(oen_slv));
  u_beh: entity beh.rmsnorm generic map(N=>N,Q=>12) port map(clk=>clk,rst=>rst,start=>start,x_mant=>xm,x_exp=>xe,w_mant=>wm,w_exp=>we,done=>db,o_mant=>ob,o_exp=>oeb);
  u_net: entity work.rmsnorm port map(clk=>clk,rst=>rst,start=>start,x_mant=>xm,x_exp=>std_logic_vector(to_signed(xe,32)),w_mant=>wm,w_exp=>std_logic_vector(to_signed(we,32)),done=>dn,o_mant=>onet,o_exp=>oen_slv);
  process variable fails:integer:=0; begin
    for i in 0 to N-1 loop
      xm((i+1)*16-1 downto i*16)<=std_logic_vector(to_signed(((i*613+97) mod 40001)-20000,16));
      wm((i+1)*16-1 downto i*16)<=std_logic_vector(to_signed(6000+((i*211) mod 8000),16));
    end loop;
    we<=13;
    wait until rising_edge(clk); wait until rising_edge(clk); rst<='0'; wait until rising_edge(clk);
    for e in -12 to 18 loop
      xe<=e; wait until rising_edge(clk);
      start<='1'; wait until rising_edge(clk); start<='0';
      wait until (db='1' and dn='1') for 50 us; wait for 1 ns;
      if ob/=onet or oeb/=oen then fails:=fails+1;
        report "MISMATCH xe="&integer'image(e)&" oeb="&integer'image(oeb)&" oen="&integer'image(oen)&" meq="&boolean'image(ob=onet) severity warning;
      else report "xe="&integer'image(e)&" MATCH oe="&integer'image(oeb) severity note; end if;
      wait until rising_edge(clk);
    end loop;
    if fails=0 then report "PASS:rms_cmp all xe match" severity note; else report "FAIL:rms_cmp "&integer'image(fails)&" mismatches" severity note; end if;
    finish;
  end process;
end architecture;
