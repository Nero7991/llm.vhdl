-- tb/tb_kv_mem.vhd
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use work.util_pkg.all;
entity tb_kv_mem is end;
architecture sim of tb_kv_mem is
  constant WORDS:positive:=32; constant W:positive:=16;
  signal clk:std_logic:='0'; signal we:std_logic:='0';
  signal waddr,raddr:std_logic_vector(clog2(WORDS)-1 downto 0):=(others=>'0');
  signal din,dout:std_logic_vector(W-1 downto 0):=(others=>'0');
begin
  clk<=not clk after 5 ns;
  uut:entity work.kv_mem generic map(WORDS=>WORDS,W=>W)
      port map(clk=>clk,we=>we,waddr=>waddr,raddr=>raddr,din=>din,dout=>dout);
  process begin
    for i in 0 to 7 loop
      wait until rising_edge(clk);
      we<='1'; waddr<=std_logic_vector(to_unsigned(i,waddr'length));
      din<=std_logic_vector(to_signed(i*7-10,W));
    end loop;
    wait until rising_edge(clk); we<='0';
    for i in 0 to 7 loop
      raddr<=std_logic_vector(to_unsigned(i,raddr'length));
      wait until rising_edge(clk); wait for 1 ns;
      assert to_integer(signed(dout))=i*7-10
        report "kv addr "&integer'image(i) severity failure;
    end loop;
    report "PASS:kv_mem" severity note; std.env.finish;
  end process;
end;
