-- rtl/axi_rd_fsm.vhd -- the AR-issue and burst-accounting FSM of axi_rd_port,
-- split out so that it can be clocked by EITHER the core clock or the AXI
-- clock without the clock ever passing through a signal assignment.
--
-- WHY IT IS A SEPARATE ENTITY, AND NOT A `fclk <= aclk when DUAL_CLK else clk`.
-- MEASURED 2026-08-28: writing it that way makes sim/tb_matvec_int4_ip FAIL
-- with 7 cycles of `arvalid` divergence between matvec_int4_ip and the
-- matvec_int4_axi it wraps -- two instances of the SAME design, driven from one
-- stimulus.  A signal assignment costs a DELTA, so the process clocked on the
-- assigned signal wakes one delta after every process clocked on the real
-- clock, and therefore samples values those processes assigned at the same
-- edge.  The skew is a pure simulation artefact, it is invisible until two
-- copies of the design sit at different hierarchy depths, and it silently makes
-- every race in the port look safe.  Reverting the process to `clk` made that
-- bench pass again, which is the measurement.
--
-- Port association of an `in` port to a plain signal introduces no delta, so
-- instantiating this entity twice -- once with `clk`, once with `aclk` --
-- under a generate is the fix, and the generate keeps it a static choice
-- rather than a clock mux.
--
-- Everything here is the code that used to live in axi_rd_port's single
-- process, unchanged apart from the four-phase FIFO clear (S_CLR / S_CLR2)
-- that replaces the old single-cycle S_FLUSH.  See axi_rd_port's header.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity axi_rd_fsm is
  generic(
    ADDR_W : positive := 32;
    BYTES  : positive := 16;    -- AXI_DW/8, bytes per beat
    DEPTH  : positive := 512;
    MAXB   : positive := 256;
    MAXOUT : positive := 16;
    -- Beats the FIFO may report ON TOP OF the raw pointer difference.  It is
    -- not decoration: with LVL_MARGIN it fixes the declared range of `f_level`
    -- and therefore the width of the throttle comparator.  Both FIFO flavours
    -- add a fixed output-stage term -- async_fifo's OUT_MARGIN (default 3,
    -- rtl/async_fifo.vhd:64) and stream_fifo's `mcnt + ocnt + inflight` with
    -- ocnt <= 2 and inflight <= 1 (rtl/stream_fifo.vhd:67) -- so 3 bounds both.
    LVL_MARGIN : natural := 3
  );
  port(
    clk, rst : in  std_logic;

    -- job, in THIS clock domain (axi_rd_port crosses `start` before it gets
    -- here; `base` and `n_beats` are levels held stable across the crossing)
    start    : in  std_logic;
    base     : in  std_logic_vector(ADDR_W-1 downto 0);
    n_beats  : in  integer;

    -- AR channel
    arvalid  : out std_logic;
    arready  : in  std_logic;
    araddr   : out std_logic_vector(ADDR_W-1 downto 0);
    arlen    : out std_logic_vector(7 downto 0);

    -- R channel accounting.  `beat` is rvalid and rready this cycle; the FSM
    -- knows on its own whether that beat was kept or discarded.
    beat     : in  std_logic;
    rlast    : in  std_logic;

    -- FIFO occupancy, in THIS domain, and the clear handshake
    -- f_level is RANGED, and the range is load-bearing: unconstrained it is a
    -- 32-bit integer, so the throttle compare below is built 32 bits wide for
    -- a value that needs 11.  MEASURED 2026-08-28: that was 5 of the 6 CARRY8
    -- on a 16-level, 5.115 ns critical path.
    --
    -- WHY 2*DEPTH AND NOT DEPTH.  In steady state the level cannot exceed
    -- DEPTH+LVL_MARGIN, and it is that value the throttle reasons about.  But
    -- async_fifo drives this port with `to_integer(wp - rp_bin_w) + OUT_MARGIN`
    -- computed from a pointer pair that is DELIBERATELY inconsistent during the
    -- four-phase clear: rtl/async_fifo.vhd:167 parks wp at 0 while the read
    -- pointer reaches the write domain two synchroniser stages later, so for
    -- that window the subtraction wraps and the reported level is the full
    -- range of an (AW+1)-bit unsigned, 0 .. 2*DEPTH-1, plus the margin.  The
    -- FSM never USES the value there -- the AR branch is guarded by st = S_RUN
    -- and the clear runs in S_CLR/S_CLR2 -- but a range must bound what is
    -- DRIVEN, not what is read, or simulation dies on a legal transient.
    -- Declaring the arithmetic bound rather than the steady-state one costs
    -- exactly one bit of comparator and no logic at all.
    f_level  : in  integer range 0 to 2*DEPTH + LVL_MARGIN;
    clr      : out std_logic;
    clr_done : in  std_logic;

    -- the state the data path needs: '1' exactly in S_RUN
    run      : out std_logic
  );
end entity;

architecture rtl of axi_rd_fsm is
  type st_t is (S_IDLE, S_DRAIN, S_CLR, S_CLR2, S_RUN);
  signal st : st_t := S_IDLE;

  signal ar_addr  : unsigned(ADDR_W-1 downto 0) := (others => '0');
  signal ar_left  : integer := 0;    -- beats not yet requested
  -- RANGED, and the bound is derived, not chosen.  `promised` only ever grows
  -- through `pr := pr + this_len` on arready, and the guard that allowed that
  -- burst was `f_level + pr + want <= DEPTH` with f_level >= 0, so
  -- pr + this_len <= DEPTH held at the guard; between the guard and arready no
  -- second burst can be issued (arv is high, so the elsif is not taken) and pr
  -- can only fall as beats retire.  Hence promised <= DEPTH.  The +MAXB is
  -- free headroom: -1..DEPTH and -1..DEPTH+MAXB are both 11 signed bits at
  -- DEPTH=512, so the slack costs nothing and a bound that is merely SAFE
  -- beats one that is exactly tight.
  signal promised : integer range 0 to DEPTH + MAXB := 0;
  signal outst    : integer range 0 to MAXOUT+1 := 0;
  signal arv      : std_logic := '0';
  -- starts at 1, never 0: arlen carries this_len-1 and to_unsigned(-1) traps
  signal this_len : integer range 1 to MAXB := 1;
  signal clr_r    : std_logic := '0';

  signal p_base   : std_logic_vector(ADDR_W-1 downto 0) := (others => '0');
  signal p_beats  : integer := 0;
begin
  arvalid <= arv;
  araddr  <= std_logic_vector(ar_addr);
  arlen   <= std_logic_vector(to_unsigned(this_len - 1, 8));
  clr     <= clr_r;
  run     <= '1' when st = S_RUN else '0';

  process(clk)
    -- The variables carry the SAME ranges as the signals they fold into, plus
    -- the one transient the code already relies on: `pr` dips to -1 when a
    -- beat retires against an empty promise count, which the `if pr < 0` clamp
    -- at the bottom of the process exists to absorb.  `os` dips the same way
    -- and has always been assigned into a 0..MAXOUT+1 signal, so -1 was
    -- already asserted to be unreachable at the assignment; that is unchanged.
    variable pr   : integer range -1 to DEPTH + MAXB;
    variable os   : integer range -1 to MAXOUT + 1;
    -- want is min(ar_left, MAXB) and is only computed inside `ar_left > 0`,
    -- so 1..MAXB; 0..MAXB keeps the reset value legal.
    variable want : integer range 0 to MAXB;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        -- S_IDLE, not S_CLR: both FIFO flavours clear from their own reset,
        -- so the handshake has nothing to do here, and entering it would run
        -- the port into S_RUN before any job was programmed.
        st <= S_IDLE;
        ar_left <= 0; promised <= 0; outst <= 0; arv <= '0';
        clr_r <= '0';

      else
        pr := promised;
        os := outst;

        -- a beat landing retires one promise; in S_DRAIN it is discarded, but
        -- the burst accounting is identical
        if beat = '1' then
          if st = S_RUN then pr := pr - 1; end if;
          if rlast = '1' then os := os - 1; end if;
        end if;

        if start = '1' then
          -- 7.7 says flush the FIFO on start.  That is NECESSARY BUT NOT
          -- SUFFICIENT: bursts already accepted by the slave keep returning
          -- beats AFTER the flush, and they land looking exactly like the new
          -- job's first beats.  So a start parks the port in S_DRAIN and it
          -- discards R beats until every outstanding burst has retired.  An
          -- AR already asserted cannot be withdrawn -- AXI requires arvalid to
          -- hold until arready -- so it is allowed to complete and drained too.
          p_base  <= base;
          p_beats <= n_beats;
          ar_left <= 0;              -- issue nothing more for the old job
          pr := 0;
          st <= S_DRAIN;
          clr_r <= '0';
        else
          case st is
            when S_DRAIN =>
              if arv = '0' and os = 0 then
                clr_r <= '1';
                st    <= S_CLR;
              end if;

            -- Phases 1-2 of the FIFO clear handshake: hold `clr` until the
            -- read side acknowledges that it has parked.  In the single-clock
            -- configuration that is one cycle; across a CDC it is however long
            -- the synchronisers take.  Waiting for the ACK rather than for a
            -- fixed number of cycles is what makes this configuration-blind.
            when S_CLR =>
              if clr_done = '1' then
                clr_r <= '0';
                st    <= S_CLR2;
              end if;

            -- Phases 3-4: `clr` is down, but the read side may still be
            -- holding its pointer at zero until it sees that.  Resuming here
            -- would let the write side move while the read side is still
            -- parked, and the consumer would take one stale beat -- the same
            -- one-beat misalignment the old S_FLUSH state existed to prevent,
            -- just spread across a clock domain crossing.
            when S_CLR2 =>
              if clr_done = '0' then
                ar_addr <= unsigned(p_base);
                ar_left <= p_beats;
                pr := 0;
                st <= S_RUN;
              end if;

            when others => null;
          end case;
        end if;

        -- AR channel.  Throttled against FIFO free space INCLUDING beats
        -- already requested, so an accepted burst can never overrun the FIFO.
        -- `outst` and `promised` are folded through VARIABLES because a burst
        -- can be issued in the same cycle a beat retires, and two signal
        -- assignments in one process would silently keep only the last.
        if arv = '1' then
          if arready = '1' then
            arv     <= '0';
            ar_addr <= ar_addr + to_unsigned(this_len * BYTES, ADDR_W);
            ar_left <= ar_left - this_len;
            pr := pr + this_len;
            os := os + 1;
          end if;
        elsif st = S_RUN and ar_left > 0 and os < MAXOUT then
          if ar_left > MAXB then want := MAXB; else want := ar_left; end if;
          if f_level + pr + want <= DEPTH then
            this_len <= want;
            arv      <= '1';
          end if;
        end if;

        if pr < 0 then pr := 0; end if;      -- drained promises never go negative
        promised <= pr;
        outst    <= os;
      end if;
    end if;
  end process;
end architecture;
