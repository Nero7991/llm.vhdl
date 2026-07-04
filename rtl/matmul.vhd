-- rtl/matmul.vhd -- Reusable, time-multiplexed block-float matrix-vector block.
--
-- Computes, bit-exactly like the C oracle's matmul_fx (and layer.vhd steps 2 /
-- 2b), the product of an OUT_ROWS x IN_COLS int16 weight matrix W (row-major,
-- per-row scale MULT[i]/SHFT[i]) with a block-float input activation
-- (x_mant[0..IN_COLS-1] int16, shared exponent x_exp), producing a block-float
-- output (o_mant[0..OUT_ROWS-1] int16, shared exponent o_exp):
--
--   for i in 0..OUT_ROWS-1:
--     acc64      = sum_j W[i][j] * x_mant[j]          (int16*int16 -> int64)
--     result[i]  = to_integer(scale_mul(acc64, MULT[i], SHFT[i]))
--     max_abs    = max(max_abs, |result[i]|)
--   p_msb   = msb_pos(max_abs)
--   shift_o = p_msb - 14 ; if CLAMP_NONNEG and shift_o<0 then shift_o = 0
--   o_exp   = x_exp - shift_o
--   for i:  o_mant[i] = saturate( shift_o>=0 ? scale_mul(result[i],1,shift_o)
--                                            : result[i] << (-shift_o) )
--
-- A SINGLE mac_array (N=IN_COLS, P=1, WW=16, XW=16, AW=48) is time-multiplexed
-- across all OUT_ROWS rows by the FSM below (NOT unrolled) -- this is the shared
-- MAC datapath the full PL engine reuses. The weight matrix, its per-row MULT
-- and SHFT are passed as VHDL-2008 unconstrained-array generics so the same
-- entity serves WQ/WK/WV/WO/W1/W2/W3.
--
-- mac_array publishes its final `acc` in the SAME delta as `done`, so we sample
-- `acc` on the cycle mac_done='1' (matvec_engine.vhd does the same).
--
-- Synthesizable: no `real`, no TEXTIO. (integer ports synthesize fine, as
-- proven by mac_array/matvec_engine.)

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;      -- msb_pos, clog2
use work.fixed_pkg.all;     -- scale_mul
use work.weights_pkg.all;   -- intarr type

entity matmul is
  generic(
    OUT_ROWS     : positive := 64;
    IN_COLS      : positive := 64;
    CLAMP_NONNEG : boolean  := true;
    -- Weight matrix (row-major, OUT_ROWS*IN_COLS int16 mantissas) and per-row
    -- requant scale.  Unconstrained -> pass the specific matrix's slice.
    WMANT        : intarr;
    WMULT        : intarr;   -- OUT_ROWS entries
    WSHFT        : intarr    -- OUT_ROWS entries
  );
  port(
    clk    : in  std_logic;
    rst    : in  std_logic;
    start  : in  std_logic;
    x_mant : in  std_logic_vector(IN_COLS*16-1 downto 0);
    x_exp  : in  integer;
    done   : out std_logic;
    o_mant : out std_logic_vector(OUT_ROWS*16-1 downto 0);
    o_exp  : out integer
  );
end entity;

architecture rtl of matmul is
  -- 'low offsets so a passed slice (e.g. WQ(0 to 4095)) indexes correctly
  -- regardless of the actual's declared index base.
  constant WM_LOW : integer := WMANT'low;
  constant MU_LOW : integer := WMULT'low;
  constant SH_LOW : integer := WSHFT'low;

  -- Latched inputs (stable across a pass)
  signal xin    : std_logic_vector(IN_COLS*16-1 downto 0) := (others=>'0');
  signal xexp_l : integer := 0;

  -- Per-row int32 requant results + running max magnitude
  type i32arr is array(0 to OUT_ROWS-1) of integer;
  signal result_v : i32arr := (others=>0);
  signal max_abs  : integer := 0;

  -- FSM
  type state_t is (S_IDLE, S_START, S_WAIT, S_PACK);
  signal state   : state_t := S_IDLE;
  signal cur_row : integer range 0 to OUT_ROWS-1 := 0;

  -- mac_array interface
  signal mac_start, mac_done : std_logic := '0';
  signal mac_acc : std_logic_vector(47 downto 0);
  signal w_row   : std_logic_vector(IN_COLS*16-1 downto 0);
begin
  -- Drive the mac_array weight row combinationally from the selected ROM row.
  gpack_w: for j in 0 to IN_COLS-1 generate
    w_row((j+1)*16-1 downto j*16) <=
      std_logic_vector(to_signed(WMANT(WM_LOW + cur_row*IN_COLS + j), 16));
  end generate;

  mac: entity work.mac_array
    generic map(N=>IN_COLS, P=>1, WW=>16, XW=>16, AW=>48)
    port map(clk=>clk, rst=>rst, start=>mac_start,
             x_vec=>xin, w_row=>w_row, done=>mac_done, acc=>mac_acc);

  process(clk)
    variable res32 : signed(31 downto 0);
    variable res_i : integer;
    variable av    : integer;
    variable p_msb : integer;
    variable sh    : integer;
    variable r32   : signed(31 downto 0);
    variable r64   : signed(63 downto 0);
    variable sat   : integer;
  begin
    if rising_edge(clk) then
      done      <= '0';
      mac_start <= '0';
      if rst = '1' then
        state   <= S_IDLE;
        cur_row <= 0;
        max_abs <= 0;
        o_exp   <= 0;
        o_mant  <= (others=>'0');
      else
        case state is
          when S_IDLE =>
            if start = '1' then
              xin     <= x_mant;      -- latch activations for the whole pass
              xexp_l  <= x_exp;
              cur_row <= 0;
              max_abs <= 0;
              state   <= S_START;
            end if;

          when S_START =>
            -- w_row settled for cur_row; kick the shared mac (1-cycle pulse).
            mac_start <= '1';
            state     <= S_WAIT;

          when S_WAIT =>
            -- Sample acc in the SAME cycle mac_done pulses, then requant.
            if mac_done = '1' then
              res32 := scale_mul(signed(mac_acc),
                                 to_signed(WMULT(MU_LOW + cur_row), 32),
                                 WSHFT(SH_LOW + cur_row));
              res_i := to_integer(res32);
              result_v(cur_row) <= res_i;
              av := res_i; if av < 0 then av := -av; end if;
              if av > max_abs then max_abs <= av; end if;
              if cur_row = OUT_ROWS-1 then
                state <= S_PACK;
              else
                cur_row <= cur_row + 1;
                state   <= S_START;
              end if;
            end if;

          when S_PACK =>
            -- Global BFP re-pack across all rows (uses the max_abs updated last
            -- delta; the final row's contribution is already folded in).
            p_msb := msb_pos(max_abs);
            sh    := p_msb - 14;
            if CLAMP_NONNEG and sh < 0 then sh := 0; end if;
            o_exp <= xexp_l - sh;
            for i in 0 to OUT_ROWS-1 loop
              if sh >= 0 then
                r32 := scale_mul(to_signed(result_v(i), 64), to_signed(1, 32), sh);
                if    r32 >  32767 then sat :=  32767;
                elsif r32 < -32768 then sat := -32768;
                else                    sat := to_integer(r32);
                end if;
              else
                r64 := shift_left(to_signed(result_v(i), 64), -sh);
                if    r64 >  32767 then sat :=  32767;
                elsif r64 < -32768 then sat := -32768;
                else                    sat := to_integer(r64);
                end if;
              end if;
              o_mant((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(sat, 16));
            end loop;
            done  <= '1';
            state <= S_IDLE;
        end case;
      end if;
    end if;
  end process;
end architecture;
