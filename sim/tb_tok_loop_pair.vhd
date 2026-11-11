-- sim/tb_tok_loop_pair.vhd -- two jc_tok_top (die A role A with host rows, die B role B with
-- link rows) joined by sim/jc_link_chan_model on a separate user clock, so the async FIFOs
-- and synchronisers are in the path (plan 2026-11-04 Task 6). The bench is the host relay of
-- spec 1b.5 phase 1: B's ids to A's NEXT_TOKEN, B's LINK_CONSUMED to A's LINK_CREDIT (plan
-- D3), and RESEND on B's pause. Oracles: both dies' seam writes equal run_prompt's pair
-- capture (case pa), B's ids equal run_prompt's; under P2/P3 faults, the same writes and ids.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.axil_bfm_pkg.all;
use work.tok_loop_pkg.all;
use work.tok_loop_tb_pkg.all;
use work.jc_link_pkg.all;

entity tb_tok_loop_pair is
  generic(VEC : string := "tok_loop_vec.txt");
end entity;

architecture sim of tb_tok_loop_pair is
  constant N : positive := 4096;
  constant FB : natural := lk_beats(N, 2);           -- beats per frame, NLANES 1
  signal clk, uclk : std_logic := '0';
  signal rst : std_logic := '1';
  signal ma, mb : axil_m2s_t := AXIL_M2S_IDLE;
  signal sa, sb : axil_s2m_t;
  type seam_bus is record
    awaddr, araddr : std_logic_vector(11 downto 0);
    awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready : std_logic;
    wdata, rdata : std_logic_vector(31 downto 0);
    wstrb : std_logic_vector(3 downto 0);
    bresp, rresp : std_logic_vector(1 downto 0);
  end record;
  signal qa, qb : seam_bus;
  signal a_tx, b_rx : std_logic_vector(63 downto 0);
  signal a_txl, a_txv, a_txr, b_rxl, b_rxv, chan_up : std_logic;
  signal down : std_logic := '0';
  signal flip_beat, drop_beat : integer := -1;
  signal nbeats : natural;
  signal ev_a, ev_b : std_logic;
  signal ad_a, ad_b : std_logic_vector(11 downto 0);
  signal dd_a, dd_b : std_logic_vector(31 downto 0);
  signal arm : std_logic := '0';
  signal case_sel : natural := 0;
  signal ea, eb, nwa, nwb : natural;
  signal enda, endb : boolean;
begin
  clk <= not clk after 2.5 ns;        -- clk_core 200 MHz
  uclk <= not uclk after 3.1 ns;      -- Aurora user clock, 161.3 MHz at 10.3125 Gb/s x 1 lane

  top_a : entity work.jc_tok_top
    generic map(N_EMBD => N, NLANES => 1, HAS_GATHER => false, TXPOL_MASK => 0)
    port map(aclk => clk, arst => rst,
             s_host_awaddr => (others => '0'), s_host_awvalid => '0', s_host_awready => open,
             s_host_wdata => (others => '0'), s_host_wstrb => "1111", s_host_wvalid => '0', s_host_wready => open,
             s_host_bresp => open, s_host_bvalid => open, s_host_bready => '1',
             s_host_araddr => (others => '0'), s_host_arvalid => '0', s_host_arready => open,
             s_host_rdata => open, s_host_rresp => open, s_host_rvalid => open, s_host_rready => '1',
             m_seam_awaddr => qa.awaddr, m_seam_awvalid => qa.awvalid, m_seam_awready => qa.awready,
             m_seam_wdata => qa.wdata, m_seam_wstrb => qa.wstrb, m_seam_wvalid => qa.wvalid, m_seam_wready => qa.wready,
             m_seam_bresp => qa.bresp, m_seam_bvalid => qa.bvalid, m_seam_bready => qa.bready,
             m_seam_araddr => qa.araddr, m_seam_arvalid => qa.arvalid, m_seam_arready => qa.arready,
             m_seam_rdata => qa.rdata, m_seam_rresp => qa.rresp, m_seam_rvalid => qa.rvalid, m_seam_rready => qa.rready,
             s_ctl_awaddr => ma.awaddr(15 downto 0), s_ctl_awvalid => ma.awvalid, s_ctl_awready => sa.awready,
             s_ctl_wdata => ma.wdata, s_ctl_wstrb => ma.wstrb, s_ctl_wvalid => ma.wvalid, s_ctl_wready => sa.wready,
             s_ctl_bresp => sa.bresp, s_ctl_bvalid => sa.bvalid, s_ctl_bready => ma.bready,
             s_ctl_araddr => ma.araddr(15 downto 0), s_ctl_arvalid => ma.arvalid, s_ctl_arready => sa.arready,
             s_ctl_rdata => sa.rdata, s_ctl_rresp => sa.rresp, s_ctl_rvalid => sa.rvalid, s_ctl_rready => ma.rready,
             m_hbm_araddr => open, m_hbm_arlen => open, m_hbm_arsize => open, m_hbm_arburst => open,
             m_hbm_arvalid => open, m_hbm_arready => '0', m_hbm_rdata => (others => '0'), m_hbm_rresp => "00",
             m_hbm_rlast => '0', m_hbm_rvalid => '0', m_hbm_rready => open,
             user_clk => uclk, m_axis_tx_tdata => a_tx, m_axis_tx_tkeep => open, m_axis_tx_tlast => a_txl,
             m_axis_tx_tvalid => a_txv, m_axis_tx_tready => a_txr,
             s_axis_rx_tdata => (others => '0'), s_axis_rx_tkeep => (others => '1'), s_axis_rx_tlast => '0',
             s_axis_rx_tvalid => '0', tx_channel_up => '1', rx_channel_up => '0', gt_pll_lock => '1',
             gtg_locked => '1', init_clk => clk, aur_reset_pb => open, aur_pma_init => open,
             aur_tx_polarity => open);
  seam_a : entity work.seam_beh_model
    generic map(N_EMBD => N)
    port map(clk => clk, rst => rst, awaddr => qa.awaddr, awvalid => qa.awvalid, awready => qa.awready,
             wdata => qa.wdata, wvalid => qa.wvalid, wready => qa.wready, bresp => qa.bresp,
             bvalid => qa.bvalid, bready => qa.bready, araddr => qa.araddr, arvalid => qa.arvalid,
             arready => qa.arready, rdata => qa.rdata, rresp => qa.rresp, rvalid => qa.rvalid,
             rready => qa.rready, wr_ev => ev_a, wr_addr => ad_a, wr_data => dd_a);

  top_b : entity work.jc_tok_top
    generic map(N_EMBD => N, NLANES => 1, HAS_GATHER => false, TXPOL_MASK => 0)
    port map(aclk => clk, arst => rst,
             s_host_awaddr => (others => '0'), s_host_awvalid => '0', s_host_awready => open,
             s_host_wdata => (others => '0'), s_host_wstrb => "1111", s_host_wvalid => '0', s_host_wready => open,
             s_host_bresp => open, s_host_bvalid => open, s_host_bready => '1',
             s_host_araddr => (others => '0'), s_host_arvalid => '0', s_host_arready => open,
             s_host_rdata => open, s_host_rresp => open, s_host_rvalid => open, s_host_rready => '1',
             m_seam_awaddr => qb.awaddr, m_seam_awvalid => qb.awvalid, m_seam_awready => qb.awready,
             m_seam_wdata => qb.wdata, m_seam_wstrb => qb.wstrb, m_seam_wvalid => qb.wvalid, m_seam_wready => qb.wready,
             m_seam_bresp => qb.bresp, m_seam_bvalid => qb.bvalid, m_seam_bready => qb.bready,
             m_seam_araddr => qb.araddr, m_seam_arvalid => qb.arvalid, m_seam_arready => qb.arready,
             m_seam_rdata => qb.rdata, m_seam_rresp => qb.rresp, m_seam_rvalid => qb.rvalid, m_seam_rready => qb.rready,
             s_ctl_awaddr => mb.awaddr(15 downto 0), s_ctl_awvalid => mb.awvalid, s_ctl_awready => sb.awready,
             s_ctl_wdata => mb.wdata, s_ctl_wstrb => mb.wstrb, s_ctl_wvalid => mb.wvalid, s_ctl_wready => sb.wready,
             s_ctl_bresp => sb.bresp, s_ctl_bvalid => sb.bvalid, s_ctl_bready => mb.bready,
             s_ctl_araddr => mb.araddr(15 downto 0), s_ctl_arvalid => mb.arvalid, s_ctl_arready => sb.arready,
             s_ctl_rdata => sb.rdata, s_ctl_rresp => sb.rresp, s_ctl_rvalid => sb.rvalid, s_ctl_rready => mb.rready,
             m_hbm_araddr => open, m_hbm_arlen => open, m_hbm_arsize => open, m_hbm_arburst => open,
             m_hbm_arvalid => open, m_hbm_arready => '0', m_hbm_rdata => (others => '0'), m_hbm_rresp => "00",
             m_hbm_rlast => '0', m_hbm_rvalid => '0', m_hbm_rready => open,
             user_clk => uclk, m_axis_tx_tdata => open, m_axis_tx_tkeep => open, m_axis_tx_tlast => open,
             m_axis_tx_tvalid => open, m_axis_tx_tready => '1',
             s_axis_rx_tdata => b_rx, s_axis_rx_tkeep => (others => '1'), s_axis_rx_tlast => b_rxl,
             s_axis_rx_tvalid => b_rxv, tx_channel_up => '1', rx_channel_up => chan_up, gt_pll_lock => '1',
             gtg_locked => '1', init_clk => clk, aur_reset_pb => open, aur_pma_init => open,
             aur_tx_polarity => open);
  seam_b : entity work.seam_beh_model
    generic map(N_EMBD => N)
    port map(clk => clk, rst => rst, awaddr => qb.awaddr, awvalid => qb.awvalid, awready => qb.awready,
             wdata => qb.wdata, wvalid => qb.wvalid, wready => qb.wready, bresp => qb.bresp,
             bvalid => qb.bvalid, bready => qb.bready, araddr => qb.araddr, arvalid => qb.arvalid,
             arready => qb.arready, rdata => qb.rdata, rresp => qb.rresp, rvalid => qb.rvalid,
             rready => qb.rready, wr_ev => ev_b, wr_addr => ad_b, wr_data => dd_b);

  chan : entity work.jc_link_chan_model
    generic map(W => 2, LAT => 8)
    port map(clk => uclk, s_tdata => a_tx, s_tlast => a_txl, s_tvalid => a_txv, s_tready => a_txr,
             m_tdata => b_rx, m_tlast => b_rxl, m_tvalid => b_rxv, chan_up => chan_up, down => down,
             flip_beat => flip_beat, flip_bit => 3, drop_beat => drop_beat, nbeats => nbeats);

  chk_a : entity work.seam_trace_chk
    generic map(VEC => VEC, DIE => 0)
    port map(clk => clk, arm => arm, case_sel => case_sel, wr_ev => ev_a, wr_addr => ad_a,
             wr_data => dd_a, errs => ea, at_end => enda, n_writes => nwa);
  chk_b : entity work.seam_trace_chk
    generic map(VEC => VEC, DIE => 1)
    port map(clk => clk, arm => arm, case_sel => case_sel, wr_ev => ev_b, wr_addr => ad_b,
             wr_data => dd_b, errs => eb, at_end => endb, n_writes => nwb);

  host : process
    variable V : vec_t := load_vec(VEC);
    variable resp : std_logic_vector(1 downto 0);
    variable d, da, db, xexp : std_logic_vector(31 downto 0);
    variable row : row16_arr(0 to N - 1);
    variable e, c, kp, polls, credit, relayed, handled, nb0, t_pause : natural := 0;
    variable fault : natural;
    procedure chk(ok : boolean; msg : string) is
    begin
      c := c + 1;
      if not ok then e := e + 1; report "tb_tok_loop_pair: " & msg severity error; end if;
    end procedure;
    procedure wa(a : natural; x : std_logic_vector(31 downto 0)) is
    begin
      axil_wr(clk, ma, sa, a, x, resp); chk(resp = "00", "die A write OKAY");
    end procedure;
    procedure wb(a : natural; x : std_logic_vector(31 downto 0)) is
    begin
      axil_wr(clk, mb, sb, a, x, resp); chk(resp = "00", "die B write OKAY");
    end procedure;
    procedure ra(a : natural; x : out std_logic_vector(31 downto 0)) is
    begin
      axil_rd(clk, ma, sa, a, x, resp);
    end procedure;
    procedure rb(a : natural; x : out std_logic_vector(31 downto 0)) is
    begin
      axil_rd(clk, mb, sb, a, x, resp);
    end procedure;
    procedure setup(cap : natural; tmo_link : natural) is
    begin
      for die in 0 to 1 loop
        if die = 0 then
          wa(TL_PROMPT_LEN, u32(V.cs(kp).plen)); wa(TL_MAX_NEW, u32(V.cs(kp).max_new));
          wa(TL_STOP_ID0, x"FFFFFFFF"); wa(TL_ROLE, u32(ROLE_A)); wa(TL_ROW_SRC, u32(SRC_HOST));
          wa(TL_RESEND_CAP, u32(cap)); wa(TL_LINK_CREDIT, u32(0)); wa(TL_PROMPT_ADDR, u32(0));
          for j in 0 to V.cs(kp).plen - 1 loop wa(TL_PROMPT_DATA, u32(V.ints(V.cs(kp).p0 + j))); end loop;
        else
          wb(TL_PROMPT_LEN, u32(V.cs(kp).plen)); wb(TL_MAX_NEW, u32(V.cs(kp).max_new));
          wb(TL_STOP_ID0, x"FFFFFFFF"); wb(TL_ROLE, u32(ROLE_B)); wb(TL_ROW_SRC, u32(SRC_LINK));
          wb(TL_TMO_LINK, u32(tmo_link)); wb(TL_PROMPT_ADDR, u32(0));
          for j in 0 to V.cs(kp).plen - 1 loop wb(TL_PROMPT_DATA, u32(V.ints(V.cs(kp).p0 + j))); end loop;
        end if;
      end loop;
    end procedure;
    -- one run; fault 0 clean, 2 payload flip in frame 2 with a delayed RESEND, 3 link down in
    -- frame 4, 4 every frame from frame 1 on corrupted with RESEND_CAP 2
    procedure run(f : natural) is
      variable fails : natural;
    begin
      case_sel <= kp; arm <= '1'; wait until rising_edge(clk); arm <= '0';
      nb0 := nbeats; credit := 0; relayed := 0; handled := 0; polls := 0; t_pause := 0;
      flip_beat <= -1; drop_beat <= -1; down <= '0';
      if f = 2 then flip_beat <= nb0 + 2 * FB + 6; end if;
      if f = 4 then flip_beat <= nb0 + 1 * FB + 6; end if;
      wb(TL_CTRL, u32(1)); wa(TL_CTRL, u32(1));
      loop
        ra(TL_STATUS, da); rb(TL_STATUS, db);
        exit when da(1 downto 0) = "10" and db(1 downto 0) = "10";
        if f = 4 and da(1 downto 0) = "10" and db(1 downto 0) = "01" then
          wb(TL_CTRL, u32(2));                                    -- ABORT B: A gave up
        end if;
        if da(2) = '1' then                                       -- A: NEED_ROW
          ra(TL_ROW_TOK, d); synth_row(to_integer(unsigned(d)), row, xexp);
          wa(TL_ROW_EXP, xexp); wa(TL_ROW_ADDR, u32(0));
          for j in 0 to N - 1 loop wa(TL_ROW_DATA, x"0000" & row(j)); end loop;
          wa(TL_CTRL, u32(8));
        end if;
        rb(TL_LINK_CONSUMED, d);                                  -- credit relay (plan D3)
        if to_integer(unsigned(d)) /= credit then credit := to_integer(unsigned(d)); wa(TL_LINK_CREDIT, d); end if;
        rb(TL_OUT_COUNT, d);                                      -- token relay (spec 1b.5)
        while relayed < to_integer(unsigned(d)) loop
          wb(TL_OUT_ADDR, u32(relayed)); rb(TL_OUT_DATA, xexp);
          wa(TL_NEXT_TOKEN, xexp); relayed := relayed + 1;
        end loop;
        if f = 3 and down = '0' and t_pause = 0 and nbeats >= nb0 + 4 * FB + 100 then
          down <= '1'; for j in 1 to 400 loop wait until rising_edge(uclk); end loop; down <= '0';
          t_pause := 1;
        end if;
        if db(4) = '1' then                                       -- B paused: LINK_BAD or LINK_DOWN
          rb(TL_CRC_FAILS, d); fails := to_integer(unsigned(d));
          rb(TL_LINK_DOWNS, d); fails := fails + to_integer(unsigned(d));
          if fails > handled then
            if f = 2 then
              for j in 1 to 600000 loop wait until rising_edge(clk); end loop;   -- past TMO_LINK
              rb(TL_STATUS, db);
              chk(db(1 downto 0) = "01" and db(4) = '1', "P2: B still paused, not timed out, after 600k cycles");
            end if;
            if f = 4 then flip_beat <= nbeats + 6; end if;        -- the resend is corrupted too
            handled := fails;
            wa(TL_CTRL, u32(4));                                  -- RESEND (P3: A is still busy
                                                                   -- sending the cut frame's tail
                                                                   -- here; jc_link_tx latches this
                                                                   -- and serves it at T_IDLE, finding 4)
          end if;
        end if;
        polls := polls + 1;
        -- a clean run takes about 75k polls (MEASURED, P1-P3); 400k is the hang bound (the
        -- brief had 3M, which made a hung mutant take hours of wall time)
        assert polls < 400000 report "tb_tok_loop_pair: run never ended" severity failure;
      end loop;
    end procedure;
    procedure check_ids(tag : string) is
    begin
      rb(TL_N_GEN, d);
      chk(to_integer(unsigned(d)) = V.cs(kp).n_ids, tag & ": B id count");
      wb(TL_OUT_ADDR, u32(0));
      for j in 0 to V.cs(kp).n_ids - 1 loop
        rb(TL_OUT_DATA, d);
        chk(to_integer(unsigned(d)) = V.ints(V.cs(kp).i0 + j), tag & ": B id " & integer'image(j) & " equals run_prompt's");
      end loop;
      wa(TL_OUT_ADDR, u32(0));
      for j in 0 to V.cs(kp).n_ids - 1 loop
        ra(TL_OUT_DATA, d);
        chk(to_integer(unsigned(d)) = V.ints(V.cs(kp).i0 + j), tag & ": A received id " & integer'image(j));
      end loop;
      wait until rising_edge(clk);
      chk(enda and endb, tag & ": both dies replayed every host write");
    end procedure;
  begin
    for k in 0 to V.n_cases - 1 loop if V.cs(k).pair then kp := k; end if; end loop;
    chk(V.cs(kp).pair, "the vectors carry a pair case");
    for k in 1 to 5 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    for k in 1 to 20 loop wait until rising_edge(clk); end loop;
    -- P1: clean
    setup(3, 400000); run(0);
    ra(TL_STATUS, da); rb(TL_STATUS, db);
    chk(unsigned(da(15 downto 8)) = R_MAX_NEW and unsigned(db(15 downto 8)) = R_MAX_NEW, "P1: both stop on MAX_NEW");
    check_ids("P1");
    ra(TL_RESENDS, d); chk(unsigned(d) = 0, "P1: no resend");
    ra(TL_FRAMES_SENT, d); chk(to_integer(unsigned(d)) = V.cs(kp).plen + V.cs(kp).n_ids - 1, "P1: one frame per position");
    rb(TL_FRAMES_GOOD, d); chk(to_integer(unsigned(d)) = V.cs(kp).plen + V.cs(kp).n_ids - 1, "P1: every frame good");
    rb(TL_CRC_FAILS, d); chk(unsigned(d) = 0, "P1: no CRC failure");
    rb(TL_OVERRUNS, d); chk(unsigned(d) = 0, "P1: no overrun");
    -- P2: payload flip, RESEND held back past TMO_LINK
    setup(3, 400000); run(2);
    rb(TL_STATUS, db); chk(unsigned(db(15 downto 8)) = R_MAX_NEW, "P2: B stops on MAX_NEW, not LINK_TIMEOUT");
    check_ids("P2");
    rb(TL_CRC_FAILS, d); chk(unsigned(d) = 1, "P2: one CRC failure counted");
    ra(TL_RESENDS, d); chk(unsigned(d) = 1, "P2: one resend");
    -- P3: link down mid-frame 4
    setup(3, 400000); run(3);
    check_ids("P3");
    rb(TL_LINK_DOWNS, d); chk(unsigned(d) = 1, "P3: one link-down counted");
    ra(TL_RESENDS, d); chk(unsigned(d) = 1, "P3: one resend");
    -- P4: every frame corrupted from frame 1, RESEND_CAP 2
    setup(2, 400000); run(4);
    ra(TL_STATUS, da); rb(TL_STATUS, db);
    chk(unsigned(da(15 downto 8)) = R_LINK_RETRY_EXHAUSTED, "P4: A stops LINK_RETRY_EXHAUSTED");
    chk(unsigned(db(15 downto 8)) = R_ABORT, "P4: B stopped by the host's ABORT");
    ra(TL_RESENDS, d); chk(unsigned(d) = 2, "P4: exactly RESEND_CAP resends");
    ra(TL_LINK_STATUS, d); chk(d(LS_TX_EXH) = '1', "P4: LINK_STATUS shows the exhausted framer");
    e := e + ea + eb;
    if e = 0 then
      report "PASS: tb_tok_loop_pair checks=" & integer'image(c) severity note;
    else
      report "FAIL: tb_tok_loop_pair errors=" & integer'image(e) severity failure;
    end if;
    std.env.finish;
  end process;
end architecture;
