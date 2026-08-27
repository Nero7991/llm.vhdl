-- sim/tb_gdn_silu.vhd -- gdn_silu against ref/gdn_silu_vec.c.
--
-- BIT-EXACT, not within a tolerance.  The reference implements 2.1.3's recipe
-- in C and the unit implements it in VHDL; the two are different transcriptions
-- of one specification, so any difference at all is a transcription error and
-- a tolerance would only hide it.  The accuracy question -- how far the recipe
-- itself is from a double oracle -- is answered by the generator, which
-- measures it there and prints it, and NOT here.  Keeping the two apart is
-- deliberate: a testbench that checks accuracy cannot also detect a wrong
-- recipe, because a wrong recipe that is accurate enough passes.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;

entity tb_gdn_silu is
  generic( LANES : positive := 4;
           ARG_Q : integer  := 12;
           N     : positive := 128;
           NCASE : positive := 256;
           VECS  : string   := "gdn_silu_vec.txt" );
end entity;

architecture sim of tb_gdn_silu is
  constant NB : integer := N / LANES;
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal e_seg : signed(7 downto 0) := (others => '0');
  signal s_valid : std_logic := '0';
  signal s_data  : std_logic_vector(LANES*16-1 downto 0) := (others => '0');
  signal o_valid : std_logic;
  signal o_data  : std_logic_vector(LANES*16-1 downto 0);

  type i_arr is array (natural range <>) of integer;
  type seg_arr is array (0 to NCASE-1) of i_arr(0 to N-1);
  signal loaded : boolean := false;
  shared variable v_sm, v_y : seg_arr;
  shared variable v_e : i_arr(0 to NCASE-1);
  shared variable nfail, ncheck : integer := 0;
  -- The clock is GUARDED.  Unguarded, it keeps toggling after the stimulus
  -- process reaches its final `wait;`, so the simulation never ends: the test
  -- reports PASS and then spins at 100% CPU forever.  One such run was found
  -- alive after 4h58m.  It is invisible when output is piped through `tail`,
  -- because the report has already been printed by then.
  signal running : boolean := true;

begin
  clk <= not clk after 5 ns when running else '0';

  dut : entity work.gdn_silu
    generic map(LANES => LANES, ARG_Q => ARG_Q)
    port map(clk => clk, rst => rst, e_seg => e_seg,
             s_valid => s_valid, s_data => s_data,
             o_valid => o_valid, o_data => o_data);

  load : process
    file fh : text; variable ln : line; variable iv, nc, nn : integer;
  begin
    file_open(fh, VECS, read_mode);
    readline(fh, ln); read(ln, nc); read(ln, nn);
    assert nc = NCASE and nn = N report "vector file shape" severity failure;
    for c in 0 to NCASE-1 loop
      readline(fh, ln); read(ln, iv); read(ln, iv); v_e(c) := iv;
      readline(fh, ln); for i in 0 to N-1 loop read(ln, iv); v_sm(c)(i) := iv; end loop;
      readline(fh, ln); for i in 0 to N-1 loop read(ln, iv); v_y(c)(i) := iv; end loop;
    end loop;
    file_close(fh);
    loaded <= true; wait;
  end process;

  drive : process
  begin
    wait until loaded;
    wait for 40 ns; rst <= '0'; wait until rising_edge(clk);
    for c in 0 to NCASE-1 loop
      -- e_seg is set BEFORE the segment and held: it is a per-segment scalar,
      -- and the unit reads it combinationally at S0.  Changing it mid-segment
      -- would corrupt the groups still inside the pipe, which is the same
      -- head-boundary hazard gdn_recur_pipe had to double-buffer for.  Here
      -- the segments are drained between cases instead, because silu has no
      -- throughput reason to overlap them.
      e_seg <= to_signed(v_e(c), 8);
      wait until rising_edge(clk);
      for g in 0 to NB-1 loop
        s_valid <= '1';
        for k in 0 to LANES-1 loop
          s_data((k+1)*16-1 downto k*16)
            <= std_logic_vector(to_signed(v_sm(c)(g*LANES + k), 16));
        end loop;
        wait until rising_edge(clk);
      end loop;
      s_valid <= '0';
      for d in 0 to 11 loop wait until rising_edge(clk); end loop;
    end loop;
    for d in 0 to 31 loop wait until rising_edge(clk); end loop;
    assert nfail = 0
      report "gdn_silu: " & integer'image(nfail) & " mismatch(es) in "
           & integer'image(ncheck) & " groups" severity error;
    if nfail = 0 then
      report "gdn_silu: bit-exact with the C reference on all "
           & integer'image(ncheck) & " groups (" & integer'image(ncheck*LANES)
           & " elements), LANES=" & integer'image(LANES)
           & " ARG_Q=" & integer'image(ARG_Q) severity note;
    end if;
    running <= false;
    wait;
  end process;

  collect : process(clk)
    variable c, g : integer := 0;
    variable got, want : integer;
  begin
    if rising_edge(clk) and rst = '0' then
      if o_valid = '1' then
        for k in 0 to LANES-1 loop
          got  := to_integer(signed(o_data((k+1)*16-1 downto k*16)));
          want := v_y(c)(g*LANES + k);
          if got /= want then
            report "case " & integer'image(c) & " (e=" & integer'image(v_e(c))
                 & ") element " & integer'image(g*LANES + k)
                 & ": got " & integer'image(got) & " want " & integer'image(want)
                 & "  from sm " & integer'image(v_sm(c)(g*LANES + k))
              severity error;
            nfail := nfail + 1;
          end if;
        end loop;
        ncheck := ncheck + 1;
        if g = NB-1 then g := 0; c := c + 1; else g := g + 1; end if;
      end if;
    end if;
  end process;
end architecture;
