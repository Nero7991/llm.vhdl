-- TRACK LUTDIET equivalence bench.  NOT part of the project gate and NOT in
-- sim/ -- a new sim/tb_*.vhd is auto-discovered into the shared regression.
-- Asserts rmsnorm_rs_mem is BIT-EXACT with rmsnorm_rs, element for element,
-- over pseudo-random vectors including the saturating rails.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;
use ieee.math_real.all;
entity tb_lutdiet_rmsmem is end entity;
architecture tb of tb_lutdiet_rmsmem is
  constant N : positive := 256;
  constant LN : positive := 4;
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal start_a, start_b : std_logic := '0';
  signal xv, wv : std_logic_vector(N*16-1 downto 0) := (others => '0');
  signal ov     : std_logic_vector(N*16-1 downto 0);
  signal xe, we : integer := 0;
  signal done_a, done_b : std_logic;
  signal oe_a, oe_b : integer;
  signal x_we, w_we : std_logic := '0';
  signal x_wa, w_wa, o_ra : std_logic_vector(7 downto 0) := (others => '0');
  signal x_wd, w_wd, o_rd : std_logic_vector(15 downto 0) := (others => '0');
  signal running : boolean := true;
  -- `done` is a ONE-CYCLE PULSE in both units (rmsnorm_rs clears it every
  -- cycle by default), and the memory-backed unit's pulse is one cycle
  -- LATER because its last bank write is a registered write.  Waiting on
  -- `done_a='1' and done_b='1'` therefore deadlocks -- measured.  Latch each.
  signal dl_a, dl_b : std_logic := '0';
  signal clr : std_logic := '0';
begin
  clk <= not clk after 5 ns when running else '0';
  process(clk) begin
    if rising_edge(clk) then
      if clr = '1' then dl_a <= '0'; dl_b <= '0';
      else
        if done_a = '1' then dl_a <= '1'; end if;
        if done_b = '1' then dl_b <= '1'; end if;
      end if;
    end if;
  end process;

  ua : entity work.rmsnorm_rs generic map(N => N, LANES => LN)
    port map(clk => clk, rst => rst, start => start_a,
             x_mant => xv, x_exp => xe, w_mant => wv, w_exp => we,
             done => done_a, o_mant => ov, o_exp => oe_a);

  ub : entity work.rmsnorm_rs_mem generic map(N => N, LANES => LN)
    port map(clk => clk, rst => rst, start => start_b,
             x_we => x_we, x_waddr => x_wa, x_wdata => x_wd, x_exp => xe,
             w_we => w_we, w_waddr => w_wa, w_wdata => w_wd, w_exp => we,
             done => done_b, o_raddr => o_ra, o_rdata => o_rd, o_exp => oe_b);

  process
    variable seed1 : positive := 17;
    variable seed2 : positive := 4021;
    variable r  : real;
    variable v  : integer;
    variable errs : natural := 0;
    variable exp16, got16 : std_logic_vector(15 downto 0);
    variable l : line;
    variable nz : natural;
  begin
    wait for 40 ns; rst <= '0'; wait until rising_edge(clk);

    for trial in 0 to 5 loop
      -- ---- build the vectors ------------------------------------------
      for i in 0 to N-1 loop
        uniform(seed1, seed2, r);
        case trial is
          when 0 => v := integer(r*65534.0) - 32767;          -- full range
          when 1 => v := integer(r*200.0) - 100;              -- small
          when 2 => v := 32767;                               -- rail
          when 3 => v := -32768;                              -- rail
          when 4 => v := integer(r*4.0) - 2;                  -- near zero
          when others => v := integer(r*65534.0) - 32767;
        end case;
        xv((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(v, 16));
        uniform(seed1, seed2, r);
        v := integer(r*2000.0) - 1000;
        if trial = 3 then v := 32767; end if;
        wv((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(v, 16));
      end loop;
      xe <= trial - 2; we <= 3 - trial;
      wait until rising_edge(clk);

      -- ---- stream the same words into the memory-backed unit ----------
      for i in 0 to N-1 loop
        x_we <= '1'; w_we <= '1';
        x_wa <= std_logic_vector(to_unsigned(i, 8));
        w_wa <= std_logic_vector(to_unsigned(i, 8));
        x_wd <= xv((i+1)*16-1 downto i*16);
        w_wd <= wv((i+1)*16-1 downto i*16);
        wait until rising_edge(clk);
      end loop;
      x_we <= '0'; w_we <= '0';
      wait until rising_edge(clk);

      clr <= '1'; wait until rising_edge(clk); clr <= '0';
      start_a <= '1'; start_b <= '1'; wait until rising_edge(clk);
      start_a <= '0'; start_b <= '0';
      for g in 0 to 20000 loop
        exit when dl_a = '1' and dl_b = '1';
        wait until rising_edge(clk);
      end loop;
      assert dl_a = '1' and dl_b = '1'
        report "LUTDIET FAIL: a unit never asserted done" severity failure;
      wait until rising_edge(clk);

      assert oe_a = oe_b
        report "LUTDIET FAIL trial " & integer'image(trial) & " o_exp "
             & integer'image(oe_a) & " vs " & integer'image(oe_b)
        severity error;
      if oe_a /= oe_b then errs := errs + 1; end if;

      nz := 0;
      for i in 0 to N-1 loop
        o_ra <= std_logic_vector(to_unsigned(i, 8));
        wait until rising_edge(clk);
        wait until rising_edge(clk);   -- 1 cycle RAM + 1 cycle sel register
        exp16 := ov((i+1)*16-1 downto i*16);
        got16 := o_rd;
        if exp16 /= got16 then
          errs := errs + 1;
          if errs < 12 then
            write(l, string'("LUTDIET FAIL trial "));  write(l, trial);
            write(l, string'(" i "));                  write(l, i);
            write(l, string'(" flat "));
            write(l, to_integer(signed(exp16)));
            write(l, string'(" mem "));
            write(l, to_integer(signed(got16)));
            writeline(output, l);
          end if;
        end if;
        if to_integer(signed(exp16)) /= 0 then nz := nz + 1; end if;
      end loop;
      write(l, string'("LUTDIET trial "));    write(l, trial);
      write(l, string'(" o_exp "));           write(l, oe_a);
      write(l, string'(" nonzero_out "));     write(l, nz);
      write(l, string'("/"));                 write(l, N);
      writeline(output, l);
      assert nz > 0 report "LUTDIET TOOTH: trial produced an all-zero output, "
        & "so it proves nothing" severity error;
    end loop;

    if errs = 0 then
      report "LUTDIET EQUIV PASS: rmsnorm_rs_mem is bit-exact with rmsnorm_rs"
        severity note;
    else
      report "LUTDIET EQUIV FAIL: " & integer'image(errs) & " mismatches"
        severity failure;
    end if;
    running <= false;
    wait;
  end process;
end architecture;
