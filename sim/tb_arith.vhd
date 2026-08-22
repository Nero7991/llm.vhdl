-- sim/tb_arith.vhd -- checks rtl/mv4i_arith_pkg.vhd against the golden vectors
-- emitted by tools/gen_arith.py.  The SAME file drives the C side, so C and
-- VHDL are compared to one authority rather than to each other.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.mv4i_arith_pkg.all;

entity tb_arith is end entity;

architecture sim of tb_arith is
begin
  process
    file     vf   : text open read_mode is "../arith_vectors.txt";
    variable l    : line;
    variable op   : string(1 to 12);
    variable a1   : integer;
    variable a0v, expv : std_logic_vector(63 downto 0);
    variable a0, exp, got : signed(63 downto 0);
    variable n, bad : integer := 0;
    variable ch   : character;
    variable good : boolean;
    variable slen : integer;
  begin
    while not endfile(vf) loop
      readline(vf, l);
      if l'length = 0 then next; end if;
      read(l, ch, good);
      if not good or ch = '#' then next; end if;
      -- rebuild the op token
      op := (others => ' ');
      slen := 1; op(1) := ch;
      loop
        read(l, ch, good);
        exit when not good or ch = ' ';
        slen := slen + 1; op(slen) := ch;
      end loop;
      hread(l, a0v); read(l, a1); hread(l, expv);
      a0 := signed(a0v); exp := signed(expv);

      if op(1 to 9) = "floor_shr" then
        got := floor_shr(a0, a1);
      elsif op(1 to 11) = "round_shift" then
        got := round_shift(a0, a1);
      elsif op(1 to 5) = "sat16" then
        got := resize(sat16(a0), 64);
      elsif op(1 to 5) = "sat32" then
        got := resize(sat32(a0), 64);
      elsif op(1 to 7) = "msb_pos" then
        got := to_signed(msb_pos_u(unsigned(a0v)), 64);
      elsif op(1 to 5) = "site4" then
        got := resize(sat16(round_shift(a0, a1)), 64);
      else
        next;
      end if;

      n := n + 1;
      if got /= exp then
        bad := bad + 1;
        if bad <= 8 then
          report "MISMATCH " & op & " sh=" & integer'image(a1) &
                 " got " & integer'image(to_integer(resize(got,32))) &
                 " want " & integer'image(to_integer(resize(exp,32)))
                 severity error;
        end if;
      end if;
    end loop;
    report "arith vectors: " & integer'image(n) & " checked, " &
           integer'image(bad) & " mismatches"
           severity note;
    assert bad = 0 report "ARITH PACKAGE DIVERGES FROM GOLDEN VECTORS"
           severity failure;
    wait;
  end process;
end architecture;
