-- tb/tb_matmul_rt.vhd
-- GHDL testbench for rtl/matmul_rt.vhd -- the runtime-weight-addressed shared
-- matrix-vector block (ONE instance, weights fetched from BRAM by mat_sel/layer).
--
-- A SINGLE matmul_rt instance is driven three times, proving one block serves
-- multiple matmuls by runtime selection:
--   1. WQ layer 0 (mat_sel=0, layer=0) -> expected q_pre = 1st BFP section of
--      mem/golden/fx_rope_l0.txt (N=64, EXP 10), clamp shift>=0.
--   2. WK layer 0 (mat_sel=1, layer=0) -> expected k_pre = 2nd BFP section
--      (N=32, EXP 10), shift may be negative.
--   3. (bonus) WQ layer 1 (mat_sel=0, layer=1) -> must differ from WQ layer 0,
--      exercising the runtime layer index (different weights from the ROM).
--
-- Activation x for all three = the attention-RMSNorm OUTPUT vector (xb), the
-- OUTPUT (2nd) BFP section of mem/golden/fx_rmsnorm_l0.txt (N=64, EXP 13).
-- Tolerance-grade goldens: assert exponent exact and per-element max_dev <= 1.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;
use std.env.all;

entity tb_matmul_rt is end;

architecture sim of tb_matmul_rt is
  constant MAXR  : integer := 172;
  constant MAXC  : integer := 172;
  constant DIM   : integer := 64;   -- WQ rows / both in_cols
  constant KVDIM : integer := 32;   -- WK rows

  signal clk   : std_logic := '0';
  signal rst   : std_logic := '1';
  signal start : std_logic := '0';
  signal mat_sel : integer := 0;
  signal layer   : integer := 0;

  signal x_mant : std_logic_vector(MAXC*16-1 downto 0) := (others=>'0');
  signal x_exp  : integer := 0;

  signal done   : std_logic;
  signal o_mant : std_logic_vector(MAXR*16-1 downto 0);
  signal o_exp  : integer;
begin
  clk <= not clk after 5 ns;

  uut: entity work.matmul_rt
    generic map(MAXROWS=>MAXR, MAXCOLS=>MAXC)
    port map(clk=>clk, rst=>rst, start=>start, mat_sel=>mat_sel, layer=>layer,
             x_mant=>x_mant, x_exp=>x_exp, done=>done,
             o_mant=>o_mant, o_exp=>o_exp);

  process
    file     gf     : text;
    variable L      : line;
    variable status : file_open_status;
    variable n_r    : integer;
    variable w3     : string(1 to 3);
    variable xv     : integer;

    variable q_gold : integer_vector(0 to DIM-1);
    variable q_ge   : integer;
    variable k_gold : integer_vector(0 to KVDIM-1);
    variable k_ge   : integer;

    -- read one BFP section: N line, "EXP e" line, then N mantissas into arr.
    procedure read_section(variable e_out : out integer;
                           variable arr : out integer_vector) is
    begin
      readline(gf, L); read(L, n_r);
      readline(gf, L); read(L, w3); read(L, e_out);
      readline(gf, L);
      for i in arr'range loop read(L, arr(i)); end loop;
    end procedure;

    -- run one pass: select matrix/layer, pulse start, wait for done.
    procedure run_pass(sel : integer; lyr : integer) is
    begin
      mat_sel <= sel; layer <= lyr;
      wait until rising_edge(clk);
      start <= '1'; wait until rising_edge(clk); start <= '0';
      wait until rising_edge(clk) and done = '1';
    end procedure;

    variable got, dev, max_dev : integer;
    variable wq_max, wk_max    : integer;
    variable l0_mant           : std_logic_vector(MAXR*16-1 downto 0);
    variable diff              : integer;
  begin
    -- ---- parse activation x = xb (2nd/OUTPUT section of fx_rmsnorm_l0) ----
    file_open(status, gf, "../mem/golden/fx_rmsnorm_l0.txt", read_mode);
    assert status = open_ok report "cannot open fx_rmsnorm_l0.txt" severity failure;
    readline(gf, L); readline(gf, L); readline(gf, L);   -- skip 1st (input) section
    readline(gf, L); read(L, n_r);
    readline(gf, L); read(L, w3); read(L, n_r);          -- reuse n_r for exp
    x_exp <= n_r;
    readline(gf, L);
    for j in 0 to DIM-1 loop
      read(L, xv);
      x_mant((j+1)*16-1 downto j*16) <= std_logic_vector(to_signed(xv, 16));
    end loop;
    -- upper columns (DIM..MAXC-1) stay 0 (masked internally too)
    file_close(gf);

    -- ---- parse expected q_pre / k_pre from fx_rope_l0 ----
    file_open(status, gf, "../mem/golden/fx_rope_l0.txt", read_mode);
    assert status = open_ok report "cannot open fx_rope_l0.txt" severity failure;
    read_section(q_ge, q_gold);   -- 1st: q_pre (64, EXP 10)
    read_section(k_ge, k_gold);   -- 2nd: k_pre (32, EXP 10)
    file_close(gf);

    -- ---- reset ----
    rst <= '1'; wait for 40 ns; wait until rising_edge(clk); rst <= '0';
    wait until rising_edge(clk);

    -- ================= Case 1: WQ layer 0 =================
    run_pass(0, 0);
    assert o_exp = q_ge
      report "FAIL:matmul_rt_wq  o_exp="&integer'image(o_exp)
             &" expected "&integer'image(q_ge) severity failure;
    max_dev := 0;
    for i in 0 to DIM-1 loop
      got := to_integer(signed(o_mant((i+1)*16-1 downto i*16)));
      dev := got - q_gold(i); if dev < 0 then dev := -dev; end if;
      if dev > max_dev then max_dev := dev; end if;
    end loop;
    assert max_dev <= 1
      report "FAIL:matmul_rt_wq  max_dev="&integer'image(max_dev) severity failure;
    wq_max  := max_dev;
    l0_mant := o_mant;   -- keep WQ-L0 output for the layer-index bonus check

    -- ================= Case 2: WK layer 0 =================
    run_pass(1, 0);
    assert o_exp = k_ge
      report "FAIL:matmul_rt_wk  o_exp="&integer'image(o_exp)
             &" expected "&integer'image(k_ge) severity failure;
    max_dev := 0;
    for i in 0 to KVDIM-1 loop
      got := to_integer(signed(o_mant((i+1)*16-1 downto i*16)));
      dev := got - k_gold(i); if dev < 0 then dev := -dev; end if;
      if dev > max_dev then max_dev := dev; end if;
    end loop;
    assert max_dev <= 1
      report "FAIL:matmul_rt_wk  max_dev="&integer'image(max_dev) severity failure;
    wk_max := max_dev;

    -- ================= Case 3 (bonus): WQ layer 1 =================
    -- Same matrix (WQ) and same activation, but layer=1 addresses different ROM
    -- weights, so the packed output MUST differ from layer 0.
    run_pass(0, 1);
    diff := 0;
    for i in 0 to DIM-1 loop
      if o_mant((i+1)*16-1 downto i*16) /= l0_mant((i+1)*16-1 downto i*16) then
        diff := diff + 1;
      end if;
    end loop;
    assert diff > 0
      report "FAIL:matmul_rt_wq_l1  layer index had no effect (output identical to L0)"
      severity failure;
    report "matmul_rt WQ L1 differs from L0 in "&integer'image(diff)&"/64 rows" severity note;

    report "PASS:matmul_rt wq="&integer'image(wq_max)&" wk="&integer'image(wk_max)
      severity note;
    finish;
  end process;
end architecture;
