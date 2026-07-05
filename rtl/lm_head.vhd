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
use work.lmhead_rom_pkg.all;  -- EMBED_MULT / EMBED_SHFT (small, kept as constants)
use work.rom_init_pkg.all;    -- init_rom_hex (file-loaded mantissa BRAM)

entity lm_head is
  generic(
    DIM        : integer := 64;
    VOCAB      : integer := 512;
    WEIGHT_DIR : string  := "../mem/weights/";
    -- Directory holding the file-init mantissa ROM (embed_mant.mem).  Default
    -- resolves from sim/ for both GHDL and the OOC Vivado runs.
    ROM_DIR    : string  := "../mem/rom/"
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
  type state_t is (S_IDLE, S_P1, S_P2, S_MAC);

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
  --
  -- BLOCK-RAM ROM READ (matmul_rt pattern).  The 32768-entry EMBED_MANT was
  -- read COMBINATIONALLY (EMBED_MANT(v*DIM+j) inside the FSM), forcing Vivado to
  -- bake the whole table into distributed LUT (~28% CLB LUT).  It is now read
  -- through a TWO-stage synchronous pipeline so Vivado infers Block RAM:
  --   mant_addr (fabric address register, +1 counter)
  --      -> mant_data  (the BRAM's OWN output register)
  --      -> w_pipe     (a plain pipeline register that feeds the multiplier)
  -- The extra w_pipe stage is essential: if mant_data fed the DSP multiplier
  -- directly, Vivado would absorb it as the DSP input register, leaving the ROM
  -- with only a registered ADDRESS -- which cannot pack into the BRAM address
  -- port once it carries an init/reset (Synth 8-6040), dropping the ROM back to
  -- LUT.  With w_pipe present, mant_data stays as the BRAM output register (as
  -- matmul_rt's rom_data does), the address register lives in fabric (init OK),
  -- and w_pipe is the register the DSP absorbs.  Because (v*DIM+j) is
  -- monotonically increasing by 1 across the whole 0..32767 stream, the address
  -- is a simple +1 counter running TWO elements ahead of the consumer (the read
  -- pipeline depth), primed in S_P1/S_P2.  The small VOCAB-deep EMBED_MULT/
  -- EMBED_SHFT tables stay combinational (read once per row).  Arithmetic is
  -- unchanged, so every logit stays bit-exact.

  -- EMBED_MANT is now FILE-INITIALIZED BRAM (loaded from mem/rom/embed_mant.mem
  -- via rom_init_pkg.init_rom_hex), replacing the 32768-literal constant aggregate
  -- from lmhead_rom_pkg that Vivado constant-folded.  The small per-row EMBED_MULT/
  -- EMBED_SHFT tables stay compile-time constants in work.lmhead_rom_pkg.
  constant EMBED_N : natural := VOCAB*DIM;
  signal EMBED_MANT : integer_vector(0 to EMBED_N-1) :=
    init_rom_hex(ROM_DIR & "embed_mant.mem", EMBED_N, 16);
  attribute rom_style : string;
  attribute rom_style of EMBED_MANT : signal is "block";

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

  process(clk)
    variable state  : state_t := S_IDLE;
    variable v_idx  : integer range 0 to VOCAB := 0;
    variable j_idx  : integer range 0 to DIM   := 0;
    variable x_v    : intarr(0 to DIM-1);
    variable acc64  : signed(63 downto 0);
    variable x16    : signed(15 downto 0);
    variable prod32 : signed(31 downto 0);
    variable res32  : signed(31 downto 0);
    variable x_e    : integer;
  begin
    if rising_edge(clk) then
      done <= '0';
      if rst = '1' then
        state     := S_IDLE;
        v_idx     := 0;
        j_idx     := 0;
        mant_addr <= 0;
        logits <= (others => '0');
      else
        case state is

          -- Latch the activation row, reset the accumulator, issue the read for
          -- flat element 0, then run the two ROM-latency prime cycles.
          when S_IDLE =>
            if start = '1' then
              x_e := x_exp;  -- accepted for interface symmetry (unused, see header)
              for j in 0 to DIM-1 loop
                x_v(j) := to_integer(signed(x_mant((j+1)*16-1 downto j*16)));
              end loop;
              v_idx     := 0;
              j_idx     := 0;
              acc64     := (others => '0');
              mant_addr <= 0;        -- flat element 0
              state     := S_P1;
            end if;

          -- Two-deep read-pipeline prime: the address runs two elements ahead of
          -- the consumer (mant_data then w_pipe latency).  w_pipe holds flat
          -- element 0 as we enter S_MAC.
          when S_P1 =>
            mant_addr <= 1;
            state     := S_P2;
          when S_P2 =>
            mant_addr <= 2;
            state     := S_MAC;

          -- One MAC per cycle over the shared multiplier: acc += w*x, where w is
          -- the block-RAM data (via w_pipe) for the current element.  On the last
          -- column of a row, scale_mul -> logit[v], then advance to the next row
          -- (accumulator re-zeroed) or finish.  mant_addr is bumped one element
          -- per cycle (it holds flat_idx+2 while consuming flat_idx); guarded so
          -- it never exceeds the ROM's last index.
          when S_MAC =>
            x16    := to_signed(x_v(j_idx), 16);
            prod32 := w_pipe * x16;
            acc64  := acc64 + resize(prod32, 64);

            if mant_addr < VOCAB*DIM-1 then
              mant_addr <= mant_addr + 1;
            end if;

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
