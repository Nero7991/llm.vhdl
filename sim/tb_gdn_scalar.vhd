-- tb_gdn_scalar: two-way check of rtl/gdn_scalar.vhd against ref/gdn_scalar_vec.
--
--   (a) BIT-EXACT against the fixed path.  This is the contract.
--   (b) REPORTED against a double oracle computed in real arithmetic.  The
--       oracle is not a second transcription of the same integer recipe -- it
--       never touches a LUT, a shift or a grid -- so it measures the recipe's
--       approximation error rather than the testbench's agreement with itself.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

entity tb_gdn_scalar is
  generic( SP_Q : integer := 18; VEC : string := "gdn_scalar_vec.txt" );
end entity;

architecture sim of tb_gdn_scalar is
  signal clk   : std_logic := '0';
  signal rst   : std_logic := '1';
  signal start : std_logic := '0';
  signal al_m, dt_m, a_m, b_m : signed(15 downto 0) := (others => '0');
  signal al_e, dt_e, a_e, b_e : signed(7 downto 0)  := (others => '0');
  signal eg, beta : unsigned(15 downto 0);
  signal err_g, done : std_logic;
  signal running : boolean := true;
begin
  clk <= not clk after 5 ns when running else '0';

  dut : entity work.gdn_scalar
    generic map(SP_Q => SP_Q)
    port map(clk=>clk, rst=>rst, start=>start,
             al_m=>al_m, al_e=>al_e, dt_m=>dt_m, dt_e=>dt_e,
             a_m=>a_m, a_e=>a_e, b_m=>b_m, b_e=>b_e,
             eg=>eg, beta=>beta, err_g=>err_g, done=>done);

  stim : process
    file     fh   : text;
    variable ln   : line;
    variable nc, q : integer;
    variable v_alm, v_ale, v_dtm, v_dte : integer;
    variable v_am, v_ae, v_bm, v_be     : integer;
    variable x_eg, x_beta, x_err        : integer;
    variable o_eg, o_beta               : real;
    variable bad_eg, bad_beta, bad_err  : integer := 0;
    variable worst_eg, worst_beta       : real := 0.0;
    variable d : real;
  begin
    file_open(fh, VEC, read_mode);
    readline(fh, ln); read(ln, nc); read(ln, q);
    assert q = SP_Q report "vector file grid Q" & integer'image(q) &
      " does not match SP_Q " & integer'image(SP_Q) severity failure;

    rst <= '1'; wait for 40 ns; rst <= '0'; wait for 20 ns;

    for i in 0 to nc-1 loop
      readline(fh, ln);
      read(ln, v_alm); read(ln, v_ale); read(ln, v_dtm); read(ln, v_dte);
      read(ln, v_am);  read(ln, v_ae);  read(ln, v_bm);  read(ln, v_be);
      read(ln, x_eg);  read(ln, x_beta); read(ln, x_err);
      read(ln, o_eg);  read(ln, o_beta);

      al_m <= to_signed(v_alm,16); al_e <= to_signed(v_ale,8);
      dt_m <= to_signed(v_dtm,16); dt_e <= to_signed(v_dte,8);
      a_m  <= to_signed(v_am,16);  a_e  <= to_signed(v_ae,8);
      b_m  <= to_signed(v_bm,16);  b_e  <= to_signed(v_be,8);
      wait until rising_edge(clk);
      start <= '1'; wait until rising_edge(clk); start <= '0';
      wait until done = '1';
      wait for 1 ns;

      -- (a) the contract
      if to_integer(eg) /= x_eg then
        bad_eg := bad_eg + 1;
        if bad_eg <= 6 then
          report "case " & integer'image(i) & ": eg " & integer'image(to_integer(eg)) &
                 " expected " & integer'image(x_eg) severity error;
        end if;
      end if;
      -- err_g was read from the vector file and never compared, so tying it
      -- high passed the entire suite at all three grids.
      if (err_g = '1') /= (x_err = 1) then
        bad_err := bad_err + 1;
        if bad_err <= 6 then
          report "case " & integer'image(i) & ": err_g " & std_logic'image(err_g) &
                 " expected " & integer'image(x_err) severity error;
        end if;
      end if;
      if to_integer(beta) /= x_beta then
        bad_beta := bad_beta + 1;
        if bad_beta <= 6 then
          report "case " & integer'image(i) & ": beta " & integer'image(to_integer(beta)) &
                 " expected " & integer'image(x_beta) severity error;
        end if;
      end if;

      -- (b) the oracle, reported not asserted
      d := abs(real(to_integer(eg)) - o_eg);
      if d > worst_eg then worst_eg := d; end if;
      d := abs(real(to_integer(beta)) - o_beta);
      if d > worst_beta then worst_beta := d; end if;
    end loop;
    file_close(fh);

    report "=== gdn_scalar, SP_Q=" & integer'image(SP_Q) & ", " &
           integer'image(nc) & " cases ===";
    report "bit-exact vs fixed reference: eg mismatches " & integer'image(bad_eg) &
           ", beta mismatches " & integer'image(bad_beta) &
           ", err_g mismatches " & integer'image(bad_err);
    report "vs double oracle: eg worst " & real'image(worst_eg) &
           " LSB(Q15), beta worst " & real'image(worst_beta) & " LSB(Q16)";
    assert bad_eg = 0 and bad_beta = 0 and bad_err = 0
      report "BIT-EXACTNESS FAILED" severity failure;
    report "PASS";
    running <= false;
    wait;
  end process;
end architecture;
