-- rtl/swiglu.vhd
-- SwiGLU (SiLU * gate) nonlinearity in Q12 fixed-point.
-- Mirrors swiglu_fx() in ref/run_fx.c:
--   v_q  = BFP_to_Qq(hb[i],  hb_exp)    -- round-half-up conversion
--   h2_q = BFP_to_Qq(hb2[i], hb2_exp)   -- round-half-up conversion
--   sig  = sigmoid_q(v_q, Q)             -- from fixed_pkg (LUT + linear interp)
--   silu = (v_q * sig) >> Q              -- plain arithmetic right shift (floor)
--   out  = (silu * h2_q) >> Q            -- plain arithmetic right shift (floor)
--
-- Block-fp convention: value[j] = mant[j] * 2^(-exp).
-- Input:  hb_mant/hb_exp, hb2_mant/hb2_exp (16-bit mantissas, shared exponent).
-- Output: out_q, N signed 32-bit Q12 values packed into one wide vector.
--
-- Arithmetic widths: v_q/h2_q/sig 32-bit signed; products 64-bit (32x32->64),
-- no 128-bit intermediates.  All multiplies stay 32x32 by resizing silu to 32
-- before the second multiply (safe: |silu| <= |v_q| since |sig| <= 2^Q).
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use work.fixed_pkg.all;

entity swiglu is
  generic(N : positive; Q : integer := 12);
  port(
    clk      : in  std_logic;
    rst      : in  std_logic;
    start    : in  std_logic;
    hb_mant  : in  std_logic_vector(N*16-1 downto 0);
    hb_exp   : in  integer;
    hb2_mant : in  std_logic_vector(N*16-1 downto 0);
    hb2_exp  : in  integer;
    done     : out std_logic;
    out_q    : out std_logic_vector(N*32-1 downto 0)
  );
end entity swiglu;

architecture rtl of swiglu is
begin
  process(clk)
    variable mant_raw : signed(15 downto 0);
    variable mant64   : signed(63 downto 0);
    variable bias64   : signed(63 downto 0);
    variable v_q      : signed(31 downto 0);
    variable h2_q     : signed(31 downto 0);
    variable sig      : signed(31 downto 0);
    variable prod1    : signed(63 downto 0);  -- v_q * sig  (32x32)
    variable silu32   : signed(31 downto 0);  -- silu after >>Q, resized to 32
    variable prod2    : signed(63 downto 0);  -- silu * h2_q (32x32)
    variable out_v    : signed(31 downto 0);
    variable sh       : integer;
  begin
    if rising_edge(clk) then
      done <= '0';
      if rst = '1' then
        out_q <= (others => '0');
      elsif start = '1' then

        for i in 0 to N-1 loop

          -- Convert hb BFP mantissa to Qq: v_q = round(mant * 2^(Q - hb_exp))
          -- Round-half-up: add bias 2^(|sh|-1) then arithmetic right shift.
          mant_raw := signed(hb_mant((i+1)*16-1 downto i*16));
          mant64   := resize(mant_raw, 64);
          sh       := Q - hb_exp;
          if sh >= 0 then
            v_q := resize(shift_left(mant64, sh), 32);
          else
            bias64 := shift_left(to_signed(1, 64), (-sh) - 1);
            v_q    := resize(shift_right(mant64 + bias64, -sh), 32);
          end if;

          -- Convert hb2 BFP mantissa to Qq: h2_q = round(mant * 2^(Q - hb2_exp))
          mant_raw := signed(hb2_mant((i+1)*16-1 downto i*16));
          mant64   := resize(mant_raw, 64);
          sh       := Q - hb2_exp;
          if sh >= 0 then
            h2_q := resize(shift_left(mant64, sh), 32);
          else
            bias64 := shift_left(to_signed(1, 64), (-sh) - 1);
            h2_q   := resize(shift_right(mant64 + bias64, -sh), 32);
          end if;

          -- sig = sigmoid_q(v_q, Q): Qq value in [0, 2^Q]
          sig := sigmoid_q(v_q, Q);

          -- silu = (v_q * sig) >> Q  (32x32->64, plain arithmetic right shift)
          prod1  := v_q * sig;
          silu32 := resize(shift_right(prod1, Q), 32);

          -- out = (silu * h2_q) >> Q  (32x32->64, plain arithmetic right shift)
          prod2 := silu32 * h2_q;
          out_v := resize(shift_right(prod2, Q), 32);

          out_q((i+1)*32-1 downto i*32) <= std_logic_vector(out_v);

        end loop;

        done <= '1';
      end if;
    end if;
  end process;
end architecture rtl;
