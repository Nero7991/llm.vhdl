-- sim/tb_swchain_cmp.vhd
-- Netlist-vs-behavioral comparison for the swiglu -> vec_mem(BRAM) -> bfp_pack
-- chain (the LUT-reduction "increment 1").  Drives the BEHAVIORAL wrapper
-- (beh.sw_chain, plain RTL simulated) and the SYNTHESIZED netlist wrapper
-- (work sw_chain_net, from write_vhdl -mode funcsim) with IDENTICAL stimulus in
-- lockstep, and compares o_mant (all 172 int16) and o_exp element-by-element.
--
-- Stimulus:
--   test 0 : the REAL layer-0 swiglu inputs from mem/golden/fx_swiglu_l0.txt
--            (hb EXP 13, hb2 EXP 14) -- the exact engine values.
--   tests 1..8 : deterministic patterns with varied exponents / magnitudes /
--            saturation edges to exercise the read-ahead pointer, the max scan,
--            the shift, and the saturate paths.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.env.all;
use std.textio.all;
library beh;
use beh.golden_pkg.all;

entity tb_swchain_cmp is end;

architecture sim of tb_swchain_cmp is
  constant N : integer := 172;

  signal clk   : std_logic := '0';
  signal rst   : std_logic := '1';
  signal start : std_logic := '0';

  signal hb_mant  : std_logic_vector(N*16-1 downto 0) := (others => '0');
  signal hb2_mant : std_logic_vector(N*16-1 downto 0) := (others => '0');
  signal hb_exp   : std_logic_vector(31 downto 0) := (others => '0');
  signal hb2_exp  : std_logic_vector(31 downto 0) := (others => '0');

  signal done_b, done_n : std_logic;
  signal ob, onet       : std_logic_vector(N*16-1 downto 0);
  signal oeb, oen       : std_logic_vector(31 downto 0);

  component sw_chain is
    port(clk, rst, start : in std_logic;
         hb_mant  : in  std_logic_vector(N*16-1 downto 0);
         hb_exp   : in  std_logic_vector(31 downto 0);
         hb2_mant : in  std_logic_vector(N*16-1 downto 0);
         hb2_exp  : in  std_logic_vector(31 downto 0);
         done     : out std_logic;
         o_mant   : out std_logic_vector(N*16-1 downto 0);
         o_exp    : out std_logic_vector(31 downto 0));
  end component;
begin
  clk <= not clk after 5 ns;

  -- Behavioral RTL wrapper.
  u_beh: entity beh.sw_chain
    generic map(N => N, Q => 12)
    port map(clk => clk, rst => rst, start => start,
             hb_mant => hb_mant, hb_exp => hb_exp,
             hb2_mant => hb2_mant, hb2_exp => hb2_exp,
             done => done_b, o_mant => ob, o_exp => oeb);

  -- Synthesized netlist wrapper.
  u_net: sw_chain
    port map(clk => clk, rst => rst, start => start,
             hb_mant => hb_mant, hb_exp => hb_exp,
             hb2_mant => hb2_mant, hb2_exp => hb2_exp,
             done => done_n, o_mant => onet, o_exp => oen);

  process
    file f_gold : text;
    variable n_hb, n_hb2, n_out : integer;
    variable e_hb, e_hb2, e_out : integer;
    variable hb_data  : integer_vector(0 to N-1);
    variable hb2_data : integer_vector(0 to N-1);
    variable out_data : integer_vector(0 to N-1);
    variable fails    : integer := 0;
    variable elt_fail : integer;
    variable a, b     : integer;

    procedure set_bus(signal s : out std_logic_vector(N*16-1 downto 0);
                      v : integer_vector) is
    begin
      for j in 0 to N-1 loop
        s((j+1)*16-1 downto j*16) <= std_logic_vector(to_signed(v(j), 16));
      end loop;
    end procedure;

    procedure run_and_check(tname : string) is
    begin
      wait until rising_edge(clk);
      start <= '1';
      wait until rising_edge(clk);
      start <= '0';
      wait until (done_b = '1' and done_n = '1') for 200 us;
      wait for 1 ns;
      elt_fail := 0;
      -- compare exponent
      if oeb /= oen then
        elt_fail := elt_fail + 1;
        report tname & " EXP MISMATCH beh=" & integer'image(to_integer(signed(oeb)))
             & " net=" & integer'image(to_integer(signed(oen))) severity warning;
      end if;
      -- compare each int16 mantissa
      for j in 0 to N-1 loop
        a := to_integer(signed(ob((j+1)*16-1 downto j*16)));
        b := to_integer(signed(onet((j+1)*16-1 downto j*16)));
        if a /= b then
          if elt_fail < 8 then
            report tname & " MANT MISMATCH elt=" & integer'image(j)
                 & " beh=" & integer'image(a) & " net=" & integer'image(b)
                 severity warning;
          end if;
          elt_fail := elt_fail + 1;
        end if;
      end loop;
      if elt_fail = 0 then
        report tname & " MATCH  o_exp=" & integer'image(to_integer(signed(oeb)))
             severity note;
      else
        report tname & " FAIL  (" & integer'image(elt_fail) & " mismatches)"
             severity warning;
        fails := fails + 1;
      end if;
      wait until rising_edge(clk);
    end procedure;
  begin
    -- release reset
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    -- ---- test 0: real layer-0 engine values ----
    file_open(f_gold, "../mem/golden/fx_swiglu_l0.txt", read_mode);
    read_bfp_block(f_gold, n_hb,  e_hb,  hb_data);
    read_bfp_block(f_gold, n_hb2, e_hb2, hb2_data);
    read_bfp_block(f_gold, n_out, e_out, out_data);
    file_close(f_gold);
    set_bus(hb_mant, hb_data);
    set_bus(hb2_mant, hb2_data);
    hb_exp  <= std_logic_vector(to_signed(e_hb, 32));
    hb2_exp <= std_logic_vector(to_signed(e_hb2, 32));
    run_and_check("test0-golden-L0");

    -- ---- tests 1..8: deterministic synthetic patterns ----
    for t in 1 to 8 loop
      for j in 0 to N-1 loop
        hb_data(j)  := ((t*131 + j*997) mod 65535) - 32768;   -- full int16 range
        hb2_data(j) := ((t*577 + j*331) mod 65535) - 32768;
      end loop;
      -- inject a few saturation / large-magnitude drivers
      hb_data(0)   := 32767;  hb2_data(0)   := 32767;
      hb_data(1)   := -32768; hb2_data(1)   := -32768;
      hb_data(N-1) := 30000;  hb2_data(N-1) := -30000;
      set_bus(hb_mant, hb_data);
      set_bus(hb2_mant, hb2_data);
      -- vary exponents across the shift-decision boundary (p_msb-14)
      hb_exp  <= std_logic_vector(to_signed(10 + t, 32));   -- 11..18
      hb2_exp <= std_logic_vector(to_signed(20 - t, 32));   -- 19..12
      run_and_check("test" & integer'image(t));
    end loop;

    -- ---- tests 9..12: SMALL exponents -> large swiglu outputs -> force
    -- shift_o>0 (o_exp<12), exercising the S_MAX->S_PACK shift decision. ----
    for t in 1 to 4 loop
      for j in 0 to N-1 loop
        hb_data(j)  := (((j*37 + t*13) mod 401) - 200);   -- +-200
        hb2_data(j) := (((j*53 + t*29) mod 401) - 200);
      end loop;
      hb_data(3)   := 200;   hb2_data(3)   := 200;   -- large paired -> big out
      hb_data(100) := -200;  hb2_data(100) := 200;
      set_bus(hb_mant, hb_data);
      set_bus(hb2_mant, hb2_data);
      hb_exp  <= std_logic_vector(to_signed(t-1, 32));   -- 0..3  (v_q = mant<<(12-exp))
      hb2_exp <= std_logic_vector(to_signed(t-1, 32));
      run_and_check("test-bigshift" & integer'image(t));
    end loop;

    if fails = 0 then
      report "VERDICT: PASS  netlist == behavioral for ALL tests (increment synth-correct)" severity note;
    else
      report "VERDICT: FAIL  " & integer'image(fails) & " test(s) diverge (synthesis bug in increment)" severity warning;
    end if;
    finish;
  end process;
end architecture;
