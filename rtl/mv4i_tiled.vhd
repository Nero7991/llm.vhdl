-- rtl/mv4i_tiled.vhd -- subsystem A at 450 MHz: per-port tiles in their own clock domain.
-- Spec: docs/superpowers/specs/2026-11-12-a450-per-port-tiles-design.md.
--
-- A drop-in for rtl/matvec_int4.vhd: the same ports (its three per-word dbg_* taps are
-- replaced by dbg_rtile/dbg_words) and the same y/err/sat/done contract, bit for bit, so
-- rtl/matvec_int4_desc_axi.vhd chooses it with A_TILED and nothing above that changes.
--
-- A_CLK_SPLIT selects the fast domain:
--   false  aclk_a IS clk.  The crossings (mv_tsync, mv_rcross, act_mem_dp) are still
--          there and are crossed between equal clocks, exactly as the JC card already
--          crosses axi_rd_port's async FIFO today.  The m_* AXI masters are on clk.
--   true   aclk_a is the `aclk` port (450 MHz).  The m_* AXI masters are on aclk.
-- The choice is a generate around ONE entity, never a clock assigned through a signal:
-- an assigned clock is a delta late in simulation and the paths between the two would
-- race (rtl/axi_rd_fsm.vhd's header records that trap).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity mv4i_tiled is
  generic(
    BLK         : positive := 32;
    ROWS_IF     : positive := 48;
    NPORTS_W    : positive := 24;
    NPORTS_S    : positive := 3;
    AXI_DW      : positive := 256;
    ADDR_W      : positive := 40;
    MAXCOLS     : positive := 17408;
    MAXROWS_BFP : positive := 17408;
    FIFO_DEPTH  : positive := 512;
    MAXB        : positive := 16;
    MAXOUT      : positive := 16;
    A_CLK_SPLIT : boolean  := false;
    XD          : positive := 32;
    G           : positive := 6
  );
  port(
    clk, rst  : in  std_logic;
    aclk      : in  std_logic := '0';
    start     : in  std_logic;
    n_rows    : in  std_logic_vector(31 downto 0);
    n_cols    : in  std_logic_vector(31 downto 0);
    out_shift : in  std_logic_vector(31 downto 0);
    w_exp     : in  std_logic_vector(31 downto 0);
    x_exp     : in  std_logic_vector(31 downto 0);
    out_mode  : in  std_logic_vector(1 downto 0);
    w_base    : in  std_logic_vector(NPORTS_W*ADDR_W-1 downto 0);
    w_beats   : in  std_logic_vector(31 downto 0);
    s_base    : in  std_logic_vector(NPORTS_S*ADDR_W-1 downto 0);
    s_beats   : in  std_logic_vector(31 downto 0);
    cb_we     : in  std_logic;
    cb_addr   : in  std_logic_vector(3 downto 0);
    cb_data   : in  std_logic_vector(7 downto 0);
    x_we      : in  std_logic;
    x_waddr   : in  std_logic_vector(15 downto 0);
    x_wdata   : in  std_logic_vector(15 downto 0);
    m_arvalid : out std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
    m_arready : in  std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
    m_araddr  : out std_logic_vector((NPORTS_W+NPORTS_S)*ADDR_W-1 downto 0);
    m_arlen   : out std_logic_vector((NPORTS_W+NPORTS_S)*8-1 downto 0);
    m_arsize  : out std_logic_vector((NPORTS_W+NPORTS_S)*3-1 downto 0);
    m_arburst : out std_logic_vector((NPORTS_W+NPORTS_S)*2-1 downto 0);
    m_rvalid  : in  std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
    m_rready  : out std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
    m_rdata   : in  std_logic_vector((NPORTS_W+NPORTS_S)*AXI_DW-1 downto 0);
    m_rlast   : in  std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
    y_we      : out std_logic;
    y_addr    : out std_logic_vector(15 downto 0);
    y_data    : out std_logic_vector(ROWS_IF*64-1 downto 0);
    y_mask    : out std_logic_vector(ROWS_IF-1 downto 0);
    y_exp     : out std_logic_vector(31 downto 0);
    done      : out std_logic;
    err       : out std_logic;
    sat_event : out std_logic;
    -- a pulse per row-tile result taken by the back end, and the weight words (nb) it
    -- stands for: what matvec_int4_desc_axi's BEATS register counts in place of
    -- matvec_int4's per-word dbg_wbeat
    dbg_rtile : out std_logic;
    dbg_words : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of mv4i_tiled is
begin
  g_split : if A_CLK_SPLIT generate
    u : entity work.mv4i_tcore
      generic map(BLK => BLK, ROWS_IF => ROWS_IF, NPORTS_W => NPORTS_W, NPORTS_S => NPORTS_S,
                  AXI_DW => AXI_DW, ADDR_W => ADDR_W, MAXCOLS => MAXCOLS,
                  MAXROWS_BFP => MAXROWS_BFP, FIFO_DEPTH => FIFO_DEPTH, MAXB => MAXB,
                  MAXOUT => MAXOUT, XD => XD, G => G)
      port map(clk => clk, rst => rst, aclk_a => aclk, start => start,
               n_rows => n_rows, n_cols => n_cols, out_shift => out_shift, w_exp => w_exp,
               x_exp => x_exp, out_mode => out_mode, w_base => w_base, w_beats => w_beats,
               s_base => s_base, s_beats => s_beats, cb_we => cb_we, cb_addr => cb_addr,
               cb_data => cb_data, x_we => x_we, x_waddr => x_waddr, x_wdata => x_wdata,
               m_arvalid => m_arvalid, m_arready => m_arready, m_araddr => m_araddr,
               m_arlen => m_arlen, m_arsize => m_arsize, m_arburst => m_arburst,
               m_rvalid => m_rvalid, m_rready => m_rready, m_rdata => m_rdata,
               m_rlast => m_rlast, y_we => y_we, y_addr => y_addr, y_data => y_data,
               y_mask => y_mask, y_exp => y_exp, done => done, err => err,
               sat_event => sat_event, dbg_rtile => dbg_rtile, dbg_words => dbg_words);
  end generate;
  g_same : if not A_CLK_SPLIT generate
    u : entity work.mv4i_tcore
      generic map(BLK => BLK, ROWS_IF => ROWS_IF, NPORTS_W => NPORTS_W, NPORTS_S => NPORTS_S,
                  AXI_DW => AXI_DW, ADDR_W => ADDR_W, MAXCOLS => MAXCOLS,
                  MAXROWS_BFP => MAXROWS_BFP, FIFO_DEPTH => FIFO_DEPTH, MAXB => MAXB,
                  MAXOUT => MAXOUT, XD => XD, G => G)
      port map(clk => clk, rst => rst, aclk_a => clk, start => start,
               n_rows => n_rows, n_cols => n_cols, out_shift => out_shift, w_exp => w_exp,
               x_exp => x_exp, out_mode => out_mode, w_base => w_base, w_beats => w_beats,
               s_base => s_base, s_beats => s_beats, cb_we => cb_we, cb_addr => cb_addr,
               cb_data => cb_data, x_we => x_we, x_waddr => x_waddr, x_wdata => x_wdata,
               m_arvalid => m_arvalid, m_arready => m_arready, m_araddr => m_araddr,
               m_arlen => m_arlen, m_arsize => m_arsize, m_arburst => m_arburst,
               m_rvalid => m_rvalid, m_rready => m_rready, m_rdata => m_rdata,
               m_rlast => m_rlast, y_we => y_we, y_addr => y_addr, y_data => y_data,
               y_mask => y_mask, y_exp => y_exp, done => done, err => err,
               sat_event => sat_event, dbg_rtile => dbg_rtile, dbg_words => dbg_words);
  end generate;
end architecture;
