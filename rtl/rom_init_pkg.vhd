-- rtl/rom_init_pkg.vhd
-- Reusable readmemh-style file initializer for block-RAM ROMs.
--
-- init_rom_hex(fname, n, width) opens `fname` and reads `n` lines, each a
-- two's-complement value written as width/4 hex digits (one per line, as emitted
-- by tools/gen_weight_mem.py into mem/rom/*.mem), returning an integer_vector.
--
-- Consumers declare a ROM SIGNAL initialized by this function and read it
-- synchronously (registered address -> registered data), which is the documented
-- Vivado pattern for a block RAM initialized from a data file (UG901 "Initializing
-- Block RAM from an External Data File").  Unlike a giant VHDL constant aggregate,
-- this does NOT constant-fold ~300K literals, so elaboration/synthesis stays light.
--
-- One codebase for BOTH toolchains:
--   * GHDL --std=08 : file_open/readline + hread (hread for std_logic_vector is a
--     VHDL-2008 op in ieee.std_logic_1164).
--   * Vivado (read_vhdl -vhdl2008) : same, and it initializes the inferred BRAM.
-- The .mem path is resolved relative to the tool's current directory (both GHDL
-- and the OOC Vivado runs launch from sim/, so the default "../mem/rom/" works);
-- consumers expose it as a generic so a different build dir can override it.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

package rom_init_pkg is
  impure function init_rom_hex(fname : string; n : natural; width : natural)
    return integer_vector;
end package;

package body rom_init_pkg is
  impure function init_rom_hex(fname : string; n : natural; width : natural)
    return integer_vector is
    file     f    : text;
    variable stat : file_open_status;
    variable l    : line;
    variable slv  : std_logic_vector(width-1 downto 0);
    variable res  : integer_vector(0 to n-1) := (others => 0);
  begin
    file_open(stat, f, fname, read_mode);
    assert stat = open_ok
      report "init_rom_hex: cannot open '" & fname & "'"
      severity failure;
    for i in 0 to n-1 loop
      assert not endfile(f)
        report "init_rom_hex: premature EOF in '" & fname & "'"
        severity failure;
      readline(f, l);
      hread(l, slv);
      res(i) := to_integer(signed(slv));
    end loop;
    file_close(f);
    return res;
  end function;
end package body;
