-- Prices the VECTORIZED narrowed RMSNorm that B section 3.3 requires, as a
-- function of lane count.
--
-- WHY.  B section 3.2 shows the output norms and L2 norms are 4.1x the state
-- sweep they were supposed to hide under, and section 3.3's fix is to fuse
-- rmsnorm.vhd's duplicated RAW/EMIT passes and then vectorize.  That fix was
-- asserted with a cycle count and no area, and section 2.8's measured DSP row
-- carries a fixed 20 (rmsnorm_rs 18 + silu 2) that covers ONE lane.  If the
-- 4-lane form costs what a naive x4 would, B's DSP row moves enough to matter
-- against a die already at 87.6%.  So it is measured, not extrapolated.
--
-- Same discipline as micro_rmsn_narrow.vhd, which this generalises: the
-- multiply SHAPES are real and narrowed to the section 3.6 value bounds, the
-- control is a free-running counter so no operand folds to a constant, and the
-- output is an XOR-fold digest so nothing is pruned.  NOT a functional
-- rmsnorm.
--
-- The structural question is whether the rsqrt stays FIXED as lanes grow.  It
-- should: rsqrt consumes the ACCUMULATED sum of squares, one per vector, not
-- one per element.  If DSP comes back affine in LANES with a nonzero
-- intercept, that is confirmed; if it comes back proportional, the rsqrt has
-- been replicated per lane and the design is wrong, not merely expensive.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity micro_rmsn_lanes is
  generic(
    LANES : positive := 4
  );
  port(
    clk   : in  std_logic;
    rst   : in  std_logic;
    xm_in : in  std_logic_vector(16*LANES-1 downto 0);
    wm_in : in  std_logic_vector(16*LANES-1 downto 0);
    dig   : out std_logic_vector(63 downto 0)
  );
end entity micro_rmsn_lanes;

architecture rtl of micro_rmsn_lanes is
  type s17a is array(0 to LANES-1) of signed(16 downto 0);
  type s34a is array(0 to LANES-1) of signed(33 downto 0);
  type s48a is array(0 to LANES-1) of signed(47 downto 0);
  type s64a is array(0 to LANES-1) of signed(63 downto 0);

  signal xm_r, wm_r : s17a := (others => (others => '0'));
  signal sq_p       : s34a := (others => (others => '0'));
  signal xm_inv     : s48a := (others => (others => '0'));
  signal raw_j      : s64a := (others => (others => '0'));
  signal s_acc      : signed(45 downto 0) := (others => '0');

  -- rsqrt, ONE instance regardless of LANES: it consumes the accumulated sum
  -- of squares, which is a per-vector quantity.
  signal rq_y, rq_smant   : signed(31 downto 0) := (others => '0');
  signal rq_y2, rq_my2    : signed(31 downto 0) := (others => '0');
  signal rq_diff          : signed(33 downto 0) := (others => '0');
  signal m_yy, m_sy, m_yd : signed(63 downto 0) := (others => '0');
  signal inv_r            : signed(31 downto 0) := (others => '0');

  signal ph     : unsigned(3 downto 0) := (others => '0');
  signal digest : signed(63 downto 0) := (others => '0');
begin
  dig <= std_logic_vector(digest);

  process(clk)
    variable sq_sum : signed(45 downto 0);
    variable fold   : signed(63 downto 0);
    variable sh     : integer;
    variable b, r   : signed(63 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        ph <= (others => '0'); digest <= (others => '0');
      else
        ph <= ph + 1;

        sq_sum := (others => '0');
        fold   := (others => '0');
        for i in 0 to LANES-1 loop
          xm_r(i) <= resize(signed(xm_in((i+1)*16-1 downto i*16)), 17);
          wm_r(i) <= resize(signed(wm_in((i+1)*16-1 downto i*16)), 17);

          -- ACC: one 17x17 square per lane per cycle
          sq_p(i) <= xm_r(i) * xm_r(i);
          sq_sum  := sq_sum + resize(sq_p(i), 46);

          -- RAW/EMIT, fused: the two multiplies that were separate FSM phases
          -- in rmsnorm.vhd are one pipeline here.  Fusing is a CYCLE saving,
          -- not a DSP saving -- the shipped unit already reused the same two
          -- physical multipliers across its RAW and EMIT phases -- so this
          -- skeleton should show the same per-lane multiply count either way.
          xm_inv(i) <= resize(xm_r(i) * inv_r, 48);       -- 17x32
          raw_j(i)  <= resize(xm_inv(i) * wm_r(i), 64);   -- 48x17
          fold      := fold xor raw_j(i);
        end loop;
        s_acc <= s_acc + sq_sum;

        -- the single shared rsqrt Newton chain, three narrowed multiplies
        m_yy   <= resize(rq_y * rq_y, 64);
        rq_y2  <= resize(shift_right(m_yy, 30), 32);
        m_sy   <= resize(rq_smant * rq_y2, 64);
        rq_my2 <= resize(shift_right(m_sy, 30), 32);
        rq_diff <= resize(shift_left(to_signed(3, 34), 30)
                          - resize(rq_my2, 34), 34);
        m_yd   <= resize(rq_diff * rq_y, 64);
        rq_y   <= resize(shift_right(m_yd, 31), 32);
        rq_smant <= resize(s_acc(31 downto 0), 32);
        inv_r  <= rq_y;

        -- emit: a round-half-up SHIFT, never a multiply-by-one
        sh := to_integer(ph) + 1;
        b  := shift_left(to_signed(1, 64), sh - 1);
        r  := shift_right(fold + b, sh);
        digest <= digest xor r xor m_yy xor resize(s_acc, 64);
      end if;
    end if;
  end process;
end architecture rtl;
