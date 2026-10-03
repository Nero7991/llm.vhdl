-- jc_axiprobe -- JTAG-to-AXI master -> AXI BRAM, clocked by CFGMCLK.
-- For measuring real JTAG-AXI write bandwidth over CoE/XVC on the Jungle Cat.
-- No external clock/GTY needed: CFGMCLK (STARTUPE3, ~50 MHz) runs the fabric;
-- the JTAG-AXI path is transport-bound, not fabric-bound, so the clock rate is
-- immaterial to the number.  LED/fan pins mirror hw/jc/census/jc_census.xdc.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
library unisim; use unisim.vcomponents.all;

entity jc_axiprobe is
  port ( LED_A, LED_B, LED_C, LED_D, fan_ctl : out std_logic );
end entity;

architecture rtl of jc_axiprobe is
  signal cfgmclk, mclk : std_logic;
  signal rstcnt : unsigned(7 downto 0) := (others => '0');
  signal rstn   : std_logic := '0';
  signal blink  : unsigned(25 downto 0) := (others => '0');
  component axiprobe_wrapper is
    port ( aresetn : in std_logic; mclk : in std_logic );
  end component;
begin
  u_start : STARTUPE3
    port map ( CFGCLK => open, CFGMCLK => cfgmclk, EOS => open, PREQ => open,
               DI => open, DO => "0000", DTS => "1111", FCSBO => '0',
               FCSBTS => '1', GSR => '0', GTS => '0', KEYCLEARB => '1',
               PACK => '0', USRCCLKO => '0', USRCCLKTS => '1',
               USRDONEO => '1', USRDONETS => '1' );
  u_mbuf : BUFG port map ( I => cfgmclk, O => mclk );

  process(mclk) begin
    if rising_edge(mclk) then
      if rstcnt < 255 then rstcnt <= rstcnt + 1; rstn <= '0';
      else rstn <= '1'; end if;
      blink <= blink + 1;
    end if;
  end process;

  u_bd : axiprobe_wrapper port map ( aresetn => rstn, mclk => mclk );

  fan_ctl <= '1';
  LED_A <= '1';            -- configured
  LED_B <= rstn;           -- AXI out of reset
  LED_C <= '0';
  LED_D <= blink(25);      -- heartbeat (~1.5 Hz at 50 MHz)
end architecture;
