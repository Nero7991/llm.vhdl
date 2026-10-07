-- Jungle Cat USER3 control core: clk_core-domain executor (plan Task 3; spec 2026-10-07 S3).
--
-- INPUT. The frame core's FIFO stream (TAG & word(256), through the async FIFO): HDR, then
-- nwords DATA words, then PASS or FAIL carrying the frame's seq in [31:0]. The executor
-- buffers one frame (header registers plus a 64 x 256 frame RAM; payload item k is bits
-- [32(k mod 8)+31 : 32(k mod 8)] of payload word k div 8) and executes it ONLY on its PASS,
-- and only if the frame arrived whole:
--   * a HDR always starts a new frame; a buffered frame with no verdict is discarded
--     (a Capture cut it mid-slot);
--   * DATA with no open header is ignored;
--   * PASS is accepted only if a header is open, the PASS word's seq equals the header's
--     seq, and exactly nwords DATA words arrived (the frame core drops pushes when the
--     FIFO is full, so a short or merged frame is possible after an overflow); otherwise
--     the frame is discarded silently (the host sees ovf and last_done_seq not advancing);
--   * FAIL discards.
--
-- VALIDATION (Ruling (e)). The frame core checks only the magic and count <= 496,
-- nwords <= 62. Before anything executes, a PASS non-NOP frame must have: op in 1..5;
-- count >= 1; nwords = ceil(count/8) for WR_INC/WR_FIX and 0 otherwise; for ops 1-4 an
-- AXI-Lite address with addr[63:32] = 0 and addr[1:0] = 0, and for the INC ops no wrap
-- past 2^32 (addr + 4*count <= 2^32); for MEM_RD addr[4:0] = 0, count a multiple of 8,
-- addr[63:ADDR_W] = 0 and addr + 4*count <= 2^ADDR_W. A header failing any of these
-- executes nothing and completes with axi_err = 1, axi_resp = "10", err_seq = its seq.
-- A READ (ops 3-5) whose seq is x"FFFFFFFF" (the "none" value) or equals the rsp_seq
-- last published executes nothing and completes with axi_err = 1, axi_resp = "01"
-- (EXOKAY, which an AXI-Lite slave never returns, so the code is unambiguous): publishing
-- the same rsp_seq twice in a row would deadlock the frame core's stale rule.
-- A NOP (op 0) frame is never validated and never changes any status field; its only
-- effect is its ack, which the frame core applies (Ruling (c)).
--
-- ACK (Rulings (a), (b)). rsp_ack_tgl (already synchronised to clk) toggles once per host
-- ack; the executor applies every toggle on the cycle it is seen, by clearing rsp_valid.
-- Before a frame's op starts:
--   * a read op (RD_INC, RD_FIX, MEM_RD) waits until rsp_valid = 0, so the response RAM is
--     never written while a response is presented;
--   * a write op whose header carries ack_valid = 1 and ack_seq = the presented rsp_seq
--     (rsp_valid = 1) waits until that ack has cleared rsp_valid.
-- So a frame's own ack is always applied before its op, whichever of the PASS word and the
-- toggle crosses first. Liveness: the frame core toggles for every PASS frame that acks
-- the presented seq, so the wait ends unless the host acked a seq it had not yet seen
-- presented; the host's next frame carrying that ack then releases it.
--
-- EXECUTION. One AXI-Lite transaction at a time (AW and W together, then B; or AR, then R).
-- WR_INC/RD_INC step the address by 4 per item, WR_FIX/RD_FIX hold it. MEM_RD issues AXI
-- read bursts of at most 16 beats (ARLEN <= 15, so AXI3-safe; ARLEN[7:4] = 0) that never
-- cross 4 KB, one burst outstanding, each 256-bit beat written to the response RAM as 8
-- words, low word first. The first non-OKAY BRESP/RRESP stops the op: no further items
-- are issued (an HBM burst in flight is drained), axi_resp keeps that first response.
-- Read data goes to the response RAM (rsp_we/rsp_waddr/rsp_wdata, word k of the response at
-- address k) and into the running rsp_crc: crc32_word (bit 0 first) over the words in
-- address order with init all ones and a final xor x"FFFFFFFF", which is the order the frame
-- core shifts them (word 0 first, each LSB first).
--
-- STATUS (st_out; fields per jc_ctl_pkg, all updated in ONE cycle when a frame completes,
-- so jc_status_sync's snapshot is always coherent):
--   last_done_seq  the seq of the last PASS non-NOP frame completed, including a frame
--                  that errored or was rejected by validation (so a host waiting on
--                  last_done_seq always sees its frame finish); x"FFFFFFFF" after reset;
--   rsp_seq/rsp_count/rsp_crc/rsp_valid  set together on a read that completed without an
--                  error (the RAM is fully written by then); rsp_valid cleared by the ack;
--                  rsp_seq x"FFFFFFFF" after reset; a failed read publishes nothing;
--   axi_err/axi_resp/err_seq  of the last PASS non-NOP frame: set when it errored, cleared
--                  ("0", "00", x"FFFFFFFF") when it did not; untouched by NOPs (sticky);
--   everything else, including the frame-core-owned fields and [383:213], is zero.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.jc_loader_pkg.all;
use work.jc_ctl_pkg.all;

entity jc_ctl_exec is
  generic(ADDR_W : positive := 33);
  port(
    clk            : in  std_logic;
    rst            : in  std_logic;                                   -- synchronous, high
    -- FIFO read side (TAG & word)
    q_valid        : in  std_logic;
    q_data         : in  std_logic_vector(JC_FIFO_W-1 downto 0);
    q_ready        : out std_logic;
    rsp_ack_tgl    : in  std_logic;                                   -- synchronised level
    -- AXI-Lite master
    m_axil_awaddr  : out std_logic_vector(31 downto 0);
    m_axil_awprot  : out std_logic_vector(2 downto 0);
    m_axil_awvalid : out std_logic;
    m_axil_awready : in  std_logic;
    m_axil_wdata   : out std_logic_vector(31 downto 0);
    m_axil_wstrb   : out std_logic_vector(3 downto 0);
    m_axil_wvalid  : out std_logic;
    m_axil_wready  : in  std_logic;
    m_axil_bresp   : in  std_logic_vector(1 downto 0);
    m_axil_bvalid  : in  std_logic;
    m_axil_bready  : out std_logic;
    m_axil_araddr  : out std_logic_vector(31 downto 0);
    m_axil_arprot  : out std_logic_vector(2 downto 0);
    m_axil_arvalid : out std_logic;
    m_axil_arready : in  std_logic;
    m_axil_rdata   : in  std_logic_vector(31 downto 0);
    m_axil_rresp   : in  std_logic_vector(1 downto 0);
    m_axil_rvalid  : in  std_logic;
    m_axil_rready  : out std_logic;
    -- AXI4 read-only master (HBM)
    m_axi_araddr   : out std_logic_vector(ADDR_W-1 downto 0);
    m_axi_arlen    : out std_logic_vector(7 downto 0);
    m_axi_arsize   : out std_logic_vector(2 downto 0);
    m_axi_arburst  : out std_logic_vector(1 downto 0);
    m_axi_arvalid  : out std_logic;
    m_axi_arready  : in  std_logic;
    m_axi_rdata    : in  std_logic_vector(255 downto 0);
    m_axi_rresp    : in  std_logic_vector(1 downto 0);
    m_axi_rlast    : in  std_logic;
    m_axi_rvalid   : in  std_logic;
    m_axi_rready   : out std_logic;
    -- response RAM write port
    rsp_we         : out std_logic;
    rsp_waddr      : out std_logic_vector(JC_CTL_RSP_AW-1 downto 0);
    rsp_wdata      : out std_logic_vector(31 downto 0);
    -- status toward jc_status_sync
    st_out         : out std_logic_vector(JC_CTL_STATUS_BITS-1 downto 0);
    busy           : out std_logic
  );
end entity;

architecture rtl of jc_ctl_exec is
  constant NONE : std_logic_vector(31 downto 0) := x"FFFFFFFF";

  type state_t is (S_RX, S_CHK, S_WAIT, S_GO, S_LRD0, S_LRD1, S_LW, S_LB, S_LAR, S_LR,
                   S_HAR, S_HR, S_HW, S_DONE);
  signal st : state_t := S_RX;

  -- the buffered frame
  signal have     : std_logic := '0';
  signal nrx      : unsigned(5 downto 0) := (others => '0');   -- 63 = too many
  signal h_seq    : std_logic_vector(31 downto 0) := (others => '0');
  signal h_op     : unsigned(7 downto 0) := (others => '0');
  signal h_cnt    : unsigned(15 downto 0) := (others => '0');
  signal h_nw     : unsigned(15 downto 0) := (others => '0');
  signal h_addr   : unsigned(63 downto 0) := (others => '0');
  signal h_ackv   : std_logic := '0';
  signal h_ackseq : std_logic_vector(31 downto 0) := (others => '0');

  type fram_t is array (0 to 63) of std_logic_vector(255 downto 0);
  signal fram  : fram_t;
  signal fr_we : std_logic := '0';
  signal fr_wa : unsigned(5 downto 0) := (others => '0');
  signal fr_wd : std_logic_vector(255 downto 0) := (others => '0');
  signal fr_ra : unsigned(5 downto 0) := (others => '0');
  signal fr_q  : std_logic_vector(255 downto 0) := (others => '0');

  -- execution
  signal it    : unsigned(9 downto 0) := (others => '0');      -- item index
  signal la    : unsigned(31 downto 0) := (others => '0');     -- AXI-Lite address
  signal ha    : unsigned(ADDR_W-1 downto 0) := (others => '0');
  signal bleft : unsigned(6 downto 0) := (others => '0');      -- MEM_RD beats not yet requested
  signal inb   : unsigned(4 downto 0) := (others => '0');      -- beats left in this burst
  signal hold  : std_logic_vector(255 downto 0) := (others => '0');
  signal k     : unsigned(2 downto 0) := (others => '0');
  signal crc   : std_logic_vector(31 downto 0) := (others => '1');
  signal e_f   : std_logic := '0';                             -- this frame errored
  signal e_r   : std_logic_vector(1 downto 0) := "00";

  -- AXI outputs
  signal l_awv, l_wv, l_bre, l_arv, l_rre : std_logic := '0';
  signal l_aw  : std_logic_vector(31 downto 0) := (others => '0');
  signal l_wd  : std_logic_vector(31 downto 0) := (others => '0');
  signal h_arv, h_rre : std_logic := '0';
  signal h_ara : std_logic_vector(ADDR_W-1 downto 0) := (others => '0');
  signal h_len : unsigned(3 downto 0) := (others => '0');
  signal r_we  : std_logic := '0';
  signal r_wa  : std_logic_vector(JC_CTL_RSP_AW-1 downto 0) := (others => '0');
  signal r_wd  : std_logic_vector(31 downto 0) := (others => '0');

  -- status
  signal s_lastd   : std_logic_vector(31 downto 0) := NONE;
  signal s_rseq   : std_logic_vector(31 downto 0) := NONE;
  signal s_rcnt   : unsigned(15 downto 0) := (others => '0');
  signal s_rvalid : std_logic := '0';
  signal s_rcrc   : std_logic_vector(31 downto 0) := (others => '0');
  signal s_err    : std_logic := '0';
  signal s_resp   : std_logic_vector(1 downto 0) := "00";
  signal s_eseq   : std_logic_vector(31 downto 0) := NONE;
  signal ack_prev : std_logic := '0';

  function is_wr(op : unsigned(7 downto 0)) return boolean is
  begin
    return op = JC_OP_WR_INC or op = JC_OP_WR_FIX;
  end function;
  function is_rd(op : unsigned(7 downto 0)) return boolean is
  begin
    return op = JC_OP_RD_INC or op = JC_OP_RD_FIX or op = JC_OP_MEM_RD;
  end function;
  function is_inc(op : unsigned(7 downto 0)) return boolean is
  begin
    return op = JC_OP_WR_INC or op = JC_OP_RD_INC;
  end function;
  -- Ruling (e): the header checks the frame core does not make
  function hdr_ok(op : unsigned(7 downto 0); cnt, nw : unsigned(15 downto 0);
                  a : unsigned(63 downto 0)) return boolean is
    variable nw_exp : unsigned(15 downto 0);
    variable bytes  : unsigned(64 downto 0);
    variable ok     : boolean;
  begin
    if is_wr(op) then
      nw_exp := shift_right(cnt + 7, 3);
    else
      nw_exp := (others => '0');
    end if;
    bytes := resize(a, 65) + resize(cnt & "00", 65);
    ok := op >= 1 and op <= 5 and cnt >= 1 and nw = nw_exp;
    if op = JC_OP_MEM_RD then
      ok := ok and a(4 downto 0) = "00000" and cnt(2 downto 0) = "000"
            and bytes <= shift_left(to_unsigned(1, 65), ADDR_W);
    else
      ok := ok and a(63 downto 32) = 0 and a(1 downto 0) = "00";
      if is_inc(op) then
        ok := ok and bytes <= shift_left(to_unsigned(1, 65), 32);
      end if;
    end if;
    return ok;
  end function;
  function burst_len(a : unsigned(ADDR_W-1 downto 0); r : unsigned(6 downto 0))
    return unsigned is
    variable to4k, n : unsigned(7 downto 0);
  begin
    to4k := to_unsigned(128, 8) - resize(a(11 downto 5), 8);
    n := to_unsigned(16, 8);
    if r < 16 then n := resize(r, 8); end if;
    if to4k < n then n := to4k; end if;
    return n(4 downto 0);
  end function;
  function item(w : std_logic_vector(255 downto 0); j : unsigned(2 downto 0))
    return std_logic_vector is
    variable x : natural := to_integer(j);
  begin
    return w(32 * x + 31 downto 32 * x);
  end function;
begin
  q_ready <= '1' when st = S_RX else '0';
  busy    <= '0' when st = S_RX else '1';

  m_axil_awaddr  <= l_aw;
  m_axil_awprot  <= "000";
  m_axil_awvalid <= l_awv;
  m_axil_wdata   <= l_wd;
  m_axil_wstrb   <= "1111";
  m_axil_wvalid  <= l_wv;
  m_axil_bready  <= l_bre;
  m_axil_araddr  <= std_logic_vector(la);
  m_axil_arprot  <= "000";
  m_axil_arvalid <= l_arv;
  m_axil_rready  <= l_rre;
  m_axi_araddr   <= h_ara;
  m_axi_arlen    <= "0000" & std_logic_vector(h_len);
  m_axi_arsize   <= "101";
  m_axi_arburst  <= "01";
  m_axi_arvalid  <= h_arv;
  m_axi_rready   <= h_rre;
  rsp_we         <= r_we;
  rsp_waddr      <= r_wa;
  rsp_wdata      <= r_wd;

  process(all)
    variable s : std_logic_vector(JC_CTL_STATUS_BITS-1 downto 0);
  begin
    s := (others => '0');
    s(JC_S_DONE_HI downto JC_S_DONE_LO)       := s_lastd;
    s(JC_S_RSPSEQ_HI downto JC_S_RSPSEQ_LO)   := s_rseq;
    s(JC_S_RSPCNT_HI downto JC_S_RSPCNT_LO)   := std_logic_vector(s_rcnt);
    s(JC_S_RSPVALID)                          := s_rvalid;
    s(JC_S_AXIERR)                            := s_err;
    s(JC_S_AXIRESP_HI downto JC_S_AXIRESP_LO) := s_resp;
    s(JC_S_ERRSEQ_HI downto JC_S_ERRSEQ_LO)   := s_eseq;
    s(JC_S_RSPCRC_HI downto JC_S_RSPCRC_LO)   := s_rcrc;
    st_out <= s;
  end process;

  -- frame RAM: one write port (receive), one registered read port (execute)
  process(clk)
  begin
    if rising_edge(clk) then
      if fr_we = '1' then
        fram(to_integer(fr_wa)) <= fr_wd;
      end if;
      fr_q <= fram(to_integer(fr_ra));
    end if;
  end process;

  process(clk)
    variable tag  : std_logic_vector(1 downto 0);
    variable word : std_logic_vector(255 downto 0);
    variable awd, wdn : boolean;
    variable bl   : unsigned(4 downto 0);
    variable last : boolean;
  begin
    if rising_edge(clk) then
      fr_we <= '0';
      r_we  <= '0';
      -- the host's ack: applied the cycle it is seen
      if rsp_ack_tgl /= ack_prev then
        ack_prev <= rsp_ack_tgl;
        s_rvalid <= '0';
      end if;

      case st is
        when S_RX =>
          if q_valid = '1' then
            tag  := q_data(JC_FIFO_W-1 downto JC_FIFO_W-2);
            word := q_data(255 downto 0);
            if tag = TAG_HDR then
              have     <= '1';
              nrx      <= (others => '0');
              h_seq    <= word(JC_H_SEQ_HI downto JC_H_SEQ_LO);
              h_op     <= unsigned(word(JC_H_OP_HI downto JC_H_OP_LO));
              h_cnt    <= unsigned(word(JC_H_COUNT_HI downto JC_H_COUNT_LO));
              h_nw     <= unsigned(word(JC_H_NWORDS_HI downto JC_H_NWORDS_LO));
              h_addr   <= unsigned(word(JC_H_ADDR_HI downto JC_H_ADDR_LO));
              h_ackv   <= word(JC_H_ACKVALID);
              h_ackseq <= word(JC_H_ACKSEQ_HI downto JC_H_ACKSEQ_LO);
            elsif tag = TAG_DATA then
              if have = '1' and nrx /= 63 then
                if nrx < JC_CTL_MAX_PAYLOAD then
                  fr_we <= '1';
                  fr_wa <= nrx;
                  fr_wd <= word;
                end if;
                nrx <= nrx + 1;
              end if;
            elsif tag = TAG_PASS then
              have <= '0';
              if have = '1' and word(31 downto 0) = h_seq and resize(nrx, 16) = h_nw then
                st <= S_CHK;
              end if;
            else
              have <= '0';
            end if;
          end if;

        when S_CHK =>
          e_f <= '0';
          e_r <= "00";
          if h_op = JC_OP_NOP then
            st <= S_RX;
          elsif not hdr_ok(h_op, h_cnt, h_nw, h_addr) then
            e_f <= '1'; e_r <= "10";
            st  <= S_DONE;
          elsif is_rd(h_op) and (h_seq = NONE or h_seq = s_rseq) then
            e_f <= '1'; e_r <= "01";
            st  <= S_DONE;
          else
            st <= S_WAIT;
          end if;

        when S_WAIT =>
          if is_rd(h_op) then
            if s_rvalid = '0' then
              st <= S_GO;
            end if;
          elsif not (h_ackv = '1' and h_ackseq = s_rseq and s_rvalid = '1') then
            st <= S_GO;
          end if;

        when S_GO =>
          it    <= (others => '0');
          crc   <= (others => '1');
          la    <= h_addr(31 downto 0);
          ha    <= h_addr(ADDR_W-1 downto 0);
          bleft <= h_cnt(9 downto 3);
          fr_ra <= (others => '0');
          if is_wr(h_op) then
            st <= S_LRD0;
          elsif h_op = JC_OP_MEM_RD then
            st <= S_HAR;
          else
            l_arv <= '1';
            st    <= S_LAR;
          end if;

        -- ---------------- AXI-Lite write ----------------
        when S_LRD0 =>                       -- fr_q loads fram(fr_ra) on this edge
          st <= S_LRD1;
        when S_LRD1 =>
          l_aw  <= std_logic_vector(la);
          l_wd  <= item(fr_q, it(2 downto 0));
          l_awv <= '1';
          l_wv  <= '1';
          st    <= S_LW;
        when S_LW =>
          awd := l_awv = '0' or m_axil_awready = '1';
          wdn := l_wv = '0' or m_axil_wready = '1';
          if m_axil_awready = '1' then l_awv <= '0'; end if;
          if m_axil_wready = '1' then l_wv <= '0'; end if;
          if awd and wdn then
            l_bre <= '1';
            st    <= S_LB;
          end if;
        when S_LB =>
          if m_axil_bvalid = '1' then
            l_bre <= '0';
            last  := it + 1 = h_cnt;
            if m_axil_bresp /= "00" then
              e_f <= '1'; e_r <= m_axil_bresp;
              st  <= S_DONE;
            elsif last then
              st <= S_DONE;
            else
              it <= it + 1;
              if h_op = JC_OP_WR_INC then
                la <= la + 4;
              end if;
              fr_ra <= resize(shift_right(it + 1, 3), 6);
              st    <= S_LRD0;
            end if;
          end if;

        -- ---------------- AXI-Lite read ----------------
        when S_LAR =>
          if m_axil_arready = '1' then
            l_arv <= '0';
            l_rre <= '1';
            st    <= S_LR;
          end if;
        when S_LR =>
          if m_axil_rvalid = '1' then
            l_rre <= '0';
            last  := it + 1 = h_cnt;
            if m_axil_rresp /= "00" then
              e_f <= '1'; e_r <= m_axil_rresp;
              st  <= S_DONE;
            else
              r_we <= '1';
              r_wa <= std_logic_vector(it(JC_CTL_RSP_AW-1 downto 0));
              r_wd <= m_axil_rdata;
              crc  <= crc32_word(crc, m_axil_rdata);
              it   <= it + 1;
              if last then
                st <= S_DONE;
              else
                if h_op = JC_OP_RD_INC then
                  la <= la + 4;
                end if;
                l_arv <= '1';
                st    <= S_LAR;
              end if;
            end if;
          end if;

        -- ---------------- HBM read (MEM_RD) ----------------
        when S_HAR =>
          if h_arv = '0' then
            bl    := burst_len(ha, bleft);
            h_ara <= std_logic_vector(ha);
            h_len <= resize(bl - 1, 4);
            inb   <= bl;
            h_arv <= '1';
          elsif m_axi_arready = '1' then
            h_arv <= '0';
            ha    <= ha + shift_left(resize(inb, ADDR_W), 5);
            bleft <= bleft - resize(inb, 7);
            h_rre <= '1';
            st    <= S_HR;
          end if;
        when S_HR =>
          if m_axi_rvalid = '1' then
            h_rre <= '0';
            hold  <= m_axi_rdata;
            if m_axi_rresp /= "00" and e_f = '0' then
              e_f <= '1'; e_r <= m_axi_rresp;
            end if;
            inb <= inb - 1;
            k   <= (others => '0');
            st  <= S_HW;
          end if;
        when S_HW =>
          r_we <= '1';
          r_wa <= std_logic_vector(it(JC_CTL_RSP_AW-1 downto 0));
          r_wd <= item(hold, k);
          crc  <= crc32_word(crc, item(hold, k));
          it   <= it + 1;
          k    <= k + 1;
          if k = 7 then
            if inb /= 0 then
              h_rre <= '1';
              st    <= S_HR;
            elsif e_f = '1' or bleft = 0 then
              st <= S_DONE;
            else
              st <= S_HAR;
            end if;
          end if;

        -- ---------------- completion: every status field in one cycle ----------------
        when S_DONE =>
          s_lastd <= h_seq;
          if e_f = '1' then
            s_err  <= '1';
            s_resp <= e_r;
            s_eseq <= h_seq;
          else
            s_err  <= '0';
            s_resp <= "00";
            s_eseq <= NONE;
            if is_rd(h_op) then
              s_rseq   <= h_seq;
              s_rcnt   <= h_cnt;
              s_rcrc   <= crc xor x"FFFFFFFF";
              s_rvalid <= '1';
            end if;
          end if;
          st <= S_RX;
      end case;

      if rst = '1' then
        st       <= S_RX;
        have     <= '0';
        l_awv    <= '0'; l_wv <= '0'; l_bre <= '0'; l_arv <= '0'; l_rre <= '0';
        h_arv    <= '0'; h_rre <= '0';
        r_we     <= '0';
        fr_we    <= '0';
        e_f      <= '0';
        s_lastd   <= NONE;
        s_rseq   <= NONE;
        s_rcnt   <= (others => '0');
        s_rvalid <= '0';
        s_rcrc   <= (others => '0');
        s_err    <= '0';
        s_resp   <= "00";
        s_eseq   <= NONE;
        ack_prev <= rsp_ack_tgl;
      end if;
    end if;
  end process;
end architecture;
