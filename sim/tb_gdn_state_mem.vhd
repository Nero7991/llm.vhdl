-- sim/tb_gdn_state_mem.vhd -- `rtl/gdn_state_mem.vhd` against an independent
-- model of the memory it is replacing.
--
-- WHY AN ORACLE AND NOT A SELF-TEST.  This memory exists to take over from
-- `rtl/llama_top.vhd`'s `stmem`, which is a process VARIABLE written and read
-- inside one clocked process.  Writing back what was written proves nothing
-- here: a wrong-but-consistent memory passes a round trip, and the `m7 mutant`
-- in this repository is the recorded case of exactly that.  So the reference
-- is a SEPARATE model, coded from `llama_top`'s statement order rather than
-- from this entity's, and every access is compared.
--
-- THE ONE BEHAVIOUR THAT IS EASY TO GET WRONG AND INVISIBLE IN NORMAL TRAFFIC
-- is a read and a write to the SAME address on the SAME edge.  `llama_top`
-- orders the read BEFORE the write, so the read returns the PRE-edge value;
-- write-first is a different memory and its difference shows up only on that
-- one coincidence.  `llama_top`'s own declaration comment calls the ordering
-- load-bearing.  A random stimulus over a 131,072-word space will essentially
-- never produce that coincidence by chance -- at the shrunk shape used here it
-- is still 1 in 2,048 per cycle, and at the real shape 1 in 131,072 -- so the
-- collision is DRIVEN DELIBERATELY in phase 2 and counted.  The bench refuses
-- to pass if that counter is zero, because a bench that never reached the case
-- it exists for is not evidence about it.
--
-- SHAPE.  Deliberately small, and NOT the 9B shape: the point is the access
-- protocol, and `regress.sh` runs this row with DEFAULT generics.  The 9B
-- extent (8,388,608 bits for one layer) is a synthesis question answered by
-- `sim/ooc_gdn_state.tcl`, not a simulation one.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.finish;

entity tb_gdn_state_mem is
  generic(
    VAL_HEADS   : positive := 4;
    DIM         : positive := 8;
    RECUR_LANES : positive := 2;
    NRAND       : positive := 4000
  );
end entity;

architecture sim of tb_gdn_state_mem is
  constant NBR   : positive := DIM / RECUR_LANES;
  constant WORDS : positive := VAL_HEADS * DIM * NBR;
  constant WBITS : positive := RECUR_LANES * 16;

  signal clk : std_logic := '0';

  signal r_en   : std_logic := '0';
  signal r_head : natural range 0 to VAL_HEADS-1 := 0;
  signal r_col  : natural range 0 to DIM-1 := 0;
  signal r_grp  : natural range 0 to NBR-1 := 0;
  signal r_data : std_logic_vector(WBITS-1 downto 0);

  signal w_en   : std_logic := '0';
  signal w_head : natural range 0 to VAL_HEADS-1 := 0;
  signal w_col  : natural range 0 to DIM-1 := 0;
  signal w_grp  : natural range 0 to NBR-1 := 0;
  signal w_data : std_logic_vector(WBITS-1 downto 0) := (others => '0');

  -- the reference's registered read, one cycle, mirroring the DUT's `rq`
  signal ref_rq    : std_logic_vector(WBITS-1 downto 0) := (others => '0');
  signal ref_valid : std_logic := '0';   -- a read was issued on the last edge

  signal running   : boolean := true;
  signal n_checks  : natural := 0;
  signal n_bad     : natural := 0;
  signal n_collide : natural := 0;       -- same address, same edge, both ports
  signal n_reads   : natural := 0;
  signal n_writes  : natural := 0;
begin
  clk <= not clk after 5 ns;             -- free-running; see the header note

  dut : entity work.gdn_state_mem
    generic map(VAL_HEADS => VAL_HEADS, DIM => DIM,
                RECUR_LANES => RECUR_LANES, STYLE => "auto")
    port map(clk => clk,
             r_en => r_en, r_head => r_head, r_col => r_col, r_grp => r_grp,
             r_data => r_data,
             w_en => w_en, w_head => w_head, w_col => w_col, w_grp => w_grp,
             w_data => w_data);

  -- ---- THE REFERENCE ---------------------------------------------------
  -- Coded from `llama_top.vhd`'s `stmem_p`, not from `gdn_state_mem.vhd`:
  -- a process variable, read before write, one flat index.  The index
  -- expression is written out longhand here on purpose so that a transposed
  -- address in the DUT cannot be reproduced by copying.
  ref_p : process(clk) is
    variable m : std_logic_vector(WORDS*WBITS-1 downto 0) := (others => '0');
    variable a : natural;
  begin
    if rising_edge(clk) then
      ref_valid <= r_en;
      if r_en = '1' then
        a := (r_head*DIM + r_col)*NBR + r_grp;
        ref_rq <= m((a+1)*WBITS-1 downto a*WBITS);
      end if;
      if w_en = '1' then
        a := (w_head*DIM + w_col)*NBR + w_grp;
        m((a+1)*WBITS-1 downto a*WBITS) := w_data;
      end if;
    end if;
  end process;

  -- ---- THE COMPARISON ---------------------------------------------------
  -- Compared on every edge on which a read was issued the cycle before, so
  -- the check covers the registered latency and not merely the value.
  -- COMPARED ON EVERY CYCLE, NOT ONLY AFTER A READ.  Gating the comparison on
  -- `ref_valid` was the first version and mutant M3 (the read ungated, so the
  -- DUT reads on cycles the caller did not ask for) SURVIVED it: a read the
  -- reference never made is invisible if you only look at cycles where the
  -- reference did read.  The registered output must also HOLD when `r_en` is
  -- low, which is part of the contract and is only visible between reads.
  chk : process(clk) is
  begin
    if rising_edge(clk) then
      if running then
        n_checks <= n_checks + 1;
        if r_data /= ref_rq then
          n_bad <= n_bad + 1;
          if n_bad < 8 then
            report "tb_gdn_state_mem: MISMATCH at check "
                 & integer'image(n_checks)
                 & " dut=" & to_hstring(r_data)
                 & " ref=" & to_hstring(ref_rq)
              severity error;
          end if;
        end if;
      end if;
    end if;
  end process;

  -- ---- THE STIMULUS -----------------------------------------------------
  stim : process is
    variable seed : unsigned(31 downto 0) := x"1234_5678";

    impure function nxt return natural is
      variable t : unsigned(63 downto 0);
    begin
      t    := seed * to_unsigned(1103515245, 32);
      seed := t(31 downto 0) + to_unsigned(12345, 32);
      seed := seed xor shift_right(seed, 15);
      return to_integer(seed(30 downto 0));
    end function;

    -- THE WRITE PORT IS SCRAMBLED WHENEVER THE ENABLE DROPS.  Mutant M4 (the
    -- write ungated) SURVIVED the first version of this bench because the
    -- address and data signals simply HELD their last values while `w_en` was
    -- low, so an unwanted write rewrote the same word with the same data and
    -- was a no-op.  A stimulus that holds its inputs cannot see a missing
    -- enable.  Moving them every idle cycle makes the unwanted write land
    -- somewhere the reference never wrote.
    procedure step is
    begin
      wait until rising_edge(clk);
      r_en <= '0'; w_en <= '0';
      w_head <= nxt mod VAL_HEADS;
      w_col  <= nxt mod DIM;
      w_grp  <= nxt mod NBR;
      w_data <= std_logic_vector(to_unsigned(nxt mod 65536, 16))
              & std_logic_vector(to_unsigned(nxt mod 65536, WBITS-16));
      r_head <= nxt mod VAL_HEADS;
      r_col  <= nxt mod DIM;
      r_grp  <= nxt mod NBR;
    end procedure;

    procedure do_write(h, c, g : natural; v : natural) is
    begin
      w_en <= '1'; w_head <= h; w_col <= c; w_grp <= g;
      w_data <= std_logic_vector(to_unsigned(v mod 2**16, 16))
              & std_logic_vector(to_unsigned((v*7+1) mod 2**16, WBITS-16));
      n_writes <= n_writes + 1;
    end procedure;

    procedure do_read(h, c, g : natural) is
    begin
      r_en <= '1'; r_head <= h; r_col <= c; r_grp <= g;
      n_reads <= n_reads + 1;
    end procedure;

    variable h, c, g, v : natural;
  begin
    wait until rising_edge(clk);

    -- ---- PHASE 1: fill, so no later read returns the reset value only ----
    for hh in 0 to VAL_HEADS-1 loop
      for cc in 0 to DIM-1 loop
        for gg in 0 to NBR-1 loop
          do_write(hh, cc, gg, hh*1013 + cc*61 + gg*7 + 3);
          step;
        end loop;
      end loop;
    end loop;

    -- ---- PHASE 2: the SAME-ADDRESS, SAME-EDGE case, driven on purpose ----
    -- Read and write the same word on one edge.  The read must return the
    -- value from BEFORE the edge.  Repeated across the address space so a
    -- DUT that is correct at one address cannot pass by luck.
    for i in 0 to 63 loop
      h := nxt mod VAL_HEADS;
      c := nxt mod DIM;
      g := nxt mod NBR;
      v := nxt mod 4096;
      do_read(h, c, g);
      do_write(h, c, g, v);
      n_collide <= n_collide + 1;
      step;
      -- read it back the following cycle: the write must have landed
      do_read(h, c, g);
      step;
      step;
    end loop;

    -- ---- PHASE 3: random interleave, both ports, independent addresses ---
    for i in 0 to NRAND-1 loop
      if (nxt mod 3) /= 0 then
        do_read(nxt mod VAL_HEADS, nxt mod DIM, nxt mod NBR);
      end if;
      if (nxt mod 2) = 0 then
        do_write(nxt mod VAL_HEADS, nxt mod DIM, nxt mod NBR, nxt mod 65536);
      end if;
      step;
    end loop;

    -- drain the last registered read
    step; step;
    running <= false;
    wait for 0 ns;

    report "tb_gdn_state_mem: checks=" & integer'image(n_checks)
         & " mismatched=" & integer'image(n_bad)
         & " reads=" & integer'image(n_reads)
         & " writes=" & integer'image(n_writes)
         & " same-edge collisions=" & integer'image(n_collide)
      severity note;

    -- A check that never ran is not a check.  Both of these have to bite or
    -- the verdict below means nothing, so they are refusals, not warnings.
    assert n_checks > 0
      report "tb_gdn_state_mem: FAIL, zero comparisons were made."
      severity failure;
    assert n_collide > 0
      report "tb_gdn_state_mem: FAIL, the same-address same-edge case never "
           & "ran, so read-before-write is UNTESTED and the pass is empty."
      severity failure;

    if n_bad = 0 then
      report "tb_gdn_state_mem RESULT: PASS -- " & integer'image(n_checks)
           & " reads matched the independent model, including "
           & integer'image(n_collide) & " same-edge read/write collisions."
        severity note;
    else
      report "tb_gdn_state_mem RESULT: FAIL -- " & integer'image(n_bad)
           & " of " & integer'image(n_checks) & " reads disagreed."
        severity error;
    end if;
    finish;
  end process;
end architecture;
