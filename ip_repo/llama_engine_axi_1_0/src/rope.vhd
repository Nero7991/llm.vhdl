-- rtl/rope.vhd
-- RoPE (Rotary Position Embedding) rotation unit.
-- Matches rope_fx() in ref/run_fx.c bit-for-bit on the integer kernel.
--
-- Block-fp convention: value[j] = mant[j] * 2^(-exp).
-- Rotation preserves the block exponent: the twiddle >>15 keeps mantissas
-- at the same scale, so qo_exp = q_exp and ko_exp = k_exp.
--
-- Algorithm (mirrors rope_fx for each pair i, i+1):
--   twiddle_idx = POS * (HEAD/2) + (i mod HEAD) / 2
--   fcr = COS_ROM[twiddle_idx]   (Q1.15)
--   fci = SIN_ROM[twiddle_idx]   (Q1.15)
--   r0  = (q0*fcr - q1*fci + (1<<14)) >> 15
--   r1  = (q0*fci + q1*fcr + (1<<14)) >> 15
--
-- Twiddle ROMs: mem/luts/rope_cos.mem and rope_sin.mem.
-- Layout: _fx_cos_tbl[pos*(head_size/2) + i/2], where i is i_outer mod head_size.
-- ROM has 512 * (HEAD/2) entries (HEAD=8 -> 2048 entries).
--
-- AREA-EFFICIENT (element-SEQUENTIAL) implementation.
-- Instead of unrolling all DIM/2 + KVDIM/2 twiddle rotations into one
-- combinational clock (which infers 4 multipliers per pair * 48 pairs = 192
-- DSP), an FSM time-multiplexes ONE per-pair datapath: it rotates one Q pair
-- per cycle (S_Q), then one K pair per cycle (S_K), pulsing `done` (multi-cycle)
-- after the last K pair.  Every product / shift / rounding / saturation is
-- IDENTICAL to the unrolled version, so qo_mant/ko_mant are bit-exact.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use work.rope_rom_pkg.all;

entity rope is
  generic(
    DIM   : positive := 64;
    HEAD  : positive := 8;
    KVDIM : positive := 32
  );
  port(
    clk     : in  std_logic;
    rst     : in  std_logic;
    start   : in  std_logic;
    pos     : in  integer;
    q_mant  : in  std_logic_vector(DIM*16-1 downto 0);
    q_exp   : in  integer;
    k_mant  : in  std_logic_vector(KVDIM*16-1 downto 0);
    k_exp   : in  integer;
    done    : out std_logic;
    qo_mant : out std_logic_vector(DIM*16-1 downto 0);
    qo_exp  : out integer;
    ko_mant : out std_logic_vector(KVDIM*16-1 downto 0);
    ko_exp  : out integer
  );
end entity;

architecture rtl of rope is

  -- ROM depth: 512 positions * (HEAD/2) half-frequencies.
  -- For HEAD=8 this is 2048 entries matching the .mem file sizes.
  constant HALF      : integer := HEAD / 2;
  constant ROM_DEPTH : integer := 512 * HALF;

  -- Twiddle ROMs are provided as literal constants by rope_rom_pkg
  -- (generated from mem/luts/rope_{cos,sin}.mem, bit-identical to the former
  -- std.textio load_rom() init). COS_ROM/SIN_ROM come from the package.

  type state_t is (S_IDLE, S_Q, S_K);

begin

  process(clk)
    variable state        : state_t := S_IDLE;
    variable idx          : integer range 0 to DIM := 0;
    variable pos_l        : integer := 0;
    variable q0_v, q1_v   : signed(15 downto 0);
    variable k0_v, k1_v   : signed(15 downto 0);
    variable fcr_v, fci_v : signed(15 downto 0);
    variable acc_v        : signed(63 downto 0);
    variable r_v          : signed(63 downto 0);
    variable rom_idx      : integer;
    constant BIAS         : signed(63 downto 0) := to_signed(16384, 64);  -- 1 << 14
  begin
    if rising_edge(clk) then
      done <= '0';
      if rst = '1' then
        state   := S_IDLE;
        idx     := 0;
        qo_exp  <= 0;
        ko_exp  <= 0;
        qo_mant <= (others => '0');
        ko_mant <= (others => '0');
      else
        case state is

          -- Wait for start; latch pos and preserve exponents (twiddle >>15
          -- keeps the same scale).
          when S_IDLE =>
            if start = '1' then
              pos_l  := pos;
              qo_exp <= q_exp;
              ko_exp <= k_exp;
              idx    := 0;
              state  := S_Q;
            end if;

          -- ----------------------------------------------------------------
          -- Rotate Q: DIM/2 pairs, one pair per cycle (idx = pair index).
          -- ----------------------------------------------------------------
          when S_Q =>
            q0_v    := signed(q_mant((2*idx+1)*16-1 downto (2*idx)*16));
            q1_v    := signed(q_mant((2*idx+2)*16-1 downto (2*idx+1)*16));
            -- twiddle index: POS*(HEAD/2) + (i_raw mod HEAD)/2
            -- i_raw = 2*idx; (2*idx mod HEAD)/2 = idx mod (HEAD/2)
            rom_idx := pos_l * HALF + ((2*idx) mod HEAD) / 2;
            fcr_v   := to_signed(COS_ROM(rom_idx), 16);
            fci_v   := to_signed(SIN_ROM(rom_idx), 16);

            -- r0 = (q0*fcr - q1*fci + (1<<14)) >> 15
            acc_v := resize(q0_v, 32) * resize(fcr_v, 32)
                   - resize(q1_v, 32) * resize(fci_v, 32)
                   + BIAS;
            r_v   := shift_right(acc_v, 15);
            -- Saturate to int16 (should not trigger for well-formed inputs)
            if    r_v > 32767  then
              qo_mant((2*idx+1)*16-1 downto (2*idx)*16) <=
                std_logic_vector(to_signed( 32767, 16));
            elsif r_v < -32768 then
              qo_mant((2*idx+1)*16-1 downto (2*idx)*16) <=
                std_logic_vector(to_signed(-32768, 16));
            else
              qo_mant((2*idx+1)*16-1 downto (2*idx)*16) <=
                std_logic_vector(resize(r_v, 16));
            end if;

            -- r1 = (q0*fci + q1*fcr + (1<<14)) >> 15
            acc_v := resize(q0_v, 32) * resize(fci_v, 32)
                   + resize(q1_v, 32) * resize(fcr_v, 32)
                   + BIAS;
            r_v   := shift_right(acc_v, 15);
            if    r_v > 32767  then
              qo_mant((2*idx+2)*16-1 downto (2*idx+1)*16) <=
                std_logic_vector(to_signed( 32767, 16));
            elsif r_v < -32768 then
              qo_mant((2*idx+2)*16-1 downto (2*idx+1)*16) <=
                std_logic_vector(to_signed(-32768, 16));
            else
              qo_mant((2*idx+2)*16-1 downto (2*idx+1)*16) <=
                std_logic_vector(resize(r_v, 16));
            end if;

            if idx = DIM/2-1 then
              idx   := 0;
              state := S_K;
            else
              idx := idx + 1;
            end if;

          -- ----------------------------------------------------------------
          -- Rotate K: KVDIM/2 pairs, one pair per cycle.
          -- Same twiddle ROM, same index formula.
          -- ----------------------------------------------------------------
          when S_K =>
            k0_v    := signed(k_mant((2*idx+1)*16-1 downto (2*idx)*16));
            k1_v    := signed(k_mant((2*idx+2)*16-1 downto (2*idx+1)*16));
            rom_idx := pos_l * HALF + ((2*idx) mod HEAD) / 2;
            fcr_v   := to_signed(COS_ROM(rom_idx), 16);
            fci_v   := to_signed(SIN_ROM(rom_idx), 16);

            acc_v := resize(k0_v, 32) * resize(fcr_v, 32)
                   - resize(k1_v, 32) * resize(fci_v, 32)
                   + BIAS;
            r_v   := shift_right(acc_v, 15);
            if    r_v > 32767  then
              ko_mant((2*idx+1)*16-1 downto (2*idx)*16) <=
                std_logic_vector(to_signed( 32767, 16));
            elsif r_v < -32768 then
              ko_mant((2*idx+1)*16-1 downto (2*idx)*16) <=
                std_logic_vector(to_signed(-32768, 16));
            else
              ko_mant((2*idx+1)*16-1 downto (2*idx)*16) <=
                std_logic_vector(resize(r_v, 16));
            end if;

            acc_v := resize(k0_v, 32) * resize(fci_v, 32)
                   + resize(k1_v, 32) * resize(fcr_v, 32)
                   + BIAS;
            r_v   := shift_right(acc_v, 15);
            if    r_v > 32767  then
              ko_mant((2*idx+2)*16-1 downto (2*idx+1)*16) <=
                std_logic_vector(to_signed( 32767, 16));
            elsif r_v < -32768 then
              ko_mant((2*idx+2)*16-1 downto (2*idx+1)*16) <=
                std_logic_vector(to_signed(-32768, 16));
            else
              ko_mant((2*idx+2)*16-1 downto (2*idx+1)*16) <=
                std_logic_vector(resize(r_v, 16));
            end if;

            if idx = KVDIM/2-1 then
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
