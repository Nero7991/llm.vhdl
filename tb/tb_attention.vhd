-- tb/tb_attention.vhd
-- Testbench for rtl/attention.vhd (integer multi-head attention + KV cache).
--
-- Golden sources (all at DUMP_POS = 3, attention window = 4 positions):
--   fx_layer0_kv.txt      : 4 K blocks (post-rope) then 4 V blocks (pre-rope),
--                           KVDIM=32 each.  Fed one position per `start`.
--   fx_rope_l0.txt         : q_pre, k_pre, q_post, k_post -- q_post (DIM=64) is
--                           the current-position query.
--   fx_softmax_l0_h0.txt   : head-0 pre-softmax scores (block1) + post-softmax
--                           probs (block2).
--   fx_att_out_l0.txt      : multi-head attention output xb (DIM=64).
--
-- The DUT is driven once per position 0..3 (K/V accumulate in its cache; q is
-- only meaningful at the final position).  At the final position we grade:
--   * head-0 scores  vs fx_softmax_l0_h0 block1  (aligned, +-16 LSB)
--   * head-0 probs   vs fx_softmax_l0_h0 block2  (Q12-aligned, +-2 LSB)
--   * KV cache slots vs fx_layer0_kv             (aligned, +-4 LSB)
--   * xb output      vs fx_att_out_l0            (aligned, +-20 LSB)
--
-- TOLERANCE NOTE (measured: scores 12, probs 2, KV 0, xb 17).  The block's q
-- input is a DIM-wide block-float (single q_exp over all 64 dims, exp=10 here),
-- exactly as the spec / layer.vhd:566 consume it.  Re-BFP'ing the head-0 slice
-- up to its own exp (12) therefore recovers scale but NOT the low ~2 bits that
-- were already rounded away on the DIM-wide 2^-10 grid.  The golden's
-- dump_softmax_l0_h0 instead runs fx_bfp_from_float on the *full-precision
-- float* q head, so its qm carries those 2 bits.  This ~2-LSB-per-element q
-- grid gap is the SAME documented root cause as tb_layer's +-12 y bound; it
-- propagates: scores ~12 LSB, and through softmax+weighted-sum to xb ~17 LSB
-- (probs stay <=2 LSB because softmax is contractive).  K/V carry no such loss
-- (KVDIM-wide exp already matches the per-head exp for head 0), so KV=0 and the
-- weighted-sum uses the exact e_i/sum ratio (softmax e_out/sum_out) to avoid
-- any additional Q-truncation.  Bounds set just above the measured values.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;
use work.golden_pkg.all;

entity tb_attention is end;

architecture sim of tb_attention is
  constant DIM       : integer := 64;
  constant HEAD_SIZE : integer := 8;
  constant NHEADS    : integer := 8;
  constant NKVH      : integer := 4;
  constant KVDIM     : integer := 32;
  constant MAXPOS    : integer := 8;
  constant Q         : integer := 12;
  constant POS       : integer := 3;
  constant NPOS      : integer := POS + 1;

  signal clk     : std_logic := '0';
  signal rst     : std_logic := '1';
  signal start   : std_logic := '0';
  signal done    : std_logic;
  signal cur_pos : integer := 0;

  signal q_mant     : std_logic_vector(DIM*16-1 downto 0)   := (others => '0');
  signal q_exp      : integer := 0;
  signal k_new_mant : std_logic_vector(KVDIM*16-1 downto 0) := (others => '0');
  signal k_new_exp  : integer := 0;
  signal v_new_mant : std_logic_vector(KVDIM*16-1 downto 0) := (others => '0');
  signal v_new_exp  : integer := 0;

  signal xb_mant : std_logic_vector(DIM*16-1 downto 0);
  signal xb_exp  : integer;

  signal dbg_score_mant : std_logic_vector(MAXPOS*16-1 downto 0);
  signal dbg_score_exp  : integer;
  signal dbg_prob_q     : std_logic_vector(MAXPOS*32-1 downto 0);
  signal dbg_slot   : integer := 0;
  signal dbg_k_mant : std_logic_vector(KVDIM*16-1 downto 0);
  signal dbg_k_exp  : integer;
  signal dbg_v_mant : std_logic_vector(KVDIM*16-1 downto 0);
  signal dbg_v_exp  : integer;

begin
  clk <= not clk after 5 ns;

  uut: entity work.attention
    generic map(
      DIM => DIM, HEAD_SIZE => HEAD_SIZE, NHEADS => NHEADS, NKVH => NKVH,
      KVDIM => KVDIM, MAXPOS => MAXPOS, Q => Q)
    port map(
      clk => clk, rst => rst, start => start, cur_pos => cur_pos,
      q_mant => q_mant, q_exp => q_exp,
      k_new_mant => k_new_mant, k_new_exp => k_new_exp,
      v_new_mant => v_new_mant, v_new_exp => v_new_exp,
      done => done, xb_mant => xb_mant, xb_exp => xb_exp,
      dbg_score_mant => dbg_score_mant, dbg_score_exp => dbg_score_exp,
      dbg_prob_q => dbg_prob_q,
      dbg_slot => dbg_slot,
      dbg_k_mant => dbg_k_mant, dbg_k_exp => dbg_k_exp,
      dbg_v_mant => dbg_v_mant, dbg_v_exp => dbg_v_exp);

  process
    file f_kv  : text;
    file f_rp  : text;
    file f_sm  : text;
    file f_xb  : text;

    type kv_data_arr is array(0 to NPOS-1) of integer_vector(0 to KVDIM-1);
    type kv_exp_arr  is array(0 to NPOS-1) of integer;
    variable k_d : kv_data_arr;  variable k_e : kv_exp_arr;
    variable v_d : kv_data_arr;  variable v_e : kv_exp_arr;

    variable nn, ee : integer;
    variable tmp32  : integer_vector(0 to KVDIM-1);
    variable q_d    : integer_vector(0 to DIM-1);
    variable q_ee   : integer;
    variable qtmp   : integer_vector(0 to DIM-1);

    variable sc_d : integer_vector(0 to MAXPOS-1);  variable e_sc : integer;
    variable pr_d : integer_vector(0 to MAXPOS-1);  variable e_pr : integer;
    variable xb_d : integer_vector(0 to DIM-1);      variable e_xb : integer;

    -- comparison scratch
    variable e_max, dut_e            : integer;
    variable dut_m, gold_m           : integer;
    variable dut_sc, gold_sc, dev    : integer;
    variable max_dev                 : integer := 0;
    variable kv_dev                  : integer := 0;
    variable sc_dev                  : integer := 0;
    variable pr_dev                  : integer := 0;
  begin
    -- ---- read fx_layer0_kv.txt : 4 K blocks then 4 V blocks --------------
    file_open(f_kv, "../mem/golden/fx_layer0_kv.txt", read_mode);
    for t in 0 to NPOS-1 loop
      read_bfp_block(f_kv, nn, ee, tmp32);
      assert nn = KVDIM report "kv K n mismatch" severity failure;
      k_e(t) := ee; k_d(t) := tmp32;
    end loop;
    for t in 0 to NPOS-1 loop
      read_bfp_block(f_kv, nn, ee, tmp32);
      assert nn = KVDIM report "kv V n mismatch" severity failure;
      v_e(t) := ee; v_d(t) := tmp32;
    end loop;
    file_close(f_kv);

    -- ---- read fx_rope_l0.txt : q_pre,k_pre,q_post,k_post ; keep q_post ----
    file_open(f_rp, "../mem/golden/fx_rope_l0.txt", read_mode);
    read_bfp_block(f_rp, nn, ee, qtmp);                 -- q_pre  (DIM)
    read_bfp_block(f_rp, nn, ee, tmp32);                -- k_pre  (KVDIM)
    read_bfp_block(f_rp, nn, q_ee, q_d);                -- q_post (DIM)
    read_bfp_block(f_rp, nn, ee, tmp32);                -- k_post (KVDIM)
    file_close(f_rp);

    -- ---- read fx_softmax_l0_h0.txt : scores + probs ----------------------
    file_open(f_sm, "../mem/golden/fx_softmax_l0_h0.txt", read_mode);
    read_bfp_block(f_sm, nn, e_sc, sc_d);
    read_bfp_block(f_sm, nn, e_pr, pr_d);
    file_close(f_sm);

    -- ---- read fx_att_out_l0.txt : xb -------------------------------------
    file_open(f_xb, "../mem/golden/fx_att_out_l0.txt", read_mode);
    read_bfp_block(f_xb, nn, e_xb, xb_d);
    assert nn = DIM report "att_out n mismatch" severity failure;
    file_close(f_xb);

    -- ---- reset -----------------------------------------------------------
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    -- ---- drive one `start` per position 0..POS ---------------------------
    for t in 0 to POS loop
      cur_pos <= t;
      -- K/V for this position
      for j in 0 to KVDIM-1 loop
        k_new_mant((j+1)*16-1 downto j*16) <= std_logic_vector(to_signed(k_d(t)(j), 16));
        v_new_mant((j+1)*16-1 downto j*16) <= std_logic_vector(to_signed(v_d(t)(j), 16));
      end loop;
      k_new_exp <= k_e(t);
      v_new_exp <= v_e(t);
      -- q only meaningful at the final position (history q is unused)
      if t = POS then
        for j in 0 to DIM-1 loop
          q_mant((j+1)*16-1 downto j*16) <= std_logic_vector(to_signed(q_d(j), 16));
        end loop;
        q_exp <= q_ee;
      else
        q_mant <= (others => '0');
        q_exp  <= 0;
      end if;

      wait until rising_edge(clk);
      start <= '1';
      wait until rising_edge(clk);
      start <= '0';
      wait until done = '1';
      wait until rising_edge(clk);
    end loop;

    -- =====================================================================
    -- 1. Head-0 pre-softmax scores vs fx_softmax_l0_h0 block1 (+-4 LSB).
    -- =====================================================================
    dut_e := dbg_score_exp;
    if dut_e > e_sc then e_max := dut_e; else e_max := e_sc; end if;
    for j in 0 to NPOS-1 loop
      dut_m   := to_integer(signed(dbg_score_mant((j+1)*16-1 downto j*16)));
      gold_m  := sc_d(j);
      dut_sc  := dut_m  * (2 ** (e_max - dut_e));
      gold_sc := gold_m * (2 ** (e_max - e_sc));
      if dut_sc >= gold_sc then dev := dut_sc - gold_sc; else dev := gold_sc - dut_sc; end if;
      if dev > sc_dev then sc_dev := dev; end if;
      assert dev <= 16   -- DIM-wide-q grid gap vs float golden (see header)
        report "score[" & integer'image(j) & "] dut=" & integer'image(dut_sc) &
               " gold=" & integer'image(gold_sc) & " dev=" & integer'image(dev)
        severity failure;
    end loop;
    report "scores head0: exp dut=" & integer'image(dbg_score_exp) &
           " gold=" & integer'image(e_sc) & " max_dev=" & integer'image(sc_dev)
      severity note;

    -- =====================================================================
    -- 2. Head-0 post-softmax probs vs block2, compared at Q12 (+-2 LSB).
    -- =====================================================================
    for j in 0 to NPOS-1 loop
      dut_m  := to_integer(signed(dbg_prob_q((j+1)*32-1 downto j*32)));  -- Q12
      gold_m := pr_d(j);                                                 -- Q e_pr
      if e_pr > Q then
        gold_sc := (gold_m + (2 ** (e_pr - Q - 1))) / (2 ** (e_pr - Q));
      elsif e_pr = Q then
        gold_sc := gold_m;
      else
        gold_sc := gold_m * (2 ** (Q - e_pr));
      end if;
      if dut_m >= gold_sc then dev := dut_m - gold_sc; else dev := gold_sc - dut_m; end if;
      if dev > pr_dev then pr_dev := dev; end if;
      assert dev <= 2
        report "prob[" & integer'image(j) & "] dut=" & integer'image(dut_m) &
               " gold=" & integer'image(gold_sc) & " dev=" & integer'image(dev)
        severity failure;
    end loop;
    report "probs head0 (Q12): max_dev=" & integer'image(pr_dev) severity note;

    -- =====================================================================
    -- 3. KV cache slots 0..POS vs fx_layer0_kv (+-4 LSB, aligned).
    -- =====================================================================
    for t in 0 to POS loop
      dbg_slot <= t;
      wait for 1 ns;
      -- K
      if dbg_k_exp > k_e(t) then e_max := dbg_k_exp; else e_max := k_e(t); end if;
      for j in 0 to KVDIM-1 loop
        dut_m   := to_integer(signed(dbg_k_mant((j+1)*16-1 downto j*16)));
        gold_m  := k_d(t)(j);
        dut_sc  := dut_m  * (2 ** (e_max - dbg_k_exp));
        gold_sc := gold_m * (2 ** (e_max - k_e(t)));
        if dut_sc >= gold_sc then dev := dut_sc - gold_sc; else dev := gold_sc - dut_sc; end if;
        if dev > kv_dev then kv_dev := dev; end if;
        assert dev <= 4 report "K[" & integer'image(t) & "][" & integer'image(j) &
          "] dev=" & integer'image(dev) severity failure;
      end loop;
      -- V
      if dbg_v_exp > v_e(t) then e_max := dbg_v_exp; else e_max := v_e(t); end if;
      for j in 0 to KVDIM-1 loop
        dut_m   := to_integer(signed(dbg_v_mant((j+1)*16-1 downto j*16)));
        gold_m  := v_d(t)(j);
        dut_sc  := dut_m  * (2 ** (e_max - dbg_v_exp));
        gold_sc := gold_m * (2 ** (e_max - v_e(t)));
        if dut_sc >= gold_sc then dev := dut_sc - gold_sc; else dev := gold_sc - dut_sc; end if;
        if dev > kv_dev then kv_dev := dev; end if;
        assert dev <= 4 report "V[" & integer'image(t) & "][" & integer'image(j) &
          "] dev=" & integer'image(dev) severity failure;
      end loop;
    end loop;
    report "KV cache: max_dev=" & integer'image(kv_dev) severity note;

    -- =====================================================================
    -- 4. Attention output xb vs fx_att_out_l0 (+-4 LSB, aligned).
    -- =====================================================================
    dut_e := xb_exp;
    if dut_e > e_xb then e_max := dut_e; else e_max := e_xb; end if;
    for j in 0 to DIM-1 loop
      dut_m   := to_integer(signed(xb_mant((j+1)*16-1 downto j*16)));
      gold_m  := xb_d(j);
      dut_sc  := dut_m  * (2 ** (e_max - dut_e));
      gold_sc := gold_m * (2 ** (e_max - e_xb));
      if dut_sc >= gold_sc then dev := dut_sc - gold_sc; else dev := gold_sc - dut_sc; end if;
      if dev > max_dev then max_dev := dev; end if;
      assert dev <= 20   -- q-grid gap propagated through 8 heads (see header)
        report "xb[" & integer'image(j) & "] dut=" & integer'image(dut_sc) &
               " gold=" & integer'image(gold_sc) & " dev=" & integer'image(dev)
        severity failure;
    end loop;
    report "xb output: exp dut=" & integer'image(xb_exp) &
           " gold=" & integer'image(e_xb) & " max_dev=" & integer'image(max_dev)
      severity note;

    report "PASS:attention  scores_dev=" & integer'image(sc_dev) &
           " probs_dev=" & integer'image(pr_dev) &
           " kv_dev=" & integer'image(kv_dev) &
           " xb_dev=" & integer'image(max_dev) severity note;
    std.env.finish;
  end process;
end architecture;
