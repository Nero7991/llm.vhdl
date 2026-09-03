-- rtl/gdn_state_store.vhd -- one GDN layer resident, backed by HBM.
--
-- Composes `gdn_state_mem` (the resident layer, 32 URAM288 at the 9B shape)
-- with `gdn_state_axi` (the per-job mover, 269 LUT / 703 FF / 1 DSP) and the
-- arbiter between them, so that whoever drives `gdn_block` instantiates ONE
-- thing and never sees the split.
--
-- WHY THE ARBITER LIVES HERE AND NOT IN THE CALLER.  It is a 2:1 mux with no
-- arithmetic in it, and that is a deliberate property: the DMA emits
-- `(head, col, grp)` rather than a flat index precisely so that all three
-- modules speak one shape and the mux cannot get the decomposition wrong.
-- An earlier draft of the DMA emitted a flat index; the arithmetic then had
-- to live in the mux, which is the one place nothing tests, and the bench
-- that caught it read back all zeros.  See
-- docs/debugging/2026-09-02_gdn-state-dma.md, defect D1.
--
-- THE OWNERSHIP RULE IS `busy`, AND IT IS NOT A SUGGESTION.  While the mover
-- is running it owns the store outright and `gdn_block`'s port is ignored.
-- The caller must not start the unit until `busy` is low; the sim-only
-- assertion below says so rather than trusting it.  A unit reading its state
-- mid-load reads a mixture of this layer and the previous one -- a wrong
-- number, not a hang.
--
-- WHAT THIS DOES NOT COVER, stated because the arena reserves it and a reader
-- would reasonably assume otherwise:
--   * the per-layer state EXPONENTS (`semem` in llama_top, 4,096 B per layer,
--     reserved in the manifest as `gdn_state_exp_bytes_per_layer`);
--   * the conv tap history (49,152 B per layer, with NO arena reservation).
-- Neither is moved.  There is no port here that pretends to.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gdn_state_store is
  generic(
    VAL_HEADS   : positive := 32;
    DIM         : positive := 128;
    RECUR_LANES : positive := 4;
    LAYERS      : positive := 24;
    STYLE       : string   := "ultra";   -- see gdn_state_mem: NOT "auto"

    LAYER_STRIDE : positive := 1052672;
    MANT_BYTES   : positive := 1048576;

    AXI_DW : positive := 256;
    ADDR_W : positive := 33;
    MAXB   : positive := 16;
    MAXOUT : positive := 4
  );
  port(
    clk : in std_logic;
    rst : in std_logic;

    -- ---- the mover's job control ----------------------------------------
    load_start : in  std_logic;
    save_start : in  std_logic;
    layer      : in  integer range 0 to LAYERS-1;
    state_base : in  std_logic_vector(ADDR_W-1 downto 0);
    busy       : out std_logic;
    done       : out std_logic;
    err        : out std_logic;

    -- ---- gdn_block's st_* ports, verbatim --------------------------------
    -- Honoured only while `busy` is low.  Shapes match rtl/gdn_block.vhd.
    st_ren   : in  std_logic;
    st_rhead : in  natural range 0 to VAL_HEADS-1;
    st_rcol  : in  natural range 0 to DIM-1;
    st_rgrp  : in  natural range 0 to DIM/RECUR_LANES-1;
    st_rdata : out std_logic_vector(RECUR_LANES*16-1 downto 0);
    st_wen   : in  std_logic;
    st_whead : in  natural range 0 to VAL_HEADS-1;
    st_wcol  : in  natural range 0 to DIM-1;
    st_wgrp  : in  natural range 0 to DIM/RECUR_LANES-1;
    st_wdata : in  std_logic_vector(RECUR_LANES*16-1 downto 0);

    -- ---- the AXI masters -------------------------------------------------
    r_arvalid : out std_logic;
    r_arready : in  std_logic;
    r_araddr  : out std_logic_vector(ADDR_W-1 downto 0);
    r_arlen   : out std_logic_vector(7 downto 0);
    r_arsize  : out std_logic_vector(2 downto 0);
    r_arburst : out std_logic_vector(1 downto 0);
    r_rvalid  : in  std_logic;
    r_rready  : out std_logic;
    r_rdata   : in  std_logic_vector(AXI_DW-1 downto 0);
    r_rlast   : in  std_logic;
    r_rresp   : in  std_logic_vector(1 downto 0);

    w_awvalid : out std_logic;
    w_awready : in  std_logic;
    w_awaddr  : out std_logic_vector(ADDR_W-1 downto 0);
    w_awlen   : out std_logic_vector(7 downto 0);
    w_awsize  : out std_logic_vector(2 downto 0);
    w_awburst : out std_logic_vector(1 downto 0);
    w_wvalid  : out std_logic;
    w_wready  : in  std_logic;
    w_wdata   : out std_logic_vector(AXI_DW-1 downto 0);
    w_wstrb   : out std_logic_vector(AXI_DW/8-1 downto 0);
    w_wlast   : out std_logic;
    w_bvalid  : in  std_logic;
    w_bready  : out std_logic;
    w_bresp   : in  std_logic_vector(1 downto 0)
  );
end entity;

architecture rtl of gdn_state_store is
  constant NBR   : positive := DIM / RECUR_LANES;
  constant WBITS : positive := RECUR_LANES * 16;

  signal bsy : std_logic;

  signal d_we, d_re : std_logic;
  signal d_wh, d_rh : natural range 0 to VAL_HEADS-1;
  signal d_wc, d_rc : natural range 0 to DIM-1;
  signal d_wg, d_rg : natural range 0 to NBR-1;
  signal d_wd       : std_logic_vector(WBITS-1 downto 0);

  signal m_we, m_re : std_logic;
  signal m_wh, m_rh : natural range 0 to VAL_HEADS-1;
  signal m_wc, m_rc : natural range 0 to DIM-1;
  signal m_wg, m_rg : natural range 0 to NBR-1;
  signal m_wd, m_rd : std_logic_vector(WBITS-1 downto 0);
begin
  busy <= bsy;

  -- THE 2:1, AND NOTHING ELSE.  No arithmetic: see the header.
  m_we <= d_we when bsy = '1' else st_wen;
  m_wh <= d_wh when bsy = '1' else st_whead;
  m_wc <= d_wc when bsy = '1' else st_wcol;
  m_wg <= d_wg when bsy = '1' else st_wgrp;
  m_wd <= d_wd when bsy = '1' else st_wdata;
  m_re <= d_re when bsy = '1' else st_ren;
  m_rh <= d_rh when bsy = '1' else st_rhead;
  m_rc <= d_rc when bsy = '1' else st_rcol;
  m_rg <= d_rg when bsy = '1' else st_rgrp;

  -- The unit's read port is the store's, unconditionally.  It is only
  -- MEANINGFUL when the unit owns the store, and the assertion below is what
  -- says so; gating the data would hide the violation rather than report it.
  st_rdata <= m_rd;

  u_mem : entity work.gdn_state_mem
    generic map(VAL_HEADS => VAL_HEADS, DIM => DIM,
                RECUR_LANES => RECUR_LANES, STYLE => STYLE)
    port map(clk => clk,
             r_en => m_re, r_head => m_rh, r_col => m_rc, r_grp => m_rg,
             r_data => m_rd,
             w_en => m_we, w_head => m_wh, w_col => m_wc, w_grp => m_wg,
             w_data => m_wd);

  u_dma : entity work.gdn_state_axi
    generic map(VAL_HEADS => VAL_HEADS, DIM => DIM,
                RECUR_LANES => RECUR_LANES, LAYERS => LAYERS,
                LAYER_STRIDE => LAYER_STRIDE, MANT_BYTES => MANT_BYTES,
                AXI_DW => AXI_DW, ADDR_W => ADDR_W,
                MAXB => MAXB, MAXOUT => MAXOUT)
    port map(clk => clk, rst => rst,
             load_start => load_start, save_start => save_start,
             layer => layer, state_base => state_base,
             busy => bsy, done => done, err => err,
             m_w_en => d_we, m_w_head => d_wh, m_w_col => d_wc,
             m_w_grp => d_wg, m_w_data => d_wd,
             m_r_en => d_re, m_r_head => d_rh, m_r_col => d_rc,
             m_r_grp => d_rg, m_r_data => m_rd,
             r_arvalid => r_arvalid, r_arready => r_arready,
             r_araddr => r_araddr, r_arlen => r_arlen, r_arsize => r_arsize,
             r_arburst => r_arburst, r_rvalid => r_rvalid,
             r_rready => r_rready, r_rdata => r_rdata, r_rlast => r_rlast,
             r_rresp => r_rresp,
             w_awvalid => w_awvalid, w_awready => w_awready,
             w_awaddr => w_awaddr, w_awlen => w_awlen, w_awsize => w_awsize,
             w_awburst => w_awburst, w_wvalid => w_wvalid,
             w_wready => w_wready, w_wdata => w_wdata, w_wstrb => w_wstrb,
             w_wlast => w_wlast, w_bvalid => w_bvalid, w_bready => w_bready,
             w_bresp => w_bresp);

  -- SIMULATION ONLY.  A VHDL severity is a width in synthesis and not a
  -- check, so this catches the caller in a bench and not on the card.  It is
  -- still the right place for it: the violation is silent otherwise, and it
  -- produces a wrong number rather than a hang.
  -- synthesis translate_off
  guard : process(clk) is
  begin
    if rising_edge(clk) then
      if bsy = '1' and (st_ren = '1' or st_wen = '1') then
        report "gdn_state_store: gdn_block accessed the recurrent state while "
             & "the HBM mover owned it.  A read here returns a mixture of "
             & "this layer and the previous one, and a write is lost.  Wait "
             & "for `busy` to fall before starting the unit."
          severity failure;
      end if;
    end if;
  end process;
  -- synthesis translate_on
end architecture;
