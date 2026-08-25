-- Prices the WIDTH-NARROWED QK-norm datapath for subsystem C section 3, the
-- same way micro_b_lane / micro_c_lane priced units that did not exist yet:
-- the multiply SHAPES are real, the control is a free-running counter so
-- synthesis cannot fold any operand to a constant, and the output is an
-- XOR-fold digest so nothing is pruned.  NOT a functional rmsnorm.
--
-- WHY.  rmsnorm.vhd synthesized as-is at N=256 on xcvu33p-fsvh2104-2L-e /
-- 3.333 ns measures DSP=78, Fmax=138.4 MHz (MEASURED 2026-08-25) -- both
-- disqualifying.  The 78 is dominated by three 64x64 mulshr sites in the
-- pipelined rsqrt and by scale_mul(x, 1, sh) -- a literal multiply-by-one
-- (the same waste bfp_pack.vhd removed on 2026-07-27).  The value bounds
-- permit lossless narrowing exactly as attention_ml's 64/64 -> 52/24 divider
-- narrowing did:
--   rsqrt: mantissa and y are Q30, |y|,|smant| < 2^31, |diff| < 3*2^30
--          -> three 33x32 multiplies instead of three 64x64.
--   raw  : xm s16 * inv s32 -> s47; then s47 * wm s16.
--   emit : scale_mul(raw, 1, sh) -> plain round-half-up shift, NO multiply.
--   acc  : xm * xm, 16x16.
-- One multiply per pipeline stage, operands registered (the C-array AREG/BREG
-- lesson).  The RAW and EMIT passes reuse the SAME two physical multipliers
-- (they are different FSM phases of one datapath in the real unit).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity micro_rmsn_narrow is
  port(
    clk   : in  std_logic;
    rst   : in  std_logic;
    xm_in : in  std_logic_vector(15 downto 0);   -- element stream (keeps inputs live)
    wm_in : in  std_logic_vector(15 downto 0);
    dig   : out std_logic_vector(63 downto 0)    -- XOR-fold digest (keeps logic live)
  );
end entity micro_rmsn_narrow;

architecture rtl of micro_rmsn_narrow is
  -- operand registers (AREG/BREG stage)
  signal xm_r, wm_r         : signed(16 downto 0) := (others => '0');
  -- ACC: xm*xm
  signal sq_p               : signed(33 downto 0) := (others => '0');
  signal s_acc              : signed(45 downto 0) := (others => '0');
  -- rsqrt state, narrowed: Q30 mantissa / y in s32, diff in s34
  signal rq_y, rq_smant     : signed(31 downto 0) := (others => '0');
  signal rq_y2, rq_my2      : signed(31 downto 0) := (others => '0');
  signal rq_diff            : signed(33 downto 0) := (others => '0');
  signal m_yy, m_sy, m_yd   : signed(63 downto 0) := (others => '0');
  signal ph                 : unsigned(3 downto 0) := (others => '0');
  -- RAW/EMIT shared multipliers
  signal inv_r              : signed(31 downto 0) := (others => '0');
  signal xm_inv             : signed(47 downto 0) := (others => '0');
  signal raw_j              : signed(63 downto 0) := (others => '0');
  signal digest             : signed(63 downto 0) := (others => '0');
begin
  dig <= std_logic_vector(digest);

  process(clk)
    variable p64 : signed(65 downto 0);
    variable sh  : integer;
    variable b   : signed(63 downto 0);
    variable r   : signed(63 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        ph <= (others => '0');
        digest <= (others => '0');
      else
        ph <= ph + 1;
        -- operand registration (the DSP AREG/BREG stage)
        xm_r <= resize(signed(xm_in), 17);
        wm_r <= resize(signed(wm_in), 17);

        -- ACC phase: one 17x17 square per cycle
        sq_p  <= xm_r * xm_r;
        s_acc <= s_acc + resize(sq_p, 46);

        -- rsqrt Newton, one narrowed multiply per stage (3 physical mults)
        m_yy <= resize(rq_y * rq_y, 64);                       -- 32x32
        rq_y2 <= resize(shift_right(m_yy, 30), 32);
        m_sy <= resize(rq_smant * rq_y2, 64);                  -- 32x32
        rq_my2 <= resize(shift_right(m_sy, 30), 32);
        rq_diff <= resize(shift_left(to_signed(3, 34), 30) - resize(rq_my2, 34), 34);
        m_yd <= resize(rq_diff * rq_y, 64);                    -- 34x32
        rq_y <= resize(shift_right(m_yd, 31), 32);
        -- keep smant live from the input stream
        rq_smant <= resize(signed(xm_in) & signed(wm_in), 32);

        -- RAW/EMIT phase: the two shared multipliers
        inv_r  <= rq_y;
        xm_inv <= resize(xm_r * inv_r, 48);                    -- 17x32
        raw_j  <= resize(xm_inv * wm_r, 64);                   -- 48x17
        -- emit: scale_mul(raw, 1, sh) replaced by a round-half-up SHIFT
        sh := to_integer(ph) + 1;                              -- runtime shift, not foldable
        b  := shift_left(to_signed(1, 64), sh - 1);
        r  := shift_right(raw_j + b, sh);
        digest <= digest xor r xor m_yy xor resize(s_acc, 64);
      end if;
    end if;
  end process;
end architecture rtl;
