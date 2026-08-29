-- sim/tb_gdn_silu.vhd -- gdn_silu against ref/gdn_silu_vec.c.
--
-- TWO CHECKS, ON PURPOSE, AND THEY ANSWER DIFFERENT QUESTIONS.
--
--  1. BIT-EXACT against ref/gdn_silu_vec.c, no tolerance.  The reference
--     implements 2.1.3's recipe in C and the unit implements it in VHDL; the
--     two are different transcriptions of one specification, so any difference
--     at all is a transcription error and a tolerance would only hide it.
--
--  2. ACCURACY against a REAL-VALUED oracle computed here, in this file, from
--     sm and e alone.  This is what check 1 cannot see: a recipe error present
--     in BOTH transcriptions is bit-exact-green by construction, and so is any
--     accuracy defect that survives a regeneration of the golden.
--
-- WHY CHECK 2 MOVED IN HERE (2026-08-29).  It used to live in the generator,
-- which computes the same figure and PRINTS it.  sim/regress.sh never runs
-- that generator -- sim/gdn_silu_vec.txt is committed, and a committed vector
-- with no tb_vector_args row is not regenerated -- so nothing in the gate ever
-- read the figure.  The measured consequence for the sibling unit rmsnorm_bf
-- was a BOTH-class mutation that is bit-exact-green and 1.7e10 output LSB
-- wrong.  Moving the claim into the bench also makes it a claim about the
-- DUT's own o_data rather than about the C's array, which is the difference
-- between an accuracy gate and a golden-freshness gate.
--
-- The two checks stay separate rather than being merged into one tolerance:
-- a testbench that checks ONLY accuracy cannot detect a wrong recipe, because
-- a wrong recipe that is accurate enough passes.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

entity tb_gdn_silu is
  generic( LANES : positive := 4;
           ARG_Q : integer  := 12;
           N     : positive := 128;
           NCASE : positive := 256;
           -- Accuracy gate, in THOUSANDTHS of an output LSB so that the whole
           -- gate is overridable from sim/regress.sh.  ghdl-mcode cannot
           -- override a `real` generic at all ("unhandled type for generic
           -- override"), so a real here would be a knob nobody can turn.
           --
           -- ACC_MAXLSB_M   cap on the worst |o_data - oracle|, milli-LSB.
           -- ACC_NEAR_M     the counting threshold, milli-LSB.
           -- ACC_NEAR_MAX   how many elements may exceed it.
           -- ACC_MEAN_M     cap on the MEAN |o_data - oracle|, milli-LSB.
           -- ACC_MIN_CHECK  FLOOR on how many elements entered the oracle.
           --
           -- FOUR NUMBERS AND NOT ONE, because each is blind to something.
           -- A max alone is blind to a distribution shift.  A mean alone is
           -- blind to a single catastrophic element.  A count sits between
           -- them.  And the FLOOR is what makes an EMPTIED oracle loud instead
           -- of reporting 0.0000 and passing.
           --
           -- CALIBRATION, and it is a MEASUREMENT rather than a choice.  Every
           -- threshold below clears the UNMUTATED unit at nine generator seeds
           -- (20260826, 1, 2, 7, 42, 123, 999, 31337, 20260829) and still
           -- kills all four BOTH-class mutations of sim/mutate_gdn_silu.sh.
           -- Calibrating on the committed seed alone would have been wrong:
           -- over those nine seeds the honest worst case moves 1.844 -> 2.621
           -- LSB and the honest count past 1.5 LSB moves 5 -> 45, so a gate
           -- fitted to the committed 1.844/14 would fire on an honest unit the
           -- moment the vectors were regenerated.  Full table in
           -- docs/debugging/2026-08-29_b-accuracy-gates.md.
           --
           -- The count is an ABSOLUTE count at the committed shape (256 x 128
           -- = 32768 elements).  Changing NCASE or N without rescaling it
           -- changes what it means.
           ACC_MAXLSB_M  : integer := 3500;   -- honest worst 2.621, B3 5.249
           ACC_NEAR_M    : integer := 1500;
           ACC_NEAR_MAX  : integer := 60;     -- honest worst 45, B4 85
           ACC_MEAN_M    : integer := 200;    -- honest worst 0.138, B2 5.13
           ACC_MIN_CHECK : integer := 32768;
           VECS  : string   := "gdn_silu_vec.txt" );
end entity;

architecture sim of tb_gdn_silu is
  constant NB : integer := N / LANES;
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal e_seg : signed(7 downto 0) := (others => '0');
  signal s_valid : std_logic := '0';
  signal s_data  : std_logic_vector(LANES*16-1 downto 0) := (others => '0');
  signal o_valid : std_logic;
  signal o_data  : std_logic_vector(LANES*16-1 downto 0);

  type i_arr is array (natural range <>) of integer;
  type seg_arr is array (0 to NCASE-1) of i_arr(0 to N-1);
  signal loaded : boolean := false;
  shared variable v_sm, v_y : seg_arr;
  shared variable v_e : i_arr(0 to NCASE-1);
  shared variable nfail, ncheck : integer := 0;

  -- ---------------------------------------------------------------------
  -- The oracle.  Written as the DEFINITION of silu and nothing else: it
  -- knows nothing about ARG_Q, the sigma table, the interpolation, the Q15
  -- output grid or either rounding rule, and it would not change if every one
  -- of them were rewritten.  Its only shared input with the DUT is sm and e.
  --
  -- It returns the true value IN LSB OF THE OUTPUT GRID, which is the same
  -- grid sm is on: silu preserves the exponent, so
  --   y_true * 2^e = (sm * 2^-e) * sigmoid(x) * 2^e = sm * sigmoid(x).
  -- Measuring in LSB rather than relatively is deliberate.  Relative error on
  -- a quantizer reports 33% on a result whose true value is 1.5 LSB of its own
  -- grid, which is the quantizer working correctly.
  --
  -- THE |x| >= 40 GUARD IS NOT AN APPROXIMATION THAT MATTERS, and it is not
  -- cosmetic either: e reaches -30, so x reaches 32767*2^30 = 3.5e13 and
  -- exp(-x) overflows.  C's exp returns +inf there and the division silently
  -- yields 0; ieee.math_real is not required to, so the guard is explicit.
  -- DERIVED bound on what the guard costs: for x >= 40,
  -- |sigmoid(x) - 1| = 1/(1+e^x) < e^-40 = 4.25e-18, and |sm| <= 32768, so
  -- the substitution moves the oracle by less than 1.4e-13 LSB.  The same
  -- bound holds at the other rail.  That is 12 orders of magnitude below the
  -- gate and 13 below the measured worst case.
  function silu_lsb(sm : integer; e : integer) return real is
    variable xd, sg : real;
  begin
    xd := real(sm) * (2.0 ** (-e));
    if    xd >=  40.0 then sg := 1.0;
    elsif xd <= -40.0 then sg := 0.0;
    else                   sg := 1.0 / (1.0 + exp(-xd));
    end if;
    return real(sm) * sg;
  end function;

  shared variable a_max   : real    := 0.0;   -- worst |dut - oracle|, LSB
  shared variable a_mcase : integer := -1;
  shared variable a_melem : integer := -1;
  shared variable a_near  : integer := 0;     -- count past ACC_NEAR_M
  shared variable a_n     : integer := 0;     -- elements the oracle saw
  shared variable a_sum   : real    := 0.0;   -- sum |dut - oracle|, for the mean
  -- The clock is GUARDED.  Unguarded, it keeps toggling after the stimulus
  -- process reaches its final `wait;`, so the simulation never ends: the test
  -- reports PASS and then spins at 100% CPU forever.  One such run was found
  -- alive after 4h58m.  It is invisible when output is piped through `tail`,
  -- because the report has already been printed by then.
  signal running : boolean := true;

begin
  clk <= not clk after 5 ns when running else '0';

  dut : entity work.gdn_silu
    generic map(LANES => LANES, ARG_Q => ARG_Q)
    port map(clk => clk, rst => rst, e_seg => e_seg,
             s_valid => s_valid, s_data => s_data,
             o_valid => o_valid, o_data => o_data);

  load : process
    file fh : text; variable ln : line; variable iv, nc, nn : integer;
  begin
    file_open(fh, VECS, read_mode);
    readline(fh, ln); read(ln, nc); read(ln, nn);
    assert nc = NCASE and nn = N report "vector file shape" severity failure;
    for c in 0 to NCASE-1 loop
      readline(fh, ln); read(ln, iv); read(ln, iv); v_e(c) := iv;
      readline(fh, ln); for i in 0 to N-1 loop read(ln, iv); v_sm(c)(i) := iv; end loop;
      readline(fh, ln); for i in 0 to N-1 loop read(ln, iv); v_y(c)(i) := iv; end loop;
    end loop;
    file_close(fh);
    loaded <= true; wait;
  end process;

  drive : process
    variable acc_bad : integer := 0;
  begin
    wait until loaded;
    wait for 40 ns; rst <= '0'; wait until rising_edge(clk);
    for c in 0 to NCASE-1 loop
      -- e_seg is set BEFORE the segment and held: it is a per-segment scalar,
      -- and the unit reads it combinationally at S0.  Changing it mid-segment
      -- would corrupt the groups still inside the pipe, which is the same
      -- head-boundary hazard gdn_recur_pipe had to double-buffer for.  Here
      -- the segments are drained between cases instead, because silu has no
      -- throughput reason to overlap them.
      e_seg <= to_signed(v_e(c), 8);
      wait until rising_edge(clk);
      for g in 0 to NB-1 loop
        s_valid <= '1';
        for k in 0 to LANES-1 loop
          s_data((k+1)*16-1 downto k*16)
            <= std_logic_vector(to_signed(v_sm(c)(g*LANES + k), 16));
        end loop;
        wait until rising_edge(clk);
      end loop;
      s_valid <= '0';
      for d in 0 to 11 loop wait until rising_edge(clk); end loop;
    end loop;
    for d in 0 to 31 loop wait until rising_edge(clk); end loop;
    assert nfail = 0
      report "gdn_silu: " & integer'image(nfail) & " mismatch(es) in "
           & integer'image(ncheck) & " groups" severity error;

    -- ---- CHECK 2's verdict.  Reported unconditionally, so the figures are in
    -- the log of a passing run too and a later drift can be dated.
    report "gdn_silu accuracy vs the real-valued oracle: worst "
         & real'image(a_max) & " LSB at case " & integer'image(a_mcase)
         & " element " & integer'image(a_melem) & "; " & integer'image(a_near)
         & " of " & integer'image(a_n) & " elements past "
         & real'image(real(ACC_NEAR_M)/1000.0) & " LSB; mean "
         & real'image(a_sum / real(maximum(a_n, 1))) & " LSB" severity note;

    acc_bad := 0;
    -- The FLOOR first, because it is the one that decides whether the other
    -- three figures mean anything.  An oracle that saw nothing reports 0.0000
    -- and 0, which is indistinguishable from a perfect unit.
    if a_n < ACC_MIN_CHECK then
      report "gdn_silu: OUT OF TOLERANCE -- the oracle saw only "
           & integer'image(a_n) & " elements, floor is "
           & integer'image(ACC_MIN_CHECK)
           & ".  The accuracy figures below are NOT evidence." severity error;
      acc_bad := acc_bad + 1;
    end if;
    if a_max > real(ACC_MAXLSB_M) / 1000.0 then
      report "gdn_silu: OUT OF TOLERANCE -- worst accuracy error "
           & real'image(a_max) & " LSB exceeds "
           & real'image(real(ACC_MAXLSB_M)/1000.0) & " LSB (case "
           & integer'image(a_mcase) & " element " & integer'image(a_melem)
           & ")" severity error;
      acc_bad := acc_bad + 1;
    end if;
    if a_sum / real(maximum(a_n, 1)) > real(ACC_MEAN_M) / 1000.0 then
      report "gdn_silu: OUT OF TOLERANCE -- mean accuracy error "
           & real'image(a_sum / real(maximum(a_n, 1))) & " LSB exceeds "
           & real'image(real(ACC_MEAN_M)/1000.0) & " LSB.  The mean is the"
           & " seat of a SYSTEMATIC error: it moved 0.1186 -> 5.13 LSB under"
           & " the halved-interpolation-slope mutation while the max moved"
           & " only 1.84 -> 253." severity error;
      acc_bad := acc_bad + 1;
    end if;
    if a_near > ACC_NEAR_MAX then
      report "gdn_silu: OUT OF TOLERANCE -- " & integer'image(a_near)
           & " elements past " & real'image(real(ACC_NEAR_M)/1000.0)
           & " LSB, cap is " & integer'image(ACC_NEAR_MAX)
           & ".  A max alone cannot see a distribution shift; this is the"
           & " half that can." severity error;
      acc_bad := acc_bad + 1;
    end if;

    if nfail = 0 and acc_bad = 0 then
      report "gdn_silu: bit-exact with the C reference on all "
           & integer'image(ncheck) & " groups (" & integer'image(ncheck*LANES)
           & " elements), LANES=" & integer'image(LANES)
           & " ARG_Q=" & integer'image(ARG_Q)
           & "; and within " & real'image(real(ACC_MAXLSB_M)/1000.0)
           & " LSB of the real-valued oracle on every one of them"
           severity note;
    end if;
    running <= false;
    wait;
  end process;

  collect : process(clk)
    variable c, g : integer := 0;
    variable got, want : integer;
    variable err : real;
  begin
    if rising_edge(clk) and rst = '0' then
      if o_valid = '1' then
        for k in 0 to LANES-1 loop
          got  := to_integer(signed(o_data((k+1)*16-1 downto k*16)));
          want := v_y(c)(g*LANES + k);
          -- CHECK 2, against the DUT's own output.  Every element enters it:
          -- silu has no saturation rail and no case that has to be excluded,
          -- so a_n must come out at exactly NCASE*N and the FLOOR below is a
          -- hard equality in practice rather than a soft bound.
          err := abs(real(got) - silu_lsb(v_sm(c)(g*LANES + k), v_e(c)));
          a_n := a_n + 1;
          if err > a_max then
            a_max := err; a_mcase := c; a_melem := g*LANES + k;
          end if;
          if err > real(ACC_NEAR_M) / 1000.0 then a_near := a_near + 1; end if;
          a_sum := a_sum + err;
          if got /= want then
            report "case " & integer'image(c) & " (e=" & integer'image(v_e(c))
                 & ") element " & integer'image(g*LANES + k)
                 & ": got " & integer'image(got) & " want " & integer'image(want)
                 & "  from sm " & integer'image(v_sm(c)(g*LANES + k))
              severity error;
            nfail := nfail + 1;
          end if;
        end loop;
        ncheck := ncheck + 1;
        if g = NB-1 then g := 0; c := c + 1; else g := g + 1; end if;
      end if;
    end if;
  end process;
end architecture;
