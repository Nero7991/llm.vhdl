-- rtl/rmsnorm_bf_mem.vhd
-- MEMORY-BACKED rmsnorm_bf.  2026-09-19.
--
-- WHAT THIS IS.  rtl/rmsnorm_bf.vhd with ONE change: the three flat
-- whole-vector ports become word streams into and out of LANES-way banked
-- block RAM held inside the unit.  It is EXACTLY the port-shape transformation
-- that produced rtl/rmsnorm_rs_mem.vhd from rtl/rmsnorm_rs.vhd (TRACK RMSMUX,
-- 2026-08-30): `diff rtl/rmsnorm_rs.vhd rtl/rmsnorm_rs_mem.vhd` was the
-- specification and `diff rtl/rmsnorm_bf.vhd rtl/rmsnorm_bf_mem.vhd` should
-- read the same hunk for hunk.  Every width, every rounding site, every
-- shift, the accumulation order, the block-floating mean + eps alignment and
-- the state machine are IDENTICAL, so o_mant/o_exp are bit-identical to
-- rmsnorm_bf element for element, and `done` fires on the same cycle.
--
-- HOW THE IDENTITY CLAIM IS CHECKED.  sim/tb_rmsnorm_bf_mem.vhd instantiates
-- rmsnorm_bf and this unit side by side on the same stimulus and asserts, per
-- trial: every o_mant element, o_exp, and the CYCLE `done` fires on, with no
-- tolerance anywhere.  The trials include the 9B embedding case (x_exp 19,
-- rms ~ 2^-6.35 -- the input rmsnorm_rs_mem clamps on), an in-window case,
-- and x_exp < 0.  The transitive chain to the real-valued oracle is:
-- rmsnorm_bf is bit-exact with ref/rmsnorm_bf_vec.c and within 1.8e-5 of a
-- double oracle (sim/tb_rmsnorm_bf.vhd), and this unit is bit-exact with
-- rmsnorm_bf (sim/tb_rmsnorm_bf_mem.vhd).  Both rows run at every gate.
--
-- WHY THIS EXISTS.  docs/debugging/2026-09-19_the-embedding-sits-below-the-
-- norms-window.md: the composed top (rtl/llama_top.vhd) instantiated
-- rmsnorm_rs_mem, whose fixed-grid mean-square clamp floors rms at 2^-6, and
-- the Qwen3.5-9B embedding row has rms 2^-6.35.  The card's XN came out
-- 0.75x and every q/k/v/z/alpha/beta of layer 0 inherited the factor.  The
-- fix, rmsnorm_bf (block-floating mean + real epsilon, 0.013% worst error
-- over the model's range, docs/debugging/2026-08-26_rmsnorm-magnitude-
-- window.md), had been RESOLVED for the UNIT since 2026-08-26 and never
-- reached the TOP because it only existed with flat 65,536-bit ports, which
-- TRACK RMSMUX measured at 40,934 CLB LUT / 17,408 MUXF7 / 8,704 MUXF8 for
-- the rs flavour at N = 4096.  This file is the missing _mem variant.
--
-- THE RAM INFERENCE IDIOMS ARE rmsnorm_rs_mem's, UNCHANGED, because they were
-- MEASURED there: 4,825 CLB LUT / 1,629 FF / 0 MUXF7 / 0 MUXF8 / 6 BRAM tiles
-- at N = 4096, LANES = 4 (hw/fk33/results/rmsmux_2026-08-30/).  vec_mem is
-- the repo's explicit `ram_style = "block"` SDP RAM with an initialiser; the
-- output write decode is TRACK WRITEDEC's combinational o_wd/o_we/o_wa form,
-- which in rmsnorm_bf still lived INSIDE the sequential process as a
-- runtime-sliced o_reg write (the form TRACK LUTDIET measured as an N-way
-- 16-bit demux per lane, 80.5% of the flat unit's LUTs).  Moving it out is
-- schedule-neutral: the bank write lands on the same rising edge the flat
-- register write used to, which the bench's done-cycle check asserts.
--
-- WHAT IS NOT THE SAME.  Only the readout: o_rdata is a registered RAM output
-- behind a LANES-to-1 select, so a reader sees word `o_raddr` ONE edge after
-- presenting it (MEASURED by the bench, not derived).  w_active is the
-- deadline tap TRACK RMSWIRE added to rs_mem, carried over unchanged.
--
-- THE FORBIDDEN OPTIMISATION IS STILL FORBIDDEN, and this is not it.
-- rmsnorm_bf.vhd's header bans STORING raw[j] because a 64x64 indexed array
-- was inferred as UNINITIALIZED distributed RAM and produced non-deterministic
-- hardware output.  raw[j] is still recomputed in the emit pass here; the
-- banks hold only x, w and o, in an explicit initialised block RAM.
--
-- DERIVED MECHANICALLY from rtl/rmsnorm_bf.vhd, once, by a substitution
-- script.  It is now a hand-maintained file: the guard that the two stay
-- bit-exact is the GATE BENCH, which runs every time, and NOT the script.
--
-- Everything below this line is rmsnorm_bf.vhd's own text, kept so the
-- arithmetic reasoning travels with the arithmetic.
-- ===========================================================================
-- Integer RMSNorm carrying mean + eps in BLOCK-FLOATING form.
--
-- WHY THIS EXISTS.  rmsnorm_rs.vhd is fast and bit-exact with rmsnorm.vhd, and
-- both of them are WRONG in a region the real model occupies.  They compute
-- x / sqrt(mean) with no epsilon at all, and floor the divisor with
--
--     if shifted_r < 1 then msq_r <= to_signed(1, 64);
--
-- which at Q = 12 is an epsilon of 2^-12 = 2.44e-4 standing in for the model's
-- 1e-6: 244x too large.  Measured on Qwen3.8-27B, that floor sits ABOVE the
-- median activation, so the unit applies a gain of 64 where ggml applies 901.
-- Over 14,800 random vectors the shipped recipe's worst relative gain error is
-- 1.0 -- not "imprecise", it returns the clamp, which carries no information
-- about the input.  Full account and the measurements:
--   docs/debugging/2026-08-26_rmsnorm-magnitude-window.md
--
-- THE FIX IS STRUCTURAL, NOT A WIDTH.  The obvious repair is to widen Q until
-- the epsilon is representable (2^12 * 1e-6 = 0.0041, below one LSB, so Q must
-- reach 20 to exist at all) and tighten the sum-of-squares assert so that
-- `S << Q` still fits s64.  That was tried, measured, and REJECTED: it still
-- leaves 2.0e-2 worst-case error, because the absolute-grid recipe rescales
-- mean into a FIXED 2^-Q grid BEFORE adding epsilon, so at the crossover -- the
-- one place the epsilon exists to handle, where mean ~ eps and the sum needs
-- both terms -- mean has already been rounded to a fraction of an LSB and the
-- add has nothing left to add to.  Resolving mean there wants Q ~ 30; Q <= 25
-- is a hard s64 ceiling at N = 128.  The two do not meet.
--
-- So this unit does not rescale to a fixed grid.  It keeps mean in the
-- block-floating form it already arrives in, expresses epsilon in the same form
-- ONCE at elaboration, aligns to the larger value and adds.  Measured against a
-- double golden over the same 14,800 vectors, the worst relative gain error is
-- then 8.8e-3 at Q = 12 and 5.2e-4 at Q = 16 -- and that residual is not the
-- algorithm, it is the output grid: it is invariant to the internal mantissa
-- width and scales 16x with Q, which is what pure output quantization does.
--
-- The same move is already proved on this exact hazard by l2norm_rs.vhd, which
-- keeps the Newton rsqrt's Q30 mantissa and applies its exponent as a scalar
-- shift at emit rather than collapsing it to an integer.  The difference is
-- that l2norm is scale-free, so its exponent CANCELS; RMSNorm's does not,
-- because epsilon is in absolute units, and that is precisely why RMSNorm
-- needs the alignment and l2norm does not.
--
-- WHAT CHANGED FROM rmsnorm_rs.vhd, and nothing else:
--
--   1. S_INV1..S_INV6 no longer form `num = S << Q`, divide by N on that grid,
--      shift by 2*x_exp and clamp.  They renormalise S to a 31-bit mantissa,
--      carry (log2 N + 2*x_exp + shift) as its exponent, align epsilon to it,
--      and add.  Still one operation per state.
--
--   2. The rsqrt divides out e_out rather than Q (`rq_d := rq_p - e_out_r`),
--      because msq_r is no longer on a fixed 2^-Q grid.  Q keeps its OTHER
--      role unchanged -- the output grid of inv32 -- which is why it stays a
--      generic.
--
--   3. The `S < 2^46` assert is replaced by the true bound `S < 2^(30+log2 N)`.
--      The old one existed only to keep `S << Q` inside s64; that shift is
--      gone.  It was also 512x looser than reality and would have permitted a
--      silent s64 overflow the moment Q moved above 16.
--
-- CONSEQUENCE, stated plainly: this unit is NOT bit-exact with rmsnorm.vhd, and
-- cannot be.  It is deliberately different from it in the region where
-- rmsnorm.vhd is wrong.  So it needs a REAL-VALUED golden of its own rather
-- than a side-by-side against the original.  ref/rmsnorm_eps_vec.c establishes
-- the GAIN against a double golden, which is what settled the design.
--
-- VERIFIED, 2026-08-26.  The full-path golden is ref/rmsnorm_bf_vec.c and the
-- testbench is sim/tb_rmsnorm_bf.vhd.  The golden carries TWO paths that share
-- nothing: a bit-exact transcription of this datapath (which the testbench
-- compares against with NO tolerance) and an independent double oracle written
-- as the definition alone.  Both are needed -- a golden that shares machinery
-- with the DUT certifies broken units, which is exactly how the l2norm
-- collapse survived 55 passing cases, and the integer path alone would
-- reproduce a wrong recipe faithfully.
--
--   * bit-exact on 200 cases x 128 elements plus every o_exp, and on 20
--     generic combinations: LANES in {1,2,4,8,16,32}, Q in {8,12,16,20,22,24},
--     N in {64,128,256,512}, eps in {1e-5, 1e-6, 5e-7, 1e-8}, several seeds.
--   * against the double oracle, worst relative gain error is 1.8e-5 over the
--     model's MEASURED log2(rms) range of [-29.63, -0.54], and worst output
--     error is 0.77 LSB of the emitted grid.  2.4e-3 over the wider sweep,
--     which is the 2^-Q output grid of inv32 at gains near 0.06 and not the
--     block-floating recipe -- the same distinction the design study drew.
--   * mutation-tested: 14 of 18 deliberate RTL faults are caught, including
--     a constant rsqrt seed and a dropped Newton iteration, both of which
--     tb_rmsnorm_rs.vhd needed a magnitude sweep to see at all.
--
-- ONE DEFECT WAS FOUND AND FIXED by writing it: the sum-of-squares assert at
-- S_INV1 was strict where the bound is attained.  See the note there.
--
-- What the testbench CANNOT prove, recorded rather than left to be assumed:
-- the -32768 emit rail and the inv32 low clamp are unreachable by
-- construction; rq_E > 32 needs Q > 52; the S = 0 guards cannot be observed
-- at o_mant/o_exp at all (S = 0 forces an all-zero output whatever inv32 is)
-- and are held only by the S_SEED2 assert; and a one-LSB perturbation of the
-- mean mantissa -- rounding the alignment instead of truncating it, rounding
-- the S renormalisation, or moving M_EPS_C by one -- is invisible at every Q
-- tested, which is the measured form of the design study's claim that the
-- truncating form costs nothing.  ref/rmsnorm_bf_vec.c prints a branch
-- coverage table on every run and names what it did not reach.
--
-- Subsystems A and C are unaffected and keep rmsnorm_rs.vhd: their goldens
-- assert bit-exactness with rmsnorm.vhd, and changing the arithmetic under them
-- would break that contract for a fix they have not yet been shown to need.
--
-- Everything below this point about narrowing, MREG, LANES and the one-op-per-
-- state rule is inherited from rmsnorm_rs.vhd unchanged, and the reasoning for
-- it is:
--
--   * NARROWED multiplies -- lossless, each justified by a bound ASSERTED at
--     run time, so a violated assumption fails loudly instead of silently.
--   * MREG on the Newton multiplies.  32x32 is a DSP48E2 CASCADE (the
--     primitive is 27x18) and without a register between partial products it
--     pinned the narrowed skeletons at 278.9 MHz.  Inferred by `m <= a*b;
--     p <= m;` with no logic between -- and "no logic between" has to include
--     the SELECT: one pair shared by all three Newton multiplies is a mux on
--     the DSP output, which blocks the absorption and puts the partial-product
--     sum back in fabric.  There is now one pair per multiply.  See the
--     declarations of mr_m_yy / mr_m_sy / mr_m_dy and
--     docs/debugging/2026-08-27_rmsnorm-max-tree-measured-worse.md.
--   * LANES.  Bit-exact under lane-parallel reduction because both element
--     reductions are order-independent: an exact integer sum and a maximum.
--   * raw[j] is still RECOMPUTED in the emit pass rather than stored.  Storing
--     it is FORBIDDEN: rmsnorm.vhd records that a 64x64 indexed array was
--     inferred as UNINITIALIZED distributed RAM in the congested engine and
--     produced NON-DETERMINISTIC hardware output.
--
-- STRUCTURE.  One operation per state -- never two of {barrel shift, 64-bit
-- add, wide compare, bus mux, multiply} in series.  That rule is not taste; it
-- is what took rmsnorm_rs from 117.2 MHz to 300.8, measured seven times.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use ieee.math_real.all;
use work.fixed_pkg.all;
use work.fixed_luts_pkg.all;
use work.util_pkg.all;

entity rmsnorm_bf_mem is
  generic(
    N     : positive;
    -- Elements processed per cycle.  Must divide N.  4 is B 3.3's target; 1
    -- reproduces rmsnorm.vhd's element rate exactly and is the fallback.
    LANES : positive := 4;
    Q     : integer  := 12;
    -- The model's epsilon, as a real.  It is resolved to a normalised integer
    -- mantissa at ELABORATION (M_EPS_C / E_EPS below), so nothing about it
    -- costs fabric.  Qwen3.8-27B's f_norm_rms_eps is 1e-6.
    EPS   : real     := 1.0e-6
  );
  port(
    clk    : in  std_logic;
    rst    : in  std_logic;
    start  : in  std_logic;
    -- RMSMUX.  The three flat whole-vector ports (3 x N*16 = 196,608 bits at
    -- N = 4096) become word streams into and out of LANES-way banked block
    -- RAM.  Word index i lives in bank (i mod LANES) at offset (i / LANES),
    -- which is EXACTLY the order the three element passes walk it, so each
    -- pass reads one word per bank per cycle and the compute schedule is
    -- unchanged.  Port names, widths and semantics are rmsnorm_rs_mem's, so
    -- rtl/llama_top.vhd's port map is like-for-like.
    x_we    : in  std_logic;
    x_waddr : in  std_logic_vector(clog2(N)-1 downto 0);
    x_wdata : in  std_logic_vector(15 downto 0);
    x_exp   : in  integer;
    w_we    : in  std_logic;
    w_waddr : in  std_logic_vector(clog2(N)-1 downto 0);
    w_wdata : in  std_logic_vector(15 downto 0);
    w_exp   : in  integer;
    done    : out std_logic;
    -- READ LATENCY IS ONE EDGE, MEASURED by sim/tb_rmsnorm_bf_mem.vhd and
    -- not asserted here on reasoning.  The RAM output register and the
    -- lane-select register both capture from the SAME combinational
    -- o_raddr, so they are in parallel and not in series: a reader
    -- presenting o_raddr at edge k sees the word at edge k+1.  Stated as a
    -- contract because it is the ONLY externally visible timing difference
    -- from rmsnorm_bf.
    o_raddr : in  std_logic_vector(clog2(N)-1 downto 0);
    o_rdata : out std_logic_vector(15 downto 0);
    o_exp   : out integer;
    -- THE DEADLINE TAP (TRACK RMSWIRE).  High on every cycle of the two
    -- element passes that read `w` (S_RAW and S_EMIT) and low everywhere
    -- else, so a parent that streams `w` concurrently with the run can name
    -- the instant its load must have landed by.  A COMBINATIONAL decode of a
    -- state register that already exists; drives nothing inside this unit;
    -- safe to leave unassociated.  IT IS NOT A HANDSHAKE: it reports, it
    -- does not stall.
    w_active : out std_logic
  );
end entity;

architecture rtl of rmsnorm_bf_mem is
  constant LOG2N : natural := clog2(N);
  constant NB    : natural := N / LANES;          -- beats per element pass

  constant THREE_Q30   : signed(33 downto 0) := shift_left(to_signed(3, 34), 30);
  constant INV_SQRT2_C : signed(31 downto 0) := to_signed(759250125, 32);

  -- S_INV is split FOUR ways, and that split is the whole reason this unit
  -- reaches its clock.  The first version did the mean divide, the exponent
  -- shift, the clamp, the 63-bit MSB scan, the normalising barrel shift and
  -- the ROM lookup in ONE state, on the theory that leaving the Newton states
  -- as pure multiplies was what mattered.  MEASURED: 117.2 MHz, worse than
  -- rmsnorm.vhd's own 138.4 -- the critical path was xe_reg -> DSP A input,
  -- 40 logic levels with 16 CARRY8, none of it a multiply.  Chasing MREG on
  -- the Newton stage would never have found it.
  type state_t is (S_IDLE, S_ACC,
                   S_INV1, S_INV2, S_INV3, S_INV4, S_INV5, S_INV6,
                   S_SEED1, S_SEED2,
                   S_RQ, S_RQ_RT1, S_RQ_RT2, S_RQ_FOLD, S_RQ_FIN1, S_RQ_FIN2, S_RQ_FIN3, S_RQ_CLAMP,
                   S_RAW, S_SHIFT1, S_SHIFT2, S_EMIT);
  signal state : state_t := S_IDLE;

  -- Newton walks a step counter rather than 12 named states.  Two cycles per
  -- multiply is FORCED by the MREG: with `mr_m <= a*b` and `mr_p <= mr_m` the
  -- product is not in mr_p until TWO cycles after issue, so a consumer one
  -- cycle later reads the PREVIOUS multiply's result.  The first version of
  -- this file did exactly that and would have produced a wrong inv32 with no
  -- structural symptom.  Even steps issue and consume; odd steps are the
  -- register hop that buys the MREG.
  signal rq_step : natural range 0 to 19 := 0;

  -- ---- scalar path.  ONE instance, so it is left at generous widths; the
  -- DSP cost lives in the per-lane multiplies and in the rsqrt, both narrowed.
  signal S           : signed(63 downto 0) := (others => '0');
  signal xe, we      : integer := 0;
  signal inv32       : signed(31 downto 0) := (others => '0');
  signal max_raw     : unsigned(62 downto 0) := (others => '0');
  signal shift_total : integer := 0;

  -- ---- rsqrt state, NARROWED to 32/34 bits.
  -- Bounds, all asserted below:
  --   rq_mant is normalised so bit 30 is set  -> smant in [2^30, 2^31)
  --   the ROM seed is 1/sqrt(m) in Q30, m in [1,2) -> y in (0.707*2^30, 2^30]
  --   y2 = y*y >> 30                          -> y2 in (0.5*2^30, 2^30]
  --   diff = 3*2^30 - my2, my2 ~ 2^30         -> |diff| < 3*2^30, needs s34
  --
  -- NARROWING rq_diff TO s32 WAS CONSIDERED AND REJECTED, 2026-08-27, twice
  -- over.  It is not merely tight, it OVERFLOWS: instrumenting
  -- ref/rmsnorm_bf_vec.c over its 200-case sweep gives diff in
  -- [2131803105, 2147654557], and the top of that is above s32's 2147483647.
  -- The bound is structural, not a sampling accident: my2 <= 2^31-1 forces
  -- diff > 3*2^30 - 2^31 = 2^30 and diff is at its largest exactly where the
  -- Newton iteration has converged, my2 -> 2^30, giving diff -> 2^31.  It is
  -- always POSITIVE, so unsigned(31 downto 0) would hold it -- but that buys
  -- nothing: the DSP48E2 multiplier is 27x18 signed (26x17 unsigned), so 34x32,
  -- 32x32 and u32xu32 are all TWO A-chunks by TWO B-chunks, four partial
  -- products, one cascade.  The premise that 32 bits "fits without a cascade"
  -- is simply not true of this primitive.
  signal rq_y, rq_smant, rq_y2, rq_my2 : signed(31 downto 0) := (others => '0');
  signal rq_diff  : signed(33 downto 0) := (others => '0');
  signal rq_yfin  : signed(31 downto 0) := (others => '0');
  signal rq_p     : integer := 0;
  signal rq_E     : integer := 0;
  -- carried between the split S_INV / seed states
  signal msq_r    : signed(63 downto 0) := (others => '0');
  signal mant_r   : unsigned(63 downto 0) := (others => '0');
  signal msb_p    : integer := 0;
  signal rq_shifted : signed(63 downto 0) := (others => '0');
  -- ---- block-floating mean + eps ----------------------------------------
  -- Both terms are carried as (mantissa, e) meaning mantissa * 2^-e, so a
  -- LARGER e is a FINER grid and therefore a SMALLER value at equal mantissa.
  --
  -- E_EPS is chosen so the epsilon mantissa normalises into [2^30, 2^31),
  -- which is what makes M_EPS_C fit a 32-bit signed integer for ANY EPS and
  -- puts it on the same grid the rsqrt seed already expects.
  constant E_EPS   : integer := 30 - integer(floor(log2(EPS)));
  constant M_EPS_C : signed(63 downto 0) :=
      to_signed(integer(round(EPS * 2.0**real(E_EPS))), 64);
  signal s_msb        : integer := 0;
  signal shs_r        : integer := 0;
  signal e_mean       : integer := 0;
  signal e_out_r      : integer := 0;
  signal d_r          : integer := 0;
  signal mean_smaller : boolean := true;
  signal m_mean_r, align_r : signed(63 downto 0) := (others => '0');
  signal rq_bias_r, rq_sum_r : signed(63 downto 0) := (others => '0');
  signal rq_sh_r  : integer := 0;
  -- The emit rounding bias depends only on shift_total, which is fixed for the
  -- whole pass, so it is computed ONCE rather than per element per lane.
  signal emit_bias : signed(63 downto 0) := (others => '0');
  signal rq_up_r  : boolean := false;
  -- MREG/PREG pairs: two registers, no logic between, ONE PAIR PER DISTINCT
  -- NEWTON MULTIPLY.
  --
  -- MEASURED, 2026-08-27, and the reason these are three pairs and not one.
  -- They used to be a SINGLE 66-bit `mr_m`/`mr_p` pair written from inside the
  -- `rq_step` case, so all three products -- y*y, smant*y2 and diff*y -- landed
  -- in the same register through a 4-way select (three products plus the hold).
  -- That select is logic between the multiplier and its M register, so Vivado
  -- could not absorb the M register into the DSP48E2 at all: the whole 32x32 /
  -- 34x32 partial-product tree (the primitive is 27x18, so every one of these
  -- is four partial products) had to be summed in FABRIC and then muxed.  The
  -- post-route critical path of the assembled emit chain was
  --   u_rms/ARG__20/DSP_A_B_DATA_INST/CLK -> u_rms/mr_m_reg[54]/D,
  --   logic 2.677 ns, net 1.289 ns  (72% LOGIC)
  -- i.e. a DSP's own A/B input register, through the multiplier, through the
  -- fabric partial-product adder, through the result mux, into bit 54 of the
  -- shared register.  Bit 54 is above anything one DSP48E2's 48-bit P can hold,
  -- which is the tell that the summation was in fabric rather than in a
  -- PCOUT->PCIN cascade.
  --
  -- With one pair per product each register directly follows its multiply with
  -- NOTHING between, which is the pattern Vivado requires to build the cascade
  -- with internal MREG/PREG.  It also removes the write enable: each product is
  -- recomputed UNCONDITIONALLY on every S_RQ cycle, so there is no select on
  -- the DSP inputs either.  Costs three multipliers where the shared form left
  -- resource sharing free to fold them onto one, and takes the declared state
  -- from 132 to 388 bits -- which is a FABRIC cost only if the absorption
  -- fails, since that is what these registers exist to become.
  --
  -- Widths are the NATURAL product widths, not a uniform 66: s32*s32 is exactly
  -- s64 and s34*s32 is exactly s66, so every `resize` below is the identity and
  -- the two redundant sign bits that the old uniform 66 carried do not have to
  -- be produced by the cascade.
  signal mr_m_yy, mr_p_yy : signed(63 downto 0) := (others => '0');  -- y * y
  signal mr_m_sy, mr_p_sy : signed(63 downto 0) := (others => '0');  -- smant*y2
  signal mr_m_dy, mr_p_dy : signed(65 downto 0) := (others => '0');  -- diff * y
  -- A FOURTH pair, for the 1/sqrt(2) fold.  Added 2026-08-27 because the
  -- measured 0.717 V post-route critical path of gdn_emit_chain lands here:
  --   u_rms/ARG__18/DSP_A_B_DATA_INST/CLK -> u_rms/rq_yfin_reg[28]/D
  --   slack -1.456 ns, logic 3.674 / net 0.932 ns  (79.8% LOGIC)
  -- The startpoint is the DSP's own A/B input register, so the path was the
  -- WHOLE multiply combinationally, then a select, then a mux, then the
  -- destination flop -- in one state.  That is the project's timing rule
  -- broken twice over, and it is the same shape the three pairs above were
  -- created to fix; this multiply was simply never given one.
  signal mr_m_rt, mr_p_rt : signed(63 downto 0) := (others => '0');  -- y * 1/sqrt2

  -- ---- element pipeline
  type s17a is array(0 to LANES-1) of signed(16 downto 0);
  type s48a is array(0 to LANES-1) of signed(47 downto 0);
  type s64a is array(0 to LANES-1) of signed(63 downto 0);
  -- FETCH stage.  Selecting one element out of the N*16 bus is a 128-to-1
  -- mux (MUXF7/MUXF8), and putting it in the same stage as the multiply made
  -- idx -> mux -> DSP the critical path at 257.0 MHz.  Registering the fetch
  -- separates the mux from the multiplier and gives the multiply registered
  -- operands, which is also what a DSP AREG/BREG wants.
  type s16a is array(0 to LANES-1) of signed(15 downto 0);
  -- RMSMUX.  xf/wf/xa were the registers that captured the output of the
  -- N-to-1 bus mux.  A block RAM's own output register IS that register,
  -- with the SAME one-cycle latency and the same address source, so they are
  -- replaced ONE FOR ONE by x_q/w_q and no pipeline stage moves.
  signal vf      : std_logic := '0';
  signal va, vb  : std_logic := '0';
  signal x_q, w_q : s16a := (others => (others => '0'));
  constant LB    : natural := clog2(LANES);       -- bank-index width
  constant AB    : natural := clog2(NB);          -- per-bank address width
  signal ram_ra  : std_logic_vector(AB-1 downto 0) := (others => '0');
  signal o_we    : std_logic := '0';
  signal o_wa    : std_logic_vector(AB-1 downto 0) := (others => '0');
  type   sl16a is array(0 to LANES-1) of std_logic_vector(15 downto 0);
  signal x_bwe, w_bwe : std_logic_vector(LANES-1 downto 0) := (others => '0');
  signal x_bq, w_bq, o_bq : sl16a;
  signal o_rsel  : std_logic_vector(LB downto 0) := (others => '0');
  type s32a is array(0 to LANES-1) of signed(31 downto 0);
  signal sq      : s32a := (others => (others => '0'));
  signal idxf    : natural range 0 to NB := 0;
  signal p1_xinv : s48a := (others => (others => '0'));   -- xm * inv   (s16 x s32)
  signal p1_wm   : s17a := (others => (others => '0'));   -- wm carried alongside
  -- THE MREG/PREG PAIR FOR THE SECOND MULTIPLY.  Measured post-route on
  -- xcvu33p-fsvh2104-2LV-e at the card's real 0.717 V, gdn_emit_chain at
  -- HEADS=24 DIM=128 SILU_LANES=16 RMS_LANES=4, 3.3 ns target:
  --
  --   u_rms/ARG__21/DSP_A_B_DATA_INST/CLK -> u_rms/p2_raw_reg[2][63]/D
  --   slack -1.007, logic 3.600 ns, net 0.530 ns, i.e. 87% LOGIC
  --
  -- The startpoint is the DSP's own A/B input register, so p1_xinv and p1_wm
  -- were absorbed into AREG/BREG and then the ENTIRE 48x17 multiply plus the
  -- resize ran combinationally out to a fabric flop.  The DSP's own MREG and
  -- PREG sat unused.  That is the same shape the three Newton pairs and the
  -- 1/sqrt(2) fold pair above were created to fix; this multiply, like the
  -- fold before it, was simply never given one.
  --
  -- p2_m is the MREG, p2_raw stays the PREG.  Back to back with NOTHING
  -- between them, which is what lets the tool put both inside the DSP48.
  --
  -- WHY THE NEW STAGE IS INSERTED BEFORE (p2_raw, v2, idx2) RATHER THAN
  -- AFTER, and this is the whole reason the change is safe.  p2_raw has TWO
  -- consumers on different schedules: the pass-2 max tree reads it at stage 2a
  -- gated by `vt(0) <= v2`, and the pass-3 emit reads it at stage 3 gated by
  -- `v3 <= v2` with `idx3 <= idx2`.  Both pair the DATA with v2, and pass 3
  -- also pairs it with idx2.  Keeping those three names on the LAST of the two
  -- new stages means every consumer keeps the identical pairing it already had
  -- and shifts by exactly one cycle automatically.  Renaming the far end
  -- instead, and re-timing each consumer by hand, is how a value from the
  -- wrong pass reaches a correct-looking consumer -- silent, and the defect
  -- class this project hit three times on 2026-08-27.
  signal p2_m    : s64a := (others => (others => '0'));   -- DSP MREG
  signal p2_raw  : s64a := (others => (others => '0'));   -- DSP PREG
  signal v1, v2m, v2, v3 : std_logic := '0';

  -- ---- max|raw| reduction, PIPELINED.  See the long note at S_RAW.
  -- TLEV is the number of comparison levels in the balanced tree; LANES is a
  -- power of two because it divides N and N is asserted to be one, so the
  -- halving is exact and TLEV = log2(LANES).  At LANES = 1 it is 0 and the
  -- tree degenerates to the abs stage alone, which is what that configuration
  -- should cost.
  constant TLEV : natural := clog2(LANES);
  type u63a   is array(0 to LANES-1) of unsigned(62 downto 0);
  type tree_t is array(0 to TLEV) of u63a;
  -- mt(0) holds the per-lane |raw|; mt(l) holds level l of the tree, of which
  -- only the first LANES/2**l entries are ever driven.  The rest are never
  -- assigned and never read, so they carry no fabric.
  signal mt : tree_t := (others => (others => (others => '0')));
  signal vt : std_logic_vector(0 to TLEV) := (others => '0');
  signal p3_sum  : s64a := (others => (others => '0'));
  signal idx     : natural range 0 to NB := 0;
  signal idx1, idx2m, idx2, idx3 : natural range 0 to NB := 0;

  -- ---- the output register's WRITE DECODE --------------------------------
  -- TRACK WRITEDEC, 2026-08-29, applied here as rmsnorm_rs_mem applies it.
  -- rmsnorm_bf's emit stage writes o_reg with a slice whose base is a runtime
  -- variable (`base := idx3 * LANES; o_reg((base+k+1)*16-1 downto ...)`),
  -- which Vivado infers as an N-way 16-bit DEMUX per lane -- MEASURED by
  -- TRACK LUTDIET at 162,276 of 201,651 LUT primitives, 80.5% of the flat
  -- unit at N = 4096 / LANES = 4, with ZERO MUXF7/MUXF8 so the read-mux
  -- signature does not find it.  The saturate-and-place moves out of the
  -- sequential process into a COMBINATIONAL o_wd, and the write target
  -- becomes ONE RAM address.  No arithmetic moves, no pipeline stage is
  -- added, and the schedule is unchanged CYCLE FOR CYCLE: `done` still fires
  -- on exactly the same cycle it always did.
  --
  -- WHY COMBINATIONAL AND NOT REGISTERED.  Registering {o_we, o_wa, o_wd}
  -- inside the FSM costs one extra cycle on `done`, and `done` is what the
  -- top level and the pinned sequencer landmarks wait on.  The combinational
  -- form is what rmsnorm_bf already computed -- p3_sum -> shift -> clamp ->
  -- write, in one cycle -- with only the assignment TARGET changed.
  signal o_wd : std_logic_vector(LANES*16-1 downto 0) := (others => '0');
begin

  -- The emit stage's saturate-and-place, verbatim, as combinational logic.
  -- This is the SAME expression rmsnorm_bf's sequential process evaluates;
  -- only where its result is deposited has changed.
  p_owd : process(p3_sum, shift_total)
    variable omc : signed(63 downto 0);
  begin
    for k in 0 to LANES-1 loop
      omc := shift_right(p3_sum(k), shift_total);
      if    omc > 32767  then
        o_wd((k+1)*16-1 downto k*16) <= std_logic_vector(to_signed(32767, 16));
      elsif omc < -32768 then
        o_wd((k+1)*16-1 downto k*16) <= std_logic_vector(to_signed(-32768, 16));
      else
        o_wd((k+1)*16-1 downto k*16) <= std_logic_vector(resize(omc, 16));
      end if;
    end loop;
  end process;

  -- The write decode.  `rst = '0' and state = S_EMIT and v3 = '1'` is exactly
  -- the guard rmsnorm_bf's write sits under -- the rst term is the outer
  -- if/else of the FSM process and it matters, because rst does NOT clear v3
  -- and `state` still reads S_EMIT on the cycle rst is taken.  It is
  -- COMBINATIONAL, so the bank write lands on the same rising edge the flat
  -- register write used to.
  o_we <= '1' when (rst = '0' and state = S_EMIT and v3 = '1' and idx3 < NB)
          else '0';
  o_wa <= std_logic_vector(to_unsigned(idx3, AB)) when idx3 < NB
          else (others => '0');

  -- The banked memories.  vec_mem is the repo's existing forced-block SDP
  -- RAM, added 2026-07-27 for exactly this trade on swiglu/bfp_pack.
  gbank : for k in 0 to LANES-1 generate
    gsel1 : if LANES = 1 generate
      x_bwe(0) <= x_we;
      w_bwe(0) <= w_we;
    else generate
      x_bwe(k) <= x_we when unsigned(x_waddr(LB-1 downto 0)) = k else '0';
      w_bwe(k) <= w_we when unsigned(w_waddr(LB-1 downto 0)) = k else '0';
    end generate;

    ux : entity work.vec_mem generic map(WORDS => NB, W => 16)
      port map(clk => clk, we => x_bwe(k),
               waddr => x_waddr(clog2(N)-1 downto LB),
               raddr => ram_ra, din => x_wdata, dout => x_bq(k));
    uw : entity work.vec_mem generic map(WORDS => NB, W => 16)
      port map(clk => clk, we => w_bwe(k),
               waddr => w_waddr(clog2(N)-1 downto LB),
               raddr => ram_ra, din => w_wdata, dout => w_bq(k));
    uo : entity work.vec_mem generic map(WORDS => NB, W => 16)
      port map(clk => clk, we => o_we, waddr => o_wa,
               raddr => o_raddr(clog2(N)-1 downto LB),
               din => o_wd((k+1)*16-1 downto k*16), dout => o_bq(k));

    x_q(k) <= signed(x_bq(k));
    w_q(k) <= signed(w_bq(k));
  end generate;

  -- The read address the three element passes present.  COMBINATIONAL from
  -- idx, so the RAM output register lands the word on exactly the edge
  -- xa/xf/wf used to.
  ram_ra <= std_logic_vector(to_unsigned(idx, AB)) when idx < NB
            else (others => '0');

  -- The output word stream.  A LANES-to-1 select, not an N-to-1 one, and it
  -- is registered so it tracks the RAM's own output register.
  process(clk) begin
    if rising_edge(clk) then
      if LANES = 1 then
        o_rsel <= (others => '0');
      else
        o_rsel <= std_logic_vector(resize(unsigned(o_raddr(LB-1 downto 0)),
                                          LB+1));
      end if;
    end if;
  end process;
  o_rdata <= o_bq(to_integer(unsigned(o_rsel)));

  -- The deadline tap.  See the port comment.  S_RAW is the FIRST cycle any
  -- `w` word is read; S_EMIT is the second pass that reads it again.
  w_active <= '1' when (state = S_RAW or state = S_EMIT) else '0';


  assert N mod LANES = 0
    report "rmsnorm_bf_mem: LANES must divide N" severity failure;
  assert 2**LOG2N = N
    report "rmsnorm_bf_mem: N must be a power of two (the mean divide is a shift)"
    severity failure;
  assert 2**LB = LANES
    report "rmsnorm_bf_mem: LANES must be a power of two -- the bank index "
         & "is the low bits of the word index" severity failure;

  process(clk)
    variable xm_j, wm_j : signed(15 downto 0);
    variable sq_sum     : signed(63 downto 0);
    variable num, msq   : signed(63 downto 0);
    variable bias64     : signed(63 downto 0);
    variable sh, p      : integer;
    variable A          : unsigned(63 downto 0);
    variable mant       : unsigned(63 downto 0);
    variable rq_d, rq_he: integer;
    variable rq_r       : signed(63 downto 0);
    variable rq_bias    : signed(63 downto 0);
    variable rq_sh      : integer;
    variable ob         : signed(63 downto 0);
    variable st         : integer;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state <= S_IDLE; done <= '0'; v1 <= '0'; v2m <= '0'; v2 <= '0';
        vt <= (others => '0');
        S <= (others => '0'); max_raw <= (others => '0');
      else
        done <= '0';
        case state is

          when S_IDLE =>
            if start = '1' then
              S <= (others => '0');
              max_raw <= (others => '0');
              xe <= x_exp; we <= w_exp;
              idx <= 0; va <= '0'; vb <= '0';
              v1 <= '0'; v2 <= '0'; vf <= '0'; vt <= (others => '0');
              state <= S_ACC;
            end if;

          -- ---- pass 1 of 3: sum of squares, LANES per cycle ---------------
          -- NARROWED: xm*xm is 16x16 -> 32 bits, not the original's 64x64.
          -- Lossless because |xm| <= 32768 exactly.  The sum is an exact
          -- integer add, so reducing LANES terms per cycle in any order gives
          -- the identical total -- this is what makes vectorising bit-exact.
          -- Three stages for the same reason the element passes have them:
          -- fused, this was idx -> 128:1 mux -> DSP square -> 64-bit
          -- accumulate in one cycle, and it measured as the critical path at
          -- 260.1 MHz once everything ahead of it had been split.
          when S_ACC =>
            -- stage A: bus mux only
            if idx < NB then
              -- RMSMUX: no mux here any more.  ram_ra is already idx.
              va <= '1'; idx <= idx + 1;
            else
              va <= '0';
            end if;
            -- stage B: square from a registered operand
            vb <= va;
            for k in 0 to LANES-1 loop
              sq(k) <= resize(x_q(k) * x_q(k), 32);
            end loop;
            -- stage C: the accumulate, alone
            if vb = '1' then
              sq_sum := (others => '0');
              for k in 0 to LANES-1 loop
                sq_sum := sq_sum + resize(sq(k), 64);
              end loop;
              S <= S + sq_sum;
            end if;
            if idx = NB and va = '0' and vb = '0' then
              idx <= 0; state <= S_INV1;
            end if;

          -- ---- mean_sq_q and the seed, ONE operation per state ------------
          -- The rule this chain follows, arrived at by measurement rather than
          -- taste: never put two of {barrel shift, 64-bit add, wide compare}
          -- in series in one state.  Every violation of it showed up as the
          -- critical path in turn -- 117.2 MHz with the whole thing in one
          -- state, then 219.6 with the shift/add/shift/clamp cone still fused.
          -- The states are free: the fixed cost is ~30 cycles against a
          -- 3N/LANES element loop that is 96 at N=128, LANES=4.
          when S_INV1 =>
            -- The OLD assert here was S < 2^46, and it existed only to keep
            -- `S << Q` inside s64.  There is no such shift any more, so this
            -- asserts the REAL bound instead.
            --
            -- The bound is `<=`, and that is not slack.  The first version of
            -- this line was `S < 2^(30+log2 N)`, written from a comment that
            -- said "S <= N * 32767^2" -- but the input is int16, so the
            -- largest square is (-32768)^2 = 2^30 EXACTLY, not 32767^2.  An
            -- all -32768 vector therefore attains N * 2^30 = 2^(30+log2 N) on
            -- the nose, and the strict form failed on legal input.  Caught by
            -- sim/tb_rmsnorm_bf.vhd, whose generator constructs that vector
            -- deliberately (ref/rmsnorm_bf_vec.c case 1) precisely because a
            -- bound that is attained rather than approached is where an
            -- off-by-one lives.  Nothing in the datapath was wrong: S is s64,
            -- 2^37 fits, and the renormalisation handles it.  Only the check
            -- was.  tb_rmsnorm_rs.vhd already drove -32768 for the same
            -- reason, against the looser 2^46 bound that hid it.
            assert S >= 0 and S <= shift_left(to_signed(1, 64), 30 + LOG2N)
              report "rmsnorm_bf_mem: sum of squares out of the assumed range"
              severity failure;
            p := 0;                                          -- one wide scan
            for i in 0 to 62 loop
              if S(i) = '1' then p := i; end if;
            end loop;
            s_msb <= p;
            state <= S_INV2;

          when S_INV2 =>                       -- narrow exponent arithmetic only
            -- mean = S * 2^-(log2 N) * 2^-2xe, so in (m, e) form m = S and
            -- e = log2 N + 2xe.  Renormalising S by shs shifts e with it.
            shs_r  <= 30 - s_msb;
            e_mean <= LOG2N + 2 * xe + (30 - s_msb);
            state  <= S_INV3;

          when S_INV3 =>                                     -- one barrel shift
            if S = 0 then
              m_mean_r <= (others => '0');
            elsif shs_r >= 0 then
              m_mean_r <= shift_left(S, shs_r);
            else
              m_mean_r <= shift_right(S, -shs_r);
            end if;
            state <= S_INV4;

          when S_INV4 =>                                -- narrow compare/select
            -- Align to the LARGER VALUE, i.e. the SMALLER e.  Whichever term
            -- is negligible is then the one that falls off the bottom, which
            -- is the entire point: at the crossover (mean ~ eps) both survive,
            -- and outside it the correct one vanishes.
            if S = 0 then
              -- mean is exactly zero, so the sum is eps alone.  Without this
              -- branch e_mean is meaningless and would drive the alignment.
              d_r <= 0; mean_smaller <= true;  e_out_r <= E_EPS;
            elsif e_mean > E_EPS then                     -- mean is the smaller
              if e_mean - E_EPS > 63 then d_r <= 63;
              else                        d_r <= e_mean - E_EPS; end if;
              mean_smaller <= true;  e_out_r <= E_EPS;
            else                                          -- eps is the smaller
              if E_EPS - e_mean > 63 then d_r <= 63;
              else                        d_r <= E_EPS - e_mean; end if;
              mean_smaller <= false; e_out_r <= e_mean;
            end if;
            state <= S_INV5;

          when S_INV5 =>                        -- one barrel shift, TRUNCATING
            -- No rounding bias, and that is measured rather than assumed: the
            -- term shifted here is by construction the negligible one, and
            -- over 14,800 random vectors rounding and truncating agree to five
            -- significant figures (ref/rmsnorm_eps_vec.c).  Rounding would
            -- cost a bias state and a 64-bit add state for nothing.
            if S = 0 then
              align_r <= (others => '0');
            elsif mean_smaller then
              align_r <= shift_right(m_mean_r, d_r);
            else
              align_r <= shift_right(M_EPS_C, d_r);
            end if;
            state <= S_INV6;

          when S_INV6 =>                                     -- one 64-bit add
            if mean_smaller then msq_r <= align_r  + M_EPS_C;
            else                 msq_r <= m_mean_r + align_r;
            end if;
            state <= S_SEED1;

          -- ---- seed step 1: the 63-bit MSB scan, alone --------------------
          when S_SEED1 =>
            p := 0;
            for i in 0 to 62 loop
              if msq_r(i) = '1' then p := i; end if;
            end loop;
            msb_p <= p;
            rq_p  <= p;
            state <= S_SEED2;

          -- ---- seed step 2: normalising barrel shift + ROM ---------------
          when S_SEED2 =>
            A := unsigned(msq_r);
            if msb_p <= 30 then mant := shift_left(A, 30 - msb_p);
            else                mant := shift_right(A, msb_p - 30);
            end if;
            rq_y     <= to_signed(RSQRT_ROM(to_integer(mant(29 downto 24))), 32);
            rq_smant <= signed(mant(31 downto 0));
            assert mant(30) = '1'
              report "rmsnorm_bf_mem: rsqrt mantissa not normalised to Q30 -- the "
                   & "32-bit narrowing of smant is not valid" severity failure;
            rq_step <= 0;
            state <= S_RQ;

          -- ---- Newton: THREE steps per multiply -------------------------
          -- MEASURED, and the reason for the cadence.  With two steps per
          -- multiply the operand was derived from mr_p by a shift and a
          -- subtract IN THE SAME STATE as the multiply, so the multiply had
          -- no registered operand (no AREG/BREG) and its 34x32 form spans two
          -- DSPs with nothing between them.  The critical path measured
          -- mr_p_reg -> LUT subtract -> DSP_MULTIPLIER -> DSP_ALU ->
          -- DSP_OUTPUT -> the next DSP's A input: 205.2 MHz.
          --
          -- So each multiply now gets three steps:
          --   A  derive the operand from mr_p into a REGISTER
          --   B  the multiply, from registered operands only  (AREG/BREG)
          --   C  hop, which is `mr_p <= mr_m` running unconditionally  (PREG)
          -- and the next A reads mr_p two cycles after the issue, which is
          -- what the MREG+PREG pair costs.  Eighteen steps instead of twelve;
          -- against a 3N/LANES element loop that is noise.
          --
          -- The three multiplies are no longer ISSUED by the case; each has its
          -- own MREG/PREG pair (see the declarations) and runs on every S_RQ
          -- cycle, so the case now only DERIVES operands and CONSUMES results.
          -- That is what takes the select off the DSP output and lets the M
          -- register be absorbed into the DSP48E2 cascade.
          --
          -- Free-running is bit-identical, not merely equivalent, and the
          -- argument is per operand: rq_y is written only at steps 9 and 18,
          -- rq_y2 only at 3 and 12, rq_diff only at 6 and 15, and rq_smant only
          -- in S_SEED2.  So the operands each multiply reads are CONSTANT
          -- across the two cycles that separate its old issue step from the
          -- step that consumes it, and the value latched by the free-running
          -- pair at the consume step is the same value the issued form latched.
          -- Worked through:
          --   step 3  reads mr_p_yy = y*y  with y = the seed         (issued  1)
          --   step 6  reads mr_p_sy = smant*y2, y2 from step 3       (issued  4)
          --   step 9  reads mr_p_dy = diff*y, diff from 6, y the seed(issued  7)
          --   step 12 reads mr_p_yy = y*y  with y from step 9        (issued 10)
          --   step 15 reads mr_p_sy = smant*y2, y2 from step 12      (issued 13)
          --   step 18 reads mr_p_dy = diff*y, diff from 15, y from 9 (issued 16)
          -- The cadence, the step count and therefore the latency are unchanged.
          when S_RQ =>
            mr_m_yy <= resize(rq_y * rq_y, 64);
            mr_p_yy <= mr_m_yy;
            mr_m_sy <= resize(rq_smant * rq_y2, 64);
            mr_p_sy <= mr_m_sy;
            mr_m_dy <= resize(rq_diff * rq_y, 66);
            mr_p_dy <= mr_m_dy;
            mr_m_rt <= resize(rq_y * INV_SQRT2_C, 64);
            mr_p_rt <= mr_m_rt;
            rq_step <= rq_step + 1;
            case rq_step is
              -- ---- Newton iteration 1
              when 3  => rq_y2   <= resize(shift_right(mr_p_yy, 30), 32);
              when 6  => rq_diff <= THREE_Q30 - resize(shift_right(mr_p_sy, 30), 34);
              when 9  => rq_y    <= resize(shift_right(mr_p_dy, 31), 32);
              -- ---- Newton iteration 2
              when 12 => rq_y2   <= resize(shift_right(mr_p_yy, 30), 32);
              when 15 => rq_diff <= THREE_Q30 - resize(shift_right(mr_p_sy, 30), 34);
              when 18 => rq_y    <= resize(shift_right(mr_p_dy, 31), 32);
                         state <= S_RQ_RT1;
              when others => null;      -- MREG / PREG hops: nothing to derive
                                        -- and nothing ready to consume
            end case;

          -- Two hop states, for the same reason the Newton steps have them: rq_y
          -- is ASSIGNED at step 18, so it is not readable until the next
          -- cycle, and the MREG/PREG pair then needs two more to present the
          -- product.  Sequence, writing y18 for the value assigned at step 18:
          --   step 18 : mr_m_rt <= y9  * C          (the previous y)
          --   S_RQ_RT1: mr_m_rt <= y18 * C          mr_p_rt <= y9  * C
          --   S_RQ_RT2:                             mr_p_rt <= y18 * C
          --   S_RQ_FOLD: reads mr_p_rt, which is y18 * C.  Correct.
          -- Cost is 2 cycles per rmsnorm invocation. rmsnorm runs once per head
          -- and the emit chain's measured per-head deadline is 367 cycles, so
          -- this is 0.5% of one head and cannot move the rate limit.
          when S_RQ_RT1 =>
            mr_m_rt <= resize(rq_y * INV_SQRT2_C, 64);
            mr_p_rt <= mr_m_rt;
            state   <= S_RQ_RT2;

          when S_RQ_RT2 =>
            mr_m_rt <= resize(rq_y * INV_SQRT2_C, 64);
            mr_p_rt <= mr_m_rt;
            state   <= S_RQ_FOLD;

          when S_RQ_FOLD =>
            rq_d := rq_p - e_out_r;   -- e_out, NOT Q: msq_r is no
                                      -- longer on a fixed 2^-Q grid
            if (rq_d mod 2) /= 0 then
              -- Now a REGISTERED product, and a 32x32 one.  The old form was
              -- `resize(rq_y, 64) * INV_SQRT2_C`, a 64x32 multiply whose upper
              -- 32 bits are pure sign extension: rq_y and INV_SQRT2_C are both
              -- s32, so the true product always fits in 64 bits and bits 61
              -- downto 30 -- the only ones this line keeps -- are identical
              -- either way. So the narrowing is bit-exact, not an
              -- approximation. rtl/l2norm_rs.vhd:306-309 already does the same
              -- operation at 32x32 and says why; rmsnorm_bf did not.
              rq_yfin <= resize(shift_right(mr_p_rt, 30), 32);
              rq_he   := (rq_d - 1) / 2;
            else
              rq_yfin <= rq_y;
              rq_he   := rq_d / 2;
            end if;
            rq_E  <= Q - 30 - rq_he;
            state <= S_RQ_FIN1;

          -- Split for the same reason S_INV was: the variable barrel shift and
          -- the 32-bit clamp were one cone, and because inv32 is absorbed into
          -- the multiplier's own A register the whole cone sat in FRONT of the
          -- DSP input.  Measured as rq_E_reg -> 18 levels -> DSP A, 231.7 MHz.
          when S_RQ_FIN1 =>                                  -- one barrel shift
            if rq_E >= 0 then
              rq_up_r <= true;  rq_sh_r <= rq_E;
              rq_bias_r <= (others => '0');
            else
              rq_up_r <= false; rq_sh_r <= -rq_E;
              rq_bias_r <= shift_left(to_signed(1, 64), (-rq_E) - 1);
            end if;
            state <= S_RQ_FIN2;

          when S_RQ_FIN2 =>                                  -- one 64-bit add
            rq_sum_r <= resize(rq_yfin, 64) + rq_bias_r;
            state <= S_RQ_FIN3;

          when S_RQ_FIN3 =>                                  -- one barrel shift
            if rq_E > 32 then
              rq_shifted <= to_signed(2147483647, 64);
            elsif rq_up_r then
              rq_shifted <= shift_left(resize(rq_yfin, 64), rq_sh_r);
            else
              rq_shifted <= shift_right(rq_sum_r, rq_sh_r);
            end if;
            state <= S_RQ_CLAMP;

          when S_RQ_CLAMP =>
            if    rq_shifted > to_signed(2147483647, 64) then inv32 <= to_signed(2147483647, 32);
            elsif rq_shifted < 0                         then inv32 <= to_signed(0, 32);
            else                                              inv32 <= resize(rq_shifted, 32);
            end if;
            idx <= 0; idxf <= 0; idx1 <= 0; idx2m <= 0; idx2 <= 0; idx3 <= 0;
            vf <= '0'; v1 <= '0'; v2m <= '0'; v2 <= '0'; v3 <= '0';
            vt <= (others => '0');
            state <= S_RAW;

          -- ---- pass 2 of 3: raw = (xm*inv)*wm, LANES per cycle ------------
          -- Two pipeline stages so the two multiplies are never a cascaded
          -- combinational cone (rmsnorm.vhd splits them into S_RAW/S_RAW_B for
          -- the same reason) -- but PIPELINED rather than sequenced, so the
          -- pass costs N/LANES cycles instead of 2N/LANES.
          --
          -- NARROWED: s16 x s32 -> s48, then s48 x s16 -> s64, against the
          -- original's two 64x64.  Lossless: |xm| < 2^15 and |inv| <= 2^31-1
          -- so |xm*inv| < 2^46 and the s48 holds it exactly; then |wm| < 2^15
          -- gives |raw| < 2^61, inside s64.  The original takes the low 64
          -- bits of a 128-bit product and this is the same value.
          when S_RAW =>
            -- stage F: bus mux only, no arithmetic
            if idx < NB then
              -- RMSMUX: no mux here any more.  ram_ra is already idx.
              vf <= '1'; idxf <= idx; idx <= idx + 1;
            else
              vf <= '0';
            end if;
            -- stage 1: multiply from REGISTERED operands
            v1 <= vf; idx1 <= idxf;
            for k in 0 to LANES-1 loop
              p1_xinv(k) <= resize(x_q(k) * inv32, 48);
              p1_wm(k)   <= resize(w_q(k), 17);
            end loop;
            -- stage 2m: the multiply, into the DSP's MREG.  See p2_m.
            v2m <= v1; idx2m <= idx1;
            for k in 0 to LANES-1 loop
              p2_m(k) <= resize(p1_xinv(k) * p1_wm(k), 64);
            end loop;
            -- stage 2p: PREG.  Nothing between the two flops, deliberately.
            v2 <= v2m; idx2 <= idx2m;
            for k in 0 to LANES-1 loop
              p2_raw(k) <= p2_m(k);
            end loop;
            -- reduce: max|raw| over all lanes.  Order-independent (max is
            -- associative and commutative on unsigned), hence bit-exact
            -- against the original's element-at-a-time scan AND against the
            -- linear per-lane chain this replaces.
            --
            -- WHY IT IS A PIPELINED TREE AND NOT A CHAIN.  The chain form was
            --
            --   cmax := max_raw;
            --   for k in 0 to LANES-1 loop
            --     araw := abs(p2_raw(k));  if araw > cmax then cmax := araw;
            --   end loop;
            --   max_raw <= cmax;
            --
            -- which is LANES 63-bit compares in series, each behind a 63-bit
            -- negate, in ONE state.  That is exactly the "never two of
            -- {barrel shift, wide add, wide compare, bus mux, multiply} in
            -- series" rule this file's header states, and it was the measured
            -- post-route critical path of gdn_emit_chain:
            --   p2_raw_reg[0][9]/C -> max_raw_reg[33]/D, slack -0.632 at
            --   3.3 ns, 1.272 logic + 2.559 net.  254.3 MHz against a
            --   299.04 MHz target, while synthesis alone reported 300.75.
            --
            -- Note the split: 67% of that path is ROUTING, so shortening the
            -- logic alone would not have been the argument.  The routing is a
            -- consequence of the same structure.  One 63-bit register bank was
            -- the sink of a cone fed by ALL LANES*64 bits of p2_raw plus its
            -- own 63-bit feedback; the placer cannot put max_raw next to every
            -- p2_raw lane at once, and p2_raw is itself pinned near the DSPs
            -- that drive it and near the S_EMIT adders it also feeds.  So the
            -- cone was forced to span distance, and a chain of comparators
            -- physically occupies fabric, so its length grows with LANES too.
            -- Splitting it gives every level exactly TWO 63-bit sources, which
            -- is a constraint the placer can actually satisfy locally, and it
            -- takes the negate's borrow chain out of series with a compare's
            -- carry chain -- two CARRY8 chains back to back is a dedicated-route
            -- hop that cannot be shortened by placement at all.
            --
            -- THE SCAR, kept because it is still live in the merge below.  An
            -- earlier version reduced through a SIGNAL rather than a variable.
            -- A signal keeps its old value for every iteration, so
            -- `if araw > max_raw then max_raw <= araw` lets the LAST
            -- qualifying lane win rather than the LARGEST -- the running max
            -- is invisible to the other lanes in the same cycle.  That is
            -- wrong at every LANES > 1; it happened to pass at 2, 4 and 8 on
            -- the test vectors and failed at 16, which is the whole argument
            -- for sweeping the generic instead of testing one value.  The tree
            -- form below cannot reproduce that fault because no stage ever
            -- reduces more than two values, and the one place a running total
            -- is still touched -- the merge into max_raw -- takes exactly ONE
            -- candidate per cycle.
            --
            -- stage 2a: the absolute value ONLY, registered.  No compare here.
            vt(0) <= v2;
            for k in 0 to LANES-1 loop
              if p2_raw(k) < 0 then mt(0)(k) <= unsigned(resize(-p2_raw(k), 63));
              else                  mt(0)(k) <= unsigned(resize( p2_raw(k), 63));
              end if;
            end loop;
            -- stages 2b..2(TLEV+1): balanced max tree, ONE compare per level.
            for lev in 1 to TLEV loop
              vt(lev) <= vt(lev-1);
              for j in 0 to (LANES / 2**lev) - 1 loop
                if mt(lev-1)(2*j) > mt(lev-1)(2*j+1) then
                  mt(lev)(j) <= mt(lev-1)(2*j);
                else
                  mt(lev)(j) <= mt(lev-1)(2*j+1);
                end if;
              end loop;
            end loop;
            -- merge: ONE compare against the running max, so the loop-carried
            -- max_raw -> compare -> max_raw path is one comparator deep
            -- whatever LANES is.  It was LANES deep before.
            if vt(TLEV) = '1' then
              if mt(TLEV)(0) > max_raw then max_raw <= mt(TLEV)(0); end if;
            end if;
            -- The completion condition has to drain the tree as well, or the
            -- reduction is truncated by TLEV+1 beats and max_raw is read while
            -- the tail is still in flight.  vt all zero means every beat that
            -- entered stage 2a has already been merged, because the merge
            -- commits on the same edge that clears vt(TLEV).
            -- v2m is in this list for the same reason vt is: a beat still
            -- inside the MREG has not reached the abs stage, so leaving here
            -- without it truncates the reduction by one beat and reads
            -- max_raw while the tail is in flight.
            if idx = NB and vf = '0' and v1 = '0' and v2m = '0' and v2 = '0'
               and vt = (vt'range => '0') then
              state <= S_SHIFT1;
            end if;

          -- The max|raw| MSB scan gets its own state for the same reason the
          -- mean_sq_q one does: a 63-bit priority encoder feeding an integer
          -- subtract and an exponent add is not a free tail on another state.
          when S_SHIFT1 =>
            p := 0;
            for i in 0 to 62 loop
              if max_raw(i) = '1' then p := i; end if;
            end loop;
            msb_p <= p;
            state <= S_SHIFT2;

          when S_SHIFT2 =>
            if msb_p - 14 < 0 then st := 0; else st := msb_p - 14; end if;
            shift_total <= st;
            o_exp       <= xe + we + Q - st;
            if st = 0 then emit_bias <= (others => '0');
            else           emit_bias <= shift_left(to_signed(1, 64), st - 1);
            end if;
            idx <= 0; idxf <= 0; idx1 <= 0; idx2m <= 0; idx2 <= 0; idx3 <= 0;
            vf <= '0'; v1 <= '0'; v2m <= '0'; v2 <= '0'; v3 <= '0';
            state <= S_EMIT;

          -- ---- pass 3 of 3: recompute raw, round-shift, saturate ----------
          -- scale_mul(raw, 1, shift_total) is a literal multiply-by-one; it is
          -- replaced by the rounded shift it computes, which is bit-exact and
          -- removes a whole multiply site per lane (the same waste bfp_pack
          -- removed on 2026-07-27).
          when S_EMIT =>
            -- stage F: bus mux only, no arithmetic
            if idx < NB then
              -- RMSMUX: no mux here any more.  ram_ra is already idx.
              vf <= '1'; idxf <= idx; idx <= idx + 1;
            else
              vf <= '0';
            end if;
            -- stage 1: multiply from REGISTERED operands
            v1 <= vf; idx1 <= idxf;
            for k in 0 to LANES-1 loop
              p1_xinv(k) <= resize(x_q(k) * inv32, 48);
              p1_wm(k)   <= resize(w_q(k), 17);
            end loop;
            -- stage 2m / 2p: MREG then PREG, same pair as pass 2.  See p2_m.
            v2m <= v1; idx2m <= idx1;
            for k in 0 to LANES-1 loop
              p2_m(k) <= resize(p1_xinv(k) * p1_wm(k), 64);
            end loop;
            v2 <= v2m; idx2 <= idx2m;
            for k in 0 to LANES-1 loop
              p2_raw(k) <= p2_m(k);
            end loop;
            -- stage 3: the rounding ADD only.  Splitting it from the shift
            -- and the saturation is what takes this path off the critical
            -- list -- fused, it was shift_total -> bias barrel shift ->
            -- 64-bit add -> second barrel shift -> compares -> o_reg, 22
            -- levels and 12 CARRY8 at 253.2 MHz.
            v3 <= v2; idx3 <= idx2;
            for k in 0 to LANES-1 loop
              p3_sum(k) <= p2_raw(k) + emit_bias;
            end loop;
            -- stage 4: one shift, then saturate and place
            -- stage 4's saturate-and-place has moved OUT of this process, to
            -- the combinational o_wd and the o_we/o_wa decode above.  Nothing
            -- else about this state changed and the completion condition is
            -- rmsnorm_bf's, unchanged: the write still lands on the same
            -- cycle it always did.
            if idx = NB and vf = '0' and v1 = '0' and v2m = '0' and v2 = '0'
               and v3 = '0' then
              done  <= '1';
              state <= S_IDLE;
            end if;

          when others =>
            state <= S_IDLE;
        end case;
      end if;
    end if;
  end process;
end architecture;
