-- tb_attn_cmp.vhd -- synth-vs-behavioral comparison for attention_ml.
-- Drives the behavioral RTL and the post-synth netlist with the SAME
-- KV-write-then-attend sequence (positions 0..NPOS-1, layer 0) and flags any
-- divergence in xb_mant/xb_exp -- catches synthesis/behavioral mismatches
-- (BRAM latency, divider, BFP shift, sequencing) that behavioral sim hides.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.env.all;
library beh;

entity tb_attn_cmp is end;
architecture sim of tb_attn_cmp is
  constant DIM   : integer := 64;
  constant KVDIM : integer := 32;
  constant MAXPOS: integer := 24;
  constant NPOS  : integer := 6;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal start : std_logic := '0';
  signal layer : integer := 0;
  signal cur_pos : integer := 0;
  signal q_mant : std_logic_vector(DIM*16-1 downto 0) := (others=>'0');
  signal q_exp  : integer := 10;
  signal k_mant : std_logic_vector(KVDIM*16-1 downto 0) := (others=>'0');
  signal k_exp  : integer := 10;
  signal v_mant : std_logic_vector(KVDIM*16-1 downto 0) := (others=>'0');
  signal v_exp  : integer := 10;

  signal done_b, done_n : std_logic;
  signal xb_b, xb_n : std_logic_vector(DIM*16-1 downto 0);
  signal xe_b, xe_n : integer;
  signal dsc_b,dsc_n, dsm_b,dsm_n, dnm_b,dnm_n : integer;

  -- deterministic small signed value for (pos,index)
  function pv(pos, idx, salt : integer) return integer is
    variable m : integer;
  begin
    m := ((pos*37 + idx*17 + salt*5) mod 121) - 60;  -- [-60,60]
    return m;
  end function;
begin
  clk <= not clk after 5 ns;

  u_beh: entity beh.attention_ml
    generic map(DIM=>DIM, MAXPOS=>MAXPOS)
    port map(clk=>clk,rst=>rst,start=>start,layer=>layer,cur_pos=>cur_pos,
             q_mant=>q_mant,q_exp=>q_exp,k_new_mant=>k_mant,k_new_exp=>k_exp,
             v_new_mant=>v_mant,v_new_exp=>v_exp,done=>done_b,xb_mant=>xb_b,xb_exp=>xe_b,
             dbg_sc=>dsc_b,dbg_sum=>dsm_b,dbg_num=>dnm_b);

  u_net: entity work.attention_ml_net_ps
    generic map(DIM=>DIM, MAXPOS=>MAXPOS)
    port map(clk=>clk,rst=>rst,start=>start,layer=>layer,cur_pos=>cur_pos,
             q_mant=>q_mant,q_exp=>q_exp,k_new_mant=>k_mant,k_new_exp=>k_exp,
             v_new_mant=>v_mant,v_new_exp=>v_exp,done=>done_n,xb_mant=>xb_n,xb_exp=>xe_n,
             dbg_sc=>dsc_n,dbg_sum=>dsm_n,dbg_num=>dnm_n);

  process
    variable fails : integer := 0;
  begin
    wait until rising_edge(clk); wait until rising_edge(clk);
    rst <= '0'; wait until rising_edge(clk);

    for p in 0 to NPOS-1 loop
      -- deterministic q/k/v for this position
      for i in 0 to DIM-1 loop
        q_mant((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(pv(p,i,1),16));
      end loop;
      for i in 0 to KVDIM-1 loop
        k_mant((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(pv(p,i,2),16));
        v_mant((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(pv(p,i,3),16));
      end loop;
      cur_pos <= p;
      wait until rising_edge(clk);
      start <= '1'; wait until rising_edge(clk); start <= '0';
      -- wait for both done
      wait until (done_b = '1' and done_n = '1') for 500 us;
      wait for 1 ns;
      report "pos=" & integer'image(p) &
             " | vref b=" & integer'image(dsc_b) & " n=" & integer'image(dsc_n) &
             " | sum_l b=" & integer'image(dsm_b) & " n=" & integer'image(dsm_n) &
             " | num_s b=" & integer'image(dnm_b) & " n=" & integer'image(dnm_n) &
             " | xe b=" & integer'image(xe_b) & " n=" & integer'image(xe_n) severity note;
      if xb_b /= xb_n or xe_b /= xe_n then
        fails := fails + 1;
        report "MISMATCH pos=" & integer'image(p) &
               " xe_b=" & integer'image(xe_b) & " xe_n=" & integer'image(xe_n) &
               " mant_eq=" & boolean'image(xb_b = xb_n) severity warning;
      else
        report "pos=" & integer'image(p) & " MATCH (xe=" & integer'image(xe_b) & ")" severity note;
      end if;
      wait until rising_edge(clk);
    end loop;

    if fails = 0 then report "PASS:attn_cmp all " & integer'image(NPOS) & " positions match" severity note;
    else report "FAIL:attn_cmp " & integer'image(fails) & " mismatches" severity note; end if;
    finish;
  end process;
end architecture;
