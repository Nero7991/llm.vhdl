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
--
-- AREA-EFFICIENT (element-SEQUENTIAL) implementation.
-- Instead of unrolling all N elements into one combinational clock (which infers
-- N parallel copies of the sigmoid+two-multiply chain -> 360 DSP / 100%), an FSM
-- time-multiplexes ONE datapath over the elements, computing one element per
-- cycle (S_CALC) and pulsing `done` (multi-cycle) after the last element.  Each
-- element is independent (no cross-element state; the BFP pack is done by the
-- consumer), so every width / rounding / shift is IDENTICAL to the unrolled
-- version -> out_q is bit-exact.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use work.fixed_pkg.all;
use work.util_pkg.all;   -- clog2

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
    -- Legacy wide parallel result bus.  Still driven so the older layer_fsm/
    -- layer_ar/layer.vhd instantiations (and tb_swiglu) keep working, but
    -- engine_shared leaves it => open so synth PRUNES the N-way output demux.
    out_q    : out std_logic_vector(N*32-1 downto 0);
    -- Sequential write port to an external vec_mem BRAM (one element/cycle,
    -- registered so waddr/wdata are aligned).  This replaces the wide out_q
    -- demux in the FFN datapath (engine_shared wires it to vec_mem).
    o_we     : out std_logic;
    o_waddr  : out std_logic_vector(clog2(N)-1 downto 0);
    o_wdata  : out std_logic_vector(31 downto 0)
  );
end entity swiglu;

architecture rtl of swiglu is
  -- S_CALC used to do EVERYTHING for one element in a single clock: two 64-bit
  -- VARIABLE barrel shifts, sigmoid_q (ROM lookup + its own 64x64 multiply), the
  -- 32x32 silu multiply and the 32x32 output multiply -- THREE cascaded DSP
  -- multiplies in one combinational cone.  That is the exact failure mode already
  -- documented and fixed in rmsnorm.vhd ("the router segments timing at each DSP
  -- boundary and under-counts the true reg->reg delay, so it 'meets' timing but
  -- the real path exceeds the clock period -> wrong result on silicon"), and the
  -- board showed its consequence: with W1/W3 reading bit-exact, bfp_pack's max
  -- scan over the values swiglu wrote saw ~2^30 where sim sees <=2^14, so
  -- shift_o came out 16 too large (exp -4 vs +12) and every mantissa was crushed
  -- to 0.  Split into four registered stages, ONE multiply per state -- the same
  -- rule rmsnorm's pipelined rsqrt follows.  Bit-identical (same widths, same
  -- rounding, same order); costs 3 extra cycles per element = ~+0.3% on a run.
  type state_t is (S_IDLE, S_CALC_A, S_CALC_B, S_CALC_C, S_CALC_D);
begin
  process(clk)
    variable state    : state_t := S_IDLE;
    variable idx      : integer range 0 to N := 0;
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
      o_we <= '0';
      if rst = '1' then
        state  := S_IDLE;
        idx    := 0;
        out_q <= (others => '0');
        o_waddr <= (others => '0');
        o_wdata <= (others => '0');
      else
        case state is

          -- Wait for start, then iterate the elements one per cycle.
          when S_IDLE =>
            if start = '1' then
              idx   := 0;
              state := S_CALC_A;
            end if;

          -- Stage A: BFP mantissa -> Qq for both operands (barrel shifts only).
          when S_CALC_A =>
            mant_raw := signed(hb_mant((idx+1)*16-1 downto idx*16));
            mant64   := resize(mant_raw, 64);
            sh       := Q - hb_exp;
            if sh >= 0 then
              v_q := resize(shift_left(mant64, sh), 32);
            else
              bias64 := shift_left(to_signed(1, 64), (-sh) - 1);
              v_q    := resize(shift_right(mant64 + bias64, -sh), 32);
            end if;

            mant_raw := signed(hb2_mant((idx+1)*16-1 downto idx*16));
            mant64   := resize(mant_raw, 64);
            sh       := Q - hb2_exp;
            if sh >= 0 then
              h2_q := resize(shift_left(mant64, sh), 32);
            else
              bias64 := shift_left(to_signed(1, 64), (-sh) - 1);
              h2_q   := resize(shift_right(mant64 + bias64, -sh), 32);
            end if;
            state := S_CALC_B;

          -- Stage B: sig = sigmoid_q(v_q, Q).  sigmoid_q contains its own 64x64
          -- interpolation multiply, so it gets a state to itself.
          when S_CALC_B =>
            sig   := sigmoid_q(v_q, Q);
            state := S_CALC_C;

          -- Stage C: silu = (v_q * sig) >> Q   (multiply 1 of 2)
          when S_CALC_C =>
            prod1  := v_q * sig;
            silu32 := resize(shift_right(prod1, Q), 32);
            state  := S_CALC_D;

          -- Stage D: out = (silu * h2_q) >> Q  (multiply 2 of 2), then commit.
          when S_CALC_D =>
            prod2 := silu32 * h2_q;
            out_v := resize(shift_right(prod2, Q), 32);

            out_q((idx+1)*32-1 downto idx*32) <= std_logic_vector(out_v);

            -- Sequential BRAM write (registered): element idx is committed to
            -- vec_mem one cycle later; waddr/wdata stay paired.  The master FSM
            -- waits for `done` before starting bfp_pack, so the final element's
            -- delayed write lands well before any read.
            o_we    <= '1';
            o_waddr <= std_logic_vector(to_unsigned(idx, o_waddr'length));
            o_wdata <= std_logic_vector(out_v);

            if idx = N-1 then
              idx   := 0;
              done  <= '1';
              state := S_IDLE;
            else
              idx   := idx + 1;
              state := S_CALC_A;
            end if;

        end case;
      end if;
    end if;
  end process;
end architecture rtl;
