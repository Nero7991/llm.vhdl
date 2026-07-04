-- rtl/rmsnorm.vhd
-- Integer RMSNorm.  Matches rmsnorm_fx() in ref/run_fx.c bit-for-bit on the
-- integer kernel (rsqrt_q) and within +/-2 int16 LSB on the output (the oracle
-- uses float for the weight-multiply glue; the RTL uses integer via scale_mul).
--
-- Block-fp convention: value[j] = mant[j] * 2^(-exp).
-- x arrives as block-fp (x_mant, x_exp).
-- w arrives as block-fp (w_mant, w_exp) -- quantised with fx_bfp_from_float.
-- Output is block-fp (o_mant, o_exp).
--
-- Algorithm (mirrors rmsnorm_fx):
--   S   = sum(xm[j]^2)
--   mean_sq_q = round(S * 2^Q / N) >> 2*xe  (Q=12, round-half-up)
--   inv = rsqrt_q(mean_sq_q, Q)
--   raw[j] = xm[j] * inv * wm[j]         (integer, scale = 2^(-xe-Q-we))
--   o_exp  = xe + we + Q - shift_total    (shift chosen so max|om|<=32767)
--   om[j]  = scale_mul(raw[j], 1, shift_total)
--
-- AREA-EFFICIENT (element-SEQUENTIAL) implementation.
-- Rather than unrolling all N multiply-accumulates and all N normalises into a
-- single combinational clock (which infers N parallel multipliers -> ~86k LUTs /
-- 353 DSP, does not fit), an FSM time-multiplexes ONE datapath over the elements:
--   S_ACC   : accumulate S = sum(xm[j]^2), one x[j]^2 per cycle (shared mult).
--   S_INV   : one-shot compute mean_sq_q + rsqrt_q -> inv (called ONCE, as before).
--   S_RAW   : compute raw[j] = xm[j]*inv*wm[j], one element per cycle, track max.
--   S_SHIFT : find MSB of max -> shift_total, set o_exp.
--   S_EMIT  : quantise raw[j] via scale_mul, one element per cycle; pulse done.
-- Every intermediate width / rounding is IDENTICAL to the unrolled version, so
-- o_mant/o_exp are bit-exact.  `done` now pulses after the iteration completes
-- (multi-cycle); consumers already use a start/done handshake.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use work.fixed_pkg.all;
use work.util_pkg.all;

entity rmsnorm is
  generic(N : positive; Q : integer := 12);
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

architecture rtl of rmsnorm is
  -- Array of 64-bit signed, one raw accumulator per element (registers).
  type raw64_arr is array (natural range <>) of signed(63 downto 0);
  type state_t is (S_IDLE, S_ACC, S_INV, S_RAW, S_SHIFT, S_EMIT);
begin
  process(clk)
    -- Control
    variable state       : state_t := S_IDLE;
    variable idx         : integer range 0 to N := 0;
    -- Accumulators and intermediates
    variable S           : signed(63 downto 0);
    variable num         : signed(63 downto 0);
    variable mean_sq_q   : signed(63 downto 0);
    variable inv32       : signed(31 downto 0);
    variable inv_ext     : signed(63 downto 0);
    variable xm_j        : signed(15 downto 0);
    variable wm_j        : signed(15 downto 0);
    variable xm_ext      : signed(63 downto 0);
    variable wm_ext      : signed(63 downto 0);
    variable xm_inv      : signed(63 downto 0);   -- xm[j] * inv (fits ~33 bits)
    variable raw_j       : signed(63 downto 0);   -- xm[j]*inv*wm[j] (fits ~48 bits)
    variable raws        : raw64_arr(0 to N-1);
    -- Magnitude tracking
    variable max_raw     : signed(63 downto 0);
    variable abs_raw_j   : signed(63 downto 0);
    -- Exponent / shift
    variable xe, we      : integer;
    variable sh          : integer;
    variable bias64      : signed(63 downto 0);
    variable p           : integer;
    variable shift_total : integer;
    -- Output
    variable om_32       : signed(31 downto 0);
  begin
    if rising_edge(clk) then
      done <= '0';
      if rst = '1' then
        state  := S_IDLE;
        idx    := 0;
        o_exp  <= 0;
        o_mant <= (others => '0');
      else
        case state is

          -- ----------------------------------------------------------------
          -- Wait for start; latch block exponents, zero the accumulator.
          -- ----------------------------------------------------------------
          when S_IDLE =>
            if start = '1' then
              xe    := x_exp;
              we    := w_exp;
              S     := (others => '0');
              idx   := 0;
              state := S_ACC;
            end if;

          -- ----------------------------------------------------------------
          -- Step 1: S = sum(xm[j]^2) in int64, one element per cycle.
          -- ----------------------------------------------------------------
          when S_ACC =>
            xm_j := signed(x_mant((idx+1)*16-1 downto idx*16));
            S    := S + resize(xm_j * xm_j, 64);
            if idx = N-1 then
              idx   := 0;
              state := S_INV;
            else
              idx := idx + 1;
            end if;

          -- ----------------------------------------------------------------
          -- Step 2/3: mean_sq_q (Q format, block-exp adjusted) then
          --   inv = rsqrt_q(mean_sq_q, Q).  Computed ONCE (as before).
          -- ----------------------------------------------------------------
          when S_INV =>
            num       := shift_left(S, Q);
            mean_sq_q := (num + to_signed(N/2, 64)) / to_signed(N, 64);

            if xe >= 0 then
              sh := 2 * xe;
              if sh > 62 then sh := 62; end if;
              if sh > 0 then
                bias64    := shift_left(to_signed(1, 64), sh - 1);
                mean_sq_q := shift_right(mean_sq_q + bias64, sh);
              end if;
            else
              sh := -(2 * xe);
              if sh > 62 then sh := 62; end if;
              mean_sq_q := shift_left(mean_sq_q, sh);
            end if;

            if mean_sq_q < 1 then mean_sq_q := to_signed(1, 64); end if;

            inv32   := rsqrt_q(mean_sq_q, Q);
            inv_ext := resize(inv32, 64);

            max_raw := (others => '0');
            idx     := 0;
            state   := S_RAW;

          -- ----------------------------------------------------------------
          -- Step 4: raw[j] = xm[j]*inv*wm[j], one element per cycle; track max.
          --   resize(a*b,64) takes the lower 64 bits (values fit in <2^48).
          -- ----------------------------------------------------------------
          when S_RAW =>
            xm_j   := signed(x_mant((idx+1)*16-1 downto idx*16));
            wm_j   := signed(w_mant((idx+1)*16-1 downto idx*16));
            xm_ext := resize(xm_j, 64);
            wm_ext := resize(wm_j, 64);
            xm_inv := resize(xm_ext * inv_ext, 64);
            raw_j  := resize(xm_inv * wm_ext, 64);
            raws(idx) := raw_j;
            -- Absolute value for magnitude tracking
            if raw_j < 0 then abs_raw_j := -raw_j;
            else               abs_raw_j :=  raw_j;
            end if;
            if abs_raw_j > max_raw then max_raw := abs_raw_j; end if;
            if idx = N-1 then
              idx   := 0;
              state := S_SHIFT;
            else
              idx := idx + 1;
            end if;

          -- ----------------------------------------------------------------
          -- Step 5/6: shift_total = MSB(max_raw) - 14; output exponent.
          -- ----------------------------------------------------------------
          when S_SHIFT =>
            p := 0;
            for i in 0 to 62 loop
              if max_raw(i) = '1' then p := i; end if;
            end loop;
            shift_total := p - 14;
            if shift_total < 0 then shift_total := 0; end if;
            o_exp <= xe + we + Q - shift_total;
            idx   := 0;
            state := S_EMIT;

          -- ----------------------------------------------------------------
          -- Step 7: quantise raw[j] to int16 via scale_mul, one per cycle.
          --   scale_mul(acc, 1, shift_total) = round(acc / 2^shift_total).
          --   done pulses on the final element (o_mant fully written by then).
          -- ----------------------------------------------------------------
          when S_EMIT =>
            om_32 := scale_mul(raws(idx), to_signed(1, 32), shift_total);
            -- Saturate to int16 range (should not trigger if shift_total chosen correctly)
            if    om_32 > 32767  then
              o_mant((idx+1)*16-1 downto idx*16) <= std_logic_vector(to_signed( 32767, 16));
            elsif om_32 < -32768 then
              o_mant((idx+1)*16-1 downto idx*16) <= std_logic_vector(to_signed(-32768, 16));
            else
              o_mant((idx+1)*16-1 downto idx*16) <= std_logic_vector(resize(om_32, 16));
            end if;
            if idx = N-1 then
              idx   := 0;
              done  <= '1';
              state := S_IDLE;
            else
              idx := idx + 1;
            end if;

        end case;
      end if;
    end if;
  end process;
end architecture;
