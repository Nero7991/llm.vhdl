-- rtl/l2norm_rs.vhd
-- The per-head L2 norm of subsystem B 2.1.3, both output paths, pipelined.
--
-- WHY A SEPARATE UNIT FROM rmsnorm_rs.  They look alike and are not the same
-- function.  B 2.1.3: this divides by sqrt(ssq), NOT sqrt(mean); it produces
-- TWO differently-quantized outputs per element; it has no weight multiply;
-- its output exponents are FIXED (15 and 18) rather than derived from
-- max|raw|, so there is no magnitude scan and no shift_total; and it carries a
-- deliberate divergence from ggml at ssq = 0.  Folding it into rmsnorm_rs as a
-- mode would put a scan it never needs in series with a path it does.
--
-- THE RECIPE, pinned here because 2.1.3 defers it to section 3 and section 3
-- had not pinned it.
--
-- CORRECTED 2026-08-25, the same night it was first written.  The first
-- version collapsed the rsqrt to a Q-scaled INTEGER, `inv = rsqrt_q(ssq<<Q,Q)
-- = round(2^Q/sqrt(ssq))`, and that is numerically broken at this unit's own
-- operating point.  2.1.3's segment requantizer normalises amax to msb 14, so
-- post-silu head mantissas sit near 2^13-2^14 BY DESIGN and ssq lands around
-- 2^33-2^37.  There `2^18/sqrt(ssq)` rounds to 1, and `2^18/sqrt(128*ssq)`
-- rounds to ZERO:
--
--     |x|     ssq      inv_k  inv_q   k_n got/true      q_s got/true
--     32768   2^37       1      0     4096/2896  +41%     0/2048  -100%
--     16384   2^35       1      0     2048/2896  -29%     0/2048  -100%
--      8192   2^33       3      0     3072/2896   +6%     0/2048  -100%
--
-- The whole q path emitted zeros over the normal input range, and the first
-- testbench CERTIFIED it, because its golden was computed from the same
-- recipe: golden and DUT rounded the same scalar to the same 0 and agreed
-- perfectly.  Bit-exactness against a twice-transcribed recipe proves
-- transcription, not adequacy.  sim/tb_l2norm_rs.vhd now carries an
-- INDEPENDENT real-valued accuracy assertion for exactly this reason.
--
-- The corrected recipe never collapses the rsqrt.  It keeps the Newton
-- engine's Q30 mantissa and applies its exponent as a per-invocation SCALAR
-- SHIFT at emit -- which is the shift_total/emit_bias machinery rmsnorm_rs
-- already closes at 300.8 MHz:
--
--   ssq  = sum xm[i]^2                                u38, |xm| <= 32768
--   -- k path: rsqrt argument is ssq itself
--   m_k  = msb(ssq)          he_k = m_k / 2      (floor; sqrt2 fold if odd)
--   y_k  = Q30 Newton rsqrt of ssq normalised to [1,2)
--   k_n[i] = sat16( round_shift( xm[i] * y_k, 15 + he_k ) )      -- exp 15
--   -- q path: the 1/sqrt(128) fold is a SHIFT OF THE ARGUMENT
--   m_q  = msb(ssq << 7)     he_q = m_q / 2      (same rule)
--   y_q  = Q30 Newton rsqrt of (ssq << 7) normalised to [1,2)
--   q_s[i] = sat16( round_shift( xm[i] * y_q, 12 + he_q ) )      -- exp 18
--
-- because 1/sqrt(v) = (y/2^30) * 2^-he exactly, so
-- xm * 2^OUT / sqrt(v) = xm * y >> (30 - OUT + he).
--
-- **Q CANCELS OUT ENTIRELY**, and the previous version's "Q = 18 is forced by
-- s64 and the <<7 fold" derivation was an artifact of the broken form, not a
-- constraint on the problem.  The generic is gone.  Measured against the real
-- ratio this is exact to 0.0% at every magnitude above, where the old form
-- was between -100% and +41%.
--
-- The exponent CANCELS and that is why none appears here: xm has exponent e,
-- so x_real = xm*2^-e and sqrt(ssq_real) = sqrt(ssq)*2^-e, and the ratio is
-- xm/sqrt(ssq) with no e in it.  rmsnorm needs x_exp because its mean is not
-- scale-free; this does not.
--
-- THE 1/sqrt(128) FOLD IS A SHIFT OF THE ARGUMENT, NOT OF THE OUTPUT, and
-- 2.1.3 is specific about that.  sqrt(128) = 8*sqrt(2) is not a power of two,
-- so it cannot be folded as an output shift; folding it into the rsqrt's
-- argument as <<7 costs one extra rsqrt evaluation and no multiply.
--
-- ssq = 0 EMITS ZEROS ON BOTH PATHS.  This is B 2.1.3's deliberate,
-- documented divergence from ggml_l2_norm, which computes 1/max(sqrt(ssq),eps)
-- and therefore emits amplified dust from an all-zero input.  The case is
-- reachable, not theoretical: at position 0 every conv tap but one is masked
-- (1.6), so a single zero projection output produces ssq = 0 for a whole head.
--
-- STRUCTURE.  One operation per state -- never two of {barrel shift, 64-bit
-- add, wide compare, bus mux, multiply} in series.  That rule is not taste; it
-- is what took rmsnorm_rs from 117.2 MHz to 300.8, measured seven times.  See
-- docs/debugging/2026-08-25_rmsnorm-rs-300mhz.md.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use work.fixed_pkg.all;
use work.fixed_luts_pkg.all;
use work.util_pkg.all;

entity l2norm_rs is
  generic(
    N     : positive := 128;
    LANES : positive := 4
  );
  port(
    clk    : in  std_logic;
    rst    : in  std_logic;
    start  : in  std_logic;
    x_mant : in  std_logic_vector(N*16-1 downto 0);
    done   : out std_logic;
    k_mant : out std_logic_vector(N*16-1 downto 0);   -- k path, exponent 15
    q_mant : out std_logic_vector(N*16-1 downto 0)    -- q path, exponent 18
  );
end entity;

architecture rtl of l2norm_rs is
  constant NB : natural := N / LANES;

  constant THREE_Q30   : signed(33 downto 0) := shift_left(to_signed(3, 34), 30);
  constant INV_SQRT2_C : signed(31 downto 0) := to_signed(759250125, 32);

  type state_t is (S_IDLE, S_ACC,
                   S_ARG,                      -- pick this pass's rsqrt argument
                   S_SEED1, S_SEED2, S_RQ, S_RQ_FOLD, S_RQ_FOLD2,
                   S_NEXT,                     -- second rsqrt pass, or emit
                   S_EMIT, S_ZERO);
  signal state : state_t := S_IDLE;

  signal ssq   : signed(63 downto 0) := (others => '0');
  signal pass  : natural range 0 to 1 := 0;    -- 0 = k path, 1 = q path
  -- The rsqrt result is carried as a Q30 MANTISSA plus a scalar shift, never
  -- collapsed to an integer.  That collapse is what broke the first version.
  signal y_k, y_q   : signed(31 downto 0) := (others => '0');
  -- The 1/sqrt(2) fold product, REGISTERED before it reaches y_k/y_q.  y_k is
  -- absorbed into the lane multiplier's DSP B-input register, so any logic
  -- feeding it lands between two multiplies: with the fold done in the same
  -- cycle the path ran arg -> multiply -> ALU -> 3x CARRY8 -> B, 12 levels, and
  -- the unit closed at 272.3 MHz instead of 300.  Splitting the fold across two
  -- states costs 2 cycles of 319 and buys the 300 MHz back.
  signal fold_p     : signed(63 downto 0) := (others => '0');
  signal fold_odd   : std_logic := '0';
  signal sh_k, sh_q : integer := 15;
  signal bias_k, bias_q : signed(63 downto 0) := (others => '0');

  -- rsqrt, narrowed exactly as rmsnorm_rs narrows it
  signal rq_y, rq_smant, rq_y2 : signed(31 downto 0) := (others => '0');
  signal rq_diff  : signed(33 downto 0) := (others => '0');
  signal rq_yfin  : signed(31 downto 0) := (others => '0');
  signal rq_p, rq_E, rq_sh_r : integer := 0;
  signal rq_up_r  : boolean := false;
  signal mr_m, mr_p : signed(65 downto 0) := (others => '0');
  signal rq_step  : natural range 0 to 19 := 0;
  signal arg_r, msq_r, rq_bias_r, rq_sum_r, rq_shifted : signed(63 downto 0)
       := (others => '0');
  signal msb_p : integer := 0;
  signal mant_hold : unsigned(63 downto 0) := (others => '0');

  -- element pipeline
  type s16a is array(0 to LANES-1) of signed(15 downto 0);
  type s32a is array(0 to LANES-1) of signed(31 downto 0);
  type s64a is array(0 to LANES-1) of signed(63 downto 0);
  signal xa, xf : s16a := (others => (others => '0'));
  signal sq     : s32a := (others => (others => '0'));
  signal pk, pq : s64a := (others => (others => '0'));
  signal va, vb, vf, v1 : std_logic := '0';
  signal idx, idxf, idx1 : natural range 0 to NB := 0;

  signal k_reg, q_reg : std_logic_vector(N*16-1 downto 0) := (others => '0');
begin
  k_mant <= k_reg;
  q_mant <= q_reg;

  assert N mod LANES = 0
    report "l2norm_rs: LANES must divide N" severity failure;

  process(clk)
    variable sq_sum : signed(63 downto 0);
    variable base   : natural;
    variable p      : integer;
    variable A, mant : unsigned(63 downto 0);
    variable rq_d, rq_he : integer;
    variable ok, oq : signed(63 downto 0);

    -- sat16 of a 64-bit value, used on both paths
    function sat16(v : signed) return signed is
    begin
      if    v >  32767 then return to_signed( 32767, 16);
      elsif v < -32768 then return to_signed(-32768, 16);
      else                  return resize(v, 16);
      end if;
    end function;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state <= S_IDLE; done <= '0';
        va <= '0'; vb <= '0'; vf <= '0'; v1 <= '0';
      else
        done <= '0';
        case state is

          when S_IDLE =>
            if start = '1' then
              ssq <= (others => '0');
              idx <= 0; va <= '0'; vb <= '0';
              state <= S_ACC;
            end if;

          -- ---- sum of squares, three stages, LANES per cycle --------------
          when S_ACC =>
            if idx < NB then
              base := idx * LANES;
              for k in 0 to LANES-1 loop
                xa(k) <= signed(x_mant((base+k+1)*16-1 downto (base+k)*16));
              end loop;
              va <= '1'; idx <= idx + 1;
            else
              va <= '0';
            end if;
            vb <= va;
            for k in 0 to LANES-1 loop
              sq(k) <= resize(xa(k) * xa(k), 32);
            end loop;
            if vb = '1' then
              sq_sum := (others => '0');
              for k in 0 to LANES-1 loop
                sq_sum := sq_sum + resize(sq(k), 64);
              end loop;
              ssq <= ssq + sq_sum;
            end if;
            if idx = NB and va = '0' and vb = '0' then
              pass <= 0;
              state <= S_ARG;
            end if;

          -- ---- pick the argument for this rsqrt pass ----------------------
          -- pass 0 (k path): the argument is ssq itself
          -- pass 1 (q path): ssq << 7 -- the 1/sqrt(128) fold, a SHIFT of the
          --                              ARGUMENT, no multiply, per 2.1.3
          when S_ARG =>
            assert ssq >= 0 and ssq < shift_left(to_signed(1, 64), 38)
              report "l2norm_rs: ssq outside the u38 bound of 2.1.3"
              severity failure;
            if ssq = 0 then
              -- 2.1.3's deliberate divergence from ggml: zeros, not dust
              idx <= 0;
              state <= S_ZERO;
            elsif pass = 0 then
              arg_r <= ssq;
              state <= S_SEED1;
            else
              arg_r <= shift_left(ssq, 7);
              state <= S_SEED1;
            end if;

          when S_SEED1 =>                              -- 63-bit MSB scan alone
            p := 0;
            for i in 0 to 62 loop
              if arg_r(i) = '1' then p := i; end if;
            end loop;
            msb_p <= p; rq_p <= p;
            state <= S_SEED2;

          when S_SEED2 =>                              -- barrel normalise + ROM
            A := unsigned(arg_r);
            if msb_p <= 30 then mant := shift_left(A, 30 - msb_p);
            else                mant := shift_right(A, msb_p - 30);
            end if;
            rq_y     <= to_signed(RSQRT_ROM(to_integer(mant(29 downto 24))), 32);
            rq_smant <= signed(mant(31 downto 0));
            assert mant(30) = '1'
              report "l2norm_rs: rsqrt mantissa not normalised to Q30"
              severity failure;
            rq_step <= 0;
            state <= S_RQ;

          -- ---- Newton, three steps per multiply (MREG + PREG) -------------
          when S_RQ =>
            mr_p    <= mr_m;
            rq_step <= rq_step + 1;
            case rq_step is
              when 1  => mr_m <= resize(rq_y * rq_y, 66);
              when 3  => rq_y2 <= resize(shift_right(mr_p, 30), 32);
              when 4  => mr_m  <= resize(rq_smant * rq_y2, 66);
              when 6  => rq_diff <= THREE_Q30 - resize(shift_right(mr_p, 30), 34);
              when 7  => mr_m    <= resize(rq_diff * rq_y, 66);
              when 9  => rq_y <= resize(shift_right(mr_p, 31), 32);
              when 10 => mr_m <= resize(rq_y * rq_y, 66);
              when 12 => rq_y2 <= resize(shift_right(mr_p, 30), 32);
              when 13 => mr_m  <= resize(rq_smant * rq_y2, 66);
              when 15 => rq_diff <= THREE_Q30 - resize(shift_right(mr_p, 30), 34);
              when 16 => mr_m    <= resize(rq_diff * rq_y, 66);
              when 18 => rq_y <= resize(shift_right(mr_p, 31), 32);
                         state <= S_RQ_FOLD;
              when others => null;
            end case;

          when S_RQ_FOLD =>
            -- rq_d is the MSB position itself, NOT p - Q: the exponent of
            -- 1/sqrt(v) is -m/2 where m = msb(v), and the odd case folds
            -- 1/sqrt(2) exactly as rmsnorm's rsqrt does.
            rq_d := rq_p;
            -- INV_SQRT2_C is s32 and rq_y is s32; multiplying at 32x32 rather
            -- than resizing to 64 first declares the multiplier the value
            -- actually needs.  Issued here, CONSUMED in S_RQ_FOLD2.
            fold_p <= resize(rq_y * INV_SQRT2_C, 64);
            if (rq_d mod 2) /= 0 then
              fold_odd <= '1';
              rq_he    := (rq_d - 1) / 2;
            else
              fold_odd <= '0';
              rq_he    := rq_d / 2;
            end if;
            -- 1/sqrt(v) = (yfin / 2^30) * 2^-he, so
            --   out = xm * 2^OUT / sqrt(v) = xm * yfin >> (30 - OUT + he)
            -- with OUT = 15 on the k path and 18 on the q path.
            if pass = 0 then
              sh_k <= 15 + rq_he;
              if 15 + rq_he > 0 then
                bias_k <= shift_left(to_signed(1, 64), 15 + rq_he - 1);
              else
                bias_k <= (others => '0');
              end if;
            else
              sh_q <= 12 + rq_he;
              if 12 + rq_he > 0 then
                bias_q <= shift_left(to_signed(1, 64), 12 + rq_he - 1);
              else
                bias_q <= (others => '0');
              end if;
            end if;
            state <= S_RQ_FOLD2;

          when S_RQ_FOLD2 =>
            -- y comes from a REGISTER through a constant shift and a 2:1 mux
            -- and nothing else, so the DSP B-input path is a register hop.
            if pass = 0 then
              if fold_odd = '1' then y_k <= resize(shift_right(fold_p, 30), 32);
              else                   y_k <= rq_y; end if;
            else
              if fold_odd = '1' then y_q <= resize(shift_right(fold_p, 30), 32);
              else                   y_q <= rq_y; end if;
            end if;
            state <= S_NEXT;

          when S_NEXT =>
            if pass = 0 then
              pass  <= 1;
              state <= S_ARG;                 -- second rsqrt, q path
            else
              idx <= 0; idxf <= 0; idx1 <= 0;
              vf <= '0'; v1 <= '0';
              state <= S_EMIT;
            end if;

          -- ---- both outputs, LANES per cycle, four stages -----------------
          -- No magnitude scan and no shift_total: 2.1.3 FIXES the output
          -- exponents at 15 and 18, so unlike rmsnorm there is nothing to
          -- normalise against and the emit pass is a straight multiply.
          when S_EMIT =>
            if idx < NB then                                  -- stage F: mux
              base := idx * LANES;
              for k in 0 to LANES-1 loop
                xf(k) <= signed(x_mant((base+k+1)*16-1 downto (base+k)*16));
              end loop;
              vf <= '1'; idxf <= idx; idx <= idx + 1;
            else
              vf <= '0';
            end if;
            v1 <= vf; idx1 <= idxf;                           -- stage 1: mults
            for k in 0 to LANES-1 loop
              pk(k) <= resize(xf(k) * y_k, 64);
              pq(k) <= resize(xf(k) * y_q, 64);
            end loop;
            -- stage 2: place.  Gated on v1/idx1, NOT v2/idx2, and the
            -- difference is one pipeline stage.  rmsnorm_rs has TWO multiply
            -- stages (xm*inv, then *wm) so its products lag the index by two
            -- and match idx2; this unit has ONE (there is no weight multiply),
            -- so pk/pq lag by one and match idx1.  Copying the deeper unit's
            -- gating wrote every block with the index of the block four
            -- elements later.  Uniform-magnitude test vectors cannot see that
            -- -- it was caught only by varying |x| per element.
            if v1 = '1' then
              base := idx1 * LANES;
              for k in 0 to LANES-1 loop
                -- Both paths: a per-INVOCATION scalar shift, its rounding
                -- bias precomputed once in S_RQ_FOLD, exactly as rmsnorm_rs
                -- precomputes emit_bias.  Never a per-element shift amount.
                ok := shift_right(pk(k) + bias_k, sh_k);
                oq := shift_right(pq(k) + bias_q, sh_q);
                k_reg((base+k+1)*16-1 downto (base+k)*16)
                  <= std_logic_vector(sat16(ok));
                q_reg((base+k+1)*16-1 downto (base+k)*16)
                  <= std_logic_vector(sat16(oq));
              end loop;
            end if;
            if idx = NB and vf = '0' and v1 = '0' then
              done  <= '1';
              state <= S_IDLE;
            end if;

          -- ---- ssq = 0: zeros on both paths ------------------------------
          when S_ZERO =>
            base := idx * LANES;
            for k in 0 to LANES-1 loop
              k_reg((base+k+1)*16-1 downto (base+k)*16) <= (others => '0');
              q_reg((base+k+1)*16-1 downto (base+k)*16) <= (others => '0');
            end loop;
            if idx = NB-1 then
              idx <= 0; done <= '1'; state <= S_IDLE;
            else
              idx <= idx + 1;
            end if;

          when others => state <= S_IDLE;
        end case;
      end if;
    end if;
  end process;
end architecture;
