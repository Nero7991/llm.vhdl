-- rtl/async_fifo.vhd -- dual-clock stream FIFO, gray-pointer, with an explicit
-- two-sided CLEAR handshake.
--
-- WHY THIS EXISTS.  rtl/weight_streamer.vhd's own header says, and spec 14.5
-- item 3 records, that the streamer is SINGLE-CLOCK while the FK33's HBM AXI
-- clock is not the core clock.  That is not a tidiness issue: the 27-master
-- feasibility note (docs/2026-08-28_can-27-read-masters-be-served.md) puts the
-- demand at 204.0 GB/s against a 259.2 GB/s supply only because the AXI side
-- runs FASTER than the core.  Run the AXI side at the core clock instead and
-- the duty is exactly 100% with zero margin, which is not a design.  So the
-- CDC is what buys the margin, and it belongs per port, in the one place that
-- already has a FIFO between the R channel and the consumer.
--
-- THE CLEAR IS THE HARD PART, NOT THE POINTERS.  A gray-pointer FIFO is
-- standard.  What is not standard is that 7.7 requires the FIFO to be FLUSHED
-- on start (see rtl/axi_rd_port.vhd's header: sub-regions are padded to whole
-- 4 KB bursts, so the final burst delivers padding beats that stay resident,
-- and the residue differs per port).  A synchronous `flush` input works in one
-- clock domain and is meaningless across two: clearing one side's pointer while
-- the other side's synchroniser still holds the old value makes the FIFO report
-- an occupancy that never existed, in whichever direction is unlucky.
--
-- So the clear is a FOUR-PHASE handshake, and the caller must run all four:
--
--   1. caller raises `clr` (write domain) and HOLDS it
--   2. the write side parks wp at 0 and passes the request to the read domain;
--      the read side parks rp at 0, empties its output stage, and acknowledges
--   3. the acknowledgement comes back as `clr_done`; BOTH pointers are now 0
--      and both are being HELD there, so there is no window in which one side
--      is running against the other's stale pointer
--   4. the caller drops `clr`; the read side releases, and `clr_done` falls.
--      Only then may traffic resume.
--
-- The caller must wait for `clr_done` to FALL as well as to rise.  Dropping
-- `clr` and immediately resuming would let the write side move wp while the
-- read side is still forcing rp to 0, and the read side would then see beats
-- appear before it had released -- the same class of one-beat misalignment that
-- axi_rd_port's S_FLUSH state was added to prevent, just spread over a CDC.
--
-- `w_level` is a WRITE-SIDE occupancy and it is deliberately CONSERVATIVE: the
-- read pointer reaches this domain two synchroniser stages late, and the beats
-- sitting in the read side's output stage have already retired rp but have not
-- been consumed.  It therefore reports at least the true occupancy, plus a
-- fixed margin for the output stage.  An AR-issue throttle that believes it is
-- an over-estimate is safe; one that believes it is exact overruns the FIFO by
-- up to three beats.
--
-- REGISTERED LEVEL (added 2026-08-28).  `w_level` is a REGISTER, one wclk
-- behind the pointer pair, and it carries OUT_MARGIN + 1 rather than
-- OUT_MARGIN.  WHY, and WHICH WAY THE ERROR GOES.
--
-- Why: combinationally, w_level was gray2bin(rp_g_s2) -> subtract -> add, and
-- the consumer's AR throttle compared it against DEPTH in the same cycle.
-- MEASURED 2026-08-28 (docs/debugging/2026-08-28_subsystem-a-ooc-synthesis-at-
-- fk33-geometry.md 5.1): that made one 16-level, 5.115 ns combinational chain
-- from this flop to axi_rd_fsm's `this_len`, and it was subsystem A's critical
-- path in every one of the 27 ports, holding the HBM ACLK to 189.4 MHz.
--
-- Which way the error goes -- PESSIMISTIC, never optimistic, and the +1 is the
-- proof, not decoration.  Writing at most one beat per wclk means
-- wp(n+1) <= wp(n) + 1, and rp_bin_w is a gray-synchronised view of a monotone
-- counter so it never moves backwards.  Hence
--
--     used_w(n+1) = wp(n+1) - rp_bin_w(n+1) <= used_w(n) + 1
--
-- and therefore the value this port presents at cycle n+1,
--
--     w_level(n+1) = used_w(n) + OUT_MARGIN + 1 >= used_w(n+1) + OUT_MARGIN
--
-- which is EXACTLY the guarantee the combinational version gave: at least the
-- true occupancy, plus OUT_MARGIN.  The staleness is paid for in full by the
-- +1, so the throttle above is no less safe than it was; it is one beat of 512
-- more conservative.  Going the other way -- registering without the +1 --
-- would let the throttle believe in a beat of space that a write in the
-- shadowed cycle had already taken, and async_fifo asserts on write-into-full.
--
-- REGISTERED FULL FLAG (added 2026-08-28, same run as the level above).
-- `w_ready` used to be `used_w /= DEPTH` evaluated combinationally, and that is
-- the SECOND consumer of the gray-decode-and-subtract, the one the 5.1
-- write-up did not name.  MEASURED: registering w_level alone moved the AXI
-- clock 189.4 -> 192.4 MHz and left the path starting at the same flop,
-- because it now ran rp_g_s2 -> gray2bin -> subtract -> the full compare ->
-- w_ready -> axi_rd_port's `rready` -> the FSM's `beat` -> `pr := pr - 1` ->
-- the same throttle comparator.  Both consumers have to go.
--
-- `full_r` is computed one cycle ahead and INCLUDES the write being performed
-- in the cycle it is computed, so it is not merely a delayed copy:
--
--     full_r(n+1) = ( used_w(n) + wr(n) >= DEPTH )
--
-- and since rp_bin_w only ever advances, used_w(n+1) = used_w(n) + wr(n) -
-- (beats retired) <= used_w(n) + wr(n).  So used_w(n+1) = DEPTH implies
-- full_r(n+1) = '1': the flag NEVER claims space that does not exist.  The
-- only error is the other way -- it can hold '1' for one extra cycle after the
-- reader frees a slot -- which delays a beat and cannot drop one.  That
-- one-cycle stall is unreachable in any case, because the AR throttle above
-- exists precisely so the FIFO never reaches DEPTH.
--
-- 0 DSP, and the memory is a simple dual-port array so it infers BRAM.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity async_fifo is
  generic(
    W     : positive := 256;
    -- MUST be a power of two.  Gray coding of a non-power-of-two pointer is
    -- not a single-bit-change encoding, which is the entire premise.
    DEPTH : positive := 256;
    -- Extra beats the write side pretends are resident, covering the read
    -- side's output stage plus the in-flight memory read.  3 is exactly that
    -- stage's capacity; it is a generic only so a caller can prove it matters.
    OUT_MARGIN : natural := 3;
    -- FAST_POP -- the read-side read-issue condition.  false is the shipping
    -- cadence and sustains 2 beats per 3 rclk cycles; true sustains one beat
    -- per rclk cycle.  See the `do_rd` comment in the read domain below, and
    -- rtl/stream_fifo.vhd, whose identical line carries the measurement.
    -- Defaulted false so rtl/fk33_eng_cdc.vhd's two instances and every
    -- existing bench are unchanged.
    FAST_POP : boolean := false
  );
  port(
    -- ------------------------------------------------------- write domain
    wclk     : in  std_logic;
    wrst     : in  std_logic;           -- synchronous in wclk
    w_valid  : in  std_logic;
    w_data   : in  std_logic_vector(W-1 downto 0);
    w_ready  : out std_logic;
    -- Conservative occupancy, see header, and REGISTERED -- see the
    -- REGISTERED LEVEL block below, which is the whole reason this port is not
    -- the combinational `to_integer(wp - rp_bin_w) + OUT_MARGIN` it used to be.
    -- RANGED so that the consumer's comparator is 11 bits and not 32.
    -- The bound is 2*DEPTH and not DEPTH because `used_w` is a wrapping
    -- (AW+1)-bit difference and the clear deliberately parks wp at 0 while
    -- rp_g_s2 still holds the old read pointer, so during the clear window the
    -- difference is any value the width can hold.  See axi_rd_fsm's f_level.
    w_level  : out integer range 0 to 2*DEPTH + OUT_MARGIN;
    clr      : in  std_logic;           -- LEVEL; hold until clr_done, then drop
    clr_done : out std_logic;           -- LEVEL; falls after clr falls

    -- -------------------------------------------------------- read domain
    rclk     : in  std_logic;
    rrst     : in  std_logic;           -- synchronous in rclk
    q_valid  : out std_logic;
    q_data   : out std_logic_vector(W-1 downto 0);
    q_ready  : in  std_logic
  );
end entity;

architecture rtl of async_fifo is
  constant AW : positive := clog2(DEPTH);

  type mem_t is array(0 to DEPTH-1) of std_logic_vector(W-1 downto 0);
  signal mem : mem_t;
  attribute ram_style : string;
  attribute ram_style of mem : signal is "block";

  -- Pointers are AW+1 bits: the extra bit is what distinguishes full from
  -- empty when the low bits agree.
  subtype ptr_t is unsigned(AW downto 0);

  function bin2gray(b : ptr_t) return ptr_t is
  begin
    return b xor shift_right(b, 1);
  end function;

  function gray2bin(g : ptr_t) return ptr_t is
    variable b : ptr_t := (others => '0');
  begin
    -- b(msb) = g(msb); b(i) = b(i+1) xor g(i)
    b(AW) := g(AW);
    for i in AW-1 downto 0 loop
      b(i) := b(i+1) xor g(i);
    end loop;
    return b;
  end function;

  signal wp, rp           : ptr_t := (others => '0');
  signal wp_g, rp_g       : ptr_t := (others => '0');
  -- 2FF synchronisers.  Named, not inlined, so a constraint file can find them.
  signal wp_g_s1, wp_g_s2 : ptr_t := (others => '0');
  signal rp_g_s1, rp_g_s2 : ptr_t := (others => '0');

  -- ASYNC_REG (added 2026-08-29, TRACK CDC-STATIC).  THIS WAS MISSING, AND
  -- MISSING IS NOT NEUTRAL.  Without it the placer is free to put the two
  -- stages of a synchroniser in different slices, so the resolution time a
  -- metastable first stage gets is whatever the router happened to leave --
  -- which is the one number the 2FF pair exists to maximise.  It also lets
  -- synthesis retime or absorb the pair.
  --
  -- MEASURED, on `report_cdc` over an OOC synth of axi_rd_port at
  -- DUAL_CLK = true, xcvu33p-fsvh2104-2L-e, before and after (the flow is
  -- sim/cdc_teeth.sh, rows BASE and N2):
  --
  --   before  CDC-2 Warning x5, CDC-5 Warning x2, "No ASYNC_REG" 24 endpoints
  --   after   CDC-3 Info    x5, CDC-6 Warning x2, "No ASYNC_REG"  0 endpoints
  --
  -- and a netlist census of every sequential cell went from 0 of 577 carrying
  -- ASYNC_REG to 50 of 577.  The header's own claim that these are "named, not
  -- inlined, so a constraint file can find them" was true and no constraint
  -- file ever did: `grep -rn ASYNC_REG` over rtl/ and hw/ found the attribute
  -- only in rtl/hbm_tg.vhd and hw/fk33/rtl/fk33_aux.vhd.
  --
  -- The two CDC-6 rows that REMAIN are the gray pointer buses themselves, and
  -- they are not closable with an attribute: report_cdc has no concept of a
  -- gray code, so a multi-bit crossing is a Warning however it is encoded.
  -- See docs/debugging/2026-08-29_cdc-static-analysis.md for what does close
  -- them, which is a bus-skew constraint and not RTL.
  attribute async_reg : string;
  attribute async_reg of wp_g_s1 : signal is "TRUE";
  attribute async_reg of wp_g_s2 : signal is "TRUE";
  attribute async_reg of rp_g_s1 : signal is "TRUE";
  attribute async_reg of rp_g_s2 : signal is "TRUE";

  -- clear handshake
  signal clr_r_s1, clr_r_s2   : std_logic := '0';   -- clr, in the read domain
  signal clr_ack_r            : std_logic := '0';   -- read side has parked
  signal clr_a_s1, clr_a_s2   : std_logic := '0';   -- ack, back in the write domain
  attribute async_reg of clr_r_s1 : signal is "TRUE";
  attribute async_reg of clr_r_s2 : signal is "TRUE";
  attribute async_reg of clr_a_s1 : signal is "TRUE";
  attribute async_reg of clr_a_s2 : signal is "TRUE";

  -- read-side output stage, same shape as rtl/stream_fifo.vhd and for the same
  -- reason: the memory read is REGISTERED so it infers BRAM, and a 2-entry
  -- stage hides the resulting cycle so the interface stays first-word-
  -- fall-through.
  type ob_t is array(0 to 1) of std_logic_vector(W-1 downto 0);
  signal ob           : ob_t := (others => (others => '0'));
  signal ob_wp, ob_rp : integer range 0 to 1 := 0;
  signal ocnt         : integer range 0 to 2 := 0;
  signal mem_q        : std_logic_vector(W-1 downto 0) := (others => '0');
  signal mem_q_v      : std_logic := '0';

  signal rp_bin_w : ptr_t;     -- read pointer, decoded, in the write domain
  signal wp_bin_r : ptr_t;     -- write pointer, decoded, in the read domain
  signal used_w   : ptr_t;
  signal empty_r  : std_logic;
  signal do_rd    : std_logic;
  signal inflight : integer range 0 to 1;
  -- what the output stage will hold after this edge's pop, before the read
  -- issued at this edge lands.  0..3, and the lower bound is a proof: the -1
  -- arm is guarded by `ocnt > 0` read in the same delta.
  signal after_e  : integer range 0 to 3;

  -- the registered occupancy actually presented on w_level; see the header
  signal w_level_r : integer range 0 to 2*DEPTH + OUT_MARGIN := OUT_MARGIN + 1;
  -- the registered full flag behind w_ready; see the header
  signal full_r    : std_logic := '0';
  signal wr_now    : std_logic;
begin
  assert 2**AW = DEPTH
    report "async_fifo: DEPTH must be a power of two (gray coding is not a " &
           "single-bit-change encoding otherwise); DEPTH = " &
           integer'image(DEPTH)
    severity failure;

  -- ===================================================== write domain
  rp_bin_w <= gray2bin(rp_g_s2);
  used_w   <= wp - rp_bin_w;
  w_level  <= w_level_r;
  -- `clr` stays COMBINATIONAL here.  It is already a register in the caller
  -- (axi_rd_fsm's clr_r), it is one LUT input away from full_r, and delaying it
  -- would move w_ready's deassertion LATER, which is the unsafe direction for a
  -- flush; full_r is the term that had to be pulled out of the cycle.
  w_ready  <= '0' when clr = '1' or full_r = '1' else '1';
  -- The ONE write-enable term.  w_ready, the memory write and full_r's own
  -- next state are all expressed through it, and that is not tidiness: while
  -- w_ready was `used_w /= DEPTH` it was by construction the same condition the
  -- write used, but full_r can hold '1' for one cycle after the reader frees a
  -- slot, and a FIFO that writes on a cycle it is refusing on w_ready would
  -- write the beat AND leave the AXI handshake incomplete -- so the same beat
  -- arrives again next cycle and is stored TWICE.  One expression, no seam.
  wr_now   <= '1' when w_valid = '1' and clr = '0' and wrst = '0'
                   and full_r = '0' else '0';
  clr_done <= clr_a_s2;

  wproc : process(wclk)
  begin
    if rising_edge(wclk) then
      -- UNCONDITIONAL, and outside every branch below on purpose: the level
      -- must track the pointer pair through reset and through the clear as
      -- well, and in both of those the pointers only ever move DOWN, which is
      -- the conservative direction for a value the throttle reads as "how full
      -- am I".  See the REGISTERED LEVEL block in the header for the +1.
      w_level_r <= to_integer(used_w) + OUT_MARGIN + 1;
      -- full_r(n+1) = ( used_w(n) + wr_now(n) >= DEPTH ), written out.  Note
      -- wr_now itself is gated by full_r, so `used_w >= DEPTH` is reachable
      -- only inside the clear window, where wp is parked at 0 against a read
      -- pointer that has not arrived yet and the difference wraps; asserting
      -- full there is the conservative reading of a value that means nothing.
      if used_w >= to_unsigned(DEPTH, AW+1) then
        full_r <= '1';
      elsif used_w = to_unsigned(DEPTH-1, AW+1) and wr_now = '1' then
        full_r <= '1';
      else
        full_r <= '0';
      end if;

      rp_g_s1 <= rp_g;  rp_g_s2 <= rp_g_s1;
      clr_a_s1 <= clr_ack_r; clr_a_s2 <= clr_a_s1;

      if wrst = '1' then
        wp <= (others => '0'); wp_g <= (others => '0');
        rp_g_s1 <= (others => '0'); rp_g_s2 <= (others => '0');
        clr_a_s1 <= '0'; clr_a_s2 <= '0';
      elsif clr = '1' then
        wp   <= (others => '0');
        wp_g <= (others => '0');
      else
        if wr_now = '1' then
          mem(to_integer(wp(AW-1 downto 0))) <= w_data;
          wp   <= wp + 1;
          wp_g <= bin2gray(wp + 1);
        end if;
        -- A write into a full FIFO would silently lose a beat and present as a
        -- per-port stream misalignment, which is the exact defect 7.7's flush
        -- rule exists to prevent.  The throttle above axi_rd_port makes it
        -- unreachable; this says so out loud if it ever is not.
        --
        -- THE CONDITION IS `wr_now`, NOT `w_valid`, AND THAT IS A FIX, NOT A
        -- TIDY-UP (2026-08-29, TRACK CDC-BENCH).  It used to read
        -- `w_valid = '1' and used_w = DEPTH`, which is not "a beat was
        -- dropped" -- it is "a producer is OFFERING while the FIFO is full",
        -- i.e. ordinary backpressure.  A conforming stream producer holds
        -- `w_valid` until `w_ready`, so filling this FIFO from one killed the
        -- simulation at severity failure with nothing wrong.  MEASURED by
        -- sim/tb_async_fifo.vhd on the FIRST run it ever made: the guard fired
        -- at 172500 ps, and with it downgraded to a probe it fired 34,362
        -- times across 8 clock ratios with `w_ready = '0'`, `full_r = '1'` and
        -- `wr_now = '0'` EVERY time.  No beat was ever dropped.
        --
        -- DERIVED, and this is why the old form could never be right:
        -- used_w(n) = DEPTH implies used_w(n-1) >= DEPTH-1, and either
        -- used_w(n-1) >= DEPTH or used_w(n-1) = DEPTH-1 with a write at n-1;
        -- both arms of the full_r assignment above set full_r(n) = '1'.  So
        -- w_ready is ALWAYS low when used_w = DEPTH, and `w_valid` at that
        -- moment carries no information at all.  `wr_now` is the one write
        -- enable term (see the comment at its declaration), so it is the only
        -- signal that means "a beat was taken".
        --
        -- Nothing in hardware changes: synthesis ignores asserts.  What
        -- changes is that the FIFO can now be FILLED in simulation, which is
        -- the one state the +123.88 MHz flag restructuring above most needed
        -- a bench to reach.  Teeth: sim/mutate_async_fifo.sh rows F1 and F2,
        -- which break full_r in the two possible directions so that a write
        -- really does land at used_w = DEPTH; both are caught HERE.
        assert not (wr_now = '1' and used_w = to_unsigned(DEPTH, AW+1))
          report "async_fifo: WRITE INTO A FULL FIFO -- a beat was dropped"
          severity failure;
      end if;
    end if;
  end process;

  -- ====================================================== read domain
  wp_bin_r <= gray2bin(wp_g_s2);
  empty_r  <= '1' when rp = wp_bin_r else '0';
  inflight <= 1 when mem_q_v = '1' else 0;

  -- THE READ-ISSUE CONDITION.  This is the SAME line as rtl/stream_fifo.vhd's
  -- and it has the same defect and the same fix; that file's comment carries
  -- the full trace and the measurement.  In one sentence: the shipping form
  -- `(ocnt + inflight) < 2` counts the beat LEAVING the output stage at this
  -- edge as if it were staying, so the FIFO settles into pop, pop, q_valid
  -- LOW and sustains 2 beats per 3 read cycles.
  --
  -- THIS IS THE FIFO THE CARD RUNS.  `DUAL_CLK => true` at
  -- hw/fk33/gen_fk33_engine.py, so all 27 of subsystem A's weight and scale
  -- ports are async_fifo, not stream_fifo, and the 1.5101 cycles-per-word
  -- slope MEASURED on silicon (docs/2026-09-20_d-side-vector-traffic.md
  -- section 4.1) is this cadence and not the memory.
  --
  -- The pop term is INLINED rather than carried in its own signal: a
  -- concurrent signal costs a delta and the subtraction then reaches -1 in
  -- the delta after the stage empties.  MEASURED as a `bound check failure`
  -- in stream_fifo before the same form was used here.
  after_e <= ocnt + inflight - 1 when (ocnt > 0 and q_ready = '1')
             else ocnt + inflight;
  do_rd    <= '1' when empty_r = '0' and clr_r_s2 = '0'
                   and ((FAST_POP and after_e < 2) or
                        ((not FAST_POP) and (ocnt + inflight) < 2))
              else '0';

  q_valid <= '1' when ocnt > 0 else '0';
  q_data  <= ob(ob_rp);

  rproc : process(rclk)
    variable o : integer;
  begin
    if rising_edge(rclk) then
      wp_g_s1 <= wp_g; wp_g_s2 <= wp_g_s1;
      clr_r_s1 <= clr; clr_r_s2 <= clr_r_s1;

      if rrst = '1' then
        rp <= (others => '0'); rp_g <= (others => '0');
        wp_g_s1 <= (others => '0'); wp_g_s2 <= (others => '0');
        clr_r_s1 <= '0'; clr_r_s2 <= '0'; clr_ack_r <= '0';
        ob_wp <= 0; ob_rp <= 0; ocnt <= 0; mem_q_v <= '0';
      elsif clr_r_s2 = '1' then
        -- Parked.  Pointer at 0, output stage empty, and the acknowledgement
        -- is raised only from HERE, so `clr_done` proves the read side saw it.
        rp        <= (others => '0');
        rp_g      <= (others => '0');
        ob_wp     <= 0; ob_rp <= 0; ocnt <= 0;
        mem_q_v   <= '0';
        clr_ack_r <= '1';
      else
        clr_ack_r <= '0';
        o := ocnt;

        mem_q   <= mem(to_integer(rp(AW-1 downto 0)));
        mem_q_v <= do_rd;
        if do_rd = '1' then
          rp   <= rp + 1;
          rp_g <= bin2gray(rp + 1);
        end if;

        if mem_q_v = '1' then
          ob(ob_wp) <= mem_q;
          ob_wp <= (ob_wp + 1) mod 2;
          o := o + 1;
        end if;

        if ocnt > 0 and q_ready = '1' then
          ob_rp <= (ob_rp + 1) mod 2;
          o := o - 1;
        end if;

        ocnt <= o;
      end if;
    end if;
  end process;
end architecture;
