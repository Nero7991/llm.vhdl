-- sim/gray_skew_demo.vhd -- what stimulus WOULD catch G1, demonstrated.
--
-- DELIBERATELY NOT NAMED tb_*.vhd.  sim/regress.sh globs sim/tb_*.vhd off the
-- filesystem, so anything matching that pattern becomes a permanent gate row
-- for every track whether it was meant to or not.  This is a DEMONSTRATION,
-- not a gate: it models a hazard rather than checking the design, and it is
-- run by hand.  The gate row for this track is sim/gray_check.sh.
--
-- ---------------------------------------------------------------------------
-- THE QUESTION IT ANSWERS
-- ---------------------------------------------------------------------------
-- sim/mutate_async_fifo.sh row G1 replaces both of rtl/async_fifo.vhd's gray
-- functions with the identity, and SURVIVES all eight clock ratios in
-- sim/tb_async_fifo.vhd.  The obvious follow-up is "then write a harder
-- testbench" -- and that is the wrong follow-up.  The reason G1 survives is not
-- that the stimulus is too tame.  It is that an RTL simulator assigns a whole
-- `unsigned` in ONE delta, so the event gray coding exists to survive -- a
-- multi-bit bus caught PART-WAY through a transition -- is not in the model at
-- all.  No sequence of writes and reads can produce an event the model does not
-- represent.
--
-- What WOULD catch it is a different model, not a different testcase: give each
-- bit of the crossing bus its OWN propagation delay, then sample with a foreign
-- clock.  That is what this file does, and it does it with a control -- the
-- identical stimulus and the identical per-bit skew, once with gray coding and
-- once without.
--
-- ---------------------------------------------------------------------------
-- THE ORACLE
-- ---------------------------------------------------------------------------
-- The write-side counter only ever counts UP and never wraps within the run
-- (NCYC < 2**N is checked below).  So a receiver that samples the crossing bus
-- and decodes it must see a value that is
--
--   * never GREATER than the counter's current value  (a value from the
--     future -- the counter never held it yet), and
--   * never LESS than the previous decoded sample     (the pointer went
--     backwards -- which, in async_fifo, is what makes `used_w = wp - rp`
--     report an occupancy that never existed).
--
-- With gray coding, at most one bit of the bus is in flight at any instant, so
-- a sample lands on the old value or the new one and both bounds hold by
-- construction.  With binary, several bits move at once and a sample can land
-- on any intermediate pattern -- the classic 0111 -> 1000 transition sampling
-- as 1111.
--
-- Run BOTH, and read the two together:
--
--   ghdl -a --std=08 -frelaxed sim/gray_skew_demo.vhd
--   ghdl -r --std=08 -frelaxed gray_skew_demo -gUSE_GRAY=true
--   ghdl -r --std=08 -frelaxed gray_skew_demo -gUSE_GRAY=false
--
-- MEASURED 2026-08-29, N=12, 4000 write cycles, wclk 3000 ps against rclk
-- 4300 ps, per-bit skew 50..950 ps: see docs/debugging/2026-08-29_gray1-
-- identity-gray-code.md section 4.1.  This file asserts nothing and fails
-- nothing; it prints two numbers whose ratio is the whole point.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gray_skew_demo is
  generic (
    N        : natural := 12;      -- pointer width
    USE_GRAY : boolean := true;    -- false = the G1 mutation, binary pointers
    WPER     : time    := 3000 ps; -- write (source) clock period
    RPER     : time    := 4300 ps; -- read (sampling) clock period, asynchronous
    NCYC     : natural := 4000     -- write cycles; MUST be < 2**N, see below
  );
end entity;

architecture sim of gray_skew_demo is
  subtype ptr_t is unsigned(N-1 downto 0);

  function enc(b : ptr_t) return ptr_t is
  begin
    if USE_GRAY then return b xor shift_right(b, 1); else return b; end if;
  end function;

  function dec(g : ptr_t) return ptr_t is
    variable b : ptr_t := (others => '0');
  begin
    if USE_GRAY then
      b(N-1) := g(N-1);
      for i in N-2 downto 0 loop
        b(i) := b(i+1) xor g(i);
      end loop;
    else
      b := g;
    end if;
    return b;
  end function;

  signal wclk, rclk : std_logic := '0';
  signal running    : boolean   := true;
  signal b          : ptr_t     := (others => '0');
  signal gbus       : ptr_t     := (others => '0');
  signal gskew      : ptr_t     := (others => '0');
  signal nsamp, nfuture, nback, nbad : natural := 0;
  signal wdone      : boolean   := false;
begin
  -- NCYC must not wrap the counter, or the oracle's monotonicity bound is
  -- false for a correct design and the run reports the model rather than the
  -- encoding.  An out-of-range natural is used because it fails the
  -- ELABORATION; a plain assert would let the run proceed and print numbers.
  assert NCYC < 2**N
    report "gray_skew_demo: NCYC must be < 2**N or the counter wraps and the "
         & "monotone oracle is invalid"
    severity failure;

  wclk <= not wclk after WPER/2 when running else '0';
  rclk <= not rclk after RPER/2 when running else '0';

  -- THE WHOLE POINT: each bit of the crossing bus gets its OWN delay, so a
  -- transition that changes k bits is spread over a window instead of being
  -- one atomic delta.  `transport` and not inertial, or a narrow intermediate
  -- pattern is cancelled by the very mechanism being modelled.
  skew : for i in 0 to N-1 generate
    gskew(i) <= transport gbus(i) after (50 + ((i * 373) mod 900)) * 1 ps;
  end generate;

  wproc : process
  begin
    for k in 1 to NCYC loop
      wait until rising_edge(wclk);
      b    <= to_unsigned(k, N);
      gbus <= enc(to_unsigned(k, N));
    end loop;
    wait until rising_edge(wclk);
    wdone <= true;
    wait;
  end process;

  rproc : process
    variable v, prev : ptr_t := (others => '0');
    variable bad     : boolean;
  begin
    loop
      wait until rising_edge(rclk);
      exit when wdone;
      v   := dec(gskew);
      bad := false;
      nsamp <= nsamp + 1;
      if v > b then
        nfuture <= nfuture + 1; bad := true;
        if nfuture < 3 then
          report "SKEW SAMPLE FROM THE FUTURE: decoded " &
                 integer'image(to_integer(v)) & " while the counter holds " &
                 integer'image(to_integer(b)) severity note;
        end if;
      end if;
      if v < prev then
        nback <= nback + 1; bad := true;
        if nback < 3 then
          report "SKEW SAMPLE WENT BACKWARDS: decoded " &
                 integer'image(to_integer(v)) & " after " &
                 integer'image(to_integer(prev)) severity note;
        end if;
      end if;
      if bad then nbad <= nbad + 1; end if;
      prev := v;
    end loop;

    report "GRAY_SKEW_DEMO use_gray=" & boolean'image(USE_GRAY) &
           " N=" & integer'image(N) &
           " samples=" & integer'image(nsamp) &
           " corrupt=" & integer'image(nbad) &
           " from_the_future=" & integer'image(nfuture) &
           " went_backwards=" & integer'image(nback)
      severity note;
    running <= false;
    wait;
  end process;
end architecture;
