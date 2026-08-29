-- sim/tb_stmem_equiv.vhd -- TRACK REALFIX, 2026-08-29.
--
-- IS `stmem` AS A PROCESS VARIABLE THE SAME MEMORY AS `stmem` AS A SIGNAL?
--
-- WHY THIS EXISTS.  `rtl/llama_top.vhd` modelled subsystem B's per-layer
-- recurrent state as a SIGNAL array of 201,326,592 scalars.  ghdl-mcode costs
-- ~228 bytes per scalar signal, so that one declaration wanted ~46 GB and
-- `ghdl -r llama_top` with NO generic overrides -- which is the REAL 9B shape,
-- because `mk_shape(MODEL, NCARDS)` is that file's own default -- died with
-- STORAGE_ERROR at 24.9 GB.  The same bits as a process variable cost 206 MB.
-- TRACK REALSHAPE measured all of that and explicitly did NOT establish that
-- the conversion is legal or behaviour-preserving: its probe SHRANK the array
-- rather than converting it.
--
-- WHAT THE CONVERSION CAN CHANGE, and it is exactly one thing.  `stmem` had
-- two accesses in the whole file, both inside one clocked process, and no
-- concurrent statement read it, so visibility and scheduling are not at issue.
-- What IS at issue is READ-DURING-WRITE at the same address on the same edge:
--
--   signal    the read always sees the PRE-EDGE value, whatever the statement
--             order, because the write is not applied until the next delta.
--   variable  the statement order IS the policy.  Read-then-write reproduces
--             the signal.  Write-then-read does not: it is a different memory.
--
-- So this bench runs THREE memories against ONE stimulus stream:
--
--   A  the original: a SIGNAL array, write block then read block.
--   B  the shipped form: a VARIABLE array, READ block then write block.
--   C  THE NEGATIVE CONTROL: a VARIABLE array, write block then read block.
--
-- A vs B is the equivalence claim.  A vs C is the TEETH: if C never differs
-- from A, this bench cannot tell the two orderings apart and the A-vs-B result
-- would be worth nothing.  The verdict therefore requires BOTH `A = B on every
-- cycle` AND `A /= C on at least one cycle`.
--
-- STIMULUS.  A deterministic LCG drives read enable, write enable, both
-- addresses and the data.  Addresses are drawn from a SMALL space and one
-- cycle in two forces `raddr = waddr`, because a uniform draw over the real
-- address space would make a same-address collision vanishingly rare and the
-- control would then pass by never being exercised -- the failure mode this
-- project files under "coverage of the input space is not coverage of the
-- output space".  The forced-collision count is printed.
--
-- NOT A VALUE TEST OF SUBSYSTEM B.  It says nothing about what the recurrent
-- state should CONTAIN.  It is an equivalence proof for one code
-- transformation, which is the question that was open.
--
-- docs/debugging/2026-08-29_realfix-9b-shape.md

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_stmem_equiv is
end entity;

architecture tb of tb_stmem_equiv is

  constant W      : positive := 64;      -- word width, as B_RECUR_LANES*16
  constant DEPTH  : positive := 64;      -- small, so collisions are reachable
  constant CYCLES : positive := 20000;

  type mem_t is array (0 to DEPTH-1) of std_logic_vector(W-1 downto 0);

  signal clk : std_logic := '0';
  signal run : boolean := true;

  -- the one stimulus stream, driven by the generator process
  signal s_ren, s_wen : std_logic := '0';
  signal s_ra, s_wa   : integer range 0 to DEPTH-1 := 0;
  signal s_wd         : std_logic_vector(W-1 downto 0) := (others => '0');

  -- the three read ports
  signal rq_a, rq_b, rq_c : std_logic_vector(W-1 downto 0) := (others => '0');

  -- the signal-form memory lives at architecture level, as the original did
  signal mem_a : mem_t := (others => (others => '0'));

  signal n_coll   : natural := 0;   -- forced same-address read+write cycles
  signal n_ab     : natural := 0;   -- cycles where A and B disagree
  signal n_ac     : natural := 0;   -- cycles where A and C disagree
  signal n_cmp    : natural := 0;   -- cycles actually compared

  -- One LCG, so the stream is a function of the cycle index and nothing else.
  function lcg(s : unsigned(31 downto 0)) return unsigned is
    variable t : unsigned(63 downto 0);
  begin
    t := s * to_unsigned(1103515245, 32) + to_unsigned(12345, 32);
    return t(31 downto 0);
  end function;

begin

  clk <= not clk after 5 ns when run else '0';

  -- ---- the stimulus ------------------------------------------------------
  gen_p : process(clk) is
    variable s : unsigned(31 downto 0) := to_unsigned(1, 32);
    variable n : natural := 0;
  begin
    if rising_edge(clk) then
      if n < CYCLES then
        s := lcg(s);  s_ren <= s(0);
        s := lcg(s);  s_wen <= s(1);
        s := lcg(s);  s_wa  <= to_integer(s(15 downto 0)) mod DEPTH;
        -- HALF THE CYCLES FORCE THE COLLISION.  Without this the control
        -- below would pass by never being exercised.
        if s(16) = '1' then
          s_ra  <= to_integer(s(15 downto 0)) mod DEPTH;
          n_coll <= n_coll + 1;
        else
          s := lcg(s);
          s_ra <= to_integer(s(15 downto 0)) mod DEPTH;
        end if;
        s := lcg(s);
        s_wd <= std_logic_vector(resize(s, W));
        n := n + 1;
      else
        s_ren <= '0'; s_wen <= '0';
      end if;
    end if;
  end process;

  -- ---- A: the ORIGINAL.  A signal array; the write block came first, and
  --         for a signal that ordering is not observable.
  mem_a_p : process(clk) is
    variable a : integer;
  begin
    if rising_edge(clk) then
      if s_wen = '1' then
        a := s_wa;
        mem_a(a) <= s_wd;
      end if;
      if s_ren = '1' then
        a := s_ra;
        rq_a <= mem_a(a);
      end if;
    end if;
  end process;

  -- ---- B: THE SHIPPED FORM.  A process variable, READ BEFORE WRITE.
  mem_b_p : process(clk) is
    variable a   : integer;
    variable mem : mem_t := (others => (others => '0'));
  begin
    if rising_edge(clk) then
      if s_ren = '1' then
        a := s_ra;
        rq_b <= mem(a);
      end if;
      if s_wen = '1' then
        a := s_wa;
        mem(a) := s_wd;
      end if;
    end if;
  end process;

  -- ---- C: THE NEGATIVE CONTROL.  A process variable, WRITE BEFORE READ.
  --         This is what a mechanical `<=` to `:=` edit that kept the
  --         original statement order would have produced, and it is a
  --         write-first memory rather than the read-first one A is.
  mem_c_p : process(clk) is
    variable a   : integer;
    variable mem : mem_t := (others => (others => '0'));
  begin
    if rising_edge(clk) then
      if s_wen = '1' then
        a := s_wa;
        mem(a) := s_wd;
      end if;
      if s_ren = '1' then
        a := s_ra;
        rq_c <= mem(a);
      end if;
    end if;
  end process;

  -- ---- the comparison ----------------------------------------------------
  cmp_p : process(clk) is
  begin
    if falling_edge(clk) then
      n_cmp <= n_cmp + 1;
      if rq_a /= rq_b then n_ab <= n_ab + 1; end if;
      if rq_a /= rq_c then n_ac <= n_ac + 1; end if;
    end if;
  end process;

  -- ---- the verdict -------------------------------------------------------
  fin_p : process is
    variable ok : boolean := true;
  begin
    wait for 10 ns * (CYCLES + 64);
    run <= false;
    wait for 1 ns;

    report "tb_stmem_equiv: cycles compared " & integer'image(n_cmp)
         & ", forced same-address collisions " & integer'image(n_coll);
    report "tb_stmem_equiv: A(signal) vs B(variable, read-first) differing "
         & "cycles = " & integer'image(n_ab) & " (must be 0)";
    report "tb_stmem_equiv: A(signal) vs C(variable, write-first) differing "
         & "cycles = " & integer'image(n_ac) & " (must be > 0, this is the "
         & "resolution check)";

    if n_ab /= 0 then
      ok := false;
      report "tb_stmem_equiv: the variable form is NOT the signal form"
        severity error;
    end if;
    if n_ac = 0 then
      ok := false;
      report "tb_stmem_equiv: the control never differed, so this bench "
           & "cannot tell read-first from write-first and the equivalence "
           & "result above is worthless" severity error;
    end if;
    if n_coll = 0 then
      ok := false;
      report "tb_stmem_equiv: no same-address collision was ever generated"
        severity error;
    end if;

    if ok then
      report "STMEM EQUIV: PASS -- the process-variable read-first form is "
           & "cycle-identical to the signal form over " & integer'image(n_cmp)
           & " cycles, and the write-first control differs on "
           & integer'image(n_ac) & " of them.";
    else
      report "STMEM EQUIV: FAIL" severity failure;
    end if;
    wait;
  end process;

end architecture;
