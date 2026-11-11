-- sim/tb_tok_loop.vhd -- tok_loop_regs + tok_loop_fsm against the behavioural seam (plan
-- 2026-11-04 Task 2). Oracles: (1) every seam write equals run_prompt's capture for the same
-- case (sim/seam_trace_chk.vhd); (2) the ids in OUT equal run_prompt's ids file; (3) the stop
-- reason is the one run_prompt printed (stop token vs --max-new). Cases run back to back on
-- one seam model, so each START's SEQ_RESET is exercised against a dirty seam.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.axil_bfm_pkg.all;
use work.tok_loop_pkg.all;
use work.tok_loop_tb_pkg.all;

entity tb_tok_loop is
  generic(VEC : string := "tok_loop_vec.txt");
end entity;

architecture sim of tb_tok_loop is
  constant N : positive := 4096;
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal cm : axil_m2s_t := AXIL_M2S_IDLE;
  signal cs : axil_s2m_t;
  signal cfg : tl_cfg_t;
  signal st : tl_stat_t;
  signal pr_addr : unsigned(11 downto 0);
  signal pr_data : unsigned(31 downto 0);
  signal out_we : std_logic;
  signal out_waddr : unsigned(15 downto 0);
  signal out_wdata : std_logic_vector(31 downto 0);
  signal hr_data : std_logic_vector(15 downto 0);
  signal loop_own, run_start : std_logic;
  signal rs_req, rs_ev, rs_mv, rs_mr : std_logic;
  signal rs_tok : unsigned(31 downto 0);
  signal rs_exp : std_logic_vector(31 downto 0);
  signal rs_md : std_logic_vector(15 downto 0);
  signal tx_wr, tx_send : std_logic;
  signal tx_widx : unsigned(11 downto 0);
  signal tx_wdata, tx_exp : std_logic_vector(31 downto 0);
  signal tx_pos : unsigned(31 downto 0);
  signal s_awaddr, s_araddr : std_logic_vector(11 downto 0);
  signal s_awvalid, s_awready, s_wvalid, s_wready, s_bvalid, s_bready : std_logic;
  signal s_arvalid, s_arready, s_rvalid, s_rready : std_logic;
  signal s_wdata, s_rdata : std_logic_vector(31 downto 0);
  signal s_wstrb : std_logic_vector(3 downto 0);
  signal s_bresp, s_rresp : std_logic_vector(1 downto 0);
  signal wr_ev : std_logic;
  signal wr_addr : std_logic_vector(11 downto 0);
  signal wr_data : std_logic_vector(31 downto 0);
  signal arm : std_logic := '0';
  signal case_sel : natural := 0;
  signal chk_errs, chk_nw : natural;
  signal chk_end : boolean;
begin
  clk <= not clk after 2.5 ns;

  regs : entity work.tok_loop_regs
    generic map(N_EMBD => N)
    port map(clk => clk, rst => rst,
             s_awaddr => cm.awaddr(15 downto 0), s_awvalid => cm.awvalid, s_awready => cs.awready,
             s_wdata => cm.wdata, s_wstrb => cm.wstrb, s_wvalid => cm.wvalid, s_wready => cs.wready,
             s_bresp => cs.bresp, s_bvalid => cs.bvalid, s_bready => cm.bready,
             s_araddr => cm.araddr(15 downto 0), s_arvalid => cm.arvalid, s_arready => cs.arready,
             s_rdata => cs.rdata, s_rresp => cs.rresp, s_rvalid => cs.rvalid, s_rready => cm.rready,
             cfg => cfg, st => st, lnk => TL_LNK_ZERO, pr_addr => pr_addr, pr_data => pr_data,
             out_we => out_we, out_waddr => out_waddr, out_wdata => out_wdata,
             hr_addr => (others => '0'), hr_data => hr_data);

  fsm : entity work.tok_loop_fsm
    generic map(N_EMBD => N, HAS_GATHER => true, HAS_LINK => false)
    port map(clk => clk, rst => rst, cfg => cfg, st => st, run_start => run_start,
             pr_addr => pr_addr, pr_data => pr_data,
             out_we => out_we, out_waddr => out_waddr, out_wdata => out_wdata,
             loop_own => loop_own, owner => loop_own,
             rs_req => rs_req, rs_tok => rs_tok, rs_exp_valid => rs_ev, rs_exp => rs_exp,
             rs_err => '0', rs_m_valid => rs_mv, rs_m_data => rs_md, rs_m_ready => rs_mr,
             rs_paused => '0',
             tx_wr => tx_wr, tx_widx => tx_widx, tx_wdata => tx_wdata, tx_send => tx_send,
             tx_pos => tx_pos, tx_exp => tx_exp, tx_busy => '0', tx_exhausted => '0',
             m_awaddr => s_awaddr, m_awvalid => s_awvalid, m_awready => s_awready,
             m_wdata => s_wdata, m_wstrb => s_wstrb, m_wvalid => s_wvalid, m_wready => s_wready,
             m_bresp => s_bresp, m_bvalid => s_bvalid, m_bready => s_bready,
             m_araddr => s_araddr, m_arvalid => s_arvalid, m_arready => s_arready,
             m_rdata => s_rdata, m_rresp => s_rresp, m_rvalid => s_rvalid, m_rready => s_rready);

  src : entity work.row_synth_src
    generic map(N_EMBD => N, LAT => 12)
    port map(clk => clk, rst => rst, req => rs_req, tok => rs_tok, exp_valid => rs_ev,
             exp_val => rs_exp, m_valid => rs_mv, m_data => rs_md, m_ready => rs_mr);

  seam : entity work.seam_beh_model
    generic map(N_EMBD => N)
    port map(clk => clk, rst => rst, awaddr => s_awaddr, awvalid => s_awvalid, awready => s_awready,
             wdata => s_wdata, wvalid => s_wvalid, wready => s_wready, bresp => s_bresp,
             bvalid => s_bvalid, bready => s_bready, araddr => s_araddr, arvalid => s_arvalid,
             arready => s_arready, rdata => s_rdata, rresp => s_rresp, rvalid => s_rvalid,
             rready => s_rready, wr_ev => wr_ev, wr_addr => wr_addr, wr_data => wr_data);

  trchk : entity work.seam_trace_chk
    generic map(VEC => VEC, DIE => 0)
    port map(clk => clk, arm => arm, case_sel => case_sel, wr_ev => wr_ev, wr_addr => wr_addr,
             wr_data => wr_data, errs => chk_errs, at_end => chk_end, n_writes => chk_nw);

  host : process
    variable V : vec_t := load_vec(VEC);
    variable resp : std_logic_vector(1 downto 0);
    variable d : std_logic_vector(31 downto 0);
    variable e, c, pollcnt, ncase, want_reason : natural := 0;
    procedure chk(ok : boolean; msg : string) is
    begin
      c := c + 1;
      if not ok then e := e + 1; report "tb_tok_loop: " & msg severity error; end if;
    end procedure;
    procedure wr(a : natural; x : std_logic_vector(31 downto 0)) is
    begin
      axil_wr(clk, cm, cs, a, x, resp);
      chk(resp = "00", "control write OKAY");
    end procedure;
    procedure rd(a : natural; x : out std_logic_vector(31 downto 0)) is
    begin
      axil_rd(clk, cm, cs, a, x, resp);
    end procedure;
  begin
    for k in 1 to 5 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);
    rd(TL_ID, d); chk(d = TL_ID_MAGIC, "ID reads TLP1");
    for k in 0 to V.n_cases - 1 loop
      next when V.cs(k).pair or V.cs(k).gather;
      ncase := ncase + 1;
      case_sel <= k; arm <= '1'; wait until rising_edge(clk); arm <= '0';
      wr(TL_PROMPT_LEN, u32(V.cs(k).plen));
      wr(TL_MAX_NEW, u32(V.cs(k).max_new));
      if V.cs(k).stop >= 0 then wr(TL_STOP_ID0, u32(V.cs(k).stop)); else wr(TL_STOP_ID0, x"FFFFFFFF"); end if;
      wr(TL_ROW_SRC, u32(SRC_GATHER));
      wr(TL_ROLE, u32(ROLE_SINGLE));
      wr(TL_PROMPT_ADDR, u32(0));
      for j in 0 to V.cs(k).plen - 1 loop wr(TL_PROMPT_DATA, u32(V.ints(V.cs(k).p0 + j))); end loop;
      wr(TL_CTRL, u32(1));
      pollcnt := 0;
      loop
        rd(TL_STATUS, d);
        exit when d(1 downto 0) = "10";
        pollcnt := pollcnt + 1;
        assert pollcnt < 2000000 report "tb_tok_loop: case never stopped" severity failure;
      end loop;
      want_reason := R_MAX_NEW;
      if V.cs(k).stop >= 0 and V.ints(V.cs(k).i0 + V.cs(k).n_ids - 1) = V.cs(k).stop then
        want_reason := R_STOP_ID;
      end if;
      chk(to_integer(unsigned(d(15 downto 8))) = want_reason, "case " & integer'image(k) & " stop reason");
      chk(d(16) = '0', "seam released after the stop");
      rd(TL_N_GEN, d);
      chk(to_integer(unsigned(d)) = V.cs(k).n_ids, "case " & integer'image(k) & " id count");
      wr(TL_OUT_ADDR, u32(0));
      for j in 0 to V.cs(k).n_ids - 1 loop
        rd(TL_OUT_DATA, d);
        chk(to_integer(unsigned(d)) = V.ints(V.cs(k).i0 + j),
            "case " & integer'image(k) & " id " & integer'image(j) & " equals run_prompt's");
      end loop;
      wait until rising_edge(clk);
      chk(chk_end, "case " & integer'image(k) & ": every host write was replayed");
    end loop;
    chk(ncase >= 4, "at least four single-die cases ran");
    chk(chk_errs = 0, "no seam write differed from the host's");
    e := e + chk_errs;
    if e = 0 then
      report "PASS: tb_tok_loop checks=" & integer'image(c) severity note;
    else
      report "FAIL: tb_tok_loop errors=" & integer'image(e) severity failure;
    end if;
    std.env.finish;
  end process;
end architecture;
