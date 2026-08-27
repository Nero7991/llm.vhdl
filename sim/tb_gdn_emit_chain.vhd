-- Testbench for gdn_emit_chain, the site 12 -> rmsnorm_bf -> silu -> site 13
-- sequencer.  Vectors from ref/gdn_emit_chain_vec.c, whose own oracle is
-- double precision, so this is a check of the RTL against a reference that was
-- itself checked in a different number system.
--
-- FOUR SEAMS, none of which the unit-level tests reach:
--
--   seam 1  head_emit's (o_mant, o_e_head)  -> rmsnorm_bf's (x_mant, x_exp)
--   seam 2  rmsnorm_bf's o_mant             -> y_emit's in_o
--   seam 3  silu's o_data                   -> y_emit's in_z
--   seam 4  rn_exp + z_e_held               -> y_emit's in_e
--
-- Seam 4 cannot be checked by inspection at all: it is an exponent SUM, and an
-- error in it scales the whole block by a power of two, which looks like a
-- plausible answer rather than a broken one.  Only the y_exp check catches it.
--
-- TWO INDEPENDENT PRODUCERS, and this structure is load bearing.  An earlier
-- version fed z and then columns from ONE process, blocking on z_ready before
-- each head's columns.  That coupled the two streams: the z handshake
-- throttled the column path, col_ready was never stressed, and a COL_GAP sweep
-- down to one column per cycle reported ZERO refused columns -- a clean,
-- confident, meaningless result.  In the real engine the two are independent:
-- gdn_recur_pipe drives columns with NO ready input at all (`o_res_valid`
-- free-runs), so a col_ready that falls under it is a LOST column, not a
-- stall.  The two processes here parse the vector file separately for exactly
-- that reason -- no shared state means no accidental coupling.
--
-- TWO MODES.  OVERLAP=false drains between blocks; OVERLAP=true is how the
-- chain actually runs (S_WAITBLK returns to S_IDLE at once) and is the mode
-- that catches the w_mant hazard: with the weight latch removed it fails on
-- head 23 of every block, and only head 23.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;

entity tb_gdn_emit_chain is
  generic(
    OVERLAP : boolean := true;
    -- Cycles between successive column offers.  The real producer emits one
    -- column result every DIM/LANES cycles -- 4 at DIM=128, LANES=32.  Values
    -- below 4 model a wider LANES; the spec's sweep table contemplates
    -- LANES=64, which is COL_GAP=2.
    COL_GAP : integer := 4;
    -- Passed straight through to the DUT.  With STRICT=true a refused column
    -- is a failure rather than a stall, which is what the top level wants
    -- because gdn_recur_pipe cannot be stalled.
    STRICT  : boolean := false;
    -- Datapath widths, exposed so a proposed re-sizing can be checked for
    -- CORRECTNESS before it is adopted on the strength of an area/Fmax sweep.
    -- SILU_LANES sets SI_BEATS = DIM/SILU_LANES, so it changes the gate's
    -- sequencing, not just its width.
    -- Cycles the z producer waits before offering each head's gate vector.
    -- 0 makes it run maximally ahead, which is what MASKED the z_have defect:
    -- z was always already latched, so a chain that never checked z_have still
    -- passed. Any positive value makes z arrive late at least once.
    Z_DELAY : integer := 0;
    SILU_LANES : positive := 16;
    RMS_LANES  : positive := 4;
    -- Head count.  A generic, not a constant, because the back-pressure
    -- experiments below care only about gdn_head_emit's reduce-versus-arrival
    -- race, which is per-head and independent of how many heads a block has.
    -- Running them at HEADS=4 costs a sixth of the sim time and measures the
    -- same thing.  Correctness runs use 24, the real value.
    HEADS   : integer := 24;
    -- Microseconds between progress reports; 0 disables.  Exists because a
    -- run that produces no output is ambiguous between "wedged" and "slow",
    -- and that ambiguity cost an hour of guessing on this testbench.
    HEARTBEAT_US : integer := 0
  );
end entity;

architecture sim of tb_gdn_emit_chain is
  constant DIM   : integer := 128;
  -- Sized for the vector file, not the design: an overlapped run cannot check
  -- block b before b+1 is in flight, so every block's output is retained.
  constant MAX_BLOCKS : integer := 8;

  type yarr_t is array (0 to DIM-1) of integer;
  type yall_t is array (0 to MAX_BLOCKS*64*DIM-1) of integer;
  type barr_t is array (0 to MAX_BLOCKS-1) of integer;
  type i64arr_t is array (0 to 511) of signed(63 downto 0);

  -- 64-bit decimal read.  textio's integer read is 32 bit and o_acc reaches
  -- 2^36, so it cannot be used; silent truncation of the top bits would look
  -- like a chain error rather than a testbench error.  Declared here rather
  -- than inside a process because both producers parse the file.
  procedure rd64(variable ln : inout line; variable v : out signed(63 downto 0)) is
    variable c    : character;
    variable good : boolean;
    variable neg  : boolean := false;
    variable acc  : signed(63 downto 0) := (others => '0');
    variable started : boolean := false;
  begin
    loop
      read(ln, c, good);
      exit when not good;
      if c = ' ' or c = HT then
        if started then exit; end if;
      elsif c = '-' then
        neg := true; started := true;
      elsif c >= '0' and c <= '9' then
        started := true;
        acc := resize(acc * 10 + character'pos(c) - character'pos('0'), 64);
      else
        exit;
      end if;
    end loop;
    assert started report "tb_gdn_emit_chain: expected a number" severity failure;
    if neg then v := -acc; else v := acc; end if;
  end procedure;

  procedure rdi(variable ln : inout line; variable v : out integer) is
    variable t : signed(63 downto 0);
  begin
    rd64(ln, t); v := to_integer(t);
  end procedure;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal running : boolean := true;

  signal w_mant : std_logic_vector(DIM*16-1 downto 0) := (others => '0');
  signal w_exp  : integer := 0;

  signal col_valid : std_logic := '0';
  signal col_acc   : signed(39 downto 0) := (others => '0');
  signal col_e_o   : signed(7 downto 0)  := (others => '0');
  signal col_ready : std_logic;

  signal z_mant  : std_logic_vector(DIM*16-1 downto 0) := (others => '0');
  signal z_exp   : signed(7 downto 0) := (others => '0');
  signal z_valid : std_logic := '0';
  signal z_ready : std_logic;

  signal y_valid : std_logic;
  signal y_mant  : signed(15 downto 0);
  signal y_last  : std_logic;
  signal y_exp   : signed(7 downto 0);
  signal done    : std_logic;
  signal y_sat   : std_logic;
  signal w_taken : std_logic;

  -- Collected output.  Driven ONLY by the collector; two drivers on one signal
  -- elaborate with no line number in ghdl, which cost real time twice here.
  signal y_got   : yall_t := (others => 0);
  signal y_idx   : integer := 0;
  signal ye_got  : barr_t := (others => 0);
  signal cnt_got : barr_t := (others => 0);
  signal blk_got : integer := 0;

  -- Back-pressure monitor: cycles on which a column was OFFERED and REFUSED.
  -- For an elastic producer that is a legal stall; for gdn_recur_pipe, which
  -- has no ready input, every one of these is a dropped column.
  signal stall_cyc : integer := 0;
  signal z_done    : boolean := false;
begin

  clk <= (not clk) after 0.5 ns when running else '0';

  dut : entity work.gdn_emit_chain
    generic map ( HEADS => HEADS, DIM => DIM,
                  SILU_LANES => SILU_LANES, RMS_LANES => RMS_LANES,
                  Q => 12, EPS => 1.0e-6,
                  STRICT_PRODUCER => STRICT )
    port map ( clk => clk, rst => rst,
               w_mant => w_mant, w_exp => w_exp,
               col_valid => col_valid, col_acc => col_acc, col_e_o => col_e_o,
               col_ready => col_ready,
               z_mant => z_mant, z_exp => z_exp,
               z_valid => z_valid, z_ready => z_ready,
               y_valid => y_valid, y_mant => y_mant, y_last => y_last,
               y_exp => y_exp, done => done, y_sat => y_sat,
               w_taken => w_taken );

  collect : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        y_idx <= 0; blk_got <= 0;
      else
        if y_valid = '1' then
          assert blk_got < MAX_BLOCKS and y_idx < MAX_BLOCKS*HEADS*DIM
            report "tb_gdn_emit_chain: more output than MAX_BLOCKS holds"
            severity failure;
          y_got(y_idx) <= to_integer(y_mant);
          y_idx        <= y_idx + 1;
          -- blk_got does not advance until the cycle after `done`, so a value
          -- landing on the same edge as `done` is attributed to its own block.
          ye_got(blk_got)  <= to_integer(y_exp);
          cnt_got(blk_got) <= cnt_got(blk_got) + 1;
        end if;
        if done = '1' then
          blk_got <= blk_got + 1;
        end if;
      end if;
    end if;
  end process;

  heartbeat : process
  begin
    if HEARTBEAT_US = 0 then wait; end if;
    loop
      wait for HEARTBEAT_US * 1 us;
      exit when not running;
      report "tb_gdn_emit_chain: heartbeat blk=" & integer'image(blk_got)
           & " y_idx=" & integer'image(y_idx)
           & " refused-column cycles=" & integer'image(stall_cyc)
           & " col_valid=" & std_logic'image(col_valid)
           & " col_ready=" & std_logic'image(col_ready)
           & " z_valid=" & std_logic'image(z_valid)
           & " z_ready=" & std_logic'image(z_ready)
           & " y_valid=" & std_logic'image(y_valid);
    end loop;
    wait;
  end process;

  monitor : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        stall_cyc <= 0;
      elsif col_valid = '1' and col_ready = '0' then
        stall_cyc <= stall_cyc + 1;
      end if;
    end if;
  end process;

  -- ------------------------------------------------------------------ --
  -- z producer.  Independent of the column producer by construction.
  -- ------------------------------------------------------------------ --
  stim_z : process
    file     zf : text;
    variable l  : line;
    variable ok : file_open_status;
    variable NB, hh, dd : integer;
    variable ti : integer;
    variable t64 : signed(63 downto 0);
    variable ze : integer;
  begin
    file_open(ok, zf, "gdn_emit_chain_vec.txt", read_mode);
    assert ok = open_ok report "tb_gdn_emit_chain: stim_z cannot open vectors"
      severity failure;
    readline(zf, l); rdi(l, NB); rdi(l, hh); rdi(l, dd);

    wait until rst = '0';
    wait until rising_edge(clk);

    for b in 0 to NB-1 loop
      readline(zf, l);
      rdi(l, ti); rdi(l, ti); rdi(l, ti); rdi(l, ti); rdi(l, ze);
      readline(zf, l);                              -- ssm_norm, not ours
      z_exp <= to_signed(ze, 8);

      for h in 0 to HEADS-1 loop
        readline(zf, l);                            -- o_acc, not ours
        readline(zf, l);                            -- e_o,   not ours
        readline(zf, l);
        for j in 0 to DIM-1 loop
          rdi(l, ti);
          z_mant((j+1)*16-1 downto j*16) <= std_logic_vector(to_signed(ti, 16));
        end loop;
        if Z_DELAY > 0 then
          for d in 1 to Z_DELAY loop wait until rising_edge(clk); end loop;
        end if;
        z_valid <= '1';
        loop
          wait until rising_edge(clk);
          exit when z_ready = '1';
        end loop;
        -- Drop valid for one cycle so the held vector cannot be latched a
        -- second time for the following head.  The chain releases z_have at
        -- the end of a head's serialization, and a still-asserted z_valid
        -- carrying the PREVIOUS head's data would be taken again -- a stale
        -- gate that is numerically plausible and silent.
        z_valid <= '0';
        wait until rising_edge(clk);
      end loop;
      readline(zf, l);                              -- expected y, not ours
    end loop;
    file_close(zf);
    z_done <= true;
    wait;
  end process;

  -- ------------------------------------------------------------------ --
  -- column producer, block weights, and the checker
  -- ------------------------------------------------------------------ --
  stim_col : process
    file     vf : text;
    variable l  : line;
    variable ok : file_open_status;
    variable NB, HDR_H, HDR_D : integer;
    variable b_i, ye_i, sat_i, we_i, ze_i : integer;
    variable ti : integer;
    variable oacc : i64arr_t;
    variable eo   : yarr_t;
    variable yexp_all : yall_t;
    variable ye_ref   : barr_t;
    variable nbad : integer := 0;
  begin
    file_open(ok, vf, "gdn_emit_chain_vec.txt", read_mode);
    assert ok = open_ok
      report "tb_gdn_emit_chain: cannot open gdn_emit_chain_vec.txt"
      severity failure;

    readline(vf, l); rdi(l, NB); rdi(l, HDR_H); rdi(l, HDR_D);
    assert HDR_H = HEADS and HDR_D = DIM
      report "tb_gdn_emit_chain: vector shape does not match the generics"
      severity failure;

    rst <= '1';
    for i in 0 to 9 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);

    for b in 0 to NB-1 loop
      readline(vf, l);
      rdi(l, b_i); rdi(l, ye_i); rdi(l, sat_i); rdi(l, we_i); rdi(l, ze_i);
      ye_ref(b) := ye_i;

      -- ssm_norm, presented before the block's columns and held until w_taken
      readline(vf, l);
      for i in 0 to DIM-1 loop
        rdi(l, ti);
        w_mant((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(ti, 16));
      end loop;
      w_exp <= we_i;
      wait until rising_edge(clk);

      for h in 0 to HEADS-1 loop
        readline(vf, l);
        for j in 0 to DIM-1 loop rd64(l, oacc(j)); end loop;
        readline(vf, l);
        for j in 0 to DIM-1 loop rdi(l, eo(j)); end loop;
        readline(vf, l);                            -- z, not ours

        col_valid <= '1';
        for j in 0 to DIM-1 loop
          col_acc <= resize(oacc(j), 40);
          col_e_o <= to_signed(eo(j), 8);
          loop
            wait until rising_edge(clk);
            exit when col_ready = '1';
          end loop;
          if COL_GAP > 1 then
            col_valid <= '0';
            for g in 1 to COL_GAP-1 loop wait until rising_edge(clk); end loop;
            col_valid <= '1';
          end if;
        end loop;
        col_valid <= '0';

        -- The weight latch fires on head 0.  Waiting for it rather than
        -- assuming it keeps the handshake honest: a w_taken that never pulsed
        -- hangs the run instead of passing it.
        if h = 0 then
          while w_taken = '0' loop wait until rising_edge(clk); end loop;
        end if;
      end loop;

      -- expected output, stashed rather than checked: in overlapped mode block
      -- b is still streaming out while b+1 is being fed
      readline(vf, l);
      for i in 0 to HEADS*DIM-1 loop rdi(l, yexp_all(b*HEADS*DIM + i)); end loop;

      if not OVERLAP then
        while blk_got < b+1 loop wait until rising_edge(clk); end loop;
      end if;
    end loop;

    while blk_got < NB loop wait until rising_edge(clk); end loop;
    wait until rising_edge(clk);

    for b in 0 to NB-1 loop
      assert cnt_got(b) = HEADS*DIM
        report "tb_gdn_emit_chain: block " & integer'image(b) & " emitted "
             & integer'image(cnt_got(b)) & " values, expected "
             & integer'image(HEADS*DIM)
        severity failure;

      assert ye_got(b) = ye_ref(b)
        report "tb_gdn_emit_chain: block " & integer'image(b)
             & " y_exp is " & integer'image(ye_got(b))
             & ", reference says " & integer'image(ye_ref(b))
             & ".  A wrong block exponent is seam 4: it scales the whole "
             & "block by a power of two and still looks plausible."
        severity failure;

      for i in 0 to HEADS*DIM-1 loop
        if y_got(b*HEADS*DIM + i) /= yexp_all(b*HEADS*DIM + i) then
          nbad := nbad + 1;
          if nbad <= 8 then
            report "tb_gdn_emit_chain: block " & integer'image(b)
                 & " element " & integer'image(i)
                 & " head " & integer'image(i / DIM)
                 & " lane " & integer'image(i mod DIM)
                 & " got " & integer'image(y_got(b*HEADS*DIM + i))
                 & " expected " & integer'image(yexp_all(b*HEADS*DIM + i))
              severity error;
          end if;
        end if;
      end loop;
    end loop;

    file_close(vf);

    if nbad = 0 then
      report "tb_gdn_emit_chain: PASS -- " & integer'image(NB)
           & " blocks x " & integer'image(HEADS) & " heads x "
           & integer'image(DIM) & " bit-exact, OVERLAP="
           & boolean'image(OVERLAP) & " COL_GAP=" & integer'image(COL_GAP)
           & " refused-column cycles=" & integer'image(stall_cyc)
           & " SILU_LANES=" & integer'image(SILU_LANES)
           & " RMS_LANES=" & integer'image(RMS_LANES)
        severity note;
    else
      report "tb_gdn_emit_chain: FAIL -- " & integer'image(nbad)
           & " mismatched elements, COL_GAP=" & integer'image(COL_GAP)
           & " refused-column cycles=" & integer'image(stall_cyc)
        severity failure;
    end if;

    running <= false;
    wait;
  end process;

end architecture;
