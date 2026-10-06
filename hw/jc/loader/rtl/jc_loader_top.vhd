-- Jungle Cat loader: block-design module reference (Task 10). Synthesis only (UNISIM
-- primitives). Instantiates the BSCANE2 wrapper (jc_frame_rx), jc_loader_core and the
-- DNA_PORTE2 die-identity primitive, and exposes the core's AXI3 master as one
-- `m_axi` interface for hbm/SAXI_00.
--
-- Port rules (hw/fk33/CLAUDE.md): std_logic / std_logic_vector only, widths are plain
-- literals, and NO port has a default, so an unconnected input draws BD 41-759; the
-- build also refuses any module-reference input pin without a net (JCLOADER_UNCONNECTED).
--
-- The m_axi_* names and widths copy rtl/hbm_tg_ip.vhd's m00_axi_* port shape, which
-- connects straight to hbm/SAXI_nn on the FK33 (AXI3: 4-bit AxLEN, 33-bit address,
-- 6-bit IDs). jc_loader_core has no ID ports: AWID/ARID are driven zero here and
-- BID/RID are accepted and ignored (the core issues one outstanding stream per channel
-- and the HBM returns responses in order per ID).
--
-- Adaptations from the plan text (recorded in task-10-report.md):
--  * hbm_cat_trip is the OR of the two stacks' DRAM_x_STAT_CATTRIP, formed here rather
--    than with a BD logic cell.
--  * hbm_ready0/1 are the HBM IP's apb_complete_0/1 (calibration done, APB clock
--    domain). They are synchronised into aclk and hold the loader in reset until both
--    stacks have finished calibration, so no AXI burst is issued into an HBM that is
--    still initialising.
--  * fan_ctl and LED_A..D are driven, with the pins hw/jc/axiprobe used on silicon:
--    fan on (as the census and axiprobe bitstreams), LED_A configured, LED_B loader out
--    of reset, LED_C HBM catastrophic trip, LED_D aclk heartbeat.
--  * DNA_DIV = 10 at the 200 MHz aclk: dna_clk = 200 / 20 = 10 MHz. Vivado's library
--    limit for DNA_PORTE2/CLK is 4.875 ns min period and 2.275 ns min pulse width
--    (MEASURED, routed timing summary), so 100 ns / 50 ns has wide margin; the DNA bit
--    order is still ESTIMATE (rtl/jc_dna_reader.vhd).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library unisim;
use unisim.vcomponents.all;

entity jc_loader_top is
  generic(DNA_DIV : positive := 10);
  port(
    aclk          : in  std_logic;
    arst          : in  std_logic;
    hbm_cattrip0  : in  std_logic;
    hbm_cattrip1  : in  std_logic;
    hbm_ready0    : in  std_logic;
    hbm_ready1    : in  std_logic;
    fan_ctl       : out std_logic;
    led_a         : out std_logic;
    led_b         : out std_logic;
    led_c         : out std_logic;
    led_d         : out std_logic;
    m_axi_awvalid : out std_logic;
    m_axi_awready : in  std_logic;
    m_axi_awaddr  : out std_logic_vector(32 downto 0);
    m_axi_awid    : out std_logic_vector(5 downto 0);
    m_axi_awlen   : out std_logic_vector(3 downto 0);
    m_axi_awsize  : out std_logic_vector(2 downto 0);
    m_axi_awburst : out std_logic_vector(1 downto 0);
    m_axi_wvalid  : out std_logic;
    m_axi_wready  : in  std_logic;
    m_axi_wdata   : out std_logic_vector(255 downto 0);
    m_axi_wstrb   : out std_logic_vector(31 downto 0);
    m_axi_wlast   : out std_logic;
    m_axi_bvalid  : in  std_logic;
    m_axi_bready  : out std_logic;
    m_axi_bid     : in  std_logic_vector(5 downto 0);
    m_axi_bresp   : in  std_logic_vector(1 downto 0);
    m_axi_arvalid : out std_logic;
    m_axi_arready : in  std_logic;
    m_axi_araddr  : out std_logic_vector(32 downto 0);
    m_axi_arid    : out std_logic_vector(5 downto 0);
    m_axi_arlen   : out std_logic_vector(3 downto 0);
    m_axi_arsize  : out std_logic_vector(2 downto 0);
    m_axi_arburst : out std_logic_vector(1 downto 0);
    m_axi_rvalid  : in  std_logic;
    m_axi_rready  : out std_logic;
    m_axi_rdata   : in  std_logic_vector(255 downto 0);
    m_axi_rlast   : in  std_logic;
    m_axi_rid     : in  std_logic_vector(5 downto 0);
    m_axi_rresp   : in  std_logic_vector(1 downto 0)
  );
end entity;

architecture rtl of jc_loader_top is
  signal tck, sel, capture, shift, tdi, tdo : std_logic;
  signal dna_clk, dna_read, dna_shift, dna_dout : std_logic;
  signal rdy_s1, rdy_s2 : std_logic := '0';
  signal core_rst : std_logic := '1';
  signal cat_trip : std_logic;
  signal beat : unsigned(26 downto 0) := (others => '0');
  attribute ASYNC_REG : string;
  attribute ASYNC_REG of rdy_s1, rdy_s2 : signal is "TRUE";
begin
  u_jc_frx : entity work.jc_frame_rx
    port map(tck_o => tck, sel_o => sel, capture_o => capture, shift_o => shift,
             tdi_o => tdi, tdo_i => tdo);

  -- DNA_PORTE2: DIN tied '0' (nothing is ever shifted back in that is read), the other
  -- four pins to the core's jc_dna_reader (rtl/jc_dna_reader.vhd header).
  u_jc_dna : DNA_PORTE2
    port map(CLK => dna_clk, DIN => '0', READ => dna_read, SHIFT => dna_shift,
             DOUT => dna_dout);

  -- HBM calibration done, both stacks, into aclk. core_rst is a register so the
  -- reset the core sees is glitch-free and synchronous to aclk.
  process(aclk)
  begin
    if rising_edge(aclk) then
      rdy_s1   <= hbm_ready0 and hbm_ready1;
      rdy_s2   <= rdy_s1;
      core_rst <= arst or not rdy_s2;
      beat     <= beat + 1;
    end if;
  end process;

  u_jc_core : entity work.jc_loader_core
    generic map(ADDR_W => 33, DNA_DIV => DNA_DIV)
    port map(tck => tck, sel => sel, capture => capture, shift => shift, tdi => tdi,
             tdo => tdo, aclk => aclk, arst => core_rst,
             hbm_cat_trip => cat_trip,
             dna_clk => dna_clk, dna_read => dna_read, dna_shift => dna_shift,
             dna_dout => dna_dout,
             m_awaddr => m_axi_awaddr, m_awlen => m_axi_awlen, m_awsize => m_axi_awsize,
             m_awburst => m_axi_awburst, m_awvalid => m_axi_awvalid,
             m_awready => m_axi_awready, m_wdata => m_axi_wdata, m_wstrb => m_axi_wstrb,
             m_wlast => m_axi_wlast, m_wvalid => m_axi_wvalid, m_wready => m_axi_wready,
             m_bresp => m_axi_bresp, m_bvalid => m_axi_bvalid, m_bready => m_axi_bready,
             m_araddr => m_axi_araddr, m_arlen => m_axi_arlen, m_arsize => m_axi_arsize,
             m_arburst => m_axi_arburst, m_arvalid => m_axi_arvalid,
             m_arready => m_axi_arready, m_rdata => m_axi_rdata, m_rresp => m_axi_rresp,
             m_rlast => m_axi_rlast, m_rvalid => m_axi_rvalid, m_rready => m_axi_rready);

  cat_trip   <= hbm_cattrip0 or hbm_cattrip1;
  m_axi_awid <= (others => '0');
  m_axi_arid <= (others => '0');

  fan_ctl <= '1';
  led_a   <= '1';
  led_b   <= not core_rst;
  led_c   <= cat_trip;
  led_d   <= beat(26);
end architecture;
