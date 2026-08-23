-- rtl/matvec_int4.vhd -- subsystem A top level.
--
-- Spec: docs/superpowers/specs/2026-08-20-int4-streaming-matvec-design.md 7.1
--
--   matvec_int4
--   |- weight_streamer   (NPORTS_W+1 AXI4 masters -> in-order streams)
--   |- act_mem_striped   (one BLK of activations per cycle, 7.8)
--   `- matvec_core       (MAC array, tree, scale, accumulate, requant, 7.4)
--
-- The split is what lets matvec_core be exercised from file-fed streams with no
-- AXI model at all (sim/tb_matvec_core), and it is also what makes the core
-- portable: weight_streamer is DDR4 here and HBM on the FK33, matvec_core is
-- neither.
--
-- The DESCRIPTOR is driven by the PS, which parses the 4 KB header (6.4) and
-- programs n_rows / n_cols / w_exp / out_shift / the sub-region bases / the
-- codebook.  Nothing in the fabric parses the header: it is read once per
-- matrix, on a control path with no throughput requirement, and putting a
-- byte-field parser in RTL would buy nothing and add a second place for the
-- byte-pinned layout to drift.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity matvec_int4 is
  generic(
    BLK         : positive := 32;
    ROWS_IF     : positive := 4;      -- 14.4 pins 4 on the AXU3EG
    NPORTS_W    : positive := 4;
    AXI_DW      : positive := 128;
    ADDR_W      : positive := 32;
    MAXCOLS     : positive := 17408;
    MAXROWS_BFP : positive := 17408;
    FIFO_DEPTH  : positive := 512;
    MAXB        : positive := 256
  );
  port(
    clk, rst : in  std_logic;

    -- descriptor, from the PS after it has read the header
    start     : in  std_logic;
    n_rows    : in  integer;
    n_cols    : in  integer;
    out_shift : in  integer;
    w_exp     : in  integer;
    x_exp     : in  integer;
    out_mode  : in  std_logic_vector(1 downto 0);
    w_base    : in  std_logic_vector(NPORTS_W*ADDR_W-1 downto 0);
    w_beats   : in  integer;
    s_base    : in  std_logic_vector(ADDR_W-1 downto 0);
    s_beats   : in  integer;

    cb_we     : in  std_logic;
    cb_addr   : in  std_logic_vector(3 downto 0);
    cb_data   : in  std_logic_vector(7 downto 0);

    -- activation producer side (rmsnorm, swiglu, ...): one element per cycle
    x_we      : in  std_logic;
    x_waddr   : in  std_logic_vector(15 downto 0);
    x_wdata   : in  std_logic_vector(15 downto 0);

    -- AXI4 read masters, flattened; index NPORTS_W is the scale port
    m_arvalid : out std_logic_vector(NPORTS_W downto 0);
    m_arready : in  std_logic_vector(NPORTS_W downto 0);
    m_araddr  : out std_logic_vector((NPORTS_W+1)*ADDR_W-1 downto 0);
    m_arlen   : out std_logic_vector((NPORTS_W+1)*8-1 downto 0);
    m_arsize  : out std_logic_vector((NPORTS_W+1)*3-1 downto 0);
    m_arburst : out std_logic_vector((NPORTS_W+1)*2-1 downto 0);
    m_rvalid  : in  std_logic_vector(NPORTS_W downto 0);
    m_rready  : out std_logic_vector(NPORTS_W downto 0);
    m_rdata   : in  std_logic_vector((NPORTS_W+1)*AXI_DW-1 downto 0);
    m_rlast   : in  std_logic_vector(NPORTS_W downto 0);

    -- result
    y_we      : out std_logic;
    y_addr    : out std_logic_vector(15 downto 0);
    y_data    : out std_logic_vector(ROWS_IF*64-1 downto 0);
    y_mask    : out std_logic_vector(ROWS_IF-1 downto 0);
    y_exp     : out integer;
    done      : out std_logic;
    err       : out std_logic;
    sat_event : out std_logic
  );
end entity;

architecture rtl of matvec_int4 is
  signal wv, wr, sv, sr : std_logic;
  signal wd : std_logic_vector(ROWS_IF*BLK*4-1 downto 0);
  signal sd : std_logic_vector(ROWS_IF*16-1 downto 0);

  signal x_rbaddr : std_logic_vector(15 downto 0);
  signal x_rdata  : std_logic_vector(BLK*16-1 downto 0);

  -- act_mem_striped sizes its own address ports from ELEMS; the interface here
  -- is a flat 16 bits, so the widths are narrowed explicitly rather than left
  -- to positional luck.
  constant XA : positive := clog2(MAXCOLS);
  constant XB : positive := clog2((MAXCOLS + BLK - 1) / BLK);
  signal xw_addr  : std_logic_vector(XA-1 downto 0);
  signal xr_baddr : std_logic_vector(XB-1 downto 0);

  -- taps are left open: they exist for sim/tb_matvec_core and synthesis prunes
  -- them, but naming them here keeps the port map explicit rather than relying
  -- on positional association
  signal o_tp_v, o_tc_v, o_ta_v, o_tm_v : std_logic;
  signal o_tp_r, o_tc_r, o_ta_r, o_tm_r : integer;
  signal o_tp_b, o_tc_b, o_ns : integer;
  signal o_tp, o_tc, o_ta, o_tm : std_logic_vector(ROWS_IF*64-1 downto 0);
begin

  streamer : entity work.weight_streamer
    generic map(NPORTS_W => NPORTS_W, AXI_DW => AXI_DW, ADDR_W => ADDR_W,
                ROWS_IF => ROWS_IF, BLK => BLK, DEPTH => FIFO_DEPTH,
                MAXB => MAXB)
    port map(clk => clk, rst => rst, start => start,
             w_base => w_base, w_beats => w_beats,
             s_base => s_base, s_beats => s_beats,
             m_arvalid => m_arvalid, m_arready => m_arready,
             m_araddr => m_araddr, m_arlen => m_arlen,
             m_arsize => m_arsize, m_arburst => m_arburst,
             m_rvalid => m_rvalid, m_rready => m_rready,
             m_rdata => m_rdata, m_rlast => m_rlast,
             w_valid => wv, w_data => wd, w_ready => wr,
             s_valid => sv, s_data => sd, s_ready => sr);

  actmem : entity work.act_mem_striped
    generic map(ELEMS => MAXCOLS, BLK => BLK, LANES => 4, W => 16)
    port map(clk => clk, we => x_we,
             waddr => xw_addr, wdata => x_wdata,
             rbaddr => xr_baddr, rdata => x_rdata);

  core : entity work.matvec_core
    generic map(BLK => BLK, ROWS_IF => ROWS_IF, MAXCOLS => MAXCOLS,
                MAXROWS_BFP => MAXROWS_BFP)
    port map(clk => clk, rst => rst, start => start,
             n_rows => n_rows, n_cols => n_cols, out_shift => out_shift,
             w_exp => w_exp, x_exp => x_exp, out_mode => out_mode,
             cb_we => cb_we, cb_addr => cb_addr, cb_data => cb_data,
             w_valid => wv, w_data => wd, w_ready => wr,
             s_valid => sv, s_data => sd, s_ready => sr,
             x_rbaddr => x_rbaddr, x_rdata => x_rdata,
             y_we => y_we, y_addr => y_addr, y_data => y_data,
             y_mask => y_mask, y_exp => y_exp,
             done => done, err => err, sat_event => sat_event,
             tp_v => o_tp_v, tc_v => o_tc_v, ta_v => o_ta_v, tm_v => o_tm_v,
             tp_r => o_tp_r, tc_r => o_tc_r, ta_r => o_ta_r, tm_r => o_tm_r,
             tp_b => o_tp_b, tc_b => o_tc_b,
             tp_val => o_tp, tc_val => o_tc, ta_val => o_ta, tm_val => o_tm,
             tap_ns => o_ns);

  xw_addr  <= x_waddr(XA-1 downto 0);
  xr_baddr <= x_rbaddr(XB-1 downto 0);
end architecture;
