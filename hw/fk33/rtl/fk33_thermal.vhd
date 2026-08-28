--------------------------------------------------------------------------------
-- fk33_thermal -- thermal protection for the FK33, on the free-running aux clock
--------------------------------------------------------------------------------
-- WHY THIS EXISTS
-- ---------------
-- Before this module the fk33_pcieep bitstream did NOTHING about temperature.
-- SYSMON existed only as a register the host could read at AXI-Lite 0x3400, the
-- HBM stacks' own temperature and catastrophic-trip outputs were left dangling,
-- and nothing in the fabric ever compared a number against a limit.  The card
-- has an EXTERNAL fan whose airflow is uncharacterised and no fan pin the FPGA
-- drives, so there is no closed loop of any kind.
--
-- WHAT THE SILICON ALREADY DOES, AND WHY IT IS NOT ENOUGH
-- -------------------------------------------------------
-- UltraScale+ SYSMON has an over-temperature (OT) alarm with an automatic
-- shutdown, and it IS armed in this design.  Arming is not optional: the
-- SYSMONE4 primitive accepts a write to the OT upper-limit register 53h only
-- when the low nibble is 0011, which is the automatic-shutdown enable, and the
-- system_management_wiz generator forces that nibble unconditionally
--   (xgui/system_management_wiz_v1_3.tcl, update_MODELPARAM_VALUE.C_ALARM_LIMIT_R3:
--    set r3_final_val [expr {(int($r3_val/16)*16)+3}])
-- so any bitstream that sets an OT trip point has also armed the shutdown.
-- SQRL's block design sets
--   CONFIG.TEMPERATURE_ALARM_OT_TRIGGER {101}  CONFIG.TEMPERATURE_ALARM_OT_RESET {99}
-- so on this card OT trips at about 101 C with a 99 C release.
--
-- That is a die-destruction backstop, not thermal management, for three
-- reasons and all three matter here:
--
--   1. It is ABOVE the operating limit.  DS890 Table 33 puts -2LE at 0..110 C
--      Tj, and note 3 limits 110 C to 1% of device lifetime; the sustained
--      column is 100 C.  A trip at 101 C fires after the part is already out of
--      its sustained rating.
--   2. It says nothing about HBM.  DS890 note 1 recommends a maximum of 95 C
--      for the high-bandwidth memory, and note 4 limits 95..105 C to 4.1% of
--      lifetime and no more than 96 hours at a time, with at least 4x refresh
--      above 95 C -- which this HBM IP is not configured to do.  The stacks sit
--      on the same interposer as the fabric that will saturate them, and the
--      die sensor is not the stack sensor.
--   3. Its consequence is a shutdown.  A card that shuts down drops off the
--      PCIe bus, and a card that is off the bus cannot be asked what happened.
--
-- So the guard below fires FIRST, at a temperature that is inside the
-- datasheet, and it halts arithmetic while deliberately leaving the PCIe link,
-- the AXI fabric, the aux domain and every status register alive and readable.
--
-- WHY THIS MODULE IS ON THE AUX CLOCK
-- -----------------------------------
-- Both sensors live in PCIe-derived clock domains: SYSMON's temperature bus is
-- registered in the system_management_wiz AXI/DRP domain (s_axi_aclk =
-- xdma/axi_aclk), and the HBM temperature is refreshed by logic inside the HBM
-- IP clocked by APB_0_PCLK, which is clk_wiz_0/clk_out1, whose reference is
-- also xdma/axi_aclk.  Putting the latch and the timers on either of those
-- would lose the thermal record exactly when it is most wanted -- after an OT
-- shutdown, after a host reset, after a link drop.  The aux domain
-- (rtl/fk33_aux.vhd, the 200 MHz board oscillator on BC26/BC27 through a plain
-- BUFG) keeps running through all of those, so:
--
--   * the staleness watchdogs cannot themselves go stale;
--   * the trip latch, the cause, the trip temperatures and the peak-hold
--     survive the link going down and stay readable over jtag_aux;
--   * the halt asserts and STAYS asserted whatever the PCIe domain does.
--
-- THE FAIL-SAFE RULE, AND WHY IT IS NOT ONLY A VALUE COMPARISON
-- -------------------------------------------------------------
-- A sensor that returns garbage, never updates, or reads implausibly is
-- treated as HOT.  A stuck-at-zero sensor is indistinguishable from a very cold
-- card BY VALUE ALONE -- both read 0 and both look safe -- so a value
-- comparison on its own is not a thermal guard, it is a thermal guard that
-- fails open.  Every sensor here therefore carries THREE independent tests and
-- must pass all of them:
--
--   1. a LIVENESS watchdog, driven by a signal that is independent of the
--      value.  The die uses SYSMON's own eoc_out (end of conversion), divided
--      and toggled in the SYSMON clock domain, so a frozen ADC with a running
--      DCLK still fails.  HBM has no valid/strobe pin on the IP -- the internal
--      temp_valid_r is not brought out -- so it uses the APB PCLK, divided and
--      toggled, which detects the clock stopping but NOT the reader wedging.
--      That is weaker and is called out here rather than glossed over.
--   2. a PLAUSIBILITY band.  All-zeroes and all-ones both fall outside it.
--   3. for HBM, an AGREEMENT test between two independently synchronised
--      copies of the same source word (see the CDC note below).
--
-- Failing any of them marks the sensor invalid, and an invalid sensor is hot.
-- At reset every sensor is invalid, so the guard comes up HALTED and only
-- releases the datapath once it has actually seen a temperature.
--
-- CLOCK DOMAIN CROSSINGS
-- ----------------------
-- Single-bit crossings (cattrip, ot, the alarm, the liveness toggles, the halt
-- going out to the compute domain, the clear requests coming in) are two-stage
-- ASYNC_REG synchronisers, the same rule rtl/fk33_aux.vhd follows.
--
-- The temperature WORDS are multi-bit and cannot use that rule alone: two flops
-- per bit make each bit stable but not the word coherent, so a code stepping
-- 31 -> 32 can be sampled as 63 for one cycle.  rtl/hbm_tg.vhd already recorded
-- this failure and its cost.  The fix here is an AGREEMENT FILTER: a candidate
-- word is accepted only after G_STABLE+1 consecutive identical aux samples.
-- The sources change at ~1 kHz (HBM: TEMP_WAIT_PERIOD_0 = 100000 APB cycles at
-- 100 MHz) against a 200 MHz sampler, so a real value is stable for ~200,000
-- samples and a torn one for at most one.  THAT is why no set_bus_skew
-- constraint is required and why the asynchronous clock group in
-- fk33_pcieep.xdc is a complete constraint: arbitrary skew between the bits
-- only ever produces a candidate that the filter rejects.
--
-- WHAT THE HALT DOES AND DOES NOT STOP
-- ------------------------------------
-- compute_halt is a single bit, synchronous to compute_clk, whose RESET VALUE
-- IS '1' (halted).  It is a request to STOP ISSUING new work.  It is NOT a
-- clock gate and it must not be used as one:
--
--   * it does not stop compute_clk, xdma/axi_aclk, the PCIe link, the AXI
--     fabric, the HBM controller or the aux domain;
--   * a datapath consuming it MUST still complete AXI bursts it has already
--     issued.  Abandoning an accepted burst hangs the channel permanently,
--     which is worse than the thermal event -- rtl/hbm_tg.vhd:727 records the
--     same rule for the same reason.
--
-- The reset value being '1' is deliberate and is the fourth fail-safe: a
-- datapath whose clock is dead, or which is sampled before the synchroniser has
-- propagated, sees HALTED.  Nothing can accidentally start.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fk33_thermal is
  generic (
    -- Free-running aux clock, in Hz.  Every time base below derives from it.
    G_CLK_HZ       : natural := 200000000;

    ------------------------------------------------------------------------
    -- DIE thresholds, in degrees C.  Justification, against DS890 Table 33
    -- for xcvu33p-fsvh2104-2L-e (the -2LE row):
    --   sustained operating Tj  100 C   ("0 C to +100 C" column)
    --   absolute Tj             110 C   (note 3: 1% of device lifetime only)
    --   SYSMON OT trip          101 C   (as this design programs it)
    --   HBM recommended max      95 C   (note 1)
    -- 90 C halt sits 10 C under the sustained limit, 20 C under the absolute
    -- one, 11 C under the OT backstop so this guard always fires first, and 5 C
    -- under the HBM recommendation -- which matters because the stacks share
    -- the interposer with the fabric.  80 C warn gives a host 10 C of notice.
    -- 75 C resume is a 15 C hysteresis band, far wider than the ~0.5 C ADC LSB
    -- and wider than any plausible sensor noise, so it cannot chatter.
    ------------------------------------------------------------------------
    G_DIE_WARN_C   : natural := 80;
    G_DIE_HALT_C   : natural := 90;
    G_DIE_RESUME_C : natural := 75;

    ------------------------------------------------------------------------
    -- HBM thresholds, in RAW 7-bit stack code units.
    --
    -- CALIBRATION CAVEAT, stated because it changes how these should be read.
    -- The HBM IP presents DRAM_x_STAT_TEMP[6:0] as the raw IEEE1500 TEMP_DATA
    -- field (hdl/hbm_v1_0_vl_rfs.sv, hbm_temp_rd: temp_value_r <= prdata[30:24])
    -- and NOTHING in the IP, in Vivado, or in any document on this workstation
    -- converts it to Celsius; PG276 is not bundled.  The only local evidence is
    -- measured: docs/debugging/2026-08-25_voltage-derate-on-hardware.md records
    -- codes 28-29 at a die temperature of 27.7-28.2 C at idle, and 32 under
    -- load.  That is consistent with the code BEING degrees C and with nothing
    -- else that has been proposed.  These thresholds are therefore set on the
    -- assumption code == degrees C, with extra margin BECAUSE the assumption is
    -- not proven: 85 is 10 C below the 95 C DS890 recommendation.  If the scale
    -- ever turns out to be different the effect is a guard that trips early,
    -- which is recoverable and loudly visible, not one that trips late.
    ------------------------------------------------------------------------
    G_HBM_WARN_C   : natural := 75;
    G_HBM_HALT_C   : natural := 85;
    G_HBM_RESUME_C : natural := 70;

    -- Plausibility bands.  Outside them a sensor is INVALID, hence hot.
    --
    -- The HBM floor is not arbitrary: on a two-stack part the IP merges the two
    -- stacks into one word with
    --   TEMP_STATUS = (t0 > 7'h05 && t1 > 7'h05) ? max(t0,t1) : min(t0,t1)
    -- (hdl/hbm_v1_0_vl_rfs.sv:3744), so any code <= 5 means at least one stack
    -- has not produced a reading yet and the output is the useless one.
    G_HBM_MIN_CODE : natural := 6;
    G_HBM_MAX_CODE : natural := 110;
    -- Die band in degrees C.  Code 0x000 maps to -279 C and 0x3FF to +228 C, so
    -- all-zeroes and all-ones are both outside this and are both caught.
    G_DIE_MIN_C    : integer := -40;
    G_DIE_MAX_C    : integer := 150;

    -- Liveness watchdogs, in milliseconds.  The die's eoc_out toggles at
    -- hundreds of kHz and the HBM APB clock divider at ~200 kHz, so anything
    -- above a few ms is generous; 250 ms is chosen to be far longer than any
    -- legitimate gap and far shorter than a thermal time constant.
    G_STALE_MS     : natural := 250;
    -- Minimum time halted, so the guard cannot chatter even if a threshold is
    -- crossed rapidly.  100 ms against a thermal time constant of seconds.
    G_MIN_HALT_MS  : natural := 100;
    -- Consecutive identical aux samples required before a multi-bit sensor word
    -- is accepted.  See the CDC note in the header.
    G_STABLE       : natural := 3;
    -- Write key for THERM_CTL[31:16].  A clear must be deliberate.
    G_CTL_KEY      : natural := 16#C1EA#;
    -- Which canary bit is toggled across into the aux domain.  19 gives one
    -- toggle every 524,288 compute cycles, i.e. about 2.1 ms at 250 MHz, so a
    -- JTAG reader sees the count move between any two reads a few tens of
    -- milliseconds apart.  Lowered in simulation so the canary is observable in
    -- a few microseconds of simulated time.
    G_CANARY_BIT   : natural := 19
  );
  port (
    ----------------------------------------------------------------------------
    -- The free-running aux domain (rtl/fk33_aux.vhd aux_clk / aux_aresetn)
    ----------------------------------------------------------------------------
    aux_clk       : in  std_logic;
    aux_aresetn   : in  std_logic;

    ----------------------------------------------------------------------------
    -- DIE.  system_management_wiz_0, in its AXI/DRP clock domain.
    --   sysmon_temp is temp_out[9:0], which the IP drives from do_i(15 downto 6)
    --   -- the TOP TEN BITS of the 16-bit DRP temperature word, left justified.
    --   Requires CONFIG.ENABLE_TEMP_BUS true.
    --   sysmon_ot is ot_out, the armed over-temperature alarm (trip 101 C here).
    --   sysmon_alarm is user_temp_alarm_out, the freely programmable user
    --   temperature alarm; requires CONFIG.USER_TEMP_ALARM true.  It is an
    --   INDEPENDENT hardware comparator inside SYSMON set to the same halt and
    --   resume points as G_DIE_HALT_C / G_DIE_RESUME_C, so the die is guarded
    --   twice by two mechanisms that share no logic.
    --   sysmon_eoc is eoc_out, the liveness source.
    ----------------------------------------------------------------------------
    sysmon_clk    : in  std_logic;
    sysmon_temp   : in  std_logic_vector(9 downto 0);
    sysmon_ot     : in  std_logic;
    sysmon_alarm  : in  std_logic;
    sysmon_eoc    : in  std_logic;

    ----------------------------------------------------------------------------
    -- HBM.  hbm/DRAM_x_STAT_TEMP and hbm/DRAM_x_STAT_CATTRIP, refreshed by
    -- logic inside the IP clocked by hbm/APB_0_PCLK.
    --
    -- TRAP, and it is the IP's, not ours: on a TWO-STACK part DRAM_0_STAT_TEMP
    -- and DRAM_1_STAT_TEMP are driven from the SAME merged expression
    -- (hdl/hbm_v1_0_vl_rfs.sv:3744-3745), so they are one signal and there is
    -- no per-stack temperature at these pins.  Per-stack separation would need
    -- CONFIG.USER_APB_EN true and our own APB reads of 0x24000C on each of
    -- APB_0 and APB_1.  Both are still taken, through SEPARATE synchroniser
    -- chains, and required to AGREE: identical sources resolving differently is
    -- a metastability or tearing fault, and that is worth catching.  CATTRIP is
    -- genuinely per stack.
    ----------------------------------------------------------------------------
    hbm_pclk      : in  std_logic;
    hbm_temp0     : in  std_logic_vector(6 downto 0);
    hbm_temp1     : in  std_logic_vector(6 downto 0);
    hbm_cattrip0  : in  std_logic;
    hbm_cattrip1  : in  std_logic;

    ----------------------------------------------------------------------------
    -- Control.  Two independent write paths, so the latch can be cleared over
    -- JTAG with the PCIe link down AND by the host over the AXI-Lite BAR.
    -- Both require the key in bits [31:16]; both are edge triggered.
    ----------------------------------------------------------------------------
    ctl_aux       : in  std_logic_vector(31 downto 0);
    ctl_host_clk  : in  std_logic;
    ctl_host      : in  std_logic_vector(31 downto 0);

    ----------------------------------------------------------------------------
    -- THE COMPUTE DATAPATH INTERFACE.  See the header for the contract.
    --
    --   compute_clk  the datapath's own clock.
    --   compute_halt synchronous to compute_clk, active high, RESET VALUE '1'.
    --                Use it as `if compute_halt = '0' then <issue work> end if`
    --                or as a clock enable via `ce <= not compute_halt`.  Do NOT
    --                gate a clock with it and do NOT abandon an AXI burst that
    --                has already been accepted.
    ----------------------------------------------------------------------------
    compute_clk   : in  std_logic;
    compute_halt  : out std_logic;

    ----------------------------------------------------------------------------
    -- Status, all in the aux domain.  Bit maps are in the register comment at
    -- the bottom of this file and in gen_pcieep.py.
    ----------------------------------------------------------------------------
    stat_therm    : out std_logic_vector(31 downto 0);
    stat_temps    : out std_logic_vector(31 downto 0);
    stat_peak     : out std_logic_vector(31 downto 0);
    stat_trip     : out std_logic_vector(31 downto 0);
    stat_canary   : out std_logic_vector(31 downto 0);

    ----------------------------------------------------------------------------
    -- The SAME five words, resynchronised into the ctl_host_clk domain for the
    -- PCIe AXI-Lite BAR.
    --
    -- These exist because handing an aux-domain word straight to an axi_gpio
    -- clocked by xdma/axi_aclk is a 32-bit unsynchronised crossing: the host
    -- would read a TORN word whenever a field changed during its sample, and a
    -- torn trip count or a torn temperature is worse than no reading because it
    -- looks like data.  They go through the same agreement filter the sensor
    -- inputs use, which tolerates arbitrary bit skew by construction, so no
    -- set_bus_skew constraint is owed on this crossing either.
    ----------------------------------------------------------------------------
    host_therm    : out std_logic_vector(31 downto 0);
    host_temps    : out std_logic_vector(31 downto 0);
    host_peak     : out std_logic_vector(31 downto 0);
    host_trip     : out std_logic_vector(31 downto 0);
    host_canary   : out std_logic_vector(31 downto 0)
  );
end entity fk33_thermal;

architecture rtl of fk33_thermal is

  ------------------------------------------------------------------------------
  -- SYSMON temperature transfer function, EXTERNAL reference
  ------------------------------------------------------------------------------
  -- The design sets CONFIG.REFERENCE {External}, and the wizard's own inverse
  -- for UltraScale+ with an external reference is
  --     code16 = (T + 279.42657680) / 507.5921310 * 2^16
  -- (xgui/system_management_wiz_v1_3.tcl, update_MODELPARAM_VALUE.C_ALARM_LIMIT_R0).
  -- host/fk33ctl.py uses the same constants in the forward direction.  temp_out
  -- is the top TEN bits, so
  --     code10 = (T + 279.42657680) * 1024 / 507.5921310
  --            = (T*10000 + 2794266) / 4956.954
  --
  -- 4957 is used instead of 4956.954 to keep this integer-only: VHDL integers
  -- are 32-bit and the exact form (T*10000 + 2794266) * 1024 overflows at
  -- 3.8e9.  The error is 9e-6 relative, under 0.01 of one code, i.e. under
  -- 0.005 C.  The assertions below check the results anyway rather than
  -- trusting the arithmetic.
  ------------------------------------------------------------------------------
  constant C_TDEN : natural := 4957;

  ------------------------------------------------------------------------------
  -- SYNTHESIS-TIME ceilings on the thresholds
  ------------------------------------------------------------------------------
  -- MEASURED 2026-08-28, and it changes what the assertions below are worth:
  -- **Vivado synthesis IGNORES `assert ... severity failure` entirely.**  An
  -- out-of-context synth of this module with G_DIE_HALT_C = 98 completed with no
  -- error, no critical warning and no message of any kind about the assertion.
  -- So every `assert` in this file is a SIMULATION guard, and simulation is not
  -- in the path of a build.
  --
  -- A `natural` constant that would have to be negative IS a static range
  -- violation, and synthesis has to reject it:
  --     ERROR: [Synth 8-11323] assigned value '-8' out of range
  -- The four constants below are therefore the only thing inside the RTL that
  -- can stop an out-of-spec threshold reaching a bitstream through Vivado alone.
  -- They are unused by design; they exist to fail elaboration.
  --
  -- gen_pcieep.py refuses to emit a build without them, because they are easy to
  -- delete while "tidying up unused constants".
  constant C_DIE_HALT_CEILING : natural := 90 - G_DIE_HALT_C;
  constant C_HBM_HALT_CEILING : natural := 85 - G_HBM_HALT_C;
  constant C_DIE_HYST_FLOOR   : natural := G_DIE_HALT_C - G_DIE_RESUME_C - 10;
  constant C_HBM_HYST_FLOOR   : natural := G_HBM_HALT_C - G_HBM_RESUME_C - 10;

  function die_code(t_c : integer) return natural is
  begin
    return (t_c * 10000 + 2794266) / C_TDEN;
  end function;

  -- Code back to approximate degrees C, for the REPORTED field only.  507.5921
  -- / 1024 = 0.49569 is approximated by 127/256 = 0.49609, and -279.42657680 by
  -- -279.  Worst case over 0..150 C is about 0.8 C.  Nothing compares against
  -- this: every threshold comparison below is done on exact codes, so the
  -- approximation can never move a trip point.  It exists so a human reading
  -- the register sees a temperature.
  --
  -- CLAMPED to the signed 8-bit range it is reported in.  Without the clamp a
  -- code of 0 -- which is exactly what an unclocked or absent SYSMON gives --
  -- converts to -279 and to_signed(-279, 8) is a runtime error in simulation
  -- and a silent wrap in synthesis.  The clamp is not cosmetic: the value being
  -- clamped is the one produced by the failure mode this module exists to
  -- survive.
  --
  -- Written as a SHIFT AND A SUBTRACT rather than `* 127`.  Vivado inferred two
  -- DSP48s for the multiply form and then warned that neither was pipelined --
  -- a lot of silicon, and a DRC warning, for a display field.
  function die_degc(code : unsigned) return integer is
    variable p : unsigned(17 downto 0);
    variable t : integer;
  begin
    p := shift_left(resize(code, 18), 7) - resize(code, 18);   -- code * 127
    t := to_integer(shift_right(p, 8)) - 279;                  -- / 256, - 279.43
    if t < -128 then
      return -128;
    elsif t > 127 then
      return 127;
    else
      return t;
    end if;
  end function;

  constant C_DIE_WARN   : natural := die_code(G_DIE_WARN_C);
  constant C_DIE_HALT   : natural := die_code(G_DIE_HALT_C);
  constant C_DIE_RESUME : natural := die_code(G_DIE_RESUME_C);
  constant C_DIE_MIN    : natural := die_code(G_DIE_MIN_C);
  constant C_DIE_MAX    : natural := die_code(G_DIE_MAX_C);

  constant C_MS_CYCLES  : natural := G_CLK_HZ / 1000;

  ------------------------------------------------------------------------------
  -- Cause codes.  Priority order, most specific first.
  ------------------------------------------------------------------------------
  constant CAUSE_NONE      : natural := 0;
  constant CAUSE_DIE_OT    : natural := 1;   -- SYSMON's own armed OT alarm
  constant CAUSE_DIE_ALARM : natural := 2;   -- SYSMON user temperature alarm
  constant CAUSE_DIE_OVER  : natural := 3;   -- our comparison on temp_out
  constant CAUSE_DIE_STALE : natural := 4;   -- die sensor not live/plausible
  constant CAUSE_HBM_CAT   : natural := 5;   -- a stack asserted CATTRIP
  constant CAUSE_HBM_OVER  : natural := 6;   -- our comparison on the stack code
  constant CAUSE_HBM_STALE : natural := 7;   -- HBM sensor not live/plausible

  ------------------------------------------------------------------------------
  -- Foreign-domain helpers.  Each is a divider plus a toggle, so the aux side
  -- sees edges it cannot miss: a single-cycle pulse in a 250 MHz domain can be
  -- missed entirely by a 200 MHz sampler, and a toggle at the raw rate could
  -- alias to a constant.  Dividing first makes both impossible.
  ------------------------------------------------------------------------------
  signal eoc_div  : unsigned(3 downto 0) := (others => '0');
  signal eoc_tgl  : std_logic := '0';
  signal pclk_div : unsigned(7 downto 0) := (others => '0');
  signal pclk_tgl : std_logic;

  ------------------------------------------------------------------------------
  -- Synchronisers into the aux domain
  ------------------------------------------------------------------------------
  signal syn_eoc   : std_logic_vector(2 downto 0) := (others => '0');
  signal syn_pclk  : std_logic_vector(2 downto 0) := (others => '0');
  signal syn_ot    : std_logic_vector(1 downto 0) := (others => '0');
  signal syn_alm   : std_logic_vector(1 downto 0) := (others => '0');
  signal syn_cat0  : std_logic_vector(1 downto 0) := (others => '0');
  signal syn_cat1  : std_logic_vector(1 downto 0) := (others => '0');
  signal syn_clrt  : std_logic_vector(2 downto 0) := (others => '0');
  signal syn_clrp  : std_logic_vector(2 downto 0) := (others => '0');
  signal syn_can   : std_logic_vector(2 downto 0) := (others => '0');

  -- multi-bit sensor words: two flops per bit, then the agreement filter
  signal die_m,  die_s  : std_logic_vector(9 downto 0) := (others => '0');
  signal h0_m,   h0_s   : std_logic_vector(6 downto 0) := (others => '0');
  signal h1_m,   h1_s   : std_logic_vector(6 downto 0) := (others => '0');

  attribute async_reg : string;
  attribute async_reg of syn_eoc  : signal is "TRUE";
  attribute async_reg of syn_pclk : signal is "TRUE";
  attribute async_reg of syn_ot   : signal is "TRUE";
  attribute async_reg of syn_alm  : signal is "TRUE";
  attribute async_reg of syn_cat0 : signal is "TRUE";
  attribute async_reg of syn_cat1 : signal is "TRUE";
  attribute async_reg of syn_clrt : signal is "TRUE";
  attribute async_reg of syn_clrp : signal is "TRUE";
  attribute async_reg of syn_can  : signal is "TRUE";
  attribute async_reg of die_m    : signal is "TRUE";
  attribute async_reg of die_s    : signal is "TRUE";
  attribute async_reg of h0_m     : signal is "TRUE";
  attribute async_reg of h0_s     : signal is "TRUE";
  attribute async_reg of h1_m     : signal is "TRUE";
  attribute async_reg of h1_s     : signal is "TRUE";

  ------------------------------------------------------------------------------
  -- Agreement filter state
  ------------------------------------------------------------------------------
  signal die_prev : std_logic_vector(9 downto 0) := (others => '0');
  signal h0_prev  : std_logic_vector(6 downto 0) := (others => '0');
  signal h1_prev  : std_logic_vector(6 downto 0) := (others => '0');
  signal die_run  : unsigned(3 downto 0) := (others => '0');
  signal h0_run   : unsigned(3 downto 0) := (others => '0');
  signal h1_run   : unsigned(3 downto 0) := (others => '0');

  signal die_acc  : unsigned(9 downto 0) := (others => '0');
  signal h0_acc   : unsigned(6 downto 0) := (others => '0');
  signal h1_acc   : unsigned(6 downto 0) := (others => '0');
  signal die_seen : std_logic := '0';
  signal h0_seen  : std_logic := '0';
  signal h1_seen  : std_logic := '0';
  signal hbm_seen : std_logic;

  ------------------------------------------------------------------------------
  -- Time base and watchdogs
  ------------------------------------------------------------------------------
  signal ms_div  : unsigned(19 downto 0) := (others => '0');
  signal ms_tick : std_logic := '0';

  -- Watchdogs start AT the timeout, not at zero: before any liveness edge has
  -- ever been seen the sensor must read as stale, not as fresh.
  signal die_wd : unsigned(15 downto 0)
                := to_unsigned(G_STALE_MS, 16);
  signal hbm_wd : unsigned(15 downto 0)
                := to_unsigned(G_STALE_MS, 16);
  signal hold   : unsigned(15 downto 0) := (others => '0');

  ------------------------------------------------------------------------------
  -- Decisions
  ------------------------------------------------------------------------------
  signal die_valid, hbm_valid : std_logic;
  signal die_hot,   hbm_hot   : std_logic;
  signal die_cool,  hbm_cool  : std_logic;
  signal warn                 : std_logic;
  signal cause                : unsigned(3 downto 0);

  signal halted   : std_logic := '1';   -- FAIL SAFE: halted out of reset
  signal armed    : std_logic := '0';
  signal halted_d : std_logic := '1';

  ------------------------------------------------------------------------------
  -- Latches
  ------------------------------------------------------------------------------
  signal trip_valid : std_logic := '0';
  signal trip_cause : unsigned(3 downto 0) := (others => '0');
  signal trip_die   : unsigned(9 downto 0) := (others => '0');
  signal trip_h0    : unsigned(6 downto 0) := (others => '0');
  signal trip_h1    : unsigned(6 downto 0) := (others => '0');
  signal trip_cnt   : unsigned(7 downto 0) := (others => '0');

  signal peak_die : unsigned(9 downto 0) := (others => '0');
  signal peak_h0  : unsigned(6 downto 0) := (others => '0');
  signal peak_h1  : unsigned(6 downto 0) := (others => '0');

  signal st_ot   : std_logic := '0';
  signal st_alm  : std_logic := '0';
  signal st_cat0 : std_logic := '0';
  signal st_cat1 : std_logic := '0';
  signal st_dis  : std_logic := '0';   -- the two HBM copies ever disagreed
  -- There is deliberately NO "die sensor was ever valid" sticky.  `armed`
  -- already carries it: the guard only ever releases when BOTH sensors are
  -- valid and cool, so armed = 1 means both have worked at least once.  A
  -- separate pair of stickies was written, found to be unread, and removed --
  -- synthesis had been silently stripping them.

  ------------------------------------------------------------------------------
  -- Control, qualified in its OWN domain before crossing
  ------------------------------------------------------------------------------
  -- The key comparison MUST be registered in the source domain.  Feeding
  -- combinational logic straight into a synchroniser lets a glitch on the
  -- decode be captured as a clear that nobody asked for.
  signal host_clrt, host_clrp : std_logic := '0';
  signal aux_key_ok : std_logic;
  signal aux_clrt, aux_clrp   : std_logic;
  signal aux_clrt_d, aux_clrp_d : std_logic := '0';
  signal clr_trip, clr_peak : std_logic;

  ------------------------------------------------------------------------------
  -- The canary.  There is no compute datapath in this bitstream yet, so the
  -- halt would otherwise have nothing to halt and no way to be tested on
  -- silicon.  This counter IS the datapath's stand-in: it advances in the
  -- compute domain only while the guard is releasing work, its top bit is
  -- toggled across into the aux domain, and the aux side counts those toggles
  -- into a register readable over JTAG with the link down.  Two reads a second
  -- apart therefore answer "is the compute domain running and un-halted" with
  -- no host, no datapath and no instrument.
  ------------------------------------------------------------------------------
  signal halt_sync : std_logic_vector(1 downto 0) := (others => '1');
  attribute async_reg of halt_sync : signal is "TRUE";
  signal canary     : unsigned(G_CANARY_BIT downto 0) := (others => '0');
  signal canary_tgl : std_logic;
  signal canary_cnt : unsigned(31 downto 0) := (others => '0');

  ------------------------------------------------------------------------------
  -- The aux -> host publication path.  One 160-bit bundle, one shared agreement
  -- filter, so all five words are captured from the SAME aux sample and are
  -- mutually consistent when the host reads them.  Five separate filters would
  -- each be correct on its own and could still hand the host a temperature from
  -- one instant and a trip count from another.
  ------------------------------------------------------------------------------
  constant C_PUBW : natural := 160;
  signal pub_src  : std_logic_vector(C_PUBW - 1 downto 0);
  signal pub_m, pub_s, pub_prev, pub_acc
                  : std_logic_vector(C_PUBW - 1 downto 0) := (others => '0');
  signal pub_run  : unsigned(3 downto 0) := (others => '0');
  attribute async_reg of pub_m : signal is "TRUE";
  attribute async_reg of pub_s : signal is "TRUE";

  -- Local copies of the status words, so the same bits feed both the aux-domain
  -- outputs and the publication bundle and cannot drift apart.
  signal w_therm, w_temps, w_peak, w_trip, w_canary
                  : std_logic_vector(31 downto 0);

begin

  ------------------------------------------------------------------------------
  -- Elaboration-time gates on the thresholds.
  --
  -- These are the same shape as rtl/fk33_aux.vhd's assertion that the pot wiper
  -- is 68, and for the same reason: a threshold is a safety property, and a
  -- build that quietly carries a different one is worse than a build that
  -- fails.  gen_pcieep.py refuses to emit a build if any of them is missing.
  ------------------------------------------------------------------------------
  assert G_DIE_HALT_C <= 90
    report "fk33_thermal: G_DIE_HALT_C must not exceed 90 C.  DS890 Table 33 "
         & "puts sustained Tj for -2LE at 100 C and the armed SYSMON OT trip "
         & "in this design is 101 C; a halt above 90 C leaves no margin and "
         & "may let the OT shutdown fire first, which drops the card off PCIe."
    severity failure;

  assert G_DIE_RESUME_C + 10 <= G_DIE_HALT_C
    report "fk33_thermal: the die hysteresis band must be at least 10 C, or "
         & "the guard can chatter around the trip point."
    severity failure;

  assert G_DIE_WARN_C < G_DIE_HALT_C and G_DIE_RESUME_C <= G_DIE_WARN_C
    report "fk33_thermal: require G_DIE_RESUME_C <= G_DIE_WARN_C < G_DIE_HALT_C."
    severity failure;

  assert G_HBM_HALT_C <= 85
    report "fk33_thermal: G_HBM_HALT_C must not exceed 85.  DS890 note 1 "
         & "recommends a maximum of 95 C for the HBM, note 4 limits 95-105 C "
         & "to 4.1% of device lifetime and requires 4x refresh above 95 C "
         & "which this HBM IP is not configured for, and the code-to-Celsius "
         & "mapping of DRAM_x_STAT_TEMP is NOT calibrated on this card."
    severity failure;

  assert G_HBM_RESUME_C + 10 <= G_HBM_HALT_C
    report "fk33_thermal: the HBM hysteresis band must be at least 10 codes."
    severity failure;

  assert G_HBM_WARN_C < G_HBM_HALT_C and G_HBM_RESUME_C <= G_HBM_WARN_C
    report "fk33_thermal: require G_HBM_RESUME_C <= G_HBM_WARN_C < G_HBM_HALT_C."
    severity failure;

  -- The integer transfer function is approximate by construction, so check the
  -- results rather than trusting them.  90 C is code 745 and 75 C is code 715
  -- under the exact external-reference equation.
  assert C_DIE_HALT > 700 and C_DIE_HALT < 800
    report "fk33_thermal: the die halt threshold did not convert to a "
         & "plausible SYSMON code.  The transfer function or the integer "
         & "arithmetic is wrong."
    severity failure;

  assert C_DIE_RESUME < C_DIE_WARN and C_DIE_WARN < C_DIE_HALT
    report "fk33_thermal: the converted die codes are not monotonic in "
         & "temperature.  The transfer function is wrong."
    severity failure;

  assert C_MS_CYCLES >= 1000
    report "fk33_thermal: G_CLK_HZ is too low for a millisecond time base with "
         & "any resolution."
    severity failure;

  assert G_STABLE >= 2
    report "fk33_thermal: the agreement filter needs at least 2 consecutive "
         & "identical samples, or a torn word can be accepted."
    severity failure;

  ------------------------------------------------------------------------------
  -- Foreign-domain dividers.  Nothing else lives in these domains.
  ------------------------------------------------------------------------------
  process (sysmon_clk)
  begin
    if rising_edge(sysmon_clk) then
      if sysmon_eoc = '1' then
        eoc_div <= eoc_div + 1;
      end if;
    end if;
  end process;
  eoc_tgl <= eoc_div(3);

  process (hbm_pclk)
  begin
    if rising_edge(hbm_pclk) then
      pclk_div <= pclk_div + 1;
    end if;
  end process;
  pclk_tgl <= pclk_div(7);

  ------------------------------------------------------------------------------
  -- The host control word, qualified and registered in the PCIe domain.
  ------------------------------------------------------------------------------
  process (ctl_host_clk)
    variable keyok : boolean;
  begin
    if rising_edge(ctl_host_clk) then
      keyok := unsigned(ctl_host(31 downto 16))
               = to_unsigned(G_CTL_KEY, 16);
      if keyok then
        host_clrt <= ctl_host(0);
        host_clrp <= ctl_host(1);
      else
        host_clrt <= '0';
        host_clrp <= '0';
      end if;
    end if;
  end process;

  -- The aux-side control word is already in this domain, so it needs no
  -- synchroniser, only the same key.
  aux_key_ok <= '1' when unsigned(ctl_aux(31 downto 16))
                         = to_unsigned(G_CTL_KEY, 16) else '0';
  aux_clrt   <= aux_key_ok and ctl_aux(0);
  aux_clrp   <= aux_key_ok and ctl_aux(1);

  ------------------------------------------------------------------------------
  -- The canary, in the compute domain
  ------------------------------------------------------------------------------
  process (compute_clk)
  begin
    if rising_edge(compute_clk) then
      halt_sync <= halt_sync(0) & halted;
      if halt_sync(1) = '0' then
        canary <= canary + 1;
      end if;
    end if;
  end process;
  compute_halt <= halt_sync(1);
  canary_tgl   <= canary(G_CANARY_BIT);

  ------------------------------------------------------------------------------
  -- Synchronisers into the aux domain, and the millisecond time base
  ------------------------------------------------------------------------------
  process (aux_clk)
  begin
    if rising_edge(aux_clk) then
      syn_eoc  <= syn_eoc(1 downto 0)  & eoc_tgl;
      syn_pclk <= syn_pclk(1 downto 0) & pclk_tgl;
      syn_can  <= syn_can(1 downto 0)  & canary_tgl;
      syn_ot   <= syn_ot(0)   & sysmon_ot;
      syn_alm  <= syn_alm(0)  & sysmon_alarm;
      syn_cat0 <= syn_cat0(0) & hbm_cattrip0;
      syn_cat1 <= syn_cat1(0) & hbm_cattrip1;
      syn_clrt <= syn_clrt(1 downto 0) & host_clrt;
      syn_clrp <= syn_clrp(1 downto 0) & host_clrp;

      die_m <= sysmon_temp; die_s <= die_m;
      h0_m  <= hbm_temp0;   h0_s  <= h0_m;
      h1_m  <= hbm_temp1;   h1_s  <= h1_m;

      ms_tick <= '0';
      if ms_div = to_unsigned(C_MS_CYCLES - 1, ms_div'length) then
        ms_div  <= (others => '0');
        ms_tick <= '1';
      else
        ms_div <= ms_div + 1;
      end if;
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- The agreement filter.  A candidate word is accepted only after G_STABLE+1
  -- consecutive identical fully-synchronised samples.  See the CDC note in the
  -- header for why this, and not set_bus_skew, is what makes the crossing safe.
  ------------------------------------------------------------------------------
  process (aux_clk)
  begin
    if rising_edge(aux_clk) then
      die_prev <= die_s;
      h0_prev  <= h0_s;
      h1_prev  <= h1_s;

      if die_s = die_prev then
        if die_run < to_unsigned(G_STABLE, die_run'length) then
          die_run <= die_run + 1;
        else
          die_acc  <= unsigned(die_s);
          die_seen <= '1';
        end if;
      else
        die_run <= (others => '0');
      end if;

      if h0_s = h0_prev then
        if h0_run < to_unsigned(G_STABLE, h0_run'length) then
          h0_run <= h0_run + 1;
        else
          h0_acc  <= unsigned(h0_s);
          h0_seen <= '1';
        end if;
      else
        h0_run <= (others => '0');
      end if;

      if h1_s = h1_prev then
        if h1_run < to_unsigned(G_STABLE, h1_run'length) then
          h1_run <= h1_run + 1;
        else
          h1_acc  <= unsigned(h1_s);
          h1_seen <= '1';
        end if;
      else
        h1_run <= (others => '0');
      end if;
    end if;
  end process;

  -- Both copies must have been accepted before the HBM sensor counts as seen.
  hbm_seen <= h0_seen and h1_seen;

  ------------------------------------------------------------------------------
  -- Liveness watchdogs.  Reset by an EDGE on the foreign-domain toggle, which
  -- is independent of the sensor VALUE -- that independence is the whole point.
  ------------------------------------------------------------------------------
  process (aux_clk)
  begin
    if rising_edge(aux_clk) then
      if syn_eoc(2) /= syn_eoc(1) then
        die_wd <= (others => '0');
      elsif ms_tick = '1' and die_wd < to_unsigned(G_STALE_MS, die_wd'length) then
        die_wd <= die_wd + 1;
      end if;

      if syn_pclk(2) /= syn_pclk(1) then
        hbm_wd <= (others => '0');
      elsif ms_tick = '1' and hbm_wd < to_unsigned(G_STALE_MS, hbm_wd'length) then
        hbm_wd <= hbm_wd + 1;
      end if;
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- Validity, and the hot / cool decisions.
  --
  -- READ THIS BEFORE CHANGING ANY OF IT.  Every `not valid` term below is a
  -- FAIL-SAFE, not a convenience.  A stuck-at-zero sensor and a very cold card
  -- produce the same value, so a value comparison alone cannot tell them apart
  -- and would fail OPEN.  The validity terms are what make the failure closed.
  ------------------------------------------------------------------------------
  die_valid <= '1' when die_seen = '1'
                    and die_wd < to_unsigned(G_STALE_MS, die_wd'length)
                    and die_acc > to_unsigned(C_DIE_MIN, die_acc'length)
                    and die_acc < to_unsigned(C_DIE_MAX, die_acc'length)
               else '0';

  hbm_valid <= '1' when hbm_seen = '1'
                    and hbm_wd < to_unsigned(G_STALE_MS, hbm_wd'length)
                    and h0_acc = h1_acc
                    and h0_acc >= to_unsigned(G_HBM_MIN_CODE, h0_acc'length)
                    and h0_acc <= to_unsigned(G_HBM_MAX_CODE, h0_acc'length)
               else '0';

  die_hot <= '1' when die_valid = '0'
                   or syn_ot(1) = '1'
                   or syn_alm(1) = '1'
                   or die_acc >= to_unsigned(C_DIE_HALT, die_acc'length)
             else '0';

  hbm_hot <= '1' when hbm_valid = '0'
                   or syn_cat0(1) = '1' or syn_cat1(1) = '1'
                   or st_cat0 = '1' or st_cat1 = '1'
                   or h0_acc >= to_unsigned(G_HBM_HALT_C, h0_acc'length)
             else '0';

  die_cool <= '1' when die_valid = '1'
                   and syn_ot(1) = '0' and syn_alm(1) = '0'
                   and die_acc <= to_unsigned(C_DIE_RESUME, die_acc'length)
              else '0';

  hbm_cool <= '1' when hbm_valid = '1'
                   and syn_cat0(1) = '0' and syn_cat1(1) = '0'
                   and st_cat0 = '0' and st_cat1 = '0'
                   and h0_acc <= to_unsigned(G_HBM_RESUME_C, h0_acc'length)
              else '0';

  warn <= '1' when (die_valid = '1'
                    and die_acc >= to_unsigned(C_DIE_WARN, die_acc'length))
                or (hbm_valid = '1'
                    and h0_acc >= to_unsigned(G_HBM_WARN_C, h0_acc'length))
          else '0';

  -- Priority encode.  Most specific first, so "the stack said catastrophic"
  -- is never reported as "a threshold was crossed".
  cause <= to_unsigned(CAUSE_DIE_OT, 4)    when syn_ot(1) = '1'                else
           to_unsigned(CAUSE_DIE_ALARM, 4) when syn_alm(1) = '1'               else
           to_unsigned(CAUSE_HBM_CAT, 4)   when syn_cat0(1) = '1'
                                             or syn_cat1(1) = '1'
                                             or st_cat0 = '1'
                                             or st_cat1 = '1'                 else
           to_unsigned(CAUSE_DIE_STALE, 4) when die_valid = '0'                else
           to_unsigned(CAUSE_HBM_STALE, 4) when hbm_valid = '0'                else
           to_unsigned(CAUSE_DIE_OVER, 4)
             when die_acc >= to_unsigned(C_DIE_HALT, die_acc'length)           else
           to_unsigned(CAUSE_HBM_OVER, 4)
             when h0_acc >= to_unsigned(G_HBM_HALT_C, h0_acc'length)           else
           to_unsigned(CAUSE_NONE, 4);

  -- Both paths are EDGE triggered, not level.  The control words come from
  -- axi_gpio output registers that hold their value indefinitely, so a level
  -- would mean a control word left set after a clear keeps clearing forever --
  -- and the peak-hold would then read zero for the rest of the session while
  -- looking perfectly healthy.  An edge makes a clear one event.
  clr_trip <= '1' when (aux_clrt_d = '0' and aux_clrt = '1')
                    or (syn_clrt(2) = '0' and syn_clrt(1) = '1') else '0';
  clr_peak <= '1' when (aux_clrp_d = '0' and aux_clrp = '1')
                    or (syn_clrp(2) = '0' and syn_clrp(1) = '1') else '0';

  ------------------------------------------------------------------------------
  -- The guard itself, plus the latches and the peak-hold.
  ------------------------------------------------------------------------------
  main : process (aux_clk)
  begin
    if rising_edge(aux_clk) then
      halted_d   <= halted;
      aux_clrt_d <= aux_clrt;
      aux_clrp_d <= aux_clrp;

      -- Canary edges seen in this domain, so a JTAG reader can tell whether the
      -- compute domain is actually advancing.
      if syn_can(2) /= syn_can(1) then
        canary_cnt <= canary_cnt + 1;
      end if;

      -- Stickies.  These record that something HAPPENED, so they must not be
      -- conditioned on the guard's state.
      if syn_ot(1)   = '1' then st_ot   <= '1'; end if;
      if syn_alm(1)  = '1' then st_alm  <= '1'; end if;
      if syn_cat0(1) = '1' then st_cat0 <= '1'; end if;
      if syn_cat1(1) = '1' then st_cat1 <= '1'; end if;
      if hbm_seen = '1' and h0_acc /= h1_acc then st_dis <= '1'; end if;

      -- Peak hold.  Only on a VALID reading, or a stuck-at-0x3FF sensor would
      -- write a peak nobody ever reached.  Deliberately NOT cleared by
      -- clr_trip: a cleared trip must still leave the peak-hold intact.
      if die_valid = '1' and die_acc > peak_die then peak_die <= die_acc; end if;
      if hbm_valid = '1' and h0_acc > peak_h0   then peak_h0  <= h0_acc;  end if;
      if hbm_valid = '1' and h1_acc > peak_h1   then peak_h1  <= h1_acc;  end if;

      ------------------------------------------------------------------------
      -- Halt / resume with hysteresis and a minimum dwell.
      ------------------------------------------------------------------------
      if die_hot = '1' or hbm_hot = '1' then
        halted <= '1';
        hold   <= (others => '0');
      elsif halted = '1' then
        if die_cool = '1' and hbm_cool = '1' then
          if hold >= to_unsigned(G_MIN_HALT_MS, hold'length) then
            halted <= '0';
            armed  <= '1';       -- the guard has released compute at least once
          elsif ms_tick = '1' then
            hold <= hold + 1;
          end if;
        else
          -- between the resume point and the halt point: STAY HALTED.  This is
          -- the hysteresis, and it is why hold is not advanced here.
          hold <= (others => '0');
        end if;
      end if;

      ------------------------------------------------------------------------
      -- Host / JTAG clears.
      --
      -- A clear NEVER releases the halt: `halted` is recomputed above from the
      -- live sensors every cycle, so clearing the latch on a card that is still
      -- hot changes the record and nothing else.  That is the point.
      ------------------------------------------------------------------------
      if clr_trip = '1' then
        trip_valid <= '0';
        trip_cause <= (others => '0');
        trip_die   <= (others => '0');
        trip_h0    <= (others => '0');
        trip_h1    <= (others => '0');
        trip_cnt   <= (others => '0');
        st_ot      <= syn_ot(1);
        st_alm     <= syn_alm(1);
        st_cat0    <= syn_cat0(1);
        st_cat1    <= syn_cat1(1);
        st_dis     <= '0';
      end if;

      if clr_peak = '1' then
        peak_die <= (others => '0');
        peak_h0  <= (others => '0');
        peak_h1  <= (others => '0');
      end if;

      ------------------------------------------------------------------------
      -- Trip capture.  Only once armed, so the fail-safe halt the guard holds
      -- from reset until it has seen a temperature is NOT counted as a thermal
      -- event -- it is reported through `armed` and `cause` instead.
      --
      -- Placed AFTER the clear block on purpose: if a clear and a genuine trip
      -- land on the same cycle, the trip must survive.  Last assignment wins.
      ------------------------------------------------------------------------
      if armed = '1' and halted = '1' and halted_d = '0' then
        trip_valid <= '1';
        trip_cause <= cause;
        trip_die   <= die_acc;
        trip_h0    <= h0_acc;
        trip_h1    <= h1_acc;
        if trip_cnt /= to_unsigned(255, trip_cnt'length) then
          trip_cnt <= trip_cnt + 1;
        end if;
      end if;

      ------------------------------------------------------------------------
      -- Reset.  Everything returns to the fail-safe state, which is HALTED and
      -- NOT armed.  Note that the synchronisers above are deliberately outside
      -- this: a synchroniser that can be held in reset reports stale data for
      -- two clocks after release.
      ------------------------------------------------------------------------
      if aux_aresetn = '0' then
        halted     <= '1';
        halted_d   <= '1';
        armed      <= '0';
        hold       <= (others => '0');
        trip_valid <= '0';
        trip_cause <= (others => '0');
        trip_cnt   <= (others => '0');
        peak_die   <= (others => '0');
        peak_h0    <= (others => '0');
        peak_h1    <= (others => '0');
        st_ot      <= '0';
        st_alm     <= '0';
        st_cat0    <= '0';
        st_cat1    <= '0';
        st_dis     <= '0';
        canary_cnt <= (others => '0');
      end if;
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- Status words.
  --
  -- THERM_STATUS
  --   [0]     halted, live
  --   [1]     warn, live
  --   [2]     armed -- the guard has released compute at least once
  --   [3]     die sensor valid, live
  --   [4]     HBM sensor valid, live
  --   [5]     die hot, live
  --   [6]     HBM hot, live
  --   [7]     trip latched, sticky
  --   [11:8]  cause, live
  --   [15:12] cause of the latched trip, sticky
  --   [23:16] trip count, saturating at 255
  --   [24]    SYSMON ot_out, live        [25] the same, sticky
  --   [26]    SYSMON user temp alarm, live [27] the same, sticky
  --   [28]    CATTRIP stack 0, sticky    [29] CATTRIP stack 1, sticky
  --   [30]    the two HBM copies ever disagreed, sticky (a CDC fault)
  --   [31]    constant 1: the thermal guard is present in this bitstream.
  --           A bitstream without it reads 0 here, so "is there a guard" is one
  --           read and cannot be answered by wishful thinking.
  --
  -- THERM_TEMPS  [9:0] die code  [16:10] HBM code 0  [23:17] HBM code 1
  --              [31:24] die temperature in degrees C, signed, APPROXIMATE
  -- THERM_PEAK   same fields, peak-hold
  -- THERM_TRIP   same code fields captured at the trip, [27:24] cause,
  --              [31:28] 0x5 fixed so a dead bus is obvious
  -- THERM_CANARY 32-bit count of compute-domain canary toggles seen here
  ------------------------------------------------------------------------------
  ------------------------------------------------------------------------------
  -- Publication into the host clock domain.  Same agreement filter as the
  -- sensor inputs: a candidate is accepted only after G_STABLE+1 consecutive
  -- identical fully-synchronised samples, so skew between the 160 bits can
  -- never produce an accepted word that never existed on the aux side.
  ------------------------------------------------------------------------------
  pub_src <= w_canary & w_trip & w_peak & w_temps & w_therm;

  process (ctl_host_clk)
  begin
    if rising_edge(ctl_host_clk) then
      pub_m    <= pub_src;
      pub_s    <= pub_m;
      pub_prev <= pub_s;
      if pub_s = pub_prev then
        if pub_run < to_unsigned(G_STABLE, pub_run'length) then
          pub_run <= pub_run + 1;
        else
          pub_acc <= pub_s;
        end if;
      else
        pub_run <= (others => '0');
      end if;
    end if;
  end process;

  host_therm  <= pub_acc(31 downto 0);
  host_temps  <= pub_acc(63 downto 32);
  host_peak   <= pub_acc(95 downto 64);
  host_trip   <= pub_acc(127 downto 96);
  host_canary <= pub_acc(159 downto 128);

  stat_therm  <= w_therm;
  stat_temps  <= w_temps;
  stat_peak   <= w_peak;
  stat_trip   <= w_trip;
  stat_canary <= w_canary;

  w_therm(0)               <= halted;
  w_therm(1)               <= warn;
  w_therm(2)               <= armed;
  w_therm(3)               <= die_valid;
  w_therm(4)               <= hbm_valid;
  w_therm(5)               <= die_hot;
  w_therm(6)               <= hbm_hot;
  w_therm(7)               <= trip_valid;
  w_therm(11 downto 8)     <= std_logic_vector(cause);
  w_therm(15 downto 12)    <= std_logic_vector(trip_cause);
  w_therm(23 downto 16)    <= std_logic_vector(trip_cnt);
  w_therm(24)              <= syn_ot(1);
  w_therm(25)              <= st_ot;
  w_therm(26)              <= syn_alm(1);
  w_therm(27)              <= st_alm;
  w_therm(28)              <= st_cat0;
  w_therm(29)              <= st_cat1;
  w_therm(30)              <= st_dis;
  w_therm(31)              <= '1';

  w_temps(9 downto 0)      <= std_logic_vector(die_acc);
  w_temps(16 downto 10)    <= std_logic_vector(h0_acc);
  w_temps(23 downto 17)    <= std_logic_vector(h1_acc);
  w_temps(31 downto 24)    <=
      std_logic_vector(to_signed(die_degc(die_acc), 8));

  w_peak(9 downto 0)       <= std_logic_vector(peak_die);
  w_peak(16 downto 10)     <= std_logic_vector(peak_h0);
  w_peak(23 downto 17)     <= std_logic_vector(peak_h1);
  w_peak(31 downto 24)     <=
      std_logic_vector(to_signed(die_degc(peak_die), 8));

  w_trip(9 downto 0)       <= std_logic_vector(trip_die);
  w_trip(16 downto 10)     <= std_logic_vector(trip_h0);
  w_trip(23 downto 17)     <= std_logic_vector(trip_h1);
  w_trip(27 downto 24)     <= std_logic_vector(trip_cause);
  w_trip(31 downto 28)     <= "0101";

  w_canary <= std_logic_vector(canary_cnt);

end architecture rtl;
