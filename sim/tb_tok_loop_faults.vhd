-- sim/tb_tok_loop_faults.vhd -- tok_loop error, stop and timeout behaviour (spec 2026-11-04
-- section 3; plan Task 6 and the Review Focus list). N_EMBD 64 and OUT_DEPTH 4 keep it fast;
-- host rows are pl_embed_synthetic's. F0 is a clean reference run; every later case either
-- stops with the named reason or must reproduce F0's ids exactly. F17-F21 are the parked
-- Task 2/4 review findings folded into Task 6 (ledger "Task 2: Ruling: parked"): F17 ABORT
-- while the host holds the seam (F_TAKE), F18 OUT_ACK past N_GEN, and on a second DUT
-- (regs + FSM fed by a bench row source that can stall or fail mid-row) F19 a clean control,
-- F20 ABORT with the source stalled mid-row (F_DATA), F21 the source failing mid-row.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.axil_bfm_pkg.all;
use work.tok_loop_pkg.all;
use work.tok_loop_tb_pkg.all;

entity tb_tok_loop_faults is
end entity;

architecture sim of tb_tok_loop_faults is
  constant N : positive := 64;
  constant NREF : positive := 8;
  signal clk : std_logic := '0';
  signal rst, seam_rst, srst : std_logic := '1';
  signal cm, hm : axil_m2s_t := AXIL_M2S_IDLE;
  signal cs, hs : axil_s2m_t;
  signal s_awaddr, s_araddr : std_logic_vector(11 downto 0);
  signal s_awvalid, s_awready, s_wvalid, s_wready, s_bvalid, s_bready : std_logic;
  signal s_arvalid, s_arready, s_rvalid, s_rready : std_logic;
  signal s_wdata, s_rdata : std_logic_vector(31 downto 0);
  signal s_wstrb : std_logic_vector(3 downto 0);
  signal s_bresp, s_rresp : std_logic_vector(1 downto 0);
  signal wr_ev, refused : std_logic;
  signal wr_addr : std_logic_vector(11 downto 0);
  signal wr_data : std_logic_vector(31 downto 0);
  signal maxpos : natural := 16384;
  signal f_err_pos, f_hang_pos, f_slverr_off : integer := -1;
  signal f_tokpos_stuck : std_logic := '0';
  signal seq_resets, n_refused : natural := 0;
  signal ltx_v : std_logic;
  -- the second DUT: regs + FSM + its own seam, fed by bad_src below
  signal cm2 : axil_m2s_t := AXIL_M2S_IDLE;
  signal cs2 : axil_s2m_t;
  signal cfg2 : tl_cfg_t;
  signal st2 : tl_stat_t;
  signal pr_addr2, pr_addr2c : unsigned(11 downto 0);
  signal pr_data2 : unsigned(31 downto 0);
  signal out_we2 : std_logic;
  signal out_waddr2 : unsigned(15 downto 0);
  signal out_wdata2 : std_logic_vector(31 downto 0);
  signal own2, run_start2 : std_logic;
  signal b_req, b_ev, b_err, b_mv, b_mr : std_logic := '0';
  signal b_tok : unsigned(31 downto 0);
  signal b_exp : std_logic_vector(31 downto 0) := (others => '0');
  signal b_md : std_logic_vector(15 downto 0) := (others => '0');
  signal bs_mode : natural := 0;             -- 0 clean, 1 stall after 10 mantissas, 2 err after 10
  signal q_awaddr, q_araddr : std_logic_vector(11 downto 0);
  signal q_awvalid, q_awready, q_wvalid, q_wready, q_bvalid, q_bready : std_logic;
  signal q_arvalid, q_arready, q_rvalid, q_rready : std_logic;
  signal q_wdata, q_rdata : std_logic_vector(31 downto 0);
  signal q_wstrb : std_logic_vector(3 downto 0);
  signal q_bresp, q_rresp : std_logic_vector(1 downto 0);
begin
  clk <= not clk after 2.5 ns;
  srst <= rst or seam_rst;

  dut : entity work.tok_loop
    generic map(N_EMBD => N, OUT_DEPTH => 4, HAS_GATHER => false, HAS_LINK => true)
    port map(clk => clk, rst => rst,
             s_ctl_awaddr => cm.awaddr(15 downto 0), s_ctl_awvalid => cm.awvalid, s_ctl_awready => cs.awready,
             s_ctl_wdata => cm.wdata, s_ctl_wstrb => cm.wstrb, s_ctl_wvalid => cm.wvalid, s_ctl_wready => cs.wready,
             s_ctl_bresp => cs.bresp, s_ctl_bvalid => cs.bvalid, s_ctl_bready => cm.bready,
             s_ctl_araddr => cm.araddr(15 downto 0), s_ctl_arvalid => cm.arvalid, s_ctl_arready => cs.arready,
             s_ctl_rdata => cs.rdata, s_ctl_rresp => cs.rresp, s_ctl_rvalid => cs.rvalid, s_ctl_rready => cm.rready,
             s_host_awaddr => hm.awaddr(11 downto 0), s_host_awvalid => hm.awvalid, s_host_awready => hs.awready,
             s_host_wdata => hm.wdata, s_host_wstrb => hm.wstrb, s_host_wvalid => hm.wvalid, s_host_wready => hs.wready,
             s_host_bresp => hs.bresp, s_host_bvalid => hs.bvalid, s_host_bready => hm.bready,
             s_host_araddr => hm.araddr(11 downto 0), s_host_arvalid => hm.arvalid, s_host_arready => hs.arready,
             s_host_rdata => hs.rdata, s_host_rresp => hs.rresp, s_host_rvalid => hs.rvalid, s_host_rready => hm.rready,
             m_seam_awaddr => s_awaddr, m_seam_awvalid => s_awvalid, m_seam_awready => s_awready,
             m_seam_wdata => s_wdata, m_seam_wstrb => s_wstrb, m_seam_wvalid => s_wvalid, m_seam_wready => s_wready,
             m_seam_bresp => s_bresp, m_seam_bvalid => s_bvalid, m_seam_bready => s_bready,
             m_seam_araddr => s_araddr, m_seam_arvalid => s_arvalid, m_seam_arready => s_arready,
             m_seam_rdata => s_rdata, m_seam_rresp => s_rresp, m_seam_rvalid => s_rvalid, m_seam_rready => s_rready,
             host_refused => refused,
             m_hbm_araddr => open, m_hbm_arlen => open, m_hbm_arsize => open, m_hbm_arburst => open,
             m_hbm_arvalid => open, m_hbm_arready => '0', m_hbm_rdata => (others => '0'), m_hbm_rresp => "00",
             m_hbm_rlast => '0', m_hbm_rvalid => '0', m_hbm_rready => open,
             ltx_tdata => open, ltx_tkeep => open, ltx_tlast => open, ltx_tvalid => ltx_v, ltx_tready => '1',
             lrx_tdata => (others => '0'), lrx_tlast => '0', lrx_tvalid => '0',
             lnk_tx_up => '1', lnk_rx_up => '1', lnk_gtg_lock => '1', lnk_pll_lock => '1', lnk_rx_ovf => '0',
             link_ctrl => open);

  seam : entity work.seam_beh_model
    generic map(N_EMBD => N)
    port map(clk => clk, rst => srst, awaddr => s_awaddr, awvalid => s_awvalid, awready => s_awready,
             wdata => s_wdata, wvalid => s_wvalid, wready => s_wready, bresp => s_bresp,
             bvalid => s_bvalid, bready => s_bready, araddr => s_araddr, arvalid => s_arvalid,
             arready => s_arready, rdata => s_rdata, rresp => s_rresp, rvalid => s_rvalid,
             rready => s_rready, wr_ev => wr_ev, wr_addr => wr_addr, wr_data => wr_data,
             maxpos => maxpos, f_err_pos => f_err_pos, f_hang_pos => f_hang_pos,
             f_slverr_off => f_slverr_off, f_tokpos_stuck => f_tokpos_stuck);

  -- the FSM drives pr_addr from its first START; until then the RAM index is all 'U'
  pr_addr2c <= (others => '0') when is_x(pr_addr2) else pr_addr2;
  regs2 : entity work.tok_loop_regs
    generic map(N_EMBD => N, OUT_DEPTH => 4)
    port map(clk => clk, rst => rst,
             s_awaddr => cm2.awaddr(15 downto 0), s_awvalid => cm2.awvalid, s_awready => cs2.awready,
             s_wdata => cm2.wdata, s_wstrb => cm2.wstrb, s_wvalid => cm2.wvalid, s_wready => cs2.wready,
             s_bresp => cs2.bresp, s_bvalid => cs2.bvalid, s_bready => cm2.bready,
             s_araddr => cm2.araddr(15 downto 0), s_arvalid => cm2.arvalid, s_arready => cs2.arready,
             s_rdata => cs2.rdata, s_rresp => cs2.rresp, s_rvalid => cs2.rvalid, s_rready => cm2.rready,
             cfg => cfg2, st => st2, lnk => TL_LNK_ZERO, pr_addr => pr_addr2c, pr_data => pr_data2,
             out_we => out_we2, out_waddr => out_waddr2, out_wdata => out_wdata2,
             hr_addr => (others => '0'), hr_data => open);

  fsm2 : entity work.tok_loop_fsm
    generic map(N_EMBD => N, OUT_DEPTH => 4, HAS_GATHER => true, HAS_LINK => false)
    port map(clk => clk, rst => rst, cfg => cfg2, st => st2, run_start => run_start2,
             pr_addr => pr_addr2, pr_data => pr_data2,
             out_we => out_we2, out_waddr => out_waddr2, out_wdata => out_wdata2,
             loop_own => own2, owner => own2,
             rs_req => b_req, rs_tok => b_tok, rs_exp_valid => b_ev, rs_exp => b_exp,
             rs_err => b_err, rs_m_valid => b_mv, rs_m_data => b_md, rs_m_ready => b_mr,
             rs_paused => '0',
             tx_wr => open, tx_widx => open, tx_wdata => open, tx_send => open,
             tx_pos => open, tx_exp => open, tx_busy => '0', tx_exhausted => '0',
             m_awaddr => q_awaddr, m_awvalid => q_awvalid, m_awready => q_awready,
             m_wdata => q_wdata, m_wstrb => q_wstrb, m_wvalid => q_wvalid, m_wready => q_wready,
             m_bresp => q_bresp, m_bvalid => q_bvalid, m_bready => q_bready,
             m_araddr => q_araddr, m_arvalid => q_arvalid, m_arready => q_arready,
             m_rdata => q_rdata, m_rresp => q_rresp, m_rvalid => q_rvalid, m_rready => q_rready);

  seam2 : entity work.seam_beh_model
    generic map(N_EMBD => N)
    port map(clk => clk, rst => rst, awaddr => q_awaddr, awvalid => q_awvalid, awready => q_awready,
             wdata => q_wdata, wvalid => q_wvalid, wready => q_wready, bresp => q_bresp,
             bvalid => q_bvalid, bready => q_bready, araddr => q_araddr, arvalid => q_arvalid,
             arready => q_arready, rdata => q_rdata, rresp => q_rresp, rvalid => q_rvalid,
             rready => q_rready, wr_ev => open, wr_addr => open, wr_data => open);

  -- a row source that serves pl_embed_synthetic rows (as the host does) or misbehaves mid-row
  bad_src : process(clk)
    variable row : row16_arr(0 to N - 1);
    variable xe : std_logic_vector(31 downto 0);
    variable lat : integer := -1;
    variable idx : natural := 0;
    variable active : boolean := false;
  begin
    if rising_edge(clk) then
      if rst = '1' or run_start2 = '1' then
        b_ev <= '0'; b_mv <= '0'; b_err <= '0'; active := false; lat := -1;
      elsif b_req = '1' then
        synth_row(to_integer(b_tok), row, xe);
        b_err <= '0'; b_ev <= '0'; b_mv <= '0'; active := false; lat := 8; idx := 0;
      elsif lat > 0 then
        lat := lat - 1;
      elsif lat = 0 then
        lat := -1; active := true; b_ev <= '1'; b_exp <= xe; b_mv <= '1'; b_md <= row(0);
      elsif active and b_mr = '1' then
        b_mv <= '0';
        if idx = N - 1 then
          active := false; b_ev <= '0';
        elsif idx = 9 and bs_mode = 1 then
          active := false;                                  -- stalls: m_valid never returns
        elsif idx = 9 and bs_mode = 2 then
          active := false; b_ev <= '0'; b_err <= '1';       -- fails mid-row
        else
          idx := idx + 1; b_md <= row(idx); b_mv <= '1';
        end if;
      end if;
    end if;
  end process;

  count : process(clk)
  begin
    if rising_edge(clk) then
      if wr_ev = '1' and wr_addr = x"014" and wr_data = x"00000002" then seq_resets <= seq_resets + 1; end if;
      if refused = '1' then n_refused <= n_refused + 1; end if;
    end if;
  end process;

  host : process
    type ids_t is array (0 to NREF - 1) of natural;
    variable ref, got : ids_t := (others => 0);
    variable resp : std_logic_vector(1 downto 0);
    variable d, st, xexp : std_logic_vector(31 downto 0);
    variable row : row16_arr(0 to N - 1);
    variable e, c, acked, polls, sr0, j1 : natural := 0;
    procedure chk(ok : boolean; msg : string) is
    begin
      c := c + 1;
      if not ok then e := e + 1; report "tb_tok_loop_faults: " & msg severity error; end if;
    end procedure;
    procedure wr(a : natural; x : std_logic_vector(31 downto 0)) is
    begin
      axil_wr(clk, cm, cs, a, x, resp); chk(resp = "00", "control write OKAY");
    end procedure;
    procedure rd(a : natural; x : out std_logic_vector(31 downto 0)) is
    begin
      axil_rd(clk, cm, cs, a, x, resp);
    end procedure;
    procedure wr2(a : natural; x : std_logic_vector(31 downto 0)) is
    begin
      axil_wr(clk, cm2, cs2, a, x, resp); chk(resp = "00", "DUT2 control write OKAY");
    end procedure;
    procedure rd2(a : natural; x : out std_logic_vector(31 downto 0)) is
    begin
      axil_rd(clk, cm2, cs2, a, x, resp);
    end procedure;
    -- one DUT2 run (MAX_NEW NREF, rows from bad_src); returns when stopped or after `bound` polls
    procedure run2(bound : natural; tag : string) is
      variable n, nn : natural;
    begin
      wr2(TL_PROMPT_LEN, u32(3)); wr2(TL_MAX_NEW, u32(NREF)); wr2(TL_ROLE, u32(ROLE_SINGLE));
      wr2(TL_ROW_SRC, u32(SRC_GATHER)); wr2(TL_PROMPT_ADDR, u32(0));
      wr2(TL_PROMPT_DATA, u32(1)); wr2(TL_PROMPT_DATA, u32(2)); wr2(TL_PROMPT_DATA, u32(3));
      acked := 0; got := (others => 0);
      wr2(TL_CTRL, u32(1));
      n := 0;
      loop
        rd2(TL_STATUS, st);
        exit when st(1 downto 0) = "10" or n >= bound;
        rd2(TL_OUT_COUNT, d); nn := to_integer(unsigned(d));
        while acked < nn loop
          wr2(TL_OUT_ADDR, u32(acked)); rd2(TL_OUT_DATA, d);
          if acked < NREF then got(acked) := to_integer(unsigned(d)); end if;
          acked := acked + 1;
        end loop;
        wr2(TL_OUT_ACK, u32(acked));
        n := n + 1;
      end loop;
      rd2(TL_OUT_COUNT, d); nn := to_integer(unsigned(d));      -- the ids pushed before the stop
      while acked < nn loop
        wr2(TL_OUT_ADDR, u32(acked)); rd2(TL_OUT_DATA, d);
        if acked < NREF then got(acked) := to_integer(unsigned(d)); end if;
        acked := acked + 1;
      end loop;
    end procedure;
    procedure tick(n : natural) is
    begin
      for k in 1 to n loop wait until rising_edge(clk); end loop;
    end procedure;
    procedure reset_seam is
    begin
      seam_rst <= '1'; tick(3); seam_rst <= '0'; tick(3);
    end procedure;
    procedure setup(max_new : natural; role, src : natural) is
    begin
      wr(TL_PROMPT_LEN, u32(3)); wr(TL_MAX_NEW, u32(max_new));
      wr(TL_ROLE, u32(role)); wr(TL_ROW_SRC, u32(src));
      wr(TL_PROMPT_ADDR, u32(0));
      wr(TL_PROMPT_DATA, u32(1)); wr(TL_PROMPT_DATA, u32(2)); wr(TL_PROMPT_DATA, u32(3));
      acked := 0; got := (others => 0);
    end procedure;
    procedure serve_row is
    begin
      rd(TL_ROW_TOK, d); synth_row(to_integer(unsigned(d)), row, xexp);
      wr(TL_ROW_EXP, xexp); wr(TL_ROW_ADDR, u32(0));
      for j in 0 to N - 1 loop wr(TL_ROW_DATA, x"0000" & row(j)); end loop;
      wr(TL_CTRL, u32(8));
    end procedure;
    procedure drain is                       -- read new ids out of the 4-deep ring, then ack them
      variable n : natural;
    begin
      rd(TL_OUT_COUNT, d); n := to_integer(unsigned(d));
      while acked < n loop
        wr(TL_OUT_ADDR, u32(acked)); rd(TL_OUT_DATA, d);
        if acked < NREF then got(acked) := to_integer(unsigned(d)); end if;
        acked := acked + 1;
      end loop;
      wr(TL_OUT_ACK, u32(acked));
    end procedure;
    -- one pass of the host loop; mode 0 serve+drain, 1 serve only, 2 ABORT on NEED_ROW
    procedure step(mode : natural) is
    begin
      rd(TL_STATUS, st);
      if st(1 downto 0) /= "10" then
        if st(2) = '1' then
          if mode = 2 then wr(TL_CTRL, u32(2)); else serve_row; end if;
        end if;
        if mode = 0 then drain; end if;
      end if;
      polls := polls + 1;
      assert polls < 2000000 report "tb_tok_loop_faults: a case never stopped" severity failure;
    end procedure;
    procedure finish_run(mode : natural) is
    begin
      polls := 0;
      loop
        step(mode);
        exit when st(1 downto 0) = "10";
      end loop;
      if mode = 0 then drain; end if;
    end procedure;
    procedure expect(r : natural; tag : string) is
    begin
      rd(TL_STATUS, st);
      chk(st(1 downto 0) = "10", tag & ": stopped");
      chk(to_integer(unsigned(st(15 downto 8))) = r, tag & ": reason " & integer'image(r) &
          " (got " & integer'image(to_integer(unsigned(st(15 downto 8)))) & ")");
      chk(st(16) = '0', tag & ": seam released");
      axil_rd(clk, hm, hs, 16#8C#, d, resp);
      chk(resp = "00", tag & ": host seam access works after the stop");
    end procedure;
    procedure expect_ref(n : natural; tag : string) is
    begin
      rd(TL_N_GEN, d); chk(to_integer(unsigned(d)) = n, tag & ": N_GEN");
      for j in 0 to n - 1 loop chk(got(j) = ref(j), tag & ": id " & integer'image(j) & " equals F0's"); end loop;
    end procedure;
  begin
    tick(5); rst <= '0'; tick(5); seam_rst <= '0'; tick(2);
    -- F0: the reference
    setup(NREF, ROLE_SINGLE, SRC_HOST); wr(TL_CTRL, u32(1)); finish_run(0);
    expect(R_MAX_NEW, "F0");
    ref := got;
    rd(TL_N_GEN, d); chk(to_integer(unsigned(d)) = NREF, "F0: N_GEN");
    -- F1: ENGINE_ERR at position 2
    f_err_pos <= 2; setup(NREF, ROLE_SINGLE, SRC_HOST); wr(TL_CTRL, u32(1)); finish_run(0);
    expect(R_ENGINE_ERR, "F1");
    rd(TL_POS, d); chk(unsigned(d) = 2, "F1: POS latches the failing position");
    rd(TL_ERR_STATUS, d); chk(d(2) = '1', "F1: ERR_STATUS holds the seam's err bit");
    f_err_pos <= -1; reset_seam;
    -- F2: ENGINE_TIMEOUT at position 1
    f_hang_pos <= 1; wr(TL_TMO_ENGINE, u32(3000));
    setup(NREF, ROLE_SINGLE, SRC_HOST); wr(TL_CTRL, u32(1)); finish_run(0);
    expect(R_ENGINE_TIMEOUT, "F2");
    rd(TL_POS, d); chk(unsigned(d) = 1, "F2: POS");
    f_hang_pos <= -1; wr(TL_TMO_ENGINE, u32(TMO_DEFAULT)); reset_seam;
    -- F3: SEAM_ERR on N_STEP
    f_slverr_off <= 16#24#; setup(NREF, ROLE_SINGLE, SRC_HOST); wr(TL_CTRL, u32(1)); finish_run(0);
    expect(R_SEAM_ERR, "F3");
    rd(TL_ERR_ADDR, d); chk(unsigned(d) = 16#24#, "F3: ERR_ADDR names N_STEP");
    f_slverr_off <= -1; reset_seam;
    -- F4: ABORT while NEED_ROW
    setup(NREF, ROLE_SINGLE, SRC_HOST); wr(TL_CTRL, u32(1)); finish_run(2);
    expect(R_ABORT, "F4");
    -- F5: ABORT while OUT_FULL
    setup(NREF, ROLE_SINGLE, SRC_HOST); wr(TL_CTRL, u32(1));
    polls := 0;
    loop step(1); exit when st(7) = '1' or st(1 downto 0) = "10"; end loop;
    chk(st(7) = '1', "F5: OUT_FULL raised with nothing acked");
    wr(TL_CTRL, u32(2)); finish_run(1);
    expect(R_ABORT, "F5");
    rd(TL_N_GEN, d); chk(unsigned(d) = 4, "F5: N_GEN stopped at OUT_DEPTH");
    -- F6: the host touches the seam mid-run: refused, the loop is undisturbed
    setup(NREF, ROLE_SINGLE, SRC_HOST); wr(TL_CTRL, u32(1));
    polls := 0;
    loop step(0); rd(TL_POS, d); exit when unsigned(d) >= 1; end loop;
    axil_rd(clk, hm, hs, 16#8C#, d, resp); chk(resp = "10", "F6: host read mid-run gets SLVERR");
    axil_wr(clk, hm, hs, 16#20#, x"00000005", resp); chk(resp = "10", "F6: host write mid-run gets SLVERR");
    finish_run(0); expect(R_MAX_NEW, "F6"); expect_ref(NREF, "F6");
    chk(n_refused >= 2, "F6: both host accesses were counted as refused");
    -- F7: SEQ_RESET does not take
    f_tokpos_stuck <= '1'; setup(NREF, ROLE_SINGLE, SRC_HOST); wr(TL_CTRL, u32(1)); finish_run(0);
    expect(R_SEQ_RESET_FAIL, "F7");
    -- parked finding 1: the TOK_POS read (stuck at cur_pos + 1 = 1) and the SEQ_POS read (0)
    rd(TL_ERR_STATUS, d); chk(unsigned(d) = 1, "F7: ERR_STATUS latches the TOK_POS read (1)");
    rd(TL_ERR_INFO, d); chk(unsigned(d) = 0, "F7: ERR_INFO latches the SEQ_POS read (0)");
    f_tokpos_stuck <= '0'; reset_seam;
    -- F8: BAD_CONFIG
    setup(NREF, ROLE_SINGLE, SRC_HOST); wr(TL_PROMPT_LEN, u32(0)); wr(TL_CTRL, u32(1)); finish_run(0);
    expect(R_BAD_CONFIG, "F8a prompt_len 0");
    setup(NREF, ROLE_SINGLE, SRC_LINK); wr(TL_CTRL, u32(1)); finish_run(0);
    expect(R_BAD_CONFIG, "F8b link rows on a single die");
    -- F9: LINK_TIMEOUT (role B, nothing arrives)
    wr(TL_TMO_LINK, u32(5000)); setup(NREF, ROLE_B, SRC_LINK); wr(TL_CTRL, u32(1)); finish_run(0);
    expect(R_LINK_TIMEOUT, "F9");
    rd(TL_POS, d); chk(unsigned(d) = 0, "F9: timed out waiting for position 0");
    wr(TL_TMO_LINK, u32(TMO_DEFAULT));
    -- F10: KV_MAXPOS 4 ends the run cleanly (plan D9)
    maxpos <= 4; reset_seam;
    setup(NREF, ROLE_SINGLE, SRC_HOST); wr(TL_CTRL, u32(1)); finish_run(0);
    expect(R_MAXPOS, "F10"); expect_ref(2, "F10");
    rd(TL_KVMAX, d); chk(unsigned(d) = 4, "F10: KVMAX read at START");
    maxpos <= 16384; reset_seam;
    -- F11 (Review Focus 3): OUT never drained stalls, loses nothing, resumes on OUT_ACK
    setup(NREF, ROLE_SINGLE, SRC_HOST); wr(TL_CTRL, u32(1));
    polls := 0;
    loop step(1); exit when st(7) = '1'; end loop;
    tick(3000);
    rd(TL_N_GEN, d); chk(unsigned(d) = 4, "F11: stalled at OUT_DEPTH ids");
    rd(TL_STATUS, st); chk(st(7) = '1' and st(1 downto 0) = "01", "F11: still running, OUT_FULL");
    finish_run(0); expect(R_MAX_NEW, "F11"); expect_ref(NREF, "F11");
    -- F12 (Review Focus 1): config written mid-run is not used until the next START
    setup(NREF, ROLE_SINGLE, SRC_HOST); wr(TL_CTRL, u32(1));
    polls := 0;
    loop step(0); rd(TL_POS, d); exit when unsigned(d) >= 1; end loop;
    wr(TL_PROMPT_LEN, u32(1)); wr(TL_MAX_NEW, u32(2)); wr(TL_ROLE, u32(ROLE_A)); wr(TL_ROW_SRC, u32(SRC_GATHER));
    finish_run(0); expect(R_MAX_NEW, "F12"); expect_ref(NREF, "F12");
    -- F13 (Review Focus 2): START while running is ignored
    setup(NREF, ROLE_SINGLE, SRC_HOST); sr0 := seq_resets; wr(TL_CTRL, u32(1));
    polls := 0;
    loop step(0); rd(TL_POS, d); exit when unsigned(d) >= 2; end loop;
    wr(TL_CTRL, u32(1));
    finish_run(0); expect(R_MAX_NEW, "F13"); expect_ref(NREF, "F13");
    chk(seq_resets = sr0 + 1, "F13: one SEQ_RESET for the run, none for the second START");
    -- F14 (Review Focus 5): a second START with no reconfiguration repeats the ids
    acked := 0; got := (others => 0); wr(TL_CTRL, u32(1)); finish_run(0);
    expect(R_MAX_NEW, "F14"); expect_ref(NREF, "F14");
    -- F15: the last STOP_ID slot works (plan D8)
    j1 := 0;                                 -- the first id that has not occurred before it
    for j in 1 to NREF - 1 loop
      if j1 = 0 then
        j1 := j;
        for q in 0 to j - 1 loop
          if ref(q) = ref(j) then j1 := 0; end if;
        end loop;
      end if;
    end loop;
    chk(j1 > 0, "F15: F0 has an id that does not repeat an earlier one");
    setup(NREF, ROLE_SINGLE, SRC_HOST); wr(TL_STOP_ID0 + 28, u32(ref(j1))); wr(TL_CTRL, u32(1)); finish_run(0);
    expect(R_STOP_ID, "F15"); expect_ref(j1 + 1, "F15");
    wr(TL_STOP_ID0 + 28, x"FFFFFFFF");
    -- F16: role A sends frame p only when LINK_CREDIT >= p (plan D3)
    setup(1, ROLE_A, SRC_HOST); wr(TL_LINK_CREDIT, u32(0)); wr(TL_CTRL, u32(1));
    polls := 0;
    loop step(1); exit when st(17) = '1'; end loop;
    tick(3000);
    rd(TL_FRAMES_SENT, d); chk(unsigned(d) = 1, "F16: one frame sent, then waiting for credit");
    rd(TL_STATUS, st); chk(st(17) = '1', "F16: TX_WAIT_CREDIT shown");
    wr(TL_LINK_CREDIT, u32(1));
    polls := 0;
    loop step(1); rd(TL_FRAMES_SENT, d); exit when unsigned(d) = 2 and st(17) = '1'; end loop;
    wr(TL_LINK_CREDIT, u32(2));
    polls := 0;
    loop step(1); exit when st(3) = '1'; end loop;
    rd(TL_FRAMES_SENT, d); chk(unsigned(d) = 3, "F16: a frame for every prompt position");
    wr(TL_NEXT_TOKEN, u32(77)); finish_run(0);
    expect(R_MAX_NEW, "F16");
    chk(got(0) = 77, "F16: the relayed token is the generated id");
    -- F17 (parked finding 2): ABORT while the host holds the seam, so the loop never gets it
    -- (F_TAKE). The host's write is accepted by the mux and parked with BREADY low.
    hm.awaddr <= u32(16#5C#); hm.wdata <= x"00000000"; hm.wstrb <= "1111";
    hm.awvalid <= '1'; hm.wvalid <= '1'; hm.bready <= '0';
    wait until rising_edge(clk);
    while hs.awready = '0' loop wait until rising_edge(clk); end loop;
    hm.awvalid <= '0'; hm.wvalid <= '0';
    tick(20);
    setup(NREF, ROLE_SINGLE, SRC_HOST); sr0 := seq_resets; wr(TL_CTRL, u32(1)); tick(200);
    rd(TL_STATUS, st); chk(st(1 downto 0) = "01" and st(16) = '0', "F17: running, seam not owned");
    wr(TL_CTRL, u32(2)); tick(50);
    rd(TL_STATUS, st);
    chk(st(1 downto 0) = "10" and to_integer(unsigned(st(15 downto 8))) = R_ABORT,
        "F17: ABORT ends the run while the host still holds the seam");
    chk(seq_resets = sr0, "F17: no SEQ_RESET was issued");
    hm.bready <= '1';
    wait until rising_edge(clk);
    while hs.bvalid = '0' loop wait until rising_edge(clk); end loop;
    hm <= AXIL_M2S_IDLE; tick(5);
    finish_run(0); expect(R_ABORT, "F17");
    -- F18 (parked finding 3): an OUT_ACK past N_GEN is clamped to N_GEN, not wrapped
    setup(NREF, ROLE_SINGLE, SRC_HOST); wr(TL_CTRL, u32(1));
    polls := 0;
    loop step(1); rd(TL_N_GEN, d); exit when unsigned(d) >= 1; end loop;
    sr0 := to_integer(unsigned(d));
    wr(TL_OUT_ACK, u32(4096));
    rd(TL_OUT_ACK, d); j1 := to_integer(unsigned(d));
    chk(j1 >= sr0 and j1 <= 4, "F18: OUT_ACK 4096 reads back clamped to N_GEN (got " & integer'image(j1) & ")");
    polls := 0;
    loop step(1); exit when st(7) = '1' or st(1 downto 0) = "10" or polls > 20000; end loop;
    rd(TL_N_GEN, d);
    chk(to_integer(unsigned(d)) = j1 + 4, "F18: the loop runs on to OUT_ACK + OUT_DEPTH ids (got " &
        integer'image(to_integer(unsigned(d))) & ")");
    -- the clamped ACK released slots 0 .. j1-1, so ids from j1 on are the ones still readable
    acked := j1; finish_run(0); expect(R_MAX_NEW, "F18");
    rd(TL_N_GEN, d); chk(to_integer(unsigned(d)) = NREF, "F18: N_GEN");
    for j in j1 to NREF - 1 loop chk(got(j) = ref(j), "F18: id " & integer'image(j) & " equals F0's"); end loop;
    -- F19: DUT2 control, a clean run from bad_src reproduces F0's ids
    bs_mode <= 0; run2(200000, "F19");
    rd2(TL_STATUS, st);
    chk(st(1 downto 0) = "10" and to_integer(unsigned(st(15 downto 8))) = R_MAX_NEW, "F19: DUT2 clean run stops MAX_NEW");
    for j in 0 to NREF - 1 loop chk(got(j) = ref(j), "F19: DUT2 id " & integer'image(j) & " equals F0's"); end loop;
    -- F20 (parked finding 2): the source stalls mid-row; ABORT ends the run (F_DATA)
    bs_mode <= 1; run2(300, "F20");
    rd2(TL_STATUS, st); chk(st(1 downto 0) = "01", "F20: running, the source stalled mid-row");
    wr2(TL_CTRL, u32(2)); tick(50);
    rd2(TL_STATUS, st);
    chk(st(1 downto 0) = "10" and to_integer(unsigned(st(15 downto 8))) = R_ABORT,
        "F20: ABORT ends a run stalled mid-row");
    -- F21 (parked finding 2): the source fails mid-row; the loop stops GATHER_ERR
    bs_mode <= 2; run2(2000, "F21");
    rd2(TL_STATUS, st);
    chk(st(1 downto 0) = "10" and to_integer(unsigned(st(15 downto 8))) = R_GATHER_ERR,
        "F21: a row-source error mid-row stops GATHER_ERR (got " &
        integer'image(to_integer(unsigned(st(15 downto 8)))) & ")");
    wr2(TL_CTRL, u32(2)); tick(10);
    if e = 0 then
      report "PASS: tb_tok_loop_faults checks=" & integer'image(c) severity note;
    else
      report "FAIL: tb_tok_loop_faults errors=" & integer'image(e) severity failure;
    end if;
    std.env.finish;
  end process;
end architecture;
