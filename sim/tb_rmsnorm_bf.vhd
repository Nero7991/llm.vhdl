-- sim/tb_rmsnorm_bf.vhd -- rmsnorm_bf against ref/rmsnorm_bf_vec.c.
--
-- TWO CHECKS, ON PURPOSE, AND THEY ANSWER DIFFERENT QUESTIONS.
--
--  1. BIT-EXACT against ref/rmsnorm_bf_vec.c, no tolerance.  The reference
--     implements the unit's integer recipe in C and the unit implements it in
--     VHDL; the two are different transcriptions of one specification, so any
--     difference at all is a transcription error and a tolerance would hide it.
--
--  2. ACCURACY against a REAL-VALUED oracle computed here, in this file, from
--     x_mant, x_exp, w_mant, w_exp and EPS alone.
--
-- WHY CHECK 2 MOVED IN HERE (2026-08-29), AND WHAT IT COSTS NOT TO HAVE IT.
-- The accuracy claim used to live in the GENERATOR, which carries the same
-- independent double path and PRINTS four figures.  It prints them and gates
-- on none: the only non-zero return in that generator fires on a violated
-- WIDTH bound, never on accuracy.  And sim/regress.sh never runs it at all --
-- sim/rmsnorm_bf_vec.txt is committed, and a committed vector with no
-- tb_vector_args row is not regenerated -- so the gate could not have read the
-- figures even if they had been gated.
--
-- MEASURED consequence, and it is the reason this unit exists: mutation B1 of
-- sim/mutate_rmsnorm_bf.sh divides the rsqrt exponent out against Q instead of
-- e_out, which is EXACTLY the defect rmsnorm_rs.vhd shipped with
-- (docs/debugging/2026-08-26_rmsnorm-magnitude-window.md).  Applied to the RTL
-- and the C together it stayed bit-exact-green on all 200 cases while the
-- output moved 1.7e10 LSB away from the definition.  Check 1 cannot see that,
-- by construction, and no amount of extra stimulus makes it able to.
--
-- The two checks stay separate rather than being merged into one tolerance:
-- a testbench that checks ONLY accuracy cannot detect a wrong recipe, because
-- a wrong recipe that is accurate enough passes.
--
-- WHY A STORED VECTOR AND NOT AN A/B, WHICH IS WHAT tb_rmsnorm_rs DOES.
-- tb_rmsnorm_rs instantiates rmsnorm.vhd as its golden and argues, correctly
-- for that unit, that a stored vector would freeze one N and one exponent
-- pair.  rmsnorm_bf cannot use that argument: it is deliberately NOT bit-exact
-- with rmsnorm.vhd, because rmsnorm.vhd is wrong in the region this unit
-- exists to fix.  There is no RTL golden available, and the one that was
-- available is the reason the defect survived
-- (docs/debugging/2026-08-26_rmsnorm-magnitude-window.md).  So the golden is
-- an independent C transcription plus a double oracle, and the exponent sweep
-- the A/B form gave for free is bought back by the generator sweeping x_exp
-- across the model's MEASURED range of log2(rms), [-29.63, -0.54].
--
-- WHAT THIS PROVES AND WHAT IT DOES NOT.  It proves every element of o_mant
-- and o_exp, the S = 0 branch, both branches of the block-floating alignment,
-- the exact upper bound on the sum of squares, the single-lane max|raw| scan,
-- and the +32767 emit rail.  It does NOT prove the -32768 rail, which is
-- unreachable by construction rather than untested: shift_total puts
-- max_raw >> shift_total inside [2^14, 2^15) and the emit bias is
-- non-negative, so the low rail cannot be crossed.  That is recorded in the
-- generator alongside the search that constructs the high one.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

entity tb_rmsnorm_bf is
  generic( N     : positive := 128;
           LANES : positive := 4;
           Q     : integer  := 12;
           EPS   : real     := 1.0e-6;
           NCASE : positive := 200;
           -- Accuracy gate, in THOUSANDTHS of an output LSB.  Integer and not
           -- real because ghdl-mcode cannot override a `real` generic at all
           -- ("unhandled type for generic override"), so a real threshold is a
           -- knob nobody can turn from sim/regress.sh.  (EPS above is a real
           -- generic and stays one: it is never overridden, and the vector
           -- file's E_EPS/M_EPS header is asserted against it below.)
           --
           -- ACC_MAXLSB_M   cap on the worst |o_mant - oracle|, milli-LSB.
           -- ACC_NEAR_M     the counting threshold, milli-LSB.
           -- ACC_NEAR_MAX   how many elements may exceed it.
           -- ACC_MEAN_M     cap on the MEAN |o_mant - oracle|, milli-LSB.
           -- ACC_MIN_CHECK  FLOOR on how many elements entered the oracle.
           --
           -- FOUR NUMBERS AND NOT ONE, because each is blind to something.  A
           -- max alone is blind to a distribution shift.  A mean alone is
           -- blind to a single catastrophic element.  A count sits between
           -- them.  The FLOOR is what makes an EMPTIED oracle loud instead of
           -- reporting 0.0000 and passing, and it is not hypothetical here:
           -- this oracle EXCLUDES saturated elements, which is an exclusion on
           -- an OUTPUT property.  gdn_head_emit and gdn_y_emit have exactly
           -- that shape and are why the floor is here.
           --
           -- CALIBRATION, and it is a MEASUREMENT rather than a choice.  Every
           -- threshold below clears the UNMUTATED unit at nine generator seeds
           -- (20260826, 1, 2, 7, 42, 123, 999, 31337, 20260829) and still
           -- kills all six BOTH-class mutations of sim/mutate_rmsnorm_bf.sh.
           --
           -- THE COMMITTED SEED IS AN OUTLIER AND CALIBRATING TO IT WOULD HAVE
           -- BEEN A TRAP.  MEASURED over those nine seeds, the honest worst
           -- case moves 0.770 -> 9.999 LSB and the honest count past 0.5 LSB
           -- moves 49 -> 465; the committed 20260826 is the benign end of both
           -- ranges by an order of magnitude.  sim/mutate_rmsnorm_bf.sh's
           -- ACC_LSB of 1.0, fitted to that one seed, fires on the HONEST unit
           -- at eight of the nine.  The mean is the stable statistic here:
           -- 0.2108 -> 0.2322 over the same nine, a 10% spread.  Full table in
           -- docs/debugging/2026-08-29_b-accuracy-gates.md.
           --
           -- The count is an ABSOLUTE count at the committed shape (200 x 128
           -- = 25600 elements, 640 of them saturated).  Changing NCASE or N
           -- without rescaling it changes what it means.
           ACC_MAXLSB_M  : integer := 20000;  -- honest worst 9.999, B3 38.5
           ACC_NEAR_M    : integer := 500;
           -- CORRECTED 2026-08-29 (TRACK B-SEED), 800 -> 1300.  The 800 was
           -- 1.7x the NINE-seed honest maximum of 465.  At FORTY seeds the
           -- honest count reaches 866, so 800 fired on the HONEST unit at 2
           -- of the 40 (5%): seeds 99 (819) and 20240229 (866).  1300 is
           -- 1.50x the 40-seed maximum.  VERIFIED both ways: B5, the only
           -- mutation this count catches on its own, reads 2572 and is still
           -- killed with a 1.98x margin.
           ACC_NEAR_MAX  : integer := 1300;   -- honest worst 866, B5 2572
           ACC_MEAN_M    : integer := 300;    -- honest worst 0.232, B6 0.403
           ACC_MIN_CHECK : integer := 24000;
           VECS  : string   := "rmsnorm_bf_vec.txt" );
end entity;

architecture sim of tb_rmsnorm_bf is
  signal clk      : std_logic := '0';
  signal rst      : std_logic := '1';
  signal done_sim : boolean   := false;

  signal start  : std_logic := '0';
  signal xm, wm : std_logic_vector(N*16-1 downto 0) := (others => '0');
  signal xe, we : integer := 0;

  signal d_done : std_logic;
  signal d_om   : std_logic_vector(N*16-1 downto 0);
  signal d_oe   : integer;

  type i_arr    is array (natural range <>) of integer;
  type case_arr is array (0 to NCASE-1) of i_arr(0 to N-1);
  signal loaded : boolean := false;
  shared variable v_x, v_w, v_o : case_arr;
  shared variable v_xe, v_we, v_oe : i_arr(0 to NCASE-1);
  shared variable nfail : integer := 0;

  -- ---------------------------------------------------------------------
  -- The oracle.  Written as the DEFINITION of rmsnorm and nothing else: it
  -- knows nothing about Q, E_EPS, e_out, the seed ROM, the Newton iteration,
  -- shift_total, the emit bias or the saturation rails, and it would not
  -- change if every one of them were rewritten.  Its only shared inputs with
  -- the DUT are the int16 arrays and the two exponents.  This is the same path
  -- ref/rmsnorm_bf_vec.c calls rmsnorm_bf_dbl(); it is TRANSCRIBED rather than
  -- read out of the vector file on purpose, because the vector file's columns
  -- come from the C, and a check against the C's numbers is a check on the
  -- golden's freshness, not on the DUT's arithmetic.
  --
  -- The result is returned in LSB OF THE EMITTED GRID, using the DUT's own
  -- o_exp.  Relative error is deliberately not the gated metric: an output
  -- whose true value is under an LSB of its own grid reports a huge relative
  -- error while the quantizer is working correctly, and the whole-sweep gain
  -- figure in the generator is set by exactly that effect.
  procedure rms_oracle(x  : in i_arr; xe : in integer;
                       w  : in i_arr; we : in integer;
                       oe : in integer;
                       o  : out real_vector(0 to N-1)) is
    variable xr, sum, mean, g : real;
  begin
    sum := 0.0;
    for i in 0 to N-1 loop
      xr  := real(x(i)) * (2.0 ** (-xe));
      sum := sum + xr * xr;
    end loop;
    mean := sum / real(N);
    g    := 1.0 / sqrt(mean + EPS);
    for i in 0 to N-1 loop
      o(i) := (real(x(i)) * (2.0 ** (-xe))) * g * (real(w(i)) * (2.0 ** (-we)))
              * (2.0 ** oe);
    end loop;
  end procedure;
begin
  clk <= '0' when done_sim else not clk after 1 ns;

  dut : entity work.rmsnorm_bf
    generic map(N => N, LANES => LANES, Q => Q, EPS => EPS)
    port map(clk=>clk, rst=>rst, start=>start,
             x_mant=>xm, x_exp=>xe, w_mant=>wm, w_exp=>we,
             done=>d_done, o_mant=>d_om, o_exp=>d_oe);

  load : process
    file fh : text; variable ln : line;
    variable iv, nc, nn, vq, ve, vm : integer;
    -- The tb resolves the epsilon the same way the DUT's E_EPS / M_EPS_C
    -- constants do.  Comparing that against the header catches a mismatched
    -- EPS generic BEFORE any vector is compared: without it a wrong epsilon
    -- presents as every case failing, with nothing pointing at why.
    constant TB_E_EPS : integer := 30 - integer(floor(log2(EPS)));
    constant TB_M_EPS : integer := integer(round(EPS * 2.0**real(TB_E_EPS)));
  begin
    file_open(fh, VECS, read_mode);
    readline(fh, ln);
    read(ln, nc); read(ln, nn); read(ln, vq); read(ln, ve); read(ln, vm);
    assert nc = NCASE and nn = N
      report "tb_rmsnorm_bf: vector file shape is " & integer'image(nc) & "x"
           & integer'image(nn) & ", generics say " & integer'image(NCASE) & "x"
           & integer'image(N) severity failure;
    assert vq = Q
      report "tb_rmsnorm_bf: vectors were generated at Q=" & integer'image(vq)
           & " but the DUT is at Q=" & integer'image(Q) severity failure;
    assert ve = TB_E_EPS and vm = TB_M_EPS
      report "tb_rmsnorm_bf: epsilon mismatch -- vectors carry E_EPS="
           & integer'image(ve) & " M_EPS=" & integer'image(vm)
           & ", this EPS generic resolves to E_EPS=" & integer'image(TB_E_EPS)
           & " M_EPS=" & integer'image(TB_M_EPS) severity failure;
    for c in 0 to NCASE-1 loop
      readline(fh, ln);
      read(ln, iv);                       -- case index, positional only
      read(ln, iv); v_xe(c) := iv;
      read(ln, iv); v_we(c) := iv;
      read(ln, iv); v_oe(c) := iv;
      readline(fh, ln); for i in 0 to N-1 loop read(ln, iv); v_x(c)(i) := iv; end loop;
      readline(fh, ln); for i in 0 to N-1 loop read(ln, iv); v_w(c)(i) := iv; end loop;
      readline(fh, ln); for i in 0 to N-1 loop read(ln, iv); v_o(c)(i) := iv; end loop;
    end loop;
    file_close(fh);
    loaded <= true; wait;
  end process;

  drive : process
    variable cyc  : natural;
    variable bad  : natural;
    variable got  : integer;
    -- CHECK 2's state.  Kept in the drive process rather than in a shared
    -- variable because this bench has one checking process and the whole
    -- comparison already happens here.
    variable orac    : real_vector(0 to N-1);
    variable err     : real;
    variable a_max   : real    := 0.0;
    variable a_mcase : integer := -1;
    variable a_melem : integer := -1;
    variable a_near  : integer := 0;
    variable a_n     : integer := 0;
    variable a_sum   : real    := 0.0;
    variable a_sat   : integer := 0;
    variable acc_bad : integer := 0;
  begin
    wait until loaded;
    rst <= '1';
    for i in 0 to 5 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);

    for c in 0 to NCASE-1 loop
      for i in 0 to N-1 loop
        xm((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(v_x(c)(i), 16));
        wm((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(v_w(c)(i), 16));
      end loop;
      xe <= v_xe(c); we <= v_we(c);
      wait until rising_edge(clk);
      start <= '1';
      wait until rising_edge(clk);
      start <= '0';

      -- `done` is a ONE-CYCLE pulse, so it is caught by polling rather than
      -- waited on as a level.  A cycle cap turns a unit that never finishes
      -- into a failure instead of a hang, which is the failure mode the
      -- rmsnorm_rs testbench hit first.
      cyc := 0;
      while d_done /= '1' loop
        wait until rising_edge(clk);
        cyc := cyc + 1;
        assert cyc < 20000
          report "case " & integer'image(c) & ": never finished" severity failure;
      end loop;
      -- outputs are held until the next start, so sampling here is safe

      -- ---- CHECK 2, against the DUT's own o_mant and o_exp.
      --
      -- SATURATED elements are EXCLUDED, and that exclusion is on an OUTPUT
      -- property, which is the dangerous shape: the emitted value there is
      -- deliberately not the true one, so counting the clip as an arithmetic
      -- error would drown every number that matters, but an exclusion keyed on
      -- the output is also how an oracle gets emptied without saying so.  That
      -- is what ACC_MIN_CHECK is for.  MEASURED on the unmutated unit: 640 of
      -- 25600 elements saturate, all at +32767.
      rms_oracle(v_x(c), v_xe(c), v_w(c), v_we(c), d_oe, orac);
      for i in 0 to N-1 loop
        got := to_integer(signed(d_om((i+1)*16-1 downto i*16)));
        if got = 32767 or got = -32768 then
          a_sat := a_sat + 1;
        else
          err := abs(real(got) - orac(i));
          a_n := a_n + 1;
          if err > a_max then
            a_max := err; a_mcase := c; a_melem := i;
          end if;
          if err > real(ACC_NEAR_M) / 1000.0 then a_near := a_near + 1; end if;
          a_sum := a_sum + err;
        end if;
      end loop;

      bad := 0;
      if d_oe /= v_oe(c) then
        report "case " & integer'image(c) & " (xe=" & integer'image(v_xe(c))
             & " we=" & integer'image(v_we(c)) & "): o_exp got "
             & integer'image(d_oe) & " want " & integer'image(v_oe(c))
          severity error;
        bad := bad + 1;
      end if;
      for i in 0 to N-1 loop
        got := to_integer(signed(d_om((i+1)*16-1 downto i*16)));
        if got /= v_o(c)(i) then
          -- Only the first few are printed per case.  A recipe error is
          -- usually wrong on every element, and 128 identical reports per
          -- case buries the ONE case that differs from the others.
          if bad < 4 then
            report "case " & integer'image(c) & " (xe=" & integer'image(v_xe(c))
                 & " we=" & integer'image(v_we(c)) & ") element "
                 & integer'image(i) & ": got " & integer'image(got)
                 & " want " & integer'image(v_o(c)(i))
                 & "  from xm " & integer'image(v_x(c)(i))
                 & " wm " & integer'image(v_w(c)(i)) severity error;
          end if;
          bad := bad + 1;
        end if;
      end loop;
      if bad /= 0 then
        nfail := nfail + 1;
        report "case " & integer'image(c) & ": MISMATCH in "
             & integer'image(bad) & " place(s)" severity error;
      end if;
    end loop;

    wait until rising_edge(clk);

    -- ---- CHECK 2's verdict.  Reported unconditionally, so a passing run
    -- carries the figures too and a later drift can be dated to a commit.
    report "rmsnorm_bf accuracy vs the real-valued oracle: worst "
         & real'image(a_max) & " LSB at case " & integer'image(a_mcase)
         & " element " & integer'image(a_melem) & "; " & integer'image(a_near)
         & " of " & integer'image(a_n) & " unsaturated elements past "
         & real'image(real(ACC_NEAR_M)/1000.0) & " LSB; mean "
         & real'image(a_sum / real(maximum(a_n, 1))) & " LSB; "
         & integer'image(a_sat) & " saturated and excluded" severity note;

    acc_bad := 0;
    -- The FLOOR first, because it decides whether the other three figures
    -- mean anything at all.  An emptied oracle reports 0.0000 and 0, which is
    -- indistinguishable from a perfect unit -- and MEASURED under mutation B7
    -- of sim/mutate_rmsnorm_bf.sh it reports figures BETTER than the honest
    -- unit's (max 0.4375 against 0.7704, count 0 against 49).
    if a_n < ACC_MIN_CHECK then
      report "rmsnorm_bf: OUT OF TOLERANCE -- the oracle saw only "
           & integer'image(a_n) & " unsaturated elements, floor is "
           & integer'image(ACC_MIN_CHECK) & " (" & integer'image(a_sat)
           & " were excluded as saturated).  The accuracy figures are NOT"
           & " evidence." severity error;
      acc_bad := acc_bad + 1;
    end if;
    if a_max > real(ACC_MAXLSB_M) / 1000.0 then
      report "rmsnorm_bf: OUT OF TOLERANCE -- worst accuracy error "
           & real'image(a_max) & " LSB exceeds "
           & real'image(real(ACC_MAXLSB_M)/1000.0) & " LSB (case "
           & integer'image(a_mcase) & " element " & integer'image(a_melem)
           & ")" severity error;
      acc_bad := acc_bad + 1;
    end if;
    if a_sum / real(maximum(a_n, 1)) > real(ACC_MEAN_M) / 1000.0 then
      report "rmsnorm_bf: OUT OF TOLERANCE -- mean accuracy error "
           & real'image(a_sum / real(maximum(a_n, 1))) & " LSB exceeds "
           & real'image(real(ACC_MEAN_M)/1000.0) & " LSB.  The mean is the"
           & " seat of a SYSTEMATIC error and it is the ONLY one of the three"
           & " that separates the dropped emit round bias (mean 0.211 ->"
           & " 0.403) from an honest unit at another seed (max 0.770 -> 9.999"
           & " over nine seeds, so the max cannot)." severity error;
      acc_bad := acc_bad + 1;
    end if;
    if a_near > ACC_NEAR_MAX then
      report "rmsnorm_bf: OUT OF TOLERANCE -- " & integer'image(a_near)
           & " elements past " & real'image(real(ACC_NEAR_M)/1000.0)
           & " LSB, cap is " & integer'image(ACC_NEAR_MAX)
           & ".  A max alone cannot see a distribution shift; this is the"
           & " half that can." severity error;
      acc_bad := acc_bad + 1;
    end if;

    if nfail = 0 and acc_bad = 0 then
      report "rmsnorm_bf: bit-exact with the C reference on all "
           & integer'image(NCASE) & " cases (" & integer'image(NCASE*N)
           & " elements + " & integer'image(NCASE) & " exponents), N="
           & integer'image(N) & " LANES=" & integer'image(LANES)
           & " Q=" & integer'image(Q)
           & "; and within " & real'image(real(ACC_MAXLSB_M)/1000.0)
           & " LSB of the real-valued oracle on every unsaturated element"
           severity note;
    elsif nfail /= 0 then
      report "rmsnorm_bf: DIFFERS from the C reference in "
           & integer'image(nfail) & " case(s)" severity failure;
    end if;
    done_sim <= true;
    wait;
  end process;
end architecture;
