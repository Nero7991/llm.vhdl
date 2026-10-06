-- hw/jc/pinfinder/pinfinder_top.vhd -- 2026-10-05. Jungle Cat pin-finder.
--
-- NOT A DESIGN: eleven independent square-wave generators so Oren can probe
-- empty carrier footprints with a multimeter in frequency mode and match a
-- reading back to a pin by its frequency. Two bitstreams (variant A: 1..11
-- kHz, variant B: 12..22 kHz on the same 11 outputs in the same order) let a
-- net shared between two slots show up as two different readings instead of
-- one that could be either side.
--
-- Clock: the module's own 200 MHz LVDS oscillator on BC26 (sysclk_clk_p/n,
-- IBUFDS + BUFG, same shape as hw/jc/census/jc_census.vhd). The N pin is a
-- build-time fact (DIFF_PAIR_PIN query), not a guess: see build_pinfinder.tcl.
--
-- Outputs, fixed order, all LVCMOS18 / DRIVE 4 / SLEW SLOW:
--   0 out_g10_p   (G10, the sysclk_ext P pin, repurposed single-ended)
--   1 out_g10_n   (G10's diff-pair partner, repurposed single-ended)
--   2 out_f13_p   (F13, the sysclk_ext2 P pin, repurposed single-ended)
--   3 out_f13_n   (F13's diff-pair partner, repurposed single-ended)
--   4 LED_A, 5 LED_B, 6 LED_C, 7 LED_D
--   8 LED_RGB_R, 9 LED_RGB_G, 10 LED_RGB_B
--
-- Every output toggles its own free-running counter at DIVn: period = 2*DIVn
-- clock cycles of the 200 MHz clock (5 ns), so frequency = 100_000_000 / DIVn
-- Hz. The defaults below are variant A; build_pinfinder.tcl overrides all
-- eleven generics for variant B via `set_property generic`. hw/jc/pinfinder/
-- README.md has the resolved table for both variants.
--
-- H12 (jcm_sync, shared across modules on the carrier) and every other pin
-- (SPI/config, UART, I2C, fan, err_vccint) are left unused: Vivado default.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
library unisim; use unisim.vcomponents.all;

entity pinfinder_top is
  generic (
    DIV0  : positive := 100000;  -- A: 1000.0000 Hz
    DIV1  : positive :=  50000;  -- A: 2000.0000 Hz
    DIV2  : positive :=  33333;  -- A: 3000.0300 Hz
    DIV3  : positive :=  25000;  -- A: 4000.0000 Hz
    DIV4  : positive :=  20000;  -- A: 5000.0000 Hz
    DIV5  : positive :=  16667;  -- A: 5999.8800 Hz
    DIV6  : positive :=  14286;  -- A: 6999.8600 Hz
    DIV7  : positive :=  12500;  -- A: 8000.0000 Hz
    DIV8  : positive :=  11111;  -- A: 9000.0900 Hz
    DIV9  : positive :=  10000;  -- A: 10000.0000 Hz
    DIV10 : positive :=   9091   -- A: 10999.8900 Hz
  );
  port (
    sysclk_clk_p : in  std_logic;
    sysclk_clk_n : in  std_logic;
    out_g10_p    : out std_logic;
    out_g10_n    : out std_logic;
    out_f13_p    : out std_logic;
    out_f13_n    : out std_logic;
    LED_A        : out std_logic;
    LED_B        : out std_logic;
    LED_C        : out std_logic;
    LED_D        : out std_logic;
    LED_RGB_R    : out std_logic;
    LED_RGB_G    : out std_logic;
    LED_RGB_B    : out std_logic
  );
end entity pinfinder_top;

architecture rtl of pinfinder_top is
  type div_arr_t is array (0 to 10) of positive;
  constant DIVS : div_arr_t := (DIV0, DIV1, DIV2, DIV3, DIV4, DIV5, DIV6, DIV7,
                                 DIV8, DIV9, DIV10);
  signal ibuf_o, mclk : std_logic;
  signal sq : std_logic_vector(0 to 10);
begin
  u_ibuf : IBUFDS port map ( I => sysclk_clk_p, IB => sysclk_clk_n, O => ibuf_o );
  u_bufg : BUFG   port map ( I => ibuf_o, O => mclk );

  gen_sq : for i in 0 to 10 generate
    signal cnt : unsigned(17 downto 0) := (others => '0');
    signal q   : std_logic := '0';
  begin
    process(mclk) begin
      if rising_edge(mclk) then
        if cnt = to_unsigned(DIVS(i) - 1, cnt'length) then
          cnt <= (others => '0');
          q   <= not q;
        else
          cnt <= cnt + 1;
        end if;
      end if;
    end process;
    sq(i) <= q;
  end generate gen_sq;

  out_g10_p <= sq(0);
  out_g10_n <= sq(1);
  out_f13_p <= sq(2);
  out_f13_n <= sq(3);
  LED_A     <= sq(4);
  LED_B     <= sq(5);
  LED_C     <= sq(6);
  LED_D     <= sq(7);
  LED_RGB_R <= sq(8);
  LED_RGB_G <= sq(9);
  LED_RGB_B <= sq(10);
end architecture rtl;
