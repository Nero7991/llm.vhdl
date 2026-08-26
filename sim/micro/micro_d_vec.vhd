-- sim/micro/micro_d_vec.vhd -- LANES_V lanes of subsystem D's elementwise unit,
-- for DSP sizing only.  NOT an implementation of D-vec.
--
-- WHY THIS EXISTS.  D §12 carries 24-40 DSP48E2 and, after B was measured at
-- 148 on 2026-08-25, that band is the ONLY estimate left in the whole-die DSP
-- sum (2,520-2,536 of 2,880, 87.5-88.1%).  It is also not a vague band: D §12
-- says exactly what its two ends mean --
--
--   24 = the three D-vec phases SHARE their multipliers ("phases are disjoint,
--        so sharing is expected")
--   40 = they do not ("40 is the no-sharing bound")
--
-- So this is a decidable question about what synthesis does with a mode-muxed
-- datapath, not a modelling guess, and the honest way to answer it is to build
-- BOTH and subtract.  A single number from a single variant would not
-- distinguish "sharing happened" from "the arithmetic was cheaper than
-- thought".
--
-- THE THREE PHASES, from D §4.2/§7.3.  D-vec is called for attn_norm,
-- ffn_norm (rmsnorm), residual (exp-aligned add + requant) and swiglu
-- (silu(g)*u).  They are DISJOINT IN TIME -- a token runs norm, then later
-- residual, then later swiglu -- which is the premise the sharing rests on.
--
--   norm      pass 1: x*x accumulate          1 multiply
--             pass 2: x * rsqrt_scale         1 multiply
--   residual  pass 1: aligned add             0 multiplies
--             pass 2: requantise              1 multiply
--   swiglu    sigmoid ROM interpolation       1 multiply   (D §7.1)
--             silu = g * sigmoid(g)           1 multiply
--             * u                             1 multiply
--
-- Peak concurrent per lane is 3 (swiglu).  Sum across phases is 5.  Hence
-- 8 x 3 = 24 and 8 x 5 = 40, exactly D §12's two ends.
--
-- SIZING DISCIPLINE, the four rules from micro_b_lane / micro_b_array:
--   * every operand arrives on a top-level port and is registered once, so
--     nothing constant-folds into a KCM or a shifter;
--   * every result is XOR-folded into `digest`, so no cone is pruned away;
--   * no DONT_TOUCH -- it blocks register-into-DSP packing and inflates FF;
--   * no use_dsp -- natural inference is what the real RTL will get, and
--     forcing it would answer a question nobody asked.
--
-- The rsqrt/reciprocal is deliberately NOT modelled per lane: it is one
-- instance per unit (D §7.3 reuses rmsnorm's rsqrt_q/RSQRT_ROM), so it belongs
-- in the fixed term, and C measured its divider at 0 DSP.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity micro_d_vec is
  generic(
    LANES_V : positive := 8;
    -- 1 = one mode-muxed multiplier set per lane, which is what D §7.3's
    --     two-pass structure permits because the phases never overlap.
    -- 0 = a separate multiplier per phase, the no-sharing bound.
    SHARE   : integer := 1
  );
  port(
    clk   : in  std_logic;
    -- phase select: 0 norm, 1 residual, 2 swiglu.  A real D-vec takes this
    -- from the descriptor; here it is a port so it cannot constant-fold and
    -- collapse the mux the experiment is about.
    mode  : in  std_logic_vector(1 downto 0);
    x_all : in  std_logic_vector(16*LANES_V-1 downto 0);   -- element / g
    u_all : in  std_logic_vector(16*LANES_V-1 downto 0);   -- residual / u
    scl   : in  std_logic_vector(15 downto 0);             -- rsqrt or requant
    interp: in  std_logic_vector(15 downto 0);             -- ROM slope
    digest: out std_logic_vector(31 downto 0)
  );
end entity;

architecture sizing of micro_d_vec is
  type dvec is array(natural range <>) of signed(31 downto 0);
  signal ld : dvec(0 to LANES_V-1) := (others => (others => '0'));
  signal red : std_logic_vector(31 downto 0) := (others => '0');
begin
  g : for i in 0 to LANES_V-1 generate
    signal xr, ur, sr, ir : signed(16 downto 0) := (others => '0');
    signal m0, m1, m2     : signed(33 downto 0) := (others => '0');
    signal n0, n1         : signed(33 downto 0) := (others => '0');
    signal acc            : signed(31 downto 0) := (others => '0');
  begin
    process(clk)
      variable a0, b0, a1, b1 : signed(16 downto 0);
    begin
      if rising_edge(clk) then
        xr <= resize(signed(x_all(16*(i+1)-1 downto 16*i)), 17);
        ur <= resize(signed(u_all(16*(i+1)-1 downto 16*i)), 17);
        sr <= resize(signed(scl), 17);
        ir <= resize(signed(interp), 17);

        if SHARE = 1 then
          -- ONE multiplier set, operands selected by phase.  The DSP count
          -- should follow the PEAK concurrent use (3), not the sum (5).
          case mode is
            when "00"   => a0 := xr;  b0 := xr;   -- norm p1: x*x
                           a1 := xr;  b1 := sr;   -- norm p2: x*scale
            when "01"   => a0 := xr;  b0 := sr;   -- residual requant
                           a1 := ur;  b1 := sr;
            when others => a0 := xr;  b0 := ir;   -- swiglu: ROM interp
                           a1 := xr;  b1 := sr;   -- silu: g*sigmoid
          end case;
          m0 <= a0 * b0;
          m1 <= a1 * b1;
          -- third multiply exists only in the swiglu phase, but a shared
          -- datapath still instantiates it once per lane
          m2 <= resize(m1(31 downto 16), 17) * ur;
          acc <= acc + m0(31 downto 0) + m1(31 downto 0) + m2(31 downto 0);
        else
          -- NO SHARING: every phase gets its own multipliers and the mode only
          -- selects which result is used.  5 per lane.
          n0 <= xr * xr;                                   -- norm p1
          n1 <= xr * sr;                                   -- norm p2
          m0 <= xr * ir;                                   -- swiglu interp
          m1 <= xr * sr;                                   -- silu
          m2 <= resize(m1(31 downto 16), 17) * ur;         -- * u
          case mode is
            when "00"   => acc <= acc + n0(31 downto 0) + n1(31 downto 0);
            when "01"   => acc <= acc + n1(31 downto 0);
            when others => acc <= acc + m0(31 downto 0) + m1(31 downto 0)
                                      + m2(31 downto 0);
          end case;
        end if;
        ld(i) <= acc;
      end if;
    end process;
  end generate;

  redp : process(clk)
    variable a : signed(31 downto 0);
  begin
    if rising_edge(clk) then
      a := (others => '0');
      for i in 0 to LANES_V-1 loop a := a xor ld(i); end loop;
      red <= std_logic_vector(a);
    end if;
  end process;

  digest <= red;
end architecture;
