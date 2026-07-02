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
  -- Unconstrained array of 64-bit signed; constrained to N in the process variable.
  type raw64_arr is array (natural range <>) of signed(63 downto 0);
begin
  process(clk)
    -- Accumulators and intermediates
    variable S           : signed(63 downto 0);
    variable num         : signed(63 downto 0);
    variable mean_sq_q   : signed(63 downto 0);
    variable inv32       : signed(31 downto 0);
    variable xm_j        : signed(15 downto 0);
    variable wm_j        : signed(15 downto 0);
    variable xm_ext      : signed(63 downto 0);
    variable inv_ext     : signed(63 downto 0);
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
        o_exp  <= 0;
        o_mant <= (others => '0');
      elsif start = '1' then
        xe := x_exp;
        we := w_exp;

        -- ----------------------------------------------------------------
        -- Step 1: S = sum(xm[j]^2) in int64
        -- ----------------------------------------------------------------
        S := (others => '0');
        for j in 0 to N-1 loop
          xm_j := signed(x_mant((j+1)*16-1 downto j*16));
          S    := S + resize(xm_j * xm_j, 64);
        end loop;

        -- ----------------------------------------------------------------
        -- Step 2: mean_sq_q in Q format, adjusted for block exponent xe.
        --
        --   num        = S << Q
        --   mean_sq_q  = (num + N/2) / N        (round-half-up divide)
        --   if xe >= 0: mean_sq_q >>= 2*xe      (round-half-up right shift)
        --   else:       mean_sq_q <<= -2*xe
        --   eps = llround(1e-5 * 2^12) = 0 at Q=12; guard >= 1
        -- ----------------------------------------------------------------
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

        -- ----------------------------------------------------------------
        -- Step 3: inv = rsqrt_q(mean_sq_q, Q)
        -- ----------------------------------------------------------------
        inv32 := rsqrt_q(mean_sq_q, Q);

        -- ----------------------------------------------------------------
        -- Step 4: raw[j] = xm[j] * inv * wm[j]; track max magnitude.
        --
        --   Uses resize(a*b, 64) to take the lower 64 bits of the product.
        --   Values fit: |xm|<=32767, |inv|<=2^18 (typical), |wm|<=32767 ->
        --   max |raw| < 2^48, well within int64.
        -- ----------------------------------------------------------------
        max_raw := (others => '0');
        inv_ext := resize(inv32, 64);
        for j in 0 to N-1 loop
          xm_j      := signed(x_mant((j+1)*16-1 downto j*16));
          wm_j      := signed(w_mant((j+1)*16-1 downto j*16));
          xm_ext    := resize(xm_j, 64);
          wm_ext    := resize(wm_j, 64);
          xm_inv    := resize(xm_ext * inv_ext, 64);
          raw_j     := resize(xm_inv * wm_ext, 64);
          raws(j)   := raw_j;
          -- Absolute value for magnitude tracking
          if raw_j < 0 then abs_raw_j := -raw_j;
          else               abs_raw_j :=  raw_j;
          end if;
          if abs_raw_j > max_raw then max_raw := abs_raw_j; end if;
        end loop;

        -- ----------------------------------------------------------------
        -- Step 5: Find MSB of max_raw to determine shift_total.
        --   shift_total = MSB_position(max_raw) - 14
        --   (so the shifted result has MSB at bit 14 => fits in int16)
        -- ----------------------------------------------------------------
        p := 0;
        for i in 0 to 62 loop
          if max_raw(i) = '1' then p := i; end if;
        end loop;
        shift_total := p - 14;
        if shift_total < 0 then shift_total := 0; end if;

        -- ----------------------------------------------------------------
        -- Step 6: Output exponent.
        --   raw[j] represents real_o[j] * 2^(xe+we+Q), so after dividing
        --   by 2^shift_total the result represents real_o[j] * 2^(xe+we+Q-shift_total).
        --   Block-fp convention: om[j] * 2^(-oe) = real_o[j]
        --   => oe = xe + we + Q - shift_total
        -- ----------------------------------------------------------------
        o_exp <= xe + we + Q - shift_total;

        -- ----------------------------------------------------------------
        -- Step 7: Quantise to int16 using scale_mul (provides real coverage
        --   for the scale_mul path left untested in tb_fixed_pkg).
        --   scale_mul(acc, 1, shift_total) = round(acc / 2^shift_total).
        -- ----------------------------------------------------------------
        for j in 0 to N-1 loop
          om_32 := scale_mul(raws(j), to_signed(1, 32), shift_total);
          -- Saturate to int16 range (should not trigger if shift_total chosen correctly)
          if    om_32 > 32767  then
            o_mant((j+1)*16-1 downto j*16) <= std_logic_vector(to_signed( 32767, 16));
          elsif om_32 < -32768 then
            o_mant((j+1)*16-1 downto j*16) <= std_logic_vector(to_signed(-32768, 16));
          else
            o_mant((j+1)*16-1 downto j*16) <= std_logic_vector(resize(om_32, 16));
          end if;
        end loop;

        done <= '1';
      end if;
    end if;
  end process;
end architecture;
