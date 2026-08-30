-- sim/tb_rmsnorm_rs_mem.vhd -- TRACK RMSMUX, 2026-08-30.
--
-- THE ORACLE FOR THE MEMORY-BACKED RMSNorm.
--
-- WHAT IS COMPARED, AND WHY IT IS NOT A ROUND TRIP.  `rmsnorm_rs_mem` writes
-- its input into a RAM and reads its output back out of one, so a bench that
-- only checked "what went in came out" would pass a packer plus a reversed
-- decoder -- this project's recorded `m7 mutant`.  So the comparison here is
-- against `rtl/rmsnorm.vhd`, which is an INDEPENDENTLY WRITTEN flat
-- implementation of the same arithmetic and is itself asserted bit-exact
-- against `rmsnorm_fx()` in `ref/run_fx.c`.  It shares no storage, no
-- addressing and no indexing with the DUT.  `rmsnorm_rs` is instantiated
-- alongside as a third opinion, because the DUT's contract is to be a
-- drop-in for THAT unit and a divergence between the two files -- which are
-- separately maintained -- must be caught at every gate run rather than at
-- the next area draw.
--
-- WHAT ELSE IS COMPARED, because a value check alone would pass a rewrite
-- that moved the schedule:
--   * `o_exp`, per trial.
--   * the CYCLE `done` fires on, DUT against `rmsnorm_rs`, exactly.  The
--     memory-backed write path is combinational precisely so this does not
--     move, and this is the assertion that says so rather than the comment.
--   * the READ LATENCY of o_raddr -> o_rdata, measured rather than assumed.
--
-- NON-DEGENERACY IS A HARD FAILURE, NOT A NOTE.  TRACK LUTDIET measured
-- THREE OF SIX of its trials producing an all-zero output from `rmsnorm_rs`
-- ITSELF -- the unit has a silent all-zeros rail outside its 19-octave
-- reciprocal window -- and two all-zero vectors compare equal.  So every
-- trial is classified, a trial that lands on the rail is reported by name and
-- counted separately, and the run FAILS unless at least MIN_LIVE trials were
-- non-degenerate (a non-zero element AND two distinct element values).  A
-- bench that says "6 of 6 passed" over three vacuous trials has not been
-- shown to work.
--
-- NO HARDWARE.  Simulation only.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use ieee.math_real.all;
use work.util_pkg.all;

entity tb_rmsnorm_rs_mem is
  generic(N : positive := 128; LANES : positive := 4;
          -- The number of trials that must be NON-DEGENERATE.  Eleven trials
          -- are run; three of them are deliberately on the all-zeros rail or
          -- are the all-zero input, so this is the count of the rest.
          MIN_LIVE : natural := 9;
          -- PER-CHECK SWITCHES, for the ATTRIBUTION CONTROL.  A mutation
          -- killed by this bench proves nothing about which check earned the
          -- kill until the same mutant is re-run with the other checks off.
          -- All three default TRUE, so the gate row runs the full bench.
          CHK_VAL : boolean := true;    -- values against rtl/rmsnorm.vhd
          CHK_CYC : boolean := true;    -- `done` cycle against rmsnorm_rs
          CHK_LAT : boolean := true);   -- o_raddr -> o_rdata latency
end entity;

architecture sim of tb_rmsnorm_rs_mem is
  constant AW : natural := clog2(N);

  signal clk  : std_logic := '0';
  signal rst  : std_logic := '1';
  signal done_sim : boolean := false;

  signal start : std_logic := '0';
  signal xm, wm : std_logic_vector(N*16-1 downto 0) := (others => '0');
  signal xe, we : integer := 0;

  -- golden (rtl/rmsnorm.vhd) and the shipping sibling (rtl/rmsnorm_rs.vhd)
  signal g_done, s_done : std_logic;
  signal g_om, s_om     : std_logic_vector(N*16-1 downto 0);
  signal g_oe, s_oe     : integer;

  -- DUT
  signal x_we, w_we : std_logic := '0';
  signal x_wa, w_wa : std_logic_vector(AW-1 downto 0) := (others => '0');
  signal x_wd, w_wd : std_logic_vector(15 downto 0) := (others => '0');
  signal d_done     : std_logic;
  signal o_ra       : std_logic_vector(AW-1 downto 0) := (others => '0');
  signal o_rd       : std_logic_vector(15 downto 0);
  signal d_oe       : integer;

  -- done latches.  `done` is a ONE-CYCLE PULSE and the three units do not
  -- have to fire on the same cycle for the bench to work, so waiting on a
  -- conjunction of the live signals deadlocks (measured by TRACK LUTDIET).
  signal g_l, s_l, d_l : std_logic := '0';
  signal g_c, s_c, d_c : natural := 0;   -- cycles from start to done
  signal cyc : natural := 0;
  signal counting : std_logic := '0';

  signal fails : natural := 0;
  signal live  : natural := 0;
  signal rail  : natural := 0;
  signal rdlat : integer := -1;          -- MEASURED o_raddr -> o_rdata edges
begin
  clk <= '0' when done_sim else not clk after 1 ns;

  golden : entity work.rmsnorm
    generic map(N => N)
    port map(clk=>clk, rst=>rst, start=>start,
             x_mant=>xm, x_exp=>xe, w_mant=>wm, w_exp=>we,
             done=>g_done, o_mant=>g_om, o_exp=>g_oe);

  sib : entity work.rmsnorm_rs
    generic map(N => N, LANES => LANES)
    port map(clk=>clk, rst=>rst, start=>start,
             x_mant=>xm, x_exp=>xe, w_mant=>wm, w_exp=>we,
             done=>s_done, o_mant=>s_om, o_exp=>s_oe);

  dut : entity work.rmsnorm_rs_mem
    generic map(N => N, LANES => LANES)
    port map(clk=>clk, rst=>rst, start=>start,
             x_we=>x_we, x_waddr=>x_wa, x_wdata=>x_wd, x_exp=>xe,
             w_we=>w_we, w_waddr=>w_wa, w_wdata=>w_wd, w_exp=>we,
             done=>d_done,
             o_raddr=>o_ra, o_rdata=>o_rd, o_exp=>d_oe);

  -- Latch each `done` and count the cycles it took.  Cleared at `start`.
  lat : process(clk) is
  begin
    if rising_edge(clk) then
      if start = '1' then
        g_l <= '0'; s_l <= '0'; d_l <= '0';
        g_c <= 0; s_c <= 0; d_c <= 0; cyc <= 0; counting <= '1';
      else
        if counting = '1' then cyc <= cyc + 1; end if;
        if g_done = '1' and g_l = '0' then g_l <= '1'; g_c <= cyc; end if;
        if s_done = '1' and s_l = '0' then s_l <= '1'; s_c <= cyc; end if;
        if d_done = '1' and d_l = '0' then d_l <= '1'; d_c <= cyc; end if;
      end if;
    end if;
  end process;

  drv : process
    variable seed1, seed2 : positive := 7;
    variable r  : real;
    variable gm, sm, dm : signed(15 downto 0);
    variable bad : natural;
    variable nz, distinct : natural;
    variable first_v : signed(15 downto 0);
    variable seen2 : boolean;
    variable nlive, nrail, nfail : natural := 0;
    variable lat_v : integer;

    procedure setx(i : natural; v : integer) is
    begin
      xm((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(v, 16));
    end procedure;
    procedure setw(i : natural; v : integer) is
    begin
      wm((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(v, 16));
    end procedure;

    -- Load the DUT's banks with the SAME words the flat vector holds, one
    -- word per cycle in ascending element order -- which is what
    -- rtl/llama_top.vhd's adapter and TRACK NORMURAM's gain loader both
    -- already do.  Deliberately driven from `xm`/`wm` so the two sides can
    -- never be given different numbers by a bench bug.
    --
    -- THE TWO STREAMS ARE SEQUENTIAL AND NOT SIMULTANEOUS, AND THAT IS A
    -- COVERAGE REQUIREMENT RATHER THAN A STYLE.  The first version of this
    -- procedure drove x_waddr and w_waddr with the SAME value on the same
    -- cycle, which made the `wbank` mutation -- the w bank enable decoded
    -- from x_waddr, the copy-paste fault this interface most invites -- a
    -- literal no-op, and it SURVIVED a bench that was otherwise killing
    -- everything.  Driving them in separate passes also matches the parent,
    -- where the region read and TRACK NORMURAM's gain loader are two
    -- independent streams that are not required to be in step.
    procedure load is
    begin
      for i in 0 to N-1 loop
        wait until rising_edge(clk);
        x_we <= '1'; w_we <= '0';
        x_wa <= std_logic_vector(to_unsigned(i, AW));
        x_wd <= xm((i+1)*16-1 downto i*16);
      end loop;
      wait until rising_edge(clk);
      x_we <= '0';
      for i in 0 to N-1 loop
        wait until rising_edge(clk);
        w_we <= '1';
        w_wa <= std_logic_vector(to_unsigned(i, AW));
        w_wd <= wm((i+1)*16-1 downto i*16);
      end loop;
      wait until rising_edge(clk);
      w_we <= '0';
    end procedure;

    -- Run one trial and compare EVERYTHING.
    procedure trial(tag : string) is
    begin
      load;
      wait until rising_edge(clk);
      start <= '1';
      wait until rising_edge(clk);
      start <= '0';
      -- Wait for all three, on the LATCHES, never on a conjunction of pulses.
      for t in 0 to 200000 loop
        wait until rising_edge(clk);
        exit when g_l = '1' and s_l = '1' and d_l = '1';
      end loop;
      assert g_l = '1' and s_l = '1' and d_l = '1'
        report "RMSMUX " & tag & ": a unit never asserted done" severity failure;

      -- ---- the SCHEDULE claim, checked rather than asserted in a comment
      if CHK_CYC and d_c /= s_c then
        report "RMSMUX FAIL " & tag & ": done cycle moved, rmsnorm_rs "
             & integer'image(s_c) & " vs rmsnorm_rs_mem " & integer'image(d_c)
          severity error;
        nfail := nfail + 1;
      end if;

      -- ---- the exponent
      if CHK_VAL and (d_oe /= g_oe or s_oe /= g_oe) then
        report "RMSMUX FAIL " & tag & ": o_exp golden " & integer'image(g_oe)
             & " sibling " & integer'image(s_oe) & " dut " & integer'image(d_oe)
          severity error;
        nfail := nfail + 1;
      end if;

      -- ---- the VALUES, element for element, DUT read out word by word
      bad := 0; nz := 0; seen2 := false;
      for i in 0 to N-1 loop
        o_ra <= std_logic_vector(to_unsigned(i, AW));
        wait until rising_edge(clk);
        -- ONE EDGE of latency: the RAM output register and the lane-select
        -- register both capture from the same combinational o_raddr, so
        -- o_rdata carries word i in the cycle AFTER the address is presented.
        -- Sampled at the falling edge and not with `wait for 0 ns`, which is
        -- the trap this bench hit: the RAM's `dout` and `o_rsel` resolve one
        -- delta after the edge and `o_rdata`, being combinational off them,
        -- one delta after that, so a single-delta sample reads the PREVIOUS
        -- address and every element is reported off by one -- a plausible,
        -- ordered, entirely wrong result.  The measurement below states the
        -- latency in EDGES rather than in deltas for the same reason.
        wait for 1 ns;
        dm := signed(o_rd);
        gm := signed(g_om((i+1)*16-1 downto i*16));
        sm := signed(s_om((i+1)*16-1 downto i*16));
        if CHK_VAL and (dm /= gm or sm /= gm) then
          if bad < 4 then
            report "RMSMUX FAIL " & tag & " i " & integer'image(i)
                 & " golden " & integer'image(to_integer(gm))
                 & " sibling " & integer'image(to_integer(sm))
                 & " dut " & integer'image(to_integer(dm)) severity error;
          end if;
          bad := bad + 1;
        end if;
        if gm /= 0 then nz := nz + 1; end if;
        if i = 0 then first_v := gm;
        elsif gm /= first_v then seen2 := true; end if;
      end loop;
      if bad > 0 then nfail := nfail + 1; end if;

      -- ---- NON-DEGENERACY.  A trial on the all-zeros rail proves nothing
      -- and says so under its own name; it is NOT counted as evidence.
      if nz > 0 and seen2 then
        nlive := nlive + 1;
        report "RMSMUX live " & tag & " o_exp " & integer'image(g_oe)
             & " nonzero " & integer'image(nz) & "/" & integer'image(N)
             & " done_cyc " & integer'image(d_c) severity note;
      else
        nrail := nrail + 1;
        report "RMSMUX RAIL " & tag & ": output is all-zero or constant, so "
             & "this trial proves nothing about the values" severity note;
      end if;
      live <= nlive; rail <= nrail; fails <= nfail;
    end procedure;
  begin
    rst <= '1';
    for i in 0 to 9 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);

    -- ---- 1. mid-scale random, the case that must be live
    for i in 0 to N-1 loop
      uniform(seed1, seed2, r); setx(i, integer(r*2000.0) - 1000);
      uniform(seed1, seed2, r); setw(i, integer(r*8000.0) + 1000);
    end loop;
    xe <= 0; we <= 12;
    trial("rand_mid");

    -- ---- 2. saturated inputs, which is what licenses the s48 narrowing
    for i in 0 to N-1 loop
      if i mod 2 = 0 then setx(i, 32767); else setx(i, -32768); end if;
      setw(i, 4096);
    end loop;
    xe <= -12; we <= 12;
    trial("sat");

    -- ---- 3. one large element against zeros: max|raw| comes from ONE lane,
    -- so a lane-parallel max that dropped a lane shows here
    for i in 0 to N-1 loop setx(i, 0); setw(i, 4096); end loop;
    setx(N/2 + 1, 30000);
    xe <= 0; we <= 12;
    trial("one_big");

    -- ---- 4. all-zero input: the mean_sq_q < 1 clamp and the rsqrt's
    -- degenerate path.  Expected to land on the rail; kept because the
    -- SCHEDULE and o_exp checks still bite there.
    for i in 0 to N-1 loop setx(i, 0); setw(i, 4096); end loop;
    xe <= 0; we <= 12;
    trial("all_zero");

    -- ---- 5/6. both signs of x_exp through the S_INV shift branches
    for i in 0 to N-1 loop
      uniform(seed1, seed2, r); setx(i, integer(r*600.0) - 300);
      uniform(seed1, seed2, r); setw(i, integer(r*6000.0) + 2000);
    end loop;
    xe <= 4;  we <= 12; trial("xexp_pos");
    xe <= -4; we <= 12; trial("xexp_neg");

    -- ---- 7. powers of two: max|raw| lands exactly on a bit boundary
    for i in 0 to N-1 loop
      setx(i, 2**((i mod 10) + 3));
      setw(i, 4096);
    end loop;
    xe <= 0; we <= 12; trial("pow2");

    -- ---- 8. a RAMP, which is the case a permuted or reversed readout
    -- passes on random data and fails here: every element is distinct and
    -- ordered, so any reordering of the output is visible element for
    -- element rather than only in aggregate.
    for i in 0 to N-1 loop
      setx(i, ((i * 131) mod 4001) - 2000);
      setw(i, 4096 + ((i * 7) mod 512) - 256);
    end loop;
    xe <= 0; we <= 12; trial("ramp");

    -- ---- 9. a BANK-ALIGNED ramp: element i = i, so element i and element
    -- i+LANES differ.  A bank/offset swap in the addressing permutes these
    -- and a random vector would hide it in the aggregate.
    for i in 0 to N-1 loop
      setx(i, (i mod 2048) - 1024);
      setw(i, 4096);
    end loop;
    xe <= 0; we <= 12; trial("bankramp");

    -- ---- 10. gain that varies per element, so a w-side bank error is not
    -- masked by a constant gain (every trial above except `ramp` uses one)
    for i in 0 to N-1 loop
      uniform(seed1, seed2, r); setx(i, integer(r*1200.0) - 600);
      setw(i, 1024 + (i mod 64) * 96);
    end loop;
    xe <= 0; we <= 12; trial("wvary");

    -- ---- 11. second random draw, different seed state
    for i in 0 to N-1 loop
      uniform(seed1, seed2, r); setx(i, integer(r*20000.0) - 10000);
      uniform(seed1, seed2, r); setw(i, integer(r*3000.0) + 500);
    end loop;
    xe <= -6; we <= 12; trial("rand_wide");

    -- ---- 12. the ramp again, purely so the READ-LATENCY probe below has a
    -- LIVE vector to match against.  Trial 11 lands on the all-zeros rail,
    -- and probing a latency by matching against an all-zero reference
    -- "succeeds" at every latency including zero.  The probe's own guard
    -- (element 0 must differ from element N-1) is what turned that into a
    -- visible -1 rather than a false 1.
    for i in 0 to N-1 loop
      setx(i, ((i * 131) mod 4001) - 2000);
      setw(i, 4096 + ((i * 7) mod 512) - 256);
    end loop;
    xe <= 0; we <= 12; trial("latref");

    -- ---- the READ LATENCY, MEASURED.  Present an address whose word is
    -- known to differ from the previous one and count the edges until
    -- o_rdata carries it.
    lat_v := -1;
    o_ra <= std_logic_vector(to_unsigned(0, AW));
    wait until rising_edge(clk);
    wait for 1 ns;
    o_ra <= std_logic_vector(to_unsigned(N-1, AW));
    for e in 1 to 4 loop
      wait until rising_edge(clk);
      wait for 1 ns;
      if lat_v < 0
         and signed(o_rd) = signed(g_om(N*16-1 downto (N-1)*16))
         and g_om(N*16-1 downto (N-1)*16) /= g_om(16-1 downto 0) then
        lat_v := e;
      end if;
    end loop;
    rdlat <= lat_v;

    report "RMSMUX SUMMARY live " & integer'image(nlive)
         & " rail " & integer'image(nrail)
         & " fails " & integer'image(nfail)
         & " read_latency_edges " & integer'image(lat_v) severity note;

    assert nfail = 0
      report "RMSMUX FAIL: " & integer'image(nfail) & " check(s) failed"
      severity failure;
    assert nlive >= MIN_LIVE
      report "RMSMUX FAIL: only " & integer'image(nlive)
           & " non-degenerate trials, need " & integer'image(MIN_LIVE)
           & ".  The run proves less than its pass count suggests."
      severity failure;
    assert (not CHK_LAT) or lat_v = 1
      report "RMSMUX FAIL: o_raddr -> o_rdata latency measured "
           & integer'image(lat_v) & " edges, the port contract says 1"
      severity failure;

    report "RMSMUX PASS: rmsnorm_rs_mem is bit-exact with rmsnorm and with "
         & "rmsnorm_rs, on the same cycle, over "
         & integer'image(nlive) & " non-degenerate trials" severity note;
    done_sim <= true;
    wait;
  end process;
end architecture;
