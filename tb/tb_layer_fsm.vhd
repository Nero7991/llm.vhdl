-- tb/tb_layer_fsm.vhd
-- Integration testbench for rtl/layer_fsm.vhd -- the time-multiplexed FSM that
-- runs ONE transformer layer by COMPOSING the validated sub-unit entities
-- (rmsnorm/matmul/rope/attention/swiglu) instead of layer.vhd's inline `real`
-- datapath.
--
-- Mirrors tb/tb_layer.vhd's scenario exactly (POS=3, KV history for positions
-- 0..2 fed via ports, input x from fx_layer0_in.txt) and grades the FSM's layer
-- output y_mant/y_exp against fx_layer0_out.txt (aligned int16 domain).  This is
-- the decisive end-to-end test that attention + the whole datapath compose
-- correctly: if the layer output lands within tolerance, every sub-block was
-- sequenced and routed correctly.
--
-- Bound: layer.vhd's own tb passes at y max_dev=12 (int16-BFP rounding floor
-- amplified through the FFN, documented as inherent, not a bug).  The FSM adds
-- one extra source of the same class -- attention.vhd's integer softmax/wsum
-- (+-a-few-LSB vs layer.vhd's float glue) and the matmul-based WO/W2 re-BFP
-- before the exp-aligned integer residual add -- so the bound is set to 16 and
-- the actual max_dev is REPORTED.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;
use work.golden_pkg.all;

entity tb_layer_fsm is end;

architecture sim of tb_layer_fsm is
  constant DIM       : integer := 64;
  constant HIDDEN    : integer := 172;
  constant NHEADS    : integer := 8;
  constant NKVH      : integer := 4;
  constant KVDIM     : integer := 32;
  constant HEAD_SIZE : integer := 8;
  constant MAXPOS    : integer := 8;
  constant POS       : integer := 3;
  constant NPOS      : integer := POS + 1;

  signal clk     : std_logic := '0';
  signal rst     : std_logic := '1';
  signal start   : std_logic := '0';
  signal done    : std_logic;
  signal cur_pos : integer := POS;

  signal x_mant : std_logic_vector(DIM*16-1 downto 0) := (others => '0');
  signal x_exp  : integer := 0;

  signal k_mant       : std_logic_vector(MAXPOS*KVDIM*16-1 downto 0) := (others => '0');
  signal k_exp_packed : std_logic_vector(MAXPOS*32-1 downto 0)        := (others => '0');
  signal v_mant       : std_logic_vector(MAXPOS*KVDIM*16-1 downto 0) := (others => '0');
  signal v_exp_packed : std_logic_vector(MAXPOS*32-1 downto 0)        := (others => '0');

  signal y_mant : std_logic_vector(DIM*16-1 downto 0);
  signal y_exp  : integer;

  signal k_out_mant : std_logic_vector(KVDIM*16-1 downto 0);
  signal k_out_exp  : integer;
  signal v_out_mant : std_logic_vector(KVDIM*16-1 downto 0);
  signal v_out_exp  : integer;

begin
  clk <= not clk after 5 ns;

  uut: entity work.layer_fsm
    generic map(
      DIM => DIM, HIDDEN => HIDDEN, NHEADS => NHEADS, NKVH => NKVH,
      KVDIM => KVDIM, HEAD_SIZE => HEAD_SIZE, MAXPOS => MAXPOS, POS => POS)
    port map(
      clk => clk, rst => rst, start => start, cur_pos => cur_pos,
      x_mant => x_mant, x_exp => x_exp,
      k_mant => k_mant, k_exp_packed => k_exp_packed,
      v_mant => v_mant, v_exp_packed => v_exp_packed,
      done => done, y_mant => y_mant, y_exp => y_exp,
      k_out_mant => k_out_mant, k_out_exp => k_out_exp,
      v_out_mant => v_out_mant, v_out_exp => v_out_exp);

  process
    file f_in  : text;
    file f_kv  : text;
    file f_out : text;

    variable n_x  : integer;
    variable x_e  : integer;
    variable x_d  : integer_vector(0 to DIM-1);

    variable kv_n : integer;
    variable kv_e : integer;
    variable kv_d : integer_vector(0 to KVDIM-1);

    variable n_o    : integer;
    variable gold_e : integer;
    variable gold_d : integer_vector(0 to DIM-1);

    variable gk_e : integer;
    variable gk_d : integer_vector(0 to KVDIM-1);
    variable gv_e : integer;
    variable gv_d : integer_vector(0 to KVDIM-1);

    variable dut_e    : integer;
    variable e_max    : integer;
    variable dut_m    : integer;
    variable gold_m   : integer;
    variable dut_sc   : integer;
    variable gold_sc  : integer;
    variable dev      : integer;
    variable max_dev  : integer := 0;
    variable kv_max_dev : integer := 0;
  begin
    -- ---- read fx_layer0_in.txt (n=64) ------------------------------------
    file_open(f_in, "../mem/golden/fx_layer0_in.txt", read_mode);
    read_bfp_block(f_in, n_x, x_e, x_d);
    file_close(f_in);
    assert n_x = DIM report "fx_layer0_in.txt n mismatch" severity failure;
    for j in 0 to DIM-1 loop
      x_mant((j+1)*16-1 downto j*16) <= std_logic_vector(to_signed(x_d(j), 16));
    end loop;
    x_exp <= x_e;

    -- ---- read fx_layer0_kv.txt : 4 K blocks then 4 V blocks --------------
    file_open(f_kv, "../mem/golden/fx_layer0_kv.txt", read_mode);
    for t in 0 to NPOS-1 loop
      read_bfp_block(f_kv, kv_n, kv_e, kv_d);
      assert kv_n = KVDIM report "kv K n mismatch" severity failure;
      if t < POS then
        for j in 0 to KVDIM-1 loop
          k_mant((t*KVDIM+j+1)*16-1 downto (t*KVDIM+j)*16) <=
            std_logic_vector(to_signed(kv_d(j), 16));
        end loop;
        k_exp_packed((t+1)*32-1 downto t*32) <= std_logic_vector(to_signed(kv_e, 32));
      else
        gk_e := kv_e; gk_d := kv_d;
      end if;
    end loop;
    for t in 0 to NPOS-1 loop
      read_bfp_block(f_kv, kv_n, kv_e, kv_d);
      assert kv_n = KVDIM report "kv V n mismatch" severity failure;
      if t < POS then
        for j in 0 to KVDIM-1 loop
          v_mant((t*KVDIM+j+1)*16-1 downto (t*KVDIM+j)*16) <=
            std_logic_vector(to_signed(kv_d(j), 16));
        end loop;
        v_exp_packed((t+1)*32-1 downto t*32) <= std_logic_vector(to_signed(kv_e, 32));
      else
        gv_e := kv_e; gv_d := kv_d;
      end if;
    end loop;
    file_close(f_kv);

    -- ---- read fx_layer0_out.txt (n=64) -----------------------------------
    file_open(f_out, "../mem/golden/fx_layer0_out.txt", read_mode);
    read_bfp_block(f_out, n_o, gold_e, gold_d);
    file_close(f_out);
    assert n_o = DIM report "fx_layer0_out.txt n mismatch" severity failure;

    -- ---- reset then pulse start ------------------------------------------
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);
    start <= '1';
    wait until rising_edge(clk);
    start <= '0';

    wait until done = '1';
    wait for 1 ns;

    -- ---- compare y output (aligned int16 domain) -------------------------
    dut_e := y_exp;
    report "DUT exp=" & integer'image(dut_e) & " golden exp=" & integer'image(gold_e) severity note;
    if dut_e > gold_e then e_max := dut_e; else e_max := gold_e; end if;
    for j in 0 to DIM-1 loop
      dut_m   := to_integer(signed(y_mant((j+1)*16-1 downto j*16)));
      gold_m  := gold_d(j);
      dut_sc  := dut_m  * (2 ** (e_max - dut_e));
      gold_sc := gold_m * (2 ** (e_max - gold_e));
      if dut_sc >= gold_sc then dev := dut_sc - gold_sc;
      else                       dev := gold_sc - dut_sc; end if;
      if dev > max_dev then max_dev := dev; end if;
      assert dev <= 16
        report "element " & integer'image(j) &
               " dut=" & integer'image(dut_sc) &
               " golden=" & integer'image(gold_sc) &
               " dev=" & integer'image(dev)
        severity failure;
    end loop;

    -- ---- compare computed K[POS]/V[POS] to golden block POS (+-4 LSB) ----
    if k_out_exp > gk_e then e_max := k_out_exp; else e_max := gk_e; end if;
    for j in 0 to KVDIM-1 loop
      dut_m   := to_integer(signed(k_out_mant((j+1)*16-1 downto j*16)));
      gold_m  := gk_d(j);
      dut_sc  := dut_m  * (2 ** (e_max - k_out_exp));
      gold_sc := gold_m * (2 ** (e_max - gk_e));
      if dut_sc >= gold_sc then dev := dut_sc - gold_sc;
      else                       dev := gold_sc - dut_sc; end if;
      if dev > kv_max_dev then kv_max_dev := dev; end if;
      assert dev <= 4
        report "k_out element " & integer'image(j) & " dev=" & integer'image(dev)
        severity failure;
    end loop;
    if v_out_exp > gv_e then e_max := v_out_exp; else e_max := gv_e; end if;
    for j in 0 to KVDIM-1 loop
      dut_m   := to_integer(signed(v_out_mant((j+1)*16-1 downto j*16)));
      gold_m  := gv_d(j);
      dut_sc  := dut_m  * (2 ** (e_max - v_out_exp));
      gold_sc := gold_m * (2 ** (e_max - gv_e));
      if dut_sc >= gold_sc then dev := dut_sc - gold_sc;
      else                       dev := gold_sc - dut_sc; end if;
      if dev > kv_max_dev then kv_max_dev := dev; end if;
      assert dev <= 4
        report "v_out element " & integer'image(j) & " dev=" & integer'image(dev)
        severity failure;
    end loop;

    report "PASS:layer_fsm  max_dev=" & integer'image(max_dev) &
           "  kv_max_dev=" & integer'image(kv_max_dev) severity note;
    std.env.finish;
  end process;
end architecture;
