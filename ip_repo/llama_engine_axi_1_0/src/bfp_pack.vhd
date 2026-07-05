-- rtl/bfp_pack.vhd
-- Sequential Q(q) int32 -> block-float int16 pack.
--
-- Exact element-SEQUENTIAL re-implementation of engine_shared.vhd's former
-- inline `L_HBPACK` block (which unrolled two HIDDEN-wide loops into one
-- combinational clock -> HIDDEN parallel scale_mul + saturate).  A tiny FSM
-- time-multiplexes ONE datapath over the elements:
--   S_MAX  : max_abs = max_i |in_q[i]|, one element/cycle.
--   (transition): p = msb_pos(max_abs); shift_o = max(0, p-14); o_exp = q - shift_o.
--   S_PACK : o_mant[i] = saturate(scale_mul(in_q[i], 1, shift_o)), one/cycle.
-- Every width / shift / rounding / saturation is IDENTICAL to the inline block,
-- so o_mant/o_exp are bit-for-bit the same (tb_engine_shared stays 24/24).
--
-- in_q holds N signed Q(q) values, 32 bits each (e.g. swiglu's out_q).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;    -- msb_pos
use work.fixed_pkg.all;   -- scale_mul

entity bfp_pack is
  generic(N : positive := 172; Q : integer := 12);
  port(
    clk    : in  std_logic;
    rst    : in  std_logic;
    start  : in  std_logic;
    in_q   : in  std_logic_vector(N*32-1 downto 0);
    done   : out std_logic;
    o_mant : out std_logic_vector(N*16-1 downto 0);
    o_exp  : out integer
  );
end entity;

architecture rtl of bfp_pack is
  type state_t is (S_IDLE, S_MAX, S_PACK);
begin
  process(clk)
    variable state   : state_t := S_IDLE;
    variable idx     : integer range 0 to N := 0;
    variable hbq     : integer;
    variable av      : integer;
    variable max_abs : integer;
    variable p_msb   : integer;
    variable shift_o : integer := 0;
    variable r32     : signed(31 downto 0);
    variable sat     : integer;
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
              max_abs := 0;
              idx     := 0;
              state   := S_MAX;
            end if;

          -- One element/cycle: track max |in_q[i]|.
          when S_MAX =>
            hbq := to_integer(signed(in_q((idx+1)*32-1 downto idx*32)));
            av  := hbq; if av < 0 then av := -av; end if;
            if av > max_abs then max_abs := av; end if;
            if idx = N-1 then
              p_msb   := msb_pos(max_abs);
              shift_o := p_msb - 14; if shift_o < 0 then shift_o := 0; end if;
              o_exp   <= Q - shift_o;
              idx     := 0;
              state   := S_PACK;
            else
              idx := idx + 1;
            end if;

          -- One element/cycle: requantise + saturate to int16.
          when S_PACK =>
            hbq := to_integer(signed(in_q((idx+1)*32-1 downto idx*32)));
            r32 := scale_mul(to_signed(hbq, 64), to_signed(1, 32), shift_o);
            if    r32 >  32767 then sat :=  32767;
            elsif r32 < -32768 then sat := -32768;
            else                    sat := to_integer(r32);
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
