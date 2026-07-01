library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use work.util_pkg.all;
entity tb_smoke is end;
architecture sim of tb_smoke is
begin
  process begin
    assert clog2(1)=0  report "clog2(1)" severity failure;
    assert clog2(8)=3  report "clog2(8)" severity failure;
    assert clog2(9)=4  report "clog2(9)" severity failure;
    assert clog2(64)=6 report "clog2(64)" severity failure;
    report "PASS:smoke" severity note;
    std.env.finish;
  end process;
end;
