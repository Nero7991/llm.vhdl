-- TRACK LUTDIET.  rmsnorm_rs_hotw must be BIT-EXACT with rmsnorm_rs: same
-- ports, same values, only the output register's write decode differs.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use ieee.math_real.all; use std.textio.all;
entity tb_lutdiet_hotw is end entity;
architecture tb of tb_lutdiet_hotw is
  constant N : positive := 256; constant LN : positive := 4;
  signal clk : std_logic := '0'; signal rst : std_logic := '1';
  signal st  : std_logic := '0';
  signal xv, wv : std_logic_vector(N*16-1 downto 0) := (others => '0');
  signal oa, ob : std_logic_vector(N*16-1 downto 0);
  signal xe, we : integer := 0;
  signal da, db : std_logic; signal ea, eb : integer;
  signal dla, dlb, clr : std_logic := '0';
  signal running : boolean := true;
begin
  clk <= not clk after 5 ns when running else '0';
  process(clk) begin
    if rising_edge(clk) then
      if clr = '1' then dla <= '0'; dlb <= '0';
      else
        if da = '1' then dla <= '1'; end if;
        if db = '1' then dlb <= '1'; end if;
      end if;
    end if;
  end process;
  ua : entity work.rmsnorm_rs      generic map(N => N, LANES => LN)
    port map(clk, rst, st, xv, xe, wv, we, da, oa, ea);
  ub : entity work.rmsnorm_rs_hotw generic map(N => N, LANES => LN)
    port map(clk, rst, st, xv, xe, wv, we, db, ob, eb);
  process
    variable s1 : positive := 17; variable s2 : positive := 4021;
    variable r : real; variable v : integer; variable errs : natural := 0;
    variable l : line; variable nz : natural;
  begin
    wait for 40 ns; rst <= '0'; wait until rising_edge(clk);
    for t in 0 to 5 loop
      for i in 0 to N-1 loop
        uniform(s1, s2, r);
        case t is
          when 1 => v := integer(r*200.0) - 100;
          when 2 => v := 32767;
          when 3 => v := -32768;
          when 4 => v := integer(r*4.0) - 2;
          when others => v := integer(r*65534.0) - 32767;
        end case;
        xv((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(v, 16));
        uniform(s1, s2, r); v := integer(r*2000.0) - 1000;
        if t = 3 then v := 32767; end if;
        wv((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(v, 16));
      end loop;
      xe <= t - 2; we <= 3 - t;
      wait until rising_edge(clk);
      clr <= '1'; wait until rising_edge(clk); clr <= '0';
      st <= '1'; wait until rising_edge(clk); st <= '0';
      for g in 0 to 20000 loop
        exit when dla = '1' and dlb = '1';
        wait until rising_edge(clk);
      end loop;
      assert dla = '1' and dlb = '1' report "LUTDIET FAIL: no done" severity failure;
      wait until rising_edge(clk);
      if ea /= eb then errs := errs + 1;
        report "LUTDIET FAIL o_exp" severity error; end if;
      nz := 0;
      for i in 0 to N-1 loop
        if oa((i+1)*16-1 downto i*16) /= ob((i+1)*16-1 downto i*16) then
          errs := errs + 1;
          if errs < 8 then
            write(l, string'("LUTDIET FAIL t ")); write(l, t);
            write(l, string'(" i ")); write(l, i);
            write(l, string'(" flat ")); write(l, to_integer(signed(oa((i+1)*16-1 downto i*16))));
            write(l, string'(" hotw ")); write(l, to_integer(signed(ob((i+1)*16-1 downto i*16))));
            writeline(output, l);
          end if;
        end if;
        if to_integer(signed(oa((i+1)*16-1 downto i*16))) /= 0 then nz := nz + 1; end if;
      end loop;
      write(l, string'("LUTDIET hotw trial ")); write(l, t);
      write(l, string'(" nonzero ")); write(l, nz); writeline(output, l);
    end loop;
    if errs = 0 then report "LUTDIET HOTW EQUIV PASS" severity note;
    else report "LUTDIET HOTW EQUIV FAIL " & integer'image(errs) severity failure; end if;
    running <= false; wait;
  end process;
end architecture;
