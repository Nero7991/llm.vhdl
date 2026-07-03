-- tb/tb_lm_head.vhd
-- Testbench for rtl/lm_head.vhd.
-- Reads mem/golden/fx_lmhead.txt: one BFP block (final-rmsnorm x, dim=64),
-- then 512 raw int32 logit lines, then one final line with the golden
-- argmax index. Drives the DUT with the golden x, waits for done, and
-- checks:
--   1. Every logit is bit-exact vs the golden (the RTL recomputes the exact
--      same int16*int16->int64 dot + scale_mul(acc,mult,shift) the C dumper
--      used to produce fx_lmhead.txt from the same tied embedding ROMs).
--   2. argmax(dut_logits) == the golden argmax index (the acceptance gate).
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;
use work.golden_pkg.all;

entity tb_lm_head is end;

architecture sim of tb_lm_head is
  constant DIM   : integer := 64;
  constant VOCAB : integer := 512;

  signal clk    : std_logic := '0';
  signal rst    : std_logic := '1';
  signal start  : std_logic := '0';
  signal done   : std_logic;
  signal x_mant : std_logic_vector(DIM*16-1 downto 0) := (others => '0');
  signal x_exp  : integer := 0;
  signal logits : std_logic_vector(VOCAB*32-1 downto 0);
begin
  clk <= not clk after 5 ns;

  uut: entity work.lm_head
    generic map(
      DIM        => DIM,
      VOCAB      => VOCAB,
      WEIGHT_DIR => "../mem/weights/"
    )
    port map(
      clk    => clk,
      rst    => rst,
      start  => start,
      x_mant => x_mant,
      x_exp  => x_exp,
      done   => done,
      logits => logits
    );

  process
    file f_lm : text;

    variable n_x     : integer;
    variable x_e      : integer;
    variable x_d      : integer_vector(0 to DIM-1);
    variable gold_log : integer_vector(0 to VOCAB-1);
    variable L        : line;
    variable gold_argmax : integer;

    variable dut_v      : integer;
    variable dut_argmax : integer;
    variable dut_best   : signed(31 downto 0);
    variable cur_v      : signed(31 downto 0);
    variable dev         : integer;
    variable max_dev     : integer := 0;
    variable mismatches  : integer := 0;
  begin
    -- ---- read golden: x-in BFP block, 512 logits, argmax index ----
    file_open(f_lm, "../mem/golden/fx_lmhead.txt", read_mode);
    read_bfp_block(f_lm, n_x, x_e, x_d);
    assert n_x = DIM
      report "fx_lmhead.txt: expected n=" & integer'image(DIM) &
             " got " & integer'image(n_x) severity failure;
    gold_log := read_int_lines(f_lm, VOCAB);
    readline(f_lm, L);
    read(L, gold_argmax);
    file_close(f_lm);

    -- ---- load x into DUT port ----
    for j in 0 to DIM-1 loop
      x_mant((j+1)*16-1 downto j*16) <= std_logic_vector(to_signed(x_d(j), 16));
    end loop;
    x_exp <= x_e;

    -- ---- reset, then pulse start ----
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    start <= '1';
    wait until rising_edge(clk);
    start <= '0';

    wait until done = '1';
    wait for 1 ns;

    -- ---- compare all 512 logits (expect bit-exact) ----
    for v in 0 to VOCAB-1 loop
      dut_v := to_integer(signed(logits((v+1)*32-1 downto v*32)));
      if dut_v >= gold_log(v) then dev := dut_v - gold_log(v);
      else                          dev := gold_log(v) - dut_v; end if;
      if dev > max_dev then max_dev := dev; end if;
      if dev /= 0 then mismatches := mismatches + 1; end if;
      assert dev = 0
        report "logit " & integer'image(v) &
               " dut=" & integer'image(dut_v) &
               " golden=" & integer'image(gold_log(v)) &
               " dev=" & integer'image(dev)
        severity failure;
    end loop;

    -- ---- compute DUT argmax (first-max on ties, mirrors sample_argmax) ----
    dut_best   := to_signed(gold_log(0), 32);  -- placeholder, recomputed below
    dut_best   := signed(logits(32-1 downto 0));
    dut_argmax := 0;
    for v in 1 to VOCAB-1 loop
      cur_v := signed(logits((v+1)*32-1 downto v*32));
      if cur_v > dut_best then
        dut_best   := cur_v;
        dut_argmax := v;
      end if;
    end loop;

    assert dut_argmax = gold_argmax
      report "argmax mismatch: dut=" & integer'image(dut_argmax) &
             " golden=" & integer'image(gold_argmax) severity failure;

    report "PASS:lm_head  max_dev=" & integer'image(max_dev) &
           "  mismatches=" & integer'image(mismatches) &
           "  argmax=" & integer'image(dut_argmax) severity note;
    std.env.finish;
  end process;
end architecture;
