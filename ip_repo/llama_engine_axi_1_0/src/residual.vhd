-- rtl/residual.vhd
-- Sequential block-float residual add:  o = a + b  (both BFP).
--
-- Block-fp convention: value[j] = mant[j] * 2^(-exp).  This is the exact
-- element-SEQUENTIAL re-implementation of engine_shared.vhd's former inline
-- `residual_add` procedure (which unrolled two DIM-wide loops into one
-- combinational clock -> ~128 parallel 64-bit barrel shifters + 64 int64 adds,
-- i.e. the bulk of engine_shared's top-level LUT/CARRY8).  A tiny FSM now
-- time-multiplexes ONE datapath over the elements:
--   S_ACC  : sums(j) = (a<<(E-a_exp)) + (b<<(E-b_exp)); track max|sums|, 1/cyc.
--   (transition): p = msb_pos64(max); sh = p-14; o_exp = E - sh.
--   S_PACK : o_mant(j) = saturate(requantise(sums(j), sh)), one element/cycle.
-- Every width / shift / rounding / saturation is IDENTICAL to the procedure,
-- so o_mant/o_exp are bit-for-bit the same (tb_engine_shared stays 24/24).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.fixed_pkg.all;   -- scale_mul

entity residual is
  generic(N : positive := 64);
  port(
    clk    : in  std_logic;
    rst    : in  std_logic;
    start  : in  std_logic;
    a_mant : in  std_logic_vector(N*16-1 downto 0);
    a_exp  : in  integer;
    b_mant : in  std_logic_vector(N*16-1 downto 0);
    b_exp  : in  integer;
    done   : out std_logic;
    o_mant : out std_logic_vector(N*16-1 downto 0);
    o_exp  : out integer
  );
end entity;

architecture rtl of residual is
  type s64arr is array(natural range <>) of signed(63 downto 0);
  type state_t is (S_IDLE, S_ACC, S_PACK);

  -- Highest set-bit index of a nonnegative signed value (0 for 0); mirrors
  -- engine_shared.msb_pos64 exactly (scan bits 0..len-2 of the 64-bit max).
  function msb_pos64(v : signed) return integer is
    variable p : integer := 0;
  begin
    for i in 0 to v'length-2 loop
      if v(i) = '1' then p := i; end if;
    end loop;
    return p;
  end function;
begin
  process(clk)
    variable state : state_t := S_IDLE;
    variable idx   : integer range 0 to N := 0;
    variable E     : integer := 0;
    variable da    : integer := 0;
    variable db    : integer := 0;
    variable sh    : integer := 0;
    variable av    : signed(63 downto 0);
    variable bv    : signed(63 downto 0);
    variable s     : signed(63 downto 0);
    variable ab    : signed(63 downto 0);
    variable mx    : signed(63 downto 0);
    variable p     : integer;
    variable r32   : signed(31 downto 0);
    variable r64   : signed(63 downto 0);
    variable sat   : integer;
    variable sums  : s64arr(0 to N-1);
  begin
    if rising_edge(clk) then
      done <= '0';
      if rst = '1' then
        state  := S_IDLE;
        idx    := 0;
        o_mant <= (others => '0');
        o_exp  <= 0;
      else
        case state is

          when S_IDLE =>
            if start = '1' then
              if a_exp > b_exp then E := a_exp; else E := b_exp; end if;
              da    := E - a_exp;
              db    := E - b_exp;
              mx    := (others => '0');
              idx   := 0;
              state := S_ACC;
            end if;

          -- One element/cycle: sums(j) = a<<da + b<<db; accumulate max|sums|.
          when S_ACC =>
            av := resize(signed(a_mant((idx+1)*16-1 downto idx*16)), 64);
            bv := resize(signed(b_mant((idx+1)*16-1 downto idx*16)), 64);
            s  := shift_left(av, da) + shift_left(bv, db);
            sums(idx) := s;
            if s < 0 then ab := -s; else ab := s; end if;
            if ab > mx then mx := ab; end if;
            if idx = N-1 then
              -- choose block exponent from the final max (round to Q14 headroom)
              p     := msb_pos64(mx);
              sh    := p - 14;           -- no clamp (allow left-shift)
              o_exp <= E - sh;
              idx   := 0;
              state := S_PACK;
            else
              idx := idx + 1;
            end if;

          -- One element/cycle: requantise sums(j) by sh, saturate to int16.
          when S_PACK =>
            if sh >= 0 then
              r32 := scale_mul(sums(idx), to_signed(1, 32), sh);
              if    r32 >  32767 then sat :=  32767;
              elsif r32 < -32768 then sat := -32768;
              else                    sat := to_integer(r32);
              end if;
            else
              r64 := shift_left(sums(idx), -sh);
              if    r64 >  32767 then sat :=  32767;
              elsif r64 < -32768 then sat := -32768;
              else                    sat := to_integer(r64);
              end if;
            end if;
            o_mant((idx+1)*16-1 downto idx*16) <= std_logic_vector(to_signed(sat, 16));
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
