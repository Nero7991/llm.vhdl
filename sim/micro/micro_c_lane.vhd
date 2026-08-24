-- sim/micro/micro_c_lane.vhd -- ONE gated-attention lane, for DSP/LUT sizing only.
--
-- NOT an implementation of subsystem C.  It exists to settle the single
-- largest uncertain structure in the whole FK33 allocation.  C §2.6 claims one
-- lane needs exactly 2 DSP48E2, on this reasoning:
--
--   score MAC    q     x k             s8  x s16   -- one DSP, second idle
--   PV MAC       p     x v_aligned     s13 x s8    -- one DSP, second idle
--   rescale      acc   x factor        s36 x s13   -- 36 > 27, so needs BOTH
--
-- i.e. the rescale is what forces the pair, and the two cheap MACs then ride
-- along for free in the DSP that the rescale already paid for.  If Vivado
-- instead lands on 3 DSPs per lane, the claim is 50% light -- across 192-288
-- lanes that is a 200-300 DSP swing on a 2,880-DSP device, larger than the
-- aux ranges of B and C combined, and it moves the ROWS_IF the A engine can
-- keep.  That is why this is built before any subsystem skeleton.
--
-- Second question, same file: the accumulator register file.  §2.6 puts the
-- PV accumulators in FF rather than BRAM because 64 read-modify-writes land
-- every cycle, and prices the read muxing at "roughly 16:1 per MAC lane, about
-- 10-13K LUT" for the whole 1,024-entry file.  This lane owns 1,024/64 = 16
-- entries, so it carries exactly one 16:1 mux and one 1-of-16 write decoder,
-- and the measured LUT here times 64 is the check on that 10-13K.
--
-- SIZING DISCIPLINE, and here it decides the answer rather than merely tidying
-- it:
--   * the mode is driven by a FREE-RUNNING COUNTER, not a port and not a
--     constant.  Time-sharing is only real if Vivado cannot prove which mode
--     is live; give it a constant and it strength-reduces each mode
--     separately, reports 1 DSP, and the "2 DSP shared" claim is confirmed by
--     an experiment that never tested it.
--   * ONE multiply expression with muxed operands, never three expressions.
--     Three would infer three multipliers and answer a different question.
--   * the register file is written out explicitly (array of signals, indexed
--     read, decoded write).  `acc(i) <= acc(i) + a*b` invites Vivado to pack
--     the add into the DSP's own accumulator and the file into a distributed
--     RAM, which is precisely the FF and LUT cost being measured.
--   * every operand enters on a top-level port; every result is XOR-folded
--     into `digest`.  Neither constant folding nor pruning is quiet.
--   * no DONT_TOUCH (blocks register packing, inflates FF), no use_dsp
--     (forcing it would assert the answer instead of measuring it).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity micro_c_lane is
  generic(
    ACC_N : positive := 16;      -- 1,024 accumulators / 64 lanes
    ACC_W : positive := 36       -- §2.6 PV accumulator width
  );
  port(
    clk    : in  std_logic;
    q_in   : in  std_logic_vector(7 downto 0);    -- s8  query
    k_in   : in  std_logic_vector(15 downto 0);   -- s16 key
    p_in   : in  std_logic_vector(12 downto 0);   -- s13 probability
    v_in   : in  std_logic_vector(7 downto 0);    -- s8  v_aligned
    f_in   : in  std_logic_vector(12 downto 0);   -- s13 rescale factor
    idx    : in  std_logic_vector(3 downto 0);    -- which accumulator
    digest : out std_logic_vector(31 downto 0)
  );
end entity;

architecture sizing of micro_c_lane is
  type acc_t is array(0 to ACC_N-1) of signed(ACC_W-1 downto 0);
  signal acc   : acc_t := (others => (others => '0'));

  -- Free-running: the mode must be opaque to synthesis, or nothing is shared.
  signal cnt   : unsigned(1 downto 0) := (others => '0');
  signal mode  : unsigned(1 downto 0) := (others => '0');

  signal q_r   : signed(7 downto 0)  := (others => '0');
  signal k_r   : signed(15 downto 0) := (others => '0');
  signal p_r   : signed(12 downto 0) := (others => '0');
  signal v_r   : signed(7 downto 0)  := (others => '0');
  signal f_r   : signed(12 downto 0) := (others => '0');
  signal i_r   : unsigned(3 downto 0) := (others => '0');

  signal a_mux : signed(ACC_W-1 downto 0) := (others => '0');  -- widest: acc
  signal b_mux : signed(15 downto 0)      := (others => '0');  -- widest: k
  signal prod  : signed(ACC_W+16-1 downto 0) := (others => '0');

  signal rd    : signed(ACC_W-1 downto 0) := (others => '0');
  signal score : signed(ACC_W-1 downto 0) := (others => '0');
  signal dig   : signed(31 downto 0) := (others => '0');
begin
  -- read side of the register file: the 16:1 mux §2.6 prices
  rd <= acc(to_integer(i_r));

  -- operand muxes.  Sign-extension to the common width is deliberate: it is
  -- what lets one physical multiplier serve all three, and it is also what
  -- makes a naive reading predict 3 DSPs.
  a_mux <= resize(q_r, ACC_W) when mode = "00" else   -- score:   s8  x s16
           resize(p_r, ACC_W) when mode = "01" else   -- PV:      s13 x s8
           rd;                                        -- rescale: s36 x s13
  b_mux <= k_r                when mode = "00" else
           resize(v_r, 16)    when mode = "01" else
           resize(f_r, 16);

  process(clk)
  begin
    if rising_edge(clk) then
      cnt  <= cnt + 1;
      mode <= cnt;

      q_r <= signed(q_in);  k_r <= signed(k_in);
      p_r <= signed(p_in);  v_r <= signed(v_in);
      f_r <= signed(f_in);  i_r <= unsigned(idx);

      prod <= a_mux * b_mux;

      -- write side: 1-of-16 decode, explicit so the file cannot collapse into
      -- a distributed RAM and hide its own cost
      for i in 0 to ACC_N-1 loop
        if to_integer(i_r) = i then
          if mode = "01" then
            acc(i) <= acc(i) + resize(prod, ACC_W);              -- PV MAC
          elsif mode = "10" then
            acc(i) <= resize(shift_right(prod, 12), ACC_W);      -- rescale
          end if;
        end if;
      end loop;

      if mode = "00" then
        score <= resize(prod, ACC_W);
      end if;

      dig <= dig xor resize(prod, 32) xor resize(rd, 32)
                 xor resize(score, 32);
    end if;
  end process;
  digest <= std_logic_vector(dig);
end architecture;
