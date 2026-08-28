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

    ------------------------------- 17. the host-domain view agrees
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
