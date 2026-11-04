-- hw/jc/census/jc_qpll_census.vhd -- 2026-11-03.  Jungle Cat QPLL-lock census.
--
-- A TEST, NOT A DESIGN.  The edge-count census (jc_census.vhd) gives erratic
-- counts on some MGTREFCLK pins after a 156.25 MHz LVDS clock was fitted to the
-- carrier.  This bitstream asks the GTY itself: every one of the 16 GTY quads
-- (GTYE4_COMMON_X0Y0..X0Y7 = banks 124-131, X1Y0..X1Y7 = banks 224-231) runs
-- QPLL0 from its MGTREFCLK0 and QPLL1 from its MGTREFCLK1, both set for a
-- 156.25 MHz refclk and a 10.3125 GHz VCO.  QPLLxLOCK = 1 means a clock of the
-- right frequency really reaches that pin.  The edge counters of jc_census are
-- kept (ODIV2 -> BUFG_GT -> counter, same gate/seq protocol, gate timed by
-- CFGMCLK) so both views land in one VIO read.
--
-- Index map: refclk index i = 2*q + r, quad q = 0..7 -> bank 124+q,
-- q = 8..15 -> bank 224+(q-8); r = MGTREFCLK r.  QPLL0 tests REFCLK0
-- (GTREFCLK00, QPLL0REFCLKSEL = "001"), QPLL1 tests REFCLK1 (GTREFCLK11,
-- QPLL1REFCLKSEL = "010"; UG578 GTREFCLK<refclk><pll>).
--
-- GTYE4_COMMON ATTRIBUTE PROVENANCE: every generic below is copied verbatim by
-- script from a GT Wizard generation, never written by hand.  Vivado 2023.2,
-- gtwizard_ultrascale v1.7, part xcvu35p-fsvh2104-1-e, two IPs:
--   CONFIG.preset GTY-10GBASE-R, CHANNEL_ENABLE X0Y0, TX/RX_LINE_RATE 10.3125,
--   TX/RX_REFCLK_FREQUENCY 156.25, FREERUN_FREQUENCY 200,
--   TX/RX_PLL_TYPE QPLL0 (gtw_q0) and QPLL1 (gtw_q1), LOCATE_COMMON CORE.
-- Source: <ip>/synth/<ip>_gtye4_common_wrapper.v generic list (89 attributes,
-- every GTYE4_COMMON generic).  The two generations give IDENTICAL attribute
-- values (QPLL0_* and QPLL1_* both configured for FBDIV 66, CLKOUT_RATE HALF);
-- they differ only in the PD/RESET/LOCKEN port values, which this design sets
-- itself (PD 0, LOCKEN 1 for both PLLs).  Generation script and the extracted
-- map: /mnt/storage/fk33_builds/jc_qpll/gtwiz/{gen.tcl,generic_map.vhdi}.
-- Port tie-offs (BGBYPASSB, BGMONITORENB, BGPDB, BGRCALOVRDENB, RCALENB = 1,
-- BGRCALOVRD = "10000", rest 0) are the wizard's (<ip>/synth/<ip>.v).
-- Deviations from the wizard: QPLLxLOCKDETCLK and DRPCLK are the 200 MHz
-- sysclk (BC26) where the wizard ties them 0; QPLL1 takes MGTREFCLK1 via
-- GTREFCLK11 / sel "010" where the wizard's QPLL1 IP used GTREFCLK01 / "001".
--
-- Reset: QPLL0RESET/QPLL1RESET = power-on reset (2**POR_LOG2 CFGMCLK cycles,
-- ~5 us at 50 MHz, after configuration) OR the VIO output bit (write 1 then 0).
-- The reset logic runs on CFGMCLK so it works even if BC26 is dead.
--
-- drop(k): sticky, set when QPLL k's lock (k = 2*q + pll) falls after it was
-- seen high; cleared by the reset.  A lock that flickers between reads shows
-- here even when every sampled lock bit reads 1.
--
-- VIO (vio_qpll, clock CFGMCLK): probe_in0..31 = edge counts (index above),
-- in32 = BC26 count, in33 = seq, in34 = lock(32) (bit 2*q+pll),
-- in35 = refclklost(32) (bit 2*q+pll), in36 = drop(32), in37 = err_vccint & gate,
-- probe_out0 = reset.
--
-- POSITIVE CONTROL (2026-11-04, after silicon showed no QPLL locked anywhere):
-- an MMCM makes exactly 156.25 MHz from the 200 MHz BC26 sysclk (DIVCLK 4,
-- MULT 25 -> VCO 1250 MHz, CLKOUT0 /8) and a BUFG feeds it to GTGREFCLK0 of
-- quad CTL_Q = 7 (GTYE4_COMMON_X0Y7, bank 131), whose QPLL0REFCLKSEL is "111"
-- (GTGREFCLK0, UG578).  That quad's REFCLK0 pin (index 14) still feeds its
-- edge counter but no longer its QPLL0; its QPLL1 is unchanged (REFCLK1).
-- The control common keeps the same 89 wizard attributes: gtwizard_ultrascale
-- offers no fabric (GTGREFCLK) reference option, so no generation of that
-- variant exists, and UG578 names no attribute that GTGREFCLK requires (it
-- documents GTGREFCLK as a test/internal path, not for production jitter).
-- Extra VIO: in38 = edge count of the MMCM output (expect 156.25/200 of
-- BC26's count), in39 = mmcm_locked, in40 = ctl_lock (= lock bit 2*CTL_Q;
-- 14 for CTL_Q 7).
-- 2026-11-04: CTL_Q is a generic.  Build b4 uses CTL_Q = 2 (GTYE4_COMMON_X0Y2,
-- bank 126, SLR0; jc_sysmon_probe read this quad's AVCC 0.926 V and AVTT
-- 1.243 V, while every SLR1 GT rail it tried read ~0), with u_mmcm LOCed at MMCM_X0Y2 (clock region X4Y2, the same
-- row as the quad's X0Y2) by the build script.  For CTL_Q = 2 the control
-- quad's REFCLK0 pin is index 4 (AD38) and LED_C (lock bit 4) shows the
-- control's QPLL0 lock instead of AD38's.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
library unisim; use unisim.vcomponents.all;

entity jc_qpll_census is
  -- CTL_Q: the positive-control quad (0..7 = bank 124+q, 8..15 = bank 224+q-8).
  -- 7 = bank 131 (build b3), 2 = bank 126 (build b4, SLR0).
  generic ( GATE_LOG2 : positive := 22; POR_LOG2 : positive := 8;
            CTL_Q : natural range 0 to 15 := 7 );
  port (
    refclk_p, refclk_n : in  std_logic_vector(31 downto 0);
    sysclk_clk_p, sysclk_clk_n : in std_logic;
    err_vccint : in  std_logic;
    fan_ctl    : out std_logic;
    LED_A, LED_B, LED_C, LED_D : out std_logic );
end entity;

architecture rtl of jc_qpll_census is
  constant NREF : positive := 32;
  constant NC   : positive := NREF + 2;   -- + BC26, + the MMCM output
  signal cfgmclk, mclk, sys_i, sclk : std_logic;
  signal clk_v : std_logic_vector(NC-1 downto 0);
  signal refo  : std_logic_vector(NREF-1 downto 0);
  type cnt_arr is array (0 to NC-1) of unsigned(31 downto 0);
  signal cnt : cnt_arr := (others => (others => '0'));
  signal gcnt : unsigned(GATE_LOG2 downto 0) := (others => '0');
  signal gate : std_logic := '0';
  signal seq  : unsigned(15 downto 0) := (others => '0');
  signal blink : unsigned(25 downto 0) := (others => '0');
  signal por_cnt : unsigned(POR_LOG2 downto 0) := (others => '0');
  signal por  : std_logic := '1';
  signal vio_rst : std_logic_vector(0 downto 0);
  attribute ASYNC_REG : string;
  signal qrst : std_logic := '1';
  signal mm_fb, mm_fbg, mm_o0, ctl_clk, mm_locked : std_logic;
  signal mm_lk_s1, mm_lk_s2 : std_logic := '0';
  attribute ASYNC_REG of mm_lk_s1, mm_lk_s2 : signal is "TRUE";
  -- bit 2*q + pll
  signal lock_a, lost_a : std_logic_vector(NREF-1 downto 0);
  signal lock_s1, lock_s2, lost_s1, lost_s2 : std_logic_vector(NREF-1 downto 0) := (others => '0');
  signal seen, drop : std_logic_vector(NREF-1 downto 0) := (others => '0');
  attribute ASYNC_REG of lock_s1, lock_s2, lost_s1, lost_s2 : signal is "TRUE";

  component vio_qpll
    port ( clk : in std_logic;
           probe_in0, probe_in1, probe_in2, probe_in3, probe_in4, probe_in5,
           probe_in6, probe_in7, probe_in8, probe_in9, probe_in10, probe_in11,
           probe_in12, probe_in13, probe_in14, probe_in15, probe_in16,
           probe_in17, probe_in18, probe_in19, probe_in20, probe_in21,
           probe_in22, probe_in23, probe_in24, probe_in25, probe_in26,
           probe_in27, probe_in28, probe_in29, probe_in30, probe_in31,
           probe_in32 : in std_logic_vector(31 downto 0);
           probe_in33 : in std_logic_vector(15 downto 0);
           probe_in34, probe_in35, probe_in36 : in std_logic_vector(31 downto 0);
           probe_in37 : in std_logic_vector(1 downto 0);
           probe_in38 : in std_logic_vector(31 downto 0);
           probe_in39, probe_in40 : in std_logic_vector(0 downto 0);
           probe_out0 : out std_logic_vector(0 downto 0) );
  end component;
  function slv(u : unsigned) return std_logic_vector is
  begin return std_logic_vector(u); end function;
begin
  fan_ctl <= '1';

  u_start : STARTUPE3
    port map ( CFGCLK => open, CFGMCLK => cfgmclk, EOS => open, PREQ => open,
               DI => open, DO => "0000", DTS => "1111", FCSBO => '0',
               FCSBTS => '1', GSR => '0', GTS => '0', KEYCLEARB => '1',
               PACK => '0', USRCCLKO => '0', USRCCLKTS => '1',
               USRDONEO => '1', USRDONETS => '1' );
  u_mbuf : BUFG port map ( I => cfgmclk, O => mclk );

  u_sib : IBUFDS port map ( I => sysclk_clk_p, IB => sysclk_clk_n, O => sys_i );
  u_sbg : BUFG   port map ( I => sys_i, O => sclk );
  clk_v(NREF) <= sclk;

  -- the positive control's reference: 200 * 25 / 4 / 8 = 156.25 MHz
  u_mmcm : MMCME4_BASE
    generic map ( CLKIN1_PERIOD => 5.000, DIVCLK_DIVIDE => 4,
                  CLKFBOUT_MULT_F => 25.000, CLKOUT0_DIVIDE_F => 8.000 )
    port map ( CLKIN1 => sclk, CLKFBIN => mm_fbg, CLKFBOUT => mm_fb,
               CLKFBOUTB => open, CLKOUT0 => mm_o0, CLKOUT0B => open,
               CLKOUT1 => open, CLKOUT1B => open, CLKOUT2 => open,
               CLKOUT2B => open, CLKOUT3 => open, CLKOUT3B => open,
               CLKOUT4 => open, CLKOUT5 => open, CLKOUT6 => open,
               LOCKED => mm_locked, PWRDWN => '0', RST => por );
  u_fbg  : BUFG port map ( I => mm_fb, O => mm_fbg );
  u_cbg  : BUFG port map ( I => mm_o0, O => ctl_clk );
  clk_v(NREF + 1) <= ctl_clk;

  gen_ref : for i in 0 to NREF-1 generate
    signal od2 : std_logic;
  begin
    u_ib : IBUFDS_GTE4
      generic map ( REFCLK_EN_TX_PATH => '0', REFCLK_HROW_CK_SEL => "00",
                    REFCLK_ICNTL_RX => "00" )
      port map ( I => refclk_p(i), IB => refclk_n(i), CEB => '0',
                 O => refo(i), ODIV2 => od2 );
    u_bg : BUFG_GT
      port map ( I => od2, O => clk_v(i), CE => '1', CEMASK => '0',
                 CLR => '0', CLRMASK => '0', DIV => "000" );
  end generate;

  gen_q : for q in 0 to 15 generate
    -- the control quad takes GTGREFCLK0 (sel "111"); every other quad REFCLK0
    constant IS_CTL : boolean := (q = CTL_Q);
    signal ctl_clk_q, refclk00_q : std_logic;
    function sel0(c : boolean) return std_logic_vector is
    begin if c then return "111"; else return "001"; end if; end function;
    constant sel0_q : std_logic_vector(2 downto 0) := sel0(IS_CTL);
  begin
    ctl_clk_q  <= ctl_clk when IS_CTL else '0';
    refclk00_q <= '0' when IS_CTL else refo(2*q);
    u_com : GTYE4_COMMON
      generic map (
        AEN_QPLL0_FBDIV        => '1',
        AEN_QPLL1_FBDIV        => '1',
        AEN_SDM0TOGGLE         => '0',
        AEN_SDM1TOGGLE         => '0',
        A_SDM0TOGGLE           => '0',
        A_SDM1DATA_HIGH        => "000000000",
        A_SDM1DATA_LOW         => "0000000000000000",
        A_SDM1TOGGLE           => '0',
        BIAS_CFG0              => "0000000000000000",
        BIAS_CFG1              => "0000000000000000",
        BIAS_CFG2              => "0000010100100100",
        BIAS_CFG3              => "0000000001000001",
        BIAS_CFG4              => "0000000000010000",
        BIAS_CFG_RSVD          => "0000000000000000",
        COMMON_CFG0            => "0000000000000000",
        COMMON_CFG1            => "0000000000000000",
        POR_CFG                => "0000000000000000",
        PPF0_CFG               => "0000011000000000",
        PPF1_CFG               => "0000011000000000",
        QPLL0CLKOUT_RATE       => "HALF",
        QPLL0_CFG0             => "0011001100011100",
        QPLL0_CFG1             => "1101000000111000",
        QPLL0_CFG1_G3          => "1101000000111000",
        QPLL0_CFG2             => "0000111111000000",
        QPLL0_CFG2_G3          => "0000111111000000",
        QPLL0_CFG3             => "0000000100100000",
        QPLL0_CFG4             => "0000000000000010",
        QPLL0_CP               => "0011111111",
        QPLL0_CP_G3            => "0000001111",
        QPLL0_FBDIV            => 66,
        QPLL0_FBDIV_G3         => 160,
        QPLL0_INIT_CFG0        => "0000001010110010",
        QPLL0_INIT_CFG1        => "00000000",
        QPLL0_LOCK_CFG         => "0010010111101000",
        QPLL0_LOCK_CFG_G3      => "0010010111101000",
        QPLL0_LPF              => "1000111111",
        QPLL0_LPF_G3           => "0111010101",
        QPLL0_PCI_EN           => '0',
        QPLL0_RATE_SW_USE_DRP  => '1',
        QPLL0_REFCLK_DIV       => 1,
        QPLL0_SDM_CFG0         => "0000000010000000",
        QPLL0_SDM_CFG1         => "0000000000000000",
        QPLL0_SDM_CFG2         => "0000000000000000",
        QPLL1CLKOUT_RATE       => "HALF",
        QPLL1_CFG0             => "0011001100011100",
        QPLL1_CFG1             => "1101000000111000",
        QPLL1_CFG1_G3          => "1101000000111000",
        QPLL1_CFG2             => "0000111111000011",
        QPLL1_CFG2_G3          => "0000111111000011",
        QPLL1_CFG3             => "0000000100100000",
        QPLL1_CFG4             => "0000000000000010",
        QPLL1_CP               => "0011111111",
        QPLL1_CP_G3            => "0001111111",
        QPLL1_FBDIV            => 66,
        QPLL1_FBDIV_G3         => 80,
        QPLL1_INIT_CFG0        => "0000001010110010",
        QPLL1_INIT_CFG1        => "00000000",
        QPLL1_LOCK_CFG         => "0010010111101000",
        QPLL1_LOCK_CFG_G3      => "0010010111101000",
        QPLL1_LPF              => "1000011111",
        QPLL1_LPF_G3           => "0111010100",
        QPLL1_PCI_EN           => '0',
        QPLL1_RATE_SW_USE_DRP  => '1',
        QPLL1_REFCLK_DIV       => 1,
        QPLL1_SDM_CFG0         => "0000000010000000",
        QPLL1_SDM_CFG1         => "0000000000000000",
        QPLL1_SDM_CFG2         => "0000000000000000",
        RSVD_ATTR0             => "0000000000000000",
        RSVD_ATTR1             => "0000000000000000",
        RSVD_ATTR2             => "0000000000000000",
        RSVD_ATTR3             => "0000000000000000",
        RXRECCLKOUT0_SEL       => "00",
        RXRECCLKOUT1_SEL       => "00",
        SARC_ENB               => '0',
        SARC_SEL               => '0',
        SDM0INITSEED0_0        => "0000000100010001",
        SDM0INITSEED0_1        => "000010001",
        SDM1INITSEED0_0        => "0000000100010001",
        SDM1INITSEED0_1        => "000010001",
        SIM_DEVICE             => "ULTRASCALE_PLUS",
        SIM_MODE               => "FAST",
        SIM_RESET_SPEEDUP      => "TRUE",
        UB_CFG0                => "0000000000000000",
        UB_CFG1                => "0000000000000000",
        UB_CFG2                => "0000000000000000",
        UB_CFG3                => "0000000000000000",
        UB_CFG4                => "0000000000000000",
        UB_CFG5                => "0000010000000000",
        UB_CFG6                => "0000000000000000"

      )
      port map (
        DRPDO => open, DRPRDY => open,
        PMARSVDOUT0 => open, PMARSVDOUT1 => open,
        QPLL0FBCLKLOST => open, QPLL0LOCK => lock_a(2*q),
        QPLL0OUTCLK => open, QPLL0OUTREFCLK => open,
        QPLL0REFCLKLOST => lost_a(2*q),
        QPLL1FBCLKLOST => open, QPLL1LOCK => lock_a(2*q+1),
        QPLL1OUTCLK => open, QPLL1OUTREFCLK => open,
        QPLL1REFCLKLOST => lost_a(2*q+1),
        QPLLDMONITOR0 => open, QPLLDMONITOR1 => open,
        REFCLKOUTMONITOR0 => open, REFCLKOUTMONITOR1 => open,
        RXRECCLK0SEL => open, RXRECCLK1SEL => open,
        SDM0FINALOUT => open, SDM0TESTDATA => open,
        SDM1FINALOUT => open, SDM1TESTDATA => open,
        UBDADDR => open, UBDEN => open, UBDI => open, UBDWE => open,
        UBMDMTDO => open, UBRSVDOUT => open, UBTXUART => open,
        BGBYPASSB => '1', BGMONITORENB => '1', BGPDB => '1',
        BGRCALOVRD => "10000", BGRCALOVRDENB => '1',
        DRPADDR => (others => '0'), DRPCLK => sclk, DRPDI => (others => '0'),
        DRPEN => '0', DRPWE => '0',
        GTGREFCLK0 => ctl_clk_q, GTGREFCLK1 => '0',
        GTNORTHREFCLK00 => '0', GTNORTHREFCLK01 => '0',
        GTNORTHREFCLK10 => '0', GTNORTHREFCLK11 => '0',
        GTREFCLK00 => refclk00_q, GTREFCLK01 => '0',
        GTREFCLK10 => '0', GTREFCLK11 => refo(2*q+1),
        GTSOUTHREFCLK00 => '0', GTSOUTHREFCLK01 => '0',
        GTSOUTHREFCLK10 => '0', GTSOUTHREFCLK11 => '0',
        PCIERATEQPLL0 => "000", PCIERATEQPLL1 => "000",
        PMARSVD0 => (others => '0'), PMARSVD1 => (others => '0'),
        QPLL0CLKRSVD0 => '0', QPLL0CLKRSVD1 => '0',
        QPLL0FBDIV => (others => '0'), QPLL0LOCKDETCLK => sclk,
        QPLL0LOCKEN => '1', QPLL0PD => '0', QPLL0REFCLKSEL => sel0_q,
        QPLL0RESET => qrst,
        QPLL1CLKRSVD0 => '0', QPLL1CLKRSVD1 => '0',
        QPLL1FBDIV => (others => '0'), QPLL1LOCKDETCLK => sclk,
        QPLL1LOCKEN => '1', QPLL1PD => '0', QPLL1REFCLKSEL => "010",
        QPLL1RESET => qrst,
        QPLLRSVD1 => (others => '0'), QPLLRSVD2 => (others => '0'),
        QPLLRSVD3 => (others => '0'), QPLLRSVD4 => (others => '0'),
        RCALENB => '1',
        SDM0DATA => (others => '0'), SDM0RESET => '0', SDM0TOGGLE => '0',
        SDM0WIDTH => "00",
        SDM1DATA => (others => '0'), SDM1RESET => '0', SDM1TOGGLE => '0',
        SDM1WIDTH => "00",
        UBCFGSTREAMEN => '0', UBDO => (others => '0'), UBDRDY => '0',
        UBENABLE => '0', UBGPI => "00", UBINTR => "00", UBIOLMBRST => '0',
        UBMBRST => '0', UBMDMCAPTURE => '0', UBMDMDBGRST => '0',
        UBMDMDBGUPDATE => '0', UBMDMREGEN => "0000", UBMDMSHIFT => '0',
        UBMDMSYSRST => '0', UBMDMTCK => '0', UBMDMTDI => '0' );
  end generate;

  -- the gate, the power-on reset, the lock synchronisers: all CFGMCLK
  process(mclk) begin
    if rising_edge(mclk) then
      gcnt  <= gcnt + 1;
      if gcnt(GATE_LOG2 - 1 downto 0) = 0 and gcnt(GATE_LOG2) = '1' then
        seq <= seq + 1;             -- entering the low (stable) half
      end if;
      gate  <= not gcnt(GATE_LOG2);
      blink <= blink + 1;
      if por_cnt(POR_LOG2) = '0' then por_cnt <= por_cnt + 1; end if;
      por  <= not por_cnt(POR_LOG2);
      qrst <= por or vio_rst(0);
      mm_lk_s1 <= mm_locked; mm_lk_s2 <= mm_lk_s1;
      lock_s1 <= lock_a; lock_s2 <= lock_s1;
      lost_s1 <= lost_a; lost_s2 <= lost_s1;
      if qrst = '1' then
        seen <= (others => '0'); drop <= (others => '0');
      else
        seen <= seen or lock_s2;
        drop <= drop or (seen and not lock_s2);
      end if;
    end if;
  end process;

  gen_cnt : for k in 0 to NC-1 generate
    signal g1, g2, g3 : std_logic := '0';
    attribute ASYNC_REG of g1, g2 : signal is "TRUE";
  begin
    process(clk_v(k)) begin
      if rising_edge(clk_v(k)) then
        g1 <= gate; g2 <= g1; g3 <= g2;
        if g2 = '1' and g3 = '0' then
          cnt(k) <= (others => '0');
        elsif g2 = '1' then
          cnt(k) <= cnt(k) + 1;
        end if;
      end if;
    end process;
  end generate;

  u_vio : vio_qpll
    port map ( clk => mclk,
               probe_in0 => slv(cnt(0)),   probe_in1 => slv(cnt(1)),
               probe_in2 => slv(cnt(2)),   probe_in3 => slv(cnt(3)),
               probe_in4 => slv(cnt(4)),   probe_in5 => slv(cnt(5)),
               probe_in6 => slv(cnt(6)),   probe_in7 => slv(cnt(7)),
               probe_in8 => slv(cnt(8)),   probe_in9 => slv(cnt(9)),
               probe_in10 => slv(cnt(10)), probe_in11 => slv(cnt(11)),
               probe_in12 => slv(cnt(12)), probe_in13 => slv(cnt(13)),
               probe_in14 => slv(cnt(14)), probe_in15 => slv(cnt(15)),
               probe_in16 => slv(cnt(16)), probe_in17 => slv(cnt(17)),
               probe_in18 => slv(cnt(18)), probe_in19 => slv(cnt(19)),
               probe_in20 => slv(cnt(20)), probe_in21 => slv(cnt(21)),
               probe_in22 => slv(cnt(22)), probe_in23 => slv(cnt(23)),
               probe_in24 => slv(cnt(24)), probe_in25 => slv(cnt(25)),
               probe_in26 => slv(cnt(26)), probe_in27 => slv(cnt(27)),
               probe_in28 => slv(cnt(28)), probe_in29 => slv(cnt(29)),
               probe_in30 => slv(cnt(30)), probe_in31 => slv(cnt(31)),
               probe_in32 => slv(cnt(32)),
               probe_in33 => slv(seq),
               probe_in34 => lock_s2, probe_in35 => lost_s2, probe_in36 => drop,
               probe_in37 => err_vccint & gate,
               probe_in38 => slv(cnt(NREF + 1)),
               probe_in39(0) => mm_lk_s2, probe_in40(0) => lock_s2(2*CTL_Q),
               probe_out0 => vio_rst );

  LED_A <= blink(25);                  -- CFGMCLK alive: the bitstream is running
  LED_B <= '1' when cnt(NREF) > 1000 else '0';   -- sysclk (BC26) alive
  LED_C <= lock_s2(4);                 -- QPLL0 of quad 126 locked (AD38 refclk; the control if CTL_Q = 2)
  LED_D <= not err_vccint;             -- the PMIC's fault line (open collector, low = fault)
end architecture;
