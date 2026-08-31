-- gain16_romoracle.vhd -- TRACK GAIN16, 2026-08-30.  SCRATCH ONLY.
--
-- DELIBERATELY NOT IN sim/ AND DELIBERATELY NOT NAMED tb_*.  A new
-- sim/tb_*.vhd becomes an auto-discovered gate row for every track whether the
-- author meant it or not, and this one needs `norm_w_9b.hex` -- 5 MB, not in
-- git, living on /mnt/storage -- so as a gate row it would turn the shared
-- gate RED for everybody the moment that path was missing.
--
-- THE QUESTION IT ANSWERS.  Does the gain word the ELABORATED ROM presents to
-- `rmsnorm_rs_mem`'s bank port equal `norm_w_9b.hex`, element by element, at
-- the real 266,240 length?
--
-- WHY THE EXISTING CHECK CANNOT ANSWER IT.  `sim:tb_llama_top_normw` runs at
-- hidden = 64 against a 9 x 64 image reduced by MEAN over groups of 64, whose
-- element-to-element spread is about 2% of the mean; it is a LANDMARK, a
-- change detector, and its own header says so.  Worse for this track: TRACK
-- GWTWO reported under its own name that that row's sub-word-mirror mutant
-- DOES NOT BITE at GW = 1, because there the mutation is a semantic no-op.
-- GW = 1 is what is landed, so that row's PASS is not evidence about a change
-- to the gain STORE.
--
-- WHY IT IS NOT A ROUND TRIP.  `decode(encode(x)) == x` passes for a
-- wrong-but-consistent codec -- the `m7 mutant` recorded in CLAUDE.md, where a
-- packer and a reversed decoder passed an entire self-test suite.  Nothing
-- here compares the design against itself: the ONLY reference is the hex file
-- on disk, read independently by this bench, and the design is compared
-- against it.
--
-- WHAT IT CANNOT SEE, stated rather than discovered later:
--   * A CONSISTENT PERMUTATION OF THE CODEBOOK is invisible to it AND IS NOT A
--     BUG -- ascending or descending codeword order are equally valid
--     encodings and both reproduce the file.  Mutant `E4` below is exactly
--     that and is reported as NOT BITING.
--   * It observes the word stream into the unit's bank port.  It says nothing
--     about what the unit then does with it.
--   * It runs one token's worth of norm ops from reset.  It does not exercise
--     the `novf` overflow path or a mid-token reset.
--
-- NO HARDWARE.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity gain16_romoracle is
  generic(
    NORM_W_IMAGE : string  := "";
    NVEC         : positive := 65;      -- norm ops in the image
    NN           : positive := 4096     -- elements per op (the 9B hidden)
  );
end entity;

architecture tb of gain16_romoracle is
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
  signal on_pub : std_logic;
  signal oexp : signed(EXP_W-1 downto 0);
  signal ossq : unsigned(63 downto 0);
  signal onn  : unsigned(15 downto 0);
  signal p_we : std_logic;
  signal p_wa, p_wd, p_ni : std_logic_vector(15 downto 0);
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
             obs_norm_ssq => ossq, obs_norm_n => onn,
             o_p_we => p_we, o_p_wa => p_wa, o_p_wd => p_wd, o_p_ni => p_ni);

  stim : process
    type w_t is array (0 to NN-1) of std_logic_vector(MANT_W-1 downto 0);
    type b_t is array (0 to NN-1) of boolean;
    variable cap    : w_t;
    variable seen   : b_t;
    file     fh     : text;
    variable ok     : file_open_status;
    variable l      : line;
    variable expv   : std_logic_vector(MANT_W-1 downto 0);
    variable c      : natural;
    variable ncmp   : natural := 0;   -- elements actually compared
    variable nbad   : natural := 0;   -- mismatches
    variable nmiss  : natural := 0;   -- elements the load never wrote
    variable nivec  : natural := 0;   -- ops whose observed nidx was wrong
    variable firstb : boolean := true;
    variable a      : natural;
    variable ol     : line;
  begin
    assert NORM_W_IMAGE /= ""
      report "GAIN16_ORACLE: no image given" severity failure;
    file_open(ok, fh, NORM_W_IMAGE, read_mode);
    assert ok = open_ok
      report "GAIN16_ORACLE: cannot open " & NORM_W_IMAGE severity failure;

    v_n <= to_unsigned(NN, VN_W);
    rst <= '1';
    for i in 0 to 9 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);
    go <= '1';
    wait until rising_edge(clk);
    go <= '0';

    for k in 0 to NVEC-1 loop
      for i in 0 to NN-1 loop seen(i) := false; end loop;
      v_start <= '1';
      c := 0;
      loop
        wait until rising_edge(clk);
        c := c + 1;
        if p_we = '1' then
          a := to_integer(unsigned(p_wa));
          cap(a)  := p_wd;
          seen(a) := true;
          if to_integer(unsigned(p_ni)) /= k then nivec := nivec + 1; end if;
        end if;
        exit when o_done = '1';
        if c > 200000 then
          report "GAIN16_ORACLE: op " & integer'image(k) & " never completed"
            severity failure;
        end if;
      end loop;

      -- Compare THIS op's captured gain vector against the next NN lines of
      -- the image.  The file is read strictly sequentially and the ops run in
      -- schedule order, so line k*NN + i is element i of op k by construction.
      for i in 0 to NN-1 loop
        assert not endfile(fh)
          report "GAIN16_ORACLE: image is short at op " & integer'image(k)
          severity failure;
        readline(fh, l);
        hread(l, expv);
        if not seen(i) then
          nmiss := nmiss + 1;
        else
          ncmp := ncmp + 1;
          if cap(i) /= expv then
            nbad := nbad + 1;
            if firstb then
              firstb := false;
              write(ol, string'("GAIN16_ORACLE FIRST MISMATCH op="));
              write(ol, k);
              write(ol, string'(" elem="));
              write(ol, i);
              write(ol, string'(" got=0x"));
              hwrite(ol, cap(i));
              write(ol, string'(" want=0x"));
              hwrite(ol, expv);
              writeline(output, ol);
            end if;
          end if;
        end if;
      end loop;

      v_ack <= '1';
      wait until rising_edge(clk);
      v_ack <= '0';
    end loop;
    v_start <= '0';
    file_close(fh);

    write(ol, string'("GAIN16_ORACLE compared="));
    write(ol, ncmp);
    write(ol, string'(" mismatched="));
    write(ol, nbad);
    write(ol, string'(" never_written="));
    write(ol, nmiss);
    write(ol, string'(" wrong_nidx="));
    write(ol, nivec);
    writeline(output, ol);

    -- THE VERDICT, and the coverage gate is part of it.  A run that compared
    -- nothing must not be able to print PASS: TRACK ROUTE2's residency
    -- checker printed PASS over an object neither of its checks ever read, and
    -- that class of defect is what this line exists to prevent.
    if nbad = 0 and nmiss = 0 and nivec = 0 and ncmp = NVEC*NN then
      report "GAIN16_ORACLE PASS " & integer'image(ncmp) & " elements"
        severity note;
    else
      report "GAIN16_ORACLE FAIL" severity failure;
    end if;
    running <= false;
    wait;
  end process;
end architecture;
