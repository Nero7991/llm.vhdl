-- sim/micro/micro_c_array.vhd -- LANES copies of c_lane, to price the BROADCAST.
--
-- WHY THIS EXISTS.  The single-lane run measured 328.6 MHz, and that number is
-- not subsystem C's.  One lane has no fanout.  In the real engine the control
-- nets reach every lane and the rescale factor spans a whole head, and it is
-- those nets -- not the lane arithmetic, which clears 300 MHz with room -- that
-- will set the achievable clock.  Subsystem A closed at only 276 MHz on this
-- same part and grade at ROWS_IF=48, so there is direct evidence that this
-- device does not hand out 300 MHz merely because the datapath is short.
--
-- THE SHARING IS MODELLED, NOT ASSUMED GLOBAL.  Wiring every operand to every
-- lane would manufacture a fanout problem and then discover it.  C organises
-- its MACs as HEADS query heads x DIMS dims (C 2.6: "4 query heads x 16 dims
-- per cycle" at MACS=64), so lane i sits at head = i/DIMS, dim = i mod DIMS,
-- and each operand fans out exactly as far as that geometry says:
--
--   q  private per lane          fanout 1
--   k  indexed by dim            fanout HEADS       (4)
--   v  indexed by dim            fanout HEADS       (4)
--   f  indexed by head           fanout DIMS        (LANES/4)
--   mode, idx  control           fanout LANES       <-- the ones under test
--
-- So the honest prediction going in is that the DATA nets are not the problem
-- (4-way) and the CONTROL nets are (LANES-way), with f in between and growing.
-- If Fmax turns out flat across the sweep, the broadcast is a non-issue and C
-- can be clocked from the lane number; if it falls, the fall IS the answer.
--
-- ACC_N IS HELD FIXED at 16 across the sweep, on purpose.  The real file is a
-- fixed 1,024 entries, so a physical design would shrink ACC_N as LANES grows
-- and the two effects would move together and be inseparable.  Holding it makes
-- LANES the only variable, and the LANES=64 point is simultaneously the
-- controlled point and the real MACS=64 geometry (64 x 16 = 1,024 exactly).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity micro_c_array is
  generic(
    LANES : positive := 64;
    HEADS : positive := 4;
    ACC_N : positive := 16
  );
  port(
    clk    : in  std_logic;
    idx    : in  std_logic_vector(7 downto 0);                 -- broadcast
    q_all  : in  std_logic_vector(8*LANES-1 downto 0);         -- private
    k_all  : in  std_logic_vector(16*(LANES/HEADS)-1 downto 0);-- per dim
    v_all  : in  std_logic_vector(8*(LANES/HEADS)-1 downto 0); -- per dim
    f_all  : in  std_logic_vector(13*HEADS-1 downto 0);        -- per head
    digest : out std_logic_vector(31 downto 0)
  );
end entity;

architecture sizing of micro_c_array is
  constant DIMS : positive := LANES / HEADS;

  function nlvl(n : positive) return positive is
    variable r : natural := 0; variable v : positive := n;
  begin
    while v > 1 loop v := (v + 3) / 4; r := r + 1; end loop;
    if r = 0 then return 1; else return r; end if;
  end function;
  constant MAXLVL : positive := nlvl(LANES);

  type dvec is array(natural range <>) of std_logic_vector(31 downto 0);
  type dmat is array(0 to MAXLVL) of dvec(0 to LANES-1);
  signal red : dmat := (others => (others => (others => '0')));

  -- The mode counter is generated ONCE here and broadcast, which is both the
  -- real structure and the thing that makes time-sharing unprovable to
  -- synthesis.  A per-lane counter would let Vivado fold the mux select into
  -- each lane locally and quietly delete the very net being measured.
  signal cnt  : unsigned(1 downto 0) := (others => '0');
  signal mode : unsigned(1 downto 0) := (others => '0');
begin
  process(clk)
  begin
    if rising_edge(clk) then
      cnt  <= cnt + 1;
      mode <= cnt;
    end if;
  end process;

  g_lane : for i in 0 to LANES-1 generate
    -- head = i/DIMS, dim = i mod DIMS.  These slices ARE the fanout model:
    -- every lane in a head sees the same f_all slice, every lane at a dim sees
    -- the same k/v slice, and no two lanes share a q slice.
    constant H : natural := i / DIMS;
    constant D : natural := i mod DIMS;
  begin
    u : entity work.c_lane
      generic map(ACC_N => ACC_N)
      port map(
        clk    => clk,
        mode   => mode,
        idx    => idx,
        q_in   => q_all(8*i + 7 downto 8*i),
        k_in   => k_all(16*D + 15 downto 16*D),
        v_in   => v_all(8*D + 7 downto 8*D),
        f_in   => f_all(13*H + 12 downto 13*H),
        digest => red(0)(i));
  end generate;

  -- Registered 4-to-1 XOR reduction of every lane's digest.
  --
  -- It has to be here or synthesis prunes all but one lane: LANES copies whose
  -- outputs go nowhere is LANES copies of dead logic.  It has to be REGISTERED
  -- at every level because an unregistered tree would be 3 to 5 LUT levels deep
  -- at LANES=64 and would become the critical path, which would answer a
  -- question about an XOR tree rather than about the broadcast.  Four inputs
  -- per level so each level is a single LUT6.
  process(clk)
    variable nsrc, ndst : natural;
    variable acc32 : std_logic_vector(31 downto 0);
  begin
    if rising_edge(clk) then
      nsrc := LANES;
      for l in 0 to MAXLVL-1 loop
        ndst := (nsrc + 3) / 4;
        for j in 0 to LANES-1 loop
          if j < ndst then
            acc32 := (others => '0');
            for m in 0 to 3 loop
              if 4*j + m < nsrc then
                acc32 := acc32 xor red(l)(4*j + m);
              end if;
            end loop;
            red(l+1)(j) <= acc32;
          end if;
        end loop;
        nsrc := ndst;
      end loop;
    end if;
  end process;

  digest <= red(MAXLVL)(0);
end architecture;
