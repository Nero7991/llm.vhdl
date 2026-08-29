-- sim/tb_gdn_head_emit.vhd
-- Bit-exactness of rtl/gdn_head_emit.vhd (subsystem B stage 6, SITE 12)
-- against ref/gdn_head_emit_vec.c, PLUS a real-valued accuracy gate on the
-- DUT's own outputs.
--
-- WHY THE ACCURACY GATE IS HERE AND NOT IN THE GENERATOR.  Until 2026-08-29
-- this file said "NO TOLERANCE" and left the real-valued claim to
-- ref/gdn_head_emit_vec.c, which computes a double oracle, PRINTS it and
-- returns 1 if it reaches 1.0 LSB.  sim/regress.sh never runs that generator
-- -- sim/gdn_head_emit_vec.txt is committed and regress.sh regenerates a
-- vector only when the file is absent -- so the gate consulted none of it.  A
-- recipe error present in the RTL and the C together was invisible to the
-- whole suite.  The claim is therefore made here, against the DUT's outputs,
-- which is also the only place it can see an RTL-ONLY accuracy defect.
--
-- AND THE GENERATOR'S ORACLE HAS A HOLE THIS ONE DOES NOT.  It accumulates
-- only `if (!sat_any && ...)`, and `sat_any` is a WHOLE-CASE flag raised when
-- any single element saturated -- an exclusion on an OUTPUT property.  MEASURED
-- on the committed vectors: dropping the output rail from 16 bits to 15 in the
-- RTL and the C together (mutation B4 of sim/mutate_gdn_head_emit.sh) makes 49
-- of 64 cases saturate; with the 15 all-zero heads that leaves the oracle
-- measuring almost nothing but zeros, and it prints 0.0000 LSB and returns OK
-- on a unit that is 16384 LSB wrong.  The oracle below excludes NOTHING.  It
-- costs nothing to include the saturated elements, because on the honest unit
-- saturation can only follow the requantize rounding 2^15-1/2 up to 2^15, so
-- its error is bounded by the same derivation as every other element:
-- MEASURED, the honest worst goes 0.5000 (case-excluded) to 0.999985 (nothing
-- excluded) and stays there at all 40 generator seeds swept.
--
-- The bit-exact comparison against the C is unchanged and is still the primary
-- check.  The tolerance cannot hide a disagreement between the two because it
-- is a SECOND, independent verdict, not a loosening of the first.
--
-- The vector file deliberately leads with the cases that are easy to get
-- wrong: all-equal exponents, an all-zero head (which pins the msb_pos(0) = 0
-- convention), a wide exponent spread, negative values one below a power of
-- two (the floor_shr counterexample that kills the one-pass amax shortcut),
-- and saturation in both directions.  See the generator for why each is there.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

entity tb_gdn_head_emit is
  generic( DIM   : positive := 128;
           NCASE : positive := 64;
           -- Accuracy gate, in THOUSANDTHS of an output LSB so that the whole
           -- gate is overridable from sim/regress.sh.  ghdl-mcode cannot
           -- override a `real` generic at all ("unhandled type for generic
           -- override of ..." and elaboration dies), so a real here would be a
           -- knob nobody can turn, and one that cannot be teeth-checked.
           --
           --   ACC_MAXLSB_M   cap on the worst |o_mant - oracle|, milli-LSB.
           --   ACC_NEAR_M     the counting threshold, milli-LSB.
           --   ACC_NEAR_MAX   how many elements may exceed it.
           --   ACC_MEAN_M     cap on the MEAN |o_mant - oracle|, milli-LSB.
           --   ACC_MIN_CHECK  FLOOR on how many elements entered the oracle.
           --
           -- FOUR NUMBERS AND NOT ONE, because each is blind to something the
           -- others see.  Here that is not a general principle, it is a
           -- MEASUREMENT: the truncated-requantize mutation B3 drives the worst
           -- error to 1.000000 LSB against the honest unit's 0.999985, a
           -- separation of 1.5e-5 that NO honest max threshold can rest on --
           -- while the same mutation moves the count past 0.5 LSB from 24 to
           -- 3127 and the mean from 0.103 to 0.385.  The max is what catches
           -- B4 (16384.999985).  Neither figure catches both.
           --
           -- CALIBRATION IS A MEASUREMENT, NOT A CHOICE.  Every threshold
           -- below clears the unmutated unit at FORTY generator seeds
           -- (100003*i + 7, i = 1..40) and still kills the BOTH-class
           -- mutations of sim/mutate_gdn_head_emit.sh that it claims to.  The
           -- honest envelope over those 40 seeds:
           --   worst      0.999985 at every one of the 40
           --   n > 0.5    3 .. 24
           --   mean       0.058687 .. 0.103475
           -- Full tables, and the two mutations these thresholds deliberately
           -- do NOT catch, in docs/debugging/2026-08-29_b-emit-accuracy-gates.md.
           --
           -- The count is an ABSOLUTE count at the committed shape
           -- (64 x 128 = 8192 elements).  Changing NCASE or DIM without
           -- rescaling ACC_NEAR_MAX and ACC_MIN_CHECK changes what they mean.
           ACC_MAXLSB_M  : integer := 1500;   -- honest 0.999985, B4 16384.999985
           ACC_NEAR_M    : integer := 500;
           ACC_NEAR_MAX  : integer := 120;    -- honest 24, B3 3127, B4 1148
           ACC_MEAN_M    : integer := 200;    -- honest 0.1035, B3 0.3847
           ACC_MIN_CHECK : integer := 8192;   -- NCASE*DIM, nothing is excluded
           -- A FIFTH check, and it is NOT an accuracy tolerance: it is the one
           -- property no error measured in LSB of the OUTPUT grid can ever
           -- have.  MEASURED: taking sh_h from msb_pos(oamax)-14 to -13, which
           -- coarsens the output grid by a whole octave and throws away one
           -- bit of every mantissa, moves the no-exclusion oracle's worst from
           -- 0.999985 to 0.500000, its count past 0.5 LSB from 14 to 0 and its
           -- mean from 0.0594 to 0.0550.  Every one of those moves the SAFE
           -- way, because the absolute error and the LSB double together.  The
           -- same defect is what sim/mutate_gdn_emit_chain.sh's B4 records as
           -- an expected survivor of both oracles.
           --
           -- So this claim is on the NORMALISATION instead.  sh_h is chosen so
           -- the largest aligned column fills the grid: sh_h > 0 implies
           -- oamax >= 2^(sh_h+14), hence |round_shift(oamax, sh_h)| >= 2^14.
           -- DERIVED exactly, not fitted -- and therefore TIGHT: MEASURED, the
           -- honest unit attains exactly 16384 at all 40 seeds swept, always
           -- on the saturation shape.  Zero margin is correct here because the
           -- bound is an identity of the recipe, but it does mean an
           -- off-by-one in the comparison would be a false red, so the
           -- comparison is `<` and the constant is a generic.
           ACC_NORM_FLOOR : integer := 16384; -- honest 16384, msb-13 8192, rail-15 16383
           VECS  : string   := "gdn_head_emit_vec.txt" );
end entity;

architecture sim of tb_gdn_head_emit is
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  signal in_valid : std_logic := '0';
  signal in_acc   : signed(39 downto 0) := (others => '0');
  signal in_e_o   : signed(7 downto 0)  := (others => '0');

  signal in_ready : std_logic;
  signal done     : std_logic;
  signal o_mant   : std_logic_vector(DIM*16-1 downto 0);
  signal o_e_head : signed(7 downto 0);
  signal o_sat    : std_logic;

  type acc_arr  is array(0 to DIM-1) of integer;
  type acc_arr2 is array(0 to DIM-1) of real;   -- o_acc can exceed VHDL integer
  type case_acc is array(0 to NCASE-1) of acc_arr2;
  type case_exp is array(0 to NCASE-1) of acc_arr;
  type case_mnt is array(0 to NCASE-1) of acc_arr;

  signal running : boolean := true;

  -- Overlap-phase capture.  done for head h fires WHILE head h+1 is filling,
  -- so the result cannot be read by the stimulus process at its leisure; it
  -- has to be snapshotted the cycle it appears.
  type snap_t is array(0 to 3) of std_logic_vector(DIM*16-1 downto 0);
  type sexp_t is array(0 to 3) of integer;
  shared variable snap_m : snap_t;
  shared variable snap_e : sexp_t;
  shared variable snap_n : integer := 0;
  signal snapping : boolean := false;
  -- A shared variable, not a signal: it is written by BOTH the monitor and
  -- the stimulus, and a signal with two drivers is an unresolved-signal
  -- elaboration error with no line number.  Same mistake as `cyc` in the
  -- cycle probe an hour earlier.
  shared variable ready_fell : boolean := false;
  -- The overlap phase checks two SEPARATE properties, and it took a mutation
  -- run to see that they are separate:
  --   correctness -- no column is lost under back-pressure.  The value
  --     comparison below covers this, and it is the property the FIRST version
  --     of this unit violated, because it had no in_ready at all and simply
  --     ignored in_valid during the reduce.
  --   throughput  -- the reduce hides behind the next head's fill.  The value
  --     comparison does NOT cover this: with a correct valid/ready handshake a
  --     single-banked unit just stalls the producer and still returns the right
  --     answers.  Collapsing the two banks passes the value check and is only
  --     visible as CYCLES, so the cycle bound below is the whole test for it.
  signal ocyc : integer := 0;
  signal ocount : boolean := false;
begin
  clk <= not clk after 5 ns when running else '0';

  dut : entity work.gdn_head_emit
    generic map ( DIM => DIM )
    port map ( clk => clk, rst => rst,
               in_valid => in_valid, in_acc => in_acc, in_e_o => in_e_o,
               in_ready => in_ready,
               done => done, o_mant => o_mant, o_e_head => o_e_head,
               o_sat => o_sat );

  ocnt : process(clk)
  begin
    if rising_edge(clk) then
      if ocount then ocyc <= ocyc + 1; else ocyc <= 0; end if;
    end if;
  end process;

  snapmon : process(clk)
  begin
    if rising_edge(clk) then
      if snapping then
        if done = '1' and snap_n < 4 then
          snap_m(snap_n) := o_mant;
          snap_e(snap_n) := to_integer(o_e_head);
          snap_n := snap_n + 1;
        end if;
        if in_ready = '0' then ready_fell := true; end if;
      end if;
    end if;
  end process;

  stim : process
    file fh : text;
    variable ln : line;
    variable iv, nc, nn : integer;
    variable rv : real;
    variable v_acc : case_acc;
    variable v_eo  : case_exp;
    variable v_mnt : case_mnt;
    variable v_eh  : acc_arr;
    variable v_sat : acc_arr;
    variable got   : integer;
    variable nerr  : integer := 0;

    -- The real-valued oracle's running state.  Deliberately accumulated over
    -- PASS A only: the overlap phase re-runs cases 0..3, and letting those
    -- four in a second time would inflate the count and pull the mean toward
    -- whatever those four happen to be.
    variable a_n     : integer := 0;
    variable a_near  : integer := 0;
    variable a_max   : real    := 0.0;
    variable a_sum   : real    := 0.0;
    variable a_mcase : integer := -1;
    variable a_mcol  : integer := -1;
    variable a_err   : real;
    variable a_ref   : real;
    variable acc_bad : integer := 0;
    variable nrm_bad : integer := 0;
    variable a_amax  : integer;
    variable a_emin  : integer;
    variable a_sh    : integer;

    -- o_acc spans 38 bits, which does not fit a VHDL integer, so the vector
    -- file's values are read as real and converted.  Reading them as integer
    -- would silently wrap on exactly the large-magnitude cases the saturation
    -- test depends on.
    function to_s40(r : real) return signed is
      variable neg : boolean := r < 0.0;
      variable a   : real := abs(r);
      variable res : signed(39 downto 0) := (others => '0');
      variable hi, lo : integer;
    begin
      hi := integer(floor(a / 1048576.0));       -- 2^20
      lo := integer(a - real(hi) * 1048576.0);
      res := shift_left(resize(to_signed(hi, 40), 40), 20)
           + resize(to_signed(lo, 40), 40);
      if neg then res := -res; end if;
      return res;
    end function;
  begin
    file_open(fh, VECS, read_mode);
    readline(fh, ln); read(ln, nc); read(ln, nn);
    assert nc = NCASE and nn = DIM
      report "tb_gdn_head_emit: vector file shape mismatch" severity failure;
    for c in 0 to NCASE-1 loop
      readline(fh, ln); read(ln, iv); read(ln, iv); v_eh(c) := iv;
                        read(ln, iv); v_sat(c) := iv;
      readline(fh, ln);
      for i in 0 to DIM-1 loop read(ln, rv); v_acc(c)(i) := rv; end loop;
      readline(fh, ln);
      for i in 0 to DIM-1 loop read(ln, iv); v_eo(c)(i) := iv; end loop;
      readline(fh, ln);
      for i in 0 to DIM-1 loop read(ln, iv); v_mnt(c)(i) := iv; end loop;
    end loop;
    file_close(fh);

    rst <= '1'; wait until rising_edge(clk); wait until rising_edge(clk);
    rst <= '0'; wait until rising_edge(clk);

    for c in 0 to NCASE-1 loop
      -- pass A: stream the head's columns in, one per cycle, which is the
      -- rate gdn_recur_pipe's o_res_valid actually produces them
      for i in 0 to DIM-1 loop
        in_valid <= '1';
        in_acc   <= to_s40(v_acc(c)(i));
        in_e_o   <= to_signed(v_eo(c)(i), 8);
        wait until rising_edge(clk);
      end loop;
      in_valid <= '0';

      -- passes B and C run without further input
      while done /= '1' loop wait until rising_edge(clk); end loop;

      if to_integer(o_e_head) /= v_eh(c) then
        report "case " & integer'image(c) & ": e_head got "
             & integer'image(to_integer(o_e_head)) & " want "
             & integer'image(v_eh(c)) severity error;
        nerr := nerr + 1;
      end if;
      if (o_sat = '1') /= (v_sat(c) = 1) then
        report "case " & integer'image(c) & ": o_sat mismatch" severity error;
        nerr := nerr + 1;
      end if;
      for i in 0 to DIM-1 loop
        got := to_integer(signed(o_mant((i+1)*16-1 downto i*16)));

        -- CHECK 2, the real-valued oracle, against the DUT's OWN output and
        -- the DUT's OWN exponent.  It shares nothing with the integer recipe:
        -- the true value the (o_acc, e_o) pair denotes is o_acc * 2^-e_o, the
        -- DUT says o_mant * 2^-e_head, and one output LSB is 2^-e_head, so the
        -- error in output LSB is |o_mant - o_acc * 2^(e_head - e_o)|.
        --
        -- Exactness of the `real`: v_acc is |o_acc| < 2^37, exact in a double,
        -- and the scaling is by a power of two, which only moves the exponent.
        -- The subtraction is exact whenever the two operands' bits span 53 or
        -- fewer places; where it is not (a very large e_o - e_head), the
        -- scaled reference is below 2^-3 and the result is dominated by the
        -- integer `got`, so the absolute error of the computation is ~1e-16
        -- against thresholds of 0.5 and up.  No threshold here is decided at
        -- that precision.
        if i = 0 then
          a_amax := abs(got); a_emin := v_eo(c)(0);
        else
          if abs(got) > a_amax then a_amax := abs(got); end if;
          if v_eo(c)(i) < a_emin then a_emin := v_eo(c)(i); end if;
        end if;
        a_ref := v_acc(c)(i) * (2.0 ** (to_integer(o_e_head) - v_eo(c)(i)));
        a_err := abs(real(got) - a_ref);
        a_n   := a_n + 1;
        a_sum := a_sum + a_err;
        if a_err > a_max then a_max := a_err; a_mcase := c; a_mcol := i; end if;
        if a_err > real(ACC_NEAR_M) / 1000.0 then a_near := a_near + 1; end if;
      end loop;

      -- CHECK 3, the NORMALISATION headroom.  sh_h = e_h - e_head, and e_h is
      -- the minimum column exponent, so the bench can recover the shift from
      -- the DUT's own e_head without knowing how it was computed.
      a_sh := a_emin - to_integer(o_e_head);
      if a_sh > 0 and a_amax < ACC_NORM_FLOOR then
        report "case " & integer'image(c)
             & ": NORMALISATION -- the requantize shifted by "
             & integer'image(a_sh) & " yet the largest |o_mant| is only "
             & integer'image(a_amax) & ", under the floor of "
             & integer'image(ACC_NORM_FLOOR)
             & ".  sh_h > 0 means oamax >= 2^(sh_h+14), so the result must"
             & " fill the grid.  A grid one octave too coarse is INVISIBLE to"
             & " any error measured in LSB of that same grid, which is why"
             & " this check is not a tolerance." severity error;
        nrm_bad := nrm_bad + 1;
      end if;

      -- The bit-exact comparison is a SEPARATE loop, and it is separate for a
      -- reason: it reports only the first mismatching column and then stops,
      -- so folding the oracle into it would let a single early RTL mismatch
      -- silently shorten a_n and turn the accuracy FLOOR into a second report
      -- of the same defect rather than an independent one.
      for i in 0 to DIM-1 loop
        got := to_integer(signed(o_mant((i+1)*16-1 downto i*16)));
        if got /= v_mnt(c)(i) then
          report "case " & integer'image(c) & " col " & integer'image(i)
               & ": mant got " & integer'image(got)
               & " want " & integer'image(v_mnt(c)(i)) severity error;
          nerr := nerr + 1;
          exit;
        end if;
      end loop;

      wait until rising_edge(clk);
    end loop;

    -- ==================================================================
    -- OVERLAP PHASE.  The reason the unit is double buffered: gdn_recur_pipe
    -- starts the next head immediately, so head h+1's columns arrive WHILE
    -- head h is still reducing.  The single-banked first version ignored
    -- in_valid during the reduce and would have dropped them silently, which
    -- is why this phase exists and why it drives with NO gap at all.
    snapping <= true; snap_n := 0; ready_fell := false;
    ocount <= true;
    wait until rising_edge(clk);
    for c in 0 to 3 loop
      for i in 0 to DIM-1 loop
        -- Proper valid/ready handshake: hold valid and the data until an edge
        -- where ready is also high.  Back-pressure WILL assert here: this
        -- phase fills a head in 128 cycles against a 268-cycle reduce, which
        -- is far tighter than the real 512-cycle arrival, so it is a harder
        -- test than the hardware will ever see.  Stalling is correct;
        -- dropping is not, and the single-banked version dropped.
        in_valid <= '1';
        in_acc   <= to_s40(v_acc(c)(i));
        in_e_o   <= to_signed(v_eo(c)(i), 8);
        loop
          wait until rising_edge(clk);
          exit when in_ready = '1';
        end loop;
      end loop;
      in_valid <= '0';
    end loop;
    -- drain the last head
    while snap_n < 4 loop wait until rising_edge(clk); end loop;
    snapping <= false;
    report "overlap phase: 4 heads back-to-back took " & integer'image(ocyc)
         & " cycles" severity note;
    -- MEASURED: **1,202** cycles double buffered against **1,586** with the
    -- two banks collapsed into one, for the same 4 heads and, note, the same
    -- CORRECT results in both cases.  The bound sits between them rather than
    -- at either, so it fails on a collapse to one bank while leaving room for
    -- pipeline changes that do not undo the overlap.
    if ocyc > 1300 then
      report "OVERLAP THROUGHPUT: 4 heads took " & integer'image(ocyc)
           & " cycles, over the 1300 bound -- the reduce is NOT hiding behind "
           & "the next head's fill, i.e. the double buffer is not working"
        severity error;
      nerr := nerr + 1;
    end if;
    ocount <= false;

    for c in 0 to 3 loop
      if snap_e(c) /= v_eh(c) then
        report "OVERLAP case " & integer'image(c) & ": e_head got "
             & integer'image(snap_e(c)) & " want " & integer'image(v_eh(c))
          severity error;
        nerr := nerr + 1;
      end if;
      for i in 0 to DIM-1 loop
        if to_integer(signed(snap_m(c)((i+1)*16-1 downto i*16))) /= v_mnt(c)(i) then
          report "OVERLAP case " & integer'image(c) & " col " & integer'image(i)
               & ": got "
               & integer'image(to_integer(signed(snap_m(c)((i+1)*16-1 downto i*16))))
               & " want " & integer'image(v_mnt(c)(i)) severity error;
          nerr := nerr + 1;
          exit;
        end if;
      end loop;
    end loop;
    report "overlap phase: back-pressure asserted at least once: "
         & boolean'image(ready_fell) severity note;

    -- ==================================================================
    -- THE ACCURACY VERDICT.  Reported unconditionally, so the honest figures
    -- are in the log of every green run and a later drift is visible without
    -- re-instrumenting anything.
    report "gdn_head_emit accuracy vs the real-valued oracle, NOTHING excluded:"
         & " worst " & real'image(a_max) & " LSB at case "
         & integer'image(a_mcase) & " col " & integer'image(a_mcol) & "; "
         & integer'image(a_near) & " of " & integer'image(a_n)
         & " elements past " & real'image(real(ACC_NEAR_M)/1000.0)
         & " LSB; mean " & real'image(a_sum / real(maximum(a_n, 1))) & " LSB"
      severity note;

    acc_bad := 0;
    -- The FLOOR first, because it is the one that decides whether the other
    -- three figures are evidence at all.  An oracle that saw nothing reports
    -- 0.0000 and 0, which is indistinguishable from a perfect unit -- and that
    -- is not hypothetical here: it is exactly what the GENERATOR's oracle does
    -- under mutation B4, because its exclusion is on an output property.
    if a_n < ACC_MIN_CHECK then
      report "gdn_head_emit: OUT OF TOLERANCE -- the oracle saw only "
           & integer'image(a_n) & " elements, floor is "
           & integer'image(ACC_MIN_CHECK)
           & ".  The accuracy figures above are NOT evidence." severity error;
      acc_bad := acc_bad + 1;
    end if;
    if a_max > real(ACC_MAXLSB_M) / 1000.0 then
      report "gdn_head_emit: OUT OF TOLERANCE -- worst accuracy error "
           & real'image(a_max) & " LSB exceeds "
           & real'image(real(ACC_MAXLSB_M)/1000.0) & " LSB (case "
           & integer'image(a_mcase) & " col " & integer'image(a_mcol)
           & ").  The derived bound is 2^-sh + 0.5*[sh>0] < 1.0 output LSB,"
           & " from the alignment floor plus the requantize round; anything"
           & " past it is the recipe, not the grid." severity error;
      acc_bad := acc_bad + 1;
    end if;
    if a_sum / real(maximum(a_n, 1)) > real(ACC_MEAN_M) / 1000.0 then
      report "gdn_head_emit: OUT OF TOLERANCE -- mean accuracy error "
           & real'image(a_sum / real(maximum(a_n, 1))) & " LSB exceeds "
           & real'image(real(ACC_MEAN_M)/1000.0)
           & " LSB.  The mean is the seat of a SYSTEMATIC error: dropping the"
           & " requantize round bias moves it 0.1035 -> 0.3847 while the max"
           & " moves 0.999985 -> 1.000000." severity error;
      acc_bad := acc_bad + 1;
    end if;
    if a_near > ACC_NEAR_MAX then
      report "gdn_head_emit: OUT OF TOLERANCE -- " & integer'image(a_near)
           & " elements past " & real'image(real(ACC_NEAR_M)/1000.0)
           & " LSB, cap is " & integer'image(ACC_NEAR_MAX)
           & ".  A max alone cannot see a distribution shift; this is the"
           & " half that can, and it is the ONLY figure here with usable"
           & " resolution against a truncated requantize." severity error;
      acc_bad := acc_bad + 1;
    end if;

    if nrm_bad > 0 then
      report "gdn_head_emit: NORMALISATION failed on " & integer'image(nrm_bad)
           & " of " & integer'image(NCASE) & " cases" severity error;
      acc_bad := acc_bad + nrm_bad;
    end if;

    if nerr = 0 and acc_bad = 0 then
      report "tb_gdn_head_emit: PASS -- " & integer'image(NCASE)
           & " cases x " & integer'image(DIM)
           & " bit-exact, plus 4 heads back-to-back with no gap; and within "
           & real'image(real(ACC_MAXLSB_M)/1000.0)
           & " LSB of the real-valued oracle on every one of "
           & integer'image(a_n) & " elements" severity note;
    else
      nerr := nerr + acc_bad;
      report "tb_gdn_head_emit: FAIL -- " & integer'image(nerr) & " mismatches"
        severity failure;
    end if;
    running <= false;
    wait;
  end process;
end architecture;
