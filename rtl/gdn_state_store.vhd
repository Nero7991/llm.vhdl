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
-- THREE REGIONS, THREE PHASES, ONE PAIR OF MASTERS.  A GDN layer's state is
-- the recurrent MANTISSAS (1,048,576 B), the state EXPONENTS (4,096 B) and the
-- CONV TAP HISTORY (49,152 B) -- `(conv_kernel-1) x qkv_dim` 16-bit elements,
-- the previous KCONV-1 columns of the whole qkv stream that `gdn_conv`'s
-- causal kernel needs.  All three are inside `LAYER_STRIDE`, laid out in that
-- order, and all three are moved by an instance of the SAME `gdn_state_axi`
-- run in turn over the same masters.
--
-- WHAT THIS STILL DOES NOT COVER, stated because a reader would reasonably
-- assume otherwise: nothing here FEEDS the conv tap write port -- that data is
-- this token's qkv column from A, one group at a time -- and nothing pulses
-- `tok_adv`, which only something that knows where a token ends can do.  Both
-- are the job sequencer's, and until it exists this tier is complete and
-- unused.
--
-- A FOURTH REGION, A FOURTH PHASE, AND IT IS NOT STATE (2026-09-18, under
-- `CONST_EN`).  The layer's learned GDN CONSTANTS -- the conv weights
-- `[KCONV][QKVN]`, the dt bias and A `[VAL_HEADS]`, the ssm norm weight
-- `[DIM]` and their six exponents -- are 66,048 bytes per layer at 9B and do
-- not fit as a ROM beside the norm image (docs/2026-09-18_b-constants-path.md).
-- They live in a SEPARATE HBM region, `const_base + layer*CONST_STRIDE`, NOT
-- inside `LAYER_STRIDE`, because that arena is per-layer STATE the host may
-- snapshot and this is model data the host loads once with the weights.  A
-- fourth `gdn_state_axi` instance moves them after the conv taps, LOAD ONLY:
-- a save job has three phases as before and never writes the region.  The
-- weights land in `gdn_conv_w_mem` (KCONV slots, no rotation, `cw_w` shaped
-- as gdn_block's `cv_w`); the scalar block lands in a decoded register file
-- whose outputs are LEVELS, valid from `done` until the next load.
-- `CONST_EN = false` is the store as it was: no fourth phase, no fourth
-- mover, no memory, every new output a constant zero.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gdn_state_store is
  generic(
    VAL_HEADS   : positive := 32;
    DIM         : positive := 128;
    RECUR_LANES : positive := 4;
    LAYERS      : positive := 24;
    -- The conv geometry.  KEY_HEADS is a generic and not derived because the
    -- q and k segments are KEY_HEADS wide while v is VAL_HEADS wide, and
    -- nothing else in this entity needed the distinction until the taps.
    KEY_HEADS   : positive := 16;         -- model_cfg_pkg lin_key_heads
    KCONV       : positive := 4;          -- model_cfg_pkg conv_kernel
    CONV_LANES  : positive := 4;          -- gdn_block CONV_LANES
    STYLE       : string   := "ultra";        -- gdn_state_mem: NOT "auto"
    EXP_STYLE   : string   := "distributed";  -- gdn_exp_mem: NOT block/ultra
    CONV_STYLE  : string   := "block";        -- gdn_conv_tap_mem: NOT distrib

    LAYER_STRIDE : positive := 1101824;   -- gdn_state_bytes_per_layer
    MANT_BYTES   : positive := 1048576;   -- gdn_state_mant_bytes_per_layer
    EXP_BYTES    : positive := 4096;      -- gdn_state_exp_bytes_per_layer
    CONV_BYTES   : positive := 49152;     -- gdn_state_conv_bytes_per_layer

    -- ---- the fourth, LOAD-ONLY phase: the layer's learned constants -----
    -- Defaults are the 9B figures from tools/hbm_map.py (`gdn_const_*`) and
    -- are still only defaults; the caller passes the manifest's.  With
    -- CONST_EN false none of the three is read.
    CONST_EN     : boolean  := false;     -- the fourth phase exists
    CONST_STRIDE : positive := 66048;     -- gdn_const_bytes_per_layer
    CONST_BYTES  : positive := 66048;     -- bytes moved per layer (= stride)

    AXI_DW : positive := 256;
    ADDR_W : positive := 33;
    MAXB   : positive := 16;
    MAXOUT : positive := 4
  );
  port(
    clk : in std_logic;
    rst : in std_logic;

    -- ---- the mover's job control ----------------------------------------
    -- ONE start covers EVERY phase.  `done` pulses once, after the last of
    -- them: the conv taps for a save, the constants for a load under
    -- CONST_EN.
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

    -- ---- gdn_block's cv_* tap source, and the write that refills it -------
    -- `cv_seg`/`cv_grp` are sampled on the rising edge and `cv_x` is valid in
    -- the following cycle, which is gdn_block's stated contract (:269-272).
    -- `cv_x` here is the KCONV-1 STORED taps only, oldest first; the CURRENT
    -- column is this token's qkv and the caller appends it.
    cv_seg   : in  integer range 0 to 2;
    cv_grp   : in  natural range 0 to (VAL_HEADS*DIM)/CONV_LANES-1;
    cv_x     : out std_logic_vector((KCONV-1)*CONV_LANES*16-1 downto 0);
    cvw_en   : in  std_logic;
    cvw_seg  : in  integer range 0 to 2;
    cvw_grp  : in  natural range 0 to (VAL_HEADS*DIM)/CONV_LANES-1;
    cvw_data : in  std_logic_vector(CONV_LANES*16-1 downto 0);
    -- ONE pulse per TOKEN, after every layer has read and written.  Not per
    -- layer: every GDN layer is visited once per token so all of them rotate
    -- in lockstep, which is why the rotation needs no per-layer state and
    -- therefore no HBM storage.  See rtl/gdn_conv_tap_mem.vhd.
    tok_adv  : in  std_logic;

    -- ---- the constants (CONST_EN only; zeros otherwise) -------------------
    -- Layer L's image is at `const_base + L*CONST_STRIDE`, L the SAME index
    -- `layer` carries.  Word `w` of the image is at byte `2w`:
    --   w <  KCONV*QKVN            conv weight, tap `w / QKVN`, channel
    --                               `w mod QKVN`, t = 0 OLDEST .. KCONV-1
    --                               NEWEST, channels in q | k | v order
    --   w >= KCONV*QKVN = SB       the scalar block, 256 words:
    --     SB + 0 .. SB + VAL_HEADS-1               dt bias, Q(dt_e)
    --     SB + VAL_HEADS .. SB + 2*VAL_HEADS-1     A, Q(a_e)
    --     SB + 2*VAL_HEADS .. SB + 2*VAL_HEADS+DIM-1   norm weight, Q(w_exp)
    --     SB + 2*VAL_HEADS + DIM + {0,1,2}        cw_exp for seg q, k, v
    --     SB + 2*VAL_HEADS + DIM + {3,4,5}        dt_e, a_e, w_exp
    --     the rest of the 256                     zero
    -- Every exponent is the LOW BYTE of its word, signed.
    const_base : in  std_logic_vector(ADDR_W-1 downto 0) := (others => '0');

    -- The conv WEIGHT face, addressed exactly like cv_seg/cv_grp and with
    -- the same timing: address sampled on the edge, data valid next cycle.
    -- Defaulted so a caller without the phase need not wire them.
    cw_seg  : in  integer range 0 to 2 := 0;
    cw_grp  : in  natural range 0 to (VAL_HEADS*DIM)/CONV_LANES-1 := 0;
    -- bit slice (t*CONV_LANES+ln)*16 +: 16 is tap t, lane ln, t=KCONV-1
    -- the NEWEST: gdn_block's `cv_w` order.
    cw_w    : out std_logic_vector(KCONV*CONV_LANES*16-1 downto 0);
    -- seg s at s*8 +: 8, signed
    cw_exp  : out std_logic_vector(3*8-1 downto 0);

    -- The scalar block.  LEVELS, valid from the `done` of a load until the
    -- next load replaces them.  Head h / column c at h*16 +: 16 / c*16 +: 16.
    sc_dt_m : out std_logic_vector(VAL_HEADS*16-1 downto 0);
    sc_a_m  : out std_logic_vector(VAL_HEADS*16-1 downto 0);
    sn_w    : out std_logic_vector(DIM*16-1 downto 0);
    sc_dt_e : out signed(7 downto 0);
    sc_a_e  : out signed(7 downto 0);
    sn_exp  : out signed(7 downto 0);

    -- ---- the AXI masters, ONE pair, shared by every phase -----------------
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
  constant KEY_CH : positive := KEY_HEADS * DIM;      -- the q and k segments
  constant VAL_CH : positive := VAL_HEADS * DIM;      -- the v segment
  constant QKVN   : positive := 2*KEY_CH + VAL_CH;    -- llama_map_pkg qkv_dim
  constant CONV_WORDS : positive := (KCONV-1) * QKVN; -- 16-bit words per layer

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
  -- THE SAME ARGUMENT, ONE REGION FURTHER ALONG, AND IT NEEDED SAYING AGAIN.
  -- The rule above stops at two regions.  With THREE, a stride that fits the
  -- mantissas and the exponents can still put the conv taps on top of the next
  -- layer, and neither of those two checks nor any of the three movers' own
  -- can see it -- each mover knows only its own byte count and the stride.
  constant bad_stride_below_all_three : natural
         := LAYER_STRIDE - (MANT_BYTES + EXP_BYTES + CONV_BYTES);
  -- The conv region starts at `state_base + MANT_BYTES + EXP_BYTES`, so that
  -- sum must be beat-aligned for the same reason MANT_BYTES alone must be.
  constant bad_conv_base_not_beat_aligned : natural
         := 0 - ((MANT_BYTES + EXP_BYTES) mod BPB);
  -- The arena figure must match the SHAPE, two bytes per 16-bit element.
  constant bad_conv_bytes_vs_shape : natural := CONV_BYTES - 2*CONV_WORDS;

  -- ---- the constants image geometry ----------------------------------
  constant CW_WORDS    : positive := KCONV * QKVN;    -- conv weight words
  constant SB_WORDS    : positive := 256;             -- the scalar block
  constant CONST_WORDS : positive := CW_WORDS + SB_WORDS;
  -- Offsets WITHIN the scalar block, in words.
  constant SB_DT  : natural := 0;
  constant SB_A   : natural := VAL_HEADS;
  constant SB_NW  : natural := 2*VAL_HEADS;
  constant SB_EXP : natural := 2*VAL_HEADS + DIM;
  constant SB_END : natural := SB_EXP + 6;

  -- THE CONST REFUSALS ARE GATED ON `CONST_EN`, and they have to be: the
  -- generics default to the 9B figures, and a caller at the sim shape with
  -- the phase OFF would otherwise be refused for a region it never moves.
  -- Two-sided where the contract is an equality, because a one-sided check
  -- lets a too-large arena figure through (the HREG_W lesson).
  function only_if(en : boolean; v : integer) return integer is
  begin
    if en then return v; else return 0; end if;
  end function;
  constant bad_const_bytes_below_shape : natural
         := only_if(CONST_EN, CONST_BYTES - 2*CONST_WORDS);
  constant bad_const_bytes_above_shape : natural
         := only_if(CONST_EN, 2*CONST_WORDS - CONST_BYTES);
  -- 129 bursts of 512 B at 9B; the packer keeps every shape a multiple.
  constant bad_const_bytes_not_512_aligned : natural
         := only_if(CONST_EN, 0 - (CONST_BYTES mod 512));
  constant bad_const_stride_below_bytes : natural
         := only_if(CONST_EN, CONST_STRIDE - CONST_BYTES);
  -- The scalar block must hold both vectors, the norm weight and the six
  -- exponents inside its 256 words.
  constant bad_scalar_block_overflows : natural
         := only_if(CONST_EN, SB_WORDS - SB_END);

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

  -- ---- the CONV TAP mover ----------------------------------------------
  -- Same entity again, at `VAL_HEADS => 1, DIM => CONV_WORDS, N_GRP => 1,
  -- WORD_BITS => 16`.
  --
  -- **THOSE GENERICS ARE CHOSEN SO THERE IS NO ARITHMETIC IN THE MUX.**
  -- `gdn_state_axi` emits `flat = (head*DIM + col)*N_GRP + grp`; with
  -- VAL_HEADS 1 and N_GRP 1 the head and the group are both always 0 and
  -- **`col` IS the flat word address**, which is exactly what
  -- `gdn_conv_tap_mem`'s mover port takes.  It wires straight across: no
  -- multiply, no add, nothing for an integration error to hide in.  That is
  -- defect D1 of docs/debugging/2026-09-02_gdn-state-dma.md applied rather
  -- than restated -- pick the decomposition so the caller never inverts it.
  signal c_load, c_save, c_busy, c_done, c_err : std_logic := '0';
  signal c_we, c_re : std_logic;
  signal c_wa, c_ra : natural range 0 to CONV_WORDS-1;
  signal c_wd, c_rd : std_logic_vector(15 downto 0);

  signal c_arvalid, c_arready, c_rvalid, c_rready : std_logic;
  signal c_araddr : std_logic_vector(ADDR_W-1 downto 0);
  signal c_arlen  : std_logic_vector(7 downto 0);
  signal c_arsize : std_logic_vector(2 downto 0);
  signal c_arburst: std_logic_vector(1 downto 0);
  signal c_awvalid, c_awready, c_wvalid, c_wready, c_wlast : std_logic;
  signal c_bvalid, c_bready : std_logic;
  signal c_awaddr : std_logic_vector(ADDR_W-1 downto 0);
  signal c_awlen  : std_logic_vector(7 downto 0);
  signal c_awsize : std_logic_vector(2 downto 0);
  signal c_awburst: std_logic_vector(1 downto 0);
  signal c_wdata  : std_logic_vector(AXI_DW-1 downto 0);
  signal c_wstrb  : std_logic_vector(AXI_DW/8-1 downto 0);

  signal cv_unit_wen : std_logic;

  -- ---- the CONSTANTS mover (CONST_EN) ----------------------------------
  -- Same entity a fourth time, at `VAL_HEADS => 1, DIM => CONST_WORDS,
  -- N_GRP => 1, WORD_BITS => 16`, so again `col` IS the flat word address.
  -- LOAD ONLY: `k_save` is a constant '0' and the read-side port is tied off.
  -- Every signal here is DRIVEN in both arms of the `gconst` generate below,
  -- so with CONST_EN false the 4:1's "11" leg and the new outputs are
  -- constant zeros rather than undriven.
  signal k_load, k_busy, k_done, k_err : std_logic := '0';
  signal k_we : std_logic := '0';
  signal k_wa : natural range 0 to CONST_WORDS-1 := 0;
  signal k_wd : std_logic_vector(15 downto 0) := (others => '0');

  signal k_arvalid, k_arready, k_rvalid, k_rready : std_logic := '0';
  signal k_araddr : std_logic_vector(ADDR_W-1 downto 0) := (others => '0');
  signal k_arlen  : std_logic_vector(7 downto 0) := (others => '0');
  signal k_arsize : std_logic_vector(2 downto 0) := (others => '0');
  signal k_arburst: std_logic_vector(1 downto 0) := (others => '0');
  signal k_awvalid, k_awready, k_wvalid, k_wready, k_wlast : std_logic := '0';
  signal k_bvalid, k_bready : std_logic := '0';
  signal k_awaddr : std_logic_vector(ADDR_W-1 downto 0) := (others => '0');
  signal k_awlen  : std_logic_vector(7 downto 0) := (others => '0');
  signal k_awsize : std_logic_vector(2 downto 0) := (others => '0');
  signal k_awburst: std_logic_vector(1 downto 0) := (others => '0');
  signal k_wdata  : std_logic_vector(AXI_DW-1 downto 0) := (others => '0');
  signal k_wstrb  : std_logic_vector(AXI_DW/8-1 downto 0) := (others => '0');

  -- ---- the sequencer ---------------------------------------------------
  type q_t is (Q_IDLE, Q_MANT, Q_EXP, Q_CONV, Q_CONST, Q_DONE);
  signal q       : q_t := Q_IDLE;
  signal is_save : std_logic := '0';
  signal done_q  : std_logic := '0';
  -- WHICH MOVER OWNS THE MASTERS.  "00" mantissas, "01" exponents, "10" conv
  -- taps, "11" the constants (CONST_EN only; never reached otherwise).  Held
  -- for a whole phase.
  signal sel     : std_logic_vector(1 downto 0) := "00";

  -- The three regions of THIS layer, in order.  The movers add
  -- `layer * LAYER_STRIDE` themselves, so the only thing added here is the
  -- within-layer offset, and both are constants.
  signal exp_base  : std_logic_vector(ADDR_W-1 downto 0);
  signal conv_base : std_logic_vector(ADDR_W-1 downto 0);
begin
  busy <= bsy;
  bsy  <= '0' when q = Q_IDLE else '1';
  done <= done_q;
  err  <= a_err or e_err or c_err or k_err;

  exp_base  <= std_logic_vector(unsigned(state_base)
                              + to_unsigned(MANT_BYTES, ADDR_W));
  conv_base <= std_logic_vector(unsigned(state_base)
                              + to_unsigned(MANT_BYTES + EXP_BYTES, ADDR_W));

  -- ================= the sequencer ======================================
  -- ONE start in, THREE transfers (FOUR for a load under CONST_EN), ONE done
  -- out.  `sel` is set on the edge a phase reports done and held for the
  -- whole of the next one; a mover has fully retired by the time it reports
  -- done (it does not leave S_SDRAIN until its last BRESP is in) so there is
  -- no residual traffic to steal.
  seq : process(clk) is
  begin
    if rising_edge(clk) then
      done_q <= '0';
      a_load <= '0'; a_save <= '0';
      e_load <= '0'; e_save <= '0';
      c_load <= '0'; c_save <= '0';
      k_load <= '0';

      if rst = '1' then
        q <= Q_IDLE; sel <= "00"; is_save <= '0';
      else
        case q is
          when Q_IDLE =>
            if load_start = '1' or save_start = '1' then
              is_save <= save_start;
              a_load  <= load_start;
              a_save  <= save_start;
              sel     <= "00";
              q       <= Q_MANT;
            end if;

          when Q_MANT =>
            if a_done = '1' then
              e_load <= not is_save;
              e_save <= is_save;
              sel    <= "01";
              q      <= Q_EXP;
            end if;

          when Q_EXP =>
            if e_done = '1' then
              c_load <= not is_save;
              c_save <= is_save;
              sel    <= "10";
              q      <= Q_CONV;
            end if;

          when Q_CONV =>
            if c_done = '1' then
              -- THE FOURTH PHASE IS A LOAD'S ONLY.  A save has nothing to
              -- write back: the constants are the model's, not the token's.
              if CONST_EN and is_save = '0' then
                k_load <= '1';
                sel    <= "11";
                q      <= Q_CONST;
              else
                sel <= "00";
                q   <= Q_DONE;
              end if;
            end if;

          when Q_CONST =>
            if k_done = '1' then
              sel <= "00";
              q   <= Q_DONE;
            end if;

          when Q_DONE =>
            done_q <= '1';
            q      <= Q_IDLE;
        end case;
      end if;
    end if;
  end process;

  -- ================= the AXI 4:1 ========================================
  -- Outputs follow `sel`.  Inputs are FORCED LOW to the movers that do not
  -- own the bus rather than merely broadcast, because a handshake is an AND of
  -- valid and ready: broadcasting `r_arready` to an idle mover is harmless
  -- only for as long as that mover keeps `arvalid` low, and a design that is
  -- correct only because of what another module happens not to do is the
  -- shape of bug this project keeps paying for.  Data and response fields ARE
  -- broadcast: they are qualified by the valid that is already gated.
  --
  -- `with ... select` rather than a chain of `when`, because with four
  -- sources a chain buries the default.  All four encodings are now named;
  -- `others` covers only metavalues and maps to the mantissa mover rather
  -- than to 'X' so a glitch cannot inject an undefined AXI valid.  With
  -- CONST_EN false the "11" leg is constant zeros and `sel` never takes it.
  with sel select r_arvalid <= e_arvalid when "01", c_arvalid when "10",
                               k_arvalid when "11", a_arvalid when others;
  with sel select r_araddr  <= e_araddr  when "01", c_araddr  when "10",
                               k_araddr  when "11", a_araddr  when others;
  with sel select r_arlen   <= e_arlen   when "01", c_arlen   when "10",
                               k_arlen   when "11", a_arlen   when others;
  with sel select r_arsize  <= e_arsize  when "01", c_arsize  when "10",
                               k_arsize  when "11", a_arsize  when others;
  with sel select r_arburst <= e_arburst when "01", c_arburst when "10",
                               k_arburst when "11", a_arburst when others;
  with sel select r_rready  <= e_rready  when "01", c_rready  when "10",
                               k_rready  when "11", a_rready  when others;

  a_arready <= r_arready when sel = "00" else '0';
  a_rvalid  <= r_rvalid  when sel = "00" else '0';
  e_arready <= r_arready when sel = "01" else '0';
  e_rvalid  <= r_rvalid  when sel = "01" else '0';
  c_arready <= r_arready when sel = "10" else '0';
  c_rvalid  <= r_rvalid  when sel = "10" else '0';
  k_arready <= r_arready when sel = "11" else '0';
  k_rvalid  <= r_rvalid  when sel = "11" else '0';

  with sel select w_awvalid <= e_awvalid when "01", c_awvalid when "10",
                               k_awvalid when "11", a_awvalid when others;
  with sel select w_awaddr  <= e_awaddr  when "01", c_awaddr  when "10",
                               k_awaddr  when "11", a_awaddr  when others;
  with sel select w_awlen   <= e_awlen   when "01", c_awlen   when "10",
                               k_awlen   when "11", a_awlen   when others;
  with sel select w_awsize  <= e_awsize  when "01", c_awsize  when "10",
                               k_awsize  when "11", a_awsize  when others;
  with sel select w_awburst <= e_awburst when "01", c_awburst when "10",
                               k_awburst when "11", a_awburst when others;
  with sel select w_wvalid  <= e_wvalid  when "01", c_wvalid  when "10",
                               k_wvalid  when "11", a_wvalid  when others;
  with sel select w_wdata   <= e_wdata   when "01", c_wdata   when "10",
                               k_wdata   when "11", a_wdata   when others;
  with sel select w_wstrb   <= e_wstrb   when "01", c_wstrb   when "10",
                               k_wstrb   when "11", a_wstrb   when others;
  with sel select w_wlast   <= e_wlast   when "01", c_wlast   when "10",
                               k_wlast   when "11", a_wlast   when others;
  with sel select w_bready  <= e_bready  when "01", c_bready  when "10",
                               k_bready  when "11", a_bready  when others;

  a_awready <= w_awready when sel = "00" else '0';
  a_wready  <= w_wready  when sel = "00" else '0';
  a_bvalid  <= w_bvalid  when sel = "00" else '0';
  e_awready <= w_awready when sel = "01" else '0';
  e_wready  <= w_wready  when sel = "01" else '0';
  e_bvalid  <= w_bvalid  when sel = "01" else '0';
  c_awready <= w_awready when sel = "10" else '0';
  c_wready  <= w_wready  when sel = "10" else '0';
  c_bvalid  <= w_bvalid  when sel = "10" else '0';
  k_awready <= w_awready when sel = "11" else '0';
  k_wready  <= w_wready  when sel = "11" else '0';
  k_bvalid  <= w_bvalid  when sel = "11" else '0';

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

  -- ================= the conv tap store =================================
  -- The write is GATED rather than muxed, the same as the exponent store's:
  -- gdn_conv_tap_mem has one write port and hands it to whichever of the two
  -- asserts, so suppressing the unit's while a mover owns the tier is what
  -- makes the ownership rule real.  The guard below reads the RAW `cvw_en`
  -- port, not this gated copy.
  cv_unit_wen <= cvw_en and not bsy;

  u_conv : entity work.gdn_conv_tap_mem
    generic map(KCONV => KCONV, CONV_LANES => CONV_LANES,
                KEY_CH => KEY_CH, VAL_CH => VAL_CH, STYLE => CONV_STYLE)
    port map(clk => clk,
             r_seg => cv_seg, r_grp => cv_grp, r_x => cv_x,
             w_en => cv_unit_wen, w_seg => cvw_seg, w_grp => cvw_grp,
             w_data => cvw_data,
             tok_adv => tok_adv,
             -- `m_r_en` IS CONNECTED HERE and is left open on the other two
             -- stores, which is not an inconsistency: this memory is a SIMPLE
             -- dual port whose one read address is muxed between the unit and
             -- the mover, so it is `m_r_en` that hands the port over.  Leaving
             -- it open would give the mover the unit's address and read the
             -- wrong word every time.
             m_r_en => c_re, m_r_addr => c_ra, m_r_data => c_rd,
             m_w_en => c_we, m_w_addr => c_wa, m_w_data => c_wd);

  u_cdma : entity work.gdn_state_axi
    -- VAL_HEADS 1 and N_GRP 1, so `col` IS the flat word address and the
    -- wiring below is names to names.  See the signal declarations.
    generic map(VAL_HEADS => 1, DIM => CONV_WORDS,
                RECUR_LANES => RECUR_LANES, LAYERS => LAYERS,
                WORD_BITS => 16, N_GRP => 1,
                LAYER_STRIDE => LAYER_STRIDE, MANT_BYTES => CONV_BYTES,
                AXI_DW => AXI_DW, ADDR_W => ADDR_W,
                MAXB => MAXB, MAXOUT => MAXOUT)
    port map(clk => clk, rst => rst,
             load_start => c_load, save_start => c_save,
             layer => layer, state_base => conv_base,
             busy => c_busy, done => c_done, err => c_err,
             m_w_en => c_we, m_w_head => open, m_w_col => c_wa,
             m_w_grp => open, m_w_data => c_wd,
             m_r_en => c_re, m_r_head => open, m_r_col => c_ra,
             m_r_grp => open, m_r_data => c_rd,
             r_arvalid => c_arvalid, r_arready => c_arready,
             r_araddr => c_araddr, r_arlen => c_arlen, r_arsize => c_arsize,
             r_arburst => c_arburst, r_rvalid => c_rvalid,
             r_rready => c_rready, r_rdata => r_rdata, r_rlast => r_rlast,
             r_rresp => r_rresp,
             w_awvalid => c_awvalid, w_awready => c_awready,
             w_awaddr => c_awaddr, w_awlen => c_awlen, w_awsize => c_awsize,
             w_awburst => c_awburst, w_wvalid => c_wvalid,
             w_wready => c_wready, w_wdata => c_wdata, w_wstrb => c_wstrb,
             w_wlast => c_wlast, w_bvalid => c_bvalid, w_bready => c_bready,
             w_bresp => w_bresp);

  -- ================= the constants: weights, scalars, mover ==============
  -- Present only under CONST_EN.  The `else` arm ties every signal the rest
  -- of this architecture reads to a constant, so the disabled store is the
  -- store as it was with one unreachable sequencer state.
  gconst : if CONST_EN generate
    -- The mover's flat word address, split by REGION at one comparator.
    -- Words below CW_WORDS are weights and go to the memory unchanged; the
    -- rest are the scalar block.  The memory's address port is bounded at
    -- CW_WORDS-1, so an out-of-region word is clamped to 0 AND its enable
    -- is dropped, which is what keeps the clamp from ever writing.
    signal kw_we  : std_logic;
    signal kw_wa  : natural range 0 to CW_WORDS-1;
    -- The read side of a load-only mover: tied off, never consulted.
    signal k_rd_z : std_logic_vector(15 downto 0) := (others => '0');

    type dt_arr_t is array (0 to VAL_HEADS-1) of std_logic_vector(15 downto 0);
    type nw_arr_t is array (0 to DIM-1)       of std_logic_vector(15 downto 0);
    type ex_arr_t is array (0 to 5)           of signed(7 downto 0);
    signal dt_m : dt_arr_t := (others => (others => '0'));
    signal a_m  : dt_arr_t := (others => (others => '0'));
    signal nw_m : nw_arr_t := (others => (others => '0'));
    signal ex_m : ex_arr_t := (others => (others => '0'));
  begin
    kw_we <= k_we when k_wa < CW_WORDS else '0';
    kw_wa <= k_wa when k_wa < CW_WORDS else 0;

    u_cw : entity work.gdn_conv_w_mem
      generic map(KCONV => KCONV, CONV_LANES => CONV_LANES,
                  KEY_CH => KEY_CH, VAL_CH => VAL_CH, STYLE => CONV_STYLE)
      port map(clk => clk,
               r_seg => cw_seg, r_grp => cw_grp, r_w => cw_w,
               m_w_en => kw_we, m_w_addr => kw_wa, m_w_data => k_wd);

    -- THE SCALAR BLOCK, a decoded register file.  One write per cycle from
    -- the mover, decoded on the offset within the block; the outputs are
    -- the registers themselves, so they are levels.  Nothing resets them:
    -- they are meaningless until a load has run, and a load writes every
    -- one of them.
    scal : process(clk) is
      variable si : natural range 0 to SB_WORDS-1;
    begin
      if rising_edge(clk) then
        if k_we = '1' and k_wa >= CW_WORDS then
          si := k_wa - CW_WORDS;
          if si < SB_A then
            dt_m(si - SB_DT) <= k_wd;
          elsif si < SB_NW then
            a_m(si - SB_A) <= k_wd;
          elsif si < SB_EXP then
            nw_m(si - SB_NW) <= k_wd;
          elsif si < SB_END then
            -- The LOW BYTE, signed.  The packer clamps to [-64, 63].
            ex_m(si - SB_EXP) <= signed(k_wd(7 downto 0));
          end if;
        end if;
      end if;
    end process;

    gdt : for h in 0 to VAL_HEADS-1 generate
      sc_dt_m((h+1)*16-1 downto h*16) <= dt_m(h);
      sc_a_m ((h+1)*16-1 downto h*16) <= a_m(h);
    end generate;
    gnw : for c in 0 to DIM-1 generate
      sn_w((c+1)*16-1 downto c*16) <= nw_m(c);
    end generate;
    gex : for s in 0 to 2 generate
      cw_exp((s+1)*8-1 downto s*8) <= std_logic_vector(ex_m(s));
    end generate;
    sc_dt_e <= ex_m(3);
    sc_a_e  <= ex_m(4);
    sn_exp  <= ex_m(5);

    u_kdma : entity work.gdn_state_axi
      -- VAL_HEADS 1 and N_GRP 1, so `col` IS the flat word address, as for
      -- the conv taps.  `save_start` is a constant '0': this region is
      -- never written by the card.
      generic map(VAL_HEADS => 1, DIM => CONST_WORDS,
                  RECUR_LANES => RECUR_LANES, LAYERS => LAYERS,
                  WORD_BITS => 16, N_GRP => 1,
                  LAYER_STRIDE => CONST_STRIDE, MANT_BYTES => CONST_BYTES,
                  AXI_DW => AXI_DW, ADDR_W => ADDR_W,
                  MAXB => MAXB, MAXOUT => MAXOUT)
      port map(clk => clk, rst => rst,
               load_start => k_load, save_start => '0',
               layer => layer, state_base => const_base,
               busy => k_busy, done => k_done, err => k_err,
               m_w_en => k_we, m_w_head => open, m_w_col => k_wa,
               m_w_grp => open, m_w_data => k_wd,
               m_r_en => open, m_r_head => open, m_r_col => open,
               m_r_grp => open, m_r_data => k_rd_z,
               r_arvalid => k_arvalid, r_arready => k_arready,
               r_araddr => k_araddr, r_arlen => k_arlen, r_arsize => k_arsize,
               r_arburst => k_arburst, r_rvalid => k_rvalid,
               r_rready => k_rready, r_rdata => r_rdata, r_rlast => r_rlast,
               r_rresp => r_rresp,
               w_awvalid => k_awvalid, w_awready => k_awready,
               w_awaddr => k_awaddr, w_awlen => k_awlen, w_awsize => k_awsize,
               w_awburst => k_awburst, w_wvalid => k_wvalid,
               w_wready => k_wready, w_wdata => k_wdata, w_wstrb => k_wstrb,
               w_wlast => k_wlast, w_bvalid => k_bvalid, w_bready => k_bready,
               w_bresp => w_bresp);
  else generate
    -- The stand-in-free constants: zeros.  Every signal the 4:1 and the
    -- sequencer read from this side is a constant, so the disabled leg
    -- costs nothing and the phase is unreachable.
    k_busy <= '0'; k_done <= '0'; k_err <= '0';
    k_we <= '0'; k_wa <= 0; k_wd <= (others => '0');
    k_arvalid <= '0'; k_rready <= '0';
    k_araddr <= (others => '0'); k_arlen <= (others => '0');
    k_arsize <= (others => '0'); k_arburst <= (others => '0');
    k_awvalid <= '0'; k_wvalid <= '0'; k_wlast <= '0'; k_bready <= '0';
    k_awaddr <= (others => '0'); k_awlen <= (others => '0');
    k_awsize <= (others => '0'); k_awburst <= (others => '0');
    k_wdata <= (others => '0'); k_wstrb <= (others => '0');

    cw_w    <= (others => '0');
    cw_exp  <= (others => '0');
    sc_dt_m <= (others => '0');
    sc_a_m  <= (others => '0');
    sn_w    <= (others => '0');
    sc_dt_e <= (others => '0');
    sc_a_e  <= (others => '0');
    sn_exp  <= (others => '0');
  end generate;

  -- SIMULATION ONLY.  A VHDL severity is a width in synthesis and not a
  -- check, so this catches the caller in a bench and not on the card.  It is
  -- still the right place for it: the violation is silent otherwise, and it
  -- produces a wrong number rather than a hang.
  -- synthesis translate_off
  guard : process(clk) is
  begin
    if rising_edge(clk) then
      if bsy = '1' and (st_ren = '1' or st_wen = '1' or se_wen = '1'
                        or cvw_en = '1') then
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
