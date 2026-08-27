-- sim/tb_gdn_head_emit.vhd
-- Bit-exactness of rtl/gdn_head_emit.vhd (subsystem B stage 6, SITE 12)
-- against ref/gdn_head_emit_vec.c.
--
-- NO TOLERANCE.  The C generator's own double-oracle check is what establishes
-- that the integer recipe means the right thing; this file's job is the
-- narrower one of proving the RTL reproduces that recipe exactly.  A tolerance
-- here would only hide a disagreement between the two.
--
-- The vector file deliberately leads with the cases that are easy to get
-- wrong: all-equal exponents, an all-zero head (which pins the msb_pos(0) = 0
-- convention), a wide exponent spread, negative values one below a power of
-- two (the floor_shr counterexample that kills the one-pass amax shortcut),
-- and saturation in both directions.  See the generator for why each is there.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

entity tb_gdn_head_emit is
  generic( DIM   : positive := 128;
           NCASE : positive := 64;
           VECS  : string   := "gdn_head_emit_vec.txt" );
end entity;

architecture sim of tb_gdn_head_emit is
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  signal in_valid : std_logic := '0';
  signal in_acc   : signed(39 downto 0) := (others => '0');
  signal in_e_o   : signed(7 downto 0)  := (others => '0');

  signal done     : std_logic;
  signal o_mant   : std_logic_vector(DIM*16-1 downto 0);
  signal o_e_head : signed(7 downto 0);
  signal o_sat    : std_logic;

  type acc_arr  is array(0 to DIM-1) of integer;
  type acc_arr2 is array(0 to DIM-1) of real;   -- o_acc can exceed VHDL integer
  type case_acc is array(0 to NCASE-1) of acc_arr2;
  type case_exp is array(0 to NCASE-1) of acc_arr;
  type case_mnt is array(0 to NCASE-1) of acc_arr;

  signal running : boolean := true;
begin
  clk <= not clk after 5 ns when running else '0';

  dut : entity work.gdn_head_emit
    generic map ( DIM => DIM )
    port map ( clk => clk, rst => rst,
               in_valid => in_valid, in_acc => in_acc, in_e_o => in_e_o,
               done => done, o_mant => o_mant, o_e_head => o_e_head,
               o_sat => o_sat );

  stim : process
    file fh : text;
    variable ln : line;
    variable iv, nc, nn : integer;
    variable rv : real;
    variable v_acc : case_acc;
    variable v_eo  : case_exp;
    variable v_mnt : case_mnt;
    variable v_eh  : acc_arr;
    variable v_sat : acc_arr;
    variable got   : integer;
    variable nerr  : integer := 0;

    -- o_acc spans 38 bits, which does not fit a VHDL integer, so the vector
    -- file's values are read as real and converted.  Reading them as integer
    -- would silently wrap on exactly the large-magnitude cases the saturation
    -- test depends on.
    function to_s40(r : real) return signed is
      variable neg : boolean := r < 0.0;
      variable a   : real := abs(r);
      variable res : signed(39 downto 0) := (others => '0');
      variable hi, lo : integer;
    begin
      hi := integer(floor(a / 1048576.0));       -- 2^20
      lo := integer(a - real(hi) * 1048576.0);
      res := shift_left(resize(to_signed(hi, 40), 40), 20)
           + resize(to_signed(lo, 40), 40);
      if neg then res := -res; end if;
      return res;
    end function;
  begin
    file_open(fh, VECS, read_mode);
    readline(fh, ln); read(ln, nc); read(ln, nn);
    assert nc = NCASE and nn = DIM
      report "tb_gdn_head_emit: vector file shape mismatch" severity failure;
    for c in 0 to NCASE-1 loop
      readline(fh, ln); read(ln, iv); read(ln, iv); v_eh(c) := iv;
                        read(ln, iv); v_sat(c) := iv;
      readline(fh, ln);
      for i in 0 to DIM-1 loop read(ln, rv); v_acc(c)(i) := rv; end loop;
      readline(fh, ln);
      for i in 0 to DIM-1 loop read(ln, iv); v_eo(c)(i) := iv; end loop;
      readline(fh, ln);
      for i in 0 to DIM-1 loop read(ln, iv); v_mnt(c)(i) := iv; end loop;
    end loop;
    file_close(fh);

    rst <= '1'; wait until rising_edge(clk); wait until rising_edge(clk);
    rst <= '0'; wait until rising_edge(clk);

    for c in 0 to NCASE-1 loop
      -- pass A: stream the head's columns in, one per cycle, which is the
      -- rate gdn_recur_pipe's o_res_valid actually produces them
      for i in 0 to DIM-1 loop
        in_valid <= '1';
        in_acc   <= to_s40(v_acc(c)(i));
        in_e_o   <= to_signed(v_eo(c)(i), 8);
        wait until rising_edge(clk);
      end loop;
      in_valid <= '0';

      -- passes B and C run without further input
      while done /= '1' loop wait until rising_edge(clk); end loop;

      if to_integer(o_e_head) /= v_eh(c) then
        report "case " & integer'image(c) & ": e_head got "
             & integer'image(to_integer(o_e_head)) & " want "
             & integer'image(v_eh(c)) severity error;
        nerr := nerr + 1;
      end if;
      if (o_sat = '1') /= (v_sat(c) = 1) then
        report "case " & integer'image(c) & ": o_sat mismatch" severity error;
        nerr := nerr + 1;
      end if;
      for i in 0 to DIM-1 loop
        got := to_integer(signed(o_mant((i+1)*16-1 downto i*16)));
        if got /= v_mnt(c)(i) then
          report "case " & integer'image(c) & " col " & integer'image(i)
               & ": mant got " & integer'image(got)
               & " want " & integer'image(v_mnt(c)(i)) severity error;
          nerr := nerr + 1;
          exit;
        end if;
      end loop;

      wait until rising_edge(clk);
    end loop;

    if nerr = 0 then
      report "tb_gdn_head_emit: PASS -- " & integer'image(NCASE)
           & " cases x " & integer'image(DIM) & " bit-exact" severity note;
    else
      report "tb_gdn_head_emit: FAIL -- " & integer'image(nerr) & " mismatches"
        severity failure;
    end if;
    running <= false;
    wait;
  end process;
end architecture;
