-- rtl/gdn_state_store.vhd -- one GDN layer resident, backed by HBM.
--
-- Composes the resident layer -- `gdn_state_mem` (mantissas, 32 URAM288 at the
-- 9B shape) and `gdn_exp_mem` (exponents, distributed RAM) -- with TWO
-- instances of the one mover `gdn_state_axi`, a sequencer that runs them in
-- turn, and the arbiters between them, so that whoever drives `gdn_block`
-- instantiates ONE thing and never sees the split.
--
-- WHY TWO MOVER INSTANCES AND ONE PAIR OF AXI MASTERS.  HBM master count is a
-- real constraint on this card, and the exponents are 4,096 bytes per layer
-- against the mantissas' 1,048,576 -- 0.39% of the traffic.  Spending a second
-- read and write master on that is the wrong trade when a mux costs a few
-- LUTs.  `gdn_state_axi` already carries `WORD_BITS` and `N_GRP` generics for
-- exactly this: at `WORD_BITS => 8, N_GRP => 1` it moves `VAL_HEADS x DIM`
-- bytes and derives its own beat and burst counts, and its
-- `bad_mant_bytes_vs_shape` refusal then checks that figure against the
-- manifest's `gdn_state_exp_bytes_per_layer`.
--
-- THE PHASES ARE SEQUENTIAL, NOT CONCURRENT, and that is the whole reason the
-- mux is safe.  `sel_e` is set by the sequencer and held for a whole phase;
-- the idle mover is in its own S_IDLE, drives no valid, and has its ready and
-- valid inputs forced low so it cannot see a handshake meant for the other.
-- Two movers sharing one master with no arbitration would interleave bursts
-- from different transfers onto one ID, and AXI3 permits a slave to return
-- those out of order.
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
-- THE OWNERSHIP RULE IS `busy`, AND IT IS NOT A SUGGESTION.  While either
-- mover is running it owns BOTH stores outright and `gdn_block`'s ports are
-- ignored.  The caller must not start the unit until `busy` is low; the
-- sim-only assertion below says so rather than trusting it.  A unit reading
-- its state mid-load reads a mixture of this layer and the previous one -- a
-- wrong number, not a hang.
--
-- WHAT THIS STILL DOES NOT COVER, stated because a reader would reasonably
-- assume otherwise: the CONV TAP HISTORY.  `(conv_kernel-1) x qkv_dim` 16-bit
-- elements = 49,152 bytes per layer at the 9B shape.  As of 2026-09-02 it IS
-- reserved -- `tools/hbm_map.py::arena_sizes()` derives
-- `gdn_state_conv_bytes_per_layer` and it is inside `LAYER_STRIDE`, sitting
-- immediately after the exponents -- but NOTHING MOVES IT.  A third phase here
-- would be a third `gdn_state_axi` at `WORD_BITS => 16, N_GRP => 1` and a
-- fourth sequencer state.  There is no port here that pretends to move it, and
-- until there is, the second token of any sequence convolves against zeros.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gdn_state_store is
  generic(
    VAL_HEADS   : positive := 32;
    DIM         : positive := 128;
    RECUR_LANES : positive := 4;
    LAYERS      : positive := 24;
    STYLE       : string   := "ultra";        -- gdn_state_mem: NOT "auto"
    EXP_STYLE   : string   := "distributed";  -- gdn_exp_mem: NOT block/ultra

    LAYER_STRIDE : positive := 1101824;   -- gdn_state_bytes_per_layer
    MANT_BYTES   : positive := 1048576;   -- gdn_state_mant_bytes_per_layer
    EXP_BYTES    : positive := 4096;      -- gdn_state_exp_bytes_per_layer

    AXI_DW : positive := 256;
    ADDR_W : positive := 33;
    MAXB   : positive := 16;
    MAXOUT : positive := 4
  );
  port(
    clk : in std_logic;
    rst : in std_logic;

    -- ---- the mover's job control ----------------------------------------
    -- ONE start covers BOTH phases.  `done` pulses once, after the exponents.
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

    -- ---- gdn_block's se_* ports, verbatim (rtl/gdn_block.vhd:318-324) ----
    -- `se_rdata` is COMBINATIONAL from `se_rhead`/`se_rcol`.  It has to be:
    -- gdn_block drives the address from the recurrence pipeline (:632-633)
    -- and consumes the byte on the same edge (:1203).
    se_rhead : in  natural range 0 to VAL_HEADS-1;
    se_rcol  : in  natural range 0 to DIM-1;
    se_rdata : out signed(7 downto 0);
    se_wen   : in  std_logic;
    se_whead : in  natural range 0 to VAL_HEADS-1;
    se_wcol  : in  natural range 0 to DIM-1;
    se_wdata : in  signed(7 downto 0);

    -- ---- the AXI masters, ONE pair, shared by both phases -----------------
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
  constant BPB   : positive := AXI_DW / 8;
  constant EXPN  : positive := VAL_HEADS * DIM;

  -- ---- REFUSALS THAT RUN DURING ELABORATION ----------------------------
  -- Out-of-range `natural`s, not asserts: Vivado ignores
  -- `assert ... severity failure` in synthesis.  The NAME is the diagnostic.
  --
  -- The two movers each check their own byte count against the geometry they
  -- were given, and each checks its own count against LAYER_STRIDE -- but
  -- NEITHER can see the other, so nothing below this line would notice the
  -- mantissa and exponent regions OVERLAPPING inside one layer.  That is
  -- precisely the shape of the collision this arena has already had once
  -- between two allocators that could not see each other, and the symptom was
  -- a wrong token.  This is the only place both figures are visible at once,
  -- so this is where the check belongs.
  constant bad_exp_bytes_vs_shape : natural := EXP_BYTES - EXPN;
  constant bad_stride_below_mant_plus_exp : natural
         := LAYER_STRIDE - (MANT_BYTES + EXP_BYTES);
  -- The exponent region starts at `state_base + MANT_BYTES`, so MANT_BYTES
  -- must itself be a whole number of beats or every exponent transfer starts
  -- mid-beat.  The mantissa mover's own `bad_mant_bytes_vs_shape` makes this
  -- true at the shipping shape, but it is true there as a CONSEQUENCE of the
  -- mantissa geometry, and a check that holds by consequence is not a check.
  constant bad_mant_bytes_not_beat_aligned : natural
         := 0 - (MANT_BYTES mod BPB);

  signal bsy : std_logic;

  -- ---- the resident stores' ports, after arbitration ------------------
  signal m_we, m_re : std_logic;
  signal m_wh, m_rh : natural range 0 to VAL_HEADS-1;
  signal m_wc, m_rc : natural range 0 to DIM-1;
  signal m_wg, m_rg : natural range 0 to NBR-1;
  signal m_wd, m_rd : std_logic_vector(WBITS-1 downto 0);

  -- ---- the MANTISSA mover ---------------------------------------------
  signal a_load, a_save, a_busy, a_done, a_err : std_logic := '0';
  signal a_we, a_re : std_logic;
  signal a_wh, a_rh : natural range 0 to VAL_HEADS-1;
  signal a_wc, a_rc : natural range 0 to DIM-1;
  signal a_wg, a_rg : natural range 0 to NBR-1;
  signal a_wd       : std_logic_vector(WBITS-1 downto 0);

  signal a_arvalid, a_arready, a_rvalid, a_rready : std_logic;
  signal a_araddr : std_logic_vector(ADDR_W-1 downto 0);
  signal a_arlen  : std_logic_vector(7 downto 0);
  signal a_arsize : std_logic_vector(2 downto 0);
  signal a_arburst: std_logic_vector(1 downto 0);
  signal a_awvalid, a_awready, a_wvalid, a_wready, a_wlast : std_logic;
  signal a_bvalid, a_bready : std_logic;
  signal a_awaddr : std_logic_vector(ADDR_W-1 downto 0);
  signal a_awlen  : std_logic_vector(7 downto 0);
  signal a_awsize : std_logic_vector(2 downto 0);
  signal a_awburst: std_logic_vector(1 downto 0);
  signal a_wdata  : std_logic_vector(AXI_DW-1 downto 0);
  signal a_wstrb  : std_logic_vector(AXI_DW/8-1 downto 0);

  -- ---- the EXPONENT mover ----------------------------------------------
  -- Same entity, `WORD_BITS => 8, N_GRP => 1`.  Its `m_*_grp` port is then
  -- `0 to 0` and carries no information, which is why it is left open: the
  -- flat byte index is `head*DIM + col` and that is exactly what
  -- gdn_exp_mem's mover port takes.
  signal e_load, e_save, e_busy, e_done, e_err : std_logic := '0';
  signal e_we, e_re : std_logic;
  signal e_wh, e_rh : natural range 0 to VAL_HEADS-1;
  signal e_wc, e_rc : natural range 0 to DIM-1;
  signal e_wd, e_rd : std_logic_vector(7 downto 0);

  signal e_arvalid, e_arready, e_rvalid, e_rready : std_logic;
  signal e_araddr : std_logic_vector(ADDR_W-1 downto 0);
  signal e_arlen  : std_logic_vector(7 downto 0);
  signal e_arsize : std_logic_vector(2 downto 0);
  signal e_arburst: std_logic_vector(1 downto 0);
  signal e_awvalid, e_awready, e_wvalid, e_wready, e_wlast : std_logic;
  signal e_bvalid, e_bready : std_logic;
  signal e_awaddr : std_logic_vector(ADDR_W-1 downto 0);
  signal e_awlen  : std_logic_vector(7 downto 0);
  signal e_awsize : std_logic_vector(2 downto 0);
  signal e_awburst: std_logic_vector(1 downto 0);
  signal e_wdata  : std_logic_vector(AXI_DW-1 downto 0);
  signal e_wstrb  : std_logic_vector(AXI_DW/8-1 downto 0);

  -- Expressions are legal as port-map actuals in VHDL-2008, but every
  -- instance port in this repository is a plain signal and Vivado's 2008
  -- coverage is not something to discover at synthesis time on a Friday.
  -- These four exist only so the port map stays a list of names.
  signal e_r_addr, e_w_addr : natural range 0 to EXPN-1;
  signal e_rd_s, e_wd_s     : signed(7 downto 0);
  signal e_unit_wen         : std_logic;

  -- ---- the sequencer ---------------------------------------------------
  type q_t is (Q_IDLE, Q_MANT, Q_EXP, Q_DONE);
  signal q       : q_t := Q_IDLE;
  signal is_save : std_logic := '0';
  signal sel_e   : std_logic := '0';   -- '1' = the exponent mover owns AXI
  signal done_q  : std_logic := '0';

  -- The exponent region of THIS layer sits immediately after its mantissas.
  -- The mover adds `layer * LAYER_STRIDE` itself, so the only thing added
  -- here is the within-layer offset, and it is a constant.
  signal exp_base : std_logic_vector(ADDR_W-1 downto 0);
begin
  busy <= bsy;
  bsy  <= '0' when q = Q_IDLE else '1';
  done <= done_q;
  err  <= a_err or e_err;

  exp_base <= std_logic_vector(unsigned(state_base)
                             + to_unsigned(MANT_BYTES, ADDR_W));

  -- ================= the sequencer ======================================
  -- ONE start in, TWO transfers, ONE done out.  `sel_e` is set on the edge
  -- the mantissa phase reports done and held for the whole exponent phase;
  -- the mantissa mover has fully retired by then (it does not leave S_SDRAIN
  -- until its last BRESP is in) so there is no residual traffic to steal.
  seq : process(clk) is
  begin
    if rising_edge(clk) then
      done_q <= '0';
      a_load <= '0'; a_save <= '0';
      e_load <= '0'; e_save <= '0';

      if rst = '1' then
        q <= Q_IDLE; sel_e <= '0'; is_save <= '0';
      else
        case q is
          when Q_IDLE =>
            if load_start = '1' or save_start = '1' then
              is_save <= save_start;
              a_load  <= load_start;
              a_save  <= save_start;
              sel_e   <= '0';
              q       <= Q_MANT;
            end if;

          when Q_MANT =>
            if a_done = '1' then
              e_load <= not is_save;
              e_save <= is_save;
              sel_e  <= '1';
              q      <= Q_EXP;
            end if;

          when Q_EXP =>
            if e_done = '1' then
              sel_e <= '0';
              q     <= Q_DONE;
            end if;

          when Q_DONE =>
            done_q <= '1';
            q      <= Q_IDLE;
        end case;
      end if;
    end if;
  end process;

  -- ================= the AXI 2:1 ========================================
  -- Outputs follow `sel_e`.  Inputs are FORCED LOW to the mover that does not
  -- own the bus rather than merely broadcast, because a handshake is an AND of
  -- valid and ready: broadcasting `r_arready` to an idle mover is harmless
  -- only for as long as that mover keeps `arvalid` low, and a design that is
  -- correct only because of what another module happens not to do is the
  -- shape of bug this project keeps paying for.  Data and response fields ARE
  -- broadcast: they are qualified by the valid that is already gated.
  r_arvalid <= e_arvalid when sel_e = '1' else a_arvalid;
  r_araddr  <= e_araddr  when sel_e = '1' else a_araddr;
  r_arlen   <= e_arlen   when sel_e = '1' else a_arlen;
  r_arsize  <= e_arsize  when sel_e = '1' else a_arsize;
  r_arburst <= e_arburst when sel_e = '1' else a_arburst;
  r_rready  <= e_rready  when sel_e = '1' else a_rready;

  a_arready <= r_arready when sel_e = '0' else '0';
  a_rvalid  <= r_rvalid  when sel_e = '0' else '0';
  e_arready <= r_arready when sel_e = '1' else '0';
  e_rvalid  <= r_rvalid  when sel_e = '1' else '0';

  w_awvalid <= e_awvalid when sel_e = '1' else a_awvalid;
  w_awaddr  <= e_awaddr  when sel_e = '1' else a_awaddr;
  w_awlen   <= e_awlen   when sel_e = '1' else a_awlen;
  w_awsize  <= e_awsize  when sel_e = '1' else a_awsize;
  w_awburst <= e_awburst when sel_e = '1' else a_awburst;
  w_wvalid  <= e_wvalid  when sel_e = '1' else a_wvalid;
  w_wdata   <= e_wdata   when sel_e = '1' else a_wdata;
  w_wstrb   <= e_wstrb   when sel_e = '1' else a_wstrb;
  w_wlast   <= e_wlast   when sel_e = '1' else a_wlast;
  w_bready  <= e_bready  when sel_e = '1' else a_bready;

  a_awready <= w_awready when sel_e = '0' else '0';
  a_wready  <= w_wready  when sel_e = '0' else '0';
  a_bvalid  <= w_bvalid  when sel_e = '0' else '0';
  e_awready <= w_awready when sel_e = '1' else '0';
  e_wready  <= w_wready  when sel_e = '1' else '0';
  e_bvalid  <= w_bvalid  when sel_e = '1' else '0';

  -- ================= the mantissa store =================================
  -- THE 2:1, AND NOTHING ELSE.  No arithmetic: see the header.
  m_we <= a_we when bsy = '1' else st_wen;
  m_wh <= a_wh when bsy = '1' else st_whead;
  m_wc <= a_wc when bsy = '1' else st_wcol;
  m_wg <= a_wg when bsy = '1' else st_wgrp;
  m_wd <= a_wd when bsy = '1' else st_wdata;
  m_re <= a_re when bsy = '1' else st_ren;
  m_rh <= a_rh when bsy = '1' else st_rhead;
  m_rc <= a_rc when bsy = '1' else st_rcol;
  m_rg <= a_rg when bsy = '1' else st_rgrp;

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
                WORD_BITS => WBITS, N_GRP => NBR,
                LAYER_STRIDE => LAYER_STRIDE, MANT_BYTES => MANT_BYTES,
                AXI_DW => AXI_DW, ADDR_W => ADDR_W,
                MAXB => MAXB, MAXOUT => MAXOUT)
    port map(clk => clk, rst => rst,
             load_start => a_load, save_start => a_save,
             layer => layer, state_base => state_base,
             busy => a_busy, done => a_done, err => a_err,
             m_w_en => a_we, m_w_head => a_wh, m_w_col => a_wc,
             m_w_grp => a_wg, m_w_data => a_wd,
             m_r_en => a_re, m_r_head => a_rh, m_r_col => a_rc,
             m_r_grp => a_rg, m_r_data => m_rd,
             r_arvalid => a_arvalid, r_arready => a_arready,
             r_araddr => a_araddr, r_arlen => a_arlen, r_arsize => a_arsize,
             r_arburst => a_arburst, r_rvalid => a_rvalid,
             r_rready => a_rready, r_rdata => r_rdata, r_rlast => r_rlast,
             r_rresp => r_rresp,
             w_awvalid => a_awvalid, w_awready => a_awready,
             w_awaddr => a_awaddr, w_awlen => a_awlen, w_awsize => a_awsize,
             w_awburst => a_awburst, w_wvalid => a_wvalid,
             w_wready => a_wready, w_wdata => a_wdata, w_wstrb => a_wstrb,
             w_wlast => a_wlast, w_bvalid => a_bvalid, w_bready => a_bready,
             w_bresp => w_bresp);

  -- ================= the exponent store =================================
  -- gdn_exp_mem has two SEPARATE write ports and resolves a collision in
  -- favour of the mover, so the arbitration here is a gate rather than a mux:
  -- the unit's write is suppressed while a mover owns the store.  The guard
  -- below reads the RAW `se_wen` port, not this gated copy, so suppressing
  -- the write does not also suppress the report of it.
  e_r_addr    <= e_rh*DIM + e_rc;
  e_w_addr    <= e_wh*DIM + e_wc;
  e_wd_s      <= signed(e_wd);
  e_rd        <= std_logic_vector(e_rd_s);
  e_unit_wen  <= se_wen and not bsy;

  u_exp : entity work.gdn_exp_mem
    generic map(VAL_HEADS => VAL_HEADS, DIM => DIM, STYLE => EXP_STYLE)
    port map(clk => clk,
             -- `se_rdata` IS DRIVEN DIRECTLY BY THE INSTANCE, with no
             -- intermediate signal relaying it out.  Such a relay is free in
             -- hardware and is NOT free in a bench: it inserts a delta, and a
             -- testbench that checks a combinational read after a fixed
             -- number of `wait for 0 ns` then sees the PREVIOUS address.
             -- MEASURED here: 767 of 768 exponent bytes mismatched, every one
             -- shifted by exactly one entry, and the defect was in neither
             -- the memory nor the mover.
             r_head => se_rhead, r_col => se_rcol, r_data => se_rdata,
             w_en => e_unit_wen, w_head => se_whead,
             w_col => se_wcol, w_data => se_wdata,
             m_r_addr => e_r_addr, m_r_data => e_rd_s,
             m_w_en => e_we, m_w_addr => e_w_addr,
             m_w_data => e_wd_s);

  u_edma : entity work.gdn_state_axi
    generic map(VAL_HEADS => VAL_HEADS, DIM => DIM,
                RECUR_LANES => RECUR_LANES, LAYERS => LAYERS,
                WORD_BITS => 8, N_GRP => 1,
                LAYER_STRIDE => LAYER_STRIDE, MANT_BYTES => EXP_BYTES,
                AXI_DW => AXI_DW, ADDR_W => ADDR_W,
                MAXB => MAXB, MAXOUT => MAXOUT)
    port map(clk => clk, rst => rst,
             load_start => e_load, save_start => e_save,
             layer => layer, state_base => exp_base,
             busy => e_busy, done => e_done, err => e_err,
             m_w_en => e_we, m_w_head => e_wh, m_w_col => e_wc,
             m_w_grp => open, m_w_data => e_wd,
             m_r_en => e_re, m_r_head => e_rh, m_r_col => e_rc,
             m_r_grp => open, m_r_data => e_rd,
             r_arvalid => e_arvalid, r_arready => e_arready,
             r_araddr => e_araddr, r_arlen => e_arlen, r_arsize => e_arsize,
             r_arburst => e_arburst, r_rvalid => e_rvalid,
             r_rready => e_rready, r_rdata => r_rdata, r_rlast => r_rlast,
             r_rresp => r_rresp,
             w_awvalid => e_awvalid, w_awready => e_awready,
             w_awaddr => e_awaddr, w_awlen => e_awlen, w_awsize => e_awsize,
             w_awburst => e_awburst, w_wvalid => e_wvalid,
             w_wready => e_wready, w_wdata => e_wdata, w_wstrb => e_wstrb,
             w_wlast => e_wlast, w_bvalid => e_bvalid, w_bready => e_bready,
             w_bresp => w_bresp);

  -- SIMULATION ONLY.  A VHDL severity is a width in synthesis and not a
  -- check, so this catches the caller in a bench and not on the card.  It is
  -- still the right place for it: the violation is silent otherwise, and it
  -- produces a wrong number rather than a hang.
  -- synthesis translate_off
  guard : process(clk) is
  begin
    if rising_edge(clk) then
      if bsy = '1' and (st_ren = '1' or st_wen = '1' or se_wen = '1') then
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
