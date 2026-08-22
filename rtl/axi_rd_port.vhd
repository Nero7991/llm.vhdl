-- rtl/axi_rd_port.vhd -- one AXI4 read-only master feeding a stream FIFO.
--
-- Spec: docs/superpowers/specs/2026-08-20-int4-streaming-matvec-design.md  7.7
--
-- This is the project's FIRST AXI master: everything before v2.0 kept its
-- weights in on-chip ROM, so there is no existing pattern to follow here and
-- the AXI-Lite slaves in llama_engine_axi / mac_axi are not one.
--
-- The port reads ONE contiguous sub-region as plain sequential bursts and hands
-- the beats out in order.  That is all it does -- there is deliberately no
-- reordering, no width conversion and no drain schedule, because 7.7 moved the
-- lane interleave into the PACKER: each port owns its own sub-region, so DDR
-- locality is sequential and the merge above is pure wiring.  Rev 3 of the spec
-- put a 128->512 width converter here and it cost ~8 BRAM36 per port for the
-- read port width alone (RAMB36E2 tops out at 72 bits).
--
-- FLUSH ON START is not optional (7.7).  Sub-regions are padded to whole 4 KB
-- bursts, so the burst carrying the last needed beat also delivers padding
-- beats that stay resident when the job ends.  The residue differs per port, so
-- without a flush the next job's word stream would be misaligned by a
-- per-port-varying amount -- silently, and differently on every matrix.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_rd_port is
  generic(
    AXI_DW  : positive := 128;
    ADDR_W  : positive := 32;
    DEPTH   : positive := 512;   -- beats; 7.7 budgets 8 KB at AXI_DW=128
    MAXB    : positive := 256;   -- beats per burst; 256 x 16 B = one 4 KB burst
    MAXOUT  : positive := 2      -- bursts allowed in flight
  );
  port(
    clk, rst : in  std_logic;

    -- job.  base must be 4 KB aligned; n_beats is the whole sub-region.
    start    : in  std_logic;
    base     : in  std_logic_vector(ADDR_W-1 downto 0);
    n_beats  : in  integer;

    -- AXI4 read address / read data
    arvalid  : out std_logic;
    arready  : in  std_logic;
    araddr   : out std_logic_vector(ADDR_W-1 downto 0);
    arlen    : out std_logic_vector(7 downto 0);
    arsize   : out std_logic_vector(2 downto 0);
    arburst  : out std_logic_vector(1 downto 0);
    rvalid   : in  std_logic;
    rready   : out std_logic;
    rdata    : in  std_logic_vector(AXI_DW-1 downto 0);
    rlast    : in  std_logic;

    -- stream out
    q_valid  : out std_logic;
    q_data   : out std_logic_vector(AXI_DW-1 downto 0);
    q_ready  : in  std_logic
  );
end entity;

architecture rtl of axi_rd_port is
  constant BYTES : positive := AXI_DW / 8;

  signal f_iv, f_ir, f_flush : std_logic := '0';
  signal f_qv, f_qr : std_logic := '0';
  signal f_qd : std_logic_vector(AXI_DW-1 downto 0);
  signal f_level : integer;

  type st_t is (S_IDLE, S_DRAIN, S_FLUSH, S_RUN);
  signal st : st_t := S_IDLE;

  signal ar_addr  : unsigned(ADDR_W-1 downto 0) := (others => '0');
  signal ar_left  : integer := 0;    -- beats not yet requested
  signal promised : integer := 0;    -- requested but not yet in the FIFO
  signal outst    : integer range 0 to 3 := 0;
  signal arv      : std_logic := '0';
  -- starts at 1, never 0: arlen carries this_len-1 and to_unsigned(-1) traps
  signal this_len : integer range 1 to MAXB := 1;

  signal p_base   : std_logic_vector(ADDR_W-1 downto 0) := (others => '0');
  signal p_beats  : integer := 0;
begin
  arvalid <= arv;
  araddr  <= std_logic_vector(ar_addr);
  arlen   <= std_logic_vector(to_unsigned(this_len - 1, 8));
  arsize  <= std_logic_vector(to_unsigned(clog2(BYTES), 3));
  arburst <= "01";                                  -- INCR

  -- In S_DRAIN the R channel is accepted and DISCARDED, so it must not be
  -- backpressured by the FIFO; in S_RUN the FIFO owns the backpressure.
  rready <= f_ir when st = S_RUN else '1';
  f_iv   <= rvalid when st = S_RUN else '0';

  -- The output is SUPPRESSED outside S_RUN.  Flushing alone is not enough: a
  -- start does not take effect until the drain completes, and in that window
  -- the FIFO still holds the abandoned job's residue.  A consumer that reads
  -- as soon as q_valid rises would swallow it before the flush ever lands --
  -- which is exactly what happened the first time this was simulated.
  q_valid <= f_qv when st = S_RUN else '0';
  q_data  <= f_qd;
  f_qr    <= q_ready when st = S_RUN else '0';

  fifo : entity work.stream_fifo
    generic map(W => AXI_DW, DEPTH => DEPTH)
    port map(clk => clk, rst => rst, flush => f_flush,
             i_valid => f_iv, i_data => rdata, i_ready => f_ir,
             q_valid => f_qv, q_data => f_qd, q_ready => f_qr,
             level => f_level);

  process(clk)
    variable pr   : integer;
    variable os   : integer;
    variable want : integer;
  begin
    if rising_edge(clk) then
      f_flush <= '0';

      if rst = '1' then
        st <= S_IDLE;
        ar_left <= 0; promised <= 0; outst <= 0; arv <= '0';
        f_flush <= '1';

      else
        pr := promised;
        os := outst;

        -- a beat landing retires one promise; in S_DRAIN it is discarded, but
        -- the burst accounting is identical
        if rvalid = '1' and rready = '1' then
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
        end if;

        case st is
          when S_DRAIN =>
            if arv = '0' and os = 0 then
              f_flush <= '1';
              st <= S_FLUSH;
            end if;

          -- S_FLUSH exists because f_flush is REGISTERED: it is high during the
          -- cycle after it is set, and the FIFO clears at the end of that
          -- cycle.  Entering S_RUN directly would leave the output live for one
          -- cycle over not-yet-cleared contents, and a consumer reading the
          -- instant q_valid rises takes exactly one stale beat -- shifting the
          -- entire stream by one, which is the silent per-port misalignment
          -- 7.7 warns about, just one beat instead of many.
          when S_FLUSH =>
            ar_addr <= unsigned(p_base);
            ar_left <= p_beats;
            pr := 0;
            st <= S_RUN;

          when others => null;
        end case;

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
