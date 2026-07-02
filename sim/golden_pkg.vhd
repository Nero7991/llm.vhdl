-- sim/golden_pkg.vhd
-- TEXTIO helpers for reading golden-file formats used by simulation TBs.
--
-- BFP block format:
--   <n>
--   EXP <e>
--   val0 val1 ... val_{n-1}   (space-separated on one line)
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;

package golden_pkg is

  -- Read one BFP block from an open text file.
  -- On entry: file positioned at the "<n>" line.
  -- On return: n_out = count, e_out = exponent, data(0..n-1) = mantissas.
  -- The caller must size data to at least (0 to n-1).
  procedure read_bfp_block(
    file     f     : text;
    variable n_out : out integer;
    variable e_out : out integer;
    variable data  : out integer_vector
  );

  -- Read 'count' integers from successive lines (one integer per line).
  impure function read_int_lines(file f : text; count : integer)
    return integer_vector;

end package;

package body golden_pkg is

  -- Parse an integer from line L, skipping non-numeric leading characters.
  -- Used to extract the number after "EXP " on the exponent line.
  procedure parse_int_after_prefix(variable L : inout line; variable result : out integer) is
    variable ch  : character;
    variable ok  : boolean;
    variable neg : boolean;
    variable acc : integer;
    variable d   : integer;
  begin
    neg    := false;
    acc    := 0;
    -- Skip non-digit, non-sign characters
    loop
      read(L, ch, ok);
      exit when not ok;
      if ch = '-' or (ch >= '0' and ch <= '9') then
        -- found start of number
        if ch = '-' then
          neg := true;
          -- read first digit
          read(L, ch, ok);
          if not ok then result := 0; return; end if;
        end if;
        acc := character'pos(ch) - character'pos('0');
        -- read remaining digits
        loop
          read(L, ch, ok);
          exit when not ok;
          exit when ch < '0' or ch > '9';
          d   := character'pos(ch) - character'pos('0');
          acc := acc * 10 + d;
        end loop;
        if neg then acc := -acc; end if;
        result := acc;
        return;
      end if;
    end loop;
    result := 0;
  end procedure;

  procedure read_bfp_block(
    file     f     : text;
    variable n_out : out integer;
    variable e_out : out integer;
    variable data  : out integer_vector
  ) is
    variable L   : line;
    variable n   : integer;
    variable e   : integer;
    variable v   : integer;
  begin
    -- Line 1: n
    readline(f, L);
    read(L, n);
    n_out := n;

    -- Line 2: "EXP <e>"
    readline(f, L);
    parse_int_after_prefix(L, e);
    e_out := e;

    -- Line 3: n space-separated integers
    readline(f, L);
    for i in 0 to n - 1 loop
      read(L, v);
      data(i) := v;
    end loop;
  end procedure;

  impure function read_int_lines(file f : text; count : integer)
    return integer_vector
  is
    variable L : line;
    variable v : integer;
    variable r : integer_vector(0 to count - 1);
  begin
    for i in 0 to count - 1 loop
      readline(f, L);
      read(L, v);
      r(i) := v;
    end loop;
    return r;
  end function;

end package body;
