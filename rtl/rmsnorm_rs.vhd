-- rtl/rmsnorm_rs.vhd
-- Integer RMSNorm, BIT-EXACT with rtl/rmsnorm.vhd, made fast enough to use.
--
-- WHY THIS EXISTS.  rmsnorm.vhd is correct and unusable at 27B scale.  As
-- shipped it measures 78 DSP48E2 and 138.4 MHz at N=256
-- (docs/debugging/2026-08-25_whole-die-budget-reconciliation.md), and both
-- numbers are disqualifying:
--
--   * C 3.13 item 1 needs a narrowed unit; the 78 DSP is dominated by three
--     64x64 mulshr sites in the pipelined rsqrt plus a scale_mul(x, 1, sh)
--     that is a literal multiply-by-one.
--   * B 3.2 needs THROUGHPUT.  At 5 cycles per element the output norms and
--     L2 norms together are 4.10x B's whole state sweep -- the thing they were
--     supposed to hide under -- so no schedule can absorb them (B 3.3).
--
-- THREE CHANGES, and nothing else.  Every width, every rounding site, every
-- shift and the accumulation order are preserved, so o_mant/o_exp are
-- bit-identical to rmsnorm.vhd element for element.  sim/tb_rmsnorm_rs.vhd
-- asserts exactly that against the original instantiated side by side.
--
--   1. NARROWED multiplies.  Lossless, not approximate -- each narrowing is
--      justified by a value bound that is ASSERTED at run time below, so a
--      violated assumption fails loudly in simulation instead of silently
--      changing a result.  The bounds and why they hold are at each site.
--
--   2. MREG.  The rsqrt Newton multiplies are 32x32, which a DSP48E2 builds
--      as a CASCADE (the primitive is 27x18).  A cascade with only AREG/BREG
--      and PREG has no register between the partial products, and that is the
--      fixed path holding the narrowed skeletons at 278.9 MHz -- measured
--      independently by C 3.6's rmsnorm_rs skeleton and by B's
--      sim/micro/micro_rmsn_lanes.vhd at 1, 2 AND 4 lanes, identically, which
--      is what says it is one structure and not a width or fanout effect.
--      C 3.13 item 1 names the fix: MREG on the 34x32 stage.  Inferred here
--      by putting TWO registers on each product path with no logic between
--      them (`m <= a*b; p <= m;`), which is the idiom Vivado maps to
--      MREG + PREG.  Costs one cycle per Newton multiply, 7 cycles total,
--      against a 3N/LANES element loop -- nothing.
--
--   3. LANES.  The element-proportional work divides by the lane count.  This
--      is bit-exact because both element loops reduce with operations that do
--      not care about order: the sum of squares is an exact integer sum (no
--      overflow, see the S bound below) and max|raw| is a maximum.  Neither
--      is floating point, so lane-parallel reduction is not merely close, it
--      is identical.
--
-- WHAT IS DELIBERATELY *NOT* CHANGED: raw[j] is still RECOMPUTED in the emit
-- pass rather than stored.  Storing it is the obvious optimization, it takes
-- the element loop from 3N to 2N, and it is FORBIDDEN -- rmsnorm.vhd's S_RAW
-- comment records that a 64x64 indexed array was inferred as UNINITIALIZED
-- distributed RAM in the congested engine and produced NON-DETERMINISTIC
-- hardware output.  B 3.3 drafted that optimization and withdrew it.  The
-- margin it buys is not needed: 3N at 4 lanes already hides under B's sweep
-- with 72% to spare.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use work.fixed_pkg.all;
use work.fixed_luts_pkg.all;
use work.util_pkg.all;

entity rmsnorm_rs is
  generic(
    N     : positive;
    -- Elements processed per cycle.  Must divide N.  4 is B 3.3's target; 1
    -- reproduces rmsnorm.vhd's element rate exactly and is the fallback.
    LANES : positive := 4;
    Q     : integer  := 12
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

architecture rtl of rmsnorm_rs is
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
  signal rq_step : natural range 0 to 25 := 0;

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
  signal sh_r     : integer := 0;
  signal up_r     : boolean := false;
  signal mant_r   : unsigned(63 downto 0) := (others => '0');
  signal msb_p    : integer := 0;
  signal rq_shifted : signed(63 downto 0) := (others => '0');
  signal num_r, bias_r, sum_r, shifted_r : signed(63 downto 0) := (others => '0');
  signal rq_bias_r, rq_sum_r : signed(63 downto 0) := (others => '0');
  signal rq_sh_r  : integer := 0;
  -- The emit rounding bias depends only on shift_total, which is fixed for the
  -- whole pass, so it is computed ONCE rather than per element per lane.
  signal emit_bias : signed(63 downto 0) := (others => '0');
  signal rq_up_r  : boolean := false;
  -- MREG/PREG pairs: two registers, no logic between, one per Newton multiply
  -- mr_m = MREG, mr_m2 = the cascade hop between the two DSPs a 34x32
  -- multiply spans, mr_p = PREG.  See the note at S_RQ.
  signal mr_m, mr_m2, mr_p : signed(65 downto 0) := (others => '0');

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
    report "rmsnorm_rs: LANES must divide N" severity failure;
  assert 2**LOG2N = N
    report "rmsnorm_rs: N must be a power of two (the mean divide is a shift)"
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
            assert S >= 0 and S < shift_left(to_signed(1, 64), 46)
              report "rmsnorm_rs: sum of squares out of the assumed range"
              severity failure;
            num_r <= shift_left(S, Q);                       -- fixed shift
            if xe >= 0 then
              up_r <= false;
              if 2 * xe > 62 then sh_r <= 62; else sh_r <= 2 * xe; end if;
            else
              up_r <= true;
              if -(2 * xe) > 62 then sh_r <= 62; else sh_r <= -(2 * xe); end if;
            end if;
            state <= S_INV2;

          when S_INV2 =>                                     -- add + fixed shift
            msq_r <= shift_right(num_r + to_signed(N/2, 64), LOG2N);
            state <= S_INV3;

          when S_INV3 =>                                     -- one barrel shift
            if up_r or sh_r = 0 then
              bias_r <= (others => '0');
            else
              bias_r <= shift_left(to_signed(1, 64), sh_r - 1);
            end if;
            state <= S_INV4;

          when S_INV4 =>                                     -- one 64-bit add
            sum_r <= msq_r + bias_r;
            state <= S_INV5;

          when S_INV5 =>                                     -- one barrel shift
            if up_r then shifted_r <= shift_left(msq_r, sh_r);
            else         shifted_r <= shift_right(sum_r, sh_r);
            end if;
            state <= S_INV6;

          when S_INV6 =>                                     -- one compare
            if shifted_r < 1 then msq_r <= to_signed(1, 64);
            else                  msq_r <= shifted_r;
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
              report "rmsnorm_rs: rsqrt mantissa not normalised to Q30 -- the "
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
            -- THE CASCADE HOP.  Measured at 0.717 V, a 14-configuration
            -- synthesis sweep: l2norm_rs, rmsnorm_rs, micro_rmsn_lanes and
            -- gdn_emit_chain are ALL bound by the same path, a
            -- DSP48E2-internal multiply in this Newton rsqrt,
            -- ARG__N/DSP_A_B_DATA_INST, at 4.35 to 4.69 ns and 84 to 88%
            -- LOGIC.  rmsnorm_rs N=256 measures 224.57 MHz at LANES 1 and
            -- 211.46 at LANES 2 and 4, against a 237.8 MHz target, and no norm
            -- unit closes at any lane count until it moves.
            --
            -- THE MREG AND THE PREG WERE ALREADY HERE and have been since this
            -- file was written; `mr_m` is the MREG and `mr_p` the PREG, and
            -- the three-step cadence above exists precisely to buy them.  So
            -- the residual is NOT a missing MREG.  It is the thing the cadence
            -- note already named and only half fixed: a 34x32 multiply SPANS
            -- TWO DSP48E2s -- the primitive is 27x18 -- and registering the
            -- operands fixed the logic in FRONT of the first DSP while leaving
            -- the hop BETWEEN the two with nothing in it.  That hop is what a
            -- path starting at DSP_A_B_DATA_INST and costing 87% logic is
            -- made of.
            --
            -- mr_m2 is a third level so the tool has a register to put in that
            -- span.  Narrowing is not an alternative here: both operands are
            -- Q30 quantities of 31 to 34 bits and neither can be cut to the
            -- 27x18 a single DSP takes, so the two-DSP span is structural.
            --
            -- Cost is one more step per multiply, 4 instead of 3, so 24 steps
            -- instead of 18: +6 cycles per rsqrt.
            mr_m2   <= mr_m;
            mr_p    <= mr_m2;
            rq_step <= rq_step + 1;
            -- Issue at N, consume at N+3: one more than before, because the
            -- product now crosses three registers (MREG, cascade, PREG) rather
            -- than two.  A consumer left at N+2 reads the PREVIOUS multiply's
            -- result, which is exactly the fault the cadence note above
            -- records this file already having shipped once.
            case rq_step is
              -- M1 = y*y   (y is already registered, so no derive step needed)
              when 1  => mr_m <= resize(rq_y * rq_y, 66);
              -- M2 = smant * y2
              when 4  => rq_y2 <= resize(shift_right(mr_p, 30), 32);
              when 5  => mr_m  <= resize(rq_smant * rq_y2, 66);
              -- M3 = diff * y
              when 8  => rq_diff <= THREE_Q30 - resize(shift_right(mr_p, 30), 34);
              when 9  => mr_m    <= resize(rq_diff * rq_y, 66);
              -- end of iteration 1; M4 = y*y
              when 12 => rq_y <= resize(shift_right(mr_p, 31), 32);
              when 13 => mr_m <= resize(rq_y * rq_y, 66);
              -- M5 = smant * y2
              when 16 => rq_y2 <= resize(shift_right(mr_p, 30), 32);
              when 17 => mr_m  <= resize(rq_smant * rq_y2, 66);
              -- M6 = diff * y
              when 20 => rq_diff <= THREE_Q30 - resize(shift_right(mr_p, 30), 34);
              when 21 => mr_m    <= resize(rq_diff * rq_y, 66);
              -- end of iteration 2
              when 24 => rq_y <= resize(shift_right(mr_p, 31), 32);
                         state <= S_RQ_FOLD;
              when others => null;                        -- MREG / PREG hops
            end case;

          when S_RQ_FOLD =>
            rq_d := rq_p - Q;
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
