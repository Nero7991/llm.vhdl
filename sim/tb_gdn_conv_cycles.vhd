-- tb_gdn_conv_cycles: COUNTS CYCLES, checks nothing.
--
-- Why it is separate from tb_gdn_conv: that testbench is the correctness
-- testbench and drives one shape only -- nch = CH_MAX, because the vector file
-- is generated at CH_MAX.  A cycle model has to be fitted across MANY shapes,
-- and the fit is only convincing if the group count `nch / LANES` moves over a
-- wide range independently of `LANES`.  Loading a vector file for each of those
-- points would cost minutes per point and prove nothing extra: the cycle count
-- of gdn_conv is data-independent (the only data-dependent thing in the unit is
-- `msb_pos` in S_SH, which is one combinational cycle either way), so synthetic
-- data is sufficient AND it keeps this file from ever being mistaken for a
-- correctness check.
--
-- Definition of the measurement, stated so it can be reproduced: cycles are
-- counted from the rising edge on which the DUT SAMPLES `start` high, through
-- the rising edge on which the DUT drives `o_done` high, inclusive of neither
-- endpoint's own setup.  Concretely `cycles = (t_done - t_start) / TCLK` where
-- `t_start` is the edge that moved the FSM out of S_IDLE and `t_done` is the
-- edge whose S_FIN body asserted `o_done`.  The channel groups are streamed
-- back to back with no producer bubbles, so this is the unit's best case: a
-- caller that cannot feed a group per cycle measures more, never less.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;
-- std.env.finish, and it is NOT optional here: the clock is a free-running
-- concurrent assignment, so a bare `wait` at the end of the driver leaves GHDL
-- toggling it until time'high.  The run prints every result and then burns a
-- core forever, which reads exactly like a hung simulation.
use std.env.all;

entity tb_gdn_conv_cycles is
  generic(CH_MAX : positive := 3072;
          K      : positive := 4;
          LANES  : positive := 4);
end entity;

architecture sim of tb_gdn_conv_cycles is
  constant TCLK : time := 10 ns;
  constant NB   : integer := CH_MAX / LANES;
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal start, s_valid, o_valid, o_done, err_seg, ready : std_logic := '0';
  signal nch_s  : integer range 0 to CH_MAX := 0;
  signal tvalid : std_logic_vector(K-1 downto 0) := (others => '1');
  signal e_t    : std_logic_vector(K*8-1 downto 0) := (others => '0');
  signal cw_exp : signed(7 downto 0) := (others => '0');
  signal x_in, w_in : std_logic_vector(K*LANES*16-1 downto 0) := (others => '0');
  signal o_data : std_logic_vector(LANES*16-1 downto 0);
  signal e_seg  : signed(7 downto 0);
  signal sh_seg : integer range 0 to 63;

  -- group counts to visit.  Deliberately not a geometric sweep only: 3, 5 and
  -- 13 are there so a model that happens to fit powers of two cannot pass.
  type gl_t is array (natural range <>) of integer;
  constant GL : gl_t := (1, 2, 3, 4, 5, 8, 13, 16, 32, 64, 128, 192, 256, 384, 768);
begin
  clk <= not clk after TCLK/2;

  dut : entity work.gdn_conv
    generic map(CH_MAX => CH_MAX, K => K, LANES => LANES)
    port map(clk => clk, rst => rst, start => start,
             nch => nch_s, tvalid => tvalid, e_t => e_t, cw_exp => cw_exp,
             s_valid => s_valid, x_in => x_in, w_in => w_in,
             o_valid => o_valid, o_data => o_data, o_done => o_done,
             e_seg => e_seg, sh_seg => sh_seg, err_seg => err_seg, ready => ready);

  drive : process
    variable t0, t1 : time;
    variable cycles : integer;
    variable nb_g   : integer;
    variable seed   : integer := 12345;
    variable v      : integer;
    variable lo     : line;
  begin
    for t in 0 to K-1 loop
      e_t((t+1)*8-1 downto t*8) <= std_logic_vector(to_signed(3 - t, 8));
    end loop;
    cw_exp <= to_signed(5, 8);
    tvalid <= (others => '1');
    wait for 4*TCLK; rst <= '0'; wait until rising_edge(clk);

    for gi in GL'range loop
      nb_g := GL(gi);
      next when nb_g > NB;
      nch_s <= nb_g * LANES;
      wait until rising_edge(clk);

      start <= '1';
      wait until rising_edge(clk);      -- the DUT samples start on THIS edge
      t0 := now;
      start <= '0';

      -- pass A: one group per cycle, no bubbles
      while ready /= '1' loop wait until rising_edge(clk); end loop;
      for g in 0 to nb_g-1 loop
        for t in 0 to K-1 loop
          for ln in 0 to LANES-1 loop
            seed := (seed * 75 + 74) mod 65537;
            v := (seed mod 32768) - 16384;
            x_in((t*LANES+ln+1)*16-1 downto (t*LANES+ln)*16)
              <= std_logic_vector(to_signed(v, 16));
            w_in((t*LANES+ln+1)*16-1 downto (t*LANES+ln)*16)
              <= std_logic_vector(to_signed((v/7) + 11, 16));
          end loop;
        end loop;
        s_valid <= '1';
        wait until rising_edge(clk);
      end loop;
      s_valid <= '0';

      -- wait for done.  The 1 ns settle after each edge is what makes the
      -- endpoint unambiguous: read at the delta of the edge itself, o_done
      -- still holds its pre-edge value and every count comes out one high.
      loop
        wait until rising_edge(clk);
        wait for 1 ns;
        exit when o_done = '1';
      end loop;
      t1 := now - 1 ns;
      cycles := (t1 - t0) / TCLK;

      write(lo, string'("CYC,"));
      write(lo, LANES);   write(lo, string'(","));
      write(lo, CH_MAX);  write(lo, string'(","));
      write(lo, nb_g*LANES); write(lo, string'(","));
      write(lo, nb_g);    write(lo, string'(","));
      write(lo, cycles);
      writeline(output, lo);

      wait until rising_edge(clk);
    end loop;

    report "tb_gdn_conv_cycles: done" severity note;
    finish;
  end process;
end architecture;
