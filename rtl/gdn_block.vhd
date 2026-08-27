-- rtl/gdn_block.vhd
-- Subsystem B: the Gated DeltaNet block, top level.  One GDN layer, one token.
--
-- WHY THIS EXISTS, and what it settles.  B had eleven unit-verified units and
-- exactly one of them -- gdn_emit_chain -- instantiated any of the others.
-- docs/debugging/2026-08-27_B-interface-audit.md says so in as many words, and
-- names the price: five of its eight findings are contracts between units that
-- are not wired together, so their reachability is a statement about prose
-- rather than about a build.  The spec audit paid a second price on the same
-- account: section 3.6 books silu at 8 DSP and the assembled emit chain ships
-- 16 lanes = 32, and NOTHING IN THE DOCUMENTS COULD SAY whether those are one
-- instance or two, because no B top level existed to count them.
--
-- THE SILU COUNT, READ OFF THE INSTANTIATIONS BELOW.  A B block contains TWO
-- gdn_silu instances, and they are different sizes:
--
--   u_silu_conv   CONV_LANES lanes   silu(conv_out), section 1.4(e)/(g), the
--                                    activation applied to the WHOLE conv
--                                    output -- q and k included -- BEFORE the
--                                    L2 norms.  Default 4 lanes = 8 DSP.
--   inside u_emit / u_silu
--                 SILU_LANES lanes   silu(z_h), the output gate.  16 lanes at
--                                    the setting gdn_emit_chain closes at
--                                    299.04 MHz = 32 DSP.
--
-- They cannot be the same instance, and the reason is structural rather than
-- schedular: gdn_conv implements 1.4(e) literally -- "depthwise, kernel 4, no
-- bias, NO FUSED ACTIVATION" -- so silu(conv_out) has no home except the top
-- level, while the gate silu is instantiated inside gdn_emit_chain, which this
-- file may not modify.  So B owes 8 + 32 = 40 DSP of silu against a booked 8,
-- and the aux row moves +32, not the +24 the audit's optimistic branch
-- assumed.  Which of the two the booked 8 DSP prices is now decidable as
-- well: it is the 4-lane micro_silu_narrow figure, u_silu_conv is a 4-lane
-- instance and the gate is not, so the conv activation is priced and the gate
-- is entirely unbooked.
--
-- SHARING ONE INSTANCE would save the 8, and is not taken.  It needs the gate
-- hoisted out of gdn_emit_chain -- a file this work may not modify -- plus a
-- mux between two streams of different widths, which forces the conv path up
-- to 16 lanes and adds a rate adapter.  8 DSP for a new seam in the one unit
-- of B that is already assembled and verified is a bad trade.
--
--     A's qkv (5,120 wide at 27B/card, 8,192 at 9B) + conv state
--            |
--     gdn_conv          x3 invocations, one per segment (q, k, v)
--            |          e_seg per segment, and see SEAM 1
--     gdn_silu          CONV_LANES lanes, the 1.4(e) activation
--            |
--     +------+------+---------------+
--     q             k               v
--     |             |               |
--   l2norm_rs     l2norm_rs         |     q path folds 1/sqrt(DIM), k path
--     | q_s         | k_n           |     does not; ONE unit produces both
--     +-------------+               |
--            |                      |
--     gdn_recur_pipe  <-------------+     per value head, DIM columns
--            |  o_acc, o_e_o                (state stream at the boundary)
--     gdn_emit_chain                        head_emit -> rmsnorm -> silu -> y
--            |
--        y stream to ssm_out
--
--     gdn_scalar   -> eg, beta       per value head, into the recurrence
--     gdn_exp_capture -> e_t, tvalid per (layer, segment), into the conv
--
-- WHAT IS AT THE BOUNDARY AND WHY.  Three things stay outside:
--
--   * The recurrent state itself.  DIM*DIM*VAL_HEADS int16 per layer, 2 MiB at
--     9B, DDR/HBM resident by section 2.4.  It appears here as a read port and
--     a write port with a one-cycle synchronous read, which is what a BRAM or
--     an HBM read stage looks like, and NOT as storage.
--   * The conv taps.  x_in is [3 stored columns | this token's qkv] and w_in
--     is the quantized ssm_conv1d; both are memory, both are subsystem D's to
--     stream.  Same one-cycle read contract.
--   * A's activations and the packer's scalars (al/dt/a/b, ssm_norm, z).
--
-- The state EXPONENT table is different and is deliberately a combinational
-- read: VAL_HEADS*DIM bytes, 4 KiB at 9B, small enough to be distributed RAM.
-- Making it combinational removes a prefetch pipeline that would otherwise sit
-- in the column issue path, and a prefetch in that path is exactly the shape
-- that produced defect B-3.  Cheap structural safety beats a clever pipeline.
--
-- SEAM 1, AND IT IS NOW A STRAIGHT WIRE.  gdn_conv used to publish `e_seg` in
-- S_FIN, two states AFTER pass B had finished streaming `o_data`, so the
-- exponent arrived after the data it described.  gdn_silu needs it for the
-- FIRST beat, so the stream could not be piped into the gate at all: a
-- straight-through connection silu'd every beat of segment s against segment
-- s-1's exponent, a per-segment power-of-two error with a legal-looking e_seg
-- and no error flag.  This block therefore buffered each segment and made a
-- SECOND pass over the buffer through silu.
--
-- Fixed in gdn_conv at commit b94e2f8: `e_seg`, `sh_seg` and `err_seg` are
-- published at S_SH, the earliest state in which the expression is computable,
-- and three cycles ahead of the first `o_valid`.  The second pass is gone and
-- conv's output stream feeds the gate directly.  MEASURED saving, one token,
-- from `sim/run_gdn_block.sh`'s cycle report: see
-- docs/debugging/2026-08-27_gdn-block-silu-straight-through.md.  It is one
-- pass over the conv width per segment, i.e. 2,048 cycles per layer at 9B and
-- CONV_LANES=4 against a 16,384-cycle state sweep.  Section 3.6's schedule
-- assumed this overlap; it is now actually available.
--
-- WHAT THE STRAIGHT WIRE COSTS, and it is not nothing.  The exponent is now
-- read by gdn_silu combinationally for EVERY beat of the segment, i.e. across
-- the whole of pass B, where the buffered form read it once at a single
-- instant.  That is the class-1 shape this project has now been bitten by
-- three times (w_mant, tvalid, cw_exp), so it is LATCHED here rather than
-- wired: `cs_eseg` tracks `cv_eseg` until the segment's first output beat and
-- FREEZES on it, `eseg_taken` pulses at that instant, and an assertion fails
-- the simulation if `cv_eseg` moves while the frozen copy is in use.  Safe by
-- construction plus a check, not safe by a latency argument.
--
-- AND SEGMENT COMPLETION IS NO LONGER `o_done`.  The last silu output lands
-- gdn_silu's latency AFTER the last conv beat, which is after `o_done` -- a
-- one-cycle pulse that now fires while the segment is still in flight.  The
-- FSM waits on the collected-beat count, a level, and captures `o_done` into a
-- sticky bit so the pulse cannot be missed either.  A completion signal that
-- stops meaning completion is the other half of the defect class above.
--
-- SEAM 2.  gdn_scalar and l2norm_rs latch NOTHING at `start` (audit B-4) and
-- read their inputs at scattered points across a whole invocation.  Both are
-- driven here from registers held for the invocation, and `sc_taken` pulses at
-- the instant the scalar group is captured, so the producer has an observable
-- safe edge instead of an unwritten "hold everything until done" contract.
-- This is the gdn_emit_chain w_taken fix applied one level up, before the
-- corresponding defect is written rather than after.
--
-- EVERY EXTERNAL SOURCE GETS ONE CYCLE, AND THE SCALAR PORT DID NOT.  The
-- conv taps and the state column are read with one cycle between address and
-- data, because that is what a register file or a BRAM needs.  The scalar
-- group was originally given ZERO -- sc_head presented, values sampled on the
-- very next edge -- which is a combinational read contract no realistic
-- source can meet, and a producer one cycle late hands over the PREVIOUS
-- head's al/dt/a/b.  Every head but the first is then decayed and gated
-- wrong: y elements 0..DIM-1 correct and everything after them not, which is
-- the head-boundary signature this project has now seen three times.  Caught
-- by the SC_MOVE axis of sim/tb_gdn_block.vhd against a REGISTERED producer
-- model; a combinational model cannot see it.  P_SCRD is that cycle, and it
-- costs VAL_HEADS cycles per layer against a 393,216-cycle sweep.
--
-- AND cv_seg IS PUBLISHED BEFORE cv_cw_exp IS SAMPLED, which it was not.  The
-- first version set cv_seg_i in P_CVWAIT, i.e. AFTER the exponent was latched
-- in P_EXP, so the producer was asked for a segment's conv-weight exponent
-- while the port still named the previous segment.  Class 2 of the audit
-- exactly: the output that says what a read refers to, published after the
-- read.  It was invisible until the testbench made cv_cw_exp depend on
-- cv_seg -- with a constant exponent every run agrees, which is the whole
-- reason the testbench varies it.
--
-- SEAM 3.  gdn_exp_capture drops a read that collides with a capture and says
-- nothing about it (audit B-12).  `rd_req` is therefore HELD until `rd_ack`
-- here, which is the safe usage the unit does not document.
--
-- SEAM 4, the one the audit calls class 3.  gdn_recur_pipe's `o_res_valid`
-- free-runs: it has no ready input, so a consumer whose ready falls under it
-- LOSES a column rather than delaying one.  That output is wired straight to
-- gdn_emit_chain's column port here, which is the first time the two have ever
-- been connected.  STRICT_PRODUCER therefore DEFAULTS TO TRUE in this block
-- (it defaults to false in gdn_emit_chain, which the audit flagged): at the
-- top level the producer is known and known to be unstallable, so a refused
-- column is a failure, not a stall.  `dbg_col_drop` is the sticky synthesizable
-- half of the same check, because an assertion is simulation-only and this
-- failure is invisible in hardware.
--
-- WHY THE PHASES ARE STRICTLY SEQUENTIAL.  conv -> silu -> L2 -> scalars ->
-- sweep run one after another, with only the sweep and the emit chain
-- concurrent.  That is not the fastest schedule and it is not meant to be:
-- every additional concurrency here is a new seam, and the seams are the thing
-- being tested.  The one concurrency that IS kept is the one section 2.4 says
-- the design rests on and the one where the known class-3 defect lives.  What
-- a production schedule would overlap is listed at the end of the file.
--
-- STAGING IS REGISTERS, NOT BRAM, AND THAT IS A CONSEQUENCE OF THE UNIT
-- INTERFACES.  l2norm_rs takes x_mant as one N*16 parallel bus, gdn_recur_pipe
-- takes k_n and q_s the same way, and rmsnorm_bf takes x_mant the same way.  A
-- block RAM cannot present 2,048 bits in a cycle, so q, k, k_n and q_s are
-- flat registers here.  Section 2.6 books q/k/v as BRAM36 rows; at these
-- interfaces they are not, and at 9B the staging is
-- (2 + 2)*KEY_HEADS*DIM*16 + VAL_HEADS*DIM*16 = 196,608 FF.  A BRAM-shaped
-- variant is possible -- keep the segment buffers beat-wide and assemble one
-- head into a DIM*16 register just before each l2norm -- and costs one extra
-- DIM/CONV_LANES-cycle pass per head.  Not taken here because it trades a
-- measured register count for an unmeasured BRAM count, and Vivado is not
-- being run.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;

entity gdn_block is
  generic(
    -- Shapes.  Defaults are Qwen3.5-9B on ONE card, which is the current
    -- target: 24 GDN layers, 32 value heads, 16 key heads, head dim 128.
    -- 27B on two cards is KEY_HEADS=8, VAL_HEADS=24, LAYERS=48.
    KEY_HEADS   : positive := 16;
    VAL_HEADS   : positive := 32;
    DIM         : positive := 128;  -- linear key head dim = value head dim
    KCONV       : positive := 4;    -- ssm.conv_kernel
    LAYERS      : positive := 24;   -- GDN layers, for the exponent store

    -- CONV_LANES sets the conv width AND the conv-path silu width, because
    -- they are wired together with no adapter.  4 is chosen so the silu
    -- instance is exactly the 4-lane / 8-DSP unit section 3.6 books, which
    -- makes the aux row correct for THIS instance instead of nearly correct
    -- for a hypothetical one.  The schedule permits it: the conv width at 9B
    -- is q 2,048 + k 2,048 + v 4,096 = 8,192 channels per layer, so the conv
    -- pass and the separate silu pass together are 4,096 cycles against a
    -- 16,384-cycle state sweep, a quarter of it and fully hideable once the
    -- phases are overlapped.
    CONV_LANES  : positive := 4;

    RECUR_LANES : positive := 32;   -- section 3.1's assumption
    RECUR_SLOTS : positive := 16;
    L2_LANES    : positive := 4;
    -- 16, not 32 and not 8.  See gdn_emit_chain's header: 8 misses B's
    -- 299.04 MHz and 32 both costs more and closes slower.
    SILU_LANES  : positive := 16;
    RMS_LANES   : positive := 4;
    Q           : integer  := 12;
    EPS         : real     := 1.0e-6;
    SP_Q        : integer range 8 to 22 := 18;

    -- Extra idle cycles inserted after every state column, so the column
    -- ARRIVAL PERIOD can be widened without changing RECUR_LANES (which would
    -- also change the state memory's word shape and make two runs
    -- incomparable).  It models a state memory that cannot sustain one group
    -- per cycle, and it exists because the emit chain's per-head deadline is
    -- a function of that period and the deadline had never been measured.
    -- Zero is the shipping configuration.
    -- Idle cycles between conv tap group requests.  Models a tap memory that
    -- cannot sustain one group per cycle, and it is the axis that moves
    -- gdn_conv's internal phase boundaries -- and therefore the instant e_seg
    -- is published and the instant the first output beat arrives -- relative
    -- to everything else in the block.  Zero is the shipping configuration.
    CV_GAP    : natural := 0;
    ISSUE_GAP : natural := 0;
    -- Idle cycles inserted ONCE per value head, between the kq_we and the
    -- head's first column.  It lengthens the head ARRIVAL PERIOD by exactly
    -- HEAD_GAP, which is what makes the emit chain's per-head deadline
    -- measurable to one cycle instead of to one ISSUE_GAP step.  It also
    -- models something real: a production schedule does the next key head's
    -- L2 norm and the next head's scalar path at this boundary rather than up
    -- front the way this file does.
    HEAD_GAP : natural := 0;

    -- TRUE here, false in gdn_emit_chain.  At the top level the column
    -- producer is gdn_recur_pipe and it demonstrably cannot be stalled, so a
    -- refused column is a lost column.  Turning this off hides the only
    -- simulation-time detector that exists for it.
    STRICT_PRODUCER : boolean := true
  );
  port(
    clk : in std_logic;
    rst : in std_logic;

    -- ---- control ---------------------------------------------------------
    start : in  std_logic;                          -- run one layer/token
    layer : in  integer range 0 to LAYERS-1;
    tk0   : in  std_logic;                          -- first token of sequence
    busy  : out std_logic;

    -- ---- exponent store, capture side: passed through to A ---------------
    seq_rst   : in  std_logic;
    cap_req   : in  std_logic;
    cap_layer : in  integer range 0 to LAYERS-1;
    cap_seg   : in  integer range 0 to 2;
    cap_exp   : in  signed(7 downto 0);
    cap_ready : out std_logic;

    -- ---- conv tap source, ONE CYCLE synchronous read ----------------------
    -- cv_ren/cv_grp/cv_seg are registered outputs; cv_x/cv_w must be valid in
    -- the cycle AFTER the one in which cv_ren is high, i.e. exactly what a
    -- registered-output BRAM does.
    cv_seg    : out integer range 0 to 2;
    cv_ren    : out std_logic;
    cv_grp    : out integer range 0 to (VAL_HEADS*DIM)/CONV_LANES-1;
    cv_x      : in  std_logic_vector(KCONV*CONV_LANES*16-1 downto 0);
    cv_w      : in  std_logic_vector(KCONV*CONV_LANES*16-1 downto 0);
    -- The conv-weight exponent for the segment named by cv_seg.  Latched at
    -- cv_taken and not read again; gdn_conv reads its own cw_exp at S_FIN,
    -- which is defect B-3b and is closed here by holding a register.
    cv_cw_exp : in  signed(7 downto 0);
    cv_taken  : out std_logic;
    -- ONE CYCLE, on the segment's first conv output beat: the instant the
    -- segment exponent is frozen for the gate.  gdn_conv may legally change
    -- e_seg after it, and may NOT before it.  Published for the same reason
    -- w_taken is: a latch whose instant is not observable is a timing
    -- contract, not a handshake.
    eseg_taken : out std_logic;

    -- ---- scalar path source, per value head ------------------------------
    -- Presented combinationally for the head named by sc_head; captured on
    -- sc_taken and held for the whole gdn_scalar invocation, because that unit
    -- latches nothing (audit B-4).
    sc_head : out integer range 0 to VAL_HEADS-1;
    sc_al_m : in  signed(15 downto 0);
    sc_al_e : in  signed(7 downto 0);
    sc_dt_m : in  signed(15 downto 0);
    sc_dt_e : in  signed(7 downto 0);
    sc_a_m  : in  signed(15 downto 0);
    sc_a_e  : in  signed(7 downto 0);
    sc_b_m  : in  signed(15 downto 0);
    sc_b_e  : in  signed(7 downto 0);
    sc_taken : out std_logic;

    -- ---- recurrent state, ONE CYCLE synchronous read ---------------------
    st_ren   : out std_logic;
    st_rhead : out integer range 0 to VAL_HEADS-1;
    st_rcol  : out integer range 0 to DIM-1;
    st_rgrp  : out integer range 0 to DIM/RECUR_LANES-1;
    st_rdata : in  std_logic_vector(RECUR_LANES*16-1 downto 0);
    st_wen   : out std_logic;
    st_whead : out integer range 0 to VAL_HEADS-1;
    st_wcol  : out integer range 0 to DIM-1;
    st_wgrp  : out integer range 0 to DIM/RECUR_LANES-1;
    st_wdata : out std_logic_vector(RECUR_LANES*16-1 downto 0);

    -- ---- state exponent table, COMBINATIONAL read ------------------------
    se_rhead : out integer range 0 to VAL_HEADS-1;
    se_rcol  : out integer range 0 to DIM-1;
    se_rdata : in  signed(7 downto 0);
    se_wen   : out std_logic;
    se_whead : out integer range 0 to VAL_HEADS-1;
    se_wcol  : out integer range 0 to DIM-1;
    se_wdata : out signed(7 downto 0);

    -- ---- output norm weight and the z gate, straight to the emit chain ----
    w_mant  : in  std_logic_vector(DIM*16-1 downto 0);
    w_exp   : in  integer;
    w_taken : out std_logic;
    z_mant  : in  std_logic_vector(DIM*16-1 downto 0);
    z_exp   : in  signed(7 downto 0);
    z_valid : in  std_logic;
    z_ready : out std_logic;

    -- ---- block output ----------------------------------------------------
    y_valid : out std_logic;
    y_mant  : out signed(15 downto 0);
    y_last  : out std_logic;
    y_exp   : out signed(7 downto 0);
    done    : out std_logic;

    -- ---- status.  Audit B-10: these were reported into open air by every
    -- unit that produces them.  They are consumed here, made sticky for the
    -- block, and published, which is the cheapest thing that can be done
    -- about an int8 exponent overflow that 2.1.6 forbids wrapping silently.
    err_conv : out std_logic;   -- gdn_conv err_seg on any of the 3 segments
    err_g    : out std_logic;   -- gdn_scalar hit the -16 g clamp
    err_se   : out std_logic;   -- gdn_recur_pipe state-exponent overflow
    y_sat    : out std_logic;
    -- Synthesizable half of the STRICT_PRODUCER check: sticky, set if a column
    -- was ever offered by gdn_recur_pipe and refused by gdn_emit_chain.  In
    -- hardware that column is gone; nothing else would say so.
    dbg_col_ready : out std_logic;
    dbg_col_drop  : out std_logic
  );
end entity;

architecture rtl of gdn_block is

  constant SEGS   : integer := 3;
  constant QCH    : integer := KEY_HEADS*DIM;   -- q segment channels
  constant VCH    : integer := VAL_HEADS*DIM;   -- v segment channels
  constant CH_MAX : integer := VCH;             -- v is the widest of the three
  constant NBQ    : integer := QCH/CONV_LANES;
  constant NBV    : integer := VCH/CONV_LANES;
  constant NB_R   : integer := DIM/RECUR_LANES; -- groups per state column
  constant VPK    : integer := VAL_HEADS/KEY_HEADS;
  constant NCOL   : integer := VAL_HEADS*DIM;   -- state columns per layer

  -- ---- staging.  See the header note on why these are registers. ---------
  signal qbuf : std_logic_vector(QCH*16-1 downto 0) := (others => '0');
  signal kbuf : std_logic_vector(QCH*16-1 downto 0) := (others => '0');
  signal vbuf : std_logic_vector(VCH*16-1 downto 0) := (others => '0');
  signal knb  : std_logic_vector(QCH*16-1 downto 0) := (others => '0');
  signal qsb  : std_logic_vector(QCH*16-1 downto 0) := (others => '0');

  type u16_arr is array (natural range <>) of unsigned(15 downto 0);
  signal eg_b   : u16_arr(0 to VAL_HEADS-1) := (others => (others => '0'));
  signal beta_b : u16_arr(0 to VAL_HEADS-1) := (others => (others => '0'));

  type e8_arr is array (0 to SEGS-1) of signed(7 downto 0);
  signal seg_e : e8_arr := (others => (others => '0'));

  -- ---- gdn_exp_capture ---------------------------------------------------
  signal ec_rd_req : std_logic;
  signal ec_rd_seg : integer range 0 to SEGS-1 := 0;
  signal ec_rd_ack : std_logic;
  signal ec_e_t    : std_logic_vector(KCONV*8-1 downto 0);
  signal ec_tvalid : std_logic_vector(KCONV-1 downto 0);

  -- ---- gdn_conv ----------------------------------------------------------
  signal cv_start  : std_logic := '0';
  signal cv_nch    : integer range 0 to CH_MAX := 0;
  signal cv_cw_r   : signed(7 downto 0) := (others => '0');
  signal cv_sv     : std_logic := '0';
  signal cv_ovalid : std_logic;
  signal cv_odata  : std_logic_vector(CONV_LANES*16-1 downto 0);
  signal cv_odone  : std_logic;
  signal cv_eseg   : signed(7 downto 0);
  signal cv_shseg  : integer range 0 to 63;
  signal cv_errseg : std_logic;
  signal cv_ready  : std_logic;
  signal cv_ren_i  : std_logic := '0';
  signal cv_seg_i  : integer range 0 to SEGS-1 := 0;

  -- ---- gdn_silu, the 1.4(e) conv activation.  INSTANCE 1 OF 2. -----------
  -- Driven concurrently off gdn_conv's output; see the straight-wire note.
  signal cs_valid  : std_logic;
  signal cs_data   : std_logic_vector(CONV_LANES*16-1 downto 0);
  -- The FROZEN segment exponent.  See the SEAM 1 note: gdn_silu reads e_seg
  -- combinationally for every beat, so it may not be a wire.
  signal cs_eseg   : signed(7 downto 0) := (others => '0');
  signal eseg_frz  : std_logic := '0';   -- '1' once the segment's copy is held
  signal cv_done_r : std_logic := '0';   -- o_done captured; it is a pulse
  signal co_valid  : std_logic;
  signal co_data   : std_logic_vector(CONV_LANES*16-1 downto 0);

  -- ---- l2norm_rs ---------------------------------------------------------
  signal l2_start : std_logic := '0';
  signal l2_x     : std_logic_vector(DIM*16-1 downto 0) := (others => '0');
  signal l2_done  : std_logic;
  signal l2_k     : std_logic_vector(DIM*16-1 downto 0);
  signal l2_q     : std_logic_vector(DIM*16-1 downto 0);

  -- ---- gdn_scalar --------------------------------------------------------
  signal sp_start : std_logic := '0';
  signal sp_al_m, sp_dt_m, sp_a_m, sp_b_m : signed(15 downto 0) := (others => '0');
  signal sp_al_e, sp_dt_e, sp_a_e, sp_b_e : signed(7 downto 0)  := (others => '0');
  signal sp_eg    : unsigned(15 downto 0);
  signal sp_beta  : unsigned(15 downto 0);
  signal sp_errg  : std_logic;
  signal sp_done  : std_logic;

  -- ---- gdn_recur_pipe ----------------------------------------------------
  signal rp_kq_we   : std_logic := '0';
  signal rp_kq_wsel : std_logic := '0';
  signal rp_eg      : unsigned(15 downto 0) := (others => '0');
  signal rp_beta    : unsigned(15 downto 0) := (others => '0');
  signal rp_kn      : std_logic_vector(DIM*16-1 downto 0) := (others => '0');
  signal rp_qs      : std_logic_vector(DIM*16-1 downto 0) := (others => '0');
  signal rp_svalid  : std_logic := '0';
  signal rp_sfirst  : std_logic := '0';
  signal rp_ctk0    : std_logic := '0';
  signal rp_chsel   : std_logic := '0';
  signal rp_cse     : signed(7 downto 0) := (others => '0');
  signal rp_cev     : signed(7 downto 0) := (others => '0');
  signal rp_cvj     : signed(15 downto 0) := (others => '0');
  signal rp_ovalid  : std_logic;
  signal rp_olast   : std_logic;
  signal rp_odata   : std_logic_vector(RECUR_LANES*16-1 downto 0);
  signal rp_senew   : signed(7 downto 0);
  signal rp_acc     : signed(39 downto 0);
  signal rp_eo      : signed(7 downto 0);
  signal rp_resv    : std_logic;
  signal rp_errse   : std_logic;

  -- ---- gdn_emit_chain ----------------------------------------------------
  signal ec_col_ready : std_logic;
  signal ec_done      : std_logic;
  signal ec_ysat      : std_logic;

  -- ---- issue-side registers ---------------------------------------------
  signal st_ren_i  : std_logic := '0';
  signal st_first_i: std_logic := '0';
  signal st_rh_i   : integer range 0 to VAL_HEADS-1 := 0;
  signal st_rc_i   : integer range 0 to DIM-1 := 0;
  signal st_rg_i   : integer range 0 to NB_R-1 := 0;

  -- ---- state write-back counters ----------------------------------------
  signal wh : integer range 0 to VAL_HEADS-1 := 0;
  signal wc : integer range 0 to DIM-1 := 0;
  signal wg : integer range 0 to NB_R-1 := 0;
  signal rh : integer range 0 to VAL_HEADS-1 := 0;
  signal rc : integer range 0 to DIM-1 := 0;
  signal res_cnt : integer range 0 to NCOL := 0;

  -- ---- the phase machine -------------------------------------------------
  type ph_t is (P_IDLE,
                P_EXP, P_CVGO, P_CVWAIT, P_CVFEED, P_CVDRAIN, P_SEGN,
                P_L2GO, P_L2WAIT, P_L2N,
                P_SCADR, P_SCRD, P_SCLAT, P_SCWAIT, P_SCN,
                P_HKQ, P_HGAP, P_COL, P_DRAIN, P_WAITY);
  signal ph : ph_t := P_IDLE;

  signal seg   : integer range 0 to SEGS-1 := 0;
  signal beat  : integer range 0 to NBV := 0;   -- conv/silu feed pointer
  signal obeat : integer range 0 to NBV := 0;   -- conv/silu collect pointer
  signal nbeat : integer range 0 to NBV := 0;   -- beats in the current segment
  signal kh    : integer range 0 to KEY_HEADS := 0;
  signal l2_qk : std_logic := '0';              -- 0 = q vector, 1 = k vector
  signal vh    : integer range 0 to VAL_HEADS := 0;
  signal col   : integer range 0 to DIM := 0;
  signal grp   : integer range 0 to NB_R := 0;
  signal gapc  : integer range 0 to ISSUE_GAP := 0;
  signal cgapc : integer range 0 to CV_GAP := 0;
  signal hgapc : integer range 0 to HEAD_GAP := 0;

  signal errc_r : std_logic := '0';
  signal errg_r : std_logic := '0';
  signal errs_r : std_logic := '0';
  signal drop_r : std_logic := '0';

  function seg_ch(s : integer) return integer is
  begin
    if s = 2 then return VCH; else return QCH; end if;
  end function;

begin

  -- Elaboration-time shape checks.  Every one of these, violated, produces
  -- silently wrong numbers rather than an error, which is why they are here
  -- and not in a comment.
  assert VAL_HEADS mod KEY_HEADS = 0
    report "gdn_block: value heads must be a whole multiple of key heads"
    severity failure;
  assert DIM mod CONV_LANES = 0
    report "gdn_block: CONV_LANES must divide DIM, or a conv output beat "
         & "straddles two heads and the q/k/v demux is wrong"
    severity failure;
  assert DIM mod RECUR_LANES = 0
    report "gdn_block: RECUR_LANES must divide DIM" severity failure;
  assert NB_R >= 2
    report "gdn_block: DIM/RECUR_LANES must be at least 2; the column issue "
         & "loop needs one non-first group to hold the per-column context"
    severity failure;
  assert DIM mod SILU_LANES = 0 and DIM mod RMS_LANES = 0
    report "gdn_block: SILU_LANES and RMS_LANES must divide DIM"
    severity failure;

  -- ---- pure wiring -------------------------------------------------------
  -- rd_req is a LEVEL held until rd_ack, which is gdn_exp_capture's safe usage
  -- and is the thing that unit does not document (audit B-12): a read that
  -- collides with a capture is dropped with no acknowledgement of any kind.
  -- Driven combinationally so it falls in the SAME cycle the ack arrives; a
  -- registered deassert leaves it high for one more cycle, during which the
  -- unit is back in S_IDLE and starts a second, redundant read.
  ec_rd_req <= '1' when (ph = P_EXP and ec_rd_ack = '0') else '0';

  -- THE STRAIGHT WIRE.  gdn_conv's pass-B output is gdn_silu's input, with
  -- nothing between them.  Direct rather than registered: a register would
  -- cost a cycle for nothing, since gdn_silu has no ready to satisfy and the
  -- exponent is already frozen by the time the first beat lands.
  cs_valid <= cv_ovalid;
  cs_data  <= cv_odata;

  cv_ren <= cv_ren_i;
  cv_seg <= cv_seg_i;
  st_ren <= st_ren_i;
  st_rhead <= st_rh_i;
  st_rcol  <= st_rc_i;
  st_rgrp  <= st_rg_i;
  busy <= '0' when ph = P_IDLE else '1';
  err_conv <= errc_r;
  err_g    <= errg_r;
  err_se   <= errs_r;
  y_sat    <= ec_ysat;
  done     <= ec_done;
  dbg_col_ready <= ec_col_ready;
  dbg_col_drop  <= drop_r;

  -- The state exponent read is combinational, so the address is simply the
  -- column being issued.  st_rh_i/st_rc_i already hold it during the cycle in
  -- which st_first_i is high, which is the cycle rp_cse must be captured in.
  se_rhead <= st_rh_i;
  se_rcol  <= st_rc_i;

  u_exp : entity work.gdn_exp_capture
    generic map ( LAYERS => LAYERS, SEGS => SEGS, K => KCONV )
    port map ( clk => clk, rst => rst, seq_rst => seq_rst,
               cap_req => cap_req, cap_layer => cap_layer, cap_seg => cap_seg,
               cap_exp => cap_exp, cap_ready => cap_ready,
               rd_req => ec_rd_req, rd_layer => layer, rd_seg => ec_rd_seg,
               rd_ack => ec_rd_ack, e_t => ec_e_t, tvalid => ec_tvalid );

  u_conv : entity work.gdn_conv
    generic map ( CH_MAX => CH_MAX, K => KCONV, LANES => CONV_LANES )
    port map ( clk => clk, rst => rst, start => cv_start,
               nch => cv_nch, tvalid => ec_tvalid, e_t => ec_e_t,
               cw_exp => cv_cw_r,
               s_valid => cv_sv, x_in => cv_x, w_in => cv_w,
               o_valid => cv_ovalid, o_data => cv_odata,
               o_done => cv_odone, e_seg => cv_eseg, sh_seg => cv_shseg,
               err_seg => cv_errseg, ready => cv_ready, cfg_taken => open );

  -- INSTANCE 1 OF 2.  silu(conv_out), 1.4(e): applied to the whole conv
  -- output, q and k included, BEFORE the L2 norms.  Same width as the conv and
  -- fed STRAIGHT off its output stream -- no adapter, no buffer, no second
  -- pass.  Rate-safe by construction: gdn_conv emits at most one beat per
  -- cycle and gdn_silu is II = 1 with a fixed latency and no ready in either
  -- direction, so neither side can ever refuse the other.
  u_silu_conv : entity work.gdn_silu
    generic map ( LANES => CONV_LANES, ARG_Q => Q )
    port map ( clk => clk, rst => rst, e_seg => cs_eseg,
               s_valid => cs_valid, s_data => cs_data,
               o_valid => co_valid, o_data => co_data );

  -- ONE instance for both q and k, and for both paths of each: the unit
  -- produces the plain L2 norm on k_mant and the 1/sqrt(DIM)-folded one on
  -- q_mant from a single pass, so a q vector is normed with the q_mant output
  -- and a k vector with the k_mant output.  2.1.4 pins the fold.
  u_l2 : entity work.l2norm_rs
    generic map ( N => DIM, LANES => L2_LANES )
    port map ( clk => clk, rst => rst, start => l2_start, x_mant => l2_x,
               done => l2_done, k_mant => l2_k, q_mant => l2_q );

  u_scal : entity work.gdn_scalar
    generic map ( SP_Q => SP_Q )
    port map ( clk => clk, rst => rst, start => sp_start,
               al_m => sp_al_m, al_e => sp_al_e,
               dt_m => sp_dt_m, dt_e => sp_dt_e,
               a_m => sp_a_m, a_e => sp_a_e, b_m => sp_b_m, b_e => sp_b_e,
               eg => sp_eg, beta => sp_beta, err_g => sp_errg, done => sp_done );

  u_recur : entity work.gdn_recur_pipe
    generic map ( DIM => DIM, LANES => RECUR_LANES, SLOTS => RECUR_SLOTS )
    port map ( clk => clk, rst => rst,
               kq_we => rp_kq_we, kq_wsel => rp_kq_wsel,
               eg => rp_eg, beta => rp_beta, k_n => rp_kn, q_s => rp_qs,
               s_valid => rp_svalid, s_first => rp_sfirst, s_data => st_rdata,
               c_tk0 => rp_ctk0, c_hsel => rp_chsel, c_se_j => rp_cse,
               c_e_v => rp_cev, c_v_j => rp_cvj,
               o_valid => rp_ovalid, o_last => rp_olast, o_data => rp_odata,
               o_se_new => rp_senew, o_acc => rp_acc, o_e_o => rp_eo,
               o_res_valid => rp_resv, o_err_se => rp_errse );

  -- INSTANCE 2 OF 2 is inside here: gdn_emit_chain instantiates gdn_silu at
  -- SILU_LANES for the z gate.  This file does not and cannot share it with
  -- u_silu_conv; see the SILU COUNT note in the header.
  u_emit : entity work.gdn_emit_chain
    generic map ( HEADS => VAL_HEADS, DIM => DIM,
                  SILU_LANES => SILU_LANES, RMS_LANES => RMS_LANES,
                  Q => Q, EPS => EPS, STRICT_PRODUCER => STRICT_PRODUCER )
    port map ( clk => clk, rst => rst,
               w_mant => w_mant, w_exp => w_exp,
               col_valid => rp_resv, col_acc => rp_acc, col_e_o => rp_eo,
               col_ready => ec_col_ready,
               z_mant => z_mant, z_exp => z_exp,
               z_valid => z_valid, z_ready => z_ready,
               y_valid => y_valid, y_mant => y_mant, y_last => y_last,
               y_exp => y_exp, done => ec_done, y_sat => ec_ysat,
               w_taken => w_taken );

  -- ---- the sequencer -----------------------------------------------------
  process(clk)
    variable base : integer;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        ph <= P_IDLE;
        cv_start <= '0'; cv_sv <= '0'; cv_ren_i <= '0';
        l2_start <= '0'; sp_start <= '0';
        eseg_frz <= '0'; cv_done_r <= '0'; eseg_taken <= '0';
        rp_kq_we <= '0'; rp_svalid <= '0'; rp_sfirst <= '0';
        st_ren_i <= '0'; st_first_i <= '0'; st_wen <= '0'; se_wen <= '0';
        cv_taken <= '0'; sc_taken <= '0';
        seg <= 0; beat <= 0; obeat <= 0; kh <= 0; vh <= 0;
        col <= 0; grp <= 0; gapc <= 0; l2_qk <= '0';
        wh <= 0; wc <= 0; wg <= 0; rh <= 0; rc <= 0; res_cnt <= 0;
        errc_r <= '0'; errg_r <= '0'; errs_r <= '0'; drop_r <= '0';
      else
        -- one-cycle strobes
        cv_start <= '0'; l2_start <= '0'; sp_start <= '0';
        rp_kq_we <= '0'; cv_taken <= '0'; sc_taken <= '0';
        st_wen <= '0'; se_wen <= '0';
        cv_ren_i <= '0'; st_ren_i <= '0'; st_first_i <= '0';
        eseg_taken <= '0';

        -- The conv tap read has one cycle of latency, so the group offered to
        -- gdn_conv is the one requested on the previous edge.
        cv_sv <= cv_ren_i;

        -- ================= always-on collectors ==========================

        -- ---- the segment exponent, LATCHED and then FROZEN ---------------
        -- gdn_conv publishes e_seg at S_SH, three cycles before the first
        -- output beat, and holds it until the NEXT segment's S_SH.  gdn_silu
        -- reads it combinationally at stage S0 for every beat.  So the value
        -- must be stable for the whole of pass B, and the honest way to get
        -- that is a register that stops following, not an argument about how
        -- far apart two states are.
        --
        -- Tracking until the first beat and freezing on it is what makes the
        -- copy correct for beat 0 as well: at that edge the register already
        -- holds what it sampled the cycle before, which is the same value
        -- e_seg has held since S_SH.
        if eseg_frz = '0' then
          cs_eseg <= cv_eseg;
          if cv_ovalid = '1' then
            eseg_frz  <= '1';
            eseg_taken <= '1';
          end if;
        else
          -- Checked, not assumed.  If gdn_conv ever republishes e_seg while a
          -- segment is still streaming through the gate, the frozen copy and
          -- the live port disagree and every beat after the change is on the
          -- wrong grid -- silently, with a legal e_seg, which is exactly how
          -- the original defect presented.
          assert cv_eseg = cs_eseg
            report "gdn_block: gdn_conv moved e_seg while the segment it "
                 & "describes was still streaming through u_silu_conv.  The "
                 & "frozen copy and the port now disagree and every beat "
                 & "after the change is on the wrong power-of-two grid."
            severity failure;
        end if;

        -- o_done is a PULSE and it no longer marks segment completion: the
        -- last silu output lands gdn_silu's latency after the last conv beat,
        -- which is later.  Captured so the FSM can require both.
        if cv_odone = '1' then cv_done_r <= '1'; end if;

        -- ---- silu output -> the segment's staging buffer ------------------
        -- The ONLY writer of these buffers now.  The buffered form wrote conv
        -- output here and then overwrote it in place on a second pass; there
        -- is no first copy to overwrite any more.
        if co_valid = '1' and ph /= P_IDLE then
          base := obeat*CONV_LANES*16;
          if    cv_seg_i = 0 then
            qbuf(base+CONV_LANES*16-1 downto base) <= co_data;
          elsif cv_seg_i = 1 then
            kbuf(base+CONV_LANES*16-1 downto base) <= co_data;
          else
            vbuf(base+CONV_LANES*16-1 downto base) <= co_data;
          end if;
          assert obeat < nbeat
            report "gdn_block: u_silu_conv produced more beats than the "
                 & "segment has; the collect pointer would run past the buffer"
            severity failure;
          obeat <= obeat + 1;
        end if;

        -- recurrence: the new state column back to memory
        if rp_ovalid = '1' then
          st_wen   <= '1';
          st_whead <= wh;
          st_wcol  <= wc;
          st_wgrp  <= wg;
          st_wdata <= rp_odata;
          if wg = NB_R-1 then
            wg <= 0;
            if wc = DIM-1 then
              wc <= 0;
              if wh = VAL_HEADS-1 then wh <= 0; else wh <= wh + 1; end if;
            else
              wc <= wc + 1;
            end if;
          else
            wg <= wg + 1;
          end if;
        end if;

        -- recurrence: the per-column results.  o_res_valid also drives the
        -- emit chain's column port directly (see the instantiation above).
        if rp_resv = '1' then
          se_wen   <= '1';
          se_whead <= rh;
          se_wcol  <= rc;
          se_wdata <= rp_senew;
          if rc = DIM-1 then
            rc <= 0;
            if rh = VAL_HEADS-1 then rh <= 0; else rh <= rh + 1; end if;
          else
            rc <= rc + 1;
          end if;
          if res_cnt < NCOL then res_cnt <= res_cnt + 1; end if;
          if rp_errse = '1' then errs_r <= '1'; end if;
          -- The synthesizable half of STRICT_PRODUCER.
          if ec_col_ready = '0' then drop_r <= '1'; end if;
        end if;

        -- ================= the phase machine =============================
        case ph is

          when P_IDLE =>
            if start = '1' then
              seg <= 0; kh <= 0; vh <= 0; l2_qk <= '0';
              wh <= 0; wc <= 0; wg <= 0; rh <= 0; rc <= 0; res_cnt <= 0;
              errc_r <= '0'; errg_r <= '0'; errs_r <= '0'; drop_r <= '0';
              ec_rd_seg <= 0;
              -- cv_seg is published HERE, with the exponent-store read and
              -- several cycles before cv_cw_exp is latched at rd_ack.  It used
              -- to be set in P_CVWAIT, i.e. AFTER the latch, so the producer
              -- was asked for a segment's conv-weight exponent while the port
              -- still named the PREVIOUS segment.  Found by wiring, and only
              -- because the skew testbench made cv_cw_exp depend on cv_seg;
              -- with a constant exponent it is invisible.  Class 2 of the
              -- 2026-08-27 audit exactly: an output that names what a read
              -- refers to, published after the read.
              cv_seg_i <= 0;
              ph <= P_EXP;
            end if;

          -- Held until rd_ack, which is the safe usage gdn_exp_capture needs
          -- and does not document (audit B-12): a read that collides with a
          -- capture is dropped with no signal of any kind.
          when P_EXP =>
            if ec_rd_ack = '1' then
              cv_cw_r  <= cv_cw_exp;      -- closes B-3b at the top level
              cv_taken <= '1';
              cv_nch   <= seg_ch(seg);
              nbeat    <= seg_ch(seg)/CONV_LANES;
              obeat    <= 0;
              beat     <= 0;
              -- Re-arm the segment exponent latch and the o_done capture.
              -- Both are per-segment and both are cleared BEFORE the conv is
              -- started, so neither can carry a value from segment s-1 into s.
              eseg_frz  <= '0';
              cv_done_r <= '0';
              cv_start  <= '1';
              ph <= P_CVGO;
            end if;

          when P_CVGO =>
            ph <= P_CVWAIT;

          -- gdn_conv reaches S_A two cycles after start; `ready` is the only
          -- signal that says so.  Note B-11: `ready` is ALSO high for the five
          -- drain cycles at the end of pass A, so it cannot be used as a
          -- per-group accept.  Exactly nbeat groups are offered here and no
          -- more, which is the framing the unit actually requires.
          when P_CVWAIT =>
            if cv_ready = '1' then
              cv_ren_i <= '1'; cv_grp <= 0;
              beat  <= 1;
              cgapc <= CV_GAP;
              ph <= P_CVFEED;
            end if;

          when P_CVFEED =>
            if beat < nbeat then
              if cgapc > 0 then
                cgapc <= cgapc - 1;       -- CV_GAP: a slow tap memory
              else
                cv_ren_i <= '1'; cv_grp <= beat;
                beat  <= beat + 1;
                cgapc <= CV_GAP;
              end if;
            else
              ph <= P_CVDRAIN;
            end if;

          -- The segment is done when every beat has come OUT of the gate,
          -- not when gdn_conv says it is done.  o_done fires while the tail of
          -- the segment is still inside u_silu_conv, so it is necessary and
          -- not sufficient; both are required here.  Waiting on o_done alone
          -- would truncate each segment by gdn_silu's latency and leave the
          -- last beats of q, k and v as whatever the buffer held before.
          when P_CVDRAIN =>
            if obeat = nbeat and cv_done_r = '1' then
              -- Taken from the FROZEN copy, not the live port: by now gdn_conv
              -- is back in S_IDLE and its e_seg is still the right value, but
              -- reading the port here would reintroduce exactly the dependency
              -- on when the next segment starts that this file has already
              -- paid for twice.
              seg_e(seg) <= cs_eseg;
              if cv_errseg = '1' then errc_r <= '1'; end if;
              ph <= P_SEGN;
            end if;

          when P_SEGN =>
            if seg = SEGS-1 then
              kh <= 0; l2_qk <= '0';
              ph <= P_L2GO;
            else
              seg <= seg + 1;
              ec_rd_seg <= seg + 1;
              cv_seg_i  <= seg + 1;
              ph <= P_EXP;
            end if;

          -- ---- L2 norms.  l2norm_rs latches nothing (B-4), so l2_x is a
          -- register held for the whole invocation rather than a live slice.
          when P_L2GO =>
            base := kh*DIM*16;
            if l2_qk = '0' then
              l2_x <= qbuf(base+DIM*16-1 downto base);
            else
              l2_x <= kbuf(base+DIM*16-1 downto base);
            end if;
            l2_start <= '1';
            ph <= P_L2WAIT;

          when P_L2WAIT =>
            if l2_done = '1' then
              base := kh*DIM*16;
              if l2_qk = '0' then
                qsb(base+DIM*16-1 downto base) <= l2_q;   -- q path, 1/sqrt(DIM)
              else
                knb(base+DIM*16-1 downto base) <= l2_k;   -- k path
              end if;
              ph <= P_L2N;
            end if;

          when P_L2N =>
            if l2_qk = '0' then
              l2_qk <= '1';
              ph <= P_L2GO;
            elsif kh = KEY_HEADS-1 then
              vh <= 0;
              ph <= P_SCADR;
            else
              kh <= kh + 1; l2_qk <= '0';
              ph <= P_L2GO;
            end if;

          -- ---- scalar path, per value head.  Same B-4 treatment.
          -- THREE states, not two, and the middle one is the point.  Every
          -- other external source this block reads -- the conv taps, the
          -- state column -- is given one cycle between the address and the
          -- data, because that is what a register file or a BRAM needs.  The
          -- scalar port used to be given ZERO: sc_head was presented and the
          -- values sampled on the very next edge, which is a combinational
          -- read contract that no realistic source can meet.  A producer one
          -- cycle late then hands over the PREVIOUS head's scalars and every
          -- head but the first is decayed and gated wrong.  Caught by the
          -- SC_MOVE axis of sim/tb_gdn_block.vhd; invisible to a producer
          -- that holds one value forever.
          when P_SCADR =>
            sc_head <= vh;
            ph <= P_SCRD;

          when P_SCRD =>
            ph <= P_SCLAT;

          when P_SCLAT =>
            sp_al_m <= sc_al_m; sp_al_e <= sc_al_e;
            sp_dt_m <= sc_dt_m; sp_dt_e <= sc_dt_e;
            sp_a_m  <= sc_a_m;  sp_a_e  <= sc_a_e;
            sp_b_m  <= sc_b_m;  sp_b_e  <= sc_b_e;
            sc_taken <= '1';
            sp_start <= '1';
            ph <= P_SCWAIT;

          when P_SCWAIT =>
            if sp_done = '1' then
              eg_b(vh)   <= sp_eg;
              beta_b(vh) <= sp_beta;
              if sp_errg = '1' then errg_r <= '1'; end if;
              ph <= P_SCN;
            end if;

          when P_SCN =>
            if vh = VAL_HEADS-1 then
              vh <= 0; col <= 0; grp <= 0;
              ph <= P_HKQ;
            else
              vh <= vh + 1;
              ph <= P_SCADR;
            end if;

          -- ---- the sweep.  One head's k_n/q_s/eg/beta into bank vh mod 2.
          -- Audit B-7: nothing tells the producer when a bank is free, so the
          -- argument has to be made here.  Bank vh mod 2 last carried head
          -- vh-2, whose columns drained DC + 2*NB_R cycles after its last
          -- issue; head vh-1's own sweep is DIM*NB_R cycles long, which is
          -- larger for every shape this block supports.  gdn_recur_pipe's occ
          -- shift register fails the simulation if that ever stops holding.
          when P_HKQ =>
            base := (vh/VPK)*DIM*16;
            rp_kn      <= knb(base+DIM*16-1 downto base);
            rp_qs      <= qsb(base+DIM*16-1 downto base);
            rp_eg      <= eg_b(vh);
            rp_beta    <= beta_b(vh);
            rp_kq_wsel <= '1' when (vh mod 2) = 1 else '0';
            rp_kq_we   <= '1';
            col <= 0; grp <= 0; gapc <= 0;
            if HEAD_GAP = 0 then
              ph <= P_COL;
            else
              hgapc <= HEAD_GAP;
              ph <= P_HGAP;
            end if;

          when P_HGAP =>
            if hgapc > 1 then hgapc <= hgapc - 1; else ph <= P_COL; end if;

          -- One group request per cycle; the state read has one cycle of
          -- latency, so s_valid/s_first are the previous cycle's request.
          when P_COL =>
            if col < DIM then
              if gapc > 0 then
                gapc <= gapc - 1;         -- ISSUE_GAP: widen the arrival period
              else
                st_ren_i <= '1';
                st_rh_i  <= vh;
                st_rc_i  <= col;
                st_rg_i  <= grp;
                if grp = 0 then st_first_i <= '1'; end if;
                if grp = NB_R-1 then
                  grp  <= 0;
                  col  <= col + 1;
                  gapc <= ISSUE_GAP;
                else
                  grp <= grp + 1;
                end if;
              end if;
            else
              if vh = VAL_HEADS-1 then
                ph <= P_DRAIN;
              else
                vh <= vh + 1;
                ph <= P_HKQ;
              end if;
            end if;

          when P_DRAIN =>
            if res_cnt = NCOL then ph <= P_WAITY; end if;

          when P_WAITY =>
            if ec_done = '1' then ph <= P_IDLE; end if;

        end case;

        -- The column issue itself, one cycle behind the request.  The
        -- per-column context is captured HERE, in the cycle st_first_i is
        -- high, from the registered address that produced this read -- not
        -- from the loop counters, which have already moved on.  That is the
        -- same class-1 mistake gdn_conv's tvalid made, avoided by
        -- construction rather than by an ordering argument.
        rp_svalid <= st_ren_i;
        rp_sfirst <= st_first_i;
        if st_first_i = '1' then
          rp_ctk0  <= tk0;
          rp_chsel <= '1' when (st_rh_i mod 2) = 1 else '0';
          rp_cse   <= se_rdata;
          rp_cev   <= seg_e(2);
          base     := (st_rh_i*DIM + st_rc_i)*16;
          rp_cvj   <= signed(vbuf(base+15 downto base));
        end if;

      end if;
    end if;
  end process;

  -- WHAT A PRODUCTION SCHEDULE WOULD OVERLAP, and is deliberately not
  -- overlapped here:
  --   * the three conv segments with each other (they share one gdn_conv, so
  --     this needs a second instance or a pipelined one);
  --   * the L2 norms and the scalar path with the sweep of the previous
  --     layer's tail -- both are short and both are on the critical path only
  --     because this file makes them so;
  --   * the conv/silu of layer L+1 with the emit stream of layer L.
  -- Each of those is a new seam.  None of them changes the DSP count, and the
  -- DSP count is what this file exists to settle.

end architecture;
