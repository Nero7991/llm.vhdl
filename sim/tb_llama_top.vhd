-- sim/tb_llama_top.vhd
-- THE INTEGRATION BENCH.  NTOK tokens of one sequence, N transformer blocks
-- each, through `rtl/llama_top.vhd`, run several times with different
-- handshake timings and compared against itself.
--
-- =====================================================================
-- WHAT THIS BENCH CAN CHECK, AND WHAT IT DELIBERATELY DOES NOT CLAIM
-- =====================================================================
-- THERE IS NO BLOCK-LEVEL ORACLE AND THIS BENCH DOES NOT PRETEND OTHERWISE.
-- An independent C reference for a whole transformer block would have to
-- model Gated DeltaNet, gated attention, rmsnorm, swiglu and the BFP
-- exponent discipline all at once, and two of those five have no RTL to
-- compare against -- attention's lane array is a pricing skeleton, and the
-- norm and swiglu D-vec engines do not exist.  A "reference" written today
-- would be a reference for the STUBS.  That is worth nothing and is worse
-- than nothing, because it would look like coverage.
--
-- So this bench checks the properties that do not need one, and those are the
-- integration properties anyway:
--
--   P1  THE SCHEDULE.  Every issue is compared against the plan, step by
--       step: opcode, unit, source region, destination region, element
--       count.  The token must end after exactly `n_steps(SHAPE)` steps.
--       This needs no arithmetic reference at all and it is the property that
--       says the block loop ran.
--
--   P2  THE RESIDUAL STREAM IS BIT-IDENTICAL UNDER PRODUCER SKEW.  The token
--       is run `NRUNS` times with a different descriptor-memory latency each
--       time, which moves every handshake in the machine relative to every
--       other one without changing one bit of input data.  Region R_X is
--       dumped after each run and compared, element by element, against run
--       0.  A single dropped beat, stale latch or lost completion anywhere
--       shows up here as a differing element.  This is the shape
--       `sim/tb_gdn_block.vhd` uses, which has found real defects three
--       times.
--
--   P3  NO SEAM FAULT FIRED.  `err_gate_drop` (the region lock refused a
--       write), `err_e_coll` (a collective was issued at NCARDS=1) and the
--       lock's own `viol` must all stay low, and `err` from the walker must
--       stay low.  These are silent in the arithmetic: a dropped write leaves
--       the previous value in place, which is a plausible number.
--
--   P4  THE RESIDUAL ACTUALLY MOVED.  A machine that sequenced 64 steps and
--       wrote nothing would pass P1, P2 and P3.  R_X after the token must
--       differ from R_X before it.
--
--   P5  THE STUB IS ANNOUNCED, OR THE STUB IS GONE.  With `C_REAL` false and
--       an attention block in the schedule, `err_unit_stub` MUST be set at
--       the end: a stub marker that stops working is worse than the stub.
--       With `C_REAL` true it MUST be clear, because a marker that stays set
--       is indistinguishable from a marker nobody cleared and would make
--       every later run unreadable.
--
-- =====================================================================
-- THE KV SEAM, AND WHAT A MULTI-TOKEN RUN ADDS (added 2026-08-29)
-- =====================================================================
-- Until today this file ran ONE token per reset.  Every attention job it has
-- ever issued therefore ran at `cur_pos = 0`, where `attn_block` takes its
-- bypass path and NEVER READS THE KV CACHE.  That is the whole reason neither
-- of the two real defects TRACK C-ORACLE found in `attn_block` was visible
-- here, and it is why a green run of this bench said nothing at all about the
-- cache.  `rtl/llama_top.vhd` also left `attn_block`'s four seam handshakes
-- open, so the block was talking to a memory that can never refuse.
--
-- With `KV_AXI` and `NTOK > 1` the cache is `rtl/attn_kv_axi.vhd`, it leaves
-- the top level over three AXI masters, and this file models them.  Six more
-- properties, and each says what it can see:
--
--   P7  WRITE PLACEMENT.  Every byte the write master commits is decoded to
--       a (region, layer, head, position) by THIS FILE'S OWN evaluation of C
--       spec 2.2's address equation, and must land at the position the DUT
--       says it is at and the layer this file counted independently.  Two
--       masters agreeing on a WRONG address produce a perfect answer, which
--       is why the equation is written twice and not shared.
--
--   P8  READ PLACEMENT.  Every byte fetched lies inside a KV region (or in
--       the at-most-one-beat of alignment padding at either end), and every
--       record from an earlier position that it touches belongs to the layer
--       in flight.
--
--   P9  READ COVERAGE.  After token t, the records this file saw FULLY read
--       are exactly {every region, every head, every layer} x {0..t-1}.  Not
--       fewer -- the sweep is [cur_pos, 0, 1, ... cur_pos-1] and every
--       earlier position is in it.  Not more -- the readable bound is
--       `pos < cur_pos`, because the record AT cur_pos is the one this job
--       is writing through a different master.
--
--   P10 THE SERVED BYTES.  Every byte handed to the cache for a record from
--       an earlier position equals the byte that record was written with,
--       and no byte of a record that was never written is ever served.
--
--   P11 C SPEC 2.7 AT THE INTEGRATION LEVEL.  At the instant subsystem C
--       reports a completion, this token's own records must be IN MEMORY,
--       not merely accepted on W.  The write slave holds accepted beats and
--       commits them at BVALID, which is what AXI promises; a slave that
--       committed at W would make this untestable.  See MUT_KV_NO_BRESP.
--
--   P12 THE SEQUENCE IS A SEQUENCE.  The same embedding is preloaded for
--       every token, so a machine with no cross-token state would produce a
--       bit-identical R_X every time.  It must not.
--
-- AND WHAT NONE OF THEM SAY.  There is still no value oracle for a token, so
-- nothing here says the numbers are attention -- that claim belongs to
-- `ref/attn_block_seq_vec.c` through `sim/tb_attn_kv_seam.vhd`, at the BLOCK
-- level.  P12 in particular says only that SOMETHING crossed the token
-- boundary: subsystem B's recurrent state is a second cross-token channel and
-- P12 cannot separate it from the cache.  MUT_KV_ZERO is the control for
-- that and its result is in the mutation table.
--
-- THE SHAPE IS FORCED, and it is not the shape any earlier landmark in this
-- file was measured at.  `attn_kv_axi` needs CM_W = 8, a 16-byte record
-- granule (KV_BLOCK >= 16) and N_KVH >= 2; `attn_block` needs an even
-- power-of-two HEAD_DIM, HEAD_DIM/KV_BLOCK >= 2 and a GQA group >= 2.  The
-- smallest shape satisfying all six is ATTN_HD = 64, KV_BLOCK = 16,
-- N_ROT = 16, which `mk_shape_scaled` had to learn.  It quadruples att_q,
-- att_qg and att_kv, so R_X and every hash differ from the ATTN_HD 16 and 32
-- landmarks and the three are not comparable.
--
-- =====================================================================
-- THE DEFAULT IS 4 BLOCKS WITH NORM_ANCHOR ON, AND NEITHER HALF OF THAT IS
-- AN ARBITRARY CHOICE.  READ THIS.
-- =====================================================================
-- Measured 2026-08-28 with the corrected D-vec exponents (see the S_DONE
-- comment in rtl/llama_top.vhd), real A and real B, attn_interval 4,
-- NRUNS = 1.  P6's counter is CUMULATIVE across runs and is never reset, so
-- a count is only comparable against another count at the same NRUNS -- an
-- earlier revision of this header quoted a 32-block figure of 46, which was
-- the same 23 counted twice at NRUNS = 2:
--
--     BLOCKS   NORM_ANCHOR=false   NORM_ANCHOR=true   NORM_REAL=true
--         4         5   red              0   green        6   red
--         8        12   red              0   green       14   red
--        16        27   red              3   red         28   red
--        32        56   red              8   red         59   red
--
-- THE THIRD COLUMN IS THE REAL `rmsnorm_rs`, MEASURED 2026-08-28, AND IT IS
-- THE WORST OF THE THREE.  Read this before assuming the probe is standing in
-- for something better than itself.  The unit's exponent bookkeeping is
-- exactly the scale-free behaviour the probe models -- it publishes o_exp 13
-- or 14 for input exponents of 3, 10, -1, -5, -6 and -7 alike -- but the unit
-- also has a HARD 19-octave INPUT MAGNITUDE window, rms(x_real) in
-- [2^-6, 2^12], with a SILENT all-zeros rail above it, measured independently
-- in docs/debugging/2026-08-26_rmsnorm-magnitude-window.md.  The residual
-- stream leaves that window during the SECOND block (log2 rms 3.20, 3.36,
-- then 15.10 and stuck), and from the third norm onward every output element
-- is zero: R_XN is a zero vector, ER is zero, the stream freezes.  The probe
-- folds the magnitude in unbounded integer arithmetic and so has no window,
-- which is precisely the idealisation.  See PART 5 of
-- docs/debugging/2026-08-28_llama-top-first-seams.md.
--
-- =====================================================================
-- CORRECTED 2026-08-28, SAME DAY: THAT WHOLE TABLE IS A MEASUREMENT OF THE
-- STIMULUS.  READ THIS BEFORE QUOTING IT.
-- =====================================================================
-- Every count above was taken with `wword`, the arithmetic weight image.  Its
-- rms ROW NORM is 2**4.87 over the 297 A jobs of a 32-block token; the real
-- Qwen3.5-9B weights, packed into this same geometry, are 2**-0.03 (every
-- tensor kind, every layer, 0.52 to 1.57).  A matvec multiplies the
-- activation magnitude by its row norm, so the synthetic image ALONE pushes
-- the stream up about five octaves per matvec.  Measured with the real
-- weights served through the `W_IMAGE` generic below, NRUNS = 1,
-- attn_interval 4, real A and real B:
--
--     BLOCKS                             1   2   4   8  16  32
--     NORM_REAL true,  REAL weights      0   0   0   0   0   0   <-- PASS
--     NORM_REAL true,  synthetic         0   2   6  14  28  59
--     no anchor,       REAL weights      0   1   3   9  23  51
--     no anchor,       synthetic         1   2   5  12  27  56
--
-- log2 rms of the norm's INPUT, at norms 0, 8, 16, 24, 32, 40, 48, 56, 64:
--
--     NORM_REAL + real   3.20  3.72  4.10  4.33  4.62  5.07  5.22  5.28  5.24
--     NORM_REAL + synth  3.20 15.10 15.10 15.10 15.10 15.10 15.10 15.10 15.10
--     no norm   + real   3.20 51.07  808  1.3e4 2.6e4 2.6e4 2.6e4 2.6e4 2.6e4
--     no norm   + synth  3.20  389  6495 2.6e4 2.6e4 2.6e4 2.6e4 2.6e4 2.6e4
--
-- The 15.10 column is the all-zeros rail, NOT a bounded stream: the machine
-- has stopped.  The 3.20 -> 5.24 row is the design working -- 65 DISTINCT
-- magnitudes over 65 norms, so the stream is still moving, and every value is
-- inside the unit's [2^-6, 2^12] window with ten octaves to spare.
--
-- So: `rmsnorm_rs` on the D-vec norm op DOES restore the activation scale,
-- PART 3's recommendation stands, and PART 5 measured the stimulus rather
-- than the design.  What is NOT withdrawn is the other half: with real
-- weights and NO real norm the stream still explodes (3.20 -> 25875 octaves
-- over 32 blocks), so the block loop really does have nothing else that
-- restores the scale.  See PART 6.
--
-- The DEFAULT stays synthetic, because the image is a 5 MB file generated
-- from an 18 GB GGUF that is not in this repository.
--
-- =====================================================================
-- THE REAL SUBSYSTEM C, `C_REAL`, MEASURED 2026-08-28.  NRUNS = 1.
-- =====================================================================
-- `rtl/attn_block.vhd` replaces the `-32768 + i` ramp.  It needs a shape with
-- `attn_head_dim = 16` (`-gATTN_HD=16`), for reasons in the generic below;
-- only the head SPLIT changes, so att_q, att_qg, att_kv and every descriptor
-- are identical at 16 and at 32 and the columns are directly comparable.
--
--     BLOCKS                          1   2   4   8  16  32
--     stub C, NORM_ANCHOR             0   0   0   0   3   8
--     REAL C, NORM_ANCHOR             0   0   0   0   3   8     <-- identical
--     stub C, unanchored              1   2   5  12  27  56
--     REAL C, unanchored              1   2   P4 fails from 4 blocks up
--
-- Swapping ten real units in for a ramp moves P6 by NOTHING, which is what it
-- should do: P6 measures the residual's SCALE, and defect 7's fix already had
-- the stub publishing its source region's exponent.  The unanchored path now
-- ends with R_X all zeros instead of ending wrong, because attn_block carries
-- `rmsnorm_rs` instances of its own for the QK-norm and therefore the same
-- 19-octave window.
--
-- EVERYTHING REAL -- A, B, C, the norm and the weights -- passes at EVERY
-- depth including 32, with the norm's input magnitude flat at log2 rms 3.20
-- to 3.34 across the whole token:
--
--     -gC_REAL=true -gATTN_HD=16 -gNORM_REAL=true -gNORM_ANCHOR=false
--     -gW_IMAGE=<real image>   ->  0 degenerate at 1/2/4/8/16/32, PASS,
--                                  R_X(0) = -14110 hash(R_X) = 52347 at 32
--
-- AND NOTHING HERE SAYS THE BLOCK COMPUTES ATTENTION.  C spec 3.11's
-- `ref/attn_gated_fx.c` does not exist, so `sim/tb_attn_block.vhd` checks
-- seams and not values, and this bench checks the schedule and the scale.
-- See PART 7.
--
-- TWO THINGS FOLLOW, AND THE SECOND IS THE UNCOMFORTABLE ONE.
--
-- First, NO unanchored configuration passes, not even ONE block.  So the
-- gate cannot run this bench unanchored at any depth without being
-- permanently red, and a permanently red gate stops being read and then
-- hides the NEXT regression behind an expected failure.
--
-- Second, `NORM_ANCHOR` is a PROBE, not a property of the design.  It gives
-- the behavioural norm model rmsnorm's one scale property and nothing else.
-- Defaulting to it means THE GATE RUNS A CONFIGURATION THE HARDWARE DOES NOT
-- YET IMPLEMENT.  That is a real cost and it is accepted deliberately, on the
-- grounds that the alternative costs more.  What makes it honest is that the
-- unanchored column above is measured, is stated here, and is restated in the
-- PASS line, so a green run cannot be read as "the scales track".  It does
-- not track.  Nothing in the block loop restores the activation scale.
--
-- The trend is the finding, not the failure.
--
-- WHY, established 2026-08-28 and NOT the reason this header gave before.
-- The earlier text blamed subsystem B's fixed-scale stand-in inputs.  That
-- was a hypothesis, it was tested by sourcing B's activations from the real
-- regions, and it is WITHDRAWN: the count went 0/3/10/23 -> 3/5/11/24, i.e.
-- slightly WORSE.  The residual stream's own exponent falls linearly at
-- about 6.2 per residual step, 3 -> -387 over 32 blocks, in BOTH
-- configurations and in the FFN residual too, which contains no B at all.
--
-- The cause is that nothing in the block loop ever restores the activation
-- scale.  A matvec's output exponent is its source's, minus
-- (out_shift - w_exp), minus its own data-driven normalisation shift `ns`
-- (matvec_core.vhd:876, :932-934), so it only ever FALLS; the one unit that
-- would put it back is rmsnorm, which is scale-free by construction, and
-- rmsnorm here is a behavioural model that passes its input exponent
-- straight through.  Measured fall: 6.19 per residual step, 12.4 per block.
-- With `NORM_ANCHOR` -- a probe that gives the norm model rmsnorm's ONE scale
-- property and nothing else -- the stream exponent stays inside [-4, +8].
--
-- WITHDRAWN 2026-08-28: this header previously said the anchored count was 0
-- at 4, 8, 16 AND 32 blocks.  That measurement was taken with the swiglu
-- D-vec model publishing a FABRICATED exponent (`v_exp_a + 2`, the op index,
-- for a PRODUCT).  Correcting it to `v_exp_a + v_exp_b - MANT_W` moved the
-- anchored column to 0/0/3/8: the fabricated value had been masking roughly
-- half the FFN-side excursion.  So anchoring the norm ALONE does not suffice
-- at depth, and 8 blocks -- not 32 -- is the deepest anchored configuration
-- that passes.  All 8 remaining failures at 32 blocks are FFN residuals.
--
-- So: 8 blocks anchored is the largest configuration in which the numeric
-- behaviour is currently defensible.  The gate runs 4, one step inside it,
-- because the bench is in SLOW_TBS and 4 costs half the wall time for the
-- same verdict.  A green run of this bench at the default says nothing about
-- a 32-block token, anchored or otherwise.
-- See docs/debugging/2026-08-28_llama-top-first-seams.md, PARTS 3 and 4.
--
-- =====================================================================
-- WHY THE DESCRIPTOR MEMORY LATENCY IS THE SKEW AXIS
-- =====================================================================
-- Subsystem D prefetches: the next descriptor is fetched while the current
-- job runs.  A FAST memory gets the prefetch ahead of the units, which is the
-- configuration that makes defect class (a) reachable -- the next job's data
-- arriving while the current one is still being read.  A SLOW memory starves
-- the walker and exercises the held `start` instead.  One generic covers both
-- ends, and the two ends put the units at completely different phases
-- relative to the walker, which is what "producer skew" has to mean at this
-- level.  `sim/tb_seq_desc_fetch.vhd` uses the same axis for the same reason.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.math_real.all;
use work.model_cfg_pkg.all;
use work.llama_map_pkg.all;
use work.llama_sched_pkg.all;
use work.seq_tbl_pkg;

entity tb_llama_top is
  generic(
    BLOCKS    : positive := 4;
    ATTN_INT  : positive := 4;
    -- The descriptor-memory latencies to sweep.  Run 0 is the reference.
    NRUNS     : positive := 4;
    -- The DEFAULT configuration is the most real one available: the real
    -- `matvec_int4`.  Set A_BEHAV true to bisect a failure to a side of the
    -- D-to-A seam.
    A_BEHAV   : boolean  := false;
    B_BEHAV   : boolean  := false;
    -- Where subsystem B's ACTIVATION inputs come from.  See the generic of
    -- the same name in `rtl/llama_top.vhd`.  false = the fixed-exponent
    -- stand-ins; true = the newest conv tap from R_QKV, alpha from R_ALPHA
    -- and beta from R_BETA, each with that region's captured exponent.
    B_SRC_REAL : boolean := false;
    -- A PROBE, and it DEFAULTS ON.  See the generic of the same name in
    -- `rtl/llama_top.vhd`, and the measured table at the head of this file
    -- for why the gate has no unanchored option at any depth.
    NORM_ANCHOR : boolean := true;
    -- THE REAL `rmsnorm_rs` ON THE D-VEC NORM OP.  See the generic of the
    -- same name in `rtl/llama_top.vhd`, and the third column of the measured
    -- table at the head of this file.  DEFAULT FALSE, and that is a MEASURED
    -- choice: the real unit emits an all-zero vector from the third norm
    -- onward, so it is worse at every depth than the probe and no better
    -- than having no norm at all.
    NORM_REAL   : boolean := false;
    -- ==================================================================
    -- REAL WEIGHTS FOR SUBSYSTEM A.  Path to a memory image emitted by
    -- `tools/gen_llama_top_weights.py`; "" (the DEFAULT) keeps the synthetic
    -- `wword` and every published number unchanged.
    --
    -- WHY IT EXISTS.  `wword` is an arithmetic weight image: uniform INT4
    -- nibbles against per-block scales masked into [16384, 32767].  Its rms
    -- ROW NORM is about 2**4.8, and a trained matrix's is about 2**0
    -- (measured over Qwen3.5-9B: every tensor kind, every layer, 0.52 to
    -- 1.57).  A matvec multiplies the activation magnitude by its row norm,
    -- so the synthetic image drives the residual stream up about five octaves
    -- PER MATVEC, and every magnitude conclusion drawn from it is a
    -- conclusion about the stimulus.  See PART 6 of
    -- docs/debugging/2026-08-28_llama-top-first-seams.md.
    --
    -- THE IMAGE MUST MATCH `BLOCKS` AND `ATTN_INT`.  It is indexed by STEP,
    -- and the step sequence is a function of both.  The bench checks the line
    -- count and REFUSES a mismatched image rather than serving a shifted one.
    W_IMAGE   : string   := "";
    -- THE REAL SUBSYSTEM C.  See the generic of the same name in
    -- `rtl/llama_top.vhd`.  DEFAULT FALSE, and the default path is
    -- bit-identical with it false.  It cannot be set on its own: the real
    -- `attn_block` refuses to elaborate at ATTN_HD = 32, so a C_REAL run
    -- needs `-gATTN_HD=16` as well, and every number it produces is at a
    -- DIFFERENT SHAPE from every published landmark in this file.
    C_REAL    : boolean  := false;
    -- The attention head dim of the scaled shape.  32 is `mk_shape_scaled`'s
    -- own default and every published number here is at it.  16 is the only
    -- other value the real C accepts, and it changes att_q, att_qg and att_kv
    -- and therefore R_X.
    ATTN_HD   : positive := 32;
    -- Subsystem C's cache geometry.  Defaults are `rtl/llama_top.vhd`'s own.
    KV_BLOCK  : positive := 4;
    N_ROT     : positive := 8;
    MAXPOS    : positive := 4;
    -- ==================================================================
    -- THE MULTI-TOKEN SEQUENCE, AND THE REAL KV CACHE.
    --
    -- NTOK = 1 is what this bench has always run, and every landmark above
    -- is at it.  A "run" was a RESET followed by one token, so `cur_pos` was
    -- 0 for every attention job that has ever executed here and the cache
    -- READ PATH NEVER RAN: `attn_block` bypasses at position 0.  That is
    -- exactly why neither of the two real defects TRACK C-ORACLE found in
    -- `attn_block` was visible to this bench.
    --
    -- NTOK > 1 makes a run a reset followed by NTOK `go`/`tok_done`
    -- handshakes, with the DUT's own `tok_pos` advancing across them.  Token
    -- t therefore attends over the records tokens 0..t-1 wrote.
    NTOK      : positive := 1;
    -- `rtl/attn_kv_axi.vhd` instead of the behavioural KV memory.  See the
    -- generic of the same name in `rtl/llama_top.vhd` for the three-way
    -- geometry constraint: it needs ATTN_HD = 64, KV_BLOCK = 16, N_ROT = 16.
    KV_AXI    : boolean  := false;
    KV_RD_LAT : natural  := 100;  -- AR accepted -> first beat, cycles
    KV_WR_LAT : natural  := 12;   -- WLAST -> BVALID, cycles
    KV_AW_LAT : natural  := 0;    -- cycles the write slave refuses AWVALID
    KV_STALL  : natural  := 5;    -- 0 = never stall; else 1-in-STALL gaps
    -- Mutation hooks for the SEAM AT THE INTEGRATION LEVEL.  Every one is
    -- false in the shipping bench.  They live here rather than in a scratch
    -- copy of the RTL because what they break is a property of llama_top and
    -- attn_kv_axi TOGETHER and of nothing in either.
    MUT_KV_STALE    : boolean := false;  -- serve the previous position's bytes
    MUT_KV_DROP_REC : boolean := false;  -- drop one record's write burst
    MUT_KV_ZERO     : boolean := false;  -- read slaves return zeros
    -- RESET THE DUT BETWEEN TOKENS, so every token runs at cur_pos 0 again.
    -- That is EXACTLY what this bench did before NTOK existed, and it is the
    -- most valuable mutation in the table: a bench that cannot tell an
    -- N-token sequence from N one-token runs has not tested a sequence.
    MUT_TOK_RESET   : boolean := false;
    -- The token index enters the embedding, so each position writes a
    -- DIFFERENT KV record.  See the `embed` function for the measurement
    -- that forced this on.
    EMBED_VARY      : boolean := true;
    MUT_KV_NO_BRESP : boolean := false;  -- commit at W, not at BVALID
    MAXCYC    : natural  := 4000000;
    -- Per-step exponents and per-region fingerprints.  Off by default: at 32
    -- blocks it is 490 lines and the regression runner reads every line.
    VERBOSE   : boolean  := false
  );
end entity;

architecture tb of tb_llama_top is

  constant SHAPE  : shape_t := mk_shape_scaled(BLOCKS, ATTN_INT, ATTN_HD);
  constant NSTEP  : natural := n_steps(SHAPE);
  constant TBL    : sched_tbl_t := build_table(SHAPE);
  constant PLAN   : plan_t := build_plan(SHAPE);
  constant REGMAX : positive := region_max(SHAPE);

  constant LANES  : positive := 8;
  constant MANT_W : positive := 16;
  constant EXP_W  : positive := 16;
  constant STEP_W : positive := 11;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal running : boolean := true;
  signal cyc : natural := 0;

  signal go, abort, tok_ack : std_logic := '0';
  signal tbl_len : unsigned(STEP_W-1 downto 0)
                 := to_unsigned(NSTEP, STEP_W);
  signal host_x_exp : signed(EXP_W-1 downto 0) := to_signed(3, EXP_W);
  signal rel_mask : std_logic_vector(NREGION-1 downto 0) := (others => '0');

  signal busy, tok_done, err : std_logic;
  signal err_code : std_logic_vector(3 downto 0);
  signal err_step, steps_done : unsigned(STEP_W-1 downto 0);

  signal d_raddr : unsigned(15 downto 0);
  signal d_ren, d_rvalid : std_logic := '0';
  signal d_rdata : std_logic_vector(63 downto 0) := (others => '0');

  signal hw_we : std_logic := '0';
  signal hw_reg : natural range 0 to NREGION-1 := 0;
  signal hw_addr : natural range 0 to REGMAX-1 := 0;
  signal hw_data : signed(MANT_W-1 downto 0) := (others => '0');
  signal hr_reg : natural range 0 to NREGION-1 := 0;
  signal hr_addr : natural range 0 to REGMAX-1 := 0;
  signal hr_data : signed(MANT_W-1 downto 0);

  signal obs_issue, obs_cmp : std_logic;
  signal obs_unit : unsigned(2 downto 0);
  signal obs_opcode : unsigned(3 downto 0);
  signal obs_step : unsigned(STEP_W-1 downto 0);
  signal obs_dst : unsigned(7 downto 0);

  signal err_lost_beat, err_gate_drop, err_unit_stub, err_e_coll : std_logic;

  -- ---- subsystem A's weight ports -------------------------------------
  signal m_arvalid, m_arready, m_rvalid, m_rready, m_rlast
       : std_logic_vector(A_NPORTS-1 downto 0) := (others => '0');
  signal m_araddr  : std_logic_vector(A_NPORTS*32-1 downto 0);
  signal m_arlen   : std_logic_vector(A_NPORTS*8-1 downto 0);
  signal m_arsize  : std_logic_vector(A_NPORTS*3-1 downto 0);
  signal m_arburst : std_logic_vector(A_NPORTS*2-1 downto 0);
  signal m_rdata   : std_logic_vector(A_NPORTS*128-1 downto 0)
                   := (others => '0');

  -- THE WEIGHT MEMORY IS A FUNCTION, NOT AN ARRAY.  The real 9B weights are
  -- 4.5 GB and the addresses this bench generates span megabytes, so the
  -- model answers every address arithmetically.  Ports 0..A_NPORTS-2 carry
  -- packed INT4 weight nibbles; the last port carries per-block scales, which
  -- the spec constrains to uint15 -- 32768 does not fit and a codebook entry
  -- of -128 is forbidden -- so that lane is masked into [16384, 32767].
  --
  -- WHAT THIS DOES AND DOES NOT ESTABLISH.  It does NOT establish that A
  -- computes the right dot product: that is `sim/run_matvec.sh`'s job, it has
  -- an independent C oracle and a packer, and it passes.  What it establishes
  -- is that the SEAM works -- that A is fed a coherent descriptor, that its
  -- un-refusable output is never dropped, that its one-cycle `done` is
  -- converted to the level D requires, and that all of that is invariant
  -- under handshake timing.  A synthetic weight image is sufficient for that
  -- and an incorrect packing would be caught by run_matvec.sh, not here.
  function wword(p : natural; idx : natural) return std_logic_vector is
    variable v : std_logic_vector(127 downto 0);
    variable x, i2 : natural;
  begin
    -- `idx` is reduced BEFORE the multiply.  It is a 24-bit word index and
    -- the bench addresses megabytes, so `idx*7919` overflows VHDL's 32-bit
    -- universal integer at 491 steps and aborts the run with
    -- "overflow detected" from inside this function -- which reads like a
    -- broken AXI slave and is arithmetic in the stimulus.
    i2 := idx mod 65536;
    if p = A_NPORTS-1 then
      for l in 0 to 7 loop
        x := 16384 + ((i2*13 + l*7 + 3) mod 16384);
        v(l*16+15 downto l*16) := std_logic_vector(to_unsigned(x, 16));
      end loop;
    else
      for b in 0 to 15 loop
        x := (i2*7919 + p*104729 + b*31 + 17) mod 251;
        v(b*8+7 downto b*8) := std_logic_vector(to_unsigned(x, 8));
      end loop;
    end if;
    return v;
  end function;
  -- ======================================================================
  -- THE REAL-WEIGHT MEMORY IMAGE.  Empty unless W_IMAGE names a file.
  --
  -- The two address constants are passed to the DUT rather than assumed, so
  -- the image's step stride and the top level's cannot drift apart.
  -- ======================================================================
  constant A_MEM_BASE_C   : natural := 16#100000#;
  constant A_JOB_STRIDE_C : natural := 16#8000#;
  constant A_SUB_BYTES    : natural := 4096;    -- port p is at base + p*4096
  -- Beats EMITTED per sub-region.  No job at this shape reads past beat 63:
  -- tiles*NB is at most 64 and the scale region needs 32 superwords.  The
  -- slave REFUSES a read past this rather than wrapping.
  constant A_WBEATS       : natural := 64;

  constant A_WWORDS : natural := NSTEP*A_NPORTS*A_WBEATS;

  type wimg_t is array (natural range <>) of std_logic_vector(127 downto 0);
  type wimg_p is access wimg_t;

  -- THE IMAGE LIVES ON THE HEAP, AND THAT IS NOT A STYLE CHOICE.  At 32 blocks
  -- it is 491*5*64 = 157,120 words of 128 bits, and GHDL stores one std_logic
  -- per byte, so the array is about 20 MB.  A function-local variable of that
  -- size is on the C stack and the run SEGFAULTS AT ELABORATION with no output
  -- at all -- which reads as a broken testbench and is a stack limit.  The
  -- `--max-stack-alloc=0` this project already passes does not cover it.
  -- A protected type with an access-type member allocates with `new`, so
  -- nothing large is ever on the stack.
  type wmem_t is protected
    procedure load(fn : string; nwords : natural);
    impure function get(i : natural) return std_logic_vector;
  end protected wmem_t;

  type wmem_t is protected body
    variable m : wimg_p := null;

    procedure load(fn : string; nwords : natural) is
      file     fh : text;
      variable ok : file_open_status;
      variable l  : line;
      variable v  : std_logic_vector(127 downto 0);
      variable i  : natural := 0;
    begin
      m := new wimg_t(0 to nwords-1);
      for k in m'range loop m(k) := (others => '0'); end loop;
      if fn = "" then return; end if;
      file_open(ok, fh, fn, read_mode);
      assert ok = open_ok
        report "tb_llama_top: cannot open the weight image " & fn
        severity failure;
      -- A SHORT OR LONG IMAGE IS A REFUSAL, NOT A TRUNCATION.  The array is
      -- indexed by STEP, so an image built for a different BLOCKS/ATTN_INT
      -- would serve every job the weights of some other job -- silently, and
      -- with a perfectly plausible result.
      while not endfile(fh) loop
        readline(fh, l);
        assert i < nwords
          report "tb_llama_top: the weight image " & fn & " is LONGER than "
               & "the " & integer'image(nwords) & " words this shape needs.  "
               & "It was built for a different BLOCKS or ATTN_INT."
          severity failure;
        hread(l, v);
        m(i) := v;
        i := i + 1;
      end loop;
      assert i = nwords
        report "tb_llama_top: the weight image " & fn & " has "
             & integer'image(i) & " words, this shape needs "
             & integer'image(nwords)
             & ".  It was built for a different BLOCKS or ATTN_INT."
        severity failure;
      file_close(fh);
    end procedure;

    impure function get(i : natural) return std_logic_vector is
    begin
      return m(i);
    end function;
  end protected body wmem_t;

  shared variable WMEM : wmem_t;

  impure function wmem_boot return boolean is
  begin
    WMEM.load(W_IMAGE, A_WWORDS);
    return true;
  end function;

  -- Elaboration order, not a process: the slaves may be read before any
  -- process has run.
  constant WMEM_READY : boolean := wmem_boot;

  -- ONE address decode for both memories, so a real run and a synthetic run
  -- cannot see different addresses.  `wword` is declared above and keeps its
  -- own comment about why it is a function.
  impure function wword_at(p : natural; addr : natural)
    return std_logic_vector is
    variable off, stp, rmn, sub, beat : natural;
  begin
    if W_IMAGE = "" then
      -- `idx` is the 16-byte word index, reduced before any multiply.  See
      -- the note in wword.
      return wword(p, (addr / 16) mod 16777216);
    end if;
    assert addr >= A_MEM_BASE_C
      report "tb_llama_top: weight read below A_MEM_BASE" severity failure;
    off  := addr - A_MEM_BASE_C;
    stp  := off / A_JOB_STRIDE_C;
    rmn := off mod A_JOB_STRIDE_C;
    sub  := rmn / A_SUB_BYTES;
    beat := (rmn mod A_SUB_BYTES) / 16;
    assert stp < NSTEP and sub = p and beat < A_WBEATS and WMEM_READY
      report "tb_llama_top: weight read outside the image -- step "
           & integer'image(stp) & " sub " & integer'image(sub) & " port "
           & integer'image(p) & " beat " & integer'image(beat)
      severity failure;
    return WMEM.get(stp*A_NPORTS*A_WBEATS + p*A_WBEATS + beat);
  end function;

  signal obs_norm_pub : std_logic;
  signal obs_norm_exp : signed(EXP_W-1 downto 0);
  signal obs_norm_ssq : unsigned(63 downto 0);
  signal obs_norm_n   : unsigned(15 downto 0);
  signal n_norm       : natural := 0;

  signal obs_res_take : std_logic;
  signal obs_res_ea, obs_res_eb : signed(EXP_W-1 downto 0);
  signal n_bad_res : natural := 0;
  signal obs_cmp_exp : signed(EXP_W-1 downto 0);
  signal obs_wsum    : unsigned(31 downto 0);

  -- The per-completion trace: the exponent the lock captured, and the running
  -- write hash at that instant.  Compared across runs to find the FIRST step
  -- at which two timings diverge, and to say whether they diverged in the
  -- exponent path or in the data path.
  type tr_t   is array (0 to 1023) of integer;
  type trs_t  is array (0 to NRUNS-1) of tr_t;
  signal tr_exp : trs_t := (others => (others => 0));
  signal tr_sum : trs_t := (others => (others => 0));
  signal cur_run : natural := 0;

  -- The live descriptor-memory latency.  A SIGNAL, not a generic, so one
  -- elaboration can sweep it.
  signal uram_lat : natural := 1;

  -- schedule checking
  signal n_issue : natural := 0;
  signal n_chk   : natural := 0;
  signal n_cmp   : natural := 0;
  signal n_bad_sched : natural := 0;
  signal tb_reset : std_logic := '0';

  -- results.  Indexed [run][token]: a run is a reset plus NTOK tokens, and
  -- the skew comparison is per TOKEN, not per run, or a sequence that diverges
  -- at token 1 and reconverges at token 3 would read as identical.
  type res_t is array (0 to REGMAX-1) of integer;
  type toks_t is array (0 to NTOK-1) of res_t;
  type runs_t is array (0 to NRUNS-1) of toks_t;
  signal results : runs_t := (others => (others => (others => 0)));
  signal x0      : res_t := (others => 0);

  -- ======================================================================
  -- THE KV CACHE'S SIDE OF THE WORLD.
  --
  -- Three modelled AXI slaves over one address space, plus a SHADOW of the
  -- records keyed by (region, layer, head, position) using THIS FILE'S OWN
  -- implementation of C spec 2.2's address equation.  The shadow is what
  -- makes the checks independent: `attn_kv_axi` writes and reads through the
  -- same equation, so a memory alone would agree with a WRONG equation.  Two
  -- masters agreeing on a wrong address produce a perfect answer.
  --
  -- The bases are deliberately awkward.  16 is 16-byte aligned and not 4 KB
  -- aligned; 4064 straddles the 4 KB boundary, so the burst splitter is
  -- exercised.  C spec 2.2 asks for 4 KB alignment and TRACK C-SEAM measured
  -- that it is not needed.
  -- ======================================================================
  constant KV_ADDR_W : positive := 16;
  constant KV_DW     : positive := 256;
  constant KV_BEAT_B : natural  := KV_DW/8;
  constant KV_CH_B   : natural  := 16;              -- the record granule
  constant KV_K_BASE : natural  := 16;
  constant KV_V_BASE : natural  := 4064;
  constant KV_NB     : natural  := 8192;            -- bytes of modelled HBM
  constant KV_REC_B  : natural  := KV_CH_B + ATTN_HD;   -- CM_W is 8
  constant KV_NBLK   : natural  := ATTN_HD / KV_BLOCK;
  constant KV_NKVH   : natural  := SHAPE.attn_kv_heads;
  function nlay_f(s : shape_t) return positive is
    variable n : natural := n_attn_blocks(s);
  begin
    if n = 0 then return 1; else return n; end if;
  end function;
  constant KV_LAY    : positive := nlay_f(SHAPE);
  -- Slot index: ((region*LAY + layer)*NKVH + head)*MAXPOS + pos
  constant KV_NSLOT  : natural  := 2*KV_LAY*KV_NKVH*MAXPOS;
  constant KV_RGN_B  : natural  := KV_LAY*KV_NKVH*MAXPOS*KV_REC_B;

  function kv_slot(r, l, h, ps : natural) return natural is
  begin
    return ((r*KV_LAY + l)*KV_NKVH + h)*MAXPOS + ps;
  end function;
  function kv_addr(r, l, h, ps : natural) return natural is
    variable b : natural;
  begin
    if r = 0 then b := KV_K_BASE; else b := KV_V_BASE; end if;
    return b + ((l*KV_NKVH + h)*MAXPOS + ps)*KV_REC_B;
  end function;

  -- The modelled HBM and the shadow, in ONE protected type: the two read
  -- slaves, the write slave and the checkers are several processes over one
  -- address space, and a plain shared variable is illegal in VHDL-2008.
  --
  -- ONE PROCESS DRIVES BOTH READ SLAVES, and that is not tidiness.  GHDL
  -- mcode reports "several sources for unresolved signal" for a SCALAR and
  -- reports NOTHING for a COMPOSITE: two processes driving disjoint slices of
  -- one std_logic_vector elaborate silently and deliver 'U' on one half and
  -- '0' on the other.  Measured by TRACK C-SEAM; it cost that track an hour.
  type kvm_t is protected
    procedure wrb(i : natural; v : std_logic_vector(7 downto 0));
    impure function rdb(i : natural) return std_logic_vector;
    procedure shw(i : natural; v : std_logic_vector(7 downto 0));
    impure function shr(i : natural) return std_logic_vector;
    impure function shhas(i : natural) return boolean;
    procedure rdmk(i : natural);
    impure function rdmq(i : natural) return boolean;
    procedure rdclr;
  end protected;
  type kvm_t is protected body
    type ba_t is array (0 to KV_NB-1) of std_logic_vector(7 downto 0);
    type sa_t is array (0 to KV_NSLOT*KV_REC_B-1) of std_logic_vector(7 downto 0);
    type sw_t is array (0 to KV_NSLOT*KV_REC_B-1) of boolean;
    variable a  : ba_t := (others => (others => '0'));
    variable sh : sa_t := (others => (others => '0'));
    variable sv : sw_t := (others => false);
    procedure wrb(i : natural; v : std_logic_vector(7 downto 0)) is
    begin a(i) := v; end procedure;
    impure function rdb(i : natural) return std_logic_vector is
    begin return a(i); end function;
    procedure shw(i : natural; v : std_logic_vector(7 downto 0)) is
    begin sh(i) := v; sv(i) := true; end procedure;
    impure function shr(i : natural) return std_logic_vector is
    begin return sh(i); end function;
    impure function shhas(i : natural) return boolean is
    begin return sv(i); end function;
    variable rm : sw_t := (others => false);
    procedure rdmk(i : natural) is
    begin rm(i) := true; end procedure;
    impure function rdmq(i : natural) return boolean is
    begin return rm(i); end function;
    procedure rdclr is
    begin rm := (others => false); end procedure;
  end protected body;
  shared variable kvm : kvm_t;

  signal kv_arvalid, kv_arready, kv_rvalid, kv_rready, kv_rlast
       : std_logic_vector(1 downto 0) := (others => '0');
  signal kv_araddr  : std_logic_vector(2*KV_ADDR_W-1 downto 0);
  signal kv_arlen   : std_logic_vector(15 downto 0);
  signal kv_arsize  : std_logic_vector(5 downto 0);
  signal kv_arburst : std_logic_vector(3 downto 0);
  signal kv_rdata   : std_logic_vector(2*KV_DW-1 downto 0) := (others => '0');
  signal kv_rresp   : std_logic_vector(3 downto 0) := (others => '0');
  signal kv_awvalid, kv_awready, kv_wvalid, kv_wready, kv_wlast : std_logic := '0';
  signal kv_bvalid, kv_bready : std_logic := '0';
  signal kv_awaddr  : std_logic_vector(KV_ADDR_W-1 downto 0);
  signal kv_awlen   : std_logic_vector(7 downto 0);
  signal kv_awsize  : std_logic_vector(2 downto 0);
  signal kv_awburst : std_logic_vector(1 downto 0);
  signal kv_wdata   : std_logic_vector(KV_DW-1 downto 0);
  signal kv_wstrb   : std_logic_vector(KV_DW/8-1 downto 0);
  signal kv_bresp   : std_logic_vector(1 downto 0) := "00";
  signal kv_err     : std_logic;
  signal obs_tok_pos : unsigned(15 downto 0);

  -- The attention layer of the C job currently in flight.  Derived by
  -- counting OP_C_JOB issues within the token, which is the same arithmetic
  -- `rtl/llama_top.vhd` does from the job ordinal, done independently here.
  signal cur_lay : natural := 0;
  signal n_cjob  : natural := 0;

  -- fault counters, one per property
  signal kv_bad_wr, kv_bad_rd, kv_bad_dat, kv_bad_cov, kv_bad_bresp
       : natural := 0;
  signal kv_n_wrec, kv_n_rbeat : natural := 0;
  -- THE LIVE KV READ LATENCY.  A SIGNAL, not a generic, so one elaboration
  -- sweeps it alongside the descriptor-memory latency.  P2 is only a check on
  -- the KV seam if the KV timing is one of the things that moves.
  signal kv_lat : natural := KV_RD_LAT;

  signal n_bad_skew : natural := 0;
  -- Driven ONLY by the driver process.  n_bad_sched belongs to `sched`, and
  -- a second driver on an integer signal is an elaboration error rather than
  -- a resolution.
  signal n_bad_pos  : natural := 0;
  -- `kv_err` is a VERDICT, not a log line.  It was checked with a bare assert
  -- and did not reach `fail`, so a run could report the fault and still print
  -- PASS.  A check whose result you do not branch on is decoration.
  signal n_bad_kverr : natural := 0;
  signal fail       : natural := 0;
  signal xsum       : integer := 0;
  signal rsum       : integer := 0;

  -- The token embedding.  Deterministic, non-trivial, and not symmetric: a
  -- residual stream that is accidentally zeroed or accidentally copied has to
  -- be distinguishable from one that was computed.
  --
  -- IT VARIES WITH THE TOKEN, AND THAT WAS MEASURED, NOT ASSUMED.  The first
  -- version of the token loop preloaded the SAME embedding every time, so
  -- that "R_X differs from token 0" would mean "something crossed the token
  -- boundary".  MEASURED at NTOK = 3: token 1 differed from token 0 in 62 of
  -- 64 elements and **token 2 was BIT-IDENTICAL to token 1, 0 of 64**.  The
  -- mechanism is the stimulus, not a defect: with an identical input every
  -- token, every K and V record in the cache is identical, and an attention
  -- output that is a convex combination of identical vectors does not depend
  -- on how many of them there are.  A sequence whose cache holds one distinct
  -- record is not a sequence, and every mutation of the read path would have
  -- been measuring that rather than the check -- C-SEAM's trap 7.4 exactly.
  --
  -- With `EMBED_VARY` the token index enters the embedding, so each position
  -- writes a DIFFERENT record and reading position 0 is distinguishable from
  -- reading position 1.  `false` reproduces the degenerate stimulus above.
  function embed(i : natural; t : natural) return integer is
  begin
    if EMBED_VARY then
      return ((i * 37 + t * 101) mod 251) - 125;
    else
      return ((i * 37) mod 251) - 125;
    end if;
  end function;

begin

  clk <= not clk after 0.5 ns when running else '0';

  cycles : process(clk) is
  begin
    if rising_edge(clk) then
      cyc <= cyc + 1;
      assert cyc < MAXCYC
        report "tb_llama_top: cycle cap reached, the run is wedged at step "
             & integer'image(n_issue) & " of " & integer'image(NSTEP)
        severity failure;
    end if;
  end process;

  -- ======================================================================
  -- THE DUT
  -- ======================================================================
  dut : entity work.llama_top
    generic map(
      SHAPE => SHAPE, LANES => LANES, MANT_W => MANT_W, EXP_W => EXP_W,
      REGMAX => REGMAX, STEP_W => STEP_W,
      WDOG_LIMIT => 200000, STRICT => true,
      A_BEHAV => A_BEHAV, B_BEHAV => B_BEHAV,
      B_SRC_REAL => B_SRC_REAL, NORM_ANCHOR => NORM_ANCHOR,
      NORM_REAL => NORM_REAL, C_REAL => C_REAL,
      C_KV_BLOCK => KV_BLOCK, C_N_ROT => N_ROT, C_MAXPOS => MAXPOS,
      C_KV_AXI => KV_AXI, C_CTXLEN => NTOK,
      C_K_BASE => KV_K_BASE, C_V_BASE => KV_V_BASE,
      C_KV_ADDR_W => KV_ADDR_W, C_KV_AXI_DW => KV_DW,
      A_MEM_BASE => A_MEM_BASE_C, A_JOB_STRIDE => A_JOB_STRIDE_C,
      SHOUT => true)
    port map(
      clk => clk, rst => rst,
      go => go, abort => abort, tbl_len => tbl_len,
      host_x_exp => host_x_exp, rel_mask => rel_mask,
      busy => busy, tok_done => tok_done, tok_ack => tok_ack,
      err => err, err_code => err_code, err_step => err_step,
      steps_done => steps_done,
      d_raddr => d_raddr, d_ren => d_ren, d_rdata => d_rdata,
      d_rvalid => d_rvalid,
      hw_we => hw_we, hw_reg => hw_reg, hw_addr => hw_addr, hw_data => hw_data,
      hr_reg => hr_reg, hr_addr => hr_addr, hr_data => hr_data,
      obs_issue => obs_issue, obs_unit => obs_unit, obs_opcode => obs_opcode,
      obs_step => obs_step, obs_dst => obs_dst, obs_cmp => obs_cmp,
      m_arvalid => m_arvalid, m_arready => m_arready, m_araddr => m_araddr,
      m_arlen => m_arlen, m_arsize => m_arsize, m_arburst => m_arburst,
      m_rvalid => m_rvalid, m_rready => m_rready, m_rdata => m_rdata,
      m_rlast => m_rlast,
      obs_res_take => obs_res_take, obs_res_ea => obs_res_ea,
      obs_res_eb => obs_res_eb,
      obs_norm_pub => obs_norm_pub, obs_norm_exp => obs_norm_exp,
      obs_norm_ssq => obs_norm_ssq, obs_norm_n => obs_norm_n,
      obs_cmp_exp => obs_cmp_exp, obs_wsum => obs_wsum,
      kv_arvalid => kv_arvalid, kv_arready => kv_arready,
      kv_araddr => kv_araddr, kv_arlen => kv_arlen, kv_arsize => kv_arsize,
      kv_arburst => kv_arburst, kv_rvalid => kv_rvalid,
      kv_rready => kv_rready, kv_rdata => kv_rdata, kv_rlast => kv_rlast,
      kv_rresp => kv_rresp,
      kv_awvalid => kv_awvalid, kv_awready => kv_awready,
      kv_awaddr => kv_awaddr, kv_awlen => kv_awlen, kv_awsize => kv_awsize,
      kv_awburst => kv_awburst, kv_wvalid => kv_wvalid,
      kv_wready => kv_wready, kv_wdata => kv_wdata, kv_wstrb => kv_wstrb,
      kv_wlast => kv_wlast, kv_bvalid => kv_bvalid, kv_bready => kv_bready,
      kv_bresp => kv_bresp, kv_err => kv_err, obs_tok_pos => obs_tok_pos,
      err_lost_beat => err_lost_beat, err_gate_drop => err_gate_drop,
      err_unit_stub => err_unit_stub, err_e_coll => err_e_coll);

  -- ======================================================================
  -- THE THREE KV AXI SLAVES.
  --
  -- One in-order server per read master with a MAXOUT-deep AR queue and a
  -- fixed KV_RD_LAT from acceptance to the first beat.  100 cycles is not
  -- HBM's real latency; it is far more than the TWO the pre-seam attn_block
  -- allowed, which is the only thing that has to be true.
  --
  -- ONE PROCESS FOR BOTH READ SLAVES.  See the note on kvm_t.
  -- ======================================================================
  kvrd : process(clk) is
    type na_t is array (0 to 15) of integer;
    type ia_t is array (0 to 1) of integer;
    type ba_t is array (0 to 1) of boolean;
    variable qa, ql : na_t := (others => 0);
    variable qh, qt, qn, tmr, beat : ia_t := (others => 0);
    variable act : ba_t := (others => false);
    variable a, l, ad, sa, off, rg, lay, hd, ps, sl : integer;
    variable byt : std_logic_vector(7 downto 0);
    variable lfsr : unsigned(15 downto 0) := x"ACE1";
    -- ACCUMULATED IN VARIABLES, published once per cycle.  A signal
    -- incremented several times inside one clock edge takes the LAST
    -- assignment, so a per-byte counter written as a signal counts CYCLES
    -- with a fault and reads as a much smaller number than the truth.
    variable nbadr, nbadd, nrb : natural := 0;
  begin
    if rising_edge(clk) then
      lfsr := lfsr(14 downto 0)
              & (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));
      if rst = '1' or tb_reset = '1' then
        qh := (others => 0); qt := (others => 0); qn := (others => 0);
        tmr := (others => 0); beat := (others => 0);
        -- NOTE the fault and traffic counters are NOT cleared here.  `rst`
        -- is asserted once per RUN, and clearing them would erase run 0's
        -- faults the moment run 1 started -- a fault counter that a later
        -- reset zeroes reports a clean run.
        act := (others => false);
        kv_arready <= "11"; kv_rvalid <= "00"; kv_rlast <= "00";
        kvm.rdclr;
      else
        -- The read mask is PER TOKEN: P9's expected set is a function of
        -- the position, so a mask carried across tokens would report token
        -- t-1's reads as token t's.
        if go = '1' then
          kvm.rdclr;
        end if;
        kv_rvalid <= "00"; kv_rlast <= "00";
        for sv in 0 to 1 loop
          -- ---- AR ----------------------------------------------------
          if kv_arvalid(sv) = '1' and kv_arready(sv) = '1' then
            a := to_integer(unsigned(
                   kv_araddr((sv+1)*KV_ADDR_W-1 downto sv*KV_ADDR_W)));
            l := to_integer(unsigned(kv_arlen((sv+1)*8-1 downto sv*8))) + 1;
            -- The FK33's HBM slave is AXI3: ARLEN is 4 bits, so a 17-beat
            -- burst does not fail, it silently becomes a 1-beat burst.  A
            -- slave that did not check would report a wrong ANSWER rather
            -- than a protocol error.
            if l > 16 then
              nbadr := nbadr + 1;
              report "tb_llama_top: KV read burst of " & integer'image(l)
                   & " beats exceeds the AXI3 cap of 16" severity error;
            end if;
            if (a mod 4096) + l*KV_BEAT_B > 4096 then
              nbadr := nbadr + 1;
              report "tb_llama_top: KV read burst at " & integer'image(a)
                   & " for " & integer'image(l) & " beats crosses 4 KB"
                severity error;
            end if;
            if a mod KV_BEAT_B /= 0 then
              nbadr := nbadr + 1;
              report "tb_llama_top: KV read address " & integer'image(a)
                   & " is not beat aligned" severity error;
            end if;
            if a + l*KV_BEAT_B > KV_NB then
              nbadr := nbadr + 1;
              report "tb_llama_top: KV read burst at " & integer'image(a)
                   & " runs past the modelled memory" severity error;
            else
              qa(sv*8 + qt(sv)) := a; ql(sv*8 + qt(sv)) := l;
              qt(sv) := (qt(sv) + 1) mod 8; qn(sv) := qn(sv) + 1;
              if qn(sv) = 1 then tmr(sv) := kv_lat; end if;
            end if;
          end if;
          if qn(sv) < 4 then kv_arready(sv) <= '1';
          else kv_arready(sv) <= '0'; end if;

          -- ---- the in-order server -----------------------------------
          if not act(sv) and qn(sv) > 0 then
            if tmr(sv) > 0 then tmr(sv) := tmr(sv) - 1;
            else act(sv) := true; beat(sv) := 0; end if;
          end if;
          if act(sv) then
            if KV_STALL /= 0
               and (to_integer(lfsr(7 downto 0)) + sv) mod KV_STALL = 0 then
              null;                      -- a gap, RVALID stays low
            else
              for c in 0 to KV_BEAT_B-1 loop
                ad := qa(sv*8 + qh(sv)) + beat(sv)*KV_BEAT_B + c;
                -- MUT_KV_STALE serves the byte one RECORD earlier: the
                -- cache is handed a plausible, well-formed record for the
                -- WRONG position.  Nothing in the AXI protocol can see it.
                if MUT_KV_STALE and ad >= KV_REC_B then sa := ad - KV_REC_B;
                else sa := ad; end if;
                if MUT_KV_ZERO then byt := (others => '0');
                else byt := kvm.rdb(sa); end if;
                kv_rdata(sv*KV_DW + (c+1)*8-1 downto sv*KV_DW + c*8) <= byt;

                -- ---- P8/P10: placement, and the served byte -----------
                -- SUB-BEAT ALIGNMENT PADDING IS LEGITIMATE AND IS EXEMPT.
                -- The bases are 16-byte aligned and a beat is 32 bytes, so
                -- the first burst of a region necessarily starts BELOW the
                -- base and the last one ends above it.  Those bytes are
                -- discarded by the realignment mux.  Exempting them is not
                -- weakening the check: a wild address is still more than one
                -- beat outside, and MEASURED, the exemption is at most 16
                -- bytes at each end here.
                rg := -1;
                if ad >= KV_K_BASE and ad < KV_K_BASE + KV_RGN_B then
                  rg := 0; off := ad - KV_K_BASE;
                elsif ad >= KV_V_BASE and ad < KV_V_BASE + KV_RGN_B then
                  rg := 1; off := ad - KV_V_BASE;
                end if;
                if rg < 0
                   and ((ad + KV_BEAT_B > KV_K_BASE and ad < KV_K_BASE)
                        or (ad >= KV_K_BASE + KV_RGN_B
                            and ad < KV_K_BASE + KV_RGN_B + KV_BEAT_B)
                        or (ad + KV_BEAT_B > KV_V_BASE and ad < KV_V_BASE)
                        or (ad >= KV_V_BASE + KV_RGN_B
                            and ad < KV_V_BASE + KV_RGN_B + KV_BEAT_B))
                then
                  rg := -2;              -- alignment padding, not a fault
                end if;
                if rg = -1 then
                  nbadr := nbadr + 1;
                  report "tb_llama_top: the KV cache read byte address "
                       & integer'image(ad) & ", which is inside neither the "
                       & "K region nor the V region, and is more than one "
                       & "beat outside both" severity error;
                elsif rg >= 0 then
                  ps  := (off / KV_REC_B) mod MAXPOS;
                  hd  := ((off / KV_REC_B) / MAXPOS) mod KV_NKVH;
                  lay := ((off / KV_REC_B) / MAXPOS) / KV_NKVH;
                  sl  := kv_slot(rg, lay, hd, ps);
                  -- A record at or past the CURRENT position is legitimately
                  -- OVER-FETCHED: REC_B is 80 and a beat is 32, so the tail
                  -- beat of a run reaches into the next record.  Those bytes
                  -- are discarded by the engine and are being written by this
                  -- same job, so comparing them would be a race.  Only bytes
                  -- of a record from an EARLIER token are checked.
                  -- WHICH MASTER FETCHED IT.  Index 0 is the K stream and
                  -- index 1 is the V stream (rtl/attn_kv_axi.vhd's port
                  -- comment), and K and V are separate regions with separate
                  -- bases.  Without this a swap of the two bases is a pure
                  -- relabelling that every other check here agrees with.
                  if rg /= sv then
                    nbadr := nbadr + 1;
                    report "tb_llama_top: KV read master " & integer'image(sv)
                         & " (0 is K, 1 is V) fetched byte "
                         & integer'image(ad) & ", which is in the "
                         & integer'image(rg) & " region." severity error;
                  end if;
                  -- THE COVERAGE MASK IS MARKED FOR EVERY DECODED BYTE,
                  -- INCLUDING RECORDS AT OR PAST cur_pos.  An earlier version
                  -- marked it only for `ps < cur_pos`, which made P9's second
                  -- half -- "the sweep must NOT fully read the record at
                  -- cur_pos" -- unable to fire at all: the slots it tests
                  -- were the only ones never marked.  A dead branch in a
                  -- checker is worse than no branch, because it reads as
                  -- coverage.  Over-fetch marks at most one beat of the next
                  -- record, so a FULL record at cur_pos is still a genuine
                  -- read of it.
                  kvm.rdmk(sl*KV_REC_B + (off mod KV_REC_B));
                  if ps < to_integer(obs_tok_pos) then
                    if lay /= cur_lay then
                      nbadr := nbadr + 1;
                      report "tb_llama_top: the KV cache read layer "
                           & integer'image(lay) & " while the attention job "
                           & "in flight is layer " & integer'image(cur_lay)
                        severity error;
                    end if;
                    -- P10b: a record byte from an EARLIER position that was
                    -- never written must never be served.  Only the format's
                    -- real bytes are checked -- the NBLK block exponents and
                    -- the HEAD_DIM mantissas -- because the record's 16-byte
                    -- header chunk is zero-PADDED and the padding may or may
                    -- not carry a write strobe.
                    if ((off mod KV_REC_B) < KV_NBLK
                        or (off mod KV_REC_B) >= KV_CH_B)
                       and not kvm.shhas(sl*KV_REC_B + (off mod KV_REC_B))
                    then
                      nbadd := nbadd + 1;
                      report "tb_llama_top: the KV cache was served byte "
                           & integer'image(off mod KV_REC_B) & " of the "
                           & "record at (region " & integer'image(rg)
                           & ", layer " & integer'image(lay) & ", head "
                           & integer'image(hd) & ", pos " & integer'image(ps)
                           & "), and no token ever wrote that byte."
                        severity error;
                    end if;
                    if kvm.shhas(sl*KV_REC_B + (off mod KV_REC_B))
                       and byt /= kvm.shr(sl*KV_REC_B + (off mod KV_REC_B))
                    then
                      nbadd := nbadd + 1;
                      report "tb_llama_top: the KV cache was served byte "
                           & integer'image(off mod KV_REC_B) & " of the "
                           & "record (region " & integer'image(rg)
                           & ", layer " & integer'image(lay) & ", head "
                           & integer'image(hd) & ", pos " & integer'image(ps)
                           & ") and it is not the byte that record was "
                           & "written with." severity error;
                    end if;
                  end if;
                end if;
              end loop;
              nrb := nrb + 1;
              kv_rvalid(sv) <= '1';
              if beat(sv) = ql(sv*8 + qh(sv))-1 then kv_rlast(sv) <= '1'; end if;
              beat(sv) := beat(sv) + 1;
              if beat(sv) = ql(sv*8 + qh(sv)) then
                act(sv) := false;
                qh(sv) := (qh(sv) + 1) mod 8; qn(sv) := qn(sv) - 1;
                tmr(sv) := kv_lat;
              end if;
            end if;
          end if;
        end loop;
      end if;
      kv_bad_rd  <= nbadr;
      kv_bad_dat <= nbadd;
      kv_n_rbeat <= nrb;
    end if;
  end process;

  -- ======================================================================
  -- THE KV WRITE SLAVE, AND THE ONE MODELLING DECISION THAT MATTERS.
  --
  -- Beats are NOT committed when they are accepted on W.  They are held and
  -- committed at the instant BVALID is returned, which is what AXI actually
  -- promises and the whole reason C spec 2.7 says `done` must wait for it.
  -- A slave that committed at W time makes the write visible to the read
  -- masters early and the `kv_wr_idle` gate becomes untestable: MEASURED by
  -- TRACK C-SEAM, whose first slave did exactly that and whose mutation of
  -- that gate SURVIVED for the wrong reason.  MUT_KV_NO_BRESP reinstates the
  -- weak slave ON PURPOSE, as the control for that claim.
  -- ======================================================================
  kvwr : process(clk) is
    type na_t is array (0 to 7) of integer;
    type pa_t is array (0 to 127) of integer;
    type pd_t is array (0 to 127) of std_logic_vector(KV_DW-1 downto 0);
    type ps_t is array (0 to 127) of std_logic_vector(KV_DW/8-1 downto 0);
    variable a, l, beat : integer := 0;
    variable inw : boolean := false;
    variable btm, bct : na_t := (others => 0);
    variable bn, awt : integer := 0;
    variable lfsr : unsigned(15 downto 0) := x"BEEF";
    variable p_a : pa_t := (others => 0);
    variable p_d : pd_t := (others => (others => '0'));
    variable p_s : ps_t := (others => (others => '0'));
    variable p_h, p_t, p_n : integer := 0;
    -- NOT `nb`: VHDL is case-insensitive and KV_NB is the memory size.  A
    -- process variable spelled `nb` would shadow a constant spelled `NB`.
    variable wbeats : integer := 0;
    variable ndrop  : integer := 0;
    variable ad, off, rg, lay, hd, ps2, sl : integer;
    -- Accumulated in a variable and published once per cycle; see the note
    -- in the read slave.
    variable nbadw : natural := 0;

    -- TWO PROCEDURES, AND THE SPLIT IS THE WHOLE POINT.
    --
    -- `note_beat` runs when the master's W beat is ACCEPTED.  At that instant
    -- the record's content is known: the master has handed it over.  It goes
    -- into the SHADOW, and the placement check (P7) runs there.
    --
    -- `mem_beat` runs when BVALID is returned, and it is the only thing that
    -- writes the modelled memory.  That is what AXI promises -- a write is
    -- ordered against nothing until its BRESP.
    --
    -- The FIRST version of this bench did both in one procedure at BVALID,
    -- and P11 was BLIND because of it: with `kv_wr_idle` ungated the record
    -- is neither in memory NOR in the shadow when `done` fires, so comparing
    -- them found two zeros and agreed.  A check whose two sides move together
    -- cannot see the thing between them.  Same family as C-SEAM's 7.5, one
    -- level up: model the ordering the spec gives you, on BOTH sides.
    procedure mem_beat(pa : integer;
                       pdv : std_logic_vector(KV_DW-1 downto 0);
                       psv : std_logic_vector(KV_DW/8-1 downto 0)) is
    begin
      for c in 0 to KV_BEAT_B-1 loop
        if psv(c) = '1' then
          kvm.wrb(pa + c, pdv((c+1)*8-1 downto c*8));
        end if;
      end loop;
    end procedure;

    procedure note_beat(pa : integer;
                        pdv : std_logic_vector(KV_DW-1 downto 0);
                        psv : std_logic_vector(KV_DW/8-1 downto 0)) is
      variable ad2, off2, rg2, lay2, hd2, ps3, sl2 : integer;
    begin
      for c in 0 to KV_BEAT_B-1 loop
        if psv(c) = '1' then
          ad2 := pa + c;
          rg2 := -1;
          if ad2 >= KV_K_BASE and ad2 < KV_K_BASE + KV_RGN_B then
            rg2 := 0; off2 := ad2 - KV_K_BASE;
          elsif ad2 >= KV_V_BASE and ad2 < KV_V_BASE + KV_RGN_B then
            rg2 := 1; off2 := ad2 - KV_V_BASE;
          end if;
          if rg2 < 0 then
            nbadw := nbadw + 1;
            report "tb_llama_top: a KV record byte was written to address "
                 & integer'image(ad2) & ", inside neither region"
              severity error;
          else
            ps3  := (off2 / KV_REC_B) mod MAXPOS;
            hd2  := ((off2 / KV_REC_B) / MAXPOS) mod KV_NKVH;
            lay2 := ((off2 / KV_REC_B) / MAXPOS) / KV_NKVH;
            sl2  := kv_slot(rg2, lay2, hd2, ps3);
            if ps3 /= to_integer(obs_tok_pos) or lay2 /= cur_lay then
              nbadw := nbadw + 1;
              report "tb_llama_top: a KV record byte landed at (region "
                   & integer'image(rg2) & ", layer " & integer'image(lay2)
                   & ", head " & integer'image(hd2) & ", pos "
                   & integer'image(ps3) & ") while token position "
                   & integer'image(to_integer(obs_tok_pos))
                   & " of attention layer " & integer'image(cur_lay)
                   & " was running.  C spec 2.2's address equation, "
                   & "evaluated independently here." severity error;
            end if;
            kvm.shw(sl2*KV_REC_B + (off2 mod KV_REC_B),
                    pdv((c+1)*8-1 downto c*8));
          end if;
        end if;
      end loop;
    end procedure;
  begin
    if rising_edge(clk) then
      lfsr := lfsr(14 downto 0)
              & (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));
      if rst = '1' or tb_reset = '1' then
        inw := false; beat := 0; bn := 0; wbeats := 0; awt := 0;
        p_h := 0; p_t := 0; p_n := 0; ndrop := 0;   -- nbadw is NOT cleared
        kv_awready <= '1'; kv_wready <= '0'; kv_bvalid <= '0';
      else
        kv_bvalid <= '0';
        -- ---- AW ------------------------------------------------------
        if KV_AW_LAT /= 0 and not inw then
          if awt < KV_AW_LAT then awt := awt + 1; kv_awready <= '0';
          else kv_awready <= '1'; end if;
        end if;
        if kv_awvalid = '1' and kv_awready = '1' then
          a := to_integer(unsigned(kv_awaddr));
          l := to_integer(unsigned(kv_awlen)) + 1;
          if l > 16 then
            nbadw := nbadw + 1;
            report "tb_llama_top: KV write burst of " & integer'image(l)
                 & " beats exceeds the AXI3 cap" severity error;
          end if;
          if (a mod 4096) + l*KV_BEAT_B > 4096 then
            nbadw := nbadw + 1;
            report "tb_llama_top: KV write burst at " & integer'image(a)
                 & " crosses 4 KB" severity error;
          end if;
          if a mod KV_BEAT_B /= 0 or a + l*KV_BEAT_B > KV_NB then
            nbadw := nbadw + 1;
            report "tb_llama_top: KV write address " & integer'image(a)
                 & " is misaligned or out of range" severity error;
          end if;
          inw := true; beat := 0; wbeats := 0; awt := 0;
          kv_awready <= '0'; kv_wready <= '1';
        end if;
        -- ---- W -------------------------------------------------------
        if inw then
          if KV_STALL /= 0
             and to_integer(lfsr(7 downto 0)) mod KV_STALL = 0 then
            kv_wready <= '0';
          else
            kv_wready <= '1';
          end if;
          if kv_wvalid = '1' and kv_wready = '1' then
            p_a(p_t) := a + beat*KV_BEAT_B;
            p_d(p_t) := kv_wdata;
            p_s(p_t) := kv_wstrb;
            -- The record's content is known HERE, at W acceptance.
            note_beat(p_a(p_t), p_d(p_t), p_s(p_t));
            if MUT_KV_NO_BRESP then
              mem_beat(p_a(p_t), p_d(p_t), p_s(p_t));
            end if;
            p_t := (p_t + 1) mod 128; p_n := p_n + 1;
            wbeats := wbeats + 1;
            assert p_n <= 128
              report "tb_llama_top: the uncommitted-write ring overflowed"
              severity failure;
            beat := beat + 1;
            if kv_wlast = '1' then
              inw := false; kv_wready <= '0';
              if KV_AW_LAT = 0 then kv_awready <= '1'; end if;
              assert bn < 8
                report "tb_llama_top: more than 8 KV write bursts outstanding"
                severity failure;
              btm(bn) := KV_WR_LAT; bct(bn) := wbeats; bn := bn + 1;
              kv_n_wrec <= kv_n_wrec + 1;
            end if;
          end if;
        end if;
        -- ---- B, and the COMMIT that goes with it ----------------------
        if bn > 0 then
          if btm(0) > 0 then
            btm(0) := btm(0) - 1;
          else
            kv_bvalid <= '1';
            -- MUT_KV_DROP_REC discards the SECOND write burst of the run.
            -- BRESP is still returned, so the master is told the record
            -- landed.  That is the shape of a record that vanishes.
            ndrop := ndrop + 1;
            for k in 0 to 15 loop
              if k < bct(0) then
                if not (MUT_KV_DROP_REC and ndrop = 2) then
                  if not MUT_KV_NO_BRESP then
                    mem_beat(p_a(p_h), p_d(p_h), p_s(p_h));
                  end if;
                end if;
                p_h := (p_h + 1) mod 128; p_n := p_n - 1;
              end if;
            end loop;
            for i in 0 to 6 loop btm(i) := btm(i+1); bct(i) := bct(i+1); end loop;
            bn := bn - 1;
          end if;
        end if;
      end if;
      kv_bad_wr <= nbadw;
    end if;
  end process;

  -- ======================================================================
  -- P11 -- C spec 2.7 AT THE INTEGRATION LEVEL.  At the instant subsystem C
  -- reports a completion, token t+1 is entitled to read this token's records
  -- through a DIFFERENT master, and AXI orders nothing between masters.  So
  -- they must be IN MEMORY now, not merely accepted on W.
  -- ======================================================================
  kvbr : process(clk) is
    variable lu : integer := -1;
    variable ad : integer;
    variable nbr : natural := 0;
  begin
    if rising_edge(clk) then
      if rst = '1' or tb_reset = '1' then
        lu := -1;   -- nbr is NOT cleared; see the read slave
      else
        if obs_issue = '1' then lu := to_integer(obs_unit); end if;
        if obs_cmp = '1' and lu = U_C and KV_AXI then
          for rg in 0 to 1 loop
            for h in 0 to KV_NKVH-1 loop
              for b in 0 to KV_NBLK-1 loop
                ad := kv_addr(rg, cur_lay, h, to_integer(obs_tok_pos)) + b;
                if kvm.rdb(ad)
                   /= kvm.shr(kv_slot(rg, cur_lay, h,
                                      to_integer(obs_tok_pos))*KV_REC_B + b)
                then
                  nbr := nbr + 1;
                  report "tb_llama_top: subsystem C reported a completion "
                       & "for position "
                       & integer'image(to_integer(obs_tok_pos))
                       & " with its record (region " & integer'image(rg)
                       & ", head " & integer'image(h) & ") block exponent "
                       & integer'image(b) & " not yet in memory.  C spec "
                       & "2.7: the next token reads it through another master."
                    severity error;
                end if;
              end loop;
            end loop;
          end loop;
        end if;
      end if;
      kv_bad_bresp <= nbr;
    end if;
  end process;

  -- ======================================================================
  -- THE ATTENTION LAYER OF THE JOB IN FLIGHT, derived independently.
  -- `rtl/llama_top.vhd` computes it from the descriptor's block ordinal;
  -- this counts OP_C_JOB issues within the token.  Two derivations of the
  -- same quantity from two different sources, which is what makes the write
  -- placement check below a check rather than a restatement.
  -- ======================================================================
  layp : process(clk) is
  begin
    if rising_edge(clk) then
      if rst = '1' or tb_reset = '1' or go = '1' then
        n_cjob  <= 0;
        cur_lay <= 0;
      elsif obs_issue = '1' and to_integer(obs_unit) = U_C then
        cur_lay <= n_cjob;
        n_cjob  <= n_cjob + 1;
      end if;
    end if;
  end process;

  trace : process(clk) is
  begin
    if rising_edge(clk) then
      if rst = '0' and tb_reset = '0' and obs_cmp = '1' and n_cmp < 1024 then
        tr_exp(cur_run)(n_cmp) <= to_integer(obs_cmp_exp);
        tr_sum(cur_run)(n_cmp) <= to_integer(obs_wsum(30 downto 0));
      end if;
    end if;
  end process;

  -- ======================================================================
  -- THE AXI READ SLAVES, one per weight port.  INCR bursts only, one burst in
  -- flight per port, `rvalid` held until `rready`.
  -- ======================================================================
  slaves : for p in 0 to A_NPORTS-1 generate
    signal aw    : unsigned(31 downto 0) := (others => '0');
    signal beats : natural := 0;
    signal act   : std_logic := '0';
  begin
    m_arready(p) <= not act;

    slv : process(clk) is
    begin
      if rising_edge(clk) then
        if rst = '1' then
          act <= '0'; beats <= 0; m_rvalid(p) <= '0'; m_rlast(p) <= '0';
        elsif act = '0' then
          m_rvalid(p) <= '0';
          m_rlast(p)  <= '0';
          if m_arvalid(p) = '1' then
            assert m_arburst((p+1)*2-1 downto p*2) = "01"
              report "tb_llama_top: port " & integer'image(p)
                   & " issued a burst that is not INCR" severity failure;
            aw    <= unsigned(m_araddr((p+1)*32-1 downto p*32));
            beats <= to_integer(unsigned(m_arlen((p+1)*8-1 downto p*8))) + 1;
            act   <= '1';
          end if;
        else
          if m_rvalid(p) = '0' or m_rready(p) = '1' then
            if beats > 0 then
              m_rdata((p+1)*128-1 downto p*128)
                <= wword_at(p, to_integer(aw));
              m_rvalid(p) <= '1';
              if beats = 1 then m_rlast(p) <= '1';
              else              m_rlast(p) <= '0'; end if;
              aw    <= aw + 16;
              beats <= beats - 1;
            else
              m_rvalid(p) <= '0';
              m_rlast(p)  <= '0';
              act         <= '0';
            end if;
          end if;
        end if;
      end if;
    end process;
  end generate;

  -- ======================================================================
  -- THE DESCRIPTOR MEMORY.  `d_rdata` is 'X' whenever `d_rvalid` is low, so a
  -- walker sampling on the wrong cycle poisons its shadow instead of being
  -- right by luck.  Lifted from sim/tb_seq_desc_fetch.vhd.
  -- ======================================================================
  uram : process(clk) is
    type pipe_t is array (0 to 63) of natural;
    variable addr_p : pipe_t := (others => 0);
    variable vld_p  : std_logic_vector(0 to 63) := (others => '0');
    variable L      : natural;
    variable a      : natural;
  begin
    if rising_edge(clk) then
      L := uram_lat;
      if L < 1 then L := 1; end if;
      if L > 63 then L := 63; end if;
      for i in 63 downto 1 loop
        addr_p(i) := addr_p(i-1);
        vld_p(i)  := vld_p(i-1);
      end loop;
      if d_ren = '1' then addr_p(0) := to_integer(d_raddr);
      else                addr_p(0) := 0; end if;
      vld_p(0) := d_ren;

      if vld_p(L-1) = '1' then
        a := addr_p(L-1);
        d_rvalid <= '1';
        if a < NSTEP*8 then
          d_rdata <= TBL(a);
        else
          d_rdata <= (others => 'X');
        end if;
      else
        d_rvalid <= '0';
        d_rdata  <= (others => 'X');
      end if;
    end if;
  end process;

  -- ======================================================================
  -- THE RELEASE MASK.  The host supplies it, per step, at the CHECK instant.
  -- seq_opdec finding (3): it is a whole-table liveness property and the
  -- descriptor format has no field for it.
  -- ======================================================================
  rel_mask <= PLAN(n_chk).rel when n_chk < NSTEP else (others => '0');

  -- The per-STEP counters are per TOKEN, not per RUN.  `go` clears them.
  -- Before NTOK existed a run was one token and `tb_reset` was enough; with
  -- a token loop, leaving `n_chk` running past NSTEP publishes an all-zero
  -- release mask for token 1 and the walker refuses at err_code 3, which
  -- reads exactly like a DUT fault and is the bench's own bookkeeping.
  chkcnt : process(clk) is
  begin
    if rising_edge(clk) then
      if rst = '1' or tb_reset = '1' or go = '1' then
        n_chk <= 0;
      elsif d_ren = '0' and busy = '1' then
        null;
      end if;
      -- chk_req is internal to the DUT; the observable proxy is that opdec
      -- consumes exactly one rel_mask per step, in order.  `obs_issue` is one
      -- step later than the check, so the mask is advanced on the ISSUE and
      -- the plan index is the step about to be checked NEXT.  A mismatch
      -- shows up as a lock violation, which P3 already fails on.
      if rst = '0' and tb_reset = '0' and obs_issue = '1' then
        n_chk <= n_chk + 1;
      end if;
    end if;
  end process;

  -- ======================================================================
  -- P1: THE SCHEDULE.  Every issue, against the plan.
  -- ======================================================================
  sched : process(clk) is
    variable p : plan_step_t;
  begin
    if rising_edge(clk) then
      if rst = '1' or tb_reset = '1' or go = '1' then
        n_issue <= 0;
        n_cmp   <= 0;
      else
        if obs_issue = '1' then
          if n_issue >= NSTEP then
            n_bad_sched <= n_bad_sched + 1;
            report "tb_llama_top: issue " & integer'image(n_issue)
                 & " is past the end of a " & integer'image(NSTEP)
                 & "-step table." severity error;
          else
            p := PLAN(n_issue);
            if to_integer(obs_opcode) /= p.opcode then
              n_bad_sched <= n_bad_sched + 1;
              report "tb_llama_top: step " & integer'image(n_issue)
                   & " issued opcode " & integer'image(to_integer(obs_opcode))
                   & ", plan says " & integer'image(p.opcode)
                severity error;
            end if;
            if to_integer(obs_unit) /= p.unit then
              n_bad_sched <= n_bad_sched + 1;
              report "tb_llama_top: step " & integer'image(n_issue)
                   & " issued to unit " & integer'image(to_integer(obs_unit))
                   & ", plan says " & integer'image(p.unit)
                severity error;
            end if;
            if to_integer(obs_dst) /= p.dst then
              n_bad_sched <= n_bad_sched + 1;
              report "tb_llama_top: step " & integer'image(n_issue)
                   & " wrote region " & integer'image(to_integer(obs_dst))
                   & ", plan says " & integer'image(p.dst)
                severity error;
            end if;
            if to_integer(obs_step) /= n_issue then
              n_bad_sched <= n_bad_sched + 1;
              report "tb_llama_top: step index " & integer'image(to_integer(obs_step))
                   & " at issue number " & integer'image(n_issue)
                   & ".  The walker and the plan have desynchronised."
                severity error;
            end if;
          end if;
          n_issue <= n_issue + 1;
        end if;
        if obs_cmp = '1' then n_cmp <= n_cmp + 1; end if;
      end if;
    end if;
  end process;

  -- ======================================================================
  -- P6: NEITHER OPERAND OF THE RESIDUAL MAY SHIFT OUT.
  --
  -- The residual is a BFP add.  `seq_vec_res` aligns X and ER by exponent, so
  -- if the two exponents differ by more than the mantissa width the smaller
  -- operand is shifted entirely away and the sum IGNORES it.  The machine
  -- then sequences the whole token, every handshake is honoured, every
  -- determinism property holds, and half the arithmetic never happened.
  --
  -- This is not hypothetical.  With the wide synthetic `w_exp` the schedule
  -- originally carried, subsystem A published exponent 19 for the step that
  -- produces ER while the residual stream sat at 3.  It was found by
  -- swapping subsystem B's implementation and seeing region R_Y's fingerprint
  -- change while region R_X's did not, which is a much more roundabout
  -- instrument than this one.
  -- ======================================================================
  resexp : process(clk) is
    variable d : integer;
  begin
    if rising_edge(clk) then
      if rst = '0' and tb_reset = '0' and obs_res_take = '1' then
        d := to_integer(obs_res_ea) - to_integer(obs_res_eb);
        if d < 0 then d := -d; end if;
        -- THE GAP AT EVERY RESIDUAL, NOT ONLY THE ONES THAT FAIL.  The
        -- failing ones say a residual discarded an operand; the whole series
        -- says whether the gap is a step, a random walk or a trend, and that
        -- is the difference between a stimulus artefact and a design hole.
        -- One line per residual, so it is behind VERBOSE like the rest.
        if VERBOSE then
          report "tb_llama_top: RESGAP issue " & integer'image(n_issue)
               & " ea " & integer'image(to_integer(obs_res_ea))
               & " eb " & integer'image(to_integer(obs_res_eb))
               & " gap " & integer'image(d)
            severity note;
        end if;
        if d > MANT_W-2 then
          n_bad_res <= n_bad_res + 1;
          report "tb_llama_top: the residual at step " & integer'image(n_issue)
               & " has operand exponents " & integer'image(to_integer(obs_res_ea))
               & " and " & integer'image(to_integer(obs_res_eb))
               & ", " & integer'image(d) & " apart against a "
               & integer'image(MANT_W) & "-bit mantissa.  One operand shifts "
               & "out ENTIRELY: this add ignores half its input."
            severity error;
        end if;
      end if;
    end if;
  end process;

  -- ======================================================================
  -- THE MAGNITUDE SERIES.  Observability, NOT a property -- there is no
  -- threshold here and nothing fails because of it.
  --
  -- It exists because the exponent series alone is misleading in the one
  -- direction that matters.  With the real `rmsnorm_rs` on the norm op the
  -- residual stream's exponent pins at -1 and holds for thirty blocks, which
  -- is exactly the bounded series a working design would show, and it is
  -- bounded because R_XN is all zeros and the machine has stopped computing.
  -- `log2 rms` of the norm's INPUT is the quantity every real normaliser's
  -- window is stated in, so it is the one that says whether the design is
  -- inside the range its arithmetic works over.  PART 5 and PART 6 of
  -- docs/debugging/2026-08-28_llama-top-first-seams.md.
  --
  -- `ieee.math_real` here and NOT in the RTL: the top level publishes the
  -- integer sum of squares and this turns it into an octave count.
  -- ======================================================================
  normmag : process(clk) is
    -- `to_integer` would OVERFLOW here.  The sum of squares reaches
    -- 64 * 2**30 = 2**36 and VHDL's integer is 32-bit, so the conversion has
    -- to go bit by bit into a real.  Same class as the `idx*7919` overflow in
    -- PART 2's traps: a run-time abort from inside the stimulus, which reads
    -- like broken RTL.
    function ureal(u : unsigned) return real is
      variable r : real := 0.0;
    begin
      for i in u'range loop
        if u(i) = '1' then r := r + 2.0**i; end if;
      end loop;
      return r;
    end function;
    variable q : real;
  begin
    if rising_edge(clk) then
      if rst = '0' and tb_reset = '0' and obs_norm_pub = '1' then
        n_norm <= n_norm + 1;
        if VERBOSE then
          if obs_norm_ssq = 0 then
            report "tb_llama_top: NORMMAG norm " & integer'image(n_norm)
                 & " run " & integer'image(cur_run)
                 & " xe " & integer'image(to_integer(obs_norm_exp))
                 & " log2rms -inf  THE NORM INPUT IS ALL ZEROS"
              severity note;
          else
            q := 0.5 * log2(ureal(obs_norm_ssq)
                            / real(to_integer(obs_norm_n)))
                 - real(to_integer(obs_norm_exp));
            report "tb_llama_top: NORMMAG norm " & integer'image(n_norm)
                 & " run " & integer'image(cur_run)
                 & " xe " & integer'image(to_integer(obs_norm_exp))
                 & " log2rms " & real'image(q)
              severity note;
          end if;
        end if;
      end if;
    end if;
  end process;

  -- ======================================================================
  -- P3: seam faults.  Checked continuously, not only at the end, so the
  -- report names the step it happened on.
  -- ======================================================================
  faults : process(clk) is
  begin
    if rising_edge(clk) then
      if rst = '0' then
        assert err_gate_drop = '0'
          report "tb_llama_top: the region lock dropped a write.  See the "
               & "llama_top report above for the region." severity failure;
        assert err_e_coll = '0'
          report "tb_llama_top: OP_E_COLL was issued at NCARDS = 1."
          severity failure;
        assert err_lost_beat = '0'
          report "tb_llama_top: an un-stallable producer beat was lost."
          severity failure;
        assert err = '0'
          report "tb_llama_top: the walker raised err_code x"
               & integer'image(to_integer(unsigned(err_code)))
               & " at step " & integer'image(to_integer(err_step))
          severity failure;
      end if;
    end if;
  end process;

  -- ======================================================================
  -- THE DRIVER
  -- ======================================================================
  drv : process is
    variable lat : natural;

    procedure preload(t : natural) is
    begin
      -- The token embedding into R_X.  Written through the host port, which
      -- is the only writer the region lock does not police -- the lock's
      -- window belongs to a JOB and this is before any job exists.
      for i in 0 to SHAPE.hidden-1 loop
        wait until rising_edge(clk);
        hw_we   <= '1';
        hw_reg  <= R_X;
        hw_addr <= i;
        hw_data <= to_signed(embed(i, t), MANT_W);
      end loop;
      wait until rising_edge(clk);
      hw_we <= '0';
    end procedure;

    procedure dump(variable r : out res_t) is
    begin
      for i in 0 to REGMAX-1 loop
        hr_reg  <= R_X;
        hr_addr <= i;
        wait until rising_edge(clk);
        wait for 0.1 ns;
        r(i) := to_integer(hr_data);
      end loop;
    end procedure;

    variable rv : res_t;
    variable nz : natural;
    variable full : boolean;
    variable ncov : natural := 0;
  begin
    report "tb_llama_top: shape blocks=" & integer'image(SHAPE.blocks)
         & " attn_interval=" & integer'image(SHAPE.attn_interval)
         & " hidden=" & integer'image(SHAPE.hidden)
         & " ffn=" & integer'image(SHAPE.ffn)
         & " -> " & integer'image(NSTEP) & " descriptors, "
         & integer'image(n_gdn_blocks(SHAPE)) & " GDN blocks, "
         & integer'image(n_attn_blocks(SHAPE)) & " attention blocks"
      severity note;

    for run in 0 to NRUNS-1 loop
      -- Latencies 1, 2, 5, 11, ... : a fast memory that gets the prefetch
      -- ahead of the units, and a slow one that starves the walker.
      case run is
        when 0 => lat := 1;
        when 1 => lat := 2;
        when 2 => lat := 5;
        when others => lat := 3 + 4*run;
      end case;
      uram_lat <= lat;
      -- The KV read latency moves with the run too.  A skew sweep that
      -- varied only the descriptor memory would leave the whole cache path
      -- at one timing and P2 would say nothing about it.
      case run is
        when 0 => kv_lat <= KV_RD_LAT;
        when 1 => kv_lat <= 7;
        when 2 => kv_lat <= 4*KV_RD_LAT + 3;
        when others => kv_lat <= 11 + 37*run;
      end case;
      cur_run  <= run;

      rst      <= '1';
      tb_reset <= '1';
      go       <= '0';
      tok_ack  <= '0';
      for i in 0 to 9 loop wait until rising_edge(clk); end loop;
      rst      <= '0';
      tb_reset <= '0';
      wait until rising_edge(clk);

      -- ================= THE TOKEN LOOP ==============================
      -- A run is a RESET followed by NTOK tokens.  The DUT's own `tok_pos`
      -- advances on each `tok_done`/`tok_ack`, so token t attends over the
      -- records tokens 0..t-1 wrote.  At NTOK = 1 this is exactly what the
      -- bench did before and every landmark above still holds.
      --
      -- THE SAME EMBEDDING IS PRELOADED FOR EVERY TOKEN, on purpose.  With
      -- identical input, any difference between token 0's R_X and token t's
      -- is cross-token state and nothing else.  See P8 below for what that
      -- does and does not isolate.
      for t in 0 to NTOK-1 loop
        if MUT_TOK_RESET and t > 0 then
          rst      <= '1';
          tb_reset <= '1';
          for i in 0 to 9 loop wait until rising_edge(clk); end loop;
          rst      <= '0';
          tb_reset <= '0';
          wait until rising_edge(clk);
        end if;
        preload(t);
        if run = 0 and t = 0 then
          dump(rv);
          x0 <= rv;
        end if;

        -- The DUT's own position counter, read back.  NOT guarded by any
        -- mutation flag: a mutation that switches its own detector off has
        -- tested nothing.
        assert to_integer(obs_tok_pos) = t
          report "tb_llama_top: run " & integer'image(run) & " token "
               & integer'image(t) & " started with the DUT at position "
               & integer'image(to_integer(obs_tok_pos))
               & ".  A run is a reset plus NTOK tokens, and the position "
               & "advances on tok_done/tok_ack." severity error;
        if to_integer(obs_tok_pos) /= t then
          n_bad_pos <= n_bad_pos + 1;
          wait for 0 ns;
        end if;

        wait until rising_edge(clk);
        go <= '1';
        wait until rising_edge(clk);
        go <= '0';

        wait until tok_done = '1' for 1 ms;
        assert tok_done = '1'
          report "tb_llama_top: run " & integer'image(run) & " token "
               & integer'image(t) & " (descriptor latency "
               & integer'image(lat)
               & ") never reached tok_done.  It stopped at issue "
               & integer'image(n_issue) & " of " & integer'image(NSTEP)
          severity failure;

        assert n_issue = NSTEP-1
          report "tb_llama_top: run " & integer'image(run) & " token "
               & integer'image(t) & " issued " & integer'image(n_issue)
               & " jobs; a " & integer'image(NSTEP)
               & "-step table has " & integer'image(NSTEP-1)
               & " startable steps (END_TOKEN starts nobody)."
          severity error;
        assert steps_done = to_unsigned(NSTEP, STEP_W)
          report "tb_llama_top: run " & integer'image(run) & " token "
               & integer'image(t) & " walked "
               & integer'image(to_integer(steps_done)) & " of "
               & integer'image(NSTEP) & " descriptors."
          severity error;

        dump(rv);
        results(run)(t) <= rv;
        wait until rising_edge(clk);

        -- ---- P9/P10: the cache's coverage for THIS token ---------------
        -- Checked here rather than at the end, because the read mask is
        -- per token and the expected set is a function of the position.
        if KV_AXI then
          for rg in 0 to 1 loop
            for l in 0 to KV_LAY-1 loop
              for h in 0 to KV_NKVH-1 loop
                for q in 0 to MAXPOS-1 loop
                  full := true;
                  for b in 0 to KV_NBLK-1 loop
                    if not kvm.rdmq(kv_slot(rg,l,h,q)*KV_REC_B + b) then
                      full := false;
                    end if;
                  end loop;
                  for d in 0 to ATTN_HD-1 loop
                    if not kvm.rdmq(kv_slot(rg,l,h,q)*KV_REC_B
                                    + KV_CH_B + d) then
                      full := false;
                    end if;
                  end loop;
                  if q < t and not full then
                    ncov := ncov + 1;
                    report "tb_llama_top: token " & integer'image(t)
                         & " did NOT read the whole record at (region "
                         & integer'image(rg) & ", layer " & integer'image(l)
                         & ", head " & integer'image(h) & ", pos "
                         & integer'image(q) & ").  The sweep is "
                         & "[cur_pos, 0, 1, ... cur_pos-1] and every earlier "
                         & "position is in it." severity error;
                  end if;
                  if q >= t and full then
                    ncov := ncov + 1;
                    report "tb_llama_top: token " & integer'image(t)
                         & " read the WHOLE record at pos "
                         & integer'image(q) & " (region " & integer'image(rg)
                         & ", layer " & integer'image(l) & ", head "
                         & integer'image(h) & ").  The readable bound is "
                         & "pos < cur_pos: the record at cur_pos is the one "
                         & "this job writes." severity error;
                  end if;
                  -- ---- and the WRITE side, for this token's own record
                  if q = t then
                    for b in 0 to KV_NBLK-1 loop
                      if not kvm.shhas(kv_slot(rg,l,h,q)*KV_REC_B + b) then
                        ncov := ncov + 1;
                        report "tb_llama_top: token " & integer'image(t)
                             & " never wrote block exponent "
                             & integer'image(b) & " of its record at "
                             & "(region " & integer'image(rg) & ", layer "
                             & integer'image(l) & ", head "
                             & integer'image(h) & ")" severity error;
                        exit;
                      end if;
                    end loop;
                    for d in 0 to ATTN_HD-1 loop
                      if not kvm.shhas(kv_slot(rg,l,h,q)*KV_REC_B
                                       + KV_CH_B + d) then
                        ncov := ncov + 1;
                        report "tb_llama_top: token " & integer'image(t)
                             & " never wrote mantissa " & integer'image(d)
                             & " of its record at (region "
                             & integer'image(rg) & ", layer "
                             & integer'image(l) & ", head "
                             & integer'image(h) & ")" severity error;
                        exit;
                      end if;
                    end loop;
                  end if;
                end loop;
              end loop;
            end loop;
          end loop;
          kv_bad_cov <= ncov;
          wait for 0 ns;
        end if;

        tok_ack <= '1';
        wait until rising_edge(clk);
        tok_ack <= '0';
        wait until rising_edge(clk);

        report "tb_llama_top: run " & integer'image(run) & " token "
             & integer'image(t)
             & " descriptor latency " & integer'image(lat)
             & ": " & integer'image(n_issue) & " jobs issued, "
             & integer'image(n_cmp) & " completions, "
             & integer'image(cyc) & " cycles elapsed, KV records written "
             & integer'image(kv_n_wrec) & ", KV beats read "
             & integer'image(kv_n_rbeat)
          severity note;
      end loop;
    end loop;

    -- ---- P4: the residual moved -----------------------------------------
    nz := 0;
    for i in 0 to SHAPE.hidden-1 loop
      if results(0)(0)(i) /= x0(i) then nz := nz + 1; end if;
    end loop;
    assert nz > 0
      report "tb_llama_top: R_X is unchanged after a whole token.  The "
           & "machine sequenced the schedule and computed nothing."
      severity failure;

    -- ---- P4b: the residual is not a constant -----------------------------
    -- A stream that saturated everywhere, or that was overwritten by one
    -- broadcast value, passes P1 through P4 and is worthless.  Count distinct
    -- values.  This is the check that caught `out_shift` = 16 driving every
    -- element of the scaled shape to zero.
    nz := 0;
    for i in 1 to SHAPE.hidden-1 loop
      if results(0)(0)(i) /= results(0)(0)(0) then nz := nz + 1; end if;
    end loop;
    assert nz >= SHAPE.hidden/4
      report "tb_llama_top: only " & integer'image(nz) & " of "
           & integer'image(SHAPE.hidden-1) & " R_X elements differ from "
           & "R_X(0) = " & integer'image(results(0)(0)(0))
           & ".  The residual stream is very nearly a constant, which passes "
           & "every determinism property and means nothing."
      severity failure;

    -- ---- the trace: where did two timings first diverge, and in what ----
    for run in 1 to NRUNS-1 loop
      for i in 0 to NSTEP-1 loop
        if tr_exp(run)(i) /= tr_exp(0)(i) then
          report "tb_llama_top: FIRST EXPONENT DIVERGENCE at completion "
               & integer'image(i) & " (step opcode "
               & integer'image(PLAN(i).opcode) & ", unit "
               & integer'image(PLAN(i).unit) & ", dst "
               & integer'image(PLAN(i).dst) & "): run "
               & integer'image(run) & " captured "
               & integer'image(tr_exp(run)(i)) & ", run 0 captured "
               & integer'image(tr_exp(0)(i))
            severity error;
          exit;
        end if;
      end loop;
      for i in 0 to NSTEP-1 loop
        if tr_sum(run)(i) /= tr_sum(0)(i) then
          report "tb_llama_top: FIRST WRITE-HASH DIVERGENCE at completion "
               & integer'image(i) & " (step opcode "
               & integer'image(PLAN(i).opcode) & ", unit "
               & integer'image(PLAN(i).unit) & ", dst "
               & integer'image(PLAN(i).dst) & ")"
            severity error;
          exit;
        end if;
      end loop;
    end loop;

    -- ---- P2: bit-identical under skew, PER TOKEN ------------------------
    -- Per token, not per run.  A sequence that diverges at token 1 and
    -- reconverges by the last one would otherwise read as identical, and
    -- divergence-then-reconvergence is exactly what a KV race looks like:
    -- the record either was or was not there when it was read.
    for run in 1 to NRUNS-1 loop
      for t in 0 to NTOK-1 loop
        for i in 0 to REGMAX-1 loop
          if results(run)(t)(i) /= results(0)(t)(i) then
            n_bad_skew <= n_bad_skew + 1;
            wait for 0 ns;
            if n_bad_skew < 8 then
              report "tb_llama_top: SKEW DIFFERENCE.  run "
                   & integer'image(run) & " token " & integer'image(t)
                   & " R_X(" & integer'image(i) & ") = "
                   & integer'image(results(run)(t)(i)) & ", run 0 = "
                   & integer'image(results(0)(t)(i))
                   & ".  A handshake timing changed the result, which means "
                   & "a beat, a latch or a completion was lost."
                severity error;
            end if;
          end if;
        end loop;
      end loop;
    end loop;
    wait for 0 ns;

    -- ---- P12b: the cache holds DISTINCT content per position -------------
    -- Read out of this file's own shadow, which is keyed by (region, layer,
    -- head, position) from the WRITE addresses.  If every position's record
    -- were the same bytes, P9 and P10 would still pass and the read path
    -- would be verifying nothing: an attention output that is a convex
    -- combination of identical vectors does not depend on which of them are
    -- in the sum.  This is the property that says the SEQUENCE has content,
    -- and it is the one the `embed` comment's measurement forced into
    -- existence.
    -- NOT guarded on EMBED_VARY.  Turning the varying stimulus off IS the
    -- degenerate sequence, and a property that switches itself off for the
    -- stimulus it exists to reject has tested nothing.  `EMBED_VARY=false`
    -- is a row in sim/mutate_llama_top_kv.sh and this is what kills it.
    if KV_AXI and NTOK > 1 then
      for rg in 0 to 1 loop
        for l in 0 to KV_LAY-1 loop
          for h in 0 to KV_NKVH-1 loop
            for t in 1 to NTOK-1 loop
              nz := 0;
              for d in 0 to ATTN_HD-1 loop
                if kvm.shr(kv_slot(rg,l,h,t)*KV_REC_B + KV_CH_B + d)
                   /= kvm.shr(kv_slot(rg,l,h,t-1)*KV_REC_B + KV_CH_B + d)
                then nz := nz + 1; end if;
              end loop;
              if nz = 0 then
                n_bad_pos <= n_bad_pos + 1;
                wait for 0 ns;
                report "tb_llama_top: P12b -- the record at (region "
                     & integer'image(rg) & ", layer " & integer'image(l)
                     & ", head " & integer'image(h) & ", pos "
                     & integer'image(t) & ") is byte-identical to the one at "
                     & "pos " & integer'image(t-1) & ".  The cache holds one "
                     & "distinct record and the read path is verifying "
                     & "nothing." severity error;
              end if;
            end loop;
          end loop;
        end loop;
      end loop;
    end if;

    -- ---- P12: the sequence is a SEQUENCE ---------------------------------
    -- WITH `EMBED_VARY` FALSE the same embedding is preloaded for every
    -- token, so a machine with no cross-token state at all would produce an
    -- identical R_X every time and this assertion is the whole property.
    -- With it TRUE (the default) the inputs differ, so the assertion is only
    -- a floor -- a machine that computed nothing at all -- and the numbers
    -- reported beside it are the measurement that matters.
    --
    -- WHAT THIS DOES AND DOES NOT ISOLATE, said here because it is easy to
    -- over-read.  The KV cache is not the only cross-token channel: subsystem
    -- B's `gdn_block` carries recurrent state too.  So P12 firing says "some
    -- state crossed the token boundary" and NOT "attention read the cache".
    -- The claim that the cache was read is P9/P10's, which count the records
    -- actually fetched and compare every byte served against the record that
    -- was written.  MUT_KV_ZERO is the control: it neuters the cache's data
    -- and leaves B's state alone, and it is reported in the mutation table.
    if NTOK > 1 then
      nz := 0;
      for i in 0 to SHAPE.hidden-1 loop
        if results(0)(NTOK-1)(i) /= results(0)(0)(i) then nz := nz + 1; end if;
      end loop;
      assert nz > 0
        report "tb_llama_top: token " & integer'image(NTOK-1)
             & " produced a bit-identical R_X to token 0.  With EMBED_VARY "
             & "false that means nothing crossed the token boundary; with it "
             & "true it means the machine computed nothing at all."
        severity error;
      report "tb_llama_top: P12 -- " & integer'image(nz) & " of "
           & integer'image(SHAPE.hidden) & " R_X elements differ between "
           & "token 0 and token " & integer'image(NTOK-1)
           & ", EMBED_VARY=" & boolean'image(EMBED_VARY) severity note;
      -- CONSECUTIVE tokens, reported because "token N differs from token 0"
      -- is compatible with a stream that moved once and then stopped, and
      -- that is not a sequence either.  This is a MEASUREMENT and not an
      -- assertion: a converging residual is a property of this stimulus, and
      -- calling it a failure would be asserting something nothing here has
      -- established.  Read it before quoting P12.
      for t in 1 to NTOK-1 loop
        nz := 0;
        for i in 0 to SHAPE.hidden-1 loop
          if results(0)(t)(i) /= results(0)(t-1)(i) then nz := nz + 1; end if;
        end loop;
        report "tb_llama_top: P12 -- token " & integer'image(t) & " vs token "
             & integer'image(t-1) & ": " & integer'image(nz) & " of "
             & integer'image(SHAPE.hidden) & " R_X elements differ"
          severity note;
      end loop;
    end if;

    -- ---- P13: the KV seam's own counters ---------------------------------
    if KV_AXI then
      assert kv_bad_wr = 0
        report "tb_llama_top: " & integer'image(kv_bad_wr)
             & " KV record bytes landed at an address C spec 2.2's equation "
             & "does not put them at." severity error;
      assert kv_bad_rd = 0
        report "tb_llama_top: " & integer'image(kv_bad_rd)
             & " KV read placement or AXI protocol faults." severity error;
      assert kv_bad_dat = 0
        report "tb_llama_top: " & integer'image(kv_bad_dat)
             & " bytes served to the cache are not the bytes the record was "
             & "written with." severity error;
      assert kv_bad_cov = 0
        report "tb_llama_top: " & integer'image(kv_bad_cov)
             & " KV record coverage faults." severity error;
      assert kv_bad_bresp = 0
        report "tb_llama_top: " & integer'image(kv_bad_bresp)
             & " completions reported with the token's own records not yet "
             & "in memory." severity error;
      if kv_err = '1' then
        n_bad_kverr <= 1;
        wait for 0 ns;
        report "tb_llama_top: the KV cache path raised its sticky error -- "
             & "either attn_kv_axi's own (C spec 3.9) or llama_top's seam "
             & "handshake check.  The reason is in the log above."
          severity error;
      end if;
      -- The read path must actually have RUN.  Zero beats at NTOK > 1 is the
      -- pre-seam state of this file wearing a green PASS line.
      if NTOK > 1 then
        assert kv_n_rbeat > 0
          report "tb_llama_top: NTOK = " & integer'image(NTOK)
               & " and the KV read masters moved ZERO beats.  Attention did "
               & "not read the cache." severity error;
      end if;
    end if;

    -- ---- P5: the stub is announced, or the stub is GONE ------------------
    -- Both halves are checked, and the second is the one that matters once
    -- C_REAL exists: a run with the real block MUST NOT set the stub marker,
    -- because a marker that stays set is indistinguishable from a marker
    -- nobody cleared and would make every later run unreadable.
    if n_attn_blocks(SHAPE) > 0 then
      if C_REAL then
        assert err_unit_stub = '0'
          report "tb_llama_top: C_REAL is set and the schedule ran "
               & integer'image(n_attn_blocks(SHAPE))
               & " attention block(s), but err_unit_stub is HIGH.  Some unit "
               & "still took the stub path."
          severity failure;
        report "tb_llama_top: NOTE -- attention was computed by the REAL "
             & "attn_block.  There is no block-level reference for subsystem "
             & "C, so nothing here says the result is attention."
          severity warning;
      else
        assert err_unit_stub = '1'
          report "tb_llama_top: the schedule contains "
               & integer'image(n_attn_blocks(SHAPE))
               & " attention block(s) but err_unit_stub is LOW.  The stub "
               & "marker has stopped working, which is worse than the stub."
          severity failure;
        report "tb_llama_top: NOTE -- this schedule contains "
             & integer'image(n_attn_blocks(SHAPE))
             & " attention block(s).  ATTENTION IS A STUB.  The residual "
             & "stream is well-formed and MEANINGLESS."
          severity warning;
      end if;
    end if;

    -- The exponent the lock captured at every completion of the LAST run.
    -- The residual is a BFP add: if two operands' exponents are far apart the
    -- smaller one shifts out entirely and contributes nothing, and the result
    -- is a perfectly deterministic number that ignores half its inputs.
    if VERBOSE then
    for i in 0 to NSTEP-2 loop
      report "tb_llama_top: step " & integer'image(i)
           & " opcode " & integer'image(PLAN(i).opcode)
           & " dst " & integer'image(PLAN(i).dst)
           & " captured y_exp " & integer'image(tr_exp(NRUNS-1)(i))
        severity note;
    end loop;
    end if;

    -- Per-region fingerprints, taken after the token.  R_X alone cannot say
    -- whether a unit's output reached the stream: if the step that CONSUMES
    -- that region produces zeros, R_X is identical whatever the unit did.
    if VERBOSE then
    for rg in 0 to NREGION-1 loop
      rsum <= 0;
      wait for 0 ns;
      for i in 0 to REGMAX-1 loop
        hr_reg  <= rg;
        hr_addr <= i;
        wait until rising_edge(clk);
        wait for 0.1 ns;
        -- A POSITIONAL HASH, NOT A SUM.  A sum is not a fingerprint: the
        -- behavioural norm removes the mean, so every post-norm region sums
        -- to nearly zero BY CONSTRUCTION and two completely different vectors
        -- give the same total.  That cost a wrong conclusion once -- see the
        -- measurement traps in
        -- docs/debugging/2026-08-28_llama-top-first-seams.md.
        rsum <= (rsum * 31 + to_integer(hr_data) + 40000) mod 100003;
      end loop;
      wait for 0 ns;
      report "tb_llama_top: region " & integer'image(rg) & " hash "
           & integer'image(rsum) severity note;
    end loop;
    end if;

    -- A checksum over the whole residual, not just element 0.  Element 0
    -- alone can coincide between two configurations that differ everywhere
    -- else, which makes it useless as the thing you eyeball when comparing
    -- a real unit against its behavioural model.
    xsum <= 0;
    wait for 0 ns;
    for i in 0 to SHAPE.hidden-1 loop
      xsum <= (xsum * 31 + results(0)(NTOK-1)(i) + 40000) mod 100003;
      wait for 0 ns;
    end loop;

    -- ---- verdict ---------------------------------------------------------
    fail <= n_bad_sched + n_bad_skew + n_bad_res + n_bad_pos + n_bad_kverr
          + kv_bad_wr + kv_bad_rd + kv_bad_dat + kv_bad_cov + kv_bad_bresp;
    wait for 0 ns;

    report "tb_llama_top: schedule mismatches=" & integer'image(n_bad_sched)
         & " skew differences=" & integer'image(n_bad_skew)
         & " degenerate residuals=" & integer'image(n_bad_res)
         & " token position faults=" & integer'image(n_bad_pos)
         & " KV sticky errors=" & integer'image(n_bad_kverr)
         & " KV faults=" & integer'image(kv_bad_wr + kv_bad_rd + kv_bad_dat
                                         + kv_bad_cov + kv_bad_bresp)
         & " (write placement " & integer'image(kv_bad_wr)
         & ", read placement " & integer'image(kv_bad_rd)
         & ", served bytes " & integer'image(kv_bad_dat)
         & ", coverage " & integer'image(kv_bad_cov)
         & ", bresp ordering " & integer'image(kv_bad_bresp) & ")"
      severity note;

    if fail = 0 then
      report "tb_llama_top RESULT: PASS -- " & integer'image(NSTEP)
           & " descriptors, " & integer'image(SHAPE.blocks)
           & " blocks, " & integer'image(NTOK)
           & " tokens per run, " & integer'image(NRUNS)
           & " descriptor-latency points, R_X bit-identical across all of "
           & "them, R_X(0) = " & integer'image(results(0)(NTOK-1)(0))
           & " hash(R_X) = " & integer'image(xsum)
           & LF & "        KV: attn_kv_axi instantiated = "
           & boolean'image(KV_AXI) & ", " & integer'image(kv_n_wrec)
           & " record write bursts retired and " & integer'image(kv_n_rbeat)
           & " read beats served, run 0 at " & integer'image(KV_RD_LAT)
           & "-cycle read latency and the other runs at swept ones, every "
           & "beat checked against this file's own evaluation of C spec "
           & "2.2's address equation."
           -- The phrase below deliberately avoids the literals sim/regress.sh
           -- greps for.  `IS NOT` is one of them and an earlier draft of this
           -- line contained it, which would have turned every passing gate
           -- run red.
           & LF & "        what this does NOT establish: there is no value "
           & "oracle for a whole token, so nothing here says the numbers are "
           & "attention.  That claim belongs to ref/attn_block_seq_vec.c and "
           & "sim/tb_attn_kv_seam.vhd, at the BLOCK level."
           -- Wording note: sim/regress.sh's FAIL_RE is a CASE-SENSITIVE
           -- grep -aqE containing the literals `IS NOT`, `IS WRONG`,
           -- `MISMATCH`, `FAILED`, `DIVERGES` and `\bFAIL\b`.  A report
           -- string containing any of them is judged red even on a passing
           -- run.  Lower case is safe; keep it that way.
           & LF & "        NOTE: " & integer'image(SHAPE.blocks)
           & " blocks with NORM_ANCHOR="
           & boolean'image(NORM_ANCHOR)
           & ".  The anchor is a PROBE standing in for an rmsnorm_rs that "
           & "the design does not yet instantiate, so this run exercises a "
           & "configuration the hardware cannot currently reach."
           & LF & "        NOTE: measured 2026-08-28, NRUNS=1, degenerate "
           & "residuals by depth -- anchored 0/0/3/8 and unanchored "
           & "5/12/27/56 at 4/8/16/32 blocks.  16 blocks and above do not "
           & "yet pass P6, and unanchored no depth passes at all.  The "
           & "scales do not track across blocks; this pass says nothing "
           & "about a 32-block token."
           & LF & "        NOTE: the real rmsnorm_rs is available as "
           & "NORM_REAL and is measured WORSE than the probe at every "
           & "depth, 6/14/28/59, because it emits an all-zero vector once "
           & "the residual stream leaves its 19-octave input magnitude "
           & "window, which happens in the second block."
        severity note;
    else
      report "tb_llama_top RESULT: FAIL" severity failure;
    end if;

    running <= false;
    wait;
  end process;

  -- ======================================================================
  -- The two copies of the region and opcode map must agree.  `llama_map_pkg`
  -- is in rtl/ because seq_opdec's consume mask is a GENERIC and the gateware
  -- therefore knows the region numbering; `seq_tbl_pkg` is in sim/ because
  -- the table is host data.  Two copies is the price; this is the check that
  -- makes a divergence stop a run instead of addressing the wrong region.
  -- ======================================================================
  mapchk : process is
  begin
    assert OP_A_JOB = seq_tbl_pkg.OP_A_JOB and OP_B_JOB = seq_tbl_pkg.OP_B_JOB
       and OP_C_JOB = seq_tbl_pkg.OP_C_JOB and OP_E_COLL = seq_tbl_pkg.OP_E_COLL
       and OP_VEC_NORM = seq_tbl_pkg.OP_VEC_NORM
       and OP_VEC_RES = seq_tbl_pkg.OP_VEC_RES
       and OP_VEC_SWG = seq_tbl_pkg.OP_VEC_SWG
       and OP_END_TOKEN = seq_tbl_pkg.OP_END_TOKEN
      report "tb_llama_top: llama_map_pkg and seq_tbl_pkg disagree about the "
           & "OPCODE numbering." severity failure;
    assert R_X = seq_tbl_pkg.R_X and R_XN = seq_tbl_pkg.R_XN
       and R_QKV = seq_tbl_pkg.R_QKV and R_Z = seq_tbl_pkg.R_Z
       and R_BETA = seq_tbl_pkg.R_BETA and R_ALPHA = seq_tbl_pkg.R_ALPHA
       and R_QG = seq_tbl_pkg.R_QG and R_KIN = seq_tbl_pkg.R_KIN
       and R_VIN = seq_tbl_pkg.R_VIN and R_Y = seq_tbl_pkg.R_Y
       and R_G = seq_tbl_pkg.R_G and R_U = seq_tbl_pkg.R_U
       and R_H = seq_tbl_pkg.R_H and R_ER = seq_tbl_pkg.R_ER
       and NREGION = seq_tbl_pkg.NREGION and R_NONE = seq_tbl_pkg.R_NONE
      report "tb_llama_top: llama_map_pkg and seq_tbl_pkg disagree about the "
           & "REGION numbering." severity failure;
    wait;
  end process;

end architecture;
