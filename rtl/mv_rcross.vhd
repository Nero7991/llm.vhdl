-- rtl/mv_rcross.vhd -- the result words' crossing from aclk_a to clk_core (spec 2.3).
-- An async FIFO (rtl/async_fifo.vhd, gray pointers) and a REGISTERED almost-full for the
-- chain's tail stage: w_afull is '1' while the FIFO's conservative write-side level is at
-- or above DEPTH - 6, which leaves 6 levels of threshold slack plus the 4 levels of
-- conservatism w_level already carries (OUT_MARGIN + 1, see rtl/async_fifo.vhd's own
-- REGISTERED LEVEL header) for whatever the chain's tail stage can still send after
-- seeing it.  A write with the FIFO full is a failure assertion, never a drop.
library ieee;
use ieee.std_logic_1164.all;

entity mv_rcross is
  generic(
    W     : positive := 97;
    DEPTH : positive := 16     -- power of two
  );
  port(
    wclk, wrst : in  std_logic;
    w_v        : in  std_logic;
    w_d        : in  std_logic_vector(W-1 downto 0);
    w_afull    : out std_logic;
    rclk, rrst : in  std_logic;
    q_valid    : out std_logic;
    q_data     : out std_logic_vector(W-1 downto 0);
    q_ready    : in  std_logic
  );
end entity;

architecture rtl of mv_rcross is
  signal w_ready : std_logic;
  signal w_level : integer range 0 to 2*DEPTH + 3;
  signal af : std_logic := '1';
begin
  q : entity work.async_fifo
    generic map(W => W, DEPTH => DEPTH, OUT_MARGIN => 3, FAST_POP => true)
    port map(wclk => wclk, wrst => wrst, w_valid => w_v, w_data => w_d, w_ready => w_ready,
             w_level => w_level, clr => '0', clr_done => open,
             rclk => rclk, rrst => rrst, q_valid => q_valid, q_data => q_data,
             q_ready => q_ready);
  p : process(wclk)
  begin
    if rising_edge(wclk) then
      if wrst = '1' then af <= '1';
      elsif w_level >= DEPTH - 6 then af <= '1';
      else af <= '0'; end if;
      assert wrst = '1' or not (w_v = '1' and w_ready = '0')
        report "mv_rcross: a result word reached a full crossing FIFO" severity failure;
    end if;
  end process;
  w_afull <= af;
end architecture;
