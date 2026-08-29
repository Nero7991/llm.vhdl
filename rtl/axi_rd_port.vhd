-- rtl/axi_rd_port.vhd -- one AXI4 read-only master feeding a stream FIFO.
--
-- Spec: docs/superpowers/specs/2026-08-20-int4-streaming-matvec-design.md  7.7
--
-- This is the project's FIRST AXI master: everything before v2.0 kept its
-- weights in on-chip ROM, so there is no existing pattern to follow here and
-- the AXI-Lite slaves in llama_engine_axi / mac_axi are not one.
--
-- The port reads ONE contiguous sub-region as plain sequential bursts and hands
-- the beats out in order.  That is all it does -- there is deliberately no
-- reordering, no width conversion and no drain schedule, because 7.7 moved the
-- lane interleave into the PACKER: each port owns its own sub-region, so DDR
-- locality is sequential and the merge above is pure wiring.  Rev 3 of the spec
-- put a 128->512 width converter here and it cost ~8 BRAM36 per port for the
-- read port width alone (RAMB36E2 tops out at 72 bits).
--
-- FLUSH ON START is not optional (7.7).  Sub-regions are padded to whole 4 KB
-- bursts, so the burst carrying the last needed beat also delivers padding
-- beats that stay resident when the job ends.  The residue differs per port, so
-- without a flush the next job's word stream would be misaligned by a
-- per-port-varying amount -- silently, and differently on every matrix.
--
-- ======================================================================
-- DUAL CLOCK (added 2026-08-28, spec 14.5 item 3)
-- ======================================================================
-- The FK33's HBM AXI clock is not the core clock, and the 27-master
-- feasibility note only clears because it is FASTER: at ACLK = f_core the duty
-- is exactly 100% with zero margin.  So the CDC is mandatory, and this is where
-- it goes -- there is already a FIFO between the R channel and the consumer,
-- and it is the only point in the weight path where a word crosses.
--
--   DUAL_CLK = false  (default)  everything runs on `clk`, `aclk` is ignored,
--                                and the FIFO is rtl/stream_fifo.vhd.  Every
--                                existing instantiation and testbench lands
--                                here.
--   DUAL_CLK = true              the AXI side (AR issue, burst accounting,
--                                R capture, FIFO write) runs on `aclk`; the
--                                stream output runs on `clk`.  The FIFO is
--                                rtl/async_fifo.vhd.
--
-- Three things cross, and each is crossed the way its shape requires:
--
--   * `start` is a one-cycle PULSE in the core domain -> toggle synchroniser.
--     A level would be missed or seen twice depending on the clock ratio.
--   * `base` and `n_beats` are LEVELS held stable by the descriptor engine
--     around `start` -> sampled in the AXI domain after the toggle lands.
--     They are not synchronised bit by bit and must not be changed between
--     `start` and the job completing.
--   * the FLUSH is a two-sided handshake, because a synchronous flush means
--     nothing across two clocks.  See rtl/async_fifo.vhd's header; the FSM in
--     rtl/axi_rd_fsm.vhd is the caller that runs all four phases.
--
-- `rst` stays a core-domain input and is synchronised into the AXI domain
-- here.  It is a long level at power-on, so a two-flop delay on assertion is
-- not a hazard; deassertion is synchronous in each domain, which is the part
-- that matters.
--
-- THE FSM IS A SEPARATE ENTITY ON PURPOSE.  It is instantiated once, under a
-- generate, with `clk` or with `aclk` -- never with an `fclk` signal carrying
-- one or the other.  A signal assignment costs a delta and the resulting clock
-- skew is a simulation artefact that MEASURABLY broke sim/tb_matvec_int4_ip;
-- see rtl/axi_rd_fsm.vhd's header for the measurement.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_rd_port is
  generic(
    AXI_DW  : positive := 128;
    ADDR_W  : positive := 32;
    DEPTH   : positive := 512;   -- beats; 7.7 budgets 8 KB at AXI_DW=128
    MAXB    : positive := 256;   -- beats per burst; 256 x 16 B = one 4 KB burst
    -- Bursts allowed in flight.  RAISED FROM 2 TO 16 on 2026-08-28.
    --
    -- 2 was never a decision: it was the default of a generic that
    -- weight_streamer did not plumb through, and it was left in place after the
    -- plumbing landed.  The AXU3EG measurement behind it (0.664 beats/cycle per
    -- port, consistent with ~129 cycles of read latency) is a DDR number, and
    -- HBM's latency is higher, not lower.  The 288.0 GB/s run in
    -- docs/2026-08-28_can-27-read-masters-be-served.md -- 100% of the
    -- arithmetic ceiling -- used 16.
    --
    -- COST, stated so it is not mistaken for free: `outst` widens from 2 bits
    -- to clog2(MAXOUT+2) bits and its comparator with it, so ~3 FF and a
    -- slightly wider compare PER PORT, times 27 ports.  Nothing else moves.
    -- The binding resource is unchanged: the AR throttle is against FIFO FREE
    -- SPACE including beats already requested, so MAXOUT can never make the
    -- FIFO overrun -- it simply stops being reachable once MAXOUT*MAXB > DEPTH,
    -- at which point DEPTH is the limit and MAXOUT is inert.  At the FK33's
    -- DEPTH=512 / MAXB=16 that boundary is MAXOUT=32.
    MAXOUT  : positive := 16;
    -- See the DUAL CLOCK block in the header.
    DUAL_CLK : boolean := false
  );
  port(
    clk, rst : in  std_logic;
    -- AXI clock.  IGNORED when DUAL_CLK = false; defaulted so that every
    -- existing single-clock instantiation and testbench needs no edit.
    aclk     : in  std_logic := '0';

    -- job.  base must be 4 KB aligned; n_beats is the whole sub-region.
    -- Both are core-domain and must be stable from `start` to completion.
    start    : in  std_logic;
    base     : in  std_logic_vector(ADDR_W-1 downto 0);
    n_beats  : in  integer;

    -- AXI4 read address / read data.  In the AXI domain when DUAL_CLK.
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

    -- stream out, always in the `clk` domain
    q_valid  : out std_logic;
    q_data   : out std_logic_vector(AXI_DW-1 downto 0);
    q_ready  : in  std_logic
  );
end entity;

architecture rtl of axi_rd_port is
  constant BYTES : positive := AXI_DW / 8;

  -- Beats the FIFO reports on top of the raw pointer difference.  Stated once
  -- here and passed to BOTH the FIFO and the FSM, so the async_fifo generic and
  -- the axi_rd_fsm f_level range cannot drift apart -- if they did, the drift
  -- would show up as a simulation range error inside a clear window and
  -- nowhere else.  3 is async_fifo's own default and also bounds stream_fifo's
  -- `ocnt + inflight`.
  constant LVL_MARGIN : natural := 3;

  signal f_iv, f_ir : std_logic;
  signal f_qv, f_qr : std_logic;
  signal f_qd : std_logic_vector(AXI_DW-1 downto 0);
  signal f_level : integer range 0 to 2*DEPTH + LVL_MARGIN;

  -- clear handshake, in the AXI domain
  signal clr, clr_done : std_logic;

  -- FSM interface, all in the AXI domain
  signal start_f : std_logic;
  signal beat_f  : std_logic;
  signal run_f   : std_logic;
  signal rready_i : std_logic;

  -- `run`, in the core domain (it gates the stream output)
  signal run_c   : std_logic;
  signal run_s1, run_s2 : std_logic := '0';
  signal rst_s1, rst_s2 : std_logic := '1';
  signal frst    : std_logic;

  signal s_tog   : std_logic := '0';
  signal s_t1, s_t2, s_t3 : std_logic := '0';

  -- ASYNC_REG (added 2026-08-29, TRACK CDC-STATIC).  Same finding as in
  -- rtl/async_fifo.vhd, whose declaration block carries the measurement: none
  -- of this port's synchroniser flops carried the attribute either, so the
  -- placer was free to split every pair.  s_t3 is deliberately NOT marked --
  -- it is the edge detector's second sample, not a synchroniser stage, and
  -- ASYNC_REG on it would ask the placer to keep a flop next to one it has no
  -- metastability relationship with.
  attribute async_reg : string;
  attribute async_reg of run_s1 : signal is "TRUE";
  attribute async_reg of run_s2 : signal is "TRUE";
  attribute async_reg of rst_s1 : signal is "TRUE";
  attribute async_reg of rst_s2 : signal is "TRUE";
  attribute async_reg of s_t1   : signal is "TRUE";
  attribute async_reg of s_t2   : signal is "TRUE";
begin
  arsize  <= std_logic_vector(to_unsigned(clog2(BYTES), 3));
  arburst <= "01";                                  -- INCR

  -- In S_DRAIN the R channel is accepted and DISCARDED, so it must not be
  -- backpressured by the FIFO; in S_RUN the FIFO owns the backpressure.
  rready_i <= f_ir when run_f = '1' else '1';
  rready   <= rready_i;
  f_iv     <= rvalid when run_f = '1' else '0';
  beat_f   <= rvalid and rready_i;

  -- The output is SUPPRESSED outside S_RUN.  Flushing alone is not enough: a
  -- start does not take effect until the drain completes, and in that window
  -- the FIFO still holds the abandoned job's residue.  A consumer that reads
  -- as soon as q_valid rises would swallow it before the flush ever lands --
  -- which is exactly what happened the first time this was simulated.
  -- Under DUAL_CLK the gate is the SYNCHRONISED run level, so it rises two
  -- core cycles late.  Late is the safe direction: the consumer waits, it does
  -- not read early.
  q_valid <= f_qv when run_c = '1' else '0';
  q_data  <= f_qd;
  f_qr    <= q_ready when run_c = '1' else '0';

  -- =============================================== single-clock configuration
  g_sc : if not DUAL_CLK generate
    signal ack : std_logic := '0';
  begin
    frst    <= rst;
    start_f <= start;
    run_c   <= run_f;

    fsm : entity work.axi_rd_fsm
      generic map(ADDR_W => ADDR_W, BYTES => BYTES, DEPTH => DEPTH,
                  MAXB => MAXB, MAXOUT => MAXOUT, LVL_MARGIN => LVL_MARGIN)
      port map(clk => clk, rst => rst, start => start_f,
               base => base, n_beats => n_beats,
               arvalid => arvalid, arready => arready,
               araddr => araddr, arlen => arlen,
               beat => beat_f, rlast => rlast,
               f_level => f_level, clr => clr, clr_done => clr_done,
               run => run_f);

    -- stream_fifo's `flush` is a synchronous LEVEL clear; holding it for the
    -- cycles the S_CLR/S_CLR2 handshake takes is the same thing the old
    -- single-cycle S_FLUSH state did, two cycles later.
    fifo : entity work.stream_fifo
      generic map(W => AXI_DW, DEPTH => DEPTH)
      port map(clk => clk, rst => rst, flush => clr,
               i_valid => f_iv, i_data => rdata, i_ready => f_ir,
               q_valid => f_qv, q_data => f_qd, q_ready => f_qr,
               level => f_level);

    -- one-cycle acknowledgement, so the four-phase handshake in the FSM is the
    -- same code in both configurations
    ackp : process(clk)
    begin
      if rising_edge(clk) then
        if rst = '1' then ack <= '0'; else ack <= clr; end if;
      end if;
    end process;
    clr_done <= ack;
  end generate;

  -- ================================================= dual-clock configuration
  g_dc : if DUAL_CLK generate
    frst  <= rst_s2;
    run_c <= run_s2;

    -- reset into the AXI domain
    rsync : process(aclk)
    begin
      if rising_edge(aclk) then
        rst_s1 <= rst; rst_s2 <= rst_s1;
      end if;
    end process;

    -- `start` pulse -> toggle -> pulse
    stog : process(clk)
    begin
      if rising_edge(clk) then
        if rst = '1' then s_tog <= '0';
        elsif start = '1' then s_tog <= not s_tog;
        end if;
      end if;
    end process;
    ssyn : process(aclk)
    begin
      if rising_edge(aclk) then
        s_t1 <= s_tog; s_t2 <= s_t1; s_t3 <= s_t2;
      end if;
    end process;
    start_f <= s_t2 xor s_t3;

    -- `run` level back into the core domain
    rsyn : process(clk)
    begin
      if rising_edge(clk) then
        if rst = '1' then run_s1 <= '0'; run_s2 <= '0';
        else run_s1 <= run_f; run_s2 <= run_s1;
        end if;
      end if;
    end process;

    fsm : entity work.axi_rd_fsm
      generic map(ADDR_W => ADDR_W, BYTES => BYTES, DEPTH => DEPTH,
                  MAXB => MAXB, MAXOUT => MAXOUT, LVL_MARGIN => LVL_MARGIN)
      port map(clk => aclk, rst => frst, start => start_f,
               base => base, n_beats => n_beats,
               arvalid => arvalid, arready => arready,
               araddr => araddr, arlen => arlen,
               beat => beat_f, rlast => rlast,
               f_level => f_level, clr => clr, clr_done => clr_done,
               run => run_f);

    fifo : entity work.async_fifo
      generic map(W => AXI_DW, DEPTH => DEPTH, OUT_MARGIN => LVL_MARGIN)
      port map(wclk => aclk, wrst => frst,
               w_valid => f_iv, w_data => rdata, w_ready => f_ir,
               w_level => f_level, clr => clr, clr_done => clr_done,
               rclk => clk, rrst => rst,
               q_valid => f_qv, q_data => f_qd, q_ready => f_qr);
  end generate;
end architecture;
