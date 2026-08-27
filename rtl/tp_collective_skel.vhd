-- rtl/tp_collective_skel.vhd
--
-- Subsystem E: tensor-parallel collective.  SKELETON ONLY.
--
-- STATUS: this file is a PORT AND HANDSHAKE CONTRACT that analyzes cleanly.
-- It is NOT an implementation and NOT verified.  The datapath bodies are
-- deliberately empty; every one of them is marked TODO.  Do not synthesise
-- this expecting function, and do not read a passing `ghdl -a` as evidence of
-- anything beyond "the ports are self-consistent".
--
-- Companion spec: docs/superpowers/specs/2026-08-27-E-tp-collective-skeleton.md
-- Numeric contract: docs/superpowers/specs/2026-08-21-tp-collective-design.md 2.1
-- Partial format:   2026-08-20-int4-streaming-matvec-design.md 14.2
--
-- WHAT E DOES.  A row-parallel matvec leaves each card holding a partial sum
-- over its own slice of K.  A emits that partial in `out_mode = "10"`: the
-- UNROUNDED s48 accumulator, carried in 64-bit lanes, with a PER-CARD `y_exp`.
-- E exchanges partials with its peers, aligns them to the minimum `y_exp` by
-- floor right shift, sums, applies `round_shift` + `sat32` ONCE, then does the
-- BFP pack (amax scan, `ns`, `sat16`) that A had to defer because a partial's
-- maximum is not knowable before the reduction.
--
-- WHY THE BFP PACK CANNOT BE SPLIT ACROSS CARDS.  The pack needs `amax` over
-- ALL n_rows of the reduced result.  That is what forbids the obvious
-- bandwidth optimisation (reduce-scatter: each card reduces half the rows and
-- broadcasts the packed half).  A reduce-scatter would need a third phase to
-- exchange the two half-amax values before either card could choose `ns`.  See
-- the spec 4.4.  At N=2 the design here is a single full exchange, and both
-- cards compute the identical full result from identical inputs.
--
-- ============================================================================
-- THE CORRECTNESS HAZARD THIS SKELETON EXISTS TO PIN DOWN
-- ============================================================================
--
-- Two of E's three input ports carry a producer that CANNOT BE STALLED:
--
--   * `p_*`  -- A's result port (`matvec_int4.vhd:82-86`) is `y_we/y_addr/
--     y_data/y_mask` with NO `y_ready`.  A writes when A is ready.  If E is
--     not able to accept, the write is LOST, not deferred.
--
--   * `r_*`  -- the peer's PCIe posted writes.  A posted write has no
--     completion and cannot be refused by the receiving datapath.  If the peer
--     runs ahead and writes collective k+1 into the buffer holding k, k is
--     silently replaced.  There is no back-pressure path to the peer at all --
--     it is in a different chassis slot.
--
-- docs/debugging/2026-08-27_gdn-head-emit-done-pulse.md is the project's
-- worked example of what that costs: `gdn_head_emit` dropped whole heads
-- because `done` was a one-cycle pulse the consumer could miss, and the lossy
-- path scored BETTER on the available metric than the correct one did.  Its
-- generalised lesson -- "in a design whose producer cannot be back-pressured,
-- throughput margin is a CORRECTNESS property, and it does not appear in any
-- static report" -- applies to E verbatim, with the aggravation that E's
-- upstream producer is a different PCIe device.
--
-- Three structural answers, all reflected in the ports below:
--
--   1. DOUBLE-BUFFERED RECEIVE (`NBUF = 2`, indexed by `seq mod NBUF`).  At
--      N=2 two buffers are PROVABLY sufficient, see spec 5.3.  Sketch: card A
--      can only send k+2 after completing k+1, which required receiving B's
--      k+1, which required B to have sent k+1, which required B to have
--      completed k, which required B to have CONSUMED A's k.  So buffer
--      (k mod 2) is free before A's k+2 can land in it.
--
--   2. SEQLOCK RECHECK.  The receiver latches `r_seq` for the buffer, reads
--      the payload, and re-reads `r_seq` afterwards.  A change means the
--      payload was overwritten mid-read: `err`, never a silent result.  This
--      is what converts a violation of (1) from corruption into detection.
--      One register and one comparator; it is not optional.
--
--   3. `done` IS HELD, NOT PULSED, until `o_ack`.  Exactly the head_emit fix.
--
-- ============================================================================
-- DSP BUDGET: ZERO, AND IT MUST STAY ZERO
-- ============================================================================
--
-- Whole-die DSP is the binding resource at 90.5-91.9% of 2,880 (B spec 3.6).
-- Every operation E performs is multiply-free: barrel right shifts for the
-- `y_exp` alignment, ACC_W-bit adds, magnitude compare for `amax`, a priority
-- encoder for `msb_pos`, add-and-shift for `round_shift`, compare-and-mux for
-- `sat32`/`sat16`.  Nothing here is a multiply.  The one way DSP creeps in is
-- synthesis choosing DSP48E2 as a wide adder, which is why USE_DSP is pinned
-- to "no" on this entity.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library work;
use work.util_pkg.all;

entity tp_collective_skel is
  generic(
    -- Cards in the tensor-parallel group.  2 for v3.0, 8 for v4.0.
    N_PEERS     : positive := 2;

    -- Largest row-parallel OUTPUT this unit ever reduces.
    --
    -- 5120 = d_model, NOT 17408.  Every row-parallel matvec in the sharding
    -- table (A 14.3: FFN down, attn o, GDN ssm_out) has M = d_model = 5120; it
    -- is their INPUT dim K that is 17408, and K never reaches E.  The
    -- 2026-08-21 spec's `MAXROWS : 17408` copied A's `MAXROWS_BFP`, which is a
    -- bound on the wrong axis, and it costs 3.4x the buffer BRAM.  See spec 7.
    MAXROWS     : positive := 5120;

    -- Reduce/pack lanes.  Sets the post-arrival tail: 2*MAXROWS/LANES cycles.
    -- LUT-only, no DSP.  See spec 4.3 for why the tail is on the critical
    -- path and the sweep that should choose this.
    LANES       : positive := 16;

    -- 48 (A's unrounded s48 partial) + clog2(N_PEERS).  52 covers N <= 16.
    -- Derived from A's INTERFACE contract |p| < 2^47, not from the workload:
    -- E cannot verify that its peers' K-slices partition anything.
    ACC_W       : positive := 52;

    -- Receive buffers per peer.  2 is provably sufficient at N=2 (spec 5.3).
    -- Do not set 1.  Setting 1 is the silent-corruption configuration.
    NBUF        : positive := 2;

    -- Flag-wait watchdog, in clk cycles.  Bounds a hang; it is NOT a
    -- performance knob.  Must exceed the worst plausible one-way transfer by a
    -- wide margin -- 300,000 @ 300 MHz = 1 ms against an expected ~6 us.
    TIMEOUT_CYC : positive := 300000;

    -- Bound on the peer y_exp spread, from A 14.2's packer policy (ns is
    -- 0..17 because the producer's pack takes s32).  A larger spread means a
    -- mismatched w_exp or a corrupt trailer, and the alignment shifter need
    -- not be built wider than this to find out.
    MAX_SPREAD  : positive := 17
  );
  port(
    clk        : in  std_logic;
    rst        : in  std_logic;

    -- ========================================================================
    -- CONTROL, from subsystem D.  Sampled at `start`, held stable until `done`.
    -- HANDSHAKE: level inputs, no ready.  D is the master here.
    -- ========================================================================
    start      : in  std_logic;
    my_rank    : in  std_logic_vector(3 downto 0);
    n_rows     : in  std_logic_vector(15 downto 0);  -- <= MAXROWS, checked
    y_exp_l    : in  std_logic_vector(31 downto 0);  -- THIS card's grid, from A
    out_shift  : in  std_logic_vector(31 downto 0);  -- applied ONCE, post-reduce

    -- Collective sequence number.  NOT a free-running counter.  It must be a
    -- DETERMINISTIC function of the descriptor program position -- see spec
    -- 5.1 -- because that determinism IS the synchronization: both cards run
    -- the same program and so agree on `seq` without exchanging anything.
    seq        : in  std_logic_vector(31 downto 0);

    -- ========================================================================
    -- LOCAL PARTIAL IN, from A's y port.
    -- HANDSHAKE: WRITE STROBE, NO READY.  A CANNOT BE STALLED.
    --   `matvec_int4.vhd:82` has y_we/y_addr/y_data/y_mask and no y_ready.
    -- Therefore this port is an unconditional BRAM write and E must never
    -- gate it.  The obligation that the buffer is free when A starts belongs
    -- to D's sequencing.  E's job is to DETECT a violation, not to prevent
    -- one: `p_we` arriving while E still needs the previous partial raises
    -- err.  That detector is the one the head_emit doc's "open, not yet
    -- answered" section says did not exist and should have.
    -- ========================================================================
    p_we       : in  std_logic;
    p_addr     : in  std_logic_vector(clog2(MAXROWS)-1 downto 0);
    p_data     : in  std_logic_vector(63 downto 0);   -- s48 sign-extended

    -- ========================================================================
    -- PEER RECEIVE REGION.  Peer PCIe posted writes land here, decoded by the
    -- XDMA/AXI-bridge slave into (peer, buffer, row).
    -- HANDSHAKE: WRITE STROBE, NO READY, AND NO POSSIBILITY OF ONE.
    --   The producer is in another chassis slot.  A posted write cannot be
    --   refused.  Overrun is prevented structurally by NBUF and detected by
    --   the seqlock recheck; there is no third option.
    -- The region must be BRAM-backed, not HBM-backed.  The stock FK33 example
    -- routes the BAR to HBM (`pcie2hbm` -> `hbm/SAXI_00`), which would make
    -- every collective spend an HBM port it does not need.  See spec 6.2.
    -- ========================================================================
    r_we       : in  std_logic;
    r_peer     : in  std_logic_vector(3 downto 0);
    r_buf      : in  std_logic_vector(clog2(NBUF)-1 downto 0);
    r_addr     : in  std_logic_vector(clog2(MAXROWS)-1 downto 0);
    r_data     : in  std_logic_vector(63 downto 0);

    -- Trailer, written by the peer AFTER its payload.  PCIe posted writes to
    -- one destination complete in order PER SOURCE-DESTINATION PAIR, so the
    -- flag landing implies the payload landed.  That ordering does NOT hold
    -- between different sources, which is why every peer gets its own region
    -- and its own flag rather than sharing one.
    r_tr_we    : in  std_logic;
    r_tr_peer  : in  std_logic_vector(3 downto 0);
    r_tr_buf   : in  std_logic_vector(clog2(NBUF)-1 downto 0);
    r_tr_yexp  : in  std_logic_vector(31 downto 0);
    r_tr_shift : in  std_logic_vector(31 downto 0);
    r_tr_seq   : in  std_logic_vector(31 downto 0);   -- written LAST

    -- ========================================================================
    -- OUTBOUND SEND, to the PCIe bridge master (AXI write -> peer BAR).
    -- HANDSHAKE: valid/ready.  THIS producer CAN be stalled, and is the only
    -- one that can.  The bridge asserts back-pressure when its outbound
    -- credit is exhausted; E must honour it or lose beats into the fabric.
    -- ========================================================================
    s_valid    : out std_logic;
    s_ready    : in  std_logic;
    s_last     : out std_logic;
    s_peer     : out std_logic_vector(3 downto 0);
    s_addr     : out std_logic_vector(clog2(MAXROWS)+3 downto 0);
    s_data     : out std_logic_vector(63 downto 0);

    -- ========================================================================
    -- REDUCED + PACKED RESULT OUT, to D's region memory.
    -- HANDSHAKE: WRITE STROBE, NO READY.  E is the producer and owns the rate,
    -- which is the mirror image of the p_* port and is why it is safe here.
    -- ========================================================================
    o_we       : out std_logic;
    o_addr     : out std_logic_vector(clog2(MAXROWS)-1 downto 0);
    o_data     : out std_logic_vector(15 downto 0);   -- int16 BFP mantissa
    o_exp      : out std_logic_vector(31 downto 0);   -- y_min - out_shift - ns

    -- ========================================================================
    -- COMPLETION.
    -- HANDSHAKE: `done` is HELD HIGH until `o_ack`.  It is NOT a pulse.
    -- A one-cycle `done` is the exact defect of
    -- docs/debugging/2026-08-27_gdn-head-emit-done-pulse.md, where a consumer
    -- busy in another state missed the pulse and an entire head was discarded
    -- with no stall and no error.
    -- ========================================================================
    done       : out std_logic;
    o_ack      : in  std_logic;

    err        : out std_logic;                       -- sticky until rst/start
    err_code   : out std_logic_vector(3 downto 0)
  );
end entity;

architecture skel of tp_collective_skel is

  -- Keep synthesis from mapping the ACC_W adders or the alignment shifters
  -- onto DSP48E2 slices.  E's whole-die DSP allowance is zero and the die is
  -- at 90.5-91.9% of 2,880 already.
  attribute use_dsp : string;
  attribute use_dsp of skel : architecture is "no";

  -- err_code encoding.  Every one of these is a DETECTOR, and the list is the
  -- point of the skeleton: each row is a failure that would otherwise be
  -- silent.  See spec 5.4.
  constant EC_NONE     : std_logic_vector(3 downto 0) := x"0";
  constant EC_NROWS    : std_logic_vector(3 downto 0) := x"1"; -- n_rows > MAXROWS
  constant EC_TIMEOUT  : std_logic_vector(3 downto 0) := x"2"; -- peer flag never arrived
  constant EC_SEQ      : std_logic_vector(3 downto 0) := x"3"; -- flag seq /= expected
  constant EC_OVERRUN  : std_logic_vector(3 downto 0) := x"4"; -- seqlock recheck failed
  constant EC_SHIFT    : std_logic_vector(3 downto 0) := x"5"; -- peer out_shift mismatch
  constant EC_SPREAD   : std_logic_vector(3 downto 0) := x"6"; -- y_exp spread > MAX_SPREAD
  constant EC_OEXP     : std_logic_vector(3 downto 0) := x"7"; -- out_exp out of range
  constant EC_PWE      : std_logic_vector(3 downto 0) := x"8"; -- A wrote while busy

  type state_t is (
    S_IDLE,      -- waiting for start
    S_CHECK,     -- n_rows / rank checks, latch control, pick buf = seq mod NBUF
    S_SEND,      -- stream local partial to every peer, then the trailer
    S_WAIT,      -- poll every peer's flag for == expected seq; watchdog runs
    S_ALIGN,     -- y_min = min(y_exp), spread check, per-peer shift amounts
    S_REDUCE,    -- pass 1: floor_shr + sum + round_shift + sat32 + amax
    S_RECHECK,   -- seqlock: re-read every peer flag, compare to the latch
    S_PACK,      -- pass 2: ns from amax, round_shift + sat16, emit o_*
    S_DONE,      -- done held high until o_ack
    S_ERR        -- sticky
  );

  signal st         : state_t := S_IDLE;

  signal err_r      : std_logic := '0';
  signal err_code_r : std_logic_vector(3 downto 0) := EC_NONE;
  signal done_r     : std_logic := '0';

  signal wd_cnt     : unsigned(clog2(TIMEOUT_CYC+1)-1 downto 0) := (others => '0');
  signal seq_exp    : std_logic_vector(31 downto 0) := (others => '0');

begin

  -- ==========================================================================
  -- TODO: none of the datapath below exists.  What a real implementation owes,
  -- in the order the FSM needs it:
  --
  --   T1  Local partial buffer.  MAXROWS x 64, single write port driven
  --       unconditionally by p_we (never gated), one read port for S_SEND and
  --       S_REDUCE.  ~10 BRAM36 at MAXROWS = 5120.
  --
  --   T2  Receive buffers.  (N_PEERS-1) x NBUF x MAXROWS x 64.  ~20 BRAM36 at
  --       N=2, NBUF=2, MAXROWS=5120.  Write side driven unconditionally by
  --       r_we; there is no other option (see the r_* port comment).
  --
  --   T3  Trailer registers, (N_PEERS-1) x NBUF x {y_exp, out_shift, seq}.
  --
  --   T4  Send engine.  Streams MAXROWS beats plus 3 trailer beats per peer,
  --       honouring s_ready.  The trailer beats MUST be issued after the last
  --       payload beat is ACCEPTED, not after it is offered.
  --
  --   T5  Flag poll + watchdog.  Wait for r_tr_seq(peer, buf) == seq_exp for
  --       every peer.  A flag arriving with seq > seq_exp is EC_SEQ, not a
  --       reason to proceed: it means a peer ran further ahead than the NBUF
  --       argument permits.
  --
  --   T6  Alignment.  y_min = min over peers and self; d_c = y_exp_c - y_min;
  --       spread check against MAX_SPREAD.  Shifts are UNCONDITIONALLY RIGHT
  --       (min reference), matching C 2.1.4 and B 2.1.4, so no saturation is
  --       needed at this site.
  --
  --   T7  Reduce pass, LANES wide.  floor_shr(p_c, d_c) then an ACC_W sum then
  --       sat32(round_shift(sum, out_shift)) then amax.  Floor, not truncate-
  --       toward-zero: the reference is deterministic floor and bit-exactness
  --       is against the reference, not against a single-card job (which is
  --       unattainable under any policy -- A 14.2).
  --
  --   T8  Seqlock recheck.  Compare every peer's r_tr_seq against the value
  --       latched in S_WAIT.  Any change -> EC_OVERRUN.  Do this BEFORE
  --       emitting anything, so a poisoned result never reaches D.
  --
  --   T9  Pack pass, LANES wide.  ns = max(0, msb_pos(amax) - 14);
  --       o_data = sat16(round_shift(y32, ns)); o_exp = y_min - out_shift - ns
  --       with a range check (EC_OEXP).
  --
  --   T10 A C reference implementing exactly T6-T9.  The 15.4b tests in
  --       ref/matvec_int4.c already execute this pipeline against real A
  --       partials at N=2/4/8; lift that code rather than rewrite it.
  --
  --   T11 A back-to-back testbench that runs collectives with NO buffer
  --       clearing and with the peer deliberately running one collective
  --       ahead.  That is the case a naive implementation passes by accident
  --       when slow and fails when fast, and it is the direct analogue of the
  --       COL_GAP sweep that found the head_emit defect.
  -- ==========================================================================

  fsm : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        st         <= S_IDLE;
        err_r      <= '0';
        err_code_r <= EC_NONE;
        done_r     <= '0';
        wd_cnt     <= (others => '0');
        seq_exp    <= (others => '0');
      else
        case st is

          when S_IDLE =>
            done_r <= '0';
            -- DETECTOR: A must not write a new partial while the previous one
            -- is still owed.  In S_IDLE it is legal.
            if start = '1' then
              err_r      <= '0';
              err_code_r <= EC_NONE;
              seq_exp    <= seq;
              wd_cnt     <= (others => '0');
              st         <= S_CHECK;
            end if;

          when S_CHECK =>
            -- TODO T1: latch n_rows / y_exp_l / out_shift / my_rank, select
            -- buf = seq mod NBUF.  Check at start, abort before output --
            -- the same discipline as A 7.6.
            if unsigned(n_rows) > MAXROWS then
              err_code_r <= EC_NROWS;
              err_r      <= '1';
              st         <= S_ERR;
            else
              st <= S_SEND;
            end if;

          when S_SEND =>
            -- TODO T4.  s_ready is the ONE back-pressure E must honour.
            st <= S_WAIT;

          when S_WAIT =>
            -- TODO T5.  Watchdog bounds the hang; it does not make a wedged
            -- peer correct, it makes it visible.
            if wd_cnt = TIMEOUT_CYC - 1 then
              err_code_r <= EC_TIMEOUT;
              err_r      <= '1';
              st         <= S_ERR;
            else
              wd_cnt <= wd_cnt + 1;
              st     <= S_ALIGN;
            end if;

          when S_ALIGN   => st <= S_REDUCE;   -- TODO T6
          when S_REDUCE  => st <= S_RECHECK;  -- TODO T7
          when S_RECHECK => st <= S_PACK;     -- TODO T8
          when S_PACK    =>                   -- TODO T9
            done_r <= '1';
            st     <= S_DONE;

          when S_DONE =>
            -- HELD, not pulsed.  The whole point of the head_emit fix.
            if o_ack = '1' then
              done_r <= '0';
              st     <= S_IDLE;
            end if;

          when S_ERR =>
            -- Sticky.  D's policy on any sub-unit err is to ABORT THE TOKEN
            -- (D 10).  Both cards must abort or they diverge permanently;
            -- recovery is by MUTUAL TIMEOUT, since a card whose peer aborted
            -- will simply never see the next flag.  Worst-case cost of an
            -- abort is therefore one TIMEOUT_CYC on the surviving card.
            done_r <= '1';
            if o_ack = '1' then
              done_r <= '0';
              st     <= S_IDLE;
            end if;

        end case;
      end if;
    end if;
  end process;

  -- Unimplemented outputs are tied off so the skeleton analyzes and so a
  -- premature instantiation is inert rather than plausible.
  s_valid  <= '0';
  s_last   <= '0';
  s_peer   <= (others => '0');
  s_addr   <= (others => '0');
  s_data   <= (others => '0');

  o_we     <= '0';
  o_addr   <= (others => '0');
  o_data   <= (others => '0');
  o_exp    <= (others => '0');

  done     <= done_r;
  err      <= err_r;
  err_code <= err_code_r;

end architecture;
