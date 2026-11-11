-- hw/jc/link/rtl/jc_gtg_clk.vhd -- 156.25 MHz for the Aurora QPLL's GTGREFCLK0, from the
-- 200 MHz board clock (spec 2026-11-04 section 1b.2: the IBERT G path, which locked on both
-- dies). Parameters copied from jc_qpll_census.vhd u_mmcm (b4) as IBERT G did: BUFG of the
-- IBUFDS output, MMCME4_BASE 200 * 25 / 4 / 8 = 156.25 (1250 MHz VCO), feedback through a
-- BUFG, output BUFG. RST is a power-on reset of 2**POR_LOG2 sclk cycles (census POR_LOG2 8;
-- IBERT G counted CFGMCLK, which the card's STARTUPE3 owner does not export). The XDC puts
-- the MMCM at MMCM_X0Y2 and CLOCK_DEDICATED_ROUTE BACKBONE on the BUFG -> MMCM net.
-- init_clk (CLKOUT1, 1250 / INIT_DIV MHz, BUFG) is the Aurora core's init_clk: the IP bounds
-- C_INIT_CLK by line_rate/64 (MEASURED 2026-11-10, IP_Flow 19-3488), so the 200 MHz sclk cannot
-- serve. INIT_DIV 10 -> 125 MHz (10.3125 Gb/s), 80 -> 15.625 MHz (1.25 Gb/s); aurora_cfg.tcl
-- jc_init_div gives the value per rate and C_INIT_CLK must match it.
-- DONT_TOUCH keeps the load-less gtg_clk BUFG until the ECO connects it (IBERT G item 1).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library unisim;
use unisim.vcomponents.all;

entity jc_gtg_clk is
  generic(POR_LOG2 : positive := 8; INIT_DIV : positive := 10);
  port(
    sys_i    : in  std_logic;    -- the board clock's IBUFDS output (200 MHz)
    sclk     : out std_logic;    -- BUFG of sys_i: the 200 MHz fabric clock
    gtg_clk  : out std_logic;    -- 156.25 MHz, to GTGREFCLK0 by the ECO
    init_clk : out std_logic;    -- 1250 / INIT_DIV MHz: init_clk of the Aurora core
    locked   : out std_logic);
end entity;

architecture rtl of jc_gtg_clk is
  signal sclk_i, fb, fbg, o0, o1, gclk : std_logic;
  signal por_cnt : unsigned(POR_LOG2 downto 0) := (others => '0');
  signal por : std_logic := '1';
  attribute DONT_TOUCH : string;
  attribute DONT_TOUCH of u_sbg, u_mmcm, u_gbg : label is "TRUE";
  attribute DONT_TOUCH of gclk : signal is "TRUE";
begin
  u_sbg : BUFG port map(I => sys_i, O => sclk_i);
  sclk <= sclk_i;
  u_mmcm : MMCME4_BASE
    generic map(CLKIN1_PERIOD => 5.000, DIVCLK_DIVIDE => 4,
                CLKFBOUT_MULT_F => 25.000, CLKOUT0_DIVIDE_F => 8.000,
                CLKOUT1_DIVIDE => INIT_DIV)
    port map(CLKIN1 => sclk_i, CLKFBIN => fbg, CLKFBOUT => fb, CLKFBOUTB => open,
             CLKOUT0 => o0, CLKOUT0B => open, CLKOUT1 => o1, CLKOUT1B => open,
             CLKOUT2 => open, CLKOUT2B => open, CLKOUT3 => open, CLKOUT3B => open,
             CLKOUT4 => open, CLKOUT5 => open, CLKOUT6 => open,
             LOCKED => locked, PWRDWN => '0', RST => por);
  u_fbg : BUFG port map(I => fb, O => fbg);
  u_gbg : BUFG port map(I => o0, O => gclk);
  gtg_clk <= gclk;
  u_ibg : BUFG port map(I => o1, O => init_clk);
  process(sclk_i)
  begin
    if rising_edge(sclk_i) then
      if por_cnt(POR_LOG2) = '0' then por_cnt <= por_cnt + 1; end if;
      por <= not por_cnt(POR_LOG2);
    end if;
  end process;
end architecture;
