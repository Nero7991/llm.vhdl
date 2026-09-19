-- rtl/stream_fifo.vhd -- synchronous-read FIFO with a first-word-fall-through
-- output stage.
--
-- WHY NOT A COMBINATIONAL READ.  Spec 7.7 budgets 8 KB per weight port
-- (512 beats x 128 b).  A FIFO whose output is `mem(rp)` read combinationally
-- is distributed RAM, so those 65,536 bits become ~1,024 SLICEM LUTs per port
-- and ~4,096 across the four weight ports -- against a budget (7.9) that has
-- the whole weight FIFO path at 8 BRAM36 and the entire design at ~6-7K LUT.
-- The memory read here is therefore REGISTERED, which is what infers BRAM, and
-- a 2-entry output stage hides the resulting cycle of latency so the interface
-- is still plain first-word-fall-through: q_valid means q_data is valid NOW.
--
-- Sustains one beat per cycle in and one out simultaneously.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity stream_fifo is
  generic(W : positive := 128; DEPTH : positive := 512);
  port(
    clk, rst : in  std_logic;
    flush    : in  std_logic;      -- synchronous, drops everything (7.7)

    i_valid  : in  std_logic;
    i_data   : in  std_logic_vector(W-1 downto 0);
    i_ready  : out std_logic;

    q_valid  : out std_logic;
    q_data   : out std_logic_vector(W-1 downto 0);
    q_ready  : in  std_logic;

    -- occupancy INCLUDING the output stage, for the AR-issue throttle
    -- Defaulted, so the formal's driving value at delta 0 is 0 and not
    -- integer'low: rtl/axi_rd_port.vhd copies this port into a range-
    -- constrained signal and the copy runs before the first driving value
    -- lands (2026-09-19).
    level    : out integer := 0
  );
end entity;

architecture rtl of stream_fifo is
  type mem_t is array(0 to DEPTH-1) of std_logic_vector(W-1 downto 0);
  signal mem : mem_t;
  attribute ram_style : string;
  attribute ram_style of mem : signal is "block";

  signal wp, rp : integer range 0 to DEPTH-1 := 0;
  signal mcnt   : integer range 0 to DEPTH   := 0;   -- beats in the memory

  signal mem_q   : std_logic_vector(W-1 downto 0) := (others => '0');
  signal mem_q_v : std_logic := '0';                 -- a read lands next cycle

  -- 2-entry output stage
  type ob_t is array(0 to 1) of std_logic_vector(W-1 downto 0);
  signal ob      : ob_t := (others => (others => '0'));
  signal ob_wp, ob_rp : integer range 0 to 1 := 0;
  signal ocnt    : integer range 0 to 2 := 0;

  signal do_rd    : std_logic;
  signal inflight : integer range 0 to 1;
begin
  inflight <= 1 when mem_q_v = '1' else 0;
  -- issue a memory read whenever the output stage has room for the beat that
  -- read will produce, counting the one already in flight
  do_rd <= '1' when mcnt > 0 and (ocnt + inflight) < 2 else '0';

  i_ready <= '1' when mcnt < DEPTH else '0';
  q_valid <= '1' when ocnt > 0 else '0';
  q_data  <= ob(ob_rp);
  level   <= mcnt + ocnt + inflight;

  process(clk)
    variable m, o : integer;
  begin
    if rising_edge(clk) then
      if rst = '1' or flush = '1' then
        wp <= 0; rp <= 0; mcnt <= 0;
        ob_wp <= 0; ob_rp <= 0; ocnt <= 0; mem_q_v <= '0';
      else
        m := mcnt; o := ocnt;

        if i_valid = '1' and mcnt < DEPTH then
          mem(wp) <= i_data;
          wp <= (wp + 1) mod DEPTH;
          m  := m + 1;
        end if;

        -- registered memory read: this is what makes it BRAM
        mem_q   <= mem(rp);
        mem_q_v <= do_rd;
        if do_rd = '1' then
          rp <= (rp + 1) mod DEPTH;
          m  := m - 1;
        end if;

        if mem_q_v = '1' then
          ob(ob_wp) <= mem_q;
          ob_wp <= (ob_wp + 1) mod 2;
          o := o + 1;
        end if;

        if ocnt > 0 and q_ready = '1' then
          ob_rp <= (ob_rp + 1) mod 2;
          o := o - 1;
        end if;

        mcnt <= m; ocnt <= o;
      end if;
    end if;
  end process;
end architecture;
