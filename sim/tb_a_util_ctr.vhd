-- sim/tb_a_util_ctr.vhd -- per-port A read-beat counters, rtl/a_util_ctr.vhd.
-- Jungle Cat engine composition, Task 1, 2026-10-07.
--
-- THE ORACLE is a set of VARIABLES in the driving process, updated at the
-- same rising edge at which the DUT samples, from the same values the
-- process drove: per port, the count of (rbeat(i) and in_job); and the count
-- of in_job cycles.  Never signals: same-delta assignments would collapse.
--
-- Cases:
--   R  27 ports, per-port 16-bit LFSR beat patterns (some ports thinned by
--      ANDing two LFSR bits, so beat density differs from cycle density),
--      5,000 cycles, in_job high for 2,500 of them in 4 windows.  Beats are
--      driven OUTSIDE the windows too, so "beats outside the job must not
--      count" is exercised on every port.  All 28 counters read (low, then
--      high) and compared as 48-bit values.
--   W  a second instance with INIT_HI = true, whose counter 0 resets to
--      2**32 - 3.  Ten beats in a job.  A low read is issued while beats are
--      still arriving and the following high read must return the value
--      LATCHED by that low read, not the live one (the carry into bit 32
--      happens between the two reads, so a live high word tears).  Then a
--      quiescent read must give 2**32 + 7 as one 48-bit value.
--   O  after W, 20 more beats with in_job low: counter 0 must not move.
--   C  (fix round 1) a CLEAR between a low read and its high read: the high
--      read must still return the pre-clear high word, and the clear must
--      not move rd_data under the read already answered.  Then the counter
--      reads its cleared value.
--
-- Prints `CHECKS <n>`; any mismatch is `severity failure`.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_a_util_ctr is
end entity;

architecture sim of tb_a_util_ctr is
  constant NP  : positive := 27;
  constant TCK : time := 5 ns;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal done_sim : boolean := false;

  -- instance A (random case)
  signal a_in_job : std_logic := '0';
  signal a_rbeat  : std_logic_vector(NP-1 downto 0) := (others => '0');
  signal a_rd_idx : unsigned(6 downto 0) := (others => '0');
  signal a_rd_hi  : std_logic := '0';
  signal a_rd_en  : std_logic := '0';
  signal a_rd_dat : std_logic_vector(31 downto 0);

  -- instance B (wrap case)
  signal b_in_job : std_logic := '0';
  signal b_rbeat  : std_logic_vector(NP-1 downto 0) := (others => '0');
  signal b_rd_idx : unsigned(6 downto 0) := (others => '0');
  signal b_rd_hi  : std_logic := '0';
  signal b_rd_en  : std_logic := '0';
  signal b_rd_dat : std_logic_vector(31 downto 0);
  signal b_clr    : std_logic := '0';

  type u48_arr is array (natural range <>) of unsigned(47 downto 0);
  type u16_arr is array (natural range <>) of unsigned(15 downto 0);

  function lfsr_next(v : unsigned(15 downto 0)) return unsigned is
    variable fb : std_logic;
  begin
    -- x^16 + x^14 + x^13 + x^11 + 1, Fibonacci form
    fb := v(15) xor v(13) xor v(12) xor v(10);
    return v(14 downto 0) & fb;
  end function;
begin
  clk <= not clk after TCK when not done_sim else '0';

  dut_a : entity work.a_util_ctr
    generic map(NP => NP, INIT_HI => false)
    port map(clk => clk, rst => rst, in_job => a_in_job, rbeat => a_rbeat,
             rd_idx => a_rd_idx, rd_hi => a_rd_hi, rd_en => a_rd_en,
             rd_data => a_rd_dat);

  dut_b : entity work.a_util_ctr
    generic map(NP => NP, INIT_HI => true)
    port map(clk => clk, rst => rst, clr => b_clr,
             in_job => b_in_job, rbeat => b_rbeat,
             rd_idx => b_rd_idx, rd_hi => b_rd_hi, rd_en => b_rd_en,
             rd_data => b_rd_dat);

  drive : process
    variable lf     : u16_arr(0 to NP-1);
    variable ref    : u48_arr(0 to NP);   -- index NP = job cycles
    variable bref   : unsigned(47 downto 0);
    variable snap   : unsigned(47 downto 0);
    variable got    : unsigned(47 downto 0);
    variable lo     : std_logic_vector(31 downto 0);
    variable checks : natural := 0;
    variable bt     : std_logic_vector(NP-1 downto 0);
    variable job    : std_logic;
    variable njob   : natural := 0;

    procedure chk(cond : boolean; msg : string) is
    begin
      checks := checks + 1;
      assert cond report "tb_a_util_ctr: MISMATCH " & msg severity failure;
    end procedure;

    function hex48(v : unsigned(47 downto 0)) return string is
      constant H : string(1 to 16) := "0123456789ABCDEF";
      variable s : string(1 to 12);
    begin
      for k in 0 to 11 loop
        s(12 - k) := H(to_integer(v(4*k+3 downto 4*k)) + 1);
      end loop;
      return s;
    end function;
  begin
    for i in 0 to NP-1 loop
      lf(i) := to_unsigned(16#ACE1# + 977 * (i + 1), 16);
      if lf(i) = 0 then lf(i) := x"0001"; end if;
    end loop;
    for i in 0 to NP loop ref(i) := (others => '0'); end loop;

    rst <= '1';
    for k in 1 to 4 loop wait until rising_edge(clk); end loop;
    wait until falling_edge(clk);
    rst <= '0';

    -- ---------------------------------------------------------------- R
    for c in 0 to 4999 loop
      if (c >= 200 and c < 825) or (c >= 1500 and c < 2125) or
         (c >= 2800 and c < 3425) or (c >= 4100 and c < 4725) then
        job := '1';
      else
        job := '0';
      end if;
      for i in 0 to NP-1 loop
        lf(i) := lfsr_next(lf(i));
        if i mod 3 = 1 then
          bt(i) := lf(i)(0) and lf(i)(5);    -- ~25% density
        else
          bt(i) := lf(i)(0);                 -- ~50% density
        end if;
      end loop;
      a_in_job <= job;
      a_rbeat  <= bt;
      wait until rising_edge(clk);
      -- the DUT sampled exactly these values at this edge
      if job = '1' then
        njob := njob + 1;
        ref(NP) := ref(NP) + 1;
        for i in 0 to NP-1 loop
          if bt(i) = '1' then ref(i) := ref(i) + 1; end if;
        end loop;
      end if;
      wait until falling_edge(clk);
    end loop;
    a_in_job <= '0';
    a_rbeat  <= (others => '0');
    chk(njob = 2500, "job cycle schedule is not 2500 (bench defect)");

    for i in 0 to NP loop
      a_rd_idx <= to_unsigned(i, 7); a_rd_hi <= '0'; a_rd_en <= '1';
      wait until rising_edge(clk); wait until falling_edge(clk);
      a_rd_en <= '0';
      lo := a_rd_dat;
      a_rd_hi <= '1'; a_rd_en <= '1';
      wait until rising_edge(clk); wait until falling_edge(clk);
      a_rd_en <= '0';
      got := unsigned(a_rd_dat(15 downto 0)) & unsigned(lo);
      chk(a_rd_dat(31 downto 16) = x"0000",
          "R counter " & integer'image(i) & " high read bits 31:16 not zero");
      chk(got = ref(i),
          "R counter " & integer'image(i) & " got 0x" & hex48(got) &
          " want 0x" & hex48(ref(i)));
    end loop;

    -- ---------------------------------------------------------------- W
    -- counter 0 of dut_b resets to 2**32 - 3.  Edges 1 and 2: beats.
    bref := (others => '0');
    bref(31 downto 0) := x"FFFFFFFD";
    b_in_job <= '1';
    b_rbeat  <= (0 => '1', others => '0');
    for k in 1 to 2 loop
      wait until rising_edge(clk); bref := bref + 1;
      wait until falling_edge(clk);
    end loop;
    -- edge 3: LOW read while a beat is also counted.  The read returns the
    -- pre-edge value and latches its high half.
    b_rd_idx <= to_unsigned(0, 7); b_rd_hi <= '0'; b_rd_en <= '1';
    wait until rising_edge(clk); snap := bref; bref := bref + 1;
    wait until falling_edge(clk);
    lo := b_rd_dat;
    -- edge 4: HIGH read while a beat is counted; the live high word has now
    -- carried (bref crossed 2**32 at edge 3), the latched one has not.
    b_rd_hi <= '1';
    wait until rising_edge(clk); bref := bref + 1;
    wait until falling_edge(clk);
    b_rd_en <= '0';
    got := unsigned(b_rd_dat(15 downto 0)) & unsigned(lo);
    chk(snap = x"0000FFFFFFFF", "W snapshot arithmetic (bench defect)");
    chk(got = snap, "W torn read: got 0x" & hex48(got) & " want 0x" &
                    hex48(snap));
    -- six more beats: ten in all
    for k in 1 to 6 loop
      wait until rising_edge(clk); bref := bref + 1;
      wait until falling_edge(clk);
    end loop;
    b_in_job <= '0';
    b_rbeat  <= (others => '0');
    chk(bref = x"000100000007",
        "W reference is not 2**32+7 (bench defect)");
    -- quiescent atomic read
    b_rd_hi <= '0'; b_rd_en <= '1';
    wait until rising_edge(clk); wait until falling_edge(clk);
    lo := b_rd_dat;
    b_rd_hi <= '1';
    wait until rising_edge(clk); wait until falling_edge(clk);
    b_rd_en <= '0';
    got := unsigned(b_rd_dat(15 downto 0)) & unsigned(lo);
    chk(got = x"000100000007", "W quiescent read got 0x" & hex48(got) &
                               " want 0x000100000007");

    -- ---------------------------------------------------------------- O
    b_in_job <= '0';
    b_rbeat  <= (others => '1');
    for k in 1 to 20 loop
      wait until rising_edge(clk); wait until falling_edge(clk);
    end loop;
    b_rbeat <= (others => '0');
    for i in 0 to 1 loop
      b_rd_idx <= to_unsigned(i, 7); b_rd_hi <= '0'; b_rd_en <= '1';
      wait until rising_edge(clk); wait until falling_edge(clk);
      lo := b_rd_dat;
      b_rd_hi <= '1';
      wait until rising_edge(clk); wait until falling_edge(clk);
      b_rd_en <= '0';
      got := unsigned(b_rd_dat(15 downto 0)) & unsigned(lo);
      if i = 0 then
        chk(got = x"000100000007", "O counter 0 moved outside the job: 0x" &
                                   hex48(got));
      else
        chk(got = 0, "O counter 1 counted outside the job: 0x" & hex48(got));
      end if;
    end loop;
    -- dut_b's job counter saw exactly the 10 job cycles of case W
    b_rd_idx <= to_unsigned(NP, 7); b_rd_hi <= '0'; b_rd_en <= '1';
    wait until rising_edge(clk); wait until falling_edge(clk);
    lo := b_rd_dat;
    b_rd_hi <= '1';
    wait until rising_edge(clk); wait until falling_edge(clk);
    b_rd_en <= '0';
    got := unsigned(b_rd_dat(15 downto 0)) & unsigned(lo);
    chk(got = 10, "O job cycle counter got 0x" & hex48(got) & " want 10");

    -- ---------------------------------------------------------------- C
    -- counter 0 holds 2**32 + 7.  Low read, then a clear, then the high read.
    b_rd_idx <= to_unsigned(0, 7); b_rd_hi <= '0'; b_rd_en <= '1';
    wait until rising_edge(clk); wait until falling_edge(clk);
    b_rd_en <= '0';
    lo := b_rd_dat;
    chk(lo = x"00000007", "C low read before the clear got 0x" &
                          hex48(x"0000" & unsigned(lo)));
    b_clr <= '1';
    wait until rising_edge(clk); wait until falling_edge(clk);
    b_clr <= '0';
    chk(b_rd_dat = x"00000007", "C the clear moved rd_data under an " &
        "answered read: 0x" & hex48(x"0000" & unsigned(b_rd_dat)));
    b_rd_hi <= '1'; b_rd_en <= '1';
    wait until rising_edge(clk); wait until falling_edge(clk);
    b_rd_en <= '0';
    got := unsigned(b_rd_dat(15 downto 0)) & unsigned(lo);
    chk(got = x"000100000007", "C clear between low and high read tore " &
        "the sample: got 0x" & hex48(got) & " want 0x000100000007");
    -- and the clear did clear: INIT_HI's reset value, 2**32 - 3
    b_rd_hi <= '0'; b_rd_en <= '1';
    wait until rising_edge(clk); wait until falling_edge(clk);
    lo := b_rd_dat;
    b_rd_hi <= '1';
    wait until rising_edge(clk); wait until falling_edge(clk);
    b_rd_en <= '0';
    got := unsigned(b_rd_dat(15 downto 0)) & unsigned(lo);
    chk(got = x"0000FFFFFFFD", "C counter 0 after the clear got 0x" &
        hex48(got) & " want 0x0000FFFFFFFD");

    report "CHECKS " & integer'image(checks);
    report "tb_a_util_ctr: PASS";
    done_sim <= true;
    wait;
  end process;
end architecture;
