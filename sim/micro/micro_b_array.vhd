-- sim/micro/micro_b_array.vhd -- LANES Gated DeltaNet lanes plus the SHARED
-- auxiliary units, for DSP sizing only.  NOT an implementation of subsystem B.
--
-- WHY THIS EXISTS.  B section 2.8 asserts DSP_B ~= 4*LANES + aux and the whole-die
-- budget carries 138-152 for B, which is the weakest row in the tightest
-- resource: DSP sits at 87.2-88.2% of 2,880 and B's contribution has never
-- seen synthesis.  micro_b_lane already measured ONE lane at 4 DSP, so the
-- per-lane claim looks settled -- but multiplying one lane by 32 is exactly
-- the step that made subsystem C's LUT estimate wrong.  C's own array measured
-- 310.5 LUT/lane against a single-lane fit predicting 238, i.e. the array cost
-- 30% more than the lane implied, because a lane in isolation has no
-- broadcast, no reduction and no shared operand registers.
--
-- So the question is NOT "what does a lane cost" (answered: 4 DSP) but
-- "does the ARRAY still cost 4/lane, and what is the fixed aux term".  That
-- needs a sweep and a fit, not a multiplication.
--
--   DSP = a + b*LANES      b -> the real per-lane cost
--                          a -> the aux term B budgets at 10-24
--
-- SHARING IS MODELLED, NOT ASSUMED GLOBAL (the micro_c_array_p rule).  Wiring
-- every operand to every lane would manufacture a fanout problem and then
-- discover it.  In B a lane owns one state-matrix element, so:
--
--   smant  private per lane           fanout 1
--   k_n    private per lane           fanout 1     (its own key element)
--   v_in   private per lane           fanout 1
--   eg     per-head decay             fanout LANES <-- broadcast under test
--   beta   per-head delta rate        fanout LANES <-- broadcast under test
--
-- THE AUX IS INSTANTIATED, NOT ESTIMATED.  B's per-head output path is
-- rmsnorm(o) * silu(z) (its 1.1(g), corrected 2026-08-25 to 48 value heads).
-- Both units exist as measured micros, so the fixed term is built from real
-- RTL rather than guessed: one narrowed rmsnorm plus one silu gate.  They are
-- SHARED across lanes -- one per array, not one per lane -- which is what
-- makes them a fixed `a` rather than part of `b`.
--
-- SIZING DISCIPLINE, same four rules as micro_b_lane:
--   * every operand arrives on a top-level port and is registered once, so
--     nothing constant-folds into a KCM or a shifter;
--   * every result is XOR-folded into `digest`, so no cone is pruned away;
--   * no DONT_TOUCH -- it blocks register-into-DSP packing and inflates FF;
--   * no use_dsp attribute -- natural inference is what the real RTL gets.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity micro_b_array is
  generic(
    LANES : positive := 32;
    -- 1 = include the shared rmsnorm + silu output path.  0 = lanes only,
    -- which isolates `b` from `a` directly instead of only through the fit.
    WITH_AUX : integer := 1
  );
  port(
    clk    : in  std_logic;
    rst    : in  std_logic;
    -- private per lane
    smant_all : in std_logic_vector(16*LANES-1 downto 0);
    k_all     : in std_logic_vector(16*LANES-1 downto 0);
    v_all     : in std_logic_vector(18*LANES-1 downto 0);
    -- broadcast: the nets whose fanout grows with LANES
    eg     : in  std_logic_vector(15 downto 0);
    beta   : in  std_logic_vector(15 downto 0);
    -- aux operands
    wm_in  : in  std_logic_vector(15 downto 0);
    z_in   : in  std_logic_vector(15 downto 0);
    digest : out std_logic_vector(31 downto 0)
  );
end entity;

architecture sizing of micro_b_array is
  type dvec is array(natural range <>) of std_logic_vector(31 downto 0);
  signal ld : dvec(0 to LANES-1);
  signal red : std_logic_vector(31 downto 0) := (others => '0');
  signal aux_d : std_logic_vector(63 downto 0) := (others => '0');
  signal aux_g : std_logic_vector(15 downto 0) := (others => '0');
  signal aux_ov : std_logic := '0';
begin
  g_lane : for i in 0 to LANES-1 generate
    u : entity work.micro_b_lane
      port map(
        clk    => clk,
        smant  => smant_all(16*(i+1)-1 downto 16*i),
        eg     => eg,
        k_n    => k_all(16*(i+1)-1 downto 16*i),
        v_in   => v_all(18*(i+1)-1 downto 18*i),
        beta   => beta,
        digest => ld(i));
  end generate;

  -- Registered XOR reduction.  Registered so the reduction tree does not
  -- appear in the lanes' critical path and quietly change the Fmax the sweep
  -- is also reporting.
  redp : process(clk)
    variable acc : std_logic_vector(31 downto 0);
  begin
    if rising_edge(clk) then
      acc := (others => '0');
      for i in 0 to LANES-1 loop
        acc := acc xor ld(i);
      end loop;
      red <= acc;
    end if;
  end process;

  -- The SHARED output path: rmsnorm(o) * silu(z), one per array.
  g_aux : if WITH_AUX = 1 generate
    ur : entity work.micro_rmsn_narrow
      port map(clk => clk, rst => rst,
               xm_in => red(15 downto 0), wm_in => wm_in, dig => aux_d);
    us : entity work.micro_silu_narrow
      generic map(Q => 12, OUT_Q => 15, SILU => 1)
      port map(clk => clk, rst => rst, iv => '1',
               z_q => aux_d(31 downto 0), u_q => z_in,
               ov => aux_ov, g_out => aux_g);
  end generate;

  digest <= red xor aux_d(31 downto 0) xor aux_d(63 downto 32)
            xor (15 downto 0 => aux_ov) & aux_g;
end architecture;
