-- Checks l2norm_rs (B 2.1.3, the per-head L2 norm) TWO ways on every case,
-- and neither check may be deleted because the other exists.
--
--   1. BIT-EXACT against ref/l2norm_rs_vec.c, which transcribes 2.1.3's
--      recipe independently in C from the same RSQRT_ROM.  A cross-language
--      check: it catches transcription-into-VHDL errors precisely -- a wrong
--      shift, a wrong width, a pipeline index off by one, a saturation that
--      fires an LSB early.  It CANNOT catch an error in the recipe, because
--      both sides share it.
--
--   2. REAL-VALUED against x/||x|| computed in math_real: a parallel
--      real-valued sum of squares, sqrt, and a divide, compared in output
--      LSBs.  A different number system, which is the only kind of golden
--      that can catch a wrong recipe.
--
-- WHY BOTH, and this is the whole reason this file reads the way it does.
-- The FIRST version of this testbench computed its golden from 2.1.3's recipe
-- using work.fixed_pkg's own rsqrt_q, on the argument that the package
-- function was the sanctioned reference.  It is not a reference: the DUT
-- implements the same recipe, so both sides of the comparison were wrong in
-- the same direction and agreed.  It certified 55 cases against a recipe that
-- emitted ALL ZEROS on the q path for every input with ssq >= 2^33.  See
-- docs/debugging/2026-08-25_l2norm-recipe-collapse.md.  Check 1 has exactly
-- that shape and would have certified the collapse too; it is here for the
-- errors check 2 is blind to, not in place of it.
--
-- The SECOND version deleted check 1 entirely and kept only the tolerance.
-- That left l2norm_rs as the only unit in subsystem B with no reference model
-- in ref/ at all, held to a bound where every sibling is held to an equality.
-- Restored 2026-08-28 as check 1, ALONGSIDE.
--
-- Do not "restore" a fixed_pkg golden, and do not delete either check.
--
-- The tolerance is set from the MEASURED error, not from a round number: see
-- the TOL generic.  ssq = 0 is asserted explicitly wherever it occurs, since
-- that is a case where matching ggml would be the bug rather than the check.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

entity tb_l2norm_rs is
  generic(N : positive := 128; LANES : positive := 4;
          -- Accuracy tolerance in output LSBs for the INDEPENDENT real-valued
          -- check.  Correct round-half-up bounds the error at 0.5 LSB and the
          -- unit measures 0.49994 worst case over the 159-case sweep in
          -- ref/l2norm_rs_vec.c, so 0.75 leaves headroom for the Newton
          -- residual while still SEPARATING correct rounding from truncation
          -- (which reaches 1.0).  At the 2.0 this started at, a mutation that
          -- dropped the rounding bias entirely went undetected.
          TOL  : real   := 0.75;
          VECS : string := "l2norm_rs_vec.txt");
end entity;

architecture sim of tb_l2norm_rs is
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal fin : boolean := false;
  signal start : std_logic := '0';
  signal xm : std_logic_vector(N*16-1 downto 0) := (others => '0');
  signal dn : std_logic;
  signal km, qm : std_logic_vector(N*16-1 downto 0);
  signal fails : natural := 0;
begin
  clk <= '0' when fin else not clk after 1 ns;

  dut : entity work.l2norm_rs
    generic map(N => N, LANES => LANES)
    port map(clk=>clk, rst=>rst, start=>start, x_mant=>xm,
             done=>dn, k_mant=>km, q_mant=>qm);

  drv : process
    file     fh : text;
    variable ln : line;
    variable iv, ncase, nv : integer;
    variable ssq : signed(63 downto 0);
    variable nrm, ssqr, rk, rq, ek, eq, worst, worst_all : real;
    -- The 1/sqrt(N) fold, DERIVED from N so the golden tracks the generic the
    -- same way the DUT now does.  Hardcoding sqrt(128) here would have made
    -- the testbench agree with a DUT that hardcoded the matching shift, which
    -- is the transcription failure check 2 exists to avoid.
    constant SQRTN : real := sqrt(real(N));
    type ia is array(0 to N-1) of integer;
    variable xv, kv, qv : ia;
    variable xj, ak, aq : signed(15 downto 0);
    variable bad, badx, cyc, nzero : natural;
    variable worst_c : integer := -1;
    variable nexact  : natural := 0;
  begin
    file_open(fh, VECS, read_mode);
    readline(fh, ln); read(ln, ncase); read(ln, nv);
    assert nv = N
      report "tb_l2norm_rs: vector file N does not match the generic"
      severity failure;

    rst <= '1';
    for i in 0 to 5 loop wait until rising_edge(clk); end loop;
    rst <= '0'; wait until rising_edge(clk);

    worst_all := 0.0; nzero := 0;
    for c in 0 to ncase-1 loop
      readline(fh, ln); for i in 0 to N-1 loop read(ln, iv); xv(i) := iv; end loop;
      readline(fh, ln); for i in 0 to N-1 loop read(ln, iv); kv(i) := iv; end loop;
      readline(fh, ln); for i in 0 to N-1 loop read(ln, iv); qv(i) := iv; end loop;

      for i in 0 to N-1 loop
        xm((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(xv(i), 16));
      end loop;

      wait until rising_edge(clk);
      start <= '1'; wait until rising_edge(clk); start <= '0';
      cyc := 0;
      while dn = '0' loop
        wait until rising_edge(clk);
        cyc := cyc + 1;
        assert cyc < 20000
          report "case " & integer'image(c) & ": never finished" severity failure;
      end loop;
      wait until rising_edge(clk);

      -- ---- check 1: BIT-EXACT against ref/l2norm_rs_vec.c ---------------
      badx := 0;
      for i in 0 to N-1 loop
        ak := signed(km((i+1)*16-1 downto i*16));
        aq := signed(qm((i+1)*16-1 downto i*16));
        if to_integer(ak) /= kv(i) or to_integer(aq) /= qv(i) then
          if badx < 3 then
            report "case " & integer'image(c) & ": NOT BIT-EXACT vs C at element "
                 & integer'image(i) & "  k got " & integer'image(to_integer(ak))
                 & " want " & integer'image(kv(i)) & " | q got "
                 & integer'image(to_integer(aq)) & " want " & integer'image(qv(i))
              severity error;
          end if;
          badx := badx + 1;
        end if;
      end loop;
      if badx /= 0 then
        nexact := nexact + 1;
        fails <= fails + 1;
        report "case " & integer'image(c) & ": NOT BIT-EXACT vs C in "
             & integer'image(badx) & " element(s)" severity error;
      end if;

      -- ------------------------------------------------------------------
      -- check 2: THE GOLDEN IS REAL-VALUED AND INDEPENDENT OF THE RECIPE.
      --
      -- Check 1 above compares against a second transcription of the recipe,
      -- which is precisely the construction that certified a recipe emitting
      -- ZEROS on the whole q path for every input with ssq >= 2^33: golden
      -- and DUT rounded the same collapsed scalar to the same 0 and agreed
      -- perfectly.  So the reference HERE is the DEFINITION -- x / ||x|| in
      -- real arithmetic -- and the assertion is an accuracy bound in output
      -- LSBs.  This cannot be fooled by any error shared between the recipe
      -- and the unit, which is the entire class check 1 is blind to.
      -- ------------------------------------------------------------------
      -- ssq reaches 128 * 32768^2 = 2^37, which overflows VHDL's 32-bit
      -- integer, so the real accumulator is kept alongside the exact one
      -- rather than converted from it.
      ssq := (others => '0'); ssqr := 0.0;
      for i in 0 to N-1 loop
        xj   := to_signed(xv(i), 16);
        ssq  := ssq + resize(xj * xj, 64);
        ssqr := ssqr + real(xv(i)) * real(xv(i));
      end loop;
      nrm := sqrt(ssqr);

      bad := 0; worst := 0.0;
      for i in 0 to N-1 loop
        ak := signed(km((i+1)*16-1 downto i*16));
        aq := signed(qm((i+1)*16-1 downto i*16));
        if ssq = 0 then
          -- 2.1.3's deliberate divergence: zeros, not ggml's amplified dust
          if ak /= 0 or aq /= 0 then
            bad := bad + 1;
            report "case " & integer'image(c) & ": ssq = 0 did not emit zeros "
                 & "at element " & integer'image(i) severity error;
          end if;
        else
          rk := real(xv(i)) / nrm * 32768.0;                 -- exp 15
          rq := real(xv(i)) / (nrm * SQRTN) * 262144.0;      -- exp 18
          -- saturation is part of the contract, so compare against the
          -- saturated reference rather than calling a clamp a mismatch
          if rk >  32767.0 then rk :=  32767.0; end if;
          if rk < -32768.0 then rk := -32768.0; end if;
          if rq >  32767.0 then rq :=  32767.0; end if;
          if rq < -32768.0 then rq := -32768.0; end if;
          ek := abs(real(to_integer(ak)) - rk);
          eq := abs(real(to_integer(aq)) - rq);
          if ek > worst then worst := ek; end if;
          if eq > worst then worst := eq; end if;
          if ek > TOL or eq > TOL then
            if bad < 3 then
              report "case " & integer'image(c) & ": element " & integer'image(i) &
                     "  k got " & integer'image(to_integer(ak)) &
                     " want " & real'image(rk) &
                     " | q got " & integer'image(to_integer(aq)) &
                     " want " & real'image(rq) severity error;
            end if;
            bad := bad + 1;
          end if;
        end if;
      end loop;
      if ssq = 0 then nzero := nzero + 1; end if;
      if worst > worst_all then worst_all := worst; worst_c := c; end if;
      if bad /= 0 then
        fails <= fails + 1;
        report "case " & integer'image(c) & ": OUT OF TOLERANCE in " &
               integer'image(bad) & " element(s), worst " & real'image(worst) &
               " LSB" severity error;
      end if;
      if c mod 32 = 0 then
        report "case " & integer'image(c) & ": ok, within " & real'image(worst) &
               " LSB of x/||x|| (" & integer'image(cyc) & " cycles)" severity note;
      end if;
    end loop;
    file_close(fh);

    wait until rising_edge(clk);
    if fails = 0 then
      report "l2norm_rs: bit-exact with ref/l2norm_rs_vec.c on all "
           & integer'image(ncase) & " cases -- " & integer'image(N*ncase*2)
           & " elements over both paths, " & integer'image(nzero)
           & " case(s) with ssq = 0 -- and within tolerance of x/||x|| on every case"
           & " -- worst " & real'image(worst_all) & " output LSB at case "
           & integer'image(worst_c) & ", bound TOL = " & real'image(TOL)
        severity note;
    else
      report "l2norm_rs FAILED in " & integer'image(fails) & " case(s) ("
           & integer'image(nexact) & " not bit-exact)" severity failure;
    end if;
    fin <= true; wait;
  end process;
end architecture;
