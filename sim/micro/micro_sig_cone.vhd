-- The sigmoid cone for subsystem C's gate, priced the same way the exp cone
-- was (sim/micro/micro_exp_cone.vhd): a 3-stage pipeline, one element per
-- cycle, arithmetic copied from fixed_pkg.sigmoid_q verbatim (64/128-bit
-- intermediate widths included) EXCEPT for the output stage, which emits
-- Q15 (round-half-up of the Q30 interpolant >> 15, clamped to [0, 32767])
-- instead of sigmoid_q's Qq -- the format C section 3 pins for the gate
-- multiply.  SIG_ROM is the shipped 513-entry Q30 table over [-16, 16),
-- step 1/16 (fixed_luts_pkg).
--
-- Purpose: DSP48E2 census for C's auxiliary-DSP row.  The exp-cone
-- measurement established that staged vs pipelined does not change the
-- census, so only the pipelined form is built here.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.fixed_luts_pkg.all;

entity micro_sig_cone is
  generic(
    Q     : integer := 12;   -- input Q-format (score/gate argument)
    OUT_Q : integer := 15    -- output Q-format (gate factor)
  );
  port(
    clk   : in  std_logic;
    rst   : in  std_logic;
    iv    : in  std_logic;                      -- input valid
    z_q   : in  std_logic_vector(31 downto 0);  -- gate argument, Qq (s32)
    ov    : out std_logic;                      -- output valid
    g_out : out std_logic_vector(15 downto 0)   -- gate factor, Q15 in [0,32767]
  );
end entity micro_sig_cone;

architecture rtl of micro_sig_cone is
  -- stage A -> B payload
  type a2b_t is record
    lo   : signed(63 downto 0);
    hd   : signed(63 downto 0);   -- hi - lo
    frac : signed(63 downto 0);
    sat0 : std_logic;             -- z <= -16<<Q  -> 0
    sat1 : std_logic;             -- z >= +16<<Q  -> 32767 (clamped one)
    v    : std_logic;
  end record;
  -- stage B -> C payload
  type b2c_t is record
    lo   : signed(63 downto 0);
    prod : signed(127 downto 0);
    sat0 : std_logic;
    sat1 : std_logic;
    v    : std_logic;
  end record;
  constant A2B0 : a2b_t := ((others=>'0'),(others=>'0'),(others=>'0'),'0','0','0');
  constant B2C0 : b2c_t := ((others=>'0'),(others=>'0'),'0','0','0');

  signal ab : a2b_t := A2B0;
  signal bc : b2c_t := B2C0;
begin
  process(clk)
    variable z      : signed(63 downto 0);
    variable offset : signed(63 downto 0);
    variable idx_fp : signed(63 downto 0);
    variable k      : integer;
    variable tmp    : signed(127 downto 0);
    variable interp : signed(63 downto 0);
    variable bias   : signed(63 downto 0);
    variable r      : signed(63 downto 0);
    variable o      : a2b_t;
  begin
    if rising_edge(clk) then
      ov <= '0';
      if rst = '1' then
        ab <= A2B0;
        bc <= B2C0;
      else
        -- stage A: clamp tests, index, frac, ROM lookups (no multiply).
        z      := resize(signed(z_q), 64);
        o      := A2B0;
        o.v    := iv;
        o.sat0 := '0';
        o.sat1 := '0';
        if z <= shift_left(to_signed(-16, 64), Q) then o.sat0 := '1'; end if;
        if z >= shift_left(to_signed( 16, 64), Q) then o.sat1 := '1'; end if;
        offset := z + shift_left(to_signed(16, 64), Q);
        idx_fp := shift_left(offset, 4);
        k      := to_integer(shift_right(idx_fp, Q));
        if k > 511 then k := 511; end if;
        if k <   0 then k :=   0; end if;
        o.frac := idx_fp - shift_left(to_signed(k, 64), Q);
        o.lo   := to_signed(SIG_ROM(k),     64);
        o.hd   := to_signed(SIG_ROM(k + 1), 64) - to_signed(SIG_ROM(k), 64);
        ab <= o;

        -- stage B: the single (hi-lo)*frac multiply, verbatim widths.
        bc.lo   <= ab.lo;
        bc.prod <= ab.hd * ab.frac;
        bc.sat0 <= ab.sat0;
        bc.sat1 <= ab.sat1;
        bc.v    <= ab.v;

        -- stage C: interpolate (Q30) -> round-half-up to Q15 -> clamp.
        tmp    := shift_right(bc.prod, Q);
        interp := bc.lo + tmp(63 downto 0);
        bias   := shift_left(to_signed(1, 64), 30 - OUT_Q - 1);
        r      := shift_right(interp + bias, 30 - OUT_Q);
        if    bc.sat0 = '1' then r := to_signed(0, 64);
        elsif bc.sat1 = '1' then r := to_signed(32767, 64);
        elsif r < 0             then r := to_signed(0, 64);
        elsif r > to_signed(32767, 64) then r := to_signed(32767, 64);
        end if;
        g_out <= std_logic_vector(resize(r, 16));
        ov    <= bc.v;
      end if;
    end if;
  end process;
end architecture rtl;
