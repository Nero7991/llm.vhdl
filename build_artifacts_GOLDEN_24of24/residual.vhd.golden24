-- rtl/residual.vhd
-- Sequential block-float residual add:  o = a + b  (both BFP).
--
-- Block-fp convention: value[j] = mant[j] * 2^(-exp).  This is the exact
-- element-SEQUENTIAL re-implementation of engine_shared.vhd's former inline
-- `residual_add` procedure (which unrolled two DIM-wide loops into one
-- combinational clock -> ~128 parallel 64-bit barrel shifters + 64 int64 adds,
-- i.e. the bulk of engine_shared's top-level LUT/CARRY8).  A tiny FSM now
-- time-multiplexes ONE datapath over the elements:
--   S_ACC    : sums(j) = (a<<(E-a_exp)) + (b<<(E-b_exp)); track max|sums|, 1/cyc.
--   (transition): p = msb_pos64(max); sh = p-14; o_exp = E - sh.
--   S_PACK_A : recompute s(j) (== S_ACC) and REGISTER it.
--   S_PACK_B : requantise s(j) by sh, saturate, write o_mant(j).
-- Every width / shift / rounding / saturation is IDENTICAL to the procedure,
-- so o_mant/o_exp are bit-for-bit the same (tb_engine_shared stays 24/24).
--
-- WHY S_PACK IS SPLIT ACROSS TWO REGISTERED STATES (2026-07-27)
--   The whole-vector debug taps proved on silicon that BOTH of this unit's input
--   vectors (x_mant_cur and wo_reg) are bit-exact, its input exponents/max/shift
--   are right (the output block exponent and element 0 both match sim), yet a
--   couple of bits elsewhere in the 1024-bit output are wrong -- deterministically
--   within a build, and DIFFERENTLY in each build.  That is the signature of a
--   combinational cone that is genuinely too slow while static timing says it
--   passes, and it is the SAME failure mode already documented and fixed in
--   rmsnorm.vhd: "the router segments timing at each DSP boundary and under-counts
--   the true reg->reg delay, so it 'meets' timing but the real path exceeds the
--   clock period".  S_PACK used to do, in ONE clock: two 64-bit VARIABLE barrel
--   shifts, a 64-bit add, scale_mul's 64x32 MULTIPLY, a 96-bit variable shift and
--   the saturate -- the longest single-cycle cone left in the engine, and the only
--   unit that had not been split.  Fix, mirroring the rmsnorm one:
--     (a) register s between the shift/add and the requantise, and
--     (b) drop the multiply entirely -- scale_mul(s, 1, sh) is EXACTLY a
--         round-half-up arithmetic right shift, so this is bit-identical while
--         removing a DSP (and its STA blind spot) from the path.
--   Cost is +1 cycle per element in S_PACK = +64 cycles per residual call; over a
--   full 24-token run (240 residual calls) that is ~+15k of ~19.6M cycles, +0.08%.
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
  type state_t is (S_IDLE, S_ACC, S_PACK_A, S_PACK_B);

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
    variable r64   : signed(63 downto 0);
    -- s registered between S_PACK_A and S_PACK_B (breaks the long cone)
    variable s_reg : signed(63 downto 0) := (others => '0');
    -- requantise intermediates, 96-bit exactly as scale_mul used to be
    variable p96   : signed(95 downto 0);
    variable bias96: signed(95 downto 0);
    variable r96   : signed(95 downto 0);
    variable q     : signed(63 downto 0);
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

          -- One element/cycle: s(j) = a<<da + b<<db; accumulate max|s|.  The
          -- per-element sums are NOT stored (no `sums` array -> avoids the
          -- uninitialized distributed-RAM Vivado infers under engine congestion);
          -- S_PACK re-computes s(j) from the still-valid a/b ports (bit-identical).
          when S_ACC =>
            av := resize(signed(a_mant((idx+1)*16-1 downto idx*16)), 64);
            bv := resize(signed(b_mant((idx+1)*16-1 downto idx*16)), 64);
            s  := shift_left(av, da) + shift_left(bv, db);
            if s < 0 then ab := -s; else ab := s; end if;
            if ab > mx then mx := ab; end if;
            if idx = N-1 then
              -- choose block exponent from the final max (round to Q14 headroom)
              p     := msb_pos64(mx);
              sh    := p - 14;           -- no clamp (allow left-shift)
              o_exp <= E - sh;
              idx   := 0;
              state := S_PACK_A;
            else
              idx := idx + 1;
            end if;

          -- Stage A: re-compute s(idx) (== S_ACC) and REGISTER it.  Nothing else
          -- happens this cycle, so the shift/add cone ends at a flop.
          when S_PACK_A =>
            av    := resize(signed(a_mant((idx+1)*16-1 downto idx*16)), 64);
            bv    := resize(signed(b_mant((idx+1)*16-1 downto idx*16)), 64);
            s_reg := shift_left(av, da) + shift_left(bv, db);
            state := S_PACK_B;

          -- Stage B: requantise the REGISTERED s by sh and saturate to int16.
          -- sh >= 0 is exactly the old scale_mul(s, 1, sh): a round-half-up
          -- arithmetic right shift in 96 bits, clamped to int32, then to int16.
          -- Clamping to int32 first is redundant once we clamp to int16 (the
          -- int16 range is inside the int32 range and both clamps are monotone),
          -- so the int16 clamp alone is bit-identical.  Saturation compares and
          -- the final write stay on signed VECTORS -- never route a value through
          -- a VHDL integer and back with to_signed(<integer>,N), which Vivado has
          -- been observed to sign-drop in this design (see attention_ml history).
          when S_PACK_B =>
            if sh >= 0 then
              p96 := resize(s_reg, 96);
              if sh = 0 then
                r96 := p96;
              else
                bias96 := shift_left(to_signed(1, 96), sh - 1);
                r96    := shift_right(p96 + bias96, sh);
              end if;
              if    r96 > to_signed( 32767, 96) then
                o_mant((idx+1)*16-1 downto idx*16) <= std_logic_vector(to_signed( 32767, 16));
              elsif r96 < to_signed(-32768, 96) then
                o_mant((idx+1)*16-1 downto idx*16) <= std_logic_vector(to_signed(-32768, 16));
              else
                o_mant((idx+1)*16-1 downto idx*16) <= std_logic_vector(resize(r96, 16));
              end if;
            else
              r64 := shift_left(s_reg, -sh);
              if    r64 > to_signed( 32767, 64) then
                o_mant((idx+1)*16-1 downto idx*16) <= std_logic_vector(to_signed( 32767, 16));
              elsif r64 < to_signed(-32768, 64) then
                o_mant((idx+1)*16-1 downto idx*16) <= std_logic_vector(to_signed(-32768, 16));
              else
                o_mant((idx+1)*16-1 downto idx*16) <= std_logic_vector(resize(r64, 16));
              end if;
            end if;
            if idx = N-1 then
              idx   := 0;
              done  <= '1';
              state := S_IDLE;
            else
              idx   := idx + 1;
              state := S_PACK_A;
            end if;

        end case;
      end if;
    end if;
  end process;
end architecture;
