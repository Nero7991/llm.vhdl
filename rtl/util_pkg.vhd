library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
package util_pkg is
  -- ceil(log2(n)), with clog2(0) = clog2(1) = 0.
  --
  -- EXACT AND OVERFLOW-FREE OVER THE WHOLE OF `natural`, 0 .. 2147483647.
  --
  -- The body up to 2026-08-29 was a doubling loop
  --     variable v : natural := 1;  while v < n loop v := v*2; r := r+1; end loop;
  -- which forms 2**31 the instant n passes 2**30.  MEASURED (GHDL 1.0.0
  -- mcode, scratch reproducer): n = 1073741824 returns 30, and n = 1073741825
  -- and n = 2147483647 both die with
  --     ghdl:error: overflow detected
  --       from: work.util_pkg.clog2 at util_pkg.vhd:<the while line>
  --     ghdl:error: error during elaboration
  -- The message names THIS function and not the caller that supplied n, so a
  -- design whose address arithmetic crossed 1 GiB failed in a file it had
  -- never heard of.  That cost TRACK CGENERICS a full round on the subsystem
  -- C KV map.  The fix below removes the failure rather than renaming it:
  -- there is no n in `natural` for which this body can abort, so there is no
  -- diagnostic left to attribute.
  --
  -- Shape: halve n-1 instead of doubling towards n.  The working value only
  -- ever DECREASES, so no intermediate can leave `natural`.  The loop is a
  -- bounded FOR rather than a while, for the same reason msb_pos below is:
  -- a while-loop on a runtime integer trips Vivado's 2000-iteration
  -- loop-convergence guard.  31 halvings take natural'high-1 to zero because
  -- natural'high < 2**31, so the bound is exact and not a guess.
  function clog2(n : natural) return natural;

  -- ceil(log2(u)) for a magnitude that does NOT fit `natural`.
  --
  -- Byte quantities in this design already exceed 4 GiB: the 9B KV map bases
  -- above byte 4,521,582,592, and natural'high is 2,147,483,647, so such a
  -- value cannot even be WRITTEN as the argument to the function above, let
  -- alone measured by it.  `2**31` is a hard ceiling of the integer type, not
  -- of the old loop, and no rewrite of clog2(natural) can lift it.
  --
  -- Build the quantity as an `unsigned` wide enough to hold it and use this
  -- instead:
  --     clog2(to_unsigned(C_LAY,64) * C_NKVH * C_MAXPOS * REC_B_C)
  -- TRAP, MEASURED 2026-08-29: numeric_std's "*"(UNSIGNED, NATURAL) returns
  -- 2*L'LENGTH bits, NOT L'LENGTH.  Feeding the product straight into clog2
  -- as above is correct and needs no resize, because this function accepts an
  -- unsigned of any width -- but assigning it back to a 64-bit variable is a
  -- `bound check failure` at run time, not a truncation and not an analysis
  -- error.  Resize explicitly if you need to keep the width.
  -- All-zero and null-range arguments return 0, matching clog2(0) above.
  -- Metavalues ('U','X',...) do not compare equal to '1' and are therefore
  -- read as clear; this function is for elaboration-time constants, where
  -- none can occur.
  function clog2(u : unsigned) return natural;

  -- Highest set bit index of v (0 for v<=0). Shared by layer.vhd and matmul.vhd.
  function msb_pos(v : integer) return integer;
end package;
package body util_pkg is
  function clog2(n : natural) return natural is
    variable m : natural;
    variable r : natural := 0;
  begin
    if n <= 1 then return 0; end if;
    m := n - 1;
    for i in 1 to 31 loop
      if m > 0 then m := m / 2; r := r + 1; end if;
    end loop;
    return r;
  end function;

  function clog2(u : unsigned) return natural is
    alias    uu  : unsigned(u'length-1 downto 0) is u;
    variable hi  : integer := -1;   -- index of the highest set bit, -1 if none
    variable cnt : natural := 0;    -- population count, to spot exact powers
  begin
    if u'length = 0 then return 0; end if;
    for i in 0 to uu'high loop
      if uu(i) = '1' then hi := i; cnt := cnt + 1; end if;
    end loop;
    if hi < 0  then return 0;      end if;  -- u = 0
    if cnt = 1 then return hi;     end if;  -- exact power of two
    return hi + 1;                          -- otherwise round up
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
