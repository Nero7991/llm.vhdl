-- rtl/mv_rdfsm.vhd -- a450 Task 3: the AR-issue FSM of rtl/mv_rdport.vhd, mv_tile's
-- single-clock copy of axi_rd_port.  Same job, AR/R and clear behaviour as
-- rtl/axi_rd_fsm.vhd; the burst-issue decision is rebuilt as a fully registered,
-- multi-cycle pipeline so it routes at 450 MHz (2.222 ns) on the VU35P -2L at 0.85 V.
--
-- WHY A COPY AND NOT AN EDIT TO axi_rd_fsm.vhd.  rtl/axi_rd_fsm.vhd, rtl/axi_rd_port.vhd
-- and rtl/stream_fifo.vhd are in the GHDL closure of EVERY existing subsystem A rating;
-- editing them would re-key every one of those ratings for a change only mv_tile's 450 MHz
-- target needs (plan ruling R10 made the same call for stream_fifo).
--
-- WHAT FAILED, MEASURED (routed, a450_tile, task-3-report.md):
--   axi_rd_fsm as is                     WNS -0.051  fifo/mcnt -> fsm/this_len CE, 6 lvl
--   + registered level and want          WNS -0.100  st_reg -> this_len CE, 8 lvl
--   + registered may_issue               WNS -0.150  st_reg -> want_issue CE, 9 lvl
-- The guard `f_level + promised + want <= DEPTH`, ANDed with the state decode, `ar_left >
-- 0` and `os < MAXOUT`, kept landing as one wide network on whichever register received it.
-- Re-registering its operands only moved it.  So here the guard does not exist at all.
--
-- THE DESIGN.
--   * `free` is a credit counter: FIFO slots neither filled nor promised to an issued
--     burst.  It is DEPTH on entry to S_RUN, +1 per word the consumer popped (registered
--     one cycle late, `pop_r`), -len per burst issued.  One adder, one 3-way delta mux.
--   * Every term of the issue decision is a register compared against a CONSTANT or a
--     small register, registered again:  len_r = min(ar_left, MAXB), left_r = ar_left > 0,
--     os_ok_r = outst < MAXOUT, crd_ok_r = free >= MAXB, and may_r = their AND with run_r.
--   * The decision itself is `run_r and may_r and quiet and arv = '0'`: five registers,
--     one LUT.  `run_r` is a register equal to (st = S_RUN) by construction, so no state
--     decode reaches a CE.
--   * `quiet` (a 2-bit shift register, `hold`) blocks a decision for the two edges after
--     anything that changes ar_left, outst or free upward in a way the registered compares
--     have not yet seen: an AR handshake and the entry to S_RUN.  See `hold`.
-- Cost: with an immediate arready an AR goes out every 4 cycles; one 16-beat burst feeds
-- the FIFO for 16 cycles, so the issue rate is never the limit.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mv_rdfsm is
  generic(
    ADDR_W : positive := 32;
    BYTES  : positive := 16;    -- AXI_DW/8, bytes per beat
    DEPTH  : positive := 512;
    MAXB   : positive := 256;
    MAXOUT : positive := 16
  );
  port(
    clk, rst : in  std_logic;
    -- THE HBM AXI PORT RESET (a450 Task 8, carry C1): active high, synchronous to clk.
    -- It clears `owed` and nothing else; see `owed` for why.  Default '0' (inactive), so
    -- an instance that does not connect it keeps the never-reset count of Task 7b.
    hbm_rst  : in  std_logic := '0';

    -- job (single clock: no crossing)
    start    : in  std_logic;
    base     : in  std_logic_vector(ADDR_W-1 downto 0);
    n_beats  : in  integer;

    -- AR channel
    arvalid  : out std_logic;
    arready  : in  std_logic;
    araddr   : out std_logic_vector(ADDR_W-1 downto 0);
    arlen    : out std_logic_vector(7 downto 0);

    -- R channel accounting: `beat` is rvalid and rready this cycle
    beat     : in  std_logic;
    rlast    : in  std_logic;

    -- one word left the FIFO this cycle (its q_valid and q_ready); only in S_RUN
    pop      : in  std_logic;

    -- the FIFO clear handshake
    clr      : out std_logic;
    clr_done : in  std_logic;

    -- '1' exactly in S_RUN, from a register
    run      : out std_logic
  );
end entity;

architecture rtl of mv_rdfsm is
  type st_t is (S_IDLE, S_DRAIN, S_CLR, S_CLR2, S_RUN);
  signal st    : st_t := S_IDLE;
  -- run_r is (st = S_RUN), kept as its own register: every transition into or out of
  -- S_RUN below assigns both, so they cannot disagree.
  signal run_r : std_logic := '0';

  signal ar_addr  : unsigned(ADDR_W-1 downto 0) := (others => '0');
  signal ar_left  : integer := 0;    -- beats not yet requested
  signal outst    : integer range 0 to MAXOUT+1 := 0;
  signal arv      : std_logic := '0';
  -- starts at 1, never 0: arlen carries this_len-1 and to_unsigned(-1) traps
  signal this_len : integer range 1 to MAXB := 1;
  signal clr_r    : std_logic := '0';

  signal p_base   : std_logic_vector(ADDR_W-1 downto 0) := (others => '0');
  signal p_beats  : integer := 0;

  -- THE OVERFLOW-SAFETY ARGUMENT.  Let L be the words in the FIFO (stream_fifo's `level`)
  -- and P the beats promised: requested by an AR issued in this S_RUN and not yet landed.
  -- Claim: in S_RUN,  free = DEPTH - L - P - pop_r,  so L + P <= DEPTH whenever free >= 0.
  --   entry to S_RUN: free := DEPTH, and L = P = 0 (S_DRAIN waited for arv = '0' and
  --     outst = 0, so nothing is in flight; the clear emptied the FIFO), pop_r = 0
  --     (nothing pops outside S_RUN: rtl/mv_rdport.vhd gates q_ready with run).
  --   a beat lands:  L+1, P-1, free unchanged.
  --   a word pops at cycle t: L-1 at t; pop_r = 1 at t+1, free+1 at t+1.  Hence the
  --     -pop_r term: free lags the real count by at most that one word, low, never high.
  --   an issue:  P + len and free - len at the SAME edge (P counts from the issue edge,
  --     not from arready; the burst is promised the moment arvalid rises).
  -- An issue happens only with crd_ok_r = '1', i.e. free >= MAXB >= len at the edge
  -- crd_ok_r was sampled, and free can only have FALLEN since by an issue -- none
  -- happened: arv was '1' from the last issue until its handshake, and `hold` blocks two
  -- further edges, which is exactly the crd_ok_r and may_r registers' refresh.  Pops only
  -- raise free.  So free - len >= 0, free stays in 0..DEPTH (its declared range: in
  -- simulation a violation is a bound failure, besides the explicit assertion in
  -- rtl/mv_rdport.vhd), and L + P <= DEPTH: an accepted burst never overruns the FIFO.
  -- Same bound as rtl/axi_rd_fsm.vhd's `f_level + promised + want <= DEPTH`; the price is
  -- that the last, short burst waits for MAXB of credit rather than its own length.
  signal free     : integer range 0 to DEPTH := 0;
  signal pop_r    : std_logic := '0';

  -- registered operands of the decision, refreshed every cycle
  signal len_r    : integer range 0 to MAXB := 0;       -- min(ar_left, MAXB), clamped >= 0
  signal dec0_r   : integer range -MAXB to 0 := 0;      -- -len_r
  signal dec1_r   : integer range 1-MAXB to 1 := 1;     -- 1 - len_r (issue and pop together)
  signal left_r   : std_logic := '0';                   -- ar_left > 0
  signal os_ok_r  : std_logic := '0';                   -- outst < MAXOUT
  signal crd_ok_r : std_logic := '0';                   -- free >= MAXB
  signal may_r    : std_logic := '0';

  -- hold: '1' bits block a decision.  THE FRESHNESS ARGUMENT.  The decision reads may_r,
  -- which is two registers downstream of ar_left / outst / free (operand register, then
  -- may_r).  ar_left and outst move only at an AR handshake (start and the S_RUN entry
  -- aside), and free falls only at an issue.  After the edge E0 that changes them, the
  -- operand registers see it at E1 and may_r at E2, so a decision at E1 or E2 could act
  -- on the old values; one at E3 cannot.  hold := "11" at E0 blocks E1 and E2.  An issue
  -- is covered by arv itself (arv = '1' until the handshake, which then sets hold).  The
  -- S_RUN entry sets hold too, for the new ar_left and free.  Values that move between
  -- refreshes in the SAFE direction only need no hold: outst falling (rlast), free rising
  -- (pop_r).  The `start` abort needs none: run_r falls at the edge after start, and the
  -- decision reads run_r directly.  A decision ON the start cycle issues one AR for the
  -- old job, exactly as rtl/axi_rd_fsm.vhd can; S_DRAIN waits for it and discards it.
  signal hold     : std_logic_vector(1 downto 0) := "00";

  -- OWED BURSTS ACROSS A RESET (a450 Task 7b fix round 1).  `outst` is cleared by rst, but
  -- the memory is not reset with this port (the card's HBM is reset only at configuration):
  -- every burst it accepted before the reset still delivers all its beats afterwards.  With
  -- outst at 0 S_DRAIN would move on at once, and beats landing after the next job reached
  -- S_RUN would enter the FIFO as that job's data (and, with up to MAXOUT x MAXB of them,
  -- overrun it).  `owed` counts accepted bursts minus retired ones (rlast beats) and is
  -- NEVER reset: its 0 is the configuration value, when the memory owes nothing either.
  -- S_DRAIN waits for it, so a start after a reset first discards every owed beat
  -- (rready is '1' and run '0' outside S_RUN).  `beat`/`rlast` must therefore count beats
  -- during the reset too: rtl/mv_rdport.vhd's R register stage is not reset.
  -- THE ONE THING THAT CLEARS IT (a450 Task 8, carry C1): `hbm_rst`, the HBM AXI port's
  -- own reset, synchronised into this clock.  A port reset makes the memory drop every
  -- burst it accepted (the Jungle Cat card resets the HBM ports from a proc_sys_reset on
  -- an MMCM's lock, so a lock loss does it), so the beats `owed` waits for never come and,
  -- uncleared, every port would wait in S_DRAIN forever.  While hbm_rst is '1' the
  -- count restarts from 0 each edge and still counts that edge's handshake: the
  -- synchronised reset falls a few edges after the port's, and an AR the memory accepts
  -- in between is owed like any other.
  -- PRECONDITION: the memory port is reset only together with hbm_rst; A's own reset
  -- (`rst`) never clears owed.
  signal owed     : integer range 0 to MAXOUT := 0;
begin
  owe : process(clk)
    variable o : integer range -1 to MAXOUT + 1;
  begin
    if rising_edge(clk) then
      if hbm_rst = '1' then o := 0; else o := owed; end if;
      if arv = '1' and arready = '1' then o := o + 1; end if;
      if beat = '1' and rlast = '1' then o := o - 1; end if;
      assert o >= 0 and o <= MAXOUT
        report "mv_rdfsm: owed bursts out of range (an rlast with nothing owed, or more than "
             & "MAXOUT accepted)" severity failure;
      if o < 0 then o := 0; elsif o > MAXOUT then o := MAXOUT; end if;
      owed <= o;
    end if;
  end process;

  arvalid <= arv;
  araddr  <= std_logic_vector(ar_addr);
  arlen   <= std_logic_vector(to_unsigned(this_len - 1, 8));
  clr     <= clr_r;
  run     <= run_r;

  process(clk)
    variable os    : integer range -1 to MAXOUT + 1;
    variable issue : std_logic;
    variable dl    : integer range -MAXB to 1;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        -- S_IDLE, not S_CLR: the FIFO clears from its own reset
        st <= S_IDLE; run_r <= '0';
        ar_left <= 0; outst <= 0; arv <= '0'; clr_r <= '0';
        free <= 0; pop_r <= '0'; may_r <= '0'; hold <= "00";
        len_r <= 0; dec0_r <= 0; dec1_r <= 1;
        left_r <= '0'; os_ok_r <= '0'; crd_ok_r <= '0';

      else
        os := outst;

        -- stage 1: operands, each a register against a constant or another register
        if ar_left > MAXB then len_r <= MAXB;
        elsif ar_left < 0 then len_r <= 0;
        else len_r <= ar_left; end if;
        dec0_r <= -len_r;
        dec1_r <= 1 - len_r;
        if ar_left > 0 then left_r <= '1'; else left_r <= '0'; end if;
        if outst < MAXOUT then os_ok_r <= '1'; else os_ok_r <= '0'; end if;
        if free >= MAXB then crd_ok_r <= '1'; else crd_ok_r <= '0'; end if;
        pop_r <= pop;
        -- stage 2
        may_r <= run_r and left_r and os_ok_r and crd_ok_r;
        hold  <= hold(0) & '0';

        -- stage 3: the decision, five registers
        if run_r = '1' and may_r = '1' and hold = "00" and arv = '0' then
          issue := '1';
        else
          issue := '0';
        end if;

        -- the R channel: a beat landing with rlast retires one burst; in S_DRAIN the beat
        -- is discarded, but the burst accounting is identical
        if beat = '1' and rlast = '1' then os := os - 1; end if;

        if start = '1' then
          -- See rtl/axi_rd_fsm.vhd at the same point: a start parks the port in S_DRAIN,
          -- which discards R beats until every outstanding burst has retired, then
          -- clears the FIFO.  An AR already asserted is allowed to complete.
          p_base  <= base;
          p_beats <= n_beats;
          ar_left <= 0;              -- issue nothing more for the old job
          st <= S_DRAIN; run_r <= '0';
          clr_r <= '0';
        else
          case st is
            when S_DRAIN =>
              if arv = '0' and os = 0 and owed = 0 then
                clr_r <= '1';
                st    <= S_CLR;
              end if;
            -- the four-phase clear, as rtl/axi_rd_fsm.vhd
            when S_CLR =>
              if clr_done = '1' then
                clr_r <= '0';
                st    <= S_CLR2;
              end if;
            when S_CLR2 =>
              if clr_done = '0' then
                ar_addr <= unsigned(p_base);
                ar_left <= p_beats;
                free    <= DEPTH;
                hold    <= "11";
                st <= S_RUN; run_r <= '1';
              end if;
            when others => null;
          end case;
        end if;

        -- free: one adder, the delta a 3-way mux of registers.  Not touched in S_CLR2,
        -- where the entry assignment above sets it (run_r = '0' there, so no issue, and
        -- pop_r = '0' since nothing pops outside S_RUN).
        if run_r = '1' then
          if issue = '1' then
            if pop_r = '1' then dl := dec1_r; else dl := dec0_r; end if;
          elsif pop_r = '1' then dl := 1;
          else dl := 0; end if;
          free <= free + dl;
        end if;

        -- AR channel.  outst is folded through a variable because a burst can be accepted
        -- in the same cycle a burst retires.
        if arv = '1' then
          if arready = '1' then
            arv     <= '0';
            ar_addr <= ar_addr + to_unsigned(this_len * BYTES, ADDR_W);
            ar_left <= ar_left - this_len;
            os := os + 1;
            hold <= "11";
          end if;
        elsif issue = '1' then
          -- len_r >= 1 here: left_r = '1' (ar_left > 0) was sampled from the same ar_left,
          -- and hold guarantees ar_left has not moved since
          this_len <= len_r;
          arv      <= '1';
        end if;

        -- clamped as rtl/axi_rd_fsm.vhd (TRACK A7): an rlast from a burst issued before
        -- a local reset must not wrap the counter
        if os < 0 then os := 0; end if;
        outst <= os;
      end if;
    end if;
  end process;
end architecture;
