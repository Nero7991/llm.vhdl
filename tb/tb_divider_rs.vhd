-- tb/tb_divider_rs.vhd
-- Standalone exactness testbench for rtl/divider_rs.vhd.
--
-- Proves q = floor(a/b) BIT-EXACTLY over:
--   * the two REAL failing operand pairs measured on silicon (the whole reason
--     this unit exists):
--       2,465,074,253,122 / 6,788 -> 363,151,775   (HW '/' gave 363,118,079)
--       4,309,152,434,643 / 5,031 -> 856,520,062   (HW '/' gave 536,802,267)
--   * edge cases: a=0, b=1, a<b, a=2^NW-1, b=2^DW-1, b=1 with a huge, exact
--     multiples, powers of two, a=b, a=b-1, a=b+1
--   * a pseudo-random sweep of pairs inside the NW/DW bounds.
-- The reference is computed in the testbench with unsigned '/' (GHDL evaluates
-- it correctly -- it is only Vivado SYNTHESIS of '/' that is untrustworthy).
--
-- Run:  ghdl -i --std=08 --workdir=W ../rtl/divider_rs.vhd tb_divider_rs.vhd
--       ghdl -m --std=08 --workdir=W tb_divider_rs
--       ghdl -r --std=08 --workdir=W tb_divider_rs

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_divider_rs is end entity;

architecture sim of tb_divider_rs is
  constant NW : positive := 52;
  constant DW : positive := 24;

  signal clk   : std_logic := '0';
  signal rst   : std_logic := '1';
  signal start : std_logic := '0';
  signal num   : std_logic_vector(NW-1 downto 0) := (others => '0');
  signal den   : std_logic_vector(DW-1 downto 0) := (others => '0');
  signal busy  : std_logic;
  signal done  : std_logic;
  signal quo   : std_logic_vector(NW-1 downto 0);

  signal running : boolean := true;

  signal npass : integer := 0;
  signal nfail : integer := 0;

  component divider_rs is
    generic(NW : positive; DW : positive);
    port(clk   : in  std_logic;
         rst   : in  std_logic;
         start : in  std_logic;
         num   : in  std_logic_vector(NW-1 downto 0);
         den   : in  std_logic_vector(DW-1 downto 0);
         busy  : out std_logic;
         done  : out std_logic;
         quo   : out std_logic_vector(NW-1 downto 0));
  end component;
begin
  clk <= not clk after 5 ns when running else '0';

  uut : divider_rs generic map(NW => NW, DW => DW)
    port map(clk => clk, rst => rst, start => start,
             num => num, den => den, busy => busy, done => done, quo => quo);

  stim : process
    variable pass_v : integer := 0;
    variable fail_v : integer := 0;
    -- xorshift-ish LCG state for the randomised sweep (deterministic)
    variable rnd    : unsigned(63 downto 0) := x"0123456789ABCDEF";

    procedure next_rnd is
    begin
      rnd := rnd xor shift_left(rnd, 13);
      rnd := rnd xor shift_right(rnd, 7);
      rnd := rnd xor shift_left(rnd, 17);
    end procedure;

    procedure check(a : unsigned(NW-1 downto 0);
                    b : unsigned(DW-1 downto 0);
                    tag : string) is
      variable expq : unsigned(NW-1 downto 0);
      variable gotq : unsigned(NW-1 downto 0);
    begin
      expq := a / resize(b, NW);
      num   <= std_logic_vector(a);
      den   <= std_logic_vector(b);
      start <= '1';
      wait until rising_edge(clk);
      start <= '0';
      -- wait for the done pulse
      loop
        wait until rising_edge(clk);
        exit when done = '1';
      end loop;
      gotq := unsigned(quo);
      if gotq = expq then
        pass_v := pass_v + 1;
      else
        fail_v := fail_v + 1;
        report "FAIL " & tag &
               "  a=" & integer'image(to_integer(a(30 downto 0))) &
               " (full hex " & to_hstring(a) & ")" &
               "  b=" & integer'image(to_integer(b)) &
               "  got=" & to_hstring(gotq) &
               "  exp=" & to_hstring(expq) severity error;
      end if;
      npass <= pass_v;
      nfail <= fail_v;
    end procedure;

    variable a : unsigned(NW-1 downto 0);
    variable b : unsigned(DW-1 downto 0);
  begin
    rst <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    ----------------------------------------------------------------
    -- 1) THE TWO REAL SILICON-FAILING PAIRS
    ----------------------------------------------------------------
    -- lane 1 (hd0/t1): 2465074253122 / 6788 = 363151775
    a := to_unsigned(0, NW); b := to_unsigned(0, DW);
    a := resize(unsigned'(x"23DF1E00D42"), NW);   -- 2,465,074,253,122
    b := to_unsigned(6788, DW);
    check(a, b, "REAL-lane1");
    assert (a / resize(b, NW)) = to_unsigned(363151775, NW)
      report "tb self-check: lane1 reference is not 363151775" severity failure;

    -- lane 63 (hd7/t7): 4309152434643 / 5031 = 856520062
    a := resize(unsigned'(x"3EB4D8009D3"), NW);   -- 4,309,152,434,643
    b := to_unsigned(5031, DW);
    check(a, b, "REAL-lane63");
    assert (a / resize(b, NW)) = to_unsigned(856520062, NW)
      report "tb self-check: lane63 reference is not 856520062" severity failure;

    ----------------------------------------------------------------
    -- 2) EDGE CASES
    ----------------------------------------------------------------
    check(to_unsigned(0, NW),  to_unsigned(1, DW),          "a=0,b=1");
    check(to_unsigned(0, NW),  to_unsigned(12345, DW),      "a=0,b=12345");
    check(to_unsigned(1, NW),  to_unsigned(1, DW),          "a=1,b=1");
    check(to_unsigned(7, NW),  to_unsigned(9, DW),          "a<b");
    check(to_unsigned(8, NW),  to_unsigned(9, DW),          "a=b-1");
    check(to_unsigned(9, NW),  to_unsigned(9, DW),          "a=b");
    check(to_unsigned(10, NW), to_unsigned(9, DW),          "a=b+1");
    -- a = 2^NW-1 (all ones) with b = 1, b = 2^DW-1, and b = 3
    a := (others => '1');
    check(a, to_unsigned(1, DW),                            "a=2^52-1,b=1");
    b := (others => '1');
    check(a, b,                                             "a=2^52-1,b=2^24-1");
    check(a, to_unsigned(3, DW),                            "a=2^52-1,b=3");
    -- b = 2^DW-1 with a small / exact multiple
    b := (others => '1');
    check(to_unsigned(16777214, NW), b,                     "a=b-1 (24b)");
    check(resize(resize(b, NW) * to_unsigned(1000, NW), NW), b, "exact multiple");
    check(resize(resize(b, NW) * to_unsigned(1000, NW), NW) + to_unsigned(1, NW), b,
          "exact multiple+1");
    -- b = 1 with a huge
    check(resize(unsigned'(x"3EB4D8009D3"), NW), to_unsigned(1, DW), "b=1,a=huge");
    -- powers of two, both operands
    for k in 0 to NW-1 loop
      a := (others => '0'); a(k) := '1';
      check(a, to_unsigned(1024, DW), "pow2 a=2^" & integer'image(k) & ",b=1024");
    end loop;
    for k in 0 to DW-1 loop
      b := (others => '0'); b(k) := '1';
      check(resize(unsigned'(x"23DF1E00D42"), NW), b,
            "pow2 b=2^" & integer'image(k));
    end loop;
    -- realistic engine regime: nmag ~ 2^41, sum_l in 4096..16384
    for k in 0 to 15 loop
      check(resize(unsigned'(x"23DF1E00D42"), NW) + to_unsigned(k*7919, NW),
            to_unsigned(4096 + k*751, DW), "regime k=" & integer'image(k));
    end loop;

    ----------------------------------------------------------------
    -- 3) RANDOMISED SWEEP inside the NW/DW bounds
    ----------------------------------------------------------------
    for k in 0 to 299 loop
      next_rnd;
      a := resize(rnd(NW-1 downto 0), NW);
      next_rnd;
      b := rnd(DW-1 downto 0);
      if b = 0 then b := to_unsigned(1, DW); end if;
      check(a, b, "rand" & integer'image(k));
    end loop;
    -- second sweep biased to the real operand regime (dividend <= 2^45,
    -- divisor 2^12..2^17) so the realistic range is densely covered
    for k in 0 to 199 loop
      next_rnd;
      a := resize(rnd(44 downto 0), NW);
      next_rnd;
      b := resize(to_unsigned(4096, DW) + resize(rnd(16 downto 0), DW), DW);
      if b = 0 then b := to_unsigned(1, DW); end if;
      check(a, b, "randreg" & integer'image(k));
    end loop;

    report "DIVIDER TB RESULT: PASS=" & integer'image(pass_v) &
           " FAIL=" & integer'image(fail_v);
    if fail_v = 0 then
      report "tb_divider_rs: ALL TESTS PASS";
    else
      report "tb_divider_rs: FAILURES PRESENT" severity error;
    end if;
    running <= false;
    wait;
  end process;
end architecture sim;
