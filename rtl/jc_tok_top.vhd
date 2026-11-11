-- rtl/jc_tok_top.vhd -- the card's module reference for the token loop (plan 2026-11-04
-- Tasks 6 and 7): tok_loop in the core clock (aclk = clk_core) plus the crossings to the
-- Aurora core's user clock and init clock. Port names follow jc_ctl_core's so the BD infers
-- s_host, m_seam, s_ctl (AXI-Lite), m_hbm (read-only AXI4) and the two AXIS interfaces.
-- TXPOL_MASK is the lane table's TX polarity (hw/jc/link/aurora_cfg.tcl), XORed with
-- LINK_CTRL bit 2 (plan D5). Same bitstream on both dies: nothing here is per-die.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity jc_tok_top is
  generic(N_EMBD : positive := 5120; NLANES : positive := 1; HAS_GATHER : boolean := true;
          TXPOL_MASK : natural := 0);
  port(
    aclk               : in  std_logic;
    arst               : in  std_logic;
    s_host_awaddr      : in  std_logic_vector(11 downto 0);
    s_host_awvalid     : in  std_logic;
    s_host_awready     : out std_logic;
    s_host_wdata       : in  std_logic_vector(31 downto 0);
    s_host_wstrb       : in  std_logic_vector(3 downto 0);
    s_host_wvalid      : in  std_logic;
    s_host_wready      : out std_logic;
    s_host_bresp       : out std_logic_vector(1 downto 0);
    s_host_bvalid      : out std_logic;
    s_host_bready      : in  std_logic;
    s_host_araddr      : in  std_logic_vector(11 downto 0);
    s_host_arvalid     : in  std_logic;
    s_host_arready     : out std_logic;
    s_host_rdata       : out std_logic_vector(31 downto 0);
    s_host_rresp       : out std_logic_vector(1 downto 0);
    s_host_rvalid      : out std_logic;
    s_host_rready      : in  std_logic;
    m_seam_awaddr      : out std_logic_vector(11 downto 0);
    m_seam_awvalid     : out std_logic;
    m_seam_awready     : in  std_logic;
    m_seam_wdata       : out std_logic_vector(31 downto 0);
    m_seam_wstrb       : out std_logic_vector(3 downto 0);
    m_seam_wvalid      : out std_logic;
    m_seam_wready      : in  std_logic;
    m_seam_bresp       : in  std_logic_vector(1 downto 0);
    m_seam_bvalid      : in  std_logic;
    m_seam_bready      : out std_logic;
    m_seam_araddr      : out std_logic_vector(11 downto 0);
    m_seam_arvalid     : out std_logic;
    m_seam_arready     : in  std_logic;
    m_seam_rdata       : in  std_logic_vector(31 downto 0);
    m_seam_rresp       : in  std_logic_vector(1 downto 0);
    m_seam_rvalid      : in  std_logic;
    m_seam_rready      : out std_logic;
    s_ctl_awaddr       : in  std_logic_vector(15 downto 0);
    s_ctl_awvalid      : in  std_logic;
    s_ctl_awready      : out std_logic;
    s_ctl_wdata        : in  std_logic_vector(31 downto 0);
    s_ctl_wstrb        : in  std_logic_vector(3 downto 0);
    s_ctl_wvalid       : in  std_logic;
    s_ctl_wready       : out std_logic;
    s_ctl_bresp        : out std_logic_vector(1 downto 0);
    s_ctl_bvalid       : out std_logic;
    s_ctl_bready       : in  std_logic;
    s_ctl_araddr       : in  std_logic_vector(15 downto 0);
    s_ctl_arvalid      : in  std_logic;
    s_ctl_arready      : out std_logic;
    s_ctl_rdata        : out std_logic_vector(31 downto 0);
    s_ctl_rresp        : out std_logic_vector(1 downto 0);
    s_ctl_rvalid       : out std_logic;
    s_ctl_rready       : in  std_logic;
    m_hbm_araddr       : out std_logic_vector(32 downto 0);
    m_hbm_arlen        : out std_logic_vector(7 downto 0);
    m_hbm_arsize       : out std_logic_vector(2 downto 0);
    m_hbm_arburst      : out std_logic_vector(1 downto 0);
    m_hbm_arvalid      : out std_logic;
    m_hbm_arready      : in  std_logic;
    m_hbm_rdata        : in  std_logic_vector(255 downto 0);
    m_hbm_rresp        : in  std_logic_vector(1 downto 0);
    m_hbm_rlast        : in  std_logic;
    m_hbm_rvalid       : in  std_logic;
    m_hbm_rready       : out std_logic;
    user_clk           : in  std_logic;
    m_axis_tx_tdata    : out std_logic_vector(64*NLANES-1 downto 0);
    m_axis_tx_tkeep    : out std_logic_vector(8*NLANES-1 downto 0);
    m_axis_tx_tlast    : out std_logic;
    m_axis_tx_tvalid   : out std_logic;
    m_axis_tx_tready   : in  std_logic;
    s_axis_rx_tdata    : in  std_logic_vector(64*NLANES-1 downto 0);
    s_axis_rx_tkeep    : in  std_logic_vector(8*NLANES-1 downto 0);
    s_axis_rx_tlast    : in  std_logic;
    s_axis_rx_tvalid   : in  std_logic;
    tx_channel_up      : in  std_logic;
    rx_channel_up      : in  std_logic;
    gt_pll_lock        : in  std_logic;
    gtg_locked         : in  std_logic;
    init_clk           : in  std_logic;
    aur_reset_pb       : out std_logic;
    aur_pma_init       : out std_logic;
    aur_tx_polarity    : out std_logic_vector(NLANES-1 downto 0));
end entity;

architecture rtl of jc_tok_top is
  -- The block design's clock association (plan 2026-11-04 Task 7), stated, not inferred: with
  -- no attribute Vivado put all six interfaces on aclk, including the two AXIS ones that run
  -- on user_clk, and then refused to change it (MEASURED jcloop_bd1, CRITICAL WARNING
  -- BD 41-737 "Cannot set the parameter ASSOCIATED_BUSIF on /tok/aclk. It is read-only").
  -- Attributes only: no logic, simulation unchanged. In the ARCHITECTURE: declared in the
  -- entity, Vivado's module-reference reader misread them (IP_Flow 19-529 "Port named
  -- 'jc_tok_top' does not exist", only aclk's seen; MEASURED jcloop_bd2).
  attribute X_INTERFACE_INFO : string;
  attribute X_INTERFACE_PARAMETER : string;
  attribute X_INTERFACE_INFO of aclk : signal is "xilinx.com:signal:clock:1.0 aclk CLK";
  attribute X_INTERFACE_PARAMETER of aclk : signal is
    "ASSOCIATED_BUSIF s_host:m_seam:s_ctl:m_hbm, ASSOCIATED_RESET arst";
  attribute X_INTERFACE_INFO of user_clk : signal is "xilinx.com:signal:clock:1.0 user_clk CLK";
  attribute X_INTERFACE_PARAMETER of user_clk : signal is "ASSOCIATED_BUSIF m_axis_tx:s_axis_rx";
  attribute X_INTERFACE_INFO of init_clk : signal is "xilinx.com:signal:clock:1.0 init_clk CLK";
  attribute X_INTERFACE_INFO of arst : signal is "xilinx.com:signal:reset:1.0 arst RST";
  attribute X_INTERFACE_PARAMETER of arst : signal is "POLARITY ACTIVE_HIGH";
  constant DW : positive := 64 * NLANES;
  signal ltx_d, lrx_d : std_logic_vector(DW-1 downto 0);
  signal ltx_l, ltx_v, ltx_r, lrx_l, lrx_v : std_logic;
  signal txq, rxq, txw, rxw : std_logic_vector(DW downto 0);
  signal txq_v, rxw_r : std_logic;
  signal link_ctrl : std_logic_vector(31 downto 0);
  signal s_tx, s_rx, s_pll, s_gtg, s_ovf : std_logic_vector(1 downto 0) := "00";
  signal u_rst_s : std_logic_vector(1 downto 0) := "11";
  signal u_rst, ovf_u : std_logic := '0';
  signal i_rpb, i_pma : std_logic_vector(1 downto 0) := "00";
  signal u_pol : std_logic_vector(2*NLANES-1 downto 0) := (others => '0');
  signal pol_mask : std_logic_vector(NLANES-1 downto 0);
  -- the synchroniser first stages; hw/jc/link/jc_link_timing.tcl names each one
  attribute ASYNC_REG : string;
  attribute ASYNC_REG of s_tx, s_rx, s_pll, s_gtg, s_ovf, u_rst_s, i_rpb, i_pma, u_pol : signal is "TRUE";
begin
  core : entity work.tok_loop
    generic map(N_EMBD => N_EMBD, HAS_GATHER => HAS_GATHER, HAS_LINK => true, NLANES => NLANES)
    port map(clk => aclk, rst => arst,
             s_ctl_awaddr => s_ctl_awaddr, s_ctl_awvalid => s_ctl_awvalid, s_ctl_awready => s_ctl_awready,
             s_ctl_wdata => s_ctl_wdata, s_ctl_wstrb => s_ctl_wstrb, s_ctl_wvalid => s_ctl_wvalid,
             s_ctl_wready => s_ctl_wready, s_ctl_bresp => s_ctl_bresp, s_ctl_bvalid => s_ctl_bvalid,
             s_ctl_bready => s_ctl_bready, s_ctl_araddr => s_ctl_araddr, s_ctl_arvalid => s_ctl_arvalid,
             s_ctl_arready => s_ctl_arready, s_ctl_rdata => s_ctl_rdata, s_ctl_rresp => s_ctl_rresp,
             s_ctl_rvalid => s_ctl_rvalid, s_ctl_rready => s_ctl_rready,
             s_host_awaddr => s_host_awaddr, s_host_awvalid => s_host_awvalid, s_host_awready => s_host_awready,
             s_host_wdata => s_host_wdata, s_host_wstrb => s_host_wstrb, s_host_wvalid => s_host_wvalid,
             s_host_wready => s_host_wready, s_host_bresp => s_host_bresp, s_host_bvalid => s_host_bvalid,
             s_host_bready => s_host_bready, s_host_araddr => s_host_araddr, s_host_arvalid => s_host_arvalid,
             s_host_arready => s_host_arready, s_host_rdata => s_host_rdata, s_host_rresp => s_host_rresp,
             s_host_rvalid => s_host_rvalid, s_host_rready => s_host_rready,
             m_seam_awaddr => m_seam_awaddr, m_seam_awvalid => m_seam_awvalid, m_seam_awready => m_seam_awready,
             m_seam_wdata => m_seam_wdata, m_seam_wstrb => m_seam_wstrb, m_seam_wvalid => m_seam_wvalid,
             m_seam_wready => m_seam_wready, m_seam_bresp => m_seam_bresp, m_seam_bvalid => m_seam_bvalid,
             m_seam_bready => m_seam_bready, m_seam_araddr => m_seam_araddr, m_seam_arvalid => m_seam_arvalid,
             m_seam_arready => m_seam_arready, m_seam_rdata => m_seam_rdata, m_seam_rresp => m_seam_rresp,
             m_seam_rvalid => m_seam_rvalid, m_seam_rready => m_seam_rready,
             host_refused => open,
             m_hbm_araddr => m_hbm_araddr, m_hbm_arlen => m_hbm_arlen, m_hbm_arsize => m_hbm_arsize,
             m_hbm_arburst => m_hbm_arburst, m_hbm_arvalid => m_hbm_arvalid, m_hbm_arready => m_hbm_arready,
             m_hbm_rdata => m_hbm_rdata, m_hbm_rresp => m_hbm_rresp, m_hbm_rlast => m_hbm_rlast,
             m_hbm_rvalid => m_hbm_rvalid, m_hbm_rready => m_hbm_rready,
             ltx_tdata => ltx_d, ltx_tkeep => open, ltx_tlast => ltx_l, ltx_tvalid => ltx_v, ltx_tready => ltx_r,
             lrx_tdata => lrx_d, lrx_tlast => lrx_l, lrx_tvalid => lrx_v,
             lnk_tx_up => s_tx(1), lnk_rx_up => s_rx(1), lnk_gtg_lock => s_gtg(1),
             lnk_pll_lock => s_pll(1), lnk_rx_ovf => s_ovf(1), link_ctrl => link_ctrl);

  -- TX: core clock -> user clock
  txw <= ltx_l & ltx_d;
  txf : entity work.async_fifo
    generic map(W => DW + 1, DEPTH => 64, FAST_POP => true)
    port map(wclk => aclk, wrst => arst, w_valid => ltx_v, w_data => txw, w_ready => ltx_r,
             w_level => open, clr => '0', clr_done => open,
             rclk => user_clk, rrst => u_rst, q_valid => txq_v, q_data => txq, q_ready => m_axis_tx_tready);
  m_axis_tx_tdata <= txq(DW-1 downto 0);  m_axis_tx_tlast <= txq(DW);
  m_axis_tx_tvalid <= txq_v;              m_axis_tx_tkeep <= (others => '1');

  -- RX: user clock -> core clock; no backpressure, so an overflow is counted, never stalled
  rxw <= s_axis_rx_tlast & s_axis_rx_tdata;
  rxf : entity work.async_fifo
    generic map(W => DW + 1, DEPTH => 64, FAST_POP => true)
    port map(wclk => user_clk, wrst => u_rst, w_valid => s_axis_rx_tvalid, w_data => rxw, w_ready => rxw_r,
             w_level => open, clr => '0', clr_done => open,
             rclk => aclk, rrst => arst, q_valid => lrx_v, q_data => rxq, q_ready => '1');
  lrx_d <= rxq(DW-1 downto 0);  lrx_l <= rxq(DW);

  -- user clock domain: reset, overflow flag, TX polarity
  pol_mask <= std_logic_vector(to_unsigned(TXPOL_MASK, NLANES));
  process(user_clk)
  begin
    if rising_edge(user_clk) then
      u_rst_s <= u_rst_s(0) & arst;  u_rst <= u_rst_s(1);
      if u_rst = '1' then ovf_u <= '0';
      elsif s_axis_rx_tvalid = '1' and rxw_r = '0' then ovf_u <= '1'; end if;
      for i in 0 to NLANES - 1 loop
        u_pol(2*i+1) <= u_pol(2*i);  u_pol(2*i) <= link_ctrl(2) xor pol_mask(i);
        aur_tx_polarity(i) <= u_pol(2*i+1);
      end loop;
    end if;
  end process;

  -- core clock domain: status synchronisers
  process(aclk)
  begin
    if rising_edge(aclk) then
      s_tx <= s_tx(0) & tx_channel_up;  s_rx <= s_rx(0) & rx_channel_up;
      s_pll <= s_pll(0) & gt_pll_lock;  s_gtg <= s_gtg(0) & gtg_locked;
      s_ovf <= s_ovf(0) & ovf_u;
    end if;
  end process;

  -- init clock domain: the Aurora resets (PG074: reset_pb and pma_init are init_clk inputs)
  process(init_clk)
  begin
    if rising_edge(init_clk) then
      i_rpb <= i_rpb(0) & link_ctrl(0);  i_pma <= i_pma(0) & link_ctrl(1);
    end if;
  end process;
  aur_reset_pb <= i_rpb(1);
  aur_pma_init <= i_pma(1);
end architecture;
