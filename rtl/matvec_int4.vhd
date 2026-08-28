-- rtl/matvec_int4.vhd -- subsystem A top level.
--
-- Spec: docs/superpowers/specs/2026-08-20-int4-streaming-matvec-design.md 7.1
--
--   matvec_int4
--   |- weight_streamer   (NPORTS_W+NPORTS_S AXI4 masters -> in-order streams)
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
    -- Scale sub-regions, spec 6.5a: lcm(ROWS_IF*16, AXI_DW) / AXI_DW.  1 on
    -- the AXU3EG, 3 at the FK33's ROWS_IF=48 / AXI_DW=256.  DEFAULT 1, and the
    -- default is load bearing: at NPORTS_S = 1 every port width below is the
    -- expression it already was (NPORTS_W+1, (NPORTS_W+1)*X), so no existing
    -- instantiation moves and none needed editing.  weight_streamer asserts
    -- that the value is 6.5a's MINIMAL one; this level only carries it.
    NPORTS_S    : positive := 1;
    AXI_DW      : positive := 128;
    ADDR_W      : positive := 32;
    MAXCOLS     : positive := 17408;
    MAXROWS_BFP : positive := 17408;
    FIFO_DEPTH  : positive := 512;
    MAXB        : positive := 256;
    MAXOUT      : positive := 2
  );
  port(
    clk, rst : in  std_logic;

    -- descriptor, from the PS after it has read the header
    -- All scalars are std_logic_vector, NOT integer.  Vivado converts integer
    -- ports to vectors when it writes a netlist, so an integer here would make
    -- the post-synthesis funcsim testbench unable to port-map the very thing it
    -- is meant to check.  An AXI-Lite wrapper wants vectors regardless.
    start     : in  std_logic;
    n_rows    : in  std_logic_vector(31 downto 0);
    n_cols    : in  std_logic_vector(31 downto 0);
    out_shift : in  std_logic_vector(31 downto 0);
    w_exp     : in  std_logic_vector(31 downto 0);
    x_exp     : in  std_logic_vector(31 downto 0);
    out_mode  : in  std_logic_vector(1 downto 0);
    w_base    : in  std_logic_vector(NPORTS_W*ADDR_W-1 downto 0);
    w_beats   : in  std_logic_vector(31 downto 0);
    -- NPORTS_S scale sub-region bases, s_sub_offset[] of the header (6.4).
    s_base    : in  std_logic_vector(NPORTS_S*ADDR_W-1 downto 0);
    s_beats   : in  std_logic_vector(31 downto 0);

    cb_we     : in  std_logic;
    cb_addr   : in  std_logic_vector(3 downto 0);
    cb_data   : in  std_logic_vector(7 downto 0);

    -- activation producer side (rmsnorm, swiglu, ...): one element per cycle
    x_we      : in  std_logic;
    x_waddr   : in  std_logic_vector(15 downto 0);
    x_wdata   : in  std_logic_vector(15 downto 0);

    -- AXI4 read masters, flattened; indices NPORTS_W .. NPORTS_W+NPORTS_S-1
    -- are the scale ports.  At NPORTS_S = 1 every range below is the one that
    -- was written here as NPORTS_W downto 0.
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

    -- result
    y_we      : out std_logic;
    y_addr    : out std_logic_vector(15 downto 0);
    y_data    : out std_logic_vector(ROWS_IF*64-1 downto 0);
    y_mask    : out std_logic_vector(ROWS_IF-1 downto 0);
    y_exp     : out std_logic_vector(31 downto 0);
    done      : out std_logic;
    err       : out std_logic;
    sat_event : out std_logic;

    -- performance taps for the AXI wrapper's counters.  11 requires sustained
    -- bandwidth reported as a percentage of DDR peak, which needs the beats
    -- actually consumed and the cycles the array spent starved, not just a
    -- wall-clock time.
    dbg_wbeat   : out std_logic;   -- a weight word was accepted this cycle
    dbg_wstarve : out std_logic    -- no weight word was available this cycle
  );
end entity;

architecture rtl of matvec_int4 is
  -- The submodules keep integer scalars; conversion happens once, here.
  -- INITIALISED: an integer signal with no initial value starts at INTEGER'LOW,
  -- so before the first delta the core would see -2^31 on both exponents and
  -- w_exp + x_exp overflows.  Simulation-only in effect, but it aborts the run.
  signal i_rows, i_cols, i_osh, i_wexp, i_xexp : integer := 0;
  signal i_wbeats, i_sbeats, i_yexp            : integer := 0;

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
    generic map(NPORTS_W => NPORTS_W, NPORTS_S => NPORTS_S,
                AXI_DW => AXI_DW, ADDR_W => ADDR_W,
                ROWS_IF => ROWS_IF, BLK => BLK, DEPTH => FIFO_DEPTH,
                MAXB => MAXB, MAXOUT => MAXOUT)
    port map(clk => clk, rst => rst, start => start,
             w_base => w_base, w_beats => i_wbeats,
             s_base => s_base, s_beats => i_sbeats,
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
             n_rows => i_rows, n_cols => i_cols, out_shift => i_osh,
             w_exp => i_wexp, x_exp => i_xexp, out_mode => out_mode,
             cb_we => cb_we, cb_addr => cb_addr, cb_data => cb_data,
             w_valid => wv, w_data => wd, w_ready => wr,
             s_valid => sv, s_data => sd, s_ready => sr,
             x_rbaddr => x_rbaddr, x_rdata => x_rdata,
             y_we => y_we, y_addr => y_addr, y_data => y_data,
             y_mask => y_mask, y_exp => i_yexp,
             done => done, err => err, sat_event => sat_event,
             tp_v => o_tp_v, tc_v => o_tc_v, ta_v => o_ta_v, tm_v => o_tm_v,
             tp_r => o_tp_r, tc_r => o_tc_r, ta_r => o_ta_r, tm_r => o_tm_r,
             tp_b => o_tp_b, tc_b => o_tc_b,
             tp_val => o_tp, tc_val => o_tc, ta_val => o_ta, tm_val => o_tm,
             tap_ns => o_ns);

  dbg_wbeat   <= wv and wr;
  dbg_wstarve <= not wv;

  i_rows   <= to_integer(signed(n_rows));
  i_cols   <= to_integer(signed(n_cols));
  i_osh    <= to_integer(signed(out_shift));
  i_wexp   <= to_integer(signed(w_exp));
  i_xexp   <= to_integer(signed(x_exp));
  i_wbeats <= to_integer(signed(w_beats));
  i_sbeats <= to_integer(signed(s_beats));
  y_exp    <= std_logic_vector(to_signed(i_yexp, 32));

  xw_addr  <= x_waddr(XA-1 downto 0);
  xr_baddr <= x_rbaddr(XB-1 downto 0);
end architecture;
