-- rtl/divider_rs.vhd
-- Multi-cycle RESTORING (shift-subtract) unsigned integer divider.
--
-- WHY THIS EXISTS
-- ---------------
-- The VHDL `/` operator, as synthesised by Vivado 2023.2 inside the
-- engine_shared datapath, produces WRONG quotients on silicon while every
-- operand is bit-perfect.  Measured directly on the XCZU3EG (attention_ml
-- S_WDIV, dbg_pos=4, layer 0), with the dividend formation independently
-- proven exact on both lanes:
--     lane 1  : nmag = 2,465,074,253,122  sum = 6,788
--               qmag(HW) = 363,118,079    vs  floor(a/b) = 363,151,775
--     lane 63 : nmag = 4,309,152,434,643  sum = 5,031
--               qmag(HW) = 536,802,267    vs  floor(a/b) = 856,520,062  (-37%)
-- The same site failed as a 64/64 divide (quotients LARGER than their own
-- dividend -- arithmetically impossible) and still fails narrowed to 52/24
-- (now too small, error varying per operand pair).  GHDL is 24/24 and the
-- ISOLATED divider passes netlist funcsim; only the in-engine silicon is wrong.
-- So the `/` macro is replaced here by an explicit, tiny, multi-cycle datapath:
-- one (DW+1)-bit compare/subtract per cycle instead of a ~1200-cell CARRY8
-- array, and nothing for the tool to "optimise" into a divider macro.
--
-- EXACTNESS
-- ---------
-- q = floor(num / den) for unsigned num, den -- the SAME value `/` is defined
-- to give.  The C-oracle rounding of the caller (which biases the dividend by
-- +/- den/2 BEFORE calling) is therefore preserved bit-exactly.  A
-- reciprocal-multiply would NOT preserve it and is deliberately not used.
--
-- IMPLEMENTATION DISCIPLINE (this is the part that has bitten this project)
-- ------------------------------------------------------------------------
-- An iterative divider was tried earlier in this design and MIS-SYNTHESISED
-- because it used VARIABLE-SIGNAL-INDEXED bit operations
-- (`div_quo(div_i) <= '1'`, `div_absnum(div_i)`).  This implementation uses
-- PURE MSB-SHIFT form:
--   * the dividend is a shift register; its MSB is taken by the FIXED index
--     r_num(NW-1) and the register is then shifted left by one;
--   * the quotient is a shift register; the new bit enters at the LSB via
--     `r_quo(NW-2 downto 0) & qb` -- a FIXED slice;
--   * the remainder is `r_rem & <msb>` (fixed concat), compared/subtracted
--     against the divisor.
-- There is NO variable index anywhere -- every slice/index is a compile-time
-- constant.  The only variable-ish state is the iteration counter, which is a
-- plain integer counter and indexes nothing.
--
-- TIMING: the critical path is one (DW+1)-bit compare + subtract (24+1 bits
-- here) -- trivially fast, versus the ~255-logic-level / 58 ns combinational
-- divide cone it replaces.
--
-- INTERFACE: single-shot.  Pulse `start` for one cycle with num/den valid;
-- `busy` goes high for NW cycles; `done` pulses for one cycle when `quo` is
-- valid, and `quo` then HOLDS until the next start.
--
-- den = 0 is never presented by the caller (softmax's sum_l is >= 2^Q); the
-- result in that case is unspecified-but-bounded garbage (no lockup): the
-- FSM always terminates after exactly NW iterations.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity divider_rs is
  generic(
    NW : positive := 52;   -- dividend / quotient width
    DW : positive := 24    -- divisor width (remainder is DW bits)
  );
  port(
    clk   : in  std_logic;
    rst   : in  std_logic;
    start : in  std_logic;                          -- 1-cycle load pulse
    num   : in  std_logic_vector(NW-1 downto 0);    -- dividend (unsigned)
    den   : in  std_logic_vector(DW-1 downto 0);    -- divisor  (unsigned, >=1)
    busy  : out std_logic;
    done  : out std_logic;                          -- 1-cycle pulse, quo valid
    quo   : out std_logic_vector(NW-1 downto 0)     -- floor(num/den), holds
  );
end entity divider_rs;

architecture rtl of divider_rs is
  -- Registered state ONLY -- the iteration consumes nothing but these.
  signal r_num  : unsigned(NW-1 downto 0) := (others => '0');  -- dividend shift reg
  signal r_quo  : unsigned(NW-1 downto 0) := (others => '0');  -- quotient shift reg
  signal r_rem  : unsigned(DW-1 downto 0) := (others => '0');  -- remainder (< den)
  signal r_den  : unsigned(DW-1 downto 0) := (others => '0');  -- latched divisor
  signal r_cnt  : integer range 0 to NW   := 0;                -- iteration counter
  signal r_busy : std_logic := '0';
  signal r_done : std_logic := '0';

  -- Keep these as real flip-flops: no LUTRAM / SRL extraction (SRL chains are
  -- un-hold-fixable and were a confirmed non-determinism source in this design).
  attribute shreg_extract : string;
  attribute shreg_extract of r_num : signal is "no";
  attribute shreg_extract of r_quo : signal is "no";
  attribute ram_style : string;
  attribute ram_style of r_num : signal is "registers";
  attribute ram_style of r_quo : signal is "registers";
begin
  busy <= r_busy;
  done <= r_done;
  quo  <= std_logic_vector(r_quo);

  process(clk)
    variable rs : unsigned(DW downto 0);   -- (r_rem << 1) | next dividend bit
    variable ds : unsigned(DW downto 0);   -- divisor, zero-extended
    variable qb : std_logic;               -- quotient bit produced this cycle
  begin
    if rising_edge(clk) then
      r_done <= '0';
      if rst = '1' then
        r_busy <= '0';
        r_cnt  <= 0;
        r_num  <= (others => '0');
        r_quo  <= (others => '0');
        r_rem  <= (others => '0');
        r_den  <= (others => '0');
      elsif r_busy = '0' then
        -- LOAD: register both operands; the iteration below never looks at the
        -- input ports again, so operand/divider sampling cannot race.
        if start = '1' then
          r_num  <= unsigned(num);
          r_den  <= unsigned(den);
          r_rem  <= (others => '0');
          r_quo  <= (others => '0');
          r_cnt  <= 0;
          r_busy <= '1';
        end if;
      else
        -- ITERATE: one restoring step.  All indices/slices below are FIXED.
        rs := r_rem & r_num(NW-1);          -- shift remainder left, bring in MSB
        ds := '0' & r_den;
        if rs >= ds then
          r_rem <= resize(rs - ds, DW);     -- subtract  -> quotient bit 1
          qb    := '1';
        else
          r_rem <= resize(rs, DW);          -- restore   -> quotient bit 0
          qb    := '0';
        end if;
        r_num <= r_num(NW-2 downto 0) & '0';   -- fixed slice
        r_quo <= r_quo(NW-2 downto 0) & qb;    -- fixed slice
        if r_cnt = NW-1 then
          r_busy <= '0';
          r_done <= '1';                    -- quo valid on this same edge
        else
          r_cnt <= r_cnt + 1;
        end if;
      end if;
    end if;
  end process;
end architecture rtl;
