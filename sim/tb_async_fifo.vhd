-- sim/tb_async_fifo.vhd -- a DIRECT bench for rtl/async_fifo.vhd, the clock
-- domain crossing in the weight path that feeds the whole INT4 array.
--
-- WHY THIS FILE EXISTS.  Until 2026-08-29 `async_fifo` and `axi_rd_fsm` had no
-- dedicated bench of any kind: both were reached ONLY through
-- rtl/axi_rd_port.vhd, and every gate row that instantiates axi_rd_port does so
-- at DUAL_CLK = false, which selects rtl/stream_fifo.vhd and leaves this file
-- entirely unelaborated.  MEASURED at HEAD: the only elaboration of
-- `async_fifo` anywhere in the gate is sim/tb_matvec_fk33_desc.vhd, and that
-- row runs at its `DUAL` generic's default of FALSE -- the dual-clock
-- configuration is a MANUAL run (sim/regress.sh's tb_args comment says so).
-- So the CDC that the FK33 build depends on was, at gate time, never clocked
-- by two clocks at all.
--
-- WHAT A FIFO BENCH HAS TO DO THAT A PUSH/POP TEST DOES NOT
-- ---------------------------------------------------------------------------
-- A bench that pushes and pops at one clock ratio proves very little, and this
-- FIFO in particular has had its FLAG LOGIC RESTRUCTURED FOR TIMING: the
-- header of rtl/async_fifo.vhd records that `w_ready` and `w_level` were both
-- pulled out of the combinational gray-decode-and-subtract on 2026-08-28,
-- buying +123.88 MHz, and that `full_r` is now computed ONE CYCLE AHEAD and
-- includes the write being performed in the cycle it is computed.  An
-- off-by-one in a restructured full flag is invisible to any bench that never
-- fills the FIFO.  So this bench:
--
--   * runs EIGHT concurrent instances at eight clock ratios, including
--     write-fast, read-fast, exactly equal with COINCIDENT EDGES, equal with a
--     quarter-period phase offset, a nearly-equal pair whose edges slide
--     through each other (7000 ps against 6999 ps), and two ratios that are
--     not integer multiples in either direction;
--   * DELIBERATELY FILLS each instance to DEPTH and holds it there, and
--     asserts as a COVERAGE property that it did -- a run in which the FIFO
--     never became full is reported as a FAILURE, not as a pass;
--   * drains each instance to empty and asserts it observed the empty
--     boundary on the read interface as well;
--   * runs the four-phase CLEAR handshake with residue resident, and checks
--     the residue is discarded and the post-clear sequence starts at its own
--     first word;
--   * applies reset in the WRITE domain only, in the READ domain only, and in
--     the skewed pattern rtl/axi_rd_port.vhd actually produces (`rrst` is the
--     core reset, `wrst` is that reset through two aclk flops), and checks
--     recovery in each case;
--   * runs one instance with the writer THROTTLED against `w_level` exactly
--     the way rtl/axi_rd_fsm.vhd throttles AR issue, which is the only
--     configuration in which an INFLATED `w_level` can be detected at all.
--
-- THE ORACLE.  The write side writes a strictly increasing 32-bit counter and
-- the read side checks the value it receives against its own independently
-- maintained counter.  That is a value-and-ORDER oracle: a dropped beat, a
-- duplicated beat and a reordered beat are three different, individually
-- reported diagnostics, and the final quiescent check that `nr = nw` catches a
-- loss the ordering check cannot (a beat lost at the very end).
--
-- WHAT THIS BENCH CANNOT SEE -- stated here so it is not mistaken for coverage
-- ---------------------------------------------------------------------------
--   * THE GRAY CODING ITSELF.  Gray coding exists so that a pointer sampled by
--     a foreign clock during a transition resolves to either the old value or
--     the new one and never to a third.  RTL simulation samples signals
--     atomically, so a BINARY pointer crosses just as cleanly here.  MEASURED
--     in sim/mutate_async_fifo.sh: replacing BOTH bin2gray and gray2bin with
--     the identity SURVIVES this bench, and it survives any functional bench
--     that could be written.  Closing that needs Vivado `report_cdc` or an
--     ASYNC_REG/skew-injection model, not simulation.
--   * THE NUMBER OF SYNCHRONISER STAGES, for the same reason: 2FF versus 1FF
--     is an MTBF statement, not a functional one.  Also measured as a survivor.
--   * METASTABILITY, obviously.
--   * GHDL 1.0.0 (mcode) has NO external-name support -- MEASURED, it raises
--     `translate_name: cannot handle IIR_KIND_EXTERNAL_SIGNAL_NAME` and a
--     GHDL bug box -- so the internal pointers cannot be watched from here
--     even to check the single-bit-change property directly.
--
-- BOTH ARMS OF `FAST_POP`, added 2026-09-20 by TRACK POPCOVER
-- ---------------------------------------------------------------------------
-- `FAST_POP` selects the read-issue condition in rtl/async_fifo.vhd's `do_rd`.
-- The card sets it TRUE (hw/fk33/rtl/fk33_engine.vhd:1356, threaded down
-- through matvec_int4 -> matvec_int4_desc_axi -> axi_rd_port); every RTL
-- default is FALSE.  MEASURED 2026-09-20 by TRACK SHAPEAUDIT
-- (docs/debugging/2026-09-20_the-shape-a-bench-runs-at.md 5.2): an off-by-two
-- planted in the FAST_POP arm alone passed FIVE benches INCLUDING THIS ONE,
-- because this file ran the DUT at the generic's default and never reached
-- the arm the shipping bitstream runs.
--
-- So every ratio below is instantiated TWICE, once per arm, from one shared
-- `af_ratios` block, with the SAME SEEDS.  That is the equivalence oracle and
-- it is not a round trip: the write side emits a strictly increasing counter
-- and the read side compares against its own independently maintained
-- counter, so "the same values in the same order come out of both arms" is
-- checked beat by beat against a number the FIFO never supplied.
--
-- AND THE ARMS MUST ALSO BE TOLD APART, or the lever is only proved harmless
-- and never proved present.  `cadence_probe` stocks the FIFO, STOPS the
-- writer, opens the reader flat out and times the drain in read cycles per
-- beat.  DERIVED from the two conditions, and MEASURED below: the shipping
-- arm settles into pop/pop/idle and takes 3 read cycles per 2 beats; the
-- FAST_POP arm takes 1 per beat.  The check is two-sided -- the fast arm
-- FAILS if it is slow, and the slow arm FAILS if it is fast -- so a
-- FAST_POP that is not threaded to the DUT and a FAST_POP that is wired on
-- unconditionally are BOTH caught, and neither is visible to the value
-- oracle.  It is skipped below DEPTH 16, where the resident beats do not
-- separate the two cadences; `tiny` (DEPTH 4) is therefore covered for
-- values and not for cadence.
--
-- Teeth: sim/mutate_async_fifo.sh, class POP.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- ===========================================================================
-- ONE CONFIGURATION: its own two clocks, its own stimulus programme, its own
-- checker.  The top level below instantiates several of these concurrently,
-- the same shape sim/tb_weight_streamer.vhd uses for its two geometries.
-- ===========================================================================
entity af_case is
  generic(
    NAME       : string   := "case";
    W          : positive := 32;
    DEPTH      : positive := 16;
    OUT_MARGIN : natural  := 3;
    -- Clock periods in PICOSECONDS.  Integers, not `time` and not `real`:
    -- ghdl-mcode cannot override a `real` generic (recorded in CLAUDE.md), and
    -- ps resolution is what lets 7000/6999 be expressed.
    WPER_PS    : positive := 5000;
    RPER_PS    : positive := 5000;
    RPHASE_PS  : natural  := 0;
    SEED       : positive := 1;
    -- Beats each traffic phase must move before the phase ends.
    NBEATS     : positive := 160;
    -- Writer offers only while `w_level < DEPTH`, which is exactly
    -- rtl/axi_rd_fsm.vhd's AR throttle with promised = 0.  In this mode an
    -- INFLATED w_level shows up as a throughput failure.
    THROTTLE   : boolean  := false;
    -- The DUT's read-issue arm.  The CARD RUNS true; every RTL default is
    -- false.  See the FAST_POP block in the header.
    FAST_POP   : boolean  := false;
    -- The cadence check only.  false is the ATTRIBUTION CONTROL: it leaves
    -- both arms instantiated and every value, level, clear, reset and
    -- coverage property in place, and removes ONLY the check this track
    -- added, so a mutation's kill can be attributed to one or the other.
    CADENCE    : boolean  := true
  );
  port(
    done : out boolean := false;
    errs : out integer := 0
  );
end entity;

architecture beh of af_case is
  constant WPER : time := WPER_PS * 1 ps;
  constant RPER : time := RPER_PS * 1 ps;

  signal wclk, rclk : std_logic := '0';
  signal wrst       : std_logic := '1';
  signal rrst       : std_logic := '1';

  signal w_valid : std_logic := '0';
  signal w_ready : std_logic;
  signal w_data  : std_logic_vector(W-1 downto 0) := (others => '0');
  signal w_level : integer range 0 to 2*DEPTH + OUT_MARGIN;
  signal clr     : std_logic := '0';
  signal clr_done: std_logic;

  signal q_valid : std_logic;
  signal q_ready : std_logic := '0';
  signal q_data  : std_logic_vector(W-1 downto 0);

  signal running : boolean := true;

  -- ---------------------------------------------------------------- control
  -- Densities are 0..16 and are compared against an LFSR nibble, so 16 is
  -- "offer every cycle" and 1 is "offer one cycle in sixteen".
  signal w_run, r_run : boolean := false;
  signal w_dens, r_dens : integer range 0 to 16 := 16;
  signal chk_en : boolean := true;    -- data checking on (off across a
                                      -- deliberately desynchronising reset)
  signal reload : boolean := false;   -- while true, a STOPPED side reloads its
                                      -- sequence counter from seq_val
  signal seq_val : integer := 0;

  -- ------------------------------------------------------------- observation
  signal nw, nr : integer := 0;       -- accepted / consumed, THIS segment
  -- Cumulative, never reloaded: the segment counters above are reset at
  -- every rebase, because a clear or a reset legitimately destroys beats and
  -- an accounting check that spanned one would be checking nothing.
  signal nw_tot, nr_tot : integer := 0;
  signal nerr   : integer := 0;       -- data / ordering errors (read domain)
  signal nlvl   : integer := 0;       -- w_level violations (write domain)
  signal nocc   : integer := 0;       -- occupancy > DEPTH  (write domain)
  signal ncov   : integer := 0;       -- coverage failures (sequencer)
  signal nclr   : integer := 0;       -- beats accepted during a clear
  signal max_occ  : integer := 0;
  signal min_slack: integer := 1000000;
  signal n_wstall : integer := 0;     -- cycles offering into a full FIFO
  signal n_rstall : integer := 0;     -- cycles ready with an empty FIFO
  signal w_idle   : boolean := true;

  -- Free-running read-domain cycle count, and the cadence the probe measured.
  -- `cad_cyc` starts NEGATIVE so "the probe never ran" and "the probe measured
  -- zero" are different states in the final report line.
  signal rcyc     : integer := 0;
  signal cad_cyc  : integer := -1;
  -- Beats timed by the probe, after the first.  10 needs 11 beats resident,
  -- against the 16 the THROTTLED case reaches and the 18 every other DEPTH-16
  -- ratio reaches, so the probe is never supply-limited.  DERIVED cadences:
  -- 10 read cycles with FAST_POP, 15 without.
  constant CAD_N  : integer := 10;
begin
  -- ================================================================= clocks
  wclkp : process
  begin
    while running loop
      wclk <= '0'; wait for WPER/2;
      wclk <= '1'; wait for WPER - WPER/2;
    end loop;
    wclk <= '0';
    wait;
  end process;

  rclkp : process
  begin
    if RPHASE_PS > 0 then wait for RPHASE_PS * 1 ps; end if;
    while running loop
      rclk <= '0'; wait for RPER/2;
      rclk <= '1'; wait for RPER - RPER/2;
    end loop;
    rclk <= '0';
    wait;
  end process;

  -- ==================================================================== DUT
  dut : entity work.async_fifo
    generic map(W => W, DEPTH => DEPTH, OUT_MARGIN => OUT_MARGIN,
                FAST_POP => FAST_POP)
    port map(wclk => wclk, wrst => wrst,
             w_valid => w_valid, w_data => w_data, w_ready => w_ready,
             w_level => w_level, clr => clr, clr_done => clr_done,
             rclk => rclk, rrst => rrst,
             q_valid => q_valid, q_data => q_data, q_ready => q_ready);

  -- ================================================================= writer
  -- Proper stream semantics: once `w_valid` is raised it is HELD until
  -- `w_ready`.  That is not a stylistic choice -- it is the only way the full
  -- boundary is ever presented to the DUT, and a writer that withdraws its
  -- offer when refused never tests the flag at all.
  wproc : process(wclk)
    variable lf : unsigned(15 downto 0) := to_unsigned((SEED*7919 + 13) mod 65536, 16);
    variable wv : integer := 0;             -- next value to write
    variable off : boolean := false;        -- an offer is outstanding
  begin
    if rising_edge(wclk) then
      lf := lf(14 downto 0) & (lf(15) xor lf(13) xor lf(12) xor lf(10));

      -- The handshake is judged FIRST and unconditionally.  A beat accepted on
      -- the same edge the writer is stopped is still a beat, and counting it
      -- inside the `w_run` arm silently loses it from the accounting.
      if off and w_valid = '1' and w_ready = '1' then
        nw <= nw + 1; nw_tot <= nw_tot + 1;
        wv := wv + 1;
        off := false;
        w_valid <= '0';
      elsif off and w_run and clr = '0' then
        -- The FULL boundary, on the interface -- and `clr = '0'` is load
        -- bearing.  w_ready is also low for the whole of a clear, and counting
        -- that as a full-flag stall makes the THROTTLED case report a throttle
        -- failure it did not have.  MEASURED: 6 spurious stalls, all inside
        -- phase 4's clear, before this term was added.
        n_wstall <= n_wstall + 1;
      end if;

      if not w_run then
        -- WITHDRAW an offer the FIFO never took.  Holding it would be stricter
        -- stream semantics, but the FIFO can be FULL with the reader stopped,
        -- so a held offer is one that can never complete and `stop_both` would
        -- wait for it forever.  That is trap 6.1 in the write-up: the first
        -- version of this file hung seven of its eight cases on exactly this,
        -- and the one case that finished was the THROTTLED one, which by
        -- construction never fills.  Withdrawing loses nothing: no handshake
        -- happened, so no beat is in flight.
        off := false;
        w_valid <= '0';
        if reload then wv := seq_val; nw <= 0; end if;
        w_idle <= true;
      else
        w_idle <= false;
        if not off then
          if to_integer(lf(3 downto 0)) < w_dens
             and (not THROTTLE or w_level < DEPTH) then
            off := true;
            w_valid <= '1';
            w_data  <= std_logic_vector(to_signed(wv, W));
          end if;
        end if;
      end if;
    end if;
  end process;

  -- ================================================================= reader
  rproc : process(rclk)
    variable lf : unsigned(15 downto 0) := to_unsigned((SEED*104729 + 7) mod 65536, 16);
    variable rv : integer := 0;             -- next value expected
    variable g  : integer;
  begin
    if rising_edge(rclk) then
      lf := lf(14 downto 0) & (lf(15) xor lf(13) xor lf(12) xor lf(10));
      rcyc <= rcyc + 1;

      -- Judged FIRST and unconditionally, for the same reason as the writer.
      if q_ready = '1' and q_valid = '1' then
        g := to_integer(signed(q_data));
        if chk_en and g /= rv then
          if nerr < 8 then
            if g > rv then
              report NAME & ": BEAT " & integer'image(nr) & " got " &
                     integer'image(g) & " want " & integer'image(rv) &
                     " -- BEATS WERE DROPPED" severity error;
            else
              report NAME & ": BEAT " & integer'image(nr) & " got " &
                     integer'image(g) & " want " & integer'image(rv) &
                     " -- A BEAT WAS DUPLICATED OR REORDERED" severity error;
            end if;
          end if;
          nerr <= nerr + 1;
          rv := g;                 -- resynchronise: one loss stays one error
        end if;
        nr <= nr + 1; nr_tot <= nr_tot + 1;
        rv := rv + 1;
      elsif q_ready = '1' and q_valid = '0' and r_run then
        n_rstall <= n_rstall + 1;  -- the empty boundary, on the interface
      end if;

      if not r_run then
        if reload then rv := seq_val; nr <= 0; end if;
        q_ready <= '0';
      else
        if to_integer(lf(3 downto 0)) < r_dens then
          q_ready <= '1';
        else
          q_ready <= '0';
        end if;
      end if;
    end if;
  end process;

  -- ================================================ write-domain properties
  -- Sampled ONE DELTA AFTER the write edge, deliberately.  `nr` lives in the
  -- read domain, and reading it AT the edge returns its pre-edge value, which
  -- over-states the occupancy by one beat -- and the guarantee
  -- `w_level >= true occupancy` holds with EXACTLY zero slack (see the
  -- REGISTERED LEVEL block in rtl/async_fifo.vhd), so a one-beat over-statement
  -- would produce a false failure on honest RTL.  This is trap 6.2 in the
  -- write-up.
  lvlp : process
    variable occ : integer;
  begin
    loop
      wait until rising_edge(wclk);
      wait for 0 ns;
      exit when not running;
      if wrst = '0' and clr = '0' and clr_done = '0' and not reload then
        occ := nw - nr;
        if occ > max_occ then max_occ <= occ; end if;
        -- The FIFO's real capacity is the memory PLUS the read side's output
        -- stage, which holds OUT_MARGIN more beats that have already retired
        -- rp but have not been consumed.  DEPTH alone is the wrong bound and
        -- fires on correct RTL; this is trap 6.3 in the write-up.
        if occ > DEPTH + OUT_MARGIN then
          if nocc < 4 then
            report NAME & ": OCCUPANCY " & integer'image(occ) &
                   " EXCEEDS CAPACITY " & integer'image(DEPTH + OUT_MARGIN)
              severity error;
          end if;
          nocc <= nocc + 1;
        end if;
        -- The safety guarantee the AR throttle rests on.  Never optimistic.
        if w_level < occ then
          if nlvl < 4 then
            report NAME & ": w_level " & integer'image(w_level) &
                   " UNDER-STATES occupancy " & integer'image(occ) &
                   " -- the throttle would overrun the FIFO" severity error;
          end if;
          nlvl <= nlvl + 1;
        end if;
        if w_level - occ < min_slack then min_slack <= w_level - occ; end if;
      end if;
    end loop;
    wait;
  end process;

  -- A beat accepted while `clr` is high is a beat that is about to be thrown
  -- away by the parked pointer, so `w_ready` must be low for the whole clear.
  -- rtl/async_fifo.vhd keeps `clr` COMBINATIONAL in w_ready specifically so
  -- that this deassertion is never late; without a writer that is still
  -- offering when the clear arrives, nothing tests it.
  clrp : process(wclk)
  begin
    if rising_edge(wclk) then
      if clr = '1' and w_valid = '1' and w_ready = '1' then
        if nclr < 4 then
          report NAME & ": A BEAT WAS ACCEPTED DURING THE CLEAR and will be " &
                 "discarded -- w_ready is high with clr high" severity error;
        end if;
        nclr <= nclr + 1;
      end if;
    end if;
  end process;

  -- ============================================================== sequencer
  seq : process
    variable target : integer;
    variable cov : integer := 0;
    variable t0 : time;

    -- Move traffic until `n` more beats have been CONSUMED, with a wall of
    -- simulated time as a backstop so a stalled DUT is a failure rather than
    -- a hang.
    procedure move(constant n : integer; constant wd, rd : integer;
                   constant tag : string) is
      variable goal : integer;
    begin
      goal := nr + n;
      w_dens <= wd; r_dens <= rd;
      w_run <= true; r_run <= true;
      t0 := now;
      while nr < goal loop
        wait until rising_edge(rclk);
        if now - t0 > (n + 64) * 64 * RPER then
          report NAME & ": " & tag & " STALLED -- " & integer'image(nr) &
                 " of " & integer'image(goal) & " beats consumed"
            severity error;
          cov := cov + 1;
          exit;
        end if;
      end loop;
    end procedure;

    procedure stop_both is
    begin
      w_run <= false; r_run <= false;
      wait until rising_edge(wclk);
      while not w_idle loop wait until rising_edge(wclk); end loop;
      wait until rising_edge(rclk);
      wait until rising_edge(wclk);
    end procedure;

    -- All four phases of the clear, and the caller's obligation to wait for
    -- clr_done to FALL as well as to rise.
    procedure do_clear is
      variable tt : time;
    begin
      -- The segment counters `nw`/`nr` are about to disagree by exactly the
      -- residue the clear destroys, so the write-domain property checker is
      -- parked from here until `rebase` re-zeroes both.  Without this the
      -- checker reports `w_level UNDER-STATES occupancy` on CORRECT RTL for
      -- the whole window -- trap 6.4 in the write-up, and it is the shape of
      -- false failure that gets a good defect report thrown away.
      reload <= true;
      wait until rising_edge(wclk);
      clr <= '1';
      tt := now;
      while clr_done = '0' loop
        wait until rising_edge(wclk);
        if now - tt > 512 * WPER then
          report NAME & ": clr_done NEVER ROSE" severity error;
          cov := cov + 1; exit;
        end if;
      end loop;
      -- Phase 3.  The writer is stopped HERE and not before, so it is still
      -- offering through phases 1-2 and `w_ready`'s combinational `clr` term
      -- is under test.  Stopping it before dropping `clr` is what keeps the
      -- emptiness check below a statement about RESIDUE rather than about
      -- beats written after the clear.
      w_run <= false; r_run <= false;
      wait until rising_edge(wclk);
      clr <= '0';
      tt := now;
      while clr_done = '1' loop
        wait until rising_edge(wclk);
        if now - tt > 512 * WPER then
          report NAME & ": clr_done NEVER FELL" severity error;
          cov := cov + 1; exit;
        end if;
      end loop;
      -- Phase 4 is not over until the read side has released.  Give it the
      -- synchroniser depth it is entitled to, then check the FIFO is empty.
      for i in 0 to 7 loop wait until rising_edge(rclk); end loop;
      if q_valid /= '0' then
        report NAME & ": FIFO NOT EMPTY AFTER THE CLEAR -- residue survived"
          severity error;
        cov := cov + 1;
      end if;
    end procedure;

    -- THE READ-ISSUE CADENCE -- the one observable `FAST_POP` changes.
    --
    -- Stock the FIFO with the reader held off, STOP the writer and wait for it
    -- to be idle, then open the reader flat out and time the drain.  With the
    -- writer stopped the window contains NOTHING but the read side's own
    -- issue condition: no write clock, no clock ratio, no LFSR density.  The
    -- timer starts at the FIRST beat consumed, so the reader's start-up
    -- latency and the output stage's fill are outside it.
    --
    -- DERIVED.  With `q_ready` held high and the FIFO non-empty, the shipping
    -- arm's `(ocnt + inflight) < 2` settles into a period-3 orbit with two
    -- pops in it (the beat leaving the stage this edge is still counted as
    -- resident, so no read is issued on the third cycle), and the FAST_POP
    -- arm's `after_e < 2` -- where after_e IS the post-edge occupancy -- holds
    -- ocnt at 1 with one read always in flight and pops on every cycle.  So
    -- CAD_N beats after the first take 1.5*CAD_N cycles and CAD_N cycles
    -- respectively: 15 against 10.  The thresholds below sit in the five-cycle
    -- gap between them, one cycle of slack on the fast side and two on the
    -- slow side.
    --
    -- Skipped below DEPTH 16: at DEPTH 4 the FIFO holds 6 beats, CAD_N has to
    -- fall to 3, and 3 against 4.5 cycles does not separate the two arms by
    -- more than the start-up jitter.  `tiny` is a VALUE row, not a cadence row.
    procedure cadence_probe is
      variable c0, n0, cyc : integer;
    begin
      if DEPTH < 16 then return; end if;

      -- stock it, reader held off (r_run stays TRUE at density 0, the same
      -- shape phase 4 uses, so the reader's `reload` path is not entered)
      w_dens <= 16; r_dens <= 0; w_run <= true; r_run <= true;
      for i in 0 to 6*DEPTH loop wait until rising_edge(wclk); end loop;
      w_run <= false;
      wait until rising_edge(wclk);
      while not w_idle loop wait until rising_edge(wclk); end loop;
      for i in 0 to 7 loop wait until rising_edge(rclk); end loop;

      -- open the reader and wait for the FIRST beat
      r_dens <= 16;
      n0 := nr;
      c0 := 0;
      loop
        wait until rising_edge(rclk);
        wait for 0 ns;                    -- see lvlp: nr updates one delta on
        exit when nr > n0;
        c0 := c0 + 1;
        if c0 > 64 then
          report NAME & ": CADENCE -- the drain never started, " &
                 integer'image(nw - nr) & " beats resident" severity error;
          cov := cov + 1;
          return;
        end if;
      end loop;

      -- time CAD_N further beats
      c0 := rcyc; n0 := nr;
      loop
        wait until rising_edge(rclk);
        wait for 0 ns;
        exit when nr >= n0 + CAD_N;
        if rcyc - c0 > 8 * CAD_N then
          report NAME & ": CADENCE -- the drain STALLED after " &
                 integer'image(nr - n0) & " of " & integer'image(CAD_N) &
                 " beats" severity error;
          cov := cov + 1;
          return;
        end if;
      end loop;
      cyc := rcyc - c0;
      cad_cyc <= cyc;

      if CADENCE then
        if FAST_POP then
          -- The lever must be PRESENT.  This fires if FAST_POP is not threaded
          -- to the DUT at all, or if its arm is narrowed.
          if cyc > CAD_N + 1 then
            report NAME & ": CADENCE -- FAST_POP took " & integer'image(cyc) &
                   " read cycles for " & integer'image(CAD_N) & " beats, want " &
                   "at most " & integer'image(CAD_N + 1) & " -- the fast " &
                   "read-issue arm is not in the netlist" severity error;
            cov := cov + 1;
          end if;
        else
          -- And the lever must be ABSENT when it is not asked for.  This fires
          -- if the fast arm is taken unconditionally.
          if cyc < CAD_N + 3 then
            report NAME & ": CADENCE -- the shipping arm took " &
                   integer'image(cyc) & " read cycles for " &
                   integer'image(CAD_N) & " beats, want at least " &
                   integer'image(CAD_N + 3) & " -- the FAST_POP arm is " &
                   "being taken with FAST_POP false" severity error;
            cov := cov + 1;
          end if;
        end if;
      end if;
    end procedure;

    -- Restart both sides on a fresh sequence base, so the FIRST beat after a
    -- clear or a reset is a value that CANNOT be residue.
    procedure rebase(constant v : integer) is
    begin
      seq_val <= v; reload <= true;
      wait until rising_edge(wclk);
      wait until rising_edge(rclk);
      wait until rising_edge(wclk);
      reload <= false;
      chk_en <= true;
      wait until rising_edge(wclk);
    end procedure;
  begin
    -- ---------------------------------------------------------- power on
    wrst <= '1'; rrst <= '1';
    for i in 0 to 7 loop wait until rising_edge(wclk); end loop;
    for i in 0 to 7 loop wait until rising_edge(rclk); end loop;
    wait until rising_edge(wclk); wrst <= '0';
    wait until rising_edge(rclk); rrst <= '0';
    for i in 0 to 3 loop wait until rising_edge(wclk); end loop;

    if q_valid /= '0' then
      report NAME & ": q_valid HIGH OUT OF RESET" severity error;
      cov := cov + 1;
    end if;

    -- ---- PHASE 1  fill: write flat out, read one cycle in sixteen -------
    move(NBEATS/4, 16, 1, "phase1 fill");

    -- ---- PHASE 2  drain: write rarely, read flat out --------------------
    move(NBEATS/2, 1, 16, "phase2 drain");

    -- ---- PHASE 3  mixed --------------------------------------------------
    move(NBEATS, 9, 7, "phase3 mixed");

    -- ---- PHASE 4  clear WITH RESIDUE RESIDENT ---------------------------
    -- Leave the FIFO part full on purpose: a clear of an empty FIFO tests
    -- nothing, and 7.7's whole reason for the flush is the padding beats that
    -- are still resident when a job ends.
    w_dens <= 16; r_dens <= 0; w_run <= true; r_run <= true;
    for i in 0 to 4*DEPTH loop wait until rising_edge(wclk); end loop;
    if nw - nr = 0 then
      report NAME & ": NO RESIDUE BEFORE THE CLEAR -- the clear tested nothing"
        severity error;
      cov := cov + 1;
    end if;
    -- NOT quiesced first, on purpose: the writer is still offering when `clr`
    -- goes high, which is the only condition under which the `clr` term in
    -- `w_ready` means anything.
    do_clear;
    stop_both;
    rebase(1000000);
    move(NBEATS/2, 12, 12, "phase5 after clear");

    -- ---- PHASE 5b  A CLEAR ENTERED WITH A READ IN FLIGHT ----------------
    -- Phase 4 stocks the FIFO with the reader STOPPED, so the output stage is
    -- saturated, `do_rd` has been low for many cycles when the read side parks
    -- and NOTHING IS IN FLIGHT ACROSS THE PARK.  That is a corner, not the
    -- normal case, and it was the only clear this bench ever ran.
    --
    -- MEASURED 2026-09-20 by TRACK POPCOVER: a mutation that parks the output
    -- stage but leaves `mem_q_v` SET (sim/mutate_async_fifo.sh row P11, the
    -- narrow half of C3) SURVIVED the whole bench, in BOTH arms, because the
    -- stale beat it strands can only land if a read was in flight when the
    -- park arrived.  Under FAST_POP a read is in flight on essentially every
    -- read cycle, so this is the CARD'S NORMAL STATE.
    --
    -- Both sides run flat out into the clear here, and unlike phase 4 the
    -- reader is NOT stopped first, so `do_rd` is high in the cycle before
    -- `clr_r_s2` rises.
    w_dens <= 16; r_dens <= 16; w_run <= true; r_run <= true;
    for i in 0 to 4*DEPTH loop wait until rising_edge(wclk); end loop;
    do_clear;
    stop_both;
    rebase(1500000);
    move(NBEATS/2, 12, 12, "phase5b after an in-flight clear");

    -- ---- PHASE 6  WRITE-DOMAIN RESET ONLY -------------------------------
    -- Not a supported operation: it parks wp while rp keeps the old value, so
    -- the read side is left pointing into stale memory.  What IS required is
    -- that the four-phase clear RECOVERS from it.  Checking is off across the
    -- window because the beats in flight are legitimately lost.
    stop_both; chk_en <= false; reload <= true;
    wait until rising_edge(wclk); wrst <= '1';
    for i in 0 to 5 loop wait until rising_edge(wclk); end loop;
    wait until rising_edge(wclk); wrst <= '0';
    for i in 0 to 5 loop wait until rising_edge(wclk); end loop;
    do_clear;
    rebase(2000000);
    move(NBEATS/2, 12, 12, "phase6 after write-only reset");

    -- ---- PHASE 7  READ-DOMAIN RESET ONLY --------------------------------
    stop_both; chk_en <= false; reload <= true;
    wait until rising_edge(rclk); rrst <= '1';
    for i in 0 to 5 loop wait until rising_edge(rclk); end loop;
    wait until rising_edge(rclk); rrst <= '0';
    for i in 0 to 5 loop wait until rising_edge(rclk); end loop;
    do_clear;
    rebase(3000000);
    move(NBEATS/2, 12, 12, "phase7 after read-only reset");

    -- ---- PHASE 8  THE SKEWED RESET rtl/axi_rd_port.vhd ACTUALLY MAKES ---
    -- `rrst` is the core reset applied directly; `wrst` is that same reset
    -- through two aclk flops, so BOTH EDGES arrive two write cycles late.
    -- This is the pattern the real design produces, and unlike phases 6 and 7
    -- it is applied WITH TRAFFIC IN FLIGHT and is NOT followed by a clear --
    -- the FIFO has to come out of it empty and usable on its own.
    w_dens <= 14; r_dens <= 6; w_run <= true; r_run <= true;
    for i in 0 to 4*DEPTH loop wait until rising_edge(wclk); end loop;
    -- Park the write-domain accounting BEFORE the destructive window: the
    -- reset legitimately destroys beats, so `nw - nr` stops being an
    -- occupancy from here until `rebase` re-zeroes both counters.
    chk_en <= false; reload <= true;
    wait until rising_edge(rclk); rrst <= '1';
    for i in 0 to 1 loop wait until rising_edge(wclk); end loop;
    wrst <= '1';
    for i in 0 to 7 loop wait until rising_edge(wclk); end loop;
    -- The writer stops as the reset releases, so anything q_valid shows after
    -- this point is RESIDUE and nothing else.
    w_run <= false; r_run <= false;
    wait until rising_edge(rclk); rrst <= '0';
    for i in 0 to 1 loop wait until rising_edge(wclk); end loop;
    wrst <= '0';
    for i in 0 to 7 loop wait until rising_edge(wclk); end loop;
    for i in 0 to 7 loop wait until rising_edge(rclk); end loop;
    if q_valid /= '0' then
      report NAME & ": RESIDUE SURVIVED THE SKEWED RESET -- q_valid is high " &
             "with nothing written since" severity error;
      cov := cov + 1;
    end if;
    stop_both;
    rebase(4000000);
    move(NBEATS, 16, 5, "phase8 after skewed reset");

    -- ---- PHASE 8b  THE READ-ISSUE CADENCE -------------------------------
    -- Placed LAST of the traffic phases on purpose: it neither clears nor
    -- resets, so the value sequence runs straight through it and phase 9's
    -- accounting check spans it.
    cadence_probe;

    -- ---- PHASE 9  quiesce and account for every beat --------------------
    w_run <= false; r_run <= true; r_dens <= 16;
    wait until rising_edge(wclk);
    while not w_idle loop wait until rising_edge(wclk); end loop;
    target := nw;
    t0 := now;
    while nr < target loop
      wait until rising_edge(rclk);
      if now - t0 > 4096 * RPER then
        report NAME & ": DRAIN STALLED with " & integer'image(target - nr) &
               " beats still inside" severity error;
        cov := cov + 1; exit;
      end if;
    end loop;
    r_run <= false;
    for i in 0 to 7 loop wait until rising_edge(rclk); end loop;
    if q_valid /= '0' then
      report NAME & ": q_valid STILL HIGH after a full drain" severity error;
      cov := cov + 1;
    end if;
    if nr /= nw then
      report NAME & ": ACCOUNTING -- " & integer'image(nw) & " written, " &
             integer'image(nr) & " consumed in the last segment" severity error;
      cov := cov + 1;
    end if;

    -- ---- COVERAGE, asserted rather than printed -------------------------
    -- A run that never reached the boundary the +123.88 MHz restructuring
    -- rewrote has not tested it, so it FAILS rather than passing quietly.
    if THROTTLE then
      -- The throttled case proves the property rtl/axi_rd_fsm.vhd's AR issue
      -- actually rests on, and it is NOT "occupancy stays under DEPTH".
      -- Occupancy as this bench counts it includes the read side's output
      -- stage, and DERIVED from the throttle's own arithmetic it legitimately
      -- REACHES DEPTH: the writer offers while w_level < DEPTH, w_level is
      -- used_w(n-1) + OUT_MARGIN + 1, so used_w can still climb to
      -- DEPTH - OUT_MARGIN - 2 and the output stage adds OUT_MARGIN on top.
      -- MEASURED: max occupancy is exactly 16 at DEPTH 16, with the memory
      -- itself at 13.  The property that has teeth is that the FIFO NEVER
      -- REFUSED A BEAT -- w_ready low under the throttle is precisely the
      -- overrun the throttle exists to prevent.
      if n_wstall /= 0 then
        report NAME & ": THE THROTTLE DID NOT HOLD -- w_ready refused an " &
               "offer " & integer'image(n_wstall) & " times under a writer " &
               "gated on w_level < DEPTH" severity error;
        cov := cov + 1;
      end if;
      if max_occ < DEPTH - OUT_MARGIN - 3 then
        report NAME & ": COVERAGE -- the throttled writer never came near " &
               "full (max occupancy " & integer'image(max_occ) & " of " &
               integer'image(DEPTH) & "), so w_level may simply be too large"
          severity error;
        cov := cov + 1;
      end if;
    else
      -- DEPTH + 2, not DEPTH, and the 2 is DERIVED rather than observed:
      -- `do_rd` is gated on `ocnt + inflight < 2`, so the read side holds at
      -- most two beats outside the memory (ocnt = 2 with nothing in flight,
      -- or ocnt = 1 with one).  Full capacity is therefore exactly DEPTH + 2,
      -- and MEASURED it is reached on every non-throttled ratio at all three
      -- depths (18/16, 18/16, 18/16, 18/16, 6/4, 66/64).
      --
      -- Asserting DEPTH alone is NOT enough, and that is a measurement rather
      -- than a worry: with the bound at DEPTH, mutation G6 (the read pointer's
      -- gray encode lags by one) SURVIVED.  It silently costs one slot of
      -- capacity -- safe, but a real regression -- and DEPTH + 2 resolves it.
      --
      -- CORRECTION 2026-09-20 (TRACK POPCOVER).  This block used to name F3
      -- (full asserts one slot early) alongside G6 as resolved by the DEPTH + 2
      -- bound.  IT IS NOT.  MEASURED at 92ba3ec, BEFORE this file grew its
      -- second arm, so the correction is not about that change:
      -- `ONLY=F3 bash sim/mutate_async_fifo.sh` reports `1 SURVIVED` with
      -- maxocc = 18/16 on every DEPTH-16 ratio, i.e. F3 still reaches the full
      -- DEPTH + 2.  DERIVED reason: `full_r` is REGISTERED and computed from
      -- used_w(n), so moving its threshold from DEPTH to DEPTH-1 without also
      -- moving the look-ahead arm still leaves full_r low in the cycle
      -- used_w = DEPTH-2, and the write that cycle admits carries used_w to
      -- DEPTH-1, and the next one to DEPTH.  F3 costs nothing, which is why
      -- nothing sees it.  The claim was self-consistent and never re-run.
      if max_occ < DEPTH + 2 then
        report NAME & ": COVERAGE -- the FIFO never reached its full " &
               "capacity (max occupancy " & integer'image(max_occ) &
               " of " & integer'image(DEPTH + 2) & " = DEPTH + 2)"
          severity error;
        cov := cov + 1;
      end if;
      if n_wstall = 0 then
        report NAME & ": COVERAGE -- w_ready never refused an offer, so the " &
               "full flag was never exercised on the interface" severity error;
        cov := cov + 1;
      end if;
    end if;
    if n_rstall = 0 then
      report NAME & ": COVERAGE -- q_valid was never low under q_ready, so " &
             "the empty boundary was never exercised" severity error;
      cov := cov + 1;
    end if;

    ncov <= cov;
    wait until rising_edge(wclk);
    report NAME & ": nw=" & integer'image(nw_tot) &
           " nr=" & integer'image(nr_tot) &
           " maxocc=" & integer'image(max_occ) & "/" & integer'image(DEPTH) &
           " wstall=" & integer'image(n_wstall) &
           " rstall=" & integer'image(n_rstall) &
           " minslack=" & integer'image(min_slack) &
           " cadence=" & integer'image(cad_cyc) & "/" & integer'image(CAD_N) &
           " err=" & integer'image(nerr + nlvl + nocc + nclr + cov)
      severity note;
    errs <= nerr + nlvl + nocc + nclr + cov;
    done <= true;
    running <= false;
    wait;
  end process;
end architecture;

-- ===========================================================================
-- THE EIGHT CLOCK RATIOS, AS ONE BLOCK, SO THAT BOTH `FAST_POP` ARMS RUN THE
-- SAME LIST.  Before 2026-09-20 these eight instances were written out once,
-- directly in the top level, at the DUT's default FAST_POP = false -- which is
-- the arm the card does NOT run.  Factoring them here is what makes "the same
-- ratios, the same seeds, the other arm" a two-line change rather than a
-- second copy of the list that can drift.
-- ===========================================================================
library ieee;
use ieee.std_logic_1164.all;

entity af_ratios is
  generic(
    ARM      : string   := "slow";   -- prefix on every case name
    FAST_POP : boolean  := false;
    CADENCE  : boolean  := true;
    NBEATS   : positive := 160
  );
  port(done : out boolean := false; errs : out integer := 0);
end entity;

architecture beh of af_ratios is
  constant NC : integer := 8;
  type ia_t is array(0 to NC-1) of integer;
  signal er : ia_t := (others => 0);
  signal d0,d1,d2,d3,d4,d5,d6,d7 : boolean;
begin
  -- Eight clock ratios.  The list is the point of the file, so each entry
  -- says what it is for.

  -- write 3.25x faster than read: the FK33 direction (HBM ACLK above f_core),
  -- and the one that makes the FIFO fill.
  c0 : entity work.af_case
    generic map(NAME => ARM & "/fastw", WPER_PS => 4000, RPER_PS => 13000,
                SEED => 1, DEPTH => 16, NBEATS => NBEATS,
                FAST_POP => FAST_POP, CADENCE => CADENCE)
    port map(done => d0, errs => er(0));

  -- read 3.25x faster than write: the FIFO is nearly always empty, so the
  -- empty flag and the output stage's first-word-fall-through are what is
  -- under test.
  c1 : entity work.af_case
    generic map(NAME => ARM & "/fastr", WPER_PS => 13000, RPER_PS => 4000,
                SEED => 2, DEPTH => 16, NBEATS => NBEATS,
                FAST_POP => FAST_POP, CADENCE => CADENCE)
    port map(done => d1, errs => er(1));

  -- EXACTLY equal, edges COINCIDENT.  The pathological case for a
  -- zero-delay simulator: every synchroniser samples a signal that changes in
  -- the same delta, so a design that only works because its edges never line
  -- up fails here and nowhere else.
  c2 : entity work.af_case
    generic map(NAME => ARM & "/eq_ph0", WPER_PS => 6000, RPER_PS => 6000,
                SEED => 3, DEPTH => 16, NBEATS => NBEATS,
                FAST_POP => FAST_POP, CADENCE => CADENCE)
    port map(done => d2, errs => er(2));

  -- Equal rate, quarter-period offset: the same rate with the opposite delta
  -- ordering.
  c3 : entity work.af_case
    generic map(NAME => ARM & "/eq_ph90", WPER_PS => 6000, RPER_PS => 6000,
                RPHASE_PS => 1500, SEED => 4, DEPTH => 16, NBEATS => NBEATS,
                FAST_POP => FAST_POP, CADENCE => CADENCE)
    port map(done => d3, errs => er(3));

  -- 7000 against 6999 ps: NOT an integer multiple, and the phase relationship
  -- sweeps through a full cycle every 7000 write clocks, so every alignment
  -- between the two domains occurs somewhere in the run.  This is the single
  -- most useful ratio in the list.
  c4 : entity work.af_case
    generic map(NAME => ARM & "/slide", WPER_PS => 7000, RPER_PS => 6999,
                SEED => 5, DEPTH => 16, NBEATS => NBEATS,
                FAST_POP => FAST_POP, CADENCE => CADENCE)
    port map(done => d4, errs => er(4));

  -- A deep FIFO with a 10.33x ratio: the fill phase leaves it full for a long
  -- time, which is where a full flag that is off by one shows up.
  c5 : entity work.af_case
    generic map(NAME => ARM & "/deep", WPER_PS => 3000, RPER_PS => 31000,
                SEED => 6, DEPTH => 64, NBEATS => NBEATS,
                FAST_POP => FAST_POP, CADENCE => CADENCE)
    port map(done => d5, errs => er(5));

  -- DEPTH 4, the smallest useful depth: OUT_MARGIN (3) is nearly the whole
  -- FIFO, so every boundary is hit on almost every beat.  Below the cadence
  -- probe's DEPTH floor, so this ratio is a VALUE row in both arms and a
  -- cadence row in neither -- see cadence_probe's header.
  c6 : entity work.af_case
    generic map(NAME => ARM & "/tiny", WPER_PS => 5000, RPER_PS => 11000,
                SEED => 7, DEPTH => 4, NBEATS => NBEATS,
                FAST_POP => FAST_POP, CADENCE => CADENCE)
    port map(done => d6, errs => er(6));

  -- The REAL caller's contract: the writer offers only while w_level < DEPTH,
  -- which is rtl/axi_rd_fsm.vhd's AR throttle with promised = 0.  This is the
  -- only case in which a w_level that is too LARGE is detectable -- it shows
  -- up as a throughput stall rather than as a wrong value.
  c7 : entity work.af_case
    generic map(NAME => ARM & "/thrott", WPER_PS => 5000, RPER_PS => 12000,
                SEED => 8, DEPTH => 16, NBEATS => NBEATS, THROTTLE => true,
                FAST_POP => FAST_POP, CADENCE => CADENCE)
    port map(done => d7, errs => er(7));

  fin : process
    variable tot : integer := 0;
  begin
    wait until d0 and d1 and d2 and d3 and d4 and d5 and d6 and d7;
    wait for 1 ns;
    for i in 0 to NC-1 loop tot := tot + er(i); end loop;
    report "async_fifo arm " & ARM & ": " & integer'image(tot) &
           " errors across 8 clock ratios" severity note;
    errs <= tot;
    done <= true;
    wait;
  end process;
end architecture;

-- ===========================================================================
library ieee;
use ieee.std_logic_1164.all;

entity tb_async_fifo is
  generic(
    NBEATS  : positive := 160;
    -- The cadence check, on both arms.  false is the ATTRIBUTION CONTROL --
    -- see the CADENCE generic on af_case.  Everything else stays.
    CADENCE : boolean  := true
  );
end entity;

architecture sim of tb_async_fifo is
  signal d_slow, d_fast : boolean;
  signal e_slow, e_fast : integer := 0;
begin
  -- THE ARM EVERY RTL DEFAULT SELECTS, and the only one this bench ran until
  -- 2026-09-20.
  a_slow : entity work.af_ratios
    generic map(ARM => "slow", FAST_POP => false, CADENCE => CADENCE,
                NBEATS => NBEATS)
    port map(done => d_slow, errs => e_slow);

  -- THE ARM THE CARD RUNS.  hw/fk33/rtl/fk33_engine.vhd:1356 sets
  -- FAST_POP => true on matvec_int4, which threads it through
  -- matvec_int4_desc_axi:202 -> axi_rd_port:102 -> async_fifo:122, and
  -- DUAL_CLK is true there, so all 27 of subsystem A's read ports end in THIS
  -- entity with THIS arm.  Same ratios, same seeds, same oracle.
  a_fast : entity work.af_ratios
    generic map(ARM => "fast", FAST_POP => true, CADENCE => CADENCE,
                NBEATS => NBEATS)
    port map(done => d_fast, errs => e_fast);

  fin : process
    variable tot : integer := 0;
  begin
    wait until d_slow and d_fast;
    wait for 1 ns;
    tot := e_slow + e_fast;
    report "async_fifo: " & integer'image(tot) &
           " errors across 8 clock ratios x 2 FAST_POP arms (slow " &
           integer'image(e_slow) & ", fast " & integer'image(e_fast) & ")"
      severity note;
    assert tot = 0
      report "async_fifo FAILED: see the per-case diagnostics above"
      severity failure;
    report "PASS: tb_async_fifo" severity note;
    std.env.stop;
  end process;
end architecture;
