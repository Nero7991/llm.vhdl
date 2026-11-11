-- sim/tb_tok_loop_top.vhd -- tok_loop (regs + FSM + mux + row sources) on one die against
-- the behavioural seam (plan 2026-11-04 Task 6). Oracles as tb_tok_loop: run_prompt's
-- captured seam writes and ids. Single-die cases are fed through the HOST row source (the
-- bench answers NEED_ROW with pl_embed_synthetic rows); case e through the GATHER source
-- from the Task 3 image poked into sim/jc_axi3_mem, so its trace is pl_embed_mv4i's rows.
-- Last, case e is ABORTed mid-row and then run again (gather restart after an abort).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.axil_bfm_pkg.all;
use work.tok_loop_pkg.all;
use work.tok_loop_tb_pkg.all;

entity tb_tok_loop_top is
  generic(VEC : string := "tok_loop_vec.txt"; GVEC : string := "embed_gather_k4096_vec.txt");
end entity;

architecture sim of tb_tok_loop_top is
  constant N : positive := 4096;
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal cm, hm : axil_m2s_t := AXIL_M2S_IDLE;
  signal cs, hs : axil_s2m_t;
  signal s_awaddr, s_araddr : std_logic_vector(11 downto 0);
  signal s_awvalid, s_awready, s_wvalid, s_wready, s_bvalid, s_bready : std_logic;
  signal s_arvalid, s_arready, s_rvalid, s_rready : std_logic;
  signal s_wdata, s_rdata : std_logic_vector(31 downto 0);
  signal s_wstrb : std_logic_vector(3 downto 0);
  signal s_bresp, s_rresp : std_logic_vector(1 downto 0);
  signal araddr : std_logic_vector(32 downto 0);
  signal arlen : std_logic_vector(7 downto 0);
  signal arsize : std_logic_vector(2 downto 0);
  signal arburst : std_logic_vector(1 downto 0);
  signal arvalid, arready, rlast, rvalid, rready : std_logic;
  signal rdata : std_logic_vector(255 downto 0);
  signal rresp : std_logic_vector(1 downto 0);
  signal poke_en : std_logic := '0';
  signal poke_addr : std_logic_vector(39 downto 0) := (others => '0');
  signal poke_data : std_logic_vector(255 downto 0) := (others => '0');
  signal mem_errs : natural;
  signal wr_ev : std_logic;
  signal wr_addr : std_logic_vector(11 downto 0);
  signal wr_data : std_logic_vector(31 downto 0);
  signal arm : std_logic := '0';
  signal case_sel : natural := 0;
  signal chk_errs, chk_nw : natural;
  signal chk_end : boolean;
  signal n_go, n_wd : natural := 0;
begin
  clk <= not clk after 2.5 ns;

  dut : entity work.tok_loop
    generic map(N_EMBD => N, OUT_DEPTH => 1024, HAS_GATHER => true, HAS_LINK => false)
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
             host_refused => open,
             m_hbm_araddr => araddr, m_hbm_arlen => arlen, m_hbm_arsize => arsize, m_hbm_arburst => arburst,
             m_hbm_arvalid => arvalid, m_hbm_arready => arready, m_hbm_rdata => rdata, m_hbm_rresp => rresp,
             m_hbm_rlast => rlast, m_hbm_rvalid => rvalid, m_hbm_rready => rready,
             ltx_tdata => open, ltx_tkeep => open, ltx_tlast => open, ltx_tvalid => open, ltx_tready => '1',
             lrx_tdata => (others => '0'), lrx_tlast => '0', lrx_tvalid => '0',
             lnk_tx_up => '0', lnk_rx_up => '0', lnk_gtg_lock => '0', lnk_pll_lock => '0', lnk_rx_ovf => '0',
             link_ctrl => open);

  mem : entity work.jc_axi3_mem
    generic map(ADDR_W => 33, IDX_W => 14, STALL => true)
    port map(clk => clk, awaddr => (others => '0'), awlen => "0000", awsize => "101",
             awburst => "01", awvalid => '0', awready => open, wdata => (others => '0'),
             wstrb => (others => '0'), wlast => '0', wvalid => '0', wready => open,
             bresp => open, bvalid => open, bready => '1',
             araddr => araddr, arlen => arlen(3 downto 0), arsize => arsize, arburst => arburst,
             arvalid => arvalid, arready => arready, rdata => rdata, rresp => rresp,
             rlast => rlast, rvalid => rvalid, rready => rready,
             poke_en => poke_en, poke_addr => poke_addr, poke_data => poke_data,
             peek_addr => (others => '0'), peek_data => open, peek_hit => open, errors => mem_errs);

  seam : entity work.seam_beh_model
    generic map(N_EMBD => N)
    port map(clk => clk, rst => rst, awaddr => s_awaddr, awvalid => s_awvalid, awready => s_awready,
             wdata => s_wdata, wvalid => s_wvalid, wready => s_wready, bresp => s_bresp,
             bvalid => s_bvalid, bready => s_bready, araddr => s_araddr, arvalid => s_arvalid,
             arready => s_arready, rdata => s_rdata, rresp => s_rresp, rvalid => s_rvalid,
             rready => s_rready, wr_ev => wr_ev, wr_addr => wr_addr, wr_data => wr_data);

  chk : entity work.seam_trace_chk
    generic map(VEC => VEC, DIE => 0)
    port map(clk => clk, arm => arm, case_sel => case_sel, wr_ev => wr_ev, wr_addr => wr_addr,
             wr_data => wr_data, errs => chk_errs, at_end => chk_end, n_writes => chk_nw);

  count : process(clk)
  begin
    if rising_edge(clk) then
      if wr_ev = '1' and wr_addr = x"014" and wr_data = x"00000001" then n_go <= n_go + 1; end if;
      if wr_ev = '1' and wr_addr = x"060" then n_wd <= n_wd + 1; end if;
    end if;
  end process;

  host : process
    variable V : vec_t := load_vec(VEC);
    file gf : text open read_mode is GVEC;
    variable l : line;
    variable ch : character;
    variable a9 : std_logic_vector(35 downto 0);
    variable b256 : std_logic_vector(255 downto 0);
    variable nbeats, mcount : integer;
    variable emb : std_logic_vector(35 downto 0);
    variable resp : std_logic_vector(1 downto 0);
    variable d, xexp : std_logic_vector(31 downto 0);
    variable row : row16_arr(0 to N - 1);
    -- no variable may be named n: VHDL is case-insensitive, so it would hide the constant N
    -- (the brief's bench had one, which made serve_row write no mantissas and CAPS compare to 0)
    variable e, c, np, nsingle, ngather, want_reason, kg, gos0, wd0 : natural := 0;
    procedure chk(ok : boolean; msg : string) is
    begin
      c := c + 1;
      if not ok then e := e + 1; report "tb_tok_loop_top: " & msg severity error; end if;
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
    procedure serve_row is
      variable t : std_logic_vector(31 downto 0);
    begin
      rd(TL_ROW_TOK, t);
      synth_row(to_integer(unsigned(t)), row, xexp);
      wr(TL_ROW_EXP, xexp);
      wr(TL_ROW_ADDR, u32(0));
      for j in 0 to N - 1 loop wr(TL_ROW_DATA, x"0000" & row(j)); end loop;
      wr(TL_CTRL, u32(8));                                   -- ROW_READY
    end procedure;
    procedure setup_case(k : natural) is
    begin
      wr(TL_PROMPT_LEN, u32(V.cs(k).plen));
      wr(TL_MAX_NEW, u32(V.cs(k).max_new));
      if V.cs(k).stop >= 0 then wr(TL_STOP_ID0, u32(V.cs(k).stop)); else wr(TL_STOP_ID0, x"FFFFFFFF"); end if;
      wr(TL_ROLE, u32(ROLE_SINGLE));
      if V.cs(k).gather then
        wr(TL_ROW_SRC, u32(SRC_GATHER));
        wr(TL_EMB_BASE_LO, emb(31 downto 0));
        wr(TL_EMB_BASE_HI, x"0000000" & "000" & emb(32));
      else
        wr(TL_ROW_SRC, u32(SRC_HOST));
      end if;
      wr(TL_PROMPT_ADDR, u32(0));
      for j in 0 to V.cs(k).plen - 1 loop wr(TL_PROMPT_DATA, u32(V.ints(V.cs(k).p0 + j))); end loop;
    end procedure;
    -- one whole case against the vectors; `bound` STATUS polls before it counts as hung
    procedure run_case(k : natural; bound : natural) is
      variable polls : natural := 0;
    begin
      case_sel <= k; arm <= '1'; wait until rising_edge(clk); arm <= '0';
      setup_case(k);
      wr(TL_CTRL, u32(1));
      loop
        rd(TL_STATUS, d);
        exit when d(1 downto 0) = "10" or polls >= bound;
        if d(2) = '1' then serve_row; end if;
        polls := polls + 1;
      end loop;
      chk(d(1 downto 0) = "10", "case " & integer'image(k) & " stopped within " & integer'image(bound) & " polls");
      want_reason := R_MAX_NEW;
      if V.cs(k).stop >= 0 and V.ints(V.cs(k).i0 + V.cs(k).n_ids - 1) = V.cs(k).stop then
        want_reason := R_STOP_ID;
      end if;
      chk(to_integer(unsigned(d(15 downto 8))) = want_reason, "case " & integer'image(k) & " stop reason");
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
      axil_rd(clk, hm, hs, 16#8C#, d, resp); chk(resp = "00", "host seam read OKAY after the stop");
    end procedure;
  begin
    -- the Task 3 image
    readline(gf, l); while l(1) = '#' loop readline(gf, l); end loop;
    read(l, ch); hread(l, emb); read(l, nbeats); read(l, mcount);
    for k in 1 to 5 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    for k in 0 to nbeats - 1 loop
      readline(gf, l); read(l, ch); hread(l, a9); hread(l, b256);
      poke_en <= '1'; poke_addr <= "0000" & a9; poke_data <= b256;
      wait until rising_edge(clk);
    end loop;
    poke_en <= '0';
    wait until rising_edge(clk);
    rd(TL_ID, d); chk(d = TL_ID_MAGIC, "ID reads TLP1");
    rd(TL_CAPS, d); chk(unsigned(d(15 downto 0)) = N and d(16) = '1' and d(17) = '0', "CAPS: N_EMBD, gather, no link");
    axil_rd(clk, hm, hs, 16#8C#, d, resp); chk(resp = "00", "host seam read OKAY while the loop is idle");
    for k in 0 to V.n_cases - 1 loop
      next when V.cs(k).pair;
      if V.cs(k).gather then ngather := ngather + 1; kg := k; else nsingle := nsingle + 1; end if;
      run_case(k, 4000000);
    end loop;
    -- case e again, ABORTed mid-row (the FSM in F_DATA, rows from the gather), then run whole:
    -- the abort ends the run before position 0's GO (parked Task 2 finding 2), and the next
    -- START finds the gather idle (tok_loop resets it, with no HBM read in flight, at START)
    case_sel <= kg; arm <= '1'; wait until rising_edge(clk); arm <= '0';
    setup_case(kg);
    gos0 := n_go; wd0 := n_wd;
    wr(TL_CTRL, u32(1));
    if n_wd < wd0 + 100 then wait until n_wd >= wd0 + 100; end if;
    wr(TL_CTRL, u32(2));
    np := 0;
    loop
      rd(TL_STATUS, d);
      exit when d(1 downto 0) = "10" or np > 100000;
      np := np + 1;
    end loop;
    chk(d(1 downto 0) = "10" and to_integer(unsigned(d(15 downto 8))) = R_ABORT, "G: the mid-row ABORT stops ABORT");
    chk(n_go = gos0, "G: no GO was issued for the aborted position");
    chk(n_wd < wd0 + N, "G: the aborted row was not completed (" & integer'image(n_wd - wd0) & " WIN_DATA writes)");
    run_case(kg, 400000);
    chk(nsingle >= 4 and ngather >= 1, "four host-row cases and one gather case ran");
    chk(chk_errs = 0, "no seam write differed from the host's");
    chk(mem_errs = 0, "every HBM burst obeyed AXI3");
    e := e + chk_errs;
    if e = 0 then
      report "PASS: tb_tok_loop_top checks=" & integer'image(c) severity note;
    else
      report "FAIL: tb_tok_loop_top errors=" & integer'image(e) severity failure;
    end if;
    std.env.finish;
  end process;
end architecture;
