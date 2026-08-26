-- gdn_scalar: subsystem B's per-head scalar path (2.1.3, last block).
--
-- Produces the two per-head scalars the recurrence consumes:
--
--   arg  = Q(alpha) + Q(dt)
--   sp   = softplus(arg)
--   g    = min(0, round_shift(sp * a_m, a_e))   clamped at -16
--   eg   = exp(g)                               -> unsigned Q15, 0..32768
--   beta = sigmoid(Q(b))                        -> unsigned Q16
--
-- ONE INTERPOLATOR, THREE KERNELS.  softplus, exp and sigmoid are all
-- evaluated as a Q30 table plus a linear interpolation, and fx.h gives all
-- three the SAME geometry: 1/16 step, offset = z + 16*2^q, 257 or 513 entries.
-- So this unit has a single interpolate engine that the FSM calls three times
-- with a different ROM, rather than three copies.  That is why the DSP cost
-- below is what it is.
--
-- THE INDEX NEEDS NO MULTIPLY.  fx.h writes the index as
-- idx = offset*16, k = idx >> q, frac = idx - (k << q).  Since the 16 is a
-- power of two this collapses to a fixed field split of offset:
--     k    = offset >> (q-4)
--     frac = offset(q-5 downto 0) << 4
-- so the whole index path is wiring, not arithmetic.
--
-- TWO DEFECTS IN 2.1.3 AS WRITTEN ARE CORRECTED HERE, BOTH MEASURED.
-- See docs/debugging/2026-08-26_gdn-scalar-path.md.
--
--  (1) THE SUM MUST NOT BE FORMED FROM TWO SATURATED TERMS.  2.1.3 says
--      alpha and dt are "converted to Q12 ... and added in s32", which
--      saturates each term before the add.  Two opposite-sign saturations
--      then cancel: a true argument of -34826 is computed as -1, and eg goes
--      from 4 (gate shut) to 32768 (gate wide open).  Here both terms are
--      converted on a wide grid and the sum is clamped once.
--
--  (2) THE POSITIVE TAIL MUST NOT BE CLAMPED.  Above +16 softplus is the
--      identity, so the argument's magnitude is exactly what propagates into
--      g through the multiply by a.  Clamping there is not lossless: it turns
--      a saturated gate into an open one (eg 30280 against a true 0.0037).
--      Only the negative tail is clamped, where softplus is below an LSB.
--
-- WHY SP_Q IS A GENERIC AND DEFAULTS TO 12.  2.1.3 pins the scalar grid at
-- Q12.  Measured on the real Qwen3.8-27B ssm_a / ssm_dt_bias weights (2304
-- heads, ref/gdn_eg_qwen3_27b.txt), end to end through this recipe against a
-- double oracle, the worst relative error on eg for the SLOW heads (those
-- retaining >= 99.9% per token, where the error compounds) and what it
-- compounds to over a 4096-token sequence:
--
--     SP_Q    slow-band rel err    (1+e)^4096
--       12          1.92e-04          2.196
--       14          5.23e-05          1.239
--       15          5.05e-05          1.230
--       16          4.09e-05          1.183
--       18          3.06e-05          1.133
--       20          3.01e-05          1.131      <- saturated
--
-- Q18 reaches the floor set by the exp table's own interpolation error
-- (3.04e-05, measured independently in
-- docs/debugging/2026-08-25_gdn-recurrence-error-bound.md), so past Q18 the
-- grid is no longer what limits accuracy.  The cost of moving 12 -> 18 is a
-- wider shift and nothing else: no extra DSP, no extra ROM, no extra state.
-- DEFAULT IS 18 as of 2026-08-26: the amendment is ADOPTED.  12 still
-- reproduces the superseded pinned grid exactly and is kept for comparison,
-- not as an option.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use work.fixed_luts_pkg.all;

entity gdn_scalar is
  generic(
    SP_Q : integer range 8 to 22 := 18   -- scalar-path grid; ADOPTED 2026-08-26
  );
  port(
    clk   : in  std_logic;
    rst   : in  std_logic;
    start : in  std_logic;
    -- (mantissa, exponent) pairs; value = m * 2**(-e)
    al_m  : in  signed(15 downto 0);
    al_e  : in  signed(7 downto 0);
    dt_m  : in  signed(15 downto 0);
    dt_e  : in  signed(7 downto 0);
    a_m   : in  signed(15 downto 0);     -- ssm_a, <= 0 per 1.1(b)
    a_e   : in  signed(7 downto 0);
    b_m   : in  signed(15 downto 0);
    b_e   : in  signed(7 downto 0);
    -- results
    eg    : out unsigned(15 downto 0);   -- Q15, 0 .. 32768
    beta  : out unsigned(15 downto 0);   -- Q16, saturated at 65535
    err_g : out std_logic;               -- g hit the -16 clamp (2.1.6)
    done  : out std_logic
  );
end entity;

architecture rtl of gdn_scalar is

  constant LIM   : integer := 16 * 2**SP_Q;    -- 16.0 on the SP_Q grid
  constant KSH   : integer := SP_Q - 4;        -- offset field split

  -- wide enough for the identity branch (2**45) plus headroom
  subtype wide_t is signed(51 downto 0);

  type st_t is (S_IDLE,
                S_CONV, S_SUM,
                S_SPSEL,
                S_IP_IDX, S_IP_RD, S_IP_MUL, S_IP_FIN,
                S_SPDONE,
                S_GMUL, S_GSH, S_GCLAMP,
                S_EGOUT,
                S_BCONV,
                S_BOUT,
                S_DONE);
  signal st : st_t := S_IDLE;

  -- interpolator call interface
  signal ip_rom : integer range 0 to 2 := 0;   -- 0 = SP, 1 = EXP, 2 = SIG
  signal ip_z   : signed(31 downto 0) := (others => '0');
  signal ip_ret : st_t := S_IDLE;
  signal ip_out : signed(31 downto 0) := (others => '0');   -- Q(SP_Q)

  signal ip_k    : integer range 0 to 512 := 0;
  signal ip_frac : unsigned(31 downto 0) := (others => '0');
  signal ip_lo   : signed(31 downto 0) := (others => '0');
  signal ip_hi   : signed(31 downto 0) := (others => '0');
  signal ip_p    : signed(63 downto 0) := (others => '0');

  signal al_q, dt_q : wide_t := (others => '0');
  signal arg        : wide_t := (others => '0');
  signal sp         : wide_t := (others => '0');
  signal gp         : signed(67 downto 0) := (others => '0');
  -- g BEFORE narrowing.  Narrowing to s32 first and clamping afterwards
  -- aliases a large negative back into (-LIM, 0] -- numeric_std resize keeps
  -- the sign bit and the low bits, so -(2**32 + 100) becomes -100, which never
  -- clamps and opens a gate the reference shuts.  Clamp wide, then narrow.
  signal g_w        : signed(67 downto 0) := (others => '0');
  signal eg_r       : signed(31 downto 0) := (others => '0');
  signal sp_tab     : std_logic := '0';   -- softplus came via the table

  -- Site 3 on a wide grid.  Same rounding as 2.1.3, but SATURATING at a
  -- sentinel instead of at the s32 rail, so the two terms of the softplus
  -- argument cannot cancel each other's saturation (defect 1 in the header).
  --
  -- Three properties this function must have, all of which it lacked when
  -- first written and all of which cost a divergence from the C reference:
  --   * m = 0 is ZERO on every grid.  Returning the positive sentinel for a
  --     zero mantissa with a large exponent slammed beta's gate to 65535.
  --   * the sentinel and the shift cutoff must MATCH the C reference exactly
  --     (SAT = 2**45, cutoff 40).  They were 2**45/36 here against 2**45/40
  --     there, which diverges for e in [SP_Q-40, SP_Q-37].
  --   * the exact shift branch must saturate TOO, not just the cutoff branch.
  --     32767 << 36 is ~2**51 per term, so two terms overflowed the s52
  --     accumulator and wrapped NEGATIVE -- an open gate where the reference
  --     has a shut one.
  -- With every term bounded by 2**45 the sum is bounded by 2**46, sp by 2**46,
  -- and sp*a_m by 2**61, which is also what keeps the C reference inside
  -- int64 rather than in undefined behaviour.
  constant SAT_W : wide_t := shift_left(to_signed(1, wide_t'length), 45);

  function to_q_wide(m : signed(15 downto 0); e : signed(7 downto 0))
    return wide_t is
    variable sh : integer;
    variable k  : natural;
    variable v  : wide_t;
  begin
    if m = 0 then
      return (others => '0');          -- zero is zero on every grid
    end if;
    sh := to_integer(e) - SP_Q;
    if sh > 62 then
      return (others => '0');
    elsif sh > 0 then
      k := sh - 1;                     -- 0 <= k <= 61
      return shift_right(resize(m, wide_t'length)
                         + shift_left(to_signed(1, wide_t'length), k), sh);
    elsif sh = 0 then
      return resize(m, wide_t'length);
    elsif -sh > 40 then
      if m > 0 then return SAT_W; else return -SAT_W; end if;
    else
      -- Saturate BEFORE shifting.  shift_left on a wide_t is performed AT
      -- wide_t's width, so -27632 << 37 wraps inside s52 and a post-shift
      -- check never sees the overflow -- while the C reference, working in
      -- int64, has the headroom and saturates correctly.  That asymmetry was
      -- a divergence, which is why the check is on m rather than on v.
      k := -sh;                        -- 1 <= k <= 40
      v := resize(m, wide_t'length);
      if v >  shift_right(SAT_W, k) then return  SAT_W; end if;
      if v < -shift_right(SAT_W, k) then return -SAT_W; end if;
      return shift_left(v, k);
    end if;
  end function;

  -- Round half toward +infinity by a runtime amount, with a SATURATING left
  -- branch.  a_e may be negative, which makes this a left shift of a value
  -- already as large as 2**61, and shifting that left by up to 40 overflows
  -- the s68 accumulator.  The C reference overflows int64 at the same point
  -- and the two wrap DIFFERENTLY, so this is a divergence rather than an
  -- inaccuracy.  g is clamped to [-16*2**q, 0] downstream and 16*2**q is at
  -- most 2**26, so saturating at 2**62 gives the identical clamped result.
  function rsh_r(v : signed; s : integer) return signed is
    variable t   : signed(v'length-1 downto 0) := v;
    variable sat : signed(v'length-1 downto 0);
    variable k   : natural;
  begin
    sat := shift_left(to_signed(1, t'length), 62);
    if s <= 0 then
      if t = 0 then
        return (t'range => '0');
      elsif -s > 62 then
        if t > 0 then return sat; else return -sat; end if;
      else
        k := -s;                       -- 1 <= k <= 62
        if t >  shift_right(sat, k) then return  sat; end if;
        if t < -shift_right(sat, k) then return -sat; end if;
        return shift_left(t, k);
      end if;
    elsif s > 62 then
      return (t'range => '0');
    else
      k := s - 1;                      -- 0 <= k <= 61
      return shift_right(t + shift_left(to_signed(1, t'length), k), s);
    end if;
  end function;

begin

  process(clk)
    variable off   : signed(51 downto 0);
    variable kk    : integer;
    variable kmax  : integer;
    variable itp   : signed(63 downto 0);
    variable corr  : signed(63 downto 0);
    variable gg    : signed(67 downto 0);
    variable ee    : signed(63 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        st <= S_IDLE; done <= '0'; err_g <= '0';
        eg <= (others => '0'); beta <= (others => '0');
      else
        done <= '0';
        case st is

          when S_IDLE =>
            if start = '1' then
              err_g <= '0';
              st <= S_CONV;
            end if;

          -- two independent barrel shifts, nothing else this cycle
          when S_CONV =>
            al_q <= to_q_wide(al_m, al_e);
            dt_q <= to_q_wide(dt_m, dt_e);
            st   <= S_SUM;

          -- the add, on the wide grid, so no term was saturated first
          when S_SUM =>
            arg <= al_q + dt_q;
            st  <= S_SPSEL;

          -- softplus branch select.  Negative tail clamps to zero (below an
          -- LSB); positive tail is the IDENTITY and must pass through.
          when S_SPSEL =>
            if arg <= to_signed(-LIM, wide_t'length) then
              sp     <= (others => '0');
              sp_tab <= '0';
              st     <= S_SPDONE;
            elsif arg >= to_signed(LIM, wide_t'length) then
              sp     <= arg;
              sp_tab <= '0';
              st     <= S_SPDONE;
            else
              ip_rom <= 0;
              ip_z   <= resize(-abs(arg), 32);   -- z = -|x| for the correction
              ip_ret <= S_SPDONE;
              sp_tab <= '1';
              st     <= S_IP_IDX;
            end if;

          -- ---------------- shared interpolator ----------------
          -- offset = z + 16*2^q ; k and frac are a field split of it
          -- frac is idx_fp - (k << q) with idx_fp = offset << 4, NOT simply
          -- the low field of offset.  The two agree in the interior, but at
          -- the top of the table they do not: fx.h clamps k to kmax and lets
          -- frac run to a FULL 2**q so the interpolation still lands exactly
          -- on lut[kmax+1].  The field-split form yields frac = 0 there and
          -- returns lut[kmax] instead -- one table step low.  That endpoint is
          -- not a corner case for exp: every g that rounds to 0 lands on it.
          when S_IP_IDX =>
            off := resize(ip_z, 52) + to_signed(LIM, 52);
            if off < 0 then off := (others => '0'); end if;
            if ip_rom = 2 then kmax := 511; else kmax := 255; end if;
            kk := to_integer(shift_right(off, KSH));
            if kk > kmax then kk := kmax; end if;
            if kk < 0    then kk := 0;    end if;
            ip_k    <= kk;
            ip_frac <= unsigned(resize(shift_left(off, 4)
                                       - shift_left(to_signed(kk, 52), SP_Q), 32));
            st      <= S_IP_RD;

          when S_IP_RD =>
            case ip_rom is
              when 0 =>
                ip_lo <= to_signed(SP_ROM(ip_k),   32);
                ip_hi <= to_signed(SP_ROM(ip_k+1), 32);
              when 1 =>
                ip_lo <= to_signed(EXP_ROM(ip_k),   32);
                ip_hi <= to_signed(EXP_ROM(ip_k+1), 32);
              when others =>
                ip_lo <= to_signed(SIG_ROM(ip_k),   32);
                ip_hi <= to_signed(SIG_ROM(ip_k+1), 32);
            end case;
            st <= S_IP_MUL;

          -- the one real multiply of the interpolator
          when S_IP_MUL =>
            ip_p <= resize((ip_hi - ip_lo) * signed('0' & ip_frac(30 downto 0)), 64);
            st   <= S_IP_FIN;

          when S_IP_FIN =>
            itp  := resize(ip_lo, 64) + shift_right(ip_p, SP_Q);
            corr := rsh_r(itp, 30 - SP_Q);
            ip_out <= resize(corr, 32);
            st     <= ip_ret;

          -- softplus = max(x,0) + correction
          when S_SPDONE =>
            if sp_tab = '1' then              -- came through the table
              if arg > 0 then sp <= arg + resize(ip_out, wide_t'length);
              else            sp <= resize(ip_out, wide_t'length); end if;
            end if;
            st <= S_GMUL;

          when S_GMUL =>
            gp <= resize(sp * a_m, 68);
            st <= S_GSH;

          -- barrel shift only, nothing else this cycle
          when S_GSH =>
            g_w <= rsh_r(gp, to_integer(a_e));
            st  <= S_GCLAMP;

          -- clamp in the WIDE domain and narrow in the same step, so no
          -- intermediate ever exists that could alias.  min(0,.) is 2.1.3's
          -- defensive guard; the lower clamp is exp_q's domain and sets err.
          when S_GCLAMP =>
            if g_w > 0 then
              ip_z <= (others => '0');
            elsif g_w < resize(to_signed(-LIM, 32), 68) then
              ip_z  <= to_signed(-LIM, 32);
              err_g <= '1';
            else
              ip_z <= resize(g_w, 32);
            end if;
            ip_rom <= 1;
            ip_ret <= S_EGOUT;
            st     <= S_IP_IDX;

          when S_EGOUT =>
            ee := rsh_r(resize(ip_out, 64), SP_Q - 15);
            if ee > 32768 then ee := to_signed(32768, 64); end if;
            if ee < 0     then ee := (others => '0');      end if;
            eg <= unsigned(ee(15 downto 0));
            st <= S_BCONV;

          when S_BCONV =>
            ip_rom <= 2;
            ip_ret <= S_BOUT;
            st     <= S_IP_IDX;

          when S_BOUT =>
            ee := rsh_r(resize(ip_out, 64), SP_Q - 16);
            if ee > 65535 then ee := to_signed(65535, 64); end if;
            if ee < 0     then ee := (others => '0');      end if;
            beta <= unsigned(ee(15 downto 0));
            st   <= S_DONE;

          when S_DONE =>
            done <= '1';
            st   <= S_IDLE;

        end case;

        -- the interpolator's z for the sigmoid call, registered one state
        -- ahead so S_IP_IDX never does a mux in series with the add.  The exp
        -- call's z is set by S_GCLAMP itself, since it has to clamp anyway.
        if st = S_BCONV then
          -- clamp before narrowing: sigmoid's own domain guard makes anything
          -- past +/-LIM equivalent, and resize() of a s52 into s32 would wrap.
          if to_q_wide(b_m, b_e) > to_signed(LIM, wide_t'length) then
            ip_z <= to_signed(LIM, 32);
          elsif to_q_wide(b_m, b_e) < to_signed(-LIM, wide_t'length) then
            ip_z <= to_signed(-LIM, 32);
          else
            ip_z <= resize(to_q_wide(b_m, b_e), 32);
          end if;
        end if;

      end if;
    end if;
  end process;

end architecture;
