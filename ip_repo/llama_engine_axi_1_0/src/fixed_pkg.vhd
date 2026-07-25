-- rtl/fixed_pkg.vhd
-- Fixed-point kernels: rsqrt_q, exp_q, sigmoid_q, scale_mul.
-- Bit-exact vs ref/fx.h. ROMs sourced from work.fixed_luts_pkg (generated).
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use work.fixed_luts_pkg.all;

package fixed_pkg is
  -- Named subtypes avoid GHDL 1.0.0 "index constraint not allowed here" on
  -- inline-constrained array types in subprogram interfaces.  Declared in the
  -- HEADER so mulshr can be exported (pipelined rsqrt in rmsnorm uses it).
  subtype s64  is signed(63 downto 0);
  subtype s96  is signed(95 downto 0);
  subtype s128 is signed(127 downto 0);
  function rsqrt_q  (mean_sq_q : signed; q : integer) return signed;
  function mulshr   (a, b : s64; sh : natural) return s64;  -- exported for pipelined rsqrt
  function exp_q    (z_q       : signed; q : integer) return signed;
  function sigmoid_q(z_q       : signed; q : integer) return signed;
  function scale_mul(acc : signed; mult : signed; shift : integer) return signed;
end package;

package body fixed_pkg is

  -- ROMs: bit-identical to the former mem/luts/*.mem TEXTIO load, now sourced
  -- from work.fixed_luts_pkg (RSQRT_ROM/EXP_ROM/SIG_ROM) so this package
  -- elaborates without std.textio and synthesizes in Vivado. Regenerate the
  -- package with tools/gen_fixed_luts_pkg.py if the .mem files change.

  -- -----------------------------------------------------------------------
  -- Internal helper: multiply two s64, arithmetic-right-shift the 128-bit
  -- product by sh, return lower 64 bits. All call sites keep the result in
  -- signed-64 range (max intermediate ~3*2^60 before the shift).
  -- -----------------------------------------------------------------------
  function mulshr(a, b : s64; sh : natural) return s64 is
    variable p   : s128;
    variable tmp : s128;
    variable r   : s64;
  begin
    p   := a * b;
    tmp := shift_right(p, sh);
    r   := tmp(63 downto 0);
    return r;
  end function;

  -- -----------------------------------------------------------------------
  -- rsqrt_q: given mean_sq_q = round(v * 2^q), return round(1/sqrt(v)*2^q).
  -- Mirrors fx_rsqrt exactly (same LUT seed, same Newton steps, same shifts).
  -- -----------------------------------------------------------------------
  function rsqrt_q(mean_sq_q : signed; q : integer) return signed is
    variable A     : unsigned(63 downto 0);
    variable p     : integer;
    variable mant  : unsigned(63 downto 0);
    variable smant : s64;
    variable k     : integer;
    variable y     : s64;
    variable y2, my2, three, diff : s64;
    variable d, he, E, sh : integer;
    variable yfin, bias, r : s64;
    constant INV_SQRT2 : s64 := to_signed(759250125, 64);
  begin
    if mean_sq_q <= 0 then
      return to_signed(2147483647, 32);
    end if;

    A := unsigned(resize(mean_sq_q, 64));

    -- MSB position: highest set bit index (matches fx_msb64 in fx.h)
    p := 0;
    for i in 0 to 62 loop
      if A(i) = '1' then p := i; end if;
    end loop;

    -- Normalise mantissa to Q30 in [1,2): bit 30 is the implicit leading 1
    if p <= 30 then
      mant := shift_left(A, 30 - p);
    else
      mant := shift_right(A, p - 30);
    end if;

    -- Seed: top 6 fraction bits of mantissa (bits [29:24])
    k     := to_integer(mant(29 downto 24));
    y     := to_signed(RSQRT_ROM(k), 64);
    smant := signed(mant);

    -- Three in Q30 = 3 << 30
    three := shift_left(to_signed(3, 64), 30);

    -- Two Newton iterations: y = (y*(3 - mant*y^2)) >> 31
    for it in 0 to 1 loop
      y2   := mulshr(y, y, 30);
      my2  := mulshr(smant, y2, 30);
      diff := three - my2;
      y    := mulshr(y, diff, 31);
    end loop;

    -- Parity fold: d = p - q
    d := p - q;
    if (d mod 2) /= 0 then
      yfin := mulshr(y, INV_SQRT2, 30);
      he   := (d - 1) / 2;
    else
      yfin := y;
      he   := d / 2;
    end if;

    -- Final shift: E = q - 30 - he
    E := q - 30 - he;
    if E > 32 then
      return to_signed(2147483647, 32);
    elsif E >= 0 then
      r := shift_left(yfin, E);
    else
      sh   := -E;
      bias := shift_left(to_signed(1, 64), sh - 1);
      r    := shift_right(yfin + bias, sh);
    end if;

    if r > to_signed(2147483647, 64) then return to_signed(2147483647, 32); end if;
    if r < 0 then return to_signed(0, 32); end if;
    return resize(r, 32);
  end function;

  -- -----------------------------------------------------------------------
  -- exp_q: exp(z) for z<=0, input/output Qq. Mirrors fx_exp_q.
  -- -----------------------------------------------------------------------
  function exp_q(z_q : signed; q : integer) return signed is
    variable z      : s64;
    variable one_q  : s64;
    variable offset : s64;
    variable idx_fp : s64;
    variable k      : integer;
    variable frac   : s64;
    variable lo, hi : s64;
    variable prod   : s128;
    variable tmp    : s128;
    variable interp : s64;
    variable r      : s64;
    variable sh     : integer;
    variable bias   : s64;
  begin
    z     := resize(z_q, 64);
    one_q := shift_left(to_signed(1, 64), q);

    if z < shift_left(to_signed(-16, 64), q) then
      return to_signed(0, 32);
    end if;
    if z > 0 then z := to_signed(0, 64); end if;

    -- offset in [0, 16*2^q]; idx_fp = offset * 16
    offset := z + shift_left(to_signed(16, 64), q);
    idx_fp := shift_left(offset, 4);

    k := to_integer(shift_right(idx_fp, q));
    if k > 255 then k := 255; end if;
    if k <   0 then k :=   0; end if;

    frac := idx_fp - shift_left(to_signed(k, 64), q);

    lo := to_signed(EXP_ROM(k),     64);
    hi := to_signed(EXP_ROM(k + 1), 64);

    -- interp_q30 = lo + ((hi - lo) * frac) >> q
    prod   := (hi - lo) * frac;
    tmp    := shift_right(prod, q);
    interp := lo + tmp(63 downto 0);

    -- Shift Q30 -> Qq (for q=12: sh=18, round half up)
    if q <= 30 then
      sh := 30 - q;
      if sh > 0 then
        bias := shift_left(to_signed(1, 64), sh - 1);
        r    := shift_right(interp + bias, sh);
      else
        r := interp;
      end if;
    else
      r := shift_left(interp, q - 30);
    end if;

    if r < 0 then return to_signed(0, 32); end if;
    if r > to_signed(2147483647, 64) then return to_signed(2147483647, 32); end if;
    return resize(r, 32);
  end function;

  -- -----------------------------------------------------------------------
  -- sigmoid_q: sigmoid(z), input/output Qq. Mirrors fx_sigmoid_q.
  -- -----------------------------------------------------------------------
  function sigmoid_q(z_q : signed; q : integer) return signed is
    variable z      : s64;
    variable one_q  : s64;
    variable offset : s64;
    variable idx_fp : s64;
    variable k      : integer;
    variable frac   : s64;
    variable lo, hi : s64;
    variable prod   : s128;
    variable tmp    : s128;
    variable interp : s64;
    variable r      : s64;
    variable sh     : integer;
    variable bias   : s64;
  begin
    z     := resize(z_q, 64);
    one_q := shift_left(to_signed(1, 64), q);

    if z <= shift_left(to_signed(-16, 64), q) then
      return to_signed(0, 32);
    end if;
    if z >= shift_left(to_signed(16, 64), q) then
      return resize(one_q, 32);
    end if;

    offset := z + shift_left(to_signed(16, 64), q);
    idx_fp := shift_left(offset, 4);

    k := to_integer(shift_right(idx_fp, q));
    if k > 511 then k := 511; end if;
    if k <   0 then k :=   0; end if;

    frac := idx_fp - shift_left(to_signed(k, 64), q);

    lo := to_signed(SIG_ROM(k),     64);
    hi := to_signed(SIG_ROM(k + 1), 64);

    prod   := (hi - lo) * frac;
    tmp    := shift_right(prod, q);
    interp := lo + tmp(63 downto 0);

    if q <= 30 then
      sh := 30 - q;
      if sh > 0 then
        bias := shift_left(to_signed(1, 64), sh - 1);
        r    := shift_right(interp + bias, sh);
      else
        r := interp;
      end if;
    else
      r := shift_left(interp, q - 30);
    end if;

    if r < 0 then return to_signed(0, 32); end if;
    if r > one_q then return resize(one_q, 32); end if;
    return resize(r, 32);
  end function;

  -- -----------------------------------------------------------------------
  -- scale_mul: round(acc * mult / 2^shift), saturated to int32.
  -- Round half toward +infinity. Mirrors fx_scale_mul.
  -- -----------------------------------------------------------------------
  function scale_mul(acc : signed; mult : signed; shift : integer) return signed is
    variable a64  : s64;
    variable m32  : signed(31 downto 0);
    variable p96  : s96;
    variable bias : s96;
    variable r96  : s96;
  begin
    a64 := resize(acc,  64);
    m32 := resize(mult, 32);
    p96 := a64 * m32;

    if shift = 0 then
      r96 := p96;
    else
      bias := shift_left(to_signed(1, 96), shift - 1);
      r96  := shift_right(p96 + bias, shift);
    end if;

    if r96 > to_signed(2147483647, 96) then
      return to_signed(2147483647, 32);
    elsif r96 < to_signed(-2147483647 - 1, 96) then
      return to_signed(-2147483647 - 1, 32);
    else
      return resize(r96, 32);
    end if;
  end function;

end package body;
