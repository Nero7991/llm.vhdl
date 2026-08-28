-- rtl/llama_top.vhd
-- THE INTEGRATION TOP LEVEL.  One token, N transformer blocks, one residual
-- stream, one sequencer, four unit adapters and a region file.
--
-- =====================================================================
-- WHY THIS FILE EXISTS
-- =====================================================================
-- Four subsystems were built and verified in isolation and NONE OF THEM HAD
-- EVER BEEN CONNECTED TO ANY OTHER:
--
--   A  INT4 matvec        matvec_int4 / matvec_core / weight_streamer.
--                         Verified end to end by sim/run_matvec.sh.
--   B  Gated DeltaNet     rtl/gdn_block.vhd, a real seven-unit top level,
--                         bit-identical under five independent producer skews.
--   C  gated attention    steps 3..8 verified contiguous.  THE LANE ARRAY
--                         `attn_lane_skel` IS A PRICING SKELETON AND COMPUTES
--                         NOTHING.  C cannot produce an attention output.
--   D  sequencer          seq_desc_fetch / seq_region_lock / seq_opdec /
--                         seq_vec_issue / seq_vec_res, all real.
--                         `seq_top_skel` is NOT real -- it instantiates
--                         nothing and has never been simulated.
--
-- Every integration defect this project has found came from a seam.  The D
-- owner demonstrated that two units each verified against a stub of the other
-- hid four defects between them.  This file is where the remaining seams
-- become reachable.
--
-- =====================================================================
-- WHAT IS REAL HERE AND WHAT IS NOT.  READ THIS BEFORE BELIEVING A NUMBER.
-- =====================================================================
-- REAL RTL, instantiated, not modelled (the DEFAULT configuration):
--   seq_desc_fetch   the descriptor walker
--   seq_opdec        opcode decode, region masks, exponent capture
--   seq_region_lock  the region locks and the per-region exponent store
--   seq_vec_issue    the D-ctrl to D-vec adapter
--   seq_vec_res      the residual add.  THE SPINE OF THE BLOCK LOOP.
--   matvec_int4      subsystem A, streaming weights over five AXI4 masters
--   gdn_block        subsystem B, seven units, with its six memories
--
-- REAL UNIT, SYNTHETIC INPUT.  Worth separating from both lists, because it
-- is the easiest thing here to overstate:
--   A's WEIGHTS       the descriptor base array past the 64-byte header is
--                     not fetched (seq_desc_fetch.vhd:113-115), so the
--                     adapter computes a per-step address block and whatever
--                     the memory returns there is what A multiplies.
--   B's conv taps,    deterministic functions of index, NOT yet read from
--   conv weights,     R_QKV / R_BETA / R_ALPHA.  Only `z`, the output gate,
--   scalars, w_mant   comes from a real region (R_Z).
--
-- BEHAVIOURAL MODELS, selected by generic, every one of them marked in its
-- own comment block and every one of them reporting what it is at time zero:
--   the region file          a flat array.  Really 14 BRAM/URAM regions.
--   unit A when A_BEHAV      a plain integer matvec with synthetic weights.
--   unit B when B_BEHAV      a first-order recurrence, NOT Gated DeltaNet.
--   unit C always            *** ATTENTION IS A STUB.  SEE THE BANNER. ***
--   unit E always            unreachable at NCARDS=1; errors if ever started.
--   the norm and swiglu      D-vec engines that do not exist as RTL yet.
--
-- `A_BEHAV` and `B_BEHAV` exist so that a failure can be BISECTED to a side of
-- a seam.  They are not an alternative implementation and nothing about them
-- is a claim.  With both false the top level instantiates the real A and the
-- real B.
--
-- =====================================================================
-- THE THREE SEAM RULES THIS FILE OBEYS, AND WHY EACH IS HERE
-- =====================================================================
-- (1) EVERY DESCRIPTOR FIELD A UNIT NEEDS IS LATCHED ONCE, AT `job_issue`,
--     AND READ FROM THE LATCH THEREAFTER.
--
--     `u_start` and `job_issue` ARE NOT THE SAME INSTANT.  seq_desc_fetch
--     drives `u_start` combinationally from `state = S_ISSUE`
--     (seq_desc_fetch.vhd:962) but sets `issue_r`, `live_bank` and `jvalid_r`
--     in the REGISTERED body of S_ISSUE (:788-794).  So `u_start` is high one
--     cycle BEFORE `job_issue`, and during that cycle the `job_*` outputs are
--     still decoding the PREVIOUS live bank.  An adapter that latches its
--     descriptor on `u_start` latches the previous job's shape.  That is
--     defect class (a) -- an input read at the wrong instant of a long
--     operation -- and it is the first thing a new adapter gets wrong.
--
--     It matters most for subsystem A, which reads `n_rows`, `n_cols`,
--     `w_exp`, `x_exp` and `out_mode` LIVE for the whole of a multi-thousand
--     cycle job (matvec_core.vhd:639, :771, :912, :932-934).  Only
--     `out_shift` is latched inside A.  So the register that holds A's
--     descriptor has to live HERE, in the adapter, or A silently computes
--     with a mixture of two jobs' shapes.
--
-- (2) EVERY COMPLETION IS CONVERTED TO A LEVEL HELD UNTIL `u_ack`.
--
--     seq_desc_fetch:235 states the contract: "u_done MUST be a level held
--     until u_ack".  Neither real unit meets it.  `matvec_core`'s `done` is a
--     one-cycle pulse with no ack (matvec_core.vhd:918-920).  `gdn_block`'s
--     `done` is a one-cycle pulse with no ack, and its own testbench polls
--     `busy` instead (tb_gdn_block.vhd:618-621).  That is defect class (b).
--     D happens to survive it, because its sticky `done_seen` capture is the
--     sole sampler, but surviving it is not the same as meeting it: D also
--     refuses to issue while `u_done` is still high (:787), so a unit whose
--     `done` is a pulse and whose `ready` is synthesised wrong deadlocks.
--     Both adapters therefore hold `done` themselves and clear it on `u_ack`.
--
-- (3) EVERY UN-STALLABLE PRODUCER IS TREATED AS A CORRECTNESS OBLIGATION.
--
--     `y_we` in A, and `y_valid` in B, have no ready.  A stall there LOSES a
--     beat, it does not delay it.  Both sinks in this file accept
--     unconditionally, every cycle, and `err_lost` is raised if a beat ever
--     arrives when the sink is not armed.  A region write that the lock drops
--     (`wr_gate` low) is likewise counted and reported, not ignored.
--
-- =====================================================================
-- WHAT THE TOP LEVEL DOES NOT DO.  STATED SO NOBODY HAS TO FIND OUT.
-- =====================================================================
--   * There is no attention.  See the C banner.  A schedule with
--     `attn_interval` > blocks has no attention step and is the only
--     configuration whose OUTPUT means anything at all.
--   * The weight base array past the 64-byte descriptor header is not
--     fetched.  seq_desc_fetch range-checks `nsub_w`/`nsub_s` against
--     NSUB_MAX and says in its own header that "fetching it is remaining
--     work" (:113-115).  So A's weights do not come from the descriptor.
--   * There is no sampler and no lm_head output.  The final A job is issued
--     with dst = R_NONE and its result is discarded.
--   * There is no KV cache, no position, no RoPE at this level.
--   * NCARDS > 1 is not wired.  OP_E_COLL reaches a unit adapter that raises
--     an error, deliberately, rather than silently completing.
--   * The release mask is an INPUT PORT.  seq_opdec finding (3) says it is a
--     whole-table liveness property with no descriptor field, so the host
--     computes it.  `sim/llama_sched_pkg.build_plan` is that computation.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.model_cfg_pkg.all;
use work.llama_map_pkg.all;

entity llama_top is
  generic(
    -- The model shape.  Defaults to the real build target.  A simulation
    -- passes `mk_shape_scaled(blocks, attn_interval)`.
    SHAPE   : shape_t := mk_shape(MODEL, NCARDS);

    -- Datapath widths.  These are the D-vec widths and they are the same ones
    -- sim/tb_seq_vec_seam.vhd closes seq_vec_res at.
    LANES   : positive := 8;
    MANT_W  : positive := 16;
    ACC_W   : positive := 32;
    EXP_W   : positive := 16;
    VN_W    : positive := 13;   -- D-vec element-count width
    ADDR_W  : positive := 16;   -- the lock's element-address width
    SEGS    : positive := 3;
    EPOCH_W : positive := 4;
    STEP_W  : positive := 11;

    -- Elements per region.  Every region is allocated the widest region's
    -- size, which is what a flat model costs and what a real build would not
    -- pay.  Stated because it is a model artefact, not a design choice.
    REGMAX  : positive := 4096;

    WDOG_LIMIT : positive := 200000;
    STRICT     : boolean  := true;

    -- Bisection switches.  See the header.  Both false = the real units.
    -- Both default FALSE: the real `matvec_int4` and the real `gdn_block` are
    -- instantiated, and the default configuration of a top level should be
    -- the real one.  Set either true to bisect a failure to a side of a seam.
    A_BEHAV : boolean := false;
    B_BEHAV : boolean := false;

    -- Set false only in a run that is deliberately measuring the banner cost.
    SHOUT   : boolean := true;

    -- SUBSYSTEM A's GEOMETRY IS NOT FREE.  `weight_streamer.vhd:100-103`
    -- asserts NPORTS_W * AXI_DW = ROWS_IF * BLK * 4, and the packed byte
    -- layout is only defined at AXI_DW = 128 with BLK = 32, so BLK = 32,
    -- AXI_DW = 128 and NPORTS_W = ROWS_IF is the whole legal family.
    A_BLK      : positive := 32;
    A_ROWS_IF  : positive := 4;
    A_FIFO     : positive := 64;
    A_MAXB     : positive := 16;
    -- Bytes of address space per A job, and where the first one starts.  Each
    -- job gets its own aligned block so two jobs cannot alias, and each port
    -- gets a 4 KB-aligned sub-region inside it because `axi_rd_port` requires
    -- a 4 KB-aligned base and pads sub-regions to whole bursts.
    A_JOB_STRIDE : natural := 16#8000#;
    A_MEM_BASE   : natural := 16#100000#;

    -- SUBSYSTEM B's LANE COUNTS.  These are the exact set `sim/tb_gdn_block.vhd`
    -- defaults to and `sim/run_gdn_block.sh` runs, which matters: the minimum
    -- legal `RECUR_SLOTS` in `gdn_recur_pipe` is SHAPE-DEPENDENT, so a smaller
    -- DIM or RECUR_LANES can silently need a larger slot count, and this
    -- project's stated failure mode for that shortcut is a wrong number rather
    -- than an elaboration error.
    B_CONV_LANES  : positive := 4;
    B_RECUR_LANES : positive := 4;
    B_RECUR_SLOTS : positive := 16;
    B_L2_LANES    : positive := 4;
    B_SILU_LANES  : positive := 8;
    B_RMS_LANES   : positive := 4
  );
  port(
    clk : in std_logic;
    rst : in std_logic;

    -- ---- host ----------------------------------------------------------
    go         : in  std_logic;
    abort      : in  std_logic;
    tbl_len    : in  unsigned(STEP_W-1 downto 0);
    host_x_exp : in  signed(EXP_W-1 downto 0);
    -- The whole-table liveness mask for the step currently being CHECKED.
    -- The host generator owns it; see seq_opdec finding (3).
    rel_mask   : in  std_logic_vector(NREGION-1 downto 0);

    busy       : out std_logic;
    tok_done   : out std_logic;
    tok_ack    : in  std_logic;
    err        : out std_logic;
    err_code   : out std_logic_vector(3 downto 0);
    err_step   : out unsigned(STEP_W-1 downto 0);
    steps_done : out unsigned(STEP_W-1 downto 0);

    -- ---- the descriptor table, a host-written URAM ----------------------
    -- Registered read of arbitrary latency, D is the only master.
    d_raddr  : out unsigned(15 downto 0);
    d_ren    : out std_logic;
    d_rdata  : in  std_logic_vector(63 downto 0);
    d_rvalid : in  std_logic;

    -- ---- host access to the region file --------------------------------
    -- The token embedding is written into R_X before `go`; the result is read
    -- back out of R_X after `tok_done`.
    hw_we    : in  std_logic;
    hw_reg   : in  natural range 0 to NREGION-1;
    hw_addr  : in  natural range 0 to REGMAX-1;
    hw_data  : in  signed(MANT_W-1 downto 0);
    hr_reg   : in  natural range 0 to NREGION-1;
    hr_addr  : in  natural range 0 to REGMAX-1;
    hr_data  : out signed(MANT_W-1 downto 0);

    -- ---- subsystem A's weight ports ------------------------------------
    -- NPORTS_W+1 = 5 AXI4 read-only masters: four weight sub-regions and one
    -- dedicated scale sub-region.  They leave the top level because the
    -- weights live in HBM and the memory model belongs to whoever is driving
    -- the top level, not inside it.  Tied off when A_BEHAV.
    m_arvalid : out std_logic_vector(A_NPORTS-1 downto 0);
    m_arready : in  std_logic_vector(A_NPORTS-1 downto 0) := (others => '0');
    m_araddr  : out std_logic_vector(A_NPORTS*32-1 downto 0);
    m_arlen   : out std_logic_vector(A_NPORTS*8-1 downto 0);
    m_arsize  : out std_logic_vector(A_NPORTS*3-1 downto 0);
    m_arburst : out std_logic_vector(A_NPORTS*2-1 downto 0);
    m_rvalid  : in  std_logic_vector(A_NPORTS-1 downto 0) := (others => '0');
    m_rready  : out std_logic_vector(A_NPORTS-1 downto 0);
    m_rdata   : in  std_logic_vector(A_NPORTS*128-1 downto 0)
              := (others => '0');
    m_rlast   : in  std_logic_vector(A_NPORTS-1 downto 0) := (others => '0');

    -- ---- observability, for the testbench and for the host -------------
    obs_issue  : out std_logic;                       -- 1 cycle per step
    obs_unit   : out unsigned(2 downto 0);
    obs_opcode : out unsigned(3 downto 0);
    obs_step   : out unsigned(STEP_W-1 downto 0);
    obs_dst    : out unsigned(7 downto 0);
    obs_cmp    : out std_logic;                       -- 1 cycle per completion
    -- The exponent the lock captured for this completion, and a running hash
    -- over EVERY element write the machine has made.  Together they separate
    -- "the exponent path is timing-dependent" from "the data path is", which
    -- is the first question to ask when a skew sweep differs.
    obs_cmp_exp : out signed(EXP_W-1 downto 0);
    obs_wsum    : out unsigned(31 downto 0);
    -- The residual's two operand exponents, valid on `obs_res_take`.  Exposed
    -- because a BFP add whose operands are far apart in scale DISCARDS one of
    -- them, silently and deterministically, and no sequencing property can
    -- see it.  See P6 in sim/tb_llama_top.vhd.
    obs_res_take : out std_logic;
    obs_res_ea   : out signed(EXP_W-1 downto 0);
    obs_res_eb   : out signed(EXP_W-1 downto 0);

    -- Sticky seam-fault counters.  Every one of these is a defect, not a
    -- statistic, and every one is silent in the arithmetic.
    err_lost_beat : out std_logic;   -- an un-stallable producer beat dropped
    err_gate_drop : out std_logic;   -- the lock refused a region write
    err_unit_stub : out std_logic;   -- a stub unit produced a result
    err_e_coll    : out std_logic    -- OP_E_COLL issued at NCARDS=1
  );
end entity;

architecture rtl of llama_top is

  -- ---- shape, derived once ---------------------------------------------
  constant SZ      : integer_vector := region_sizes(SHAPE);
  constant NG      : natural := (REGMAX + LANES - 1) / LANES;
  function clog2(n : natural) return natural is
    variable v : natural := 0;
  begin
    while (2**v) < n loop v := v + 1; end loop;
    return v;
  end function;
  constant LOG2L   : natural := clog2(LANES);
  constant GA_W    : natural := VN_W - LOG2L;

  -- ---- D core ----------------------------------------------------------
  signal go_walk    : std_logic;
  signal d_ren_i    : std_logic;
  signal job_valid, job_issue, job_cmp : std_logic;
  signal job_epoch  : unsigned(EPOCH_W-1 downto 0);
  signal job_unit   : unsigned(2 downto 0);
  signal job_opcode : unsigned(3 downto 0);
  signal job_flags  : std_logic_vector(7 downto 0);
  signal job_src, job_src2, job_dst : unsigned(7 downto 0);
  signal job_dst_off, job_n_rows, job_n_cols : unsigned(31 downto 0);
  signal job_w_exp, job_out_shift, job_const_exp : signed(31 downto 0);
  signal job_out_mode : std_logic_vector(7 downto 0);
  signal job_ordinal  : unsigned(7 downto 0);
  signal job_const_base : unsigned(31 downto 0);
  signal job_step   : unsigned(STEP_W-1 downto 0);

  signal chk_req, chk_bad : std_logic;
  signal chk_code : std_logic_vector(3 downto 0);
  signal chk_opcode : unsigned(3 downto 0);
  signal chk_src, chk_dst : unsigned(7 downto 0);
  signal chk_dst_off, chk_n_rows : unsigned(31 downto 0);

  signal u_start, u_ready, u_done, u_ack, u_err
       : std_logic_vector(NUNIT-1 downto 0) := (others => '0');
  signal u_done_epoch : std_logic_vector(NUNIT*EPOCH_W-1 downto 0)
                      := (others => '0');
  signal u_y_exp      : std_logic_vector(NUNIT*EXP_W-1 downto 0)
                      := (others => '0');

  signal host_busy : std_logic;
  signal lock_rst  : std_logic;
  signal iss_req, iss_commit, iss_prod : std_logic;
  signal iss_dst   : unsigned(7 downto 0);
  signal iss_seg   : unsigned(1 downto 0);
  signal iss_off, iss_n_rows : unsigned(ADDR_W-1 downto 0);
  signal iss_cons, iss_rel : std_logic_vector(NREGION-1 downto 0);
  signal iss_ok    : std_logic;
  signal iss_code  : std_logic_vector(3 downto 0);
  signal cmp_valid : std_logic;
  signal cmp_y_exp : signed(EXP_W-1 downto 0);
  signal viol, viol_ack : std_logic;
  signal viol_code : std_logic_vector(3 downto 0);
  signal viol_reg  : unsigned(7 downto 0);
  signal y_exp_taken : std_logic;
  signal y_exp_held  : signed(EXP_W-1 downto 0);
  signal viol_step   : unsigned(STEP_W-1 downto 0);
  signal viol_seen   : std_logic;
  signal lock_state  : std_logic_vector(2*NREGION-1 downto 0);

  signal wr_we    : std_logic := '0';
  signal wr_region: unsigned(7 downto 0) := (others => '0');
  signal wr_gate  : std_logic;
  -- THE EXPONENT READ PORT IS A SHARED RESOURCE, AND IT HAS TO BE ARBITRATED.
  --
  -- `seq_region_lock` has exactly ONE exponent read port and it is
  -- combinational (seq_region_lock.vhd:378-383).  `seq_vec_issue` drives it
  -- for the D-vec ops.  Unit A needs it too: A's `y_exp` is
  -- `w_exp + x_exp - out_shift`, and `x_exp` is the SOURCE region's captured
  -- exponent, which lives in the lock because hazard A3's fix made the
  -- exponent part of the locked object.
  --
  -- Wiring seq_vec_issue straight to the port and letting A read whatever it
  -- happened to be pointing at makes A's exponent a function of the D-vec
  -- adapter's internal state, i.e. OF TIMING.  That is what the first run of
  -- sim/tb_llama_top.vhd measured: R_X differed between descriptor-memory
  -- latency 1 and latency 2.  See docs/debugging/2026-08-28_llama-top-first-seams.md.
  signal exp_rd_region : unsigned(7 downto 0);
  signal exp_rd_seg    : unsigned(1 downto 0);
  signal exp_rd_data   : signed(EXP_W-1 downto 0);
  signal exp_rd_valid  : std_logic;
  signal vi_exp_region : unsigned(7 downto 0);
  signal vi_exp_seg    : unsigned(1 downto 0);
  -- Claimed by whichever NON-D-vec unit is active, at the same instant it
  -- latches its descriptor.  Units A and B both need a source exponent out of
  -- the lock; the lock has one port and D runs one unit at a time.
  -- ONE SIGNAL PER CLAIMANT, NOT ONE SHARED SIGNAL.  A first version had A
  -- and B both driving a single `ux_exp_region`, one signal for both.  `unsigned` is built on the
  -- RESOLVED type `std_logic`, so two drivers is not an elaboration error: the
  -- bits resolve to 'X', `to_integer` reports a metavalue and returns 0, and
  -- unit A silently reads region 0's exponent.  It is deterministic, so the
  -- skew sweep passed; the `exp_rd_valid` assertion below is what caught it.
  -- That is the second time in this file that a shared-resource defect
  -- survived a determinism property -- see defect 2 in
  -- docs/debugging/2026-08-28_llama-top-first-seams.md.
  signal a_exp_region  : unsigned(7 downto 0) := (others => '0');
  signal a_exp_seg     : unsigned(1 downto 0) := "00";
  signal b_exp_region  : unsigned(7 downto 0) := (others => '0');
  signal b_exp_seg     : unsigned(1 downto 0) := "00";
  signal c_exp_region  : unsigned(7 downto 0) := (others => '0');
  signal c_exp_seg     : unsigned(1 downto 0) := "00";

  -- The three q/k/v exponents subsystem A published for R_QKV this block,
  -- recorded so unit B can hand them to `gdn_exp_capture` before it starts.
  -- THIS IS A REAL CROSS-SUBSYSTEM OBLIGATION AND NOTHING CARRIED IT BEFORE:
  -- `gdn_block`'s conv path reads its tap exponents out of `gdn_exp_capture`,
  -- and the values that belong there are A's `y_exp` for the three wqkv
  -- projections.  No descriptor field says so; the schedule only guarantees
  -- the ordering.
  type qexp_t is array (0 to 2) of signed(7 downto 0);
  signal qkv_exp : qexp_t := (others => (others => '0'));
  signal last_dst : natural range 0 to 255 := 255;
  signal last_seg : natural range 0 to 2 := 0;
  signal b_seq_rst : std_logic := '0';

  -- ---- D-vec -----------------------------------------------------------
  signal v_start, v_ready, v_taken, v_done, v_ack, v_err
       : std_logic_vector(NVOP-1 downto 0) := (others => '0');
  signal v_y_exp : std_logic_vector(NVOP*EXP_W-1 downto 0) := (others => '0');
  signal v_n     : unsigned(VN_W-1 downto 0);
  signal v_exp_a, v_exp_b : signed(EXP_W-1 downto 0);
  signal v_reg_a, v_reg_b, v_reg_d : unsigned(7 downto 0);
  signal vi_epoch : unsigned(EPOCH_W-1 downto 0);
  signal vi_yexp  : signed(EXP_W-1 downto 0);
  signal vi_code  : std_logic_vector(3 downto 0);

  signal r_en   : std_logic;
  signal r_addr : unsigned(GA_W-1 downto 0);
  signal x_rdata, e_rdata : std_logic_vector(LANES*MANT_W-1 downto 0)
                          := (others => '0');
  signal w_we   : std_logic;
  signal w_addr : unsigned(GA_W-1 downto 0);
  signal w_be   : std_logic_vector(LANES-1 downto 0);
  signal w_data : std_logic_vector(LANES*MANT_W-1 downto 0);
  signal vres_exp : signed(EXP_W-1 downto 0);

  -- ======================================================================
  -- THE REGION FILE.
  --
  -- BEHAVIOURAL.  A flat array of NREGION*REGMAX 16-bit mantissas with one
  -- element read port, one element write port, one LANES-wide group read port
  -- with two operand selects, and one LANES-wide group write port.  Both read
  -- ports are REGISTERED, one cycle, because that is what a BRAM is and an
  -- adapter written against a combinational read does not survive the real
  -- thing.
  --
  -- READ_LATENCY IS TWO EDGES, NOT ONE, AND EVERY ADAPTER HERE DEPENDS ON IT.
  -- An adapter drives `ur_addr` from a clocked process, so the address is
  -- registered once there; the memory registers the data again.  An element
  -- whose address is issued at edge k is therefore readable at edge k+2.
  -- Consuming it at k+1 reads whatever the port held from the PREVIOUS unit's
  -- last access, which is a function of timing and not of data -- a wrong
  -- number that changes when a handshake moves.  See
  -- docs/debugging/2026-08-28_llama-top-first-seams.md.
  --
  -- A REAL IMPLEMENTATION would be 14 separately-sized BRAM/URAM regions with
  -- their own port counts, sized from `region_sizes(SHAPE)` rather than all
  -- at REGMAX, and the arbitration below would be per-region rather than
  -- global.  The single element port is not a simplification: subsystem D
  -- issues at most one unit at a time -- `cur_unit` in seq_desc_fetch is a
  -- scalar -- so no second unit can be reading.  When D grows overlap, this
  -- becomes a real arbiter and this comment becomes wrong.
  -- ======================================================================
  type buf_t is array (natural range <>) of signed(MANT_W-1 downto 0);
  subtype mem_t is buf_t(0 to NREGION*REGMAX-1);
  signal mem : mem_t := (others => (others => '0'));

  -- Per-CLIENT element ports, muxed below.  A client is not a unit: unit V is
  -- an ADAPTER in front of NVOP engines, and each engine needs its own port
  -- slot or the two of them are two drivers on one unresolved signal.  Slots
  -- 0..NUNIT-1 are the units (slot U_V is unused), slots NUNIT+v are the
  -- D-vec engines.
  constant NPORT : natural := NUNIT + NVOP;
  type nat_u  is array (0 to NPORT-1) of natural;
  type sig_u  is array (0 to NPORT-1) of signed(MANT_W-1 downto 0);
  signal ur_en   : std_logic_vector(NPORT-1 downto 0) := (others => '0');
  signal ur_reg  : nat_u := (others => 0);
  signal ur_addr : nat_u := (others => 0);
  signal uw_en   : std_logic_vector(NPORT-1 downto 0) := (others => '0');
  signal uw_reg  : nat_u := (others => 0);
  signal uw_addr : nat_u := (others => 0);
  signal uw_data : sig_u := (others => (others => '0'));

  signal el_ren   : std_logic := '0';
  signal el_reg   : natural range 0 to NREGION-1 := 0;
  signal el_addr  : natural range 0 to REGMAX-1 := 0;
  signal el_rdata : signed(MANT_W-1 downto 0) := (others => '0');
  signal el_we    : std_logic := '0';
  signal el_wreg  : natural range 0 to NREGION-1 := 0;
  signal el_waddr : natural range 0 to REGMAX-1 := 0;
  signal el_wdata : signed(MANT_W-1 downto 0) := (others => '0');

  -- The unit whose element ports are selected.  Latched at `job_issue` and
  -- held for the whole job, because the mux is read for the DURATION of a
  -- long operation and `job_unit` is not: it decodes the live bank, which is
  -- exactly what defect class (a) is about.
  signal act_unit : natural range 0 to NUNIT-1 := 0;
  -- Which D-vec engine owns the port while act_unit = U_V.  Latched at
  -- `v_taken`, which is the engine's own accept instant, not at `v_start`:
  -- seq_vec_issue holds `v_start` until the engine takes it, so `v_start` is
  -- high for an arbitrary number of cycles before anything is running.
  signal act_vop  : natural range 0 to NVOP-1 := 0;
  signal act_port : natural range 0 to NUNIT+NVOP-1 := 0;

  -- ---- sticky seam faults ----------------------------------------------
  signal f_lost  : std_logic := '0';
  signal f_gate  : std_logic := '0';
  signal f_stub  : std_logic := '0';
  signal f_ecoll : std_logic := '0';

  -- ---- helpers ---------------------------------------------------------
  function sat_m(v : integer) return signed is
    constant HI : integer := 2**(MANT_W-1) - 1;
    constant LO : integer := -(2**(MANT_W-1));
  begin
    if v > HI then return to_signed(HI, MANT_W); end if;
    if v < LO then return to_signed(LO, MANT_W); end if;
    return to_signed(v, MANT_W);
  end function;

  -- Subsystem A's shape limits, derived from SHAPE so nobody re-derives them.
  -- `n_cols` is the SOURCE width of an A job and `n_rows` the destination
  -- width.  The lm_head step's `n_rows` is the vocabulary shard, which is far
  -- larger than any region -- it is issued with dst = R_NONE and in raw mode,
  -- so `MAXROWS_BFP` (checked only in BFP mode) does not have to cover it and
  -- the y buffer does not have to hold it.
  function amax_cols(sh : shape_t) return positive is
    variable m : positive := sh.hidden;
  begin
    if sh.ffn      > m then m := sh.ffn;      end if;
    if val_dim(sh) > m then m := val_dim(sh); end if;
    if att_q(sh)   > m then m := att_q(sh);   end if;
    return m;
  end function;
  constant A_MAXCOLS : positive := amax_cols(SHAPE);
  constant A_MAXROWS : positive := region_max(SHAPE);

  -- The identity signed-int4 codebook: nibble value v selects cb(v), and the
  -- table makes cb(v) the two's-complement 4-bit integer that v encodes.  The
  -- production codebook is IQ4_NL; this one is chosen so that a wrong nibble
  -- order is a wrong number rather than a differently-scaled right one.
  function cb_int4(i : natural) return integer is
  begin
    if i < 8 then return i; else return i - 16; end if;
  end function;

  -- The synthetic weight of the behavioural A.  A deterministic function of
  -- (row, col, ordinal) only.  It is NOT a model of anything; it exists so
  -- that the residual stream carries a value that DEPENDS on every input and
  -- therefore cannot be right by accident under a skew sweep.
  function wsyn(r, c, o : natural) return integer is
  begin
    return ((r*13 + c*7 + o*29) mod 15) - 7;
  end function;

begin

  -- ======================================================================
  -- THE BANNERS.  Printed once, at time zero, at severity note, so that no
  -- run of this top level can be mistaken for inference.
  -- ======================================================================
  banner : process is
  begin
    if SHOUT then
      report LF
        & "==========================================================" & LF
        & " llama_top: THIS DOES NOT PERFORM INFERENCE YET." & LF
        & "==========================================================" & LF
        & " * ATTENTION IS A STUB.  Unit C returns a documented," & LF
        & "   obviously-wrong, well-formed pattern.  attn_lane_skel" & LF
        & "   is a pricing skeleton and computes nothing.  Any block" & LF
        & "   at an attention position produces a MEANINGLESS value" & LF
        & "   and every later block inherits it through the residual." & LF
        & " * unit A behavioural : " & boolean'image(A_BEHAV) & LF
        & " * unit B behavioural : " & boolean'image(B_BEHAV) & LF
        & " * norm and swiglu are behavioural in every configuration." & LF
        & " * the region file is a flat behavioural array." & LF
        & " * no weights are fetched: the descriptor base array past" & LF
        & "   the header is range-checked and not read." & LF
        & " What IS real: the schedule, the region locks, the" & LF
        & " exponent path, the residual add, and every handshake." & LF
        & "=========================================================="
        severity note;
    end if;
    wait;
  end process;

  -- ======================================================================
  -- REGION FILE
  -- ======================================================================
  -- Element port mux.  One-hot by construction; the assertion says so.
  act_port <= act_unit when act_unit /= U_V else NUNIT + act_vop;

  elmux : process(ur_en, ur_reg, ur_addr, uw_en, uw_reg, uw_addr, uw_data,
                  act_port, hw_we, hw_reg, hw_addr, hw_data) is
  begin
    el_ren   <= ur_en(act_port);
    el_reg   <= ur_reg(act_port);
    el_addr  <= ur_addr(act_port);
    if hw_we = '1' then
      el_we    <= '1';
      el_wreg  <= hw_reg;
      el_waddr <= hw_addr;
      el_wdata <= hw_data;
    else
      el_we    <= uw_en(act_port);
      el_wreg  <= uw_reg(act_port);
      el_waddr <= uw_addr(act_port);
      el_wdata <= uw_data(act_port);
    end if;
  end process;

  -- A unit that drives a port it does not own is a silent cross-region write,
  -- which is the worst failure this file can have: it corrupts the residual
  -- stream and every later block inherits it.  Checked every cycle.
  onehot : process(clk) is
    variable n : natural;
  begin
    if rising_edge(clk) then
      n := 0;
      for u in 0 to NPORT-1 loop
        if uw_en(u) = '1' and u /= act_port then n := n + 1; end if;
      end loop;
      assert n = 0
        report "llama_top: a unit that is not the active unit drove the "
             & "region write port.  This is a cross-region write."
        severity failure;
    end if;
  end process;

  memp : process(clk) is
    variable a : natural;
  begin
    if rising_edge(clk) then
      -- write-first, so an in-place overtake is visible rather than hidden
      if el_we = '1' then
        mem(el_wreg*REGMAX + el_waddr) <= el_wdata;
      end if;
      if w_we = '1' then
        for i in 0 to LANES-1 loop
          if w_be(i) = '1' then
            a := to_integer(unsigned(v_reg_d(6 downto 0)))*REGMAX
                 + to_integer(w_addr)*LANES + i;
            if a < NREGION*REGMAX then
              mem(a) <= signed(w_data((i+1)*MANT_W-1 downto i*MANT_W));
            end if;
          end if;
        end loop;
      end if;

      if el_ren = '1' then
        el_rdata <= mem(el_reg*REGMAX + el_addr);
      end if;

      -- The D-vec group read: ONE address, TWO operand regions.
      if r_en = '1' then
        for i in 0 to LANES-1 loop
          a := to_integer(unsigned(v_reg_a(6 downto 0)))*REGMAX
               + to_integer(r_addr)*LANES + i;
          if a < NREGION*REGMAX then
            x_rdata((i+1)*MANT_W-1 downto i*MANT_W) <= std_logic_vector(mem(a));
          else
            x_rdata((i+1)*MANT_W-1 downto i*MANT_W) <= (others => '0');
          end if;
          a := to_integer(unsigned(v_reg_b(6 downto 0)))*REGMAX
               + to_integer(r_addr)*LANES + i;
          if a < NREGION*REGMAX then
            e_rdata((i+1)*MANT_W-1 downto i*MANT_W) <= std_logic_vector(mem(a));
          else
            e_rdata((i+1)*MANT_W-1 downto i*MANT_W) <= (others => '0');
          end if;
        end loop;
      end if;
    end if;
  end process;

  hr_data <= mem(hr_reg*REGMAX + hr_addr);

  -- ======================================================================
  -- SUBSYSTEM D.  Three real units.  This port map is lifted from
  -- sim/tb_seq_vec_seam.vhd:510-627, which is the only place these three had
  -- ever been connected, and it is the authoritative reference for it.
  -- ======================================================================
  d_ren <= d_ren_i;

  u_fetch : entity work.seq_desc_fetch
    generic map(
      NREG => NREGION, EPOCH_W => EPOCH_W, NUNIT => NUNIT,
      NSUB_MAX => 64, STEP_W => STEP_W,
      WDOG_LIMIT => WDOG_LIMIT, STRICT_PROTO => STRICT)
    port map(
      clk => clk, rst => rst,
      go => go_walk, tbl_len => tbl_len, abort => abort,
      busy => busy, tok_done => tok_done, tok_ack => tok_ack,
      err => err, err_code => err_code, err_step => err_step,
      steps_done => steps_done,
      d_raddr => d_raddr, d_ren => d_ren_i, d_rdata => d_rdata,
      d_rvalid => d_rvalid,
      job_valid => job_valid, job_issue => job_issue, job_cmp => job_cmp,
      job_epoch => job_epoch, job_unit => job_unit, job_opcode => job_opcode,
      job_flags => job_flags, job_src => job_src, job_src2 => job_src2,
      job_dst => job_dst, job_dst_off => job_dst_off,
      job_n_rows => job_n_rows, job_n_cols => job_n_cols,
      job_w_exp => job_w_exp, job_out_shift => job_out_shift,
      job_out_mode => job_out_mode, job_ordinal => job_ordinal,
      job_const_base => job_const_base, job_const_exp => job_const_exp,
      job_step => job_step,
      chk_req => chk_req, chk_bad => chk_bad, chk_code => chk_code,
      chk_opcode => chk_opcode, chk_src => chk_src, chk_dst => chk_dst,
      chk_dst_off => chk_dst_off, chk_n_rows => chk_n_rows,
      u_start => u_start, u_ready => u_ready, u_done => u_done,
      u_ack => u_ack, u_err => u_err, u_done_epoch => u_done_epoch);

  u_opdec : entity work.seq_opdec
    generic map(
      NREG => NREGION, SEGS => SEGS, ADDR_W => ADDR_W, EXP_W => EXP_W,
      NUNIT => NUNIT, STEP_W => STEP_W,
      OPC_CONS => OPC_CONS_MAP,
      -- The three-way q|k|v exponent split.  R_QKV carries three captured
      -- exponents because the wqkv split exists precisely so q, k and v do
      -- not share a scale; the descriptor has no segment field, so the
      -- segment is inferred from `dst_off` against these two boundaries.
      MSEG_REG => R_QKV, MSEG_OFF1 => key_dim(SHAPE),
      MSEG_OFF2 => 2*key_dim(SHAPE),
      REL_NAIVE => false,
      HOST_REG => R_X, HOST_ROWS => SHAPE.hidden,
      STRICT => STRICT)
    port map(
      clk => clk, rst => rst,
      go_in => go, host_x_exp => host_x_exp,
      go_out => go_walk, host_busy => host_busy,
      chk_req => chk_req, chk_opcode => chk_opcode, chk_src => chk_src,
      chk_dst => chk_dst, chk_dst_off => chk_dst_off, chk_n_rows => chk_n_rows,
      chk_bad => chk_bad, chk_code => chk_code,
      rel_mask => rel_mask,
      job_issue => job_issue, job_cmp => job_cmp, job_unit => job_unit,
      job_src2 => job_src2, job_step => job_step,
      u_done => u_done, u_y_exp => u_y_exp,
      lock_rst => lock_rst,
      iss_req => iss_req, iss_commit => iss_commit, iss_prod => iss_prod,
      iss_dst => iss_dst, iss_seg => iss_seg, iss_off => iss_off,
      iss_n_rows => iss_n_rows, iss_cons => iss_cons, iss_rel => iss_rel,
      iss_ok => iss_ok, iss_code => iss_code,
      cmp_valid => cmp_valid, cmp_y_exp => cmp_y_exp,
      viol => viol, viol_code => viol_code, viol_ack => viol_ack,
      y_exp_taken => y_exp_taken, y_exp_held => y_exp_held,
      viol_step => viol_step, viol_seen => viol_seen);

  u_lock : entity work.seq_region_lock
    generic map(
      REG_SIZE => SZ, SEGS => SEGS, ADDR_W => ADDR_W, EXP_W => EXP_W,
      STRICT => STRICT)
    port map(
      clk => clk, rst => lock_rst,
      iss_req => iss_req, iss_commit => iss_commit, iss_prod => iss_prod,
      iss_dst => iss_dst, iss_seg => iss_seg, iss_off => iss_off,
      iss_n_rows => iss_n_rows, iss_cons => iss_cons, iss_rel => iss_rel,
      iss_ok => iss_ok, iss_code => iss_code,
      cmp_valid => cmp_valid, cmp_y_exp => cmp_y_exp,
      wr_we => wr_we, wr_region => wr_region, wr_gate => wr_gate,
      -- The exponent write port is unused: exponents reach the lock through
      -- seq_opdec's `cmp_valid`/`cmp_y_exp` capture, which is the path that
      -- freezes the exponent as part of the locked object (hazard A3).  A
      -- second, ungated path would reopen it.
      xw_we => '0', xw_region => (others => '0'), xw_seg => "00",
      xw_exp => (others => '0'), xw_gate => open,
      exp_rd_region => exp_rd_region, exp_rd_seg => exp_rd_seg,
      exp_rd_data => exp_rd_data, exp_rd_valid => exp_rd_valid,
      lock_state => lock_state,
      viol => viol, viol_ack => viol_ack, viol_code => viol_code,
      viol_region => viol_reg);

  -- Every region write in the machine is policed by the lock.  A beat outside
  -- the window [iss_commit, cmp_valid] of the job that owns the region is
  -- DROPPED by a real design, so it is counted here rather than ignored.
  wr_we     <= w_we or el_we;
  wr_region <= v_reg_d when w_we = '1'
               else to_unsigned(el_wreg, 8);

  gatechk : process(clk) is
  begin
    if rising_edge(clk) then
      if rst = '1' then
        f_gate <= '0';
      elsif wr_we = '1' and wr_gate /= '1' and hw_we = '0' then
        f_gate <= '1';
        report "llama_top: the region lock DROPPED a write to region "
             & integer'image(to_integer(wr_region))
             & ".  A unit is writing outside the window its own job holds."
          severity error;
      end if;
    end if;
  end process;

  -- ======================================================================
  -- SUBSYSTEM D-VEC.  seq_vec_issue is real; seq_vec_res is real; the norm
  -- and swiglu engines behind it do not exist as RTL and are modelled.
  -- ======================================================================
  u_vissue : entity work.seq_vec_issue
    generic map(
      NVOP => NVOP, OP_BASE => OP_VEC_NORM, MY_UNIT => U_V,
      NREG => NREGION, EXP_W => EXP_W, VN_W => VN_W,
      EPOCH_W => EPOCH_W, STEP_W => STEP_W, STRICT => STRICT)
    port map(
      clk => clk, rst => rst,
      job_issue => job_issue, job_unit => job_unit, job_opcode => job_opcode,
      job_epoch => job_epoch, job_src => job_src, job_src2 => job_src2,
      job_dst => job_dst, job_dst_off => job_dst_off,
      job_n_rows => job_n_rows, job_step => job_step,
      u_start => u_start(U_V), u_ack => u_ack(U_V),
      u_ready => u_ready(U_V), u_done => u_done(U_V), u_err => u_err(U_V),
      u_done_epoch => vi_epoch, u_y_exp => vi_yexp,
      exp_rd_region => vi_exp_region, exp_rd_seg => vi_exp_seg,
      exp_rd_data => exp_rd_data, exp_rd_valid => exp_rd_valid,
      v_start => v_start, v_ready => v_ready, v_taken => v_taken,
      v_done => v_done, v_ack => v_ack, v_err => v_err, v_y_exp => v_y_exp,
      v_n => v_n, v_exp_a => v_exp_a, v_exp_b => v_exp_b,
      v_reg_a => v_reg_a, v_reg_b => v_reg_b, v_reg_d => v_reg_d,
      iss_lat => open, exp_lat => open, err_code => vi_code);

  u_done_epoch((U_V+1)*EPOCH_W-1 downto U_V*EPOCH_W)
    <= std_logic_vector(vi_epoch);
  u_y_exp((U_V+1)*EXP_W-1 downto U_V*EXP_W) <= std_logic_vector(vi_yexp);

  -- The arbiter.  `act_unit` is latched at `job_issue` and held for the whole
  -- job, so the selection cannot move underneath a reader mid-operation --
  -- which is the same rule the element port mux obeys, for the same reason.
  exp_rd_region <= a_exp_region when act_unit = U_A else
                   b_exp_region when act_unit = U_B else
                   c_exp_region when act_unit = U_C else vi_exp_region;
  exp_rd_seg    <= a_exp_seg    when act_unit = U_A else
                   b_exp_seg    when act_unit = U_B else
                   c_exp_seg    when act_unit = U_C else vi_exp_seg;

  -- THE RESIDUAL.  Real RTL.  X <- X + ER, in place, twice per block.  This
  -- is the spine and it is the one arithmetic unit in the block loop that is
  -- not a model.
  u_vres : entity work.seq_vec_res
    generic map(LANES => LANES, MANT_W => MANT_W, ACC_W => ACC_W,
                EXP_W => EXP_W, ADDR_W => VN_W, STRICT => true)
    port map(
      clk => clk, rst => rst,
      ready => v_ready(V_RES), start => v_start(V_RES), i_n => v_n,
      i_exp_x => v_exp_a, i_exp_e => v_exp_b, i_taken => v_taken(V_RES),
      r_en => r_en, r_addr => r_addr, x_rdata => x_rdata, e_rdata => e_rdata,
      w_we => w_we, w_addr => w_addr, w_be => w_be, w_data => w_data,
      done => v_done(V_RES), done_ack => v_ack(V_RES),
      o_exp => vres_exp, o_shift => open, o_sat => open,
      err => v_err(V_RES));

  v_y_exp((V_RES+1)*EXP_W-1 downto V_RES*EXP_W) <= std_logic_vector(vres_exp);

  -- ======================================================================
  -- THE TWO D-VEC ENGINES THAT DO NOT EXIST.
  --
  -- BEHAVIOURAL MODEL.  rmsnorm and swiglu both have real RTL in this repo
  -- (rtl/rmsnorm_rs.vhd, rtl/swiglu.vhd) and NEITHER has a D-vec adapter:
  -- they take their own shapes and handshakes and nothing translates
  -- seq_vec_issue's by-value protocol to them.  Building those adapters is
  -- remaining work.  These models produce a well-formed, deterministic,
  -- input-dependent result over the same handshake, so the SEQUENCING is
  -- exercised and the arithmetic is not claimed.
  --
  -- norm  : out(i) = in(i) - (sum(in) / n)      mean removal, not rmsnorm
  -- swiglu: out(i) = (a(i) * b(i)) / 64         no gate, not swiglu
  -- ======================================================================
  gen_vstub : for vi in 0 to NVOP-1 generate
    gv : if vi /= V_RES generate
      signal rdy  : std_logic := '1';
      signal dn   : std_logic := '0';
      signal tk   : std_logic := '0';
      signal yexp : signed(EXP_W-1 downto 0) := (others => '0');
    begin
      v_ready(vi) <= rdy;
      v_done(vi)  <= dn;
      v_taken(vi) <= tk;
      v_err(vi)   <= '0';
      v_y_exp((vi+1)*EXP_W-1 downto vi*EXP_W) <= std_logic_vector(yexp);

      vproc : process(clk) is
        type st_t is (S_IDLE, S_RD, S_WR, S_DONE);
        variable st   : st_t := S_IDLE;
        variable buf  : buf_t(0 to REGMAX-1);
        variable buf2 : buf_t(0 to REGMAX-1);
        variable n    : natural := 0;
        variable k    : natural := 0;
        variable acc  : integer := 0;
        variable pass : natural := 0;
      begin
        if rising_edge(clk) then
          tk <= '0';
          ur_en(NUNIT+vi) <= '0';
          uw_en(NUNIT+vi) <= '0';
          if rst = '1' then
            st := S_IDLE; rdy <= '1'; dn <= '0'; k := 0; pass := 0;
          else
            case st is
              when S_IDLE =>
                if v_start(vi) = '1' and rdy = '1' then
                  tk   <= '1';
                  rdy  <= '0';
                  n    := to_integer(v_n);
                  k    := 0;
                  pass := 0;
                  acc  := 0;
                  st   := S_RD;
                end if;

              when S_RD =>
                -- TWO cycles of read latency, not one.  See READ_LATENCY in
                -- the region-file header: the address is registered in this
                -- process and the data is registered in the memory, so the
                -- element issued at edge k is readable at edge k+2.  The loop
                -- therefore runs to n+1 and drains.  Each pass drains fully
                -- before the next begins, so the (region, address) pair in
                -- flight always belongs to the pass that issued it.
                if k < n then
                  ur_en(NUNIT+vi)   <= '1';
                  ur_reg(NUNIT+vi)  <= to_integer(unsigned(v_reg_a(6 downto 0)))
                                  when pass = 0
                                  else to_integer(unsigned(v_reg_b(6 downto 0)));
                  ur_addr(NUNIT+vi) <= k;
                end if;
                if k >= 2 then
                  if pass = 0 then buf(k-2) := el_rdata; acc := acc + to_integer(el_rdata);
                  else                buf2(k-2) := el_rdata; end if;
                end if;
                if k = n+1 then
                  if pass = 0 and vi = V_SWG then
                    pass := 1; k := 0;
                  else
                    k := 0;
                    st := S_WR;
                  end if;
                else
                  k := k + 1;
                end if;

              when S_WR =>
                uw_en(NUNIT+vi)   <= '1';
                uw_reg(NUNIT+vi)  <= to_integer(unsigned(v_reg_d(6 downto 0)));
                uw_addr(NUNIT+vi) <= k;
                if vi = V_NORM then
                  uw_data(NUNIT+vi) <= sat_m(to_integer(buf(k)) - (acc / n));
                else
                  uw_data(NUNIT+vi) <= sat_m((to_integer(buf(k))
                                         * to_integer(buf2(k))) / 64);
                end if;
                if k = n-1 then
                  k  := 0;
                  st := S_DONE;
                else
                  k := k + 1;
                end if;

              when S_DONE =>
                dn <= '1';
                -- A deterministic, input-dependent exponent.  It must not be
                -- a constant: a shared or stale capture anywhere in the
                -- exponent path has to become a WRONG NUMBER, not a repeat of
                -- the right one.
                yexp <= v_exp_a + to_signed(vi, EXP_W);
                if v_ack(vi) = '1' then
                  dn  <= '0';
                  rdy <= '1';
                  st  := S_IDLE;
                end if;
            end case;
          end if;
        end if;
      end process;
    end generate;
  end generate;

  -- ======================================================================
  -- UNIT A.  BEHAVIOURAL when A_BEHAV.
  --
  -- The adapter half is REAL in both configurations and is where the D-to-A
  -- seam lives: latch the descriptor at `job_issue` (never at `u_start`),
  -- hold `n_rows`/`n_cols`/`w_exp`/`x_exp`/`out_mode` stable for the whole
  -- job, convert A's one-cycle `done` pulse into a level held until `u_ack`,
  -- and synthesise the `u_ready` that A does not have.
  --
  -- BEHAVIOURAL MODEL: y(r) = sat16( sum_c x(c)*wsyn(r,c,ord) >> out_shift ).
  -- The weights are synthetic.  A's arithmetic is verified by
  -- sim/run_matvec.sh and is NOT what this file is testing.
  -- ======================================================================
  ga_behav : if A_BEHAV generate
    signal rdy  : std_logic := '1';
    signal dn   : std_logic := '0';
    signal ep   : unsigned(EPOCH_W-1 downto 0) := (others => '0');
    signal yexp : signed(EXP_W-1 downto 0) := (others => '0');
  begin
    u_ready(U_A) <= rdy;
    u_done(U_A)  <= dn;
    u_err(U_A)   <= '0';
    u_done_epoch((U_A+1)*EPOCH_W-1 downto U_A*EPOCH_W) <= std_logic_vector(ep);
    u_y_exp((U_A+1)*EXP_W-1 downto U_A*EXP_W) <= std_logic_vector(yexp);

    ap : process(clk) is
      type st_t is (S_IDLE, S_XRD, S_EXP, S_MUL, S_DONE);
      variable st   : st_t := S_IDLE;
      variable xb   : buf_t(0 to REGMAX-1);
      -- THE LATCHED DESCRIPTOR.  Seam rule (1).
      variable j_src, j_dst, j_off, j_rows, j_cols, j_ord : natural := 0;
      variable j_shift : integer := 0;
      variable j_wexp  : integer := 0;
      variable j_live  : boolean := false;
      variable k, r    : natural := 0;
      variable acc     : integer := 0;
      variable xexp    : integer := 0;
    begin
      if rising_edge(clk) then
        ur_en(U_A) <= '0';
        uw_en(U_A) <= '0';
        if rst = '1' then
          st := S_IDLE; rdy <= '1'; dn <= '0'; j_live := false;
        else
          -- Latch at job_issue.  NOT at u_start: u_start leads job_issue by
          -- one cycle and job_* still decodes the previous live bank there.
          if job_issue = '1' and to_integer(job_unit) = U_A then
            j_src   := to_integer(job_src(6 downto 0));
            j_dst   := to_integer(job_dst(6 downto 0));
            j_off   := to_integer(job_dst_off(15 downto 0));
            j_rows  := to_integer(job_n_rows(15 downto 0));
            j_cols  := to_integer(job_n_cols(15 downto 0));
            j_ord   := to_integer(job_ordinal);
            j_shift := to_integer(job_out_shift(15 downto 0));
            j_wexp  := to_integer(job_w_exp(15 downto 0));
            j_live  := true;
            ep      <= job_epoch;
            rdy     <= '0';
            k       := 0;
            st      := S_XRD;
            -- Claim the exponent read port for THIS job's source, at the same
            -- instant the descriptor is latched.  A's sources are never the
            -- multi-segment region, so segment 0 is the whole story here; a
            -- source that could be R_QKV would have to infer the segment from
            -- the offset the way seq_opdec's MSEG mechanism does.
            a_exp_region <= job_src;
            a_exp_seg    <= "00";
          end if;

          case st is
            when S_IDLE => null;

            when S_XRD =>
              -- Two cycles of read latency; the loop runs to j_cols+1 and
              -- drains.  Consuming at k-1 reads the PREVIOUS unit's last
              -- result instead of this region's element 0, which is a
              -- timing-dependent wrong number and is exactly what
              -- sim/tb_llama_top.vhd's write-hash trace caught at
              -- completion 1.
              if k < j_cols then
                ur_en(U_A)   <= '1';
                ur_reg(U_A)  <= j_src;
                ur_addr(U_A) <= k;
              end if;
              if k >= 2 then xb(k-2) := el_rdata; end if;
              if k = j_cols+1 then
                k := 0;
                st := S_EXP;
              else
                k := k + 1;
              end if;

            when S_EXP =>
              -- x_exp comes out of the LOCK, not out of the descriptor: it is
              -- the producing job's captured exponent and it is part of the
              -- locked object.  This is the read half of hazard A3's fix.
              --
              -- `a_exp_region` was driven at the LATCH instant and has been
              -- stable ever since, and the lock's read is combinational, so
              -- this samples a value that has not moved.  Reading the port
              -- without owning it is what produced the first skew difference
              -- this bench found.
              assert exp_rd_valid = '1'
                report "llama_top: unit A read region "
                     & integer'image(to_integer(a_exp_region))
                     & "'s exponent before anything captured it."
                severity error;
              xexp := to_integer(exp_rd_data);
              r    := 0;
              st   := S_MUL;

            when S_MUL =>
              acc := 0;
              for c in 0 to REGMAX-1 loop
                if c < j_cols then
                  acc := acc + to_integer(xb(c)) * wsyn(r, c, j_ord);
                end if;
              end loop;
              if j_dst < NREGION then
                uw_en(U_A)   <= '1';
                uw_reg(U_A)  <= j_dst;
                uw_addr(U_A) <= j_off + r;
                if j_shift >= 0 and j_shift < 31 then
                  uw_data(U_A) <= sat_m(acc / (2**j_shift));
                else
                  uw_data(U_A) <= sat_m(acc);
                end if;
              end if;
              if r = j_rows-1 then
                st := S_DONE;
              else
                r := r + 1;
              end if;

            when S_DONE =>
              -- Seam rule (2): a LEVEL, held until u_ack.
              dn   <= '1';
              yexp <= to_signed(j_wexp + xexp - j_shift, EXP_W);
              if u_ack(U_A) = '1' then
                dn     <= '0';
                rdy    <= '1';
                j_live := false;
                st     := S_IDLE;
              end if;
          end case;
        end if;
      end if;
    end process;
  end generate;


  -- With the behavioural A there is no weight streamer, so the AXI masters
  -- are tied off rather than left floating.
  ga_tie : if A_BEHAV generate
    m_arvalid <= (others => '0');
    m_araddr  <= (others => '0');
    m_arlen   <= (others => '0');
    m_arsize  <= (others => '0');
    m_arburst <= (others => '0');
    m_rready  <= (others => '0');
  end generate;

  -- ======================================================================
  -- UNIT A.  THE REAL `matvec_int4`, and the D-to-A seam.
  --
  -- This adapter is the seam.  Everything it does is one of the three rules
  -- in the header, applied to a unit that meets none of D's conventions:
  --
  --  * A HAS NO `ready`.  seq_desc_fetch holds `u_start` until it sees one
  --    (:787) and refuses to issue while `u_done` is high.  The adapter
  --    synthesises `ready` from its own idle state.
  --
  --  * A's `done` IS A ONE-CYCLE PULSE WITH NO ACK (matvec_core.vhd:918-920).
  --    D's contract is a LEVEL held until `u_ack` (seq_desc_fetch.vhd:235).
  --    The adapter converts.
  --
  --  * A READS `n_rows`, `n_cols`, `w_exp`, `x_exp` AND `out_mode` LIVE for
  --    the whole job (matvec_core.vhd:639, :771, :912, :932-934).  Only
  --    `out_shift` is latched inside A.  So the adapter holds all six in its
  --    own registers, written once at `job_issue` and never again while the
  --    job runs.  Driving them from `job_*` would be defect class (a) with a
  --    multi-thousand-cycle exposure window.
  --
  --  * A's `y_we` HAS NO READY.  A stall LOSES a beat.  The sink below
  --    accepts every beat unconditionally into a buffer and drains afterwards,
  --    and raises `err_lost_beat` if a beat ever arrives outside the window
  --    or past the end of the buffer.  A beat cannot be refused, so the only
  --    honest design is one that cannot refuse.
  --
  --  * `cb_we` AND `start` MUST NOT SHARE AN EDGE.  matvec_core.vhd:565-571
  --    keeps an empty branch specifically as that interlock, and a `start` on
  --    the same edge as the last codebook write is silently DROPPED, not
  --    flagged.  S_CBGAP exists for that and for nothing else.
  --
  -- WHAT IS STILL SYNTHETIC: the weights.  The descriptor's base array past
  -- the 64-byte header is not fetched by `seq_desc_fetch` (its header,
  -- :113-115, "fetching it is remaining work"), so the adapter computes a
  -- per-step address block instead.  Whatever the memory returns at those
  -- addresses is what A multiplies.  A's ARITHMETIC is verified by
  -- sim/run_matvec.sh against its own oracle; what is verified HERE is the
  -- seam.
  -- ======================================================================
  ga_real : if not A_BEHAV generate
    signal rdy  : std_logic := '1';
    signal dn   : std_logic := '0';
    signal uerr : std_logic := '0';
    signal ep   : unsigned(EPOCH_W-1 downto 0) := (others => '0');
    signal yexp : signed(EXP_W-1 downto 0) := (others => '0');

    signal mv_start : std_logic := '0';
    signal mv_done, mv_err, mv_sat : std_logic;
    signal r_rows, r_cols, r_shift, r_wexp, r_xexp : std_logic_vector(31 downto 0)
         := (others => '0');
    signal r_mode  : std_logic_vector(1 downto 0) := "00";
    signal r_wbase : std_logic_vector(A_ROWS_IF*32-1 downto 0) := (others => '0');
    signal r_wbeat : std_logic_vector(31 downto 0) := (others => '0');
    signal r_sbase : std_logic_vector(31 downto 0) := (others => '0');
    signal r_sbeat : std_logic_vector(31 downto 0) := (others => '0');

    signal cb_we   : std_logic := '0';
    signal cb_addr : std_logic_vector(3 downto 0) := (others => '0');
    signal cb_data : std_logic_vector(7 downto 0) := (others => '0');
    signal x_we    : std_logic := '0';
    signal x_waddr : std_logic_vector(15 downto 0) := (others => '0');
    signal x_wdata : std_logic_vector(15 downto 0) := (others => '0');

    signal y_we    : std_logic;
    signal y_addr  : std_logic_vector(15 downto 0);
    signal y_data  : std_logic_vector(A_ROWS_IF*64-1 downto 0);
    signal y_mask  : std_logic_vector(A_ROWS_IF-1 downto 0);
    signal y_expv  : std_logic_vector(31 downto 0);
  begin
    u_ready(U_A) <= rdy;
    u_done(U_A)  <= dn;
    u_err(U_A)   <= uerr;
    u_done_epoch((U_A+1)*EPOCH_W-1 downto U_A*EPOCH_W) <= std_logic_vector(ep);
    u_y_exp((U_A+1)*EXP_W-1 downto U_A*EXP_W) <= std_logic_vector(yexp);

    u_mv : entity work.matvec_int4
      generic map(
        BLK => A_BLK, ROWS_IF => A_ROWS_IF, NPORTS_W => A_ROWS_IF,
        AXI_DW => 128, ADDR_W => 32,
        MAXCOLS => A_MAXCOLS, MAXROWS_BFP => A_MAXROWS,
        FIFO_DEPTH => A_FIFO, MAXB => A_MAXB, MAXOUT => 2)
      port map(
        clk => clk, rst => rst,
        start => mv_start,
        n_rows => r_rows, n_cols => r_cols, out_shift => r_shift,
        w_exp => r_wexp, x_exp => r_xexp, out_mode => r_mode,
        w_base => r_wbase, w_beats => r_wbeat,
        s_base => r_sbase, s_beats => r_sbeat,
        cb_we => cb_we, cb_addr => cb_addr, cb_data => cb_data,
        x_we => x_we, x_waddr => x_waddr, x_wdata => x_wdata,
        m_arvalid => m_arvalid, m_arready => m_arready, m_araddr => m_araddr,
        m_arlen => m_arlen, m_arsize => m_arsize, m_arburst => m_arburst,
        m_rvalid => m_rvalid, m_rready => m_rready, m_rdata => m_rdata,
        m_rlast => m_rlast,
        y_we => y_we, y_addr => y_addr, y_data => y_data, y_mask => y_mask,
        y_exp => y_expv, done => mv_done, err => mv_err, sat_event => mv_sat,
        dbg_wbeat => open, dbg_wstarve => open);

    ap : process(clk) is
      type st_t is (S_IDLE, S_CB, S_CBGAP, S_XRD, S_EXP, S_GO, S_RUN,
                    S_DRAIN, S_DONE);
      variable st : st_t := S_IDLE;
      variable yb : buf_t(0 to A_MAXROWS-1);
      -- THE LATCHED DESCRIPTOR.  Seam rule (1).  Nothing below reads `job_*`.
      variable j_src, j_dst, j_off, j_rows, j_cols, j_step : natural := 0;
      variable j_shift, j_wexp : integer := 0;
      variable j_mode : std_logic_vector(1 downto 0) := "00";
      variable k, r   : natural := 0;
      variable tiles, nb, base : natural := 0;
      variable a  : natural;
    begin
      if rising_edge(clk) then
        ur_en(U_A) <= '0';
        uw_en(U_A) <= '0';
        cb_we      <= '0';
        x_we       <= '0';
        mv_start   <= '0';

        if rst = '1' then
          st := S_IDLE; rdy <= '1'; dn <= '0'; uerr <= '0';
        else
          if job_issue = '1' and to_integer(job_unit) = U_A then
            j_src   := to_integer(job_src(6 downto 0));
            j_dst   := to_integer(job_dst(6 downto 0));
            j_off   := to_integer(job_dst_off(15 downto 0));
            j_rows  := to_integer(job_n_rows(15 downto 0));
            j_cols  := to_integer(job_n_cols(15 downto 0));
            j_shift := to_integer(job_out_shift(15 downto 0));
            j_wexp  := to_integer(job_w_exp(15 downto 0));
            j_mode  := job_out_mode(1 downto 0);
            j_step  := to_integer(job_step);
            ep      <= job_epoch;
            uerr    <= '0';
            rdy     <= '0';
            k       := 0;
            st      := S_CB;
            a_exp_region <= job_src;
            a_exp_seg    <= "00";
          end if;

          -- ---- the un-refusable y sink.  Outside the FSM on purpose: a
          -- beat that arrives in a state that did not expect it must still be
          -- ACCEPTED and then reported, never dropped.
          if y_we = '1' then
            if st /= S_RUN then
              f_lost <= '1';
              report "llama_top: unit A emitted a y beat outside its run "
                   & "window.  y_we has no ready, so this beat is LOST."
                severity error;
            end if;
            for rr in 0 to A_ROWS_IF-1 loop
              if y_mask(rr) = '1' then
                a := to_integer(unsigned(y_addr)) + rr;
                if j_dst < NREGION then
                  if a < A_MAXROWS then
                    yb(a) := signed(y_data(rr*64+MANT_W-1 downto rr*64));
                  else
                    f_lost <= '1';
                    report "llama_top: unit A produced row "
                         & integer'image(a) & " past the y buffer ("
                         & integer'image(A_MAXROWS) & ")." severity error;
                  end if;
                end if;
              end if;
            end loop;
          end if;

          case st is
            when S_IDLE => null;

            when S_CB =>
              cb_we   <= '1';
              cb_addr <= std_logic_vector(to_unsigned(k, 4));
              cb_data <= std_logic_vector(to_signed(cb_int4(k), 8));
              if k = 15 then k := 0; st := S_CBGAP; else k := k + 1; end if;

            when S_CBGAP =>
              -- ONE dead cycle, so `start` can never share an edge with the
              -- last `cb_we`.  matvec_core drops such a start silently.
              st := S_XRD;

            when S_XRD =>
              if k < j_cols then
                ur_en(U_A)   <= '1';
                ur_reg(U_A)  <= j_src;
                ur_addr(U_A) <= k;
              end if;
              if k >= 2 then
                x_we    <= '1';
                x_waddr <= std_logic_vector(to_unsigned(k-2, 16));
                x_wdata <= std_logic_vector(el_rdata);
              end if;
              if k = j_cols+1 then
                k := 0;
                st := S_EXP;
              else
                k := k + 1;
              end if;

            when S_EXP =>
              assert exp_rd_valid = '1'
                report "llama_top: unit A read region "
                     & integer'image(to_integer(a_exp_region))
                     & "'s exponent before anything captured it."
                severity error;
              nb    := (j_cols + A_BLK - 1) / A_BLK;
              tiles := (j_rows + A_ROWS_IF - 1) / A_ROWS_IF;
              base  := A_MEM_BASE + j_step * A_JOB_STRIDE;
              r_rows  <= std_logic_vector(to_signed(j_rows, 32));
              r_cols  <= std_logic_vector(to_signed(j_cols, 32));
              r_shift <= std_logic_vector(to_signed(j_shift, 32));
              r_wexp  <= std_logic_vector(to_signed(j_wexp, 32));
              r_xexp  <= std_logic_vector(resize(exp_rd_data, 32));
              r_mode  <= j_mode;
              for p in 0 to A_ROWS_IF-1 loop
                r_wbase((p+1)*32-1 downto p*32)
                  <= std_logic_vector(to_unsigned(base + p*4096, 32));
              end loop;
              r_sbase <= std_logic_vector(
                           to_unsigned(base + A_ROWS_IF*4096, 32));
              r_wbeat <= std_logic_vector(to_signed(tiles*nb, 32));
              -- one uint16 scale per (tile, block, row), 16 bytes per beat
              r_sbeat <= std_logic_vector(
                           to_signed((tiles*nb*A_ROWS_IF*2 + 15) / 16, 32));
              st := S_GO;

            when S_GO =>
              mv_start <= '1';
              r        := 0;
              st       := S_RUN;

            when S_RUN =>
              if mv_done = '1' then
                uerr <= mv_err;
                r    := 0;
                if j_dst < NREGION then st := S_DRAIN; else st := S_DONE; end if;
              end if;

            when S_DRAIN =>
              uw_en(U_A)   <= '1';
              uw_reg(U_A)  <= j_dst;
              uw_addr(U_A) <= j_off + r;
              uw_data(U_A) <= yb(r);
              if r = j_rows-1 then st := S_DONE; else r := r + 1; end if;

            when S_DONE =>
              dn   <= '1';
              yexp <= resize(signed(y_expv), EXP_W);
              if u_ack(U_A) = '1' then
                dn  <= '0';
                rdy <= '1';
                st  := S_IDLE;
              end if;
          end case;
        end if;
      end if;
    end process;
  end generate;

  -- ======================================================================
  -- UNIT B.  BEHAVIOURAL when B_BEHAV.
  --
  -- BEHAVIOURAL MODEL, AND IT IS NOT GATED DELTANET.  It reads R_QKV, R_Z,
  -- R_BETA and R_ALPHA -- the same four regions the real B consumes, which is
  -- what makes the region-lock consume mask reachable -- and produces
  --   y(i) = sat16( (qkv(i) + qkv(2*key_dim+i)) * z(i) / 256 + beta(head) )
  -- which is a first-order function of every one of its inputs and of nothing
  -- else.  It has no recurrent state, no conv, no L2 norm and no gate.
  -- ======================================================================
  gb_behav : if B_BEHAV generate
    signal rdy  : std_logic := '1';
    signal dn   : std_logic := '0';
    signal ep   : unsigned(EPOCH_W-1 downto 0) := (others => '0');
    signal yexp : signed(EXP_W-1 downto 0) := (others => '0');
  begin
    u_ready(U_B) <= rdy;
    u_done(U_B)  <= dn;
    u_err(U_B)   <= '0';
    u_done_epoch((U_B+1)*EPOCH_W-1 downto U_B*EPOCH_W) <= std_logic_vector(ep);
    u_y_exp((U_B+1)*EXP_W-1 downto U_B*EXP_W) <= std_logic_vector(yexp);

    bp : process(clk) is
      type st_t is (S_IDLE, S_RD, S_WR, S_DONE);
      variable st  : st_t := S_IDLE;
      variable qb, zb, bb : buf_t(0 to REGMAX-1);
      variable j_dst, j_rows, j_ord : natural := 0;
      variable j_wexp : integer := 0;
      variable k    : natural := 0;
      variable pass : natural := 0;
      constant KD   : natural := key_dim(SHAPE);
      constant HD   : natural := SHAPE.head_dim;
    begin
      if rising_edge(clk) then
        ur_en(U_B) <= '0';
        uw_en(U_B) <= '0';
        if rst = '1' then
          st := S_IDLE; rdy <= '1'; dn <= '0';
        else
          if job_issue = '1' and to_integer(job_unit) = U_B then
            j_dst  := to_integer(job_dst(6 downto 0));
            j_rows := to_integer(job_n_rows(15 downto 0));
            j_ord  := to_integer(job_ordinal);
            j_wexp := to_integer(job_w_exp(15 downto 0));
            ep     <= job_epoch;
            rdy    <= '0';
            k      := 0;
            pass   := 0;
            st     := S_RD;
          end if;

          case st is
            when S_IDLE => null;

            when S_RD =>
              -- three passes: qkv value half, z, beta
              if k < j_rows then
                ur_en(U_B) <= '1';
                case pass is
                  when 0 =>
                    ur_reg(U_B)  <= R_QKV;
                    ur_addr(U_B) <= 2*KD + k;
                  when 1 =>
                    ur_reg(U_B)  <= R_Z;
                    ur_addr(U_B) <= k;
                  when others =>
                    ur_reg(U_B)  <= R_BETA;
                    ur_addr(U_B) <= k / HD;
                end case;
              end if;
              if k >= 2 then
                case pass is
                  when 0      => qb(k-2) := el_rdata;
                  when 1      => zb(k-2) := el_rdata;
                  when others => bb(k-2) := el_rdata;
                end case;
              end if;
              if k = j_rows+1 then
                k := 0;
                if pass = 2 then st := S_WR; else pass := pass + 1; end if;
              else
                k := k + 1;
              end if;

            when S_WR =>
              uw_en(U_B)   <= '1';
              uw_reg(U_B)  <= j_dst;
              uw_addr(U_B) <= k;
              uw_data(U_B) <= sat_m((to_integer(qb(k)) * to_integer(zb(k)))
                                    / 256 + to_integer(bb(k)));
              if k = j_rows-1 then
                st := S_DONE;
              else
                k := k + 1;
              end if;

            when S_DONE =>
              dn   <= '1';
              yexp <= to_signed(j_wexp + j_ord, EXP_W);
              if u_ack(U_B) = '1' then
                dn  <= '0';
                rdy <= '1';
                st  := S_IDLE;
              end if;
          end case;
        end if;
      end if;
    end process;
  end generate;

  -- ======================================================================
  -- UNIT B.  THE REAL `gdn_block`, its six memories, and the D-to-B seam.
  --
  -- WHAT IS REAL HERE:
  --   * `gdn_block` itself, seven units, at the exact generic set
  --     `sim/tb_gdn_block.vhd` defaults to and `sim/run_gdn_block.sh` runs.
  --   * the six memories it needs, at the LATENCIES ITS PORT CONTRACT
  --     SPECIFIES, which are not all the same and getting one wrong is a
  --     silent wrong number:
  --        st_*   registered address, data one cycle later   (BRAM)
  --        se_*   COMBINATIONAL, address to data in one cycle (LUTRAM)
  --        cv_*   registered address, combinational data      (BRAM)
  --        sc_*   registered, one cycle, indexed by sc_head   (regfile)
  --        w_*    a level, latched inside B at head 0's pickup
  --        z_*    a real valid/ready handshake, one per value head
  --     Building `se_*` as a one-cycle BRAM by analogy with `st_*` is the
  --     obvious mistake and the port comment says so in as many words.
  --   * the EXPONENT CAPTURE OBLIGATION.  Before B may be started for a
  --     layer, exactly one `cap_req` per q/k/v segment must have been issued
  --     carrying A's `y_exp` for that projection.  Nothing carried that
  --     before this file: it is a contract between subsystem A and subsystem
  --     B that no descriptor field expresses.
  --   * COMPLETION IS `busy` FALLING, NOT `done`.  `gdn_block`'s `done` is a
  --     one-cycle pulse with no ack; `busy` is a level that falls one cycle
  --     later, and `sim/tb_gdn_block.vhd:618-621` polls `busy` for exactly
  --     this reason.  Defect class (b), avoided by using the level.
  --   * the y stream has NO ready.  Accepted unconditionally into a buffer.
  --   * z, the output gate, IS READ FROM REGION R_Z, which subsystem A
  --     produced.  That is one real A-to-B data path.
  --
  -- WHAT IS STILL A STAND-IN, stated plainly:
  --   the CONTENTS of the conv taps, the conv weights, the four scalars and
  --   the ssm_norm weight.  They are deterministic functions of their index,
  --   as in `tb_gdn_block`, and they are NOT yet sourced from R_QKV, R_BETA
  --   and R_ALPHA.  Wiring them is what remains before the GDN path carries
  --   real numbers.  The conv tap memory in particular is a per-token
  --   HISTORY, KCONV deep, and this file has no token loop yet.
  -- ======================================================================
  gb_real : if not B_BEHAV generate
    constant KH  : positive := SHAPE.key_heads;
    constant VH  : positive := SHAPE.val_heads;
    constant DM  : positive := SHAPE.head_dim;
    constant KC  : positive := SHAPE.conv_kernel;
    constant NLY : positive := n_gdn_blocks(SHAPE);
    constant NBR : positive := DM / B_RECUR_LANES;

    signal rdy  : std_logic := '1';
    signal dn   : std_logic := '0';
    signal ep   : unsigned(EPOCH_W-1 downto 0) := (others => '0');
    signal yexp : signed(EXP_W-1 downto 0) := (others => '0');

    signal b_start, b_busy, b_done, b_tk0 : std_logic := '0';
    signal b_layer : integer range 0 to NLY-1 := 0;
    signal cap_req, cap_ready : std_logic := '0';
    signal cap_layer : integer range 0 to NLY-1 := 0;
    signal cap_seg   : integer range 0 to 2 := 0;
    signal cap_exp   : signed(7 downto 0) := (others => '0');

    signal cv_seg   : integer range 0 to 2;
    signal cv_ren   : std_logic;
    signal cv_grp   : integer range 0 to (VH*DM)/B_CONV_LANES-1;
    signal cv_x, cv_w : std_logic_vector(KC*B_CONV_LANES*16-1 downto 0);
    signal cv_cw_exp  : signed(7 downto 0);
    signal cv_taken, eseg_taken : std_logic;
    signal cvq_seg : integer range 0 to 2 := 0;
    signal cvq_grp : integer range 0 to (VH*DM)/B_CONV_LANES-1 := 0;

    signal sc_head : integer range 0 to VH-1;
    signal sc_head_q : integer range 0 to VH-1 := 0;
    signal sc_al_m, sc_dt_m, sc_a_m, sc_b_m : signed(15 downto 0);
    signal sc_al_e, sc_dt_e, sc_a_e, sc_b_e : signed(7 downto 0);
    signal sc_taken : std_logic;

    signal st_ren, st_wen : std_logic;
    signal st_rhead, st_whead : integer range 0 to VH-1;
    signal st_rcol, st_wcol : integer range 0 to DM-1;
    signal st_rgrp, st_wgrp : integer range 0 to NBR-1;
    signal st_rdata, st_wdata, st_rq
         : std_logic_vector(B_RECUR_LANES*16-1 downto 0);
    type stmem_t is array (0 to VH*DM*NBR-1)
                    of std_logic_vector(B_RECUR_LANES*16-1 downto 0);
    signal stmem : stmem_t := (others => (others => '0'));

    signal se_rhead, se_whead : integer range 0 to VH-1;
    signal se_rcol, se_wcol : integer range 0 to DM-1;
    signal se_rdata, se_wdata : signed(7 downto 0);
    signal se_wen : std_logic;
    type semem_t is array (0 to VH*DM-1) of signed(7 downto 0);
    signal semem : semem_t := (others => (others => '0'));

    signal w_mant : std_logic_vector(DM*16-1 downto 0);
    signal w_exp  : integer := 12;
    signal w_taken : std_logic;

    signal z_mant : std_logic_vector(DM*16-1 downto 0) := (others => '0');
    signal z_exp  : signed(7 downto 0) := to_signed(12, 8);
    signal z_valid : std_logic := '0';
    signal z_ready : std_logic;

    signal y_valid, y_last : std_logic;
    signal y_mant : signed(15 downto 0);
    signal b_yexp : signed(7 downto 0);

    -- Deterministic stand-in stimulus, a function of the index and NOTHING
    -- else, so that changing a handshake cannot change one input value.  That
    -- is the whole basis of the cross-skew comparison.  Range is a 12-bit
    -- signed centred on zero, matching `tb_gdn_block`'s m12: full-scale int16
    -- would make every comparison a comparison of clamps.
    function m12(a, b : integer) return signed is
      variable x : unsigned(31 downto 0);
      variable t : unsigned(63 downto 0);
    begin
      t := to_unsigned(a mod 1048576, 32) * to_unsigned(1103515245, 32);
      x := t(31 downto 0) + to_unsigned((b mod 100000) * 12345, 32);
      x := x xor shift_right(x, 15);
      t := x * to_unsigned(668265261, 32);
      x := t(31 downto 0);
      x := x xor shift_right(x, 13);
      return to_signed(to_integer(x(11 downto 0)) - 2048, 16);
    end function;
  begin
    u_ready(U_B) <= rdy;
    u_done(U_B)  <= dn;
    u_err(U_B)   <= '0';
    u_done_epoch((U_B+1)*EPOCH_W-1 downto U_B*EPOCH_W) <= std_logic_vector(ep);
    u_y_exp((U_B+1)*EXP_W-1 downto U_B*EXP_W) <= std_logic_vector(yexp);

    u_gdn : entity work.gdn_block
      generic map(
        KEY_HEADS => KH, VAL_HEADS => VH, DIM => DM, KCONV => KC,
        LAYERS => NLY, CONV_LANES => B_CONV_LANES,
        RECUR_LANES => B_RECUR_LANES, RECUR_SLOTS => B_RECUR_SLOTS,
        L2_LANES => B_L2_LANES, SILU_LANES => B_SILU_LANES,
        RMS_LANES => B_RMS_LANES, STRICT_PRODUCER => STRICT)
      port map(
        clk => clk, rst => rst,
        start => b_start, layer => b_layer, tk0 => b_tk0, busy => b_busy,
        seq_rst => b_seq_rst,
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
        y_exp => b_yexp, done => b_done,
        err_conv => open, err_g => open, err_se => open, y_sat => open,
        dbg_col_ready => open, dbg_col_drop => open);

    -- ---- memory 1: the recurrent state.  Registered, one cycle. ---------
    st_rdata <= st_rq;
    stmem_p : process(clk) is
      variable a : integer;
    begin
      if rising_edge(clk) then
        if st_wen = '1' then
          a := st_whead*DM*NBR + st_wcol*NBR + st_wgrp;
          stmem(a) <= st_wdata;
        end if;
        if st_ren = '1' then
          a := st_rhead*DM*NBR + st_rcol*NBR + st_rgrp;
          st_rq <= stmem(a);
        end if;
      end if;
    end process;

    -- ---- memory 2: the state exponents.  COMBINATIONAL read. -----------
    se_rdata <= semem(se_rhead*DM + se_rcol);
    semem_p : process(clk) is
    begin
      if rising_edge(clk) then
        if se_wen = '1' then
          semem(se_whead*DM + se_wcol) <= se_wdata;
        end if;
      end if;
    end process;

    -- ---- memory 3: conv taps and weights.  Registered ADDRESS, ---------
    -- combinational DATA, which is what a BRAM with a registered address
    -- port gives and what the port comment demands.
    cvaddr_p : process(clk) is
    begin
      if rising_edge(clk) then
        cvq_seg <= cv_seg;
        cvq_grp <= cv_grp;
      end if;
    end process;

    cvdata_p : process(cvq_seg, cvq_grp) is
      variable xv, wv : std_logic_vector(KC*B_CONV_LANES*16-1 downto 0);
      variable b : integer;
    begin
      for t in 0 to KC-1 loop
        for ln in 0 to B_CONV_LANES-1 loop
          b := (t*B_CONV_LANES + ln)*16;
          xv(b+15 downto b) :=
            std_logic_vector(m12(cvq_seg*104729 + cvq_grp*31, t*17 + ln));
          wv(b+15 downto b) :=
            std_logic_vector(m12(cvq_seg*65537 + cvq_grp*13, t*101 + ln + 5));
        end loop;
      end loop;
      cv_x <= xv;
      cv_w <= wv;
    end process;

    -- Per SEGMENT, published one cycle behind `cv_seg` like a register file.
    cvsq : process(clk) is
    begin
      if rising_edge(clk) then
        cv_cw_exp <= to_signed(12 + cv_seg, 8);
      end if;
    end process;

    -- ---- memory 4: the four scalars.  Registered, one cycle. -----------
    scq : process(clk) is
    begin
      if rising_edge(clk) then
        sc_head_q <= sc_head;
      end if;
    end process;

    scdrv : process(sc_head_q) is
      variable ix : integer;
    begin
      ix      := sc_head_q;
      sc_al_m <= m12(ix*31 + 1, 2);
      sc_dt_m <= m12(ix*31 + 2, 3);
      -- ssm_a is -exp(A_log), so `a` is always <= 0 and the decay never
      -- amplifies.  A positive one would exercise a case the model cannot
      -- produce.
      sc_a_m  <= -abs(m12(ix*31 + 3, 4));
      sc_b_m  <= m12(ix*31 + 4, 5);
      sc_al_e <= to_signed(12, 8);
      sc_dt_e <= to_signed(12, 8);
      sc_a_e  <= to_signed(12, 8);
      sc_b_e  <= to_signed(12, 8);
    end process;

    -- ---- memory 5: the ssm_norm weight.  A level. ----------------------
    wdrv : process(all) is
    begin
      for j in 0 to DM-1 loop
        w_mant((j+1)*16-1 downto j*16) <= std_logic_vector(m12(4242, j));
      end loop;
    end process;

    -- ---- the adapter, the z producer and the y sink --------------------
    bp : process(clk) is
      type st_t is (S_IDLE, S_ZRD, S_CAPW, S_CAPR, S_GO, S_ARM, S_RUN,
                    S_DRAIN, S_DONE);
      variable st : st_t := S_IDLE;
      variable zb : buf_t(0 to A_MAXROWS-1);
      variable yb : buf_t(0 to A_MAXROWS-1);
      variable j_dst, j_rows, j_blk : natural := 0;
      variable k, seg, h, ycnt : natural := 0;
      variable zi : natural := 0;
    begin
      if rising_edge(clk) then
        ur_en(U_B) <= '0';
        uw_en(U_B) <= '0';
        cap_req    <= '0';
        b_start    <= '0';

        if rst = '1' then
          st := S_IDLE; rdy <= '1'; dn <= '0'; z_valid <= '0';
        else
          if job_issue = '1' and to_integer(job_unit) = U_B then
            j_dst  := to_integer(job_dst(6 downto 0));
            j_rows := to_integer(job_n_rows(15 downto 0));
            j_blk  := to_integer(job_ordinal);
            -- The GDN LAYER ORDINAL, not the block index.  `job_ordinal`
            -- carries the block index; B's `layer` port and the exponent
            -- capture are indexed by the GDN layer, which is the block index
            -- minus the attention blocks before it.
            b_layer  <= j_blk - (j_blk + 1) / SHAPE.attn_interval;
            ep       <= job_epoch;
            rdy      <= '0';
            k        := 0;
            ycnt     := 0;
            seg      := 0;
            h        := 0;
            zi       := 0;
            st       := S_ZRD;
            b_exp_region <= to_unsigned(R_Z, 8);
            b_exp_seg    <= "00";
          end if;

          -- The un-refusable y stream.  Outside the FSM: a beat that arrives
          -- where it was not expected must still be ACCEPTED, then reported.
          if y_valid = '1' then
            if st /= S_RUN then
              f_lost <= '1';
              report "llama_top: unit B emitted a y element outside its run "
                   & "window.  y_valid has no ready, so this element is LOST."
                severity error;
            end if;
            if ycnt < A_MAXROWS then yb(ycnt) := y_mant; end if;
            ycnt := ycnt + 1;
          end if;

          case st is
            when S_IDLE => null;

            -- Read the whole gate region into a buffer BEFORE starting, so
            -- the z handshake never has to wait on a region read while the
            -- block is running.
            when S_ZRD =>
              if k < VH*DM then
                ur_en(U_B)   <= '1';
                ur_reg(U_B)  <= R_Z;
                ur_addr(U_B) <= k;
              end if;
              if k >= 2 then zb(k-2) := el_rdata; end if;
              if k = VH*DM+1 then
                z_exp <= resize(exp_rd_data, 8);
                k := 0;
                st := S_CAPW;
              else
                k := k + 1;
              end if;

            -- One capture per q/k/v segment, carrying A's y_exp for that
            -- projection.  Hold-until-ready on both sides: wait for
            -- cap_ready with cap_req low, pulse for one cycle, then wait for
            -- cap_ready again before the next.
            when S_CAPW =>
              if cap_ready = '1' and cap_req = '0' then
                cap_layer <= b_layer;
                cap_seg   <= seg;
                cap_exp   <= qkv_exp(seg);
                cap_req   <= '1';
                st        := S_CAPR;
              end if;

            when S_CAPR =>
              if cap_ready = '1' then
                if seg = 2 then st := S_GO; else seg := seg + 1; st := S_CAPW; end if;
              end if;

            when S_GO =>
              b_start <= '1';
              b_tk0   <= '1';   -- one token only; there is no token loop yet
              st      := S_ARM;

            -- `busy` does not rise on the same edge as `start`, so waiting
            -- for it to FALL without first seeing it RISE completes instantly.
            when S_ARM =>
              if b_busy = '1' then st := S_RUN; end if;

            when S_RUN =>
              -- COMPLETION IS `busy` FALLING.  `done` is a one-cycle pulse
              -- with no ack and this adapter never reads it.
              if b_busy = '0' then
                k    := 0;
                yexp <= resize(b_yexp, EXP_W);
                assert ycnt = VH*DM
                  report "llama_top: unit B produced " & integer'image(ycnt)
                       & " y elements, expected " & integer'image(VH*DM)
                       & ".  An un-stallable stream lost or gained beats."
                  severity error;
                if j_dst < NREGION then st := S_DRAIN; else st := S_DONE; end if;
              end if;

            when S_DRAIN =>
              uw_en(U_B)   <= '1';
              uw_reg(U_B)  <= j_dst;
              uw_addr(U_B) <= k;
              if k < A_MAXROWS then uw_data(U_B) <= yb(k); end if;
              if k = j_rows-1 then st := S_DONE; else k := k + 1; end if;

            when S_DONE =>
              dn <= '1';
              if u_ack(U_B) = '1' then
                dn  <= '0';
                rdy <= '1';
                st  := S_IDLE;
              end if;
          end case;

          -- The z handshake, one offer per value head, running alongside.
          if st = S_RUN or st = S_ARM or st = S_GO then
            if z_valid = '0' and h < VH then
              for j in 0 to DM-1 loop
                z_mant((j+1)*16-1 downto j*16) <=
                  std_logic_vector(zb(h*DM + j));
              end loop;
              z_valid <= '1';
            elsif z_valid = '1' and z_ready = '1' then
              z_valid <= '0';
              h := h + 1;
            end if;
          else
            z_valid <= '0';
          end if;
        end if;
      end if;
    end process;
  end generate;

  -- ======================================================================
  -- UNIT C.  *** ATTENTION IS A STUB.  THIS COMPUTES NOTHING. ***
  --
  -- Subsystem C's steps 3..8 -- twiddle, rope, kv_quant, score, softmax,
  -- recip, gate, emit -- are verified and contiguous.  THE LANE ARRAY IS NOT.
  -- `rtl/attn_lane_skel.vhd` is a PRICING SKELETON: it exists to be
  -- synthesised for area and it produces a 32-bit `digest`, not an attention
  -- score.  There is therefore no path from Q, K and V to an attention
  -- output in this repository, and this adapter cannot make one.
  --
  -- WHAT IT WRITES, and it is chosen to be impossible to mistake for a
  -- result: y(i) = -32768 + i, ignoring Q, K and V entirely.  It is
  -- saturated-negative at element 0, it ramps, and it does not depend on any
  -- input.  A residual stream that has passed through an attention block
  -- therefore carries an obviously broken value, on purpose.
  --
  -- `err_unit_stub` goes high and STAYS high the first time this runs.  Any
  -- run whose `err_unit_stub` is set produced no inference.
  -- ======================================================================
  gc : block
    signal rdy  : std_logic := '1';
    signal dn   : std_logic := '0';
    signal ep   : unsigned(EPOCH_W-1 downto 0) := (others => '0');
    signal yexp : signed(EXP_W-1 downto 0) := (others => '0');
  begin
    u_ready(U_C) <= rdy;
    u_done(U_C)  <= dn;
    u_err(U_C)   <= '0';
    u_done_epoch((U_C+1)*EPOCH_W-1 downto U_C*EPOCH_W) <= std_logic_vector(ep);
    u_y_exp((U_C+1)*EXP_W-1 downto U_C*EXP_W) <= std_logic_vector(yexp);

    cp : process(clk) is
      type st_t is (S_IDLE, S_WR, S_DONE);
      variable st : st_t := S_IDLE;
      variable j_dst, j_rows : natural := 0;
      variable k : natural := 0;
      variable said : boolean := false;
    begin
      if rising_edge(clk) then
        uw_en(U_C) <= '0';
        if rst = '1' then
          st := S_IDLE; rdy <= '1'; dn <= '0';
        else
          if job_issue = '1' and to_integer(job_unit) = U_C then
            j_dst  := to_integer(job_dst(6 downto 0));
            j_rows := to_integer(job_n_rows(15 downto 0));
            ep     <= job_epoch;
            rdy    <= '0';
            k      := 0;
            st     := S_WR;
            f_stub <= '1';
            -- THE STUB'S VALUES ARE GARBAGE; ITS SCALE IS NOT.  A stub that
            -- also fabricates an exponent puts its output on a scale nothing
            -- else in the token shares, and the next residual then shifts one
            -- of its two operands out entirely -- which is a SECOND, invisible
            -- failure layered on top of the intended, visible one.  Measured:
            -- with a fabricated exponent of 0 the attention block produced a
            -- residual whose operands were 25 binary places apart.  So the
            -- stub reports its SOURCE region's exponent, and the damage stays
            -- confined to the numbers.
            c_exp_region <= job_src;
            c_exp_seg    <= "00";
            if not said and SHOUT then
              report "llama_top: *** UNIT C IS A STUB.  ATTENTION WAS NOT "
                   & "COMPUTED.  The residual stream from this block onward "
                   & "is meaningless. ***" severity warning;
              said := true;
            end if;
          end if;

          case st is
            when S_IDLE => null;
            when S_WR =>
              uw_en(U_C)   <= '1';
              uw_reg(U_C)  <= j_dst;
              uw_addr(U_C) <= k;
              uw_data(U_C) <= to_signed(-32768 + (k mod 4096), MANT_W);
              if k = j_rows-1 then st := S_DONE; else k := k + 1; end if;
            when S_DONE =>
              dn   <= '1';
              yexp <= exp_rd_data;
              if u_ack(U_C) = '1' then
                dn  <= '0'; rdy <= '1'; st := S_IDLE;
              end if;
          end case;
        end if;
      end if;
    end process;
  end block;

  -- ======================================================================
  -- UNIT E.  The tensor-parallel collective.  Unreachable at NCARDS = 1: the
  -- schedule emits no OP_E_COLL.  It is wired to raise `u_err` rather than to
  -- complete, so a schedule built for NCARDS > 1 and run here STOPS instead
  -- of quietly producing a number.
  --
  -- Note the OPEN hazard it would hit if it ever did run: `e_o_we` into
  -- D-vec's residual pass has NO ready at all (seq_top_skel.vhd:199-209,
  -- seq_vec_res.vhd:168-174, both calling it "UNSTALLABLE, AND UNRESOLVED").
  -- ======================================================================
  ge : block
    signal rdy : std_logic := '1';
    signal dn  : std_logic := '0';
    signal ep  : unsigned(EPOCH_W-1 downto 0) := (others => '0');
  begin
    u_ready(U_E) <= rdy;
    u_done(U_E)  <= dn;
    u_err(U_E)   <= dn;
    u_done_epoch((U_E+1)*EPOCH_W-1 downto U_E*EPOCH_W) <= std_logic_vector(ep);
    u_y_exp((U_E+1)*EXP_W-1 downto U_E*EXP_W) <= (others => '0');

    epp : process(clk) is
    begin
      if rising_edge(clk) then
        if rst = '1' then
          dn <= '0'; rdy <= '1';
        else
          if job_issue = '1' and to_integer(job_unit) = U_E then
            ep     <= job_epoch;
            rdy    <= '0';
            dn     <= '1';
            f_ecoll <= '1';
            report "llama_top: OP_E_COLL was issued.  NCARDS = 1 has no "
                 & "collective and no unit E.  The schedule and the build "
                 & "disagree." severity error;
          end if;
          if dn = '1' and u_ack(U_E) = '1' then
            dn <= '0'; rdy <= '1';
          end if;
        end if;
      end if;
    end process;
  end block;

  -- ======================================================================
  -- THE ACTIVE-UNIT LATCH, and observability.
  -- ======================================================================
  actp : process(clk) is
  begin
    if rising_edge(clk) then
      if rst = '1' then
        act_unit <= 0;
      elsif job_issue = '1' then
        act_unit <= to_integer(job_unit);
      end if;
      if rst = '1' then
        act_vop <= 0;
      else
        for v in 0 to NVOP-1 loop
          if v_taken(v) = '1' then act_vop <= v; end if;
        end loop;
      end if;
    end if;
  end process;

  wsump : process(clk) is
    variable h : unsigned(31 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        h := (others => '0');
      elsif el_we = '1' then
        h := resize(h * 31, 32);
        h := h + to_unsigned(el_wreg * 8191 + el_waddr, 32)
               + resize(unsigned(std_logic_vector(el_wdata)), 32);
      elsif w_we = '1' then
        for i in 0 to LANES-1 loop
          if w_be(i) = '1' then
            h := resize(h * 31, 32);
            h := h + to_unsigned(to_integer(unsigned(v_reg_d(6 downto 0)))*8191
                                 + to_integer(w_addr)*LANES + i, 32)
                   + resize(unsigned(w_data((i+1)*MANT_W-1 downto i*MANT_W)), 32);
          end if;
        end loop;
      end if;
      obs_wsum <= h;
    end if;
  end process;

  -- The q/k/v exponent recorder.  `cmp_valid` is the completing job, and D
  -- runs one job at a time, so the job latched at the last `job_issue` IS the
  -- one completing.  Segment comes from `dst_off` against the same two
  -- boundaries `seq_opdec`'s MSEG mechanism uses, so the two cannot disagree
  -- about which of q, k and v a job produced.
  qexpp : process(clk) is
    variable off : natural;
  begin
    if rising_edge(clk) then
      b_seq_rst <= '0';
      if rst = '1' then
        last_dst <= 255;
        qkv_exp  <= (others => (others => '0'));
      else
        if go = '1' then
          -- One sequence reset per token, issued while everything is idle.
          -- `gdn_exp_capture` asserts failure if this arrives mid-capture.
          b_seq_rst <= '1';
        end if;
        if job_issue = '1' then
          last_dst <= to_integer(job_dst(6 downto 0));
          off := to_integer(job_dst_off(15 downto 0));
          if    off = key_dim(SHAPE)   then last_seg <= 1;
          elsif off = 2*key_dim(SHAPE) then last_seg <= 2;
          else                              last_seg <= 0; end if;
        end if;
        if cmp_valid = '1' and last_dst = R_QKV then
          qkv_exp(last_seg) <= resize(cmp_y_exp, 8);
        end if;
      end if;
    end if;
  end process;

  obs_res_take <= v_taken(V_RES);
  obs_res_ea   <= v_exp_a;
  obs_res_eb   <= v_exp_b;

  obs_cmp_exp <= cmp_y_exp;
  obs_issue  <= job_issue;
  obs_unit   <= job_unit;
  obs_opcode <= job_opcode;
  obs_step   <= job_step;
  obs_dst    <= job_dst;
  obs_cmp    <= cmp_valid;

  err_lost_beat <= f_lost;
  err_gate_drop <= f_gate;
  err_unit_stub <= f_stub;
  err_e_coll    <= f_ecoll;

end architecture;
