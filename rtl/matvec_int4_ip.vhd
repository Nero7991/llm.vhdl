-- rtl/matvec_int4_ip.vhd -- board-facing wrapper: named AXI interfaces.
--
-- GENERATED-SHAPED but checked in by hand: the five read masters need
-- individually NAMED ports (m00_axi_*, m01_axi_* ...) because that is what
-- Vivado's interface inference keys on.  matvec_int4_axi carries them flattened
-- into vectors, which is right for a generate loop and useless to a block
-- design, so this wrapper is the only place the two conventions meet.
--
-- READ-ONLY masters: only the AR and R channels exist.  Subsystem A never
-- writes to DDR -- results come back through the AXI-Lite result buffer (14.4)
-- -- so emitting a write channel would be five sets of tied-off ports for
-- nothing.
--
-- One master per PS slave port is deliberate: HP0..HP3 take the four weight
-- sub-regions and HPC0 takes the scales, so the four weight streams do not
-- share a port.  Sharing would halve the delivered bandwidth, and sustained
-- bandwidth is the acceptance criterion of 11, not an incidental.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity matvec_int4_ip is
  generic(
    BLK         : positive := 32;
    ROWS_IF     : positive := 4;
    AXI_DW      : positive := 128;
    ADDR_W      : positive := 32;
    MAXCOLS     : positive := 17408;
    MAXROWS_BFP : positive := 17408;
    FIFO_DEPTH  : positive := 512;
    MAXB        : positive := 256;
    MAXOUT      : positive := 2
  );
  port(
    s_axi_aclk    : in  std_logic;
    s_axi_aresetn : in  std_logic;
    s_axi_awaddr  : in  std_logic_vector(7 downto 0);
    s_axi_awprot  : in  std_logic_vector(2 downto 0);
    s_axi_awvalid : in  std_logic;
    s_axi_awready : out std_logic;
    s_axi_wdata   : in  std_logic_vector(31 downto 0);
    s_axi_wstrb   : in  std_logic_vector(3 downto 0);
    s_axi_wvalid  : in  std_logic;
    s_axi_wready  : out std_logic;
    s_axi_bresp   : out std_logic_vector(1 downto 0);
    s_axi_bvalid  : out std_logic;
    s_axi_bready  : in  std_logic;
    s_axi_araddr  : in  std_logic_vector(7 downto 0);
    s_axi_arprot  : in  std_logic_vector(2 downto 0);
    s_axi_arvalid : in  std_logic;
    s_axi_arready : out std_logic;
    s_axi_rdata   : out std_logic_vector(31 downto 0);
    s_axi_rresp   : out std_logic_vector(1 downto 0);
    s_axi_rvalid  : out std_logic;
    s_axi_rready  : in  std_logic;
    m00_axi_arvalid : out std_logic;
    m00_axi_arready : in  std_logic;
    m00_axi_araddr  : out std_logic_vector(ADDR_W-1 downto 0);
    m00_axi_arlen   : out std_logic_vector(7 downto 0);
    m00_axi_arsize  : out std_logic_vector(2 downto 0);
    m00_axi_arburst : out std_logic_vector(1 downto 0);
    m00_axi_arlock  : out std_logic;
    m00_axi_arcache : out std_logic_vector(3 downto 0);
    m00_axi_arprot  : out std_logic_vector(2 downto 0);
    m00_axi_arqos   : out std_logic_vector(3 downto 0);
    m00_axi_rvalid  : in  std_logic;
    m00_axi_rready  : out std_logic;
    m00_axi_rdata   : in  std_logic_vector(AXI_DW-1 downto 0);
    m00_axi_rresp   : in  std_logic_vector(1 downto 0);
    m00_axi_rlast   : in  std_logic;
    m01_axi_arvalid : out std_logic;
    m01_axi_arready : in  std_logic;
    m01_axi_araddr  : out std_logic_vector(ADDR_W-1 downto 0);
    m01_axi_arlen   : out std_logic_vector(7 downto 0);
    m01_axi_arsize  : out std_logic_vector(2 downto 0);
    m01_axi_arburst : out std_logic_vector(1 downto 0);
    m01_axi_arlock  : out std_logic;
    m01_axi_arcache : out std_logic_vector(3 downto 0);
    m01_axi_arprot  : out std_logic_vector(2 downto 0);
    m01_axi_arqos   : out std_logic_vector(3 downto 0);
    m01_axi_rvalid  : in  std_logic;
    m01_axi_rready  : out std_logic;
    m01_axi_rdata   : in  std_logic_vector(AXI_DW-1 downto 0);
    m01_axi_rresp   : in  std_logic_vector(1 downto 0);
    m01_axi_rlast   : in  std_logic;
    m02_axi_arvalid : out std_logic;
    m02_axi_arready : in  std_logic;
    m02_axi_araddr  : out std_logic_vector(ADDR_W-1 downto 0);
    m02_axi_arlen   : out std_logic_vector(7 downto 0);
    m02_axi_arsize  : out std_logic_vector(2 downto 0);
    m02_axi_arburst : out std_logic_vector(1 downto 0);
    m02_axi_arlock  : out std_logic;
    m02_axi_arcache : out std_logic_vector(3 downto 0);
    m02_axi_arprot  : out std_logic_vector(2 downto 0);
    m02_axi_arqos   : out std_logic_vector(3 downto 0);
    m02_axi_rvalid  : in  std_logic;
    m02_axi_rready  : out std_logic;
    m02_axi_rdata   : in  std_logic_vector(AXI_DW-1 downto 0);
    m02_axi_rresp   : in  std_logic_vector(1 downto 0);
    m02_axi_rlast   : in  std_logic;
    m03_axi_arvalid : out std_logic;
    m03_axi_arready : in  std_logic;
    m03_axi_araddr  : out std_logic_vector(ADDR_W-1 downto 0);
    m03_axi_arlen   : out std_logic_vector(7 downto 0);
    m03_axi_arsize  : out std_logic_vector(2 downto 0);
    m03_axi_arburst : out std_logic_vector(1 downto 0);
    m03_axi_arlock  : out std_logic;
    m03_axi_arcache : out std_logic_vector(3 downto 0);
    m03_axi_arprot  : out std_logic_vector(2 downto 0);
    m03_axi_arqos   : out std_logic_vector(3 downto 0);
    m03_axi_rvalid  : in  std_logic;
    m03_axi_rready  : out std_logic;
    m03_axi_rdata   : in  std_logic_vector(AXI_DW-1 downto 0);
    m03_axi_rresp   : in  std_logic_vector(1 downto 0);
    m03_axi_rlast   : in  std_logic;
    m04_axi_arvalid : out std_logic;
    m04_axi_arready : in  std_logic;
    m04_axi_araddr  : out std_logic_vector(ADDR_W-1 downto 0);
    m04_axi_arlen   : out std_logic_vector(7 downto 0);
    m04_axi_arsize  : out std_logic_vector(2 downto 0);
    m04_axi_arburst : out std_logic_vector(1 downto 0);
    m04_axi_arlock  : out std_logic;
    m04_axi_arcache : out std_logic_vector(3 downto 0);
    m04_axi_arprot  : out std_logic_vector(2 downto 0);
    m04_axi_arqos   : out std_logic_vector(3 downto 0);
    m04_axi_rvalid  : in  std_logic;
    m04_axi_rready  : out std_logic;
    m04_axi_rdata   : in  std_logic_vector(AXI_DW-1 downto 0);
    m04_axi_rresp   : in  std_logic_vector(1 downto 0);
    m04_axi_rlast   : in  std_logic
  );
end entity;

architecture rtl of matvec_int4_ip is
  constant NP : positive := ROWS_IF;   -- NPORTS_W, the 6.5 invariant
  signal arvalid, arready, rvalid, rready, rlast : std_logic_vector(NP downto 0);
  signal araddr  : std_logic_vector((NP+1)*ADDR_W-1 downto 0);
  signal arlen   : std_logic_vector((NP+1)*8-1 downto 0);
  signal arsize  : std_logic_vector((NP+1)*3-1 downto 0);
  signal arburst : std_logic_vector((NP+1)*2-1 downto 0);
  signal rdata   : std_logic_vector((NP+1)*AXI_DW-1 downto 0);
begin
  core : entity work.matvec_int4_axi
    generic map(BLK => BLK, ROWS_IF => ROWS_IF, NPORTS_W => NP,
                AXI_DW => AXI_DW, ADDR_W => ADDR_W, MAXCOLS => MAXCOLS,
                MAXROWS_BFP => MAXROWS_BFP, FIFO_DEPTH => FIFO_DEPTH,
                MAXB => MAXB, MAXOUT => MAXOUT,
                C_S_AXI_ADDR_WIDTH => 8)
    port map(
      s_axi_aclk => s_axi_aclk, s_axi_aresetn => s_axi_aresetn,
      s_axi_awaddr => s_axi_awaddr, s_axi_awprot => s_axi_awprot,
      s_axi_awvalid => s_axi_awvalid, s_axi_awready => s_axi_awready,
      s_axi_wdata => s_axi_wdata, s_axi_wstrb => s_axi_wstrb,
      s_axi_wvalid => s_axi_wvalid, s_axi_wready => s_axi_wready,
      s_axi_bresp => s_axi_bresp, s_axi_bvalid => s_axi_bvalid,
      s_axi_bready => s_axi_bready,
      s_axi_araddr => s_axi_araddr, s_axi_arprot => s_axi_arprot,
      s_axi_arvalid => s_axi_arvalid, s_axi_arready => s_axi_arready,
      s_axi_rdata => s_axi_rdata, s_axi_rresp => s_axi_rresp,
      s_axi_rvalid => s_axi_rvalid, s_axi_rready => s_axi_rready,
      m_arvalid => arvalid, m_arready => arready, m_araddr => araddr,
      m_arlen => arlen, m_arsize => arsize, m_arburst => arburst,
      m_rvalid => rvalid, m_rready => rready, m_rdata => rdata,
      m_rlast => rlast);

  m00_axi_arvalid <= arvalid(0);
  arready(0)  <= m00_axi_arready;
  m00_axi_araddr  <= araddr(1*ADDR_W-1 downto 0*ADDR_W);
  m00_axi_arlen   <= arlen(1*8-1 downto 0*8);
  m00_axi_arsize  <= arsize(1*3-1 downto 0*3);
  m00_axi_arburst <= arburst(1*2-1 downto 0*2);
  m00_axi_arlock  <= '0';
  m00_axi_arcache <= "0011";      -- normal, non-cacheable, bufferable
  m00_axi_arprot  <= "000";
  m00_axi_arqos   <= "0000";
  rvalid(0)   <= m00_axi_rvalid;
  m00_axi_rready  <= rready(0);
  rdata(1*AXI_DW-1 downto 0*AXI_DW) <= m00_axi_rdata;
  rlast(0)    <= m00_axi_rlast;
  m01_axi_arvalid <= arvalid(1);
  arready(1)  <= m01_axi_arready;
  m01_axi_araddr  <= araddr(2*ADDR_W-1 downto 1*ADDR_W);
  m01_axi_arlen   <= arlen(2*8-1 downto 1*8);
  m01_axi_arsize  <= arsize(2*3-1 downto 1*3);
  m01_axi_arburst <= arburst(2*2-1 downto 1*2);
  m01_axi_arlock  <= '0';
  m01_axi_arcache <= "0011";      -- normal, non-cacheable, bufferable
  m01_axi_arprot  <= "000";
  m01_axi_arqos   <= "0000";
  rvalid(1)   <= m01_axi_rvalid;
  m01_axi_rready  <= rready(1);
  rdata(2*AXI_DW-1 downto 1*AXI_DW) <= m01_axi_rdata;
  rlast(1)    <= m01_axi_rlast;
  m02_axi_arvalid <= arvalid(2);
  arready(2)  <= m02_axi_arready;
  m02_axi_araddr  <= araddr(3*ADDR_W-1 downto 2*ADDR_W);
  m02_axi_arlen   <= arlen(3*8-1 downto 2*8);
  m02_axi_arsize  <= arsize(3*3-1 downto 2*3);
  m02_axi_arburst <= arburst(3*2-1 downto 2*2);
  m02_axi_arlock  <= '0';
  m02_axi_arcache <= "0011";      -- normal, non-cacheable, bufferable
  m02_axi_arprot  <= "000";
  m02_axi_arqos   <= "0000";
  rvalid(2)   <= m02_axi_rvalid;
  m02_axi_rready  <= rready(2);
  rdata(3*AXI_DW-1 downto 2*AXI_DW) <= m02_axi_rdata;
  rlast(2)    <= m02_axi_rlast;
  m03_axi_arvalid <= arvalid(3);
  arready(3)  <= m03_axi_arready;
  m03_axi_araddr  <= araddr(4*ADDR_W-1 downto 3*ADDR_W);
  m03_axi_arlen   <= arlen(4*8-1 downto 3*8);
  m03_axi_arsize  <= arsize(4*3-1 downto 3*3);
  m03_axi_arburst <= arburst(4*2-1 downto 3*2);
  m03_axi_arlock  <= '0';
  m03_axi_arcache <= "0011";      -- normal, non-cacheable, bufferable
  m03_axi_arprot  <= "000";
  m03_axi_arqos   <= "0000";
  rvalid(3)   <= m03_axi_rvalid;
  m03_axi_rready  <= rready(3);
  rdata(4*AXI_DW-1 downto 3*AXI_DW) <= m03_axi_rdata;
  rlast(3)    <= m03_axi_rlast;
  m04_axi_arvalid <= arvalid(4);
  arready(4)  <= m04_axi_arready;
  m04_axi_araddr  <= araddr(5*ADDR_W-1 downto 4*ADDR_W);
  m04_axi_arlen   <= arlen(5*8-1 downto 4*8);
  m04_axi_arsize  <= arsize(5*3-1 downto 4*3);
  m04_axi_arburst <= arburst(5*2-1 downto 4*2);
  m04_axi_arlock  <= '0';
  m04_axi_arcache <= "0011";      -- normal, non-cacheable, bufferable
  m04_axi_arprot  <= "000";
  m04_axi_arqos   <= "0000";
  rvalid(4)   <= m04_axi_rvalid;
  m04_axi_rready  <= rready(4);
  rdata(5*AXI_DW-1 downto 4*AXI_DW) <= m04_axi_rdata;
  rlast(4)    <= m04_axi_rlast;

end architecture;
