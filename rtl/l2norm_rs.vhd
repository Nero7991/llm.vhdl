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
-- had not pinned it:
--
--   ssq    = sum xm[i]^2                             -- u38, |xm| <= 32768
--   inv_k  = rsqrt_q(ssq << Q, Q)                    -- = round(2^Q / sqrt(ssq))
--   inv_q  = rsqrt_q((ssq << 7) << Q, Q)             -- = round(2^Q / sqrt(128*ssq))
--   k_n[i] = sat16( round_half_up(xm[i] * inv_k, 3) )   -- exp 15
--   q_s[i] = sat16( xm[i] * inv_q )                     -- exp 18
--
-- Q = 18, and that is forced, not chosen.  rsqrt_q takes s64, ssq < 2^37, and
-- the q path shifts the argument LEFT BY 7 before scaling, so ssq<<7<<Q must
-- stay inside s63: Q <= 19.  Q = 18 then makes the two output shifts fall out
-- as 2^15/2^18 = >>3 for the k path and 2^18/2^18 = no shift at all for the q
-- path.  A larger Q would carry more of the rsqrt's precision but overflows;
-- Q = 12 (rmsnorm's) would need a LEFT shift on the output, which throws away
-- precision it already has.
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
    LANES : positive := 4;
    Q     : integer  := 18
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
                   S_SEED1, S_SEED2, S_RQ, S_RQ_FOLD,
                   S_FIN1, S_FIN2, S_FIN3, S_CLAMP,
                   S_NEXT,                     -- second rsqrt pass, or emit
                   S_EMIT, S_ZERO);
  signal state : state_t := S_IDLE;

  signal ssq   : signed(63 downto 0) := (others => '0');
  signal pass  : natural range 0 to 1 := 0;    -- 0 = k path, 1 = q path
  signal inv_k, inv_q : signed(31 downto 0) := (others => '0');

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
          -- pass 0 (k path): ssq << Q
          -- pass 1 (q path): ssq << 7 << Q -- the 1/sqrt(128) fold, a SHIFT of
          --                                  the argument, no multiply
          when S_ARG =>
            assert ssq >= 0 and ssq < shift_left(to_signed(1, 64), 38)
              report "l2norm_rs: ssq outside the u38 bound of 2.1.3"
              severity failure;
            if ssq = 0 then
              -- 2.1.3's deliberate divergence from ggml: zeros, not dust
              idx <= 0;
              state <= S_ZERO;
            elsif pass = 0 then
              arg_r <= shift_left(ssq, Q);
              state <= S_SEED1;
            else
              arg_r <= shift_left(ssq, Q + 7);
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
            rq_d := rq_p - Q;
            if (rq_d mod 2) /= 0 then
              rq_yfin <= resize(shift_right(resize(rq_y, 64) * INV_SQRT2_C, 30), 32);
              rq_he   := (rq_d - 1) / 2;
            else
              rq_yfin <= rq_y;
              rq_he   := rq_d / 2;
            end if;
            rq_E  <= Q - 30 - rq_he;
            state <= S_FIN1;

          when S_FIN1 =>                                     -- one barrel shift
            if rq_E >= 0 then
              rq_up_r <= true;  rq_sh_r <= rq_E;
              rq_bias_r <= (others => '0');
            else
              rq_up_r <= false; rq_sh_r <= -rq_E;
              rq_bias_r <= shift_left(to_signed(1, 64), (-rq_E) - 1);
            end if;
            state <= S_FIN2;

          when S_FIN2 =>                                     -- one 64-bit add
            rq_sum_r <= resize(rq_yfin, 64) + rq_bias_r;
            state <= S_FIN3;

          when S_FIN3 =>                                     -- one barrel shift
            if rq_E > 32 then
              rq_shifted <= to_signed(2147483647, 64);
            elsif rq_up_r then
              rq_shifted <= shift_left(resize(rq_yfin, 64), rq_sh_r);
            else
              rq_shifted <= shift_right(rq_sum_r, rq_sh_r);
            end if;
            state <= S_CLAMP;

          when S_CLAMP =>                                    -- one compare
            if    rq_shifted > to_signed(2147483647, 64) then
              if pass = 0 then inv_k <= to_signed(2147483647, 32);
              else             inv_q <= to_signed(2147483647, 32); end if;
            elsif rq_shifted < 0 then
              if pass = 0 then inv_k <= to_signed(0, 32);
              else             inv_q <= to_signed(0, 32); end if;
            else
              if pass = 0 then inv_k <= resize(rq_shifted, 32);
              else             inv_q <= resize(rq_shifted, 32); end if;
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
              pk(k) <= resize(xf(k) * inv_k, 64);
              pq(k) <= resize(xf(k) * inv_q, 64);
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
                -- k path: 2^15 / 2^Q = >>3 at Q=18, round half up
                ok := shift_right(pk(k) + to_signed(4, 64), 3);
                -- q path: 2^18 / 2^Q = no shift at all at Q=18
                oq := pq(k);
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
