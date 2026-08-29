-- tb_gdn_scalar: two-way check of rtl/gdn_scalar.vhd against ref/gdn_scalar_vec.
--
--   (a) BIT-EXACT against the fixed path.  This is the contract.
--   (b) GATED against a double oracle computed in real arithmetic.  The
--       oracle is not a second transcription of the same integer recipe -- it
--       never touches a LUT, a shift or a grid -- so it measures the recipe's
--       approximation error rather than the testbench's agreement with itself.
--
-- ---------------------------------------------------------------------------
-- WHY (b) IS GATED ON A SUB-DOMAIN, AND WHY A WHOLE-SET MAX GATE CANNOT EXIST
-- ---------------------------------------------------------------------------
-- Until 2026-08-29 (b) was REPORTED and not asserted, and the reason it could
-- not be asserted is that it is SATURATED on the correct unit.  MEASURED,
-- unmutated, SP_Q = 18, over all 320 committed cases:
--
--   vs double oracle: eg worst 3.2768e4 LSB(Q15)
--
-- 32768 is the entire Q15 output range.  A max-based gate on that figure is
-- vacuous, so for a while this unit had no accuracy signal at all.
--
-- The mechanism is NOT one thing.  MEASURED, three distinct ones produce the
-- 17 cases past 100 LSB, and they are separated by instrumenting a copy of the
-- generator with a per-case saturation probe:
--
--   1. Both softplus inputs hit ref/gdn_scalar_vec.c's +-2^45 wide-grid
--      sentinel with OPPOSITE signs and CANCEL (14 cases; case 260 computes
--      eg = 0 where the truth is 32768).  This is the s32 cancellation the
--      unit's own header says it corrected, relocated to the sentinel.
--   2. One input hits the sentinel with the SAME sign, so arg is truncated
--      from ~1e12 to 2^45/2^18 = 1.34e8, and a tiny |a| then lands the product
--      inside the [-16, 0] window on one side only (cases 69, 258).
--   3. NO sentinel fires at all: the softplus negative tail is flushed to
--      exactly 0 below arg = -16, where the truth is exp(arg), and an
--      enormous |a| multiplies that difference back up.  Case 70 -- |a| =
--      3.09e14, arg = -30.43 -- is 32767.9963 LSB wrong with a saturation
--      count of ZERO.  It is the joint-worst case in the file.
--
-- What they share is the real statement: the eg error is |a| times the
-- softplus error, and the case set deliberately sweeps al_e, dt_e and a_e over
-- [-40, 60] so that the RTL's guard branches are reachable at all (see the
-- generator's own comment: "Four RTL-vs-reference divergences hid in that
-- gap").  ACCURACY AND GUARD COVERAGE CANNOT BE GATED FROM ONE NUMBER OVER
-- ONE CASE SET, because the same stimulus that reaches the guards puts |a| and
-- |arg| where no 2^-18 grid can carry the answer.
--
-- So the gate is stated on a DOMAIN, and the domain is a predicate on the
-- INPUTS, never on the outputs.  That distinction is the whole point: excluding
-- cases because the answer came out large is what emptied gdn_y_emit's oracle
-- (its sat_any exclusion removes 41 of 48 cases and leaves it reporting 0.0000
-- on nothing but the all-zero cases).  Here the excluded set's OWN median error
-- is 0.0037 LSB and its minimum is 0.0000, so the exclusion is plainly not
-- error-driven.
--
-- IN-DOMAIN, both conditions DERIVED from the recipe rather than fitted:
--   (i)  neither softplus input reaches to_q_wide's sentinel.  `sentinel`
--        below mirrors that function's two guards exactly.
--   (ii) |a| <= 256.  Below the clamp the recipe returns exactly 0 where the
--        truth is exp(arg) <= exp(-16) = 1.1254e-7, so the eg error from the
--        flush is at most 32768 * |a| * 1.1254e-7, and 256 is the largest
--        power of two keeping that under one output LSB (0.944).
--
-- MEASURED with that predicate over the committed 320:
--   in-domain 259 cases, worst 15.3271 LSB(Q15), median 0.0832, NONE past 100
--   excluded   61 cases, all of them in the wide-exponent (47 of 64) and
--              named-corner (14 of 16) bands, i.e. exactly the two bands the
--              generator says exist to reach the guards
--   every one of the physical (64), softplus-threshold (64), g-clamp (64) and
--   degenerate (48) cases is RETAINED, so the band drawn from the real Qwen3
--   weight ranges is covered in full
--
-- beta needs no domain at all: MEASURED worst 3.0880 LSB(Q16) over all 320.
--
-- All three tolerances are 1.5x the measured figure, which is the same
-- convention sim/tb_gdn_conv.vhd's TOL uses (0.75 against a measured
-- 0.4999999).
--
-- TRAP, MEASURED: ghdl-mcode CANNOT override a `real` generic from the command
-- line -- `-gEG_TOL=10.0` dies with "unhandled type for generic override of
-- 'eg_tol'" and no simulation runs at all.  So EG_TOL and BETA_TOL cannot be
-- swept from sim/regress.sh or teeth-checked by lowering them; both were
-- teeth-checked against REAL mutants instead, which is the better evidence
-- anyway.  MEASURED, with sim/mutate_gdn_scalar.sh:
--   EG_TOL       tripped by B1 (19046 LSB), B2 (26491), B3 (352.7), R4, R6, R8
--   EG_N1_TOL    tripped by B5 (151 of 259 past 1 LSB), which EG_TOL cannot see
--   BETA_TOL     tripped by R3 (32768 LSB(Q16))
--   MIN_IN_DOMAIN  tripped by -gMIN_IN_DOMAIN=300 on the correct unit (it is
--                  an integer, so that one CAN be overridden)
-- B4, the eg output round bias dropped in BOTH, is a DELIBERATE survivor: it
-- moves the in-domain worst 15.3271 -> 15.2885 and the count 67 -> 61, i.e.
-- the safe way.  The gate is NOT widened or made two-sided to catch it.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

entity tb_gdn_scalar is
  generic( SP_Q : integer := 18; VEC : string := "gdn_scalar_vec.txt";
           -- 1.5x the MEASURED in-domain worst of 15.3271 LSB(Q15).  Set from
           -- the measurement, not from a round number: see the header.
           EG_TOL   : real := 23.0;
           -- 1.5x the MEASURED worst of 3.0880 LSB(Q16), over ALL cases.
           BETA_TOL : real := 4.65;
           -- A max alone is blind to a mutation that moves the BULK of the
           -- distribution without moving its worst case.  MEASURED: moving g's
           -- lower clamp from -16 to -8 in BOTH the C and the RTL leaves the
           -- in-domain max at 15.3271 exactly -- below -8 the true eg is
           -- already under 11 LSB, so the change cannot reach the worst case --
           -- while the count of in-domain cases past one output LSB goes
           -- 67 -> 151 and the in-domain median goes 0.0832 -> 2.2214.  The
           -- count is gated rather than the median because it needs no sort.
           -- 100 is 1.5x the measured 67, the same convention as the two
           -- tolerances above.
           EG_N1_TOL : integer := 100;
           -- The domain must not be allowed to EMPTY.  259 of 320 cases are
           -- in-domain today; a floor of 250 fails loudly if a change to the
           -- generator quietly drains the set the gate is computed over,
           -- which is the failure mode that made gdn_y_emit's oracle report
           -- 0.0000 on nothing but its all-zero cases.
           MIN_IN_DOMAIN : integer := 250 );
end entity;

architecture sim of tb_gdn_scalar is
  -- Does ref/gdn_scalar_vec.c's to_q_wide return its +-2^45 sentinel for the
  -- (mantissa, exponent) pair (m, e)?  This mirrors that function's TWO guards
  -- and both of them matter: the `s > 40` cutoff fires on magnitude-innocent
  -- inputs (case 258 is m = 1, e = -25, whose true value 2^25 is far below the
  -- 2^27 the sentinel corresponds to, and it is slammed to the sentinel
  -- anyway), so a predicate written only on |value| would keep that case and
  -- carry an 11454 LSB error into the gate.
  function sentinel(m : integer; e : integer) return boolean is
    variable s : integer;
  begin
    if m = 0 then return false; end if;          -- zero is zero on every grid
    if e - SP_Q >= 0 then return false; end if;  -- right shift, never saturates
    s := SP_Q - e;
    if s > 40 then return true; end if;
    return abs(real(m)) * 2.0 ** real(s) > 2.0 ** 45.0;
  end function;

  signal clk   : std_logic := '0';
  signal rst   : std_logic := '1';
  signal start : std_logic := '0';
  signal al_m, dt_m, a_m, b_m : signed(15 downto 0) := (others => '0');
  signal al_e, dt_e, a_e, b_e : signed(7 downto 0)  := (others => '0');
  signal eg, beta : unsigned(15 downto 0);
  signal err_g, done : std_logic;
  signal running : boolean := true;
begin
  clk <= not clk after 5 ns when running else '0';

  dut : entity work.gdn_scalar
    generic map(SP_Q => SP_Q)
    port map(clk=>clk, rst=>rst, start=>start,
             al_m=>al_m, al_e=>al_e, dt_m=>dt_m, dt_e=>dt_e,
             a_m=>a_m, a_e=>a_e, b_m=>b_m, b_e=>b_e,
             eg=>eg, beta=>beta, err_g=>err_g, done=>done);

  stim : process
    file     fh   : text;
    variable ln   : line;
    variable nc, q : integer;
    variable v_alm, v_ale, v_dtm, v_dte : integer;
    variable v_am, v_ae, v_bm, v_be     : integer;
    variable x_eg, x_beta, x_err        : integer;
    variable o_eg, o_beta               : real;
    variable bad_eg, bad_beta, bad_err  : integer := 0;
    variable worst_eg, worst_beta       : real := 0.0;
    variable worst_eg_in                : real := 0.0;   -- in-domain only
    variable n_in, n_eg_gt1             : integer := 0;
    variable in_dom                     : boolean;
    variable a_abs                      : real;
    variable d : real;
  begin
    file_open(fh, VEC, read_mode);
    readline(fh, ln); read(ln, nc); read(ln, q);
    assert q = SP_Q report "vector file grid Q" & integer'image(q) &
      " does not match SP_Q " & integer'image(SP_Q) severity failure;

    rst <= '1'; wait for 40 ns; rst <= '0'; wait for 20 ns;

    for i in 0 to nc-1 loop
      readline(fh, ln);
      read(ln, v_alm); read(ln, v_ale); read(ln, v_dtm); read(ln, v_dte);
      read(ln, v_am);  read(ln, v_ae);  read(ln, v_bm);  read(ln, v_be);
      read(ln, x_eg);  read(ln, x_beta); read(ln, x_err);
      read(ln, o_eg);  read(ln, o_beta);

      al_m <= to_signed(v_alm,16); al_e <= to_signed(v_ale,8);
      dt_m <= to_signed(v_dtm,16); dt_e <= to_signed(v_dte,8);
      a_m  <= to_signed(v_am,16);  a_e  <= to_signed(v_ae,8);
      b_m  <= to_signed(v_bm,16);  b_e  <= to_signed(v_be,8);
      wait until rising_edge(clk);
      start <= '1'; wait until rising_edge(clk); start <= '0';
      wait until done = '1';
      wait for 1 ns;

      -- (a) the contract
      if to_integer(eg) /= x_eg then
        bad_eg := bad_eg + 1;
        if bad_eg <= 6 then
          report "case " & integer'image(i) & ": eg " & integer'image(to_integer(eg)) &
                 " expected " & integer'image(x_eg) severity error;
        end if;
      end if;
      -- err_g was read from the vector file and never compared, so tying it
      -- high passed the entire suite at all three grids.
      if (err_g = '1') /= (x_err = 1) then
        bad_err := bad_err + 1;
        if bad_err <= 6 then
          report "case " & integer'image(i) & ": err_g " & std_logic'image(err_g) &
                 " expected " & integer'image(x_err) severity error;
        end if;
      end if;
      if to_integer(beta) /= x_beta then
        bad_beta := bad_beta + 1;
        if bad_beta <= 6 then
          report "case " & integer'image(i) & ": beta " & integer'image(to_integer(beta)) &
                 " expected " & integer'image(x_beta) severity error;
        end if;
      end if;

      -- (b) the oracle.  worst_eg is kept over ALL cases so the saturated
      -- figure stays visible and nobody mistakes the gated one for it; the
      -- GATE is worst_eg_in, over the domain defined in the header.  The
      -- predicate reads only the INPUTS of the case, never its outputs.
      a_abs  := abs(real(v_am)) * 2.0 ** real(-v_ae);
      in_dom := (not sentinel(v_alm, v_ale))
            and (not sentinel(v_dtm, v_dte))
            and a_abs <= 256.0;

      d := abs(real(to_integer(eg)) - o_eg);
      if d > worst_eg then worst_eg := d; end if;
      if in_dom then
        n_in := n_in + 1;
        if d > worst_eg_in then worst_eg_in := d; end if;
        if d > 1.0 then n_eg_gt1 := n_eg_gt1 + 1; end if;
      end if;
      d := abs(real(to_integer(beta)) - o_beta);
      if d > worst_beta then worst_beta := d; end if;
    end loop;
    file_close(fh);

    report "=== gdn_scalar, SP_Q=" & integer'image(SP_Q) & ", " &
           integer'image(nc) & " cases ===";
    report "bit-exact vs fixed reference: eg mismatches " & integer'image(bad_eg) &
           ", beta mismatches " & integer'image(bad_beta) &
           ", err_g mismatches " & integer'image(bad_err);
    report "vs double oracle: eg worst " & real'image(worst_eg) &
           " LSB(Q15), beta worst " & real'image(worst_beta) & " LSB(Q16)";
    report "vs double oracle IN DOMAIN (" & integer'image(n_in) & " of " &
           integer'image(nc) & " cases): eg worst " & real'image(worst_eg_in) &
           " LSB(Q15), gate " & real'image(EG_TOL) & "; eg past 1 LSB " &
           integer'image(n_eg_gt1) & ", gate " & integer'image(EG_N1_TOL);

    -- The domain floor comes FIRST.  An accuracy figure computed over an
    -- emptied set is the one number that looks better the more broken things
    -- get, so it must not be possible to report a green eg_in without also
    -- reporting how many cases it was computed over.
    assert n_in >= MIN_IN_DOMAIN
      report "gdn_scalar: the accuracy DOMAIN COLLAPSED -- only " &
             integer'image(n_in) & " of " & integer'image(nc) &
             " cases are in domain, floor is " & integer'image(MIN_IN_DOMAIN) &
             ".  The eg figure below is computed over too few cases to mean " &
             "anything." severity error;
    assert worst_eg_in <= EG_TOL
      report "gdn_scalar: eg is OUT OF TOLERANCE vs the ORACLE in domain -- " &
             real'image(worst_eg_in) & " LSB(Q15) against a gate of " &
             real'image(EG_TOL) & " over " & integer'image(n_in) & " cases"
      severity error;
    assert n_eg_gt1 <= EG_N1_TOL
      report "gdn_scalar: eg is OUT OF TOLERANCE vs the ORACLE in domain -- " &
             integer'image(n_eg_gt1) & " of " & integer'image(n_in) &
             " in-domain cases are past one output LSB, gate is " &
             integer'image(EG_N1_TOL) & ".  The worst case did not move; the " &
             "bulk of the distribution did." severity error;
    assert worst_beta <= BETA_TOL
      report "gdn_scalar: beta is OUT OF TOLERANCE vs the ORACLE -- " &
             real'image(worst_beta) & " LSB(Q16) against a gate of " &
             real'image(BETA_TOL) & " over all " & integer'image(nc) & " cases"
      severity error;

    assert bad_eg = 0 and bad_beta = 0 and bad_err = 0
      report "BIT-EXACTNESS FAILED" severity failure;
    -- PASS is stated only when the accuracy gates are clean too, so a run
    -- that is bit-exact and inaccurate cannot read as a pass in a log tail.
    if n_in >= MIN_IN_DOMAIN and worst_eg_in <= EG_TOL
       and n_eg_gt1 <= EG_N1_TOL and worst_beta <= BETA_TOL then
      report "PASS";
    end if;
    running <= false;
    wait;
  end process;
end architecture;
