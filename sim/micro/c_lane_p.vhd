-- sim/micro/c_lane_p.vhd -- c_lane with the DSP48E2's OWN INPUT REGISTERS used.
--
-- The 8-lane routed run put the critical path here:
--
--   acc_reg[14][8]/C  ->  prod_reg/DSP_OUTPUT_INST/ALU_OUT[0]
--   logic 2.413 ns, net 0.864 ns, Fmax 294 MHz
--
-- i.e. accumulator -> 16:1 read mux -> 3:1 operand mux -> DSP multiply, all in
-- one cycle.  It is logic-dominated by nearly 3:1, so at that lane count the
-- limit is MUX DEPTH, not broadcast.  And the DSP census showed why the path
-- was allowed to get that long: prod0 reports AREG=0, BREG=0 -- the DSP48E2's
-- dedicated input registers were sitting idle, because c_lane drives the
-- multiplier from combinational muxes and registers only the product.
--
-- Those registers cost NOTHING in fabric: they are inside the DSP tile whether
-- used or not.  Registering the operand muxes therefore splits the path into
-- (accumulator -> muxes -> AREG/BREG) and (DSP multiply -> P) for free, at the
-- price of one cycle of latency that C's schedule can absorb.
--
-- Identical to c_lane in every other respect so the two are comparable.
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

entity c_lane_p is
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

architecture sizing of c_lane_p is
  -- LOCAL ON PURPOSE, NOT A COPY WAITING TO BE DELETED.  `work.util_pkg.clog2`
  -- is the same function, but the micro flow synthesises these files ONE AT A
  -- TIME with no package in the fileset -- `sim/run_micro.sh:27` passes
  -- `micro/micro_c_lane.vhd` alone and `sim/run_micro_pnr.sh:24` passes
  -- `micro/c_lane.vhd micro/micro_c_array.vhd`, and `sim/ooc_micro.tcl:59`
  -- reads exactly the files it is handed.  A `use work.util_pkg.clog2;` here
  -- would break every one of those runs.
  --
  -- THE BODY IS THE HALVING SHAPE NOW, NOT `v := v * 2`.  The doubling form
  -- needs `2**31` at n = 2**30 + 1 and leaves the integer type there; MEASURED
  -- by TRACK CLOG2 as `overflow detected` at exactly that threshold, and the
  -- same defect that `rtl/util_pkg.vhd` was fixed for at `209d69e`.  ACC_N is
  -- a lane count and has never been near 2**30, so this is a latent class and
  -- not a live bug -- recorded as such rather than dressed up.  The halving
  -- form only ever decreases, so no intermediate can leave `natural`.
  function clog2(n : positive) return natural is
    variable r : natural := 0; variable v : natural;
  begin
    if n <= 1 then return 0; end if;
    v := n - 1;
    while v > 0 loop r := r + 1; v := v / 2; end loop; return r;
  end function;
  constant IW : positive := clog2(ACC_N);

  type acc_t is array(0 to ACC_N-1) of signed(ACC_W-1 downto 0);
  signal acc   : acc_t := (others => (others => '0'));

  signal mode1 : unsigned(1 downto 0) := (others => '0');
  signal mode2 : unsigned(1 downto 0) := (others => '0');
  signal q_r   : signed(7 downto 0)  := (others => '0');
  signal k_r   : signed(15 downto 0) := (others => '0');
  signal p_r   : signed(12 downto 0) := (others => '0');
  signal v_r   : signed(7 downto 0)  := (others => '0');
  signal f_r   : signed(12 downto 0) := (others => '0');
  signal i_r   : unsigned(IW-1 downto 0) := (others => '0');
  signal i_r1  : unsigned(IW-1 downto 0) := (others => '0');
  signal i_r2  : unsigned(IW-1 downto 0) := (others => '0');

  signal a_mux : signed(ACC_W-1 downto 0) := (others => '0');
  signal b_mux : signed(15 downto 0)      := (others => '0');
  -- These two are the whole change.  They should land in the DSP's AREG/BREG,
  -- not in fabric FF -- check the census for AREG=1/BREG=1 before believing any
  -- Fmax improvement, because if they land in fabric the tile gained nothing
  -- and the LUT/FF cost went up for a pipeline stage bought at full price.
  signal a_reg : signed(ACC_W-1 downto 0) := (others => '0');
  signal b_reg : signed(15 downto 0)      := (others => '0');
  signal prod  : signed(ACC_W+16-1 downto 0) := (others => '0');

  signal rd    : signed(ACC_W-1 downto 0) := (others => '0');
  signal rd1   : signed(ACC_W-1 downto 0) := (others => '0');
  signal rd2   : signed(ACC_W-1 downto 0) := (others => '0');
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
  wdata <= rd2 + resize(prod, ACC_W)              when mode2 = "01" else
           resize(shift_right(prod, 12), ACC_W);

  process(clk)
  begin
    if rising_edge(clk) then
      mode1 <= mode;
      mode2 <= mode1;
      q_r <= signed(q_in);  k_r <= signed(k_in);
      p_r <= signed(q_in & q_in(4 downto 0));   -- probability, lane-private
      v_r <= signed(v_in);
      f_r <= signed(f_in);
      i_r <= unsigned(idx(IW-1 downto 0));
      i_r1 <= i_r;  rd1 <= rd;
      i_r2 <= i_r1; rd2 <= rd1;

      a_reg <= a_mux;
      b_reg <= b_mux;
      prod  <= a_reg * b_reg;

      for i in 0 to ACC_N-1 loop
        if to_integer(i_r2) = i and (mode2 = "01" or mode2 = "10") then
          acc(i) <= wdata;
        end if;
      end loop;

      if mode2 = "00" then
        score <= resize(prod, ACC_W);
      end if;

      dig <= dig xor resize(prod, 32) xor resize(rd, 32)
                 xor resize(score, 32);
    end if;
  end process;
  digest <= std_logic_vector(dig);
end architecture;
