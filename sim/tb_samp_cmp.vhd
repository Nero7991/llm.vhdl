library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.env.all;
library beh;
entity tb_samp_cmp is end;
architecture sim of tb_samp_cmp is
  constant VOCAB:integer:=512;
  signal clk:std_logic:='0'; signal rst:std_logic:='1'; signal clr:std_logic:='0'; signal iv:std_logic:='0';
  signal inv:std_logic_vector(31 downto 0):=(others=>'0');
  signal tok_b,tok_n:integer;
  component sampler_stream_net is
    port(clk,rst,clr,in_valid:in std_logic; in_v:in std_logic_vector(31 downto 0); token:out std_logic_vector(31 downto 0));
  end component;
  signal tn_slv:std_logic_vector(31 downto 0);
  function lv(v:integer) return integer is begin
    -- peak at index 300, otherwise a ramp; tests strict-> first-max
    if v=300 then return 100000; elsif v=50 then return 100000; else return (v*7 mod 5000)-2500; end if;
  end function;
begin
  clk<=not clk after 5 ns;
  tok_n<=to_integer(signed(tn_slv));
  u_beh: entity beh.sampler_stream generic map(VOCAB=>VOCAB) port map(clk=>clk,rst=>rst,clr=>clr,in_valid=>iv,in_v=>inv,token=>tok_b);
  u_net: sampler_stream_net port map(clk=>clk,rst=>rst,clr=>clr,in_valid=>iv,in_v=>inv,token=>tn_slv);
  process begin
    wait until rising_edge(clk); wait until rising_edge(clk); rst<='0'; wait until rising_edge(clk);
    clr<='1'; wait until rising_edge(clk); clr<='0';
    for v in 0 to VOCAB-1 loop
      inv<=std_logic_vector(to_signed(lv(v),32)); iv<='1'; wait until rising_edge(clk);
    end loop;
    iv<='0'; wait until rising_edge(clk); wait for 1 ns;
    report "tok_beh="&integer'image(tok_b)&" tok_net="&integer'image(tok_n)&" (expect 50)" severity note;
    if tok_b=tok_n then report "PASS:samp_cmp match tok="&integer'image(tok_b) severity note;
    else report "FAIL:samp_cmp beh="&integer'image(tok_b)&" net="&integer'image(tok_n) severity note; end if;
    finish;
  end process;
end architecture;
