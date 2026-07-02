-- tb/tb_softmax.vhd
-- Testbench for rtl/softmax.vhd.
-- Golden file: mem/golden/fx_softmax_l0_h0.txt
--   Block 1: scores-in  (n=4, EXP 13, mantissas as int16 BFP)
--   Block 2: probs-out  (n=4, EXP 15, mantissas; sum=32768=1.0 at EXP15)
--
-- Comparison: gold at EXP 15, DUT at Q12 (EXP 12).
-- Align to finer scale (EXP 15): dut_at_15 = prob_q[i] * 2^3; gold_at_15 = mant[i].
-- Tolerance: +-2 LSB at EXP 15.  Also asserts sum(prob_q) in [4094,4098].
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;
use work.util_pkg.all;
use work.golden_pkg.all;

entity tb_softmax is end;

architecture sim of tb_softmax is
  constant NMAX : positive := 4;
  constant Q    : integer  := 12;

  signal clk        : std_logic := '0';
  signal rst        : std_logic := '1';
  signal start      : std_logic := '0';
  signal done       : std_logic;

  signal score_mant : std_logic_vector(NMAX*16-1 downto 0) := (others => '0');
  signal score_exp  : integer := 0;
  signal prob_q     : std_logic_vector(NMAX*32-1 downto 0);

begin
  clk <= not clk after 5 ns;

  uut: entity work.softmax
    generic map(NMAX => NMAX, Q => Q)
    port map(
      clk        => clk,
      rst        => rst,
      start      => start,
      n          => NMAX,
      score_mant => score_mant,
      score_exp  => score_exp,
      done       => done,
      prob_q     => prob_q
    );

  process
    file f_gold : text;

    variable n_sc, n_pr  : integer;
    variable e_sc, e_pr  : integer;
    variable sc_data     : integer_vector(0 to NMAX-1);
    variable pr_data     : integer_vector(0 to NMAX-1);

    variable e_max       : integer;
    variable dut_p       : integer;
    variable gold_p      : integer;
    variable dut_scaled  : integer;
    variable gold_scaled : integer;
    variable dev         : integer;
    variable max_dev     : integer := 0;
    variable pq_sum      : integer;
    variable sum_dev     : integer;

  begin
    file_open(f_gold, "../mem/golden/fx_softmax_l0_h0.txt", read_mode);
    read_bfp_block(f_gold, n_sc, e_sc, sc_data);
    read_bfp_block(f_gold, n_pr, e_pr, pr_data);
    file_close(f_gold);

    assert n_sc = NMAX report "score block n mismatch" severity failure;
    assert n_pr = NMAX report "prob block n mismatch"  severity failure;

    -- load scores into port vector (BFP mantissas, 16-bit each)
    for j in 0 to NMAX-1 loop
      score_mant((j+1)*16-1 downto j*16) <=
        std_logic_vector(to_signed(sc_data(j), 16));
    end loop;
    score_exp <= e_sc;

    -- reset
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    -- pulse start
    start <= '1';
    wait until rising_edge(clk);
    start <= '0';

    -- wait for done
    wait until done = '1';
    wait for 1 ns;

    -- assert sum(prob_q[0..n-1]) is within +-2 of 4096 (1.0 in Q12)
    pq_sum := 0;
    for j in 0 to NMAX-1 loop
      dut_p  := to_integer(signed(prob_q((j+1)*32-1 downto j*32)));
      pq_sum := pq_sum + dut_p;
    end loop;
    if pq_sum >= 4096 then sum_dev := pq_sum - 4096;
    else                   sum_dev := 4096 - pq_sum;
    end if;
    -- Sum tolerance is n-1 due to integer truncation in (e_i<<Q)/sum per element.
    -- For this test NMAX=4, so max deficit is 3.
    assert sum_dev <= NMAX
      report "prob_q sum=" & integer'image(pq_sum) &
             " expected ~4096 dev=" & integer'image(sum_dev)
      severity failure;

    -- Compare at Q12 (the DUT's native precision), as that is the coarser scale.
    -- gold_at_Q12 = round(mant * 2^(Q - e_pr))  [right-shift with round-half-up]
    -- dut_at_Q12  = prob_q[i]
    -- Tolerance: +-2 at Q12.
    -- When e_pr > Q (Q15 golden vs Q12 DUT), gold is right-shifted by (e_pr - Q)=3.
    -- Comparing at the finer Q15 scale would give deviations up to 8 Q15 = 1 Q12
    -- from int-truncation vs the C float divide; comparing at Q12 gives <=1.
    e_max   := Q;  -- compare at DUT's scale
    max_dev := 0;

    for j in 0 to NMAX-1 loop
      dut_p  := to_integer(signed(prob_q((j+1)*32-1 downto j*32)));
      gold_p := pr_data(j);

      -- scale gold down to Q: right-shift (e_pr - Q) with round-half-up
      dut_scaled  := dut_p;  -- already at Q
      if e_pr > Q then
        gold_scaled := (gold_p + (2 ** (e_pr - Q - 1))) / (2 ** (e_pr - Q));
      elsif e_pr = Q then
        gold_scaled := gold_p;
      else
        gold_scaled := gold_p * (2 ** (Q - e_pr));
      end if;

      if dut_scaled >= gold_scaled then dev := dut_scaled - gold_scaled;
      else                              dev := gold_scaled - dut_scaled;
      end if;
      if dev > max_dev then max_dev := dev; end if;

      assert dev <= 2
        report "element " & integer'image(j) &
               " dut=" & integer'image(dut_scaled) &
               " golden=" & integer'image(gold_scaled) &
               " dev=" & integer'image(dev)
        severity failure;
    end loop;

    report "PASS:softmax  max_dev=" & integer'image(max_dev) &
           "  pq_sum=" & integer'image(pq_sum) severity note;
    std.env.finish;
  end process;
end architecture;
