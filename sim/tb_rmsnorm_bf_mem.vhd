-- sim/tb_rmsnorm_bf_mem.vhd -- 2026-09-19.
--
-- THE IDENTITY BENCH FOR THE MEMORY-BACKED rmsnorm_bf.
--
-- WHAT IS COMPARED.  `rtl/rmsnorm_bf.vhd` (flat whole-vector ports, the unit
-- that is bit-exact with ref/rmsnorm_bf_vec.c and within 1.8e-5 of a double
-- oracle at every gate run via sim/tb_rmsnorm_bf.vhd) and
-- `rtl/rmsnorm_bf_mem.vhd` (the same arithmetic behind word-stream ports into
-- LANES-way banked block RAM) are driven with the SAME stimulus and the bench
-- asserts, per trial and with NO tolerance:
--   * every element of o_mant, DUT read out word by word against the flat
--     unit's register;
--   * o_exp;
--   * the CYCLE `done` fires on.  The memory-backed write path is
--     combinational precisely so this does not move, and this is the
--     assertion that says so rather than the comment;
--   * the READ LATENCY of o_raddr -> o_rdata, measured rather than assumed.
--
-- WHY THIS IS NOT A ROUND TRIP.  The DUT writes its input into a RAM and
-- reads its output back out of one; a bench that only checked "what went in
-- came out" would pass a packer plus a reversed decoder (the recorded `m7
-- mutant`).  The reference here is a separately maintained implementation
-- that shares no storage, no addressing and no indexing with the DUT, and its
-- own correctness against a real-valued oracle is established elsewhere.
--
-- WHICH INPUT REGIMES, AND WHY THESE.  docs/debugging/2026-09-19_the-
-- embedding-sits-below-the-norms-window.md: the composed top ran
-- rmsnorm_rs_mem, which clamps its mean square at 2^-12 and so floors rms at
-- 2^-6; the Qwen3.5-9B embedding row has rms 2^-6.35 (x_exp 19, mantissa rms
-- ~6428, absmax ~23040) and the card's XN came out 0.75x.  So the trials
-- include exactly that case (`embed`), an in-window case (`rand_mid`), an
-- x_exp < 0 case (`xexp_neg`), the eps-dominated region (`deep_eps`, where
-- the model's norm is a constant gain of 1000 and the fixed-grid unit is
-- wrong by 14x at the median), and the mean ~ eps crossover (`crossover`),
-- which is the one place the block-floating alignment needs both terms.
-- The remaining trials are rs_mem's structural ones -- saturation, a
-- single-lane max, all-zero, powers of two, a ramp, a bank-aligned ramp, a
-- varying gain and a wide random draw -- because the RAM addressing faults
-- they were written to catch are the same faults this port shape invites.
--
-- NON-DEGENERACY IS A HARD FAILURE.  Two all-zero vectors compare equal, so
-- every trial is classified and the run fails unless at least MIN_LIVE were
-- non-degenerate (a non-zero element AND two distinct element values).
--
-- CHECKS ARE COUNTED IN VARIABLES, never in signals: two `chk` calls in one
-- delta on a signal collapse to one increment (CLAUDE.md, MEASURED).
--
-- THE VERDICT LINE.  sim/regress.sh's FAIL_RE matches a bare `\bFAIL\b`, so
-- a passing summary must not contain that word; and sim/mutverdict.py wants
-- `<entity>: PASS`.  The house form `tb_rmsnorm_bf_mem: PASS -- ` satisfies
-- both (see sim/tb_fk33_seam.vhd's note).
--
-- NO HARDWARE.  Simulation only.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use ieee.math_real.all;
use work.util_pkg.all;

entity tb_rmsnorm_bf_mem is
  generic(N : positive := 128; LANES : positive := 4;
          Q : integer := 12;
          -- The number of trials that must be NON-DEGENERATE.  Fourteen
          -- trials are run; one is the all-zero input, so this is the rest.
          MIN_LIVE : natural := 13;
          -- PER-CHECK SWITCHES, for the ATTRIBUTION CONTROL.  A mutation
          -- killed by this bench proves nothing about which check earned the
          -- kill until the same mutant is re-run with the other checks off.
          CHK_VAL : boolean := true;    -- values and o_exp against rmsnorm_bf
          CHK_CYC : boolean := true;    -- `done` cycle against rmsnorm_bf
          CHK_LAT : boolean := true);   -- o_raddr -> o_rdata latency
end entity;

architecture sim of tb_rmsnorm_bf_mem is
  constant AW : natural := clog2(N);

  signal clk  : std_logic := '0';
  signal rst  : std_logic := '1';
  signal done_sim : boolean := false;

  signal start : std_logic := '0';
  signal xm, wm : std_logic_vector(N*16-1 downto 0) := (others => '0');
  signal xe, we : integer := 0;

  -- reference: the flat rmsnorm_bf
  signal g_done : std_logic;
  signal g_om   : std_logic_vector(N*16-1 downto 0);
  signal g_oe   : integer;

  -- DUT
  signal x_we, w_we : std_logic := '0';
  signal x_wa, w_wa : std_logic_vector(AW-1 downto 0) := (others => '0');
  signal x_wd, w_wd : std_logic_vector(15 downto 0) := (others => '0');
  signal d_done     : std_logic;
  signal o_ra       : std_logic_vector(AW-1 downto 0) := (others => '0');
  signal o_rd       : std_logic_vector(15 downto 0);
  signal d_oe       : integer;
  signal d_wact     : std_logic;

  -- done latches.  `done` is a ONE-CYCLE PULSE; waiting on a conjunction of
  -- the live pulses deadlocks, so each is latched and the latches are
  -- waited on.
  signal g_l, d_l : std_logic := '0';
  signal g_c, d_c : natural := 0;        -- cycles from start to done
  signal cyc : natural := 0;
  signal counting : std_logic := '0';

  signal checks : natural := 0;
  signal bad    : natural := 0;
  signal live   : natural := 0;
  signal rail   : natural := 0;
  signal rdlat  : integer := -1;         -- MEASURED o_raddr -> o_rdata edges
begin
  clk <= '0' when done_sim else not clk after 1 ns;

  ref : entity work.rmsnorm_bf
    generic map(N => N, LANES => LANES, Q => Q)
    port map(clk=>clk, rst=>rst, start=>start,
             x_mant=>xm, x_exp=>xe, w_mant=>wm, w_exp=>we,
             done=>g_done, o_mant=>g_om, o_exp=>g_oe);

  dut : entity work.rmsnorm_bf_mem
    generic map(N => N, LANES => LANES, Q => Q)
    port map(clk=>clk, rst=>rst, start=>start,
             x_we=>x_we, x_waddr=>x_wa, x_wdata=>x_wd, x_exp=>xe,
             w_we=>w_we, w_waddr=>w_wa, w_wdata=>w_wd, w_exp=>we,
             done=>d_done,
             o_raddr=>o_ra, o_rdata=>o_rd, o_exp=>d_oe,
             w_active=>d_wact);

  lat : process(clk) is
  begin
    if rising_edge(clk) then
      if start = '1' then
        g_l <= '0'; d_l <= '0';
        g_c <= 0; d_c <= 0; cyc <= 0; counting <= '1';
      else
        if counting = '1' then cyc <= cyc + 1; end if;
        if g_done = '1' and g_l = '0' then g_l <= '1'; g_c <= cyc; end if;
        if d_done = '1' and d_l = '0' then d_l <= '1'; d_c <= cyc; end if;
      end if;
    end if;
  end process;

  drv : process
    variable seed1, seed2 : positive := 7;
    variable r, r2, r3 : real;
    variable gm, dm : signed(15 downto 0);
    variable nbadel : natural;
    variable nz : natural;
    variable first_v : signed(15 downto 0);
    variable seen2 : boolean;
    variable nlive, nrail : natural := 0;
    variable nchk, nbad : natural := 0;
    variable lat_v : integer;

    procedure setx(i : natural; v : integer) is
    begin
      xm((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(v, 16));
    end procedure;
    procedure setw(i : natural; v : integer) is
    begin
      wm((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(v, 16));
    end procedure;

    -- A bell-shaped draw: the sum of three uniforms on [-a, a] has rms a.
    -- The embedding trial wants rms ~6428 with an absmax near 23040, and a
    -- flat uniform cannot give both.
    procedure draw3(i : natural; a : real) is
    begin
      uniform(seed1, seed2, r); uniform(seed1, seed2, r2); uniform(seed1, seed2, r3);
      setx(i, integer(((r - 0.5) + (r2 - 0.5) + (r3 - 0.5)) * 2.0 * a));
    end procedure;

    -- Load the DUT's banks with the SAME words the flat vector holds, one
    -- word per cycle in ascending element order, x and w in SEPARATE passes.
    -- Driven from `xm`/`wm` so the two sides can never be given different
    -- numbers by a bench bug.  The two streams are sequential and not
    -- simultaneous on purpose: driving x_waddr and w_waddr together makes a
    -- "w bank enable decoded from x_waddr" fault a literal no-op
    -- (sim/tb_rmsnorm_rs_mem.vhd records that mutant surviving).
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

    procedure trial(tag : string) is
    begin
      load;
      wait until rising_edge(clk);
      start <= '1';
      wait until rising_edge(clk);
      start <= '0';
      for t in 0 to 200000 loop
        wait until rising_edge(clk);
        exit when g_l = '1' and d_l = '1';
      end loop;
      assert g_l = '1' and d_l = '1'
        report "tb_rmsnorm_bf_mem " & tag & ": a unit never asserted done"
        severity failure;

      -- ---- the SCHEDULE claim
      if CHK_CYC then
        nchk := nchk + 1;
        if d_c /= g_c then
          report "tb_rmsnorm_bf_mem BAD " & tag & ": done cycle moved, rmsnorm_bf "
               & integer'image(g_c) & " vs rmsnorm_bf_mem " & integer'image(d_c)
            severity error;
          nbad := nbad + 1;
        end if;
      end if;

      -- ---- the exponent
      if CHK_VAL then
        nchk := nchk + 1;
        if d_oe /= g_oe then
          report "tb_rmsnorm_bf_mem BAD " & tag & ": o_exp ref " & integer'image(g_oe)
               & " dut " & integer'image(d_oe) severity error;
          nbad := nbad + 1;
        end if;
      end if;

      -- ---- the VALUES, element for element, DUT read out word by word
      nbadel := 0; nz := 0; seen2 := false;
      for i in 0 to N-1 loop
        o_ra <= std_logic_vector(to_unsigned(i, AW));
        wait until rising_edge(clk);
        -- ONE EDGE of latency, sampled at the falling edge and not with
        -- `wait for 0 ns`: the RAM's `dout` and `o_rsel` resolve one delta
        -- after the edge and `o_rdata` one delta after that, so a
        -- single-delta sample reads the PREVIOUS address (tb_rmsnorm_rs_mem
        -- hit this).
        wait for 1 ns;
        dm := signed(o_rd);
        gm := signed(g_om((i+1)*16-1 downto i*16));
        if CHK_VAL then
          nchk := nchk + 1;
          if dm /= gm then
            if nbadel < 4 then
              report "tb_rmsnorm_bf_mem BAD " & tag & " i " & integer'image(i)
                   & " ref " & integer'image(to_integer(gm))
                   & " dut " & integer'image(to_integer(dm)) severity error;
            end if;
            nbadel := nbadel + 1; nbad := nbad + 1;
          end if;
        end if;
        if gm /= 0 then nz := nz + 1; end if;
        if i = 0 then first_v := gm;
        elsif gm /= first_v then seen2 := true; end if;
      end loop;

      -- ---- NON-DEGENERACY
      if nz > 0 and seen2 then
        nlive := nlive + 1;
        report "tb_rmsnorm_bf_mem live " & tag & " x_exp " & integer'image(xe)
             & " o_exp " & integer'image(g_oe)
             & " nonzero " & integer'image(nz) & "/" & integer'image(N)
             & " done_cyc " & integer'image(d_c)
             & " badel " & integer'image(nbadel) severity note;
      else
        nrail := nrail + 1;
        report "tb_rmsnorm_bf_mem RAIL " & tag & ": output is all-zero or constant, "
             & "so this trial proves nothing about the values" severity note;
      end if;
      live <= nlive; rail <= nrail; checks <= nchk; bad <= nbad;
    end procedure;
  begin
    rst <= '1';
    for i in 0 to 9 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);

    -- ---- 1. IN-WINDOW random: rms(x_real) ~ 577 * 2^0, inside [2^-6, 2^12]
    for i in 0 to N-1 loop
      uniform(seed1, seed2, r); setx(i, integer(r*2000.0) - 1000);
      uniform(seed1, seed2, r); setw(i, integer(r*8000.0) + 1000);
    end loop;
    xe <= 0; we <= 12;
    trial("rand_mid");

    -- ---- 2. THE EMBEDDING CASE.  x_exp 19, mantissa rms ~6428, absmax
    -- ~19000..23000, gain near 1.0 at w_exp 12 with per-element variation.
    -- rms(x_real) = 6428 / 2^19 = 2^-6.35, which rmsnorm_rs_mem clamps to
    -- 2^-6 and this unit does not.
    for i in 0 to N-1 loop
      draw3(i, 6428.0);
      uniform(seed1, seed2, r); setw(i, 4096 + integer(r*1024.0) - 512);
    end loop;
    xe <= 19; we <= 12;
    trial("embed");

    -- ---- 3. x_exp < 0, through the other S_INV3 shift branch
    for i in 0 to N-1 loop
      uniform(seed1, seed2, r); setx(i, integer(r*600.0) - 300);
      uniform(seed1, seed2, r); setw(i, integer(r*6000.0) + 2000);
    end loop;
    xe <= -4; we <= 12;
    trial("xexp_neg");

    -- ---- 4. deep in the eps-dominated region: rms(x_real) = 6428 * 2^-40
    -- ~ 2^-27.4, inside the model's MEASURED range [2^-29.63, 2^-0.54] and
    -- where the norm is a constant gain of 1/sqrt(eps) = 1000.
    for i in 0 to N-1 loop
      draw3(i, 6428.0);
      uniform(seed1, seed2, r); setw(i, 4096 + integer(r*1024.0) - 512);
    end loop;
    xe <= 40; we <= 12;
    trial("deep_eps");

    -- ---- 5. the crossover, mean ~ eps: rms 1e-3 is 2^-9.97, and
    -- 6428 * 2^-23 = 2^-10.35.  Both alignment terms survive here.
    for i in 0 to N-1 loop
      draw3(i, 6428.0);
      uniform(seed1, seed2, r); setw(i, 4096 + integer(r*1024.0) - 512);
    end loop;
    xe <= 23; we <= 12;
    trial("crossover");

    -- ---- 6. saturated inputs, which is what licenses the s48 narrowing.
    -- x_exp 15 puts rms(x_real) at exactly 1.0.  (tb_rmsnorm_rs_mem runs
    -- this at x_exp -12, rms 2^27, which is above the model's range and
    -- where inv32 = 2^12 / 2^27 underflows the output grid to zero in ANY
    -- variant -- MEASURED here as an all-zero rail before the exponent was
    -- moved.  A rail trial proves nothing about the values.)
    for i in 0 to N-1 loop
      if i mod 2 = 0 then setx(i, 32767); else setx(i, -32768); end if;
      setw(i, 4096);
    end loop;
    xe <= 15; we <= 12;
    trial("sat");

    -- ---- 7. one large element against zeros: max|raw| comes from ONE lane
    for i in 0 to N-1 loop setx(i, 0); setw(i, 4096); end loop;
    setx(N/2 + 1, 30000);
    xe <= 0; we <= 12;
    trial("one_big");

    -- ---- 8. all-zero input: the S = 0 branch.  Lands on the rail by
    -- construction; kept because the SCHEDULE and o_exp checks still bite.
    for i in 0 to N-1 loop setx(i, 0); setw(i, 4096); end loop;
    xe <= 0; we <= 12;
    trial("all_zero");

    -- ---- 9. powers of two: max|raw| lands exactly on a bit boundary
    for i in 0 to N-1 loop
      setx(i, 2**((i mod 10) + 3));
      setw(i, 4096);
    end loop;
    xe <= 0; we <= 12; trial("pow2");

    -- ---- 10. a RAMP: every element distinct and ordered, so any reordering
    -- of the readout is visible element for element
    for i in 0 to N-1 loop
      setx(i, ((i * 131) mod 4001) - 2000);
      setw(i, 4096 + ((i * 7) mod 512) - 256);
    end loop;
    xe <= 0; we <= 12; trial("ramp");

    -- ---- 11. a BANK-ALIGNED ramp: element i and element i+LANES differ, so
    -- a bank/offset swap permutes them visibly
    for i in 0 to N-1 loop
      setx(i, (i mod 2048) - 1024);
      setw(i, 4096);
    end loop;
    xe <= 0; we <= 12; trial("bankramp");

    -- ---- 12. gain varying per element, so a w-side bank fault is not
    -- masked by a constant gain
    for i in 0 to N-1 loop
      uniform(seed1, seed2, r); setx(i, integer(r*1200.0) - 600);
      setw(i, 1024 + (i mod 64) * 96);
    end loop;
    xe <= 0; we <= 12; trial("wvary");

    -- ---- 13. wide random draw, mantissa rms ~5774, at x_exp 14 so
    -- rms(x_real) ~ 2^-1.5, near the top of the model's measured range.
    -- (At rs_mem's x_exp -6 this is rms 2^18.5 and an all-zero rail, for
    -- the reason trial 6 gives.)
    for i in 0 to N-1 loop
      uniform(seed1, seed2, r); setx(i, integer(r*20000.0) - 10000);
      uniform(seed1, seed2, r); setw(i, integer(r*3000.0) + 500);
    end loop;
    xe <= 14; we <= 12; trial("rand_wide");

    -- ---- 14. the ramp again, so the READ-LATENCY probe has a LIVE vector
    -- whose element 0 differs from element N-1
    for i in 0 to N-1 loop
      setx(i, ((i * 131) mod 4001) - 2000);
      setw(i, 4096 + ((i * 7) mod 512) - 256);
    end loop;
    xe <= 0; we <= 12; trial("latref");

    -- ---- the READ LATENCY, MEASURED
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
    if CHK_LAT then
      nchk := nchk + 1;
      if lat_v /= 1 then
        report "tb_rmsnorm_bf_mem BAD: o_raddr -> o_rdata latency measured "
             & integer'image(lat_v) & " edges, the port contract says 1"
          severity error;
        nbad := nbad + 1;
      end if;
    end if;

    -- ---- non-degeneracy gate
    nchk := nchk + 1;
    if nlive < MIN_LIVE then
      report "tb_rmsnorm_bf_mem BAD: only " & integer'image(nlive)
           & " non-degenerate trials, need " & integer'image(MIN_LIVE)
           & ".  The run proves less than its pass count suggests."
        severity error;
      nbad := nbad + 1;
    end if;
    checks <= nchk; bad <= nbad;

    report "tb_rmsnorm_bf_mem: checks=" & integer'image(nchk)
         & " bad=" & integer'image(nbad)
         & " live=" & integer'image(nlive)
         & " rail=" & integer'image(nrail)
         & " read_latency_edges=" & integer'image(lat_v) severity note;

    if nbad = 0 then
      report "tb_rmsnorm_bf_mem: PASS -- rmsnorm_bf_mem is bit-exact with "
           & "rmsnorm_bf in every o_mant element and o_exp, on the same "
           & "done cycle, over " & integer'image(nlive)
           & " non-degenerate trials including the x_exp 19 embedding case"
        severity note;
    else
      report "tb_rmsnorm_bf_mem: FAIL -- " & integer'image(nbad)
           & " of " & integer'image(nchk) & " checks bad" severity error;
    end if;
    assert nbad = 0
      report "tb_rmsnorm_bf_mem: FAIL -- see above" severity failure;

    done_sim <= true;
    wait;
  end process;
end architecture;
