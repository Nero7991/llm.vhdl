-- rtl/mv_dist.vhd -- the a450 x/scale distributor (spec 2.2), in aclk_a.
--
-- JOB CONTRACT (a450 Task 4 review fix).  On `go` (a one-cycle pulse) every job input
-- EXCEPT s_base/s_beats is LATCHED right there (j_nb/j_rows/j_lastv/j_os/j_mode/j_cb, and
-- the pad-column mask derived from j_lastv), so the caller is free to change them on the
-- very next cycle.  s_base/s_beats are NOT latched -- they are wired straight into the
-- scale ports' `base`/`n_beats` (rtl/mv_rdport.vhd), which read them for the WHOLE job the
-- way rtl/axi_rd_port.vhd's header already requires of its own caller ("must not be
-- changed between start and the job completing"), so mv_dist's caller must hold those two
-- stable for the whole job -- the same contract, just one level up.
--
-- `busy` falls as soon as the FSM below returns to D_IDLE, which is BEFORE the job's last
-- few flits have cleared the pipeline: up to 2 are still in mv_dist's own A/B stages and up
-- to 3 more are in rtl/mv_xbcast.vhd's tree, so a tile can still be receiving flits for a
-- few cycles after `busy` falls.  `go` is sampled only in D_IDLE (see the `case` below); a
-- `go` pulse while busy is '1' is a caller bug -- the FSM silently ignores it rather than
-- queuing or restarting a job, so the `go_accept` assertion flags it instead of letting a
-- job go missing unnoticed.  Serialising a new job against every TILE's drain
-- (rtl/mv_tile.vhd's `serialize` contract) is the CALLER's job (Task 6 `mv_back`), not
-- this entity's: mv_dist only needs its own pipeline clear, which `busy` already reports.
--
-- On `go` it starts the NPORTS_S scale ports and sends, in order and only while room_all
-- is '1':
--   1 PARAM flit   x[5:0] = out_shift, x[7:6] = out_mode
--   16 CB flits    x[3:0] = entry, x[11:4] = the int8 codebook value
--   one ITEM per (row-tile t, block b), b fastest: x = activation block b with every
--                  column at or past n_cols forced to 0, s = the 48 scales of the scale
--                  superword (scale port q is rows 16q..16q+15, spec 6.5a), first = (b = 0),
--                  last = (b = nb-1)
-- Pad columns are zeroed HERE, so a tile needs no column count: a zero activation
-- contributes exactly the 0 that matvec_core's `k < n_cols` arm writes.
--
-- Two stages: A decides and pops (scale FIFOs, block counter, the activation read
-- address), B lands the 1-cycle activation read and masks it.  Both outputs registered.
--
-- TIMING (a450 Task 4 review fix).  j_nb/j_rows/j_lastv/s_beats are range-constrained to
-- their real maxima: NB_MAX = ceil(MAXCOLS/BLK) for j_nb, MAXROWS for j_rows, BLK for
-- j_lastv, and NB_MAX * ceil(MAXROWS/ROWS_IF) for s_beats (one scale superword per
-- (row-tile, block) pair, spec 2.2) -- see the NB_MAX/NTL_MAX/SBEATS_MAX constants below.
-- The row-tile count is tracked as `rtleft_r`, row-tiles REMAINING after the one in
-- flight (not rows left), precomputed once at `go` (ceil(j_rows/ROWS_IF) - 1) alongside
-- `nb_m1_r` (j_nb - 1).  The per-cycle tests in D_RUN are then the narrow, registered-only
-- `b = nb_m1_r` and `rtleft_r = 0` (`at_lastblk`/`at_lastrt` below), never the wide
-- `b = nb_r - 1` subtraction or the wide `rows_left <= ROWS_IF` magnitude compare the
-- first cut of this file used -- both sat in the same cycle `s_take` (itself a late
-- signal, off room_all and the three scale FIFOs' `q_valid`) resolves in. The flit
-- sequence emitted is unchanged: this is a resynthesis of the same FSM, not a behaviour
-- change.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity mv_dist is
  generic(
    BLK      : positive := 32;
    ROWS_IF  : positive := 48;
    NPORTS_S : positive := 3;
    AXI_DW   : positive := 256;
    ADDR_W   : positive := 40;
    DEPTH    : positive := 512;
    MAXB     : positive := 16;
    MAXOUT   : positive := 16;
    MAXCOLS  : positive := 17408;
    MAXROWS  : positive := 17408   -- a450 Task 4 review fix: bounds j_rows/s_beats
  );
  port(
    clk, rst  : in  std_logic;
    go        : in  std_logic;
    -- a450 Task 4 review fix: range-constrained to the real maxima (see the header and
    -- the NB_MAX/NTL_MAX constants below), not left as unconstrained natural/integer.
    j_nb      : in  natural range 0 to (MAXCOLS + BLK - 1) / BLK;  -- ceil(n_cols/BLK)
    j_rows    : in  natural range 0 to MAXROWS;                   -- n_rows
    j_lastv   : in  natural range 0 to BLK;                       -- valid cols, last block
    j_os      : in  std_logic_vector(5 downto 0);
    j_mode    : in  std_logic_vector(1 downto 0);
    j_cb      : in  std_logic_vector(127 downto 0);   -- entry e at [8e+7:8e]
    s_base    : in  std_logic_vector(NPORTS_S*ADDR_W-1 downto 0);
    -- widest possible total = ceil(MAXCOLS/BLK) * ceil(MAXROWS/ROWS_IF) scale superwords
    s_beats   : in  natural range 0 to ((MAXCOLS + BLK - 1) / BLK)
                                      * ((MAXROWS + ROWS_IF - 1) / ROWS_IF);
    x_rbaddr  : out std_logic_vector(clog2((MAXCOLS+BLK-1)/BLK)-1 downto 0);
    x_rdata   : in  std_logic_vector(BLK*16-1 downto 0);
    m_arvalid : out std_logic_vector(NPORTS_S-1 downto 0);
    m_arready : in  std_logic_vector(NPORTS_S-1 downto 0);
    m_araddr  : out std_logic_vector(NPORTS_S*ADDR_W-1 downto 0);
    m_arlen   : out std_logic_vector(NPORTS_S*8-1 downto 0);
    m_arsize  : out std_logic_vector(NPORTS_S*3-1 downto 0);
    m_arburst : out std_logic_vector(NPORTS_S*2-1 downto 0);
    m_rvalid  : in  std_logic_vector(NPORTS_S-1 downto 0);
    m_rready  : out std_logic_vector(NPORTS_S-1 downto 0);
    m_rdata   : in  std_logic_vector(NPORTS_S*AXI_DW-1 downto 0);
    m_rlast   : in  std_logic_vector(NPORTS_S-1 downto 0);
    o_v       : out std_logic;
    o_kind    : out std_logic_vector(1 downto 0);
    o_x       : out std_logic_vector(BLK*16-1 downto 0);
    o_s       : out std_logic_vector(ROWS_IF*16-1 downto 0);
    o_first   : out std_logic;
    o_last    : out std_logic;
    room_all  : in  std_logic;
    busy      : out std_logic
  );
end entity;

architecture rtl of mv_dist is
  -- GRP = 1 only: one superword is exactly one row-tile's scales (ROWS_IF = 48, 3 x 256).
  constant CHK_GRP : natural := 1 - abs(NPORTS_S*AXI_DW - ROWS_IF*16);
  -- a450 Task 4 review fix: the real maxima the ports above range-constrain to.  NB_MAX =
  -- ceil(MAXCOLS/BLK) is the widest block count a job can carry; NTL_MAX =
  -- ceil(MAXROWS/ROWS_IF) is the widest row-tile count; SBEATS_MAX = NB_MAX*NTL_MAX is the
  -- widest total scale-superword count (one beat per (row-tile, block) pair).
  constant NB_MAX     : positive := (MAXCOLS + BLK - 1) / BLK;
  constant NTL_MAX     : positive := (MAXROWS + ROWS_IF - 1) / ROWS_IF;
  constant SBEATS_MAX : positive := NB_MAX * NTL_MAX;
  type st_t is (D_IDLE, D_PAR, D_CB, D_RUN);
  signal st : st_t := D_IDLE;
  type qd_t is array(0 to NPORTS_S-1) of std_logic_vector(AXI_DW-1 downto 0);
  signal qv : std_logic_vector(NPORTS_S-1 downto 0);
  signal qd : qd_t;
  signal s_allv, s_take : std_logic;
  signal s_start : std_logic := '0';
  -- nb_m1_r = j_nb - 1 and rtleft_r = ceil(j_rows/ROWS_IF) - 1 (row-tiles remaining AFTER
  -- the one in flight), both precomputed once at `go` so the per-cycle tests below
  -- (at_lastblk/at_lastrt) are narrow equality/zero compares against REGISTERED values,
  -- never a live subtraction or a live magnitude compare against ROWS_IF in the s_take
  -- cycle (see the header).
  signal nb_m1_r  : natural range 0 to NB_MAX-1  := 0;
  signal rtleft_r : natural range 0 to NTL_MAX-1 := 0;
  signal b    : natural range 0 to NB_MAX-1 := 0;
  signal cbi  : natural range 0 to 15 := 0;
  signal lvm  : std_logic_vector(BLK-1 downto 0) := (others => '1');
  signal os_r : std_logic_vector(5 downto 0) := (others => '0');
  signal md_r : std_logic_vector(1 downto 0) := "00";
  signal cb_r : std_logic_vector(127 downto 0) := (others => '0');
  -- stage A
  signal a_v, a_f, a_l : std_logic := '0';
  signal a_k   : std_logic_vector(1 downto 0) := "00";
  signal a_pay : std_logic_vector(11 downto 0) := (others => '0');
  signal a_s   : std_logic_vector(ROWS_IF*16-1 downto 0) := (others => '0');
  signal a_msk : std_logic_vector(BLK-1 downto 0) := (others => '1');
  -- stage B
  signal b_v, b_f, b_l : std_logic := '0';
  signal b_k : std_logic_vector(1 downto 0) := "00";
  signal b_x : std_logic_vector(BLK*16-1 downto 0) := (others => '0');
  signal b_s : std_logic_vector(ROWS_IF*16-1 downto 0) := (others => '0');
  -- narrow flags read in D_RUN instead of recomputing wide arithmetic there (see header)
  signal at_lastblk, at_lastrt : std_logic;
begin
  gen_s : for q in 0 to NPORTS_S-1 generate
    -- a450 Task 4 review fix: mv_rdport, not axi_rd_port.  axi_rd_port's single-clock path
    -- was measured FAILING at 2.222 ns in Task 3 (mcnt -> this_len/arv); mv_rdport
    -- (rtl/mv_rdport.vhd, wired to rtl/mv_rdfsm.vhd) is the same fix mv_tile already
    -- carries for its weight port, applied here to the 3 scale ports -- same port
    -- semantics, no DUAL_CLK generic (mv_rdport is single-clock only; see its header).
    -- Do not edit rtl/axi_rd_port.vhd, rtl/axi_rd_fsm.vhd or rtl/stream_fifo.vhd for this.
    sport : entity work.mv_rdport
      generic map(AXI_DW => AXI_DW, ADDR_W => ADDR_W, DEPTH => DEPTH, MAXB => MAXB,
                  MAXOUT => MAXOUT, FAST_POP => true)
      port map(clk => clk, rst => rst, start => s_start,
               base => s_base((q+1)*ADDR_W-1 downto q*ADDR_W), n_beats => s_beats,
               arvalid => m_arvalid(q), arready => m_arready(q),
               araddr => m_araddr((q+1)*ADDR_W-1 downto q*ADDR_W),
               arlen => m_arlen((q+1)*8-1 downto q*8),
               arsize => m_arsize((q+1)*3-1 downto q*3),
               arburst => m_arburst((q+1)*2-1 downto q*2),
               rvalid => m_rvalid(q), rready => m_rready(q),
               rdata => m_rdata((q+1)*AXI_DW-1 downto q*AXI_DW), rlast => m_rlast(q),
               q_valid => qv(q), q_data => qd(q), q_ready => s_take);
  end generate;

  agg : process(qv)
    variable a : std_logic;
  begin
    a := '1';
    for q in 0 to NPORTS_S-1 loop a := a and qv(q); end loop;
    s_allv <= a;
  end process;

  s_take   <= '1' when st = D_RUN and room_all = '1' and s_allv = '1' else '0';
  x_rbaddr <= std_logic_vector(to_unsigned(b, x_rbaddr'length));
  busy     <= '0' when st = D_IDLE else '1';

  -- narrow, registered-only tests: no subtraction, no magnitude compare against ROWS_IF
  at_lastblk <= '1' when b = nb_m1_r  else '0';
  at_lastrt  <= '1' when rtleft_r = 0 else '0';

  -- a450 Task 4 review fix: `go` may only be accepted in D_IDLE (see the case statement
  -- below); a `go` pulse while busy is '1' is a caller bug that would otherwise drop a
  -- job silently.  Simulation-only; synthesis ignores it.
  go_accept : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '0' then
        assert not (go = '1' and busy = '1')
          report "mv_dist: go accepted while busy -- a job would be dropped (the caller "
               & "must not issue go until busy falls)"
          severity failure;
      end if;
    end if;
  end process;

  -- a450 Task 4 review fix: a degenerate job (no columns or no rows) has no well-defined
  -- flit sequence; catch it at the point it is accepted. Simulation-only; synthesis
  -- ignores it.
  degenerate : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '0' then
        assert not (go = '1' and (j_nb = 0 or j_rows = 0))
          report "mv_dist: go asserted with a degenerate job (j_nb=0 or j_rows=0)"
          severity failure;
      end if;
    end if;
  end process;

  p : process(clk)
    variable ntl0 : natural;
  begin
    if rising_edge(clk) then
      a_v <= '0';
      s_start <= '0';
      -- stage B: land the activation read, mask the pad columns
      b_v <= a_v; b_k <= a_k; b_f <= a_f; b_l <= a_l; b_s <= a_s;
      b_x <= (others => '0');
      if a_k = "00" then
        for j in 0 to BLK-1 loop
          if a_msk(j) = '1' then b_x(j*16+15 downto j*16) <= x_rdata(j*16+15 downto j*16); end if;
        end loop;
      else
        b_x(11 downto 0) <= a_pay;
      end if;
      -- stage A
      case st is
        when D_IDLE =>
          if go = '1' then
            nb_m1_r <= j_nb - 1; b <= 0; cbi <= 0;
            ntl0 := (j_rows + ROWS_IF - 1) / ROWS_IF;
            rtleft_r <= ntl0 - 1;
            os_r <= j_os; md_r <= j_mode; cb_r <= j_cb;
            for j in 0 to BLK-1 loop
              if j < j_lastv then lvm(j) <= '1'; else lvm(j) <= '0'; end if;
            end loop;
            s_start <= '1';
            st <= D_PAR;
          end if;
        when D_PAR =>
          if room_all = '1' then
            a_v <= '1'; a_k <= "10";
            a_pay <= "0000" & md_r & os_r;
            st <= D_CB;
          end if;
        when D_CB =>
          if room_all = '1' then
            a_v <= '1'; a_k <= "01";
            a_pay <= cb_r(cbi*8+7 downto cbi*8) & std_logic_vector(to_unsigned(cbi, 4));
            if cbi = 15 then st <= D_RUN; else cbi <= cbi + 1; end if;
          end if;
        when D_RUN =>
          if s_take = '1' then
            a_v <= '1'; a_k <= "00";
            for q in 0 to NPORTS_S-1 loop
              a_s((q+1)*AXI_DW-1 downto q*AXI_DW) <= qd(q);
            end loop;
            if b = 0 then a_f <= '1'; else a_f <= '0'; end if;
            if at_lastblk = '1' then
              a_l <= '1'; a_msk <= lvm; b <= 0;
              if at_lastrt = '1' then
                st <= D_IDLE;
              else
                rtleft_r <= rtleft_r - 1;
              end if;
            else
              a_l <= '0'; a_msk <= (others => '1'); b <= b + 1;
            end if;
          end if;
      end case;
      if rst = '1' then
        st <= D_IDLE; a_v <= '0'; b_v <= '0'; s_start <= '0';
      end if;
    end if;
  end process;

  o_v <= b_v; o_kind <= b_k; o_x <= b_x; o_s <= b_s; o_first <= b_f; o_last <= b_l;
end architecture;
