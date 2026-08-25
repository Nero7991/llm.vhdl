-- The narrowed cone must be BIT-IDENTICAL to the verbatim-width one, or its
-- DSP saving is a silent accuracy change rather than a saving.  Both are
-- driven from the same stimulus in lockstep and compared every cycle.
--
-- The range is swept exhaustively where it matters (the 512 table intervals,
-- every frac boundary) and out to the saturation corners on both sides, which
-- is the only place the two forms can legitimately differ in intermediate
-- values (the wide one lets frac run away and discards it; the narrow one
-- clamps).  They must still agree on the OUTPUT there.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_silu_cone is
  generic(Q : integer := 12; OUT_Q : integer := 15);
end entity;

architecture sim of tb_silu_cone is
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal iv  : std_logic := '0';
  signal zq  : std_logic_vector(31 downto 0) := (others => '0');
  signal ov_w, ov_n : std_logic;
  signal g_w,  g_n  : std_logic_vector(15 downto 0);
  signal done : boolean := false;
  signal nchk, nbad : integer := 0;
begin
  clk <= '0' when done else not clk after 1 ns;

  wide : entity work.micro_sig_cone
    generic map(Q => Q, OUT_Q => OUT_Q)
    port map(clk => clk, rst => rst, iv => iv, z_q => zq, ov => ov_w, g_out => g_w);

  narrow : entity work.micro_silu_narrow
    generic map(Q => Q, OUT_Q => OUT_Q, SILU => 0)
    port map(clk => clk, rst => rst, iv => iv, z_q => zq, ov => ov_n, g_out => g_n);

  -- both are 3-stage with identical latency, so ov and g line up cycle for cycle
  chk : process(clk)
  begin
    if rising_edge(clk) then
      if ov_w = '1' or ov_n = '1' then
        nchk <= nchk + 1;
        if ov_w /= ov_n or g_w /= g_n then
          nbad <= nbad + 1;
          report "MISMATCH wide=" & integer'image(to_integer(signed(g_w))) &
                 " narrow=" & integer'image(to_integer(signed(g_n)))
                 severity error;
        end if;
      end if;
    end if;
  end process;

  drv : process
    procedure drive(v : integer) is
    begin
      zq <= std_logic_vector(to_signed(v, 32));
      iv <= '1';
      wait until rising_edge(clk);
    end procedure;
    constant LIM : integer := 16 * (2**Q);      -- the saturation corner
  begin
    rst <= '1'; wait for 10 ns;
    wait until rising_edge(clk);
    rst <= '0'; wait until rising_edge(clk);

    -- 1. every table interval, at its low edge, midpoint and high edge
    for k in 0 to 511 loop
      drive(-LIM + (k * (2**Q)) / 16);
      drive(-LIM + (k * (2**Q)) / 16 + (2**Q) / 32);
      drive(-LIM + ((k + 1) * (2**Q)) / 16 - 1);
    end loop;

    -- 2. a dense sweep near zero, where the slope is largest
    for v in -2048 to 2048 loop
      drive(v);
    end loop;

    -- 3. both saturation corners and well past them, the only place the two
    --    forms' INTERNAL values differ
    for v in 0 to 64 loop
      drive( LIM - 32 + v);
      drive(-LIM - 32 + v);
    end loop;
    drive( LIM * 4);   drive(-LIM * 4);
    drive( 2**30);     drive(-(2**30));
    drive( 2**30 + 7); drive(-(2**30) - 7);

    iv <= '0';
    for i in 0 to 8 loop wait until rising_edge(clk); end loop;

    report "compared " & integer'image(nchk) & " outputs, " &
           integer'image(nbad) & " mismatches" severity note;
    assert nchk > 4000
      report "COVERAGE: too few comparisons, the sweep did not run" severity failure;
    assert nbad = 0
      report "NARROWED CONE IS NOT BIT-IDENTICAL TO THE VERBATIM ONE" severity failure;
    report "narrowed cone is bit-identical to the verbatim-width cone" severity note;
    done <= true;
    wait;
  end process;
end architecture;
