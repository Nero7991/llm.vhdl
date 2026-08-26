-- Checks l2norm_rs against B 2.1.3 computed directly from work.fixed_pkg's own
-- rsqrt_q, which is the sanctioned reference implementation of this kernel and
-- the same function rmsnorm.vhd's pipelined rsqrt is asserted bit-exact with.
--
-- WHY NOT A/B AGAINST AN EXISTING UNIT, the way tb_rmsnorm_rs does.  There is
-- no existing L2 unit -- that is the point of writing this one -- so the golden
-- has to come from the package function plus the recipe, computed here in one
-- unpipelined expression per element.  That is a WEAKER form of golden than
-- tb_rmsnorm_rs's, because the recipe is transcribed twice rather than once,
-- and it is why the ssq = 0 case and the saturation corners are asserted
-- explicitly rather than left to the comparison.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use ieee.math_real.all;
use work.fixed_pkg.all;

entity tb_l2norm_rs is
  generic(N : positive := 128; LANES : positive := 4;
          -- Accuracy tolerance in output LSBs for the INDEPENDENT real-valued
          -- check.  Correct round-half-up bounds the error at 0.5 LSB and the
          -- unit measures 0.4995 worst case, so 0.75 leaves headroom for the
          -- Newton residual while still SEPARATING correct rounding from
          -- truncation (which reaches 1.0).  At the 2.0 this started at, a
          -- mutation that dropped the rounding bias entirely went undetected.
          TOL : real := 0.75);
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
    variable seed1, seed2 : positive := 3;
    variable r : real;
    variable ssq : signed(63 downto 0);
    variable nrm, ssqr, rk, rq, ek, eq, worst : real;
    constant SQRT128 : real := 11.3137084989847603904;
    variable xj : signed(15 downto 0);
    variable ak, aq : signed(15 downto 0);
    variable bad, cyc : natural;

    procedure setx(i : natural; v : integer) is
    begin
      xm((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(v, 16));
    end procedure;

    procedure check(tag : string) is
    begin
      wait until rising_edge(clk);
      start <= '1'; wait until rising_edge(clk); start <= '0';
      cyc := 0;
      while dn = '0' loop
        wait until rising_edge(clk);
        cyc := cyc + 1;
        assert cyc < 20000 report tag & ": never finished" severity failure;
      end loop;
      wait until rising_edge(clk);

      -- ------------------------------------------------------------------
      -- THE GOLDEN IS REAL-VALUED AND INDEPENDENT OF THE RECIPE.
      --
      -- The first version of this testbench computed its golden from the SAME
      -- fixed-point recipe the DUT implements, and it therefore certified a
      -- recipe that emitted ZEROS on the whole q path over the normal input
      -- range: golden and DUT rounded the same collapsed scalar to the same 0
      -- and agreed perfectly.  Bit-exactness against a twice-transcribed
      -- recipe proves transcription, not adequacy.
      --
      -- So the reference here is the DEFINITION -- x / ||x|| in real
      -- arithmetic -- and the assertion is an accuracy bound in output LSBs.
      -- This cannot be fooled by any error shared between the recipe and the
      -- unit, which is the entire class the first version was blind to.
      -- ------------------------------------------------------------------
      -- ssq reaches 128 * 32768^2 = 2^37, which overflows VHDL's 32-bit
      -- integer, so the real accumulator is kept alongside the exact one
      -- rather than converted from it.
      ssq := (others => '0'); ssqr := 0.0;
      for i in 0 to N-1 loop
        xj   := signed(xm((i+1)*16-1 downto i*16));
        ssq  := ssq + resize(xj * xj, 64);
        ssqr := ssqr + real(to_integer(xj)) * real(to_integer(xj));
      end loop;
      nrm := sqrt(ssqr);

      bad := 0; worst := 0.0;
      for i in 0 to N-1 loop
        xj := signed(xm((i+1)*16-1 downto i*16));
        ak := signed(km((i+1)*16-1 downto i*16));
        aq := signed(qm((i+1)*16-1 downto i*16));
        if ssq = 0 then
          -- 2.1.3's deliberate divergence: zeros, not ggml's amplified dust
          if ak /= 0 or aq /= 0 then bad := bad + 1; end if;
        else
          rk := real(to_integer(xj)) / nrm * 32768.0;                -- exp 15
          rq := real(to_integer(xj)) / (nrm * SQRT128) * 262144.0;   -- exp 18
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
              report tag & ": element " & integer'image(i) &
                     "  k got " & integer'image(to_integer(ak)) &
                     " want " & real'image(rk) &
                     " | q got " & integer'image(to_integer(aq)) &
                     " want " & real'image(rq) severity error;
            end if;
            bad := bad + 1;
          end if;
        end if;
      end loop;
      if bad /= 0 then
        fails <= fails + 1;
        report tag & ": OUT OF TOLERANCE in " & integer'image(bad) &
               " element(s), worst " & real'image(worst) & " LSB"
          severity error;
      else
        report tag & ": within " & real'image(worst) & " LSB of x/||x|| (" &
               integer'image(cyc) & " cycles)" severity note;
      end if;
    end procedure;
  begin
    rst <= '1';
    for i in 0 to 5 loop wait until rising_edge(clk); end loop;
    rst <= '0'; wait until rising_edge(clk);

    -- 1. the ssq = 0 case, which 2.1.3 requires to emit ZEROS and which is
    --    the deliberate divergence from ggml_l2_norm.  2.1.3 calls it
    --    reachable rather than theoretical: at position 0 every conv tap but
    --    one is masked, so one zero projection output zeroes a whole head.
    for i in 0 to N-1 loop setx(i, 0); end loop;
    check("ssq = 0 -> zeros (the ggml divergence)");
    for i in 0 to N-1 loop
      assert km((i+1)*16-1 downto i*16) = x"0000"
         and qm((i+1)*16-1 downto i*16) = x"0000"
        report "ssq=0 did not emit zeros at element " & integer'image(i)
        severity failure;
    end loop;

    -- 2. a single nonzero element: ssq is tiny, so 1/sqrt(ssq) is huge and
    --    BOTH paths must saturate.  This is the sat16 corner.
    for i in 0 to N-1 loop setx(i, 0); end loop;
    setx(0, 1);
    check("single element = 1 (sat16 corner)");
    setx(0, -1);
    check("single element = -1 (negative sat16 corner)");

    -- 3. saturated magnitudes
    for i in 0 to N-1 loop
      if i mod 2 = 0 then setx(i, 32767); else setx(i, -32768); end if;
    end loop;
    check("all +-32767/-32768");

    -- 4. uniform, the typical case: |x| ~ sqrt(ssq/128) so the outputs land
    --    mid-range and nothing saturates
    for i in 0 to N-1 loop setx(i, 1000); end loop;
    check("uniform 1000");
    for i in 0 to N-1 loop setx(i, -1000); end loop;
    check("uniform -1000");

    -- 5. powers of two, where the rsqrt's normalisation and parity fold
    --    change branch
    for m in 0 to 14 loop
      for i in 0 to N-1 loop setx(i, 2**m); end loop;
      check("uniform 2^" & integer'image(m));
    end loop;

    -- 6. magnitude sweep -- the case that actually exercises the rsqrt, for
    --    the same reason tb_rmsnorm_rs needs one
    for m in 0 to 24 loop
      for i in 0 to N-1 loop
        setx(i, ((m * 41 + i * 13) mod 4000) - 2000 + m * 800);
      end loop;
      check("magnitude sweep m=" & integer'image(m));
    end loop;

    -- 7. random
    for t in 0 to 9 loop
      for i in 0 to N-1 loop
        uniform(seed1, seed2, r); setx(i, integer(r*50000.0) - 25000);
      end loop;
      check("random " & integer'image(t));
    end loop;

    wait until rising_edge(clk);
    if fails = 0 then
      report "l2norm_rs is within tolerance of x/||x|| on every case" severity note;
    else
      report "l2norm_rs OUT OF TOLERANCE in " & integer'image(fails) & " case(s)"
        severity failure;
    end if;
    fin <= true; wait;
  end process;
end architecture;
