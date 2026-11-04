-- hw/jc/census/jc_sysmon_probe.vhd -- 2026-11-03.  Jungle Cat SYSMON supply probe.
--
-- A TEST, NOT A DESIGN.  jc_qpll_census showed no GTY QPLL locked on any quad,
-- including a positive control fed from an MMCM.  Leading hypothesis: the GTY
-- analog rails (MGTAVCC ~0.9 V, MGTAVTT ~1.2 V, MGTVCCAUX ~1.8 V) are not
-- powered.  This bitstream asks the on-die SYSMONs to measure them, next to
-- VCCINT / VCCAUX / VCCBRAM, which the board tool already reports (~0.853,
-- ~1.79, ~0.855 V) and which therefore act as a positive control for the
-- readout itself.
--
-- SITES AND SLRS (MEASURED, Vivado 2023.2 get_sites / get_slrs / get_iobanks on
-- xcvu35p-fsvh2104-1-e, script /mnt/storage/fk33_builds/jc_sysmon/query/q.tcl):
--   SYSMONE4_X0Y0 in SLR0 (master), SYSMONE4_X0Y1 in SLR1 (SSIT slave 0).
--   SLR0: GTY banks 124-127 and 224-227 (GTYE4_COMMON_X0Y0..3, X1Y0..3).
--   SLR1: GTY banks 128-131 and 228-231 (GTYE4_COMMON_X0Y4..7, X1Y4..7).
--   A SYSMON's VUSER bank must be in its own SLR: the wizard rejects
--   USER_SUPPLY0_BANK 131 with "Valid values are - 64, 65, 66, 67, 124, 125,
--   126, 127, 224, 225, 226, 227" and the slave bank 126 with "68..71, 128..131,
--   228..231".
--
-- VUSER ASSIGNMENT.  Legal SYSMON_VUSERn_MONITOR strings for a GTY bank, from
-- system_management_wiz v1.3 (xgui update_PARAM_VALUE.SELECT_USER_SUPPLY<n>,
-- range = get_device_data D_BANK_VALID_VOLTAGE <bank>; probed by setting an
-- invalid value): "Valid values are - AVCC, AVTT, MGTVCCAUX".  The wizard also
-- refuses two VUSERs of one SYSMON on the same quadrant with the same rail.
--   SM0 (SLR0): VUSER0 = 126 AVCC, VUSER1 = 126 AVTT,
--               VUSER2 = 226 AVCC, VUSER3 = 226 MGTVCCAUX
--   SM1 (SLR1): VUSER0 = 131 AVCC, VUSER1 = 131 MGTVCCAUX,
--               VUSER2 = 231 AVCC, VUSER3 = 231 AVTT
-- v2 (SM1_CFG = 2, 2026-11-04): silicon read b1's four SLR1 VUSERs as
-- 0x0000-0x002E while SLR1 VCCINT/AUX/BRAM read right, so SM1 becomes
--   VUSER0 = bank 68 VCCAUX (HP bank in SLR1: no used pin is in SLR1, all are in
--            banks 65/67 of SLR0; VCCAUX is the rail SM1 already reads at
--            ~1.795 V, so this is a powered positive control for the slave VUSER
--            path; an unused bank's VCCO is not known to be powered),
--   VUSER1 = 128 AVCC, VUSER2 = 129 AVTT, VUSER3 = 228 MGTVCCAUX.
-- The v2 wizard generation (jc_sysmon/v2/query/sm_sysmon_v2.v) differs from b1's
-- only in SM1's VUSER generics and INIT_45 (0x5420 -> 0xADCD).
-- Every rail is seen on both columns (1xx west, 2xx east) somewhere, AVCC on
-- all four banks, and bank 131 is the positive-control quad of jc_qpll_census.
--
-- INIT PROVENANCE.  Every SYSMONE4 generic below is copied by script from a
-- system_management_wiz v1.3 (rev 19) generation, Vivado 2023.2, part
-- xcvu35p-fsvh2104-1-e, with INTERFACE_SELECTION Enable_DRP,
-- SYSMONE1_STARUP_SELECTION channel_sequencer (SEQUENCER_MODE Continuous),
-- DCLK_FREQUENCY 60, Enable_Slave0 true, channels VCCINT, VCCAUX, VBRAM,
-- TEMPERATURE, TEMPERATURE_SLAVE0_SSIT, VUSER0..3 and VUSER0..3_SLAVE0_SSIT,
-- the banks/rails above.  Source: <ip>/sm_sysmon.v, instances inst_sysmon and
-- inst_sysmon_ssit_slave0, kept at
-- /mnt/storage/fk33_builds/jc_sysmon/query/wizard_ref/sm_sysmon_dclk60.v
-- (generation script q4.tcl beside it).  LOCs from the same generation's sm.xdc.
-- Register meaning (SYSMONE4.vhd unisim model, data/vhdl/src/unisims/primitive):
--   INIT_41 = 0x2F90: [15:12] = "0010" = SEQ_CONT_CHAN (continuous sequence).
--   INIT_42 = 0x0C00: [15:8] = ADC clock divider 12.  DCLK_FREQUENCY was set to
--     60, not 50, ON PURPOSE: CFGMCLK is nominally 50 MHz but not trimmed, and
--     50/12 = 4.17 MHz leaves margin under the ADCCLK limit if it runs fast (the
--     50 MHz generation gave 0x0A00, divider 10).  dclk50 output kept beside.
--   INIT_44 = 0x0000: [3:0] = per-VUSER 6 V range select, all 0 = 3 V range.
--   INIT_46 = 0x000F: sequencer channels 32..35 = VUSER0..3 (seq_hr_chan_reg3).
--   INIT_48: bit 0 cal, 8 temp, 9 VCCINT, 10 VCCAUX, 11 VP/VN, 14 VCCBRAM.
--     SM0 0x4F01 is the wizard's.
--     SM1 0x4701 is ONE DEVIATION: the wizard's slave value is 0x0100 (cal off,
--     temperature only; its slave panel offers only temperature + VUSER).  Here
--     cal, VCCINT, VCCAUX and VCCBRAM are added so SLR1 has its own positive
--     control.  Whether a slave SYSMON measures its SLR's VCCINT/AUX/BRAM on
--     silicon is NOT established by any source read here: if SM1's 0x01/0x02/0x06
--     read 0 or nonsense while SM0's are right, that is the reason, not a fault.
-- DRP: each SYSMONE4 has its own DRP; DADDR is 8 bits.  Status registers read:
--   0x00 temp, 0x01 VCCINT, 0x02 VCCAUX, 0x06 VCCBRAM, 0x80..0x83 VUSER0..3.
--
-- CONVERSION (code = the 16-bit DRP word, ADC result MSB-justified):
--   VCCINT/VCCAUX/VCCBRAM:  V = code / 65536 * 3.
--   VUSER0..3: same 3 V scale.  SYSMONE4.vhd: channels 32..35 use
--     "mn_mux_in * 65536.0 / 3.0" unless bank_sel_6V (INIT_44[3:0]) is set, and
--     INIT_44 = 0.  (The 6 V range is documented only for HR-bank VCCO; ESTIMATE
--     that silicon matches the model for GT rails, not tested here.)
--   Temperature (UltraScale+ internal reference, SYSMONE4.vhd CR 961722):
--     T[C] = code * 509.3140064 / 65536 - 280.2308787.
--   Expected codes: 0.85 V -> 18569 (0x4889), 0.90 V -> 19661 (0x4CCD),
--     1.20 V -> 26214 (0x6666), 1.80 V -> 39322 (0x999A); 0 V -> ~0.
--
-- FSM: one per SYSMON, on CFGMCLK (STARTUPE3, as jc_qpll_census, so it runs
-- with no board clock).  Loops over the 8 addresses: DEN for one cycle, wait for
-- DRDY (timeout 1023 cycles: counted in tmo, the slot keeps its old value),
-- latch DO, gap 256 cycles, next.  hb counts completed reads (wraps); a reader
-- that sees hb move knows the FSM and the DRP are alive.
--
-- VIO (vio_sm, clock CFGMCLK):
--   probe_in0..7   = SM0 codes: temp, vccint, vccaux, vccbram, vuser0..3   (16)
--   probe_in8      = SM0 hb (32), probe_in9 = SM0 tmo (16)
--   probe_in10..17 = SM1 codes, same order                                (16)
--   probe_in18     = SM1 hb (32), probe_in19 = SM1 tmo (16)
--   probe_in20     = misc (3): bit 0 = SM0 OT, bit 1 = SM1 OT,
--                    bit 2 = err_vccint pin (1 = no PMIC fault)
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
library unisim; use unisim.vcomponents.all;

entity jc_sysmon_probe is
  -- SM1_CFG selects SM1's VUSER set (see "v2" in the header): 1 = build b1, 2 = build v2.
  generic ( SM1_CFG : positive := 1 );
  port (
    err_vccint : in  std_logic;
    fan_ctl    : out std_logic;
    LED_A, LED_B, LED_C, LED_D : out std_logic );
end entity;

architecture rtl of jc_sysmon_probe is
  constant NCH : positive := 8;
  type addr_arr is array (0 to NCH-1) of std_logic_vector(7 downto 0);
  constant ADDRS : addr_arr := (x"00", x"01", x"02", x"06", x"80", x"81", x"82", x"83");
  type code_arr is array (0 to NCH-1) of std_logic_vector(15 downto 0);
  type code_2d  is array (0 to 1) of code_arr;
  type u32_arr  is array (0 to 1) of unsigned(31 downto 0);
  type u16_arr  is array (0 to 1) of unsigned(15 downto 0);
  type slv8_arr is array (0 to 1) of std_logic_vector(7 downto 0);
  type slv16_arr is array (0 to 1) of std_logic_vector(15 downto 0);
  type st_t is (S_POR, S_REQ, S_WAIT, S_GAP);
  type st_arr is array (0 to 1) of st_t;

  -- SM1 VUSER configuration.  Each set is the wizard's own output for that
  -- assignment (INIT_45 = analog bus select, one nibble per VUSER, depends on
  -- the bank's quadrant and the rail).
  function sm1_i45 return std_logic_vector is
  begin if SM1_CFG = 2 then return X"ADCD"; else return X"5420"; end if; end function;
  function sm1_bank(n : natural) return integer is
    type ia is array (0 to 3) of integer;
    constant b1 : ia := (131, 131, 231, 231);
    constant b2 : ia := (68, 128, 129, 228);
  begin if SM1_CFG = 2 then return b2(n); else return b1(n); end if; end function;
  function sm1_mon(n : natural) return string is
  begin
    if SM1_CFG = 2 then
      case n is when 0 => return "VCCAUX"; when 1 => return "AVCC";
                when 2 => return "AVTT";   when others => return "MGTVCCAUX"; end case;
    else
      case n is when 0 => return "AVCC"; when 1 => return "MGTVCCAUX";
                when 2 => return "AVCC"; when others => return "AVTT"; end case;
    end if;
  end function;

  signal cfgmclk, mclk : std_logic;
  signal codes : code_2d := (others => (others => (others => '0')));
  signal hb    : u32_arr := (others => (others => '0'));
  signal tmo   : u16_arr := (others => (others => '0'));
  signal st    : st_arr  := (others => S_POR);
  signal idx   : u16_arr := (others => (others => '0'));   -- channel index (low 3 bits)
  signal wcnt  : u16_arr := (others => (others => '0'));
  signal den, drdy, ot : std_logic_vector(1 downto 0) := (others => '0');
  signal daddr : slv8_arr := (others => (others => '0'));
  signal dout  : slv16_arr;
  signal blink : unsigned(25 downto 0) := (others => '0');
  signal err_s1, err_s2 : std_logic := '1';
  attribute ASYNC_REG : string;
  attribute ASYNC_REG of err_s1, err_s2 : signal is "TRUE";
  signal misc : std_logic_vector(2 downto 0);

  component vio_sm
    port ( clk : in std_logic;
           probe_in0, probe_in1, probe_in2, probe_in3, probe_in4, probe_in5,
           probe_in6, probe_in7 : in std_logic_vector(15 downto 0);
           probe_in8 : in std_logic_vector(31 downto 0);
           probe_in9 : in std_logic_vector(15 downto 0);
           probe_in10, probe_in11, probe_in12, probe_in13, probe_in14,
           probe_in15, probe_in16, probe_in17 : in std_logic_vector(15 downto 0);
           probe_in18 : in std_logic_vector(31 downto 0);
           probe_in19 : in std_logic_vector(15 downto 0);
           probe_in20 : in std_logic_vector(2 downto 0) );
  end component;
begin
  fan_ctl <= '1';

  u_start : STARTUPE3
    port map ( CFGCLK => open, CFGMCLK => cfgmclk, EOS => open, PREQ => open,
               DI => open, DO => "0000", DTS => "1111", FCSBO => '0',
               FCSBTS => '1', GSR => '0', GTS => '0', KEYCLEARB => '1',
               PACK => '0', USRCCLKO => '0', USRCCLKTS => '1',
               USRDONEO => '1', USRDONETS => '1' );
  u_mbuf : BUFG port map ( I => cfgmclk, O => mclk );

  -- SM0: SYSMONE4_X0Y0, SLR0, master.  Generics = wizard inst_sysmon, verbatim.
  u_sm0 : SYSMONE4
    generic map (
      COMMON_N_SOURCE => X"FFFF",
      INIT_40 => X"0000", INIT_41 => X"2F90", INIT_42 => X"0C00", INIT_43 => X"200F",
      INIT_44 => X"0000", INIT_45 => X"A8DC", INIT_46 => X"000F", INIT_47 => X"0000",
      INIT_48 => X"4F01", INIT_49 => X"0000", INIT_4A => X"0000", INIT_4B => X"0000",
      INIT_4C => X"0000", INIT_4D => X"0000", INIT_4E => X"0000", INIT_4F => X"0000",
      INIT_50 => X"B794", INIT_51 => X"4E81", INIT_52 => X"A147", INIT_53 => X"CBA3",
      INIT_54 => X"AB02", INIT_55 => X"4963", INIT_56 => X"9555", INIT_57 => X"B00A",
      INIT_58 => X"4E81", INIT_59 => X"4963", INIT_5A => X"4963", INIT_5B => X"9A74",
      INIT_5C => X"4963", INIT_5D => X"451E", INIT_5E => X"451E", INIT_5F => X"91EB",
      INIT_60 => X"9A74", INIT_61 => X"9A74", INIT_62 => X"9A74", INIT_63 => X"9A74",
      INIT_68 => X"98BF", INIT_69 => X"98BF", INIT_6A => X"98BF", INIT_6B => X"98BF",
      INIT_7A => X"0000", INIT_7B => X"0000", INIT_7C => X"0000", INIT_7D => X"0000",
      SYSMON_VUSER0_BANK => 126, SYSMON_VUSER0_MONITOR => "AVCC",
      SYSMON_VUSER1_BANK => 126, SYSMON_VUSER1_MONITOR => "AVTT",
      SYSMON_VUSER2_BANK => 226, SYSMON_VUSER2_MONITOR => "AVCC",
      SYSMON_VUSER3_BANK => 226, SYSMON_VUSER3_MONITOR => "MGTVCCAUX",
      SIM_DEVICE => "ULTRASCALE_PLUS", SIM_MONITOR_FILE => "design.dat" )
    port map (
      ADC_DATA => open, ALM => open, BUSY => open, CHANNEL => open,
      DO => dout(0), DRDY => drdy(0), EOC => open, EOS => open,
      I2C_SCLK_TS => open, I2C_SDA_TS => open, JTAGBUSY => open,
      JTAGLOCKED => open, JTAGMODIFIED => open, MUXADDR => open, OT => ot(0),
      SMBALERT_TS => open,
      CONVST => '0', CONVSTCLK => '0', DADDR => daddr(0), DCLK => mclk,
      DEN => den(0), DI => (others => '0'), DWE => '0',
      I2C_SCLK => '0', I2C_SDA => '0', RESET => '0',
      VAUXN => (others => '0'), VAUXP => (others => '0'), VN => '0', VP => '0' );

  -- SM1: SYSMONE4_X0Y1, SLR1, SSIT slave 0.  Generics = wizard
  -- inst_sysmon_ssit_slave0 verbatim EXCEPT INIT_48 (wizard 0x0100; see header).
  u_sm1 : SYSMONE4
    generic map (
      COMMON_N_SOURCE => X"FFFF",
      INIT_40 => X"0000", INIT_41 => X"2F90", INIT_42 => X"0C00", INIT_43 => X"200F",
      INIT_44 => X"0000", INIT_45 => sm1_i45, INIT_46 => X"000F", INIT_47 => X"0000",
      INIT_48 => X"4701", INIT_49 => X"0000", INIT_4A => X"0000", INIT_4B => X"0000",
      INIT_4C => X"0000", INIT_4D => X"0000", INIT_4E => X"0000", INIT_4F => X"0000",
      INIT_50 => X"B794", INIT_51 => X"4E81", INIT_52 => X"A147", INIT_53 => X"CBA3",
      INIT_54 => X"AB02", INIT_55 => X"4963", INIT_56 => X"9555", INIT_57 => X"B00A",
      INIT_58 => X"4E81", INIT_59 => X"4963", INIT_5A => X"4963", INIT_5B => X"9A74",
      INIT_5C => X"4963", INIT_5D => X"451E", INIT_5E => X"451E", INIT_5F => X"91EB",
      INIT_60 => X"9A74", INIT_61 => X"4DA7", INIT_62 => X"9A74", INIT_63 => X"9A74",
      INIT_68 => X"98BF", INIT_69 => X"4BF2", INIT_6A => X"98BF", INIT_6B => X"98BF",
      INIT_7A => X"0000", INIT_7B => X"0000", INIT_7C => X"0000", INIT_7D => X"0000",
      SYSMON_VUSER0_BANK => sm1_bank(0), SYSMON_VUSER0_MONITOR => sm1_mon(0),
      SYSMON_VUSER1_BANK => sm1_bank(1), SYSMON_VUSER1_MONITOR => sm1_mon(1),
      SYSMON_VUSER2_BANK => sm1_bank(2), SYSMON_VUSER2_MONITOR => sm1_mon(2),
      SYSMON_VUSER3_BANK => sm1_bank(3), SYSMON_VUSER3_MONITOR => sm1_mon(3),
      SIM_DEVICE => "ULTRASCALE_PLUS", SIM_MONITOR_FILE => "design.dat" )
    port map (
      ADC_DATA => open, ALM => open, BUSY => open, CHANNEL => open,
      DO => dout(1), DRDY => drdy(1), EOC => open, EOS => open,
      I2C_SCLK_TS => open, I2C_SDA_TS => open, JTAGBUSY => open,
      JTAGLOCKED => open, JTAGMODIFIED => open, MUXADDR => open, OT => ot(1),
      SMBALERT_TS => open,
      CONVST => '0', CONVSTCLK => '0', DADDR => daddr(1), DCLK => mclk,
      DEN => den(1), DI => (others => '0'), DWE => '0',
      I2C_SCLK => '0', I2C_SDA => '0', RESET => '0',
      VAUXN => (others => '0'), VAUXP => (others => '0'), VN => '0', VP => '0' );

  -- one DRP read loop per SYSMON
  g_fsm : for s in 0 to 1 generate
    process (mclk)
      variable k : natural range 0 to NCH-1;
    begin
      if rising_edge(mclk) then
        k := to_integer(idx(s)(2 downto 0));
        den(s) <= '0';
        case st(s) is
          when S_POR =>                 -- let the SYSMON finish its first sequence
            wcnt(s) <= wcnt(s) + 1;
            if wcnt(s) = x"FFFF" then wcnt(s) <= (others => '0'); st(s) <= S_REQ; end if;
          when S_REQ =>
            daddr(s) <= ADDRS(k);
            den(s)   <= '1';
            wcnt(s)  <= (others => '0');
            st(s)    <= S_WAIT;
          when S_WAIT =>
            wcnt(s) <= wcnt(s) + 1;
            if drdy(s) = '1' then
              codes(s)(k) <= dout(s);
              hb(s) <= hb(s) + 1;
              wcnt(s) <= (others => '0');
              st(s) <= S_GAP;
            elsif wcnt(s) = to_unsigned(1023, 16) then
              tmo(s) <= tmo(s) + 1;
              wcnt(s) <= (others => '0');
              st(s) <= S_GAP;
            end if;
          when S_GAP =>
            wcnt(s) <= wcnt(s) + 1;
            if wcnt(s) = to_unsigned(255, 16) then
              if k = NCH-1 then idx(s) <= (others => '0'); else idx(s) <= idx(s) + 1; end if;
              st(s) <= S_REQ;
            end if;
        end case;
      end if;
    end process;
  end generate;

  process (mclk)
  begin
    if rising_edge(mclk) then
      blink <= blink + 1;
      err_s1 <= err_vccint; err_s2 <= err_s1;
    end if;
  end process;

  misc <= err_s2 & ot(1) & ot(0);

  u_vio : vio_sm
    port map ( clk => mclk,
      probe_in0 => codes(0)(0), probe_in1 => codes(0)(1), probe_in2 => codes(0)(2),
      probe_in3 => codes(0)(3), probe_in4 => codes(0)(4), probe_in5 => codes(0)(5),
      probe_in6 => codes(0)(6), probe_in7 => codes(0)(7),
      probe_in8 => std_logic_vector(hb(0)), probe_in9 => std_logic_vector(tmo(0)),
      probe_in10 => codes(1)(0), probe_in11 => codes(1)(1), probe_in12 => codes(1)(2),
      probe_in13 => codes(1)(3), probe_in14 => codes(1)(4), probe_in15 => codes(1)(5),
      probe_in16 => codes(1)(6), probe_in17 => codes(1)(7),
      probe_in18 => std_logic_vector(hb(1)), probe_in19 => std_logic_vector(tmo(1)),
      probe_in20 => misc );

  LED_A <= blink(25);                    -- CFGMCLK alive: the bitstream is running
  LED_B <= hb(0)(10);                    -- SM0 DRP loop alive
  LED_C <= hb(1)(10);                    -- SM1 DRP loop alive
  LED_D <= not err_s2;                   -- PMIC fault line (low = fault)
end architecture;
