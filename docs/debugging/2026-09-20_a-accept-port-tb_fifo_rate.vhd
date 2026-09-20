-- tb_fifo_rate -- TRACK AIDLE micro-bench.  Isolates ONE question: what
-- sustained rate does the FIFO in subsystem A's weight path deliver when the
-- write side offers a beat every cycle and the read side takes one every
-- cycle?  Nothing else is in the loop: no AXI, no array, no memory model.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_fifo_rate is
  generic(
    N   : positive := 2000;
    TAG : string   := "stream";
    FP  : boolean  := false;
    -- CONSUMER BACKPRESSURE, AND THE BENCH WAS USELESS WITHOUT IT.
    -- MEASURED 2026-09-20: with q_ready tied high, mutant M1 (the read-issue
    -- threshold one too PERMISSIVE, `after_e < 3`) and mutant M4 (the pop
    -- term ignoring q_ready) BOTH SURVIVED, at the identical rate and with
    -- every value in order.  Neither is detectable by a consumer that never
    -- stalls: the overrun state needs a cycle where the output stage holds a
    -- beat that is NOT leaving, and `ocnt > 0` and `ocnt > 0 and q_ready` are
    -- the same expression when q_ready is a constant.  That is coverage of
    -- the input space mistaken for coverage of the output space.
    -- BP = 0 holds q_ready high (the rate measurement); BP > 0 drops it
    -- pseudo-randomly, which is the mutation-sensitive configuration.
    BP  : natural  := 0
  );
end entity;

architecture sim of tb_fifo_rate is
  constant W : positive := 32;
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal fin : boolean := false;
  signal iv, ir, qv, qr : std_logic := '0';
  signal idat, qdat : std_logic_vector(W-1 downto 0) := (others => '0');
  signal lvl : integer;
  signal npush, npop, ncyc, nqlow : integer := 0;
begin
  clkp : process begin
    while not fin loop clk <= '0'; wait for 5 ns; clk <= '1'; wait for 5 ns; end loop;
    wait;
  end process;
  rst <= '1', '0' after 40 ns;

  dut : entity work.stream_fifo
    generic map(W => W, DEPTH => 512, FAST_POP => FP)
    port map(clk => clk, rst => rst, flush => '0',
             i_valid => iv, i_data => idat, i_ready => ir,
             q_valid => qv, q_data => qdat, q_ready => qr, level => lvl);

  -- A plain 16-bit LFSR, so the pattern is reproducible and the bench has no
  -- dependence on a random seed.
  bpp : process(clk)
    variable lfsr : unsigned(15 downto 0) := x"ACE1";
  begin
    if rising_edge(clk) then
      if rst = '1' then
        lfsr := x"ACE1"; qr <= '1';
      elsif BP = 0 then
        qr <= '1';
      else
        lfsr := (lfsr(14 downto 0) & (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10)));
        if to_integer(lfsr(7 downto 0)) mod 100 < BP then qr <= '0';
        else qr <= '1'; end if;
      end if;
    end if;
  end process;
  drv : process(clk)
    variable wseq : integer := 0;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        iv <= '0'; wseq := 0; npush <= 0; npop <= 0; ncyc <= 0; nqlow <= 0;
      else
        -- write side: offer a beat every cycle until N are pushed.  The
        -- accounting runs BEFORE the drive so that `idat` always carries the
        -- NEXT unpushed value rather than the one just taken.
        if iv = '1' and ir = '1' then
          npush <= npush + 1;
          wseq := wseq + 1;
        end if;
        if wseq < N then
          iv <= '1'; idat <= std_logic_vector(to_unsigned(wseq, W));
        else
          iv <= '0';
        end if;
        -- read side
        if npop < N then
          ncyc <= ncyc + 1;
          if qv = '0' then nqlow <= nqlow + 1; end if;
        end if;
        if qv = '1' and qr = '1' then
          assert qdat = std_logic_vector(to_unsigned(npop, W))
            report "tb_fifo_rate: OUT OF ORDER or WRONG value at pop "
                 & integer'image(npop) severity failure;
          npop <= npop + 1;
        end if;
      end if;
    end if;
  end process;

  mon : process
  begin
    wait until rst = '0';
    while npop < N loop wait until rising_edge(clk); end loop;
    wait until rising_edge(clk);
    report "FIFORATE tag=" & TAG & " N=" & integer'image(N)
         & " cycles_to_drain=" & integer'image(ncyc)
         & " qvalid_low=" & integer'image(nqlow)
         & " bp=" & integer'image(BP)
         & " cycles_per_beat_x1000="
         & integer'image((ncyc * 1000) / N);
    fin <= true;
    wait for 50 ns;
    std.env.stop;
    wait;
  end process;
end architecture;
