-- sim/tb_gdn_y_emit.vhd
-- Bit-exactness of rtl/gdn_y_emit.vhd (subsystem B SITE 13) against
-- ref/gdn_y_emit_vec.c, PLUS a real-valued accuracy gate on the DUT's own
-- outputs.
--
-- WHY THE ACCURACY GATE IS HERE AND NOT IN THE GENERATOR.  Until 2026-08-29
-- this file said "NO TOLERANCE" and left the real-valued claim to
-- ref/gdn_y_emit_vec.c, which computes a double oracle, PRINTS it and returns
-- 1 if it reaches 1.0 LSB.  sim/regress.sh never runs that generator --
-- sim/gdn_y_emit_vec.txt is committed and regress.sh regenerates a vector only
-- when the file is absent -- so the gate consulted none of it.  A recipe error
-- present in the RTL and the C together was invisible to the whole suite.  The
-- claim is therefore made here, against the DUT's outputs, which is also the
-- only place it can see an RTL-ONLY accuracy defect.
--
-- AND THE GENERATOR'S ORACLE HAS A HOLE THIS ONE DOES NOT.  It accumulates
-- only `if (!sat_any && ...)`, and `sat_any` is a WHOLE-CASE flag raised when
-- any single element saturated -- an exclusion on an OUTPUT property.  MEASURED
-- on the committed vectors: dropping the output rail from 16 bits to 15 in the
-- RTL and the C together (mutation B4 of sim/mutate_gdn_y_emit.sh) makes 41 of
-- 48 cases saturate, and the other 7 are the all-zero case shape, so 41 + 7 =
-- 48 and the oracle measures NOTHING BUT ZEROS.  It prints 0.0000 LSB and
-- returns OK on a unit that is 15854 LSB wrong.
--
-- EXCLUDING ONLY THE SATURATED ELEMENTS DOES NOT FIX IT, AND THAT IS THE
-- LESS OBVIOUS HALF.  MEASURED with an independent oracle over the same
-- vectors: under B4 the element-excluded max is 0.750000 and the
-- element-excluded count past 0.5 LSB is 3492 -- both EXACTLY the honest
-- unit's figures, to every digit, because what B4 does is move error out of
-- the measured population rather than change what is left in it.  Only the
-- mean (0.1559 -> 0.1993) and the population size (147456 -> 112582) move at
-- all.  So the oracle below excludes NOTHING, and the FLOOR generic exists to
-- make any future exclusion loud.
--
-- The bit-exact comparison against the C is unchanged and is still the primary
-- check.  The tolerance cannot hide a disagreement between the two because it
-- is a SECOND, independent verdict, not a loosening of the first.
--
-- Cases are read and run ONE AT A TIME rather than slurped up front: at 24
-- heads x 128 the vectors are 3,072 elements per case and three arrays deep,
-- so holding all of them would be ~450k integers for no benefit.
--
-- The vector file leads with the cases that are easy to get wrong: all
-- exponents equal, an all-zero case (which pins the msb_pos(0) = 0
-- convention), a wide exponent spread, both operands at -32768 (the product
-- maximum 2^30 EXACTLY, the case an over-strict width bound gets wrong),
-- negatives just under a power of two (the counterexample that kills the
-- one-pass amax shortcut), and saturation.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use ieee.math_real.all;   -- for the real-valued accuracy oracle below
use std.textio.all;

entity tb_gdn_y_emit is
  generic( HEADS : positive := 24;
           DIM   : positive := 128;
           VECS  : string   := "gdn_y_emit_vec.txt";
           -- Cycle bound for the overlap phase.  MEASURED: 15,390 cycles
           -- double buffered against 18,462 with the two banks collapsed into
           -- one, for the same 2 blocks and -- note -- the same CORRECT
           -- results in both cases.  17,000 sits between them, so it fails on
           -- a collapse while leaving room for pipeline changes that do not
           -- undo the overlap.
           OCYC_BOUND : positive := 17000;
           -- Accuracy gate, in THOUSANDTHS of an output LSB so that the whole
           -- gate is overridable from sim/regress.sh.  ghdl-mcode cannot
           -- override a `real` generic at all ("unhandled type for generic
           -- override of ..." and elaboration dies), so a real here would be a
           -- knob nobody can turn, and one that cannot be teeth-checked.
           --
           --   ACC_MAXLSB_M   cap on the worst |y - oracle|, milli-LSB.
           --   ACC_NEAR_M     the counting threshold, milli-LSB.
           --   ACC_NEAR_MAX   how many elements may exceed it.
           --   ACC_MEAN_M     cap on the MEAN |y - oracle|, milli-LSB.
           --   ACC_MIN_CHECK  FLOOR on how many elements entered the oracle.
           --
           -- FOUR NUMBERS AND NOT ONE, because on THIS unit each of them is
           -- measurably blind to a mutation another one catches:
           --   B4 (rail 16 -> 15 bits, in BOTH) is caught by the max, 15854
           --      against 0.75, and by the count, 31428 against 5648.
           --   B3 (requantize truncates, in BOTH) reaches only 1.000000 on the
           --      max, which no honest threshold can separate from the derived
           --      bound of 1.0, and 0.271581 on the mean, which no honest
           --      threshold can separate from the honest 0.204489.  It is
           --      caught by the COUNT alone, 28037 against 5648.
           -- The mean is kept because it is the figure that moves first under a
           -- systematic bias, and the max because it is the only one that is
           -- derived rather than fitted.  Neither is load bearing here; the
           -- COUNT is.
           --
           -- CALIBRATION IS A MEASUREMENT, NOT A CHOICE.  Every threshold below
           -- clears the unmutated unit at FORTY generator seeds (100003*i + 11,
           -- i = 1..40).  The honest envelope over those 40 seeds:
           --   worst      0.750000 at every one of the 40
           --   n > 0.5    930 .. 5648
           --   mean       0.113755 .. 0.204489
           -- Note how much wider the count's honest range is than the max's --
           -- 6.1x between its own extremes while the max does not move at all.
           -- A gate fitted to the committed seed's 3492 would fire on an honest
           -- unit the moment the vectors were regenerated.  Full tables in
           -- docs/debugging/2026-08-29_b-emit-accuracy-gates.md.
           --
           -- The count is an ABSOLUTE count at the committed shape
           -- (48 x 24 x 128 = 147456 elements).  Changing the case count,
           -- HEADS or DIM without rescaling ACC_NEAR_MAX and ACC_MIN_CHECK
           -- changes what they mean.
           ACC_MAXLSB_M  : integer := 1500;    -- honest 0.750000, B4 15854.13
           ACC_NEAR_M    : integer := 500;
           ACC_NEAR_MAX  : integer := 12000;   -- honest 5648, B3 28037, B4 31428
           ACC_MEAN_M    : integer := 350;     -- honest 0.2045, B4 92.94
           ACC_MIN_CHECK : integer := 147456;  -- 48*HEADS*DIM, nothing excluded
           -- A FIFTH check, and it is NOT an accuracy tolerance: it is the one
           -- property no error measured in LSB of the OUTPUT grid can ever
           -- have.  MEASURED: taking sh from msb_pos(amax)-14 to -13, which
           -- coarsens the output grid by a whole octave and throws away one bit
           -- of every mantissa, moves the no-exclusion oracle's worst from
           -- 0.750000 to 0.500000, its count past 0.5 LSB from 3492 to ZERO,
           -- and its mean from 0.1559 to 0.1588.  Every one of those moves the
           -- SAFE way, because the absolute error and the LSB double together.
           -- That is exactly the mutation sim/mutate_gdn_emit_chain.sh's B4
           -- records as an expected survivor of both oracles, where the
           -- generator's own figure went 1.1280 -> 0.8505, in the wrong
           -- direction.
           --
           -- So this claim is on the NORMALISATION instead.  sh is chosen so
           -- the largest aligned element fills the grid: sh > 0 implies
           -- amax >= 2^(sh+14), hence |round_shift(amax, sh)| >= 2^14.  The
           -- bench recovers sh as min(e_p) - y_exp from the DUT's OWN exponent,
           -- so it never asks how sh was computed.  DERIVED exactly, not fitted
           -- -- and therefore TIGHT: MEASURED, the honest unit attains exactly
           -- 16384 at all 40 seeds swept, always on the (-32768)^2 shape.  Zero
           -- margin is correct for an identity of the recipe, but it does mean
           -- an off-by-one in the comparison would be a false red, so the
           -- comparison is `<` and the constant is a generic.
           ACC_NORM_FLOOR : integer := 16384 );-- honest 16384, msb-13 8192, rail-15 16383
end entity;

architecture sim of tb_gdn_y_emit is
  constant NTOT : integer := HEADS * DIM;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  signal in_valid  : std_logic := '0';
  signal in_hfirst : std_logic := '0';
  signal in_o      : signed(15 downto 0) := (others => '0');
  signal in_z      : signed(15 downto 0) := (others => '0');
  signal in_e      : signed(7 downto 0)  := (others => '0');

  signal in_ready : std_logic;
  signal o_valid : std_logic;
  signal o_mant  : signed(15 downto 0);
  signal o_last  : std_logic;
  signal y_exp   : signed(7 downto 0);
  signal done    : std_logic;
  signal o_sat   : std_logic;

  signal running : boolean := true;

  type int_arr is array(natural range <>) of integer;
  -- collected by the monitor process
  shared variable got_y   : int_arr(0 to 4095);
  shared variable got_n   : integer := 0;
  shared variable got_last_at : integer := -1;
  -- Overlap phase.  Two SEPARATE properties, as the gdn_head_emit mutation run
  -- showed: no element is lost under back-pressure (the value check covers
  -- it), and the reduce hides behind the next block's fill (invisible to the
  -- value check -- a single-banked unit with a correct handshake merely stalls
  -- and still returns the right answers, so only CYCLES see it).
  shared variable ob_y : int_arr(0 to 4095);
  shared variable ob_n : integer := 0;
  shared variable ob_blocks : integer := 0;
  signal ob_on : boolean := false;
  signal ocyc : integer := 0;
  signal ocount : boolean := false;
begin
  clk <= not clk after 5 ns when running else '0';

  dut : entity work.gdn_y_emit
    generic map ( HEADS => HEADS, DIM => DIM )
    port map ( clk => clk, rst => rst,
               in_valid => in_valid, in_ready => in_ready,
               in_hfirst => in_hfirst,
               in_o => in_o, in_z => in_z, in_e => in_e,
               o_valid => o_valid, o_mant => o_mant, o_last => o_last,
               y_exp => y_exp, done => done, o_sat => o_sat );

  -- Collect the output stream.  o_last is recorded by INDEX, not merely
  -- checked as a flag, because the bug it guards against is o_last arriving
  -- one cycle after the final o_valid -- a consumer that only counts elements
  -- would never notice, so the testbench has to notice for it.
  mon : process(clk)
  begin
    if rising_edge(clk) then
      if o_valid = '1' then
        if got_n < got_y'length then got_y(got_n) := to_integer(o_mant); end if;
        if o_last = '1' then got_last_at := got_n; end if;
        got_n := got_n + 1;
      end if;
    end if;
  end process;

  ocnt : process(clk)
  begin
    if rising_edge(clk) then
      if ocount then ocyc <= ocyc + 1; else ocyc <= 0; end if;
    end if;
  end process;

  obmon : process(clk)
  begin
    if rising_edge(clk) then
      if ob_on then
        if o_valid = '1' then
          -- keep only the LAST block's elements; earlier blocks are already
          -- covered by the main phase
          if ob_n < ob_y'length then ob_y(ob_n) := to_integer(o_mant); end if;
          ob_n := ob_n + 1;
        end if;
        if done = '1' then
          ob_blocks := ob_blocks + 1;
          if ob_blocks < 2 then ob_n := 0; end if;   -- restart for block 2
        end if;
      end if;
    end if;
  end process;

  stim : process
    file fh : text;
    variable ln : line;
    variable iv, nc, nh, nd : integer;
    variable v_ep : int_arr(0 to 63);
    variable v_om, v_zm, v_y : int_arr(0 to 4095);
    variable v_ye, v_sat : integer;
    variable nerr : integer := 0;

    -- The real-valued oracle's running state.  Accumulated over the MAIN loop
    -- only: the overlap phase re-runs cases 0 and 1, and letting those two in
    -- a second time would inflate the count and pull the mean toward whatever
    -- those two happen to be.
    variable a_n     : integer := 0;
    variable a_near  : integer := 0;
    variable a_max   : real    := 0.0;
    variable a_sum   : real    := 0.0;
    variable a_mcase : integer := -1;
    variable a_melem : integer := -1;
    variable a_err   : real;
    variable a_ref   : real;
    variable a_scale : real;
    variable acc_bad : integer := 0;
    variable nrm_bad : integer := 0;
    variable a_amax  : integer;
    variable a_emin  : integer;
    variable a_sh    : integer;
  begin
    file_open(fh, VECS, read_mode);
    readline(fh, ln); read(ln, nc); read(ln, nh); read(ln, nd);
    assert nh = HEADS and nd = DIM
      report "tb_gdn_y_emit: vector file shape mismatch" severity failure;

    rst <= '1'; wait until rising_edge(clk); wait until rising_edge(clk);
    rst <= '0'; wait until rising_edge(clk);

    for c in 0 to nc-1 loop
      readline(fh, ln); read(ln, iv); read(ln, v_ye); read(ln, v_sat);
      readline(fh, ln);
      for h in 0 to HEADS-1 loop read(ln, iv); v_ep(h) := iv; end loop;
      readline(fh, ln);
      for i in 0 to NTOT-1 loop read(ln, iv); v_om(i) := iv; end loop;
      readline(fh, ln);
      for i in 0 to NTOT-1 loop read(ln, iv); v_zm(i) := iv; end loop;
      readline(fh, ln);
      for i in 0 to NTOT-1 loop read(ln, iv); v_y(i) := iv; end loop;

      got_n := 0; got_last_at := -1;

      -- pass A: stream the gated product's operands, one element per cycle
      for h in 0 to HEADS-1 loop
        for j in 0 to DIM-1 loop
          -- Proper valid/ready handshake: hold valid and the data until an
          -- edge where ready is also high.  The unit ignores in_valid for the
          -- whole of its reduce passes if it is not ready, so a driver that
          -- does not honour this loses elements silently.
          in_valid  <= '1';
          if j = 0 then in_hfirst <= '1'; else in_hfirst <= '0'; end if;
          in_o <= to_signed(v_om(h*DIM + j), 16);
          in_z <= to_signed(v_zm(h*DIM + j), 16);
          in_e <= to_signed(v_ep(h), 8);
          loop
            wait until rising_edge(clk);
            exit when in_ready = '1';
          end loop;
        end loop;
      end loop;
      in_valid <= '0'; in_hfirst <= '0';

      while done /= '1' loop wait until rising_edge(clk); end loop;

      if got_n /= NTOT then
        report "case " & integer'image(c) & ": emitted " & integer'image(got_n)
             & " elements, want " & integer'image(NTOT) severity error;
        nerr := nerr + 1;
      end if;
      if got_last_at /= NTOT-1 then
        report "case " & integer'image(c) & ": o_last at element "
             & integer'image(got_last_at) & ", want " & integer'image(NTOT-1)
             & " (o_last must coincide with the final o_valid)" severity error;
        nerr := nerr + 1;
      end if;
      if to_integer(y_exp) /= v_ye then
        report "case " & integer'image(c) & ": y_exp got "
             & integer'image(to_integer(y_exp)) & " want "
             & integer'image(v_ye) severity error;
        nerr := nerr + 1;
      end if;
      if (o_sat = '1') /= (v_sat = 1) then
        report "case " & integer'image(c) & ": o_sat mismatch" severity error;
        nerr := nerr + 1;
      end if;
      -- CHECK 5b, the real-valued oracle, against the DUT's OWN elements and
      -- the DUT's OWN exponent.  It shares nothing with the integer recipe:
      -- the true gated product is o_mant * z_mant * 2^-e_p[h], the DUT says
      -- y * 2^-y_exp, and one output LSB is 2^-y_exp, so the error in output
      -- LSB is |y - o_mant * z_mant * 2^(y_exp - e_p[h])|.
      --
      -- Exactness of the `real`: |o_mant * z_mant| <= 2^30, exact in a double,
      -- and the scaling is by a power of two, which only moves the exponent.
      -- The scale is hoisted out of the inner loop because it depends only on
      -- the head.  No threshold here is decided anywhere near double
      -- precision; the closest call is B3's 1.000000 against the honest
      -- 0.750000, and that one is deliberately NOT gated on the max.
      --
      -- It is a SEPARATE loop from the bit-exact comparison below, which
      -- reports only the first mismatching element and then stops: folding the
      -- two together would let one early RTL mismatch silently shorten a_n and
      -- turn the accuracy FLOOR into a second report of the same defect rather
      -- than an independent check.
      a_amax := 0; a_emin := v_ep(0);
      for h in 0 to HEADS-1 loop
        if v_ep(h) < a_emin then a_emin := v_ep(h); end if;
        a_scale := 2.0 ** (to_integer(y_exp) - v_ep(h));
        for j in 0 to DIM-1 loop
          a_ref := real(v_om(h*DIM + j)) * real(v_zm(h*DIM + j)) * a_scale;
          a_err := abs(real(got_y(h*DIM + j)) - a_ref);
          a_n   := a_n + 1;
          a_sum := a_sum + a_err;
          if a_err > a_max then
            a_max := a_err; a_mcase := c; a_melem := h*DIM + j;
          end if;
          if a_err > real(ACC_NEAR_M) / 1000.0 then a_near := a_near + 1; end if;
          if abs(got_y(h*DIM + j)) > a_amax then
            a_amax := abs(got_y(h*DIM + j));
          end if;
        end loop;
      end loop;

      -- CHECK 6, the NORMALISATION headroom.  sh = e_y_raw - y_exp, and
      -- e_y_raw is the minimum head exponent, so the bench can recover the
      -- shift from the DUT's own y_exp without knowing how it was computed.
      a_sh := a_emin - to_integer(y_exp);
      if a_sh > 0 and a_amax < ACC_NORM_FLOOR then
        report "case " & integer'image(c)
             & ": NORMALISATION -- the requantize shifted by "
             & integer'image(a_sh) & " yet the largest |y| is only "
             & integer'image(a_amax) & ", under the floor of "
             & integer'image(ACC_NORM_FLOOR)
             & ".  sh > 0 means amax >= 2^(sh+14), so the result must fill the"
             & " grid.  A grid one octave too coarse is INVISIBLE to any error"
             & " measured in LSB of that same grid, which is why this check is"
             & " not a tolerance." severity error;
        nrm_bad := nrm_bad + 1;
      end if;

      for i in 0 to NTOT-1 loop
        if got_y(i) /= v_y(i) then
          report "case " & integer'image(c) & " elem " & integer'image(i)
               & ": got " & integer'image(got_y(i))
               & " want " & integer'image(v_y(i)) severity error;
          nerr := nerr + 1;
          exit;
        end if;
      end loop;

      wait until rising_edge(clk);
    end loop;
    file_close(fh);

    -- ==================================================================
    -- OVERLAP PHASE: two blocks driven back-to-back with no gap.
    file_open(fh, VECS, read_mode);
    readline(fh, ln); read(ln, iv); read(ln, iv); read(ln, iv);
    ob_on <= true; ob_n := 0; ob_blocks := 0; ocount <= true;
    wait until rising_edge(clk);
    for c in 0 to 1 loop
      readline(fh, ln); read(ln, iv); read(ln, v_ye); read(ln, v_sat);
      readline(fh, ln);
      for h in 0 to HEADS-1 loop read(ln, iv); v_ep(h) := iv; end loop;
      readline(fh, ln);
      for i in 0 to NTOT-1 loop read(ln, iv); v_om(i) := iv; end loop;
      readline(fh, ln);
      for i in 0 to NTOT-1 loop read(ln, iv); v_zm(i) := iv; end loop;
      readline(fh, ln);
      for i in 0 to NTOT-1 loop read(ln, iv); v_y(i) := iv; end loop;
      for h in 0 to HEADS-1 loop
        for j in 0 to DIM-1 loop
          in_valid <= '1';
          if j = 0 then in_hfirst <= '1'; else in_hfirst <= '0'; end if;
          in_o <= to_signed(v_om(h*DIM + j), 16);
          in_z <= to_signed(v_zm(h*DIM + j), 16);
          in_e <= to_signed(v_ep(h), 8);
          loop
            wait until rising_edge(clk);
            exit when in_ready = '1';
          end loop;
        end loop;
      end loop;
      in_valid <= '0'; in_hfirst <= '0';
    end loop;
    while ob_blocks < 2 loop wait until rising_edge(clk); end loop;
    ocount <= false; ob_on <= false;
    file_close(fh);

    report "overlap phase: 2 blocks back-to-back took " & integer'image(ocyc)
         & " cycles" severity note;
    for i in 0 to NTOT-1 loop
      if ob_y(i) /= v_y(i) then
        report "OVERLAP block 2 elem " & integer'image(i) & ": got "
             & integer'image(ob_y(i)) & " want " & integer'image(v_y(i))
          severity error;
        nerr := nerr + 1;
        exit;
      end if;
    end loop;
    if ocyc > OCYC_BOUND then
      report "OVERLAP THROUGHPUT: 2 blocks took " & integer'image(ocyc)
           & " cycles, over the bound -- the reduce is NOT hiding behind the "
           & "next block's fill" severity error;
      nerr := nerr + 1;
    end if;

    -- ==================================================================
    -- THE ACCURACY VERDICT.  Reported unconditionally, so the honest figures
    -- are in the log of every green run and a later drift is visible without
    -- re-instrumenting anything.
    report "gdn_y_emit accuracy vs the real-valued oracle, NOTHING excluded:"
         & " worst " & real'image(a_max) & " LSB at case "
         & integer'image(a_mcase) & " elem " & integer'image(a_melem) & "; "
         & integer'image(a_near) & " of " & integer'image(a_n)
         & " elements past " & real'image(real(ACC_NEAR_M)/1000.0)
         & " LSB; mean " & real'image(a_sum / real(maximum(a_n, 1))) & " LSB"
      severity note;

    acc_bad := 0;
    if nrm_bad > 0 then
      report "gdn_y_emit: NORMALISATION failed on " & integer'image(nrm_bad)
           & " of " & integer'image(nc) & " cases" severity error;
      acc_bad := acc_bad + nrm_bad;
    end if;
    -- The FLOOR next, because it is the one that decides whether the other
    -- three figures are evidence at all.  An oracle that saw nothing reports
    -- 0.0000 and 0, which is indistinguishable from a perfect unit -- and that
    -- is not hypothetical here: it is exactly what the GENERATOR's oracle does
    -- under mutation B4, because its exclusion is on an output property.
    if a_n < ACC_MIN_CHECK then
      report "gdn_y_emit: OUT OF TOLERANCE -- the oracle saw only "
           & integer'image(a_n) & " elements, floor is "
           & integer'image(ACC_MIN_CHECK)
           & ".  The accuracy figures above are NOT evidence." severity error;
      acc_bad := acc_bad + 1;
    end if;
    if a_max > real(ACC_MAXLSB_M) / 1000.0 then
      report "gdn_y_emit: OUT OF TOLERANCE -- worst accuracy error "
           & real'image(a_max) & " LSB exceeds "
           & real'image(real(ACC_MAXLSB_M)/1000.0) & " LSB (case "
           & integer'image(a_mcase) & " elem " & integer'image(a_melem)
           & ").  The derived bound is 2^-sh + 0.5*[sh>0] < 1.0 output LSB,"
           & " from the alignment floor plus the requantize round; anything"
           & " past it is the recipe, not the grid." severity error;
      acc_bad := acc_bad + 1;
    end if;
    if a_sum / real(maximum(a_n, 1)) > real(ACC_MEAN_M) / 1000.0 then
      report "gdn_y_emit: OUT OF TOLERANCE -- mean accuracy error "
           & real'image(a_sum / real(maximum(a_n, 1))) & " LSB exceeds "
           & real'image(real(ACC_MEAN_M)/1000.0)
           & " LSB.  The mean is the seat of a SYSTEMATIC error, but on this"
           & " unit it has the LEAST resolution of the four: it does not"
           & " separate a truncated requantize (0.2716) from an honest seed"
           & " (0.2045)." severity error;
      acc_bad := acc_bad + 1;
    end if;
    if a_near > ACC_NEAR_MAX then
      report "gdn_y_emit: OUT OF TOLERANCE -- " & integer'image(a_near)
           & " elements past " & real'image(real(ACC_NEAR_M)/1000.0)
           & " LSB, cap is " & integer'image(ACC_NEAR_MAX)
           & ".  This is the load-bearing figure on this unit: it is the only"
           & " one of the four that separates a truncated requantize from an"
           & " honest seed." severity error;
      acc_bad := acc_bad + 1;
    end if;

    if nerr = 0 and acc_bad = 0 then
      report "tb_gdn_y_emit: PASS -- " & integer'image(nc) & " cases x "
           & integer'image(HEADS) & " heads x " & integer'image(DIM)
           & " bit-exact; and within "
           & real'image(real(ACC_MAXLSB_M)/1000.0)
           & " LSB of the real-valued oracle on every one of "
           & integer'image(a_n) & " elements" severity note;
    else
      nerr := nerr + acc_bad;
      report "tb_gdn_y_emit: FAIL -- " & integer'image(nerr) & " mismatches"
        severity failure;
    end if;
    running <= false;
    wait;
  end process;
end architecture;
