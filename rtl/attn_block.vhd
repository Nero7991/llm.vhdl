-- rtl/attn_block.vhd
-- Subsystem C: the gated-attention block, top level.  One attention layer,
-- one token, one card.
--
-- WHY THIS EXISTS, and what it settles.  C had eight unit-verified leaf units
-- and NOT ONE of them instantiated another.  Every one of the five read-path
-- units -- attn_score_q12, attn_softmax, attn_recip, attn_gate, attn_emit --
-- was built against a stream whose only possible producer was a multiply array
-- that did not exist, so their reachability was a statement about prose rather
-- than about a build.  That array is now rtl/attn_mac_array.vhd and this file
-- is what connects it to the other nine.  It is the same step gdn_block was for
-- subsystem B, and it is taken for the same reason: five of B's eight audit
-- findings were contracts between units that were not wired together.
--
--   A's wq output (Q and gate interleaved per head)     A's wk / wv outputs
--            |                                                  |
--     [Q half]                                            [K]        [V]
--            |                                             |          |
--       rmsnorm_rs  <- attn_q_norm            rmsnorm_rs <- attn_k_norm
--            |        (ONE shared instance, 14 invocations per layer)
--       attn_rope <- attn_twiddle             attn_rope             |
--            |                                     |                |
--       Q register plane                    attn_kv_quant  <--------+
--            |                                     |  272-byte record, per-32
--            |                                     |  exponents, v_ref fold
--            |                              KV cache port  (see the boundary
--            |                                     |       note below)
--            +--------> attn_mac_array <-----------+
--                        score mode | PV mode | rescale mode
--                          |                    ^
--                   attn_score_q12              |
--                          |                    |
--                    attn_softmax  --- e_p -----+
--                          |  s
--                    attn_recip
--                          |  (p, r)
--                    attn_gate  <- the gate half of wq, RE-READ (2.6)
--                          |  y_pre
--                    attn_emit
--                          |
--                        y stream
--
-- ======================= WHAT IS AT THE BOUNDARY =======================
--
-- THE KV CACHE IS A MEMORY PORT, NOT AXI, AND THAT IS A BOUNDARY AND NOT A
-- STUB.  C spec 2.2 puts the cache in DDR/HBM behind two read masters and one
-- write master, with 4 KB burst splitting, a 16-byte record-phase realignment
-- mux and a drain-then-flush on `start`.  That unit is `rtl/attn_kv_axi.vhd`
-- and it is written; what appears HERE is still a read port and a write port
-- with a one-cycle synchronous read, which is exactly what gdn_block does
-- with the recurrent state (2 MiB, DDR-resident by B spec 2.4, and a port
-- here).  The difference between a boundary and a stub is that a boundary
-- computes nothing and claims nothing: no exponent is fabricated, no value is
-- invented, and the port contract is the same one a BRAM or an HBM read stage
-- presents.
--
-- UNTIL 2026-08-28 THAT PORT COULD NOT BE CONNECTED TO ANY CACHE WITH
-- LATENCY, and the four `_rdy` inputs are what fixed it.  The issue is one
-- beat per cycle back to back and the capture is a fixed two cycles behind
-- it, so there was nothing to wait on; MEASURED, one extra cycle of memory
-- latency turns 64 of 64 output mantissas wrong against the oracle with `err`
-- clear.  The seam
-- is documented at the port declarations and at P_RECK.  What is still NOT
-- covered is stated in the open list at the end of this header.
--
-- THE CURRENT POSITION IS BYPASSED FROM REGISTERS AND NEVER RE-READ.  C spec
-- 2.4 makes this a correctness requirement rather than an optimisation: C
-- writes K/V[cur_pos] through the write master and would otherwise read it back
-- through a read master in the same job, and AXI orders nothing between
-- masters.  The bypass holds the QUANTIZED record, not the pre-quantization
-- int16, because the reference attends over the quantized cache including the
-- current token.
--
-- ===================== THE SCHEDULE, AND WHY IT IS SLOW =====================
--
-- Phases are STRICTLY SEQUENTIAL, exactly as gdn_block's are and for the same
-- reason: every additional concurrency is a new seam, and the seams are the
-- thing being tested.  C spec 3.1's production schedule is a 16-cycle position
-- slot with the PV of position p-2 running under the score of position p, plus
-- a group-overlap that hides group 1's QK-norms under group 0's sweep.  Neither
-- is built here.  What a production schedule would overlap is listed at the end
-- of the file.  The numeric result is unaffected: the online softmax's
-- PROCESSING ORDER is part of the numeric contract and it is preserved exactly
-- -- [cur_pos, 0, 1, ..., cur_pos-1], the bypass position first (C spec 3.1).
--
-- ONE DELIBERATE DEVIATION FROM THE SPEC'S DSP BUDGET, stated loudly because
-- it is a real cost.  C spec 3.1 shares ONE pipelined EXP_ROM cone across the
-- group's six query heads.  attn_softmax contains its own cone and cannot be
-- time-shared between heads, because it holds one head's m_g and s for the
-- whole sweep.  This block therefore instantiates G of them, i.e. G x 8 DSP
-- where the spec books 8.  At G = 6 that is +40 DSP on C's aux row -- 47 -> 87
-- -- and it moves C from 431 to 471.  The alternative is to serialise the
-- query heads (QH_TILE = 1, MACS = 32 on C spec 3.0's ladder), which costs a
-- factor of G in KV read bandwidth and is the exact redundancy the GQA
-- grouping of 2.4 exists to remove.  Neither is free and this one is at least
-- visible.  Hoisting the cone out of attn_softmax would fix it properly and
-- would modify a verified unit, which is out of scope here.
--
-- ================== THE SEAMS, AND WHAT EACH ONE COST ==================
--
-- SEAM 1: the norm weights.  rmsnorm_rs reads x_mant and w_mant as N*16
-- PARALLEL buses for the whole of its ~814-cycle invocation, and there are
-- 14 invocations per layer on the one shared instance -- a read window of
-- roughly 11,400 cycles.  This is the direct `w_mant` analogue of subsystem B's
-- 2026-08-27 defect, where head 23 of every block normalised with the NEXT
-- block's weights and heads 0 through 22 were bit-exact.  Both weight vectors
-- are therefore LATCHED at `start` into registers and `wn_taken` pulses at that
-- instant, so the producer has an observable safe edge instead of an unwritten
-- "hold everything until done" contract.
--
-- SEAM 2: v_ref.  attn_kv_quant folds the write-time minimum internally, but
-- it has ONE fold register and C spec 2.1.4 requires one per (layer, KV head).
-- With a single shared quantizer instance its own `v_ref` output would mix the
-- heads, so this block folds v_ref PER (LAYER, HEAD) from the record header the
-- unit publishes, and leaves the unit's own output open.  The LAYER half of
-- that index was missing until 2026-08-29 (defect C1): this block is
-- time-shared across every attention layer, so a head-only fold let each
-- layer's write-time minimum leak into every other layer's alignment shift.  The init value is +127 and
-- IS NOT NEUTRAL: an init of 0 right-shifts every V block by its full exponent
-- and silently destroys the cache's precision while passing every structural
-- check (C spec MJ5-2).  It is reset by `kv_seq_rst`, which is per SEQUENCE and
-- not per token, and `seq_rst_taken` makes that instant observable.
--
-- SEAM 3: the exponent chains.  All three are data-dependent and NOT derivable
-- from any interface port (C spec 2.1.2), which is the defect that survived
-- three revisions of the spec:
--     v_norm_exp     = v_exp                       (V is neither normed nor roped)
--     k_norm_exp[h]  = rmsnorm_rs's o_exp for K    (NOT k_exp)
--     q_norm_exp[qh] = rmsnorm_rs's o_exp for Q    (NOT qg_exp)
-- Each is taken from the norm stage's own output and nowhere else.  They are
-- also RANGE CHECKED against the int8 the record header and the downstream
-- ports carry: out of range raises `err` and aborts rather than wrapping
-- silently (C spec 2.1.5).
--
-- SEAM 4: the rescale pass is UNIFORM across the group.  attn_softmax raises
-- rs_valid and HOLDS it, refusing scores and producing no e_p until it is
-- acked, so a head that rescales cannot hand the array a weight belonging to
-- the new grid while the array still holds the old one.  The block waits until
-- every head has either produced its e_p or raised rs_valid, then runs ONE
-- pass over all NBLK accumulator indices with f = the head's own factor for
-- the heads that rose and f = 2^Q for the heads that did not.  2^Q is an EXACT
-- identity at site 5d, which is what makes the uniform pass legal and needs no
-- per-head masking (C spec 3.1).  The pass runs BEFORE the position's PV, and
-- that order is part of the numeric contract: the reference's mutation M6
-- swaps it and is killed.
--
-- SEAM 5: e_p has NO READY.  attn_softmax's ep_valid free-runs -- an e_p the
-- array does not take is a LOST weight, not a delayed one, which is
-- gdn_recur_pipe's o_res_valid shape exactly.  It is latched here by an
-- always-on collector, and `dbg_ep_lost` is the sticky synthesizable half of
-- the check: set if an e_p arrives for a head whose previous e_p has not yet
-- been consumed.  An assertion is simulation-only and this failure is
-- invisible in hardware.
--
-- ==================== BACK-PRESSURE, STATED PER PORT ====================
--
--   qg / kin / vin reads      N/A -- C is the master.  A memory cannot refuse
--                             and the block never issues an address it is not
--                             ready to consume.
--   KV cache read / write     N/A -- same, and see the boundary note.
--   y stream out              `y_ready` EXISTS and defaults to '1'.  C spec 1.4
--                             and 3.10 declare no ready at all, which makes C a
--                             producer that cannot be stalled, structurally
--                             identical to gdn_recur_pipe.  It is safe today
--                             only because subsystem D guarantees A is idle
--                             while C runs (2.7) -- a SCHEDULE property, not an
--                             interface property, and exactly the invisible
--                             contract the w_mant defect punished.  Adding the
--                             ready changes nothing for a consumer that
--                             genuinely cannot stall and converts the failure
--                             from silent loss into a visible stall.
--   done / done_ack           RULE 1: `done` is HELD until acked, never pulsed.
--                             `busy` is also published, because gdn_block's own
--                             adapter in llama_top had to use busy-falling
--                             rather than done for exactly this reason.
--
-- ============== WHAT THIS FILE DOES NOT DO -- the open list ==============
--
--   * No AXI IN THIS FILE.  The masters, the 4 KB burst splitting, the
--     16-byte record-phase realignment and the drain-then-flush on `start`
--     all live in `rtl/attn_kv_axi.vhd`; this block drives its port shape and
--     obeys its three `_rdy` signals.  `done` IS now gated on the write
--     master's B channel, through `kv_wr_idle` (C spec 2.7).
--   * The `_rdy` inputs default to '1'.  An instantiation that leaves them
--     open compiles, runs, and gets the pre-seam never-refusing memory --
--     which is correct for a BRAM and silently wrong for a cache with
--     latency.  `rtl/llama_top.vhd` leaves them open today and runs one token
--     at cur_pos = 0, where nothing is ever read.
--   * No overlap.  One position at a time, no two-position PV lag, no
--     group-overlap of the QK-norms.  C spec 3.7's cycle budget assumes both.
--   * G exp cones instead of one shared cone.  See the deviation note above.
--   * The gate is re-read from the qg port one element at a time rather than
--     through a 512-bit block port (C spec 3.10).  Same values, more cycles.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use work.util_pkg.all;

entity attn_block is
  generic(
    -- Shapes.  Defaults are Qwen3.5-9B on ONE card, which is the current
    -- build target, and every one of the four is DERIVED from
    -- `rtl/model_cfg_pkg.vhd`'s `QWEN35_9B` record at `NCARDS = 1`:
    --   HEAD_DIM 256 = attn_head_dim
    --   N_QH      16 = attn_q_heads / ncards
    --   N_KVH      4 = attn_kv_heads
    --   LAYERS     8 = blocks / attn_interval = 32 / 4
    -- 27B on two cards is N_QH = 12, N_KVH = 2, LAYERS = 16 (64 / 4).
    --
    -- CORRECTED 2026-08-29, TRACK CGENERICS.  All four used to be the 27B
    -- two-card set while the header claimed it was "the build target"; the
    -- target moved to the 9B at `constant MODEL := QWEN35_9B` and this file
    -- did not follow.  `rtl/gdn_block.vhd:187` is the precedent: subsystem
    -- B's defaults already say "Qwen3.5-9B on ONE card, which is the current
    -- target" and carry LAYERS 24 = gdn_layers.  NOTHING READ THESE
    -- DEFAULTS -- `sim/tb_attn_block.vhd:405`, `sim/tb_attn_kv_seam.vhd:502`
    -- and `rtl/llama_top.vhd:3951` all map every shape generic explicitly,
    -- and `sim/ooc_compose_bcd.tcl:73` passes exactly the set below because
    -- the old one was wrong -- so this is a statement made true again, not a
    -- number that was being computed with.  MEASURED: `sim/regress.sh
    -- --only attn` is PASS 15 FAIL 0 either side of the change.
    HEAD_DIM  : positive := 256;
    N_QH      : positive := 16;   -- query heads on THIS card
    N_KVH     : positive := 4;    -- KV heads on THIS card
    KV_BLOCK  : positive := 32;   -- C spec 2.1.1, and one 256-bit HBM beat
    N_ROT     : positive := 64;   -- GGUF rope.dimension_count
    LAYERS    : positive := 8;    -- attention layers, for the cache map
    POS_W     : positive := 16;   -- position width; MAXCTX <= 2^POS_W
    MANT_W    : positive := 16;   -- activation mantissa
    CM_W      : positive := 8;    -- KV cache mantissa
    EXP_W     : positive := 8;    -- every exponent on the wire
    ACC_W     : positive := 36;   -- PV accumulator, C spec 2.6
    E_W       : positive := 13;   -- e_p and f, u13
    S_W       : positive := 26;   -- the softmax denominator
    P_W       : positive := 32;   -- score / partial
    T_W       : positive := 24;   -- site 6b's t
    Y_W       : positive := 24;   -- site 6e's y_pre
    Q         : natural  := 12;   -- the Q12 grid
    GQ        : natural  := 15;   -- the sigmoid output's Q
    -- The reciprocal's Q.  Site 6b gives value = t * 2^-(v_ref + R_Q - 1),
    -- so the output grid of 6f is v_ref + 14 at R_Q = 15.  It is a separate
    -- generic from GQ because they are 15 for two unrelated reasons and
    -- folding them would make one of the two invisible.
    R_Q       : natural  := 15;
    ROM_N     : positive := 256;  -- EXP_ROM intervals
    SIG_N     : positive := 512;  -- SIG_ROM intervals
    TW_TBL    : positive := 1024; -- sine table entries
    -- rmsnorm_rs lane count.  1 is the only configuration C spec 3.8 measured
    -- as closing at N = 256, and it is the only one whose cycle count was
    -- checked against C's schedule (814 cycles x 224 norms = 182K, inside the
    -- 290K serial fallback).
    NORM_LANES : positive := 1;
    -- TRUE here, false in the leaves.  At the top level every producer is
    -- known, so a refused beat is a lost beat and not a stall.
    STRICT_PRODUCER : boolean := true;
    -- ==================================================================
    -- SWEEP_PIPE -- the per-POSITION cost of the sweep loop.  OFF by
    -- default, so every existing instantiation keeps the schedule it has
    -- bit for bit.  See the note at P_RECK.
    -- ==================================================================
    SWEEP_PIPE : boolean := false;
    -- ==================================================================
    -- SCORE_EARLY -- hand the K record's HEADER to attn_score_q12 as soon
    -- as it is captured, instead of after the whole record is.  OFF by
    -- default, so every existing instantiation keeps the schedule it has
    -- bit for bit.  See the note at P_HDR.
    --
    -- WHY IT EXISTS, MEASURED.  sim/tb_csweep_rate.vhd 2026-09-20, real 9B
    -- geometry, per position per KV head, asymptotic slope:
    --
    --     SWEEP_PIPE off            SWEEP_PIPE on
    --     P_SCORE  23.00 cycles     P_SCORE  23.00 cycles
    --       of which 14.00 is `ar_prdy` LOW and 9.00 is the eight issues
    --
    -- Those 14 cycles are `attn_score_q12` walking its own header:
    -- S_EMIN is NBLK-1 narrow compares one per cycle and S_SHIFTS is NBLK
    -- narrow subtracts one per cycle (rtl/attn_score_q12.vhd:343 and :357),
    -- 15 cycles from the latch, of which 14 are visible here.  The sweep
    -- has nothing to do for any of them.
    --
    -- The header is a function of the K record ALONE and it arrives with
    -- that record's FIRST beat -- `kr_hdr` stands for every beat of a
    -- record -- so the whole pass can run under the rest of the fetch and
    -- under the previous position's PV.  This generic does that and
    -- nothing else: no arithmetic moves, no beat moves, and the partials
    -- are still issued by P_SCORE in the same order.
    SCORE_EARLY : boolean := false
  );
  port(
    clk : in std_logic;
    rst : in std_logic;

    -- ---- control ---------------------------------------------------------
    start   : in  std_logic;                       -- run one layer/token
    layer   : in  integer range 0 to LAYERS-1;
    cur_pos : in  unsigned(POS_W-1 downto 0);
    ctx_len : in  unsigned(POS_W-1 downto 0);
    busy    : out std_logic;
    -- RULE 2: layer/cur_pos/ctx_len are latched here and read from the latch
    -- for the whole job.  D advancing the descriptor mid-job would otherwise
    -- corrupt the tail of the job and nothing else, which is the head-23 shape.
    cfg_taken : out std_logic;

    -- ---- per-SEQUENCE reset of the v_ref fold.  A LEVEL from D. ----------
    kv_seq_rst    : in  std_logic;
    seq_rst_taken : out std_logic;

    -- ---- subsystem A's activation memory, ONE CYCLE synchronous reads ----
    -- x_rdata must hold mem[x_raddr] on the cycle after an edge at which the
    -- enable was high, and must be HELD across any edge at which it was low.
    -- The gate is the second half of each head's wq output (1.1(a)), so the
    -- qg region is 2*HEAD_DIM per query head and Q of head qh is at
    -- 2*HEAD_DIM*qh while G of head qh is at 2*HEAD_DIM*qh + HEAD_DIM.
    qg_raddr : out unsigned(clog2(2*HEAD_DIM*N_QH)-1 downto 0);
    qg_re    : out std_logic;
    qg_rdata : in  signed(MANT_W-1 downto 0);
    qg_exp   : in  signed(EXP_W-1 downto 0);
    kin_raddr : out unsigned(clog2(HEAD_DIM*N_KVH)-1 downto 0);
    kin_re    : out std_logic;
    kin_rdata : in  signed(MANT_W-1 downto 0);
    kin_exp   : in  signed(EXP_W-1 downto 0);
    vin_raddr : out unsigned(clog2(HEAD_DIM*N_KVH)-1 downto 0);
    vin_re    : out std_logic;
    vin_rdata : in  signed(MANT_W-1 downto 0);
    vin_exp   : in  signed(EXP_W-1 downto 0);

    -- ---- per-layer QK-norm weights.  LATCHED, see SEAM 1. ----------------
    qn_mant : in  std_logic_vector(HEAD_DIM*MANT_W-1 downto 0);
    qn_exp  : in  signed(EXP_W-1 downto 0);
    kn_mant : in  std_logic_vector(HEAD_DIM*MANT_W-1 downto 0);
    kn_exp  : in  signed(EXP_W-1 downto 0);
    wn_taken : out std_logic;

    -- ---- the KV cache.  A PORT, not a master.  See the boundary note. ----
    --
    -- THE FOUR `_rdy` INPUTS BELOW ARE THE SEAM, ADDED 2026-08-28.  Before
    -- them this port was unconnectable to any AXI-backed cache and that was
    -- not a matter of degree.  The read issue below is ONE BEAT PER CYCLE,
    -- BACK TO BACK, and the capture is a fixed two cycles after the issue
    -- (:1013-1027), i.e. a one-cycle synchronous read with no elasticity
    -- anywhere; HBM read latency is O(100) cycles and this block had no
    -- signal on which it could wait.  MEASURED before the change: giving the
    -- memory model in sim/tb_attn_block.vhd ONE extra cycle of latency makes
    -- 64 of 64 output mantissas wrong against the oracle with `err` clear --
    -- a wrong answer, not a stall and not a fault.
    --
    -- All four default to '1', which is exactly the behaviour of a memory
    -- that can never refuse, so an instantiation that leaves them open keeps
    -- the pre-seam schedule bit for bit.  That default is a compatibility
    -- decision and it is the same one `y_ready` takes above; it is NOT a
    -- claim that leaving them open is safe against a real cache.
    kv_layer : out unsigned(clog2(LAYERS)-1 downto 0);
    -- write: the header first, then one block per cycle
    kw_sel   : out std_logic;                       -- '0' = K, '1' = V
    kw_head  : out unsigned(clog2(N_KVH)-1 downto 0);
    kw_pos   : out unsigned(POS_W-1 downto 0);
    kw_hen   : out std_logic;
    kw_hdr   : out std_logic_vector((HEAD_DIM/KV_BLOCK)*EXP_W-1 downto 0);
    kw_en    : out std_logic;
    kw_blk   : out unsigned(clog2(HEAD_DIM/KV_BLOCK)-1 downto 0);
    kw_mant  : out std_logic_vector(KV_BLOCK*CM_W-1 downto 0);
    -- '1' while the sink can take a whole record.  rtl/attn_kv_axi.vhd drops
    -- kw_hen and kw_en SILENTLY while its record buffer is full or while it
    -- is flushing, so an ungated writer loses a record and nothing says so.
    kw_rdy   : in  std_logic := '1';
    -- read, K side and V side, one cycle.  The header is returned with every
    -- beat of the record it belongs to, which is what makes the header-first
    -- contract attn_score_q12 depends on free at this boundary.
    --
    -- REQUEST / RESIDENCY / BEATS, the contract rtl/attn_kv_axi.vhd:85-101
    -- publishes.  `kr_head` / `kr_pos` are a REQUEST and are HELD from before
    -- the first issue until after the last beat of that record has been
    -- taken; `kr_rdy` is combinational in the held request and says the
    -- record is resident; only while it is '1' may `kr_en` be raised, and the
    -- beat then returns on the next cycle.
    kr_en   : out std_logic;
    kr_head : out unsigned(clog2(N_KVH)-1 downto 0);
    kr_pos  : out unsigned(POS_W-1 downto 0);
    kr_rdy  : in  std_logic := '1';
    kr_blk  : out unsigned(clog2(HEAD_DIM/KV_BLOCK)-1 downto 0);
    kr_hdr  : in  std_logic_vector((HEAD_DIM/KV_BLOCK)*EXP_W-1 downto 0);
    kr_mant : in  std_logic_vector(KV_BLOCK*CM_W-1 downto 0);
    vr_en   : out std_logic;
    vr_head : out unsigned(clog2(N_KVH)-1 downto 0);
    vr_pos  : out unsigned(POS_W-1 downto 0);
    vr_rdy  : in  std_logic := '1';
    vr_blk  : out unsigned(clog2(HEAD_DIM/KV_BLOCK)-1 downto 0);
    vr_hdr  : in  std_logic_vector((HEAD_DIM/KV_BLOCK)*EXP_W-1 downto 0);
    vr_mant : in  std_logic_vector(KV_BLOCK*CM_W-1 downto 0);
    -- C spec 2.7: token T's write of K/V[cur_pos] is read by token T+1
    -- through a DIFFERENT master and AXI orders nothing between masters, so
    -- `done` must not assert until every write of this job has retired its
    -- BRESP.  rtl/attn_kv_axi.vhd publishes that term as `wr_idle`; this
    -- block does not own the fact and only gates on it.
    kv_wr_idle : in std_logic := '1';

    -- ---- the block output, to A's activation memory for wo ---------------
    y_valid : out std_logic;
    y_mant  : out signed(MANT_W-1 downto 0);
    y_index : out unsigned(clog2(N_QH*HEAD_DIM)-1 downto 0);
    y_last  : out std_logic;
    y_exp   : out signed(EXP_W-1 downto 0);
    y_ready : in  std_logic := '1';
    -- Published strictly before the first y_valid; see the ordering rule.
    y_hdr_valid : out std_logic;

    -- ---- completion.  RULE 1: held until acked, never pulsed. ------------
    done     : out std_logic;
    done_ack : in  std_logic := '1';

    -- ---- status.  Every one of these is reported into open air by the unit
    -- that produces it; they are consumed, made sticky for the block, and
    -- published, which is the cheapest thing that can be done about them.
    err       : out std_logic;   -- an abort-class event, C spec 3.9
    rope_sat  : out std_logic;   -- quality event, NOT an error (C spec 3.4)
    kv_sat    : out std_logic;   -- the int8 pack clipped; quality event
    y_sat     : out std_logic;   -- the int16 output pack clipped
    z_sat     : out std_logic;   -- site 6c saturated; reachable and legal
    rescale_max : out unsigned(15 downto 0);   -- C spec 3.3's observability
    -- Sticky, synthesizable: an e_p arrived for a head whose previous e_p had
    -- not been consumed.  In hardware that weight is gone; nothing else would
    -- say so.
    dbg_ep_lost : out std_logic;

    -- ---- THE SWEEP PHASE, PUBLISHED SO A RATE BENCH CAN SPLIT IT ---------
    -- WHY THIS PORT EXISTS.  `ph` is a locally-declared enumeration in this
    -- architecture, so no bench can name its type and no VHDL external name
    -- can reach it.  MEASURED 2026-09-20 by sim/tb_csweep_rate.vhd, the
    -- per-position cost of the sweep is 87.42 cycles of which 56.42 sit
    -- between the last K beat and the first V beat -- and that 56.42 could
    -- only be SPLIT by DERIVING it, because the states inside it drive no
    -- port of this entity.  `docs/debugging/2026-09-20_c-sweeps-at-5-cycles-
    -- per-beat.md` closes on exactly that gap.
    --
    -- The encoding is a NAMED constant per state (SWPH_* below), not the
    -- `ph_t'pos` of the phase, so inserting a state cannot silently shift a
    -- code that a bench or a document has already quoted.  It is zero
    -- (SWPH_NONE) in every state outside the sweep.  Bit 4 is `is_byp`, the
    -- bypass position, which reads no record and must be excluded from any
    -- per-record-pair figure.
    --
    -- COST: none in the shipping build.  The phase register already exists;
    -- this is a decode of it, and an unconnected OUT port is trimmed.  Every
    -- instantiation in rtl/llama_top.vhd, rtl/fk33_llama_top.vhd,
    -- rtl/ooc_cattnadapt_top.vhd and hw/fk33/rtl/compose4_top.vhd leaves it
    -- unassociated, which is legal for mode `out` and needs no edit to any
    -- of them.
    dbg_sw_ph : out std_logic_vector(4 downto 0);

    -- The four sweep handshakes, published for the same reason and with the
    -- same cost.  A phase code says WHICH state the sweep is in; these say
    -- WHY it is still there, which is the difference between "P_SCORE takes
    -- 23 cycles" and "P_SCORE spends 15 of them waiting for
    -- attn_score_q12's header pass and 8 issuing".
    --   (0) ar_prdy  -- every score unit's p_ready, the score-issue gate
    --   (1) ar_scv   -- a score partial block was issued this cycle
    --   (2) sq_busy  -- some score unit is not idle
    --   (3) ar_pvv   -- a PV block was issued this cycle
    dbg_sw_aux : out std_logic_vector(3 downto 0)
  );
end entity;

architecture rtl of attn_block is

  constant NBLK  : integer := HEAD_DIM/KV_BLOCK;
  constant G     : integer := N_QH/N_KVH;
  constant NPAIR : integer := N_ROT/2;
  constant AW_D  : integer := clog2(HEAD_DIM);
  constant AW_B  : integer := clog2(NBLK);
  constant AW_G  : integer := clog2(G);
  constant AW_H  : integer := clog2(N_KVH);
  constant GRP_N : integer := G*HEAD_DIM;
  constant AW_Y  : integer := clog2(N_QH*HEAD_DIM);
  -- kq_scale = 1/sqrt(head_dim) is a power of two ONLY when head_dim is an
  -- even power of two, which 256 is in both target models.  The elaboration
  -- check below is what stops a head_dim that is not from folding an
  -- irrational scale into an exponent and looking fine.
  constant KQ_SH : integer := AW_D/2;

  -- ---- latched descriptor (RULE 2) --------------------------------------
  signal lay_r  : integer range 0 to LAYERS-1 := 0;
  signal cpos_r : unsigned(POS_W-1 downto 0) := (others => '0');
  signal clen_r : unsigned(POS_W-1 downto 0) := (others => '0');

  -- ---- latched norm weights (SEAM 1) ------------------------------------
  signal qnm_r : std_logic_vector(HEAD_DIM*MANT_W-1 downto 0) := (others => '0');
  signal knm_r : std_logic_vector(HEAD_DIM*MANT_W-1 downto 0) := (others => '0');
  signal qne_r : signed(EXP_W-1 downto 0) := (others => '0');
  signal kne_r : signed(EXP_W-1 downto 0) := (others => '0');
  signal qge_r, kie_r, vie_r : signed(EXP_W-1 downto 0) := (others => '0');

  -- ---- scratches ---------------------------------------------------------
  type v_arr is array (0 to HEAD_DIM-1) of signed(MANT_W-1 downto 0);
  signal vs   : v_arr := (others => (others => '0'));   -- norm/rope source
  signal vs2  : v_arr := (others => (others => '0'));   -- rope destination
  signal vs_q, vs2_q : signed(MANT_W-1 downto 0) := (others => '0');

  -- vs2 flattened, so gqpl's slice target can be static in the generate index.
  -- See the note at gqpl.
  signal vs2_flat : std_logic_vector(HEAD_DIM*MANT_W-1 downto 0)
                  := (others => '0');

  signal qplane : std_logic_vector(G*HEAD_DIM*MANT_W-1 downto 0)
                := (others => '0');
  type e8_arr is array (natural range <>) of signed(EXP_W-1 downto 0);
  signal qexp_r : e8_arr(0 to G-1) := (others => (others => '0'));

  signal krec, vrec : std_logic_vector(HEAD_DIM*CM_W-1 downto 0)
                    := (others => '0');
  signal khdr, vhdr : std_logic_vector(NBLK*EXP_W-1 downto 0)
                    := (others => '0');
  signal kbyp, vbyp : std_logic_vector(HEAD_DIM*CM_W-1 downto 0)
                    := (others => '0');
  signal kbh,  vbh  : std_logic_vector(NBLK*EXP_W-1 downto 0)
                    := (others => '0');

  -- The per-(layer, KV head) write-time min fold (SEAM 2).  The layer index is
  -- part of the SHAPE, not a nicety: ONE attn_block is time-shared across every
  -- attention layer, so a fold with only a head index makes each layer's
  -- minimum visible to every other layer (defect C1,
  -- docs/debugging/2026-08-29_c1-vref-layer.md).  Indexed lay_r*N_KVH + kvh;
  -- `lay_r` is the LATCHED layer (RULE 2), never the live `layer` port.
  signal vref_r : e8_arr(0 to LAYERS*N_KVH-1)
                := (others => to_signed(127, EXP_W));

  -- ---- rmsnorm_rs --------------------------------------------------------
  signal rn_start : std_logic := '0';
  signal rn_x     : std_logic_vector(HEAD_DIM*MANT_W-1 downto 0) := (others => '0');
  signal rn_w     : std_logic_vector(HEAD_DIM*MANT_W-1 downto 0) := (others => '0');
  signal rn_xe, rn_we : integer := 0;
  signal rn_done  : std_logic;
  signal rn_o     : std_logic_vector(HEAD_DIM*MANT_W-1 downto 0);
  signal rn_oe    : integer;

  -- ---- attn_twiddle ------------------------------------------------------
  signal tw_start : std_logic := '0';
  signal tw_valid : std_logic;
  signal tw_cos, tw_sin : signed(MANT_W-1 downto 0);
  signal tw_ready : std_logic;
  signal tw_err   : std_logic;

  -- ---- attn_rope ---------------------------------------------------------
  signal rp_start : std_logic := '0';
  signal rp_xexp  : signed(EXP_W-1 downto 0) := (others => '0');
  signal rp_raddr : std_logic_vector(AW_D-1 downto 0);
  signal rp_re    : std_logic;
  signal rp_yexp  : signed(EXP_W-1 downto 0);
  signal rp_yv    : std_logic;
  signal rp_yd    : signed(MANT_W-1 downto 0);
  signal rp_yi    : unsigned(AW_D-1 downto 0);
  signal rp_done  : std_logic;
  signal rp_sat, rp_err : std_logic;

  -- ---- attn_kv_quant -----------------------------------------------------
  signal kq_start : std_logic := '0';
  signal kq_isv   : std_logic := '0';
  signal kq_sexp  : signed(EXP_W-1 downto 0) := (others => '0');
  signal kq_raddr : std_logic_vector(AW_D-1 downto 0);
  signal kq_re    : std_logic;
  signal kq_rdata : std_logic_vector(MANT_W-1 downto 0);
  signal kq_hdrv  : std_logic;
  signal kq_eblk  : std_logic_vector(NBLK*EXP_W-1 downto 0);
  signal kq_mv    : std_logic;
  signal kq_md    : std_logic_vector(CM_W-1 downto 0);
  signal kq_mi    : std_logic_vector(AW_D-1 downto 0);
  signal kq_done  : std_logic;
  signal kq_sat, kq_err : std_logic;

  -- ---- attn_mac_array ----------------------------------------------------
  signal ar_clr  : std_logic := '0';
  signal ar_scv  : std_logic := '0';
  signal ar_scb  : unsigned(AW_B-1 downto 0) := (others => '0');
  signal ar_sck  : std_logic_vector(KV_BLOCK*CM_W-1 downto 0) := (others => '0');
  signal ar_scq  : std_logic_vector(G*KV_BLOCK*MANT_W-1 downto 0) := (others => '0');
  signal ar_pv   : std_logic;
  signal ar_pd   : std_logic_vector(G*P_W-1 downto 0);
  signal ar_pvv  : std_logic := '0';
  signal ar_pvb  : unsigned(AW_B-1 downto 0) := (others => '0');
  signal ar_vdat : std_logic_vector(KV_BLOCK*CM_W-1 downto 0) := (others => '0');
  signal ar_pve  : std_logic_vector(G*E_W-1 downto 0) := (others => '0');
  signal ar_rsv  : std_logic := '0';
  signal ar_rsb  : unsigned(AW_B-1 downto 0) := (others => '0');
  signal ar_rsf  : std_logic_vector(G*E_W-1 downto 0) := (others => '0');
  signal ar_rdv  : std_logic := '0';
  signal ar_rdh  : unsigned(AW_G-1 downto 0) := (others => '0');
  signal ar_rdi  : unsigned(clog2(NBLK*KV_BLOCK)-1 downto 0) := (others => '0');
  signal ar_ov   : std_logic;
  signal ar_od   : signed(ACC_W-1 downto 0);
  signal ar_ovr, ar_err : std_logic;
  signal ar_prdy : std_logic;
  -- C spec 3.11 item 2(c): the append-only invariant e_v[b] >= v_ref.  It is
  -- what makes the V alignment UNCONDITIONALLY a right shift, and it holds
  -- only because v_ref is a minimum folded over every record ever written for
  -- this (layer, KV head).  A cache slot written before the fold was armed --
  -- or any future cache truncation or rollback, which C spec 2.1.4 warns
  -- breaks the equivalence SILENTLY -- violates it.  Clamping the shift to
  -- zero, which is what the barrel shifter must do anyway, would hide that.
  signal vsh_neg : std_logic;
  -- The REGISTERED block index the operand buses are built from.  It is not
  -- `blk`: `blk` is incremented in the same edge that raises the valid, so a
  -- combinational bus built from it presents the NEXT block's operands with
  -- this block's label.  That is the gdn_conv tvalid shape and it is silent.
  signal opb : integer range 0 to NBLK-1 := 0;

  -- ---- per-head read-path instances --------------------------------------
  signal sq_hdrv : std_logic := '0';
  type sl_arr is array (0 to G-1) of std_logic;
  signal sq_taken, sq_busy, sq_sv, sq_sat, sq_ovr, sq_err : sl_arr;
  type p32_arr is array (0 to G-1) of signed(P_W-1 downto 0);
  signal sq_q12 : p32_arr;
  signal sq_prdy : sl_arr;

  signal sm_start : std_logic := '0';
  signal sm_last  : std_logic := '0';
  signal last_p   : std_logic := '0';
  signal sm_taken, sm_busy, sm_scrdy, sm_epv, sm_rsv, sm_done : sl_arr;
  signal sm_ovf, sm_err : sl_arr;
  type e13_arr is array (0 to G-1) of unsigned(E_W-1 downto 0);
  signal sm_ep, sm_f : e13_arr;
  type s_arr is array (0 to G-1) of unsigned(S_W-1 downto 0);
  signal sm_s : s_arr;
  type r16_arr is array (0 to G-1) of unsigned(15 downto 0);
  signal sm_rn : r16_arr;
  signal sm_rsack : std_logic := '0';
  signal sm_dack  : std_logic := '0';

  signal ep_have : sl_arr := (others => '0');
  signal ep_val  : e13_arr := (others => (others => '0'));
  signal rs_have : sl_arr := (others => '0');
  signal rs_val  : e13_arr := (others => (others => '0'));
  signal eplost_r : std_logic := '0';

  -- ---- attn_recip --------------------------------------------------------
  signal rc_sv   : std_logic := '0';
  signal rc_sin  : unsigned(S_W-1 downto 0) := (others => '0');
  signal rc_last : std_logic := '0';
  signal rc_srdy : std_logic;
  signal rc_rv   : std_logic;
  signal rc_p    : unsigned(clog2(S_W)-1 downto 0);
  signal rc_r    : unsigned(15 downto 0);
  signal rc_err, rc_ovr : std_logic;

  -- ---- attn_gate ---------------------------------------------------------
  signal gt_cfgv : std_logic := '0';
  signal gt_p    : unsigned(clog2(S_W)-1 downto 0) := (others => '0');
  signal gt_r    : unsigned(15 downto 0) := (others => '0');
  signal gt_qge  : signed(EXP_W-1 downto 0) := (others => '0');
  signal gt_crdy, gt_busy : std_logic;
  signal gt_xv   : std_logic := '0';
  signal gt_o    : signed(ACC_W-1 downto 0) := (others => '0');
  signal gt_g    : signed(MANT_W-1 downto 0) := (others => '0');
  signal gt_xrdy : std_logic;
  signal gt_yv   : std_logic;
  signal gt_y    : signed(Y_W-1 downto 0);
  signal gt_done : std_logic;
  signal gt_zsat, gt_ovr, gt_ysat : std_logic;

  -- ---- the y_pre scratch and attn_emit -----------------------------------
  type y_arr is array (0 to N_KVH*GRP_N-1) of signed(Y_W-1 downto 0);
  signal ypre : y_arr := (others => (others => '0'));
  signal ypre_q : signed(Y_W-1 downto 0) := (others => '0');
  signal ypre_wi : integer range 0 to N_KVH*GRP_N := 0;

  signal em_start : std_logic := '0';
  signal em_grid  : std_logic_vector(N_KVH*EXP_W-1 downto 0) := (others => '0');
  signal em_raddr : std_logic_vector(clog2(N_KVH*GRP_N)-1 downto 0);
  signal em_re    : std_logic;
  signal em_hdrv  : std_logic;
  signal em_yexp  : signed(EXP_W-1 downto 0);
  signal em_mv    : std_logic;
  signal em_md    : std_logic_vector(MANT_W-1 downto 0);
  signal em_mi    : std_logic_vector(clog2(N_KVH*GRP_N)-1 downto 0);
  signal em_done  : std_logic;
  signal em_sat, em_err : std_logic;

  -- ---- STICKY COMPLETION CAPTURES.  Every `done` in this design is either a
  -- pulse or a level held only until an ack, and a phase machine that polls a
  -- pulse at the wrong instant waits forever.  That is RULE 1's failure mode
  -- read from the consumer side, and it cost llama_top's gdn_block adapter a
  -- debugging session (it had to wait on `busy` falling instead).  Each flag
  -- is cleared by the state that issues the matching `start`, so it can never
  -- carry a completion from one invocation into the next.
  signal rn_dn, rp_dn, kq_dn, gt_dn, em_dn, rc_dn : std_logic := '0';
  signal rc_pq : unsigned(clog2(S_W)-1 downto 0) := (others => '0');
  signal rc_rq : unsigned(15 downto 0) := (others => '0');

  -- ---- the phase machine -------------------------------------------------
  type ph_t is (P_IDLE,
                P_KLOAD, P_NORMGO, P_NORMW,
                P_ROPEGO, P_ROPEW,
                P_KQGO, P_KQW,
                P_VQGO, P_VQW, P_WREC,
                P_QN,
                P_SWGO, P_RECK, P_HDR, P_SCORE, P_SCW,
                P_EPW, P_RSPASS, P_RSACK,
                P_RECV, P_PV, P_POSN,
                P_SFW, P_RCP, P_RCW, P_GATEGO,
                P_GAT1, P_GAT2, P_GAT3, P_GAT4, P_GATEW, P_GN,
                P_HN, P_EMITGO, P_EMITW, P_DONE);

  -- The published sweep-phase codes, driving `dbg_sw_ph(3 downto 0)`.  These
  -- are DELIBERATELY not `ph_t'pos`: a code quoted in a document or decoded
  -- by a bench must not move when a state is inserted into the enumeration
  -- above.  Only the ten sweep states have a code; everything else reads
  -- SWPH_NONE.
  subtype swph_t is std_logic_vector(3 downto 0);
  constant SWPH_NONE   : swph_t := x"0";
  constant SWPH_RECK   : swph_t := x"1";
  constant SWPH_HDR    : swph_t := x"2";
  constant SWPH_SCORE  : swph_t := x"3";
  constant SWPH_SCW    : swph_t := x"4";
  constant SWPH_EPW    : swph_t := x"5";
  constant SWPH_RSPASS : swph_t := x"6";
  constant SWPH_RSACK  : swph_t := x"7";
  constant SWPH_RECV   : swph_t := x"8";
  constant SWPH_PV     : swph_t := x"9";
  constant SWPH_POSN   : swph_t := x"A";
  signal ph : ph_t := P_IDLE;

  -- ---- SCORE_EARLY.  Both are inert with the generic false. -------------
  -- se_rdy   the K header of the position about to be scored has been
  --          captured into `khdr` and has not yet been handed over.  Set on
  --          the FIRST captured beat of a K record and on no other.
  -- se_sent  every attn_score_q12 has taken that header, so P_HDR is a
  --          no-op for this position.
  signal se_rdy  : std_logic := '0';
  signal se_sent : std_logic := '0';

  signal kvh   : integer range 0 to N_KVH := 0;
  signal qh    : integer range 0 to G := 0;
  signal li    : integer range 0 to HEAD_DIM := 0;
  signal lw    : integer range 0 to HEAD_DIM := 0;
  signal lsel  : integer range 0 to 2 := 0;   -- 0 kin, 1 vin, 2 qg
  signal lsel_q: integer range 0 to 2 := 0;
  signal lv    : std_logic_vector(1 to 2) := (others => '0');
  signal blk   : integer range 0 to NBLK+3 := 0;
  signal rbv   : std_logic_vector(1 to 2) := (others => '0');
  signal rbi   : integer range 0 to NBLK := 0;
  signal pos_i : unsigned(POS_W-1 downto 0) := (others => '0');
  signal is_byp: std_logic := '0';

  -- ====================================================================
  -- SWEEP_PIPE.  See the note at P_RECK.  Every signal below is inert
  -- when the generic is false: `cap_v` falls back to `ph` and nothing
  -- else is ever written, so the shipping schedule is unchanged bit for
  -- bit and synthesis optimises the rest away.
  -- ====================================================================
  -- WHICH REGISTER A CAPTURED BEAT BELONGS TO, CARRIED WITH THE ISSUE
  -- RATHER THAN READ FROM `ph` TWO CYCLES LATER.  In the shipping
  -- schedule the two are the same fact, because a V beat is only ever
  -- issued in P_RECV and P_RECV cannot be left until every beat of the
  -- record has been captured.  Under SWEEP_PIPE they are NOT: a V record
  -- is fetched while `ph` is in the score phase, so `ph` names the wrong
  -- register for it.
  signal rbs   : std_logic_vector(1 to 2) := (others => '0');
  signal cap_v : std_logic;
  signal cidx_k, cidx_v : integer range 0 to NBLK;

  -- The K stream, which under SWEEP_PIPE runs ONE POSITION AHEAD of the
  -- sweep, and the V stream, which runs ahead WITHIN the position.
  signal pk_en  : std_logic := '0';   -- beats still to issue
  signal pk_blk : integer range 0 to NBLK := 0;
  signal pk_cnt : integer range 0 to NBLK := 0;   -- beats captured
  signal pk_got : std_logic := '0';   -- krec holds this position's record
  -- A REQUEST IS OUTSTANDING.  `pk_en` falls on the LAST ISSUE and the last
  -- capture lands two cycles later, so `pk_en = '0'` on its own is true for
  -- a window in which the record is already on its way.  MEASURED on the
  -- first SWEEP_PIPE run of sim/tb_attn_block: without this, P_RECK re-armed
  -- the SAME fetch inside that window, and the re-arm was still running when
  -- P_RECK consumed the original and armed V -- which is the one state the
  -- shared `rbv`/`rbs` pipe cannot represent.  The assert below caught it.
  signal pk_pend: std_logic := '0';
  signal pk_act : std_logic := '0';   -- the held K request LEADS pos_i
  signal pv_en  : std_logic := '0';
  signal pv_blk : integer range 0 to NBLK := 0;
  signal pv_cnt : integer range 0 to NBLK := 0;
  signal pv_got : std_logic := '0';
  signal wr_isv: std_logic := '0';
  signal gi    : integer range 0 to HEAD_DIM := 0;

  signal err_r   : std_logic := '0';
  signal rsat_r  : std_logic := '0';
  signal ksat_r  : std_logic := '0';
  signal ysat_r  : std_logic := '0';
  signal zsat_r  : std_logic := '0';
  signal rmax_r  : unsigned(15 downto 0) := (others => '0');
  signal done_r  : std_logic := '0';
  signal cfgtk_r, wntk_r, srtk_r : std_logic := '0';
  signal seqrst_q : std_logic := '0';

  function e_of(v : std_logic_vector; i : integer) return signed is
  begin
    return signed(v((i+1)*EXP_W-1 downto i*EXP_W));
  end function;

  -- BALANCED-TREE MINIMUM over the NBLK block exponents of a v header.
  --
  -- WHY THIS EXISTS (TRACK TIMING, 2026-08-30).  The SEAM 2 write-time fold in
  -- the sequencer used to be a SERIAL reduction that seeded from `vref_r` and
  -- chained NBLK compare-selects through it.  MEASURED on TRACK COMPOSE4's
  -- composed A+B+C+D PLACED checkpoint: that is a 28-LOGIC-LEVEL path from
  -- vref_r_reg back to vref_r_reg, it is every one of the forty worst paths in
  -- that design, and it is EXACTLY the 256 endpoints that fail setup in the
  -- POST-SYNTHESIS report -- LAYERS*N_KVH*EXP_W = 8*4*8 = 256, the whole of
  -- `vref_r`.  No other structure in the composition reaches 28 levels; the
  -- next deepest is 20.
  --
  -- MINIMUM IS ASSOCIATIVE, COMMUTATIVE AND IDEMPOTENT ON INTEGERS, so
  -- re-bracketing it is BIT-EXACT rather than approximate: the same value, on
  -- the same clock edge, for every input.  Nothing about the seam's latency,
  -- its handshake, or the three seam rules at the head of this file changes --
  -- only the shape of the combinational cone feeding the register.
  --
  -- The array is padded to a power of two by REPEATING element 0.  A minimum
  -- is idempotent, so duplicating an element cannot change it, and padding
  -- keeps every loop bound and every index a CONSTANT EXPRESSION.  That is
  -- what makes this synthesise as a tree: an index carrying a variable offset
  -- would be built as a multiplexer instead, which is the cost this is
  -- removing rather than a way to pay it again.
  function emin_tree(v : std_logic_vector) return signed is
    constant LG : natural := clog2(NBLK);
    constant PW : natural := 2**LG;
    type ea_t is array(0 to PW-1) of signed(EXP_W-1 downto 0);
    variable a : ea_t;
  begin
    for i in 0 to PW-1 loop
      if i < NBLK then a(i) := e_of(v, i);
      else             a(i) := e_of(v, 0);
      end if;
    end loop;
    for s in 0 to LG-1 loop
      for i in 0 to 2**(LG-1-s)-1 loop
        if a(i + 2**(LG-1-s)) < a(i) then a(i) := a(i + 2**(LG-1-s)); end if;
      end loop;
    end loop;
    return a(0);
  end function;

  function all_ones(v : sl_arr) return boolean is
  begin
    for i in v'range loop
      if v(i) /= '1' then return false; end if;
    end loop;
    return true;
  end function;

  function all_zero(v : sl_arr) return boolean is
  begin
    for i in v'range loop
      if v(i) /= '0' then return false; end if;
    end loop;
    return true;
  end function;

begin

  -- Elaboration-time shape checks.  Every one of these, violated, produces
  -- silently wrong numbers rather than an error, which is why they are here
  -- and not in a comment.
  assert HEAD_DIM mod KV_BLOCK = 0
    report "attn_block: KV_BLOCK must divide HEAD_DIM, or a record block "
         & "straddles two exponents" severity failure;
  assert N_QH mod N_KVH = 0
    report "attn_block: query heads must be a whole multiple of KV heads; "
         & "that ratio IS the GQA group" severity failure;
  assert G >= 2
    report "attn_block: a GQA group of 1 gives a zero-width head index in "
         & "attn_mac_array" severity failure;
  assert NBLK >= 2
    report "attn_block: HEAD_DIM/KV_BLOCK must be at least 2" severity failure;
  assert N_ROT mod 2 = 0 and N_ROT <= HEAD_DIM
    report "attn_block: N_ROT must be even and at most HEAD_DIM"
    severity failure;
  -- kq_scale = 2^-KQ_SH is EXACT only for an even power-of-two head_dim.
  assert 2**AW_D = HEAD_DIM and AW_D mod 2 = 0
    report "attn_block: HEAD_DIM is not an even power of two, so "
         & "kq_scale = 1/sqrt(HEAD_DIM) is irrational and cannot be folded "
         & "into the exponent.  It would need a real multiply, and folding it "
         & "anyway is a silent scale error on every score."
    severity failure;

  -- ANNOUNCED AT TIME ZERO, following llama_top's "*** UNIT C IS A STUB ***"
  -- convention.  Nothing in this block is a stub -- no value is invented and
  -- no exponent is fabricated -- but ONE spec unit is absent and its absence
  -- is invisible from the port list, so it is said out loud rather than left
  -- in a header.  It deliberately does NOT raise `err`: `err` is an abort
  -- condition that D acts on, a flag every legal job asserted would be turned
  -- off within a week, and an absent AXI master is a build-time fact rather
  -- than a run-time event.
  announce : process
  begin
    report "attn_block: the KV cache is a memory PORT.  rtl/attn_kv_axi.vhd "
         & "implements the other side of it -- burst splitting, 16-byte "
         & "record phase realignment, drain-then-flush on start -- and this "
         & "block connects to it through kr_rdy / vr_rdy / kw_rdy and gates "
         & "`done` on kv_wr_idle (C spec 2.7).  All four default to '1', so "
         & "an instantiation that leaves them open still gets the old "
         & "never-refusing memory and none of those properties."
      severity note;
    wait;
  end process;

  busy        <= '0' when ph = P_IDLE else '1';
  cfg_taken   <= cfgtk_r;
  wn_taken    <= wntk_r;
  seq_rst_taken <= srtk_r;
  err         <= err_r;
  rope_sat    <= rsat_r;
  kv_sat      <= ksat_r;
  y_sat       <= ysat_r;
  z_sat       <= zsat_r;
  rescale_max <= rmax_r;
  done        <= done_r;
  dbg_ep_lost <= eplost_r;

  -- THE SWEEP PHASE DECODE.  See the port declaration for why this exists.
  -- One named code per sweep state; SWPH_NONE everywhere else.  Combinational
  -- on the already-registered `ph` and `is_byp`, so it adds no state and is
  -- trimmed wherever the port is left unassociated.
  dbg_sw_ph(4) <= is_byp;
  dbg_sw_ph(3 downto 0) <=
      SWPH_RECK   when ph = P_RECK   else
      SWPH_HDR    when ph = P_HDR    else
      SWPH_SCORE  when ph = P_SCORE  else
      SWPH_SCW    when ph = P_SCW    else
      SWPH_EPW    when ph = P_EPW    else
      SWPH_RSPASS when ph = P_RSPASS else
      SWPH_RSACK  when ph = P_RSACK  else
      SWPH_RECV   when ph = P_RECV   else
      SWPH_PV     when ph = P_PV     else
      SWPH_POSN   when ph = P_POSN   else
      SWPH_NONE;

  dbg_sw_aux(0) <= ar_prdy;
  dbg_sw_aux(1) <= ar_scv;
  dbg_sw_aux(2) <= '0' when all_zero(sq_busy) else '1';
  dbg_sw_aux(3) <= ar_pvv;

  kv_layer    <= to_unsigned(lay_r, clog2(LAYERS));
  sm_last     <= last_p;

  -- THE HELD KV READ REQUEST.  Driven concurrently from the sweep's own
  -- registers rather than inside P_RECK / P_RECV, which is what makes the
  -- request stand a STATE EARLIER than the issue and keeps it standing
  -- across P_HDR, the score, the rescale and the whole of P_RECV -- i.e.
  -- from before the first beat of a record is asked for until after the last
  -- beat of it has been captured.  `kr_rdy` is combinational in this request
  -- at the other end, so a residency answer only means anything if the
  -- question is stable, and driving it from the issue cycle would have made
  -- the answer arrive one cycle after it was needed.
  --
  -- `pos_i` is the bypass position (= cur_pos) during the first position of
  -- every head's sweep.  That is deliberately still published: the sink
  -- refuses `pos >= cur_pos` by leaving `kr_rdy` low and raises `err` only
  -- for an ENABLED read, and P_RECK never enables one while `is_byp` is set.
  -- C spec 2.4's bypass therefore stays a property of the addresses.
  --
  -- UNDER SWEEP_PIPE THE K REQUEST LEADS `pos_i` BY ONE POSITION while
  -- `pk_act` stands, and `pk_act` is cleared on the SAME EDGE at which
  -- P_POSN advances `pos_i`.  The published number therefore does not
  -- move across that edge, which is what the RESIDENCY contract needs:
  -- `kr_rdy` is combinational in the request at the other end, so a
  -- request that changed on the advance would withdraw a residency
  -- answer the sweep is about to act on.
  kr_head <= to_unsigned(kvh, AW_H);
  kr_pos  <= (pos_i + 1) when (SWEEP_PIPE and pk_act = '1') else pos_i;
  vr_head <= to_unsigned(kvh, AW_H);
  vr_pos  <= pos_i;

  -- The capture destination and the two capture indices.  With SWEEP_PIPE
  -- false these are EXACTLY the expressions the capture used inline
  -- before the generic existed (`ph /= P_RECV` and `rbi`), so the old
  -- path is unchanged rather than merely equivalent.
  cap_v  <= rbs(2) when SWEEP_PIPE else
            '1'    when ph = P_RECV else
            '0';
  cidx_k <= pk_cnt when SWEEP_PIPE else rbi;
  cidx_v <= pv_cnt when SWEEP_PIPE else rbi;

  y_valid     <= em_mv;
  y_mant      <= signed(em_md);
  y_index     <= resize(unsigned(em_mi), AW_Y);
  y_exp       <= em_yexp;
  y_hdr_valid <= em_hdrv;
  y_last      <= '1' when (em_mv = '1'
                  and unsigned(em_mi) = to_unsigned(N_KVH*GRP_N-1,
                                                    em_mi'length))
                 else '0';

  -- The array's partial stream has NO ready in the datapath, so a single head
  -- refusing loses the partial for every head.  p_ready is therefore the AND
  -- of the group, and the array asserts on it.
  ar_prdy <= '1' when all_ones(sq_prdy) else '0';

  -- ---- the scratch read ports.  Registered read WITH ENABLE, which is the
  -- contract every master unit here states: data holds mem[addr] the cycle
  -- after an edge at which the enable was high, and is HELD across any edge
  -- at which it was low.
  scr : process(clk)
  begin
    if rising_edge(clk) then
      if rp_re = '1' then vs_q <= vs(to_integer(unsigned(rp_raddr))); end if;
      if kq_re = '1' then
        -- K is quantized from the ROPED vector, V from the raw one: V is
        -- neither normed nor roped (2.1.2), and quantizing V from vs2 would
        -- silently feed it the previous K's rotation.
        if kq_isv = '1' then
          vs2_q <= vs(to_integer(unsigned(kq_raddr)));
        else
          vs2_q <= vs2(to_integer(unsigned(kq_raddr)));
        end if;
      end if;
      if em_re = '1' then
        ypre_q <= ypre(to_integer(unsigned(em_raddr)));
      end if;
    end if;
  end process;

  kq_rdata <= std_logic_vector(vs2_q);

  -- ======================= the instances =================================

  u_norm : entity work.rmsnorm_rs
    generic map ( N => HEAD_DIM, LANES => NORM_LANES, Q => Q )
    port map ( clk => clk, rst => rst, start => rn_start,
               x_mant => rn_x, x_exp => rn_xe,
               w_mant => rn_w, w_exp => rn_we,
               done => rn_done, o_mant => rn_o, o_exp => rn_oe );

  u_tw : entity work.attn_twiddle
    generic map ( NPAIR => NPAIR, TBL => TW_TBL, POS_W => POS_W,
                  Q_W => MANT_W, PHI_W => 32,
                  STRICT_PRODUCER => STRICT_PRODUCER )
    port map ( clk => clk, rst => rst, start => tw_start, pos => cpos_r,
               cfg_taken => open, busy => open,
               tw_valid => tw_valid, tw_j => open,
               tw_cos => tw_cos, tw_sin => tw_sin, tw_phi => open,
               tw_ready => tw_ready,
               done => open, done_ack => '1', err => tw_err );

  u_rope : entity work.attn_rope
    generic map ( HEAD_DIM => HEAD_DIM, N_ROT => N_ROT, MANT_W => MANT_W,
                  Q => GQ, EXP_W => EXP_W,
                  STRICT_PRODUCER => STRICT_PRODUCER )
    port map ( clk => clk, rst => rst, start => rp_start, x_exp => rp_xexp,
               cfg_taken => open, busy => open,
               x_raddr => rp_raddr, x_re => rp_re,
               x_rdata => std_logic_vector(vs_q),
               tw_valid => tw_valid, tw_cos => tw_cos, tw_sin => tw_sin,
               tw_ready => tw_ready,
               hdr_valid => open, y_exp => rp_yexp,
               y_valid => rp_yv, y_data => rp_yd, y_index => rp_yi,
               y_ready => '1',
               done => rp_done, done_ack => '1',
               rope_sat => rp_sat, err => rp_err );

  u_quant : entity work.attn_kv_quant
    generic map ( HEAD_DIM => HEAD_DIM, KV_BLOCK => KV_BLOCK,
                  IN_W => MANT_W, MANT_W => CM_W, EXP_W => EXP_W,
                  VREF_INIT => 127, STRICT_PRODUCER => STRICT_PRODUCER )
    port map ( clk => clk, rst => rst, start => kq_start, is_v => kq_isv,
               src_exp => kq_sexp, cfg_taken => open, busy => open,
               kv_seq_rst => kv_seq_rst, seq_rst_taken => open,
               x_raddr => kq_raddr, x_re => kq_re, x_rdata => kq_rdata,
               hdr_valid => kq_hdrv, e_blk => kq_eblk,
               m_valid => kq_mv, m_data => kq_md, m_index => kq_mi,
               m_ready => '1',
               done => kq_done, done_ack => '1',
               o_sat => kq_sat, err => kq_err,
               -- SEAM 2: the unit's own fold mixes the KV heads when one
               -- instance serves several, so the block folds per head instead.
               v_ref => open );

  u_arr : entity work.attn_mac_array
    generic map ( QH_TILE => G, DIM_TILE => KV_BLOCK, ACC_N => NBLK,
                  Q_W => MANT_W, K_W => CM_W, E_W => E_W, ACC_W => ACC_W,
                  P_W => P_W, Q => Q, STRICT_PRODUCER => STRICT_PRODUCER )
    port map ( clk => clk, rst => rst, acc_clr => ar_clr,
               sc_valid => ar_scv, sc_blk => ar_scb, sc_k => ar_sck,
               sc_q => ar_scq,
               p_valid => ar_pv, p_blk => open, p_data => ar_pd,
               p_ready => ar_prdy,
               pv_valid => ar_pvv, pv_blk => ar_pvb, pv_v => ar_vdat,
               pv_e => ar_pve,
               rs_valid => ar_rsv, rs_blk => ar_rsb, rs_f => ar_rsf,
               rd_valid => ar_rdv, rd_head => ar_rdh, rd_idx => ar_rdi,
               o_valid => ar_ov, o_data => ar_od,
               ovr => ar_ovr, err => ar_err );

  -- G score converters and G online softmaxes, wired DIRECTLY to each other.
  -- attn_score_q12 HOLDS s_valid until s_ready and attn_softmax lowers
  -- sc_ready for the whole rescale sequence, so refusing a score DELAYS it and
  -- never loses it.  That is the one interface in C where the handshake is a
  -- real one, and it is why nothing between them needs a buffer.
  gen_head : for gg in 0 to G-1 generate
    u_sq : entity work.attn_score_q12
      generic map ( NBLK => NBLK, P_W => P_W, EXP_W => EXP_W,
                    KQ_SHIFT => KQ_SH, QOUT => Q,
                    LSH_CLAMP => 32, RSH_CLAMP => 32,
                    STRICT_PRODUCER => STRICT_PRODUCER )
      port map ( clk => clk, rst => rst,
                 hdr_valid => sq_hdrv, e_k => khdr, q_exp => qexp_r(gg),
                 hdr_taken => sq_taken(gg), busy => sq_busy(gg),
                 p_valid => ar_pv,
                 p_data  => signed(ar_pd((gg+1)*P_W-1 downto gg*P_W)),
                 p_ready => sq_prdy(gg),
                 s_valid => sq_sv(gg), s_q12 => sq_q12(gg), s_exp => open,
                 s_sat => sq_sat(gg), s_ready => sm_scrdy(gg),
                 done => open, done_ack => '1',
                 ovr => sq_ovr(gg), err => sq_err(gg) );

    u_sm : entity work.attn_softmax
      generic map ( P_W => P_W, Q => Q, ROM_N => ROM_N, E_W => E_W,
                    S_W => S_W, STRICT_PRODUCER => STRICT_PRODUCER )
      port map ( clk => clk, rst => rst, start => sm_start,
                 cfg_taken => sm_taken(gg), busy => sm_busy(gg),
                 sc_valid => sq_sv(gg), sc_q12 => sq_q12(gg),
                 sc_last => sm_last, sc_ready => sm_scrdy(gg),
                 ep_valid => sm_epv(gg), ep => sm_ep(gg), ep_ready => '1',
                 rs_valid => sm_rsv(gg), rs_f => sm_f(gg), rs_ack => sm_rsack,
                 s_out => sm_s(gg), m_out => open, rescale_n => sm_rn(gg),
                 done => sm_done(gg), done_ack => sm_dack,
                 ovf => sm_ovf(gg), err => sm_err(gg) );
  end generate;

  u_recip : entity work.attn_recip
    generic map ( S_W => S_W, R_W => 16, R_Q => R_Q, NW => 44, DW => 28,
                  STRICT_PRODUCER => STRICT_PRODUCER )
    port map ( clk => clk, rst => rst,
               s_valid => rc_sv, s_in => rc_sin, s_last => rc_last,
               s_ready => rc_srdy, s_taken => open, busy => open,
               r_valid => rc_rv, p_out => rc_p, r_out => rc_r, r_ready => '1',
               done => open, done_ack => '1',
               err => rc_err, ovr => rc_ovr );

  u_gate : entity work.attn_gate
    generic map ( N => HEAD_DIM, O_W => ACC_W, R_W => 16,
                  P_W => clog2(S_W), G_W => MANT_W, Z_W => 32, EXP_W => EXP_W,
                  Q => Q, GQ => GQ, T_W => T_W, Y_W => Y_W, SIG_N => SIG_N,
                  LSH_CLAMP => 32, STRICT_PRODUCER => STRICT_PRODUCER )
    port map ( clk => clk, rst => rst,
               cfg_valid => gt_cfgv, p_in => gt_p, r_in => gt_r,
               qg_exp => gt_qge, cfg_ready => gt_crdy, cfg_taken => open,
               busy => gt_busy,
               x_valid => gt_xv, o_in => gt_o, g_in => gt_g,
               x_ready => gt_xrdy,
               y_valid => gt_yv, y_out => gt_y, t_out => open, g_out => open,
               y_ready => '1',
               done => gt_done, done_ack => '1',
               zsat => gt_zsat, ovr => gt_ovr, ysat => gt_ysat );

  u_emit : entity work.attn_emit
    generic map ( NGRP => N_KVH, GRP_N => GRP_N, IN_W => Y_W,
                  MANT_W => MANT_W, EXP_W => EXP_W,
                  TARGET_MSB => MANT_W-2, SH_MAX => 63,
                  STRICT_PRODUCER => STRICT_PRODUCER )
    port map ( clk => clk, rst => rst, start => em_start, e_grid => em_grid,
               cfg_taken => open, busy => open,
               x_raddr => em_raddr, x_re => em_re,
               x_rdata => std_logic_vector(ypre_q),
               hdr_valid => em_hdrv, y_exp => em_yexp,
               m_valid => em_mv, m_data => em_md, m_index => em_mi,
               m_ready => y_ready,
               done => em_done, done_ack => '1',
               o_sat => em_sat, err => em_err );

  -- ---- the array's operand buses, built combinationally ------------------
  -- sc_q is the Q register plane sliced by the block being fed; sc_k is the
  -- staged K record; pv_v is the V record after the SITE-3 alignment, which
  -- happens HERE and not in the array (see the array's header on why that
  -- boundary matters).
  ops : process(all)
    variable s  : integer;
    variable v8 : signed(CM_W-1 downto 0);
    variable neg : std_logic;
  begin
    neg := '0';
    for gg in 0 to G-1 loop
      for t in 0 to KV_BLOCK-1 loop
        ar_scq((gg*KV_BLOCK + t + 1)*MANT_W-1 downto (gg*KV_BLOCK + t)*MANT_W)
          <= qplane((gg*HEAD_DIM + opb*KV_BLOCK + t + 1)*MANT_W-1 downto
                    (gg*HEAD_DIM + opb*KV_BLOCK + t)*MANT_W);
      end loop;
      ar_pve((gg+1)*E_W-1 downto gg*E_W) <= std_logic_vector(ep_val(gg));
    end loop;
    for t in 0 to KV_BLOCK-1 loop
      ar_sck((t+1)*CM_W-1 downto t*CM_W)
        <= krec((opb*KV_BLOCK + t + 1)*CM_W-1 downto (opb*KV_BLOCK + t)*CM_W);
      -- SITE 3: v_aligned = v_mant asr (e_v[b] - v_ref).  Unconditionally a
      -- RIGHT shift because v_ref is a MINIMUM -- that is the whole reason
      -- the fold exists, and it is why the accumulator bound is 2^30 and not
      -- rev 4's 2^38.  Rev 4 printed this shift the other way round and three
      -- things in its own text contradicted it.
      s := to_integer(e_of(vhdr, opb)) - to_integer(vref_r(lay_r*N_KVH + kvh));
      if s < 0 then s := 0; neg := '1'; end if;
      if s > CM_W then s := CM_W; end if;
      v8 := signed(vrec((opb*KV_BLOCK + t + 1)*CM_W-1 downto
                        (opb*KV_BLOCK + t)*CM_W));
      ar_vdat((t+1)*CM_W-1 downto t*CM_W)
        <= std_logic_vector(shift_right(v8, s));
    end loop;
    vsh_neg <= neg;
  end process;

  -- ---- qplane, krec and vrec: the WRITE DECODE ---------------------------
  -- TRACK WRITEDEC, 2026-08-29.  These three registers used to be written from
  -- the sequencer with slice bounds containing a runtime signal, and Vivado
  -- infers each such write as a demux over the WHOLE register.  MEASURED
  -- (TRACK LUTDIET's netlist census, docs/debugging/
  -- 2026-08-29_lutdiet-flat-vector-ports.md section 5.4 and SHARES.txt):
  -- qplane 49,184 LUT, krec 14,150, vrec 11,276 -- 74,610 of the 91,396 this
  -- module spends on write demux, and 47% of the whole unit's 157,560.  None
  -- of it carries a MUXF7 or a MUXF8.
  --
  -- Each write below becomes a per-word generate with a CONSTANT slice index,
  -- enabled by the SAME condition the write sat under in the sequencer, read
  -- from the same signals.  Nothing new is registered, no pipeline stage is
  -- added and the schedule is unchanged CYCLE FOR CYCLE.
  --
  -- THE PRIORITY IS THE ORIGINAL PROCESS'S ASSIGNMENT ORDER, and it is the one
  -- part of this that is not mechanical.  Inside a process the LAST assignment
  -- on an edge wins, so for krec and vrec:
  --    the case-statement bypass write (:1398 / :1494) outranks
  --    the block collector (:1118 / :1121)  which outranks
  --    the element collector (:1104 / :1106).
  -- The if/elsif chains below are written in that order.  Whether any two of
  -- them can actually be true on one edge is NOT assumed either way; the
  -- ordering reproduces the original whether they can or not.
  --
  -- TRAP, MEASURED IN GHDL.  The slice target must be fully STATIC in the
  -- generate index.  A process creates its driver over the longest static
  -- prefix of the target, so a bound containing a for-loop variable gives
  -- every generated process a driver over the WHOLE register, they resolve
  -- against each other, and the signal simulates as 'X' -- while synthesising
  -- cleanly.  That is why vs2 is flattened by a separate concurrent generate
  -- below and handed to gqpl as one static slice.
  gv2f : for i in 0 to HEAD_DIM-1 generate
    vs2_flat((i+1)*MANT_W-1 downto i*MANT_W) <= std_logic_vector(vs2(i));
  end generate;

  gqpl : for g in 0 to G-1 generate
    process(clk) begin
      if rising_edge(clk) then
        if rst = '0' and ph = P_ROPEW and rp_dn = '1' and lsel /= 0
           and qh = g then
          qplane((g+1)*HEAD_DIM*MANT_W-1 downto g*HEAD_DIM*MANT_W) <= vs2_flat;
        end if;
      end if;
    end process;
  end generate;

  gkrec : for j in 0 to HEAD_DIM-1 generate
    process(clk) begin
      if rising_edge(clk) then
        if rst = '0' then
          if ph = P_RECK and is_byp = '1' then
            krec((j+1)*CM_W-1 downto j*CM_W)
              <= kbyp((j+1)*CM_W-1 downto j*CM_W);
          elsif rbv(2) = '1' and cap_v = '0' and cidx_k = j/KV_BLOCK then
            krec((j+1)*CM_W-1 downto j*CM_W)
              <= kr_mant((j mod KV_BLOCK + 1)*CM_W-1 downto (j mod KV_BLOCK)*CM_W);
          elsif kq_mv = '1' and kq_isv = '0'
                and to_integer(unsigned(kq_mi)) = j then
            krec((j+1)*CM_W-1 downto j*CM_W) <= kq_md;
          end if;
        end if;
      end if;
    end process;
  end generate;

  gvrec : for j in 0 to HEAD_DIM-1 generate
    process(clk) begin
      if rising_edge(clk) then
        if rst = '0' then
          if ph = P_RECV and is_byp = '1' then
            vrec((j+1)*CM_W-1 downto j*CM_W)
              <= vbyp((j+1)*CM_W-1 downto j*CM_W);
          elsif rbv(2) = '1' and cap_v = '1' and cidx_v = j/KV_BLOCK then
            vrec((j+1)*CM_W-1 downto j*CM_W)
              <= vr_mant((j mod KV_BLOCK + 1)*CM_W-1 downto (j mod KV_BLOCK)*CM_W);
          elsif kq_mv = '1' and kq_isv = '1'
                and to_integer(unsigned(kq_mi)) = j then
            vrec((j+1)*CM_W-1 downto j*CM_W) <= kq_md;
          end if;
        end if;
      end if;
    end process;
  end generate;

  -- ======================= the sequencer =================================
  process(clk)
    variable base  : integer;
    variable ev    : signed(EXP_W-1 downto 0);
    variable evh   : signed(EXP_W-1 downto 0);
    variable allep : boolean;
    variable anyrs : boolean;
    variable okrs  : boolean;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        ph <= P_IDLE;
        rn_start <= '0'; tw_start <= '0'; rp_start <= '0'; kq_start <= '0';
        ar_clr <= '0'; ar_scv <= '0'; ar_pvv <= '0'; ar_rsv <= '0';
        ar_rdv <= '0'; sq_hdrv <= '0'; sm_start <= '0'; sm_rsack <= '0';
        sm_dack <= '0'; rc_sv <= '0'; gt_cfgv <= '0'; gt_xv <= '0';
        em_start <= '0';
        se_rdy <= '0'; se_sent <= '0';
        kw_hen <= '0'; kw_en <= '0'; kr_en <= '0'; vr_en <= '0';
        qg_re <= '0'; kin_re <= '0'; vin_re <= '0';
        cfgtk_r <= '0'; wntk_r <= '0'; srtk_r <= '0';
        done_r <= '0'; err_r <= '0'; rsat_r <= '0'; ksat_r <= '0';
        ysat_r <= '0'; zsat_r <= '0'; eplost_r <= '0';
        rmax_r <= (others => '0');
        kvh <= 0; qh <= 0; li <= 0; lw <= 0; blk <= 0; rbi <= 0;
        lv <= (others => '0'); rbv <= (others => '0');
        rbs <= (others => '0');
        pk_en <= '0'; pk_blk <= 0; pk_cnt <= 0; pk_got <= '0'; pk_act <= '0';
        pk_pend <= '0';
        pv_en <= '0'; pv_blk <= 0; pv_cnt <= 0; pv_got <= '0';
        gi <= 0; ypre_wi <= 0; opb <= 0;
        ep_have <= (others => '0'); rs_have <= (others => '0');
        rn_dn <= '0'; rp_dn <= '0'; kq_dn <= '0'; gt_dn <= '0';
        em_dn <= '0'; rc_dn <= '0';
        vref_r <= (others => to_signed(127, EXP_W));
        seqrst_q <= '0';
      else
        -- one-cycle strobes
        rn_start <= '0'; tw_start <= '0'; rp_start <= '0'; kq_start <= '0';
        ar_clr <= '0'; ar_scv <= '0'; ar_pvv <= '0'; ar_rsv <= '0';
        ar_rdv <= '0'; sm_start <= '0'; sm_rsack <= '0'; sm_dack <= '0';
        rc_sv <= '0'; gt_cfgv <= '0'; em_start <= '0';
        kw_hen <= '0'; kw_en <= '0'; kr_en <= '0'; vr_en <= '0';
        qg_re <= '0'; kin_re <= '0'; vin_re <= '0';
        cfgtk_r <= '0'; wntk_r <= '0'; srtk_r <= '0';

        -- ---- the per-SEQUENCE v_ref reset (SEAM 2) --------------------
        seqrst_q <= kv_seq_rst;
        if kv_seq_rst = '1' and seqrst_q = '0' then
          vref_r <= (others => to_signed(127, EXP_W));
          srtk_r <= '1';
        end if;

        -- ---- always-on collectors ------------------------------------
        if rn_done = '1' then rn_dn <= '1'; end if;
        if rp_done = '1' then rp_dn <= '1'; end if;
        if kq_done = '1' then kq_dn <= '1'; end if;
        if gt_done = '1' then gt_dn <= '1'; end if;
        if em_done = '1' then em_dn <= '1'; end if;
        if rc_rv   = '1' then rc_dn <= '1'; rc_pq <= rc_p; rc_rq <= rc_r; end if;

        if rp_sat  = '1' then rsat_r <= '1'; end if;
        if kq_sat  = '1' then ksat_r <= '1'; end if;
        if em_sat  = '1' then ysat_r <= '1'; end if;
        if gt_zsat = '1' then zsat_r <= '1'; end if;
        if rp_err = '1' or kq_err = '1' or tw_err = '1' or em_err = '1'
           or rc_err = '1' or rc_ovr = '1' or gt_ovr = '1' or gt_ysat = '1'
           or ar_err = '1' or ar_ovr = '1' then
          err_r <= '1';
        end if;
        for gg in 0 to G-1 loop
          if sq_ovr(gg) = '1' or sq_err(gg) = '1'
             or sm_ovf(gg) = '1' or sm_err(gg) = '1' then
            err_r <= '1';
          end if;
        end loop;

        -- the source load capture, one cycle behind its issue
        lv(1) <= '0';
        lv(2) <= lv(1);
        lsel_q <= lsel;
        if lv(2) = '1' then
          case lsel_q is
            when 0 => vs(lw) <= kin_rdata;
            when 1 => vs(lw) <= vin_rdata;
            when others => vs(lw) <= qg_rdata;
          end case;
          lw <= lw + 1;
        end if;

        -- the rope output stream, straight into vs2 at ITS OWN index
        if rp_yv = '1' then
          vs2(to_integer(rp_yi)) <= rp_yd;
        end if;

        -- the quantizer's record.  hdr_valid lands strictly before the first
        -- mantissa, which is the order the read side needs.
        --
        -- DEFECT 1, found 2026-08-28 by ref/attn_block_vec.c and fixed here.
        -- attn_kv_quant's `hdr_valid` is a LEVEL, not a pulse: hdr_r is raised
        -- when the last block exponent settles and is cleared only at the next
        -- `start` (rtl/attn_kv_quant.vhd:572 against :432).  Unguarded, this
        -- capture therefore re-executed on EVERY CYCLE of the whole sweep with
        -- kq_isv still '1' from the V quantization, and it sits EARLIER in this
        -- process than the cache-read capture below -- so `vhdr <= vr_hdr` won
        -- for the one cycle it ran and was overwritten by the CURRENT token's
        -- V header on the very next one.  By the time P_PV built its operands,
        -- every cached position's V block exponents had been replaced by the
        -- current record's, so the site-3 alignment shift e_v[b] - v_ref came
        -- out as 0 for every earlier token instead of its true value: every
        -- cached V was attended at up to 2^8 times its real magnitude.
        --
        -- Nothing structural could see it.  The mantissas were right, the
        -- record lengths were right, the exponents were legal int8s, `err`
        -- stayed clear, and the SHIFT stayed non-negative so `vsh_neg` never
        -- fired.  All seven of tb_attn_block's structural properties passed --
        -- including P5, because the substituted header moves with vin_exp
        -- exactly as the real one does.  It took a value oracle.
        --
        -- The phase gate is the fix rather than an edge detector because the
        -- quantizer is the ONLY producer of these two registers and P_KQW /
        -- P_VQW are the only states in which it runs, so the guard states the
        -- contract instead of re-deriving it from a waveform.
        if kq_hdrv = '1' and (ph = P_KQW or ph = P_VQW) then
          if kq_isv = '1' then vhdr <= kq_eblk; else khdr <= kq_eblk; end if;
        end if;
        -- the per-element krec/vrec write has moved to the gkrec / gvrec
        -- generates above, under this exact condition.

        -- the KV record read, one cycle behind its issue.  The destination is
        -- decided by the STATE, and the state cannot advance until rbi = NBLK,
        -- so no capture ever lands after the state has moved on.
        rbv(1) <= '0';
        rbv(2) <= rbv(1);
        rbs(1) <= '0';
        rbs(2) <= rbs(1);
        if rbv(2) = '1' then
          -- the per-block krec/vrec write has moved to the gkrec / gvrec
          -- generates above, under this exact condition; only the header and
          -- the pointer remain here.
          if cap_v = '1' then
            vhdr <= vr_hdr;
            if SWEEP_PIPE then
              pv_cnt <= pv_cnt + 1;
              if pv_cnt = NBLK-1 then pv_got <= '1'; end if;
            end if;
          else
            khdr <= kr_hdr;
            if SWEEP_PIPE then
              pk_cnt <= pk_cnt + 1;
              if pk_cnt = NBLK-1 then pk_got <= '1'; end if;
            end if;
            -- ==========================================================
            -- SCORE_EARLY.  The header is complete on the FIRST captured
            -- beat, so arm the hand-over here rather than after the whole
            -- record.  `se_rdy` is set on the first beat and on no other,
            -- because it must not re-arm behind a hand-over that has
            -- already happened for this record.
            --
            -- AND THE ASSUMPTION IT RESTS ON IS CHECKED, NOT ASSUMED.
            -- The old path read `khdr` only after beat NBLK-1, so it was
            -- indifferent to whether `kr_hdr` was the same on every beat
            -- of a record; this path is not.  Both producers stand it for
            -- the life of a record -- rtl/attn_kv_axi.vhd replays the
            -- record's header chunk with every beat, and the model in
            -- sim/tb_attn_block.vhd does the same -- and the assert below
            -- is what makes that a checked property of the CONNECTION
            -- rather than a reading of two files.  A producer that
            -- changed the header mid-record would otherwise align this
            -- position's partials on another record's e_min, which is
            -- exactly the 2026-08-28 vhdr defect in a new place: in
            -- range, plausible, and wrong by a power of two.
            if SCORE_EARLY then
              if (SWEEP_PIPE and pk_cnt = 0) or ((not SWEEP_PIPE) and rbi = 0)
              then
                se_rdy <= '1';
              else
                assert kr_hdr = khdr
                  report "attn_block: SCORE_EARLY -- kr_hdr changed inside a "
                       & "K record.  The header handed to attn_score_q12 on "
                       & "beat 0 is not the one this record's mantissas "
                       & "belong to, so e_min and every alignment shift are "
                       & "taken from the wrong record."
                  severity failure;
              end if;
            end if;
          end if;
          -- `rbi` is the OLD path's capture counter and is reset by the
          -- states that own it (P_EPW and P_POSN).  Under SWEEP_PIPE two
          -- records can be captured between those resets, so incrementing
          -- it here runs it past its `0 to NBLK` range -- MEASURED as
          -- `bound check failure at rtl/attn_block.vhd:1318` on the first
          -- SWEEP_PIPE run of sim/tb_attn_block.  It is dead in that mode,
          -- so it is simply not counted.
          if not SWEEP_PIPE then
            rbi <= rbi + 1;
          end if;
        end if;

        -- ================================================================
        -- SWEEP_PIPE: THE RECORD FETCH ENGINE.
        --
        -- It issues beats for whichever stream is armed, one per cycle
        -- while that stream's `_rdy` stands, and it runs regardless of
        -- `ph`.  That is the whole of the change: the beats themselves
        -- are identical, the ORDER of the beats within a record is
        -- identical, and only WHEN they are issued moves.
        --
        -- THE TWO STREAMS NEVER ISSUE IN THE SAME CYCLE, and the assert
        -- below is what makes that a checked property rather than a
        -- reading of the schedule.  `rbv` / `rbs` are ONE two-deep pipe,
        -- so a simultaneous issue would silently give one stream's beat
        -- to the other register -- exactly the failure mode that the
        -- `ph`-based destination had.
        -- ================================================================
        if SWEEP_PIPE then
          assert not (pk_en = '1' and kr_rdy = '1'
                      and pv_en = '1' and vr_rdy = '1')
            report "attn_block: SWEEP_PIPE issued a K beat and a V beat in "
                 & "the same cycle; rbv/rbs is one pipe and one of the two "
                 & "beats would land in the wrong record"
            severity failure;
          if pk_en = '1' and kr_rdy = '1' then
            kr_en  <= '1';
            kr_blk <= to_unsigned(pk_blk, AW_B);
            rbv(1) <= '1';
            rbs(1) <= '0';
            if pk_blk = NBLK-1 then pk_en <= '0';
            else pk_blk <= pk_blk + 1; end if;
          elsif pv_en = '1' and vr_rdy = '1' then
            vr_en  <= '1';
            vr_blk <= to_unsigned(pv_blk, AW_B);
            rbv(1) <= '1';
            rbs(1) <= '1';
            if pv_blk = NBLK-1 then pv_en <= '0';
            else pv_blk <= pv_blk + 1; end if;
          end if;
        end if;

        -- SEAM 5: e_p has no ready.  Latch it, and notice a lost one.
        for gg in 0 to G-1 loop
          if sm_epv(gg) = '1' then
            if ep_have(gg) = '1' then eplost_r <= '1'; end if;
            ep_val(gg)  <= sm_ep(gg);
            ep_have(gg) <= '1';
          end if;
          -- DEFECT 2, found 2026-08-28 by ref/attn_block_vec.c and fixed here.
          -- `sm_rsack = '0'` is load-bearing.  attn_softmax holds rs_valid
          -- until the ack and drops it on the edge AFTER the ack is presented
          -- (rtl/attn_softmax.vhd:612) -- which is the correct handshake and
          -- not a fault there.  P_RSACK clears rs_have in the same edge that
          -- raises sm_rsack, so without this guard the collector, which runs
          -- unconditionally and EARLIER in this process than the case
          -- statement, re-latched rs_have from the still-standing rs_valid on
          -- the ack cycle.  The risen head has produced no e_p yet at that
          -- instant, so P_EPW then saw anyrs and okrs again and ran a SECOND
          -- uniform rescale pass: every accumulator in the group was
          -- multiplied by f TWICE per rise, once for real and once for the
          -- handshake.
          --
          -- It was invisible to everything that existed.  `s` is rescaled
          -- inside attn_softmax and is rescaled exactly once, so the
          -- denominator was right; only the numerators were small by a factor
          -- of f per rise, which is a data-dependent value in (0, 1] and never
          -- leaves a range.  `rescale_max` counts the SOFTMAX's rises, not the
          -- array's passes, so it read correctly too.
          if sm_rsv(gg) = '1' and sm_rsack = '0' then
            rs_val(gg)  <= sm_f(gg);
            rs_have(gg) <= '1';
          end if;
        end loop;

        -- the gate output stream into the y_pre scratch
        if gt_yv = '1' then
          ypre(ypre_wi) <= gt_y;
          ypre_wi <= ypre_wi + 1;
        end if;

        -- ---- the phase machine ----------------------------------------
        case ph is

          when P_IDLE =>
            if start = '1' then
              -- RULE 2.  llama_top's defect 1 is this same shape one level up:
              -- a unit that reads a descriptor live latches the PREVIOUS job's
              -- shape for the tail of this one, and nothing else.
              lay_r  <= layer;
              cpos_r <= cur_pos;
              clen_r <= ctx_len;
              qnm_r  <= qn_mant; qne_r <= qn_exp;
              knm_r  <= kn_mant; kne_r <= kn_exp;
              qge_r  <= qg_exp;  kie_r <= kin_exp; vie_r <= vin_exp;
              cfgtk_r <= '1';
              wntk_r  <= '1';
              err_r <= '0'; rsat_r <= '0'; ksat_r <= '0';
              ysat_r <= '0'; zsat_r <= '0'; eplost_r <= '0';
              rmax_r <= (others => '0');
              done_r <= '0';
              kvh <= 0; qh <= 0; ypre_wi <= 0;
              -- C spec 3.9: the job-level range checks, at start, before any
              -- state write.  A bad descriptor aborts and `done` still
              -- asserts, so D's FSM cannot hang.
              if cur_pos >= ctx_len then
                err_r <= '1';
                ph <= P_DONE;
              else
                li <= 0; lw <= 0; lsel <= 0;
                ph <= P_KLOAD;
              end if;
            end if;

          -- ---- load one head vector into vs ---------------------------
          when P_KLOAD =>
            if li < HEAD_DIM then
              case lsel is
                when 0 =>
                  kin_raddr <= to_unsigned(kvh*HEAD_DIM + li,
                                           clog2(HEAD_DIM*N_KVH));
                  kin_re <= '1';
                when 1 =>
                  vin_raddr <= to_unsigned(kvh*HEAD_DIM + li,
                                           clog2(HEAD_DIM*N_KVH));
                  vin_re <= '1';
                when others =>
                  -- 1.1(a): Q of head qh is at 2*HEAD_DIM*qh and its GATE at
                  -- 2*HEAD_DIM*qh + HEAD_DIM.  A half/half assumption
                  -- produces plausible garbage rather than an obvious failure.
                  qg_raddr <= to_unsigned(2*HEAD_DIM*(kvh*G + qh) + li,
                                          clog2(2*HEAD_DIM*N_QH));
                  qg_re <= '1';
              end case;
              lv(1) <= '1';
              li <= li + 1;
            elsif lw = HEAD_DIM then
              if lsel = 1 then
                ph <= P_VQGO;          -- V takes neither norm nor rope
              else
                ph <= P_NORMGO;
              end if;
            end if;

          when P_NORMGO =>
            for i in 0 to HEAD_DIM-1 loop
              rn_x((i+1)*MANT_W-1 downto i*MANT_W) <= std_logic_vector(vs(i));
            end loop;
            if lsel = 0 then
              rn_w <= knm_r; rn_we <= to_integer(kne_r);
              rn_xe <= to_integer(kie_r);
            else
              rn_w <= qnm_r; rn_we <= to_integer(qne_r);
              rn_xe <= to_integer(qge_r);
            end if;
            rn_dn <= '0';
            rn_start <= '1';
            ph <= P_NORMW;

          when P_NORMW =>
            if rn_dn = '1' then
              for i in 0 to HEAD_DIM-1 loop
                vs(i) <= signed(rn_o((i+1)*MANT_W-1 downto i*MANT_W));
              end loop;
              -- SEAM 3 plus the 2.1.5 range check.  o_exp is an unbounded
              -- integer and every port downstream carries int8; out of range
              -- is an abort, never a wrap.
              if rn_oe > 127 or rn_oe < -128 then
                err_r <= '1';
                ph <= P_DONE;
              else
                rp_xexp <= to_signed(rn_oe, EXP_W);
                if lsel = 2 then qexp_r(qh) <= to_signed(rn_oe, EXP_W); end if;
                ph <= P_ROPEGO;
              end if;
            end if;

          -- One twiddle run per rope invocation.  The twiddle producer HOLDS
          -- its first pair, which attn_rope's own out-of-window guard is
          -- written to tolerate (it excludes S_HDR for exactly this reason).
          when P_ROPEGO =>
            rp_dn <= '0';
            rp_start <= '1';
            tw_start <= '1';
            ph <= P_ROPEW;

          when P_ROPEW =>
            if rp_dn = '1' then
              if lsel = 0 then
                kq_sexp <= rp_yexp;
                kq_isv  <= '0';
                ph <= P_KQGO;
              else
                -- the qplane write has moved to the gqpl generate above,
                -- under this exact condition
                ph <= P_QN;
              end if;
            end if;

          when P_KQGO =>
            kq_dn <= '0';
            kq_start <= '1';
            blk <= 0;
            ph <= P_KQW;

          -- `kw_rdy` gates the HEADER and not just the mantissas, because
          -- the sink takes the record header first and drops it silently if
          -- its buffer is occupied -- and a dropped header makes every
          -- following kw_en a no-op as well, so the whole record vanishes.
          when P_KQW =>
            if kq_dn = '1' and kw_rdy = '1' then
              kbyp <= krec;
              kbh  <= khdr;
              -- HEADER FIRST, then the mantissa blocks.  The record layout is
              -- 8 B of exponents ahead of 256 B of mantissas precisely so a
              -- reader knows e_min before the first partial arrives, and a
              -- writer that reversed the order would make that impossible
              -- while writing a byte-identical record.
              kw_sel  <= '0';
              kw_head <= to_unsigned(kvh, AW_H);
              kw_pos  <= cpos_r;
              kw_hdr  <= khdr;
              kw_hen  <= '1';
              wr_isv  <= '0';
              blk <= 0;
              ph <= P_WREC;
            end if;

          when P_VQGO =>
            kq_sexp <= vie_r;            -- v_norm_exp = v_exp, 2.1.2
            kq_isv  <= '1';
            kq_dn <= '0';
            kq_start <= '1';
            ph <= P_VQW;

          when P_VQW =>
            if kq_dn = '1' and kw_rdy = '1' then
              vbyp <= vrec;
              vbh  <= vhdr;
              kw_sel  <= '1';
              kw_head <= to_unsigned(kvh, AW_H);
              kw_pos  <= cpos_r;
              kw_hdr  <= vhdr;
              kw_hen  <= '1';
              -- SEAM 2: the per-head write-time min fold.
              --
              -- REASSOCIATED 2026-08-30 (TRACK TIMING), and BIT-EXACT: see
              -- emin_tree above for why re-bracketing a minimum cannot change
              -- its value.  `vref_r` is folded in LAST rather than seeding the
              -- chain, so the tree over the header's NBLK exponents depends
              -- only on `vhdr` and the vref_r -> vref_r cone shrinks to the
              -- read multiplexer, ONE compare, and the write.  It was:
              --
              --     ev := vref_r(lay_r*N_KVH + kvh);
              --     for b in 0 to NBLK-1 loop
              --       if e_of(vhdr, b) < ev then ev := e_of(vhdr, b); end if;
              --     end loop;
              --     vref_r(lay_r*N_KVH + kvh) <= ev;
              evh := emin_tree(vhdr);
              ev  := vref_r(lay_r*N_KVH + kvh);
              if evh < ev then ev := evh; end if;
              vref_r(lay_r*N_KVH + kvh) <= ev;
              wr_isv <= '1';
              blk <= 0;
              ph <= P_WREC;
            end if;

          when P_WREC =>
            if blk < NBLK then
              if kw_rdy = '1' then
                kw_en  <= '1';
                kw_blk <= to_unsigned(blk, AW_B);
                if wr_isv = '1' then
                  kw_mant <= vrec((blk+1)*KV_BLOCK*CM_W-1 downto
                                  blk*KV_BLOCK*CM_W);
                else
                  kw_mant <= krec((blk+1)*KV_BLOCK*CM_W-1 downto
                                  blk*KV_BLOCK*CM_W);
                end if;
                blk <= blk + 1;
              end if;
            else
              li <= 0; lw <= 0; qh <= 0;
              if wr_isv = '1' then
                lsel <= 2;              -- V is written; the Q heads are next
              else
                lsel <= 1;              -- K is written; V is next
              end if;
              ph <= P_KLOAD;
            end if;

          when P_QN =>
            if qh = G-1 then
              ph <= P_SWGO;
            else
              qh <= qh + 1;
              li <= 0; lw <= 0; lsel <= 2;
              ph <= P_KLOAD;
            end if;

          -- ---- the sweep.  PROCESSING ORDER IS PART OF THE NUMERIC
          -- CONTRACT: [cur_pos, 0, 1, ..., cur_pos-1], the bypass position
          -- first, then the cache in ascending order (C spec 3.1).
          when P_SWGO =>
            ar_clr   <= '1';
            sm_start <= '1';
            pos_i    <= cpos_r;
            is_byp   <= '1';
            if cpos_r = 0 then last_p <= '1'; else last_p <= '0'; end if;
            ep_have <= (others => '0');
            rs_have <= (others => '0');
            rbi <= 0; blk <= 0;
            -- A new head's sweep starts at the bypass position, so nothing
            -- is in flight and nothing is held: clear the whole prefetch
            -- state rather than relying on the previous head having left
            -- it clean.
            pk_en <= '0'; pk_got <= '0'; pk_act <= '0'; pk_pend <= '0';
            pv_en <= '0'; pv_got <= '0';
            -- and the SCORE_EARLY hand-over with it, for the same reason.
            -- The bypass position reads no record, so it must go down
            -- P_HDR's old path; a stale `se_sent` left by the previous
            -- head would make it skip a header it never sent.
            se_rdy <= '0'; se_sent <= '0';
            ph <= P_RECK;

          -- THE SEAM.  `kr_rdy` is the whole of the change on the read side:
          -- the issue is still one beat per cycle and the capture is still a
          -- fixed two cycles behind it, but a beat is only issued while the
          -- cache says the record named by the HELD request is resident.  The
          -- request itself is driven concurrently from `kvh` / `pos_i` below,
          -- which is what makes it stand a state earlier than this one and
          -- keeps standing until P_POSN moves `pos_i`.
          -- ================================================================
          -- SWEEP_PIPE, AND THE MEASUREMENT THAT MOTIVATES IT.
          --
          -- MEASURED 2026-09-20, sim/tb_csweep_rate.vhd at the real 9B
          -- geometry with RD_LAT 100: one position of one KV head costs
          -- 87.42 cycles, of which
          --
          --     7.00  the 8 K beats            (KSPAN)
          --    56.42  P_HDR + P_SCORE + the score drain and the softmax
          --     7.00  the 8 V beats            (VSPAN)
          --    17.00  P_PV, P_POSN and the two record tails
          --
          -- and `kr_rdy` / `vr_rdy` are low for ZERO cycles inside a
          -- record at every position.  Replacing `attn_kv_axi` with a
          -- memory that cannot refuse reproduces all four numbers to the
          -- integer, so the cache contributes nothing to the slope: the
          -- per-position cost is THIS state machine, and the 16 beats of
          -- actual data movement are 16 percent of it.
          --
          -- What SWEEP_PIPE changes, and it is only WHEN a beat is
          -- issued:
          --
          --   * the V record of THIS position is fetched while the score
          --     and the softmax drain, instead of after them.  `vrec` is
          --     not read until P_PV, so the record may arrive any time
          --     before it.
          --   * the K record of the NEXT position is fetched during P_PV
          --     and P_POSN.  `krec` is read only by P_SCORE, which for
          --     this position is already over, and the quantizer -- the
          --     only other writer of `krec` -- runs in P_KQW / P_VQW,
          --     which are earlier in the job and cannot be concurrent
          --     with the sweep.  So no double buffer is needed and none
          --     is added.
          --
          -- NOT changed: the beats, their order within a record, the
          -- capture, the arithmetic, or any handshake.  A beat is still
          -- issued only while that stream's `_rdy` stands.
          -- ================================================================
          when P_RECK =>
            if is_byp = '1' then
              -- krec <= kbyp has moved to the gkrec generate above
              khdr <= kbh;
              ph <= P_HDR;
            elsif SWEEP_PIPE then
              -- The record is either already here (P_PV of the previous
              -- position fetched it) or this is the first position of the
              -- head's sweep, in which case nothing has been armed and
              -- this state arms it for `pos_i` itself.
              if pk_got = '1' then
                pk_got <= '0'; pk_pend <= '0';
                -- arm the V record of THIS position, to be fetched while
                -- the score and the softmax drain
                pv_en  <= '1'; pv_blk <= 0; pv_cnt <= 0; pv_got <= '0';
                ph <= P_HDR;
              elsif pk_pend = '0' then
                pk_en <= '1'; pk_blk <= 0; pk_cnt <= 0; pk_pend <= '1';
              end if;
            elsif blk < NBLK then
              if kr_rdy = '1' then
                kr_en   <= '1';
                kr_blk  <= to_unsigned(blk, AW_B);
                rbv(1)  <= '1';
                blk <= blk + 1;
              end if;
            elsif rbi = NBLK then
              ph <= P_HDR;
            end if;

          -- The header must STAND before the first partial.  That is what
          -- lets attn_score_q12 know e_min with no buffer for the partials,
          -- and it is the ORDERING RULE expressed as a phase.
          -- ================================================================
          -- SCORE_EARLY.  With the generic false this state is exactly what
          -- it was: raise the header, wait for every score unit to take it.
          -- With it true the hand-over has normally already happened, under
          -- the K fetch (SWEEP_PIPE false) or under the previous position's
          -- PV (SWEEP_PIPE true), and this state is one cycle.
          --
          -- THE FALLBACK IS NOT DEAD CODE AND MUST STAY.  `se_sent` is
          -- clear for the BYPASS position at every head -- it reads no
          -- record, so no capture ever arms `se_rdy` -- and it is clear
          -- whenever the arm below has not finished.  Both go down the old
          -- path, which is why this generic cannot change the order in
          -- which any score unit sees its header.
          -- ================================================================
          when P_HDR =>
            -- A HEADER NOT HANDED OVER EARLY IS NOT HANDED OVER LATE, and
            -- this one line is what makes that structural instead of a
            -- timing coincidence.  `se_rdy` is a LEVEL.  If the arm has not
            -- consumed it by the time this state runs, the early path has
            -- missed its window for THIS position -- and without this clear
            -- the arm simply fires later, at P_EPW, where the score units
            -- next go idle.  That hand-over carries the header of the
            -- position just FINISHED and sets `se_sent`, so the NEXT
            -- position's P_HDR skips on it and scores against the wrong
            -- e_min.
            --
            -- MEASURED, and it is why the line exists: mutants E6 and E7 of
            -- sim/mutate_attn_score_early.sh delay the arm in two different
            -- ways, and BOTH were KILLED by ref/attn_block_seq_vec.c before
            -- this clear was added.  Both were WRITTEN as pure schedule
            -- changes that a value oracle should not be able to see, and
            -- the oracle saw them, which is the tell that the delay was not
            -- schedule-only at all.
            if SCORE_EARLY then se_rdy <= '0'; end if;
            if SCORE_EARLY and se_sent = '1' then
              se_sent <= '0';
              blk <= 0;
              ph <= P_SCORE;
            else
              sq_hdrv <= '1';
              if all_ones(sq_taken) then
                sq_hdrv <= '0';
                blk <= 0;
                ph <= P_SCORE;
              end if;
            end if;

          when P_SCORE =>
            if blk < NBLK then
              if ar_prdy = '1' then
                ar_scv <= '1';
                ar_scb <= to_unsigned(blk, AW_B);
                opb    <= blk;
                blk <= blk + 1;
              end if;
            else
              ph <= P_SCW;
            end if;

          when P_SCW =>
            if all_zero(sq_busy) then
              ph <= P_EPW;
            end if;

          -- SEAM 4: wait until every head has either produced its e_p or
          -- raised rs_valid.  A head that rescales produces no e_p until it
          -- is acked, so this condition is reachable and stable.
          when P_EPW =>
            allep := true; anyrs := false; okrs := true;
            for gg in 0 to G-1 loop
              if ep_have(gg) = '0' then allep := false; end if;
              if rs_have(gg) = '1' then anyrs := true; end if;
              if ep_have(gg) = '0' and rs_have(gg) = '0' then okrs := false; end if;
            end loop;
            if allep then
              blk <= 0; rbi <= 0;
              ph <= P_RECV;
            elsif anyrs and okrs then
              -- Heads that did not rise ride the same pass with f = 2^Q,
              -- which site 5d makes an EXACT identity.  That is what makes a
              -- uniform pass legal and removes all per-head masking.
              for gg in 0 to G-1 loop
                if rs_have(gg) = '1' then
                  ar_rsf((gg+1)*E_W-1 downto gg*E_W)
                    <= std_logic_vector(rs_val(gg));
                else
                  ar_rsf((gg+1)*E_W-1 downto gg*E_W)
                    <= std_logic_vector(to_unsigned(2**Q, E_W));
                end if;
              end loop;
              blk <= 0;
              ph <= P_RSPASS;
            end if;

          when P_RSPASS =>
            if blk < NBLK then
              ar_rsv <= '1';
              ar_rsb <= to_unsigned(blk, AW_B);
              blk <= blk + 1;
            else
              blk <= 0;
              ph <= P_RSACK;
            end if;

          when P_RSACK =>
            -- Drain before the ack, so no e_p can reach the array while a
            -- rescale write is still in flight.  The array's own index-aware
            -- assertion is what enforces it rather than this comment.
            if blk < 3 then
              blk <= blk + 1;
            else
              sm_rsack <= '1';
              rs_have  <= (others => '0');
              ph <= P_EPW;
            end if;

          when P_RECV =>
            if is_byp = '1' then
              -- vrec <= vbyp has moved to the gvrec generate above
              vhdr <= vbh;
              blk <= 0;
              ph <= P_PV;
            elsif SWEEP_PIPE then
              -- The V record was fetched during the score drain.  Arm the
              -- NEXT position's K record here rather than in P_PV so that
              -- it overlaps P_PV's eight write-backs as well as P_POSN's
              -- drain; `krec` is free from this instant because P_SCORE is
              -- over.  `last_p` is already decided for this position, and
              -- when it is clear P_POSN's own rule guarantees
              -- `pos_i + 2 < cur_pos`, so the prefetched position is inside
              -- the readable range and the cache's `pos >= cur_pos` refusal
              -- is never reached by it.
              if pv_got = '1' then
                pv_got <= '0';
                if last_p = '0' then
                  pk_act <= '1'; pk_pend <= '1';
                  pk_en  <= '1'; pk_blk <= 0; pk_cnt <= 0; pk_got <= '0';
                end if;
                blk <= 0;
                ph <= P_PV;
              end if;
            elsif blk < NBLK then
              if vr_rdy = '1' then
                vr_en   <= '1';
                vr_blk  <= to_unsigned(blk, AW_B);
                rbv(1)  <= '1';
                blk <= blk + 1;
              end if;
            elsif rbi = NBLK then
              blk <= 0;
              ph <= P_PV;
            end if;

          when P_PV =>
            if vsh_neg = '1' then err_r <= '1'; end if;
            if blk < NBLK then
              ar_pvv <= '1';
              ar_pvb <= to_unsigned(blk, AW_B);
              opb    <= blk;
              blk <= blk + 1;
            else
              blk <= 0;
              ep_have <= (others => '0');
              ph <= P_POSN;
            end if;

          when P_POSN =>
            if blk < 3 then                  -- let the PV write-backs land
              blk <= blk + 1;
            elsif last_p = '1' then
              ph <= P_SFW;
            else
              if is_byp = '1' then
                pos_i  <= (others => '0');
                is_byp <= '0';
                if cpos_r = 1 then last_p <= '1'; else last_p <= '0'; end if;
              else
                pos_i <= pos_i + 1;
                if (pos_i + 2) = cpos_r then last_p <= '1';
                else last_p <= '0'; end if;
                -- The K request stops leading on the SAME EDGE at which
                -- `pos_i` catches up with it, so the published number does
                -- not move; see the note at `kr_pos`.
                pk_act <= '0';
              end if;
              blk <= 0; rbi <= 0;
              ph <= P_RECK;
            end if;

          when P_SFW =>
            if all_ones(sm_done) then
              for gg in 0 to G-1 loop
                if sm_rn(gg) > rmax_r then rmax_r <= sm_rn(gg); end if;
              end loop;
              qh <= 0;
              ph <= P_RCP;
            end if;

          -- ---- the output stage, per query head -----------------------
          when P_RCP =>
            if rc_srdy = '1' then
              rc_sin  <= sm_s(qh);
              if kvh = N_KVH-1 and qh = G-1 then rc_last <= '1';
              else rc_last <= '0'; end if;
              rc_dn <= '0';
              rc_sv <= '1';
              ph <= P_RCW;
            end if;

          when P_RCW =>
            if rc_dn = '1' then
              gt_p   <= rc_pq;
              gt_r   <= rc_rq;
              gt_qge <= qge_r;
              ph <= P_GATEGO;
            end if;

          when P_GATEGO =>
            if gt_crdy = '1' then
              gt_cfgv <= '1';
              gt_dn <= '0';
              gi <= 0;
              ph <= P_GAT1;
            end if;

          -- One element per cycle would need the gate's x_ready two cycles
          -- ahead of the read it gates.  This walks it instead: issue, wait
          -- for the two one-cycle reads, present, wait for the accept.  Four
          -- cycles per element against a possible one.  It is slow and it is
          -- safe, and the fast form is a new seam of exactly the class that
          -- lost gdn_head_emit an entire head.
          when P_GAT1 =>
            ar_rdv <= '1';
            ar_rdh <= to_unsigned(qh, AW_G);
            ar_rdi <= to_unsigned(gi, clog2(NBLK*KV_BLOCK));
            qg_raddr <= to_unsigned(2*HEAD_DIM*(kvh*G + qh) + HEAD_DIM + gi,
                                    clog2(2*HEAD_DIM*N_QH));
            qg_re <= '1';
            ph <= P_GAT2;

          when P_GAT2 =>
            ph <= P_GAT3;

          when P_GAT3 =>
            gt_o  <= ar_od;
            gt_g  <= qg_rdata;
            gt_xv <= '1';
            ph <= P_GAT4;

          when P_GAT4 =>
            if gt_xrdy = '1' then
              gt_xv <= '0';
              if gi = HEAD_DIM-1 then
                ph <= P_GATEW;
              else
                gi <= gi + 1;
                ph <= P_GAT1;
              end if;
            end if;

          when P_GATEW =>
            if gt_dn = '1' then
              ph <= P_GN;
            end if;

          when P_GN =>
            if qh = G-1 then
              ph <= P_HN;
            else
              qh <= qh + 1;
              ph <= P_RCP;
            end if;

          when P_HN =>
            -- The group's softmaxes are acked HERE and not at P_SFW, because
            -- s_out is only specified valid from `done` to the next `start`
            -- and the output stage reads it the whole way through.
            sm_dack <= '1';
            if kvh = N_KVH-1 then
              -- Site 6f: the two grids the card's heads sit on.  value =
              -- t * 2^-(v_ref + R_Q - 1), so the grid is v_ref + 14 at Q15.
              for h in 0 to N_KVH-1 loop
                em_grid((h+1)*EXP_W-1 downto h*EXP_W)
                  <= std_logic_vector(vref_r(lay_r*N_KVH + h)
                                      + to_signed(R_Q-1, EXP_W));
              end loop;
              ph <= P_EMITGO;
            else
              kvh <= kvh + 1;
              li <= 0; lw <= 0; lsel <= 0; qh <= 0;
              ph <= P_KLOAD;
            end if;

          when P_EMITGO =>
            em_dn <= '0';
            em_start <= '1';
            ph <= P_EMITW;

          when P_EMITW =>
            if em_dn = '1' then
              ph <= P_DONE;
            end if;

          -- RULE 1: done is HELD until acked, never pulsed.  C spec 2.7:
          -- it must also not assert until this job's KV writes have retired
          -- their BRESP, because token T+1 reads them through a DIFFERENT
          -- master.  `kv_wr_idle` is that term and it is an input, not a
          -- derivation: this block cannot see a B channel.
          when P_DONE =>
            if kv_wr_idle = '1' then
              done_r <= '1';
              if done_ack = '1' then
                done_r <= '0';
                ph <= P_IDLE;
              end if;
            end if;

        end case;

        -- ================================================================
        -- SCORE_EARLY: THE HAND-OVER, RUN OUTSIDE THE PHASE MACHINE.
        --
        -- It is placed AFTER the case and gated on `ph /= P_HDR`, which
        -- makes it and P_HDR's own branch DISJOINT drivers of `sq_hdrv`
        -- rather than two assignments in one delta where the later one
        -- silently wins.  That is the same hazard this file already
        -- records at the `vhdr` capture: an unguarded second writer of a
        -- register produced numbers that were in range, plausible and
        -- wrong by a power of two, and nothing structural could see it.
        --
        -- WHY `all_zero(sq_busy)` IS THE WHOLE GUARD.  A score unit takes
        -- a header only in S_IDLE, and the sweep does not leave P_SCW
        -- until every unit is back there (`all_zero(sq_busy)` at P_SCW).
        -- So from P_EPW of position p until the header of position p+1 is
        -- handed over, every unit is idle -- which is exactly the window
        -- in which a K record is captured in BOTH modes: under the K fetch
        -- of p+1 with SWEEP_PIPE false, and under the PV of p with it
        -- true.  The gate is therefore a check of the thing itself and not
        -- a reading of the schedule, and it holds if the schedule moves.
        --
        -- WHAT IT DOES NOT TOUCH: `khdr`, the partials, their order, the
        -- array, and the score units' own arithmetic.  A unit that has
        -- taken its header early sits in S_ACC with `p_ready` high and
        -- receives nothing, because attn_mac_array raises `p_valid` only
        -- in M_SCORE mode (rtl/attn_mac_array.vhd:456) and the only issuer
        -- of M_SCORE is P_SCORE.
        -- ================================================================
        if SCORE_EARLY and ph /= P_HDR then
          if sq_hdrv = '1' then
            if all_ones(sq_taken) then
              sq_hdrv <= '0';
              se_sent <= '1';
              se_rdy  <= '0';
            end if;
          elsif se_rdy = '1' and se_sent = '0' and all_zero(sq_busy) then
            sq_hdrv <= '1';
          end if;
        end if;

      end if;
    end if;
  end process;

  -- WHAT A PRODUCTION SCHEDULE WOULD OVERLAP, and is deliberately not
  -- overlapped here:
  --   * the PV of position p-2 under the score of position p, which is C spec
  --     3.1's 16-cycle slot and the only reason the lag is two rather than one;
  --   * group 1's QK-norms under group 0's sweep, which is what turns the
  --     182K-cycle serial norm row into 104K (C skeleton section 4);
  --   * the K and V record fetches, which run in lockstep on two masters in
  --     the spec and strictly one after the other here;
  --   * the output stage of group 0 under the sweep of group 1;
  --   * the gate feed, four cycles per element here against one in the spec.
  -- Each of those is a new seam.  None of them changes the values.
  --
  -- ======================================================================
  -- WHERE THE PER-POSITION CYCLES ACTUALLY GO, MEASURED RATHER THAN
  -- DERIVED (TRACK MIDGAP, 2026-09-20)
  -- ======================================================================
  -- sim/tb_csweep_rate.vhd now publishes the phase split through
  -- `dbg_sw_ph`, so the figures below are cycle counts and not a
  -- subtraction.  Per position per KV head, asymptotic slope, real 9B
  -- geometry, RD_LAT 100, SPREAD 0:
  --
  --                      base   SWEEP_PIPE   SCORE_EARLY   both
  --   P_RECK            12.79       2.77        12.79       2.77
  --   P_HDR              3.00       3.00         1.00       1.00
  --   P_SCORE           23.00      23.00        17.00      14.01
  --     of which waiting for `ar_prdy`
  --                     14.00      14.00         8.00       5.01
  --     of which issuing the eight blocks
  --                      9.00       9.00         9.00       9.00
  --   P_SCW             13.00      13.00        13.00      13.00
  --   P_EPW             13.00      13.00        13.00      13.00
  --   P_RSPASS/P_RSACK   0.00       0.00         0.00       0.00
  --   P_RECV            11.00       1.00        11.00       1.00
  --   P_PV               9.00       9.00         9.00       9.00
  --   P_POSN             4.00       4.00         4.00       4.00
  --   ---------------------------------------------------------------
  --   per position      88.79      68.77        80.79      57.79
  --   x N_KVH = 4      355.17     275.11       323.17     231.17
  --
  -- THE TWO GENERICS ARE NOT ADDITIVE AND THE COMBINATION IS WORTH MORE
  -- THAN THE SUM.  Alone they save 80.06 and 32.00 cycles per position per
  -- job; together they save 124.00, i.e. 11.94 MORE than 80.06 + 32.00.
  -- The mechanism is in the table: with SWEEP_PIPE the K record of the
  -- next position is captured during P_PV, so SCORE_EARLY's hand-over
  -- happens a whole PV and P_POSN earlier and hides 8.99 of the header
  -- pass instead of 6.00.  Quote the pair, never the two singles added.
  --
  -- THREE THINGS IN THAT TABLE ARE WORTH MORE THAN THE TOTALS:
  --
  -- 1. THE RESCALE PASS IS ZERO AT THE ASYMPTOTE.  It fires in the first
  --    position or two of a head and never again at this stimulus, so it
  --    is not a term in the slope at all.  What the bench does NOT
  --    establish is the card's rescale rate; see the open list in
  --    docs/debugging/2026-09-20_the-attention-midgap.md.
  -- 2. P_SCW AND P_EPW ARE FIXED PIPELINE LATENCIES, NOT DRAINS OF
  --    ANYTHING ELASTIC.  P_SCW is attn_score_q12's three-stage accumulate
  --    emptying plus S_EXP1/S_EXP2/S_SH/S_Q1/S_Q2/S_DONE; P_EPW is one
  --    pass of attn_softmax's cone.  Neither shortens with a faster memory
  --    or a wider port, and together they are 26.00 of the 52.00 the score
  --    chain costs.
  -- 3. NOTHING IN THE SWEEP IS A DIVIDE.  attn_recip -- the only divider on
  --    C's read path, rtl/divider_rs.vhd behind it -- runs in P_RCP/P_RCW
  --    ONCE PER QUERY HEAD after the whole sweep, so its latency is in the
  --    job's fixed cost and contributes 0.00 to the per-position slope.
  --    It was a candidate and it is excluded by measurement.
  --
  -- AND THE OVERLAP THAT IS *NOT* BUILT, stated with its blocker because
  -- the obvious reading of the table is to reach for it.  Computing the
  -- score of position p+1 under the softmax of position p is NUMERICALLY
  -- legal: the score is Q . K[p+1] aligned by e_min(p+1), and it reads
  -- `qrec`, `krec` and `khdr` only -- no softmax state, no running maximum,
  -- no accumulator.  It is blocked by the SCHEDULE, in two places:
  --   * `krec` does not hold position p+1 yet.  Even with SWEEP_PIPE the
  --     K record of p+1 is fetched during P_PV/P_POSN of p, which is AFTER
  --     the softmax window, and moving it earlier puts it in the same
  --     window as the V record of p through a capture path that is ONE
  --     pipe wide (`rbv` / `rbs`, at the capture above).
  --   * attn_mac_array has ONE multiplier and three mutually exclusive
  --     modes (rtl/attn_mac_array.vhd:339).  P_PV needs it for nine cycles
  --     immediately after P_EPW's thirteen, so a score issue moved into
  --     the softmax window buys nothing unless the PV moves too.
  -- SCORE_EARLY is the part of that lever which needs neither: the HEADER
  -- is complete on the record's first beat and the header pass touches no
  -- multiplier, so it can be hoisted on its own.  The rest is open work.

end architecture;
