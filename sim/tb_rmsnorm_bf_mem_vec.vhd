-- sim/tb_rmsnorm_bf_mem_vec.vhd -- 2026-10-09.
--
-- rmsnorm_bf_mem AT A NON-POWER-OF-TWO N, against two references that share
-- nothing with it.
--
-- WHY THIS BENCH EXISTS.  docs/debugging/2026-10-09_jc-27b-first-token-
-- residual-gain.md: rmsnorm_bf_mem took the mean as S >> clog2(N).  At the
-- Qwen3.8-27B hidden size, N = 5120, that divides by 8192, and every
-- hidden-length norm on the card came out sqrt(8192/5120) = 1.2649x too
-- large.  The unit's only guard was `assert 2**LOG2N = N`, which synthesis
-- ignores.  Every existing rmsnorm_bf_mem row runs at a power of two (128 in
-- the gate, 4096 on the 9B), where the shift IS the divide, so no bench could
-- see it.  sim/tb_rmsnorm_bf_mem.vhd compares the unit against rmsnorm_bf,
-- which shared the same shift, so even a 5120 row there would have been a
-- comparison of one defect against itself.
--
-- TWO CHECKS, the same two sim/tb_rmsnorm_bf.vhd makes, for the same reasons:
--
--  1. BIT-EXACT against ref/rmsnorm_bf_vec_n5120.c (ref/rmsnorm_bf_vec.c at
--     N = 5120), no tolerance: every o_mant element and every o_exp.
--
--  2. ACCURACY against a REAL-VALUED oracle computed here from x, x_exp, w,
--     w_exp and EPS alone: mean = sum(x^2) / N in double, then
--     x * w / sqrt(mean + eps).  It knows nothing about LOG2N, the mean
--     reciprocal, Q, the seed ROM or shift_total.  It is the check that can
--     see a wrong DIVISOR, because check 1 cannot when the C and the RTL
--     share the wrong one (as they would have if the C had been "fixed" to
--     clog2 alone).  The gain is also measured directly as a least-squares
--     FIT of the DUT's output against the oracle, so a uniform gain error
--     -- the exact shape of this defect -- is named as a number rather than
--     inferred from LSB statistics.
--
-- RED, MEASURED 2026-10-09 against the unfixed RTL: the unit's own assert
-- fails at elaboration; with that assert removed (which is what synthesis
-- builds) the per-case oracle fit reads 1.2649 wherever the mean dominates
-- eps (the eps-dominated cases are, correctly, less affected).  See
-- ~/regress_scratch/rmsnorm_npow2/REPORT.md.
--
-- CHECKS ARE COUNTED IN VARIABLES, never in signals.
-- The verdict line `tb_rmsnorm_bf_mem_vec: PASS -- ...` satisfies
-- sim/regress.sh's PASS_RE and carries no bare FAIL word.
--
-- NO HARDWARE.  Simulation only.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;
use work.util_pkg.all;

entity tb_rmsnorm_bf_mem_vec is
  generic( N     : positive := 5120;
           LANES : positive := 4;
           Q     : integer  := 12;
           EPS   : real     := 1.0e-6;
           NCASE : positive := 40;
           -- Accuracy gates, in thousandths of an output LSB and parts per
           -- million (integer generics: ghdl-mcode cannot override a real
           -- one).  CALIBRATED, not chosen: the C is bit-exact with the DUT,
           -- so its outputs scored against this oracle (a Python transcription
           -- of rms_oracle, which reproduces this bench's own figures at the
           -- committed seed to four digits) give the honest unit's figures.
           -- Over 52 generator seeds (20261009, 20260826, 1, 2, 7, 42, 123,
           -- 999, 31337, 99, 20240229, 5, and 100..139) the honest maxima are:
           --   worst |err|    13.106 LSB   (seed 20240229)
           --   mean |err|      0.3091 LSB  (seed 123)
           --   pooled fit      8.75 ppm    (seed 20240229)
           --   per-case fit  460.62 ppm    (seed 20240229, a high-rms case
           --                                where inv32 itself is coarse)
           -- The defect, MEASURED on the unfixed RTL with its assert removed:
           -- worst 5878 LSB, mean 456 LSB, pooled fit 56,920 ppm, per-case
           -- 266,954 ppm.  The caps sit 1.5x to 11x above the honest maxima
           -- and 9x to 900x below the defect.  The mean cap is NOT
           -- tb_rmsnorm_bf's 300: at N = 5120 the honest mean reaches 309.
           ACC_MAXLSB_M  : integer := 20000;
           ACC_MEAN_M    : integer := 500;
           ACC_FIT_PPM   : integer := 100;    -- pooled over all cases
           ACC_CFIT_PPM  : integer := 2000;   -- worst single case
           -- Floor on how many elements entered the oracle (honest: 199,680
           -- of 204,800; 5,120 saturate by construction in case 0).
           ACC_MIN_CHECK : integer := 150000;
           VECS  : string   := "rmsnorm_bf_vec_n5120.txt" );
end entity;

architecture sim of tb_rmsnorm_bf_mem_vec is
  constant AW : natural := clog2(N);

  signal clk      : std_logic := '0';
  signal rst      : std_logic := '1';
  signal done_sim : boolean   := false;

  signal start      : std_logic := '0';
  signal xe, we     : integer := 0;
  signal x_we, w_we : std_logic := '0';
  signal x_wa, w_wa : std_logic_vector(AW-1 downto 0) := (others => '0');
  signal x_wd, w_wd : std_logic_vector(15 downto 0) := (others => '0');
  signal d_done     : std_logic;
  signal o_ra       : std_logic_vector(AW-1 downto 0) := (others => '0');
  signal o_rd       : std_logic_vector(15 downto 0);
  signal d_oe       : integer;
  signal d_wact     : std_logic;

  type i_arr is array (natural range <>) of integer;

  -- The DEFINITION of rmsnorm, in LSB of the DUT's own emitted grid.
  -- Transcribed from sim/tb_rmsnorm_bf.vhd's rms_oracle, unchanged.
  procedure rms_oracle(x  : in i_arr; pxe : in integer;
                       w  : in i_arr; pwe : in integer;
                       oe : in integer;
                       o  : out real_vector(0 to N-1)) is
    variable xr, sum, mean, g : real;
  begin
    sum := 0.0;
    for i in 0 to N-1 loop
      xr  := real(x(i)) * (2.0 ** (-pxe));
      sum := sum + xr * xr;
    end loop;
    mean := sum / real(N);
    g    := 1.0 / sqrt(mean + EPS);
    for i in 0 to N-1 loop
      o(i) := (real(x(i)) * (2.0 ** (-pxe))) * g * (real(w(i)) * (2.0 ** (-pwe)))
              * (2.0 ** oe);
    end loop;
  end procedure;
begin
  clk <= '0' when done_sim else not clk after 1 ns;

  dut : entity work.rmsnorm_bf_mem
    generic map(N => N, LANES => LANES, Q => Q, EPS => EPS)
    port map(clk=>clk, rst=>rst, start=>start,
             x_we=>x_we, x_waddr=>x_wa, x_wdata=>x_wd, x_exp=>xe,
             w_we=>w_we, w_waddr=>w_wa, w_wdata=>w_wd, w_exp=>we,
             done=>d_done,
             o_raddr=>o_ra, o_rdata=>o_rd, o_exp=>d_oe,
             w_active=>d_wact);

  drive : process
    file fh : text; variable ln : line;
    variable iv, nc, nn, vq, ve, vm : integer;
    constant TB_E_EPS : integer := 30 - integer(floor(log2(EPS)));
    constant TB_M_EPS : integer := integer(round(EPS * 2.0**real(TB_E_EPS)));
    variable vx, vw, vo : i_arr(0 to N-1);
    variable vxe, vwe, voe : integer;
    variable got   : i_arr(0 to N-1);
    variable orac  : real_vector(0 to N-1);
    variable cyc, done_cyc0 : natural := 0;
    variable bad, nfail, ncheck : natural := 0;
    variable err : real;
    variable a_max, a_sum : real := 0.0;
    variable a_mcase, a_melem : integer := -1;
    variable a_n, a_sat : natural := 0;
    -- The fit: sum(got*orac) / sum(orac^2) over unsaturated elements, ALL
    -- cases pooled, and also per case so one bad case is named.
    variable f_num, f_den, c_num, c_den, c_fit : real := 0.0;
    variable c_worst_fit : real := 1.0;
    variable c_worst_case : integer := -1;
    variable fit : real;
    variable acc_bad : natural := 0;
  begin
    file_open(fh, VECS, read_mode);
    readline(fh, ln);
    read(ln, nc); read(ln, nn); read(ln, vq); read(ln, ve); read(ln, vm);
    assert nc = NCASE and nn = N
      report "tb_rmsnorm_bf_mem_vec: vector file shape is " & integer'image(nc)
           & "x" & integer'image(nn) & ", generics say " & integer'image(NCASE)
           & "x" & integer'image(N) severity failure;
    assert vq = Q
      report "tb_rmsnorm_bf_mem_vec: vectors at Q=" & integer'image(vq)
           & ", DUT at Q=" & integer'image(Q) severity failure;
    assert ve = TB_E_EPS and vm = TB_M_EPS
      report "tb_rmsnorm_bf_mem_vec: epsilon mismatch with the vector file"
      severity failure;

    rst <= '1';
    for i in 0 to 5 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);

    for c in 0 to NCASE-1 loop
      readline(fh, ln);
      read(ln, iv);
      read(ln, vxe); read(ln, vwe); read(ln, voe);
      readline(fh, ln); for i in 0 to N-1 loop read(ln, vx(i)); end loop;
      readline(fh, ln); for i in 0 to N-1 loop read(ln, vw(i)); end loop;
      readline(fh, ln); for i in 0 to N-1 loop read(ln, vo(i)); end loop;

      -- load x then w, one word per edge, through the unit's write ports
      for i in 0 to N-1 loop
        x_we <= '1';
        x_wa <= std_logic_vector(to_unsigned(i, AW));
        x_wd <= std_logic_vector(to_signed(vx(i), 16));
        wait until rising_edge(clk);
      end loop;
      x_we <= '0';
      for i in 0 to N-1 loop
        w_we <= '1';
        w_wa <= std_logic_vector(to_unsigned(i, AW));
        w_wd <= std_logic_vector(to_signed(vw(i), 16));
        wait until rising_edge(clk);
      end loop;
      w_we <= '0';
      xe <= vxe; we <= vwe;
      wait until rising_edge(clk);
      start <= '1';
      wait until rising_edge(clk);
      start <= '0';
      cyc := 0;
      while d_done /= '1' loop
        wait until rising_edge(clk);
        cyc := cyc + 1;
        assert cyc < 8*N
          report "tb_rmsnorm_bf_mem_vec case " & integer'image(c)
               & ": never finished" severity failure;
      end loop;
      -- The latency is data independent: one constant for the whole run.
      if c = 0 then done_cyc0 := cyc;
      elsif cyc /= done_cyc0 then
        report "tb_rmsnorm_bf_mem_vec BAD case " & integer'image(c)
             & ": done after " & integer'image(cyc) & " cycles, case 0 took "
             & integer'image(done_cyc0) severity error;
        nfail := nfail + 1;
      end if;

      -- read out: o_raddr at edge k gives o_rdata at edge k+1
      for i in 0 to N-1 loop
        o_ra <= std_logic_vector(to_unsigned(i, AW));
        wait until rising_edge(clk);
        wait for 1 ns;
        got(i) := to_integer(signed(o_rd));
      end loop;

      -- ---- CHECK 1: bit-exact against the C
      bad := 0;
      ncheck := ncheck + 1;
      if d_oe /= voe then
        report "tb_rmsnorm_bf_mem_vec BAD case " & integer'image(c)
             & ": o_exp got " & integer'image(d_oe) & " want "
             & integer'image(voe) severity error;
        bad := bad + 1;
      end if;
      for i in 0 to N-1 loop
        ncheck := ncheck + 1;
        if got(i) /= vo(i) then
          if bad < 4 then
            report "tb_rmsnorm_bf_mem_vec BAD case " & integer'image(c)
                 & " element " & integer'image(i) & ": got "
                 & integer'image(got(i)) & " want " & integer'image(vo(i))
              severity error;
          end if;
          bad := bad + 1;
        end if;
      end loop;
      if bad /= 0 then
        nfail := nfail + 1;
        report "tb_rmsnorm_bf_mem_vec case " & integer'image(c)
             & ": MISMATCH with the C in " & integer'image(bad) & " place(s)"
          severity error;
      end if;

      -- ---- CHECK 2: the real-valued oracle, on the DUT's own o_exp
      rms_oracle(vx, vxe, vw, vwe, d_oe, orac);
      c_num := 0.0; c_den := 0.0;
      for i in 0 to N-1 loop
        if got(i) = 32767 or got(i) = -32768 then
          a_sat := a_sat + 1;
        else
          err := abs(real(got(i)) - orac(i));
          a_n := a_n + 1;
          a_sum := a_sum + err;
          if err > a_max then a_max := err; a_mcase := c; a_melem := i; end if;
          c_num := c_num + real(got(i)) * orac(i);
          c_den := c_den + orac(i) * orac(i);
        end if;
      end loop;
      f_num := f_num + c_num; f_den := f_den + c_den;
      -- Per-case fit only where the case carries enough signal to have one:
      -- 1e6 LSB^2 is an rms of ~14 LSB over 5120 elements.
      if c_den > 1.0e6 then
        c_fit := c_num / c_den;
        report "tb_rmsnorm_bf_mem_vec case " & integer'image(c) & " x_exp "
             & integer'image(vxe) & ": fit " & real'image(c_fit) severity note;
        if abs(c_fit - 1.0) > abs(c_worst_fit - 1.0) then
          c_worst_fit := c_fit; c_worst_case := c;
        end if;
      end if;
    end loop;
    file_close(fh);

    if f_den > 0.0 then fit := f_num / f_den; else fit := 0.0; end if;
    report "tb_rmsnorm_bf_mem_vec: N=" & integer'image(N) & " LANES="
         & integer'image(LANES) & " done latency " & integer'image(done_cyc0)
         & " cycles; oracle worst " & real'image(a_max) & " LSB (case "
         & integer'image(a_mcase) & " element " & integer'image(a_melem)
         & "), mean " & real'image(a_sum / real(maximum(a_n, 1)))
         & " LSB over " & integer'image(a_n) & " elements, "
         & integer'image(a_sat) & " saturated and excluded; pooled fit "
         & real'image(fit) & ", worst per-case fit " & real'image(c_worst_fit)
         & " (case " & integer'image(c_worst_case) & ")" severity note;

    acc_bad := 0;
    if a_n < ACC_MIN_CHECK then
      report "tb_rmsnorm_bf_mem_vec: OUT OF TOLERANCE -- the oracle saw only "
           & integer'image(a_n) & " elements, floor " & integer'image(ACC_MIN_CHECK)
        severity error;
      acc_bad := acc_bad + 1;
    end if;
    if a_max > real(ACC_MAXLSB_M) / 1000.0 then
      report "tb_rmsnorm_bf_mem_vec: OUT OF TOLERANCE -- worst "
           & real'image(a_max) & " LSB" severity error;
      acc_bad := acc_bad + 1;
    end if;
    if a_sum / real(maximum(a_n, 1)) > real(ACC_MEAN_M) / 1000.0 then
      report "tb_rmsnorm_bf_mem_vec: OUT OF TOLERANCE -- mean "
           & real'image(a_sum / real(maximum(a_n, 1))) & " LSB" severity error;
      acc_bad := acc_bad + 1;
    end if;
    if abs(fit - 1.0) * 1.0e6 > real(ACC_FIT_PPM)
       or abs(c_worst_fit - 1.0) * 1.0e6 > real(ACC_CFIT_PPM) then
      report "tb_rmsnorm_bf_mem_vec: OUT OF TOLERANCE -- gain fit "
           & real'image(fit) & " (cap " & integer'image(ACC_FIT_PPM)
           & " ppm), worst case " & real'image(c_worst_fit) & " (cap "
           & integer'image(ACC_CFIT_PPM) & " ppm).  A uniform gain"
           & " error is the signature of a wrong mean divisor." severity error;
      acc_bad := acc_bad + 1;
    end if;

    if nfail = 0 and acc_bad = 0 then
      report "tb_rmsnorm_bf_mem_vec: PASS -- bit-exact with "
           & "ref/rmsnorm_bf_vec.c on " & integer'image(NCASE) & " cases ("
           & integer'image(ncheck) & " checks) at N=" & integer'image(N)
           & ", and within tolerance of the real-valued oracle (fit "
           & real'image(fit) & ")" severity note;
    else
      report "tb_rmsnorm_bf_mem_vec: " & integer'image(nfail)
           & " case(s) differ from the C, " & integer'image(acc_bad)
           & " accuracy gate(s) tripped" severity failure;
    end if;
    done_sim <= true;
    wait;
  end process;
end architecture;
