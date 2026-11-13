-- rtl/mv_lfifo.vhd -- a small first-word-fall-through FIFO in distributed RAM, one beat
-- per cycle in and out.  rtl/stream_fifo.vhd's structure at FAST_POP = true (registered
-- memory read, 2-entry output stage, the after-pop read-issue bound), with the memory in
-- LUTRAM: the a450 tile's 32-deep flit FIFO and 4-deep result FIFO would each waste a
-- BRAM36 (spec 2.2).  A separate entity, not a generic on stream_fifo, because a change
-- to stream_fifo's text re-keys every block rating that contains it.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mv_lfifo is
  generic(
    W     : positive := 64;
    DEPTH : positive := 32
  );
  port(
    clk, rst : in  std_logic;
    i_valid  : in  std_logic;
    i_data   : in  std_logic_vector(W-1 downto 0);
    i_ready  : out std_logic;
    q_valid  : out std_logic;
    q_data   : out std_logic_vector(W-1 downto 0);
    q_ready  : in  std_logic;
    level    : out integer := 0     -- memory + output stage + read in flight
  );
end entity;

architecture rtl of mv_lfifo is
  type mem_t is array(0 to DEPTH-1) of std_logic_vector(W-1 downto 0);
  signal mem : mem_t;
  attribute ram_style : string;
  attribute ram_style of mem : signal is "distributed";
  signal wp, rp : integer range 0 to DEPTH-1 := 0;
  signal mcnt   : integer range 0 to DEPTH := 0;
  signal mem_q  : std_logic_vector(W-1 downto 0) := (others => '0');
  signal mem_q_v : std_logic := '0';
  type ob_t is array(0 to 1) of std_logic_vector(W-1 downto 0);
  signal ob : ob_t := (others => (others => '0'));
  signal ob_wp, ob_rp : integer range 0 to 1 := 0;
  signal ocnt : integer range 0 to 2 := 0;
  signal do_rd : std_logic;
  signal inflight : integer range 0 to 1;
  signal after_e : integer range 0 to 3;
begin
  inflight <= 1 when mem_q_v = '1' else 0;
  -- the pop term is inlined, not a signal (stream_fifo.vhd records why: a delta-late
  -- pop makes the subtraction reach -1 in simulation)
  after_e <= ocnt + inflight - 1 when (ocnt > 0 and q_ready = '1') else ocnt + inflight;
  do_rd   <= '1' when mcnt > 0 and after_e < 2 else '0';
  i_ready <= '1' when mcnt < DEPTH else '0';
  q_valid <= '1' when ocnt > 0 else '0';
  q_data  <= ob(ob_rp);
  level   <= mcnt + ocnt + inflight;

  process(clk)
    variable m, o : integer;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        wp <= 0; rp <= 0; mcnt <= 0; ob_wp <= 0; ob_rp <= 0; ocnt <= 0; mem_q_v <= '0';
      else
        m := mcnt; o := ocnt;
        if i_valid = '1' and mcnt < DEPTH then
          mem(wp) <= i_data;
          wp <= (wp + 1) mod DEPTH;
          m := m + 1;
        end if;
        mem_q   <= mem(rp);
        mem_q_v <= do_rd;
        if do_rd = '1' then
          rp <= (rp + 1) mod DEPTH;
          m := m - 1;
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
