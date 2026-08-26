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
  generic(N : positive := 128; LANES : positive := 4; Q : integer := 18);
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
    generic map(N => N, LANES => LANES, Q => Q)
    port map(clk=>clk, rst=>rst, start=>start, x_mant=>xm,
             done=>dn, k_mant=>km, q_mant=>qm);

  drv : process
    variable seed1, seed2 : positive := 3;
    variable r : real;
    variable ssq : signed(63 downto 0);
    variable invk, invq : signed(31 downto 0);
    variable xj : signed(15 downto 0);
    variable ek, eq : signed(63 downto 0);
    variable gk, gq : signed(15 downto 0);
    variable ak, aq : signed(15 downto 0);
    variable bad, cyc : natural;

    procedure setx(i : natural; v : integer) is
    begin
      xm((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(v, 16));
    end procedure;

    function sat32(v : signed) return signed is
    begin
      if    v > to_signed(2147483647, 64) then return to_signed(2147483647, 32);
      elsif v < 0                         then return to_signed(0, 32);
      else                                     return resize(v, 32);
      end if;
    end function;

    function sat16(v : signed) return signed is
    begin
      if    v >  32767 then return to_signed( 32767, 16);
      elsif v < -32768 then return to_signed(-32768, 16);
      else                  return resize(v, 16);
      end if;
    end function;

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

      -- golden, straight from the recipe
      ssq := (others => '0');
      for i in 0 to N-1 loop
        xj  := signed(xm((i+1)*16-1 downto i*16));
        ssq := ssq + resize(xj * xj, 64);
      end loop;
      if ssq = 0 then
        invk := (others => '0'); invq := (others => '0');
      else
        -- rsqrt_q returns s64; the recipe clamps it to s32 exactly as
        -- rmsnorm.vhd's S_RQ_FIN does, so the golden clamps here too.
        invk := sat32(rsqrt_q(shift_left(ssq, Q),     Q));
        invq := sat32(rsqrt_q(shift_left(ssq, Q + 7), Q));
      end if;

      bad := 0;
      for i in 0 to N-1 loop
        xj := signed(xm((i+1)*16-1 downto i*16));
        if ssq = 0 then
          gk := (others => '0'); gq := (others => '0');
        else
          ek := shift_right(resize(resize(xj, 17) * invk, 64)
                            + to_signed(4, 64), 3);
          eq := resize(resize(xj, 17) * invq, 64);
          gk := sat16(ek); gq := sat16(eq);
        end if;
        ak := signed(km((i+1)*16-1 downto i*16));
        aq := signed(qm((i+1)*16-1 downto i*16));
        if ak /= gk or aq /= gq then
          if bad < 3 then
            report tag & ": element " & integer'image(i) &
                   "  k got " & integer'image(to_integer(ak)) &
                   " want " & integer'image(to_integer(gk)) &
                   " | q got " & integer'image(to_integer(aq)) &
                   " want " & integer'image(to_integer(gq)) severity error;
          end if;
          bad := bad + 1;
        end if;
      end loop;
      if bad /= 0 then
        fails <= fails + 1;
        report tag & ": MISMATCH in " & integer'image(bad) & " element(s)"
          severity error;
      else
        report tag & ": matches the 2.1.3 recipe (" & integer'image(cyc) &
               " cycles)" severity note;
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
      report "l2norm_rs matches the 2.1.3 recipe on every case" severity note;
    else
      report "l2norm_rs DIFFERS in " & integer'image(fails) & " case(s)"
        severity failure;
    end if;
    fin <= true; wait;
  end process;
end architecture;
