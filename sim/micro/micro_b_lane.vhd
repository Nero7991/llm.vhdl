-- sim/micro/micro_b_lane.vhd -- ONE Gated DeltaNet lane, for DSP sizing only.
--
-- NOT an implementation of subsystem B. It exists to answer one question:
-- does B's per-lane arithmetic cost 4 DSP48E2, as its §2.8 asserts
-- (DSP_B ~= 4*LANES + aux)? That claim rests on the site-6 prescale and site-7
-- normalize having been engineered so every product fits one 27x18 DSP, and B
-- is Rev 1 with no adversarial review -- its own §0 predicts errors.
--
-- The four products, from B §2.1.4:
--   stage 1  decay    w    = smant * eg        s16 x u16(<=2^15)  -> s32
--   stage 2  sk dot   sk  += w18 * k_n         s19 x s16          -> s41 acc
--   stage 3  delta    d_m  = diff * beta       s18 x u16 Q16      -> s18
--   stage 4  update   kd   = k_n * d_m         s16 x s18          -> s33
--
-- SIZING DISCIPLINE (all four matter, each has bitten this kind of experiment):
--   * every operand arrives on a top-level port and is registered once, so
--     nothing constant-folds into a KCM or a shifter;
--   * every result is XOR-folded into `digest`, so no cone is pruned away
--     with only a quiet log note;
--   * no DONT_TOUCH -- it blocks register-into-DSP packing and inflates FF;
--   * no use_dsp attribute -- natural inference is what the real RTL will get,
--     and forcing it would answer a question nobody asked.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity micro_b_lane is
  port(
    clk    : in  std_logic;
    smant  : in  std_logic_vector(15 downto 0);   -- s16 state mantissa
    eg     : in  std_logic_vector(15 downto 0);   -- u16 decay, <= 2^15
    k_n    : in  std_logic_vector(15 downto 0);   -- s16 normalised key
    v_in   : in  std_logic_vector(17 downto 0);   -- s18 value on the e_d grid
    beta   : in  std_logic_vector(15 downto 0);   -- u16 Q16
    digest : out std_logic_vector(31 downto 0)
  );
end entity;

architecture sizing of micro_b_lane is
  signal smant_r, eg_r, k_r, beta_r : signed(17 downto 0) := (others => '0');
  signal v_r      : signed(17 downto 0) := (others => '0');
  signal w32      : signed(33 downto 0) := (others => '0');   -- stage 1
  signal w18      : signed(18 downto 0) := (others => '0');   -- prescale to s19
  signal sk_acc   : signed(40 downto 0) := (others => '0');   -- stage 2
  signal skm      : signed(17 downto 0) := (others => '0');
  signal diff     : signed(17 downto 0) := (others => '0');
  signal d_m      : signed(17 downto 0) := (others => '0');   -- stage 3
  signal kd       : signed(33 downto 0) := (others => '0');   -- stage 4
  signal dig      : signed(31 downto 0) := (others => '0');
begin
  process(clk)
  begin
    if rising_edge(clk) then
      -- operands registered once, straight off the ports
      smant_r <= resize(signed(smant), 18);
      eg_r    <= resize(signed('0' & eg(14 downto 0)), 18);   -- u16 <= 2^15
      k_r     <= resize(signed(k_n), 18);
      v_r     <= signed(v_in);
      beta_r  <= resize(signed('0' & beta(14 downto 0)), 18);

      -- stage 1: decay, s16 x u16
      w32 <= resize(smant_r * eg_r, 34);
      -- site 6 prescale to s19; w18 can reach exactly 2^17, hence 19 not 18
      w18 <= resize(shift_right(w32, 13), 19);

      -- stage 2: sk dot, s19 x s16, accumulated. Written as an explicit
      -- register add rather than a bare `acc <= acc + a*b`, which Vivado
      -- would fold into the DSP's internal accumulator and hide a DSP.
      sk_acc <= sk_acc + resize(w18 * k_r, 41);
      skm    <= resize(shift_right(sk_acc, 15), 18);

      -- stage 3: delta, s18 x u16 Q16
      diff <= resize(v_r - skm, 18);
      d_m  <= resize(shift_right(diff * beta_r, 16), 18);

      -- stage 4: update, s16 x s18
      kd <= resize(k_r * d_m, 34);

      -- fold everything live so no cone is pruned
      dig <= dig xor resize(w32, 32) xor resize(sk_acc, 32)
                 xor resize(d_m, 32) xor resize(kd, 32);
    end if;
  end process;
  digest <= std_logic_vector(dig);
end architecture;
