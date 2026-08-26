-- Prices the ONE-PER-VECTOR reciprocal-square-root that D-vec's two RMSNorms
-- need, isolated from the per-element lane priced by micro_d_vec.vhd.
--
-- WHY SEPARATELY.  D section 12's DSP row is per-element x LANES_V plus a fixed
-- term, and only the per-element half had been measured.  The fixed term was
-- carried as "rsqrt, shared across lanes ~6-9 DSP, DERIVED from the 18-DSP
-- 1-lane narrowed rmsnorm skeleton" -- a number obtained by subtracting other
-- estimates from a measurement, which is not a measurement.  This skeleton is
-- the rsqrt alone, at micro_rmsn_narrow's narrowed widths, so the fixed term
-- can be added to 24 rather than guessed at.
--
-- The iteration is y <- y*(3 - s*y^2)/2 in Q30, three multiplies deep.  The
-- real unit runs several Newton steps through ONE datapath, so the DSP cost is
-- set by the number of physical multiply SITES, not by the iteration count --
-- hence no iteration-count generic.  SHARE_ND asks the same coding-style
-- question micro_d_vec asks of the phases: 1 = the three Newton multiplies are
-- one phase-muxed multiplier, 0 = three distinct ones.
--
-- Control is a free-running counter and the output an XOR-fold digest, so no
-- operand folds to a constant and nothing is pruned.  NOT a functional rsqrt:
-- the seed is taken from the input stream rather than a LZC+ROM, because a
-- table lookup is BRAM/LUT and would not change the DSP answer this asks for.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity micro_d_rsqrt is
  generic(
    SHARE_ND : natural := 1   -- 1: one phase-muxed multiplier; 0: three
  );
  port(
    clk   : in  std_logic;
    rst   : in  std_logic;
    s_in  : in  std_logic_vector(31 downto 0);  -- sum-of-squares mantissa, Q30
    dig   : out std_logic_vector(63 downto 0)
  );
end entity micro_d_rsqrt;

architecture rtl of micro_d_rsqrt is
  signal smant, y     : signed(31 downto 0) := to_signed(1, 32);
  signal y2, my2      : signed(31 downto 0) := (others => '0');
  signal diff         : signed(33 downto 0) := (others => '0');
  signal p_sh, p0, p1, p2 : signed(67 downto 0) := (others => '0');
  signal ph           : unsigned(1 downto 0) := (others => '0');
  signal digest       : signed(63 downto 0) := (others => '0');
begin
  dig <= std_logic_vector(digest);

  process(clk)
    variable a, b : signed(33 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        ph <= (others => '0'); digest <= (others => '0');
        y <= to_signed(1, 32);
      else
        ph    <= ph + 1;
        smant <= signed(s_in);

        if SHARE_ND = 1 then
          -- one physical multiplier, phase-selected operands
          case ph is
            when "00"   => a := resize(y, 34);     b := resize(y, 34);      -- y*y
            when "01"   => a := resize(smant, 34); b := resize(y2, 34);     -- s*y2
            when others => a := diff;              b := resize(y, 34);      -- d*y
          end case;
          p_sh <= a * b;
          y2   <= resize(shift_right(p_sh, 30), 32);
          my2  <= resize(shift_right(p_sh, 30), 32);
          diff <= resize(shift_left(to_signed(3, 34), 30) - resize(my2, 34), 34);
          y    <= resize(shift_right(p_sh, 31), 32);
          digest <= digest xor resize(p_sh, 64);
        else
          -- three distinct multipliers, one per Newton stage
          p0   <= resize(y * y, 68);
          y2   <= resize(shift_right(p0, 30), 32);
          p1   <= resize(smant * y2, 68);
          my2  <= resize(shift_right(p1, 30), 32);
          diff <= resize(shift_left(to_signed(3, 34), 30) - resize(my2, 34), 34);
          p2   <= resize(diff * y, 68);
          y    <= resize(shift_right(p2, 31), 32);
          digest <= digest xor resize(p0, 64) xor resize(p1, 64) xor resize(p2, 64);
        end if;
      end if;
    end if;
  end process;
end architecture rtl;
