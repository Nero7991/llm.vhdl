-- rtl/tok_loop_fsm.vhd -- the host's per-position seam sequence, on the fabric (spec
-- 2026-11-04 sections 1.1, 2, 3; plan Task 2). Every value it writes, in order, is what
-- run_prompt writes over the same seam (server/pl_backend.c:1252-1415): SEQ_RESET and its
-- read-backs, then per position X_EXP, WIN_SEL 2, WIN_ADDR 0, n_embd WIN_DATA, SEQ_POS,
-- N_STEP 1, GO, poll STATUS for DONE|ERR, and from the last prompt position on, ARGMAX.
-- Role A also reads R_X (window 3) and XEXP_OUT into jc_link_tx, once the host has relayed
-- LINK_CREDIT >= p (plan D3), and sends it; its generated token comes from NEXT_TOKEN.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.tok_loop_pkg.all;

entity tok_loop_fsm is
  generic(N_EMBD : positive := 4096; PROMPT_MAX : positive := 4096; OUT_DEPTH : positive := 1024;
          HAS_GATHER : boolean := true; HAS_LINK : boolean := true; SEAM_TMO : positive := 65536);
  port(
    clk, rst     : in  std_logic;
    cfg          : in  tl_cfg_t;
    st           : out tl_stat_t;
    run_start    : out std_logic;
    pr_addr      : out unsigned(11 downto 0);
    pr_data      : in  unsigned(31 downto 0);
    out_we       : out std_logic;
    out_waddr    : out unsigned(15 downto 0);
    out_wdata    : out std_logic_vector(31 downto 0);
    loop_own     : out std_logic;
    owner        : in  std_logic;
    rs_req       : out std_logic;
    rs_tok       : out unsigned(31 downto 0);
    rs_exp_valid : in  std_logic;
    rs_exp       : in  std_logic_vector(31 downto 0);
    rs_err       : in  std_logic;
    rs_m_valid   : in  std_logic;
    rs_m_data    : in  std_logic_vector(15 downto 0);
    rs_m_ready   : out std_logic;
    rs_paused    : in  std_logic;
    tx_wr        : out std_logic;
    tx_widx      : out unsigned(11 downto 0);
    tx_wdata     : out std_logic_vector(31 downto 0);
    tx_send      : out std_logic;
    tx_pos       : out unsigned(31 downto 0);
    tx_exp       : out std_logic_vector(31 downto 0);
    tx_busy      : in  std_logic;
    tx_exhausted : in  std_logic;
    m_awaddr     : out std_logic_vector(11 downto 0);
    m_awvalid    : out std_logic;
    m_awready    : in  std_logic;
    m_wdata      : out std_logic_vector(31 downto 0);
    m_wstrb      : out std_logic_vector(3 downto 0);
    m_wvalid     : out std_logic;
    m_wready     : in  std_logic;
    m_bresp      : in  std_logic_vector(1 downto 0);
    m_bvalid     : in  std_logic;
    m_bready     : out std_logic;
    m_araddr     : out std_logic_vector(11 downto 0);
    m_arvalid    : out std_logic;
    m_arready    : in  std_logic;
    m_rdata      : in  std_logic_vector(31 downto 0);
    m_rresp      : in  std_logic_vector(1 downto 0);
    m_rvalid     : in  std_logic;
    m_rready     : out std_logic);
end entity;

architecture rtl of tok_loop_fsm is
  type fs_t is (F_IDLE, F_CHECK, F_TAKE, F_TXN, F_RS1, F_RS2, F_RS3, F_RS4, F_RS5,
                F_TOP, F_TOK1, F_TOK2, F_ROWREQ, F_ROWW, F_ROWEXP, F_WS, F_WA, F_DATA, F_DNEXT,
                F_NS, F_GO, F_POLL, F_PCHK, F_EWAIT, F_EINFO, F_DONE, F_XW, F_XA, F_XD, F_XD2, F_XE,
                F_TXW, F_TXB1, F_TXB2, F_GEN, F_TOKW, F_ARG, F_PUSH, F_SCHK, F_STOP, F_STOPPED);
  constant Z32 : std_logic_vector(31 downto 0) := (others => '0');
  signal fs, op_ret : fs_t := F_IDLE;
  signal op_wr : std_logic := '0';
  signal op_addr : natural range 0 to 4095 := 0;
  signal op_data, rd_r, tp_r, xexp_r, ax_rdata : std_logic_vector(31 downto 0) := (others => '0');
  signal ax_req, ax_done, ax_tmo, sent : std_logic := '0';
  signal ax_resp : std_logic_vector(1 downto 0);
  signal p, plen, maxn, kvmax, n_gen, tok, g, ecnt, lcnt, pcyc : unsigned(31 downto 0) := (others => '0');
  signal role_l, src_l, state2 : unsigned(1 downto 0) := "00";
  signal i : natural range 0 to N_EMBD := 0;
  signal lo16 : std_logic_vector(15 downto 0) := (others => '0');
  signal eng_run, abort_l, own_r, tok_take : std_logic := '0';
  signal reason : unsigned(7 downto 0) := (others => '0');
  signal err_addr, err_status, err_info, last_arg : std_logic_vector(31 downto 0) := (others => '0');
  signal row_tok, pos_cycles : unsigned(31 downto 0) := (others => '0');
  signal op_addr_u : unsigned(11 downto 0) := (others => '0');
begin
  -- GHDL 1.0.0 mcode miscompiles a generic-sized unsigned port fed directly by a
  -- to_unsigned(<signal>, ...) actual (trans.adb:553 INTERNAL_ERROR at -r, bisected
  -- 2026-11-05); an intermediate signal avoids it (deviation, Task 2).
  op_addr_u <= to_unsigned(op_addr, 12);
  axm : entity work.tok_loop_axm
    generic map(AW => 12)
    port map(clk => clk, rst => rst, req => ax_req, req_wr => op_wr,
             req_addr => op_addr_u, req_data => op_data,
             tmo_cyc => to_unsigned(SEAM_TMO, 32), done => ax_done, rdata => ax_rdata,
             resp => ax_resp, timed_out => ax_tmo,
             m_awaddr => m_awaddr, m_awvalid => m_awvalid, m_awready => m_awready,
             m_wdata => m_wdata, m_wstrb => m_wstrb, m_wvalid => m_wvalid, m_wready => m_wready,
             m_bresp => m_bresp, m_bvalid => m_bvalid, m_bready => m_bready,
             m_araddr => m_araddr, m_arvalid => m_arvalid, m_arready => m_arready,
             m_rdata => m_rdata, m_rresp => m_rresp, m_rvalid => m_rvalid, m_rready => m_rready);

  loop_own <= own_r;
  st.state <= state2;          st.reason <= reason;
  st.pos <= p;                 st.n_gen <= n_gen;
  st.need_row <= '1' when fs = F_ROWEXP and src_l = SRC_HOST else '0';
  st.need_token <= '1' when fs = F_TOKW else '0';
  st.out_full <= '1' when fs = F_PUSH and n_gen - cfg.out_ack >= OUT_DEPTH else '0';
  st.owns <= owner;
  st.tx_wait <= '1' when fs = F_XW else '0';
  st.link_wait <= '1' when fs = F_ROWEXP and src_l = SRC_LINK else '0';
  st.tok_take <= tok_take;
  st.err_addr <= err_addr;     st.err_status <= err_status;
  st.err_info <= err_info;     st.last_argmax <= last_arg;
  st.row_tok <= row_tok;       st.pos_cycles <= pos_cycles;
  st.kvmax <= kvmax;           st.row_src <= src_l;
  st.role <= role_l;

  process(clk)
    procedure txn(wr : std_logic; a : natural; d : std_logic_vector(31 downto 0); ret : fs_t) is
    begin
      op_wr <= wr; op_addr <= a; op_data <= d; op_ret <= ret; fs <= F_TXN;
    end procedure;
    procedure stop(r : natural) is
    begin
      reason <= to_unsigned(r, 8); fs <= F_STOP;
    end procedure;
    impure function is_stop(v : unsigned(31 downto 0)) return boolean is
    begin
      for k in 0 to 7 loop
        if cfg.stop_id(k) = std_logic_vector(v) then return true; end if;
      end loop;
      return false;
    end function;
  begin
    if rising_edge(clk) then
      ax_req <= '0'; rs_req <= '0'; rs_m_ready <= '0'; out_we <= '0';
      tx_wr <= '0'; tx_send <= '0'; run_start <= '0'; tok_take <= '0';
      if eng_run = '1' then ecnt <= ecnt + 1; end if;
      if state2 = 1 then pcyc <= pcyc + 1; end if;
      if cfg.abort = '1' and state2 = 1 then abort_l <= '1'; end if;
      if rst = '1' then
        fs <= F_IDLE; own_r <= '0'; state2 <= "00"; reason <= (others => '0');
        eng_run <= '0'; abort_l <= '0'; sent <= '0';
      else
        case fs is
          when F_IDLE | F_STOPPED =>
            if cfg.clear = '1' then reason <= (others => '0'); state2 <= "00"; fs <= F_IDLE; end if;
            if cfg.start = '1' then fs <= F_CHECK; end if;
          when F_CHECK =>
            plen <= cfg.prompt_len; maxn <= cfg.max_new; role_l <= cfg.role; src_l <= cfg.row_src;
            p <= (others => '0'); n_gen <= (others => '0'); abort_l <= '0';
            err_addr <= Z32; err_status <= Z32; err_info <= Z32;
            reason <= (others => '0'); state2 <= "01"; run_start <= '1';
            if cfg.prompt_len = 0 or cfg.prompt_len > PROMPT_MAX or cfg.max_new = 0
               or cfg.role = 3 or cfg.row_src = 3
               or ((cfg.row_src = SRC_LINK) /= (cfg.role = ROLE_B))
               or (cfg.row_src = SRC_GATHER and not HAS_GATHER)
               or (cfg.role /= ROLE_SINGLE and not HAS_LINK) then
              stop(R_BAD_CONFIG);
            else
              fs <= F_TAKE;
            end if;
          when F_TAKE =>
            own_r <= '1';
            if owner = '1' then
              txn('1', SM_CTRL, tl_u32(CTRL_SEQ_RESET), F_RS1);
            end if;
          when F_TXN =>
            if sent = '0' then
              ax_req <= '1'; sent <= '1';
            elsif ax_done = '1' then
              sent <= '0';
              if ax_resp /= "00" then
                err_addr <= tl_u32(op_addr); stop(R_SEAM_ERR);
              else
                rd_r <= ax_rdata; fs <= op_ret;
              end if;
            end if;
          when F_RS1 => txn('0', SM_STATUS, Z32, F_RS2);
          when F_RS2 =>
            if rd_r(2) = '1' then err_status <= rd_r; stop(R_SEQ_RESET_FAIL);
            else txn('0', SM_TOK_POS, Z32, F_RS3); end if;
          when F_RS3 => tp_r <= rd_r; txn('0', SM_SEQ_POS, Z32, F_RS4);
          when F_RS4 =>
            if unsigned(tp_r) /= 0 or unsigned(rd_r) /= 0 then stop(R_SEQ_RESET_FAIL);
            else txn('0', SM_KV_MAXPOS, Z32, F_RS5); end if;
          when F_RS5 => kvmax <= unsigned(rd_r); fs <= F_TOP;
          when F_TOP =>
            pcyc <= (others => '0');
            if abort_l = '1' then stop(R_ABORT);
            elsif tx_exhausted = '1' and role_l = ROLE_A then stop(R_LINK_RETRY_EXHAUSTED);
            elsif p >= kvmax then stop(R_MAXPOS);
            elsif p < plen then
              pr_addr <= p(11 downto 0); fs <= F_TOK1;
            else
              tok <= g; fs <= F_ROWREQ;
            end if;
          when F_TOK1 => fs <= F_TOK2;
          when F_TOK2 => tok <= pr_data; fs <= F_ROWREQ;
          when F_ROWREQ =>
            rs_req <= '1'; rs_tok <= tok; row_tok <= tok; lcnt <= (others => '0'); fs <= F_ROWW;
          when F_ROWW => fs <= F_ROWEXP;      -- the source clears a previous error on req
          when F_ROWEXP =>
            if rs_err = '1' then stop(R_GATHER_ERR);
            elsif rs_exp_valid = '1' then
              txn('1', SM_X_EXP, rs_exp, F_WS);
            elsif abort_l = '1' then stop(R_ABORT);
            elsif src_l = SRC_LINK then
              if rs_paused = '0' then lcnt <= lcnt + 1; end if;
              if lcnt >= cfg.tmo_link then stop(R_LINK_TIMEOUT); end if;
            end if;
          when F_WS => txn('1', SM_WIN_SEL, tl_u32(WIN_XIN), F_WA);
          when F_WA => i <= 0; txn('1', SM_WIN_ADDR, Z32, F_DATA);
          when F_DATA =>
            if rs_m_valid = '1' then
              rs_m_ready <= '1';
              txn('1', SM_WIN_DATA, x"0000" & rs_m_data, F_DNEXT);
            end if;
          when F_DNEXT =>
            if i = N_EMBD - 1 then
              txn('1', SM_SEQ_POS, std_logic_vector(p), F_NS);
            else
              i <= i + 1; fs <= F_DATA;
            end if;
          when F_NS => txn('1', SM_N_STEP, tl_u32(1), F_GO);
          when F_GO =>
            ecnt <= (others => '0'); eng_run <= '1';
            txn('1', SM_CTRL, tl_u32(CTRL_GO), F_POLL);
          when F_POLL => txn('0', SM_STATUS, Z32, F_PCHK);
          when F_PCHK =>
            if rd_r(0) = '1' then
              eng_run <= '0'; pos_cycles <= pcyc; fs <= F_DONE;
            elsif rd_r(2) = '1' then
              err_status <= rd_r; fs <= F_EWAIT;
            elsif ecnt >= cfg.tmo_engine then
              err_status <= rd_r; eng_run <= '0'; stop(R_ENGINE_TIMEOUT);
            else
              fs <= F_POLL;
            end if;
          when F_EWAIT =>
            if rd_r(1) = '0' then eng_run <= '0'; txn('0', SM_ERR_INFO, Z32, F_EINFO);
            elsif ecnt >= cfg.tmo_engine then eng_run <= '0'; stop(R_ENGINE_TIMEOUT);
            else txn('0', SM_STATUS, Z32, F_EWAIT); end if;
          when F_EINFO => err_info <= rd_r; stop(R_ENGINE_ERR);
          when F_DONE =>
            if role_l = ROLE_A then fs <= F_XW; else fs <= F_GEN; end if;
          when F_XW =>                                    -- plan D3: B has popped every frame before p
            if tx_exhausted = '1' then stop(R_LINK_RETRY_EXHAUSTED);
            elsif abort_l = '1' then stop(R_ABORT);
            elsif cfg.link_credit >= p then txn('1', SM_WIN_SEL, tl_u32(WIN_XOUT), F_XA);
            end if;
          when F_XA => i <= 0; txn('1', SM_WIN_ADDR, Z32, F_XD);
          when F_XD => txn('0', SM_WIN_DATA, Z32, F_XD2);
          when F_XD2 =>
            if (i mod 2) = 0 then
              lo16 <= rd_r(15 downto 0);
            else
              tx_wr <= '1'; tx_widx <= to_unsigned(i / 2, 12); tx_wdata <= rd_r(15 downto 0) & lo16;
            end if;
            if i = N_EMBD - 1 then txn('0', SM_XEXP_OUT, Z32, F_XE);
            else i <= i + 1; fs <= F_XD; end if;
          when F_XE => xexp_r <= rd_r; fs <= F_TXW;
          when F_TXW =>
            if tx_busy = '0' then
              tx_send <= '1'; tx_pos <= p; tx_exp <= xexp_r; fs <= F_TXB1;
            elsif abort_l = '1' then stop(R_ABORT);
            end if;
          when F_TXB1 => fs <= F_TXB2;
          when F_TXB2 =>
            if tx_busy = '0' then fs <= F_GEN;
            elsif abort_l = '1' then stop(R_ABORT);
            end if;
          when F_GEN =>
            if p + 1 < plen then p <= p + 1; fs <= F_TOP;
            elsif role_l = ROLE_A then fs <= F_TOKW;
            else txn('0', SM_ARGMAX, Z32, F_ARG); end if;
          when F_TOKW =>
            if cfg.next_tok_v = '1' then
              g <= cfg.next_tok; tok_take <= '1'; fs <= F_PUSH;
            elsif tx_exhausted = '1' then stop(R_LINK_RETRY_EXHAUSTED);
            elsif abort_l = '1' then stop(R_ABORT);
            end if;
          when F_ARG => g <= unsigned(rd_r); last_arg <= rd_r; fs <= F_PUSH;
          when F_PUSH =>
            if n_gen - cfg.out_ack >= OUT_DEPTH then
              if abort_l = '1' then stop(R_ABORT); end if;
            else
              out_we <= '1'; out_waddr <= n_gen(15 downto 0); out_wdata <= std_logic_vector(g);
              n_gen <= n_gen + 1; fs <= F_SCHK;
            end if;
          when F_SCHK =>
            if is_stop(g) then stop(R_STOP_ID);
            elsif n_gen >= maxn then stop(R_MAX_NEW);
            else p <= p + 1; fs <= F_TOP; end if;
          when F_STOP =>
            own_r <= '0'; eng_run <= '0'; state2 <= "10"; fs <= F_STOPPED;
        end case;
      end if;
    end if;
  end process;
end architecture;
