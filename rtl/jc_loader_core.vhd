-- Jungle Cat loader: composition (spec S3). TCK side: jc_frame_core. Crossing:
-- async_fifo (258 x 128) for words, jc_status_sync for status. aclk side: jc_hbm_writer
-- (AXI3 write channels) and jc_hbm_crc (AXI3 read channels) share one master port.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.jc_loader_pkg.all;

entity jc_loader_core is
  generic(ADDR_W : positive := 33);
  port(
    tck, sel, capture, shift, tdi : in  std_logic;
    tdo          : out std_logic;
    aclk, arst   : in  std_logic;
    hbm_cat_trip : in  std_logic;
    m_awaddr  : out std_logic_vector(ADDR_W-1 downto 0);
    m_awlen   : out std_logic_vector(3 downto 0);
    m_awsize  : out std_logic_vector(2 downto 0);
    m_awburst : out std_logic_vector(1 downto 0);
    m_awvalid : out std_logic;
    m_awready : in  std_logic;
    m_wdata   : out std_logic_vector(255 downto 0);
    m_wstrb   : out std_logic_vector(31 downto 0);
    m_wlast   : out std_logic;
    m_wvalid  : out std_logic;
    m_wready  : in  std_logic;
    m_bresp   : in  std_logic_vector(1 downto 0);
    m_bvalid  : in  std_logic;
    m_bready  : out std_logic;
    m_araddr  : out std_logic_vector(ADDR_W-1 downto 0);
    m_arlen   : out std_logic_vector(3 downto 0);
    m_arsize  : out std_logic_vector(2 downto 0);
    m_arburst : out std_logic_vector(1 downto 0);
    m_arvalid : out std_logic;
    m_arready : in  std_logic;
    m_rdata   : in  std_logic_vector(255 downto 0);
    m_rresp   : in  std_logic_vector(1 downto 0);
    m_rlast   : in  std_logic;
    m_rvalid  : in  std_logic;
    m_rready  : out std_logic
  );
end entity;

architecture rtl of jc_loader_core is
  signal w_valid, w_ready, q_valid, q_ready : std_logic;
  signal w_data, q_data : std_logic_vector(JC_FIFO_W-1 downto 0);
  signal st_tck, live : std_logic_vector(255 downto 0);
  signal desync : unsigned(15 downto 0);
  signal ovf : std_logic;
  signal trst_s1, trst_s2 : std_logic := '1';
  signal crc_req, crc_busy, res_valid, res_err, w_busy : std_logic;
  signal crc_addr : std_logic_vector(ADDR_W-1 downto 0);
  signal crc_len : unsigned(39 downto 0);
  signal crc_seq, res_crc, res_seq, last_seq : std_logic_vector(31 downto 0);
  signal committed : unsigned(31 downto 0);
  signal crc_fail, seq_err, dup_cnt, bresp_err : unsigned(15 downto 0);
  attribute ASYNC_REG : string;
  attribute ASYNC_REG of trst_s1, trst_s2 : signal is "TRUE";
begin
  -- FIFO write-side reset in TCK: held from configuration until two TCK edges after arst
  -- falls. The host's filler slot absorbs those edges.
  process(tck)
  begin
    if rising_edge(tck) then
      trst_s1 <= arst;
      trst_s2 <= trst_s1;
    end if;
  end process;

  rx : entity work.jc_frame_core
    port map(tck => tck, sel => sel, capture => capture, shift => shift, tdi => tdi,
             tdo => tdo, w_valid => w_valid, w_data => w_data, w_ready => w_ready,
             st_in => st_tck, desync_cnt => desync, ovf_seen => ovf);

  fifo : entity work.async_fifo
    generic map(W => JC_FIFO_W, DEPTH => 128)
    port map(wclk => tck, wrst => trst_s2, w_valid => w_valid, w_data => w_data,
             w_ready => w_ready, w_level => open, clr => '0', clr_done => open,
             rclk => aclk, rrst => arst, q_valid => q_valid, q_data => q_data,
             q_ready => q_ready);

  wr : entity work.jc_hbm_writer
    generic map(ADDR_W => ADDR_W)
    port map(clk => aclk, rst => arst, q_valid => q_valid, q_data => q_data,
             q_ready => q_ready, awaddr => m_awaddr, awlen => m_awlen, awsize => m_awsize,
             awburst => m_awburst, awvalid => m_awvalid, awready => m_awready,
             wdata => m_wdata, wstrb => m_wstrb, wlast => m_wlast, wvalid => m_wvalid,
             wready => m_wready, bresp => m_bresp, bvalid => m_bvalid, bready => m_bready,
             crc_req => crc_req, crc_addr => crc_addr, crc_len => crc_len,
             crc_seq => crc_seq, crc_busy => crc_busy, last_seq => last_seq,
             committed => committed, crc_fail => crc_fail, seq_err => seq_err,
             dup_cnt => dup_cnt, bresp_err => bresp_err, busy => w_busy);

  cu : entity work.jc_hbm_crc
    generic map(ADDR_W => ADDR_W)
    port map(clk => aclk, rst => arst, req => crc_req, req_addr => crc_addr,
             req_len => crc_len, req_seq => crc_seq, busy => crc_busy,
             araddr => m_araddr, arlen => m_arlen, arsize => m_arsize,
             arburst => m_arburst, arvalid => m_arvalid, arready => m_arready,
             rdata => m_rdata, rresp => m_rresp, rlast => m_rlast, rvalid => m_rvalid,
             rready => m_rready, res_valid => res_valid, res_err => res_err,
             res_crc => res_crc, res_seq => res_seq);

  -- aclk-side status (the plan's "Status word layout"); the core fills magic, desync, ovf
  live(31 downto 0)    <= (others => '0');
  live(63 downto 32)   <= last_seq;
  live(95 downto 64)   <= std_logic_vector(committed);
  live(111 downto 96)  <= std_logic_vector(crc_fail);
  live(127 downto 112) <= std_logic_vector(seq_err);
  live(143 downto 128) <= (others => '0');
  live(159 downto 144) <= std_logic_vector(bresp_err);
  live(175 downto 160) <= std_logic_vector(dup_cnt);
  live(176)            <= w_busy or crc_busy;
  live(177)            <= hbm_cat_trip;
  live(178)            <= res_valid;
  live(179)            <= '0';
  live(180)            <= res_err;
  live(191 downto 181) <= (others => '0');
  live(223 downto 192) <= res_crc;
  live(255 downto 224) <= res_seq;

  sync : entity work.jc_status_sync
    port map(aclk => aclk, live => live, tck => tck, st_tck => st_tck);
end architecture;
