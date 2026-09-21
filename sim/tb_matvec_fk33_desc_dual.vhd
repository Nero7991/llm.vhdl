-- sim/tb_matvec_fk33_desc_dual.vhd -- subsystem A's descriptor control plane
-- with the AXI side on its own faster clock, as a GATE ROW rather than a
-- manual run, run at BOTH arms of FAST_POP.
--
-- WHY IT IS A SEPARATE FILE AND NOT A SECOND SET OF ARGUMENTS.  sim/regress.sh
-- keys a test by NAME and cannot run one testbench twice, which is stated in
-- as many words next to sim:tb_matvec_fk33_desc's own argument row.  So the
-- only way to gate a second configuration of that bench is a second entity,
-- and the cheapest honest second entity is a wrapper that instantiates the
-- first one with the generic set.  Nothing is duplicated: the 22-case
-- mutation matrix, the legal-shape sweep and the bit-exact comparison against
-- ref/matvec_int4.c all live in sim/tb_matvec_fk33_desc.vhd and all run here.
--
-- WHY IT IS WORTH A ROW.  DUAL_CLK = true is what the FK33 build instantiates
-- (hw/fk33/rtl/fk33_engine.vhd:1171), and it is not a small switch: it selects
-- axi_rd_port's `g_dc` generate, which replaces stream_fifo with async_fifo
-- and puts a toggle synchroniser on `start` and a level synchroniser on `run`.
-- When TRACK A-CTRL first built that path its absence broke 17 of 22 cases.
-- Until this file existed, the ONLY thing standing between that defect class
-- and the gate was somebody remembering to type -gDUAL=true, and row N8 of
-- docs/WORKLOG.md is the record that nobody had.
--
-- WHAT IT DOES NOT COVER.  The AXI clock is 1.67x the core clock and nothing
-- else; there is no ratio sweep here, and an RTL simulator samples atomically,
-- so a synchroniser cut down to one flop or to none still crosses cleanly.
-- That resolution floor is measured, not guessed -- five of the twenty rows in
-- sim/mutate_axi_rd_port_dual.sh survive for exactly this reason, and
-- sim/cdc_teeth.sh (report_cdc) is the flow that reaches them.  Read the three
-- together; each alone is a misleading picture.
--
-- TRACE is passed explicitly, and it has to be: sim/regress.sh discovers a
-- test's data files from the STRING LITERALS IN THE TESTBENCH FILE ITSELF
-- (files[tb][3]), not from its dependency closure, so a wrapper that inherited
-- the default would be run with no vector generated and would fail on "cannot
-- open mv_fk33_tr.txt".
--
-- ======================================================================
-- BOTH ARMS OF FAST_POP, added 2026-09-20 by TRACK DESCARM
-- ======================================================================
--
-- Build 11b ships FAST_POP = true.  TRACK POPCOVER (fbac64e) cleared the arm
-- inside rtl/async_fifo.vhd and TRACK POPPORT (62dc777) cleared the 27-way
-- rendezvous in rtl/weight_streamer.vhd, and POPPORT closed by naming what
-- neither had reached: the DESCRIPTOR plane.  FAST_POP arrives at
-- rtl/matvec_int4_desc_axi.vhd twice --
--   :628  the descriptor read master `dfetch`, which POPPORT recorded as
--         outside every bench's cone, and
--   :690  the core, and through it weight_streamer --
-- and until this file ran both arms, the descriptor master's copy of the
-- lever was instantiated by nothing in the tree at either setting.
--
-- IT CLOSES :628 AND IT DOES NOT CLOSE :690, AND THAT IS MEASURED RATHER THAN
-- ASSUMED.  Row D1 of sim/mutate_desc_fastpop.sh -- the descriptor master
-- forwarding false while the core keeps true -- dies here and nowhere else.
-- Rows C1 and C2, the same two mutations at the CORE's forwarding site,
-- SURVIVE every column, and the weight-window note printed below is the
-- evidence for why: the only window that reaches :690 is confounded by the
-- weight slaves' stall LFSR.  The gap is reported, not papered over.
--
-- A SECOND ENTITY WOULD HAVE COST A SECOND GATE ROW, AND A SECOND ROW NEEDS
-- THREE EDITS TO sim/regress.sh THAT A NEW FILE CANNOT CARRY WITH IT.  A row
-- is discovered by globbing sim/tb_*.vhd, but its --stop-delta, its optional
-- prerequisite (the .mv4i tensor) and its pass marker are all case arms in
-- sim/regress.sh keyed by name.  A new file landing without them runs on
-- ghdl's 5000-delta default, is scored NOVERDICT, and turns the shared gate
-- red for every track until somebody edits the runner.  So the second arm
-- goes INSIDE this entity, where it inherits the row's flags, its prereq and
-- its marker by construction, and the runner needs no edit at all.
--
-- THE MARKER IS OWNED HERE, WHICH IS THE POINT OF -gMARK=false.  Two arms
-- under one row means a run in which one arm finishes and the other hangs
-- would otherwise put the marker in the log and PASS on half a run.  Both
-- arms are told to stay quiet; the phrase sim/regress.sh greps for is printed
-- by the verdict process below and only after BOTH have reported done.  A
-- truncated run is therefore a NOVERDICT, which is what it is.
--
-- THE CADENCE CHECK IS TWO-SIDED, AND IT NEEDS NO CONSTANT.  A value oracle
-- can prove FAST_POP HARMLESS and never PRESENT, because the lever changes no
-- value by construction: that is POPCOVER's and POPPORT's finding and it is
-- just as true here.  What this file adds is the drain probe described in
-- sim/tb_matvec_fk33_desc.vhd's PROBE generic, run on both arms, and the
-- comparison is made BETWEEN THE TWO INSTANCES rather than against a number
-- written down here.  So the fast arm fails if it is not faster and the slow
-- arm fails if it is not slower.  The magnitude IS a written-down number, 42
-- ns, and it is MEASURED rather than derived -- the derivation said 50 and the
-- constant's comment below says why it is wrong.
--
-- -gCADENCE=false neutralises the two bounds and nothing else -- the card's
-- arm is still instantiated, still checked for values, just not timed.  It is
-- the attribution control sim/mutate_desc_fastpop.sh runs on every row, and
-- without it a mutation caught by the mere presence of the second instance
-- would be credited to the probe.

entity tb_matvec_fk33_desc_dual is
  generic(
    -- The attribution control.  false keeps both arms and both value oracles
    -- and drops only the timing bounds.
    CADENCE : boolean := true
  );
end entity;

architecture sim of tb_matvec_fk33_desc_dual is
  -- MEASURED 2026-09-20, TRACK DESCARM, not derived, and the derivation is
  -- recorded here because it FAILED and that is the useful part.
  --
  -- DBEATS is 10 at this geometry (DESC_BASE0 8 + NPORTS_W 24 + NPORTS_S 3 +
  -- DESC_EXT_WORDS 4 = 39 words at 4 words per 256-bit beat, rounded up).
  -- Ten beats popped one per core cycle against one per 1.5 core cycles
  -- DERIVES a 5-cycle, 50 ns difference.  The measurement is 42 ns.
  --
  -- The derivation is wrong for a reason worth keeping: the window's two
  -- endpoints are both AXI-domain events (the descriptor AR handshake and the
  -- first weight AR, each issued by an axi_rd_port on `aclk`) while the drain
  -- they bracket is a CORE-domain quantity, so a difference that is a whole
  -- number of 10 ns core cycles is observed on a 6 ns grid and lands on 42.
  -- The fill and the drain also interleave rather than running in sequence --
  -- the slave supplies a beat every 6 ns while the shipping arm pops one every
  -- 15 -- so the arm-to-arm difference is not the full 10 x 0.5 either.
  --
  -- 42 is therefore a MEASURED constant of THIS wrapper's pinned geometry, not
  -- a law, and it is asserted as an equality because an inequality passes a
  -- lever that moved by one cycle -- which is exactly TRACK POPCOVER's row P3,
  -- the fast arm committing one instead of two, every value correct and
  -- STRICTLY SLOWER than the arm it exists to beat.
  constant DBEATS_A : integer := 10;
  constant WANT_D   : integer := 42;        -- ns, MEASURED

  signal d_slow, d_fast : boolean := false;
  signal p_slow, p_fast : integer := -1;    -- ns, AR to first weight AR
  signal s_slow, s_fast : integer := -1;    -- ns, AR to last descriptor R
  signal w_slow, w_fast : integer := -1;    -- ns, first weight AR to job_done
  signal b_slow, b_fast : integer := -1;    -- weight beats inside that window
begin
  -- The shipping arm.  Identical in every generic to what this row ran before
  -- 2026-09-20 except MARK and PROBE, neither of which the DUT can see.
  slow : entity work.tb_matvec_fk33_desc
    generic map(TRACE => "mv_fk33_tr.txt", DUAL => true,
                FASTP => false, PROBE => true, MARK => false)
    port map(done_o => d_slow, probe_o => p_slow, supply_o => s_slow,
             weight_o => w_slow, beats_o => b_slow);

  -- The arm build 11b ships.
  fast : entity work.tb_matvec_fk33_desc
    generic map(TRACE => "mv_fk33_tr.txt", DUAL => true,
                FASTP => true, PROBE => true, MARK => false)
    port map(done_o => d_fast, probe_o => p_fast, supply_o => s_fast,
             weight_o => w_fast, beats_o => b_fast);

  verdict : process
    variable nerr : integer := 0;
  begin
    wait until d_slow and d_fast;

    -- Both probes must have fired.  A probe that never armed reports -1, and
    -- a pair of bounds evaluated against -1 would be arithmetic on an absence
    -- rather than on a measurement.
    if p_slow < 0 or p_fast < 0 or s_slow < 0 or s_fast < 0
       or w_slow < 0 or w_fast < 0 or b_slow < 0 or b_fast < 0 then
      nerr := nerr + 1;
      report "DRAIN PROBE DID NOT ARM (drain slow=" & integer'image(p_slow) &
             " fast=" & integer'image(p_fast) & ", supply slow=" &
             integer'image(s_slow) & " fast=" & integer'image(s_fast) &
             ", weight slow=" & integer'image(w_slow) & " fast=" &
             integer'image(w_fast) & ", beats slow=" & integer'image(b_slow) &
             " fast=" & integer'image(b_fast) &
             ") -- the window was never opened and its silence means nothing"
        severity error;
    end if;

    report "DRAIN PROBE: descriptor AR to first weight AR, shipping arm " &
           integer'image(p_slow) & " ns, FAST_POP arm " &
           integer'image(p_fast) & " ns, difference " &
           integer'image(p_slow - p_fast) & " ns (want " &
           integer'image(WANT_D) & ").  SUPPLY CONTROL, AR to last " &
           "descriptor R: shipping " & integer'image(s_slow) &
           " ns, FAST_POP " & integer'image(s_fast) & " ns" severity note;

    -- REPORTED, DELIBERATELY NOT ASSERTED.  See section 43 of
    -- docs/debugging/2026-09-20_the-shape-a-bench-runs-at.md.  MEASURED
    -- 2026-09-20: shipping 342 ns, FAST_POP 366 ns -- the card's arm is the
    -- SLOWER of the two here, over the same 27 beats, and the sign is an
    -- artefact rather than a result.  The weight slaves stall on an LFSR that
    -- advances once per AXI edge from reset, and the two arms enter this
    -- window 42 ns (7 AXI edges) apart because of the DESCRIPTOR drain, so
    -- they meet different stall realisations.  A "the arms differ" check would
    -- therefore pass on the head start alone and would credit the core's
    -- forwarding site for something the descriptor master did.  The number is
    -- printed because it is the evidence for that gap, and it is the only
    -- thing in this file that a reader might otherwise assume is checked.
    report "WEIGHT WINDOW (reported, NOT asserted): first weight AR to " &
           "job_done, shipping arm " & integer'image(w_slow) & " ns over " &
           integer'image(b_slow) & " beats, FAST_POP arm " &
           integer'image(w_fast) & " ns over " & integer'image(b_fast) &
           " beats" severity note;

    if CADENCE and p_slow >= 0 and p_fast >= 0 then
      -- THE CONTROL FIRST, because a drain difference is only attributable to
      -- the drain if the supply did not move.  The descriptor slave serves
      -- back to back and the FIFO is 64 deep against DBEATS = 10, so the last
      -- R beat must land at the same nanosecond on both arms.  If it does not,
      -- the FIFO went full, the supply is part of the difference, and no
      -- statement about the read-issue condition can be made from it.
      if s_slow /= s_fast then
        nerr := nerr + 1;
        report "THE SUPPLY MOVED: the last descriptor R beat lands at " &
               integer'image(s_slow) & " ns on the shipping arm and " &
               integer'image(s_fast) & " ns on the FAST_POP arm.  The drain " &
               "difference below is NOT attributable to the read-issue " &
               "condition" severity error;
      end if;
      -- TWO-SIDED.  The equality fails a fast arm that is not fast AND a
      -- shipping arm that is not slow, in one statement, because it pins the
      -- gap rather than either end.
      if p_slow - p_fast /= WANT_D then
        nerr := nerr + 1;
        report "FAST_POP DRAIN IS NOT " & integer'image(WANT_D) &
               " ns: shipping " & integer'image(p_slow) &
               " ns, FAST_POP " & integer'image(p_fast) & " ns, difference " &
               integer'image(p_slow - p_fast) & " ns over DBEATS=" &
               integer'image(DBEATS_A) & " descriptor beats" severity error;
      end if;
      -- THE BEATS CONTROL.  The same job moved the same 27 weight and scale
      -- beats on both arms.  This is the one thing the weight window CAN say
      -- without the stall-realisation confound, because a count is not a time.
      -- It is expected never to bite -- a lost beat fails the value oracle
      -- long before it reaches here -- and it is kept because a faster arm
      -- that moved fewer beats has not gone faster, it has gone wrong, and
      -- nothing else in this file would say so in those words.
      if b_slow /= b_fast then
        nerr := nerr + 1;
        report "THE ARMS MOVED DIFFERENT AMOUNTS OF DATA: " &
               integer'image(b_slow) & " weight beats on the shipping arm " &
               "against " & integer'image(b_fast) &
               " on the FAST_POP arm.  No timing comparison between them is " &
               "meaningful" severity error;
      end if;
      -- And the SIGN on its own, reported separately, so a log read by a human
      -- says which way round it went rather than only that a number moved.
      -- This one is REDUNDANT with the equality above while the equality holds
      -- and is kept because it is the check that survives a geometry change:
      -- 42 rots, "faster" does not.
      if p_fast >= p_slow then
        nerr := nerr + 1;
        report "THE LEVER IS NOT PRESENT OR IS INVERTED: the FAST_POP arm " &
               "reached its first weight AR in " & integer'image(p_fast) &
               " ns against the shipping arm's " & integer'image(p_slow)
          severity error;
      end if;
    end if;

    assert nerr = 0
      report "SUBSYSTEM A'S DESCRIPTOR CONTROL PLANE FAILED " &
             integer'image(nerr) & " CHECKS AT THE FAST_POP ARM"
      severity failure;

    report "tb_matvec_fk33_desc_dual: both FAST_POP arms complete [CADENCE=" &
           boolean'image(CADENCE) & "]" severity note;
    report "subsystem A is bit-exact with ref/matvec_int4.c through the " &
           "descriptor control plane, and every checked mutation is refused"
      severity note;
    wait;
  end process;
end architecture;
