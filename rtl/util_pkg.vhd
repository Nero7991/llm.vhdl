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
  -- Highest set-bit index of v (0 for v<=0). Bounded FOR loop over the 32 bits
  -- so it is synthesizable (a while-loop on a runtime integer trips Vivado's
  -- 2000-iteration loop-convergence guard). Bit-identical to the old while form.
  function msb_pos(v : integer) return integer is
    variable u : unsigned(31 downto 0);
    variable p : integer := 0;
  begin
    if v <= 0 then return 0; end if;
    u := to_unsigned(v, 32);
    for i in 0 to 31 loop
      if u(i) = '1' then p := i; end if;
    end loop;
    return p;
  end function;
end package body;
