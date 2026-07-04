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
use work.fixed_pkg.all;
use work.lmhead_rom_pkg.all;

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
  type state_t is (S_IDLE, S_MAC);

  -- Tied-classifier weight ROMs are provided as literal constants by
  -- lmhead_rom_pkg (generated from mem/weights/embed{,_mult,_shift}.mem,
  -- bit-identical to the former std.textio load_ints() init).
  -- EMBED_MANT/EMBED_MULT/EMBED_SHFT come from the package.
  --
  -- AREA-EFFICIENT (element-SEQUENTIAL) implementation.
  -- Instead of unrolling all VOCAB*DIM = 512*64 = 32768 multiply-accumulates
  -- into one combinational clock (which infers thousands of parallel
  -- multipliers), an FSM streams the classifier through ONE shared 16x16
  -- multiplier: one MAC per cycle (S_MAC), walking j=0..DIM-1 within each row v,
  -- and on the last column applies the SAME scale_mul(acc, mult_v, shift_v) and
  -- writes logit[v].  The int64 accumulation order (j = 0..DIM-1) is identical to
  -- the unrolled loop, so every logit is bit-exact (tb_lm_head max_dev=0).
  -- `done` pulses (multi-cycle) after the last row.

begin

  process(clk)
    variable state  : state_t := S_IDLE;
    variable v_idx  : integer range 0 to VOCAB := 0;
    variable j_idx  : integer range 0 to DIM   := 0;
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
        state  := S_IDLE;
        v_idx  := 0;
        j_idx  := 0;
        logits <= (others => '0');
      else
        case state is

          -- Latch the activation row, reset the accumulator, start streaming.
          when S_IDLE =>
            if start = '1' then
              x_e := x_exp;  -- accepted for interface symmetry (unused, see header)
              for j in 0 to DIM-1 loop
                x_v(j) := to_integer(signed(x_mant((j+1)*16-1 downto j*16)));
              end loop;
              v_idx := 0;
              j_idx := 0;
              acc64 := (others => '0');
              state := S_MAC;
            end if;

          -- One MAC per cycle over the shared multiplier: acc += w*x. On the
          -- last column of a row, scale_mul -> logit[v], then advance to the
          -- next row (accumulator re-zeroed) or finish.
          when S_MAC =>
            w16    := to_signed(EMBED_MANT(v_idx*DIM + j_idx), 16);
            x16    := to_signed(x_v(j_idx), 16);
            prod32 := w16 * x16;
            acc64  := acc64 + resize(prod32, 64);

            if j_idx = DIM-1 then
              res32 := scale_mul(acc64, to_signed(EMBED_MULT(v_idx), 32),
                                 EMBED_SHFT(v_idx));
              logits((v_idx+1)*32-1 downto v_idx*32) <= std_logic_vector(res32);
              j_idx := 0;
              acc64 := (others => '0');
              if v_idx = VOCAB-1 then
                v_idx := 0;
                done  <= '1';
                state := S_IDLE;
              else
                v_idx := v_idx + 1;
              end if;
            else
              j_idx := j_idx + 1;
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture;
