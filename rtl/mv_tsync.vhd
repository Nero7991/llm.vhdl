-- rtl/mv_tsync.vhd -- one-cycle pulse from one clock domain to another, by toggle.
-- The source flips a toggle on each pulse; the destination samples it through two
-- ASYNC_REG flops and a third, and pulses on the change.  Pulses must be at least three
-- destination cycles apart (A_JOB start is: the back end cannot start a second job
-- before the first has returned all its results).  With equal clocks it is a 3-cycle
-- delay, which is what A_CLK_SPLIT = false gets.
library ieee;
use ieee.std_logic_1164.all;

entity mv_tsync is
  port(
    sclk, srst : in  std_logic;
    s_pulse    : in  std_logic;
    dclk, drst : in  std_logic;
    d_pulse    : out std_logic
  );
end entity;

architecture rtl of mv_tsync is
  signal tog : std_logic := '0';
  signal s1, s2, s3 : std_logic := '0';
  attribute async_reg : string;
  attribute async_reg of s1 : signal is "TRUE";
  attribute async_reg of s2 : signal is "TRUE";
begin
  src : process(sclk)
  begin
    if rising_edge(sclk) then
      if srst = '1' then tog <= '0';
      elsif s_pulse = '1' then tog <= not tog;
      end if;
    end if;
  end process;

  dst : process(dclk)
  begin
    if rising_edge(dclk) then
      s1 <= tog; s2 <= s1;
      if drst = '1' then s3 <= s2; d_pulse <= '0';
      else s3 <= s2; d_pulse <= s2 xor s3;
      end if;
    end if;
  end process;
end architecture;
