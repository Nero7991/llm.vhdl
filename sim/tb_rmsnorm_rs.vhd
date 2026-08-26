-- Proves rmsnorm_rs is BIT-EXACT with rmsnorm by running both on the same
-- stimulus and comparing every output element and the exponent.
--
-- WHY A/B AND NOT A GOLDEN VECTOR.  rmsnorm.vhd is itself the reference for
-- this arithmetic -- it is asserted bit-exact against rmsnorm_fx() in
-- ref/run_fx.c, and the whole point of rmsnorm_rs is to be a drop-in for it.
-- A stored golden vector would freeze one N, one exponent pair and one input
-- distribution; instantiating the original means every case below is checked
-- against the thing rmsnorm_rs has to replace, at every LANES value, with no
-- opportunity for the two to drift apart silently.
--
-- The cases are chosen to hit the sites where a narrowing or a reordering
-- could differ, not to be a broad random sweep:
--   * saturated inputs (+-32767, -32768) drive |xm*inv| to its bound, which
--     is what licenses the s48 narrowing of the first multiply
--   * a single large element against zeros makes max|raw| come from ONE lane,
--     so a lane-parallel max that dropped a lane would show
--   * all-zero input forces the mean_sq_q < 1 clamp and the rsqrt's degenerate
--     path, which is where the Q30 normalisation assumption is weakest
--   * x_exp negative and positive exercise both branches of the S_INV shift
--   * powers of two land max|raw| exactly on a bit boundary, where the
--     MSB scan and shift_total are one-off-able
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use ieee.math_real.all;

entity tb_rmsnorm_rs is
  generic(N : positive := 128; LANES : positive := 4);
end entity;

architecture sim of tb_rmsnorm_rs is
  signal clk  : std_logic := '0';
  signal rst  : std_logic := '1';
  signal done_sim : boolean := false;

  signal start : std_logic := '0';
  signal xm, wm : std_logic_vector(N*16-1 downto 0) := (others => '0');
  signal xe, we : integer := 0;

  signal a_done, b_done : std_logic;
  signal a_om, b_om     : std_logic_vector(N*16-1 downto 0);
  signal a_oe, b_oe     : integer;

  signal fails : natural := 0;
begin
  clk <= '0' when done_sim else not clk after 1 ns;

  ref : entity work.rmsnorm
    generic map(N => N)
    port map(clk=>clk, rst=>rst, start=>start,
             x_mant=>xm, x_exp=>xe, w_mant=>wm, w_exp=>we,
             done=>a_done, o_mant=>a_om, o_exp=>a_oe);

  dut : entity work.rmsnorm_rs
    generic map(N => N, LANES => LANES)
    port map(clk=>clk, rst=>rst, start=>start,
             x_mant=>xm, x_exp=>xe, w_mant=>wm, w_exp=>we,
             done=>b_done, o_mant=>b_om, o_exp=>b_oe);

  drv : process
    variable seed1, seed2 : positive := 7;
    variable r : real;
    variable a_cyc, b_cyc : natural;
    variable am, bm : signed(15 downto 0);
    variable bad : natural;
    variable ga, gb : boolean;

    procedure setx(i : natural; v : integer) is
    begin
      xm((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(v, 16));
    end procedure;
    procedure setw(i : natural; v : integer) is
    begin
      wm((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(v, 16));
    end procedure;

    -- Runs both units from one `start`, counts their cycles separately, and
    -- compares.  Returns nothing; failures are counted so the run reports ALL
    -- mismatching cases instead of stopping at the first, which matters when
    -- a narrowing is wrong for one input class only.
    procedure both(tag : string) is
    begin
      wait until rising_edge(clk);
      start <= '1';
      wait until rising_edge(clk);
      start <= '0';
      a_cyc := 0; b_cyc := 0; ga := false; gb := false;
      -- Each `done` is a ONE-CYCLE pulse and the two units take different
      -- numbers of cycles -- that is the whole point -- so they are latched
      -- separately.  Waiting for both to be high at the same instant can never
      -- succeed, which is how the first version of this testbench hung.
      while not (ga and gb) loop
        wait until rising_edge(clk);
        if a_done = '1' then ga := true; end if;
        if b_done = '1' then gb := true; end if;
        if not ga then a_cyc := a_cyc + 1; end if;
        if not gb then b_cyc := b_cyc + 1; end if;
        assert a_cyc < 20000 and b_cyc < 20000
          report tag & ": ref done=" & std_logic'image(a_done) & " (" &
                 integer'image(a_cyc) & " cyc), rs done=" &
                 std_logic'image(b_done) & " (" & integer'image(b_cyc) &
                 " cyc) -- a unit never finished" severity failure;
      end loop;
      -- outputs are held until the next start, so sampling after both is safe

      bad := 0;
      for i in 0 to N-1 loop
        am := signed(a_om((i+1)*16-1 downto i*16));
        bm := signed(b_om((i+1)*16-1 downto i*16));
        if am /= bm then
          if bad < 4 then
            report tag & ": element " & integer'image(i) & " ref=" &
                   integer'image(to_integer(am)) & " rs=" &
                   integer'image(to_integer(bm)) severity error;
          end if;
          bad := bad + 1;
        end if;
      end loop;
      if a_oe /= b_oe then
        report tag & ": o_exp ref=" & integer'image(a_oe) & " rs=" &
               integer'image(b_oe) severity error;
        bad := bad + 1;
      end if;
      if bad /= 0 then
        fails <= fails + 1;
        report tag & ": MISMATCH in " & integer'image(bad) & " place(s)"
          severity error;
      else
        report tag & ": bit-exact  (ref " & integer'image(a_cyc) &
               " cycles, rs " & integer'image(b_cyc) & ")" severity note;
      end if;
    end procedure;
  begin
    rst <= '1';
    for i in 0 to 5 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);

    -- 1. plain random
    for i in 0 to N-1 loop
      uniform(seed1, seed2, r); setx(i, integer(r*60000.0) - 30000);
      uniform(seed1, seed2, r); setw(i, integer(r*60000.0) - 30000);
    end loop;
    xe <= 8; we <= 12;
    both("random, xe=8");

    -- 2. the same data with a NEGATIVE x_exp: the other branch of S_INV
    xe <= -5; we <= 12;
    both("random, xe=-5");

    -- 3. saturated magnitudes: drives |xm*inv| to the bound that licenses s48
    for i in 0 to N-1 loop
      if i mod 2 = 0 then setx(i,  32767); else setx(i, -32768); end if;
      setw(i, 32767);
    end loop;
    xe <= 0; we <= 0;
    both("saturated +-32767/-32768");

    -- 4. one large element, rest zero: max|raw| comes from a single lane, so
    --    a lane-parallel max that lost a lane cannot hide here
    for i in 0 to N-1 loop setx(i, 0); setw(i, 1000); end loop;
    setx(N-1, 32767);
    xe <= 3; we <= 3;
    both("single spike at the LAST element");

    setx(N-1, 0); setx(0, 32767);
    both("single spike at the FIRST element");

    -- 5. all zero: forces the mean_sq_q < 1 clamp and the degenerate rsqrt
    for i in 0 to N-1 loop setx(i, 0); setw(i, 12345); end loop;
    xe <= 0; we <= 0;
    both("all-zero input (mean_sq_q clamp)");

    -- 6. exact powers of two: max|raw| lands on a bit boundary, where the MSB
    --    scan and shift_total are most easily off by one
    for i in 0 to N-1 loop setx(i, 1024); setw(i, 256); end loop;
    xe <= 4; we <= 4;
    both("powers of two");

    for i in 0 to N-1 loop setx(i, 1); setw(i, 1); end loop;
    xe <= 0; we <= 0;
    both("all ones (smallest nonzero)");

    -- 7. more random draws, different exponents, to catch anything the
    --    structured cases miss
    for t in 0 to 7 loop
      for i in 0 to N-1 loop
        uniform(seed1, seed2, r); setx(i, integer(r*40000.0) - 20000);
        uniform(seed1, seed2, r); setw(i, integer(r*40000.0) - 20000);
      end loop;
      xe <= t - 3; we <= 2 * t - 5;
      both("random sweep " & integer'image(t));
    end loop;

    -- 8. MAGNITUDE SWEEP -- the case that actually tests the rsqrt.
    --
    -- Mutation testing showed the random cases above barely exercise it: a
    -- WRONG rsqrt seed still produced bit-identical o_mant.  That is
    -- structural, not luck.  o_mant[j] = raw[j] >> shift_total, and
    -- shift_total is derived from max|raw| which is itself proportional to
    -- inv -- so inv very nearly CANCELS out of the mantissas, and all the
    -- rsqrt precision lands in o_exp instead.  A test that only compares
    -- mantissas on random data is close to blind to the Newton iteration.
    --
    -- Sweeping the input magnitude walks max|raw|'s MSB across many bit
    -- positions, which is where o_exp becomes a sharp probe of inv.  Verified
    -- by mutation: seeding the ROM at a constant, and dropping either Newton
    -- iteration, are caught here and NOT by the cases above.
    for m in 0 to 29 loop
      for i in 0 to N-1 loop
        setx(i, ((m * 37 + i * 11) mod 2000) + 1 + m * 1000);
        setw(i, ((m * 53 + i *  7) mod 3000) + 1);
      end loop;
      xe <= m mod 11 - 5; we <= 3;
      both("magnitude sweep m=" & integer'image(m));
    end loop;

    -- 9. mean_sq_q straddling a power of two, where the rsqrt's own
    --    normalisation shift (p <= 30 vs p > 30) changes branch.
    for m in 0 to 17 loop
      for i in 0 to N-1 loop
        if i = 0 then setx(i, 2**(m mod 15) + (m mod 3) - 1);
        else          setx(i, (m mod 5));
        end if;
        setw(i, 4096 + m);
      end loop;
      xe <= 2; we <= 1;
      both("power-of-two straddle m=" & integer'image(m));
    end loop;

    wait until rising_edge(clk);
    if fails = 0 then
      report "rmsnorm_rs is BIT-EXACT with rmsnorm on every case" severity note;
    else
      report "rmsnorm_rs DIFFERS from rmsnorm in " & integer'image(fails) &
             " case(s)" severity failure;
    end if;
    done_sim <= true;
    wait;
  end process;
end architecture;
