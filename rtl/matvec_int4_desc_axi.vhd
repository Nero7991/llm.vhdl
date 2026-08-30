-- rtl/matvec_int4_desc_axi.vhd -- subsystem A's DESCRIPTOR-IN-MEMORY control
-- plane.  The AXI-Lite map is constant at every geometry; everything that
-- grows with geometry is fetched from memory by the fabric.
--
-- Spec: docs/2026-08-28_matvec-descriptor-format.md
-- Layout constants: rtl/matvec_int4_desc_pkg.vhd
--
-- WHY THIS EXISTS.  rtl/matvec_int4_axi.vhd asserts NPORTS_W = 4 and
-- NPORTS_S = 1 (its lines 252 and 265) because its register map holds four
-- W_BASE/W_BASE_HI pairs and one S_BASE/S_BASE_HI pair.  The FK33 geometry
-- (spec 6.5a, ROWS_IF=48, AXI_DW=256) needs 24 and 3.  That file's own header
-- states the objection to widening it -- "a map whose shape moves with a
-- synthesis generic is a map no host driver can parse" -- and that objection
-- stands.  So the map does not grow: a descriptor pointer does, and the
-- descriptor grows in MEMORY, where growing is free.
--
-- THE OLD MAP IS RETAINED, UNCHANGED, AS A SEPARATE ENTITY.  Not behind a
-- boolean generic in this file: that would put both register decodes and both
-- base-storage shapes in one entity whose map shape then moves with a generic,
-- which is precisely the thing being avoided.  matvec_int4_axi keeps driving
-- the AXU3EG DDR build and hw/mv_driver.c, and sim/tb_matvec_axi.vhd keeps
-- covering it.  Neither map is a superset of the other and nothing chooses
-- between them at run time.
--
-- ======================================================================
-- REGISTER MAP (word-addressed, reg = addr[7:2]).  CONSTANT AT ANY GEOMETRY.
-- ======================================================================
--   0x00 DESC_PTR_LO  RW  descriptor byte address, low 32.  Must be aligned to
--                         DESC_MAXB*AXI_DW/8 bytes (512 at the FK33) -- see
--                         DESC_ALIGN in the body for why alignment replaces a
--                         4 KB burst splitter.
--   0x04 DESC_PTR_HI  RW  descriptor byte address, high 32.  A bit at or above
--                         ADDR_W latches ERR_ADDR AT WRITE TIME -- see below.
--   0x08 CTRL         W   bit0 = GO (self-clearing)
--   0x0C STATUS       R   bit0 done, bit1 busy, bit2 err, bit3 sat_event,
--                         bit4 err_addr (sticky), bits[11:8] err_code
--   0x10 ERR_INFO     R   [10:0] failing descriptor WORD INDEX,
--                         [15:11] SUB-CASE within err_code (0 = none, 31 = the
--                         report is about DESC_PTR itself and there is no
--                         word, so 0xFFFF still reads as the old sentinel).
--                         The register's WIDTH and OFFSET are unchanged and no
--                         DESCRIPTOR byte moved: this splits an existing
--                         register field, which is why it is the route OI-9
--                         took.  See rtl/matvec_int4_desc_pkg.vhd.
--   0x14 ID           R   0x4D563449 "MV4I"
--   0x18 ADDR_CAP     R   ADDR_W this build was synthesised with, in bits
--   0x1C CAPS         R   [7:0] NPORTS_W [15:8] NPORTS_S [23:16] ROWS_IF
--                         [31:24] AXI_DW/8
--   0x20 DESC_WORDS   R   descriptor length this build expects, in 64-bit words
--   0x24 Y_IDX        W   result row to present
--   0x28 Y_LO         R   y[Y_IDX][31:0]
--   0x2C Y_HI         R   y[Y_IDX][63:32]
--   0x30 Y_EXP        R
--   0x34 CYCLES       R   cycles busy, GO to done
--   0x38 BEATS        R   weight words the array consumed
--   0x3C STARVED      R   cycles busy with no weight word available
--
-- NOT IN THE MAP, ON PURPOSE: N_ROWS, N_COLS, OUT_SHIFT, W_EXP, X_EXP,
-- OUT_MODE, the bases, W_BEATS, S_BEATS and the codebook are all descriptor
-- fields now.  X_IDX / X_DATA are gone too: activations arrive on the
-- x_we/x_waddr/x_wdata port one element per cycle from the previous stage, and
-- an AXI-Lite element-at-a-time load of a 4096-element vector is a bring-up
-- crutch the FK33 has no use for.  A register nothing exercises is how a map
-- grows a second dialect.
--
-- ERR_ADDR AT WRITE TIME IS DELIBERATELY PRESERVED.  It is one of the few
-- teeth the old wrapper had: "a driver that reads STATUS after programming the
-- descriptor sees it before it runs anything".  DESC_PTR_HI is the only
-- address register left, so it keeps that behaviour, and the BASES -- which
-- are now in memory and cannot be checked at write time -- are checked in
-- S_CHECK before `start` ever reaches the core.
--
-- ======================================================================
-- EVERY CHECK RUNS BEFORE THE CORE IS STARTED
-- ======================================================================
-- That is rtl/seq_desc_fetch.vhd's S_CHECK discipline and the reason is the
-- same: a descriptor rejected after the array has begun consuming weights has
-- already read the wrong memory.  On any failure this entity does NOT pulse
-- `start`, does not set `done`, drops `busy`, and latches err / err_code /
-- err_info until reset.  A driver polling for `done` alone therefore hangs
-- rather than reading stale results.
--
-- What is NOT checked, stated so nobody assumes coverage that is not there:
-- a base that is well-formed but points at the WRONG sub-region.  Nothing in
-- the descriptor says what a sub-region should CONTAIN, so only a hash over
-- the weight store can see it; it produces a wrong answer rather than an
-- error.  Section 5.1 of the spec document.
--
-- w_beats/s_beats INCONSISTENT WITH n_rows/n_cols USED TO BE ON THAT LIST AND
-- IS NOT ANY MORE.  It was the worse of the two, because a w_beats that is too
-- small does not produce a wrong answer -- it STARVES the array, and the job
-- then never completes and never errors, because WDOG_LIMIT covers the
-- descriptor FETCH only.  A driver polling for `done or err` waits forever.
-- S_SHAPE / S_SHAPE_C below refuse it with EC_SHAPE before `start`, which
-- makes the hang UNREACHABLE rather than merely detectable.  The reason it was
-- left out originally -- "checking needs the ceil(n_rows/ROWS_IF) divide that
-- is the whole reason those fields are carried" -- was right about the divide
-- and wrong that a divide is the only way: the check MULTIPLIES UP instead.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;
use work.matvec_int4_desc_pkg.all;

entity matvec_int4_desc_axi is
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
    MAXB        : positive := 16;   -- the FK33 HBM slave is AXI3: 16 is the cap
    MAXOUT      : positive := 16;
    -- Beats per descriptor-fetch burst.  Capped the same way as MAXB and for
    -- the same reason (the FK33 HBM slave is AXI3, ARLEN is 4 bits).  It also
    -- sets the DESC_PTR alignment: see DESC_ALIGN in the body.
    DESC_MAXB   : positive := 16;
    -- Cycles the descriptor fetch may take before ERR_WDOG.  It covers a slave
    -- that never answers as well as one that answers slowly, so it is a
    -- liveness bound on the whole fetch, not a latency budget.  It still does
    -- NOT cover the COMPUTE phase, and deliberately so: the one way an
    -- ACCEPTED descriptor could starve the array was a w_beats/s_beats that
    -- did not match the shape, and S_SHAPE now refuses that before `start`.
    -- A compute-phase watchdog would need a per-geometry limit -- a tuned
    -- constant -- and would report that something starved without saying why.
    WDOG_LIMIT  : positive := 65536;
    -- Take x_exp from the `x_exp_in` PORT rather than from the descriptor.
    -- In the integrated system the activation vector's block exponent is a
    -- per-token value produced by the previous stage, so the descriptor's copy
    -- is stale by construction; standalone, there is no previous stage.  Which
    -- one the FK33 build uses is an integration decision.
    USE_XEXP_PORT : boolean := false;
    -- Run the AXI read masters on `aclk` (spec 14.5 item 3).  The CDC lives in
    -- rtl/axi_rd_port.vhd, and the DESCRIPTOR master is one of those ports, so
    -- the whole memory side -- weights, scales and the descriptor -- is one
    -- domain and every word crosses through the same tested FIFO.
    DUAL_CLK    : boolean := false;
    C_S_AXI_DATA_WIDTH : integer := 32;
    C_S_AXI_ADDR_WIDTH : integer := 8
  );
  port(
    s_axi_aclk    : in  std_logic;      -- the CORE clock
    s_axi_aresetn : in  std_logic;
    -- HBM AXI clock.  Ignored when DUAL_CLK = false.
    m_aclk        : in  std_logic := '0';

    s_axi_awaddr  : in  std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
    s_axi_awprot  : in  std_logic_vector(2 downto 0);
    s_axi_awvalid : in  std_logic;
    s_axi_awready : out std_logic;
    s_axi_wdata   : in  std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
    s_axi_wstrb   : in  std_logic_vector((C_S_AXI_DATA_WIDTH/8)-1 downto 0);
    s_axi_wvalid  : in  std_logic;
    s_axi_wready  : out std_logic;
    s_axi_bresp   : out std_logic_vector(1 downto 0);
    s_axi_bvalid  : out std_logic;
    s_axi_bready  : in  std_logic;
    s_axi_araddr  : in  std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
    s_axi_arprot  : in  std_logic_vector(2 downto 0);
    s_axi_arvalid : in  std_logic;
    s_axi_arready : out std_logic;
    s_axi_rdata   : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
    s_axi_rresp   : out std_logic_vector(1 downto 0);
    s_axi_rvalid  : out std_logic;
    s_axi_rready  : in  std_logic;

    -- DESCRIPTOR FETCH MASTER.  A separate AXI4 read master, not folded into
    -- the flattened weight/scale array, so the integrator can route it
    -- somewhere else -- another HBM port, or a small BRAM -- without touching
    -- the weight path.  It is read-only and issues one burst chain per GO.
    d_arvalid : out std_logic;
    d_arready : in  std_logic;
    d_araddr  : out std_logic_vector(ADDR_W-1 downto 0);
    d_arlen   : out std_logic_vector(7 downto 0);
    d_arsize  : out std_logic_vector(2 downto 0);
    d_arburst : out std_logic_vector(1 downto 0);
    d_rvalid  : in  std_logic;
    d_rready  : out std_logic;
    d_rdata   : in  std_logic_vector(AXI_DW-1 downto 0);
    d_rlast   : in  std_logic;

    -- weight / scale read masters, flattened; the shape is unchanged from
    -- matvec_int4 so the integration wiring is the same
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

    -- activations, from the previous stage, one element per cycle
    x_we      : in  std_logic := '0';
    x_waddr   : in  std_logic_vector(15 downto 0) := (others => '0');
    x_wdata   : in  std_logic_vector(15 downto 0) := (others => '0');
    -- per-token activation block exponent; used only when USE_XEXP_PORT
    x_exp_in  : in  std_logic_vector(31 downto 0) := (others => '0');

    -- result, straight out of the core, for whoever moves it
    y_we      : out std_logic;
    y_addr    : out std_logic_vector(15 downto 0);
    y_data    : out std_logic_vector(ROWS_IF*64-1 downto 0);
    y_mask    : out std_logic_vector(ROWS_IF-1 downto 0);
    y_exp_o   : out std_logic_vector(31 downto 0);
    job_done  : out std_logic;    -- level, mirrors STATUS bit 0
    job_err   : out std_logic     -- level, mirrors STATUS bit 2
  );
end entity;

architecture rtl of matvec_int4_desc_axi is
  constant NP_ALL : positive := NPORTS_W + NPORTS_S;
  constant TILES  : positive := (MAXROWS_BFP + ROWS_IF - 1) / ROWS_IF;
  constant BYTES  : positive := AXI_DW / 8;
  constant WPB    : positive := AXI_DW / 64;          -- descriptor words / beat
  constant DWORDS : positive := desc_words(NPORTS_W, NPORTS_S);
  constant DBEATS : positive := desc_beats(NPORTS_W, NPORTS_S, AXI_DW);
  constant EXT0   : natural  := desc_ext0(NPORTS_W, NPORTS_S);
  -- ERR_INFO carries the failing descriptor word index in EI_WORD_W = 11 bits
  -- and the sub-case in the top 5 (rtl/matvec_int4_desc_pkg.vhd).  A build
  -- whose descriptor is longer than 2048 words could not name its own failing
  -- word: the index would overflow into the sub-case field and a base-array
  -- refusal would read as some other check entirely.  This is the guard.
  --
  -- A NATURAL, NOT AN ASSERT.  MEASURED, three OOC runs: Vivado silently
  -- ignores `assert ... severity failure` in synthesis.  An out-of-range
  -- natural constant DOES fail the build -- with no message beyond
  -- "bound check failure at <file>:<line>", because a natural constant cannot
  -- carry a report string.  If that line points here, the descriptor is longer
  -- than ERR_INFO can index; see EI_WORD_W.
  --
  -- DERIVED: at the FK33 geometry DWORDS = desc_words(24,3) = 39, so the guard
  -- has 2009 words of headroom and binds only past NPORTS_W+NPORTS_S = 2036.
  constant EI_WORD_FITS : natural := EI_WORD_MAX - (DWORDS - 1);
  -- FIFO for the descriptor fetch.  A power of two (async_fifo requires it),
  -- at least DESC_MAXB so a full burst can be issued, and at least DBEATS so
  -- the whole descriptor can land before it is read.
  constant DESC_FIFO : positive := 64;
  -- THE POINTER ALIGNMENT.  axi_rd_port caps a burst at MAXB beats but does
  -- not split at 4 KB, so the 4 KB rule is met by ALIGNMENT instead: every
  -- burst starts at a multiple of DESC_MAXB*BYTES and is at most that long, so
  -- it lies inside one such block, and one such block lies inside one 4 KB
  -- page because DESC_MAXB*BYTES divides 4096 (asserted below).
  constant DESC_ALIGN : positive := DESC_MAXB * (AXI_DW / 8);

  -- ---------------------------------------------------- the shape identity
  -- What w_beats and s_beats MUST be for a given n_rows / n_cols.  Derived,
  -- and the same three-way agreement the packer and the C reference already
  -- have:
  --
  --   tiles   = ceil(n_rows / ROWS_IF)            matvec_core.vhd:672-680
  --   nblk    = ceil(n_cols / BLK)                matvec_core.vhd:924
  --   w_beats = tiles * nblk                      per WEIGHT sub-region
  --   s_beats = ceil(tiles * nblk / GRP)          per SCALE  sub-region
  --
  -- Why those are the right numbers, rather than a plausible reading of the
  -- packer.  matvec_core's issue FSM walks t_iss over tiles and b_iss over
  -- nblk (:664-683) and accepts exactly one weight word per step; w_ready and
  -- s_ready are THE SAME signal (`accept`, :565-568), so one scale GROUP is
  -- consumed per weight word.  weight_streamer pops one beat from EVERY
  -- weight port per delivered word and one beat from EVERY scale port per
  -- SUPERWORD, and a superword carries GRP groups.  So a weight sub-region
  -- owes one beat per word and a scale sub-region owes one beat per GRP
  -- words.  Anything less STARVES the array, which is a hang and not an
  -- error; anything more reads padding.
  constant SW_BITS : positive := ROWS_IF * 16;                 -- scale group
  constant GRP     : positive := (NPORTS_S * AXI_DW) / SW_BITS;
  -- The same condition as the assert below, in a form Vivado CANNOT ignore.
  -- Vivado silently drops `assert ... severity failure`, and if GRP were
  -- truncated the card would refuse every legal descriptor instead of failing
  -- the build.  This constant is 0 when NPORTS_S*AXI_DW is a whole number of
  -- scale groups and NEGATIVE otherwise, which no `natural` can hold.
  constant GRP_EXACT : natural := 0 - ((NPORTS_S * AXI_DW) mod SW_BITS);
  -- Bounds, so the checker's counters are range-declared rather than trusted.
  -- Reachable only because n_rows/n_cols are range-checked FIRST.
  constant NBMAX   : positive := (MAXCOLS + BLK - 1) / BLK;

  type word_arr is array(0 to DWORDS-1) of std_logic_vector(63 downto 0);
  signal dw : word_arr := (others => (others => '0'));

  signal rst : std_logic;

  -- AXI-Lite plumbing
  signal awready, wready, bvalid, arready, rvalid : std_logic := '0';
  signal rdata_r : std_logic_vector(31 downto 0) := (others => '0');
  signal wr_addr : std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0)
                   := (others => '0');

  signal dptr     : std_logic_vector(63 downto 0) := (others => '0');
  -- GO, COMBINATIONALLY, IN THE WRITE-HANDSHAKE CYCLE ITSELF, and there is
  -- exactly one of it.  This used to be a registered `go` set inside the write
  -- channel's own case statement, which put the assertion one clock AFTER the
  -- handshake.  That one clock was the head of a three-clock window in which
  -- STATUS still reported the PREVIOUS job's completion -- see done_l below.
  --
  -- It is combinational off signals that are all stable in that cycle:
  -- `awready`/`wready` are registered and high together for exactly one cycle,
  -- `wr_addr` was captured on the cycle before and is held, and AXI requires
  -- WDATA stable while WVALID is high, which it must be for the handshake to
  -- be happening at all.  A glitch is not a hazard here because every consumer
  -- is edge-triggered on the same clock.
  --
  -- ONE definition, used by the FSM, by STATUS and by the job_done port.  Two
  -- decodes of "a GO write is being accepted" would be free to drift, and the
  -- whole defect this closes was two pieces of the design disagreeing about
  -- when a job begins.
  signal go_now   : std_logic;
  -- GO reaches an FSM that is not always in a state listening for it.  Class
  -- (b) of rtl/seq_desc_fetch.vhd's header, exactly: a command signalled as a
  -- pulse and discarded because the consumer was busy.  So it is captured into
  -- a sticky bit in an UNCONDITIONAL branch and the FSM reads only that bit.
  signal go_p     : std_logic := '0';
  signal busy     : std_logic := '0';
  -- COMPLETION, AND IT MUST BELONG TO THE MOST RECENT GO.
  --
  -- done_l was set in S_DONE and cleared only when S_IDLE consumed the next
  -- GO.  Between the CTRL write and that clear there were three core clocks in
  -- which STATUS reported the PREVIOUS job's `done` -- registered `go` at
  -- handshake+1, go_p at +2, S_DONE -> S_IDLE at +3, the clear at +4 -- so a
  -- host that wrote GO and read STATUS would see the previous job's completion
  -- and then read the previous job's Y registers.  A wrong number with no
  -- error anywhere.
  --
  -- NO TOOL BEFORE 2026-08-29 COULD MEET IT, because every one of them ran a
  -- SINGLE job; a sequence meets it on every job after the first.  Found by
  -- TRACK LAYERRUN by reading, not by running.  PCIe ordering plus AXI-Lite
  -- latency very probably closed it in practice, but by about 10x of timing
  -- margin and not by construction, and "not by construction" is the whole
  -- objection: it is a race that happens to be losing.
  --
  -- Closed HERE, on go_now, not on the registered `go`: clearing on `go` would
  -- still leave the handshake cycle and the one after it stale.  The clear is
  -- in the same UNCONDITIONAL branch that captures go_p, so it fires from any
  -- state, and the S_WAIT arm that SETS done_l runs later in the same process
  -- and therefore wins if a job completes on the very cycle a GO is written.
  signal done_l   : std_logic := '0';
  signal err_l    : std_logic := '0';
  signal err_addr : std_logic := '0';
  signal err_code : std_logic_vector(3 downto 0) := EC_NONE;
  signal err_info : std_logic_vector(15 downto 0) := (others => '0');

  -- fetch / control FSM
  type st_t is (S_IDLE, S_FETCH, S_R, S_CHECK, S_SHAPE, S_SHAPE_C, S_CB,
                S_START, S_WAIT, S_DONE, S_ERR);
  signal st : st_t := S_IDLE;

  -- ------------------------------------------------- the shape checker
  -- MULTIPLY UP, NEVER DIVIDE.  ROWS_IF is 48 on the FK33 and a divide by it
  -- is exactly what this control plane refused to own -- it is why w_beats is
  -- carried in the descriptor at all.  So tiles and nblk are found by
  -- REPEATED ADDITION of the two synthesis constants until each accumulator
  -- covers its dimension, which is a multiply written out longhand: two
  -- adders and two comparators, no divider and no magic reciprocal.
  --
  -- COST, stated rather than hidden: the loop runs max(tiles, nblk) cycles,
  -- bounded by max(TILES, NBMAX) -- 544 at the FK33's MAXCOLS=17408/BLK=32,
  -- 128 in sim/tb_matvec_fk33_desc.  The job it gates is w_beats = tiles*nblk
  -- cycles at an absolute minimum, and nblk >= 1, so the loop can never
  -- exceed the compute it precedes and is under 1.2% of it at any real shape
  -- (max(86, 128) = 128 cycles against 86*128 = 11,008 for a 4096x4096 tensor
  -- at ROWS_IF=48/BLK=32).
  signal sh_rows : integer range 0 to MAXROWS_BFP := 0;
  signal sh_cols : integer range 0 to MAXCOLS     := 0;
  signal sh_t    : integer range 0 to TILES       := 0;   -- tiles so far
  signal sh_nb   : integer range 0 to NBMAX       := 0;   -- blocks so far
  signal sh_racc : integer range 0 to TILES*ROWS_IF := 0; -- sh_t * ROWS_IF
  signal sh_cacc : integer range 0 to NBMAX*BLK     := 0; -- sh_nb * BLK
  signal sh_prod : integer range 0 to TILES*NBMAX   := 0; -- sh_t * sh_nb

  -- THE DESCRIPTOR FETCH IS AN axi_rd_port, NOT A HAND-ROLLED MASTER.
  -- It was hand-rolled first, in this clock domain, and MEASURED to fail the
  -- moment DUAL_CLK was switched on: the descriptor slave answers in the AXI
  -- domain, the capture register was clocked in the core domain, and the
  -- result was a descriptor read as garbage (err_code = ERR_MAGIC) or not read
  -- at all (ERR_WDOG) on 17 of 22 cases in sim/tb_matvec_fk33_desc.  The
  -- weight path had a CDC and the CONTROL path did not.
  --
  -- Reusing axi_rd_port fixes that with no new crossing: it already owns the
  -- CDC, the burst splitting and the flush-on-start, and the descriptor then
  -- arrives on the same first-word-fall-through stream interface as a weight
  -- sub-region does.  The fetch below is a beat counter, nothing more.
  signal d_start : std_logic := '0';
  signal d_qv, d_qr : std_logic;
  signal d_qd    : std_logic_vector(AXI_DW-1 downto 0);
  signal f_got  : integer range 0 to DBEATS := 0;    -- beats captured
  signal wdog   : integer range 0 to WDOG_LIMIT := 0;
  signal cb_cnt : integer range 0 to 16 := 0;

  -- to the core
  signal core_start : std_logic := '0';
  signal core_done, core_err, core_sat : std_logic;
  signal dbg_wbeat, dbg_wstarve : std_logic;
  signal v_rows, v_cols, v_osh, v_wexp, v_xexp : std_logic_vector(31 downto 0);
  signal v_wbeats, v_sbeats, v_yexp : std_logic_vector(31 downto 0);
  signal v_mode : std_logic_vector(1 downto 0);
  signal w_base : std_logic_vector(NPORTS_W*ADDR_W-1 downto 0);
  signal s_base : std_logic_vector(NPORTS_S*ADDR_W-1 downto 0);

  signal cb_we   : std_logic := '0';
  signal cb_addr : std_logic_vector(3 downto 0) := (others => '0');
  signal cb_data : std_logic_vector(7 downto 0) := (others => '0');
  -- A codebook that was never loaded is all zeros, which computes a plausible
  -- all-zero answer rather than failing.  D's flags bit 2 makes the load
  -- optional, so this is the state that makes "optional" safe.
  signal cb_valid : std_logic := '0';

  signal y_we_i   : std_logic;
  signal y_addr_i : std_logic_vector(15 downto 0);
  signal y_data_i : std_logic_vector(ROWS_IF*64-1 downto 0);
  signal y_mask_i : std_logic_vector(ROWS_IF-1 downto 0);
  signal sat_l    : std_logic := '0';

  -- result buffer, one whole tile per word (7.9a: FLAT, written whole)
  type res_t is array(0 to TILES-1) of std_logic_vector(ROWS_IF*64-1 downto 0);
  signal res   : res_t;
  attribute ram_style : string;
  attribute ram_style of res : signal is "block";
  signal res_q   : std_logic_vector(ROWS_IF*64-1 downto 0) := (others => '0');
  signal y_idx   : unsigned(15 downto 0) := (others => '0');
  signal y_sel   : std_logic_vector(63 downto 0);

  -- ---------------------------------------- Y_IDX -> (tile, lane), NO DIVIDE
  -- `res` is tile-major, so presenting row Y_IDX needs Y_IDX / ROWS_IF and
  -- Y_IDX mod ROWS_IF.  Both used to be written as VHDL `/` and `mod` on the
  -- 16-bit register, and ROWS_IF is 48 on the FK33, so both were real
  -- dividers.  MEASURED (sim/ooc_fk33_a.tcl, Vivado 2023.2,
  -- xcvu33p-fsvh2104-2L-e @ 0.717 V), once matvec_core's own divide-by-48 was
  -- removed this became the WHOLE critical path -- the three worst paths in
  -- the design were all y_idx_reg[5] -> res_reg_N/ADDRARDADDR[14], 4.727 ns,
  -- 16 logic levels, 8 CARRY8, holding the core clock at 192.86 MHz against
  -- 226.96 MHz for matvec_int4 with no descriptor plane at all.
  --
  -- Same answer as section 5.2's shape check and as matvec_core's tile
  -- counter: subtract the synthesis constant repeatedly instead of dividing.
  -- The quotient and remainder are produced by a small sequential loop, and
  -- the AXI-Lite read of Y_LO / Y_HI STALLS until they are ready.  The stall
  -- is what makes this a handshake rather than a timing assumption: nothing
  -- here relies on the host leaving cycles between the Y_IDX write and the
  -- Y_LO read, which is a software convention and not a hardware guarantee.
  --
  -- COST: floor(Y_IDX / ROWS_IF) cycles per NEW Y_IDX value, bounded by
  -- TILES-1 (362 at MAXROWS_BFP = 17408 / ROWS_IF = 48), against an AXI-Lite
  -- read transaction that is already several cycles.  It is the result
  -- READBACK path, one row per host transaction; the real result leaves on
  -- the y_we / y_addr / y_data bus, which this does not touch.
  signal yq      : integer range 0 to TILES-1   := 0;   -- Y_IDX / ROWS_IF
  signal yr      : integer range 0 to ROWS_IF-1 := 0;   -- Y_IDX mod ROWS_IF
  signal yi_q    : integer range 0 to TILES-1   := 0;   -- quotient so far
  signal yi_run  : unsigned(15 downto 0) := (others => '0');  -- what is left
  signal yi_snap : unsigned(15 downto 0) := (others => '0');  -- index in hand
  signal y_ok    : std_logic := '0';   -- yq / yr are final for yi_snap
  signal y_rdy   : std_logic := '0';   -- ... and res_q has been read at yq

  -- Write side, also without a divide.  `res` is written once per tile, in
  -- tile order, by matvec_core's emit (rtl/matvec_core.vhd:840 in raw/partial
  -- mode and :978 in BFP mode, both with y_addr = the tile's BASE row), so
  -- the tile index is a counter and y_addr/ROWS_IF is not needed.  That the
  -- counter and y_addr agree is CHECKED below rather than assumed.
  signal w_tile  : integer range 0 to TILES-1 := 0;

  signal c_cycles, c_beats, c_starve : unsigned(31 downto 0)
         := (others => '0');

  -- ---------------------------------------------------------- field access
  -- 64-bit little-endian words; every accessor assigns through a declared
  -- 0-based variable, the same rule rtl/seq_desc_fetch.vhd:355 states: a
  -- slice of a downto vector keeps the parent's bounds, so `return
  -- w(31 downto 0)` would hand back a vector indexed 31 downto 0 and any
  -- caller indexing it from zero reads the wrong end.
  function lo32(w : std_logic_vector(63 downto 0))
    return std_logic_vector is
    variable r : std_logic_vector(31 downto 0);
  begin r := w(31 downto 0); return r; end function;

  function hi32(w : std_logic_vector(63 downto 0))
    return std_logic_vector is
    variable r : std_logic_vector(31 downto 0);
  begin r := w(63 downto 32); return r; end function;

  -- True when no bit at or above ADDR_W is set.  A LOOP, not a slice compare:
  -- "the bits above ADDR_W" is an EMPTY range at ADDR_W = 64 and a null slice
  -- there reads as a mistake even though it is legal.  Same construction and
  -- same reason as matvec_int4_axi.vhd's fits_hi().
  function fits_addr(v : std_logic_vector(63 downto 0)) return boolean is
  begin
    for i in 0 to 63 loop
      if i >= ADDR_W and v(i) /= '0' then return false; end if;
    end loop;
    return true;
  end function;

  function is_4k_aligned(v : std_logic_vector(63 downto 0)) return boolean is
  begin
    return v(11 downto 0) = x"000";
  end function;

  -- The base-array verdict, combinational over all NP_ALL bases.  Split out of
  -- the FSM so S_CHECK is one clocked decision, exactly as seq_desc_fetch
  -- splits desc_chk out of its own.
  signal base_bad  : std_logic;
  signal base_code : std_logic_vector(3 downto 0);
  signal base_info : std_logic_vector(15 downto 0);
begin
  -- ------------------------------------------------------- generic contract
  assert ADDR_W >= 32 and ADDR_W <= 64
    report "matvec_int4_desc_axi: ADDR_W must be 32..64; DESC_PTR is a " &
           "32-bit LO/HI register pair and the descriptor's bases are 64-bit"
    severity failure;
  -- The descriptor is a stream of 64-bit words carved out of AXI beats, so a
  -- beat that is not a whole number of words has no defined decode.  Every
  -- AXI4 width in scope (64/128/256/512) satisfies this; the assert exists so
  -- that a build at 32 fails here rather than reading half a field.
  assert AXI_DW mod 64 = 0
    report "matvec_int4_desc_axi: AXI_DW must be a multiple of 64; the " &
           "descriptor is a stream of 64-bit little-endian words"
    severity failure;
  -- 512 bits is the widest AXI4 data bus, and it is also the widest this
  -- decode has been reasoned about: every beat carries AXI_DW/64 descriptor
  -- words and the DESC_ALIGN argument below assumes one burst fits one 4 KB
  -- page.
  assert AXI_DW <= 512
    report "matvec_int4_desc_axi: AXI_DW above 512 is not an AXI4 data width"
    severity failure;
  assert DESC_MAXB * BYTES <= 4096 and 4096 mod (DESC_MAXB * BYTES) = 0
    report "matvec_int4_desc_axi: DESC_MAXB*AXI_DW/8 must divide 4096, so " &
           "that a DESC_ALIGN-aligned burst cannot cross a 4 KB boundary"
    severity failure;
  assert DESC_FIFO >= DBEATS and DESC_FIFO >= DESC_MAXB
    report "matvec_int4_desc_axi: DESC_FIFO must hold a whole descriptor and " &
           "a whole burst"
    severity failure;
  -- GRP must be exact or the s_beats identity is not an identity.  This is
  -- weight_streamer's own 6.5a superword condition restated where the check
  -- that USES it lives, so a geometry that violates it fails here rather than
  -- silently refusing every legal descriptor.
  assert (NPORTS_S * AXI_DW) mod SW_BITS = 0
    report "matvec_int4_desc_axi: NPORTS_S*AXI_DW must be a whole number of " &
           "ROWS_IF*16-bit scale groups (spec 6.5a); s_beats has no identity " &
           "otherwise"
    severity failure;

  rst <= not s_axi_aresetn;

  s_axi_awready <= awready; s_axi_wready <= wready;
  s_axi_bvalid  <= bvalid;  s_axi_bresp  <= "00";
  s_axi_arready <= arready; s_axi_rvalid <= rvalid;
  s_axi_rresp   <= "00";    s_axi_rdata  <= rdata_r;

  -- The descriptor read master.  Same entity, same CDC, same flush-on-start
  -- discipline as a weight sub-region port; only the length differs.
  dfetch : entity work.axi_rd_port
    generic map(AXI_DW => AXI_DW, ADDR_W => ADDR_W, DEPTH => DESC_FIFO,
                MAXB => DESC_MAXB, MAXOUT => 2, DUAL_CLK => DUAL_CLK)
    port map(clk => s_axi_aclk, rst => rst, aclk => m_aclk,
             start => d_start,
             base => dptr(ADDR_W-1 downto 0), n_beats => DBEATS,
             arvalid => d_arvalid, arready => d_arready, araddr => d_araddr,
             arlen => d_arlen, arsize => d_arsize, arburst => d_arburst,
             rvalid => d_rvalid, rready => d_rready, rdata => d_rdata,
             rlast => d_rlast,
             q_valid => d_qv, q_data => d_qd, q_ready => d_qr);

  -- Accepted unconditionally while capturing: the capture is a register write
  -- and the fetch is bounded at DBEATS beats.
  d_qr <= '1' when st = S_R else '0';

  -- ------------------------------------------------- descriptor field decode
  -- Combinational off `dw`, which is written only in S_R and is stable from
  -- S_CHECK onwards, so nothing the core reads can move under it.
  v_rows   <= lo32(dw(1));
  v_cols   <= hi32(dw(1));
  v_wexp   <= lo32(dw(2));
  v_osh    <= hi32(dw(2));
  v_mode   <= dw(3)(1 downto 0);
  v_wbeats <= lo32(dw(EXT0 + 1));
  v_sbeats <= hi32(dw(EXT0 + 1));
  v_xexp   <= x_exp_in when USE_XEXP_PORT else lo32(dw(EXT0 + 2));

  gen_wb : for p in 0 to NPORTS_W-1 generate
    w_base((p+1)*ADDR_W-1 downto p*ADDR_W)
      <= dw(DESC_BASE0 + p)(ADDR_W-1 downto 0);
  end generate;
  gen_sb : for q in 0 to NPORTS_S-1 generate
    s_base((q+1)*ADDR_W-1 downto q*ADDR_W)
      <= dw(DESC_BASE0 + NPORTS_W + q)(ADDR_W-1 downto 0);
  end generate;

  -- ------------------------------------------------------ base-array checks
  bchk : process(dw)
    variable bad  : std_logic;
    variable code : std_logic_vector(3 downto 0);
    variable info : std_logic_vector(15 downto 0);
  begin
    bad  := '0'; code := EC_NONE; info := (others => '0');
    for p in 0 to NP_ALL-1 loop
      if bad = '0' and not fits_addr(dw(DESC_BASE0 + p)) then
        bad := '1'; code := EC_ADDR;
        info := ei(EI_SUB_NONE, DESC_BASE0 + p);
      end if;
      if bad = '0' and not is_4k_aligned(dw(DESC_BASE0 + p)) then
        bad := '1'; code := EC_ALIGN;
        info := ei(EI_SUB_NONE, DESC_BASE0 + p);
      end if;
    end loop;
    base_bad <= bad; base_code <= code; base_info <= info;
  end process;

  -- ----------------------------------------------------------------- core
  dut : entity work.matvec_int4
    generic map(BLK => BLK, ROWS_IF => ROWS_IF, NPORTS_W => NPORTS_W,
                NPORTS_S => NPORTS_S, AXI_DW => AXI_DW, ADDR_W => ADDR_W,
                MAXCOLS => MAXCOLS, MAXROWS_BFP => MAXROWS_BFP,
                FIFO_DEPTH => FIFO_DEPTH, MAXB => MAXB, MAXOUT => MAXOUT,
                DUAL_CLK => DUAL_CLK)
    port map(clk => s_axi_aclk, rst => rst, aclk => m_aclk,
             start => core_start,
             n_rows => v_rows, n_cols => v_cols, out_shift => v_osh,
             w_exp => v_wexp, x_exp => v_xexp, out_mode => v_mode,
             w_base => w_base, w_beats => v_wbeats,
             s_base => s_base, s_beats => v_sbeats,
             cb_we => cb_we, cb_addr => cb_addr, cb_data => cb_data,
             x_we => x_we, x_waddr => x_waddr, x_wdata => x_wdata,
             m_arvalid => m_arvalid, m_arready => m_arready,
             m_araddr => m_araddr, m_arlen => m_arlen,
             m_arsize => m_arsize, m_arburst => m_arburst,
             m_rvalid => m_rvalid, m_rready => m_rready,
             m_rdata => m_rdata, m_rlast => m_rlast,
             y_we => y_we_i, y_addr => y_addr_i, y_data => y_data_i,
             y_mask => y_mask_i, y_exp => v_yexp,
             done => core_done, err => core_err, sat_event => core_sat,
             dbg_wbeat => dbg_wbeat, dbg_wstarve => dbg_wstarve);

  y_we    <= y_we_i;
  y_addr  <= y_addr_i;
  y_data  <= y_data_i;
  y_mask  <= y_mask_i;
  y_exp_o <= v_yexp;
  -- The SAME masked view STATUS presents, so a consumer of the port and a
  -- consumer of the register cannot disagree about whether a job is done.
  -- The mask covers the handshake cycle itself, which the registered clear
  -- cannot: a read accepted on the very cycle of the GO write would otherwise
  -- latch the old done_l.  No PCIe master can issue that read (a non-posted
  -- read cannot pass the posted write ahead of it), but "no master can" is an
  -- argument about the master and this is meant to be an argument about the
  -- slave.
  job_done <= done_l and not go_now;
  job_err  <= err_l;

  -- =====================================================================
  -- THE CONTROL FSM.  Fetch, check, load the codebook, start, wait.
  -- =====================================================================
  ctrl : process(s_axi_aclk)
    variable widx : integer;
    variable op   : integer;
  begin
    if rising_edge(s_axi_aclk) then
      core_start <= '0';
      cb_we      <= '0';
      d_start    <= '0';

      if rst = '1' then
        st <= S_IDLE; busy <= '0'; done_l <= '0'; err_l <= '0';
        err_code <= EC_NONE; err_info <= (others => '0');
        f_got <= 0; wdog <= 0; cb_cnt <= 0;
        sh_rows <= 0; sh_cols <= 0; sh_t <= 0; sh_nb <= 0;
        sh_racc <= 0; sh_cacc <= 0; sh_prod <= 0;
        cb_valid <= '0'; sat_l <= '0'; go_p <= '0';
        dw <= (others => (others => '0'));

      else
        -- UNCONDITIONAL, in every state in every cycle.  See go_p's comment.
        -- done_l is cleared HERE and not in S_IDLE: see done_l's declaration.
        -- The S_WAIT arm below may set it again in this same cycle and wins,
        -- which is the right priority -- a job that completes on the cycle a
        -- new GO is written has completed.
        if go_now = '1' then go_p <= '1'; done_l <= '0'; end if;
        if core_sat = '1' then sat_l <= '1'; end if;

        case st is
          -- ------------------------------------------------------- idle
          when S_IDLE =>
            if go_p = '1' then
              go_p   <= '0';
              busy   <= '1';
              -- REDUNDANT since the go_now clear above, and deliberately kept.
              -- It is the assignment this defect used to live in, and leaving
              -- it means the go_now clear is the ONLY thing standing between
              -- the design and a three-cycle stale window -- so a mutation
              -- that removes it is caught by the timing check and by nothing
              -- else, which is what makes that check attributable.
              done_l <= '0';
              sat_l  <= '0';
              wdog   <= 0;
              c_cycles <= (others => '0');
              c_beats  <= (others => '0');
              c_starve <= (others => '0');
              -- Two things about the POINTER are checkable before any AXI
              -- transaction exists, so they are checked here rather than
              -- being allowed to issue a read at a nonsense address.
              if not fits_addr(dptr) then
                err_code <= EC_ADDR;
                err_info <= EI_PTR_V;
                st <= S_ERR;
              elsif unsigned(dptr(clog2(DESC_ALIGN)-1 downto 0)) /= 0 then
                err_code <= EC_ALIGN;
                err_info <= EI_PTR_V;
                st <= S_ERR;
              else
                f_got   <= 0;
                d_start <= '1';
                st      <= S_FETCH;
              end if;
            end if;

          -- ------------------------------------------------ issue the read
          -- One cycle, purely to let `d_start` reach the read port.  The port
          -- owns the burst splitting, the outstanding accounting and (under
          -- DUAL_CLK) the clock domain crossing; there is nothing to do here
          -- but wait for beats.
          when S_FETCH =>
            st <= S_R;

          -- --------------------------------------------------- take beats
          when S_R =>
            -- The increment is INSIDE the else: `wdog` is range-bound at
            -- WDOG_LIMIT, so incrementing on the cycle the limit is reached
            -- would be a bound violation, not a timeout.
            if wdog = WDOG_LIMIT then
              err_code <= EC_WDOG;
              err_info <= EI_PTR_V;
              st <= S_ERR;
            else
              wdog <= wdog + 1;
              if d_qv = '1' then
                for j in 0 to WPB-1 loop
                  widx := f_got * WPB + j;
                  if widx < DWORDS then
                    dw(widx) <= d_qd((j+1)*64-1 downto j*64);
                  end if;
                end loop;
                if f_got = DBEATS-1 then
                  st <= S_CHECK;
                else
                  f_got <= f_got + 1;
                end if;
              end if;
            end if;

          -- ---------------------------------------------------- the checks
          -- One clocked decision, first match wins, and NOTHING has been
          -- started yet.
          when S_CHECK =>
            op := to_integer(unsigned(dw(0)(7 downto 0)));
            if lo32(dw(EXT0)) /= MV4I_MAGIC then
              err_code <= EC_MAGIC;
              err_info <= ei(EI_SUB_NONE, EXT0);
              st <= S_ERR;
            elsif to_integer(unsigned(dw(EXT0)(47 downto 32))) /= MV4I_DESC_VER then
              err_code <= EC_VER;
              err_info <= ei(EI_SUB_NONE, EXT0);
              st <= S_ERR;
            elsif dw(EXT0)(63 downto 48) /= x"0000" then
              err_code <= EC_DESC;                     -- ext_flags reserved
              err_info <= ei(ED_EXT_FLAGS, EXT0);
              st <= S_ERR;
            elsif to_integer(unsigned(dw(3)(31 downto 16))) /= NPORTS_W then
              err_code <= EC_GEOM;
              err_info <= ei(EG_NSUB_W, 3);
              st <= S_ERR;
            elsif to_integer(unsigned(dw(3)(47 downto 32))) /= NPORTS_S then
              err_code <= EC_GEOM;
              err_info <= ei(EG_NSUB_S, 3);
              st <= S_ERR;
            elsif op /= OP_A_JOB then
              err_code <= EC_DESC;                     -- opcode
              err_info <= ei(ED_OPCODE, 0);
              st <= S_ERR;
            elsif dw(3)(63 downto 56) /= x"00" then
              err_code <= EC_DESC;                     -- D's word 3 pad
              err_info <= ei(ED_PAD_W3, 3);
              st <= S_ERR;
            elsif dw(7) /= x"0000000000000000" then
              err_code <= EC_DESC;                     -- D's word 7 pad
              err_info <= ei(ED_PAD_W7, 7);
              st <= S_ERR;
            elsif hi32(dw(EXT0 + 2)) /= x"00000000" then
              err_code <= EC_DESC;                     -- A's extension pads
              err_info <= ei(ED_PAD_EXT, EXT0 + 2);
              st <= S_ERR;
            elsif dw(EXT0 + 3) /= x"0000000000000000" then
              err_code <= EC_DESC;                     -- A's extension pads
              err_info <= ei(ED_PAD_EXT, EXT0 + 3);
              st <= S_ERR;
            elsif to_integer(unsigned(dw(3)(7 downto 0))) > 2 then
              err_code <= EC_DESC;                     -- out_mode 3..255
              err_info <= ei(ED_OUT_MODE, 3);
              st <= S_ERR;
            elsif unsigned(lo32(dw(1))) = 0 then
              err_code <= EC_DESC;                     -- shape: n_rows = 0
              err_info <= ei(ED_ROWS_ZERO, 1);
              st <= S_ERR;
            elsif unsigned(lo32(dw(1))) > MAXROWS_BFP then
              err_code <= EC_DESC;                     -- shape: n_rows too big
              err_info <= ei(ED_ROWS_MAX, 1);
              st <= S_ERR;
            elsif unsigned(hi32(dw(1))) = 0 then
              err_code <= EC_DESC;                     -- shape: n_cols = 0
              err_info <= ei(ED_COLS_ZERO, 1);
              st <= S_ERR;
            elsif unsigned(hi32(dw(1))) > MAXCOLS then
              err_code <= EC_DESC;                     -- shape: n_cols too big
              err_info <= ei(ED_COLS_MAX, 1);
              st <= S_ERR;
            elsif unsigned(lo32(dw(EXT0 + 1))) = 0 then
              err_code <= EC_DESC;                     -- w_beats = 0
              err_info <= ei(ED_WBEATS_ZERO, EXT0 + 1);
              st <= S_ERR;
            elsif unsigned(hi32(dw(EXT0 + 1))) = 0 then
              err_code <= EC_DESC;                     -- s_beats = 0
              err_info <= ei(ED_SBEATS_ZERO, EXT0 + 1);
              st <= S_ERR;
            elsif base_bad = '1' then
              err_code <= base_code;
              err_info <= base_info;
              st <= S_ERR;
            elsif dw(0)(10) = '0' and cb_valid = '0' then
              -- flags bit 2 is D's cb_load, at word 0 bit 8+2.  Reusing a
              -- codebook that was never loaded computes an all-zero answer
              -- and reports success, which is the failure mode this whole
              -- file exists to stop.
              err_code <= EC_DESC;                     -- codebook never loaded
              err_info <= ei(ED_CB_UNLOADED, 0);
              st <= S_ERR;
            else
              -- Everything above passed, so n_rows and n_cols are inside
              -- 1..MAXROWS_BFP / 1..MAXCOLS and the accumulators below are
              -- bounded by TILES and NBMAX.  Latching them as integers here
              -- is what makes that true: to_integer on a 32-bit field is only
              -- ever evaluated on a value the range check has already passed.
              cb_cnt  <= 0;
              sh_rows <= to_integer(unsigned(lo32(dw(1))));
              sh_cols <= to_integer(unsigned(hi32(dw(1))));
              sh_t    <= 0; sh_nb   <= 0;
              sh_racc <= 0; sh_cacc <= 0;
              st <= S_SHAPE;
            end if;

          -- ----------------------------------------------- the shape gate
          -- MULTIPLY UP.  One cycle per tile and per block, in parallel, until
          -- each accumulator covers its dimension.  On exit sh_t is
          -- ceil(n_rows/ROWS_IF) and sh_nb is ceil(n_cols/BLK), by the
          -- definition of "smallest t with t*ROWS_IF >= n_rows".
          when S_SHAPE =>
            if sh_racc >= sh_rows and sh_cacc >= sh_cols then
              sh_prod <= sh_t * sh_nb;         -- the ONE multiply
              st <= S_SHAPE_C;
            else
              if sh_racc < sh_rows then
                sh_racc <= sh_racc + ROWS_IF;
                sh_t    <= sh_t + 1;
              end if;
              if sh_cacc < sh_cols then
                sh_cacc <= sh_cacc + BLK;
                sh_nb   <= sh_nb + 1;
              end if;
            end if;

          -- ------------------------------------------------- the verdict
          -- w_beats must be EXACTLY tiles*nblk, and s_beats exactly
          -- ceil(tiles*nblk / GRP) -- stated as a bracket so that GRP, a
          -- synthesis constant, is multiplied rather than divided.  s_beats
          -- is known nonzero here (the check above rejects 0), so the
          -- `sb - 1` cannot underflow.  Both operands are widened to 64 bits
          -- because a garbage 32-bit s_beats times GRP overflows 32.
          when S_SHAPE_C =>
            if unsigned(lo32(dw(EXT0 + 1))) /= to_unsigned(sh_prod, 32) then
              err_code <= EC_SHAPE;
              err_info <= ei(ES_WBEATS, EXT0 + 1);
              st <= S_ERR;
            elsif unsigned(hi32(dw(EXT0 + 1))) * GRP
                    < to_unsigned(sh_prod, 64) then
              err_code <= EC_SHAPE;
              err_info <= ei(ES_SBEATS_LO, EXT0 + 1);
              st <= S_ERR;
            elsif (unsigned(hi32(dw(EXT0 + 1))) - 1) * GRP
                    >= to_unsigned(sh_prod, 64) then
              err_code <= EC_SHAPE;
              err_info <= ei(ES_SBEATS_HI, EXT0 + 1);
              st <= S_ERR;
            else
              st <= S_CB;
            end if;

          -- ------------------------------------------------- codebook load
          when S_CB =>
            if dw(0)(10) = '0' then
              st <= S_START;                 -- reuse the loaded codebook
            elsif cb_cnt = 16 then
              cb_valid <= '1';
              st <= S_START;
            else
              cb_addr <= std_logic_vector(to_unsigned(cb_cnt, 4));
              if cb_cnt < 8 then
                cb_data <= dw(5)((cb_cnt+1)*8-1 downto cb_cnt*8);
              else
                cb_data <= dw(6)((cb_cnt-8+1)*8-1 downto (cb_cnt-8)*8);
              end if;
              cb_we  <= '1';
              cb_cnt <= cb_cnt + 1;
            end if;

          when S_START =>
            core_start <= '1';
            st <= S_WAIT;

          when S_WAIT =>
            c_cycles <= c_cycles + 1;
            if dbg_wbeat   = '1' then c_beats  <= c_beats + 1;  end if;
            if dbg_wstarve = '1' then c_starve <= c_starve + 1; end if;
            if core_err = '1' then
              err_code <= EC_CORE;
              err_info <= EI_PTR_V;
              st <= S_ERR;
            elsif core_done = '1' then
              busy   <= '0';
              done_l <= '1';
              st     <= S_DONE;
            end if;

          -- S_DONE leaves `go_p` SET and lets S_IDLE consume it, so a GO that
          -- arrives here is not swallowed by the state change.
          when S_DONE =>
            if go_p = '1' then st <= S_IDLE; end if;

          -- STICKY.  Only a reset leaves this state: a design that could be
          -- re-armed by another GO would let a driver that ignores STATUS
          -- keep running descriptors past a rejected one.
          when S_ERR =>
            busy  <= '0';
            err_l <= '1';
        end case;
      end if;
    end if;
  end process;

  -- ------------------------------------------------------------ write channel
  --
  -- THE one decode of "a GO write is being accepted, this cycle".  Held in
  -- reset because s_axi_aresetn drives awready/wready low, so no handshake can
  -- be in progress; stated rather than relied on.
  go_now <= '1' when s_axi_aresetn = '1' and awready = '1' and wready = '1'
                     and unsigned(wr_addr(7 downto 2)) = 2
                     and s_axi_wdata(0) = '1'
            else '0';

  wrp : process(s_axi_aclk)
    variable reg : integer;
  begin
    if rising_edge(s_axi_aclk) then
      if s_axi_aresetn = '0' then
        awready <= '0'; wready <= '0'; bvalid <= '0';
        err_addr <= '0'; dptr <= (others => '0'); y_idx <= (others => '0');
      else
        if awready = '0' and s_axi_awvalid = '1' and s_axi_wvalid = '1' then
          awready <= '1'; wready <= '1'; wr_addr <= s_axi_awaddr;
        else
          awready <= '0'; wready <= '0';
        end if;

        if awready = '1' and wready = '1' then
          reg := to_integer(unsigned(wr_addr(7 downto 2)));
          case reg is
            when 0 => dptr(31 downto 0)  <= s_axi_wdata;
            when 1 =>
              dptr(63 downto 32) <= s_axi_wdata;
              -- WRITE-TIME check, deliberately kept from the old map: a driver
              -- that reads STATUS after programming the pointer sees this
              -- before it runs anything.
              for i in 0 to 31 loop
                if 32 + i >= ADDR_W and s_axi_wdata(i) /= '0' then
                  err_addr <= '1';
                end if;
              end loop;
            -- reg 2 is CTRL/GO and is deliberately EMPTY here.  The GO is
            -- decoded combinationally as `go_now` above, in the handshake
            -- cycle itself; a registered copy set in this arm is what put the
            -- start of the job one clock behind the write.
            when 2 => null;
            when 9 => y_idx <= unsigned(s_axi_wdata(15 downto 0));
            when others => null;
          end case;
          bvalid <= '1';
        elsif bvalid = '1' and s_axi_bready = '1' then
          bvalid <= '0';
        end if;
      end if;
    end if;
  end process;

  -- ------------------------------------------- Y_IDX -> (tile, lane) by
  -- repeated subtraction.  Restarts whenever Y_IDX changes; y_ok marks the
  -- pair final.  See the declarations for why this is not a divide.
  ydiv : process(s_axi_aclk)
  begin
    if rising_edge(s_axi_aclk) then
      if s_axi_aresetn = '0' then
        yi_snap <= (others => '0'); yi_run <= (others => '0');
        yi_q <= 0; yq <= 0; yr <= 0; y_ok <= '0';
      elsif y_idx /= yi_snap then
        -- a new index: reload and start again.  Comparing against the
        -- SNAPSHOT rather than watching the register write is what makes a
        -- rewrite of the same value cost nothing and a rewrite mid-loop
        -- restart correctly.
        yi_snap <= y_idx;
        yi_run  <= y_idx;
        yi_q    <= 0;
        y_ok    <= '0';
      elsif y_ok = '0' then
        if yi_run >= ROWS_IF then
          if yi_q = TILES-1 then
            -- Y_IDX is past the last row this build can hold.  SATURATE
            -- rather than run off the end of `res`: the old expression
            -- res(to_integer(y_idx)/ROWS_IF) indexed outside the array for
            -- any Y_IDX >= TILES*ROWS_IF, which is a simulation abort and an
            -- undefined address in hardware.  Nothing legal reaches here.
            yq <= TILES-1; yr <= ROWS_IF-1; y_ok <= '1';
          else
            yi_run <= yi_run - ROWS_IF;
            yi_q   <= yi_q + 1;
          end if;
        else
          yq <= yi_q; yr <= to_integer(yi_run); y_ok <= '1';
        end if;
      end if;
    end if;
  end process;

  -- --------------------------------------------------------- result capture
  resp : process(s_axi_aclk)
  begin
    if rising_edge(s_axi_aclk) then
      if y_we_i = '1' then
        res(w_tile) <= y_data_i;
        -- THE ASSUMPTION, CHECKED.  w_tile replaces y_addr_i/ROWS_IF and is
        -- only equal to it while the core emits tiles in order starting at
        -- tile 0.  Vivado drops `assert` in synthesis, so this costs nothing
        -- there and fires in every GHDL run.
        assert w_tile * ROWS_IF = to_integer(unsigned(y_addr_i))
          report "matvec_int4_desc_axi: result write " & integer'image(w_tile)
               & " carries y_addr = "
               & integer'image(to_integer(unsigned(y_addr_i)))
               & ", not " & integer'image(w_tile * ROWS_IF)
               & ".  The tile counter that replaced y_addr/ROWS_IF assumes "
               & "the core emits tiles in order from 0."
          severity failure;
        if w_tile < TILES-1 then w_tile <= w_tile + 1; end if;
      end if;
      if core_start = '1' then w_tile <= 0; end if;
      -- registered read, issued continuously so it infers a BRAM read port
      res_q <= res(yq);
      y_rdy <= y_ok;
    end if;
  end process;

  -- combinational lane mux, aligned to the index that fetched res_q
  y_sel <= res_q((yr + 1)*64 - 1 downto yr*64);

  -- ------------------------------------------------------------- read channel
  rdp : process(s_axi_aclk)
    variable rreg : integer;
  begin
    if rising_edge(s_axi_aclk) then
      if s_axi_aresetn = '0' then
        arready <= '0'; rvalid <= '0';
      else
        rreg := to_integer(unsigned(s_axi_araddr(7 downto 2)));
        -- Y_LO / Y_HI STALL until Y_IDX has been resolved to (tile, lane) and
        -- res_q has been fetched at that tile.  Holding arready low is a real
        -- handshake; the alternative -- answering immediately and trusting
        -- the host to have left enough cycles since the Y_IDX write -- is a
        -- software convention that no constraint or test would ever check.
        -- Every other register answers in the same cycle it always did.
        if arready = '0' and s_axi_arvalid = '1'
           and not ((rreg = 10 or rreg = 11) and (y_ok and y_rdy) = '0') then
          arready <= '1';
          case rreg is
            when 0 => rdata_r <= dptr(31 downto 0);
            when 1 => rdata_r <= dptr(63 downto 32);
            when 3 => rdata_r <= (31 downto 12 => '0') & err_code &
                                 (7 downto 5 => '0') &
                                 err_addr & sat_l & err_l & busy &
                                 (done_l and not go_now);
            when 4 => rdata_r <= (31 downto 16 => '0') & err_info;
            when 5 => rdata_r <= MV4I_MAGIC;
            when 6 => rdata_r <= std_logic_vector(to_unsigned(ADDR_W, 32));
            when 7 => rdata_r <=
                        std_logic_vector(to_unsigned(BYTES, 8)) &
                        std_logic_vector(to_unsigned(ROWS_IF, 8)) &
                        std_logic_vector(to_unsigned(NPORTS_S, 8)) &
                        std_logic_vector(to_unsigned(NPORTS_W, 8));
            when 8 => rdata_r <= std_logic_vector(to_unsigned(DWORDS, 32));
            when 10 => rdata_r <= y_sel(31 downto 0);
            when 11 => rdata_r <= y_sel(63 downto 32);
            when 12 => rdata_r <= v_yexp;
            when 13 => rdata_r <= std_logic_vector(c_cycles);
            when 14 => rdata_r <= std_logic_vector(c_beats);
            when 15 => rdata_r <= std_logic_vector(c_starve);
            when others => rdata_r <= (others => '0');
          end case;
          rvalid <= '1';
        elsif rvalid = '1' and s_axi_rready = '1' then
          arready <= '0'; rvalid <= '0';
        else
          arready <= '0';
        end if;
      end if;
    end if;
  end process;
end architecture;
