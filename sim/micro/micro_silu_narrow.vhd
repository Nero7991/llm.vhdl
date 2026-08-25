-- Narrowed sigmoid/silu cone for subsystem D's swiglu, priced against
-- sim/micro/micro_sig_cone.vhd (the verbatim-width form, MEASURED 8 DSP).
--
-- WHY THIS EXISTS.  D 7.3 gives swiglu to D-vec at LANES_V = 8, so pass 1
-- needs EIGHT silu evaluations per cycle.  At the verbatim cone's 8 DSP per
-- lane that is 64 DSP for the nonlinearity alone, against D 12's whole-D-vec
-- estimate of 24-40 which must also cover two norms and two residual adds.
-- The whole-die reconciliation
-- (docs/debugging/2026-08-25_whole-die-budget-reconciliation.md) names this
-- measurement as the one that decides whether D's row is a budget or a wish.
--
-- WHY NARROWING IS LOSSLESS HERE, and it is not a judgement call:
--
--   hd   = SIG_ROM(k+1) - SIG_ROM(k).  MEASURED over the shipped 513-entry
--          table: min delta 8, max delta 16,771,757 < 2^24, ALWAYS POSITIVE
--          (the table is monotone).  So hd fits u24 / s25 exactly.
--   frac = idx_fp - (k << Q), in [0, 2^Q) whenever k is in range, so u12/s13
--          at Q = 12.
--   hd * frac  <=  2^24 * 2^12  =  2^36,  so s38 holds it EXACTLY.
--
-- 25 x 13 fits ONE DSP48E2 (27x18).  The verbatim cone declares the same
-- product as signed(64) * signed(64) -> signed(128), which is why it burns 8.
-- No value is lost: both forms compute the same integer, and sim/tb_silu_cone
-- asserts that bit for bit over the whole input range.
--
-- The one place the widths could have wrapped is the SATURATED path: when
-- |z| >= 16<<Q, k clamps to 0 or 511 and frac leaves [0, 2^Q).  The verbatim
-- form absorbs that in its 64-bit slack and then DISCARDS the result via
-- sat0/sat1.  Here frac is clamped instead, which changes nothing in the
-- non-saturated path (frac is already in range) and prevents a silent wrap in
-- the path whose output is overridden anyway.  Structural, not lucky.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.fixed_luts_pkg.all;

entity micro_silu_narrow is
  generic(
    Q     : integer := 12;   -- input Q-format (gate argument)
    OUT_Q : integer := 15;   -- output Q-format (gate factor)
    -- 0 = sigmoid only, directly comparable to micro_sig_cone.
    -- 1 = silu: y = x * sigmoid(x).
    -- 2 = a full swiglu LANE: y = silu(g) * u, which is what D-vec 7.3 needs
    --     LANES_V of.  Measured rather than derived, because "one more
    --     multiply" is exactly the kind of estimate this project keeps
    --     finding to be wrong by a DSP pair.
    SILU  : integer := 0
  );
  port(
    clk   : in  std_logic;
    rst   : in  std_logic;
    iv    : in  std_logic;
    z_q   : in  std_logic_vector(31 downto 0);  -- gate argument, Qq (s32)
    u_q   : in  std_logic_vector(15 downto 0) := (others => '0');  -- SILU=2 only
    ov    : out std_logic;
    g_out : out std_logic_vector(15 downto 0)   -- Q15 factor, or silu mantissa
  );
end entity micro_silu_narrow;

architecture rtl of micro_silu_narrow is
  -- stage A -> B.  Widths are the MEASURED bounds above, not round numbers.
  type a2b_t is record
    lo   : signed(31 downto 0);   -- SIG_ROM entry, Q30, <= 2^30
    hd   : signed(24 downto 0);   -- table delta, u24 measured
    frac : signed(12 downto 0);   -- [0, 2^Q), Q = 12
    zq   : signed(17 downto 0);   -- x carried for the silu multiply (s18)
    uq   : signed(15 downto 0);   -- u carried for the swiglu multiply
    sat0 : std_logic;
    sat1 : std_logic;
    v    : std_logic;
  end record;
  type b2c_t is record
    lo   : signed(31 downto 0);
    prod : signed(37 downto 0);   -- 25 x 13 -> s38, exact
    zq   : signed(17 downto 0);
    uq   : signed(15 downto 0);
    sat0 : std_logic;
    sat1 : std_logic;
    v    : std_logic;
  end record;
  constant A2B0 : a2b_t := ((others=>'0'),(others=>'0'),(others=>'0'),
                            (others=>'0'),(others=>'0'),'0','0','0');
  constant B2C0 : b2c_t := ((others=>'0'),(others=>'0'),(others=>'0'),
                            (others=>'0'),'0','0','0');

  signal ab : a2b_t := A2B0;
  signal bc : b2c_t := B2C0;
begin
  process(clk)
    variable z      : signed(31 downto 0);
    variable offset : signed(31 downto 0);
    variable idx_fp : signed(35 downto 0);
    variable k      : integer;
    variable fr     : signed(35 downto 0);
    variable interp : signed(31 downto 0);
    variable bias   : signed(31 downto 0);
    variable r      : signed(31 downto 0);
    variable sm     : signed(33 downto 0);
    variable sg     : signed(15 downto 0);
    variable o      : a2b_t;
  begin
    if rising_edge(clk) then
      ov <= '0';
      if rst = '1' then
        ab <= A2B0;
        bc <= B2C0;
      else
        -- stage A: clamp tests, index, frac, ROM lookups.  No multiply.
        z      := signed(z_q);
        o      := A2B0;
        o.v    := iv;
        if z <= shift_left(to_signed(-16, 32), Q) then o.sat0 := '1'; end if;
        if z >= shift_left(to_signed( 16, 32), Q) then o.sat1 := '1'; end if;
        offset := z + shift_left(to_signed(16, 32), Q);
        idx_fp := shift_left(resize(offset, 36), 4);
        k      := to_integer(shift_right(idx_fp, Q));
        if k > 511 then k := 511; end if;
        if k <   0 then k :=   0; end if;
        fr     := idx_fp - shift_left(to_signed(k, 36), Q);
        -- clamp: only reachable on the saturated path, see the header
        if fr < 0 then fr := (others => '0'); end if;
        if fr > shift_left(to_signed(1, 36), Q) - 1 then
          fr := shift_left(to_signed(1, 36), Q) - 1;
        end if;
        o.frac := resize(fr, 13);
        o.lo   := to_signed(SIG_ROM(k),     32);
        o.hd   := to_signed(SIG_ROM(k + 1) - SIG_ROM(k), 25);
        -- x itself, for the silu multiply.  s18 is the DSP's B port width and
        -- covers the whole non-saturated argument range (|z| < 16<<12 = 2^16).
        if    z >  shift_left(to_signed( 16, 32), Q) then o.zq := to_signed( 65536, 18);
        elsif z < -shift_left(to_signed( 16, 32), Q) then o.zq := to_signed(-65536, 18);
        else  o.zq := resize(z, 18); end if;
        o.uq := signed(u_q);
        ab <= o;

        -- stage B: the ONE narrow multiply, 25 x 13 -> s38, exact.
        bc.lo   <= ab.lo;
        bc.prod <= ab.hd * ab.frac;
        bc.zq   <= ab.zq;
        bc.uq   <= ab.uq;
        bc.sat0 <= ab.sat0;
        bc.sat1 <= ab.sat1;
        bc.v    <= ab.v;

        -- stage C: interpolate (Q30) -> round-half-up to OUT_Q -> clamp.
        interp := bc.lo + resize(shift_right(bc.prod, Q), 32);
        bias   := shift_left(to_signed(1, 32), 30 - OUT_Q - 1);
        r      := shift_right(interp + bias, 30 - OUT_Q);
        if    bc.sat0 = '1' then r := to_signed(0, 32);
        elsif bc.sat1 = '1' then r := to_signed(32767, 32);
        elsif r < 0             then r := to_signed(0, 32);
        elsif r > to_signed(32767, 32) then r := to_signed(32767, 32);
        end if;

        if SILU = 0 then
          g_out <= std_logic_vector(resize(r, 16));
        else
          -- silu: x * sigmoid(x).  s18 x s16 -> one DSP.  Q(in)+OUT_Q, shifted
          -- back to Q(in) so the output shares the input's grid.
          sm := bc.zq * resize(r, 16);
          if SILU = 1 then
            g_out <= std_logic_vector(resize(shift_right(sm, OUT_Q), 16));
          else
            -- swiglu lane: silu(g) * u.  The silu is narrowed to s16 first so
            -- the second multiply is 16x16 and stays in one DSP.
            sg    := resize(shift_right(sm, OUT_Q), 16);
            g_out <= std_logic_vector(resize(shift_right(sg * bc.uq, 15), 16));
          end if;
        end if;
        ov <= bc.v;
      end if;
    end if;
  end process;
end architecture rtl;
