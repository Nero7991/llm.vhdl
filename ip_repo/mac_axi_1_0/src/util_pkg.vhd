library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
package util_pkg is
  function clog2(n : natural) return natural;
end package;
package body util_pkg is
  function clog2(n : natural) return natural is
    variable r : natural := 0; variable v : natural := 1;
  begin
    while v < n loop v := v*2; r := r+1; end loop;
    return r;
  end function;
end package body;
