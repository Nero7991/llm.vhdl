-- rtl/tok_loop.vhd -- the on-fabric token loop of one die (spec 2026-11-04 sections 1, 1b, 3;
-- plan Task 6): control slave + seam-master FSM + seam ownership mux + the three row
-- sources (HBM gather, host row buffer, die-to-die link) + the link framer and deframer.
-- Each row source restarts at START (the host and link sources on run_start, the gather by
-- the reset below), so a run ABORTed mid-row never leaves a source holding a stale row.
-- Single clock: the Aurora clock crossing is jc_tok_top's.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.tok_loop_pkg.all;

entity tok_loop is
  generic(N_EMBD : positive := 5120; PROMPT_MAX : positive := 4096; OUT_DEPTH : positive := 1024;
          HAS_GATHER : boolean := true; HAS_LINK : boolean := true; NLANES : positive := 1;
          RXDEPTH : positive := 2; SEAM_TMO : positive := 65536);
  port(
    clk, rst       : in  std_logic;
    s_ctl_awaddr   : in  std_logic_vector(15 downto 0);
    s_ctl_awvalid  : in  std_logic;
    s_ctl_awready  : out std_logic;
    s_ctl_wdata    : in  std_logic_vector(31 downto 0);
    s_ctl_wstrb    : in  std_logic_vector(3 downto 0);
    s_ctl_wvalid   : in  std_logic;
    s_ctl_wready   : out std_logic;
    s_ctl_bresp    : out std_logic_vector(1 downto 0);
    s_ctl_bvalid   : out std_logic;
    s_ctl_bready   : in  std_logic;
    s_ctl_araddr   : in  std_logic_vector(15 downto 0);
    s_ctl_arvalid  : in  std_logic;
    s_ctl_arready  : out std_logic;
    s_ctl_rdata    : out std_logic_vector(31 downto 0);
    s_ctl_rresp    : out std_logic_vector(1 downto 0);
    s_ctl_rvalid   : out std_logic;
    s_ctl_rready   : in  std_logic;
    s_host_awaddr  : in  std_logic_vector(11 downto 0);
    s_host_awvalid : in  std_logic;
    s_host_awready : out std_logic;
    s_host_wdata   : in  std_logic_vector(31 downto 0);
    s_host_wstrb   : in  std_logic_vector(3 downto 0);
    s_host_wvalid  : in  std_logic;
    s_host_wready  : out std_logic;
    s_host_bresp   : out std_logic_vector(1 downto 0);
    s_host_bvalid  : out std_logic;
    s_host_bready  : in  std_logic;
    s_host_araddr  : in  std_logic_vector(11 downto 0);
    s_host_arvalid : in  std_logic;
    s_host_arready : out std_logic;
    s_host_rdata   : out std_logic_vector(31 downto 0);
    s_host_rresp   : out std_logic_vector(1 downto 0);
    s_host_rvalid  : out std_logic;
    s_host_rready  : in  std_logic;
    m_seam_awaddr  : out std_logic_vector(11 downto 0);
    m_seam_awvalid : out std_logic;
    m_seam_awready : in  std_logic;
    m_seam_wdata   : out std_logic_vector(31 downto 0);
    m_seam_wstrb   : out std_logic_vector(3 downto 0);
    m_seam_wvalid  : out std_logic;
    m_seam_wready  : in  std_logic;
    m_seam_bresp   : in  std_logic_vector(1 downto 0);
    m_seam_bvalid  : in  std_logic;
    m_seam_bready  : out std_logic;
    m_seam_araddr  : out std_logic_vector(11 downto 0);
    m_seam_arvalid : out std_logic;
    m_seam_arready : in  std_logic;
    m_seam_rdata   : in  std_logic_vector(31 downto 0);
    m_seam_rresp   : in  std_logic_vector(1 downto 0);
    m_seam_rvalid  : in  std_logic;
    m_seam_rready  : out std_logic;
    host_refused   : out std_logic;
    m_hbm_araddr   : out std_logic_vector(32 downto 0);
    m_hbm_arlen    : out std_logic_vector(7 downto 0);
    m_hbm_arsize   : out std_logic_vector(2 downto 0);
    m_hbm_arburst  : out std_logic_vector(1 downto 0);
    m_hbm_arvalid  : out std_logic;
    m_hbm_arready  : in  std_logic;
    m_hbm_rdata    : in  std_logic_vector(255 downto 0);
    m_hbm_rresp    : in  std_logic_vector(1 downto 0);
    m_hbm_rlast    : in  std_logic;
    m_hbm_rvalid   : in  std_logic;
    m_hbm_rready   : out std_logic;
    ltx_tdata      : out std_logic_vector(64*NLANES-1 downto 0);
    ltx_tkeep      : out std_logic_vector(8*NLANES-1 downto 0);
    ltx_tlast      : out std_logic;
    ltx_tvalid     : out std_logic;
    ltx_tready     : in  std_logic;
    lrx_tdata      : in  std_logic_vector(64*NLANES-1 downto 0);
    lrx_tlast      : in  std_logic;
    lrx_tvalid     : in  std_logic;
    lnk_tx_up, lnk_rx_up, lnk_gtg_lock, lnk_pll_lock, lnk_rx_ovf : in std_logic;
    link_ctrl      : out std_logic_vector(31 downto 0));
end entity;

architecture rtl of tok_loop is
  constant W : positive := 2 * NLANES;
  function b2s(b : boolean) return std_logic is
  begin
    if b then return '1'; else return '0'; end if;
  end function;
  constant CAPS : std_logic_vector(31 downto 0) :=
    std_logic_vector(to_unsigned(RXDEPTH, 8)) & std_logic_vector(to_unsigned(NLANES, 4)) &
    "00" & b2s(HAS_LINK) & b2s(HAS_GATHER) & std_logic_vector(to_unsigned(N_EMBD, 16));
  signal cfg : tl_cfg_t;
  signal st : tl_stat_t;
  signal lnk : tl_lnk_t := TL_LNK_ZERO;
  signal run_start, loop_own, owner : std_logic;
  signal pr_addr : unsigned(11 downto 0);
  signal pr_data : unsigned(31 downto 0);
  signal out_we : std_logic;
  signal out_waddr : unsigned(15 downto 0);
  signal out_wdata : std_logic_vector(31 downto 0);
  signal hr_addr : unsigned(12 downto 0) := (others => '0');
  signal hr_data : std_logic_vector(15 downto 0);
  -- the FSM's seam master
  signal l_awaddr, l_araddr : std_logic_vector(11 downto 0);
  signal l_awvalid, l_awready, l_wvalid, l_wready, l_bvalid, l_bready : std_logic;
  signal l_arvalid, l_arready, l_rvalid, l_rready : std_logic;
  signal l_wdata, l_rdata : std_logic_vector(31 downto 0);
  signal l_wstrb : std_logic_vector(3 downto 0);
  signal l_bresp, l_rresp : std_logic_vector(1 downto 0);
  -- the row-source bus as the FSM sees it, and each source's copy
  signal rs_req, rs_ev, rs_err, rs_mv, rs_mr, rs_paused : std_logic;
  signal rs_tok : unsigned(31 downto 0);
  signal rs_exp : std_logic_vector(31 downto 0);
  signal rs_md : std_logic_vector(15 downto 0);
  signal g_ev, g_err, g_mv : std_logic := '0';
  signal g_exp : std_logic_vector(31 downto 0) := (others => '0');
  signal g_md : std_logic_vector(15 downto 0) := (others => '0');
  signal h_ev, h_mv : std_logic := '0';
  signal h_exp : std_logic_vector(31 downto 0) := (others => '0');
  signal h_md : std_logic_vector(15 downto 0) := (others => '0');
  signal k_ev, k_mv : std_logic := '0';
  signal k_exp : std_logic_vector(31 downto 0) := (others => '0');
  signal k_md : std_logic_vector(15 downto 0) := (others => '0');
  type hs_t is (H_IDLE, H_ARM, H_RD1, H_RD2, H_PRES);
  type ks_t is (K_IDLE, K_WAIT, K_RD1, K_RD2, K_PRES);
  signal hs : hs_t := H_IDLE;
  signal ks : ks_t := K_IDLE;
  signal h_idx, k_idx : natural range 0 to N_EMBD - 1 := 0;
  -- link
  signal tx_wr, tx_send, tx_busy, tx_exh : std_logic := '0';
  signal tx_widx : unsigned(11 downto 0);
  signal tx_wdata, tx_exp : std_logic_vector(31 downto 0);
  signal tx_pos : unsigned(31 downto 0);
  signal rx_hval, rx_bad, rx_down, rx_pop : std_logic := '0';
  signal rx_hpos : unsigned(31 downto 0);
  signal rx_hexp, rx_rdata : std_logic_vector(31 downto 0) := (others => '0');
  signal rx_idx : unsigned(11 downto 0) := (others => '0');
  signal f_sent, f_res, f_good, f_crc, f_sp, f_ld, f_ov, f_cons : unsigned(31 downto 0) := (others => '0');
begin
  regs : entity work.tok_loop_regs
    generic map(N_EMBD => N_EMBD, PROMPT_MAX => PROMPT_MAX, OUT_DEPTH => OUT_DEPTH, CAPS => CAPS)
    port map(clk => clk, rst => rst,
             s_awaddr => s_ctl_awaddr, s_awvalid => s_ctl_awvalid, s_awready => s_ctl_awready,
             s_wdata => s_ctl_wdata, s_wstrb => s_ctl_wstrb, s_wvalid => s_ctl_wvalid,
             s_wready => s_ctl_wready, s_bresp => s_ctl_bresp, s_bvalid => s_ctl_bvalid,
             s_bready => s_ctl_bready, s_araddr => s_ctl_araddr, s_arvalid => s_ctl_arvalid,
             s_arready => s_ctl_arready, s_rdata => s_ctl_rdata, s_rresp => s_ctl_rresp,
             s_rvalid => s_ctl_rvalid, s_rready => s_ctl_rready,
             cfg => cfg, st => st, lnk => lnk, pr_addr => pr_addr, pr_data => pr_data,
             out_we => out_we, out_waddr => out_waddr, out_wdata => out_wdata,
             hr_addr => hr_addr, hr_data => hr_data);

  fsm : entity work.tok_loop_fsm
    generic map(N_EMBD => N_EMBD, PROMPT_MAX => PROMPT_MAX, OUT_DEPTH => OUT_DEPTH,
                HAS_GATHER => HAS_GATHER, HAS_LINK => HAS_LINK, SEAM_TMO => SEAM_TMO)
    port map(clk => clk, rst => rst, cfg => cfg, st => st, run_start => run_start,
             pr_addr => pr_addr, pr_data => pr_data,
             out_we => out_we, out_waddr => out_waddr, out_wdata => out_wdata,
             loop_own => loop_own, owner => owner,
             rs_req => rs_req, rs_tok => rs_tok, rs_exp_valid => rs_ev, rs_exp => rs_exp,
             rs_err => rs_err, rs_m_valid => rs_mv, rs_m_data => rs_md, rs_m_ready => rs_mr,
             rs_paused => rs_paused,
             tx_wr => tx_wr, tx_widx => tx_widx, tx_wdata => tx_wdata, tx_send => tx_send,
             tx_pos => tx_pos, tx_exp => tx_exp, tx_busy => tx_busy, tx_exhausted => tx_exh,
             m_awaddr => l_awaddr, m_awvalid => l_awvalid, m_awready => l_awready,
             m_wdata => l_wdata, m_wstrb => l_wstrb, m_wvalid => l_wvalid, m_wready => l_wready,
             m_bresp => l_bresp, m_bvalid => l_bvalid, m_bready => l_bready,
             m_araddr => l_araddr, m_arvalid => l_arvalid, m_arready => l_arready,
             m_rdata => l_rdata, m_rresp => l_rresp, m_rvalid => l_rvalid, m_rready => l_rready);

  mux : entity work.jc_seam_mux
    generic map(AW => 12)
    port map(clk => clk, rst => rst, loop_own => loop_own, owner => owner, host_refused => host_refused,
             s_h_awaddr => s_host_awaddr, s_h_awvalid => s_host_awvalid, s_h_awready => s_host_awready,
             s_h_wdata => s_host_wdata, s_h_wstrb => s_host_wstrb, s_h_wvalid => s_host_wvalid,
             s_h_wready => s_host_wready, s_h_bresp => s_host_bresp, s_h_bvalid => s_host_bvalid,
             s_h_bready => s_host_bready, s_h_araddr => s_host_araddr, s_h_arvalid => s_host_arvalid,
             s_h_arready => s_host_arready, s_h_rdata => s_host_rdata, s_h_rresp => s_host_rresp,
             s_h_rvalid => s_host_rvalid, s_h_rready => s_host_rready,
             s_l_awaddr => l_awaddr, s_l_awvalid => l_awvalid, s_l_awready => l_awready,
             s_l_wdata => l_wdata, s_l_wstrb => l_wstrb, s_l_wvalid => l_wvalid, s_l_wready => l_wready,
             s_l_bresp => l_bresp, s_l_bvalid => l_bvalid, s_l_bready => l_bready,
             s_l_araddr => l_araddr, s_l_arvalid => l_arvalid, s_l_arready => l_arready,
             s_l_rdata => l_rdata, s_l_rresp => l_rresp, s_l_rvalid => l_rvalid, s_l_rready => l_rready,
             m_awaddr => m_seam_awaddr, m_awvalid => m_seam_awvalid, m_awready => m_seam_awready,
             m_wdata => m_seam_wdata, m_wstrb => m_seam_wstrb, m_wvalid => m_seam_wvalid,
             m_wready => m_seam_wready, m_bresp => m_seam_bresp, m_bvalid => m_seam_bvalid,
             m_bready => m_seam_bready, m_araddr => m_seam_araddr, m_arvalid => m_seam_arvalid,
             m_arready => m_seam_arready, m_rdata => m_seam_rdata, m_rresp => m_seam_rresp,
             m_rvalid => m_seam_rvalid, m_rready => m_seam_rready);

  -- ---- the row-source mux: the FSM's latched ROW_SRC picks one source ----------------
  rs_ev <= g_ev when st.row_src = SRC_GATHER else h_ev when st.row_src = SRC_HOST else k_ev;
  rs_exp <= g_exp when st.row_src = SRC_GATHER else h_exp when st.row_src = SRC_HOST else k_exp;
  rs_mv <= g_mv when st.row_src = SRC_GATHER else h_mv when st.row_src = SRC_HOST else k_mv;
  rs_md <= g_md when st.row_src = SRC_GATHER else h_md when st.row_src = SRC_HOST else k_md;
  rs_err <= g_err when st.row_src = SRC_GATHER else '0';
  rs_paused <= (rx_bad or rx_down) when st.row_src = SRC_LINK else '0';

  -- ---- gather (spec 1.4) ---------------------------------------------------------------
  g_gather : if HAS_GATHER generate
    -- START resets the gather: an ABORT (F_ROWEXP, or F_DATA mid-row) can leave it reading or
    -- emitting a row nobody takes, and a request made then would be lost. The reset waits for
    -- a cycle with no HBM read in flight and no AR offered, so the AXI3 port never sees a
    -- reset mid-burst; a request that arrives meanwhile is held and issued after it.
    signal g_req, g_rst, g_kill, g_req_in : std_logic;
    signal g_dirty, g_reqp, g_inflt : std_logic := '0';
    signal g_arv, g_rr : std_logic;
  begin
    g_req_in <= rs_req when st.row_src = SRC_GATHER else '0';
    g_kill <= g_dirty and not g_inflt and not g_arv;
    g_req <= (g_req_in or g_reqp) and not g_dirty;
    g_rst <= rst or g_kill;
    m_hbm_arvalid <= g_arv;  m_hbm_rready <= g_rr;
    g_ctl : process(clk)
    begin
      if rising_edge(clk) then
        if rst = '1' then
          g_dirty <= '0'; g_reqp <= '0'; g_inflt <= '0';
        else
          if g_arv = '1' and m_hbm_arready = '1' then g_inflt <= '1';
          elsif m_hbm_rvalid = '1' and g_rr = '1' and m_hbm_rlast = '1' then g_inflt <= '0'; end if;
          if run_start = '1' then g_dirty <= '1'; g_reqp <= '0';
          else
            if g_kill = '1' then g_dirty <= '0'; end if;
            if g_req = '1' then g_reqp <= '0';
            elsif g_req_in = '1' then g_reqp <= '1'; end if;
          end if;
        end if;
      end if;
    end process;
    gat : entity work.embed_gather
      generic map(N_EMBD => N_EMBD, ADDR_W => 33)
      port map(clk => clk, rst => g_rst, emb_base => cfg.emb_base, invalidate => run_start,
               req => g_req, tok => rs_tok, exp_valid => g_ev, exp_val => g_exp, err => g_err,
               err_code => open, m_valid => g_mv, m_data => g_md,
               m_ready => rs_mr and b2s(st.row_src = SRC_GATHER),
               m_axi_araddr => m_hbm_araddr, m_axi_arlen => m_hbm_arlen, m_axi_arsize => m_hbm_arsize,
               m_axi_arburst => m_hbm_arburst, m_axi_arvalid => g_arv,
               m_axi_arready => m_hbm_arready, m_axi_rdata => m_hbm_rdata, m_axi_rresp => m_hbm_rresp,
               m_axi_rlast => m_hbm_rlast, m_axi_rvalid => m_hbm_rvalid, m_axi_rready => g_rr);
  end generate;
  g_nogather : if not HAS_GATHER generate
    m_hbm_araddr <= (others => '0'); m_hbm_arlen <= (others => '0'); m_hbm_arsize <= "101";
    m_hbm_arburst <= "01"; m_hbm_arvalid <= '0'; m_hbm_rready <= '1';
  end generate;

  -- ---- host row buffer (NEED_ROW / ROW_READY, spec 1.3 "host" source) ---------------------
  host_src : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' or run_start = '1' then
        hs <= H_IDLE; h_ev <= '0'; h_mv <= '0';
      else
        case hs is
          when H_IDLE =>
            if rs_req = '1' and st.row_src = SRC_HOST then hs <= H_ARM; end if;
          when H_ARM =>
            if cfg.row_ready = '1' then
              h_exp <= cfg.row_exp; h_ev <= '1'; h_idx <= 0; hr_addr <= (others => '0'); hs <= H_RD1;
            end if;
          when H_RD1 => hs <= H_RD2;
          when H_RD2 => h_md <= hr_data; h_mv <= '1'; hs <= H_PRES;
          when H_PRES =>
            if rs_mr = '1' then
              h_mv <= '0';
              if h_idx = N_EMBD - 1 then
                h_ev <= '0'; hs <= H_IDLE;
              else
                h_idx <= h_idx + 1; hr_addr <= to_unsigned(h_idx + 1, 13); hs <= H_RD1;
              end if;
            end if;
        end case;
      end if;
    end if;
  end process;

  -- ---- the link (spec 1b) ----------------------------------------------------------------
  g_link : if HAS_LINK generate
  begin
    tx : entity work.jc_link_tx
      generic map(N_EMBD => N_EMBD, W => W)
      port map(clk => clk, rst => rst, run_start => run_start, fill_we => tx_wr, fill_idx => tx_widx,
               fill_data => tx_wdata, send => tx_send, send_pos => tx_pos, send_exp => tx_exp,
               resend => cfg.resend, resend_cap => cfg.resend_cap, busy => tx_busy, exhausted => tx_exh,
               frames_sent => f_sent, resends => f_res, m_tdata => ltx_tdata, m_tkeep => ltx_tkeep,
               m_tlast => ltx_tlast, m_tvalid => ltx_tvalid, m_tready => ltx_tready);
    rx : entity work.jc_link_rx
      generic map(N_EMBD => N_EMBD, W => W, DEPTH => RXDEPTH)
      port map(clk => clk, rst => rst, run_start => run_start, chan_up => lnk_rx_up,
               s_tdata => lrx_tdata, s_tlast => lrx_tlast, s_tvalid => lrx_tvalid,
               head_valid => rx_hval, head_pos => rx_hpos, head_exp => rx_hexp,
               rd_idx => rx_idx, rd_data => rx_rdata, pop => rx_pop, bad => rx_bad, down => rx_down,
               frames_good => f_good, crc_fails => f_crc, seqpos_bad => f_sp, link_downs => f_ld,
               overruns => f_ov, consumed => f_cons);

    link_src : process(clk)
    begin
      if rising_edge(clk) then
        rx_pop <= '0';
        if rst = '1' or run_start = '1' then
          ks <= K_IDLE; k_ev <= '0'; k_mv <= '0';
        else
          case ks is
            when K_IDLE =>
              if rs_req = '1' and st.row_src = SRC_LINK then ks <= K_WAIT; end if;
            when K_WAIT =>
              if rx_hval = '1' then
                k_exp <= rx_hexp; k_ev <= '1'; k_idx <= 0; rx_idx <= (others => '0'); ks <= K_RD1;
              end if;
            when K_RD1 => ks <= K_RD2;
            when K_RD2 =>
              if (k_idx mod 2) = 0 then k_md <= rx_rdata(15 downto 0); else k_md <= rx_rdata(31 downto 16); end if;
              k_mv <= '1'; ks <= K_PRES;
            when K_PRES =>
              if rs_mr = '1' then
                k_mv <= '0';
                if k_idx = N_EMBD - 1 then
                  k_ev <= '0'; rx_pop <= '1'; ks <= K_IDLE;
                else
                  k_idx <= k_idx + 1; rx_idx <= to_unsigned((k_idx + 1) / 2, 12); ks <= K_RD1;
                end if;
              end if;
          end case;
        end if;
      end if;
    end process;
  end generate;
  g_nolink : if not HAS_LINK generate
    ltx_tdata <= (others => '0'); ltx_tkeep <= (others => '0'); ltx_tlast <= '0'; ltx_tvalid <= '0';
  end generate;

  lnk.frames_sent <= f_sent;  lnk.resends <= f_res;     lnk.frames_good <= f_good;
  lnk.crc_fails <= f_crc;     lnk.seqpos_bad <= f_sp;   lnk.link_downs <= f_ld;
  lnk.overruns <= f_ov;       lnk.consumed <= f_cons;
  lnk.status <= (LS_TX_UP => lnk_tx_up, LS_RX_UP => lnk_rx_up, LS_GTG_LOCK => lnk_gtg_lock,
                 LS_PLL_LOCK => lnk_pll_lock, LS_PAUSED => rs_paused, LS_BAD => rx_bad,
                 LS_DOWN => rx_down, LS_TX_EXH => tx_exh, LS_RX_OVF => lnk_rx_ovf, others => '0');
  link_ctrl <= cfg.link_ctrl;
end architecture;
