-- sim/tb_attn_kv_seam.vhd
-- rtl/attn_block.vhd JOINED TO rtl/attn_kv_axi.vhd, over a MULTI-TOKEN
-- sequence, against ref/attn_block_seq_vec.c.
--
-- ======================================================================
-- WHAT THIS ESTABLISHES THAT NEITHER UNIT COULD ESTABLISH ALONE
-- ======================================================================
--
-- Both units were bit-exact before this bench existed and neither fact
-- reached the other:
--
--   * sim/tb_attn_block.vhd drives the KV cache with a MEMORY MODEL whose
--     records the oracle made up.  No record is ever both written and later
--     read, so nothing in it can see the append, the address equation's
--     agreement between the write master and the read masters, or v_ref
--     folding across tokens.
--   * sim/tb_attn_kv_axi.vhd drives attn_kv_axi with a synthetic consumer.
--     It proves the cache serves the port shape; it says nothing about
--     whether attention is what asked for those records.
--
-- And they COULD NOT BE CONNECTED.  MEASURED on the pre-seam RTL, by giving
-- sim/tb_attn_block.vhd's memory model one extra cycle of read latency and
-- changing nothing else: 64 of 64 output mantissas wrong against the oracle,
-- on every run, with `err` clear.  attn_block issued one beat per cycle back
-- to back and captured a fixed two cycles later with nothing to wait on; HBM
-- latency is O(100) cycles.  The four `_rdy` inputs added to attn_block on
-- 2026-08-28 are the seam and this bench is what holds them shut.
--
-- ======================================================================
-- THE PROPERTIES
-- ======================================================================
--
--   Q1  THE VALUES, BIT-EXACTLY, PER TOKEN.  Every one of the N_QH*HEAD_DIM
--       output mantissas and the y_exp of every token must equal
--       ref/attn_block_seq_vec.c's exactly, with no tolerance.  Token t
--       attends over positions [t, 0, 1, ..., t-1] where 0..t-1 are the
--       records tokens 0..t-1 actually wrote through the AXI write master and
--       read back through the AXI read masters.  Token 0 is the cur_pos = 0
--       case `llama_top` already ran; tokens 1..NTOK-1 are new.
--
--   Q2  THE RECORD IMAGE IN MEMORY.  After the sequence, every byte of every
--       record -- NBLK block exponents in the 16-byte header chunk, HEAD_DIM
--       int8 mantissas after it -- must equal the oracle's, AT THE ADDRESS
--       C spec 2.2's equation gives.  "The block computed the right numbers"
--       and "the record landed at the right address" are different claims and
--       a bench that checked only y could not tell a wrong address from a
--       wrong value: two masters agreeing on a wrong address produce a
--       perfect answer.
--
--   Q3  THE RETURNED BEAT IS THE REQUESTED BEAT.  On every kr_en / vr_en the
--       (head, pos, blk) is latched and the beat that arrives on the next
--       cycle is compared against the oracle's record for THAT position.
--       This is a direct check of the read path that does not go through the
--       arithmetic at all, so a reordering across positions is caught as a
--       reordering rather than as a wrong number.
--
--   Q4  THE HANDSHAKE.  `kr_en` may only be raised while `kr_rdy` stands,
--       `vr_en` only while `vr_rdy`, and `kw_hen` / `kw_en` only while
--       `kw_rdy`.  A beat taken early is the pre-seam behaviour and it is a
--       SILENT wrong answer, so it has to be an explicit property.
--
--   Q5  C SPEC 2.7, THE RULE THAT ONLY A SEQUENCE CAN FALSIFY.  At the cycle
--       `done` rises for token t, the memory must ALREADY hold token t's four
--       records.  Token t+1 reads them through a different master and AXI
--       orders nothing between masters, so a `done` that does not wait for
--       BRESP is a race that a fast memory hides.
--
--   Q6  THE BYPASS, over the addresses.  No read master is ever asked for
--       pos >= cur_pos (C spec 2.4), and every pos < cur_pos is read exactly
--       once per KV head per token, every block of it.
--
--   Q7  NO ERROR.  Neither unit raises `err` on a legal sequence, and every
--       token completes.
--
-- ======================================================================
-- THE GEOMETRY, AND THE TWO SPEC CONSTRAINTS IT DELIBERATELY BREAKS
-- ======================================================================
--
-- HEAD_DIM 64 / KV_BLOCK 16 makes REC_B = 80 bytes, which is NOT a multiple
-- of the 32-byte beat, so the 16-byte record phase alternates with the
-- parity of `pos` and the realignment mux is exercised on every other record.
--
-- C spec 2.2 requires `k_base` and `v_base` to be 4 KB aligned and MAXCTX to
-- be a multiple of 256.  Neither holds here -- K_BASE = 16, V_BASE = 4064,
-- MAXCTX = 8 -- and that is the point: rtl/attn_kv_axi.vhd splits on the
-- ABSOLUTE beat address rather than on an offset from the base, so those
-- constraints are unnecessary.  V_BASE = 4064 puts the very first V record of
-- layer 0 across the 4 KB boundary at 4096, so a read run that starts there
-- MUST split.  If the spec still says otherwise, it is the spec that is
-- wrong, and this bench is the measurement that says so.
--
-- ======================================================================
-- WHAT THIS DOES NOT ESTABLISH
-- ======================================================================
--
--   * NOT the shipping geometry.  HEAD_DIM 256 / 12 query heads / 2 KV heads
--     / KV_BLOCK 32 / N_ROT 64 is the build; this is 64 / 4 / 2 / 16 / 16.
--   * NOT a long context.  NTOK is 4 by default.  The s26 softmax denominator
--     and the s36 accumulator are the widths that would first bite at long
--     context and neither is approached here.
--   * NOT the real HBM.  The slaves below are a fixed-latency in-order model
--     with a single ID.  Reordering across IDs, refresh, and bank conflicts
--     are not modelled, and no hardware was touched.
--   * NOT more than NLAY layers.  NLAY is 2 by default.  Two is enough to
--     make every per-layer quantity contended (see THE SCHEDULE below) and
--     nothing here is quadratic in the layer count, but a defect that needs
--     three distinct layers to appear would not be seen.
--   * NOT a per-layer ctx_len.  Every layer runs the same sequence length,
--     which is what a transformer does; a design that latched ctx_len from
--     the wrong layer's job would be invisible here.
--
-- ======================================================================
-- THE SCHEDULE: TWO LAYERS, INTERLEAVED
-- ======================================================================
--
-- The run is NTOK*NLAY jobs in TOKEN-major, LAYER-minor order,
--
--     step s -> token t = s/NLAY, layer l = s mod NLAY
--
-- so it goes (tok 0, lay 0), (tok 0, lay 1), (tok 1, lay 0), ... -- the
-- order a transformer actually runs, and the only order in which the
-- per-layer state is genuinely contended.  Layer 0's whole sequence
-- followed by layer 1's would leave layer 0 untouched by layer 1, so half
-- of any layer-crossing defect would be invisible and the other half would
-- look like a first-token effect.
--
-- What ONLY the interleave can falsify, and what a one-layer stream was
-- bit-exact under:
--
--   L1  THE `v_ref` FOLD IS PER (LAYER, KV HEAD).  C spec 2.1.4, and defect
--       C1 (docs/debugging/2026-08-29_c1-vref-layer.md).  `attn_block` holds
--       ONE fold array and time-shares it across every attention layer, so a
--       fold indexed by head alone lets each layer's write-time minimum leak
--       into every other layer's alignment shift.  With one layer in the
--       stream there is nothing to leak from.
--   L2  THE ADDRESS EQUATION'S `layer` TERM.  At a single layer 0 a design that
--       dropped the term entirely is byte-identical.  With two layers the
--       write master and the read master must agree on it, and they are
--       different masters over different AXI channels.
--   L3  THE QK-NORM WEIGHTS ARE LATCHED PER LAYER.  `attn_block` samples
--       them at `start` (SEAM 1).  One weight set for the whole run cannot
--       tell a latch from a wire, nor a latch that sampled the PREVIOUS
--       job's weights.
--   L4  `kv_layer` TRACKS THE CONFIGURED LAYER.  `rtl/llama_top.vhd` asserts
--       this because the block's own latch putting a whole layer's records
--       at another layer's addresses would still be SERVED by every read.
--       At one layer the assert is a tautology.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;
use work.util_pkg.all;

entity tb_attn_kv_seam is
  generic(
    HEAD_DIM : positive := 64;
    N_QH     : positive := 4;
    N_KVH    : positive := 2;
    KV_BLOCK : positive := 16;
    N_ROT    : positive := 16;
    LAYERS   : positive := 2;
    MAXCTX   : positive := 8;
    NTOK     : positive := 4;
    -- How many attention layers the schedule interleaves.  MUST be >= 2 and
    -- <= LAYERS; both are asserted at elaboration.  See THE SCHEDULE.
    NLAY     : positive := 2;
    POS_W    : positive := 16;
    AXI_DW   : positive := 256;
    ADDR_W   : positive := 16;
    MAXB     : positive := 16;
    MAXOUT   : positive := 4;
    RBUF     : positive := 4;
    RD_LAT   : natural  := 100;  -- AR accepted -> first beat, cycles.  HBM
                                 -- read latency is O(100); the pre-seam block
                                 -- allowed exactly 1.
    WR_LAT   : natural  := 12;   -- WLAST -> BVALID, cycles
    AW_LAT   : natural  := 0;    -- cycles the write slave refuses AWVALID
    STALL    : natural  := 5;    -- 0 = never stall; else 1-in-STALL gaps
    -- Mutation hooks.  Every one of these is '0'/0 in the shipping bench and
    -- is set only by sim/mutate_attn_kv_seam.sh.  They live here rather than
    -- in a scratch copy of the RTL because what they break is the SEAM, which
    -- is a property of the two files together and of nothing in either.
    MUT_EARLY_BEAT  : boolean := false;  -- ignore kr_rdy, issue anyway
    MUT_DROP_RDY    : boolean := false;  -- pull kr_rdy low mid-record
    MUT_REORDER     : boolean := false;  -- ask for the neighbouring POSITION
    MUT_BLK_SWAP    : boolean := false;  -- ask for the neighbouring BLOCK
    MUT_NO_WRIDLE   : boolean := false;  -- done without waiting for BRESP
    -- Hands the CACHE a cur_pos one larger than the block's, so its own
    -- pos >= cur_pos refusal no longer covers the block's cur_pos.  Paired
    -- with removing the block's bypass, it is the only cheap way to make the
    -- cache actually SERVE a read of the current position -- five separate
    -- guards inside attn_kv_axi would otherwise have to come out, at which
    -- point the mutant is a different design rather than a mutation.
    MUT_CACHE_CPOS_HI : boolean := false;
    MUT_SEQRST_TOK  : boolean := false;  -- reset v_ref per TOKEN, not sequence
    -- Hands the CACHE layer 0 for every job while the BLOCK runs the
    -- schedule's layer.  A pure SEAM mutation: neither file is wrong on its
    -- own, they merely disagree about which layer's region the records
    -- belong in, and every read is still served -- which is precisely why
    -- `rtl/llama_top.vhd` carries an assert for it.
    MUT_KV_LAY0     : boolean := false;
    -- Drives the BLOCK layer 0 for every job while the cache runs the
    -- schedule's layer.  The mirror of MUT_KV_LAY0, and the one that also
    -- collapses the per-layer v_ref fold and the QK-norm latch.
    MUT_BLK_LAY0    : boolean := false;
    -- Hands the block the OTHER layer's QK-norm weights while everything
    -- else about the job is correct.  It exists to give the per-layer weight
    -- axis its own teeth check: without it the weights could have been wired
    -- to layer 0 for every job and L3 would still kill, so the axis would be
    -- dead and nothing would say so.
    MUT_WN_SWAP     : boolean := false;
    WDOG     : positive := 20000;-- cycles of dead air that count as a hang
    HEARTBEAT_US : integer := 0
  );
end entity;

architecture sim of tb_attn_kv_seam is

  constant MANT_W : positive := 16;
  constant CM_W   : positive := 8;
  constant EXP_W  : positive := 8;
  constant NBLK   : integer  := HEAD_DIM/KV_BLOCK;
  constant G      : integer  := N_QH/N_KVH;
  constant NY     : integer  := N_QH*HEAD_DIM;

  constant CH_B   : integer := 16;                  -- the record granule
  constant REC_B  : integer := CH_B + HEAD_DIM;     -- 80 at this geometry
  constant BEAT_B : integer := AXI_DW/8;            -- 32
  constant K_BASE : integer := 16;                  -- 16 B aligned, NOT 4 KB
  constant V_BASE : integer := 4064;                -- straddles 4096
  constant NB     : integer := 8192;                -- bytes of modelled HBM

  -- ======================= the oracle's vector file =====================
  -- One flat integer stream in the order ref/attn_block_seq_vec.c writes it.
  -- The offsets are DERIVED from the generics and the file's own shape header
  -- is asserted against them, so a file written for another geometry is a
  -- loud failure rather than a silent misread at the wrong offsets.
  type int_arr is array (natural range <>) of integer;

  -- The vector file is indexed by STEP, not by token: one step is one
  -- (token, layer) job.  `s_of` is the schedule, written here ONCE, and it
  -- is the inverse the Q3 and Q5 checks need -- they know a LAYER and a
  -- POSITION and must find the step whose record that is.
  constant NSTEP    : integer := NTOK*NLAY;
  function s_of (lay, ps : integer) return integer is
  begin return ps*NLAY + lay; end function;

  constant OFF_EXPS : integer := 8;      -- 8: the shape header gained NLAY
  constant OFF_QNW  : integer := OFF_EXPS + 5;
  constant OFF_KNW  : integer := OFF_QNW + NLAY*HEAD_DIM;
  constant RECH     : integer := 2*NBLK + 2*HEAD_DIM;   -- one head's record
  constant TOKB     : integer := 2*HEAD_DIM*N_QH + 2*HEAD_DIM*N_KVH
                               + 1 + NY + N_KVH*RECH;
  constant OFF_TOK0 : integer := OFF_KNW + NLAY*HEAD_DIM;
  constant NVEC     : integer := OFF_TOK0 + NSTEP*TOKB;

  -- The per-layer norm weight blocks.
  function o_qnw (lay : integer) return integer is
  begin return OFF_QNW + lay*HEAD_DIM; end function;
  function o_knw (lay : integer) return integer is
  begin return OFF_KNW + lay*HEAD_DIM; end function;

  function o_tok (t : integer) return integer is
  begin return OFF_TOK0 + t*TOKB; end function;
  function o_qg  (t : integer) return integer is
  begin return o_tok(t); end function;
  function o_kin (t : integer) return integer is
  begin return o_tok(t) + 2*HEAD_DIM*N_QH; end function;
  function o_vin (t : integer) return integer is
  begin return o_kin(t) + HEAD_DIM*N_KVH; end function;
  function o_yex (t : integer) return integer is
  begin return o_vin(t) + HEAD_DIM*N_KVH; end function;
  function o_ym  (t : integer) return integer is
  begin return o_yex(t) + 1; end function;
  function o_rec (t : integer) return integer is
  begin return o_ym(t) + NY; end function;
  function o_ke  (t, h : integer) return integer is
  begin return o_rec(t) + h*RECH; end function;
  function o_km  (t, h : integer) return integer is
  begin return o_ke(t, h) + NBLK; end function;
  function o_ve  (t, h : integer) return integer is
  begin return o_km(t, h) + HEAD_DIM; end function;
  function o_vm  (t, h : integer) return integer is
  begin return o_ve(t, h) + NBLK; end function;

  impure function load_vec(fn : string; n : integer) return int_arr is
    file     fh : text;
    variable st : file_open_status;
    variable ln : line;
    variable v  : int_arr(0 to n-1) := (others => 0);
    variable iv : integer;
    variable ok : boolean;
    variable i  : integer := 0;
  begin
    file_open(st, fh, fn, read_mode);
    assert st = open_ok
      report "tb_attn_kv_seam: cannot open " & fn
           & " -- ref/attn_block_seq_vec.c did not run" severity failure;
    while i < n loop
      assert not endfile(fh)
        report "tb_attn_kv_seam: the oracle vector file is short; expected "
             & integer'image(n) & " integers, got " & integer'image(i)
        severity failure;
      readline(fh, ln);
      loop
        read(ln, iv, ok);
        exit when not ok;
        v(i) := iv;
        i := i + 1;
        exit when i = n;
      end loop;
    end loop;
    file_close(fh);
    return v;
  end function;

  constant VEC : int_arr(0 to NVEC-1)
               := load_vec("attn_block_seq_vec.txt", NVEC);

  -- C spec 2.2, generalised over REC_B.  The one equation both masters and
  -- this bench must agree on; it is written here ONCE and every use goes
  -- through it, because two spellings of it would be two chances to be wrong
  -- in the same direction.
  function rec_a(base, lay, hd, ps : integer) return integer is
  begin
    return base + ((lay*N_KVH + hd)*MAXCTX + ps)*REC_B;
  end function;

  -- ======================= the modelled HBM =============================
  -- A protected type: the two read slaves, the write slave and the checker
  -- are four processes over ONE address space, and a plain shared variable is
  -- illegal in VHDL-2008.
  type mem_t is protected
    procedure wrb(i : natural; v : std_logic_vector(7 downto 0));
    impure function rdb(i : natural) return std_logic_vector;
  end protected;
  type mem_t is protected body
    type ba_t is array (0 to NB-1) of std_logic_vector(7 downto 0);
    variable a : ba_t := (others => (others => '0'));
    procedure wrb(i : natural; v : std_logic_vector(7 downto 0)) is
    begin a(i) := v; end procedure;
    impure function rdb(i : natural) return std_logic_vector is
    begin return a(i); end function;
  end protected body;
  shared variable mem : mem_t;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal running : boolean := true;
  signal all_done : boolean := false;

  signal blk_start : std_logic := '0';
  signal cur_pos   : unsigned(POS_W-1 downto 0) := (others => '0');
  signal ctx_len   : unsigned(POS_W-1 downto 0) := to_unsigned(NTOK, POS_W);
  signal busy      : std_logic;
  signal cfg_taken : std_logic;
  signal kv_seq_rst : std_logic := '0';
  signal seq_rst_taken : std_logic;
  -- The schedule, held for the whole of a job.  `tok_i` is the STEP index
  -- (the vector-file row); `pos_i` and `lay_i` are the token position and
  -- the layer that step runs.  They were one number while NLAY was 1, and
  -- keeping them one number is exactly how a bench stops being able to see
  -- a layer defect.
  signal tok_i : integer range 0 to NSTEP := 0;
  signal pos_i : integer range 0 to NTOK  := 0;
  signal lay_i : integer range 0 to NLAY-1 := 0;
  -- What each DUT is actually told, after the two layer mutation hooks.
  signal lay_blk : integer range 0 to LAYERS-1 := 0;
  signal lay_kv  : integer range 0 to LAYERS-1 := 0;
  signal q8_bad  : integer := 0;

  signal qg_raddr : unsigned(clog2(2*HEAD_DIM*N_QH)-1 downto 0);
  signal qg_re    : std_logic;
  signal qg_rdata : signed(MANT_W-1 downto 0) := (others => '0');
  signal kin_raddr : unsigned(clog2(HEAD_DIM*N_KVH)-1 downto 0);
  signal kin_re    : std_logic;
  signal kin_rdata : signed(MANT_W-1 downto 0) := (others => '0');
  signal vin_raddr : unsigned(clog2(HEAD_DIM*N_KVH)-1 downto 0);
  signal vin_re    : std_logic;
  signal vin_rdata : signed(MANT_W-1 downto 0) := (others => '0');
  signal qg_exp  : signed(EXP_W-1 downto 0) := to_signed(VEC(OFF_EXPS+0), EXP_W);
  signal kin_exp : signed(EXP_W-1 downto 0) := to_signed(VEC(OFF_EXPS+1), EXP_W);
  signal vin_exp : signed(EXP_W-1 downto 0) := to_signed(VEC(OFF_EXPS+2), EXP_W);
  signal qn_exp  : signed(EXP_W-1 downto 0) := to_signed(VEC(OFF_EXPS+3), EXP_W);
  signal kn_exp  : signed(EXP_W-1 downto 0) := to_signed(VEC(OFF_EXPS+4), EXP_W);
  signal qn_mant : std_logic_vector(HEAD_DIM*MANT_W-1 downto 0);
  signal kn_mant : std_logic_vector(HEAD_DIM*MANT_W-1 downto 0);
  signal wn_taken : std_logic;

  signal kv_layer : unsigned(clog2(LAYERS)-1 downto 0);
  signal kw_sel   : std_logic;
  signal kw_head  : unsigned(clog2(N_KVH)-1 downto 0);
  signal kw_pos   : unsigned(POS_W-1 downto 0);
  signal kw_hen   : std_logic;
  signal kw_hdr   : std_logic_vector(NBLK*EXP_W-1 downto 0);
  signal kw_en    : std_logic;
  signal kw_blk   : unsigned(clog2(NBLK)-1 downto 0);
  signal kw_mant  : std_logic_vector(KV_BLOCK*CM_W-1 downto 0);
  signal kw_rdy   : std_logic;
  signal kr_en    : std_logic;
  signal kr_head  : unsigned(clog2(N_KVH)-1 downto 0);
  signal kr_pos   : unsigned(POS_W-1 downto 0);
  signal kr_rdy   : std_logic;
  signal kr_blk   : unsigned(clog2(NBLK)-1 downto 0);
  signal kr_hdr   : std_logic_vector(NBLK*EXP_W-1 downto 0);
  signal kr_mant  : std_logic_vector(KV_BLOCK*CM_W-1 downto 0);
  signal vr_en    : std_logic;
  signal vr_head  : unsigned(clog2(N_KVH)-1 downto 0);
  signal vr_pos   : unsigned(POS_W-1 downto 0);
  signal vr_rdy   : std_logic;
  signal vr_blk   : unsigned(clog2(NBLK)-1 downto 0);
  signal vr_hdr   : std_logic_vector(NBLK*EXP_W-1 downto 0);
  signal vr_mant  : std_logic_vector(KV_BLOCK*CM_W-1 downto 0);
  -- what the block sees, and what the cache sees, after the mutation hooks
  signal kr_rdy_b, vr_rdy_b, kw_rdy_b, wr_idle_b : std_logic;
  signal kr_pos_c, vr_pos_c : unsigned(POS_W-1 downto 0);
  signal kv_cpos, kv_clen : unsigned(POS_W-1 downto 0);
  signal kr_blk_c, vr_blk_c : unsigned(clog2(NBLK)-1 downto 0);
  -- the watchdog
  signal wd_cnt, wd_max : integer := 0;

  signal y_valid : std_logic;
  signal y_mant  : signed(MANT_W-1 downto 0);
  signal y_index : unsigned(clog2(NY)-1 downto 0);
  signal y_last  : std_logic;
  signal y_exp   : signed(EXP_W-1 downto 0);
  signal y_ready : std_logic := '1';
  signal y_hdr_valid : std_logic;
  signal blk_done : std_logic;
  signal done_ack : std_logic := '1';
  signal blk_err, rope_sat, kv_sat, y_sat, z_sat, dbg_ep_lost : std_logic;
  signal rescale_max : unsigned(15 downto 0);

  -- attn_kv_axi
  signal kv_start   : std_logic := '0';
  signal kv_cfgt    : std_logic;
  signal kv_busy    : std_logic;
  signal kv_wr_idle : std_logic;
  signal kv_err     : std_logic;
  signal r_arvalid, r_arready, r_rvalid, r_rready, r_rlast : std_logic_vector(1 downto 0);
  signal r_araddr  : std_logic_vector(2*ADDR_W-1 downto 0);
  signal r_arlen   : std_logic_vector(15 downto 0);
  signal r_arsize  : std_logic_vector(5 downto 0);
  signal r_arburst : std_logic_vector(3 downto 0);
  signal r_rdata   : std_logic_vector(2*AXI_DW-1 downto 0) := (others => '0');
  signal r_rresp   : std_logic_vector(3 downto 0) := (others => '0');
  signal w_awvalid, w_awready, w_wvalid, w_wready, w_wlast : std_logic;
  signal w_bvalid, w_bready : std_logic;
  signal w_awaddr  : std_logic_vector(ADDR_W-1 downto 0);
  signal w_awlen   : std_logic_vector(7 downto 0);
  signal w_awsize  : std_logic_vector(2 downto 0);
  signal w_awburst : std_logic_vector(1 downto 0);
  signal w_wdata   : std_logic_vector(AXI_DW-1 downto 0);
  signal w_wstrb   : std_logic_vector(AXI_DW/8-1 downto 0);
  signal w_bresp   : std_logic_vector(1 downto 0) := "00";

  -- collectors
  signal y_got  : int_arr(0 to NSTEP*NY-1) := (others => 0);
  signal yi_got : int_arr(0 to NSTEP*NY-1) := (others => 0);
  signal ye_got : int_arr(0 to NSTEP-1) := (others => 0);
  signal yn_got : int_arr(0 to NSTEP-1) := (others => 0);
  signal y_idx  : integer := 0;
  signal q4_bad, q3_bad, q6_bad, q5_bad : integer := 0;
  -- One counter per SLAVE PROCESS.  Two processes on one integer signal
  -- elaborates as "several sources for unresolved signal" with no line
  -- number, and indexing one array signal from a loop whose index is not
  -- static creates a driver for the WHOLE array, which collides just as
  -- hard.  Two plain integers is the form that cannot do either.
  signal slv_bad_r : integer := 0;   -- the two read slaves
  signal slv_bad_w : integer := 0;   -- the write slave
  -- Coverage carries the LAYER as its outermost index.  Without it a read
  -- that went to the wrong layer's region would still land in the right
  -- (head, pos, block) bucket and the counts would balance.
  signal cov    : int_arr(0 to 2*NLAY*N_KVH*MAXCTX*NBLK-1) := (others => 0);

  signal rnd_r : unsigned(31 downto 0) := x"1234ABCD";

  -- Q3's one-cycle pipeline: what was asked for, to be compared with what
  -- arrives on the next cycle.
  -- `q3_kl` / `q3_vl` carry the LAYER the request was made under, because
  -- the vector row that holds the expected record is s_of(layer, pos) and
  -- the position alone no longer identifies it.
  signal q3_kv : std_logic := '0';
  signal q3_kh, q3_kp, q3_kb, q3_kl : integer := 0;
  signal q3_vv : std_logic := '0';
  signal q3_vh, q3_vp, q3_vb, q3_vl : integer := 0;

  -- MUT_DROP_RDY's counter
  signal mut_beat : integer := 0;

begin

  clk <= not clk after 5 ns when running else '0';

  -- The two layer ports, after the mutation hooks.  In the shipping bench
  -- both are `lay_i` and `rtl/llama_top.vhd` drives them from one signal for
  -- the same reason.
  lay_blk <= 0 when MUT_BLK_LAY0 else lay_i;
  lay_kv  <= 0 when MUT_KV_LAY0  else lay_i;

  -- ======================= the DUTs =====================================
  u_blk : entity work.attn_block
    generic map ( HEAD_DIM => HEAD_DIM, N_QH => N_QH, N_KVH => N_KVH,
                  KV_BLOCK => KV_BLOCK, N_ROT => N_ROT, LAYERS => LAYERS,
                  POS_W => POS_W, MANT_W => MANT_W, CM_W => CM_W,
                  EXP_W => EXP_W, NORM_LANES => 1,
                  STRICT_PRODUCER => true )
    port map ( clk => clk, rst => rst,
               start => blk_start, layer => lay_blk,
               cur_pos => cur_pos, ctx_len => ctx_len, busy => busy,
               cfg_taken => cfg_taken,
               kv_seq_rst => kv_seq_rst, seq_rst_taken => seq_rst_taken,
               qg_raddr => qg_raddr, qg_re => qg_re, qg_rdata => qg_rdata,
               qg_exp => qg_exp,
               kin_raddr => kin_raddr, kin_re => kin_re,
               kin_rdata => kin_rdata, kin_exp => kin_exp,
               vin_raddr => vin_raddr, vin_re => vin_re,
               vin_rdata => vin_rdata, vin_exp => vin_exp,
               qn_mant => qn_mant, qn_exp => qn_exp,
               kn_mant => kn_mant, kn_exp => kn_exp, wn_taken => wn_taken,
               kv_layer => kv_layer,
               kw_sel => kw_sel, kw_head => kw_head, kw_pos => kw_pos,
               kw_hen => kw_hen, kw_hdr => kw_hdr, kw_en => kw_en,
               kw_blk => kw_blk, kw_mant => kw_mant, kw_rdy => kw_rdy_b,
               kr_en => kr_en, kr_head => kr_head, kr_pos => kr_pos,
               kr_rdy => kr_rdy_b,
               kr_blk => kr_blk, kr_hdr => kr_hdr, kr_mant => kr_mant,
               vr_en => vr_en, vr_head => vr_head, vr_pos => vr_pos,
               vr_rdy => vr_rdy_b,
               vr_blk => vr_blk, vr_hdr => vr_hdr, vr_mant => vr_mant,
               kv_wr_idle => wr_idle_b,
               y_valid => y_valid, y_mant => y_mant, y_index => y_index,
               y_last => y_last, y_exp => y_exp, y_ready => y_ready,
               y_hdr_valid => y_hdr_valid,
               done => blk_done, done_ack => done_ack,
               err => blk_err, rope_sat => rope_sat, kv_sat => kv_sat,
               y_sat => y_sat, z_sat => z_sat,
               rescale_max => rescale_max, dbg_ep_lost => dbg_ep_lost );

  u_kv : entity work.attn_kv_axi
    generic map ( HEAD_DIM => HEAD_DIM, KV_BLOCK => KV_BLOCK, N_KVH => N_KVH,
                  LAYERS => LAYERS, MAXCTX => MAXCTX, POS_W => POS_W,
                  CM_W => CM_W, EXP_W => EXP_W, AXI_DW => AXI_DW,
                  ADDR_W => ADDR_W, MAXB => MAXB, MAXOUT => MAXOUT,
                  RBUF => RBUF )
    port map ( clk => clk, rst => rst,
               start => kv_start, layer => lay_kv,
               cur_pos => kv_cpos, ctx_len => kv_clen,
               k_base => std_logic_vector(to_unsigned(K_BASE, ADDR_W)),
               v_base => std_logic_vector(to_unsigned(V_BASE, ADDR_W)),
               cfg_taken => kv_cfgt, busy => kv_busy, wr_idle => kv_wr_idle,
               err => kv_err,
               kw_sel => kw_sel, kw_head => kw_head, kw_pos => kw_pos,
               kw_hen => kw_hen, kw_hdr => kw_hdr, kw_en => kw_en,
               kw_blk => kw_blk, kw_mant => kw_mant, kw_rdy => kw_rdy,
               kr_head => kr_head, kr_pos => kr_pos_c, kr_rdy => kr_rdy,
               kr_en => kr_en, kr_blk => kr_blk_c, kr_hdr => kr_hdr,
               kr_mant => kr_mant,
               vr_head => vr_head, vr_pos => vr_pos_c, vr_rdy => vr_rdy,
               vr_en => vr_en, vr_blk => vr_blk_c, vr_hdr => vr_hdr,
               vr_mant => vr_mant,
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
               w_bresp => w_bresp );

  -- ======================= the mutation hooks ===========================
  -- MUT_EARLY_BEAT forces the block's view of kr_rdy high: exactly the
  -- pre-seam behaviour, and the reason the seam exists.
  -- MUT_DROP_RDY pulls it low in the middle of a record instead of holding
  -- it, which is the sink withdrawing a residency answer the consumer is
  -- still acting on.
  -- MUT_DROP_RDY withdraws the residency answer on ROUGHLY A QUARTER of all
  -- cycles, not once: a single-cycle withdrawal is a legal stall that any
  -- gated consumer absorbs, so it would have measured nothing.  See the
  -- survivor analysis in docs/debugging/2026-08-28_attn-block-kv-seam.md.
  kr_rdy_b <= '1' when MUT_EARLY_BEAT else
              '0' when MUT_DROP_RDY and rnd_r(5 downto 4) = "00" else kr_rdy;
  vr_rdy_b <= vr_rdy;
  kw_rdy_b <= kw_rdy;
  wr_idle_b <= '1' when MUT_NO_WRIDLE else kv_wr_idle;

  -- MUT_REORDER asks the cache for the record ONE POSITION ON, and only when
  -- that position is also readable, so the mutation is a wrong ANSWER and not
  -- a refusal: a mutation that hangs has tested the watchdog, not the check.
  -- MUT_BLK_SWAP does the same one block on inside the record, which is the
  -- "beats must be returned in issue order" contract from the other side.
  kv_cpos <= cur_pos + 1 when MUT_CACHE_CPOS_HI else cur_pos;
  kv_clen <= ctx_len + 1 when MUT_CACHE_CPOS_HI else ctx_len;

  kr_pos_c <= kr_pos + 1 when MUT_REORDER and (kr_pos + 1) < cur_pos
              else kr_pos;
  vr_pos_c <= vr_pos + 1 when MUT_REORDER and (vr_pos + 1) < cur_pos
              else vr_pos;
  kr_blk_c <= (kr_blk xor to_unsigned(1, clog2(NBLK))) when MUT_BLK_SWAP
              else kr_blk;
  vr_blk_c <= (vr_blk xor to_unsigned(1, clog2(NBLK))) when MUT_BLK_SWAP
              else vr_blk;

  -- THE WATCHDOG.  A seam that stalls is a HANG, and a hang scored by the
  -- stop time is indistinguishable from a slow run.  Any of the block's own
  -- observable events rearms it; WDOG is measured rather than guessed, and
  -- the longest quiet stretch actually seen is printed in the PASS line so
  -- the margin is a number rather than a hope.
  wdog_p : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' or busy = '0' then
        wd_cnt <= 0;
      elsif y_valid = '1' or kr_en = '1' or vr_en = '1' or kw_en = '1'
            or kw_hen = '1' or cfg_taken = '1' then
        wd_cnt <= 0;
      else
        wd_cnt <= wd_cnt + 1;
        if wd_cnt > wd_max then wd_max <= wd_cnt; end if;
        assert wd_cnt < WDOG
          report "tb_attn_kv_seam: " & integer'image(WDOG) & " cycles with "
               & "the block busy and no cache traffic, no output and no "
               & "descriptor latch.  The seam is stalled: the most likely "
               & "cause is a residency answer that never arrives, which is "
               & "what a refused read looks like from this side."
          severity failure;
      end if;
    end if;
  end process;

  mutcnt : process(clk)
  begin
    if rising_edge(clk) then
      if kr_en = '1' then mut_beat <= mut_beat + 1;
      elsif kr_rdy = '0' then mut_beat <= 0; end if;
    end if;
  end process;

  -- ======================= the norm weights =============================
  -- PER LAYER, and they follow `lay_i`, which the driver sets before it
  -- raises `blk_start`.  `attn_block` LATCHES them at start (SEAM 1), so a
  -- design that read them combinationally, or latched the previous job's,
  -- now computes different numbers.  Under MUT_BLK_LAY0 the block is told
  -- layer 0, so it must be given layer 0's weights too -- otherwise the
  -- mutant would be killed by a weight mismatch the mutation did not name.
  wgen : process(all)
    variable wl : integer;
  begin
    if MUT_BLK_LAY0 then wl := 0;
    elsif MUT_WN_SWAP then wl := (lay_i + 1) mod NLAY;
    else wl := lay_i; end if;
    for i in 0 to HEAD_DIM-1 loop
      qn_mant((i+1)*MANT_W-1 downto i*MANT_W)
        <= std_logic_vector(to_signed(VEC(o_qnw(wl) + i), MANT_W));
      kn_mant((i+1)*MANT_W-1 downto i*MANT_W)
        <= std_logic_vector(to_signed(VEC(o_knw(wl) + i), MANT_W));
    end loop;
  end process;

  -- ======================= A's activation memories ======================
  -- Registered read WITH ENABLE, held across an edge at which the enable was
  -- low: the contract every master in attn_block states.  The token index is
  -- a signal, so token t's job reads token t's activations and nothing else.
  amem : process(clk)
  begin
    if rising_edge(clk) then
      if qg_re = '1' then
        qg_rdata <= to_signed(VEC(o_qg(tok_i) + to_integer(qg_raddr)), MANT_W);
      end if;
      if kin_re = '1' then
        kin_rdata <= to_signed(VEC(o_kin(tok_i) + to_integer(kin_raddr)), MANT_W);
      end if;
      if vin_re = '1' then
        vin_rdata <= to_signed(VEC(o_vin(tok_i) + to_integer(vin_raddr)), MANT_W);
      end if;
    end if;
  end process;

  -- ======================= the AXI read slaves ==========================
  -- One in-order server per master with a MAXOUT-deep AR queue and a fixed
  -- RD_LAT from acceptance to the first beat.  RD_LAT defaults to 40 cycles,
  -- which is not HBM's real latency but is far more than the two cycles the
  -- pre-seam attn_block allowed, and that is the only thing that has to be
  -- true for this bench to be the check it claims to be.
  -- ONE PROCESS FOR BOTH READ SLAVES, and the reason is a GHDL trap worth
  -- writing down: two processes driving DISJOINT SLICES of one unresolved
  -- std_logic_vector do NOT elaborate as an error the way two processes on a
  -- scalar do ("several sources for unresolved signal").  GHDL mcode accepts
  -- it and then delivers 'U' on one half and '0' on the other, silently.
  -- MEASURED on a nine-line reduction; it cost an hour here first, presenting
  -- as "the cache returns zeros for a record that is demonstrably in memory".
  rslv : process(clk)
    type na_t is array (0 to 15) of integer;
    type ia_t is array (0 to 1) of integer;
    type ba_t is array (0 to 1) of boolean;
    variable qa, ql : na_t := (others => 0);
    variable qh, qt, qn, tmr, beat : ia_t := (others => 0);
    variable act : ba_t := (others => false);
    variable a, l : integer;
    variable lfsr : unsigned(15 downto 0) := x"ACE1";
  begin
    if rising_edge(clk) then
      lfsr := lfsr(14 downto 0) & (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));
      if rst = '1' then
        qh := (others => 0); qt := (others => 0); qn := (others => 0);
        tmr := (others => 0); beat := (others => 0);
        act := (others => false);
        r_arready <= "11"; r_rvalid <= "00"; r_rlast <= "00";
      else
        r_rvalid <= "00"; r_rlast <= "00";
        for s in 0 to 1 loop

          -- ---- AR ----------------------------------------------------
          if r_arvalid(s) = '1' and r_arready(s) = '1' then
            a := to_integer(unsigned(r_araddr((s+1)*ADDR_W-1 downto s*ADDR_W)));
            l := to_integer(unsigned(r_arlen((s+1)*8-1 downto s*8))) + 1;
            -- S1/S2/S3, the three protocol facts this bench depends on.  The
            -- FK33 HBM slave is AXI3: ARLEN is 4 bits, so a 17-beat burst does
            -- not fail, it silently becomes a 1-beat burst, and a slave that
            -- did not check would report a wrong ANSWER rather than a protocol
            -- error.  That defect has escaped once already in this project.
            if l > MAXB then
              slv_bad_r <= slv_bad_r + 1;
              report "tb_attn_kv_seam: read burst of " & integer'image(l)
                   & " beats exceeds the AXI3 cap of " & integer'image(MAXB)
                severity error;
            end if;
            if (a mod 4096) + l*BEAT_B > 4096 then
              slv_bad_r <= slv_bad_r + 1;
              report "tb_attn_kv_seam: read burst at " & integer'image(a)
                   & " for " & integer'image(l) & " beats crosses 4 KB"
                severity error;
            end if;
            if a mod BEAT_B /= 0 then
              slv_bad_r <= slv_bad_r + 1;
              report "tb_attn_kv_seam: read address " & integer'image(a)
                   & " is not beat aligned" severity error;
            end if;
            if a + l*BEAT_B > NB then
              slv_bad_r <= slv_bad_r + 1;
              report "tb_attn_kv_seam: read burst at " & integer'image(a)
                   & " runs past the modelled memory" severity error;
            else
              qa(s*8 + qt(s)) := a; ql(s*8 + qt(s)) := l;
              qt(s) := (qt(s) + 1) mod 8; qn(s) := qn(s) + 1;
              if qn(s) = 1 then tmr(s) := RD_LAT; end if;
            end if;
          end if;
          if qn(s) < MAXOUT then r_arready(s) <= '1';
          else r_arready(s) <= '0'; end if;

          -- ---- the in-order server -----------------------------------
          if not act(s) and qn(s) > 0 then
            if tmr(s) > 0 then tmr(s) := tmr(s) - 1;
            else act(s) := true; beat(s) := 0; end if;
          end if;
          if act(s) then
            if STALL /= 0
               and (to_integer(lfsr(7 downto 0)) + s) mod STALL = 0 then
              null;                      -- a gap, RVALID stays low
            else
              for c in 0 to BEAT_B-1 loop
                r_rdata(s*AXI_DW + (c+1)*8-1 downto s*AXI_DW + c*8)
                  <= mem.rdb(qa(s*8 + qh(s)) + beat(s)*BEAT_B + c);
              end loop;
              r_rvalid(s) <= '1';
              if beat(s) = ql(s*8 + qh(s))-1 then r_rlast(s) <= '1'; end if;
              beat(s) := beat(s) + 1;
              if beat(s) = ql(s*8 + qh(s)) then
                act(s) := false;
                qh(s) := (qh(s) + 1) mod 8; qn(s) := qn(s) - 1;
                tmr(s) := RD_LAT;
              end if;
            end if;
          end if;
        end loop;
      end if;
    end if;
  end process;

  -- ======================= the AXI write slave ==========================
  -- THE WRITE SLAVE, AND THE ONE MODELLING DECISION THAT MATTERS.
  --
  -- Beats are NOT committed to memory when they are accepted on W.  They are
  -- held and committed at the instant BVALID is returned.  That is what AXI
  -- actually promises -- a write is not ordered against anything until its
  -- BRESP -- and it is the whole reason C spec 2.7 says `done` must wait for
  -- it.  A slave that committed at W time would make the write visible to the
  -- read masters early, and then removing the `kv_wr_idle` gate would be
  -- invisible: MEASURED, that is exactly what happened here on the first
  -- version of this bench, where the gate's mutation SURVIVED.
  wslv : process(clk)
    type na_t is array (0 to 7) of integer;
    type pa_t is array (0 to 127) of integer;
    type pd_t is array (0 to 127) of std_logic_vector(AXI_DW-1 downto 0);
    type ps_t is array (0 to 127) of std_logic_vector(AXI_DW/8-1 downto 0);
    variable a, l, beat : integer := 0;
    variable inw : boolean := false;
    variable btm, bct : na_t := (others => 0);
    variable bn  : integer := 0;
    variable awt : integer := 0;
    variable lfsr : unsigned(15 downto 0) := x"BEEF";
    -- the uncommitted write ring
    variable p_a : pa_t := (others => 0);
    variable p_d : pd_t := (others => (others => '0'));
    variable p_s : ps_t := (others => (others => '0'));
    variable p_h, p_t, p_n : integer := 0;
    -- NOT `nb`: VHDL is case-insensitive and the architecture constant NB
    -- is the size of the modelled memory.  A process variable spelled `nb`
    -- shadows it and the range check silently compares against 0.
    variable wbeats : integer := 0;  -- beats of the burst being accepted
  begin
    if rising_edge(clk) then
      lfsr := lfsr(14 downto 0) & (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));
      if rst = '1' then
        inw := false; beat := 0; bn := 0; wbeats := 0; awt := 0;
        p_h := 0; p_t := 0; p_n := 0;
        w_awready <= '1'; w_wready <= '0'; w_bvalid <= '0';
      else
        w_bvalid <= '0';
        -- ---- AW ------------------------------------------------------
        if AW_LAT /= 0 and not inw then
          if awt < AW_LAT then
            awt := awt + 1; w_awready <= '0';
          else
            w_awready <= '1';
          end if;
        end if;
        if w_awvalid = '1' and w_awready = '1' then
          a := to_integer(unsigned(w_awaddr));
          l := to_integer(unsigned(w_awlen)) + 1;
          if l > MAXB then
            slv_bad_w <= slv_bad_w + 1;
            report "tb_attn_kv_seam: write burst of " & integer'image(l)
                 & " beats exceeds the AXI3 cap" severity error;
          end if;
          if (a mod 4096) + l*BEAT_B > 4096 then
            slv_bad_w <= slv_bad_w + 1;
            report "tb_attn_kv_seam: write burst at " & integer'image(a)
                 & " crosses 4 KB" severity error;
          end if;
          if a mod BEAT_B /= 0 or a + l*BEAT_B > NB then
            slv_bad_w <= slv_bad_w + 1;
            report "tb_attn_kv_seam: write address " & integer'image(a)
                 & " is misaligned or out of range" severity error;
          end if;
          inw := true; beat := 0; wbeats := 0; awt := 0;
          w_awready <= '0'; w_wready <= '1';
        end if;
        -- ---- W -------------------------------------------------------
        if inw then
          if STALL /= 0 and to_integer(lfsr(7 downto 0)) mod STALL = 0 then
            w_wready <= '0';
          else
            w_wready <= '1';
          end if;
          if w_wvalid = '1' and w_wready = '1' then
            -- HELD, not committed.  See the note on this process.
            p_a(p_t) := a + beat*BEAT_B;
            p_d(p_t) := w_wdata;
            p_s(p_t) := w_wstrb;
            p_t := (p_t + 1) mod 128; p_n := p_n + 1;
            wbeats := wbeats + 1;
            assert p_n <= 128
              report "tb_attn_kv_seam: the uncommitted-write ring overflowed; "
                   & "raise its depth or lower WR_LAT" severity failure;
            beat := beat + 1;
            if w_wlast = '1' then
              inw := false; w_wready <= '0';
              if AW_LAT = 0 then w_awready <= '1'; end if;
              assert bn < 8
                report "tb_attn_kv_seam: more than 8 write bursts outstanding "
                     & "in the slave model.  Dropping one would starve the "
                     & "DUT's B counter and present as a watchdog hang "
                     & "attributed to the wrong thing." severity failure;
              btm(bn) := WR_LAT; bct(bn) := wbeats; bn := bn + 1;
            end if;
          end if;
        end if;
        -- ---- B, and the COMMIT that goes with it ----------------------
        if bn > 0 then
          if btm(0) > 0 then
            btm(0) := btm(0) - 1;
          else
            w_bvalid <= '1';
            for k in 0 to MAXB-1 loop
              if k < bct(0) then
                for c in 0 to BEAT_B-1 loop
                  if p_s(p_h)(c) = '1' then
                    mem.wrb(p_a(p_h) + c, p_d(p_h)((c+1)*8-1 downto c*8));
                  end if;
                end loop;
                p_h := (p_h + 1) mod 128; p_n := p_n - 1;
              end if;
            end loop;
            for i in 0 to 6 loop btm(i) := btm(i+1); bct(i) := bct(i+1); end loop;
            bn := bn - 1;
          end if;
        end if;
      end if;
    end if;
  end process;

  -- ======================= the consumer =================================
  -- Alternating: token 0 never stalls, token 1 stalls pseudo-randomly, and so
  -- on.  A never-stalling consumer is NOT the weak case -- it reaches states a
  -- gapped one skips -- so both are run and the values must not move.
  -- A FULL xorshift32, not the one-term form.  `x := x xor (x sll 13)` alone
  -- LEAVES THE LOW 13 BITS UNCHANGED FOR EVER, so anything selecting a low
  -- nibble out of it is a constant wearing the word "pseudo-random".  Found
  -- here 2026-08-28 because MUT_DROP_RDY, which selects bits 5..4, held its
  -- initial value and turned a stall mutation into a permanent one.
  yrdy : process(clk)
    variable v : unsigned(31 downto 0);
  begin
    if rising_edge(clk) then
      v := rnd_r;
      v := v xor shift_left(v, 13);
      v := v xor shift_right(v, 17);
      v := v xor shift_left(v, 5);
      rnd_r <= v;
      -- POSITION, not step.  With `tok_i` here and NLAY = 2 the parity is the
      -- LAYER, so layer 0 would get the never-stall consumer for the whole run
      -- and layer 1 the stalling one, and neither layer would ever see the
      -- other configuration.  `pos_i` keeps the per-token alternation this
      -- always had and gives BOTH layers both consumers across the sequence.
      if pos_i mod 2 = 0 then
        y_ready <= '1';
      elsif rnd_r(3 downto 0) < 6 then
        y_ready <= '0';
      else
        y_ready <= '1';
      end if;
      done_ack <= '1';
    end if;
  end process;

  -- ======================= collectors and the seam checks ===============
  collect : process(clk)
    variable exp_m : integer;
    variable ci    : integer;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        y_idx <= 0;
      else
        -- ---- Q1's collector ----------------------------------------
        if y_valid = '1' and y_ready = '1' then
          assert y_idx < NSTEP*NY
            report "tb_attn_kv_seam: more output than the sequence expects"
            severity failure;
          y_got(y_idx)  <= to_integer(y_mant);
          yi_got(y_idx) <= to_integer(y_index);
          y_idx <= y_idx + 1;
          yn_got(tok_i) <= yn_got(tok_i) + 1;
          ye_got(tok_i) <= to_integer(y_exp);
        end if;

        -- ---- Q8: `kv_layer` tracks the configured layer (L4) ---------
        -- `rtl/llama_top.vhd` carries this assert because the block's own
        -- layer latch putting a whole layer's records at another layer's
        -- addresses would still be SERVED by every read, so nothing
        -- downstream complains.  Checked only while a record write is
        -- actually offered, which is when the value is used.
        if (kw_en = '1' or kw_hen = '1')
           and to_integer(kv_layer) /= lay_blk then
          q8_bad <= q8_bad + 1;
          report "tb_attn_kv_seam: Q8 -- attn_block is writing layer "
               & integer'image(to_integer(kv_layer))
               & " and it was configured for layer "
               & integer'image(lay_blk)
               & ".  A whole layer's records would land at another layer's "
               & "addresses and every read would still be served."
            severity error;
        end if;

        -- ---- Q4: the handshake -------------------------------------
        if kr_en = '1' and kr_rdy = '0' then
          q4_bad <= q4_bad + 1;
          report "tb_attn_kv_seam: kr_en was raised while kr_rdy was low.  "
               & "The record is not resident and the beat that arrives is "
               & "whatever the buffer last held -- a SILENT wrong answer, "
               & "which is what the pre-seam block did on every read."
            severity error;
        end if;
        if vr_en = '1' and vr_rdy = '0' then
          q4_bad <= q4_bad + 1;
          report "tb_attn_kv_seam: vr_en was raised while vr_rdy was low"
            severity error;
        end if;
        if (kw_en = '1' or kw_hen = '1') and kw_rdy = '0' then
          q4_bad <= q4_bad + 1;
          report "tb_attn_kv_seam: a record write beat was offered while "
               & "kw_rdy was low.  attn_kv_axi drops it silently and the "
               & "whole record vanishes." severity error;
        end if;

        -- ---- Q6: the bypass, and the coverage ----------------------
        if kr_en = '1' then
          if kr_pos >= cur_pos then
            q6_bad <= q6_bad + 1;
            report "tb_attn_kv_seam: the sweep read pos "
                 & integer'image(to_integer(kr_pos)) & " with cur_pos "
                 & integer'image(to_integer(cur_pos))
                 & ".  C spec 2.4: that record is written through the write "
                 & "master in this same job and AXI orders nothing between "
                 & "masters." severity error;
          else
            ci := ((lay_i*N_KVH + to_integer(kr_head))*MAXCTX
                   + to_integer(kr_pos))*NBLK + to_integer(kr_blk);
            cov(ci) <= cov(ci) + 1;
          end if;
        end if;
        if vr_en = '1' then
          if vr_pos >= cur_pos then
            q6_bad <= q6_bad + 1;
            report "tb_attn_kv_seam: the sweep read the current position's V "
                 & "record; see the K message" severity error;
          else
            ci := NLAY*N_KVH*MAXCTX*NBLK
                  + ((lay_i*N_KVH + to_integer(vr_head))*MAXCTX
                     + to_integer(vr_pos))*NBLK + to_integer(vr_blk);
            cov(ci) <= cov(ci) + 1;
          end if;
        end if;

        -- ---- Q3: the returned beat is the requested beat -------------
        q3_kv <= '0'; q3_vv <= '0';
        if kr_en = '1' and kr_pos < cur_pos then
          q3_kv <= '1';
          q3_kh <= to_integer(kr_head);
          q3_kp <= to_integer(kr_pos);
          q3_kb <= to_integer(kr_blk);
          q3_kl <= lay_i;
        end if;
        if vr_en = '1' and vr_pos < cur_pos then
          q3_vv <= '1';
          q3_vh <= to_integer(vr_head);
          q3_vp <= to_integer(vr_pos);
          q3_vb <= to_integer(vr_blk);
          q3_vl <= lay_i;
        end if;
        if q3_kv = '1' then
          for i in 0 to KV_BLOCK-1 loop
            exp_m := VEC(o_km(s_of(q3_kl, q3_kp), q3_kh)
                         + q3_kb*KV_BLOCK + i);
            if to_integer(signed(kr_mant((i+1)*CM_W-1 downto i*CM_W)))
               /= exp_m then
              q3_bad <= q3_bad + 1;
              report "tb_attn_kv_seam: K beat (head "
                   & integer'image(q3_kh) & ", pos " & integer'image(q3_kp)
                   & ", blk " & integer'image(q3_kb) & ") element "
                   & integer'image(i) & " = "
                   & integer'image(to_integer(signed(
                       kr_mant((i+1)*CM_W-1 downto i*CM_W))))
                   & ", the oracle's record for that position says "
                   & integer'image(exp_m) severity error;
              exit;
            end if;
          end loop;
          for b in 0 to NBLK-1 loop
            if to_integer(signed(kr_hdr((b+1)*EXP_W-1 downto b*EXP_W)))
               /= VEC(o_ke(s_of(q3_kl, q3_kp), q3_kh) + b) then
              q3_bad <= q3_bad + 1;
              report "tb_attn_kv_seam: the K header returned with pos "
                   & integer'image(q3_kp) & " is not that position's header"
                severity error;
              exit;
            end if;
          end loop;
        end if;
        if q3_vv = '1' then
          for i in 0 to KV_BLOCK-1 loop
            exp_m := VEC(o_vm(s_of(q3_vl, q3_vp), q3_vh)
                         + q3_vb*KV_BLOCK + i);
            if to_integer(signed(vr_mant((i+1)*CM_W-1 downto i*CM_W)))
               /= exp_m then
              q3_bad <= q3_bad + 1;
              report "tb_attn_kv_seam: V beat (head "
                   & integer'image(q3_vh) & ", pos " & integer'image(q3_vp)
                   & ", blk " & integer'image(q3_vb) & ") element "
                   & integer'image(i) & " disagrees with the oracle's record"
                severity error;
              exit;
            end if;
          end loop;
          for b in 0 to NBLK-1 loop
            if to_integer(signed(vr_hdr((b+1)*EXP_W-1 downto b*EXP_W)))
               /= VEC(o_ve(s_of(q3_vl, q3_vp), q3_vh) + b) then
              q3_bad <= q3_bad + 1;
              report "tb_attn_kv_seam: the V header returned with pos "
                   & integer'image(q3_vp) & " is not that position's header"
                severity error;
              exit;
            end if;
          end loop;
        end if;
      end if;
    end if;
  end process;

  hb : process
  begin
    if HEARTBEAT_US = 0 then wait; end if;
    loop
      wait for HEARTBEAT_US * 1 us;
      exit when all_done;
      report "tb_attn_kv_seam: alive, token " & integer'image(tok_i)
           & " y " & integer'image(y_idx) severity note;
    end loop;
    wait;
  end process;

  -- ======================= the driver ===================================
  drive : process
    variable nerr : integer := 0;
    variable q1_n, q1_cmp, q2_n : integer := 0;
    variable a : integer;
    variable ev : integer;
  begin
    assert VEC(0) = HEAD_DIM and VEC(1) = N_QH and VEC(2) = N_KVH
       and VEC(3) = KV_BLOCK and VEC(4) = N_ROT and VEC(5) = NTOK
       and VEC(7) = NLAY
      report "tb_attn_kv_seam: attn_block_seq_vec.txt shape "
           & integer'image(VEC(0)) & "/" & integer'image(VEC(1)) & "/"
           & integer'image(VEC(2)) & "/" & integer'image(VEC(3)) & "/"
           & integer'image(VEC(4)) & "/" & integer'image(VEC(5))
           & " NLAY " & integer'image(VEC(7))
           & " does not match this bench's generics" severity failure;
    assert NTOK <= MAXCTX
      report "tb_attn_kv_seam: NTOK must not exceed MAXCTX" severity failure;
    assert NLAY >= 2
      report "tb_attn_kv_seam: NLAY must be at least 2.  At one layer the "
           & "per-layer v_ref fold, the address equation's layer term, the "
           & "QK-norm latch and the kv_layer property are all unfalsifiable "
           & "-- which is the state this bench was in before 2026-08-29."
      severity failure;
    assert NLAY <= LAYERS
      report "tb_attn_kv_seam: NLAY exceeds LAYERS, so the schedule names a "
           & "layer neither DUT will accept" severity failure;
    assert rec_a(V_BASE, NLAY-1, N_KVH-1, MAXCTX-1) + REC_B <= NB
      report "tb_attn_kv_seam: the modelled memory is too small for this "
           & "geometry" severity failure;

    rst <= '1';
    for i in 1 to 8 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);

    -- The per-SEQUENCE v_ref reset.  ONCE, before token 0, and NOT between
    -- tokens: v_ref is a minimum folded over every record ever written for
    -- this sequence (C spec 2.1.4).  MUT_SEQRST_TOK moves it inside the loop,
    -- which is the mutation this bench exists to be able to see.
    kv_seq_rst <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    assert seq_rst_taken = '1'
      report "tb_attn_kv_seam: seq_rst_taken did not pulse" severity error;
    kv_seq_rst <= '0';
    wait until rising_edge(clk);

    -- THE SCHEDULE.  Token-major, layer-minor: every layer sees token t
    -- before any layer sees token t+1.  See the header.
    for t in 0 to NTOK-1 loop
     for l in 0 to NLAY-1 loop
      tok_i   <= s_of(l, t);
      pos_i   <= t;
      lay_i   <= l;
      cur_pos <= to_unsigned(t, POS_W);
      ctx_len <= to_unsigned(NTOK, POS_W);
      wait until rising_edge(clk);

      if MUT_SEQRST_TOK then
        kv_seq_rst <= '1';
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        kv_seq_rst <= '0';
        wait until rising_edge(clk);
      end if;

      blk_start <= '1';
      kv_start  <= '1';
      wait until rising_edge(clk);
      blk_start <= '0';
      kv_start  <= '0';
      wait until rising_edge(clk);
      loop
        wait until rising_edge(clk);
        exit when busy = '0';
      end loop;

      -- ---- Q5: C spec 2.7, checked at the instant it matters ---------
      -- `busy` has just fallen, so `done` was asserted and acked.  Token
      -- t+1 is entitled to read these records now; they must be in memory
      -- NOW, not merely on their way.
      for h in 0 to N_KVH-1 loop
        a := rec_a(K_BASE, l, h, t);
        for b in 0 to NBLK-1 loop
          ev := to_integer(signed(mem.rdb(a + b)));
          if ev /= VEC(o_ke(s_of(l, t), h) + b) then
            q5_bad <= q5_bad + 1;
            report "tb_attn_kv_seam: Q5 -- token " & integer'image(t)
                 & " layer " & integer'image(l)
                 & " signalled done, but its K record (head "
                 & integer'image(h) & ") block exponent " & integer'image(b)
                 & " is not in memory yet: read " & integer'image(ev)
                 & ", expected "
                 & integer'image(VEC(o_ke(s_of(l, t), h) + b))
                 & ".  C spec 2.7: token t+1 reads this through a DIFFERENT "
                 & "master and AXI orders nothing between masters."
              severity error;
            exit;
          end if;
        end loop;
        a := rec_a(V_BASE, l, h, t);
        for d in 0 to HEAD_DIM-1 loop
          ev := to_integer(signed(mem.rdb(a + CH_B + d)));
          if ev /= VEC(o_vm(s_of(l, t), h) + d) then
            q5_bad <= q5_bad + 1;
            report "tb_attn_kv_seam: Q5 -- token " & integer'image(t)
                 & " layer " & integer'image(l)
                 & " signalled done with its V record (head "
                 & integer'image(h) & ") not yet in memory at element "
                 & integer'image(d) severity error;
            exit;
          end if;
        end loop;
      end loop;

      for i in 1 to 8 loop wait until rising_edge(clk); end loop;
     end loop;
    end loop;

    all_done <= true;
    wait until rising_edge(clk);

    -- ======================= the checks ================================
    -- Q1: the values, per STEP, no tolerance.  A step is one (token,
    -- layer) job and the oracle emits one row per step.
    for t in 0 to NSTEP-1 loop
      if yn_got(t) /= NY then
        nerr := nerr + 1;
        report "tb_attn_kv_seam: step " & integer'image(t) & " emitted "
             & integer'image(yn_got(t)) & " elements, expected "
             & integer'image(NY) severity error;
      end if;
      q1_n := 0;
      for i in 0 to NY-1 loop
        if yi_got(t*NY + i) /= i then
          nerr := nerr + 1;
          report "tb_attn_kv_seam: token " & integer'image(t)
               & " y_index out of order at " & integer'image(i)
            severity error;
          exit;
        end if;
      end loop;
      for i in 0 to NY-1 loop
        if y_got(t*NY + i) /= VEC(o_ym(t) + i) then
          if q1_n = 0 then
            report "tb_attn_kv_seam: Q1 -- token " & integer'image(t)
                 & " element " & integer'image(i) & " = "
                 & integer'image(y_got(t*NY + i)) & ", the oracle says "
                 & integer'image(VEC(o_ym(t) + i))
                 & ".  MISMATCH against ref/attn_block_seq_vec.c."
              severity error;
          end if;
          q1_n := q1_n + 1;
        end if;
      end loop;
      if q1_n /= 0 then
        nerr := nerr + 1;
        report "tb_attn_kv_seam: Q1 -- token " & integer'image(t) & ", "
             & integer'image(q1_n) & " of " & integer'image(NY)
             & " mantissas differ from the oracle" severity error;
      end if;
      if ye_got(t) /= VEC(o_yex(t)) then
        nerr := nerr + 1;
        report "tb_attn_kv_seam: Q1 -- token " & integer'image(t)
             & " y_exp is " & integer'image(ye_got(t)) & ", the oracle says "
             & integer'image(VEC(o_yex(t))) & ".  MISMATCH." severity error;
      end if;
      q1_cmp := q1_cmp + NY + 1;
    end loop;

    -- Q2: the record image, at the address C spec 2.2's equation gives, for
    -- EVERY (layer, position).  The layer loop is what makes the equation's
    -- `layer` term falsifiable: at one layer a design that dropped the term
    -- writes to exactly the same bytes.
    q2_n := 0;
    for l in 0 to NLAY-1 loop
     for p in 0 to NTOK-1 loop
      for h in 0 to N_KVH-1 loop
        a := rec_a(K_BASE, l, h, p);
        for b in 0 to NBLK-1 loop
          if to_integer(signed(mem.rdb(a + b)))
             /= VEC(o_ke(s_of(l, p), h) + b) then
            if q2_n = 0 then
              report "tb_attn_kv_seam: Q2 -- K record (layer "
                   & integer'image(l) & ", pos "
                   & integer'image(p) & ", head " & integer'image(h)
                   & ") block exponent " & integer'image(b) & " at byte "
                   & integer'image(a + b) & " = "
                   & integer'image(to_integer(signed(mem.rdb(a + b))))
                   & ", the oracle says "
                   & integer'image(VEC(o_ke(s_of(l, p), h) + b))
                severity error;
            end if;
            q2_n := q2_n + 1;
          end if;
        end loop;
        for d in 0 to HEAD_DIM-1 loop
          if to_integer(signed(mem.rdb(a + CH_B + d)))
             /= VEC(o_km(s_of(l, p), h) + d)
          then
            if q2_n = 0 then
              report "tb_attn_kv_seam: Q2 -- K record (layer "
                   & integer'image(l) & ", pos "
                   & integer'image(p) & ", head " & integer'image(h)
                   & ") mantissa " & integer'image(d) & " at byte "
                   & integer'image(a + CH_B + d) & " = "
                   & integer'image(to_integer(signed(mem.rdb(a + CH_B + d))))
                   & ", the oracle says "
                   & integer'image(VEC(o_km(s_of(l, p), h) + d))
                severity error;
            end if;
            q2_n := q2_n + 1;
          end if;
        end loop;
        a := rec_a(V_BASE, l, h, p);
        for b in 0 to NBLK-1 loop
          if to_integer(signed(mem.rdb(a + b)))
             /= VEC(o_ve(s_of(l, p), h) + b) then
            if q2_n = 0 then
              report "tb_attn_kv_seam: Q2 -- V record (layer "
                   & integer'image(l) & ", pos "
                   & integer'image(p) & ", head " & integer'image(h)
                   & ") block exponent " & integer'image(b) & " mismatches"
                severity error;
            end if;
            q2_n := q2_n + 1;
          end if;
        end loop;
        for d in 0 to HEAD_DIM-1 loop
          if to_integer(signed(mem.rdb(a + CH_B + d)))
             /= VEC(o_vm(s_of(l, p), h) + d)
          then
            if q2_n = 0 then
              report "tb_attn_kv_seam: Q2 -- V record (layer "
                   & integer'image(l) & ", pos "
                   & integer'image(p) & ", head " & integer'image(h)
                   & ") mantissa " & integer'image(d) & " mismatches"
                severity error;
            end if;
            q2_n := q2_n + 1;
          end if;
        end loop;
      end loop;
     end loop;
    end loop;
    if q2_n /= 0 then
      nerr := nerr + 1;
      report "tb_attn_kv_seam: Q2 -- " & integer'image(q2_n)
           & " record bytes in HBM differ from the oracle" severity error;
    end if;

    -- Q6's coverage half.  Token t reads positions 0..t-1, so over the whole
    -- sequence position p is read by tokens p+1..NTOK-1, i.e. NTOK-1-p times.
    -- Each LAYER runs the same sequence independently, so the count is the
    -- same per layer.  A read that went to the wrong layer's region shows up
    -- as one bucket over and one bucket under, which no per-layer-blind
    -- count could distinguish from a correct run.
    for l in 0 to NLAY-1 loop
     for h in 0 to N_KVH-1 loop
      for p in 0 to NTOK-1 loop
        for b in 0 to NBLK-1 loop
          if cov(((l*N_KVH + h)*MAXCTX + p)*NBLK + b) /= NTOK-1-p then
            nerr := nerr + 1;
            report "tb_attn_kv_seam: K record (layer " & integer'image(l)
                 & ", head " & integer'image(h)
                 & ", pos " & integer'image(p) & ", block "
                 & integer'image(b) & ") was read "
                 & integer'image(cov(((l*N_KVH + h)*MAXCTX + p)*NBLK + b))
                 & " times over the sequence, expected "
                 & integer'image(NTOK-1-p) severity error;
            exit;
          end if;
          if cov(NLAY*N_KVH*MAXCTX*NBLK
                 + ((l*N_KVH + h)*MAXCTX + p)*NBLK + b) /= NTOK-1-p then
            nerr := nerr + 1;
            report "tb_attn_kv_seam: V record (layer " & integer'image(l)
                 & ", head " & integer'image(h)
                 & ", pos " & integer'image(p) & ", block "
                 & integer'image(b) & ") was read the wrong number of times"
              severity error;
            exit;
          end if;
        end loop;
      end loop;
     end loop;
    end loop;

    if q8_bad /= 0 then nerr := nerr + 1; end if;
    if q3_bad /= 0 then nerr := nerr + 1; end if;
    if q4_bad /= 0 then nerr := nerr + 1; end if;
    if q5_bad /= 0 then nerr := nerr + 1; end if;
    if q6_bad /= 0 then nerr := nerr + 1; end if;
    if slv_bad_r /= 0 or slv_bad_w /= 0 then nerr := nerr + 1; end if;
    if dbg_ep_lost /= '0' then
      nerr := nerr + 1;
      report "tb_attn_kv_seam: an e_p arrived while the previous one was "
           & "unconsumed" severity error;
    end if;

    report "tb_attn_kv_seam: blk_err=" & std_logic'image(blk_err)
         & " kv_err=" & std_logic'image(kv_err)
         & " rope_sat=" & std_logic'image(rope_sat)
         & " kv_sat=" & std_logic'image(kv_sat)
         & " y_sat=" & std_logic'image(y_sat)
         & " z_sat=" & std_logic'image(z_sat)
         & " rescale_max=" & integer'image(to_integer(rescale_max));

    if blk_err = '1' or kv_err = '1' then
      nerr := nerr + 1;
      report "tb_attn_kv_seam: err was raised on a legal sequence"
        severity error;
    end if;

    if nerr = 0 then
      report "tb_attn_kv_seam: PASS -- " & integer'image(NTOK)
           & " tokens at cur_pos 0.." & integer'image(NTOK-1)
           & " x " & integer'image(NLAY)
           & " layers INTERLEAVED token-major (" & integer'image(NSTEP)
           & " jobs) through rtl/attn_kv_axi.vhd over AXI at "
           & integer'image(RD_LAT)
           & "-cycle read latency, BIT-EXACT against "
           & "ref/attn_block_seq_vec.c over " & integer'image(q1_cmp)
           & " output values and "
           & integer'image(NSTEP*N_KVH*2*(NBLK+HEAD_DIM))
           & " record bytes in HBM, every returned beat matched to the "
           & "layer and position it was requested for, k_base="
           & integer'image(K_BASE)
           & " v_base=" & integer'image(V_BASE)
           & " (neither 4 KB aligned), MAXCTX=" & integer'image(MAXCTX)
           & ", longest quiet stretch " & integer'image(wd_max)
           & " cycles against a watchdog of " & integer'image(WDOG);
    else
      report "tb_attn_kv_seam: RESULT bad, " & integer'image(nerr)
           & " properties violated" severity failure;
    end if;
    running <= false;
    wait;
  end process;

end architecture;
