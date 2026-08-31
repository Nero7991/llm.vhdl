-- gwtwo_rateprobe.vhd -- TRACK GWTWO, 2026-08-30.  SCRATCH ONLY.
--
-- DELIBERATELY NOT IN sim/ AND DELIBERATELY NOT NAMED tb_*.  A new
-- sim/tb_*.vhd becomes a gate row for every track whether the author meant it
-- or not; this file is a one-question probe and has no business in the gate.
--
-- THE QUESTION IT ANSWERS.  Does the gain load's DURATION depend on GW at the
-- REAL 9B shape (NN = 4096)?  `sim/tb_rmswire_loadrace.vhd` cannot answer it:
-- it instantiates `rmsnorm_rs` and `rmsnorm_rs_mem` DIRECTLY and never
-- elaborates llama_top's `gvr` block, so GW does not appear in it at all and
-- its result is identical at every GW for a reason that has nothing to do with
-- GW.  `sim/tb_llama_top_normw` does elaborate the block but only at
-- hidden = 64.
--
-- WHAT IS OBSERVED, AND WHY IT IS THE RIGHT PIN.  `nproc`'s S_GO does not fire
-- `r_go` until `wbusy` clears, so any load slower than the S_RD pass shows up
-- as a STALL between the read pass and the unit starting.  `wbusy` is internal,
-- but the stall is not: it delays everything downstream of `r_go`, and the
-- first `o_uw_en` (S_WR's first region write) is downstream of it.  So
-- cycles(i_v_start -> first o_uw_en) contains the stall exactly once.
--
-- IT IS A NEGATIVE MEASUREMENT, SO IT NEEDS TEETH.  A number that does not
-- move across GW proves nothing unless something CAN move it.  The `slowload`
-- mutant advances `wel` on alternate cycles only, doubling the load to ~2*NN
-- against a budget of NN+4, and must move this number by ~NN.  If it does not,
-- this probe is decoration and its GW result must be discarded.
--
-- NO HARDWARE.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity gwtwo_rateprobe is
  generic(NORM_W_IMAGE : string := "");
end entity;

architecture tb of gwtwo_rateprobe is
  constant MANT_W : positive := 16;
  constant EXP_W  : positive := 16;
  constant VN_W   : positive := 14;
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal go  : std_logic := '0';
  signal v_start, v_ack : std_logic := '0';
  signal v_n     : unsigned(VN_W-1 downto 0) := (others => '0');
  signal v_exp_a : signed(EXP_W-1 downto 0) := (others => '0');
  signal v_reg_a, v_reg_d : unsigned(7 downto 0) := (others => '0');
  signal el_rdata : signed(MANT_W-1 downto 0) := to_signed(1000, MANT_W);
  signal o_ready, o_done, o_taken, o_err : std_logic;
  signal o_yexp : std_logic_vector(EXP_W-1 downto 0);
  signal ur_en, uw_en : std_logic;
  signal ur_reg, uw_reg : std_logic_vector(15 downto 0);
  signal ur_addr, uw_addr : std_logic_vector(31 downto 0);
  signal uw_data : std_logic_vector(MANT_W-1 downto 0);
  signal op, on_pub : std_logic;
  signal oexp : signed(EXP_W-1 downto 0);
  signal ossq : unsigned(63 downto 0);
  signal onn  : unsigned(15 downto 0);
  signal running : boolean := true;
begin
  clkp : process is
  begin
    while running loop
      wait for 2.5 ns; clk <= not clk;
    end loop;
    wait;
  end process;

  dut : entity work.ooc_normadapt
    generic map(MANT_W => MANT_W, EXP_W => EXP_W, VN_W => VN_W,
                NORM_W_IMAGE => NORM_W_IMAGE, NORM_REAL => true)
    port map(clk => clk, rst => rst, go => go,
             i_v_start => v_start, i_v_ack => v_ack, i_v_n => v_n,
             i_v_exp_a => v_exp_a, i_v_reg_a => v_reg_a, i_v_reg_d => v_reg_d,
             i_el_rdata => el_rdata,
             o_v_ready => o_ready, o_v_done => o_done, o_v_taken => o_taken,
             o_v_err => o_err, o_v_y_exp => o_yexp,
             o_ur_en => ur_en, o_ur_reg => ur_reg, o_ur_addr => ur_addr,
             o_uw_en => uw_en, o_uw_reg => uw_reg, o_uw_addr => uw_addr,
             o_uw_data => uw_data,
             obs_norm_pub => on_pub, obs_norm_exp => oexp,
             obs_norm_ssq => ossq, obs_norm_n => onn);

  stim : process
    variable c        : natural := 0;
    variable t_start  : integer := -1;
    variable t_ur     : integer := -1;
    variable t_uw     : integer := -1;
    variable t_done   : integer := -1;
    variable l        : line;
    variable nn       : natural;
  begin
    -- NN is read back from the DUT's own assert path: the adapter fails hard
    -- if v_n /= NN, so driving the wrong value is loud rather than silent.
    -- The 9B shape is hidden = 4096 and that is what is driven here.
    nn := 4096;
    report "GWTWO_RATEPROBE: alive, image=" & NORM_W_IMAGE severity note;
    v_n <= to_unsigned(nn, VN_W);
    rst <= '1';
    for i in 0 to 9 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);

    -- THE RESTART.  `go` is one of the three events that restarts the gain
    -- load, and it is the one a token start uses.  The norm op is issued the
    -- cycle AFTER it, which is the worst case the design must survive: the
    -- load has had zero head start.
    go <= '1';
    wait until rising_edge(clk);
    go <= '0';
    c := 0;
    v_start <= '1';
    t_start := 0;
    loop
      wait until rising_edge(clk);
      c := c + 1;
      if ur_en = '1' and t_ur < 0 then t_ur := c; end if;
      if uw_en = '1' and t_uw < 0 then t_uw := c; end if;
      if o_done = '1' and t_done < 0 then t_done := c; v_start <= '0'; end if;
      exit when t_done >= 0 or c > 200000;
    end loop;

    write(l, string'("GWTWO_RATEPROBE NN=") & integer'image(nn));
    write(l, string'(" first_ur_en=") & integer'image(t_ur));
    write(l, string'(" first_uw_en=") & integer'image(t_uw));
    write(l, string'(" done=") & integer'image(t_done));
    writeline(output, l);
    running <= false;
    wait;
  end process;
end architecture;
