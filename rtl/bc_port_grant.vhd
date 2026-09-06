-- rtl/bc_port_grant.vhd -- THE 2:1 GRANT BETWEEN SUBSYSTEMS B AND C OVER THE
-- SHARED HBM PORTS, WITH THE DRAIN INTERLOCK.
--
-- WHY THIS EXISTS.  docs/2026-08-27_hbm-port-contention.md closes the HBM port
-- budget only by taking B and C as `max`, not as a sum, on the ground that they
-- are never simultaneously active.  Its own words on the state of that:
--
--     "Both B and C already specify the cure, and neither has it in RTL."
--
-- and, on the interlock this file also carries:
--
--     "its absence is a silent-data-corruption class of bug, not a performance
--      one"  (one counter per shared port, one FSM state, MEASURED below 0.02%
--      of the token).
--
-- A budget that closes on mutual exclusion is only as good as the thing that
-- ENFORCES the exclusion.  Until this block exists, "B and C are never both
-- active" is a property of the schedule, and a schedule is not a mechanism.
--
-- THE SHAPES, read off the RTL rather than assumed:
--   B  rtl/gdn_state_store.vhd  ONE read master (`r_*`) + ONE write master
--      (`w_*`), surfaced at llama_top as `bst_*`, 33-bit address, 256-bit data.
--      Its port demand is BANDWIDTH-driven and proportional to the core clock:
--      2 ports at 175 MHz (DERIVED from 30.22 GB/s at 236.128 MHz, 11.77 GB/s
--      per port).
--   C  TWO read masters + ONE write master.  `kv_arvalid` is
--      std_logic_vector(1 downto 0) and `kv_araddr` is 2*ADDR_W wide, i.e. the
--      two reads are FLATTENED on one port pair, not two separate interfaces.
--      Its demand is a CONCURRENCY requirement and does NOT fall with the
--      clock: 3 at every clock and every context, because the datapath issues
--      three concurrent streams.
--
-- So the pool is THREE ports and the assignment is:
--   port 0   B read    or  C read 0
--   port 1   B write   or  C read 1
--   port 2   (idle)    or  C write
--
-- THE DRAIN INTERLOCK IS THE POINT, AND IT IS A STATE BOUNDARY, NOT A DEADLINE.
-- Switching the mux while the outgoing master still has transactions in flight
-- does not hang: the returning R or B beat is delivered to WHOEVER OWNS THE
-- PORT NOW.  The incoming master accepts it as its own, and the outgoing one
-- never sees it.  Both then compute on data that is silently wrong, with no
-- error anywhere -- which is exactly why the budget document rates this above
-- a performance bug.  So the grant does not switch on request; it switches only
-- when every outstanding count on every shared port is zero.
--
-- This file drives NOTHING toward hardware and contains no board primitive.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity bc_port_grant is
  generic (
    ADDR_W  : positive := 33;      -- the HBM SAXI address width, MEASURED
    DATA_W  : positive := 256;
    NPORT   : positive := 3;       -- the shared pool
    -- Width of the outstanding counters.  8 bits is 255 in flight per port,
    -- far above anything either master issues; it is a counter, not a budget.
    CNT_W   : positive := 8
  );
  port (
    clk  : in std_logic;
    rstn : in std_logic;

    -- ---- requests.  Each is the requester's own "I have work" level. -----
    b_req : in std_logic;
    c_req : in std_logic;
    b_gnt : out std_logic;
    c_gnt : out std_logic;

    -- ---- B: one read master, one write master ---------------------------
    b_arvalid : in  std_logic;
    b_araddr  : in  std_logic_vector(ADDR_W-1 downto 0);
    b_arlen   : in  std_logic_vector(7 downto 0);
    b_arready : out std_logic;
    b_rvalid  : out std_logic;
    b_rdata   : out std_logic_vector(DATA_W-1 downto 0);
    b_rlast   : out std_logic;
    b_rready  : in  std_logic;
    b_awvalid : in  std_logic;
    b_awaddr  : in  std_logic_vector(ADDR_W-1 downto 0);
    b_awlen   : in  std_logic_vector(7 downto 0);
    b_awready : out std_logic;
    b_wvalid  : in  std_logic;
    b_wdata   : in  std_logic_vector(DATA_W-1 downto 0);
    b_wlast   : in  std_logic;
    b_wready  : out std_logic;
    b_bvalid  : out std_logic;
    b_bready  : in  std_logic;

    -- ---- C: two read masters (FLATTENED) and one write master -----------
    c_arvalid : in  std_logic_vector(1 downto 0);
    c_araddr  : in  std_logic_vector(2*ADDR_W-1 downto 0);
    c_arlen   : in  std_logic_vector(15 downto 0);
    c_arready : out std_logic_vector(1 downto 0);
    c_rvalid  : out std_logic_vector(1 downto 0);
    c_rdata   : out std_logic_vector(2*DATA_W-1 downto 0);
    c_rlast   : out std_logic_vector(1 downto 0);
    c_rready  : in  std_logic_vector(1 downto 0);
    c_awvalid : in  std_logic;
    c_awaddr  : in  std_logic_vector(ADDR_W-1 downto 0);
    c_awlen   : in  std_logic_vector(7 downto 0);
    c_awready : out std_logic;
    c_wvalid  : in  std_logic;
    c_wdata   : in  std_logic_vector(DATA_W-1 downto 0);
    c_wlast   : in  std_logic;
    c_wready  : out std_logic;
    c_bvalid  : out std_logic;
    c_bready  : in  std_logic;

    -- ---- the shared pool, flattened NPORT-wide --------------------------
    m_arvalid : out std_logic_vector(NPORT-1 downto 0);
    m_araddr  : out std_logic_vector(NPORT*ADDR_W-1 downto 0);
    m_arlen   : out std_logic_vector(NPORT*8-1 downto 0);
    m_arready : in  std_logic_vector(NPORT-1 downto 0);
    m_rvalid  : in  std_logic_vector(NPORT-1 downto 0);
    m_rdata   : in  std_logic_vector(NPORT*DATA_W-1 downto 0);
    m_rlast   : in  std_logic_vector(NPORT-1 downto 0);
    m_rready  : out std_logic_vector(NPORT-1 downto 0);
    m_awvalid : out std_logic_vector(NPORT-1 downto 0);
    m_awaddr  : out std_logic_vector(NPORT*ADDR_W-1 downto 0);
    m_awlen   : out std_logic_vector(NPORT*8-1 downto 0);
    m_awready : in  std_logic_vector(NPORT-1 downto 0);
    m_wvalid  : out std_logic_vector(NPORT-1 downto 0);
    m_wdata   : out std_logic_vector(NPORT*DATA_W-1 downto 0);
    m_wlast   : out std_logic_vector(NPORT-1 downto 0);
    m_wready  : in  std_logic_vector(NPORT-1 downto 0);
    m_bvalid  : in  std_logic_vector(NPORT-1 downto 0);
    m_bready  : out std_logic_vector(NPORT-1 downto 0);

    -- ---- observability, and one sticky fault ---------------------------
    owner_is_c : out std_logic;
    draining   : out std_logic;
    -- Sticky.  Set if a switch was ever attempted with traffic outstanding,
    -- which cannot happen if this block is correct.  It is here so that a
    -- future change which bypasses the interlock is LOUD rather than silent,
    -- because the failure it guards is silent by nature.
    err_switch_busy : out std_logic
  );
end entity;

architecture rtl of bc_port_grant is
  type own_t is (OWN_NONE, OWN_B, OWN_C);
  signal own : own_t := OWN_NONE;

  subtype cnt_t is unsigned(CNT_W-1 downto 0);
  type cnt_arr is array (0 to NPORT-1) of cnt_t;
  signal rd_out : cnt_arr := (others => (others => '0'));
  signal wr_out : cnt_arr := (others => (others => '0'));

  signal quiet      : std_logic;
  signal issue_now  : std_logic;
  signal out_idle   : std_logic;
  signal may_switch : std_logic;
  signal err_r      : std_logic := '0';
  signal own_q      : own_t := OWN_NONE;
  signal quiet_q    : std_logic := '1';
  signal to_c, to_b : std_logic;
begin
  -- Every shared port idle: no read burst and no write burst in flight.
  -- ONE zero test over ALL ports, not per port: a switch is global, so a
  -- per-port test would allow the mux to move while a sibling port still has
  -- a beat coming back.
  quiet_p : process(rd_out, wr_out) is
    variable q : std_logic;
  begin
    q := '1';
    for i in 0 to NPORT-1 loop
      if rd_out(i) /= 0 or wr_out(i) /= 0 then q := '0'; end if;
    end loop;
    quiet <= q;
  end process;

  -- DEFECT FOUND BY READING THIS FILE BACK, NOT BY A BENCH.  `quiet` is the
  -- COUNTER state, and the counters move on the NEXT edge.  So an address
  -- handshake completing in the very cycle the FSM decides to switch is
  -- counted AFTER the owner has already changed: the outgoing master's burst
  -- is charged to the incoming one, and its data beat is delivered to the
  -- wrong requester.  That is precisely the silent corruption this block is
  -- for, reintroduced by the block itself.  So the switch also requires that
  -- no address handshake completes this cycle.
  issue_p : process(m_arvalid, m_arready, m_awvalid, m_awready) is
    variable v : std_logic;
  begin
    v := '0';
    for i in 0 to NPORT-1 loop
      if (m_arvalid(i) and m_arready(i)) = '1' then v := '1'; end if;
      if (m_awvalid(i) and m_awready(i)) = '1' then v := '1'; end if;
    end loop;
    issue_now <= v;
  end process;

  -- SECOND DEFECT, same reading.  AXI forbids deasserting a VALID that has not
  -- been accepted.  Dropping the mux while the outgoing master holds an
  -- unaccepted AWVALID/ARVALID/WVALID pulls VALID low without a handshake, and
  -- a protocol violation on an HBM port is not a recoverable condition.  The
  -- counters do NOT cover this: a master may assert WVALID before AWVALID, and
  -- an address that has never handshaked has never been counted.
  hold_p : process(own, b_arvalid, b_awvalid, b_wvalid,
                   c_arvalid, c_awvalid, c_wvalid) is
  begin
    case own is
      when OWN_B =>
        out_idle <= not (b_arvalid or b_awvalid or b_wvalid);
      when OWN_C =>
        out_idle <= not (c_arvalid(0) or c_arvalid(1) or c_awvalid or c_wvalid);
      when others =>
        out_idle <= '1';
    end case;
  end process;

  may_switch <= quiet and out_idle and (not issue_now);

  b_gnt      <= '1' when own = OWN_B else '0';
  c_gnt      <= '1' when own = OWN_C else '0';
  owner_is_c <= '1' when own = OWN_C else '0';
  draining   <= not quiet;
  err_switch_busy <= err_r;

  to_c <= '1' when (c_req = '1' and own /= OWN_C) else '0';
  to_b <= '1' when (b_req = '1' and own /= OWN_B) else '0';

  -- ---- the grant FSM.  Switch ONLY when quiet. -------------------------
  g : process(clk) is
  begin
    if rising_edge(clk) then
      if rstn = '0' then
        own <= OWN_NONE; err_r <= '0';
      else
        if may_switch = '1' then
          -- C first when both ask.  C is the latency-critical one (attention
          -- sits on the token's critical path; B's state move does not), and
          -- an arbitrary but FIXED priority is what keeps this testable --
          -- a round robin would make the switch instant depend on history.
          if to_c = '1' then
            own <= OWN_C;
          elsif to_b = '1' then
            own <= OWN_B;
          elsif b_req = '0' and c_req = '0' then
            own <= OWN_NONE;
          end if;
        end if;

        -- err_switch_busy is an INDEPENDENT OBSERVER, not a restatement of the
        -- FSM.  It watches the OWNER SIGNAL ITSELF and fires if the owner ever
        -- changed across a cycle in which the pool was not quiet.  Written as
        -- `own /= own_q and quiet_q = '0'` it does not share a term with the
        -- guard above, so a future edit that weakens the guard is caught here
        -- rather than silently corrupting data.  A check derived from the same
        -- expression it is checking is decoration; this one is not.
        own_q   <= own;
        quiet_q <= quiet;
        if own /= own_q and quiet_q = '0' then
          err_r <= '1';
        end if;
      end if;
    end if;
  end process;

  -- ---- outstanding counters, one pair per SHARED port ------------------
  -- A read burst is outstanding from AR handshake until RLAST handshake; a
  -- write burst from AW handshake until BVALID handshake.  Counted on the
  -- SHARED side, which is the only side that sees what the slave still owes.
  cnt_p : process(clk) is
  begin
    if rising_edge(clk) then
      if rstn = '0' then
        rd_out <= (others => (others => '0'));
        wr_out <= (others => (others => '0'));
      else
        for i in 0 to NPORT-1 loop
          if (m_arvalid(i) and m_arready(i)) = '1'
             and not ((m_rvalid(i) and m_rlast(i) and m_rready(i)) = '1') then
            rd_out(i) <= rd_out(i) + 1;
          elsif (m_rvalid(i) and m_rlast(i) and m_rready(i)) = '1'
             and rd_out(i) /= 0 then
            rd_out(i) <= rd_out(i) - 1;
          end if;

          if (m_awvalid(i) and m_awready(i)) = '1'
             and not ((m_bvalid(i) and m_bready(i)) = '1') then
            wr_out(i) <= wr_out(i) + 1;
          elsif (m_bvalid(i) and m_bready(i)) = '1' and wr_out(i) /= 0 then
            wr_out(i) <= wr_out(i) - 1;
          end if;
        end loop;
      end if;
    end if;
  end process;

  -- ---- the mux ---------------------------------------------------------
  -- Port 0: B read   / C read 0
  -- Port 1: B write  / C read 1
  -- Port 2: idle     / C write
  mux_p : process(own, b_arvalid, b_araddr, b_arlen, b_rready,
                  b_awvalid, b_awaddr, b_awlen, b_wvalid, b_wdata, b_wlast,
                  b_bready, c_arvalid, c_araddr, c_arlen, c_rready,
                  c_awvalid, c_awaddr, c_awlen, c_wvalid, c_wdata, c_wlast,
                  c_bready, m_arready, m_rvalid, m_rdata, m_rlast,
                  m_awready, m_wready, m_bvalid) is
    constant Z8 : std_logic_vector(7 downto 0) := (others => '0');
  begin
    m_arvalid <= (others => '0');  m_araddr <= (others => '0');
    m_arlen   <= (others => '0');  m_rready <= (others => '0');
    m_awvalid <= (others => '0');  m_awaddr <= (others => '0');
    m_awlen   <= (others => '0');  m_wvalid <= (others => '0');
    m_wdata   <= (others => '0');  m_wlast  <= (others => '0');
    m_bready  <= (others => '0');
    b_arready <= '0'; b_rvalid <= '0'; b_rlast <= '0';
    b_rdata   <= (others => '0');
    b_awready <= '0'; b_wready <= '0'; b_bvalid <= '0';
    c_arready <= (others => '0'); c_rvalid <= (others => '0');
    c_rlast   <= (others => '0'); c_rdata <= (others => '0');
    c_awready <= '0'; c_wready <= '0'; c_bvalid <= '0';

    if own = OWN_B then
      -- port 0 <- B read
      m_arvalid(0) <= b_arvalid;
      m_araddr(ADDR_W-1 downto 0) <= b_araddr;
      m_arlen(7 downto 0) <= b_arlen;
      m_rready(0)  <= b_rready;
      b_arready    <= m_arready(0);
      b_rvalid     <= m_rvalid(0);
      b_rlast      <= m_rlast(0);
      b_rdata      <= m_rdata(DATA_W-1 downto 0);
      -- port 1 <- B write
      m_awvalid(1) <= b_awvalid;
      m_awaddr(2*ADDR_W-1 downto ADDR_W) <= b_awaddr;
      m_awlen(15 downto 8) <= b_awlen;
      m_wvalid(1)  <= b_wvalid;
      m_wdata(2*DATA_W-1 downto DATA_W) <= b_wdata;
      m_wlast(1)   <= b_wlast;
      m_bready(1)  <= b_bready;
      b_awready    <= m_awready(1);
      b_wready     <= m_wready(1);
      b_bvalid     <= m_bvalid(1);

    elsif own = OWN_C then
      -- ports 0,1 <- C's two reads
      m_arvalid(1 downto 0) <= c_arvalid;
      m_araddr(2*ADDR_W-1 downto 0) <= c_araddr;
      m_arlen(15 downto 0)  <= c_arlen;
      m_rready(1 downto 0)  <= c_rready;
      c_arready <= m_arready(1 downto 0);
      c_rvalid  <= m_rvalid(1 downto 0);
      c_rlast   <= m_rlast(1 downto 0);
      c_rdata   <= m_rdata(2*DATA_W-1 downto 0);
      -- port 2 <- C write
      m_awvalid(2) <= c_awvalid;
      m_awaddr(3*ADDR_W-1 downto 2*ADDR_W) <= c_awaddr;
      m_awlen(23 downto 16) <= c_awlen;
      m_wvalid(2)  <= c_wvalid;
      m_wdata(3*DATA_W-1 downto 2*DATA_W) <= c_wdata;
      m_wlast(2)   <= c_wlast;
      m_bready(2)  <= c_bready;
      c_awready    <= m_awready(2);
      c_wready     <= m_wready(2);
      c_bvalid     <= m_bvalid(2);
    end if;
  end process;
end architecture;
