library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.env.all;
entity tb_attn_beh is end;
architecture sim of tb_attn_beh is
  constant DIM:integer:=64; constant KVDIM:integer:=32; constant MAXPOS:integer:=24; constant NPOS:integer:=4;
  signal clk:std_logic:='0'; signal rst:std_logic:='1'; signal start:std_logic:='0';
  signal layer:integer:=0; signal cur_pos:integer:=0;
  signal q_mant:std_logic_vector(DIM*16-1 downto 0):=(others=>'0'); signal q_exp:integer:=10;
  signal k_mant:std_logic_vector(KVDIM*16-1 downto 0):=(others=>'0'); signal k_exp:integer:=10;
  signal v_mant:std_logic_vector(KVDIM*16-1 downto 0):=(others=>'0'); signal v_exp:integer:=10;
  signal done_b:std_logic; signal xb_b:std_logic_vector(DIM*16-1 downto 0); signal xe_b:integer;
begin
  clk <= not clk after 5 ns;
  u_beh: entity work.attention_ml generic map(DIM=>DIM,MAXPOS=>MAXPOS)
    port map(clk=>clk,rst=>rst,start=>start,layer=>layer,cur_pos=>cur_pos,
      q_mant=>q_mant,q_exp=>q_exp,k_new_mant=>k_mant,k_new_exp=>k_exp,
      v_new_mant=>v_mant,v_new_exp=>v_exp,done=>done_b,xb_mant=>xb_b,xb_exp=>xe_b);
  process begin
    wait until rising_edge(clk); wait until rising_edge(clk); rst<='0'; wait until rising_edge(clk);
    for p in 0 to NPOS-1 loop
      for i in 0 to DIM-1 loop q_mant((i+1)*16-1 downto i*16)<=std_logic_vector(to_signed(((p*37+i*17) mod 121)-60,16)); end loop;
      for i in 0 to KVDIM-1 loop
        k_mant((i+1)*16-1 downto i*16)<=std_logic_vector(to_signed(((p*37+i*17+10) mod 121)-60,16));
        v_mant((i+1)*16-1 downto i*16)<=std_logic_vector(to_signed(((p*37+i*17+15) mod 121)-60,16)); end loop;
      cur_pos<=p; wait until rising_edge(clk); start<='1'; wait until rising_edge(clk); start<='0';
      wait until done_b='1' for 500 us; wait for 1 ns;
      report "pos="&integer'image(p)&" done="&std_logic'image(done_b)&" xe="&integer'image(xe_b) severity note;
      wait until rising_edge(clk);
    end loop;
    report "BEH_DONE" severity note; finish;
  end process;
end architecture;
