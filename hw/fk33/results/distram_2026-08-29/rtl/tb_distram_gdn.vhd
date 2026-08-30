-- tb_distram_gdn.vhd -- TRACK DISTRAM, 2026-08-29.
--
-- THE SHADOW-DUT EQUIVALENCE BENCH.  sim/tb_gdn_block.vhd, copied, with a
-- SECOND gdn_block instance added: `shadow`, bound to gdn_block_ref, which is
-- rtl/gdn_block.vhd at the pinned SHA byte for byte.  Both instances are
-- driven from the SAME environment signals; only the DUT's outputs feed the
-- environment back, and the shadow's outputs go nowhere but the comparator.
--
-- WHY THAT IS SOUND, and it is the whole reason this shape was chosen over a
-- dump-and-diff.  The environment at cycle N is a function of the DUT outputs
-- at cycles < N.  If every output has matched up to N-1, the shadow has seen
-- byte-identical inputs, so a mismatch at N is a real divergence and is caught
-- ON THE CYCLE IT HAPPENS -- which makes this a CYCLE-EXACT check and not only
-- a value check.  A dump-and-diff cannot distinguish "same values, two cycles
-- later" from "identical".
--
-- Every one of gdn_block's 37 output ports is compared on every rising edge,
-- by name, and the first mismatch names the port and the cycle.  DELIBERATELY
-- NOT IN sim/: a new sim/tb_*.vhd is auto-discovered into the shared gate, and
-- this bench needs an RTL variant (gdn_block_ref) that is not in rtl/.
--
-- NO HARDWARE.  Simulation only.
-- Testbench for gdn_block, subsystem B's top level.
--
-- WHAT THIS CAN AND CANNOT CHECK.  Every unit inside gdn_block is already
-- bit-exact against a double-oracled C reference, individually.  What has
-- never been checked is the SEAMS, and every one of this week's four confirmed
-- defects lived in a seam, was numerically plausible, and was invisible to a
-- value comparison against a testbench that ran its producers maximally ahead.
-- So this testbench does not re-check arithmetic.  It checks the property that
-- would have caught all four:
--
--   THE BLOCK'S OUTPUT MUST BE BIT-IDENTICAL UNDER EVERY PRODUCER SKEW.
--
-- The y stream, the per-token y_exp, the final recurrent state and the final
-- state-exponent table are dumped to OUTFILE.  sim/run_gdn_block.sh runs the
-- same stimulus under a matrix of skews and diffs the dumps.  A latch that is
-- missing, a handshake that is not waited on, a port read across a span longer
-- than the producer holds it -- all of them are skew-dependent by definition,
-- and none of them is visible in any single run.
--
-- FIVE INDEPENDENT PRODUCERS, and the independence is the point.  The z gate,
-- the ssm_norm weight, the scalar group, the conv-weight exponent and the
-- exponent-store capture side each run from their own process with their own
-- skew generic.  gdn_emit_chain's testbench learned this the hard way: an
-- earlier version fed z and columns from ONE process, which coupled them, and
-- a COL_GAP sweep down to one column per cycle then reported ZERO refused
-- columns -- a clean, confident, meaningless result.
--
-- WHAT EACH SKEW GENERIC IS FOR, and what it broke when it was first turned on
-- is recorded in docs/debugging/2026-08-27_gdn-block-top-level.md:
--
--   Z_DELAY   cycles the z producer idles between heads.  0 makes it run
--             maximally ahead, which is exactly what masked defect B-2.  It
--             also probes the class-3 column path: a z producer slow enough
--             stalls the emit chain, col_ready falls, and gdn_recur_pipe --
--             which has no ready input -- LOSES columns rather than waiting.
--   W_MOVE    the ssm_norm producer scrambles w the cycle after w_taken.  A
--             block that reads w through rmsnorm_bf for all VAL_HEADS heads
--             without latching fails on every head but the first.
--   SC_MOVE   the scalar producer scrambles al/dt/a/b the cycle after
--             sc_taken.  gdn_scalar latches NOTHING at start (audit B-4) and
--             reads b_m/b_e at the very END of a ~30-state FSM, so an
--             unlatched top level fails here and only here.
--   CW_MOVE   the conv-weight exponent moves after cv_taken.  gdn_conv reads
--             cw_exp at S_FIN, hundreds of cycles after start (audit B-3b).
--   CAP_BUSY  the exponent store's capture side runs continuously against a
--             DIFFERENT layer while the block is working, so every rd_req has
--             a chance of colliding with a capture.  gdn_exp_capture drops
--             such a read with no acknowledgement of any kind (audit B-12);
--             a top level that pulses rd_req instead of holding it then
--             convolves with a stale (layer, segment)'s tap exponents.
--
-- THE STATE MEMORY IS REAL, NOT A STUB.  It is read AND written across the
-- run, and it carries between tokens, so the final contents are part of the
-- comparison.  A one-column misalignment in the write-back counters -- the
-- shape of defect B-1 -- shows up there and nowhere else.
--
-- AND `layer` IS NO LONGER HARDWIRED TO ZERO.  Until 2026-08-29 both
-- block-level benches drove `layer => 0`, which is structurally the same hole
-- that hid defect C1 in subsystem C: `attn_block`'s `vref_r` has no layer
-- dimension, one block is time-shared across every attention layer, and
-- `tb_attn_block` could not see it because it only ever ran layer 0.
--
-- ONE GDN BLOCK IS TIME-SHARED THE SAME WAY.  rtl/llama_top.vhd instantiates
-- exactly one `gdn_block` and sweeps `b_layer` across every GDN layer
-- (rtl/llama_top.vhd:2980), so anything the block retains across invocations
-- WITHOUT a layer index folds every layer into every other one.
--
-- THE PROPERTY THIS BENCH NOW CHECKS is non-interference:
--
--     A LAYER'S TOKEN SEQUENCE MUST COME OUT THE SAME WHETHER IT RUNS ALONE
--     OR INTERLEAVED TOKEN-BY-TOKEN WITH ANOTHER LAYER'S -- THE SAME y
--     STREAM, THE SAME y_exp, AND THE SAME FINAL STATE.
--
-- Phase A runs each layer's TOKENS tokens with nothing between them; layer
-- 0's phase is byte for byte what this bench did before, because every
-- stimulus function reduces to its old form at layer 0.  Phase B puts the
-- layer-qualified memories back where phase A started and runs the layers
-- ALTERNATING, L0, L1, L0, L1.  Every phase-B invocation must reproduce the
-- phase-A invocation with the SAME (layer, token), and the final state
-- regions must match what phase A left, region for region.
--
-- EVERY LAYER IS FED DIFFERENT NUMBERS, and that is the part that is easy to
-- get wrong.  An earlier version of this phase fed every layer identical
-- stimulus and compared the layers against each other.  That property is
-- BLIND to the defect it is for: with identical inputs, a register carried
-- across invocations holds, at layer 0's second token, exactly the value it
-- would have held in the solo run, so the fold cancels out of the comparison.
-- Per-layer stimulus plus a per-layer solo reference is what makes the
-- interleaving observable.
--
-- The external memories are layer-qualified HERE, in the bench, because
-- `gdn_block`'s st_*/se_* ports carry no layer index at all: they are
-- addressed by (head, col, group) only, so the memory OWNER is what has to
-- fold `layer` in.  That is a real gap in the port contract and rtl/llama_top
-- .vhd does NOT close it -- see docs/debugging/2026-08-29_b-layer-dimension.md
-- for the defect that follows.
--
-- WHAT THIS PROPERTY IS NOT, stated because a check whose floor is not
-- measured is not a measurement.  It is a NON-INTERFERENCE property, not a
-- value oracle: it compares the DUT against itself, so it can say that the
-- layers do not contaminate each other and it can never say the numbers are
-- right.  The value side is sim/tb_gdn_block_vec.vhd, which runs the block at
-- DUT_LAYER=1 against ref/gdn_block_vec.c with decoy captures in every layer
-- it is not running.  The two benches cover the two halves, and both are
-- needed: MEASURED 2026-08-29, `rd_layer => 0` is killed by the value oracle
-- at DUT_LAYER=1 and the store losing its layer dimension altogether is
-- killed here.  See docs/debugging/2026-08-29_b-layer-dimension.md.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;

entity tb_distram_gdn is
  generic(
    -- Shapes.  Small by default: the block is six units deep and one token at
    -- the shipping shape is ~30,000 cycles, which is minutes of GHDL per skew
    -- point.  The seams do not care how many heads there are.
    KEY_HEADS   : positive := 2;
    VAL_HEADS   : positive := 4;
    DIM         : positive := 32;
    -- One MORE than NLAYER: the CAP_BUSY collider needs a layer the DUT is
    -- not running, so that a collision can only DELAY the block's own read
    -- and never change what it reads.
    LAYERS      : positive := 3;
    -- How many GDN layers the interleaved phase cycles through.  1 disables
    -- the phase entirely and reduces this bench to what it was before
    -- 2026-08-29.  2 is the smallest value at which a fold is observable.
    NLAYER      : positive := 2;
    CONV_LANES  : positive := 4;
    -- The column issue rate, and therefore the emit chain's deadline.  At
    -- DIM/RECUR_LANES = 8 a head arrives over 8*DIM cycles; at 4 it arrives
    -- twice as fast, which is the setting that stresses gdn_head_emit's
    -- reduce-versus-arrival race.
    RECUR_LANES : positive := 4;
    RECUR_SLOTS : positive := 16;
    L2_LANES    : positive := 4;
    SILU_LANES  : positive := 8;
    RMS_LANES   : positive := 4;

    TOKENS   : integer := 2;
    -- Extra idle cycles per state column, passed straight to the DUT.  This
    -- is the axis that sets the emit chain's per-head deadline.
    -- Idle cycles between conv tap group requests, passed to the DUT.  This
    -- is the axis that stresses the STRAIGHT-THROUGH silu path: it moves
    -- gdn_conv's internal phase boundaries, so the instant e_seg is published
    -- and the instant the first output beat arrives both shift relative to
    -- the block's own sequencing and to every other producer.
    CV_GAP    : natural := 0;
    ISSUE_GAP : natural := 0;
    -- Idle cycles per value head; lengthens the arrival period by exactly
    -- HEAD_GAP and so measures the emit chain deadline to one cycle.
    HEAD_GAP  : natural := 0;

    -- ---- the skew axes ---------------------------------------------------
    Z_DELAY  : integer := 0;
    W_MOVE   : boolean := false;
    SC_MOVE  : boolean := false;
    CW_MOVE  : boolean := false;
    CAP_BUSY : boolean := false;

    STRICT   : boolean := true;
    -- Microseconds between progress reports; 0 disables.  A run that produces
    -- no output is ambiguous between wedged and slow, and that ambiguity has
    -- cost real time on this project's testbenches more than once.
    HEARTBEAT_US : integer := 0;

    -- ---- what the four status flags MUST be on this stimulus -------------
    --
    -- These were PRINTED, not asserted, from the day this bench was written,
    -- so the regression could not fail on any of them.  That is the third
    -- instance of a shape already fixed twice in subsystem B: gdn_silu and
    -- rmsnorm_bf both had oracles whose result was reported rather than
    -- gated, and the flagship mutation in the second was bit-exact green
    -- while the output was 1.7e10 LSB wrong.
    --
    -- All four are FALSE, and that is a claim about the stimulus, derived
    -- rather than observed:
    --
    --   err_conv  gdn_conv's e_seg leaves int8.  m12() bounds every conv
    --             mantissa at +/-2047, so |acc| <= 4*2047^2 < 2^24 and
    --             sh_seg <= 10; e_ref is 8..10 and cw_exp is 12..14, so
    --             e_seg lands in roughly [10, 24].  int8 is never at risk.
    --   err_g     gdn_scalar hit the -16 clamp on g.  a_m is -|m12| at
    --             a_e = 12, so |a| <= 0.5; al and dt are m12 at exp 12, so
    --             |al+dt| <= 1.0 and softplus(.) <= 1.32.  |g| <= 0.66,
    --             twenty-four times inside the clamp.
    --   err_se    a state-column exponent leaves int8.  MEASURED, not
    --             derived: the semem initialiser is a constant 10 and the
    --             stimulus is narrow-band, so se_new stays near it.
    --   y_sat     site 13's sat16 fired.  MEASURED.
    --
    -- They are generics rather than literals so that a deliberately
    -- out-of-range stimulus can assert the OTHER polarity and prove the flag
    -- is reachable, which is the check that stops "expect 0" from being a
    -- check that can never fail.
    EXP_ERR_CONV : boolean := false;
    EXP_ERR_G    : boolean := false;
    EXP_ERR_SE   : boolean := false;
    EXP_Y_SAT    : boolean := false;

    OUTFILE  : string  := "gdn_block_out.txt"
  );
end entity;

architecture sim of tb_distram_gdn is

  constant KCONV  : integer := 4;
  constant QCH    : integer := KEY_HEADS*DIM;
  constant VCH    : integer := VAL_HEADS*DIM;
  constant NB_R   : integer := DIM/RECUR_LANES;
  constant NCOL   : integer := VAL_HEADS*DIM;
  constant NSTW   : integer := VAL_HEADS*DIM*NB_R;   -- state words per LAYER

  -- Phase A: TOKENS invocations at layer 0.  Phase B: NLAYER*TOKENS more,
  -- alternating layer by layer.  Both phases are one simulation, deliberately:
  -- the DUT is NOT reset between them, so anything it carries internally
  -- carries across the boundary, which is the whole point.
  function ilv_n return integer is
  begin
    if NLAYER > 1 then return NLAYER*TOKENS; else return 0; end if;
  end function;
  constant NSOLO  : integer := NLAYER*TOKENS;
  constant NILV   : integer := ilv_n;
  constant NINV   : integer := NSOLO + NILV;
  constant YPB    : integer := VAL_HEADS*DIM;        -- y elements per token
  constant NY     : integer := NINV*YPB;

  -- Which layer and which per-layer token index invocation `iv` is.
  function lay_of(iv : integer) return integer is
  begin
    if iv < NSOLO then return iv / TOKENS;
    else               return (iv - NSOLO) mod NLAYER; end if;
  end function;
  function ltok_of(iv : integer) return integer is
  begin
    if iv < NSOLO then return iv mod TOKENS;
    else               return (iv - NSOLO) / NLAYER; end if;
  end function;
  -- The SOLO invocation that an interleaved one must reproduce.
  function solo_of(iv : integer) return integer is
  begin
    return lay_of(iv)*TOKENS + ltok_of(iv);
  end function;

  -- Deterministic stimulus.  A function of the index and NOTHING else, so
  -- that changing a skew generic cannot change a single input value.  That is
  -- the whole basis of the cross-skew comparison.
  function hsh(a, b : integer) return unsigned is
    variable x : unsigned(31 downto 0);
    variable t : unsigned(63 downto 0);
  begin
    t := to_unsigned(a mod 1048576, 32) * to_unsigned(1103515245, 32);
    x := t(31 downto 0) + to_unsigned((b mod 100000) * 12345, 32);
    x := x xor shift_right(x, 15);
    t := x * to_unsigned(668265261, 32);
    x := t(31 downto 0);
    x := x xor shift_right(x, 13);
    return x;
  end function;

  -- Mantissas are kept to +-2047 on purpose.  The conv accumulates K products
  -- of two int16s; at full scale that is a saturating segment and every
  -- comparison would then be a comparison of clamps rather than of arithmetic.
  function m12(a, b : integer) return signed is
  begin
    return to_signed(to_integer(hsh(a, b)(11 downto 0)) - 2048, 16);
  end function;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal running : boolean := true;

  signal blk_start : std_logic := '0';
  signal tk0       : std_logic := '1';
  signal busy      : std_logic;
  signal tok       : integer := 0;   -- per-LAYER token index
  signal inv       : integer := 0;   -- global invocation index, 0 .. NINV-1

  signal seq_rst   : std_logic := '0';
  -- The two capture sources are arbitrated on the way in rather than sharing
  -- a signal: two drivers on one signal elaborate in ghdl with no line number,
  -- which has cost real time on this project twice.
  signal dr_req, cb_req : std_logic := '0';
  signal dr_layer, cb_layer : integer := 0;
  signal dr_seg,   cb_seg   : integer := 0;
  signal dr_exp,   cb_exp   : signed(7 downto 0) := (others => '0');
  signal cap_req   : std_logic;
  -- These carry the DUT's own port subtypes: ghdl rejects a plain integer
  -- actual against a constrained integer port outright.
  signal cap_layer : integer range 0 to LAYERS-1;
  signal cap_seg   : integer range 0 to 2;
  signal cap_exp   : signed(7 downto 0);
  signal cap_ready : std_logic;

  signal cv_seg    : integer range 0 to 2;
  signal cv_ren    : std_logic;
  signal cv_grp    : integer range 0 to VCH/CONV_LANES-1;
  signal cv_x      : std_logic_vector(KCONV*CONV_LANES*16-1 downto 0) := (others => '0');
  signal cv_w      : std_logic_vector(KCONV*CONV_LANES*16-1 downto 0) := (others => '0');
  signal cv_cw_exp : signed(7 downto 0) := to_signed(12, 8);
  signal cv_taken  : std_logic;
  signal eseg_taken : std_logic;

  signal sc_head  : integer range 0 to VAL_HEADS-1;
  signal sc_al_m, sc_dt_m, sc_a_m, sc_b_m : signed(15 downto 0) := (others => '0');
  signal sc_al_e, sc_dt_e, sc_a_e, sc_b_e : signed(7 downto 0)  := (others => '0');
  signal sc_taken : std_logic;

  signal st_ren   : std_logic;
  signal st_rhead : integer range 0 to VAL_HEADS-1;
  signal st_rcol  : integer range 0 to DIM-1;
  signal st_rgrp  : integer range 0 to NB_R-1;
  signal st_rdata : std_logic_vector(RECUR_LANES*16-1 downto 0);
  signal st_wen   : std_logic;
  signal st_whead : integer range 0 to VAL_HEADS-1;
  signal st_wcol  : integer range 0 to DIM-1;
  signal st_wgrp  : integer range 0 to NB_R-1;
  signal st_wdata : std_logic_vector(RECUR_LANES*16-1 downto 0);

  signal se_rhead : integer range 0 to VAL_HEADS-1;
  signal se_rcol  : integer range 0 to DIM-1;
  signal se_rdata : signed(7 downto 0);
  signal se_wen   : std_logic;
  signal se_whead : integer range 0 to VAL_HEADS-1;
  signal se_wcol  : integer range 0 to DIM-1;
  signal se_wdata : signed(7 downto 0);

  signal w_mant : std_logic_vector(DIM*16-1 downto 0) := (others => '0');
  signal w_exp  : integer := 12;
  signal w_taken : std_logic;
  signal z_mant : std_logic_vector(DIM*16-1 downto 0) := (others => '0');
  signal z_exp  : signed(7 downto 0) := to_signed(12, 8);
  signal z_valid : std_logic := '0';
  signal z_ready : std_logic;

  signal y_valid : std_logic;
  signal y_mant  : signed(15 downto 0);
  signal y_last  : std_logic;
  signal y_exp   : signed(7 downto 0);
  signal blk_done : std_logic;

  signal err_conv, err_g, err_se, y_sat : std_logic;
  signal dbg_col_ready, dbg_col_drop : std_logic;

  -- ---- memory models, LAYER-QUALIFIED ------------------------------------
  -- gdn_block's st_*/se_* ports carry (head, col, group) and NO layer, so the
  -- layer fold is the memory owner's job.  It is done here; rtl/llama_top.vhd
  -- does not do it.  Every layer's region is initialised IDENTICALLY, which
  -- is what makes "layer l reproduces layer 0" a well-posed property.
  type stmem_t is array (0 to NLAYER*NSTW-1) of std_logic_vector(RECUR_LANES*16-1 downto 0);
  type semem_t is array (0 to NLAYER*NCOL-1) of signed(7 downto 0);
  -- Initialised in the declaration, NOT from the driver process: the memory
  -- process is the only driver of these, and a second one elaborates in ghdl
  -- with no line number at all.  A deliberately NON-zero start state, because
  -- an all-zero state hides every alignment fault in the write-back counters.
  function stmem_init return stmem_t is
    variable m : stmem_t;
  begin
    for l in 0 to NLAYER-1 loop
      for i in 0 to NSTW-1 loop
        for k in 0 to RECUR_LANES-1 loop
          -- Layer 0's region is EXACTLY what this bench always had, so the
          -- solo layer-0 phase is byte for byte the run it was before the
          -- layer axis existed.  Every other layer gets a DIFFERENT resident
          -- state, for the reason given at the stimulus functions.
          m(l*NSTW + i)((k+1)*16-1 downto k*16) :=
            std_logic_vector(m12(i, k+1+l));
        end loop;
      end loop;
    end loop;
    return m;
  end function;
  signal stmem : stmem_t := stmem_init;
  signal semem : semem_t := (others => to_signed(10, 8));
  -- Which layer the DUT is running.  Held for the whole invocation by the
  -- driver, and it is what qualifies every memory access below.
  signal cur_lay : integer range 0 to NLAYER-1 := 0;
  -- Pulsed by the driver between the two phases: puts both memories back to
  -- the state phase A started from, for EVERY layer.
  signal mem_rst : std_logic := '0';
  signal st_rq : std_logic_vector(RECUR_LANES*16-1 downto 0) := (others => '0');

  -- ---- collected output --------------------------------------------------
  type yarr_t is array (0 to NY-1) of integer;
  type tarr_t is array (0 to NINV-1) of integer;
  signal y_got : yarr_t := (others => 0);
  signal y_idx : integer := 0;
  signal ye_got : tarr_t := (others => 0);
  signal yn_got : tarr_t := (others => 0);
  signal blk_got : integer := 0;
  signal all_done : boolean := false;

  -- registered conv tap address, so cv_x/cv_w land one cycle after cv_ren,
  -- which is the block's documented contract for that port.
  signal cvq_seg : integer := 0;
  signal cvq_grp : integer := 0;
  signal cvq_tok : integer := 0;
  signal cvq_lay : integer := 0;

  -- THE CYCLE COUNT.  The whole reason the straight-through form exists is
  -- the schedule, so the block's cost per token is measured rather than
  -- argued.  Counted from the `start` edge to `busy` falling, which is
  -- exactly one layer's work for one token.
  signal cyc      : integer := 0;
  signal tok_cyc  : tarr_t := (others => 0);
  signal counting : boolean := false;

  signal w_dirty  : boolean := false;
  signal sc_dirty : boolean := false;
  signal sc_head_q : integer := 0;
  signal cw_dirty : boolean := false;
  signal cv_seg_q : integer range 0 to 2 := 0;

  -- ---- TRACK DISTRAM: the shadow's outputs, and the comparison state ------
  signal s_busy, s_cap_ready, s_cv_ren, s_cv_taken, s_eseg_taken,
         s_sc_taken, s_st_ren, s_st_wen, s_se_wen, s_w_taken, s_z_ready,
         s_y_valid, s_y_last, s_done, s_err_conv, s_err_g, s_err_se,
         s_y_sat, s_dbg_col_ready, s_dbg_col_drop : std_logic;
  signal s_cv_seg   : integer range 0 to 2;
  signal s_cv_grp   : integer range 0 to (VAL_HEADS*DIM)/CONV_LANES-1;
  signal s_sc_head  : integer range 0 to VAL_HEADS-1;
  signal s_st_rhead, s_st_whead, s_se_rhead, s_se_whead
                    : integer range 0 to VAL_HEADS-1;
  signal s_st_rcol, s_st_wcol, s_se_rcol, s_se_wcol
                    : integer range 0 to DIM-1;
  signal s_st_rgrp, s_st_wgrp : integer range 0 to DIM/RECUR_LANES-1;
  signal s_st_wdata : std_logic_vector(RECUR_LANES*16-1 downto 0);
  signal s_se_wdata : signed(7 downto 0);
  signal s_y_mant   : signed(15 downto 0);
  signal s_y_exp    : signed(7 downto 0);

  signal cmp_cyc    : integer := 0;
  signal cmp_fail   : integer := 0;
  signal cmp_checks : integer := 0;
  -- NON-TRIVIALITY.  A comparator that runs while the block is idle proves
  -- nothing, so the live cycles are counted separately and asserted non-zero.
  signal cmp_live   : integer := 0;

begin

  clk <= (not clk) after 0.5 ns when running else '0';

  cap_req   <= dr_req or cb_req;
  cap_layer <= dr_layer when dr_req = '1' else cb_layer;
  cap_seg   <= dr_seg   when dr_req = '1' else cb_seg;
  cap_exp   <= dr_exp   when dr_req = '1' else cb_exp;

  dut : entity work.gdn_block
    generic map ( KEY_HEADS => KEY_HEADS, VAL_HEADS => VAL_HEADS, DIM => DIM,
                  KCONV => KCONV, LAYERS => LAYERS,
                  CONV_LANES => CONV_LANES, RECUR_LANES => RECUR_LANES,
                  RECUR_SLOTS => RECUR_SLOTS, L2_LANES => L2_LANES,
                  SILU_LANES => SILU_LANES, RMS_LANES => RMS_LANES,
                  Q => 12, EPS => 1.0e-6, SP_Q => 18,
                  CV_GAP => CV_GAP,
                  ISSUE_GAP => ISSUE_GAP, HEAD_GAP => HEAD_GAP,
                  STRICT_PRODUCER => STRICT )
    port map ( clk => clk, rst => rst,
               start => blk_start, layer => cur_lay, tk0 => tk0,
               busy => busy,
               seq_rst => seq_rst,
               cap_req => cap_req, cap_layer => cap_layer, cap_seg => cap_seg,
               cap_exp => cap_exp, cap_ready => cap_ready,
               cv_seg => cv_seg, cv_ren => cv_ren, cv_grp => cv_grp,
               cv_x => cv_x, cv_w => cv_w, cv_cw_exp => cv_cw_exp,
               cv_taken => cv_taken, eseg_taken => eseg_taken,
               sc_head => sc_head,
               sc_al_m => sc_al_m, sc_al_e => sc_al_e,
               sc_dt_m => sc_dt_m, sc_dt_e => sc_dt_e,
               sc_a_m => sc_a_m, sc_a_e => sc_a_e,
               sc_b_m => sc_b_m, sc_b_e => sc_b_e, sc_taken => sc_taken,
               st_ren => st_ren, st_rhead => st_rhead, st_rcol => st_rcol,
               st_rgrp => st_rgrp, st_rdata => st_rdata,
               st_wen => st_wen, st_whead => st_whead, st_wcol => st_wcol,
               st_wgrp => st_wgrp, st_wdata => st_wdata,
               se_rhead => se_rhead, se_rcol => se_rcol, se_rdata => se_rdata,
               se_wen => se_wen, se_whead => se_whead, se_wcol => se_wcol,
               se_wdata => se_wdata,
               w_mant => w_mant, w_exp => w_exp, w_taken => w_taken,
               z_mant => z_mant, z_exp => z_exp,
               z_valid => z_valid, z_ready => z_ready,
               y_valid => y_valid, y_mant => y_mant, y_last => y_last,
               y_exp => y_exp, done => blk_done,
               err_conv => err_conv, err_g => err_g, err_se => err_se,
               y_sat => y_sat,
               dbg_col_ready => dbg_col_ready, dbg_col_drop => dbg_col_drop );

  -- ======================= memory models ================================

  st_rdata <= st_rq;

  stmem_p : process(clk)
    variable a : integer;
  begin
    if rising_edge(clk) then
      if mem_rst = '1' then
        stmem <= stmem_init;
      else
        if st_wen = '1' then
          a := cur_lay*NSTW + st_whead*DIM*NB_R + st_wcol*NB_R + st_wgrp;
          stmem(a) <= st_wdata;
        end if;
        if st_ren = '1' then
          a := cur_lay*NSTW + st_rhead*DIM*NB_R + st_rcol*NB_R + st_rgrp;
          st_rq <= stmem(a);
        end if;
      end if;
    end if;
  end process;

  -- Combinational read, which is what gdn_block's port contract says.  The
  -- table is VAL_HEADS*DIM bytes; at 9B that is 4 KiB of distributed RAM.
  se_rdata <= semem(cur_lay*NCOL + se_rhead*DIM + se_rcol);

  semem_p : process(clk)
  begin
    if rising_edge(clk) then
      if mem_rst = '1' then
        semem <= (others => to_signed(10, 8));
      elsif se_wen = '1' then
        semem(cur_lay*NCOL + se_whead*DIM + se_wcol) <= se_wdata;
      end if;
    end if;
  end process;

  -- ======================= producer 1: conv taps ========================
  -- Registered address, combinational data: a plain BRAM.  The values are a
  -- function of (token, segment, group, tap, lane) only.
  cvaddr_p : process(clk)
  begin
    if rising_edge(clk) then
      cvq_seg <= cv_seg;
      cvq_grp <= cv_grp;
      cvq_tok <= tok;
      cvq_lay <= cur_lay;
    end if;
  end process;

  -- EVERY LAYER GETS DIFFERENT NUMBERS, and that is load bearing rather than
  -- decorative.  If layer 1's inputs equalled layer 0's, then a register the
  -- block carried across invocations without a layer index would hold, at
  -- layer 0's second token, exactly the value it would have held in the solo
  -- run -- and the interleaved comparison would pass on a design that folds.
  -- The stimulus therefore depends on (layer, token), and the multiplier is
  -- chosen so that layer 0 reproduces the pre-2026-08-29 stimulus exactly.
  cvdata_p : process(cvq_seg, cvq_grp, cvq_tok, cvq_lay)
    variable xv, wv : std_logic_vector(KCONV*CONV_LANES*16-1 downto 0);
    variable b : integer;
  begin
    for t in 0 to KCONV-1 loop
      for ln in 0 to CONV_LANES-1 loop
        b := (t*CONV_LANES + ln)*16;
        xv(b+15 downto b) := std_logic_vector(
          m12(cvq_lay*1000003 + cvq_tok*7919 + cvq_seg*104729 + cvq_grp*31,
              t*17 + ln));
        -- The conv weights are per (LAYER, segment, channel, tap) and do NOT
        -- depend on the token; they are model weights, and a model weight is
        -- per layer.
        wv(b+15 downto b) := std_logic_vector(
          m12(cvq_lay*524287 + cvq_seg*65537 + cvq_grp*13, t*101 + ln + 5));
      end loop;
    end loop;
    cv_x <= xv;
    cv_w <= wv;
  end process;

  -- The conv-weight exponent.  CW_MOVE scrambles it the cycle after cv_taken,
  -- which gdn_conv would otherwise read at S_FIN (audit B-3b).
  cw_p : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        cw_dirty <= false;
      else
        cv_seg_q <= cv_seg;
        if cv_taken = '1' then
          cw_dirty <= true;
        elsif cv_seg /= cv_seg_q or busy = '0' then
          cw_dirty <= false;
        end if;
      end if;
    end if;
  end process;
  -- Per SEGMENT, not constant: a constant makes gdn_conv's cw_exp latch
  -- untestable and hides whether cv_seg is published before the value is
  -- sampled.  The producer reacts to cv_seg one cycle late, like a register
  -- file, which is exactly what the block's port contract must tolerate.
  cv_cw_exp <= to_signed(-99, 8) when (CW_MOVE and cw_dirty)
               else to_signed(12 + cv_seg_q, 8);

  -- ======================= producer 2: scalar path ======================
  -- Combinational on sc_head.  With SC_MOVE the values are scrambled from the
  -- cycle after sc_taken until the block asks for the next head, which is the
  -- exact window gdn_scalar reads b_m/b_e in (audit B-4: it latches nothing at
  -- start and reads b at the very end of a ~30-state FSM).
  sc_p : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        sc_dirty <= false; sc_head_q <= 0;
      else
        sc_head_q <= sc_head;
        if sc_taken = '1' then
          sc_dirty <= true;
        elsif sc_head /= sc_head_q then
          sc_dirty <= false;
        end if;
      end if;
    end if;
  end process;

  -- A REGISTERED source: the index is sc_head_q, one cycle behind the port,
  -- which is what a register file or a BRAM gives you.  A combinational model
  -- here would let the block get away with sampling on the very next edge.
  scdrv : process(sc_head_q, sc_dirty, tok, cur_lay)
    variable ix : integer;
  begin
    if SC_MOVE and sc_dirty then ix := 987654;
    else ix := cur_lay*4096 + tok*64 + sc_head_q; end if;
    sc_al_m <= m12(ix*31 + 1, 2);
    sc_dt_m <= m12(ix*31 + 2, 3);
    -- 1.1(b): ssm_a is -exp(A_log), so a is always <= 0 and the decay never
    -- amplifies.  Feeding a positive one would exercise a case the model
    -- cannot produce.
    sc_a_m  <= -abs(m12(ix*31 + 3, 4));
    sc_b_m  <= m12(ix*31 + 4, 5);
    sc_al_e <= to_signed(12, 8);
    sc_dt_e <= to_signed(12, 8);
    sc_a_e  <= to_signed(12, 8);
    sc_b_e  <= to_signed(12, 8);
  end process;

  -- ======================= producer 3: the z gate =======================
  -- z is indexed by the PER-LAYER token index, not by a free-running counter.
  -- Every layer must be offered the same gate vectors in the same order, or
  -- the cross-layer comparison compares two different stimuli and means
  -- nothing.  The process still runs on its own, with its own Z_DELAY skew,
  -- and never looks at the DUT except through z_ready.
  zgen : process
    variable h  : integer := 0;
    variable lt : integer := 0;
  begin
    z_valid <= '0';
    wait until rst = '0';
    for iv in 0 to NINV-1 loop
      lt := ltok_of(iv);
      for hh in 0 to VAL_HEADS-1 loop
        for i in 1 to Z_DELAY loop
          wait until rising_edge(clk);
        end loop;
        h := lay_of(iv)*4096 + lt*VAL_HEADS + hh;
        for j in 0 to DIM-1 loop
          z_mant((j+1)*16-1 downto j*16) <= std_logic_vector(m12(h*1013 + 3, j));
        end loop;
        z_exp   <= to_signed(12, 8);
        z_valid <= '1';
        loop
          wait until rising_edge(clk);
          exit when z_ready = '1';
        end loop;
        z_valid <= '0';
      end loop;
    end loop;
    wait;
  end process;

  -- ======================= producer 4: ssm_norm weight ==================
  wgen : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        w_dirty <= false;
      else
        if w_taken = '1' then
          w_dirty <= true;
        elsif busy = '0' then
          w_dirty <= false;
        end if;
      end if;
    end if;
  end process;

  -- ssm_norm is a per-LAYER weight, so the model gives each layer its own.
  -- 4242 + 0 is what layer 0 always had.
  wdrv : process(w_dirty, cur_lay)
  begin
    for j in 0 to DIM-1 loop
      if W_MOVE and w_dirty then
        w_mant((j+1)*16-1 downto j*16) <= std_logic_vector(m12(999999, j));
      else
        w_mant((j+1)*16-1 downto j*16) <=
          std_logic_vector(m12(4242 + cur_lay*77, j));
      end if;
    end loop;
  end process;

  -- ======================= producer 5: the capture side =================
  -- Free-running captures against a layer NO PHASE RUNS -- LAYERS is one
  -- larger than NLAYER for exactly this -- so the block's own tap exponents
  -- never move; only the collisions do.
  capbusy : process
  begin
    if not CAP_BUSY then wait; end if;
    wait until rst = '0';
    loop
      for i in 1 to 37 loop wait until rising_edge(clk); end loop;
      exit when all_done;
      if dr_req = '0' then
        cb_layer <= LAYERS-1;
        cb_seg   <= 1;
        cb_exp   <= to_signed(9, 8);
        cb_req   <= '1';
        wait until rising_edge(clk);
        cb_req   <= '0';
      end if;
    end loop;
    wait;
  end process;

  cyccnt : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        cyc <= 0; counting <= false;
      else
        if blk_start = '1' then
          cyc <= 0; counting <= true;
        elsif counting then
          if busy = '0' and cyc > 1 then
            counting <= false;
            tok_cyc(inv) <= cyc;
          else
            cyc <= cyc + 1;
          end if;
        end if;
      end if;
    end if;
  end process;

  -- ======================= collector ====================================
  collect : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        y_idx <= 0; blk_got <= 0;
      else
        if y_valid = '1' then
          assert blk_got < NINV and y_idx < NY
            report "tb_gdn_block: more output than the run expects"
            severity failure;
          y_got(y_idx) <= to_integer(y_mant);
          y_idx <= y_idx + 1;
          ye_got(blk_got) <= to_integer(y_exp);
          yn_got(blk_got) <= yn_got(blk_got) + 1;
        end if;
        if blk_done = '1' then
          blk_got <= blk_got + 1;
        end if;
      end if;
    end if;
  end process;

  heartbeat : process
  begin
    if HEARTBEAT_US = 0 then wait; end if;
    loop
      wait for HEARTBEAT_US * 1 us;
      exit when all_done;
      report "tb_gdn_block: alive, token " & integer'image(tok)
           & " y " & integer'image(y_idx) & " of " & integer'image(NY);
    end loop;
    wait;
  end process;

  -- ======================= the driver ===================================
  drive : process
    variable l : line;
    file fh : text;
    -- The regions phase A left behind.  Variables, not signals: they are read
    -- and written only inside this process, and a second driver on a signal
    -- of this size elaborates in ghdl with no line number.
    variable st_ref : stmem_t;
    variable se_ref : semem_t;
    variable nbad   : integer := 0;
    variable ia, ib : integer;

    -- One capture, with the handshake HELD.  gdn_exp_capture drops a read
    -- that collides with a capture and says nothing (audit B-12).
    procedure do_cap(lay : integer; seg : integer; ex : integer) is
    begin
      loop
        wait until rising_edge(clk);
        exit when cap_ready = '1' and cap_req = '0';
      end loop;
      dr_layer <= lay;
      dr_seg   <= seg;
      dr_exp   <= to_signed(ex, 8);
      dr_req   <= '1';
      wait until rising_edge(clk);
      dr_req   <= '0';
      loop
        wait until rising_edge(clk);
        exit when cap_ready = '1';
      end loop;
    end procedure;

    -- One invocation: one token of one layer.  The stimulus is a function of
    -- the PER-LAYER token index only, never of the layer or of the global
    -- invocation number, which is what makes the cross-layer comparison a
    -- comparison of the DUT rather than of two different inputs.
    procedure run_inv(iv : integer) is
      variable lt : integer;
    begin
      lt := ltok_of(iv);
      inv     <= iv;
      cur_lay <= lay_of(iv);
      tok     <= lt;
      if lt = 0 then tk0 <= '1'; else tk0 <= '0'; end if;
      wait until rising_edge(clk);

      -- One capture per segment per token: that is what advances the conv
      -- state FIFO and what makes tvalid grow 0001 -> 0011 -> 0111 -> 1111.
      for s in 0 to 2 loop
        do_cap(lay_of(iv), s, 8 + (lt + s + lay_of(iv)) mod 3);
      end loop;

      blk_start <= '1';
      wait until rising_edge(clk);
      blk_start <= '0';
      wait until rising_edge(clk);
      loop
        wait until rising_edge(clk);
        exit when busy = '0';
      end loop;
    end procedure;
  begin
    rst <= '1';
    for i in 1 to 8 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);

    -- Sequence boundary: clear the tap-validity counters.  gdn_exp_capture
    -- requires the unit to be idle for this, and says so with an assertion.
    seq_rst <= '1';
    wait until rising_edge(clk);
    seq_rst <= '0';
    wait until rising_edge(clk);

    -- ---- PHASE A: each layer's whole token sequence, ALONE.  Layer 0's
    -- phase is byte for byte what this bench did before the layer axis
    -- existed: the stimulus functions all reduce to their old form at layer 0.
    for lp in 0 to NLAYER-1 loop
      if lp > 0 then
        -- A fresh sequence for this layer.  seq_rst clears gdn_exp_capture's
        -- tap-validity counters for every entry, which is what it does in the
        -- real design too -- a sequence boundary is not per layer.
        seq_rst <= '1';
        wait until rising_edge(clk);
        seq_rst <= '0';
        wait until rising_edge(clk);
      end if;
      for t in 0 to TOKENS-1 loop
        run_inv(lp*TOKENS + t);
      end loop;
    end loop;

    -- What each layer leaves behind when nothing else runs between its
    -- tokens.  This is the reference the interleaved phase must reproduce.
    wait until rising_edge(clk);
    st_ref := stmem;
    se_ref := semem;

    -- ---- PHASE B: the same token sequence for each of NLAYER layers,
    -- INTERLEAVED token by token.  The memories go back to where phase A
    -- started; the DUT deliberately does NOT, because what it carries across
    -- the boundary is the thing under test.
    if NLAYER > 1 then
      mem_rst <= '1';
      wait until rising_edge(clk);
      mem_rst <= '0';
      wait until rising_edge(clk);
      seq_rst <= '1';
      wait until rising_edge(clk);
      seq_rst <= '0';
      wait until rising_edge(clk);
      for k in 0 to NILV-1 loop
        run_inv(NSOLO + k);
      end loop;
    end if;

    for i in 1 to 16 loop wait until rising_edge(clk); end loop;
    all_done <= true;

    -- ---- checks ---------------------------------------------------------
    assert y_idx = NY
      report "tb_gdn_block: expected " & integer'image(NY)
           & " output elements, got " & integer'image(y_idx)
      severity failure;
    for t in 0 to NINV-1 loop
      assert yn_got(t) = VAL_HEADS*DIM
        report "tb_gdn_block: invocation " & integer'image(t) & " emitted "
             & integer'image(yn_got(t)) & " elements, expected "
             & integer'image(VAL_HEADS*DIM)
        severity failure;
    end loop;
    assert dbg_col_drop = '0'
      report "tb_gdn_block: gdn_recur_pipe offered a column that "
           & "gdn_emit_chain refused.  That column is LOST, not delayed."
      severity failure;
    for t in 0 to NINV-1 loop
      report "tb_gdn_block: CYCLES invocation " & integer'image(t)
           & " (layer " & integer'image(lay_of(t)) & " token "
           & integer'image(ltok_of(t)) & ") = " & integer'image(tok_cyc(t));
    end loop;
    report "tb_gdn_block: err_conv=" & std_logic'image(err_conv)
         & " err_g=" & std_logic'image(err_g)
         & " err_se=" & std_logic'image(err_se)
         & " y_sat=" & std_logic'image(y_sat);

    -- ---- and the same four, GATED.  See the generics for why each is
    -- false on this stimulus.  Printed, they were decoration: mutation
    -- testing cannot catch a check that cannot fail, because mutating what
    -- it watches changes nothing.
    assert (err_conv = '1') = EXP_ERR_CONV
      report "tb_gdn_block: err_conv is " & std_logic'image(err_conv)
           & ", expected " & boolean'image(EXP_ERR_CONV)
           & ".  err_conv is gdn_conv reporting a segment exponent outside "
           & "int8, and this stimulus bounds every conv mantissa at +/-2047."
      severity failure;
    assert (err_g = '1') = EXP_ERR_G
      report "tb_gdn_block: err_g is " & std_logic'image(err_g)
           & ", expected " & boolean'image(EXP_ERR_G)
           & ".  err_g is gdn_scalar hitting the -16 clamp on g, and this "
           & "stimulus holds |a| <= 0.5 and |alpha+dt| <= 1."
      severity failure;
    assert (err_se = '1') = EXP_ERR_SE
      report "tb_gdn_block: err_se is " & std_logic'image(err_se)
           & ", expected " & boolean'image(EXP_ERR_SE)
           & ".  err_se is gdn_recur_pipe reporting a state-column exponent "
           & "outside int8."
      severity failure;
    assert (y_sat = '1') = EXP_Y_SAT
      report "tb_gdn_block: y_sat is " & std_logic'image(y_sat)
           & ", expected " & boolean'image(EXP_Y_SAT)
           & ".  y_sat is site 13's sat16 firing on the whole-token "
           & "renormalization."
      severity failure;

    -- ---- THE LAYER PROPERTY ---------------------------------------------
    -- Non-interference: layer 0's tokens must come out the same whether they
    -- run alone (phase A) or interleaved with another layer's (phase B), and
    -- every other layer must reproduce layer 0 exactly, because every layer
    -- is fed the same stimulus against its own memory region.
    --
    -- This is the check the C1-shaped defect fails.  If gdn_block ever
    -- retains anything across invocations that ought to be per-layer, phase
    -- B's layer-0 tokens see layer 1's residue and stop matching phase A.
    if NLAYER > 1 then
      nbad := 0;
      for k in 0 to NILV-1 loop
        ia := (NSOLO + k) * YPB;          -- interleaved block
        ib := solo_of(NSOLO + k) * YPB;   -- the SAME (layer, token), alone
        for j in 0 to YPB-1 loop
          if y_got(ia + j) /= y_got(ib + j) then
            if nbad = 0 then
              report "tb_gdn_block: LAYER FOLD.  interleaved invocation "
                   & integer'image(NSOLO + k) & " (layer "
                   & integer'image(lay_of(NSOLO + k)) & " token "
                   & integer'image(ltok_of(NSOLO + k)) & ") element "
                   & integer'image(j) & " is " & integer'image(y_got(ia + j))
                   & ", the same layer and token running ALONE gave "
                   & integer'image(y_got(ib + j))
                severity note;
            end if;
            nbad := nbad + 1;
          end if;
        end loop;
        assert ye_got(NSOLO + k) = ye_got(solo_of(NSOLO + k))
          report "tb_gdn_block: LAYER FOLD.  interleaved invocation "
               & integer'image(NSOLO + k) & " y_exp "
               & integer'image(ye_got(NSOLO + k)) & ", alone it was "
               & integer'image(ye_got(solo_of(NSOLO + k)))
          severity failure;
      end loop;
      assert nbad = 0
        report "tb_gdn_block: LAYER FOLD -- " & integer'image(nbad) & " of "
             & integer'image(NILV*YPB) & " interleaved y elements differ "
             & "from the SAME layer and token run alone.  One gdn_block is "
             & "time-shared across every GDN layer in rtl/llama_top.vhd, so "
             & "state without a layer index folds every layer into every "
             & "other one."
        severity failure;

      -- and the OTHER output: the state each layer leaves behind.
      nbad := 0;
      for i in 0 to NLAYER*NSTW-1 loop
        if stmem(i) /= st_ref(i) then nbad := nbad + 1; end if;
      end loop;
      for i in 0 to NLAYER*NCOL-1 loop
        if semem(i) /= se_ref(i) then nbad := nbad + 1; end if;
      end loop;
      assert nbad = 0
        report "tb_gdn_block: LAYER FOLD in the STATE -- "
             & integer'image(nbad) & " words of the interleaved per-layer "
             & "state regions differ from what those layers left when each "
             & "ran alone.  A token whose y is right and whose state is wrong "
             & "has corrupted every token after it."
        severity failure;
      report "tb_gdn_block: layer non-interference OK, " & integer'image(NILV)
           & " interleaved invocations across " & integer'image(NLAYER)
           & " layers reproduce their own solo runs exactly";
    end if;

    -- ---- the dump that the cross-skew diff compares ---------------------
    file_open(fh, OUTFILE, write_mode);
    for t in 0 to NINV-1 loop
      write(l, string'("blk ") & integer'image(t)
             & " lay " & integer'image(lay_of(t))
             & " tok " & integer'image(ltok_of(t))
             & " n " & integer'image(yn_got(t))
             & " yexp " & integer'image(ye_got(t)));
      writeline(fh, l);
    end loop;
    for i in 0 to NY-1 loop
      write(l, string'("y ") & integer'image(i) & " " & integer'image(y_got(i)));
      writeline(fh, l);
    end loop;
    for i in 0 to NLAYER*NSTW-1 loop
      for k in 0 to RECUR_LANES-1 loop
        write(l, string'("s ") & integer'image(i) & " " & integer'image(k)
               & " " & integer'image(to_integer(signed(stmem(i)((k+1)*16-1 downto k*16)))));
        writeline(fh, l);
      end loop;
    end loop;
    for i in 0 to NLAYER*NCOL-1 loop
      write(l, string'("e ") & integer'image(i) & " "
             & integer'image(to_integer(semem(i))));
      writeline(fh, l);
    end loop;
    file_close(fh);

    -- TRACK DISTRAM's verdict.  A comparator that never ran is not a pass,
    -- so the live-cycle count carries a hard non-triviality assertion.
    assert cmp_live > 1000
      report "DISTRAM: NON-TRIVIALITY FAILED -- only "
           & integer'image(cmp_live) & " busy cycles were compared"
      severity failure;
    report "DISTRAM_RESULT checks=" & integer'image(cmp_checks)
         & " live=" & integer'image(cmp_live)
         & " fails=" & integer'image(cmp_fail);
    assert cmp_fail = 0
      report "DISTRAM: " & integer'image(cmp_fail)
           & " output mismatches against gdn_block_ref"
      severity failure;
    report "DISTRAM_OVERALL PASS";
    report "tb_gdn_block: PASS, " & integer'image(NY) & " elements, dump in "
         & OUTFILE;
    running <= false;
    wait;
  end process;


  -- ======================= TRACK DISTRAM: the shadow ======================
  shadow : entity work.gdn_block_ref
    generic map ( KEY_HEADS => KEY_HEADS, VAL_HEADS => VAL_HEADS, DIM => DIM,
                  KCONV => KCONV, LAYERS => LAYERS,
                  CONV_LANES => CONV_LANES, RECUR_LANES => RECUR_LANES,
                  RECUR_SLOTS => RECUR_SLOTS, L2_LANES => L2_LANES,
                  SILU_LANES => SILU_LANES, RMS_LANES => RMS_LANES,
                  Q => 12, EPS => 1.0e-6, SP_Q => 18,
                  CV_GAP => CV_GAP,
                  ISSUE_GAP => ISSUE_GAP, HEAD_GAP => HEAD_GAP,
                  STRICT_PRODUCER => STRICT )
    port map ( clk => clk, rst => rst,
               start => blk_start, layer => cur_lay, tk0 => tk0,
               busy => s_busy,
               seq_rst => seq_rst,
               cap_req => cap_req, cap_layer => cap_layer, cap_seg => cap_seg,
               cap_exp => cap_exp, cap_ready => s_cap_ready,
               cv_seg => s_cv_seg, cv_ren => s_cv_ren, cv_grp => s_cv_grp,
               cv_x => cv_x, cv_w => cv_w, cv_cw_exp => cv_cw_exp,
               cv_taken => s_cv_taken, eseg_taken => s_eseg_taken,
               sc_head => s_sc_head,
               sc_al_m => sc_al_m, sc_al_e => sc_al_e,
               sc_dt_m => sc_dt_m, sc_dt_e => sc_dt_e,
               sc_a_m => sc_a_m, sc_a_e => sc_a_e,
               sc_b_m => sc_b_m, sc_b_e => sc_b_e, sc_taken => s_sc_taken,
               st_ren => s_st_ren, st_rhead => s_st_rhead,
               st_rcol => s_st_rcol, st_rgrp => s_st_rgrp, st_rdata => st_rdata,
               st_wen => s_st_wen, st_whead => s_st_whead,
               st_wcol => s_st_wcol, st_wgrp => s_st_wgrp,
               st_wdata => s_st_wdata,
               se_rhead => s_se_rhead, se_rcol => s_se_rcol,
               se_rdata => se_rdata,
               se_wen => s_se_wen, se_whead => s_se_whead,
               se_wcol => s_se_wcol, se_wdata => s_se_wdata,
               w_mant => w_mant, w_exp => w_exp, w_taken => s_w_taken,
               z_mant => z_mant, z_exp => z_exp,
               z_valid => z_valid, z_ready => s_z_ready,
               y_valid => s_y_valid, y_mant => s_y_mant, y_last => s_y_last,
               y_exp => s_y_exp, done => s_done,
               err_conv => s_err_conv, err_g => s_err_g, err_se => s_err_se,
               y_sat => s_y_sat,
               dbg_col_ready => s_dbg_col_ready,
               dbg_col_drop => s_dbg_col_drop );

  -- Every output port, every rising edge, by name.  The first failure names
  -- the port and the cycle; the run continues so the shape of a divergence is
  -- visible rather than only its onset.
  cmp_p : process(clk)
    procedure ck(name : string; a, b : std_logic) is
    begin
      if a /= b then
        cmp_fail <= cmp_fail + 1;
        report "DISTRAM MISMATCH cyc=" & integer'image(cmp_cyc)
             & " port=" & name & " dut=" & std_logic'image(a)
             & " ref=" & std_logic'image(b) severity error;
      end if;
    end procedure;
    procedure cki(name : string; a, b : integer) is
    begin
      if a /= b then
        cmp_fail <= cmp_fail + 1;
        report "DISTRAM MISMATCH cyc=" & integer'image(cmp_cyc)
             & " port=" & name & " dut=" & integer'image(a)
             & " ref=" & integer'image(b) severity error;
      end if;
    end procedure;
  begin
    if rising_edge(clk) then
      cmp_cyc <= cmp_cyc + 1;
      cmp_checks <= cmp_checks + 1;
      if busy = '1' or s_busy = '1' then cmp_live <= cmp_live + 1; end if;
      ck("busy", busy, s_busy);
      ck("cap_ready", cap_ready, s_cap_ready);
      ck("cv_ren", cv_ren, s_cv_ren);
      ck("cv_taken", cv_taken, s_cv_taken);
      ck("eseg_taken", eseg_taken, s_eseg_taken);
      ck("sc_taken", sc_taken, s_sc_taken);
      ck("st_ren", st_ren, s_st_ren);
      ck("st_wen", st_wen, s_st_wen);
      ck("se_wen", se_wen, s_se_wen);
      ck("w_taken", w_taken, s_w_taken);
      ck("z_ready", z_ready, s_z_ready);
      ck("y_valid", y_valid, s_y_valid);
      ck("y_last", y_last, s_y_last);
      ck("done", blk_done, s_done);
      ck("err_conv", err_conv, s_err_conv);
      ck("err_g", err_g, s_err_g);
      ck("err_se", err_se, s_err_se);
      ck("y_sat", y_sat, s_y_sat);
      ck("dbg_col_ready", dbg_col_ready, s_dbg_col_ready);
      ck("dbg_col_drop", dbg_col_drop, s_dbg_col_drop);
      cki("cv_seg", cv_seg, s_cv_seg);
      cki("cv_grp", cv_grp, s_cv_grp);
      cki("sc_head", sc_head, s_sc_head);
      cki("st_rhead", st_rhead, s_st_rhead);
      cki("st_rcol", st_rcol, s_st_rcol);
      cki("st_rgrp", st_rgrp, s_st_rgrp);
      cki("st_whead", st_whead, s_st_whead);
      cki("st_wcol", st_wcol, s_st_wcol);
      cki("st_wgrp", st_wgrp, s_st_wgrp);
      cki("se_rhead", se_rhead, s_se_rhead);
      cki("se_rcol", se_rcol, s_se_rcol);
      cki("se_whead", se_whead, s_se_whead);
      cki("se_wcol", se_wcol, s_se_wcol);
      cki("st_wdata", to_integer(unsigned(st_wdata(15 downto 0))),
                      to_integer(unsigned(s_st_wdata(15 downto 0))));
      if st_wdata /= s_st_wdata then
        cmp_fail <= cmp_fail + 1;
        report "DISTRAM MISMATCH cyc=" & integer'image(cmp_cyc)
             & " port=st_wdata (full word)" severity error;
      end if;
      cki("se_wdata", to_integer(s_se_wdata), to_integer(se_wdata));
      cki("y_mant", to_integer(y_mant), to_integer(s_y_mant));
      cki("y_exp", to_integer(y_exp), to_integer(s_y_exp));
    end if;
  end process;

end architecture;
