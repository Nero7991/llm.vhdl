-- hw/jc/census/jc_census.vhd -- 2026-09-27.  Jungle Cat bring-up, bitstream 1.
--
-- A CLOCK CENSUS, NOT A DESIGN.  The JCCL2-JCM35 XDC names the Aurora refclk
-- pin (AD38 = MGTREFCLK0P_126, MEASURED by a Vivado part query) and never its
-- frequency, and the IBERT that tests the carrier's slot-to-slot pairs needs
-- that frequency at IP generation.  So every GTY refclk input of quads 124-128
-- and the three LVDS system clocks each count their own edges over one gate
-- window timed by CFGMCLK (STARTUPE3, nominally 50 MHz, +-15%), and a VIO
-- shows the counts.  CFGMCLK's tolerance makes each count's absolute value
-- uncertain; the RATIOS between clocks are exact to the window, and those
-- identify standard frequencies (100, 125, 156.25, 161.1328125, 322.265625).
-- An input with no oscillator behind it counts 0 (or noise: read it twice).
--
-- It also drives the fan PWM pin high.  The XDC puts fan_ctl on an FPGA pin
-- with a PULLDOWN, so an unconfigured module may not spin its fan at all.
--
-- Protocol: gate is high for 2**GATE_LOG2 CFGMCLK cycles, then low for as
-- many.  Each domain synchronises the gate, clears on its rising edge and
-- counts while it is high, so its count is STABLE for the whole low half.
-- Read `seq` before and after the counts; equal seq and gate_o = '0' means a
-- clean read.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
library unisim; use unisim.vcomponents.all;

entity jc_census is
  generic ( GATE_LOG2 : positive := 22; NREF : positive := 10 );
  port (
    refclk_p, refclk_n : in  std_logic_vector(NREF-1 downto 0);
    sysclk_clk_p, sysclk_clk_n : in std_logic;
    sysclk_ext_clk_p, sysclk_ext_clk_n : in std_logic;
    sysclk_ext2_clk_p, sysclk_ext2_clk_n : in std_logic;
    err_vccint : in  std_logic;
    fan_ctl    : out std_logic;
    LED_A, LED_B, LED_C, LED_D : out std_logic );
end entity;

architecture rtl of jc_census is
  constant NC : positive := NREF + 3;
  signal cfgmclk, mclk : std_logic;
  signal clk_v : std_logic_vector(NC-1 downto 0);
  type cnt_arr is array (0 to NC-1) of unsigned(31 downto 0);
  signal cnt : cnt_arr := (others => (others => '0'));
  signal gcnt : unsigned(GATE_LOG2 downto 0) := (others => '0');
  signal gate : std_logic := '0';
  signal seq  : unsigned(15 downto 0) := (others => '0');
  signal blink : unsigned(25 downto 0) := (others => '0');

  component vio_census
    port ( clk : in std_logic;
           probe_in0, probe_in1, probe_in2, probe_in3, probe_in4, probe_in5,
           probe_in6, probe_in7, probe_in8, probe_in9, probe_in10, probe_in11,
           probe_in12 : in std_logic_vector(31 downto 0);
           probe_in13 : in std_logic_vector(15 downto 0);
           probe_in14 : in std_logic_vector(1 downto 0) );
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

  gen_ref : for i in 0 to NREF-1 generate
    signal od2 : std_logic;
  begin
    u_ib : IBUFDS_GTE4
      generic map ( REFCLK_EN_TX_PATH => '0', REFCLK_HROW_CK_SEL => "00",
                    REFCLK_ICNTL_RX => "00" )
      port map ( I => refclk_p(i), IB => refclk_n(i), CEB => '0',
                 O => open, ODIV2 => od2 );
    u_bg : BUFG_GT
      port map ( I => od2, O => clk_v(i), CE => '1', CEMASK => '0',
                 CLR => '0', CLRMASK => '0', DIV => "000" );
  end generate;

  gen_sys : for j in 0 to 2 generate
    signal ip, inn, o : std_logic;
  begin
    ip  <= sysclk_clk_p      when j = 0 else sysclk_ext_clk_p  when j = 1 else sysclk_ext2_clk_p;
    inn <= sysclk_clk_n      when j = 0 else sysclk_ext_clk_n  when j = 1 else sysclk_ext2_clk_n;
    u_ib : IBUFDS port map ( I => ip, IB => inn, O => o );
    u_bg : BUFG   port map ( I => o, O => clk_v(NREF + j) );
  end generate;

  -- the gate, in CFGMCLK
  process(mclk) begin
    if rising_edge(mclk) then
      gcnt  <= gcnt + 1;
      if gcnt(GATE_LOG2 - 1 downto 0) = 0 and gcnt(GATE_LOG2) = '1' then
        seq <= seq + 1;             -- entering the low (stable) half
      end if;
      gate  <= not gcnt(GATE_LOG2);
      blink <= blink + 1;
    end if;
  end process;

  gen_cnt : for k in 0 to NC-1 generate
    signal g1, g2, g3 : std_logic := '0';
    attribute ASYNC_REG : string;
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

  u_vio : vio_census
    port map ( clk => mclk,
               probe_in0 => slv(cnt(0)),  probe_in1 => slv(cnt(1)),
               probe_in2 => slv(cnt(2)),  probe_in3 => slv(cnt(3)),
               probe_in4 => slv(cnt(4)),  probe_in5 => slv(cnt(5)),
               probe_in6 => slv(cnt(6)),  probe_in7 => slv(cnt(7)),
               probe_in8 => slv(cnt(8)),  probe_in9 => slv(cnt(9)),
               probe_in10 => slv(cnt(10)), probe_in11 => slv(cnt(11)),
               probe_in12 => slv(cnt(12)),
               probe_in13 => slv(seq),
               probe_in14 => err_vccint & gate );

  LED_A <= blink(25);                  -- CFGMCLK alive: the bitstream is running
  -- "alive" is a count above 1000 in the last window (read across domains:
  -- a LED, so a torn read is harmless).  refclk index i is quad 124 + i/2,
  -- REFCLK(i mod 2), so AD38 = MGTREFCLK0_126 is index 4.
  LED_B <= '1' when cnt(NREF) > 1000 else '0';   -- sysclk (BC26) alive
  LED_C <= '1' when cnt(4) > 1000 else '0';      -- AD38, the Aurora refclk, alive
  LED_D <= not err_vccint;             -- the PMIC's fault line (open collector, low = fault)
end architecture;
