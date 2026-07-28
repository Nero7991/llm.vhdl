-- rtl/bfp_pack.vhd
-- Sequential Q(q) int32 -> block-float int16 pack.
--
-- Exact element-SEQUENTIAL re-implementation of engine_shared.vhd's former
-- inline `L_HBPACK` block (which unrolled two HIDDEN-wide loops into one
-- combinational clock -> HIDDEN parallel scale_mul + saturate).  A tiny FSM
-- time-multiplexes ONE datapath over the elements:
--   S_MAX  : max_abs = max_i |in[i]|, one element/cycle.
--   (transition): p = msb_pos(max_abs); shift_o = max(0, p-14); o_exp = q - shift_o.
--   S_PACK : o_mant[i] = saturate(scale_mul(in[i], 1, shift_o)), one/cycle.
-- Every width / shift / rounding / saturation is IDENTICAL to the inline block,
-- so o_mant/o_exp are bit-for-bit the same (tb_engine_shared stays 24/24).
--
-- INPUT SOURCE CHANGE (LUT reduction): the N Q(q) values are no longer received
-- as one wide `in_q` bus (which forced two N-way 32-bit input MUXes here).  They
-- now live in an external synchronous BRAM (rtl/vec_mem.vhd) written by swiglu.
-- This unit drives a read-ahead pointer `o_raddr` and consumes the registered
-- data `i_rdata` one cycle later (the same 1-cycle BRAM read-ahead bubble used by
-- attention_ml's KV scans): at pointer value R>=1, i_rdata holds element R-1.
-- Both the S_MAX and the S_PACK pass sweep all N elements, so the BRAM is read
-- twice; semantics (find max over ALL elements, THEN repack) are unchanged.
--
-- SIGNED-VECTOR ONLY (2026-07-27) -- this unit used to do
--     hbq := to_integer(signed(i_rdata));  av := hbq; if av < 0 then av := -av;
--     r32 := scale_mul(to_signed(hbq, 64), to_signed(1, 32), shift_o);
-- i.e. it routed the element through a VHDL INTEGER and back.  Vivado has been
-- observed IN THIS DESIGN to DROP THE SIGN across that round-trip (see the
-- attention_ml history and the project memory): GHDL evaluates it correctly, so
-- every simulation passes, and only the netlist/silicon is wrong.  Here a dropped
-- sign makes |element| astronomically large, so the S_MAX scan over-scales
-- shift_o and S_PACK crushes every mantissa to ~0.  That is exactly what the
-- board measured once the units upstream had been made bit-exact: bfp_pack out
-- read exp -4 with element 0 = 0, where sim gives exp +12 / -335, while its W1
-- and W3 inputs both read bit-exact.
-- Fix: keep the element as a SIGNED VECTOR throughout (abs, running max, msb
-- scan, requantise, saturate) and never call to_signed(<integer>, N).  The
-- multiply-by-one is also gone -- scale_mul(x,1,sh) is just a round-half-up
-- arithmetic right shift -- which removes a 64x32 DSP cone from the path for
-- free.  Bit-identical: tb_engine_shared stays 24/24.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;    -- msb_pos, clog2
use work.fixed_pkg.all;   -- scale_mul

entity bfp_pack is
  generic(N : positive := 172; Q : integer := 12);
  port(
    clk     : in  std_logic;
    rst     : in  std_logic;
    start   : in  std_logic;
    -- Read-ahead BRAM read port (to vec_mem): present o_raddr, get i_rdata next
    -- cycle.  Replaces the old wide `in_q` input bus + its two N-way muxes.
    o_raddr : out std_logic_vector(clog2(N)-1 downto 0);
    i_rdata : in  std_logic_vector(31 downto 0);
    done    : out std_logic;
    o_mant  : out std_logic_vector(N*16-1 downto 0);
    o_exp   : out integer
  );
end entity;

architecture rtl of bfp_pack is
  type state_t is (S_IDLE, S_MAX, S_PACK);
  signal state : state_t := S_IDLE;
  -- Read-ahead pointer.  o_raddr is COMBINATIONAL from rptr (clamped so the
  -- trailing bubble read at rptr=N stays in range).  At pointer value R the data
  -- for element R-1 is on i_rdata (issued when the pointer was R-1).
  signal rptr    : integer range 0 to N := 0;
  -- Running max of |element|, held as an UNSIGNED VECTOR, never a VHDL integer.
  signal max_abs : unsigned(31 downto 0) := (others => '0');
  signal shift_o : integer range 0 to 63 := 0;  -- S_MAX->S_PACK, always >= 0

  -- Highest set-bit index of an unsigned vector (0 for 0).  Replaces
  -- util_pkg.msb_pos(integer), which forced the data through an integer.
  function msb_pos_u(u : unsigned) return integer is
    variable r : integer := 0;
  begin
    for i in 0 to u'length-1 loop
      if u(i) = '1' then r := i; end if;
    end loop;
    return r;
  end function;
begin
  -- Combinational read address off the read-ahead pointer.
  o_raddr <= std_logic_vector(to_unsigned(rptr, o_raddr'length)) when rptr <= N-1
             else std_logic_vector(to_unsigned(N-1, o_raddr'length));

  process(clk)
    variable p     : integer;   -- element consumed this cycle (rptr-1)
    variable hbq_s : signed(31 downto 0);   -- the element, as a SIGNED VECTOR
    variable av_u  : unsigned(31 downto 0); -- |element|
    variable mx_u  : unsigned(31 downto 0); -- final max over all N elements
    variable p_msb : integer;
    variable sh    : integer;
    -- requantise intermediates (96-bit, exactly as scale_mul used to be)
    variable p96    : signed(95 downto 0);
    variable bias96 : signed(95 downto 0);
    variable r96    : signed(95 downto 0);
  begin
    if rising_edge(clk) then
      done <= '0';
      if rst = '1' then
        state   <= S_IDLE;
        rptr    <= 0;
        max_abs <= (others => '0');
        shift_o <= 0;
        o_mant  <= (others => '0');
        o_exp   <= 0;
      else
        case state is

          when S_IDLE =>
            if start = '1' then
              max_abs <= (others => '0');
              rptr    <= 0;
              state   <= S_MAX;
            end if;

          -- Read-ahead max scan: at rptr>=1 fold |element rptr-1| (on i_rdata)
          -- into max_abs; at rptr=N the last element (N-1) is consumed, so
          -- compute the shift and move to S_PACK (re-priming the pointer to 0).
          when S_MAX =>
            if rptr >= 1 then
              hbq_s := signed(i_rdata);
              if hbq_s(31) = '1' then av_u := unsigned(-hbq_s);
              else                    av_u := unsigned( hbq_s);
              end if;
            else
              av_u := (others => '0');
            end if;
            if rptr = N then
              -- max_abs signal already holds the running max of elements 0..N-2;
              -- fold in element N-1 (av_u) locally to get the true max over all N.
              mx_u := max_abs; if av_u > mx_u then mx_u := av_u; end if;
              p_msb := msb_pos_u(mx_u);
              sh := p_msb - 14; if sh < 0 then sh := 0; end if;
              shift_o <= sh;
              o_exp   <= Q - sh;
              rptr    <= 0;
              state   <= S_PACK;
            else
              if av_u > max_abs then max_abs <= av_u; end if;
              rptr <= rptr + 1;
            end if;

          -- Read-ahead repack: at rptr>=1 saturate+requantise element rptr-1 (on
          -- i_rdata) into o_mant[rptr-1]; at rptr=N the last element is written
          -- and the pack is done.
          when S_PACK =>
            if rptr >= 1 then
              p     := rptr - 1;
              hbq_s := signed(i_rdata);
              -- scale_mul(x, 1, sh) is exactly a round-half-up arithmetic right
              -- shift, so do it directly: no 64x32 multiply-by-one, and no value
              -- routed through a VHDL integer.  The old int32 clamp is redundant
              -- once we clamp to int16 (both clamps are monotone and the int16
              -- range is inside the int32 range), so this is bit-identical.
              p96 := resize(hbq_s, 96);
              if shift_o = 0 then
                r96 := p96;
              else
                bias96 := shift_left(to_signed(1, 96), shift_o - 1);
                r96    := shift_right(p96 + bias96, shift_o);
              end if;
              if    r96 > to_signed( 32767, 96) then
                o_mant((p+1)*16-1 downto p*16) <= std_logic_vector(to_signed( 32767, 16));
              elsif r96 < to_signed(-32768, 96) then
                o_mant((p+1)*16-1 downto p*16) <= std_logic_vector(to_signed(-32768, 16));
              else
                o_mant((p+1)*16-1 downto p*16) <= std_logic_vector(resize(r96, 16));
              end if;
            end if;
            if rptr = N then
              rptr  <= 0;
              done  <= '1';
              state <= S_IDLE;
            else
              rptr <= rptr + 1;
            end if;

        end case;
      end if;
    end if;
  end process;
end architecture;
