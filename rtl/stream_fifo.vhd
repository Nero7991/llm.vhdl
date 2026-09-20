-- rtl/stream_fifo.vhd -- synchronous-read FIFO with a first-word-fall-through
-- output stage.
--
-- WHY NOT A COMBINATIONAL READ.  Spec 7.7 budgets 8 KB per weight port
-- (512 beats x 128 b).  A FIFO whose output is `mem(rp)` read combinationally
-- is distributed RAM, so those 65,536 bits become ~1,024 SLICEM LUTs per port
-- and ~4,096 across the four weight ports -- against a budget (7.9) that has
-- the whole weight FIFO path at 8 BRAM36 and the entire design at ~6-7K LUT.
-- The memory read here is therefore REGISTERED, which is what infers BRAM, and
-- a 2-entry output stage hides the resulting cycle of latency so the interface
-- is still plain first-word-fall-through: q_valid means q_data is valid NOW.
--
-- Sustains one beat per cycle in and one out simultaneously.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity stream_fifo is
  generic(
    W : positive := 128;
    DEPTH : positive := 512;
    -- FAST_POP -- see the `do_rd` comment in the body.  false reproduces the
    -- shipping cadence of 1.5 cycles per beat EXACTLY, bit for bit; true
    -- delivers one beat per cycle.  Defaulted to false so that every existing
    -- instantiation and every testbench is unchanged and the lever has to be
    -- asked for by name.
    FAST_POP : boolean := false
  );
  port(
    clk, rst : in  std_logic;
    flush    : in  std_logic;      -- synchronous, drops everything (7.7)

    i_valid  : in  std_logic;
    i_data   : in  std_logic_vector(W-1 downto 0);
    i_ready  : out std_logic;

    q_valid  : out std_logic;
    q_data   : out std_logic_vector(W-1 downto 0);
    q_ready  : in  std_logic;

    -- occupancy INCLUDING the output stage, for the AR-issue throttle
    -- Defaulted, so the formal's driving value at delta 0 is 0 and not
    -- integer'low: rtl/axi_rd_port.vhd copies this port into a range-
    -- constrained signal and the copy runs before the first driving value
    -- lands (2026-09-19).
    level    : out integer := 0
  );
end entity;

architecture rtl of stream_fifo is
  type mem_t is array(0 to DEPTH-1) of std_logic_vector(W-1 downto 0);
  signal mem : mem_t;
  attribute ram_style : string;
  attribute ram_style of mem : signal is "block";

  signal wp, rp : integer range 0 to DEPTH-1 := 0;
  signal mcnt   : integer range 0 to DEPTH   := 0;   -- beats in the memory

  signal mem_q   : std_logic_vector(W-1 downto 0) := (others => '0');
  signal mem_q_v : std_logic := '0';                 -- a read lands next cycle

  -- 2-entry output stage
  type ob_t is array(0 to 1) of std_logic_vector(W-1 downto 0);
  signal ob      : ob_t := (others => (others => '0'));
  signal ob_wp, ob_rp : integer range 0 to 1 := 0;
  signal ocnt    : integer range 0 to 2 := 0;

  signal do_rd    : std_logic;
  signal inflight : integer range 0 to 1;
  -- what the output stage will hold AFTER this edge, before the read issued
  -- at this edge lands.  0..3 because ocnt <= 2 and inflight <= 1, and the -1
  -- arm is only taken when ocnt > 0, so it cannot go negative.
  signal after_e  : integer range 0 to 3;
begin
  inflight <= 1 when mem_q_v = '1' else 0;

  -- THE READ-ISSUE CONDITION, AND THE 1.5 CYCLES PER BEAT IT USED TO COST.
  --
  -- The output stage holds 2 beats and the memory read has one cycle of
  -- latency, so a read may be issued only while the stage will have room for
  -- the beat it produces.  The shipping form is
  --
  --     do_rd <= '1' when mcnt > 0 and (ocnt + inflight) < 2 else '0';
  --
  -- and it counts the beat that is LEAVING at this same edge as if it were
  -- still there.  MEASURED 2026-09-20, TRACK AIDLE, with a producer offering a
  -- beat every cycle and a consumer holding q_ready high: the FIFO settles
  -- into a three-cycle cadence -- pop, pop, q_valid LOW -- and sustains
  -- **2 beats per 3 cycles, 1.501 cycles per beat, with q_valid low 33.4% of
  -- the time**.  Trace, with (ocnt, mem_q_v) read pre-edge:
  --
  --     (1,1): sum = 2, no read issued; a beat lands, one pops -> (1,0)
  --     (1,0): sum = 1, read issued;    nothing lands, one pops -> (0,1)
  --     (0,1): sum = 1, read issued;    a beat lands, NONE pops -> (1,1)
  --                                     ^ q_valid was LOW this cycle
  --
  -- That cadence is subsystem A's whole 0.51 cycles-per-word stall: the array
  -- accepts a weight word only when all 24 weight FIFOs and all 3 scale FIFOs
  -- present one, so 1.5 here is 1.5 there, whatever the memory does.
  --
  -- The correct bound is on what the stage holds AFTER the pop, which is the
  -- room the landing beat actually needs:
  --
  --     after_e = ocnt + inflight - pop   must be <= 1 for a read to issue
  --
  -- because next edge that read lands and the stage must not exceed 2 even if
  -- nothing pops then.  It is the same invariant, evaluated one pop later, so
  -- it can never overrun the two entries -- and `ocnt` keeps its 0..2 range as
  -- the proof, since a bound check would fire in simulation if it did.
  --
  -- WHAT IT DOES NOT CHANGE: the ORDER and the VALUES.  Both arms read `mem`
  -- at `rp` and advance `rp` by one per read; the only difference is WHEN a
  -- read is issued.  A slower consumer takes the same beats in the same order.
  -- THE POP TERM IS INLINED, NOT A SIGNAL, AND THAT IS NOT STYLE.  MEASURED
  -- 2026-09-20: written as a separate `pop <= '1' when ocnt > 0 and q_ready =
  -- '1'` signal this line dies with `bound check failure` on the FIRST run.
  -- A concurrent signal costs a delta, so in the delta after an edge that
  -- emptied the stage, `ocnt` reads 0 while `pop` still reads the PREVIOUS
  -- delta's '1', and the subtraction reaches -1.  Inlined, the guard and the
  -- subtraction read `ocnt` in the SAME delta, so `ocnt > 0` implies
  -- `ocnt + inflight - 1 >= 0` and the 0..3 range is a proof rather than a
  -- hope.  Same delta-skew trap as rtl/axi_rd_fsm.vhd's header records for a
  -- clock; here it hits an arithmetic guard instead.
  after_e <= ocnt + inflight - 1 when (ocnt > 0 and q_ready = '1')
             else ocnt + inflight;
  do_rd   <= '1' when mcnt > 0 and
                      ((FAST_POP and after_e < 2) or
                       ((not FAST_POP) and (ocnt + inflight) < 2))
             else '0';

  i_ready <= '1' when mcnt < DEPTH else '0';
  q_valid <= '1' when ocnt > 0 else '0';
  q_data  <= ob(ob_rp);
  level   <= mcnt + ocnt + inflight;

  process(clk)
    variable m, o : integer;
  begin
    if rising_edge(clk) then
      if rst = '1' or flush = '1' then
        wp <= 0; rp <= 0; mcnt <= 0;
        ob_wp <= 0; ob_rp <= 0; ocnt <= 0; mem_q_v <= '0';
      else
        m := mcnt; o := ocnt;

        if i_valid = '1' and mcnt < DEPTH then
          mem(wp) <= i_data;
          wp <= (wp + 1) mod DEPTH;
          m  := m + 1;
        end if;

        -- registered memory read: this is what makes it BRAM
        mem_q   <= mem(rp);
        mem_q_v <= do_rd;
        if do_rd = '1' then
          rp <= (rp + 1) mod DEPTH;
          m  := m - 1;
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

        mcnt <= m; ocnt <= o;
      end if;
    end if;
  end process;
end architecture;
