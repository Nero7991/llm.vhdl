-- sim/tb_gdn_y_emit.vhd
-- Bit-exactness of rtl/gdn_y_emit.vhd (subsystem B SITE 13) against
-- ref/gdn_y_emit_vec.c.
--
-- NO TOLERANCE.  The C generator's double oracle is what establishes that the
-- integer recipe means the right thing; this file proves the RTL reproduces
-- that recipe exactly.  A tolerance here could only hide a disagreement.
--
-- Cases are read and run ONE AT A TIME rather than slurped up front: at 24
-- heads x 128 the vectors are 3,072 elements per case and three arrays deep,
-- so holding all of them would be ~450k integers for no benefit.
--
-- The vector file leads with the cases that are easy to get wrong: all
-- exponents equal, an all-zero case (which pins the msb_pos(0) = 0
-- convention), a wide exponent spread, both operands at -32768 (the product
-- maximum 2^30 EXACTLY, the case an over-strict width bound gets wrong),
-- negatives just under a power of two (the counterexample that kills the
-- one-pass amax shortcut), and saturation.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;

entity tb_gdn_y_emit is
  generic( HEADS : positive := 24;
           DIM   : positive := 128;
           VECS  : string   := "gdn_y_emit_vec.txt";
           -- Cycle bound for the overlap phase.  MEASURED: 15,390 cycles
           -- double buffered against 18,462 with the two banks collapsed into
           -- one, for the same 2 blocks and -- note -- the same CORRECT
           -- results in both cases.  17,000 sits between them, so it fails on
           -- a collapse while leaving room for pipeline changes that do not
           -- undo the overlap.
           OCYC_BOUND : positive := 17000 );
end entity;

architecture sim of tb_gdn_y_emit is
  constant NTOT : integer := HEADS * DIM;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  signal in_valid  : std_logic := '0';
  signal in_hfirst : std_logic := '0';
  signal in_o      : signed(15 downto 0) := (others => '0');
  signal in_z      : signed(15 downto 0) := (others => '0');
  signal in_e      : signed(7 downto 0)  := (others => '0');

  signal in_ready : std_logic;
  signal o_valid : std_logic;
  signal o_mant  : signed(15 downto 0);
  signal o_last  : std_logic;
  signal y_exp   : signed(7 downto 0);
  signal done    : std_logic;
  signal o_sat   : std_logic;

  signal running : boolean := true;

  type int_arr is array(natural range <>) of integer;
  -- collected by the monitor process
  shared variable got_y   : int_arr(0 to 4095);
  shared variable got_n   : integer := 0;
  shared variable got_last_at : integer := -1;
  -- Overlap phase.  Two SEPARATE properties, as the gdn_head_emit mutation run
  -- showed: no element is lost under back-pressure (the value check covers
  -- it), and the reduce hides behind the next block's fill (invisible to the
  -- value check -- a single-banked unit with a correct handshake merely stalls
  -- and still returns the right answers, so only CYCLES see it).
  shared variable ob_y : int_arr(0 to 4095);
  shared variable ob_n : integer := 0;
  shared variable ob_blocks : integer := 0;
  signal ob_on : boolean := false;
  signal ocyc : integer := 0;
  signal ocount : boolean := false;
begin
  clk <= not clk after 5 ns when running else '0';

  dut : entity work.gdn_y_emit
    generic map ( HEADS => HEADS, DIM => DIM )
    port map ( clk => clk, rst => rst,
               in_valid => in_valid, in_ready => in_ready,
               in_hfirst => in_hfirst,
               in_o => in_o, in_z => in_z, in_e => in_e,
               o_valid => o_valid, o_mant => o_mant, o_last => o_last,
               y_exp => y_exp, done => done, o_sat => o_sat );

  -- Collect the output stream.  o_last is recorded by INDEX, not merely
  -- checked as a flag, because the bug it guards against is o_last arriving
  -- one cycle after the final o_valid -- a consumer that only counts elements
  -- would never notice, so the testbench has to notice for it.
  mon : process(clk)
  begin
    if rising_edge(clk) then
      if o_valid = '1' then
        if got_n < got_y'length then got_y(got_n) := to_integer(o_mant); end if;
        if o_last = '1' then got_last_at := got_n; end if;
        got_n := got_n + 1;
      end if;
    end if;
  end process;

  ocnt : process(clk)
  begin
    if rising_edge(clk) then
      if ocount then ocyc <= ocyc + 1; else ocyc <= 0; end if;
    end if;
  end process;

  obmon : process(clk)
  begin
    if rising_edge(clk) then
      if ob_on then
        if o_valid = '1' then
          -- keep only the LAST block's elements; earlier blocks are already
          -- covered by the main phase
          if ob_n < ob_y'length then ob_y(ob_n) := to_integer(o_mant); end if;
          ob_n := ob_n + 1;
        end if;
        if done = '1' then
          ob_blocks := ob_blocks + 1;
          if ob_blocks < 2 then ob_n := 0; end if;   -- restart for block 2
        end if;
      end if;
    end if;
  end process;

  stim : process
    file fh : text;
    variable ln : line;
    variable iv, nc, nh, nd : integer;
    variable v_ep : int_arr(0 to 63);
    variable v_om, v_zm, v_y : int_arr(0 to 4095);
    variable v_ye, v_sat : integer;
    variable nerr : integer := 0;
  begin
    file_open(fh, VECS, read_mode);
    readline(fh, ln); read(ln, nc); read(ln, nh); read(ln, nd);
    assert nh = HEADS and nd = DIM
      report "tb_gdn_y_emit: vector file shape mismatch" severity failure;

    rst <= '1'; wait until rising_edge(clk); wait until rising_edge(clk);
    rst <= '0'; wait until rising_edge(clk);

    for c in 0 to nc-1 loop
      readline(fh, ln); read(ln, iv); read(ln, v_ye); read(ln, v_sat);
      readline(fh, ln);
      for h in 0 to HEADS-1 loop read(ln, iv); v_ep(h) := iv; end loop;
      readline(fh, ln);
      for i in 0 to NTOT-1 loop read(ln, iv); v_om(i) := iv; end loop;
      readline(fh, ln);
      for i in 0 to NTOT-1 loop read(ln, iv); v_zm(i) := iv; end loop;
      readline(fh, ln);
      for i in 0 to NTOT-1 loop read(ln, iv); v_y(i) := iv; end loop;

      got_n := 0; got_last_at := -1;

      -- pass A: stream the gated product's operands, one element per cycle
      for h in 0 to HEADS-1 loop
        for j in 0 to DIM-1 loop
          -- Proper valid/ready handshake: hold valid and the data until an
          -- edge where ready is also high.  The unit ignores in_valid for the
          -- whole of its reduce passes if it is not ready, so a driver that
          -- does not honour this loses elements silently.
          in_valid  <= '1';
          if j = 0 then in_hfirst <= '1'; else in_hfirst <= '0'; end if;
          in_o <= to_signed(v_om(h*DIM + j), 16);
          in_z <= to_signed(v_zm(h*DIM + j), 16);
          in_e <= to_signed(v_ep(h), 8);
          loop
            wait until rising_edge(clk);
            exit when in_ready = '1';
          end loop;
        end loop;
      end loop;
      in_valid <= '0'; in_hfirst <= '0';

      while done /= '1' loop wait until rising_edge(clk); end loop;

      if got_n /= NTOT then
        report "case " & integer'image(c) & ": emitted " & integer'image(got_n)
             & " elements, want " & integer'image(NTOT) severity error;
        nerr := nerr + 1;
      end if;
      if got_last_at /= NTOT-1 then
        report "case " & integer'image(c) & ": o_last at element "
             & integer'image(got_last_at) & ", want " & integer'image(NTOT-1)
             & " (o_last must coincide with the final o_valid)" severity error;
        nerr := nerr + 1;
      end if;
      if to_integer(y_exp) /= v_ye then
        report "case " & integer'image(c) & ": y_exp got "
             & integer'image(to_integer(y_exp)) & " want "
             & integer'image(v_ye) severity error;
        nerr := nerr + 1;
      end if;
      if (o_sat = '1') /= (v_sat = 1) then
        report "case " & integer'image(c) & ": o_sat mismatch" severity error;
        nerr := nerr + 1;
      end if;
      for i in 0 to NTOT-1 loop
        if got_y(i) /= v_y(i) then
          report "case " & integer'image(c) & " elem " & integer'image(i)
               & ": got " & integer'image(got_y(i))
               & " want " & integer'image(v_y(i)) severity error;
          nerr := nerr + 1;
          exit;
        end if;
      end loop;

      wait until rising_edge(clk);
    end loop;
    file_close(fh);

    -- ==================================================================
    -- OVERLAP PHASE: two blocks driven back-to-back with no gap.
    file_open(fh, VECS, read_mode);
    readline(fh, ln); read(ln, iv); read(ln, iv); read(ln, iv);
    ob_on <= true; ob_n := 0; ob_blocks := 0; ocount <= true;
    wait until rising_edge(clk);
    for c in 0 to 1 loop
      readline(fh, ln); read(ln, iv); read(ln, v_ye); read(ln, v_sat);
      readline(fh, ln);
      for h in 0 to HEADS-1 loop read(ln, iv); v_ep(h) := iv; end loop;
      readline(fh, ln);
      for i in 0 to NTOT-1 loop read(ln, iv); v_om(i) := iv; end loop;
      readline(fh, ln);
      for i in 0 to NTOT-1 loop read(ln, iv); v_zm(i) := iv; end loop;
      readline(fh, ln);
      for i in 0 to NTOT-1 loop read(ln, iv); v_y(i) := iv; end loop;
      for h in 0 to HEADS-1 loop
        for j in 0 to DIM-1 loop
          in_valid <= '1';
          if j = 0 then in_hfirst <= '1'; else in_hfirst <= '0'; end if;
          in_o <= to_signed(v_om(h*DIM + j), 16);
          in_z <= to_signed(v_zm(h*DIM + j), 16);
          in_e <= to_signed(v_ep(h), 8);
          loop
            wait until rising_edge(clk);
            exit when in_ready = '1';
          end loop;
        end loop;
      end loop;
      in_valid <= '0'; in_hfirst <= '0';
    end loop;
    while ob_blocks < 2 loop wait until rising_edge(clk); end loop;
    ocount <= false; ob_on <= false;
    file_close(fh);

    report "overlap phase: 2 blocks back-to-back took " & integer'image(ocyc)
         & " cycles" severity note;
    for i in 0 to NTOT-1 loop
      if ob_y(i) /= v_y(i) then
        report "OVERLAP block 2 elem " & integer'image(i) & ": got "
             & integer'image(ob_y(i)) & " want " & integer'image(v_y(i))
          severity error;
        nerr := nerr + 1;
        exit;
      end if;
    end loop;
    if ocyc > OCYC_BOUND then
      report "OVERLAP THROUGHPUT: 2 blocks took " & integer'image(ocyc)
           & " cycles, over the bound -- the reduce is NOT hiding behind the "
           & "next block's fill" severity error;
      nerr := nerr + 1;
    end if;

    if nerr = 0 then
      report "tb_gdn_y_emit: PASS -- " & integer'image(nc) & " cases x "
           & integer'image(HEADS) & " heads x " & integer'image(DIM)
           & " bit-exact" severity note;
    else
      report "tb_gdn_y_emit: FAIL -- " & integer'image(nerr) & " mismatches"
        severity failure;
    end if;
    running <= false;
    wait;
  end process;
end architecture;
