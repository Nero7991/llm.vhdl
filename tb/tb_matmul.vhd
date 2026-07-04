-- tb/tb_matmul.vhd
-- GHDL testbench for rtl/matmul.vhd -- the reusable time-multiplexed block-float
-- matrix-vector block (one shared mac_array across all output rows).
--
-- Two cases, both driven by the SAME activation x = the attention-RMSNorm OUTPUT
-- vector (xb), parsed from the OUTPUT (2nd) BFP section of
-- mem/golden/fx_rmsnorm_l0.txt (N=64, EXP 13):
--
--   1. WQ layer 0, CLAMP_NONNEG=true  -> expected = q_pre = 1st BFP section of
--      mem/golden/fx_rope_l0.txt (N=64, EXP 10).
--   2. WK layer 0, CLAMP_NONNEG=false -> expected = k_pre = 2nd BFP section of
--      mem/golden/fx_rope_l0.txt (N=32, EXP 10).
--
-- These are the WQ/WK matmul outputs BEFORE RoPE, exactly as layer.vhd steps
-- 2 / 2b produce them.  Tolerance-grade goldens: assert exponent exact and
-- per-element max_dev <= 1.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;
use std.env.all;
use work.weights_pkg.all;   -- WQ/WQ_MULT/WQ_SHIFT/WK/... slices

entity tb_matmul is end;

architecture sim of tb_matmul is
  constant DIM   : integer := 64;   -- IN_COLS for both, OUT_ROWS for WQ
  constant KVDIM : integer := 32;   -- OUT_ROWS for WK

  signal clk   : std_logic := '0';
  signal rst   : std_logic := '1';
  signal start : std_logic := '0';

  signal x_mant : std_logic_vector(DIM*16-1 downto 0) := (others=>'0');
  signal x_exp  : integer := 0;

  signal done_q  : std_logic;
  signal oq_mant : std_logic_vector(DIM*16-1 downto 0);
  signal oq_exp  : integer;

  signal done_k  : std_logic;
  signal ok_mant : std_logic_vector(KVDIM*16-1 downto 0);
  signal ok_exp  : integer;
begin
  clk <= not clk after 5 ns;

  -- WQ: 64x64, clamp shift_o >= 0
  uut_q: entity work.matmul
    generic map(OUT_ROWS=>DIM, IN_COLS=>DIM, CLAMP_NONNEG=>true,
                WMANT=>WQ(0 to WQ_STRIDE-1),
                WMULT=>WQ_MULT(0 to DIM-1),
                WSHFT=>WQ_SHIFT(0 to DIM-1))
    port map(clk=>clk, rst=>rst, start=>start,
             x_mant=>x_mant, x_exp=>x_exp,
             done=>done_q, o_mant=>oq_mant, o_exp=>oq_exp);

  -- WK: 32x64, shift_o may be negative
  uut_k: entity work.matmul
    generic map(OUT_ROWS=>KVDIM, IN_COLS=>DIM, CLAMP_NONNEG=>false,
                WMANT=>WK(0 to WK_STRIDE-1),
                WMULT=>WK_MULT(0 to KVDIM-1),
                WSHFT=>WK_SHIFT(0 to KVDIM-1))
    port map(clk=>clk, rst=>rst, start=>start,
             x_mant=>x_mant, x_exp=>x_exp,
             done=>done_k, o_mant=>ok_mant, o_exp=>ok_exp);

  process
    file     gf     : text;
    variable L      : line;
    variable status : file_open_status;
    variable n_r, e_r : integer;
    variable w3     : string(1 to 3);
    variable itmp   : integer;

    variable xv     : integer;
    variable q_gold : integer_vector(0 to DIM-1);
    variable q_ge   : integer;
    variable k_gold : integer_vector(0 to KVDIM-1);
    variable k_ge   : integer;

    -- read one BFP section: N line, "EXP e" line, then N mantissas into arr.
    procedure read_section(variable e_out : out integer;
                           variable arr : out integer_vector) is
    begin
      readline(gf, L); read(L, n_r);            -- N (ignored, arr length known)
      readline(gf, L); read(L, w3); read(L, e_out); -- "EXP <e>"
      readline(gf, L);
      for i in arr'range loop read(L, arr(i)); end loop;
    end procedure;

    variable got, dev, max_dev : integer;
  begin
    -- ---- parse activation x = xb (2nd/OUTPUT section of fx_rmsnorm_l0) ----
    file_open(status, gf, "../mem/golden/fx_rmsnorm_l0.txt", read_mode);
    assert status = open_ok report "cannot open fx_rmsnorm_l0.txt" severity failure;
    -- skip 1st (input) section: N, EXP, mantissas
    readline(gf, L); readline(gf, L); readline(gf, L);
    -- 2nd (output) section = xb
    readline(gf, L); read(L, n_r);
    readline(gf, L); read(L, w3); read(L, e_r);
    x_exp <= e_r;
    readline(gf, L);
    for j in 0 to DIM-1 loop
      read(L, xv);
      x_mant((j+1)*16-1 downto j*16) <= std_logic_vector(to_signed(xv, 16));
    end loop;
    file_close(gf);

    -- ---- parse expected q_pre / k_pre from fx_rope_l0 ----
    file_open(status, gf, "../mem/golden/fx_rope_l0.txt", read_mode);
    assert status = open_ok report "cannot open fx_rope_l0.txt" severity failure;
    read_section(q_ge, q_gold);   -- 1st: q_pre (64, EXP 10)
    read_section(k_ge, k_gold);   -- 2nd: k_pre (32, EXP 10)
    file_close(gf);

    -- ---- reset + single start pulse ----
    rst <= '1'; wait for 40 ns; wait until rising_edge(clk); rst <= '0';
    wait until rising_edge(clk);
    start <= '1'; wait until rising_edge(clk); start <= '0';

    -- WQ has more rows than WK, so done_q pulses last; both outputs then hold.
    wait until rising_edge(clk) and done_q = '1';
    wait until rising_edge(clk);

    -- ---- Case 1: WQ ----
    assert oq_exp = q_ge
      report "FAIL:matmul_wq  o_exp="&integer'image(oq_exp)
             &" expected "&integer'image(q_ge) severity failure;
    max_dev := 0;
    for i in 0 to DIM-1 loop
      got := to_integer(signed(oq_mant((i+1)*16-1 downto i*16)));
      dev := got - q_gold(i); if dev < 0 then dev := -dev; end if;
      if dev > max_dev then max_dev := dev; end if;
    end loop;
    assert max_dev <= 1
      report "FAIL:matmul_wq  max_dev="&integer'image(max_dev) severity failure;
    report "PASS:matmul_wq max_dev="&integer'image(max_dev) severity note;

    -- ---- Case 2: WK ----
    assert ok_exp = k_ge
      report "FAIL:matmul_wk  o_exp="&integer'image(ok_exp)
             &" expected "&integer'image(k_ge) severity failure;
    max_dev := 0;
    for i in 0 to KVDIM-1 loop
      got := to_integer(signed(ok_mant((i+1)*16-1 downto i*16)));
      dev := got - k_gold(i); if dev < 0 then dev := -dev; end if;
      if dev > max_dev then max_dev := dev; end if;
    end loop;
    assert max_dev <= 1
      report "FAIL:matmul_wk  max_dev="&integer'image(max_dev) severity failure;
    report "PASS:matmul_wk max_dev="&integer'image(max_dev) severity note;

    finish;
  end process;
end architecture;
