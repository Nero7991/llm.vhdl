-- tools/clog2_equiv_tb.vhd -- teeth for util_pkg.clog2, TRACK CLOG2, 2026-08-29.
--
-- DELIBERATELY NOT under sim/ or tb/.  sim/regress.sh globs sim/tb_*.vhd and
-- tb/tb_*.vhd for gate rows and rtl,sim,sim/micro,tb/*.vhd for its analysis
-- closure; tools/ is in none of them, so this file cannot silently become a
-- permanent gate row.  Run it by hand:
--
--   mkdir -p /tmp/clog2 && ghdl -a --std=08 -frelaxed --workdir=/tmp/clog2 \
--     rtl/util_pkg.vhd tools/clog2_equiv_tb.vhd &&
--   ghdl -r --std=08 --workdir=/tmp/clog2 clog2_equiv_tb
--
-- What is checked, and against WHAT:
--
--  1. OLD vs NEW.  `clog2_old` below is a byte-for-byte copy of the doubling
--     body that shipped up to 8889cfa.  It is only ever called for
--     n <= 2**30, because above that it aborts the simulation -- which is the
--     defect.  Equivalence there is what makes the change safe for the ~78
--     files that already use clog2 to size address widths.
--  2. NEW vs an INDEPENDENT ORACLE.  `oracle_ok` does not loop at all: it
--     checks the defining inequality 2**(r-1) < n <= 2**r using 64-bit
--     unsigned shifts.  A shared bug between a halving loop and a doubling
--     loop is conceivable; a shared bug between either and a shift is not.
--  3. NEW natural vs NEW unsigned overload, over the same values.
--  4. The values that cannot be reached any other way: 2**30, 2**30+1,
--     natural'high, and the real 9B KV extent 6,803,283,968, which is beyond
--     `natural` entirely and exists only as an unsigned.
--
-- Exit is via `severity failure` on the first mismatch, plus a final PASS
-- line that names every count so a silently-empty run cannot read as a pass.

library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use work.util_pkg.all;

entity clog2_equiv_tb is end entity;

architecture tb of clog2_equiv_tb is

  -- Byte-for-byte the body that shipped up to 8889cfa.  Valid for n <= 2**30.
  function clog2_old(n : natural) return natural is
    variable r : natural := 0; variable v : natural := 1;
  begin
    while v < n loop v := v*2; r := r+1; end loop;
    return r;
  end function;

  -- INDEPENDENT ORACLE.  No loop, no accumulator: just the definition
  -- ceil(log2(n)) = the unique r with 2**(r-1) < n <= 2**r, for n >= 2,
  -- and r = 0 for n in {0,1}.  Evaluated with 64-bit shifts so nothing can
  -- overflow at any n in `natural`.
  function oracle_ok(n : natural; r : natural) return boolean is
    constant ONE : unsigned(63 downto 0) := to_unsigned(1, 64);
  begin
    if n <= 1 then return r = 0; end if;
    if r = 0 then return false; end if;
    if r > 63 then return false; end if;
    return shift_left(ONE, r) >= n and shift_left(ONE, r-1) < n;
  end function;

  -- Same, for a magnitude held as unsigned.
  function oracle_ok_u(u : unsigned; r : natural) return boolean is
    constant ONE : unsigned(127 downto 0) := to_unsigned(1, 128);
    variable uu  : unsigned(127 downto 0) := (others => '0');
  begin
    uu(u'length-1 downto 0) := u;
    if uu <= 1 then return r = 0; end if;
    if r = 0 or r > 127 then return false; end if;
    return shift_left(ONE, r) >= uu and shift_left(ONE, r-1) < uu;
  end function;

  -- Deterministic 64-bit LCG (Knuth MMIX constants).  Deterministic on
  -- purpose: a failing run must be replayable without capturing a seed.
  procedure lcg_next(variable s : inout unsigned(63 downto 0)) is
    constant A : unsigned(63 downto 0) := x"5851F42D4C957F2D";
    constant C : unsigned(63 downto 0) := x"14057B7EF767814F";
  begin
    s := resize(s * A, 64) + C;
  end procedure;

begin
  process
    variable r_new, r_old, r_u : natural;
    variable s                 : unsigned(63 downto 0) := x"0123456789ABCDEF";
    variable n                 : natural;
    variable u64               : unsigned(63 downto 0);
    variable n_exh, n_bnd, n_rnd, n_uns : natural := 0;
    variable k                 : natural;
  begin

    ------------------------------------------------------------------------
    -- 1. EXHAUSTIVE 0 .. 2**21.  Every n, three ways.
    ------------------------------------------------------------------------
    for i in 0 to 2097152 loop
      r_new := clog2(i);
      r_old := clog2_old(i);
      r_u   := clog2(to_unsigned(i, 32));
      assert r_new = r_old
        report "EXH old/new mismatch at n=" & integer'image(i)
             & " old=" & integer'image(r_old) & " new=" & integer'image(r_new)
        severity failure;
      assert oracle_ok(i, r_new)
        report "EXH oracle mismatch at n=" & integer'image(i)
             & " new=" & integer'image(r_new)
        severity failure;
      assert r_u = r_new
        report "EXH unsigned/natural mismatch at n=" & integer'image(i)
             & " uns=" & integer'image(r_u) & " nat=" & integer'image(r_new)
        severity failure;
      n_exh := n_exh + 1;
    end loop;
    report "EXHAUSTIVE 0..2**21 ok, " & integer'image(n_exh) & " values";

    ------------------------------------------------------------------------
    -- 2. BOUNDARIES 2**k-1, 2**k, 2**k+1 for k = 0 .. 30, and the three
    --    values at the top of `natural` that the old body cannot reach.
    ------------------------------------------------------------------------
    for kk in 0 to 30 loop
      k := kk;
      for d in -1 to 1 loop
        n := 2**k + d;
        if n >= 0 then
          r_new := clog2(n);
          r_u   := clog2(to_unsigned(n, 32));
          assert oracle_ok(n, r_new)
            report "BND oracle mismatch at n=" & integer'image(n)
                 & " new=" & integer'image(r_new) severity failure;
          assert r_u = r_new
            report "BND unsigned mismatch at n=" & integer'image(n)
            severity failure;
          -- The old body is only defined up to 2**30.
          if n <= 1073741824 then
            r_old := clog2_old(n);
            assert r_new = r_old
              report "BND old/new mismatch at n=" & integer'image(n)
                   & " old=" & integer'image(r_old)
                   & " new=" & integer'image(r_new) severity failure;
          end if;
          n_bnd := n_bnd + 1;
        end if;
      end loop;
    end loop;
    report "BOUNDARIES 2**k-1/2**k/2**k+1, k=0..30 ok, "
         & integer'image(n_bnd) & " values";

    ------------------------------------------------------------------------
    -- 3. THE FOUR VALUES THE BRIEF NAMES.  Stated one at a time so the log
    --    carries the answers and not merely a pass.
    ------------------------------------------------------------------------
    assert clog2(1073741824) = 30
      report "2**30 wrong" severity failure;
    report "2**30      = 1073741824 -> clog2 = " & integer'image(clog2(1073741824))
         & "  (old body: LAST VALUE IT SURVIVES)";
    assert clog2(1073741825) = 31
      report "2**30+1 wrong" severity failure;
    report "2**30+1    = 1073741825 -> clog2 = " & integer'image(clog2(1073741825))
         & "  (old body: overflow, elaboration aborted)";
    assert clog2(2147483647) = 31
      report "natural'high wrong" severity failure;
    report "natural'high = 2147483647 -> clog2 = " & integer'image(clog2(2147483647))
         & "  (old body: overflow, elaboration aborted)";
    assert clog2(natural'high) = 31 report "natural'high attr wrong" severity failure;

    ------------------------------------------------------------------------
    -- 4. THE REAL VALUE THAT BROKE IT.  6,803,283,968 bytes is beyond
    --    `natural` (2,147,483,647) by a factor of three, so it exists only
    --    as an unsigned.  DERIVED: the subsystem C KV extent is
    --      max(C_K_BASE, C_V_BASE) + C_LAY*C_NKVH*C_MAXPOS*REC_B_C
    --      = 4,521,582,592 + 131,072 * 17,408
    --      = 4,521,582,592 + 2,281,701,376
    --      = 6,803,283,968
    --    and 2**32 = 4,294,967,296 < 6,803,283,968 <= 8,589,934,592 = 2**33,
    --    so the answer must be 33, which is exactly C_KV_ADDR_W.
    ------------------------------------------------------------------------
    -- Every literal below fits `integer`; the PRODUCTS do not, which is
    -- exactly why they are formed in unsigned.  17408 = C_LAY*C_NKVH*REC_B_C,
    -- DERIVED from the bisect: 61680 passes and 61681 fails, and
    -- 61680*17408 = 1073725440 <= 2**30 < 1073742848 = 61681*17408.
    -- MEASURED trap, 2026-08-29: numeric_std's "*"(UNSIGNED, NATURAL) returns
    -- 2*L'LENGTH bits, not L'LENGTH.  `u64 := to_unsigned(131072,64)*17408`
    -- is a bound check failure, not a truncation and not a compile error.
    -- Either resize as here, or feed the product straight to clog2, which
    -- takes an unsigned of any width.
    u64 := resize(to_unsigned(131072, 64) * 17408, 64);  -- KVREG_B = 2281701376
    report "KVREG_B    = x" & to_hstring(std_logic_vector(u64));
    u64 := u64 + resize(to_unsigned(4415608, 64) * 1024, 64);  -- + 4521582592
    report "KV extent  = x" & to_hstring(std_logic_vector(u64));
    r_u := clog2(u64);
    -- and the same answer without any resize at all, straight from the product
    assert clog2(to_unsigned(131072, 64) * 17408
                 + resize(to_unsigned(4415608, 64) * 1024, 128)) = 33
      report "REAL unresized form disagrees" severity failure;
    assert oracle_ok_u(u64, r_u)
      report "REAL oracle mismatch, r=" & integer'image(r_u) severity failure;
    assert r_u = 33
      report "REAL KV extent: expected clog2 = 33, got " & integer'image(r_u)
      severity failure;
    report "REAL 9B KV extent 6803283968 -> clog2 = " & integer'image(r_u)
         & "  (C_KV_ADDR_W = 33, zero slack)";

    -- and the two neighbours of 2**33, to show the boundary is not luck
    assert clog2(shift_left(to_unsigned(1, 64), 33)) = 33
      report "1<<33 wrong" severity failure;
    assert clog2(shift_left(to_unsigned(1, 64), 33) + 1) = 34
      report "1<<33+1 wrong" severity failure;
    assert clog2(shift_left(to_unsigned(1, 64), 33) - 1) = 33
      report "1<<33-1 wrong" severity failure;
    report "2**33-1 -> 33, 2**33 -> 33, 2**33+1 -> 34";

    -- null range and all-zero
    assert clog2(to_unsigned(0, 64)) = 0 report "unsigned 0 wrong" severity failure;

    ------------------------------------------------------------------------
    -- 4b. VECTORS WHOSE TOP BIT IS SET, AND NULL RANGES.
    --
    -- ADDED after a mutation run, 2026-08-29.  Two mutants of clog2(unsigned)
    -- did NOT bite the first version of this bench:
    --   U4  `for i in 0 to uu'high loop` -> `uu'high-1`   (drop the top bit)
    --   U5  the u'length = 0 branch returning 1 instead of 0
    -- Both survived because every unsigned fed in above is either
    -- to_unsigned(n,32) with n <= 2**31-1 (bit 31 always clear) or a 64-bit
    -- value under 2**34 (bit 63 always clear), and no null range was ever
    -- passed.  Coverage of the VALUE space was not coverage of the VECTOR
    -- space.  The two loops below close it: every width 1..13 exhaustively,
    -- which makes the top bit set in half of all cases, plus the 64-bit
    -- top-bit values and a genuine null slice.
    ------------------------------------------------------------------------
    for w in 1 to 13 loop
      for v in 0 to 2**w - 1 loop
        assert clog2(to_unsigned(v, w)) = clog2(v)
          report "WIDTH mismatch w=" & integer'image(w)
               & " v=" & integer'image(v)
               & " uns=" & integer'image(clog2(to_unsigned(v, w)))
               & " nat=" & integer'image(clog2(v)) severity failure;
        n_uns := n_uns + 1;
      end loop;
    end loop;
    assert clog2(shift_left(to_unsigned(1, 64), 63)) = 63
      report "1<<63 wrong" severity failure;
    assert clog2(shift_left(to_unsigned(1, 64), 63) + 1) = 64
      report "1<<63+1 wrong" severity failure;
    assert clog2(not to_unsigned(0, 64)) = 64
      report "all-ones 64 wrong" severity failure;
    -- MY OWN EXPECTATION WAS WRONG HERE FIRST TIME, kept as a note: a 1-bit
    -- all-ones vector is the VALUE 1, and clog2(1) is 0, not 1.  Width is not
    -- the answer; the value is.
    assert clog2(not to_unsigned(0, 1)) = 0
      report "all-ones 1 wrong" severity failure;
    assert clog2(not to_unsigned(0, 2)) = 2
      report "all-ones 2 wrong" severity failure;
    assert clog2(u64(0 downto 1)) = 0
      report "null-range unsigned wrong" severity failure;
    report "WIDTH SWEEP w=1..13 exhaustive ok, " & integer'image(n_uns)
         & " values; top-bit-set 64-bit and null range ok";
    n_uns := 0;

    ------------------------------------------------------------------------
    -- 5. RANDOM SWEEP over the FULL `natural` range, 2**20 draws.
    --    Above 2**30 the old body cannot be consulted, so the oracle is the
    --    only witness there -- which is the whole point of having one.
    ------------------------------------------------------------------------
    for i in 1 to 1048576 loop
      lcg_next(s);
      n     := to_integer(s(30 downto 0));   -- 0 .. 2147483647
      r_new := clog2(n);
      r_u   := clog2(to_unsigned(n, 32));
      assert oracle_ok(n, r_new)
        report "RND oracle mismatch at n=" & integer'image(n)
             & " new=" & integer'image(r_new) severity failure;
      assert r_u = r_new
        report "RND unsigned mismatch at n=" & integer'image(n) severity failure;
      if n <= 1073741824 then
        r_old := clog2_old(n);
        assert r_new = r_old
          report "RND old/new mismatch at n=" & integer'image(n)
               & " old=" & integer'image(r_old)
               & " new=" & integer'image(r_new) severity failure;
        n_uns := n_uns + 1;
      end if;
      n_rnd := n_rnd + 1;
    end loop;
    report "RANDOM full-range ok, " & integer'image(n_rnd) & " draws, "
         & integer'image(n_uns) & " of them also checked against the old body";

    report "CLOG2 EQUIV: PASS  exhaustive=" & integer'image(n_exh)
         & " boundary=" & integer'image(n_bnd)
         & " random=" & integer'image(n_rnd);
    wait;
  end process;
end architecture;
