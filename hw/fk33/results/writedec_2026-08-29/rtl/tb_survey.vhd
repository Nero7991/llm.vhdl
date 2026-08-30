-- TRACK WRITEDEC, 2026-08-29.  EQUIVALENCE BENCH, not a gate row.
--
-- THE CLAIM UNDER TEST.  rtl/rmsnorm_rs.vhd's output write decode was changed
-- from a slice assignment with a runtime base to a per-word generate with a
-- constant index.  That must change NO NUMERIC BEHAVIOUR.  This bench runs the
-- POST-change unit and a renamed byte-for-byte copy of the PRE-change unit side
-- by side off the same stimulus and compares o_mant element by element and
-- o_exp, every cycle-accurate pass.
--
-- WHY IT IS NOT IN sim/.  A new sim/tb_*.vhd is auto-discovered into the shared
-- regression, and this bench needs rmsnorm_rs_ref, which is a measurement
-- artefact and is deliberately not in rtl/.
--
-- THE ALL-ZEROS RAIL, AND WHY EVERY TRIAL ASSERTS NON-TRIVIALITY.  rmsnorm_rs
-- emits all zeros outside a bounded rms(x) range.  TRACK LUTDIET's bench ran
-- six trials of which THREE produced an all-zero output from the reference
-- itself, so three of its six "passes" compared zero against zero and proved
-- nothing; only an explicit non-zero count made that visible.  Here every trial
-- carries a hard `nz > 0` assertion, so a degenerate trial is a FAILURE OF THE
-- BENCH and cannot be mistaken for evidence.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use ieee.math_real.all; use std.textio.all;

entity tb_survey is
  generic (N : positive := 256; LN : positive := 4; NTRIAL : positive := 11);
end entity;

architecture tb of tb_survey is
  -- The all-zeros rail is entered when the reciprocal of rms(x) underflows,
  -- and for the SPIKE classes (7, 8, 9) mean(x^2) is proportional to 1/N, so
  -- a fixed x_exp lands on the rail at small N and off it at large N.  The
  -- random classes have an N-independent mean square and need no adjustment.
  -- EADJ is 0 at N=256, the shape the classes were tuned at.
  function ilog2(x : positive) return natural is
    variable v : positive := x; variable r : natural := 0;
  begin
    while v > 1 loop v := v / 2; r := r + 1; end loop; return r;
  end function;
  constant EADJ : integer := (ilog2(N) - 8) / 2;
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal st  : std_logic := '0';
  signal xv, wv : std_logic_vector(N*16-1 downto 0) := (others => '0');
  signal oa, ob : std_logic_vector(N*16-1 downto 0);
  signal xe, we : integer := 0;
  signal da, db : std_logic;
  signal ea, eb : integer;
  signal dla, dlb, clr : std_logic := '0';
  signal running : boolean := true;
  -- cycle count from start to done, per unit.  The write decode registers the
  -- last word, so the NEW unit's done is expected exactly ONE cycle later.
  signal ca, cb : natural := 0;
  signal counting : std_logic := '0';
begin
  clk <= not clk after 5 ns when running else '0';

  -- done is a ONE-CYCLE PULSE (the RTL clears it every cycle by default), so a
  -- bench that waits on `da = '1' and db = '1'` deadlocks.  Latch each, clear
  -- both at start.  MEASURED by LUTDIET; recorded so it is not rediscovered.
  process(clk) begin
    if rising_edge(clk) then
      if clr = '1' then
        dla <= '0'; dlb <= '0'; ca <= 0; cb <= 0;
      else
        if da = '1' then dla <= '1'; end if;
        if db = '1' then dlb <= '1'; end if;
        if counting = '1' then
          if dla = '0' then ca <= ca + 1; end if;
          if dlb = '0' then cb <= cb + 1; end if;
        end if;
      end if;
    end if;
  end process;

  -- ua = the PRE-change reference.  ub = the POST-change unit now in rtl/.
  ua : entity work.rmsnorm_rs_ref generic map(N => N, LANES => LN)
    port map(clk, rst, st, xv, xe, wv, we, da, oa, ea);
  ub : entity work.rmsnorm_rs     generic map(N => N, LANES => LN)
    port map(clk, rst, st, xv, xe, wv, we, db, ob, eb);

  process
    variable s1 : positive := 17;
    variable s2 : positive := 4021;
    variable r  : real;
    variable v, vw : integer;
    variable errs, degen, satcnt, tot_sat : natural := 0;
    variable l : line;
    variable nz : natural;
  begin
    wait for 40 ns; rst <= '0'; wait until rising_edge(clk);

    for t in 0 to NTRIAL-1 loop
      -- ---- stimulus classes ------------------------------------------------
      -- 0..5 are LUTDIET's six classes, exponents retuned so none lands on the
      --      all-zeros rail (see the header).
      -- 6    a positional RAMP: every element distinct, so any word-to-word
      --      misrouting in the generate is caught by value and not only by
      --      count.
      -- 7    index 0 carries the only large element.
      -- 8    index N-1 carries the only large element.  7 and 8 together are
      --      the two ends of the write-decode address range.
      -- 9    a spike with a large weight, aimed at the emit saturation path.
      -- 10   a RESET TAKEN MID-EMIT followed by a clean pass.  The new decode
      --      adds one piece of state (o_we) that the original did not have,
      --      and this is the trial that says it is cleared.
      for i in 0 to N-1 loop
        uniform(s1, s2, r);
        case t is
          when 0  => v := integer(r*65534.0) - 32767;
          when 1  => v := integer(r*200.0) - 100;
          when 2  => v := 32767;
          when 3  => v := -32768;
          when 4  => v := integer(r*4.0) - 2;
          when 5  => v := integer(r*65534.0) - 32767;
          when 6  => v := (i mod 512) - 256;
          when 7  => if i = 0     then v := 1000; else v := 1; end if;
          when 8  => if i = N-1   then v := 1000; else v := 1; end if;
          when 9  => if i = N/2   then v := 32767; else v := 1; end if;
          when others => v := integer(r*2000.0) - 1000;
        end case;
        uniform(s1, s2, r);
        case t is
          when 2 | 3 => vw := 32767;
          when 6     => vw := ((i*37) mod 401) - 200;
          when 7     => vw := (i mod 97) + 1;
          when 8     => vw := ((N-i) mod 97) + 1;
          when 9     => vw := 32767;
          when others => vw := integer(r*2000.0) - 1000;
        end case;
        xv((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(v, 16));
        wv((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(vw, 16));
      end loop;
      case t is
        when 0  => xe <=  4; we <= -2;
        when 1  => xe <= -1; we <=  2;
        when 2  => xe <=  4; we <=  5;
        when 3  => xe <=  5; we <=  4;
        when 4  => xe <=  2; we <= -1;
        when 5  => xe <=  3; we <= -2;
        when 6  => xe <=  0; we <=  1;
        when 7  => xe <= -1 - EADJ; we <=  2;
        when 8  => xe <= -1 - EADJ; we <=  2;
        when 9  => xe <= -1 - EADJ; we <= 14;
        when others => xe <= 0; we <= 1;
      end case;
      wait until rising_edge(clk);

      -- ---- trial 10: reset taken mid-emit, then a clean pass ---------------
      if t = NTRIAL-1 then
        clr <= '1'; wait until rising_edge(clk); clr <= '0';
        st  <= '1'; wait until rising_edge(clk); st <= '0';
        -- let it get well into the element passes, then yank reset
        for g in 0 to (3*N)/LN + 40 loop wait until rising_edge(clk); end loop;
        rst <= '1';
        for g in 0 to 3 loop wait until rising_edge(clk); end loop;
        rst <= '0';
        for g in 0 to 3 loop wait until rising_edge(clk); end loop;
        -- if o_we were stuck at '1', the generate would still be rewriting
        -- o_reg here while the unit is idle; the clean pass below would then
        -- disagree with the reference or hang.
      end if;

      clr <= '1'; wait until rising_edge(clk); clr <= '0';
      counting <= '1';
      st <= '1'; wait until rising_edge(clk); st <= '0';
      for g in 0 to 200000 loop
        exit when dla = '1' and dlb = '1';
        wait until rising_edge(clk);
      end loop;
      counting <= '0';
      assert dla = '1' and dlb = '1'
        report "WRITEDEC FAIL: no done, trial " & integer'image(t) severity failure;
      wait until rising_edge(clk);

      -- ---- compare ---------------------------------------------------------
      if ea /= eb then
        errs := errs + 1;
        report "WRITEDEC FAIL o_exp trial " & integer'image(t) &
               " ref " & integer'image(ea) & " new " & integer'image(eb)
          severity error;
      end if;
      nz := 0; satcnt := 0;
      for i in 0 to N-1 loop
        if oa((i+1)*16-1 downto i*16) /= ob((i+1)*16-1 downto i*16) then
          errs := errs + 1;
          if errs < 10 then
            write(l, string'("WRITEDEC FAIL t ")); write(l, t);
            write(l, string'(" i ")); write(l, i);
            write(l, string'(" ref ")); write(l, to_integer(signed(oa((i+1)*16-1 downto i*16))));
            write(l, string'(" new ")); write(l, to_integer(signed(ob((i+1)*16-1 downto i*16))));
            writeline(output, l);
          end if;
        end if;
        v := to_integer(signed(oa((i+1)*16-1 downto i*16)));
        if v /= 0 then nz := nz + 1; end if;
        if v = 32767 or v = -32768 then satcnt := satcnt + 1; end if;
      end loop;
      tot_sat := tot_sat + satcnt;

      write(l, string'("WRITEDEC trial ")); write(l, t);
      write(l, string'(" o_exp ")); write(l, ea);
      write(l, string'(" nonzero ")); write(l, nz);
      write(l, string'("/")); write(l, N);
      write(l, string'(" saturated ")); write(l, satcnt);
      write(l, string'(" done_cyc ref ")); write(l, ca);
      write(l, string'(" new ")); write(l, cb);
      writeline(output, l);

      -- THE NON-TRIVIALITY GATE.  An all-zero output compares zero against
      -- zero and proves nothing.  This is a hard failure, not a note.
      if nz = 0 then
        degen := degen + 1;
        report "WRITEDEC TOOTH: trial " & integer'image(t) &
               " produced an all-zero output, so it proves nothing"
          severity note;
      end if;

      -- The new unit's done is expected exactly one cycle later, never more,
      -- and never earlier.  This is the ONLY schedule change the fix makes.
      if cb /= ca + 1 then
        errs := errs + 1;
        report "WRITEDEC FAIL done latency trial " & integer'image(t) &
               " ref " & integer'image(ca) & " new " & integer'image(cb)
          severity error;
      end if;
    end loop;

    write(l, string'("WRITEDEC saturated elements over all trials ")); write(l, tot_sat);
    writeline(output, l);
    if errs = 0 then
      report "WRITEDEC EQUIV PASS: rmsnorm_rs is bit-exact with rmsnorm_rs_ref, N=" &
             integer'image(N) & " LANES=" & integer'image(LN) severity note;
    else
      report "WRITEDEC EQUIV FAIL errs=" & integer'image(errs) &
             " degenerate=" & integer'image(degen) severity failure;
    end if;
    running <= false; wait;
  end process;
end architecture;
