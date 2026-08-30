-- tb_readconv_l2.vhd -- TRACK READCONV, 2026-08-29.
--
-- THE ORACLE.  This runs the post-change `l2norm_rs` and `l2norm_rs_ref` --
-- the PRE-change file, byte for byte, with only the entity and architecture
-- names changed -- side by side off IDENTICAL stimulus, and compares every
-- output element and the start-to-done cycle count.
--
-- WHY NOT A ROUND TRIP.  A self-consistency check passes for a
-- wrong-but-consistent implementation.  The comparison here is against an
-- independent copy of the code that was known good, which is the only thing a
-- structural rewrite of a write path can be checked against.
--
-- NON-TRIVIALITY IS ASSERTED ON EVERY TRIAL, AND THAT IS THE POINT.
-- `l2norm_rs` has a SILENT ALL-ZEROS RAIL: ssq = 0 takes S_ZERO and emits
-- zeros on both paths by design (B 2.1.3's deliberate divergence from ggml),
-- and a badly chosen magnitude makes sat16 round every element to 0 as well.
-- TRACK LUTDIET's probe was fooled by exactly this on rmsnorm_rs: three of six
-- trials proved nothing and the run still reported 6 of 6 passed.  So every
-- trial declares whether it EXPECTS zeros, and the bench fails hard if a trial
-- that should be live is not, or if a trial that should be dead is not.
--
-- DELIBERATELY NOT IN sim/.  A new sim/tb_*.vhd is auto-discovered into the
-- shared regression gate, and this bench needs `l2norm_rs_ref`, which is not
-- in rtl/ and must never be moved there.
--
-- NO HARDWARE.  Simulation only.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;

entity tb_readconv_l2 is
  generic(
    N     : positive := 128;
    LANES : positive := 4
  );
end entity;

architecture sim of tb_readconv_l2 is
  constant W : integer := N*16;

  signal clk   : std_logic := '0';
  signal rst   : std_logic := '1';
  signal start : std_logic := '0';
  signal x     : std_logic_vector(W-1 downto 0) := (others => '0');

  signal d_done, r_done : std_logic;
  signal d_k, d_q, r_k, r_q : std_logic_vector(W-1 downto 0);

  signal running : boolean := true;

  -- done-cycle capture, driven by a free-running counter so the two units are
  -- timed by the same clock edge and not by two different wait statements
  signal cyc      : natural := 0;
  signal d_at, r_at : integer := -1;
  -- p_cyc is the ONLY driver of d_at/r_at.  GHDL rejects two processes driving
  -- an unresolved signal, and letting the stimulus process clear the
  -- timestamps would also have raced the capture.  p_stim arms instead.
  signal arm      : std_logic := '0';

  signal fails : natural := 0;
  signal trials, live_trials : natural := 0;
begin
  clk <= not clk after 5 ns when running else '0';

  u_dut : entity work.l2norm_rs
    generic map(N => N, LANES => LANES)
    port map(clk => clk, rst => rst, start => start, x_mant => x,
             done => d_done, k_mant => d_k, q_mant => d_q);

  u_ref : entity work.l2norm_rs_ref
    generic map(N => N, LANES => LANES)
    port map(clk => clk, rst => rst, start => start, x_mant => x,
             done => r_done, k_mant => r_k, q_mant => r_q);

  -- The done timestamps.  Captured in their own process off the same edge, so
  -- a one-cycle schedule change shows up as d_at /= r_at and cannot be hidden
  -- by the stimulus process happening to sample late.
  p_cyc : process(clk) begin
    if rising_edge(clk) then
      cyc <= cyc + 1;
      if arm = '0' then
        d_at <= -1; r_at <= -1;
      else
        if d_done = '1' then d_at <= cyc; end if;
        if r_done = '1' then r_at <= cyc; end if;
      end if;
    end if;
  end process;

  p_stim : process
    variable seed : unsigned(31 downto 0);
    variable v    : integer;
    variable nz_k, nz_q : natural;
    variable dist_k : natural;
    variable seen : integer_vector(0 to 15);
    variable nseen : natural;
    variable e_ref, e_dut : integer;
    variable ok : boolean;

    procedure step is begin wait until rising_edge(clk); end procedure;

    -- Load one stimulus vector.  cls picks the class; see the table in the
    -- write-up.  Returns through the shared signal `x`.
    procedure load(cls : integer) is
      variable m : integer;
    begin
      seed := x"12345678" + to_unsigned(cls*7919, 32);
      for i in 0 to N-1 loop
        case cls is
          when 0 => v :=  1000;                              -- flat, moderate
          when 1 => v :=  ((i mod 251) - 125) * 61;           -- ramp, signed
          when 2 => v :=  32767;                              -- flat, maximal
          when 3 => v :=  32767 when (i mod 2) = 0 else -32768;
          when 4 => v :=  20000 when i = 0 else 0;            -- lone element 0
          when 5 => v :=  20000 when i = N-1 else 0;          -- lone element N-1
          when 6 =>                                            -- LFSR moderate
            seed := seed(30 downto 0) & (seed(31) xor seed(21) xor seed(1) xor seed(0));
            v := to_integer(signed(seed(11 downto 0)));
          when 7 =>                                            -- LFSR large
            seed := seed(30 downto 0) & (seed(31) xor seed(21) xor seed(1) xor seed(0));
            v := to_integer(signed(seed(15 downto 0)));
          when 8 => v := 0;                                    -- ssq = 0 rail
          when 9 =>                                            -- MIXED magnitude
            -- The class that caught gdn/l2's pipeline-gating bug: a uniform
            -- vector cannot see a block written with the wrong index.
            m := 2 ** (1 + (i mod 14));
            v := m when (i mod 3) /= 0 else -m;
          when 10 => v := -32768;                              -- flat, most negative
          when 11 => v := 3 when (i mod 7) = 0 else 0;         -- sparse, tiny
          -- 12 and 13 exist ONLY to try to reach the NEGATIVE saturation
          -- branch of sat16.  Class 4's lone +20000 makes the exact ratio
          -- x/sqrt(ssq) equal to +1, so k_n lands on 32768, one past the
          -- positive limit, and the high clamp fires.  The mirror lands on
          -- -32768 exactly, which is REPRESENTABLE, so it takes the resize
          -- branch and not the clamp.  See the coverage note in the write-up.
          when 12 => v := -20000 when i = 0 else 0;            -- lone negative
          when 13 => v := -32768 when i = 0 else 0;            -- lone, most negative
          when others => v := 0;
        end case;
        x((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(v, 16));
      end loop;
    end procedure;

    -- Run one invocation on both units and compare.
    -- expect_zero: this class takes the S_ZERO rail by construction.
    -- want_var   : this class must produce at least two DISTINCT k values.
    procedure trial(cls : integer; expect_zero : boolean; want_var : boolean;
                    mid_reset : boolean) is
    begin
      load(cls);
      arm <= '0';
      step; step;
      arm <= '1';
      step;
      start <= '1'; step; start <= '0';

      if mid_reset then
        -- Take reset in the middle of the run and confirm both units land in
        -- the same place afterwards.  rst does NOT clear v1 in either unit, so
        -- this is the case the `rst = '0'` term in the new write decode exists
        -- for.
        for i in 0 to N/LANES + 20 loop step; end loop;
        rst <= '1'; arm <= '0'; step; step; rst <= '0'; step;
        -- and then a clean run
        arm <= '1'; step;
        start <= '1'; step; start <= '0';
      end if;

      for i in 0 to 40*N + 4000 loop
        exit when d_at >= 0 and r_at >= 0;
        step;
      end loop;

      trials <= trials + 1;
      ok := true;

      assert d_at >= 0 and r_at >= 0
        report "READCONV FAIL cls=" & integer'image(cls)
               & " : a unit never asserted done (dut=" & integer'image(d_at)
               & " ref=" & integer'image(r_at) & ")"
        severity failure;

      if d_at /= r_at then
        report "READCONV FAIL cls=" & integer'image(cls)
               & " : done cycle differs, dut=" & integer'image(d_at)
               & " ref=" & integer'image(r_at) severity error;
        ok := false;
      end if;

      -- element-by-element, both paths
      nz_k := 0; nz_q := 0; nseen := 0;
      for i in 0 to N-1 loop
        e_ref := to_integer(signed(r_k((i+1)*16-1 downto i*16)));
        e_dut := to_integer(signed(d_k((i+1)*16-1 downto i*16)));
        if e_ref /= e_dut then
          report "READCONV FAIL cls=" & integer'image(cls) & " k[" &
                 integer'image(i) & "] ref=" & integer'image(e_ref) &
                 " dut=" & integer'image(e_dut) severity error;
          ok := false;
        end if;
        if e_ref /= 0 then nz_k := nz_k + 1; end if;
        if nseen < 16 then
          dist_k := 0;
          for j in 0 to nseen-1 loop
            if seen(j) = e_ref then dist_k := 1; end if;
          end loop;
          if dist_k = 0 then seen(nseen) := e_ref; nseen := nseen + 1; end if;
        end if;

        e_ref := to_integer(signed(r_q((i+1)*16-1 downto i*16)));
        e_dut := to_integer(signed(d_q((i+1)*16-1 downto i*16)));
        if e_ref /= e_dut then
          report "READCONV FAIL cls=" & integer'image(cls) & " q[" &
                 integer'image(i) & "] ref=" & integer'image(e_ref) &
                 " dut=" & integer'image(e_dut) severity error;
          ok := false;
        end if;
        if e_ref /= 0 then nz_q := nz_q + 1; end if;
      end loop;

      -- ---- NON-TRIVIALITY.  Without this the trial proves nothing. -------
      if expect_zero then
        assert nz_k = 0 and nz_q = 0
          report "READCONV BENCH DEFECT cls=" & integer'image(cls)
                 & " : the S_ZERO class produced non-zero output"
          severity failure;
      else
        assert nz_k > 0
          report "READCONV DEGENERATE TRIAL cls=" & integer'image(cls)
                 & " : k path is all zeros, the trial proves nothing"
          severity failure;
        assert nz_q > 0
          report "READCONV DEGENERATE TRIAL cls=" & integer'image(cls)
                 & " : q path is all zeros, the trial proves nothing"
          severity failure;
        live_trials <= live_trials + 1;
      end if;

      if want_var then
        assert nseen >= 2
          report "READCONV DEGENERATE TRIAL cls=" & integer'image(cls)
                 & " : every k element is the same value, the trial cannot "
                 & "see a mis-indexed write"
          severity failure;
      end if;

      if not ok then fails <= fails + 1; end if;

      report "READCONV trial cls=" & integer'image(cls)
             & " done_cyc=" & integer'image(d_at)
             & " nz_k=" & integer'image(nz_k)
             & " nz_q=" & integer'image(nz_q)
             & " distinct_k=" & integer'image(nseen)
             & " ok=" & boolean'image(ok);

      -- let both units settle back to idle
      arm <= '0';
      for i in 0 to 8 loop step; end loop;
    end procedure;

  begin
    rst <= '1';
    for i in 0 to 8 loop step; end loop;
    rst <= '0';
    step;

    --      cls  expect_zero  want_var  mid_reset
    trial(   0,     false,     false,    false);
    trial(   1,     false,     true,     false);
    trial(   2,     false,     false,    false);
    trial(   3,     false,     true,     false);
    trial(   4,     false,     true,     false);
    trial(   5,     false,     true,     false);
    trial(   6,     false,     true,     false);
    trial(   7,     false,     true,     false);
    trial(   8,     true,      false,    false);
    trial(   9,     false,     true,     false);
    trial(  10,     false,     false,    false);
    trial(  11,     false,     true,     false);
    trial(  12,     false,     true,     false);
    trial(  13,     false,     true,     false);
    -- and the same live classes again with a reset taken mid-run
    trial(   9,     false,     true,     true);
    trial(   1,     false,     true,     true);

    report "READCONV SUMMARY N=" & integer'image(N)
           & " LANES=" & integer'image(LANES)
           & " trials=" & integer'image(trials)
           & " live=" & integer'image(live_trials)
           & " fails=" & integer'image(fails);

    assert fails = 0
      report "READCONV OVERALL FAIL" severity failure;
    report "READCONV OVERALL PASS";
    running <= false;
    wait;
  end process;
end architecture;
