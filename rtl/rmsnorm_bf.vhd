-- rtl/rmsnorm_bf.vhd
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
--     p <= m;` with no logic between.
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

entity rmsnorm_bf is
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
    x_mant : in  std_logic_vector(N*16-1 downto 0);
    x_exp  : in  integer;
    w_mant : in  std_logic_vector(N*16-1 downto 0);
    w_exp  : in  integer;
    done   : out std_logic;
    o_mant : out std_logic_vector(N*16-1 downto 0);
    o_exp  : out integer
  );
end entity;

architecture rtl of rmsnorm_bf is
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
                   S_RQ, S_RQ_FOLD, S_RQ_FIN1, S_RQ_FIN2, S_RQ_FIN3, S_RQ_CLAMP,
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
  -- MREG/PREG pairs: two registers, no logic between, one per Newton multiply
  signal mr_m, mr_p : signed(65 downto 0) := (others => '0');

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
  signal xf, wf  : s16a := (others => (others => '0'));
  signal vf      : std_logic := '0';
  signal va, vb  : std_logic := '0';
  signal xa      : s16a := (others => (others => '0'));
  type s32a is array(0 to LANES-1) of signed(31 downto 0);
  signal sq      : s32a := (others => (others => '0'));
  signal idxf    : natural range 0 to NB := 0;
  signal p1_xinv : s48a := (others => (others => '0'));   -- xm * inv   (s16 x s32)
  signal p1_wm   : s17a := (others => (others => '0'));   -- wm carried alongside
  signal p2_raw  : s64a := (others => (others => '0'));   -- (xm*inv) * wm
  signal v1, v2, v3 : std_logic := '0';
  signal p3_sum  : s64a := (others => (others => '0'));
  signal idx     : natural range 0 to NB := 0;
  signal idx1, idx2, idx3 : natural range 0 to NB := 0;

  signal o_reg : std_logic_vector(N*16-1 downto 0) := (others => '0');
begin
  o_mant <= o_reg;

  assert N mod LANES = 0
    report "rmsnorm_bf: LANES must divide N" severity failure;
  assert 2**LOG2N = N
    report "rmsnorm_bf: N must be a power of two (the mean divide is a shift)"
    severity failure;

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
    variable araw       : unsigned(62 downto 0);
    variable cmax       : unsigned(62 downto 0);
    variable om         : signed(63 downto 0);
    variable ob         : signed(63 downto 0);
    variable base       : natural;
    variable st         : integer;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state <= S_IDLE; done <= '0'; v1 <= '0'; v2 <= '0';
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
              v1 <= '0'; v2 <= '0'; vf <= '0';
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
              base := idx * LANES;
              for k in 0 to LANES-1 loop
                xa(k) <= signed(x_mant((base+k+1)*16-1 downto (base+k)*16));
              end loop;
              va <= '1'; idx <= idx + 1;
            else
              va <= '0';
            end if;
            -- stage B: square from a registered operand
            vb <= va;
            for k in 0 to LANES-1 loop
              sq(k) <= resize(xa(k) * xa(k), 32);
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
              report "rmsnorm_bf: sum of squares out of the assumed range"
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
              report "rmsnorm_bf: rsqrt mantissa not normalised to Q30 -- the "
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
          --   B  issue the multiply from registered operands only  (AREG/BREG)
          --   C  hop, which is `mr_p <= mr_m` running unconditionally  (PREG)
          -- and the next A reads mr_p two cycles after the issue, which is
          -- what the MREG+PREG pair costs.  Eighteen steps instead of twelve;
          -- against a 3N/LANES element loop that is noise.
          when S_RQ =>
            mr_p    <= mr_m;
            rq_step <= rq_step + 1;
            case rq_step is
              -- M1 = y*y   (y is already registered, so no derive step needed)
              when 1  => mr_m <= resize(rq_y * rq_y, 66);
              -- M2 = smant * y2
              when 3  => rq_y2 <= resize(shift_right(mr_p, 30), 32);
              when 4  => mr_m  <= resize(rq_smant * rq_y2, 66);
              -- M3 = diff * y
              when 6  => rq_diff <= THREE_Q30 - resize(shift_right(mr_p, 30), 34);
              when 7  => mr_m    <= resize(rq_diff * rq_y, 66);
              -- end of iteration 1; M4 = y*y
              when 9  => rq_y <= resize(shift_right(mr_p, 31), 32);
              when 10 => mr_m <= resize(rq_y * rq_y, 66);
              -- M5 = smant * y2
              when 12 => rq_y2 <= resize(shift_right(mr_p, 30), 32);
              when 13 => mr_m  <= resize(rq_smant * rq_y2, 66);
              -- M6 = diff * y
              when 15 => rq_diff <= THREE_Q30 - resize(shift_right(mr_p, 30), 34);
              when 16 => mr_m    <= resize(rq_diff * rq_y, 66);
              -- end of iteration 2
              when 18 => rq_y <= resize(shift_right(mr_p, 31), 32);
                         state <= S_RQ_FOLD;
              when others => null;                        -- MREG / PREG hops
            end case;

          when S_RQ_FOLD =>
            rq_d := rq_p - e_out_r;   -- e_out, NOT Q: msq_r is no
                                      -- longer on a fixed 2^-Q grid
            if (rq_d mod 2) /= 0 then
              rq_yfin <= resize(shift_right(resize(rq_y, 64) * INV_SQRT2_C, 30), 32);
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
            idx <= 0; idxf <= 0; idx1 <= 0; idx2 <= 0; idx3 <= 0;
            vf <= '0'; v1 <= '0'; v2 <= '0'; v3 <= '0';
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
              base := idx * LANES;
              for k in 0 to LANES-1 loop
                xf(k) <= signed(x_mant((base+k+1)*16-1 downto (base+k)*16));
                wf(k) <= signed(w_mant((base+k+1)*16-1 downto (base+k)*16));
              end loop;
              vf <= '1'; idxf <= idx; idx <= idx + 1;
            else
              vf <= '0';
            end if;
            -- stage 1: multiply from REGISTERED operands
            v1 <= vf; idx1 <= idxf;
            for k in 0 to LANES-1 loop
              p1_xinv(k) <= resize(xf(k) * inv32, 48);
              p1_wm(k)   <= resize(wf(k), 17);
            end loop;
            -- stage 2
            v2 <= v1; idx2 <= idx1;
            for k in 0 to LANES-1 loop
              p2_raw(k) <= resize(p1_xinv(k) * p1_wm(k), 64);
            end loop;
            -- reduce: max|raw| over all lanes.  Order-independent, hence
            -- bit-exact against the original's element-at-a-time scan.
            -- The max is reduced through a VARIABLE, not by assigning the
            -- signal inside the loop.  A signal keeps its old value for every
            -- iteration, so `if araw > max_raw then max_raw <= araw` lets the
            -- LAST qualifying lane win rather than the LARGEST -- the running
            -- max is invisible to the other lanes in the same cycle.  That is
            -- wrong at every LANES > 1; it happened to pass at 2, 4 and 8 on
            -- the test vectors and failed at 16, which is the whole argument
            -- for sweeping the generic instead of testing one value.
            if v2 = '1' then
              cmax := max_raw;
              for k in 0 to LANES-1 loop
                if p2_raw(k) < 0 then araw := unsigned(resize(-p2_raw(k), 63));
                else                  araw := unsigned(resize( p2_raw(k), 63));
                end if;
                if araw > cmax then cmax := araw; end if;
              end loop;
              max_raw <= cmax;
            end if;
            if idx = NB and vf = '0' and v1 = '0' and v2 = '0' then
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
            idx <= 0; idxf <= 0; idx1 <= 0; idx2 <= 0; idx3 <= 0;
            vf <= '0'; v1 <= '0'; v2 <= '0'; v3 <= '0';
            state <= S_EMIT;

          -- ---- pass 3 of 3: recompute raw, round-shift, saturate ----------
          -- scale_mul(raw, 1, shift_total) is a literal multiply-by-one; it is
          -- replaced by the rounded shift it computes, which is bit-exact and
          -- removes a whole multiply site per lane (the same waste bfp_pack
          -- removed on 2026-07-27).
          when S_EMIT =>
            -- stage F: bus mux only, no arithmetic
            if idx < NB then
              base := idx * LANES;
              for k in 0 to LANES-1 loop
                xf(k) <= signed(x_mant((base+k+1)*16-1 downto (base+k)*16));
                wf(k) <= signed(w_mant((base+k+1)*16-1 downto (base+k)*16));
              end loop;
              vf <= '1'; idxf <= idx; idx <= idx + 1;
            else
              vf <= '0';
            end if;
            -- stage 1: multiply from REGISTERED operands
            v1 <= vf; idx1 <= idxf;
            for k in 0 to LANES-1 loop
              p1_xinv(k) <= resize(xf(k) * inv32, 48);
              p1_wm(k)   <= resize(wf(k), 17);
            end loop;
            v2 <= v1; idx2 <= idx1;
            for k in 0 to LANES-1 loop
              p2_raw(k) <= resize(p1_xinv(k) * p1_wm(k), 64);
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
            if v3 = '1' then
              base := idx3 * LANES;
              for k in 0 to LANES-1 loop
                om := shift_right(p3_sum(k), shift_total);
                if    om > 32767  then
                  o_reg((base+k+1)*16-1 downto (base+k)*16)
                    <= std_logic_vector(to_signed(32767, 16));
                elsif om < -32768 then
                  o_reg((base+k+1)*16-1 downto (base+k)*16)
                    <= std_logic_vector(to_signed(-32768, 16));
                else
                  o_reg((base+k+1)*16-1 downto (base+k)*16)
                    <= std_logic_vector(resize(om, 16));
                end if;
              end loop;
            end if;
            if idx = NB and vf = '0' and v1 = '0' and v2 = '0' and v3 = '0' then
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
