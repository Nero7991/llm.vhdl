-- sim/micro/micro_c_lane_sh.vhd -- micro_c_lane with ONE shared accumulator adder.
--
-- The naive lane (micro_c_lane.vhd) writes the read-modify-write as
--
--     for i in 0 to ACC_N-1 loop
--       if to_integer(i_r) = i then acc(i) <= acc(i) + prod; end if;
--     end loop;
--
-- which is the obvious way to say it and the way anyone would write it first.
-- Vivado does NOT share the adder across the branches: it built SIXTEEN 36-bit
-- adders, one per entry, 80 CARRY8 in a lane that needs 5.  Only one branch can
-- ever be active, so the hardware is pure waste -- but it is waste the tool
-- will not remove on its own, because sharing it means proving the enables are
-- one-hot, and synthesis does not attempt that.
--
-- This variant does the sharing by hand: read through the mux that already
-- exists, add ONCE, write the single result back under a decoded enable.  The
-- delta between the two files is the price of the coding discipline, and it is
-- the number that belongs in C's LUT budget -- quoting the naive figure would
-- inflate the subsystem by whatever the delta turns out to be, times 192-288
-- lanes.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity micro_c_lane_sh is
  generic(
    ACC_N : positive := 16;
    ACC_W : positive := 36
  );
  port(
    clk    : in  std_logic;
    q_in   : in  std_logic_vector(7 downto 0);
    k_in   : in  std_logic_vector(15 downto 0);
    p_in   : in  std_logic_vector(12 downto 0);
    v_in   : in  std_logic_vector(7 downto 0);
    f_in   : in  std_logic_vector(12 downto 0);
    idx    : in  std_logic_vector(7 downto 0);   -- widest; only clog2(ACC_N) used
    digest : out std_logic_vector(31 downto 0)
  );
end entity;

architecture sizing of micro_c_lane_sh is
  -- ACC_N is swept, so the index width has to follow it rather than being
  -- hardcoded.  A fixed-width index would leave dead decode logic in the small
  -- configurations and understate how the file scales.
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

  signal cnt   : unsigned(1 downto 0) := (others => '0');
  signal mode  : unsigned(1 downto 0) := (others => '0');
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

  -- THE one adder.  Both write modes fold into a single 36-bit add whose
  -- addend is muxed, so the entry index reaches only the write enables.
  wdata <= rd1 + resize(prod, ACC_W)              when mode1 = "01" else
           resize(shift_right(prod, 12), ACC_W);

  process(clk)
  begin
    if rising_edge(clk) then
      cnt  <= cnt + 1;
      mode <= cnt;
      mode1 <= mode;

      q_r <= signed(q_in);  k_r <= signed(k_in);
      p_r <= signed(p_in);  v_r <= signed(v_in);
      f_r <= signed(f_in);  i_r <= unsigned(idx(IW-1 downto 0));
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
