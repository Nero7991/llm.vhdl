-- sim/micro/c_lane.vhd -- the gated-attention lane of micro_c_lane_sh.vhd,
-- extracted as a component so an array of them can be built.
--
-- The arithmetic is UNCHANGED from micro_c_lane_sh, deliberately: that lane
-- measured 2 DSP / 318 LUT / 765 FF / 328.6 MHz standalone on
-- xcvu33p-fsvh2104-2L-e (docs/debugging/2026-08-23_bc-lane-micro-synthesis.md),
-- and the whole point of the array is to find how much of that 328.6 MHz
-- survives once the shared operands have to reach every lane.  Changing the
-- lane at the same time would make the two runs incomparable.
--
-- The one structural change: operand SELECTION moved out.  A lane no longer
-- takes `idx` and works out which k/v/f it wants; the array hands it the
-- already-selected values.  That is what puts the sharing pattern in the
-- array, where it can be modelled honestly, instead of hiding it inside a
-- component that cannot see its siblings.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity c_lane is
  generic(
    ACC_N : positive := 16;
    ACC_W : positive := 36
  );
  port(
    clk    : in  std_logic;
    mode   : in  unsigned(1 downto 0);            -- BROADCAST from the array
    idx    : in  std_logic_vector(7 downto 0);    -- BROADCAST from the array
    q_in   : in  std_logic_vector(7 downto 0);    -- private to this lane
    k_in   : in  std_logic_vector(15 downto 0);   -- shared across heads
    v_in   : in  std_logic_vector(7 downto 0);    -- shared across heads
    f_in   : in  std_logic_vector(12 downto 0);   -- shared across a whole head
    digest : out std_logic_vector(31 downto 0)
  );
end entity;

architecture sizing of c_lane is
  function clog2(n : positive) return natural is
    variable r : natural := 0; variable v : positive := 1;
  begin
    while v < n loop v := v * 2; r := r + 1; end loop; return r;
  end function;
  constant IW : positive := clog2(ACC_N);

  type acc_t is array(0 to ACC_N-1) of signed(ACC_W-1 downto 0);
  signal acc   : acc_t := (others => (others => '0'));

  signal mode1 : unsigned(1 downto 0) := (others => '0');
  signal q_r   : signed(7 downto 0)  := (others => '0');
  signal k_r   : signed(15 downto 0) := (others => '0');
  signal p_r   : signed(12 downto 0) := (others => '0');
  signal v_r   : signed(7 downto 0)  := (others => '0');
  signal f_r   : signed(12 downto 0) := (others => '0');
  signal i_r   : unsigned(IW-1 downto 0) := (others => '0');
  signal i_r1  : unsigned(IW-1 downto 0) := (others => '0');

  signal a_mux : signed(ACC_W-1 downto 0) := (others => '0');
  signal b_mux : signed(15 downto 0)      := (others => '0');
  signal prod  : signed(ACC_W+16-1 downto 0) := (others => '0');

  signal rd    : signed(ACC_W-1 downto 0) := (others => '0');
  signal rd1   : signed(ACC_W-1 downto 0) := (others => '0');
  signal wdata : signed(ACC_W-1 downto 0) := (others => '0');
  signal score : signed(ACC_W-1 downto 0) := (others => '0');
  signal dig   : signed(31 downto 0) := (others => '0');
begin
  rd <= acc(to_integer(i_r));

  a_mux <= resize(q_r, ACC_W) when mode = "00" else
           resize(p_r, ACC_W) when mode = "01" else
           rd;
  b_mux <= k_r                when mode = "00" else
           resize(v_r, 16)    when mode = "01" else
           resize(f_r, 16);

  -- ONE adder, shared across both write modes.  See micro_c_lane_sh.vhd for
  -- what the per-entry form costs: 792 extra LUT in a 318 LUT lane.
  wdata <= rd1 + resize(prod, ACC_W)              when mode1 = "01" else
           resize(shift_right(prod, 12), ACC_W);

  process(clk)
  begin
    if rising_edge(clk) then
      mode1 <= mode;
      q_r <= signed(q_in);  k_r <= signed(k_in);
      p_r <= signed(q_in & q_in(4 downto 0));   -- probability, lane-private
      v_r <= signed(v_in);
      f_r <= signed(f_in);
      i_r <= unsigned(idx(IW-1 downto 0));
      i_r1 <= i_r;  rd1 <= rd;

      prod <= a_mux * b_mux;

      for i in 0 to ACC_N-1 loop
        if to_integer(i_r1) = i and (mode1 = "01" or mode1 = "10") then
          acc(i) <= wdata;
        end if;
      end loop;

      if mode1 = "00" then
        score <= resize(prod, ACC_W);
      end if;

      dig <= dig xor resize(prod, 32) xor resize(rd, 32)
                 xor resize(score, 32);
    end if;
  end process;
  digest <= std_logic_vector(dig);
end architecture;
