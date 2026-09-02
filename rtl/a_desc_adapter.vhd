-- rtl/a_desc_adapter.vhd
-- THE CARD'S D-to-A SEAM.  TRACK CARDTOP increment 2, backlog row N3.
--
-- llama_top's adapter (llama_top.vhd:3196-3235) bridges D to `matvec_int4`,
-- a unit with no descriptor plane, by holding six shape registers and
-- fabricating weight base addresses.  THE CARD'S UNIT IS DIFFERENT: it is
-- `matvec_int4_desc_axi`, which fetches a host-prebuilt descriptor over its
-- own read master and needs nothing but a pointer and a GO.  So this seam is
-- SMALLER than the simulation one, not wider: three AXI-Lite writes per job.
--
--   0x00 DESC_PTR_LO  <= addr(31 downto 0)
--   0x04 DESC_PTR_HI  <= addr(63 downto 32)
--   0x08 CTRL bit0    <= '1'          (GO, self-clearing)
--
-- WHAT THIS ADAPTER STILL HAS TO DO, and why each is here:
--
--  * A HAS NO `ready`.  Same as the simulation seam: seq_desc_fetch holds
--    `u_start` until it sees one and refuses to issue while `u_done` is
--    high, so `u_ready` is synthesised from the idle state.
--
--  * D's `done` IS A LEVEL HELD UNTIL `u_ack` (seq_desc_fetch.vhd:235).
--    `matvec_int4_desc_axi`'s `job_done` is ALREADY such a level: it is set
--    in S_DONE and cleared by the next GO (:712, :727, :962), and masked
--    combinationally on the GO write cycle by `and not go_now` (:682).  So
--    the conversion the simulation adapter performs is NOT needed, and
--    re-implementing it would be a second model of a hazard the unit has
--    already closed.  This adapter only holds the level across `u_ack` and
--    refuses to issue the next GO until the ack has been seen.
--
--  * THAT REFUSAL IS THE WHOLE CORRECTNESS ARGUMENT.  Because `job_done` is
--    cleared by GO and by nothing else, a GO issued before D acknowledged
--    the previous completion would erase a `done` D has not yet consumed,
--    and D would then wait forever on a job that had already finished.  The
--    FSM cannot reach S_LO from S_DONE without `u_ack`, and an assertion
--    below says so rather than leaving it to the state encoding.
--
--  * THE ARENA BASE IS AN INPUT PORT, NOT A GENERIC, DELIBERATELY.
--    tools/hbm_map.py's header records that a hardcoded copy of this address
--    in server/fk33_seam.h became "a FOURTH model of the same address".
--    hbm_map.py is the only thing in this repository that chooses an arena
--    address, it writes it into manifest.json, and the host programs it here.
--    A generic would make this file the fifth model.
--
-- WHAT IS NOT HERE: no AXI-Lite READ path.  Completion and error arrive on
-- the unit's `job_done`/`job_err` PORTS, which the unit documents as
-- mirroring STATUS bits 0 and 2.  A read channel would be a second way to
-- learn the same fact, free to disagree with the first.  The consequence is
-- that this adapter cannot report `err_code`; the host reads STATUS itself
-- when `u_err` fires.  That is a deliberate narrowing, recorded here so the
-- next reader does not think it was forgotten.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity a_desc_adapter is
  generic (
    ADDR_W      : positive := 40;   -- must match the unit's ADDR_W
    LITE_AW     : positive := 8;    -- the unit's C_S_AXI_ADDR_WIDTH
    DESC_STRIDE : positive := 512;  -- = DESC_MAXB*AXI_DW/8, the unit's DESC_ALIGN
    N_JOBS      : positive := 311;  -- descriptors the arena was sized for
    EPOCH_W     : positive := 4     -- must match seq_desc_fetch's EPOCH_W
  );
  port (
    clk        : in  std_logic;
    rstn       : in  std_logic;

    -- configuration.  See the header: a port, not a generic.
    arena_base : in  std_logic_vector(ADDR_W-1 downto 0);

    -- the D side
    u_start    : in  std_logic;                      -- level, held until ready
    u_index    : in  std_logic_vector(15 downto 0);  -- which descriptor
    u_ready    : out std_logic;
    u_done     : out std_logic;                      -- level, until u_ack
    u_err      : out std_logic;
    u_ack      : in  std_logic;

    -- THE EPOCH ECHO.  seq_desc_fetch bumps `job_epoch` at S_ISSUE and
    -- compares what comes back at S_COMPLETE (`seq_desc_fetch.vhd:302-304`),
    -- so a completion that does not carry the epoch of the job D issued is
    -- rejected as stale.  The adapter's job is to LATCH the epoch at issue
    -- and echo it, never to compute one: an epoch generated here rather than
    -- captured would agree with itself and defeat the very check it feeds.
    job_epoch    : in  unsigned(EPOCH_W-1 downto 0);
    u_done_epoch : out std_logic_vector(EPOCH_W-1 downto 0);

    -- AXI-Lite master, write channel only
    m_awaddr   : out std_logic_vector(LITE_AW-1 downto 0);
    m_awvalid  : out std_logic;
    m_awready  : in  std_logic;
    m_wdata    : out std_logic_vector(31 downto 0);
    m_wstrb    : out std_logic_vector(3 downto 0);
    m_wvalid   : out std_logic;
    m_wready   : in  std_logic;
    m_bresp    : in  std_logic_vector(1 downto 0);
    m_bvalid   : in  std_logic;
    m_bready   : out std_logic;

    -- straight from the unit's ports, not from a STATUS read
    job_done   : in  std_logic;
    job_err    : in  std_logic;

    -- observability.  jobs_issued counts accepted GOs, not starts.
    jobs_issued : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of a_desc_adapter is

  type st_t is (S_IDLE, S_LO, S_HI, S_GO, S_WAIT, S_DONE, S_REFUSE);
  signal st : st_t := S_IDLE;

  signal addr_q  : unsigned(63 downto 0) := (others => '0');
  signal awdone  : std_logic := '0';   -- this beat's AW handshake has happened
  signal wdone   : std_logic := '0';   -- this beat's W  handshake has happened
  signal err_q   : std_logic := '0';
  signal ep_q    : unsigned(EPOCH_W-1 downto 0) := (others => '0');
  signal ep_take : std_logic := '0';
  signal cnt_q   : unsigned(31 downto 0) := (others => '0');

  -- the register offsets, word-addressed as the unit decodes them
  constant A_LO : natural := 16#00#;
  constant A_HI : natural := 16#04#;
  constant A_GO : natural := 16#08#;

  -- DESC_STRIDE must be a power of two for the alignment check below to be
  -- the same predicate the unit applies.  An out-of-range natural constant
  -- is the only construct Vivado does not silently ignore in synthesis;
  -- `assert ... severity failure` IS silently ignored there.
  function stride_pow2_or_die return natural is
    variable v : natural := DESC_STRIDE;
    variable n : natural := 0;
  begin
    while v > 1 loop
      if (v mod 2) /= 0 then
        return 999999999;  -- deliberately out of range: DESC_STRIDE not 2^k
      end if;
      v := v / 2;
      n := n + 1;
    end loop;
    return n;
  end function;
  constant LOG2_STRIDE : natural range 0 to 31 := stride_pow2_or_die;

begin

  u_ready     <= '1' when st = S_IDLE else '0';
  u_done      <= '1' when (st = S_DONE or st = S_REFUSE) else '0';
  u_err       <= err_q;
  u_done_epoch <= std_logic_vector(ep_q);
  jobs_issued <= std_logic_vector(cnt_q);

  m_wstrb  <= "1111";
  m_bready <= '1';

  -- the write address / data for the beat this state owns
  process(st, addr_q)
  begin
    case st is
      when S_LO =>
        m_awaddr <= std_logic_vector(to_unsigned(A_LO, LITE_AW));
        m_wdata  <= std_logic_vector(addr_q(31 downto 0));
      when S_HI =>
        m_awaddr <= std_logic_vector(to_unsigned(A_HI, LITE_AW));
        m_wdata  <= std_logic_vector(addr_q(63 downto 32));
      when others =>
        m_awaddr <= std_logic_vector(to_unsigned(A_GO, LITE_AW));
        m_wdata  <= x"00000001";
    end case;
  end process;

  m_awvalid <= '1' when (st = S_LO or st = S_HI or st = S_GO) and awdone = '0'
               else '0';
  m_wvalid  <= '1' when (st = S_LO or st = S_HI or st = S_GO) and wdone = '0'
               else '0';

  process(clk)
    variable base_v : unsigned(63 downto 0);
    variable off_v  : unsigned(63 downto 0);
    variable idx_v  : unsigned(15 downto 0);
    variable bad_v  : std_logic;
  begin
    if rising_edge(clk) then
      if rstn = '0' then
        st <= S_IDLE; awdone <= '0'; wdone <= '0';
        err_q <= '0'; addr_q <= (others => '0'); cnt_q <= (others => '0');
        ep_take <= '0'; ep_q <= (others => '0');
      else
        -- the deferred epoch latch; see the note at `ep_take <= '1'` below
        ep_take <= '0';
        if ep_take = '1' then
          ep_q <= job_epoch;
        end if;

        case st is

          when S_IDLE =>
            awdone <= '0'; wdone <= '0';
            if u_start = '1' then
              -- HAZARD, NOT YET A BUG, and it becomes one the moment
              -- `u_index` is driven from D.  rtl/llama_top.vhd:3047 says of
              -- this exact edge: "Latch at job_issue.  NOT at u_start:
              -- u_start leads job_issue by one cycle and job_* still decodes
              -- the PREVIOUS live bank there."  That applies to every job_*
              -- field, not only to the epoch below.
              --
              -- It is safe TODAY only because `u_index` is a top-level input
              -- of the composed top and is not sourced from D's decode at
              -- all.  When it is wired -- and hw/fk33/gen_compose4_top.py
              -- records why it is not wired yet -- it must be sampled one
              -- cycle later, the same way `ep_take` defers the epoch.
              idx_v  := unsigned(u_index);
              base_v := (others => '0');
              base_v(ADDR_W-1 downto 0) := unsigned(arena_base);
              -- NOT a multiply.  numeric_std's `*` returns the SUM of the
              -- operand widths (64 + 32 = 96 here), so the obvious
              -- `resize(idx,64) * to_unsigned(DESC_STRIDE,32)` is a bound
              -- check failure into a 64-bit target.  DESC_STRIDE is already
              -- constrained to a power of two above, so the shift is both
              -- correct and the honest statement of that constraint.
              off_v  := shift_left(resize(idx_v, 64), LOG2_STRIDE);

              -- REFUSE rather than issue, in the two cases the unit would
              -- either latch ERR_ADDR at write time or fetch a descriptor
              -- that was never emitted.  BASEFAB's rule: an adapter that
              -- can issue an out-of-capacity job is a defect the unit's own
              -- benches cannot see.
              bad_v := '0';
              if idx_v >= to_unsigned(N_JOBS, 16) then
                bad_v := '1';
              end if;
              if base_v(LOG2_STRIDE-1 downto 0) /= 0 then
                bad_v := '1';
              end if;

              -- Armed in BOTH arms.  A REFUSED job still completes from
              -- D's point of view -- it raises u_done with u_err -- so it
              -- must carry the epoch of the job D issued, or D rejects the
              -- error report as stale and waits forever on a job that will
              -- never be retried.
              --
              -- ARMED HERE, LATCHED ONE CYCLE LATER.  seq_desc_fetch drives
              -- `job_epoch <= epoch_r` (:932) and bumps `epoch_r` ON this
              -- edge (:790), so `job_epoch` still carries the OLD value in
              -- the issue cycle while S_COMPLETE compares the echo against
              -- the NEW one (:834).  Latching here would be off by one on
              -- EVERY job.  llama_top's seven proven adapters all latch on
              -- `job_issue`, which D raises one cycle later; `ep_take` is
              -- that same instant without adding a port.
              --
              -- FOUND 2026-09-02, and it had passed a 2,496-check bench:
              -- that bench's D model carried the same off-by-one, so the
              -- adapter and its oracle agreed with each other and neither
              -- agreed with seq_desc_fetch.  A model written by the author
              -- of the thing it checks is not an oracle.
              ep_take <= '1';
              if bad_v = '1' then
                err_q <= '1';
                st    <= S_REFUSE;
              else
                err_q  <= '0';
                addr_q <= base_v + off_v;
                st     <= S_LO;
              end if;
            end if;

          when S_LO | S_HI | S_GO =>
            if m_awready = '1' and m_awvalid = '1' then awdone <= '1'; end if;
            if m_wready  = '1' and m_wvalid  = '1' then wdone  <= '1'; end if;
            if m_bvalid = '1' then
              if m_bresp /= "00" then
                err_q <= '1';
                st    <= S_REFUSE;
              else
                awdone <= '0'; wdone <= '0';
                case st is
                  when S_LO => st <= S_HI;
                  when S_HI => st <= S_GO;
                  when others =>
                    cnt_q <= cnt_q + 1;
                    st    <= S_WAIT;
                end case;
              end if;
            end if;

          when S_WAIT =>
            -- job_done is the unit's own level.  It cannot be the PREVIOUS
            -- job's: the GO whose bvalid put us here cleared done_l at that
            -- same edge (:712) and masked it combinationally during the
            -- write cycle (:682).
            if job_err = '1' then
              err_q <= '1';
              st    <= S_DONE;
            elsif job_done = '1' then
              st <= S_DONE;
            end if;

          when S_DONE | S_REFUSE =>
            -- HOLD.  Leaving without u_ack would let the next GO erase a
            -- completion D has not consumed, and D would wait forever.
            if u_ack = '1' then
              st <= S_IDLE;
            end if;

        end case;
      end if;
    end if;
  end process;

  -- Teeth for the argument in the header, checked every cycle in simulation.
  -- Vivado ignores `severity failure` in synthesis, so these are simulation
  -- guards only and the FSM is written so they cannot fire.
  process(clk)
  begin
    if rising_edge(clk) then
      if rstn = '1' then
        assert not (st = S_LO and u_ack = '0' and u_done = '1')
          report "a_desc_adapter: issuing a job while a completion is unacked"
          severity failure;
        assert not (st = S_WAIT and u_ready = '1')
          report "a_desc_adapter: ready asserted while a job is in flight"
          severity failure;
      end if;
    end if;
  end process;

end architecture;
