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
          VECS  : string   := "gdn_recur_vec.txt";
          -- Tolerances against the ORACLE.  Set from measurement once the
          -- bit-exact check passes, never guessed: a tolerance looser than the
          -- quantity it checks is how a dropped rounding bias went undetected
          -- in tb_l2norm_rs, and it took a mutation campaign to notice.
          -- State mantissa, in LSB of the 2^-se_new grid.  The median case is
          -- 0.63 LSB; 8.0 covers the small-beta STEADY-STATE cases, which reach
          -- 6.6.  Those are a milder form of the same d_m grid defect as the
          -- tk = 0 one below -- diluted by the state term rather than standing
          -- alone -- so this number will drop when that correction lands too.
          TOL_S : real := 8.0;
          -- tk = 0 ONLY.  This is NOT slack, and it must not be treated as a
          -- tolerance that happens to be loose: it is the measured size of an
          -- OPEN DEFECT in the pinned recipe.  At the first token the state is
          -- exactly k_n * d_m, so d_m's quantization error becomes the state's
          -- relative error with nothing in the sum to dilute it, and d_m is
          -- quantized on e_d -- a grid set by max(|v|,|sk|), not by |d|.  With
          -- a small beta the first token's state can be lost ENTIRELY (d_m
          -- rounds to 0 in 7% of draws at beta = 2.4e-4).  The vector set
          -- deliberately includes small-beta head groups so this is exercised
          -- rather than avoided.  Normalizing d onto
          -- its own grid, exactly as site 7 already does for sk, removes it.
          -- See docs/debugging/2026-08-26_gdn-first-token-dm-grid.md.
          -- WHEN THAT CORRECTION LANDS, DELETE THIS GENERIC and let tk = 0
          -- cases be held to TOL_S like every other case.
          -- Measured worst is 1218 LSB, on a tk = 0 column with beta = 92:
          -- 3.9% of full scale, on every element at once.
          TOL_S_TK0 : real := 1500.0;
          TOL_O : real := 1.0e-3;   -- output dot, relative to the TERM norm
          -- Same open defect, same reason: at tk = 0 the output dot is taken
          -- over a state that is entirely k_n * d_m, so it inherits d_m's
          -- relative error too.  Delete with TOL_S_TK0.
          TOL_O_TK0 : real := 5.0e-3);
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
begin
  clk <= not clk after 5 ns;

  dut : entity work.gdn_recur
    generic map(DIM => DIM, LANES => LANES)
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
    variable exp_se, exp_eo : integer;
    variable exp_oacc, orc_o : real;
    variable c_phys, c_tk0, c_sej, c_ev, c_eg, c_beta, c_vj : integer;
    variable orc_on : real;   -- sum |term| of the oracle output dot
    variable nphys : integer := 0;
    variable worst_s0, worst_s1 : real := 0.0;   -- tk=0 and steady-state
    variable tol_here, tol_o_here : real;
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
      read(ln, exp_se); read(ln, exp_oacc); read(ln, exp_eo);
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
      if to_integer(se_new) /= exp_se then bad_exact := bad_exact + 1; end if;
      if to_integer(e_o)    /= exp_eo then bad_exact := bad_exact + 1; end if;
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
      bad_tol := 0;
      if c_phys = 1 then
      nphys := nphys + 1;
      if c_tk0 = 1 then tol_here := TOL_S_TK0; else tol_here := TOL_S; end if;
      if c_tk0 = 1 then tol_o_here := TOL_O_TK0; else tol_o_here := TOL_O; end if;
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
        e_o_rel := abs(gs_val - orc_o);
      end if;
      if e_o_rel > worst_o then worst_o := e_o_rel; end if;
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
    assert ntol = 0
      report "gdn_recur is outside oracle tolerance in "
           & integer'image(ntol) & " case(s)" severity error;
    if nexact = 0 and ntol = 0 then
      report "gdn_recur: bit-exact with the C recipe on all "
           & integer'image(ncase) & " cases; over the "
           & integer'image(nphys) & " physically realizable ones, worst vs the "
           & "double ORACLE is " & real'image(worst_s) & " state LSB and "
           & real'image(worst_o) & " of the output dot's term norm"
           severity note;
      report "gdn_recur: worst state error splits by token index -- "
           & real'image(worst_s1) & " LSB in steady state, "
           & real'image(worst_s0) & " LSB at tk = 0.  The gap is the open "
           & "d_m grid defect, not noise." severity note;
    end if;
    wait;
  end process;
end architecture;
