-- tb/tb_weight_mem.vhd
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use work.util_pkg.all;
entity tb_weight_mem is end;
architecture sim of tb_weight_mem is
  constant WORDS:positive:=8; constant W:positive:=8;
  signal clk:std_logic:='0';
  signal addr:std_logic_vector(clog2(WORDS)-1 downto 0):=(others=>'0');
  signal dout:std_logic_vector(W-1 downto 0):=(others=>'0');
  -- Expected fixture values (golden)
  constant golden:integer_vector(0 to 7):=(-3,7,0,-128,127,1,-1,42);
begin
  clk<=not clk after 5 ns;
  uut:entity work.weight_mem generic map(WORDS=>WORDS,W=>W,INIT=>"../mem/golden/wm_fixture.mem")
      port map(clk=>clk,addr=>addr,dout=>dout);
  process begin
    for i in 0 to 7 loop
      addr<=std_logic_vector(to_unsigned(i,addr'length));
      wait until rising_edge(clk); wait for 1 ns;
      assert to_integer(signed(dout))=golden(i)
        report "weight addr "&integer'image(i)&" got "&integer'image(to_integer(signed(dout)))&" expected "&integer'image(golden(i)) severity failure;
    end loop;
    report "PASS:weight_mem" severity note; std.env.finish;
  end process;
end;
