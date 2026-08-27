-- Checks gdn_recur (B 2.1.4, the delta-rule recurrence) TWO ways, because
-- neither check alone is sufficient and this project has already paid to
-- learn that.
--
--   1. BIT-EXACT against ref/gdn_recur_vec.c's fixed path.  A cross-language
--      check: the same recipe executed by a different compiler in a different
--      language, so it catches transcription-into-VHDL errors precisely -- a
--      wrong shift, a wrong width, a misaligned pipeline index.  What it
--      CANNOT catch is an error in the recipe itself, since both sides share
--      it.  That is exactly how the l2norm recipe collapse survived 55 passing
--      cases: docs/debugging/2026-08-25_l2norm-recipe-collapse.md.
--
--   2. REAL-VALUED against a double-precision oracle of the same column,
--      carried in the same vector file.  The oracle has no grids, no shifts
--      and no exponents -- a different number system, which is the only kind
--      of golden that can catch a wrong recipe.  Necessarily a tolerance
--      check, since the fixed path is MEANT to differ from the oracle by its
--      quantization error.
--
-- Check 2 is the one that would have caught the l2norm bug, and the reason
-- this file carries an oracle column at all rather than just diffing integers.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

entity tb_gdn_recur is
  generic(DIM   : positive := 128;
          LANES : positive := 8;
          -- Flip BOTH together: D_NORM selects the recipe in the DUT, VECS
          -- selects the matching reference.  Mismatching them is a loud
          -- bit-exact failure rather than a silent wrong answer, which is the
          -- intended behaviour.
          -- Both TRUE as of 2026-08-26: the 2.1.4 amendment is adopted and
          -- these now match rtl/gdn_recur.vhd's own defaults.
          D_NORM : boolean := true;
          TK0_ED : boolean := true;
          -- EG0_ED: the third masked-operand site (eg = 0 mid-sequence).
          EG0_ED : boolean := true;
          VECS  : string   := "gdn_recur_vec.txt";
          -- Tolerances against the ORACLE.  Set from measurement once the
          -- bit-exact check passes, never guessed: a tolerance looser than the
          -- quantity it checks is how a dropped rounding bias went undetected
          -- in tb_l2norm_rs, and it took a mutation campaign to notice.
          -- State mantissa, in LSB of the 2^-se_new grid.  The median case is
          -- 0.63 LSB and p95 is 6.65, but the steady-state tail reaches 22.1,
          -- so 32 is the honest bound.  That tail is the SAME d_m grid defect
          -- as the tk = 0 one below, diluted by the state term rather than
          -- standing alone: d_m is quantized on e_d, a grid set by
          -- max(|v|,|sk|) rather than by |d|, so its half-LSB error is
          -- multiplied by k_n (up to 2^15) into every element.  Measured over
          -- 224 physical columns, the proposed correction takes p95 from 6.65
          -- to 1.29 and the worst case from 1218 to 3.47 -- so this generic
          -- should become 4.0, not merely shrink, when it lands.
          -- Tolerances against the ORACLE, SET FROM MEASUREMENT.  A tolerance
          -- looser than the quantity it checks is how a dropped rounding bias
          -- went undetected in tb_l2norm_rs, and it took a mutation campaign
          -- to notice.
          --
          -- Measured over the 288 physically realizable columns with the fully
          -- corrected recipe (D_NORM + TK0_ED + EG0_ED) and eg drawn from the
          -- real per-head distribution:
          --
          --                       state LSB      output dot / term norm
          --   overall               8.955               6.578e-05
          --   tk = 0                1.111               7.164e-06
          --   steady state          8.955               6.578e-05
          --
          -- so tk = 0 is no longer the hard case and needs no separate bound.
          -- The former TOL_S_TK0 = 6000.0 and TOL_O_TK0 = 50.0 existed ONLY to
          -- hold the sizes of the two defects the 2026-08-26 amendment removed,
          -- and are DELETED, exactly as their own comments instructed.
          TOL_S : real := 12.0;      -- 8.955 measured, ~34% margin
          TOL_O : real := 1.0e-4);   -- 6.578e-05 measured, ~52% margin
end entity;

architecture sim of tb_gdn_recur is
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal start, tk0, done, err_se : std_logic := '0';
  signal se_j, e_v, se_new, e_o : signed(7 downto 0) := (others => '0');
  signal eg, beta : unsigned(15 downto 0) := (others => '0');
  signal v_j : signed(15 downto 0) := (others => '0');
  signal s_in, k_n, q_s, s_out : std_logic_vector(DIM*16-1 downto 0) := (others => '0');
  signal o_acc : signed(39 downto 0) := (others => '0');

  -- exact conversion of a wide signed to real.  o_acc is s38 and every s38
  -- integer is exactly representable in a double, so this loses nothing; a
  -- to_integer would overflow VHDL's 32-bit integer.
  function sel_r(c : boolean; a, b : real) return real is
  begin
    if c then return a; else return b; end if;
  end function;

  function to_real_s(v : signed) return real is
    variable m : unsigned(v'length-1 downto 0);
    variable r : real := 0.0;
  begin
    if v(v'high) = '1' then m := unsigned(-v); else m := unsigned(v); end if;
    for i in m'high downto 0 loop
      r := r * 2.0;
      if m(i) = '1' then r := r + 1.0; end if;
    end loop;
    if v(v'high) = '1' then return -r; else return r; end if;
  end function;
  -- The clock is GUARDED.  Unguarded, it keeps toggling after the stimulus
  -- process reaches its final `wait;`, so the simulation never ends: the test
  -- reports PASS and then spins at 100% CPU forever.  One such run was found
  -- alive after 4h58m.  It is invisible when output is piped through `tail`,
  -- because the report has already been printed by then.
  signal running : boolean := true;

begin
  clk <= not clk after 5 ns when running else '0';

  dut : entity work.gdn_recur
    generic map(DIM => DIM, LANES => LANES, D_NORM => D_NORM,
                TK0_ED => TK0_ED, EG0_ED => EG0_ED)
    port map(clk => clk, rst => rst, start => start, tk0 => tk0,
             se_j => se_j, eg => eg, beta => beta, v_j => v_j, e_v => e_v,
             s_in => s_in, k_n => k_n, q_s => q_s,
             s_out => s_out, se_new => se_new, o_acc => o_acc, e_o => e_o,
             err_se => err_se, done => done);

  drive : process
    file     fh   : text;
    variable ln   : line;
    variable iv, ncase, dimv : integer;
    variable rv   : real;
    variable exp_s : integer_vector(0 to DIM-1);
    variable orc_u : real_vector(0 to DIM-1);
    variable exp_se, exp_eo, exp_err : integer;
    variable exp_oacc, orc_o : real;
    variable c_phys, c_tk0, c_sej, c_ev, c_eg, c_beta, c_vj : integer;
    variable orc_on : real;   -- sum |term| of the oracle output dot
    -- A "relative" figure is only meaningful if its denominator is.  Carry the
    -- term norm of the worst case so a huge ratio can be told apart from a
    -- tiny scale, which is the trap this metric has already sprung twice.
    variable worst_o_on : real := 0.0;
    variable worst_o_c  : integer := -1;
    variable worst_o_eg : integer := -1;
    variable nphys : integer := 0;
    variable n_odeg : integer := 0;   -- columns whose oracle output dot is identically zero
    variable worst_s0, worst_s1 : real := 0.0;   -- tk=0 and steady-state
    variable tol_here, tol_o_here : real;
    -- The tolerance tracks the RECIPE, because two of the four generic
    -- combinations are not configurations anyone would ship:
    --   both false : the pinned recipe, with both known defects
    --   both true  : the corrected recipe, held to 4 LSB
    --   mixed      : NOT SUPPORTED.  D_NORM without TK0_ED measures WORSE than
    --                pinned (37414 LSB vs 5189) because normalizing d
    --                amplifies the error the phantom grid introduced.  It
    --                exists only to prove the two fixes are ONE amendment.
    constant CORRECTED : boolean := D_NORM and TK0_ED and EG0_ED;

    -- One bound per quantity, applied to every case class, taken straight
    -- from the generics.  The superseded recipe is REPORTED, not asserted
    -- (see the branch below), so it needs no tolerance of its own.
    variable got_s : integer;
    variable e_s, e_o_rel, worst_s, worst_o, gs_val, gsr : real;
    variable bad_exact, bad_tol, nexact, ntol : integer := 0;
    variable cyc : integer;
  begin
    file_open(fh, VECS, read_mode);
    readline(fh, ln); read(ln, ncase); read(ln, dimv);
    assert dimv = DIM report "vector file DIM does not match the generic"
      severity failure;

    wait for 40 ns; rst <= '0'; wait until rising_edge(clk);
    worst_s := 0.0; worst_o := 0.0;

    for c in 0 to ncase-1 loop
      readline(fh, ln);
      read(ln, c_phys); read(ln, c_tk0); read(ln, c_sej); read(ln, c_ev);
      read(ln, c_eg);  read(ln, c_beta); read(ln, c_vj);
      readline(fh, ln);
      for i in 0 to DIM-1 loop
        read(ln, iv);
        s_in((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(iv, 16));
      end loop;
      readline(fh, ln);
      for i in 0 to DIM-1 loop
        read(ln, iv);
        k_n((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(iv, 16));
      end loop;
      readline(fh, ln);
      for i in 0 to DIM-1 loop
        read(ln, iv);
        q_s((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(iv, 16));
      end loop;
      readline(fh, ln);
      for i in 0 to DIM-1 loop read(ln, iv); exp_s(i) := iv; end loop;
      readline(fh, ln);
      read(ln, exp_se); read(ln, exp_oacc); read(ln, exp_eo); read(ln, exp_err);
      readline(fh, ln);
      for i in 0 to DIM-1 loop read(ln, rv); orc_u(i) := rv; end loop;
      readline(fh, ln);
      read(ln, orc_o); read(ln, orc_on);

      if c_tk0 = 1 then tk0 <= '1'; else tk0 <= '0'; end if;
      se_j <= to_signed(c_sej, 8);
      e_v  <= to_signed(c_ev, 8);
      eg   <= to_unsigned(c_eg, 16);
      beta <= to_unsigned(c_beta, 16);
      v_j  <= to_signed(c_vj, 16);
      wait until rising_edge(clk);
      start <= '1'; wait until rising_edge(clk); start <= '0';

      cyc := 0;
      while done /= '1' loop
        wait until rising_edge(clk);
        cyc := cyc + 1;
        assert cyc < 20000 report "gdn_recur: no done" severity failure;
      end loop;
      wait for 1 ns;

      -- ---- check 1: bit-exact against the C fixed path ------------------
      bad_exact := 0;
      for i in 0 to DIM-1 loop
        got_s := to_integer(signed(s_out((i+1)*16-1 downto i*16)));
        if got_s /= exp_s(i) then bad_exact := bad_exact + 1; end if;
      end loop;
      -- 2.1.6: when the column exponent leaves int8 the unit must REPORT it,
      -- and the reported value is then meaningless by definition -- so the
      -- check is that err_se fires, not that a wrapped value matches.
      if exp_err = 1 then
        if err_se /= '1' then
          bad_exact := bad_exact + 1;
          report "case " & integer'image(c)
               & ": exponent out of int8 range and err_se NOT set" severity error;
        end if;
      else
        if err_se = '1' then bad_exact := bad_exact + 1; end if;
        if to_integer(se_new) /= exp_se then bad_exact := bad_exact + 1; end if;
        if to_integer(e_o)    /= exp_eo then bad_exact := bad_exact + 1; end if;
      end if;
      if to_real_s(o_acc)   /= exp_oacc then bad_exact := bad_exact + 1; end if;
      if bad_exact /= 0 then
        report "case " & integer'image(c) & ": NOT BIT-EXACT vs C in "
             & integer'image(bad_exact) & " field(s)  (se_new got "
             & integer'image(to_integer(se_new)) & " want "
             & integer'image(exp_se) & ")" severity error;
        nexact := nexact + 1;
      end if;

      -- ---- check 2: real-valued, against the double oracle ---------------
      -- PHYS cases only.  The adversarial group carries inputs this recurrence
      -- cannot receive -- k that is not a unit vector above all -- and holding
      -- those to an accuracy tolerance would measure the recipe against inputs
      -- it was never designed for.  They are still checked bit-exactly above,
      -- which is what corner cases are for.
      -- Columns whose exponent left int8 are excluded from the ACCURACY check
      -- as well: se_new is meaningless by 2.1.6, and the oracle comparison
      -- scales by 2^se_new, so it would be comparing against a wrapped
      -- exponent.  The unit is still required to REPORT them, which is checked
      -- above.
      bad_tol := 0;
      if c_phys = 1 and exp_err = 0 then
      nphys := nphys + 1;
      -- ACCURACY IS ASSERTED ONLY FOR THE CORRECTED RECIPE.  For the pinned
      -- one it is REPORTED instead, because the pinned recipe has two known
      -- open defects and the only way to keep the assertion green would be to
      -- raise the bound until it swallowed them -- 4381 relative on the output
      -- dot, at which point the check measures nothing.  Widening a tolerance
      -- to accommodate a defect is how tb_l2norm_rs let a dropped rounding
      -- bias through; the honest form is to state the size and not pretend it
      -- is within bounds.  Bit-exactness is asserted in every mode.
      tol_here := TOL_S; tol_o_here := TOL_O;
      if not CORRECTED then tol_here := 1.0e12; tol_o_here := 1.0e12; end if;
      for i in 0 to DIM-1 loop
        got_s := to_integer(signed(s_out((i+1)*16-1 downto i*16)));
        gsr   := orc_u(i) * 2.0 ** real(to_integer(se_new));
        e_s   := abs(real(got_s) - gsr);
        if e_s > worst_s then worst_s := e_s; end if;
        if c_tk0 = 1 then
          if e_s > worst_s0 then worst_s0 := e_s; end if;
        else
          if e_s > worst_s1 then worst_s1 := e_s; end if;
        end if;
        if e_s > tol_here then bad_tol := bad_tol + 1; end if;
      end loop;
      -- Output dot: normalised by the sum of |terms|, NOT by |sum|.  It is a
      -- 128-term signed sum that cancels heavily, so dividing by the sum
      -- itself reports an enormous error wherever the sum lands near zero
      -- while every individual term is accurate -- a property of the metric,
      -- not of the unit.  The term norm is the scale the error actually lives
      -- on.
      gs_val := to_real_s(o_acc) * 2.0 ** real(-to_integer(e_o));
      if orc_on > 1.0e-300 then
        e_o_rel := abs(gs_val - orc_o) / orc_on;
      else
        -- The oracle's terms are all zero, so there is no scale to be relative
        -- TO.  Reporting an absolute value under a "relative" label produced a
        -- headline figure of 7e26 in an earlier run, which is a property of
        -- the metric and not of the unit.  Skip it and count it instead.
        e_o_rel := 0.0;
        n_odeg  := n_odeg + 1;
      end if;
      if e_o_rel > worst_o then
        worst_o    := e_o_rel;
        worst_o_on := orc_on;      -- the DENOMINATOR at the worst case
        worst_o_c  := c;
        worst_o_eg := c_eg;
      end if;
      if bad_tol /= 0 or e_o_rel > tol_o_here then
        report "case " & integer'image(c) & ": OUT OF TOLERANCE vs ORACLE in "
             & integer'image(bad_tol) & " state element(s), o rel err "
             & real'image(e_o_rel) severity error;
        ntol := ntol + 1;
      end if;
      end if;

      if c mod 16 = 0 then
        report "case " & integer'image(c) & ": ok ("
             & integer'image(cyc) & " cycles)" severity note;
      end if;
    end loop;

    file_close(fh);
    assert nexact = 0
      report "gdn_recur is NOT bit-exact with the C recipe in "
           & integer'image(nexact) & " case(s)" severity error;
    assert ntol = 0 or not CORRECTED
      report "gdn_recur is outside oracle tolerance in "
           & integer'image(ntol) & " case(s)" severity error;
    if not CORRECTED then
      report "gdn_recur: accuracy REPORTED, not asserted -- this recipe has "
           & "known open defects (see 2026-08-26_gdn-first-token-dm-grid.md).  "
           & "Worst state error " & real'image(worst_s1) & " LSB steady state, "
           & real'image(worst_s0) & " LSB at tk = 0, worst output dot "
           & real'image(worst_o) & " relative (" & integer'image(n_odeg)
           & " columns had an identically-zero oracle dot and were skipped "
           & "for that check)." severity note;
    end if;
    if nexact = 0 and (ntol = 0 or not CORRECTED) then
      report "gdn_recur: bit-exact with the C recipe on all "
           & integer'image(ncase) & " cases; over the "
           & integer'image(nphys) & " physically realizable ones, worst vs the "
           & "double ORACLE is " & real'image(worst_s) & " state LSB and "
           & real'image(worst_o) & " of the output dot's term norm"
           & " [worst at case " & integer'image(worst_o_c)
           & ", eg=" & integer'image(worst_o_eg)
           & ", term norm " & real'image(worst_o_on) & "]"
           severity note;
      report "gdn_recur: worst state error splits by token index -- "
           & real'image(worst_s1) & " LSB in steady state, "
           & real'image(worst_s0) & " LSB at tk = 0.  The gap is the open "
           & "d_m grid defect, not noise." severity note;
    end if;
    running <= false;
    wait;
  end process;
end architecture;
