-- Bench for rtl/jc_dna_reader.vhd against sim/jc_dna_model.vhd (Task 9b). The reader runs
-- at its DEFAULT DIV on a 450 MHz aclk (the brief's ceiling case), so this also checks
-- that the default keeps dna_clk at or under 25 MHz there.
--
-- SIM_DNA has distinct, non-mirrored halves, so a reader that assembles the bits in the
-- opposite order (or reads 95 of them shifted by one) cannot reproduce it.
-- Checks are counted in variables; PASS is printed only after the count is asserted.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_jc_dna_reader is
end entity;

architecture sim of tb_jc_dna_reader is
  constant CLK_P   : time := 2222 ps;                  -- ~450 MHz aclk
  constant SIM_DNA : std_logic_vector(95 downto 0) := x"13579BDF2468ACE0F1E2D3C4";
  -- 450 MHz / 25 MHz = 18 aclk cycles: the shortest dna_clk period the brief allows
  constant MIN_CYC : natural := 18;
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal dclk, drd, dsh, ddout, vld : std_logic;
  signal dna : std_logic_vector(95 downto 0);
  signal errors, reads, shifts : natural;
  signal done : boolean := false;
  signal ncyc : natural := 0;          -- aclk cycles since time 0
  signal dclk_rises : natural := 0;
  signal min_period : natural := natural'high;   -- shortest dna_clk period, aclk cycles
begin
  clk <= not clk after CLK_P / 2 when not done else '0';

  dut : entity work.jc_dna_reader               -- DIV left at its default on purpose
    port map(clk => clk, rst => rst, dna_clk => dclk, dna_read => drd, dna_shift => dsh,
             dna_dout => ddout, dna => dna, dna_valid => vld);

  mdl : entity work.jc_dna_model
    generic map(SIM_DNA => SIM_DNA, T_MARGIN => CLK_P, T_CLK_MIN => 40 ns)
    port map(clk => dclk, read => drd, shift => dsh, din => '0', dout => ddout,
             errors => errors, reads => reads, shifts => shifts);

  cyc : process(clk)
  begin
    if rising_edge(clk) then
      ncyc <= ncyc + 1;
    end if;
  end process;

  -- dna_clk period in aclk cycles, measured on dna_clk's own rising edges
  per : process(dclk)
    variable last : integer := -1;
  begin
    if rising_edge(dclk) then
      dclk_rises <= dclk_rises + 1;
      if last >= 0 and ncyc - last < min_period then
        min_period <= ncyc - last;
      end if;
      last := ncyc;
    end if;
  end process;

  driver : process
    variable checks, errs : natural := 0;
    variable t0, sh0, rd0, rises0 : natural := 0;
    variable early : boolean;
    procedure chk(cond : boolean; msg : string) is
    begin
      checks := checks + 1;
      if not cond then errs := errs + 1; report msg severity error; end if;
    end procedure;
    -- release reset, then wait for dna_valid with a bound; returns the cycles taken
    procedure read_once(timeout : natural; cycles : out natural; zero_before : out boolean) is
      variable zb : boolean := true;
      variable n : natural := 0;
    begin
      wait until falling_edge(clk); rst <= '0';
      while vld /= '1' and n < timeout loop
        wait until rising_edge(clk);
        n := n + 1;
        if vld /= '1' and dna /= (95 downto 0 => '0') then zb := false; end if;
      end loop;
      cycles := n; zero_before := zb;
    end procedure;
    variable cyc_taken : natural;
  begin
    for i in 1 to 10 loop wait until rising_edge(clk); end loop;
    chk(vld = '0', "dna_valid must be low in reset");

    -- 1. first read after reset release
    read_once(40000, cyc_taken, early);
    report "dna_valid after " & integer'image(cyc_taken) & " aclk cycles, dna_clk period " &
           integer'image(min_period) & " aclk cycles";
    chk(vld = '1', "dna_valid never rose (" & integer'image(cyc_taken) & " cycles)");
    chk(dna = SIM_DNA, "dna " & to_hstring(dna) & " expected " & to_hstring(SIM_DNA));
    chk(early, "dna must read zero until dna_valid");
    chk(reads = 1, "expected exactly 1 READ, got " & integer'image(reads));
    chk(shifts = 95, "expected 95 SHIFTs (bit 0 is out after READ), got " & integer'image(shifts));
    -- 1 READ period + 95 SHIFT periods at 2*DIV cycles each cannot finish in fewer than
    -- 96 * MIN_CYC cycles; the upper bound is the same count with three periods of slack
    chk(cyc_taken >= 96 * MIN_CYC, "dna_valid too early: " & integer'image(cyc_taken) & " cycles");
    chk(cyc_taken <= 99 * min_period, "dna_valid too late: " & integer'image(cyc_taken) &
        " cycles at a dna_clk period of " & integer'image(min_period));
    chk(min_period >= MIN_CYC, "dna_clk period " & integer'image(min_period) &
        " aclk cycles: over 25 MHz at a 450 MHz aclk");

    -- 2. sticky, and the DNA_PORTE2 pins go quiet once the value is held
    rises0 := dclk_rises; rd0 := reads; sh0 := shifts;
    for i in 1 to 200 * MIN_CYC loop
      wait until rising_edge(clk);
      if vld /= '1' or dna /= SIM_DNA then
        chk(false, "dna_valid/dna not sticky at cycle " & integer'image(i));
        exit;
      end if;
    end loop;
    chk(vld = '1' and dna = SIM_DNA, "dna held after 200 periods");
    chk(reads = rd0 and shifts = sh0, "no READ/SHIFT after dna_valid");
    chk(dclk_rises = rises0, "dna_clk must stop once the value is held");

    -- 3. reset in the middle of a read: valid drops at once, the read restarts with a
    --    fresh READ and gets the whole value again
    wait until falling_edge(clk); rst <= '1';
    wait until rising_edge(clk); wait until falling_edge(clk);
    chk(vld = '0' and dna = (95 downto 0 => '0'), "reset must clear dna and dna_valid");
    rd0 := reads; sh0 := shifts;
    wait until falling_edge(clk); rst <= '0';
    for i in 1 to 40000 loop
      exit when shifts >= sh0 + 40;
      wait until rising_edge(clk);
    end loop;
    for i in 1 to 7 loop wait until rising_edge(clk); end loop;  -- off the dna_clk phase
    wait until falling_edge(clk); rst <= '1';
    for i in 1 to 5 loop wait until rising_edge(clk); end loop;
    chk(vld = '0', "dna_valid must stay low after a mid-read reset");
    sh0 := shifts;
    read_once(40000, cyc_taken, early);
    chk(vld = '1' and dna = SIM_DNA, "re-read after a mid-read reset: " & to_hstring(dna));
    chk(reads = rd0 + 2, "a READ per read attempt: " & integer'image(reads - rd0));
    chk(shifts = sh0 + 95, "95 SHIFTs in the re-read, got " & integer'image(shifts - sh0));

    chk(errors = 0, "DNA_PORTE2 model timing errors: " & integer'image(errors));
    done <= true;
    assert checks = 18 report "expected 18 checks, ran " & integer'image(checks) severity failure;
    if errs = 0 then
      report "PASS: tb_jc_dna_reader checks=" & integer'image(checks);
    else
      report "FAIL: tb_jc_dna_reader errors=" & integer'image(errs) severity failure;
    end if;
    wait;
  end process;
end architecture;
