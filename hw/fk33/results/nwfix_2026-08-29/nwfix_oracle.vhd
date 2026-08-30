-- nwfix_oracle.vhd -- TRACK NWFIX, 2026-08-29.  SCRATCH, not in sim/.
--
-- THE VALUES ORACLE TRACK NWROM SAID DID NOT EXIST.  Its write-up, section 8:
-- "Nothing here checks that the table Vivado loaded holds the values the file
-- holds."  This entity holds THREE things and compares them:
--
--   (1) `nw_count_old` -- the counting function as it stood at fc7dea9, one
--       `readline` per iteration of a single `while` loop.
--   (2) `nw_count_new` -- the shipping function after the NWFIX edit, counting
--       in groups of NN through two nested loops.
--   (3) `nw_load`      -- copied VERBATIM from rtl/llama_top.vhd.
--
-- and then emits, per norm op, a checksum of the DECODED signed values plus
-- the first and last element.  `nwfix_oracle.py` computes the same three
-- numbers from the same file with an independent reader, so agreement is a
-- cross-implementation check on the loaded values and not a round trip
-- through this file's own writer.
--
-- NO HARDWARE.  GHDL only.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity nwfix_oracle is
  generic (
    NORM_W_IMAGE : string  := "";
    SKIP_OLD     : boolean := false;
    NN           : positive := 4096;
    MANT_W       : positive := 16
  );
end entity;

architecture beh of nwfix_oracle is

  -- ---------------- (1) the OLD function, verbatim from fc7dea9 -----------
  impure function nw_count_old return natural is
    file     fh : text;
    variable ok : file_open_status;
    variable l  : line;
    variable n  : natural := 0;
  begin
    if SKIP_OLD then return 0; end if;
    if NORM_W_IMAGE = "" then return 1; end if;
    file_open(ok, fh, NORM_W_IMAGE, read_mode);
    assert ok = open_ok
      report "oracle: cannot open " & NORM_W_IMAGE severity failure;
    while not endfile(fh) loop
      readline(fh, l);
      n := n + 1;
    end loop;
    file_close(fh);
    assert n > 0 and n mod NN = 0
      report "oracle(old): " & NORM_W_IMAGE & " has " & integer'image(n)
           & " lines, not a positive multiple of " & integer'image(NN) & "."
      severity failure;
    return n / NN;
  end function;

  -- ---------------- (2) the NEW function, verbatim from the edit -----------
  impure function nw_count_new return natural is
    file     fh : text;
    variable ok    : file_open_status;
    variable l     : line;
    variable n     : natural := 0;
    variable part  : natural := 0;
    variable short : boolean := false;
  begin
    if NORM_W_IMAGE = "" then return 1; end if;
    file_open(ok, fh, NORM_W_IMAGE, read_mode);
    assert ok = open_ok
      report "oracle: cannot open " & NORM_W_IMAGE severity failure;
    while not endfile(fh) loop
      part := 0;
      for i in 0 to NN-1 loop
        if endfile(fh) then
          short := true;
          exit;
        end if;
        readline(fh, l);
        part := part + 1;
      end loop;
      if short then exit; end if;
      n := n + 1;
    end loop;
    file_close(fh);
    assert not short
      report "oracle(new): " & NORM_W_IMAGE & " holds " & integer'image(n)
           & " complete norm ops of " & integer'image(NN) & " elements plus "
           & integer'image(part) & " leftover lines."
      severity failure;
    assert n > 0
      report "oracle(new): " & NORM_W_IMAGE & " is empty." severity failure;
    return n;
  end function;

  constant NW_N_OLD : natural  := nw_count_old;
  constant NW_N     : positive := nw_count_new;

  type nw_t is array (0 to NW_N-1)
    of std_logic_vector(NN*MANT_W-1 downto 0);

  -- ---------------- (3) nw_load, verbatim from rtl/llama_top.vhd -----------
  -- W_CONST is unreachable here (the image is never "") so it is a zero fill.
  constant W_CONST : std_logic_vector(NN*MANT_W-1 downto 0) := (others => '0');

  impure function nw_load return nw_t is
    file     fh : text;
    variable ok : file_open_status;
    variable l  : line;
    variable v  : std_logic_vector(MANT_W-1 downto 0);
    variable r  : nw_t := (others => W_CONST);
  begin
    if NORM_W_IMAGE = "" then return r; end if;
    file_open(ok, fh, NORM_W_IMAGE, read_mode);
    assert ok = open_ok
      report "oracle: cannot open " & NORM_W_IMAGE severity failure;
    for k in 0 to NW_N-1 loop
      for i in 0 to NN-1 loop
        readline(fh, l);
        hread(l, v);
        r(k)((i+1)*MANT_W-1 downto i*MANT_W) := v;
      end loop;
    end loop;
    file_close(fh);
    return r;
  end function;

  constant NW_TBL : nw_t := nw_load;

begin
  process is
    variable ln  : line;
    variable acc : integer;
    variable wac : integer;
    variable e   : integer;
  begin
    report "NWFIX_ORACLE image=" & NORM_W_IMAGE severity note;
    assert SKIP_OLD or NW_N_OLD = NW_N
      report "NWFIX_ORACLE COUNT MISMATCH old=" & integer'image(NW_N_OLD)
           & " new=" & integer'image(NW_N) severity failure;
    write(ln, string'("NWFIX_ORACLE_NW_N ") & integer'image(NW_N));
    writeline(output, ln);
    for k in 0 to NW_N-1 loop
      acc := 0;
      wac := 0;
      for i in 0 to NN-1 loop
        e := to_integer(signed(NW_TBL(k)((i+1)*MANT_W-1 downto i*MANT_W)));
        -- sum mod 2**24, kept inside integer'high with room to spare
        acc := (acc + e) mod 16777216;
        if acc < 0 then acc := acc + 16777216; end if;
        -- POSITION-WEIGHTED, because the plain sum is permutation-blind.
        -- MEASURED, mutation T6: swapping elements 100 and 200 of one norm op
        -- leaves `sum24`, `first` and `last` all unchanged, so the plain sum
        -- alone cannot see a shuffled gain vector.
        wac := (wac + ((i + 1) mod 4096) * e) mod 16777216;
        if wac < 0 then wac := wac + 16777216; end if;
      end loop;
      write(ln, string'("NWFIX_ORACLE_OP ") & integer'image(k)
              & " sum24=" & integer'image(acc)
              & " wsum24=" & integer'image(wac)
              & " first=" & integer'image(to_integer(signed(
                    NW_TBL(k)(MANT_W-1 downto 0))))
              & " last=" & integer'image(to_integer(signed(
                    NW_TBL(k)(NN*MANT_W-1 downto (NN-1)*MANT_W)))));
      writeline(output, ln);
    end loop;
    write(ln, string'("NWFIX_ORACLE_DONE"));
    writeline(output, ln);
    wait;
  end process;
end architecture;
