--------------------------------------------------------------------------------
-- tb_fk33_thermal -- does the thermal guard actually halt, and actually fail safe
--------------------------------------------------------------------------------
-- WHY THIS EXISTS
-- ---------------
-- A threshold that has never been crossed in simulation is not implemented, it
-- is written down.  Every path below is exercised against the real RTL:
--
--   1. the guard comes up HALTED with no sensor reading, and the compute-domain
--      canary does NOT advance;
--   2. it releases once both sensors are live, plausible and cool;
--   3. the warn threshold sets warn without halting;
--   4. the die halt threshold halts, latches a cause, a temperature and a count;
--   5. HYSTERESIS: a temperature between the resume point and the halt point
--      keeps it halted;
--   6. STALENESS: stopping the die liveness strobe halts it, with the stale
--      cause, even though the VALUE is still perfectly cool;
--   7. STUCK-AT-ZERO: a sensor reading 0 with its liveness strobe still running
--      halts it.  This is the one a value comparison alone gets wrong, because
--      0 also means "very cold";
--   8. the HBM code threshold halts;
--   9. CATTRIP halts and STAYS halted after the live signal goes away;
--  10. a clear with the WRONG KEY changes nothing;
--  11. a clear with the right key over the aux (JTAG) path clears the latch and
--      LEAVES THE PEAK-HOLD INTACT;
--  12. a clear over the HOST path does the same, from its own clock domain;
--  13. a clear issued while the card is still HOT does NOT release the halt.
--
-- Added 2026-08-30, after THERM-255.  hbm_temp0 and hbm_temp1 are TWO SEPARATE
-- DIES (build_fk33_pcieep.tcl:781-782), and the rows above never noticed
-- because set_hbm drove both stacks to the SAME code on every single call, so
-- the whole two-stack axis was untested.  These four rows are the ones that
-- distinguish a two-stack guard from a guard that halts on inequality:
--
--  18. the two stacks a single code apart at benign values does NOT halt and
--      does NOT count a trip -- the defect that halted an idle card 255 times
--      at 38 C against a halt threshold of 85 -- and, when that difference
--      PERSISTS past the dwell, it is REPORTED in the sticky and STILL not
--      halted.  Two tiers, and only the wide one may stop the datapath;
--  19. a genuine over-temperature on EITHER stack ALONE halts, with the
--      OVER cause and both stacks' codes latched.  This is the row that catches
--      a fix which trades the false halt for a missed one -- before it, the
--      halt, resume and warn thresholds were all compared against h0_acc only,
--      so stack 1 reached no threshold in the design at all;
--  20. stack 1 is plausibility-checked IN ITS OWN RIGHT (the band used to be
--      applied to stack 0 alone), and a LARGE divergence, sustained, DOES
--      invalidate the sensor and halt.  That is the stuck-sensor case the
--      equality test used to cover by accident, and dropping the equality test
--      without it leaves it open;
--  21. a halt cause exactly ONE aux clock long records ITS OWN cause, not the
--      benign aftermath one cycle later.  The card recorded `trips=1`, cause
--      `none` and two EQUAL HBM codes for a trip that an INEQUALITY caused.
--
-- Generics are scaled so a simulated millisecond is a real millisecond and the
-- whole run is a few tens of milliseconds.  Every count in the design derives
-- from G_CLK_HZ, so the behaviour is identical to the 200 MHz build.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_fk33_thermal is
end entity;

architecture sim of tb_fk33_thermal is

  constant CLK_HZ    : natural := 2000000;      -- aux clock, 2 MHz
  constant TCK       : time    := 500 ns;
  constant TSYS      : time    := 400 ns;       -- SYSMON DRP clock, 2.5 MHz
  constant TPCLK     : time    := 1000 ns;      -- HBM APB clock, 1 MHz
  constant TCOMP     : time    := 400 ns;       -- compute clock, 2.5 MHz

  constant STALE_MS  : natural := 5;
  constant MINHALT   : natural := 2;

  constant DIE_WARN_C   : natural := 80;
  constant DIE_HALT_C   : natural := 90;
  constant DIE_RESUME_C : natural := 75;
  constant HBM_WARN_C   : natural := 75;
  constant HBM_HALT_C   : natural := 85;
  constant HBM_RESUME_C : natural := 70;

  -- The two-stack divergence bound and its dwell.  DIV_MS is scaled down from
  -- the build's 250 ms the same way STALE_MS is, so a row can wait it out.
  --
  -- It must stay comfortably LONGER than the longest unequal stretch any row
  -- that expects the sticky to be CLEAR spends in that state.  Set to 8 first,
  -- and section 18 then set the sticky legitimately -- three consecutive 3 ms
  -- waits with the stacks one code apart is 9 ms, and the dwell does not reset
  -- when the difference merely changes sign.  That was the bench being wrong
  -- about its own timing, not the design.
  constant HBM_MAX_DELTA : natural := 20;
  constant HBM_DIV_MS    : natural := 20;

  constant KEY : std_logic_vector(15 downto 0) := x"C1EA";

  -- The same integer transfer function the DUT uses, repeated here on purpose.
  -- If the two ever disagree the testbench stops matching the design, which is
  -- exactly what a threshold regression looks like.
  function die_code(t_c : integer) return natural is
  begin
    return (t_c * 10000 + 2794266) / 4957;
  end function;

  signal aux_clk    : std_logic := '0';
  signal aux_rstn   : std_logic := '0';
  signal sysmon_clk : std_logic := '0';
  signal hbm_pclk   : std_logic := '0';
  signal comp_clk   : std_logic := '0';

  signal sysmon_temp  : std_logic_vector(9 downto 0) := (others => '0');
  signal sysmon_ot    : std_logic := '0';
  signal sysmon_alarm : std_logic := '0';
  signal sysmon_eoc   : std_logic := '0';
  signal eoc_on       : boolean := true;

  signal hbm_temp0 : std_logic_vector(6 downto 0) := (others => '0');
  signal hbm_temp1 : std_logic_vector(6 downto 0) := (others => '0');
  signal cattrip0  : std_logic := '0';
  signal cattrip1  : std_logic := '0';
  signal pclk_on   : boolean := true;

  signal ctl_aux  : std_logic_vector(31 downto 0) := (others => '0');
  signal ctl_host : std_logic_vector(31 downto 0) := (others => '0');

  signal compute_halt : std_logic;
  signal s_therm, s_temps, s_peak, s_trip, s_canary
                      : std_logic_vector(31 downto 0);
  signal h_therm, h_temps, h_peak, h_trip, h_canary
                      : std_logic_vector(31 downto 0);

  -- cause codes, mirrored from the DUT
  constant CAUSE_DIE_OT    : natural := 1;
  constant CAUSE_DIE_ALARM : natural := 2;
  constant CAUSE_DIE_OVER  : natural := 3;
  constant CAUSE_DIE_STALE : natural := 4;
  constant CAUSE_HBM_CAT   : natural := 5;
  constant CAUSE_HBM_OVER  : natural := 6;
  constant CAUSE_HBM_STALE : natural := 7;

begin

  aux_clk    <= not aux_clk    after TCK / 2;
  sysmon_clk <= not sysmon_clk after TSYS / 2;
  comp_clk   <= not comp_clk   after TCOMP / 2;
  hbm_pclk   <= (not hbm_pclk) after TPCLK / 2 when pclk_on else '0';

  -- SYSMON end-of-conversion, the die liveness source.  One pulse every 20
  -- sysmon clocks; the DUT divides it by 8 before crossing.
  eoc_gen : process
  begin
    wait for TSYS * 20;
    if eoc_on then
      sysmon_eoc <= '1';
      wait for TSYS;
      sysmon_eoc <= '0';
    end if;
  end process;

  dut : entity work.fk33_thermal
    generic map (
      G_CLK_HZ       => CLK_HZ,
      G_DIE_WARN_C   => DIE_WARN_C,
      G_DIE_HALT_C   => DIE_HALT_C,
      G_DIE_RESUME_C => DIE_RESUME_C,
      G_HBM_WARN_C   => HBM_WARN_C,
      G_HBM_HALT_C   => HBM_HALT_C,
      G_HBM_RESUME_C => HBM_RESUME_C,
      G_HBM_MAX_DELTA => HBM_MAX_DELTA,
      G_HBM_DIV_MS    => HBM_DIV_MS,
      G_STALE_MS     => STALE_MS,
      G_MIN_HALT_MS  => MINHALT,
      G_CANARY_BIT   => 4
    )
    port map (
      aux_clk      => aux_clk,
      aux_aresetn  => aux_rstn,
      sysmon_clk   => sysmon_clk,
      sysmon_temp  => sysmon_temp,
      sysmon_ot    => sysmon_ot,
      sysmon_alarm => sysmon_alarm,
      sysmon_eoc   => sysmon_eoc,
      hbm_pclk     => hbm_pclk,
      hbm_temp0    => hbm_temp0,
      hbm_temp1    => hbm_temp1,
      hbm_cattrip0 => cattrip0,
      hbm_cattrip1 => cattrip1,
      ctl_aux      => ctl_aux,
      ctl_host_clk => comp_clk,
      ctl_host     => ctl_host,
      compute_clk  => comp_clk,
      compute_halt => compute_halt,
      stat_therm   => s_therm,
      stat_temps   => s_temps,
      stat_peak    => s_peak,
      stat_trip    => s_trip,
      stat_canary  => s_canary,
      host_therm   => h_therm,
      host_temps   => h_temps,
      host_peak    => h_peak,
      host_trip    => h_trip,
      host_canary  => h_canary
    );

  main : process
    variable c0 : unsigned(31 downto 0);
    variable pk : unsigned(9 downto 0);

    procedure set_die(t_c : integer) is
    begin
      sysmon_temp <= std_logic_vector(to_unsigned(die_code(t_c), 10));
    end procedure;

    procedure set_hbm(code : natural) is
    begin
      hbm_temp0 <= std_logic_vector(to_unsigned(code, 7));
      hbm_temp1 <= std_logic_vector(to_unsigned(code, 7));
    end procedure;

    -- The two stacks driven INDEPENDENTLY.  Every row above this one used
    -- set_hbm, which drives both to the same code, and that is precisely why
    -- none of them could see THERM-255.
    procedure set_hbm2(code0, code1 : natural) is
    begin
      hbm_temp0 <= std_logic_vector(to_unsigned(code0, 7));
      hbm_temp1 <= std_logic_vector(to_unsigned(code1, 7));
    end procedure;

    -- The canary is the observable thing the halt gates.  It advances only
    -- while the compute domain is running AND the guard has released it.
    procedure check_canary(should_move : boolean; what : string) is
      variable a : unsigned(31 downto 0);
    begin
      a := unsigned(s_canary);
      wait for 3 ms;
      if should_move then
        assert unsigned(s_canary) > a
          report "tb_fk33_thermal: the canary did NOT advance while " & what
          severity failure;
      else
        assert unsigned(s_canary) = a
          report "tb_fk33_thermal: the canary ADVANCED while " & what &
                 " -- the halt is not gating the compute domain"
          severity failure;
      end if;
    end procedure;

    procedure expect_halt(v : std_logic; what : string) is
    begin
      assert s_therm(0) = v
        report "tb_fk33_thermal: halted=" & std_logic'image(s_therm(0)) &
               " but expected " & std_logic'image(v) & " while " & what
        severity failure;
      assert compute_halt = v
        report "tb_fk33_thermal: compute_halt does not match the aux-domain "
             & "halt while " & what
        severity failure;
    end procedure;

    procedure expect_cause(c : natural; what : string) is
    begin
      assert to_integer(unsigned(s_therm(11 downto 8))) = c
        report "tb_fk33_thermal: live cause is " &
               integer'image(to_integer(unsigned(s_therm(11 downto 8)))) &
               ", expected " & integer'image(c) & " while " & what
        severity failure;
    end procedure;

    procedure expect_trip(c : natural; n : natural; what : string) is
    begin
      assert s_therm(7) = '1'
        report "tb_fk33_thermal: no trip latched after " & what severity failure;
      assert to_integer(unsigned(s_therm(15 downto 12))) = c
        report "tb_fk33_thermal: latched cause is " &
               integer'image(to_integer(unsigned(s_therm(15 downto 12)))) &
               ", expected " & integer'image(c) & " after " & what
        severity failure;
      assert to_integer(unsigned(s_therm(23 downto 16))) = n
        report "tb_fk33_thermal: trip count is " &
               integer'image(to_integer(unsigned(s_therm(23 downto 16)))) &
               ", expected " & integer'image(n) & " after " & what
        severity failure;
    end procedure;

    -- Wait for the guard to release, with a bound so a design that never
    -- releases fails as a timeout rather than hanging the simulation.
    procedure wait_release(what : string) is
      variable t : time;
    begin
      t := now;
      while s_therm(0) = '1' loop
        wait for 100 us;
        assert now - t < 60 ms
          report "tb_fk33_thermal: the guard never released while " & what
          severity failure;
      end loop;
    end procedure;

  begin
    ---------------------------------------------------------------- 1. reset
    -- Before anything: the guard must be HALTED with no reading at all.  This
    -- is the fail-safe that matters most, because it is the state the card
    -- powers up in.
    --
    -- Checked at time zero, BEFORE any clock edge, because that is the only
    -- moment at which the register INITIAL values are observable: the
    -- combinational hot logic re-asserts the halt within one aux clock, so a
    -- design whose registers powered up released would look identical a
    -- microsecond later.
    wait for 1 ns;
    assert compute_halt = '1'
      report "tb_fk33_thermal: compute_halt does not power up HALTED.  A "
           & "datapath sampling it before the first clock edge would be "
           & "released with no temperature reading in existence"
      severity failure;
    assert s_therm(0) = '1'
      report "tb_fk33_thermal: the guard does not power up halted"
      severity failure;

    set_die(25);
    set_hbm(0);                   -- what an HBM that has not read yet gives
    wait for 200 us;
    expect_halt('1', "still in reset with no sensor reading");
    assert s_therm(31) = '1' report "the guard-present bit must read 1"
      severity failure;
    assert s_therm(2) = '0' report "armed must be 0 before the first release"
      severity failure;
    assert s_therm(4) = '0'
      report "the HBM sensor must NOT be valid at code 0.  Code <= 5 means the "
           & "IP has not produced a reading; treating it as 0 C is the "
           & "stuck-at-zero failure this design exists to avoid"
      severity failure;
    check_canary(false, "held in reset with no sensor reading");

    aux_rstn <= '1';
    wait for 200 us;
    expect_halt('1', "just out of reset, HBM still reading 0");
    expect_cause(CAUSE_HBM_STALE, "HBM still reading 0");

    ------------------------------------------------------- 2. cool and release
    set_hbm(30);
    wait_release("both sensors cool");
    assert s_therm(2) = '1' report "armed should be set after the first release"
      severity failure;
    assert s_therm(3) = '1' and s_therm(4) = '1'
      report "both sensors should read valid when cool and live" severity failure;
    assert to_integer(unsigned(s_therm(23 downto 16))) = 0
      report "the fail-safe halt from reset must NOT be counted as a trip"
      severity failure;
    check_canary(true, "cool and released");

    -- the reported die temperature, through the approximate conversion
    assert abs(to_integer(signed(s_temps(31 downto 24))) - 25) <= 2
      report "the reported die temperature is " &
             integer'image(to_integer(signed(s_temps(31 downto 24)))) &
             " C, expected about 25" severity failure;

    ----------------------------------------------------------------- 3. warn
    set_die(DIE_WARN_C + 2);
    wait for 1 ms;
    assert s_therm(1) = '1' report "warn should be set above the warn threshold"
      severity failure;
    expect_halt('0', "above warn but below halt");
    check_canary(true, "warned but not halted");

    ------------------------------------------------------- 4. die over-temp
    set_die(DIE_HALT_C + 3);
    wait for 1 ms;
    expect_halt('1', "the die is above the halt threshold");
    expect_cause(CAUSE_DIE_OVER, "the die is over temperature");
    expect_trip(CAUSE_DIE_OVER, 1, "a die over-temperature");
    assert unsigned(s_trip(9 downto 0)) >= to_unsigned(die_code(DIE_HALT_C), 10)
      report "the latched trip temperature is below the halt threshold"
      severity failure;
    check_canary(false, "halted on die over-temperature");

    ------------------------------------------------------------ 5. hysteresis
    -- Between the resume point and the halt point.  It must NOT resume.
    set_die(DIE_HALT_C - 5);       -- 85 C: below halt, above resume
    wait for 8 ms;
    expect_halt('1',
      "the die is between the resume point and the halt point -- HYSTERESIS");
    check_canary(false, "inside the hysteresis band");

    set_die(DIE_RESUME_C - 5);
    wait_release("the die fell below the resume point");
    check_canary(true, "resumed after cooling below the resume point");

    -------------------------------------------------------------- 6. stale die
    -- The VALUE stays perfectly cool.  Only the liveness strobe stops.  A guard
    -- that only compares values would sail straight through this.
    eoc_on <= false;
    wait for (STALE_MS + 3) * 1 ms;
    expect_halt('1', "the die liveness strobe stopped with a cool value");
    expect_cause(CAUSE_DIE_STALE, "the die sensor went stale");
    expect_trip(CAUSE_DIE_STALE, 2, "a stale die sensor");
    check_canary(false, "halted on a stale die sensor");
    assert s_therm(3) = '0' report "the die sensor should read invalid"
      severity failure;

    eoc_on <= true;
    wait_release("the die liveness strobe came back");

    -------------------------------------------------- 7. die stuck at zero
    -- The strobe keeps running, so the sensor looks alive; the value is 0,
    -- which by value alone means "very cold".  It must be treated as HOT.
    sysmon_temp <= (others => '0');
    wait for 3 ms;
    expect_halt('1', "the die sensor reads all-zeroes with a live strobe");
    expect_cause(CAUSE_DIE_STALE, "the die sensor reads implausibly");
    expect_trip(CAUSE_DIE_STALE, 3, "an implausible die reading");
    check_canary(false, "halted on a stuck-at-zero die sensor");

    -- and all-ones, the other end of the same failure
    sysmon_temp <= (others => '1');
    wait for 3 ms;
    expect_halt('1', "the die sensor reads all-ones");
    assert s_therm(3) = '0'
      report "an all-ones die reading must be invalid, not 228 C of real data"
      severity failure;

    set_die(30);
    wait_release("the die sensor came back with a plausible value");

    ------------------------------------------------------------ 8. HBM code
    set_hbm(HBM_HALT_C + 2);
    wait for 1 ms;
    expect_halt('1', "the HBM code is above its halt threshold");
    expect_cause(CAUSE_HBM_OVER, "the HBM is over temperature");
    expect_trip(CAUSE_HBM_OVER, 4, "an HBM over-temperature");
    assert to_integer(unsigned(s_trip(16 downto 10))) = HBM_HALT_C + 2
      report "the latched HBM trip code is wrong" severity failure;
    check_canary(false, "halted on the HBM code");

    set_hbm(HBM_RESUME_C - 5);
    wait_release("the HBM code fell below its resume point");

    ------------------------------------------------------------- 9. CATTRIP
    cattrip0 <= '1';
    wait for 1 ms;
    expect_halt('1', "stack 0 asserted CATTRIP");
    expect_cause(CAUSE_HBM_CAT, "CATTRIP");
    expect_trip(CAUSE_HBM_CAT, 5, "a CATTRIP");

    -- CATTRIP is the stack's own catastrophic signal.  It is sticky on purpose:
    -- the card must not quietly restart because the pin went away.
    cattrip0 <= '0';
    wait for 8 ms;
    expect_halt('1',
      "CATTRIP deasserted -- it is STICKY and must not self-clear");
    assert s_therm(28) = '1' report "the CATTRIP sticky should be set"
      severity failure;
    check_canary(false, "held by a sticky CATTRIP");

    ------------------------------------------- 10. a clear with the wrong key
    pk := unsigned(s_peak(9 downto 0));
    assert pk >= to_unsigned(die_code(DIE_HALT_C), 10)
      report "the peak-hold should have recorded the die over-temperature"
      severity failure;

    ctl_aux <= x"DEAD" & x"0003";      -- both clear bits, WRONG key
    wait for 1 ms;
    ctl_aux <= (others => '0');
    wait for 1 ms;
    expect_halt('1', "a clear with the wrong key must change nothing");
    expect_trip(CAUSE_HBM_CAT, 5, "a clear with the wrong key");
    assert unsigned(s_peak(9 downto 0)) = pk
      report "a clear with the wrong key moved the peak-hold" severity failure;

    ------------------------------ 11. a clear over the aux (JTAG) path, HOT
    -- Make the card genuinely hot first, then clear.  The latch must clear and
    -- the halt must NOT be released, because the halt is recomputed from the
    -- live sensors and the live sensors still say hot.
    set_die(DIE_HALT_C + 5);
    wait for 2 ms;
    ctl_aux <= KEY & x"0001";
    wait for 1 ms;
    ctl_aux <= (others => '0');
    wait for 1 ms;
    expect_halt('1', "a clear was issued while the card is still HOT");
    assert unsigned(s_peak(9 downto 0)) >= pk
      report "clearing the trip latch must NOT clear the peak-hold"
      severity failure;

    ------------------------------------------- 12. a clear that does release
    -- The cool reading has to have been ACCEPTED before the clear is issued.
    -- Without this wait the peak-hold is cleared and immediately re-acquires
    -- the still-hot live value, so the "peak survives a trip clear" assertion
    -- below passes whether or not the design actually preserves it.  Found by
    -- running that assertion against a deliberately broken copy and watching it
    -- NOT bite.
    set_die(30);
    wait for 2 ms;
    ctl_aux <= KEY & x"0001";
    wait for 1 ms;
    ctl_aux <= (others => '0');
    wait for 1 ms;
    assert s_therm(7) = '0' report "the trip latch did not clear" severity failure;
    assert to_integer(unsigned(s_therm(23 downto 16))) = 0
      report "the trip count did not clear" severity failure;
    assert s_therm(28) = '0' report "the CATTRIP sticky did not clear"
      severity failure;
    pk := unsigned(s_peak(9 downto 0));
    assert pk >= to_unsigned(die_code(DIE_HALT_C), 10)
      report "the peak-hold must survive a trip clear.  It read " &
             integer'image(to_integer(pk)) severity failure;
    wait_release("cleared and cool again");
    check_canary(true, "released after a clear");

    ------------------------------------ 13. the HOST clear path, own domain
    set_die(DIE_HALT_C + 5);
    wait for 2 ms;
    expect_halt('1', "hot again for the host clear test");
    expect_trip(CAUSE_DIE_OVER, 1, "the die went over temperature again");
    set_die(30);
    wait_release("cool again before the host clear");

    ctl_host <= x"BEEF" & x"0001";     -- wrong key first
    wait for 1 ms;
    ctl_host <= (others => '0');
    wait for 1 ms;
    assert s_therm(7) = '1'
      report "a host clear with the wrong key cleared the latch" severity failure;

    ctl_host <= KEY & x"0001";
    wait for 1 ms;
    ctl_host <= (others => '0');
    wait for 1 ms;
    assert s_therm(7) = '0'
      report "the host clear path did not clear the latch" severity failure;

    ------------------------------------------------- 14. clearing the peak
    assert unsigned(s_peak(9 downto 0)) > 0
      report "the peak-hold should still be set" severity failure;
    ctl_host <= KEY & x"0002";
    wait for 1 ms;
    ctl_host <= (others => '0');
    wait for 1 ms;
    -- The peak does NOT go to zero and must not be asserted to: the hold
    -- re-acquires the LIVE reading on the very next cycle, which is the
    -- correct behaviour and the only useful one.  What has to be true is that
    -- the old high-water mark is gone.
    assert unsigned(s_peak(9 downto 0)) < to_unsigned(die_code(DIE_HALT_C), 10)
      report "the explicit peak clear did not clear the peak-hold; it still "
           & "reads " & integer'image(to_integer(unsigned(s_peak(9 downto 0))))
      severity failure;
    assert abs(to_integer(unsigned(s_peak(9 downto 0)))
               - die_code(30)) <= 2
      report "after a peak clear the peak-hold should re-acquire the live "
           & "reading, but it reads " &
             integer'image(to_integer(unsigned(s_peak(9 downto 0))))
      severity failure;

    ------------------------------------------ 15. the SYSMON OT alarm path
    sysmon_ot <= '1';
    wait for 1 ms;
    expect_halt('1', "SYSMON asserted its armed OT alarm");
    expect_cause(CAUSE_DIE_OT, "the SYSMON OT alarm");
    sysmon_ot <= '0';
    wait_release("the OT alarm released");

    sysmon_alarm <= '1';
    wait for 1 ms;
    expect_halt('1', "SYSMON asserted its user temperature alarm");
    expect_cause(CAUSE_DIE_ALARM, "the SYSMON user temperature alarm");
    sysmon_alarm <= '0';
    wait_release("the user temperature alarm released");

    ------------------------------------------- 16. the HBM clock stopping
    -- The HBM temperature has no valid pin, so its liveness is the APB clock.
    -- Stopping it must halt, with a cool code still on the pins.
    pclk_on <= false;
    wait for (STALE_MS + 3) * 1 ms;
    expect_halt('1', "the HBM APB clock stopped with a cool code on the pins");
    expect_cause(CAUSE_HBM_STALE, "the HBM APB clock stopped");
    check_canary(false, "halted on a dead HBM APB clock");

    ---------------------------------------- 17. back to a known two-stack state
    -- Section 16 left the HBM APB clock stopped.  Restart it, put BOTH stacks
    -- on the same benign code, clear the record, and release.  Everything from
    -- here counts trips from zero.
    pclk_on <= true;
    set_hbm(30);
    wait for 2 ms;
    ctl_aux <= KEY & x"0001";
    wait for 1 ms;
    ctl_aux <= (others => '0');
    wait for 1 ms;
    wait_release("both stacks back on a benign code");
    assert to_integer(unsigned(s_therm(23 downto 16))) = 0
      report "the trip count did not clear before the two-stack rows"
      severity failure;
    assert s_therm(30) = '0'
      report "the divergence sticky did not clear before the two-stack rows"
      severity failure;

    -------------------------------- 18. THE TWO STACKS ARE NOT ONE READING
    -- hbm_temp0 and hbm_temp1 are wired to hbm/DRAM_0_STAT_TEMP and
    -- hbm/DRAM_1_STAT_TEMP -- two physically separate dies at two board
    -- positions.  One code apart at 30/31 is the NORMAL condition for them, and
    -- it is guaranteed transiently at every code crossing because the two
    -- debounce counters in the DUT are independent.
    --
    -- Until 2026-08-30 hbm_valid required h0_acc = h1_acc, so this halted the
    -- compute domain and counted a thermal trip.  On the card that reached the
    -- 8-bit saturating maximum of 255 trips on an IDLE board at code 38,
    -- against an HBM halt threshold of 85.
    set_hbm2(30, 31);
    wait for 3 ms;
    expect_halt('0',
      "the two HBM STACKS read one code apart at a benign temperature.  They "
    & "are separate dies; disagreement is not a fault");
    assert s_therm(4) = '1'
      report "the HBM sensor must stay VALID when the two stacks are one code "
           & "apart.  They are two separate dies, not two copies of one word"
      severity failure;
    assert to_integer(unsigned(s_therm(23 downto 16))) = 0
      report "a one-code difference between the two HBM stacks counted a "
           & "thermal trip.  This is THERM-255: it saturated the counter at "
           & "255 on an idle card at 38 C"
      severity failure;
    assert s_therm(30) = '0'
      report "a one-code difference set the divergence sticky.  That sticky "
           & "must mean a stuck or torn sensor, not two dies at two "
           & "temperatures, or it is set on every card within seconds"
      severity failure;
    check_canary(true, "the two stacks read one code apart");

    -- and the other way round, because a fix that special-cases stack 0 would
    -- pass the line above and fail this one.
    set_hbm2(31, 30);
    wait for 3 ms;
    expect_halt('0', "the two HBM stacks read one code apart, stack 0 higher");
    assert to_integer(unsigned(s_therm(23 downto 16))) = 0
      report "a one-code difference counted a trip with stack 0 the higher one"
      severity failure;
    assert s_therm(30) = '0'
      report "the disagreement sticky fired on a difference that has lasted "
           & "less than the dwell.  On the card the real transient is ONE aux "
           & "clock, 5 ns; a sticky that fires inside the dwell is the old "
           & "one, which was set on every idle card and told nobody anything"
      severity failure;

    ------------------- 18b. A SUSTAINED DISAGREEMENT IS REPORTED, NOT HALTED
    -- The two tiers, and the reason this design is not simply "drop the
    -- equality term".  A one-code difference that PERSISTS is not normal --
    -- MEASURED on the card 2026-08-30, 123 million samples of THERM_TEMPS at
    -- 3.89 us across idle and a 320-job load, ZERO with h0 /= h1 -- so it is
    -- worth telling the host about.  It is NOT worth halting on: a halt has no
    -- operator in the loop and fk33_run_job.py refuses to start any job while
    -- compute_halt is asserted, so a wrong halt does not cost throughput, it
    -- stops the card.
    --
    -- So the sticky must SET and the datapath must KEEP RUNNING.  A design
    -- that halts here is candidate (c) applied to bare inequality; a design
    -- whose sticky stays clear has given up the only sensitive detector of a
    -- stuck stack sensor there is.
    set_hbm2(30, 31);
    wait for (HBM_DIV_MS + 4) * 1 ms;
    assert s_therm(30) = '1'
      report "a one-code difference sustained past the dwell did NOT set the "
           & "disagreement sticky.  That sticky is the only sensitive detector "
           & "of a stuck stack sensor in the design, and the only instrument "
           & "that can answer whether the two stacks ever separate under load"
      severity failure;
    expect_halt('0',
      "the two stacks have disagreed by one code for longer than the dwell.  "
    & "That is REPORTED, not halted -- a halt here stops the card outright");
    assert to_integer(unsigned(s_therm(23 downto 16))) = 0
      report "a sustained one-code disagreement counted a thermal trip"
      severity failure;
    assert s_therm(4) = '1'
      report "a sustained one-code disagreement must NOT invalidate the HBM "
           & "sensor.  Invalid means hot, and hot means halted" severity failure;
    check_canary(true, "the disagreement sticky is set");

    set_hbm(30);
    wait for 2 ms;
    assert s_therm(30) = '1'
      report "the disagreement sticky must survive the stacks converging"
      severity failure;
    ctl_aux <= KEY & x"0001";
    wait for 1 ms;
    ctl_aux <= (others => '0');
    wait for 1 ms;
    assert s_therm(30) = '0'
      report "an explicit trip clear must clear the disagreement sticky"
      severity failure;

    ------------------------- 19. OVER-TEMPERATURE ON EITHER STACK ALONE
    -- The row that catches a fix which trades a false halt for a MISSED one.
    -- Before 2026-08-30 the halt, resume and warn comparisons all read h0_acc
    -- and nothing else, so stack 1's temperature reached no threshold in the
    -- design; the equality term was the only thing that made it matter at all.
    -- Removing that term without also comparing both stacks would leave stack 1
    -- entirely unguarded, which is far worse than the defect being fixed.
    --
    -- The codes are HBM_MAX_DELTA apart and no further, so this row tests the
    -- THRESHOLD and not the divergence detector.
    set_hbm2(HBM_HALT_C + 2 - HBM_MAX_DELTA, HBM_HALT_C + 2);
    wait for 3 ms;
    expect_halt('1', "HBM STACK 1 ALONE is above the halt threshold");
    expect_cause(CAUSE_HBM_OVER,
      "stack 1 is over temperature and stack 0 is cool");
    expect_trip(CAUSE_HBM_OVER, 1, "an over-temperature on stack 1 alone");
    assert to_integer(unsigned(s_trip(23 downto 17))) = HBM_HALT_C + 2
      report "the latched stack 1 code is " &
             integer'image(to_integer(unsigned(s_trip(23 downto 17)))) &
             ", expected " & integer'image(HBM_HALT_C + 2) severity failure;
    assert to_integer(unsigned(s_trip(16 downto 10)))
             = HBM_HALT_C + 2 - HBM_MAX_DELTA
      report "the latched stack 0 code is wrong for a stack 1 over-temperature"
      severity failure;
    check_canary(false, "halted on stack 1 alone");

    set_hbm(HBM_RESUME_C - 5);
    wait_release("both stacks fell below the resume point");

    -- the mirror image
    set_hbm2(HBM_HALT_C + 2, HBM_HALT_C + 2 - HBM_MAX_DELTA);
    wait for 3 ms;
    expect_halt('1', "HBM STACK 0 ALONE is above the halt threshold");
    expect_cause(CAUSE_HBM_OVER,
      "stack 0 is over temperature and stack 1 is cool");
    expect_trip(CAUSE_HBM_OVER, 2, "an over-temperature on stack 0 alone");
    check_canary(false, "halted on stack 0 alone");

    -- RESUME needs BOTH stacks cool, not just the one that went over.  Stack 0
    -- is dropped below the resume point while stack 1 is left INSIDE the
    -- hysteresis band, between the resume point and the halt point.  A guard
    -- that resumes on min(), or on stack 0 alone, releases the datapath here.
    set_hbm2(HBM_RESUME_C - 5, HBM_RESUME_C + 2);
    wait for 8 ms;
    expect_halt('1',
      "stack 0 is below the resume point but stack 1 is still inside the "
    & "hysteresis band -- RESUME REQUIRES BOTH");

    set_hbm(HBM_RESUME_C - 5);
    wait_release("both stacks below the resume point");

    -- WARN is a threshold too, and it was compared against stack 0 alone with
    -- everything else.  Found by mutation: reverting `warn` to h0_acc survived
    -- the whole bench, new rows included, until this row was added.  It is the
    -- host's only advance notice, so a warn that cannot see stack 1 is a card
    -- that goes from quiet to halted with nothing in between.
    set_hbm2(HBM_WARN_C + 2 - HBM_MAX_DELTA, HBM_WARN_C + 2);
    wait for 3 ms;
    assert s_therm(1) = '1'
      report "WARN is not set with HBM STACK 1 ALONE above the warn threshold"
      severity failure;
    expect_halt('0', "stack 1 is above warn but below halt");

    set_hbm(HBM_RESUME_C - 5);
    wait for 3 ms;
    assert s_therm(1) = '0'
      report "WARN did not clear once both stacks fell back" severity failure;

    ------------------ 20a. STACK 1 IS PLAUSIBILITY-CHECKED IN ITS OWN RIGHT
    -- The plausibility band used to be applied to h0_acc alone.  That was safe
    -- only while the equality term forced the two stacks to be equal; with that
    -- term gone, a stack 1 reading of 0 -- what an HBM that has not produced a
    -- reading gives, and what a dead sensor gives -- would be accepted as a
    -- very cold stack, which is the stuck-at-zero failure this whole module
    -- exists to avoid.
    --
    -- It must halt WELL INSIDE the divergence dwell, or the row is passing on
    -- the divergence detector rather than on the range check it is aimed at.
    set_hbm2(30, 0);
    wait for 2 ms;
    expect_halt('1', "HBM STACK 1 reads all-zeroes with stack 0 perfectly cool");
    expect_cause(CAUSE_HBM_STALE, "stack 1 reads implausibly low");
    expect_trip(CAUSE_HBM_STALE, 3, "an implausible stack 1 reading");
    assert s_therm(4) = '0'
      report "the HBM sensor must be INVALID when stack 1 reads 0, whatever "
           & "stack 0 says" severity failure;

    set_hbm(30);
    wait_release("stack 1 came back with a plausible value");

    -- and all-ones, the other end of the same failure
    set_hbm2(30, 127);
    wait for 2 ms;
    expect_halt('1', "HBM STACK 1 reads all-ones with stack 0 perfectly cool");
    expect_trip(CAUSE_HBM_STALE, 4, "an all-ones stack 1 reading");
    assert s_therm(4) = '0'
      report "an all-ones stack 1 reading must be invalid, not 127 codes of "
           & "real data" severity failure;

    set_hbm(30);
    wait_release("stack 1 came back from all-ones");
    assert s_therm(30) = '0'
      report "the disagreement sticky fired during the range-check rows.  "
           & "Those rows are meant to complete well inside the dwell; if it "
           & "fired, they are passing on the disagreement detector rather "
           & "than on the per-stack range check they are aimed at"
      severity failure;

    ----------------------------- 20b. A LARGE, SUSTAINED DIVERGENCE IS A FAULT
    -- This is the hole that removing the equality test would otherwise open,
    -- and it is closed here rather than left for later.  A stack sensor stuck
    -- at a plausible value while its stack really heats is invisible to
    -- max(stack0, stack1) -- max reads the GOOD stack and stays cool -- and it
    -- is invisible to the staleness watchdog, which watches the APB clock and
    -- not the value.  What it is not invisible to is the two stacks drifting
    -- further apart than any real gradient on one interposer.
    --
    -- It must NOT fire immediately: a bound that acts on the first sample is a
    -- slower version of the equality test.  It must fire once sustained.
    set_hbm2(30, 30 + HBM_MAX_DELTA + 5);
    wait for 2 ms;
    expect_halt('0',
      "a large divergence has only just appeared -- it must persist before it "
    & "counts, so that nothing transient can halt the datapath");
    assert to_integer(unsigned(s_therm(23 downto 16))) = 4
      report "a divergence counted a trip before its dwell had elapsed"
      severity failure;

    wait for (HBM_DIV_MS + 4) * 1 ms;
    expect_halt('1',
      "the two stacks have been " & integer'image(HBM_MAX_DELTA + 5) &
      " codes apart for longer than the divergence dwell -- a stuck sensor");
    expect_cause(CAUSE_HBM_STALE, "a sustained two-stack divergence");
    expect_trip(CAUSE_HBM_STALE, 5, "a sustained two-stack divergence");
    assert s_therm(4) = '0'
      report "a sustained divergence must make the HBM sensor INVALID"
      severity failure;
    assert s_therm(30) = '1'
      report "the disagreement sticky must also be set by a sustained WIDE "
           & "divergence -- the wide tier is a subset of the any-difference "
           & "tier, so a sticky that is clear here means the tiers have been "
           & "wired the wrong way round" severity failure;
    check_canary(false, "halted on a sustained two-stack divergence");

    set_hbm(30);
    wait_release("the two stacks converged again");
    assert s_therm(30) = '1'
      report "the disagreement sticky must SURVIVE the stacks converging.  It "
           & "records that something happened" severity failure;

    ------------------------- 21. A ONE-CYCLE HALT CAUSE MUST RECORD ITSELF
    -- The trip record used to be captured on the rising edge of `halted`, which
    -- is a REGISTER, so the cause and both temperatures were sampled one clock
    -- after the combinational term that caused the halt.  Any cause shorter
    -- than two cycles therefore recorded CAUSE_NONE and the benign aftermath.
    -- That is exactly what the card produced on 2026-08-30: trips=1, cause
    -- `none`, HBM codes 38 / 38 recorded for a trip an INEQUALITY caused.
    --
    -- SYSMON's OT alarm is pulsed for exactly ONE aux clock.  It reaches the
    -- decision logic through syn_ot, so die_hot and `cause` are high for one
    -- cycle and nothing else in the design is hot at all.
    wait until rising_edge(aux_clk);
    sysmon_ot <= '1';
    wait until rising_edge(aux_clk);
    sysmon_ot <= '0';
    wait for 1 ms;

    expect_trip(CAUSE_DIE_OT, 6,
      "a SYSMON OT alarm exactly one aux clock long");
    assert to_integer(unsigned(s_therm(15 downto 12))) /= 0
      report "the latched cause is CAUSE_NONE.  Every term of die_hot and "
           & "hbm_hot has a matching arm in `cause`, so a latched CAUSE_NONE "
           & "means the record was captured a cycle after the condition that "
           & "caused it and is describing the aftermath, not the cause"
      severity failure;
    assert to_integer(unsigned(s_trip(27 downto 24))) = CAUSE_DIE_OT
      report "THERM_TRIP's own cause field disagrees with THERM_STATUS's"
      severity failure;
    -- The recorded temperatures must be the ones that were live at the halt,
    -- not zero and not something the sensors never read.
    assert unsigned(s_trip(16 downto 10)) = 30
       and unsigned(s_trip(23 downto 17)) = 30
      report "the latched HBM codes are " &
             integer'image(to_integer(unsigned(s_trip(16 downto 10)))) & " / " &
             integer'image(to_integer(unsigned(s_trip(23 downto 17)))) &
             ", expected 30 / 30 -- the codes live at the instant of the halt"
      severity failure;

    wait_release("the one-cycle OT alarm went away");
    check_canary(true, "released after a one-cycle OT alarm");

    ------------------------------- 21b. settle the design before comparing
    -- The comparison below needs the whole design STILL.  The canary counts
    -- every compute cycle the guard has released, so while it is running the
    -- publication filter can never accept a word that still matches the live
    -- aux one and the comparison fails on a moving target rather than on a
    -- broken crossing.  Section 16 used to leave the guard halted and section
    -- 22 inherited that by accident; the two-stack rows leave it running, so
    -- halt it explicitly here rather than depending on the row above.
    pclk_on <= false;
    wait for (STALE_MS + 3) * 1 ms;
    expect_halt('1', "the HBM APB clock was stopped again to settle the design");
    expect_cause(CAUSE_HBM_STALE, "the HBM APB clock stopped");

    ------------------------------- 22. the host-domain view agrees
    -- The five words the host reads over the PCIe BAR are resynchronised
    -- copies.  With everything settled they must equal the aux-domain
    -- originals; if they do not, the publication filter is broken and the host
    -- has been reading torn or stale data all along.
    wait for 2 ms;
    assert h_therm = s_therm and h_temps = s_temps and h_peak = s_peak
       and h_trip = s_trip and h_canary = s_canary
      report "tb_fk33_thermal: the host-domain status view does not match the "
           & "aux-domain original once settled.  host_therm=0x"
           & to_hstring(h_therm) & " stat_therm=0x" & to_hstring(s_therm)
      severity failure;

    report "THERM_STATUS = 0x" & to_hstring(s_therm);
    report "THERM_TEMPS  = 0x" & to_hstring(s_temps);
    report "THERM_PEAK   = 0x" & to_hstring(s_peak);
    report "THERM_TRIP   = 0x" & to_hstring(s_trip);
    report "THERM_CANARY = " & integer'image(to_integer(unsigned(s_canary)));
    report "die halt code = " & integer'image(die_code(DIE_HALT_C)) &
           "  resume code = " & integer'image(die_code(DIE_RESUME_C));
    report "TB_FK33_THERMAL PASS";
    std.env.finish;
  end process;

end architecture;
