-- sim/tb_rmsnorm_bf.vhd -- rmsnorm_bf against ref/rmsnorm_bf_vec.c.
--
-- BIT-EXACT, not within a tolerance.  The reference implements the unit's
-- integer recipe in C and the unit implements it in VHDL; the two are
-- different transcriptions of one specification, so any difference at all is a
-- transcription error and a tolerance would only hide it.  The accuracy
-- question -- how far the recipe itself is from a real-valued oracle -- is
-- answered by the GENERATOR, which carries an independent double path and
-- prints the figures there, and NOT here.  Keeping the two apart is
-- deliberate: a testbench that checks accuracy cannot also detect a wrong
-- recipe, because a wrong recipe that is accurate enough passes.
--
-- WHY A STORED VECTOR AND NOT AN A/B, WHICH IS WHAT tb_rmsnorm_rs DOES.
-- tb_rmsnorm_rs instantiates rmsnorm.vhd as its golden and argues, correctly
-- for that unit, that a stored vector would freeze one N and one exponent
-- pair.  rmsnorm_bf cannot use that argument: it is deliberately NOT bit-exact
-- with rmsnorm.vhd, because rmsnorm.vhd is wrong in the region this unit
-- exists to fix.  There is no RTL golden available, and the one that was
-- available is the reason the defect survived
-- (docs/debugging/2026-08-26_rmsnorm-magnitude-window.md).  So the golden is
-- an independent C transcription plus a double oracle, and the exponent sweep
-- the A/B form gave for free is bought back by the generator sweeping x_exp
-- across the model's MEASURED range of log2(rms), [-29.63, -0.54].
--
-- WHAT THIS PROVES AND WHAT IT DOES NOT.  It proves every element of o_mant
-- and o_exp, the S = 0 branch, both branches of the block-floating alignment,
-- the exact upper bound on the sum of squares, the single-lane max|raw| scan,
-- and the +32767 emit rail.  It does NOT prove the -32768 rail, which is
-- unreachable by construction rather than untested: shift_total puts
-- max_raw >> shift_total inside [2^14, 2^15) and the emit bias is
-- non-negative, so the low rail cannot be crossed.  That is recorded in the
-- generator alongside the search that constructs the high one.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

entity tb_rmsnorm_bf is
  generic( N     : positive := 128;
           LANES : positive := 4;
           Q     : integer  := 12;
           EPS   : real     := 1.0e-6;
           NCASE : positive := 200;
           VECS  : string   := "rmsnorm_bf_vec.txt" );
end entity;

architecture sim of tb_rmsnorm_bf is
  signal clk      : std_logic := '0';
  signal rst      : std_logic := '1';
  signal done_sim : boolean   := false;

  signal start  : std_logic := '0';
  signal xm, wm : std_logic_vector(N*16-1 downto 0) := (others => '0');
  signal xe, we : integer := 0;

  signal d_done : std_logic;
  signal d_om   : std_logic_vector(N*16-1 downto 0);
  signal d_oe   : integer;

  type i_arr    is array (natural range <>) of integer;
  type case_arr is array (0 to NCASE-1) of i_arr(0 to N-1);
  signal loaded : boolean := false;
  shared variable v_x, v_w, v_o : case_arr;
  shared variable v_xe, v_we, v_oe : i_arr(0 to NCASE-1);
  shared variable nfail : integer := 0;
begin
  clk <= '0' when done_sim else not clk after 1 ns;

  dut : entity work.rmsnorm_bf
    generic map(N => N, LANES => LANES, Q => Q, EPS => EPS)
    port map(clk=>clk, rst=>rst, start=>start,
             x_mant=>xm, x_exp=>xe, w_mant=>wm, w_exp=>we,
             done=>d_done, o_mant=>d_om, o_exp=>d_oe);

  load : process
    file fh : text; variable ln : line;
    variable iv, nc, nn, vq, ve, vm : integer;
    -- The tb resolves the epsilon the same way the DUT's E_EPS / M_EPS_C
    -- constants do.  Comparing that against the header catches a mismatched
    -- EPS generic BEFORE any vector is compared: without it a wrong epsilon
    -- presents as every case failing, with nothing pointing at why.
    constant TB_E_EPS : integer := 30 - integer(floor(log2(EPS)));
    constant TB_M_EPS : integer := integer(round(EPS * 2.0**real(TB_E_EPS)));
  begin
    file_open(fh, VECS, read_mode);
    readline(fh, ln);
    read(ln, nc); read(ln, nn); read(ln, vq); read(ln, ve); read(ln, vm);
    assert nc = NCASE and nn = N
      report "tb_rmsnorm_bf: vector file shape is " & integer'image(nc) & "x"
           & integer'image(nn) & ", generics say " & integer'image(NCASE) & "x"
           & integer'image(N) severity failure;
    assert vq = Q
      report "tb_rmsnorm_bf: vectors were generated at Q=" & integer'image(vq)
           & " but the DUT is at Q=" & integer'image(Q) severity failure;
    assert ve = TB_E_EPS and vm = TB_M_EPS
      report "tb_rmsnorm_bf: epsilon mismatch -- vectors carry E_EPS="
           & integer'image(ve) & " M_EPS=" & integer'image(vm)
           & ", this EPS generic resolves to E_EPS=" & integer'image(TB_E_EPS)
           & " M_EPS=" & integer'image(TB_M_EPS) severity failure;
    for c in 0 to NCASE-1 loop
      readline(fh, ln);
      read(ln, iv);                       -- case index, positional only
      read(ln, iv); v_xe(c) := iv;
      read(ln, iv); v_we(c) := iv;
      read(ln, iv); v_oe(c) := iv;
      readline(fh, ln); for i in 0 to N-1 loop read(ln, iv); v_x(c)(i) := iv; end loop;
      readline(fh, ln); for i in 0 to N-1 loop read(ln, iv); v_w(c)(i) := iv; end loop;
      readline(fh, ln); for i in 0 to N-1 loop read(ln, iv); v_o(c)(i) := iv; end loop;
    end loop;
    file_close(fh);
    loaded <= true; wait;
  end process;

  drive : process
    variable cyc  : natural;
    variable bad  : natural;
    variable got  : integer;
  begin
    wait until loaded;
    rst <= '1';
    for i in 0 to 5 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);

    for c in 0 to NCASE-1 loop
      for i in 0 to N-1 loop
        xm((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(v_x(c)(i), 16));
        wm((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(v_w(c)(i), 16));
      end loop;
      xe <= v_xe(c); we <= v_we(c);
      wait until rising_edge(clk);
      start <= '1';
      wait until rising_edge(clk);
      start <= '0';

      -- `done` is a ONE-CYCLE pulse, so it is caught by polling rather than
      -- waited on as a level.  A cycle cap turns a unit that never finishes
      -- into a failure instead of a hang, which is the failure mode the
      -- rmsnorm_rs testbench hit first.
      cyc := 0;
      while d_done /= '1' loop
        wait until rising_edge(clk);
        cyc := cyc + 1;
        assert cyc < 20000
          report "case " & integer'image(c) & ": never finished" severity failure;
      end loop;
      -- outputs are held until the next start, so sampling here is safe

      bad := 0;
      if d_oe /= v_oe(c) then
        report "case " & integer'image(c) & " (xe=" & integer'image(v_xe(c))
             & " we=" & integer'image(v_we(c)) & "): o_exp got "
             & integer'image(d_oe) & " want " & integer'image(v_oe(c))
          severity error;
        bad := bad + 1;
      end if;
      for i in 0 to N-1 loop
        got := to_integer(signed(d_om((i+1)*16-1 downto i*16)));
        if got /= v_o(c)(i) then
          -- Only the first few are printed per case.  A recipe error is
          -- usually wrong on every element, and 128 identical reports per
          -- case buries the ONE case that differs from the others.
          if bad < 4 then
            report "case " & integer'image(c) & " (xe=" & integer'image(v_xe(c))
                 & " we=" & integer'image(v_we(c)) & ") element "
                 & integer'image(i) & ": got " & integer'image(got)
                 & " want " & integer'image(v_o(c)(i))
                 & "  from xm " & integer'image(v_x(c)(i))
                 & " wm " & integer'image(v_w(c)(i)) severity error;
          end if;
          bad := bad + 1;
        end if;
      end loop;
      if bad /= 0 then
        nfail := nfail + 1;
        report "case " & integer'image(c) & ": MISMATCH in "
             & integer'image(bad) & " place(s)" severity error;
      end if;
    end loop;

    wait until rising_edge(clk);
    if nfail = 0 then
      report "rmsnorm_bf: bit-exact with the C reference on all "
           & integer'image(NCASE) & " cases (" & integer'image(NCASE*N)
           & " elements + " & integer'image(NCASE) & " exponents), N="
           & integer'image(N) & " LANES=" & integer'image(LANES)
           & " Q=" & integer'image(Q) severity note;
    else
      report "rmsnorm_bf: DIFFERS from the C reference in "
           & integer'image(nfail) & " case(s)" severity failure;
    end if;
    done_sim <= true;
    wait;
  end process;
end architecture;
