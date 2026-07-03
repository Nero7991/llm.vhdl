-- rtl/lm_head.vhd
-- Tied classifier: for each of the VOCAB=512 rows, logit[v] =
-- scale_mul(dot(x, embed_row_v), mult_v, shift_v). Reuses the SAME
-- embed.mem/embed_mult.mem/embed_shift.mem ROMs as embed.vhd (tied
-- embedding: lm_head weight == token_embedding_table, confirmed in
-- ref/run_fx.c's apply_i16_fakequant/dump_all_weights), and the exact
-- int16*int16 -> int64 accumulate -> scale_mul(acc,mult,shift) -> int32
-- pattern every matmul in layer.vhd uses (mirrors matmul_fx in
-- ref/run_fx.c).
--
-- NOTE on x_exp: unlike layer.vhd's matmuls, lm_head does NOT divide the
-- result by 2^(-x_exp) the way matmul_fx's xout[i] does (xout[i] =
-- fx_scale_mul(acc,mult,shift) * inv_xe). x_exp is the SAME common factor
-- for all 512 output rows here, so omitting that final multiply doesn't
-- change the relative order of the logits -- and argmax (the only thing
-- sample_argmax/sampler.vhd cares about) is exactly preserved. x_exp is
-- still accepted on the port for interface symmetry with embed.vhd's
-- output (and to leave room for a future numerically-scaled logits port);
-- it is intentionally unused in the current output convention.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.fixed_pkg.all;

entity lm_head is
  generic(
    DIM        : integer := 64;
    VOCAB      : integer := 512;
    WEIGHT_DIR : string  := "../mem/weights/"
  );
  port(
    clk    : in  std_logic;
    rst    : in  std_logic;
    start  : in  std_logic;
    x_mant : in  std_logic_vector(DIM*16-1 downto 0);
    x_exp  : in  integer;
    done   : out std_logic;
    logits : out std_logic_vector(VOCAB*32-1 downto 0)
  );
end entity;

architecture rtl of lm_head is

  type intarr is array(natural range <>) of integer;

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

  process(clk)
    variable x_v    : intarr(0 to DIM-1);
    variable acc64  : signed(63 downto 0);
    variable w16    : signed(15 downto 0);
    variable x16    : signed(15 downto 0);
    variable prod32 : signed(31 downto 0);
    variable res32  : signed(31 downto 0);
    variable x_e    : integer;
  begin
    if rising_edge(clk) then
      done <= '0';
      if rst = '1' then
        logits <= (others => '0');
      elsif start = '1' then
        x_e := x_exp;  -- accepted for interface symmetry; see header note (unused)

        for j in 0 to DIM-1 loop
          x_v(j) := to_integer(signed(x_mant((j+1)*16-1 downto j*16)));
        end loop;

        for v in 0 to VOCAB-1 loop
          acc64 := (others => '0');
          for j in 0 to DIM-1 loop
            w16    := to_signed(EMBED_MANT(v*DIM + j), 16);
            x16    := to_signed(x_v(j), 16);
            prod32 := w16 * x16;
            acc64  := acc64 + resize(prod32, 64);
          end loop;
          res32 := scale_mul(acc64, to_signed(EMBED_MULT(v), 32), EMBED_SHFT(v));
          logits((v+1)*32-1 downto v*32) <= std_logic_vector(res32);
        end loop;

        done <= '1';
      end if;
    end if;
  end process;

end architecture;
