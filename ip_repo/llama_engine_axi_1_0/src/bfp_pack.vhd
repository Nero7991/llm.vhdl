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
  signal max_abs : integer := 0;   -- persists across S_MAX (running max)
  signal shift_o : integer := 0;   -- computed at S_MAX->S_PACK, used in S_PACK
begin
  -- Combinational read address off the read-ahead pointer.
  o_raddr <= std_logic_vector(to_unsigned(rptr, o_raddr'length)) when rptr <= N-1
             else std_logic_vector(to_unsigned(N-1, o_raddr'length));

  process(clk)
    variable p     : integer;   -- element consumed this cycle (rptr-1)
    variable hbq   : integer;
    variable av    : integer;
    variable mx    : integer;   -- final max over all N elements
    variable p_msb : integer;
    variable r32   : signed(31 downto 0);
    variable sat   : integer;
    variable sh    : integer;
  begin
    if rising_edge(clk) then
      done <= '0';
      if rst = '1' then
        state   <= S_IDLE;
        rptr    <= 0;
        max_abs <= 0;
        shift_o <= 0;
        o_mant  <= (others => '0');
        o_exp   <= 0;
      else
        case state is

          when S_IDLE =>
            if start = '1' then
              max_abs <= 0;
              rptr    <= 0;
              state   <= S_MAX;
            end if;

          -- Read-ahead max scan: at rptr>=1 fold |element rptr-1| (on i_rdata)
          -- into max_abs; at rptr=N the last element (N-1) is consumed, so
          -- compute the shift and move to S_PACK (re-priming the pointer to 0).
          when S_MAX =>
            if rptr >= 1 then
              hbq := to_integer(signed(i_rdata));
              av  := hbq; if av < 0 then av := -av; end if;
            else
              av := 0;
            end if;
            if rptr = N then
              -- max_abs signal already holds the running max of elements 0..N-2;
              -- fold in element N-1 (av) locally to get the true max over all N.
              mx := max_abs; if av > mx then mx := av; end if;
              p_msb := msb_pos(mx);
              sh := p_msb - 14; if sh < 0 then sh := 0; end if;
              shift_o <= sh;
              o_exp   <= Q - sh;
              rptr    <= 0;
              state   <= S_PACK;
            else
              if av > max_abs then max_abs <= av; end if;
              rptr <= rptr + 1;
            end if;

          -- Read-ahead repack: at rptr>=1 saturate+requantise element rptr-1 (on
          -- i_rdata) into o_mant[rptr-1]; at rptr=N the last element is written
          -- and the pack is done.
          when S_PACK =>
            if rptr >= 1 then
              p   := rptr - 1;
              hbq := to_integer(signed(i_rdata));
              r32 := scale_mul(to_signed(hbq, 64), to_signed(1, 32), shift_o);
              if    r32 >  32767 then sat :=  32767;
              elsif r32 < -32768 then sat := -32768;
              else                    sat := to_integer(r32);
              end if;
              o_mant((p+1)*16-1 downto p*16) <= std_logic_vector(to_signed(sat, 16));
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
