-- rtl/mv_rdport.vhd -- a450 Task 3: a tile-local, SINGLE-CLOCK-ONLY copy of
-- rtl/axi_rd_port.vhd, wired to rtl/mv_rdfsm.vhd instead of rtl/axi_rd_fsm.vhd.
--
-- WHY A COPY.  rtl/axi_rd_port.vhd and rtl/axi_rd_fsm.vhd are in the GHDL closure of every
-- existing subsystem A rating; editing them (even just the FSM they instantiate) would
-- re-key every one of those ratings for a timing fix only mv_tile's 450 MHz target needs
-- (plan ruling R10 made the identical call for stream_fifo). rtl/mv_rdfsm.vhd's header has
-- the measurements and the fix; this entity wires that FSM in instead of rtl/axi_rd_fsm.vhd.
-- Two differences from axi_rd_port's g_sc wiring: the FSM is fed the FIFO's POPS (its
-- credit counter) instead of the FIFO's level, and the `credit` process below checks the
-- overflow invariant independently, from the AXI handshakes and the FIFO's own level.
--
-- DUAL_CLK IS DROPPED, NOT DEFAULTED.  mv_tile's HBM port and its core logic are both on
-- `clk` (6.5a: a tile owns one port, both in the core domain) -- mv_tile's instantiation of
-- axi_rd_port never connected `aclk` and always passed DUAL_CLK => false, so there is no
-- single-clock behaviour this entity is missing by not having the generic, and no dual-clock
-- generate for Vivado or GHDL to elaborate (and ignore) on every build of this tile. Diff
-- this file against rtl/axi_rd_port.vhd's `g_sc` generate to see that the single-clock
-- wiring itself is unchanged, just no longer wrapped in a generate with a sibling it can
-- never select.
--
-- R-CHANNEL REGISTER STAGE (a450 Task 7b).  rvalid, rdata and rlast are registered once
-- on entry (rv_q, rd_q, rl_q: no enable, no reset) and everything below reads
-- the registered copies, so the HBM interface's clock-to-out reaches exactly one flop
-- (Task 7 MEASURED, composed: HBM ACLK -> fabric R paths -0.66 ns).  rready to the
-- memory is the constant '1', and that is not a weakening: rready_i below can only be '0'
-- in S_RUN with the FIFO full, and the AR credit (rtl/mv_rdfsm.vhd: FIFO level plus beats
-- requested and not yet landed never exceeds DEPTH; checked independently by `credit`
-- below) means the FIFO always has a slot for every beat the memory can send, the one in
-- rv_q included.  `rstage` asserts it: a registered beat that finds the FIFO not ready
-- is a failure, never a silent drop.  Full throughput, one beat per cycle; the stage adds
-- one cycle of R latency, which the FSM never sees (it counts beats and rlast at the
-- registered side).  rv_q has no reset on purpose (fix round 1): the FSM's never-reset
-- `owed` count must see the beats that arrive while this port is in reset.
--
-- Everything else -- the AR-side wiring, the output gate and its TAUTOLOGY assertion,
-- FAST_POP forwarding, the clear-acknowledgement process -- is rtl/axi_rd_port.vhd's g_sc
-- generate, unchanged.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity mv_rdport is
  generic(
    AXI_DW  : positive := 128;
    ADDR_W  : positive := 32;
    DEPTH   : positive := 512;   -- beats; 7.7 budgets 8 KB at AXI_DW=128
    MAXB    : positive := 256;   -- beats per burst; 256 x 16 B = one 4 KB burst
    -- Bursts allowed in flight.  See rtl/axi_rd_port.vhd's generic of the same
    -- name for the measurement behind 16; unchanged here.
    MAXOUT  : positive := 16;
    -- FAST_POP -- forwarded UNCHANGED to stream_fifo.  See
    -- rtl/stream_fifo.vhd's `do_rd` comment.
    FAST_POP : boolean := false
  );
  port(
    clk, rst : in  std_logic;
    -- the HBM AXI port reset, synchronous to clk, active high: forwarded to
    -- rtl/mv_rdfsm.vhd, where it clears the owed-burst count (a450 Task 8, carry C1)
    hbm_rst  : in  std_logic := '0';

    -- job.  base must be 4 KB aligned; n_beats is the whole sub-region.
    start    : in  std_logic;
    base     : in  std_logic_vector(ADDR_W-1 downto 0);
    n_beats  : in  integer;

    -- AXI4 read address / read data.
    arvalid  : out std_logic;
    arready  : in  std_logic;
    araddr   : out std_logic_vector(ADDR_W-1 downto 0);
    arlen    : out std_logic_vector(7 downto 0);
    arsize   : out std_logic_vector(2 downto 0);
    arburst  : out std_logic_vector(1 downto 0);
    rvalid   : in  std_logic;
    rready   : out std_logic;
    rdata    : in  std_logic_vector(AXI_DW-1 downto 0);
    rlast    : in  std_logic;

    -- stream out
    q_valid  : out std_logic;
    q_data   : out std_logic_vector(AXI_DW-1 downto 0);
    q_ready  : in  std_logic
  );
end entity;

architecture rtl of mv_rdport is
  constant BYTES : positive := AXI_DW / 8;

  signal f_iv, f_ir : std_logic;
  signal f_qv, f_qr : std_logic;
  signal f_qd : std_logic_vector(AXI_DW-1 downto 0);
  -- the FIFO's level, read only by the simulation-only `credit` check below
  signal f_level_raw : integer;
  signal pop_f : std_logic;

  -- clear handshake
  signal clr, clr_done : std_logic;

  -- FSM interface
  signal start_f : std_logic;
  signal beat_f  : std_logic;
  signal run_f   : std_logic;
  signal rready_i : std_logic;

  -- single-clock: run_c is run_f directly, no CDC to cross
  signal run_c   : std_logic;

  signal ack : std_logic := '0';

  -- the R-channel register stage (see the header)
  signal rv_q : std_logic := '0';
  signal rd_q : std_logic_vector(AXI_DW-1 downto 0) := (others => '0');
  signal rl_q : std_logic := '0';
  signal arvalid_i : std_logic;
  signal arlen_i   : std_logic_vector(7 downto 0);
begin
  arsize  <= std_logic_vector(to_unsigned(clog2(BYTES), 3));
  arburst <= "01";                                  -- INCR

  -- In S_DRAIN the R channel is accepted and DISCARDED, so it must not be
  -- backpressured by the FIFO; in S_RUN the FIFO owns the backpressure.
  rready_i <= f_ir when run_f = '1' else '1';
  rready   <= '1';
  f_iv     <= rv_q when run_f = '1' else '0';
  beat_f   <= rv_q and rready_i;

  rstage : process(clk)
  begin
    if rising_edge(clk) then
      rd_q <= rdata;
      rl_q <= rlast;
      rv_q <= rvalid;
      if rst = '0' then
        assert not (rv_q = '1' and rready_i = '0')
          report "mv_rdport: a registered R beat found the FIFO full (rready is tied '1' on "
               & "the AR credit; the credit is broken)"
          severity failure;
      end if;
    end if;
  end process;

  -- The output is SUPPRESSED outside S_RUN.  See rtl/axi_rd_port.vhd's comment
  -- at the same point; unchanged here (DUAL_CLK's extra two-cycle lateness does
  -- not apply -- run_c is run_f with no synchroniser in between).
  q_valid <= f_qv when run_c = '1' else '0';
  q_data  <= f_qd;
  f_qr    <= q_ready when run_c = '1' else '0';

  start_f <= start;
  run_c   <= run_f;
  pop_f   <= f_qv and f_qr;

  -- THE OVERFLOW INVARIANT, CHECKED INDEPENDENTLY OF THE FSM's CREDIT COUNTER.  In S_RUN
  -- the words in the FIFO plus the beats requested by ARs accepted in this S_RUN and not
  -- yet landed must never exceed DEPTH (rtl/mv_rdfsm.vhd's `free` argument).  `chk` is
  -- built from the AXI handshakes and the R beats the FIFO accepted, not from anything
  -- the FSM computes.  It counts from arready, a later edge than the FSM's own count
  -- (from arvalid), so it is the weaker bound, and the one AXI actually needs.
  -- Simulation-only; synthesis ignores it.
  credit : process(clk)
    variable chk : integer := 0;
  begin
    if rising_edge(clk) then
      if rst = '1' or run_f = '0' then
        chk := 0;
      else
        if arvalid_i = '1' and arready = '1' then
          chk := chk + to_integer(unsigned(arlen_i)) + 1;
        end if;
        if beat_f = '1' then chk := chk - 1; end if;
        assert f_level_raw + chk <= DEPTH
          report "mv_rdport: FIFO level plus beats in flight exceeds DEPTH (AR credit "
               & "overrun): an accepted burst can overflow the FIFO"
          severity failure;
      end if;
    end if;
  end process;

  -- THE TWO GATES ABOVE MUST CARRY THE SAME LEVEL.  See rtl/axi_rd_port.vhd's
  -- TAUTOLOGY comment at the same assertion; unchanged here, and worth keeping
  -- for the same reason -- it is a simulation-only check Vivado ignores in
  -- synthesis (documented in CLAUDE.md), and it fires in every bench that
  -- instantiates this port.
  gate_chk : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '0' then
        assert not (f_qv = '1' and f_qr = '1' and run_c = '0')
          report "mv_rdport: the FIFO was POPPED while the stream output was "
               & "SUPPRESSED.  A word left the FIFO that no consumer can ever "
               & "have seen; q_valid and f_qr must carry the same run gate."
          severity failure;
      end if;
    end if;
  end process;

  fsm : entity work.mv_rdfsm
    generic map(ADDR_W => ADDR_W, BYTES => BYTES, DEPTH => DEPTH,
                MAXB => MAXB, MAXOUT => MAXOUT)
    port map(clk => clk, rst => rst, hbm_rst => hbm_rst, start => start_f,
             base => base, n_beats => n_beats,
             arvalid => arvalid_i, arready => arready,
             araddr => araddr, arlen => arlen_i,
             beat => beat_f, rlast => rl_q, pop => pop_f,
             clr => clr, clr_done => clr_done,
             run => run_f);
  arvalid <= arvalid_i;
  arlen   <= arlen_i;

  -- stream_fifo's `flush` is a synchronous LEVEL clear; holding it for the
  -- cycles the S_CLR/S_CLR2 handshake takes is the same thing the old
  -- single-cycle S_FLUSH state did, two cycles later.
  fifo : entity work.stream_fifo
    generic map(W => AXI_DW, DEPTH => DEPTH, FAST_POP => FAST_POP)
    port map(clk => clk, rst => rst, flush => clr,
             i_valid => f_iv, i_data => rd_q, i_ready => f_ir,
             q_valid => f_qv, q_data => f_qd, q_ready => f_qr,
             level => f_level_raw);

  -- one-cycle acknowledgement, so the four-phase handshake in the FSM is the
  -- same code as the dual-clock configuration's (which this entity does not
  -- have, but mv_rdfsm's states still expect it)
  ackp : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then ack <= '0'; else ack <= clr; end if;
    end if;
  end process;
  clr_done <= ack;
end architecture;
