-- tb/tb_swiglu.vhd
-- Testbench for rtl/swiglu.vhd.
-- Golden file: mem/golden/fx_swiglu_l0.txt
--   Block 1: hb-in    (n=172, EXP 13, int16 mantissas)
--   Block 2: hb2-in   (n=172, EXP 14, int16 mantissas)
--   Block 3: gated-out (n=172, EXP 13, int16 mantissas)
--
-- Comparison: at Q12 (DUT native scale).
-- Golden output (EXP 13) is right-shifted by (EXP-Q)=1 with round-half-up
-- to align to Q12. Tolerance +-2 LSB at Q12.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;
use work.util_pkg.all;
use work.golden_pkg.all;

entity tb_swiglu is end;

architecture sim of tb_swiglu is
  constant N : positive := 172;
  constant Q : integer  := 12;

  signal clk      : std_logic := '0';
  signal rst      : std_logic := '1';
  signal start    : std_logic := '0';
  signal done     : std_logic;

  signal hb_mant  : std_logic_vector(N*16-1 downto 0) := (others => '0');
  signal hb_exp   : integer := 0;
  signal hb2_mant : std_logic_vector(N*16-1 downto 0) := (others => '0');
  signal hb2_exp  : integer := 0;
  signal out_q    : std_logic_vector(N*32-1 downto 0);

begin
  clk <= not clk after 5 ns;

  uut: entity work.swiglu
    generic map(N => N, Q => Q)
    port map(
      clk      => clk,
      rst      => rst,
      start    => start,
      hb_mant  => hb_mant,
      hb_exp   => hb_exp,
      hb2_mant => hb2_mant,
      hb2_exp  => hb2_exp,
      done     => done,
      out_q    => out_q
    );

  process
    file f_gold : text;

    variable n_hb, n_hb2, n_out  : integer;
    variable e_hb, e_hb2, e_out  : integer;
    variable hb_data   : integer_vector(0 to N-1);
    variable hb2_data  : integer_vector(0 to N-1);
    variable out_data  : integer_vector(0 to N-1);

    variable dut_p    : integer;
    variable gold_p   : integer;
    variable gold_q12 : integer;
    variable dev      : integer;
    variable max_dev  : integer := 0;
    variable sh       : integer;

  begin
    file_open(f_gold, "../mem/golden/fx_swiglu_l0.txt", read_mode);
    read_bfp_block(f_gold, n_hb,  e_hb,  hb_data);
    read_bfp_block(f_gold, n_hb2, e_hb2, hb2_data);
    read_bfp_block(f_gold, n_out, e_out, out_data);
    file_close(f_gold);

    assert n_hb  = N report "hb block n mismatch"  severity failure;
    assert n_hb2 = N report "hb2 block n mismatch" severity failure;
    assert n_out = N report "out block n mismatch"  severity failure;

    -- Load mantissas into port vectors (16-bit signed each)
    for j in 0 to N-1 loop
      hb_mant((j+1)*16-1 downto j*16) <=
        std_logic_vector(to_signed(hb_data(j), 16));
      hb2_mant((j+1)*16-1 downto j*16) <=
        std_logic_vector(to_signed(hb2_data(j), 16));
    end loop;
    hb_exp  <= e_hb;
    hb2_exp <= e_hb2;

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

    -- Compare all N outputs at Q12 scale.
    -- golden BFP (e_out) -> Q12: right-shift by (e_out - Q) with round-half-up.
    sh      := e_out - Q;
    max_dev := 0;

    for j in 0 to N-1 loop
      dut_p  := to_integer(signed(out_q((j+1)*32-1 downto j*32)));
      gold_p := out_data(j);

      -- Convert golden mantissa to Q12
      if sh > 0 then
        -- round-half-up: (gold_p + 2^(sh-1)) / 2^sh
        gold_q12 := (gold_p + (2 ** (sh - 1))) / (2 ** sh);
      elsif sh = 0 then
        gold_q12 := gold_p;
      else
        gold_q12 := gold_p * (2 ** (-sh));
      end if;

      if dut_p >= gold_q12 then dev := dut_p - gold_q12;
      else                       dev := gold_q12 - dut_p;
      end if;
      if dev > max_dev then max_dev := dev; end if;

      assert dev <= 2
        report "element " & integer'image(j) &
               " dut=" & integer'image(dut_p) &
               " golden=" & integer'image(gold_q12) &
               " dev=" & integer'image(dev)
        severity failure;
    end loop;

    report "PASS:swiglu max_dev=" & integer'image(max_dev) severity note;
    std.env.finish;
  end process;
end architecture sim;
