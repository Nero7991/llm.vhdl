-- rtl/embed.vhd
-- Token embedding lookup.
--
-- ROM-loads mem/weights/embed.mem (VOCAB*DIM int16 mantissas) plus the
-- per-row embed_mult.mem/embed_shift.mem scale (the SAME per-row
-- mult/shift-quantised format every other weight matrix in this project
-- uses -- dumped by dump_weight_matrix/dump_all_weights, consumed by
-- lm_head.vhd's dot products via scale_mul).
--
-- That per-row (mant, mult, shift) format is NOT directly a block-fp value
-- (mult/shift approximate an arbitrary real row-scale, not a power of two),
-- so it cannot be fed straight into layer.vhd's x_mant/x_exp port, which
-- expects value[j] = mant[j] * 2^(-exp). This unit bridges the two: it
-- reconstructs row `token` to real precision (mant[j] * mult * 2^-shift --
-- the same VHDL-`real` float-glue convention layer.vhd itself uses for its
-- own BFP-from-real requantise steps, e.g. the attention-output / residual
-- BFP encode blocks) and then re-BFP-encodes that reconstructed row to a
-- single power-of-two exponent, using the identical max-search loop
-- layer.vhd uses everywhere it does a "BFP encode from real". This matches
-- forward_fx's raw (float) embedding-lookup row being re-quantised by
-- fx_bfp_from_float the moment it reaches the first matmul_fx/rmsnorm_fx
-- call -- see ref/run_fx.c's dump_embed_prompt / fx_embed.txt, which applies
-- write_bfp_section (== fx_bfp_from_float) directly to the same float row.
--
-- Block-fp convention: value[j] = mant[j] * 2^(-exp).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.embed_rom_pkg.all;   -- EMBED_MULT / EMBED_SHFT (small, kept as constants)
use work.rom_init_pkg.all;    -- init_rom_hex (file-loaded mantissa BRAM)

entity embed is
  generic(
    DIM        : integer := 64;
    VOCAB      : integer := 512;
    WEIGHT_DIR : string  := "../mem/weights/";  -- retained for port compat
    -- Directory holding the file-init mantissa ROM (embed_mant.mem).  Default
    -- resolves from sim/ for both GHDL and the OOC Vivado runs.
    ROM_DIR    : string  := "../mem/rom/"
  );
  port(
    clk    : in  std_logic;
    -- Optional compute-enable.  Defaults to '1' so existing instantiations
    -- (tb_embed, seq_ctrl) are unchanged and embed recomputes every clock as
    -- before.  The autoregressive engine drives it low outside the one-shot
    -- embed window so this always-on process does not re-run its heavy body on
    -- every one of the ~270k cycles/position of the shared-MAC datapath (a
    -- ~600x GHDL-sim speedup; purely a simulation-cost gate, output held while
    -- disabled).
    en     : in  std_logic := '1';
    token  : in  integer;
    done   : out std_logic;
    x_mant : out std_logic_vector(DIM*16-1 downto 0);
    x_exp  : out integer
  );
end entity;

architecture rtl of embed is

  type state_t is (S_IDLE, S_MAX_P1, S_MAX_P2, S_MAX, S_EXP,
                   S_EMIT_P1, S_EMIT_P2, S_EMIT);

  -- Weight ROMs:
  --   EMBED_MANT : int16 mantissas (VOCAB*DIM) -- now FILE-INITIALIZED BRAM,
  --     loaded from mem/rom/embed_mant.mem via rom_init_pkg.init_rom_hex (was a
  --     32768-literal constant aggregate that Vivado constant-folded).  The small
  --     per-row scale tables stay compile-time constants in work.embed_rom_pkg:
  --   EMBED_MULT : integer_vector(0 to VOCAB-1)      (int32 per-row mult)
  --   EMBED_SHFT : integer_vector(0 to VOCAB-1)      (per-row shift, 0..31)
  constant EMBED_N : natural := VOCAB*DIM;
  signal EMBED_MANT : integer_vector(0 to EMBED_N-1) :=
    init_rom_hex(ROM_DIR & "embed_mant.mem", EMBED_N, 16);
  attribute rom_style : string;
  attribute rom_style of EMBED_MANT : signal is "block";

  -- BLOCK-RAM ROM READ (matmul_rt pattern).  The 32768-entry EMBED_MANT was
  -- read COMBINATIONALLY (EMBED_MANT(tok*DIM+idx) in both the S_MAX and S_EMIT
  -- sweeps), forcing Vivado to bake the whole table into distributed LUT
  -- (~39% CLB LUT).  It is now read through a TWO-stage synchronous pipeline so
  -- Vivado infers Block RAM:
  --   mant_addr (fabric address register, +1 counter)
  --      -> mant_data  (the BRAM's OWN output register)
  --      -> w_pipe     (a plain pipeline register that feeds the multiplier)
  -- The extra w_pipe stage is essential: if mant_data fed the DSP multiplier
  -- directly, Vivado would absorb it as the DSP input register, leaving the ROM
  -- with only a registered ADDRESS -- which cannot pack into the BRAM address
  -- port once it carries an init/reset (Synth 8-6040), dropping the ROM to LUT.
  -- With w_pipe present, mant_data stays as the BRAM output register (as
  -- matmul_rt's rom_data does), the address lives in fabric (init OK), and w_pipe
  -- is the register the DSP absorbs.  Each DIM-long sweep over base=tok*DIM
  -- streams addresses base..base+DIM-1; the address runs TWO elements ahead of
  -- the consumer (the read pipeline depth), primed per sweep (S_MAX_P1/P2 before
  -- the max search, S_EMIT_P1/P2 before the emit).  The small VOCAB-deep
  -- EMBED_MULT/EMBED_SHFT tables stay combinational (read once in S_IDLE).  All
  -- widths/rounding/saturation are unchanged, so x_mant/x_exp stay bit-for-bit
  -- identical (tb_embed max_dev=1).
  signal mant_addr : integer range 0 to VOCAB*DIM-1 := 0;  -- fabric addr register
  signal mant_data : signed(15 downto 0) := (others => '0');  -- BRAM output register
  signal w_pipe    : signed(15 downto 0) := (others => '0');  -- DSP input pipeline reg

begin

  -- Block-ROM inference template: registered address -> registered ROM output
  -- (mant_data) -> pipeline register (w_pipe).  mant_data is the BRAM output
  -- register; w_pipe decouples the DSP so mant_data is not absorbed.
  rom_rd: process(clk)
  begin
    if rising_edge(clk) then
      mant_data <= to_signed(EMBED_MANT(mant_addr), 16);
      w_pipe    <= mant_data;
    end if;
  end process;

  -- AREA-EFFICIENT (element-SEQUENTIAL) implementation.
  -- The former version unrolled both DIM-wide loops (max-search and emit) into
  -- one combinational clock -> 2*DIM = 128 parallel 64x64 multipliers.  An FSM
  -- now time-multiplexes ONE multiplier over the elements:
  --   S_MAX  : max_prod = max_j |prod[j]|, one prod = mant[j]*mult per cycle.
  --   S_EXP  : one-shot exponent search (shift-only, no multiply).
  --   S_EMIT : requantise + saturate one element per cycle (shared multiplier).
  -- `done` now pulses (multi-cycle) after the emit sweep completes; consumers
  -- drive a fresh `token` and wait for `done` (engine/seq_ctrl updated to do so).
  --
  -- Trigger: a RISING EDGE of `en` starts one reconstruction of the current
  -- `token`; the FSM then runs to completion regardless of the later `en` level
  -- (so a one-cycle enable pulse is sufficient), holding outputs while idle.
  -- This preserves the sim-cost gate intent (the heavy body no longer runs every
  -- cycle) while working both for the engine (pulsed `en`) and seq_ctrl.
  --
  -- Bit-exact integer reimplementation of the former `real` datapath.
  -- The reconstructed value is v[j] = prod[j] * 2^(-shift), where
  --   prod[j] = EMBED_MANT[tok*DIM+j] * EMBED_MULT[tok]   (|prod| < 2^47)
  --   shift   = EMBED_SHFT[tok]   (0..31)
  -- All widths/rounding/saturation are identical to the unrolled version, so
  -- x_mant/x_exp are bit-for-bit the same (tb_embed max_dev=1).
  process(clk)
    variable state   : state_t := S_IDLE;
    variable en_prev : std_logic := '0';
    variable idx     : integer range 0 to DIM := 0;
    variable tok     : integer := 0;
    variable base    : integer range 0 to VOCAB*DIM-1 := 0;  -- tok*DIM (ROM row base)
    variable mant    : signed(63 downto 0);
    variable mult    : signed(63 downto 0);
    variable shft    : integer;
    variable prod    : signed(63 downto 0);
    variable absprod : signed(63 downto 0);
    variable max_prod: signed(63 downto 0);
    variable e       : integer;
    variable net     : integer;
    variable sh      : integer;
    variable r       : signed(63 downto 0);
    variable m       : signed(63 downto 0);
    variable found   : boolean;
    variable zero_row: boolean;
  begin
    if rising_edge(clk) then
      done <= '0';
      case state is

        -- Idle: a rising edge of `en` (with a stable `token`) launches a run.
        when S_IDLE =>
          if en = '1' and en_prev = '0' then
            tok      := token;
            base     := token*DIM;
            mult     := to_signed(EMBED_MULT(tok), 64);
            shft     := EMBED_SHFT(tok);
            max_prod := (others => '0');
            idx      := 0;
            mant_addr <= token*DIM;     -- issue read for element (base+0)
            state    := S_MAX_P1;
          end if;

        -- Two-deep read-pipeline prime for the max sweep: the address runs two
        -- elements ahead of the consumer (mant_data then w_pipe latency), so
        -- w_pipe holds base+0 as we enter S_MAX.
        when S_MAX_P1 =>
          mant_addr <= base + 1;
          state     := S_MAX_P2;
        when S_MAX_P2 =>
          mant_addr <= base + 2;
          idx       := 0;
          state     := S_MAX;

        -- max_prod = max_j |prod[j]|, one element per cycle (shared multiplier).
        when S_MAX =>
          mant    := resize(w_pipe, 64);         -- block-RAM data for base+idx
          prod    := resize(mant * mult, 64);
          absprod := abs(prod);
          if absprod > max_prod then max_prod := absprod; end if;
          if mant_addr < VOCAB*DIM-1 then
            mant_addr <= mant_addr + 1;
          end if;
          if idx = DIM-1 then
            idx   := 0;
            state := S_EXP;
          else
            idx := idx + 1;
          end if;

        -- One-shot: choose the block exponent (shift-only search, no multiply).
        when S_EXP =>
          if max_prod = 0 then
            -- All-zero row: matches the original all-zero branch.
            x_exp    <= 14;
            zero_row := true;
            net      := 0;
          else
            -- Largest e in [-30,30] with round(max_prod*2^(e-shift)) <= 32767
            -- (round-half-up; monotone-decreasing in e, so first hit wins).
            e     := -30;
            found := false;
            for ti in 0 to 60 loop
              e   := 30 - ti;
              net := e - shft;
              if net >= 0 then
                r := to_signed(32768, 64);   -- positive shift of nonzero max > 32767
              else
                sh := -net;
                r  := shift_right(max_prod + (to_signed(1, 64) sll (sh-1)), sh);
              end if;
              if r <= 32767 then found := true; exit; end if;
            end loop;
            assert found report "embed: no valid BFP exponent found" severity failure;
            x_exp    <= e;
            net      := e - shft;
            zero_row := false;
          end if;
          idx       := 0;
          mant_addr <= base;          -- re-prime the ROM read for the emit sweep
          state     := S_EMIT_P1;

        -- Two-deep read-pipeline prime for the emit sweep (same as S_MAX_P1/P2).
        when S_EMIT_P1 =>
          mant_addr <= base + 1;
          state     := S_EMIT_P2;
        when S_EMIT_P2 =>
          mant_addr <= base + 2;
          idx       := 0;
          state     := S_EMIT;

        -- Requantise + saturate one element per cycle (shared multiplier).
        when S_EMIT =>
          if mant_addr < VOCAB*DIM-1 then
            mant_addr <= mant_addr + 1;
          end if;
          if zero_row then
            x_mant((idx+1)*16-1 downto idx*16) <= (others => '0');
          else
            mant := resize(w_pipe, 64);          -- block-RAM data for base+idx
            prod := resize(mant * mult, 64);
            if net >= 0 then
              m := shift_left(prod, net);           -- exact
            else
              sh := -net;
              if prod >= 0 then
                m := shift_right(prod + (to_signed(1, 64) sll (sh-1)), sh);
              else
                m := -( shift_right((-prod) + (to_signed(1, 64) sll (sh-1)), sh) );
              end if;
            end if;
            -- saturate to [-32768, 32767]
            if    m >  32767 then m := to_signed( 32767, 64);
            elsif m < -32768 then m := to_signed(-32768, 64);
            end if;
            x_mant((idx+1)*16-1 downto idx*16) <= std_logic_vector(resize(m, 16));
          end if;
          if idx = DIM-1 then
            idx   := 0;
            done  <= '1';
            state := S_IDLE;
          else
            idx := idx + 1;
          end if;

      end case;
      en_prev := en;
    end if;
  end process;

end architecture;
