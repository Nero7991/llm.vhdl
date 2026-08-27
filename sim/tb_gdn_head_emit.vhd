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

  signal in_ready : std_logic;
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

  -- Overlap-phase capture.  done for head h fires WHILE head h+1 is filling,
  -- so the result cannot be read by the stimulus process at its leisure; it
  -- has to be snapshotted the cycle it appears.
  type snap_t is array(0 to 3) of std_logic_vector(DIM*16-1 downto 0);
  type sexp_t is array(0 to 3) of integer;
  shared variable snap_m : snap_t;
  shared variable snap_e : sexp_t;
  shared variable snap_n : integer := 0;
  signal snapping : boolean := false;
  -- A shared variable, not a signal: it is written by BOTH the monitor and
  -- the stimulus, and a signal with two drivers is an unresolved-signal
  -- elaboration error with no line number.  Same mistake as `cyc` in the
  -- cycle probe an hour earlier.
  shared variable ready_fell : boolean := false;
  -- The overlap phase checks two SEPARATE properties, and it took a mutation
  -- run to see that they are separate:
  --   correctness -- no column is lost under back-pressure.  The value
  --     comparison below covers this, and it is the property the FIRST version
  --     of this unit violated, because it had no in_ready at all and simply
  --     ignored in_valid during the reduce.
  --   throughput  -- the reduce hides behind the next head's fill.  The value
  --     comparison does NOT cover this: with a correct valid/ready handshake a
  --     single-banked unit just stalls the producer and still returns the right
  --     answers.  Collapsing the two banks passes the value check and is only
  --     visible as CYCLES, so the cycle bound below is the whole test for it.
  signal ocyc : integer := 0;
  signal ocount : boolean := false;
begin
  clk <= not clk after 5 ns when running else '0';

  dut : entity work.gdn_head_emit
    generic map ( DIM => DIM )
    port map ( clk => clk, rst => rst,
               in_valid => in_valid, in_acc => in_acc, in_e_o => in_e_o,
               in_ready => in_ready,
               done => done, o_mant => o_mant, o_e_head => o_e_head,
               o_sat => o_sat );

  ocnt : process(clk)
  begin
    if rising_edge(clk) then
      if ocount then ocyc <= ocyc + 1; else ocyc <= 0; end if;
    end if;
  end process;

  snapmon : process(clk)
  begin
    if rising_edge(clk) then
      if snapping then
        if done = '1' and snap_n < 4 then
          snap_m(snap_n) := o_mant;
          snap_e(snap_n) := to_integer(o_e_head);
          snap_n := snap_n + 1;
        end if;
        if in_ready = '0' then ready_fell := true; end if;
      end if;
    end if;
  end process;

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

    -- ==================================================================
    -- OVERLAP PHASE.  The reason the unit is double buffered: gdn_recur_pipe
    -- starts the next head immediately, so head h+1's columns arrive WHILE
    -- head h is still reducing.  The single-banked first version ignored
    -- in_valid during the reduce and would have dropped them silently, which
    -- is why this phase exists and why it drives with NO gap at all.
    snapping <= true; snap_n := 0; ready_fell := false;
    ocount <= true;
    wait until rising_edge(clk);
    for c in 0 to 3 loop
      for i in 0 to DIM-1 loop
        -- Proper valid/ready handshake: hold valid and the data until an edge
        -- where ready is also high.  Back-pressure WILL assert here: this
        -- phase fills a head in 128 cycles against a 268-cycle reduce, which
        -- is far tighter than the real 512-cycle arrival, so it is a harder
        -- test than the hardware will ever see.  Stalling is correct;
        -- dropping is not, and the single-banked version dropped.
        in_valid <= '1';
        in_acc   <= to_s40(v_acc(c)(i));
        in_e_o   <= to_signed(v_eo(c)(i), 8);
        loop
          wait until rising_edge(clk);
          exit when in_ready = '1';
        end loop;
      end loop;
      in_valid <= '0';
    end loop;
    -- drain the last head
    while snap_n < 4 loop wait until rising_edge(clk); end loop;
    snapping <= false;
    report "overlap phase: 4 heads back-to-back took " & integer'image(ocyc)
         & " cycles" severity note;
    -- MEASURED: **1,202** cycles double buffered against **1,586** with the
    -- two banks collapsed into one, for the same 4 heads and, note, the same
    -- CORRECT results in both cases.  The bound sits between them rather than
    -- at either, so it fails on a collapse to one bank while leaving room for
    -- pipeline changes that do not undo the overlap.
    if ocyc > 1300 then
      report "OVERLAP THROUGHPUT: 4 heads took " & integer'image(ocyc)
           & " cycles, over the 1300 bound -- the reduce is NOT hiding behind "
           & "the next head's fill, i.e. the double buffer is not working"
        severity error;
      nerr := nerr + 1;
    end if;
    ocount <= false;

    for c in 0 to 3 loop
      if snap_e(c) /= v_eh(c) then
        report "OVERLAP case " & integer'image(c) & ": e_head got "
             & integer'image(snap_e(c)) & " want " & integer'image(v_eh(c))
          severity error;
        nerr := nerr + 1;
      end if;
      for i in 0 to DIM-1 loop
        if to_integer(signed(snap_m(c)((i+1)*16-1 downto i*16))) /= v_mnt(c)(i) then
          report "OVERLAP case " & integer'image(c) & " col " & integer'image(i)
               & ": got "
               & integer'image(to_integer(signed(snap_m(c)((i+1)*16-1 downto i*16))))
               & " want " & integer'image(v_mnt(c)(i)) severity error;
          nerr := nerr + 1;
          exit;
        end if;
      end loop;
    end loop;
    report "overlap phase: back-pressure asserted at least once: "
         & boolean'image(ready_fell) severity note;

    if nerr = 0 then
      report "tb_gdn_head_emit: PASS -- " & integer'image(NCASE)
           & " cases x " & integer'image(DIM)
           & " bit-exact, plus 4 heads back-to-back with no gap" severity note;
    else
      report "tb_gdn_head_emit: FAIL -- " & integer'image(nerr) & " mismatches"
        severity failure;
    end if;
    running <= false;
    wait;
  end process;
end architecture;
