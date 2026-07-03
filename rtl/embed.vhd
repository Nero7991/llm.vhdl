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
use ieee.math_real.all;
use std.textio.all;

entity embed is
  generic(
    DIM        : integer := 64;
    VOCAB      : integer := 512;
    WEIGHT_DIR : string  := "../mem/weights/"
  );
  port(
    clk    : in  std_logic;
    token  : in  integer;
    done   : out std_logic;
    x_mant : out std_logic_vector(DIM*16-1 downto 0);
    x_exp  : out integer
  );
end entity;

architecture rtl of embed is

  type intarr is array(natural range <>) of integer;

  -- File loading helper (impure: reads file at elaboration), mirrors
  -- layer.vhd's load_ints.
  impure function load_ints(fn : string; n : integer) return intarr is
    file   fh : text open read_mode is fn;
    variable L : line; variable v : integer;
    variable r : intarr(0 to n-1);
  begin
    for i in 0 to n-1 loop
      readline(fh, L); read(L, v); r(i) := v;
    end loop;
    return r;
  end function;

  constant EMBED_MANT : intarr(0 to VOCAB*DIM-1) := load_ints(WEIGHT_DIR & "embed.mem",       VOCAB*DIM);
  constant EMBED_MULT : intarr(0 to VOCAB-1)      := load_ints(WEIGHT_DIR & "embed_mult.mem",  VOCAB);
  constant EMBED_SHFT : intarr(0 to VOCAB-1)      := load_ints(WEIGHT_DIR & "embed_shift.mem", VOCAB);

begin

  -- Behavioral, single-cycle, no start/rst handshake (matches the brief's
  -- port list): `token` is sampled every rising edge and the reconstructed
  -- BFP row for that token is registered on x_mant/x_exp with `done`
  -- pulsing high the same cycle -- a sequencer just drives `token` and reads
  -- the result one clock later (or holds `token` steady and samples once
  -- `done`='1'; with no start pulse, `done` is simply "output valid",
  -- continuously true after the first clock edge).
  process(clk)
    type realarr is array(natural range <>) of real;
    variable row_r  : realarr(0 to DIM-1);
    variable bfp_mx : real;
    variable bfp_e  : integer;
    variable bfp_sc : real;
    variable bfp_rv : integer;
    variable tok    : integer;
  begin
    if rising_edge(clk) then
      tok := token;

      -- Reconstruct row to real precision: value[j] = mant[j] * mult * 2^-shift.
      bfp_mx := 0.0;
      for j in 0 to DIM-1 loop
        row_r(j) := real(EMBED_MANT(tok*DIM + j)) * real(EMBED_MULT(tok)) *
                    (2.0 ** (-EMBED_SHFT(tok)));
        if abs(row_r(j)) > bfp_mx then bfp_mx := abs(row_r(j)); end if;
      end loop;

      -- Re-BFP-encode to a single power-of-two exponent (mirrors
      -- fx_bfp_from_float / layer.vhd's bfp_mx/bfp_e search loop).
      if bfp_mx = 0.0 then
        x_exp <= 14;
        for j in 0 to DIM-1 loop
          x_mant((j+1)*16-1 downto j*16) <= (others => '0');
        end loop;
      else
        bfp_e := -30;
        for ti in 0 to 60 loop
          bfp_e := 30 - ti;
          if bfp_e >= 0 then bfp_sc := bfp_mx * real(2**bfp_e);
          else               bfp_sc := bfp_mx / real(2**(-bfp_e)); end if;
          -- Compare in the real domain, NOT integer(round(bfp_sc)) <= 32767:
          -- the first iteration (bfp_e=30) can produce bfp_sc up to
          -- bfp_mx*2^30, which overflows a 32-bit integer for any bfp_mx
          -- greater than ~2.0 and silently wraps to a huge negative number
          -- (GHDL does not range-check integer(real) here), spuriously
          -- satisfying "<= 32767" on the first iteration and saturating
          -- every output element. Same latent bug found and fixed in
          -- layer.vhd's three identical search loops (see its comments).
          if bfp_sc < 32767.5 then exit; end if;
        end loop;
        x_exp <= bfp_e;
        for j in 0 to DIM-1 loop
          if bfp_e >= 0 then bfp_sc := row_r(j) * real(2**bfp_e);
          else               bfp_sc := row_r(j) / real(2**(-bfp_e)); end if;
          bfp_rv := integer(round(bfp_sc));
          if    bfp_rv >  32767 then bfp_rv :=  32767;
          elsif bfp_rv < -32768 then bfp_rv := -32768;
          end if;
          x_mant((j+1)*16-1 downto j*16) <= std_logic_vector(to_signed(bfp_rv, 16));
        end loop;
      end if;

      done <= '1';
    end if;
  end process;

end architecture;
