library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
package util_pkg is
  function clog2(n : natural) return natural;
  -- Highest set bit index of v (0 for v<=0). Shared by layer.vhd and matmul.vhd.
  function msb_pos(v : integer) return integer;
end package;
package body util_pkg is
  function clog2(n : natural) return natural is
    variable r : natural := 0; variable v : natural := 1;
  begin
    while v < n loop v := v*2; r := r+1; end loop;
    return r;
  end function;
  function msb_pos(v : integer) return integer is
    variable u : integer := v;
    variable p : integer := 0;
  begin
    if u <= 0 then return 0; end if;
    while u > 1 loop u := u / 2; p := p + 1; end loop;
    return p;
  end function;
end package body;
