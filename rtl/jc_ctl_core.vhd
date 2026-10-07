-- Jungle Cat USER3 control core: composition (plan Task 4; spec 2026-10-07 S3).
--
--   TCK side   jc_ctl_frame_core   receive frames, shift status + response out on TDO
--   crossing   async_fifo 258 x 128 (the loader's instance shape) for the tagged words
--              jc_status_sync (W = 384) for the executor's status, aclk -> TCK
--              rak_s1/rak_s2: 2-FF ASYNC_REG synchroniser for rsp_ack_tgl, TCK -> aclk
--              rram: 512 x 32 dual-clock BRAM, written on aclk, read on TCK
--   aclk side  jc_ctl_exec         execute frames on AXI-Lite (m_axil_*) and HBM (m_axi_*)
--
-- No BSCANE2 here: hw/jc/ctl/rtl/jc_ctl_rx.vhd (JTAG_CHAIN => 3 + BUFG) supplies tck, sel,
-- capture, shift, tdi and takes tdo, so this file is GHDL-testable end to end. The port
-- names are hw/jc/card/gen_jc_card.py's "jc_ctl_core PORT TABLE". This file is written as
-- VHDL-93 (it is a block-design module-reference top): std_logic/std_logic_vector ports,
-- literal widths, no input defaults.
--
-- STATUS CROSSING (why jc_status_sync is safe for this use; full argument in
-- hw/jc/ctl/README.md). aclk takes a snapshot `snap` of the executor's status and flips
-- `pub` on the SAME edge, and takes the next snapshot only after TCK's `ack` has come
-- back through two flops; TCK copies `snap` into `st_r` only after seeing `pub` through
-- two flops and flips `ack` on that same edge. So (1) every st_r value is ONE snapshot,
-- all 384 bits from one aclk edge (coherent); (2) st_r only ever moves to the snapshot
-- taken after the one it holds (monotonic: never older); (3) it can be arbitrarily STALE
-- when TCK has been stopped, because TCK-side progress happens only on TCK edges. The
-- frame core's stale rule exists for (3); the executor's single-cycle completion makes
-- every snapshot a consistent frame boundary. The bench (sim/tb_jc_ctl_core.vhd)
-- measures (1), (2) and the snap-to-capture stability margin with status changing on
-- every aclk.
--
-- RESET CONTRACT.
--   * `arst` is active high. In the card BD it is core_reset/peripheral_reset, a
--     proc_sys_reset output already synchronous to clk_core; it still passes through a
--     2-FF synchroniser here (rst_s1/rst_s2), so an asynchronous source is also safe.
--     Assertion and release reach the executor two aclk cycles late.
--   * The executor drops AXI VALIDs when reset mid-transaction. That is only legal if the
--     AXI-Lite interconnect (axil2eng) and the HBM smartconnect (hbm_sc) are reset
--     TOGETHER with this core: they are, from the same proc_sys_reset (peripheral_aresetn
--     is the complement of peripheral_reset). Never reset this core alone.
--   * The async FIFO is NEVER reset. Its TCK side cannot see a reset while TCK is stopped
--     (rtl/jc_loader_core.vhd's reset note), and a one-sided pointer reset replays stale
--     words. Instead, while rst is high the executor neither sees nor pops FIFO words
--     (q_valid and q_ready are gated), so words already queued survive the reset and are
--     taken afterwards; the executor restarts with no open frame and discards orphan
--     DATA/PASS words until the next HDR. Net effect: a frame whose PASS was popped
--     before the reset is dropped (its seq never reaches last_done_seq), a frame still
--     queued executes after it, and no frame executes twice.
--   * jc_ctl_frame_core and the TCK half of jc_status_sync have no reset: the desync,
--     crc-fail and ovf counts are sticky for the life of the configuration, as the loader's.
--   * After a reset the executor shows last_done_seq = rsp_seq = err_seq = x"FFFFFFFF",
--     rsp_valid = 0. The host must treat a last_done_seq that went BACK to none as "reset
--     happened": every frame in flight is UNKNOWN.
--
-- RESPONSE RAM. A read response is written by the executor before it publishes rsp_valid
-- (S_DONE), and the RAM is not written again until the host's ack clears rsp_valid. The one
-- overlap is the ACK SLOT: the ack toggles at bit 16159 of the frame that carries it, but
-- that slot keeps shifting the acked response's last words (bits 16160..16255, words
-- 493..495 of a 496-word response) while a following MEM_RD may already be writing them.
-- The host has accepted that response from an earlier slot; the ack slot's copy can be
-- torn, and its rsp_crc (the acked response's) then does not match, so it is detected,
-- not silent. The host must never accept a response from the slot that carried its ack.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.jc_loader_pkg.all;
use work.jc_ctl_pkg.all;

entity jc_ctl_core is
  generic(TMO_CYC : positive := 65536);
  port(
    aclk           : in  std_logic;
    arst           : in  std_logic;
    -- USER3 BSCANE2 signals (through jc_ctl_rx)
    tck            : in  std_logic;
    sel            : in  std_logic;
    capture        : in  std_logic;
    shift          : in  std_logic;
    tdi            : in  std_logic;
    tdo            : out std_logic;
    -- AXI-Lite master (32-bit address and data)
    m_axil_awaddr  : out std_logic_vector(31 downto 0);
    m_axil_awprot  : out std_logic_vector(2 downto 0);
    m_axil_awvalid : out std_logic;
    m_axil_awready : in  std_logic;
    m_axil_wdata   : out std_logic_vector(31 downto 0);
    m_axil_wstrb   : out std_logic_vector(3 downto 0);
    m_axil_wvalid  : out std_logic;
    m_axil_wready  : in  std_logic;
    m_axil_bresp   : in  std_logic_vector(1 downto 0);
    m_axil_bvalid  : in  std_logic;
    m_axil_bready  : out std_logic;
    m_axil_araddr  : out std_logic_vector(31 downto 0);
    m_axil_arprot  : out std_logic_vector(2 downto 0);
    m_axil_arvalid : out std_logic;
    m_axil_arready : in  std_logic;
    m_axil_rdata   : in  std_logic_vector(31 downto 0);
    m_axil_rresp   : in  std_logic_vector(1 downto 0);
    m_axil_rvalid  : in  std_logic;
    m_axil_rready  : out std_logic;
    -- AXI4 read-only master toward HBM (33-bit address, 256-bit data, ARLEN <= 15)
    m_axi_araddr   : out std_logic_vector(32 downto 0);
    m_axi_arlen    : out std_logic_vector(7 downto 0);
    m_axi_arsize   : out std_logic_vector(2 downto 0);
    m_axi_arburst  : out std_logic_vector(1 downto 0);
    m_axi_arvalid  : out std_logic;
    m_axi_arready  : in  std_logic;
    m_axi_rdata    : in  std_logic_vector(255 downto 0);
    m_axi_rresp    : in  std_logic_vector(1 downto 0);
    m_axi_rlast    : in  std_logic;
    m_axi_rvalid   : in  std_logic;
    m_axi_rready   : out std_logic
  );
end entity;

architecture rtl of jc_ctl_core is
  -- reset synchroniser (aclk)
  signal rst_s1, rst_s2 : std_logic := '1';
  -- frame core <-> FIFO
  signal w_valid, w_ready : std_logic;
  signal w_data : std_logic_vector(JC_FIFO_W-1 downto 0);
  -- FIFO <-> executor (q_vx / q_rx are the reset-gated pair the executor sees)
  signal q_valid, q_ready, q_vx, q_rx : std_logic;
  signal q_data : std_logic_vector(JC_FIFO_W-1 downto 0);
  -- status
  signal st_live, st_tck : std_logic_vector(JC_CTL_STATUS_BITS-1 downto 0);
  -- ack toggle, TCK -> aclk
  signal ack_tgl : std_logic;
  signal rak_s1, rak_s2 : std_logic := '0';
  -- response RAM
  type rram_t is array (0 to 2**JC_CTL_RSP_AW - 1) of std_logic_vector(31 downto 0);
  signal rram : rram_t := (others => (others => '0'));
  signal rsp_we : std_logic;
  signal rsp_waddr, rsp_addr : std_logic_vector(JC_CTL_RSP_AW-1 downto 0);
  signal rsp_wdata : std_logic_vector(31 downto 0);
  signal rsp_q : std_logic_vector(31 downto 0) := (others => '0');

  attribute ASYNC_REG : string;
  attribute ASYNC_REG of rst_s1, rst_s2 : signal is "TRUE";
  attribute ASYNC_REG of rak_s1, rak_s2 : signal is "TRUE";
  attribute ram_style : string;
  attribute ram_style of rram : signal is "block";
begin
  process(aclk)
  begin
    if rising_edge(aclk) then
      rst_s1 <= arst;
      rst_s2 <= rst_s1;
      rak_s1 <= ack_tgl;
      rak_s2 <= rak_s1;
    end if;
  end process;

  rx : entity work.jc_ctl_frame_core
    port map(tck => tck, sel => sel, capture => capture, shift => shift, tdi => tdi,
             tdo => tdo, w_valid => w_valid, w_data => w_data, w_ready => w_ready,
             st_in => st_tck, rsp_addr => rsp_addr, rsp_q => rsp_q,
             rsp_ack_tgl => ack_tgl, desync_cnt => open, crcf_cnt => open,
             ovf_seen => open);

  fifo : entity work.async_fifo
    generic map(W => JC_FIFO_W, DEPTH => 128)
    port map(wclk => tck, wrst => '0', w_valid => w_valid, w_data => w_data,
             w_ready => w_ready, w_level => open, clr => '0', clr_done => open,
             rclk => aclk, rrst => '0', q_valid => q_valid, q_data => q_data,
             q_ready => q_ready);

  -- while in reset the executor neither sees nor pops a FIFO word (reset contract)
  q_vx    <= q_valid and not rst_s2;
  q_ready <= q_rx and not rst_s2;

  ex : entity work.jc_ctl_exec
    generic map(ADDR_W => 33, TMO_CYC => TMO_CYC)
    port map(clk => aclk, rst => rst_s2,
             q_valid => q_vx, q_data => q_data, q_ready => q_rx,
             rsp_ack_tgl => rak_s2,
             m_axil_awaddr => m_axil_awaddr, m_axil_awprot => m_axil_awprot,
             m_axil_awvalid => m_axil_awvalid, m_axil_awready => m_axil_awready,
             m_axil_wdata => m_axil_wdata, m_axil_wstrb => m_axil_wstrb,
             m_axil_wvalid => m_axil_wvalid, m_axil_wready => m_axil_wready,
             m_axil_bresp => m_axil_bresp, m_axil_bvalid => m_axil_bvalid,
             m_axil_bready => m_axil_bready,
             m_axil_araddr => m_axil_araddr, m_axil_arprot => m_axil_arprot,
             m_axil_arvalid => m_axil_arvalid, m_axil_arready => m_axil_arready,
             m_axil_rdata => m_axil_rdata, m_axil_rresp => m_axil_rresp,
             m_axil_rvalid => m_axil_rvalid, m_axil_rready => m_axil_rready,
             m_axi_araddr => m_axi_araddr, m_axi_arlen => m_axi_arlen,
             m_axi_arsize => m_axi_arsize, m_axi_arburst => m_axi_arburst,
             m_axi_arvalid => m_axi_arvalid, m_axi_arready => m_axi_arready,
             m_axi_rdata => m_axi_rdata, m_axi_rresp => m_axi_rresp,
             m_axi_rlast => m_axi_rlast, m_axi_rvalid => m_axi_rvalid,
             m_axi_rready => m_axi_rready,
             rsp_we => rsp_we, rsp_waddr => rsp_waddr, rsp_wdata => rsp_wdata,
             st_out => st_live, busy => open);

  sync : entity work.jc_status_sync
    generic map(W => JC_CTL_STATUS_BITS)
    port map(aclk => aclk, live => st_live, tck => tck, st_tck => st_tck);

  -- response RAM: simple dual port, independent clocks (one RAMB18E2)
  rram_w : process(aclk)
  begin
    if rising_edge(aclk) then
      if rsp_we = '1' then
        rram(to_integer(unsigned(rsp_waddr))) <= rsp_wdata;
      end if;
    end if;
  end process;

  rram_r : process(tck)
  begin
    if rising_edge(tck) then
      rsp_q <= rram(to_integer(unsigned(rsp_addr)));
    end if;
  end process;
end architecture;
