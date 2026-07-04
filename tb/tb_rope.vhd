-- tb/tb_rope.vhd
-- Testbench for rtl/rope.vhd.
--
-- Golden file: mem/golden/fx_rope_l0.txt
-- Block order (confirmed from dump_rope_l0 in ref/run_fx.c, dumped at POS=3):
--   Block 1: q_pre  (64 elements = DIM,   EXP 10)
--   Block 2: k_pre  (32 elements = KVDIM, EXP 10)
--   Block 3: q_post (64 elements = DIM,   EXP 10)
--   Block 4: k_post (32 elements = KVDIM, EXP 10)
--
-- The DUT is driven at POS=3 (the dump position).  Output mantissas are
-- compared against q_post and k_post within +/-2 LSB (exponents aligned
-- before comparison, as in tb_rmsnorm).
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;
use work.util_pkg.all;
use work.golden_pkg.all;

entity tb_rope is end;

architecture sim of tb_rope is
  constant DIM   : positive := 64;
  constant HEAD  : positive := 8;
  constant KVDIM : positive := 32;
  constant POS   : integer  := 3;

  signal clk     : std_logic := '0';
  signal rst     : std_logic := '1';
  signal start   : std_logic := '0';
  signal done    : std_logic;

  signal q_mant  : std_logic_vector(DIM*16-1   downto 0) := (others => '0');
  signal q_exp   : integer := 0;
  signal k_mant  : std_logic_vector(KVDIM*16-1 downto 0) := (others => '0');
  signal k_exp   : integer := 0;

  signal qo_mant : std_logic_vector(DIM*16-1   downto 0);
  signal qo_exp  : integer;
  signal ko_mant : std_logic_vector(KVDIM*16-1 downto 0);
  signal ko_exp  : integer;

begin
  clk <= not clk after 5 ns;

  uut: entity work.rope
    generic map(
      DIM   => DIM,
      HEAD  => HEAD,
      KVDIM => KVDIM
    )
    port map(
      clk     => clk,
      rst     => rst,
      start   => start,
      pos     => POS,
      q_mant  => q_mant,
      q_exp   => q_exp,
      k_mant  => k_mant,
      k_exp   => k_exp,
      done    => done,
      qo_mant => qo_mant,
      qo_exp  => qo_exp,
      ko_mant => ko_mant,
      ko_exp  => ko_exp
    );

  process
    file f_gold : text;

    -- n and exp per block
    variable n_qpre,  n_kpre  : integer;
    variable n_qpost, n_kpost : integer;
    variable e_qpre,  e_kpre  : integer;
    variable e_qpost, e_kpost : integer;

    variable q_pre_data  : integer_vector(0 to DIM-1);
    variable k_pre_data  : integer_vector(0 to KVDIM-1);
    variable q_post_data : integer_vector(0 to DIM-1);
    variable k_post_data : integer_vector(0 to KVDIM-1);

    -- comparison helpers
    variable e_max        : integer;
    variable dut_m        : integer;
    variable gold_m       : integer;
    variable dut_scaled   : integer;
    variable gold_scaled  : integer;
    variable dev          : integer;
    variable max_dev      : integer := 0;
    variable dut_qo_exp_v : integer;
    variable dut_ko_exp_v : integer;

  begin
    -- ---- read all four BFP blocks from fx_rope_l0.txt ----
    file_open(f_gold, "../mem/golden/fx_rope_l0.txt", read_mode);
    read_bfp_block(f_gold, n_qpre,  e_qpre,  q_pre_data);
    read_bfp_block(f_gold, n_kpre,  e_kpre,  k_pre_data);
    read_bfp_block(f_gold, n_qpost, e_qpost, q_post_data);
    read_bfp_block(f_gold, n_kpost, e_kpost, k_post_data);
    file_close(f_gold);

    assert n_qpre  = DIM   report "q_pre  n mismatch"  severity failure;
    assert n_kpre  = KVDIM report "k_pre  n mismatch"  severity failure;
    assert n_qpost = DIM   report "q_post n mismatch"  severity failure;
    assert n_kpost = KVDIM report "k_post n mismatch"  severity failure;

    -- ---- load inputs into port vectors ----
    for j in 0 to DIM-1 loop
      q_mant((j+1)*16-1 downto j*16) <=
        std_logic_vector(to_signed(q_pre_data(j), 16));
    end loop;
    q_exp <= e_qpre;

    for j in 0 to KVDIM-1 loop
      k_mant((j+1)*16-1 downto j*16) <=
        std_logic_vector(to_signed(k_pre_data(j), 16));
    end loop;
    k_exp <= e_kpre;

    -- ---- reset ----
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    -- ---- pulse start ----
    start <= '1';
    wait until rising_edge(clk);
    start <= '0';

    -- ---- wait for done ----
    wait until done = '1';
    wait for 1 ns;  -- delta settle

    -- ---- capture output exponents ----
    dut_qo_exp_v := qo_exp;
    dut_ko_exp_v := ko_exp;
    max_dev      := 0;

    -- ---- compare Q output ----
    -- Align to the finer (larger) exponent for integer comparison.
    if dut_qo_exp_v > e_qpost then
      e_max := dut_qo_exp_v;
    else
      e_max := e_qpost;
    end if;

    for j in 0 to DIM-1 loop
      dut_m  := to_integer(signed(qo_mant((j+1)*16-1 downto j*16)));
      gold_m := q_post_data(j);

      dut_scaled  := dut_m  * (2 ** (e_max - dut_qo_exp_v));
      gold_scaled := gold_m * (2 ** (e_max - e_qpost));

      if dut_scaled >= gold_scaled then
        dev := dut_scaled - gold_scaled;
      else
        dev := gold_scaled - dut_scaled;
      end if;
      if dev > max_dev then max_dev := dev; end if;

      assert dev <= 2
        report "Q element " & integer'image(j) &
               " dut=" & integer'image(dut_scaled) &
               " golden=" & integer'image(gold_scaled) &
               " dev=" & integer'image(dev)
        severity failure;
    end loop;

    -- ---- compare K output ----
    if dut_ko_exp_v > e_kpost then
      e_max := dut_ko_exp_v;
    else
      e_max := e_kpost;
    end if;

    for j in 0 to KVDIM-1 loop
      dut_m  := to_integer(signed(ko_mant((j+1)*16-1 downto j*16)));
      gold_m := k_post_data(j);

      dut_scaled  := dut_m  * (2 ** (e_max - dut_ko_exp_v));
      gold_scaled := gold_m * (2 ** (e_max - e_kpost));

      if dut_scaled >= gold_scaled then
        dev := dut_scaled - gold_scaled;
      else
        dev := gold_scaled - dut_scaled;
      end if;
      if dev > max_dev then max_dev := dev; end if;

      assert dev <= 2
        report "K element " & integer'image(j) &
               " dut=" & integer'image(dut_scaled) &
               " golden=" & integer'image(gold_scaled) &
               " dev=" & integer'image(dev)
        severity failure;
    end loop;

    report "PASS:rope  max_dev=" & integer'image(max_dev) severity note;
    std.env.finish;
  end process;
end architecture;
