-- rtl/mv_lfifo.vhd -- a small first-word-fall-through FIFO in distributed RAM, one beat
-- per cycle in and out.  rtl/stream_fifo.vhd's structure at FAST_POP = true (registered
-- memory read, 2-entry output stage, the after-pop read-issue bound), with the memory in
-- LUTRAM: the a450 tile's 32-deep flit FIFO and 4-deep result FIFO would each waste a
-- BRAM36 (spec 2.2).  A separate entity, not a generic on stream_fifo, because a change
-- to stream_fifo's text re-keys every block rating that contains it.  Its only user is
-- rtl/mv_tile.vhd.
--
-- SEGMENTS (a450 Task 7b).  The data is split into NSEG column segments, each with its
-- OWN copy of the four pointers (write, read, output-stage write, output-stage read),
-- dont_touch so synthesis keeps the copies.  Every copy is updated by the same enables as
-- the shared counts (mcnt, ocnt, mem_q_v), so the copies are always equal; what changes is
-- the fan-out: a 548-bit flit FIFO has one read pointer per ~69 bits instead of one for
-- all 548 (Task 7 MEASURED, composed: flitq/rp -> mem_q -0.605, flitq/ob_rp -> q_data
-- loads -0.705, the worst tile-internal groups).  The memory read lands directly in a
-- register (mem_q, no enable, no reset): rp -> LUTRAM read -> D.  NSEG = 1 is the
-- unsegmented FIFO.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mv_lfifo is
  generic(
    W     : positive := 64;
    DEPTH : positive := 32;
    NSEG  : positive := 1
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
  constant SW : positive := (W + NSEG - 1) / NSEG;   -- segment width
  constant PW : positive := SW * NSEG;               -- padded width
  signal di, dq : std_logic_vector(PW-1 downto 0);
  type ptr_a is array(0 to NSEG-1) of integer range 0 to DEPTH-1;
  type bit_a is array(0 to NSEG-1) of integer range 0 to 1;
  signal wp, rp : ptr_a := (others => 0);
  signal ob_wp, ob_rp : bit_a := (others => 0);
  attribute dont_touch : string;
  attribute dont_touch of wp : signal is "true";
  attribute dont_touch of rp : signal is "true";
  attribute dont_touch of ob_wp : signal is "true";
  attribute dont_touch of ob_rp : signal is "true";
  signal mcnt   : integer range 0 to DEPTH := 0;
  signal mem_q_v : std_logic := '0';
  signal ocnt : integer range 0 to 2 := 0;
  signal do_rd, we, pop : std_logic;
  signal inflight : integer range 0 to 1;
  signal after_e : integer range 0 to 3;
begin
  inflight <= 1 when mem_q_v = '1' else 0;
  -- the pop term is inlined, not a signal (stream_fifo.vhd records why: a delta-late
  -- pop makes the subtraction reach -1 in simulation)
  after_e <= ocnt + inflight - 1 when (ocnt > 0 and q_ready = '1') else ocnt + inflight;
  do_rd   <= '1' when mcnt > 0 and after_e < 2 else '0';
  we      <= '1' when i_valid = '1' and mcnt < DEPTH else '0';
  pop     <= '1' when ocnt > 0 and q_ready = '1' else '0';
  i_ready <= '1' when mcnt < DEPTH else '0';
  q_valid <= '1' when ocnt > 0 else '0';
  level   <= mcnt + ocnt + inflight;
  di <= (PW-1 downto W => '0') & i_data;
  q_data <= dq(W-1 downto 0);

  g_seg : for g in 0 to NSEG-1 generate
    type mem_t is array(0 to DEPTH-1) of std_logic_vector(SW-1 downto 0);
    signal mem : mem_t;
    attribute ram_style : string;
    attribute ram_style of mem : signal is "distributed";
    signal mem_q : std_logic_vector(SW-1 downto 0) := (others => '0');
    type ob_t is array(0 to 1) of std_logic_vector(SW-1 downto 0);
    signal ob : ob_t := (others => (others => '0'));
  begin
    dq((g+1)*SW-1 downto g*SW) <= ob(ob_rp(g));

    -- DATA: no reset (a450 Task 7b).  The memory write, the registered memory read and
    -- the output-stage write load whatever they load during a reset too.  Nothing written
    -- then can reach q_data while it matters: reset zeroes mcnt, ocnt, mem_q_v and every
    -- pointer, so a memory entry is read only after wp has passed it again (mcnt counts it
    -- from that write), mem_q enters ob only on mem_q_v, and q_valid = ocnt > 0 covers
    -- only ob slots written since.  Keeping rst out of these enables is what keeps the
    -- reset net off the LUTRAM write enables (Task 7: the worst path was ar2 -> resq/ob
    -- LUTRAM WE).
    data : process(clk)
    begin
      if rising_edge(clk) then
        if we = '1' then
          mem(wp(g)) <= di((g+1)*SW-1 downto g*SW);
        end if;
        mem_q <= mem(rp(g));
        if mem_q_v = '1' then
          ob(ob_wp(g)) <= mem_q;
        end if;
      end if;
    end process;

    -- this segment's pointer copies: the same enables as the shared counts below
    ptrs : process(clk)
    begin
      if rising_edge(clk) then
        if rst = '1' then
          wp(g) <= 0; rp(g) <= 0; ob_wp(g) <= 0; ob_rp(g) <= 0;
        else
          if we = '1' then wp(g) <= (wp(g) + 1) mod DEPTH; end if;
          if do_rd = '1' then rp(g) <= (rp(g) + 1) mod DEPTH; end if;
          if mem_q_v = '1' then ob_wp(g) <= (ob_wp(g) + 1) mod 2; end if;
          if pop = '1' then ob_rp(g) <= (ob_rp(g) + 1) mod 2; end if;
        end if;
      end if;
    end process;
  end generate;

  -- CONTROL: the shared counts and the read-valid, reset
  ctrl : process(clk)
    variable m, o : integer;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        mcnt <= 0; ocnt <= 0; mem_q_v <= '0';
      else
        m := mcnt; o := ocnt;
        if we = '1' then m := m + 1; end if;
        mem_q_v <= do_rd;
        if do_rd = '1' then m := m - 1; end if;
        if mem_q_v = '1' then o := o + 1; end if;
        if pop = '1' then o := o - 1; end if;
        mcnt <= m; ocnt <= o;
      end if;
    end if;
  end process;
end architecture;
