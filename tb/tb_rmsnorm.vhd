-- tb/tb_rmsnorm.vhd
-- Testbench for rtl/rmsnorm.vhd.
-- Reads x-in and o-expected from mem/golden/fx_rmsnorm_l0.txt (two BFP blocks),
-- reads layer-0 att weight from mem/golden/fx_rmsnorm_l0_w.txt (one BFP block).
-- Drives the DUT, waits for done, compares output mantissas in the reconstructed
-- integer domain (aligned to the finer exponent) within +/-2 LSB.
-- Also provides real coverage for fixed_pkg.scale_mul (used in the datapath).
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;
use work.util_pkg.all;
use work.golden_pkg.all;

entity tb_rmsnorm is end;

architecture sim of tb_rmsnorm is
  constant N : positive := 64;

  signal clk    : std_logic := '0';
  signal rst    : std_logic := '1';
  signal start  : std_logic := '0';
  signal done   : std_logic;
  signal x_mant : std_logic_vector(N*16-1 downto 0) := (others => '0');
  signal x_exp  : integer := 0;
  signal w_mant : std_logic_vector(N*16-1 downto 0) := (others => '0');
  signal w_exp  : integer := 0;
  signal o_mant : std_logic_vector(N*16-1 downto 0);
  signal o_exp  : integer;
begin
  clk <= not clk after 5 ns;

  uut: entity work.rmsnorm
    generic map(N => N, Q => 12)
    port map(
      clk    => clk,
      rst    => rst,
      start  => start,
      x_mant => x_mant,
      x_exp  => x_exp,
      w_mant => w_mant,
      w_exp  => w_exp,
      done   => done,
      o_mant => o_mant,
      o_exp  => o_exp
    );

  process
    file f_rms : text;
    file f_w   : text;

    variable n_x, n_o, n_w : integer;
    variable xe, gold_oe, we : integer;
    variable x_data  : integer_vector(0 to N-1);
    variable o_data  : integer_vector(0 to N-1);
    variable w_data  : integer_vector(0 to N-1);

    variable e_max       : integer;
    variable dut_om_j    : integer;
    variable gold_om_j   : integer;
    variable dut_scaled  : integer;
    variable gold_scaled : integer;
    variable dev         : integer;
    variable max_dev     : integer := 0;
    variable dut_oe      : integer;
  begin
    -- ---- read x-in (block 1) and o-expected (block 2) from fx_rmsnorm_l0.txt ----
    file_open(f_rms, "../mem/golden/fx_rmsnorm_l0.txt", read_mode);
    read_bfp_block(f_rms, n_x, xe, x_data);
    read_bfp_block(f_rms, n_o, gold_oe, o_data);
    file_close(f_rms);
    assert n_x = N report "x block n mismatch" severity failure;
    assert n_o = N report "o block n mismatch" severity failure;

    -- ---- read weight from fx_rmsnorm_l0_w.txt ----
    file_open(f_w, "../mem/golden/fx_rmsnorm_l0_w.txt", read_mode);
    read_bfp_block(f_w, n_w, we, w_data);
    file_close(f_w);
    assert n_w = N report "w block n mismatch" severity failure;

    -- ---- load x and w into port vectors ----
    for j in 0 to N-1 loop
      x_mant((j+1)*16-1 downto j*16) <= std_logic_vector(to_signed(x_data(j), 16));
      w_mant((j+1)*16-1 downto j*16) <= std_logic_vector(to_signed(w_data(j), 16));
    end loop;
    x_exp <= xe;
    w_exp <= we;

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

    -- ---- compare outputs ----
    dut_oe := o_exp;
    max_dev := 0;

    -- Align both representations to the finer (larger) exponent so that
    -- comparing integers corresponds to the smallest representable step.
    if dut_oe > gold_oe then
      e_max := dut_oe;
    else
      e_max := gold_oe;
    end if;

    for j in 0 to N-1 loop
      dut_om_j  := to_integer(signed(o_mant((j+1)*16-1 downto j*16)));
      gold_om_j := o_data(j);

      -- Scale each to e_max units (left-shift by the exponent difference).
      dut_scaled  := dut_om_j  * (2 ** (e_max - dut_oe));
      gold_scaled := gold_om_j * (2 ** (e_max - gold_oe));

      if dut_scaled >= gold_scaled then
        dev := dut_scaled - gold_scaled;
      else
        dev := gold_scaled - dut_scaled;
      end if;
      if dev > max_dev then max_dev := dev; end if;

      assert dev <= 2
        report "element " & integer'image(j) &
               " dut=" & integer'image(dut_scaled) &
               " golden=" & integer'image(gold_scaled) &
               " dev=" & integer'image(dev)
        severity failure;
    end loop;

    report "PASS:rmsnorm  max_dev=" & integer'image(max_dev) severity note;
    std.env.finish;
  end process;
end architecture;
