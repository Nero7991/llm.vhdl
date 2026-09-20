-- rtl/fk33_eng_cdc.vhd -- THE A CLOCK-DOMAIN SEAM.  TRACK ACLK, 2026-09-20.
--
-- Sits between the card cell (subsystems B, C, D on clk_wiz_0/clk_out3, the
-- 75 MHz core clock) and the engine cell (subsystem A, fk33_engine) when
-- hw/fk33/gen_pcieep.py is run with FK33_ENG_SPLIT_CLK=1 and the engine's
-- core_clk is moved onto its own MMCM output.  Every signal-level net that
-- crosses between `card` and `eng` today goes through this entity instead,
-- and so does the card's AXI-Lite write master onto the engine's control
-- slave.  With the switch OFF this file is not in the build at all.
--
-- ======================================================================
-- THE SEAM, AS THE GENERATOR WIRES IT (CARD_SEAM_TO_ENG / CARD_SEAM_FROM_ENG)
-- ======================================================================
--   card -> eng   a_job_index[32]   quasi-static: changes at job retire
--                 a_x_we / a_x_waddr[16] / a_x_wdata[16]
--                                   a push stream with NO ready, one element
--                                   per card cycle, j_cols back to back
--                 a_x_exp[32]       quasi-static: written at the card's S_GO,
--                                   the same edge the job's first AXI write
--                                   is armed, held for the whole job
--   card -> eng   a_aw*/a_w*/a_b*   AXI-Lite WRITE-ONLY master: three writes
--                                   per job (DESC_PTR_LO, DESC_PTR_HI, CTRL=GO)
--   eng  -> card  d_y_we / d_y_addr[16] / d_y_data[ROWS_IF*64] /
--                 d_y_mask[ROWS_IF] / d_y_exp[32]
--                                   a beat stream with NO ready; matvec_core
--                                   emits the whole job's tiles BACK TO BACK,
--                                   one per engine cycle (S_EMIT), up to
--                                   MAXROWS/ROWS_IF beats
--   eng  -> card  d_job_done        LEVEL: set at job completion, cleared by
--                                   the next GO write and by nothing else
--   eng  -> card  d_job_err         LEVEL, STICKY: only a reset clears it
--
-- ======================================================================
-- THE CROSSING PER CLASS, AND WHY EACH ONE IS SHAPED THE WAY IT IS
-- ======================================================================
-- The card side (rtl/a_desc_adapter.vhd, rtl/fk33_llama_top.vhd's ga_desc arm)
-- was written for ONE clock and its correctness rests on three orderings
-- that a single clock gives for free.  This wrapper reproduces each one
-- STRUCTURALLY -- by handshake, not by a timing argument -- so that no
-- claim below depends on the ratio of the two clocks or on route delay:
--
--  1. "Every x element is already in A" when the first AXI write goes out
--     (fk33_llama_top S_GO).  The x elements cross in a gray-pointer FIFO
--     and the AXI writes cross in a toggle handshake; the two paths have
--     different latencies.  So the card-side write acceptance WAITS until
--     the x FIFO's write side sees the read pointer caught up (every element
--     read out of the memory), and the engine-side write execution WAITS
--     until the FIFO's output stage is empty and the last `d_x_we` pulse has
--     been presented.  The request toggle is flipped only after the first
--     condition, and reaches the engine side at least two engine cycles
--     later, by which time the element it was waiting for has been popped.
--
--  2. "job_done cannot be the PREVIOUS job's" when the adapter enters S_WAIT
--     (a_desc_adapter.vhd, S_WAIT).  A level synchroniser would break this:
--     the GO clears `done` in the engine domain, and the card would keep
--     seeing the stale '1' for two or three of its cycles after the GO's
--     write response -- long enough to complete a job that has not started.
--     So `done` is NOT carried as a level.  The engine side detects its
--     RISING EDGE and sends one toggle event; the card side raises
--     `a_job_done` on the event and CLEARS it when it accepts the next AXI
--     write.  The adapter never issues a GO before it has consumed the
--     previous done (its S_DONE holds until u_ack), so an event can never
--     be cleared before it was seen.
--
--     What changes at the seam's edge: a GO refused by the thermal halt
--     (fk33_engine masks the GO bit) leaves `done` HIGH from the previous
--     job with no new rising edge.  On one clock the adapter completes such
--     a job instantly and silently (S_WAIT sees the stale level).  Through
--     this wrapper it WAITS, because no event arrives.  A hang the host's
--     watchdog sees is preferred to a silent skip, and it is recorded here
--     rather than hidden.
--
--  3. "Every y beat arrives during S_RUN", i.e. before the card sees done
--     (fk33_llama_top: `if st /= S_RUN then f_lost_a`).  The beats cross in
--     a FIFO and done in a toggle; again different latencies, and here the
--     FIFO is the slower path by construction because it drains at the card
--     clock.  So the engine side holds the done event until the y FIFO's
--     write side sees the read pointer caught up, and the card side holds
--     `a_job_done` until the FIFO's output stage is empty and the last
--     `a_y_we` pulse has gone out.  Same cycle-count argument as (1), in
--     the other direction.
--
--  The multi-bit payloads (the AXI write's address/data/strobe and the two
--  quasi-static words a_x_exp / a_job_index) ride the same request toggle as
--  DATA-BEFORE-TOGGLE: they are registered on the sending side two cycles
--  before the toggle flips and are not touched until the response has come
--  back, so the receiver samples them at least two of its own cycles after
--  they settled.  a_x_exp is CAPTURED WITH EACH WRITE rather than
--  synchronised on its own: the card writes it on the same edge it arms the
--  first write of a job, so the value the GO carries is the value the job
--  reads (matvec_int4_desc_axi reads x_exp_in at S_CHECK, after the GO).
--
--  d_job_err is a STICKY level and crosses as a plain two-flop synchroniser;
--  a monotone level has no stale-window hazard.  The wrapper's own two
--  sticky faults (a push into a full x FIFO, a beat into a full y FIFO) are
--  OR-ed into `a_job_err`, because a lost element or beat IS a wrong result
--  for that job and D should learn it through the same line it already
--  reads, and are also brought out on `cdc_fault` for a future seam register.
--
-- ======================================================================
-- THE FIFOs ARE rtl/async_fifo.vhd, NOT A NEW ONE
-- ======================================================================
-- Subsystem A already carries a gray-pointer dual-clock FIFO with ASYNC_REG
-- synchronisers, a registered full flag, a BRAM-inferring memory and its own
-- mutation-tested bench (sim/tb_async_fifo.vhd, sim/mutate_async_fifo.sh),
-- and it is in every engine build's source list.  Vivado's xpm_fifo_async
-- would need a `library beh` stand-in for GHDL -- a second implementation
-- free to disagree with the first -- and would buy nothing this one lacks.
-- Its four-phase CLEAR handshake is tied off here: nothing in this seam
-- flushes.
--
-- SIZING.  The y FIFO must hold a WHOLE JOB'S BEATS, because the beats
-- arrive back to back at the engine clock and the consumer has no ready:
-- with the engine faster than the card, a burst of N beats leaves about
-- N*(1 - f_card/f_eng) of them resident.  Y_DEPTH therefore defaults to
-- 256 = fk33_llama_top's A_YWORDS (A_MAXROWS 12,288 / ROWS_IF 48), so that
-- NO job can overflow it at ANY clock ratio; and because the done event is
-- held until the FIFO has drained, the next job cannot start before it is
-- empty.  256 x (16 + 48*64 + 48 + 32) bits is 44 RAMB36 (72-bit ports, 512
-- deep), against 105 free tiles in the shipped card build (MEASURED,
-- hw/fk33/results/card_swg_2026-09-20/bd_wrapper_utilization_placed.rpt).
-- The x FIFO is 16 deep: the card pushes one element per ITS cycle and the
-- engine pops one per ITS cycle, so with the engine faster it never holds
-- more than one or two.  Both overflows are detected, never assumed away.
--
-- ======================================================================
-- RESET
-- ======================================================================
-- Each side has its own active-low reset (s_rstn from the card's core_reset,
-- m_rstn from the engine domain's own proc_sys_reset).  The wrapper does
-- not require either to release first: every cross-domain source register
-- (pointers, toggles, the err level) resets to '0', every receiver's
-- reference register resets to '0', so a side that is out of reset while
-- the other is still held sees "no event, empty FIFO".  A side still in
-- reset drives its outputs at their idle values.  Both resets descend from
-- xdma/axi_aresetn and nothing else, which is what check_reset_topology in
-- gen_pcieep.py enforces for the engine's.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fk33_eng_cdc is
  generic (
    ROWS_IF : positive := 48;
    LITE_AW : positive := 12;
    X_DEPTH : positive := 16;    -- power of two (async_fifo)
    Y_DEPTH : positive := 256    -- power of two; >= the largest job's beats
  );
  port (
    ------------------------------------------------------------------
    -- CARD SIDE (slow).  Pin names are the CARD's, so gen_pcieep.py
    -- wires card/<pin> -> cdc/<pin> for every CARD_SEAM_* row.
    ------------------------------------------------------------------
    s_clk       : in  std_logic;
    s_rstn      : in  std_logic;

    a_job_index : in  std_logic_vector(31 downto 0);
    a_x_we      : in  std_logic;
    a_x_waddr   : in  std_logic_vector(15 downto 0);
    a_x_wdata   : in  std_logic_vector(15 downto 0);
    a_x_exp     : in  std_logic_vector(31 downto 0);
    a_y_we      : out std_logic;
    a_y_addr    : out std_logic_vector(15 downto 0);
    a_y_data    : out std_logic_vector(ROWS_IF*64-1 downto 0);
    a_y_mask    : out std_logic_vector(ROWS_IF-1 downto 0);
    a_y_exp     : out std_logic_vector(31 downto 0);
    a_job_done  : out std_logic;
    a_job_err   : out std_logic;

    -- AXI-Lite write-only SLAVE, the card's `a` master lands here
    sa_awaddr   : in  std_logic_vector(LITE_AW-1 downto 0);
    sa_awvalid  : in  std_logic;
    sa_awready  : out std_logic;
    sa_wdata    : in  std_logic_vector(31 downto 0);
    sa_wstrb    : in  std_logic_vector(3 downto 0);
    sa_wvalid   : in  std_logic;
    sa_wready   : out std_logic;
    sa_bresp    : out std_logic_vector(1 downto 0);
    sa_bvalid   : out std_logic;
    sa_bready   : in  std_logic;

    -- sticky: a push into a full x FIFO or a beat into a full y FIFO
    cdc_fault   : out std_logic;

    ------------------------------------------------------------------
    -- ENGINE SIDE (fast).  Pin names are the ENGINE's, so gen_pcieep.py
    -- wires cdc/<pin> -> eng/<pin> for every CARD_SEAM_* row.
    ------------------------------------------------------------------
    m_clk       : in  std_logic;
    m_rstn      : in  std_logic;

    job_index   : out std_logic_vector(31 downto 0);
    d_x_we      : out std_logic;
    d_x_waddr   : out std_logic_vector(15 downto 0);
    d_x_wdata   : out std_logic_vector(15 downto 0);
    d_x_exp     : out std_logic_vector(31 downto 0);
    d_y_we      : in  std_logic;
    d_y_addr    : in  std_logic_vector(15 downto 0);
    d_y_data    : in  std_logic_vector(ROWS_IF*64-1 downto 0);
    d_y_mask    : in  std_logic_vector(ROWS_IF-1 downto 0);
    d_y_exp     : in  std_logic_vector(31 downto 0);
    d_job_done  : in  std_logic;
    d_job_err   : in  std_logic;

    -- AXI-Lite write-only MASTER onto the engine's control slave
    ma_awaddr   : out std_logic_vector(LITE_AW-1 downto 0);
    ma_awvalid  : out std_logic;
    ma_awready  : in  std_logic;
    ma_wdata    : out std_logic_vector(31 downto 0);
    ma_wstrb    : out std_logic_vector(3 downto 0);
    ma_wvalid   : out std_logic;
    ma_wready   : in  std_logic;
    ma_bresp    : in  std_logic_vector(1 downto 0);
    ma_bvalid   : in  std_logic;
    ma_bready   : out std_logic
  );
end entity;

architecture rtl of fk33_eng_cdc is

  -- async_fifo's read side holds OUT_MARGIN beats outside the memory and its
  -- registered w_level carries OUT_MARGIN + 1 when used_w = 0.  "Caught up"
  -- on the write side is therefore w_level = OUT_MARGIN + 1, one cycle stale
  -- in the CONSERVATIVE direction only (see the REGISTERED LEVEL note in
  -- rtl/async_fifo.vhd), and the one write that stale cycle can hide is
  -- excluded below by also requiring no write in the current or previous
  -- cycle.
  constant OUT_MARGIN : natural := 3;
  constant X_W : positive := 32;
  constant Y_W : positive := 16 + ROWS_IF*64 + ROWS_IF + 32;

  signal s_rst, m_rst : std_logic;

  -- ---------------------------------------------------- x FIFO (card -> eng)
  signal x_wdata_v  : std_logic_vector(X_W-1 downto 0);
  signal x_wready   : std_logic;
  signal x_wlevel   : integer range 0 to 2*X_DEPTH + OUT_MARGIN;
  signal x_qvalid   : std_logic;
  signal x_qdata    : std_logic_vector(X_W-1 downto 0);
  signal x_we_d1    : std_logic := '0';   -- a_x_we, one card cycle late
  signal x_caught   : std_logic;          -- card side: every element read out
  signal x_ovf      : std_logic := '0';   -- STICKY, card domain
  signal dx_we_r    : std_logic := '0';
  signal dx_addr_r  : std_logic_vector(15 downto 0) := (others => '0');
  signal dx_data_r  : std_logic_vector(15 downto 0) := (others => '0');

  -- ---------------------------------------------------- y FIFO (eng -> card)
  signal y_wdata_v  : std_logic_vector(Y_W-1 downto 0);
  signal y_wready   : std_logic;
  signal y_wlevel   : integer range 0 to 2*Y_DEPTH + OUT_MARGIN;
  signal y_qvalid   : std_logic;
  signal y_qdata    : std_logic_vector(Y_W-1 downto 0);
  signal y_we_d1    : std_logic := '0';   -- d_y_we, one engine cycle late
  signal y_caught   : std_logic;          -- engine side: every beat read out
  signal y_ovf      : std_logic := '0';   -- STICKY, engine domain
  signal ay_we_r    : std_logic := '0';
  signal ay_addr_r  : std_logic_vector(15 downto 0) := (others => '0');
  signal ay_data_r  : std_logic_vector(ROWS_IF*64-1 downto 0) := (others => '0');
  signal ay_mask_r  : std_logic_vector(ROWS_IF-1 downto 0) := (others => '0');
  signal ay_exp_r   : std_logic_vector(31 downto 0) := (others => '0');

  -- ------------------------------------------- AXI-Lite write, card -> eng
  type s_st_t is (S_IDLE, S_ACC, S_HOLD, S_TOG, S_WAIT, S_RESP);
  signal s_st       : s_st_t := S_IDLE;
  signal req_addr   : std_logic_vector(LITE_AW-1 downto 0) := (others => '0');
  signal req_data   : std_logic_vector(31 downto 0) := (others => '0');
  signal req_strb   : std_logic_vector(3 downto 0) := (others => '0');
  signal req_xexp   : std_logic_vector(31 downto 0) := (others => '0');
  signal req_jidx   : std_logic_vector(31 downto 0) := (others => '0');
  signal req_tog    : std_logic := '0';   -- card domain, flips per request
  signal ack_s1, ack_s2 : std_logic := '0';   -- ack toggle, into the card domain
  signal ack_seen   : std_logic := '0';
  signal resp_bresp : std_logic_vector(1 downto 0) := "00";  -- engine domain
  signal s_bresp_r  : std_logic_vector(1 downto 0) := "00";
  signal sa_awready_r, sa_wready_r, sa_bvalid_r : std_logic := '0';

  type m_st_t is (M_IDLE, M_AW, M_B, M_HOLD, M_TOG);
  signal m_st       : m_st_t := M_IDLE;
  signal req_s1, req_s2 : std_logic := '0';   -- request toggle, into the engine domain
  signal req_seen   : std_logic := '0';
  signal ack_tog    : std_logic := '0';   -- engine domain, flips per response
  signal m_addr_r   : std_logic_vector(LITE_AW-1 downto 0) := (others => '0');
  signal m_data_r   : std_logic_vector(31 downto 0) := (others => '0');
  signal m_strb_r   : std_logic_vector(3 downto 0) := (others => '0');
  signal m_xexp_r   : std_logic_vector(31 downto 0) := (others => '0');
  signal m_jidx_r   : std_logic_vector(31 downto 0) := (others => '0');
  signal ma_awvalid_r, ma_wvalid_r, ma_bready_r : std_logic := '0';
  signal aw_done, w_done : std_logic := '0';

  -- ------------------------------------------------ done event, eng -> card
  signal done_d1    : std_logic := '0';   -- d_job_done, one engine cycle late
  signal done_pend  : std_logic := '0';   -- rising edge seen, y not yet drained
  signal done_tog   : std_logic := '0';   -- engine domain, flips per completion
  signal dn_s1, dn_s2 : std_logic := '0'; -- into the card domain
  signal dn_seen    : std_logic := '0';
  signal dn_pend_s  : std_logic := '0';   -- event seen, y output not yet drained
  signal done_s     : std_logic := '0';   -- a_job_done

  -- ------------------------------------------------- err level, eng -> card
  signal err_s1, err_s2   : std_logic := '0';
  signal yovf_s1, yovf_s2 : std_logic := '0';

  -- ASYNC_REG on every synchroniser pair.  rtl/async_fifo.vhd carries its
  -- own on the pointer synchronisers.
  attribute async_reg : string;
  attribute async_reg of ack_s1  : signal is "TRUE";
  attribute async_reg of ack_s2  : signal is "TRUE";
  attribute async_reg of req_s1  : signal is "TRUE";
  attribute async_reg of req_s2  : signal is "TRUE";
  attribute async_reg of dn_s1   : signal is "TRUE";
  attribute async_reg of dn_s2   : signal is "TRUE";
  attribute async_reg of err_s1  : signal is "TRUE";
  attribute async_reg of err_s2  : signal is "TRUE";
  attribute async_reg of yovf_s1 : signal is "TRUE";
  attribute async_reg of yovf_s2 : signal is "TRUE";

begin

  s_rst <= not s_rstn;
  m_rst <= not m_rstn;

  -- ======================================================================
  -- x: card -> engine
  -- ======================================================================
  x_wdata_v <= a_x_waddr & a_x_wdata;

  u_xfifo : entity work.async_fifo
    generic map (W => X_W, DEPTH => X_DEPTH, OUT_MARGIN => OUT_MARGIN)
    port map (
      wclk => s_clk, wrst => s_rst,
      w_valid => a_x_we, w_data => x_wdata_v, w_ready => x_wready,
      w_level => x_wlevel, clr => '0', clr_done => open,
      rclk => m_clk, rrst => m_rst,
      q_valid => x_qvalid, q_data => x_qdata, q_ready => '1');

  x_caught <= '1' when x_wlevel = OUT_MARGIN + 1 and a_x_we = '0'
                       and x_we_d1 = '0' else '0';

  xs : process(s_clk)
  begin
    if rising_edge(s_clk) then
      x_we_d1 <= a_x_we;
      if s_rst = '1' then
        x_ovf <= '0'; x_we_d1 <= '0';
      elsif a_x_we = '1' and x_wready = '0' then
        x_ovf <= '1';
      end if;
    end if;
  end process;

  xm : process(m_clk)
  begin
    if rising_edge(m_clk) then
      if m_rst = '1' then
        dx_we_r <= '0';
      else
        dx_we_r <= x_qvalid;
        if x_qvalid = '1' then
          dx_addr_r <= x_qdata(31 downto 16);
          dx_data_r <= x_qdata(15 downto 0);
        end if;
      end if;
    end if;
  end process;

  d_x_we    <= dx_we_r;
  d_x_waddr <= dx_addr_r;
  d_x_wdata <= dx_data_r;

  -- ======================================================================
  -- y: engine -> card
  -- ======================================================================
  y_wdata_v <= d_y_addr & d_y_data & d_y_mask & d_y_exp;

  u_yfifo : entity work.async_fifo
    generic map (W => Y_W, DEPTH => Y_DEPTH, OUT_MARGIN => OUT_MARGIN)
    port map (
      wclk => m_clk, wrst => m_rst,
      w_valid => d_y_we, w_data => y_wdata_v, w_ready => y_wready,
      w_level => y_wlevel, clr => '0', clr_done => open,
      rclk => s_clk, rrst => s_rst,
      q_valid => y_qvalid, q_data => y_qdata, q_ready => '1');

  y_caught <= '1' when y_wlevel = OUT_MARGIN + 1 and d_y_we = '0'
                       and y_we_d1 = '0' else '0';

  ym : process(m_clk)
  begin
    if rising_edge(m_clk) then
      y_we_d1 <= d_y_we;
      if m_rst = '1' then
        y_ovf <= '0'; y_we_d1 <= '0';
      elsif d_y_we = '1' and y_wready = '0' then
        y_ovf <= '1';
      end if;
    end if;
  end process;

  ys : process(s_clk)
  begin
    if rising_edge(s_clk) then
      if s_rst = '1' then
        ay_we_r <= '0';
      else
        ay_we_r <= y_qvalid;
        if y_qvalid = '1' then
          ay_addr_r <= y_qdata(Y_W-1 downto Y_W-16);
          ay_data_r <= y_qdata(Y_W-17 downto ROWS_IF+32);
          ay_mask_r <= y_qdata(ROWS_IF+31 downto 32);
          ay_exp_r  <= y_qdata(31 downto 0);
        end if;
      end if;
    end if;
  end process;

  a_y_we   <= ay_we_r;
  a_y_addr <= ay_addr_r;
  a_y_data <= ay_data_r;
  a_y_mask <= ay_mask_r;
  a_y_exp  <= ay_exp_r;

  -- ======================================================================
  -- AXI-Lite write request, card side
  -- ======================================================================
  sa_awready <= sa_awready_r;
  sa_wready  <= sa_wready_r;
  sa_bvalid  <= sa_bvalid_r;
  sa_bresp   <= s_bresp_r;

  sreq : process(s_clk)
  begin
    if rising_edge(s_clk) then
      ack_s1 <= ack_tog; ack_s2 <= ack_s1;
      if s_rst = '1' then
        s_st <= S_IDLE; req_tog <= '0'; ack_seen <= '0';
        ack_s1 <= '0'; ack_s2 <= '0';
        sa_awready_r <= '0'; sa_wready_r <= '0'; sa_bvalid_r <= '0';
        done_s <= '0'; dn_seen <= '0'; dn_pend_s <= '0';
        dn_s1 <= '0'; dn_s2 <= '0';
      else
        dn_s1 <= done_tog; dn_s2 <= dn_s1;

        -- the done EVENT, held until the y output stage has drained (3)
        if dn_s2 /= dn_seen then
          dn_seen   <= dn_s2;
          dn_pend_s <= '1';
        end if;
        if dn_pend_s = '1' and y_qvalid = '0' and ay_we_r = '0' then
          dn_pend_s <= '0';
          done_s    <= '1';
        end if;

        case s_st is
          when S_IDLE =>
            -- Both channels of the write must be offered and the x FIFO
            -- must have been read out (1) before the beat is accepted.
            if sa_awvalid = '1' and sa_wvalid = '1' and x_caught = '1' then
              sa_awready_r <= '1';
              sa_wready_r  <= '1';
              s_st <= S_ACC;
            end if;
          when S_ACC =>
            -- the handshake cycle: valid is held by the master, ready is up
            sa_awready_r <= '0';
            sa_wready_r  <= '0';
            req_addr <= sa_awaddr;
            req_data <= sa_wdata;
            req_strb <= sa_wstrb;
            req_xexp <= a_x_exp;
            req_jidx <= a_job_index;
            done_s   <= '0';      -- (2): a write clears the previous done
            s_st <= S_HOLD;
          when S_HOLD =>
            -- data-before-toggle: one full cycle with the payload settled
            s_st <= S_TOG;
          when S_TOG =>
            req_tog <= not req_tog;
            s_st <= S_WAIT;
          when S_WAIT =>
            if ack_s2 /= ack_seen then
              ack_seen    <= ack_s2;
              s_bresp_r   <= resp_bresp;   -- settled >= 2 engine cycles before the toggle
              sa_bvalid_r <= '1';
              s_st <= S_RESP;
            end if;
          when S_RESP =>
            if sa_bready = '1' then
              sa_bvalid_r <= '0';
              s_st <= S_IDLE;
            end if;
        end case;
      end if;
    end if;
  end process;

  a_job_done <= done_s;

  -- ======================================================================
  -- AXI-Lite write execution, engine side
  -- ======================================================================
  ma_awaddr  <= m_addr_r;
  ma_wdata   <= m_data_r;
  ma_wstrb   <= m_strb_r;
  ma_awvalid <= ma_awvalid_r;
  ma_wvalid  <= ma_wvalid_r;
  ma_bready  <= ma_bready_r;
  d_x_exp    <= m_xexp_r;
  job_index  <= m_jidx_r;

  mreq : process(m_clk)
  begin
    if rising_edge(m_clk) then
      req_s1 <= req_tog; req_s2 <= req_s1;
      if m_rst = '1' then
        m_st <= M_IDLE; ack_tog <= '0'; req_seen <= '0';
        req_s1 <= '0'; req_s2 <= '0';
        ma_awvalid_r <= '0'; ma_wvalid_r <= '0'; ma_bready_r <= '0';
        aw_done <= '0'; w_done <= '0';
        m_xexp_r <= (others => '0'); m_jidx_r <= (others => '0');
        done_d1 <= '0'; done_pend <= '0'; done_tog <= '0';
      else
        -- the done event source (2)+(3): rising edge, then wait for the y
        -- FIFO's write side to see the read pointer caught up
        done_d1 <= d_job_done;
        if d_job_done = '1' and done_d1 = '0' then
          done_pend <= '1';
        end if;
        if done_pend = '1' and y_caught = '1' then
          done_pend <= '0';
          done_tog  <= not done_tog;
        end if;

        case m_st is
          when M_IDLE =>
            -- (1): the x output stage must be empty and the last element
            -- presented before the write is executed
            if req_s2 /= req_seen and x_qvalid = '0' and dx_we_r = '0' then
              req_seen <= req_s2;
              m_addr_r <= req_addr;
              m_data_r <= req_data;
              m_strb_r <= req_strb;
              m_xexp_r <= req_xexp;
              m_jidx_r <= req_jidx;
              ma_awvalid_r <= '1';
              ma_wvalid_r  <= '1';
              aw_done <= '0'; w_done <= '0';
              m_st <= M_AW;
            end if;
          when M_AW =>
            if ma_awvalid_r = '1' and ma_awready = '1' then
              ma_awvalid_r <= '0'; aw_done <= '1';
            end if;
            if ma_wvalid_r = '1' and ma_wready = '1' then
              ma_wvalid_r <= '0'; w_done <= '1';
            end if;
            if (aw_done = '1' or (ma_awvalid_r = '1' and ma_awready = '1'))
               and (w_done = '1' or (ma_wvalid_r = '1' and ma_wready = '1')) then
              ma_bready_r <= '1';
              m_st <= M_B;
            end if;
          when M_B =>
            if ma_bvalid = '1' then
              ma_bready_r <= '0';
              resp_bresp  <= ma_bresp;
              m_st <= M_HOLD;
            end if;
          when M_HOLD =>
            -- data-before-toggle for the response
            m_st <= M_TOG;
          when M_TOG =>
            ack_tog <= not ack_tog;
            m_st <= M_IDLE;
        end case;
      end if;
    end if;
  end process;

  -- ======================================================================
  -- err (sticky level) and the wrapper's own faults
  -- ======================================================================
  errs : process(s_clk)
  begin
    if rising_edge(s_clk) then
      err_s1  <= d_job_err; err_s2  <= err_s1;
      yovf_s1 <= y_ovf;     yovf_s2 <= yovf_s1;
      if s_rst = '1' then
        err_s1 <= '0'; err_s2 <= '0'; yovf_s1 <= '0'; yovf_s2 <= '0';
      end if;
    end if;
  end process;

  cdc_fault <= x_ovf or yovf_s2;
  a_job_err <= err_s2 or x_ovf or yovf_s2;

  -- Simulation-only visibility: a push or a beat into a full FIFO is a LOST
  -- element.  Severity WARNING, not error, deliberately: the sticky flags
  -- above are the detector (they reach a_job_err), and sim/regress.sh scores
  -- any `(assertion error)` as a failed row, which would make the bench
  -- phases that exercise the detector unrunnable.
  process(s_clk)
  begin
    if rising_edge(s_clk) then
      if s_rst = '0' then
        assert not (a_x_we = '1' and x_wready = '0')
          report "fk33_eng_cdc: x element pushed into a FULL x FIFO -- LOST"
          severity warning;
      end if;
    end if;
  end process;
  process(m_clk)
  begin
    if rising_edge(m_clk) then
      if m_rst = '0' then
        assert not (d_y_we = '1' and y_wready = '0')
          report "fk33_eng_cdc: y beat pushed into a FULL y FIFO -- LOST"
          severity warning;
      end if;
    end if;
  end process;

end architecture;
