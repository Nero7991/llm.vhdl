-- Bench for jc_loader_pkg.crc32_word against zlib vectors (tools/jc/gen_jc_vectors.py).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;
use work.jc_loader_pkg.all;

entity tb_jc_crc32 is
end entity;

architecture sim of tb_jc_crc32 is
begin
  process
    file vf     : text open read_mode is "jc_crc32_vec.txt";
    variable l  : line;
    variable n  : integer;
    variable w  : std_logic_vector(31 downto 0);
    variable c  : std_logic_vector(31 downto 0);
    variable ex : std_logic_vector(31 downto 0);
    variable checks, errors : natural := 0;
  begin
    while not endfile(vf) loop
      readline(vf, l);
      read(l, n);
      c := (others => '1');
      for i in 1 to n loop
        hread(l, w);
        c := crc32_word(c, w);
      end loop;
      hread(l, ex);
      checks := checks + 1;
      if (c xor x"FFFFFFFF") /= ex then
        errors := errors + 1;
        report "crc mismatch on a " & integer'image(n) & "-word vector" severity error;
      end if;
    end loop;
    assert checks = 6 report "expected 6 vectors, read " & integer'image(checks) severity failure;
    if errors = 0 then
      report "PASS: tb_jc_crc32 checks=" & integer'image(checks);
    else
      report "FAIL: tb_jc_crc32 errors=" & integer'image(errors) severity failure;
    end if;
    wait;
  end process;
end architecture;
