-- sim/tb_jc_tok_top_rst.vhd -- the Aurora resets out of jc_tok_top while the GTG MMCM locks
-- (final review I5, 2026-11-11). init_clk and the GTG refclk come from jc_gtg_clk's MMCM, so
-- until it locks neither is trustworthy: aur_pma_init and aur_reset_pb must be HIGH while
-- gtg_locked is low, whatever LINK_CTRL says, and follow LINK_CTRL bits 1 and 0 once it is
-- high. Oracle: the two outputs sampled on every init_clk edge of each phase. Also checks the
-- loop's timeout reset values (I2): TMO_LINK resets to 0xFFFFFFFF, TMO_ENGINE to TMO_DEFAULT.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.axil_bfm_pkg.all;
use work.tok_loop_pkg.all;

entity tb_jc_tok_top_rst is
end entity;

architecture sim of tb_jc_tok_top_rst is
  signal clk, iclk, uclk : std_logic := '0';
  signal rst : std_logic := '1';
  signal locked : std_logic := '0';
  signal m : axil_m2s_t := AXIL_M2S_IDLE;
  signal s : axil_s2m_t;
  signal rpb, pma : std_logic;
  signal done : boolean := false;
begin
  clk <= not clk after 2.5 ns when not done;      -- clk_core 200 MHz
  iclk <= not iclk after 4.0 ns when not done;    -- init_clk 125 MHz
  uclk <= not uclk after 3.1 ns when not done;

  dut : entity work.jc_tok_top
    generic map(N_EMBD => 64, NLANES => 1, HAS_GATHER => false, TXPOL_MASK => 0)
    port map(aclk => clk, arst => rst,
             s_host_awaddr => (others => '0'), s_host_awvalid => '0', s_host_awready => open,
             s_host_wdata => (others => '0'), s_host_wstrb => "1111", s_host_wvalid => '0', s_host_wready => open,
             s_host_bresp => open, s_host_bvalid => open, s_host_bready => '1',
             s_host_araddr => (others => '0'), s_host_arvalid => '0', s_host_arready => open,
             s_host_rdata => open, s_host_rresp => open, s_host_rvalid => open, s_host_rready => '1',
             m_seam_awaddr => open, m_seam_awvalid => open, m_seam_awready => '1',
             m_seam_wdata => open, m_seam_wstrb => open, m_seam_wvalid => open, m_seam_wready => '1',
             m_seam_bresp => "00", m_seam_bvalid => '0', m_seam_bready => open,
             m_seam_araddr => open, m_seam_arvalid => open, m_seam_arready => '1',
             m_seam_rdata => (others => '0'), m_seam_rresp => "00", m_seam_rvalid => '0', m_seam_rready => open,
             s_ctl_awaddr => m.awaddr(15 downto 0), s_ctl_awvalid => m.awvalid, s_ctl_awready => s.awready,
             s_ctl_wdata => m.wdata, s_ctl_wstrb => m.wstrb, s_ctl_wvalid => m.wvalid, s_ctl_wready => s.wready,
             s_ctl_bresp => s.bresp, s_ctl_bvalid => s.bvalid, s_ctl_bready => m.bready,
             s_ctl_araddr => m.araddr(15 downto 0), s_ctl_arvalid => m.arvalid, s_ctl_arready => s.arready,
             s_ctl_rdata => s.rdata, s_ctl_rresp => s.rresp, s_ctl_rvalid => s.rvalid, s_ctl_rready => m.rready,
             m_hbm_araddr => open, m_hbm_arlen => open, m_hbm_arsize => open, m_hbm_arburst => open,
             m_hbm_arvalid => open, m_hbm_arready => '0', m_hbm_rdata => (others => '0'), m_hbm_rresp => "00",
             m_hbm_rlast => '0', m_hbm_rvalid => '0', m_hbm_rready => open,
             user_clk => uclk, m_axis_tx_tdata => open, m_axis_tx_tkeep => open, m_axis_tx_tlast => open,
             m_axis_tx_tvalid => open, m_axis_tx_tready => '1',
             s_axis_rx_tdata => (others => '0'), s_axis_rx_tkeep => (others => '1'), s_axis_rx_tlast => '0',
             s_axis_rx_tvalid => '0', tx_channel_up => '0', rx_channel_up => '0', gt_pll_lock => '0',
             gtg_locked => locked, init_clk => iclk, aur_reset_pb => rpb, aur_pma_init => pma,
             aur_tx_polarity => open);

  main : process
    variable e, c : natural := 0;
    variable resp : std_logic_vector(1 downto 0);
    variable d : std_logic_vector(31 downto 0);
    procedure chk(ok : boolean; msg : string) is
    begin
      c := c + 1;
      if not ok then e := e + 1; report "tb_jc_tok_top_rst: " & msg severity error; end if;
    end procedure;
    -- every init_clk edge of n: both outputs equal (want_rpb, want_pma); one check per phase
    procedure hold(n : natural; want_rpb, want_pma : std_logic; msg : string) is
      variable bad : natural := 0;
    begin
      for k in 1 to n loop
        wait until rising_edge(iclk);
        if rpb /= want_rpb or pma /= want_pma then bad := bad + 1; end if;
      end loop;
      chk(bad = 0, msg & " (" & integer'image(bad) & " of " & integer'image(n) & " init_clk edges wrong)");
    end procedure;
    procedure link_ctrl(v : natural) is
    begin
      axil_wr(clk, m, s, TL_LINK_CTRL, u32(v), resp); chk(resp = "00", "LINK_CTRL write OKAY");
      for k in 1 to 8 loop wait until rising_edge(iclk); end loop;     -- the 2-flop crossing
    end procedure;
  begin
    -- before any clock edge: the configuration values
    wait for 1 ns;
    chk(rpb = '1' and pma = '1', "both resets high at configuration, before any init_clk edge");
    hold(20, '1', '1', "MMCM not locked, arst high: both resets held");
    rst <= '0';
    for k in 1 to 5 loop wait until rising_edge(clk); end loop;
    -- the I2 reset values
    axil_rd(clk, m, s, TL_TMO_LINK, d, resp);
    chk(d = x"FFFFFFFF", "TMO_LINK resets to 0xFFFFFFFF (I2), not TMO_DEFAULT");
    axil_rd(clk, m, s, TL_TMO_ENGINE, d, resp);
    chk(unsigned(d) = TMO_DEFAULT, "TMO_ENGINE resets to TMO_DEFAULT");
    -- not locked: LINK_CTRL cannot release them
    hold(40, '1', '1', "MMCM not locked, LINK_CTRL 0 (its reset value): both resets held");
    link_ctrl(0); hold(40, '1', '1', "MMCM not locked, LINK_CTRL written 0: both resets held");
    link_ctrl(1); hold(20, '1', '1', "MMCM not locked, LINK_CTRL 1: both resets held");
    link_ctrl(2); hold(20, '1', '1', "MMCM not locked, LINK_CTRL 2: both resets held");
    link_ctrl(0);
    -- lock: the outputs follow LINK_CTRL bit 0 (reset_pb) and bit 1 (pma_init)
    locked <= '1';
    for k in 1 to 6 loop wait until rising_edge(iclk); end loop;
    hold(40, '0', '0', "locked, LINK_CTRL 0: both resets released");
    link_ctrl(1); hold(20, '1', '0', "locked, LINK_CTRL 1: reset_pb only");
    link_ctrl(2); hold(20, '0', '1', "locked, LINK_CTRL 2: pma_init only");
    link_ctrl(3); hold(20, '1', '1', "locked, LINK_CTRL 3: both");
    link_ctrl(0); hold(20, '0', '0', "locked, LINK_CTRL 0 again: both released");
    -- loss of lock re-asserts both
    locked <= '0';
    for k in 1 to 6 loop wait until rising_edge(iclk); end loop;
    hold(40, '1', '1', "lock lost: both resets re-asserted with LINK_CTRL 0");
    locked <= '1';
    for k in 1 to 6 loop wait until rising_edge(iclk); end loop;
    hold(20, '0', '0', "relocked: released again");
    if e = 0 then
      report "PASS: tb_jc_tok_top_rst checks=" & integer'image(c) severity note;
    else
      report "FAIL: tb_jc_tok_top_rst errors=" & integer'image(e) severity failure;
    end if;
    done <= true;
    std.env.finish;
  end process;
end architecture;
