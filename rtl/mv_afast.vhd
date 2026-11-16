-- rtl/mv_afast.vhd -- everything of the a450 subsystem A that runs in aclk_a (spec 1.1):
-- the distributor and its NPORTS_S scale ports, the distribution and room trees, NT =
-- NPORTS_W tiles (one per weight port) and the result chain.  Single clock, so it is the
-- unit the A-composed block rating (hw/targets/blocks.json a450_afast) times at 2.222 ns.
--
-- SLACK, THE CREDIT SIZE, IS DERIVED HERE AND NOWHERE ELSE.  A flit decided in mv_dist
-- stage A reaches a tile's FIFO LF = 2 + 3 cycles later (dist A, B; tree root, mid, leaf);
-- a tile's level change reaches stage A LR = 1 + 2 cycles later (tile room register; mid
-- and root AND).  Everything sent in that LF + LR window lands after room fell, so the
-- tile withdraws room at XD - SLACK with SLACK = LF + LR + 4 (4 of margin).
-- sim/tb_mv_dist.vhd measures the loop: SLACK = 3 overflows, 8 does not.
--
-- RESET TREE (a450 Task 7b).  `rst` (mv4i_tcore's ar2) reaches no logic directly; it
-- drives only registers.  The distributor and the distribution tree get it through one
-- register (rst_d, dont_touch; fix round 1, Task 7b gate run 3 MEASURED ar2 at fanout 265
-- as the worst path while it still drove them).  The tiles and the chain get it through
-- two: NT/G mid registers (rst_m, dont_touch, one per tile group of G, G loads each), then
-- one local register inside each tile (mv_tile rst_l), which also resets that tile's chain
-- link (mv_tile rst_o -> mv_rchain rst(k)).  ar2 thus has NT/G + 1 loads here, plus ar3
-- and ar_ts in mv4i_tcore.  Task 7 MEASURED ar2 driving everything at fanout 3,611.
-- Why the delays are safe (ar2 high for cycles [t, t+L), L >= 1; E_k is the edge that
-- ends cycle k, the edge at which a synchronous reset seen in cycle k acts):
--   * dist and tree are in reset for [t+1, t+L+1); tiles and links for [t+2, t+L+2);
--     mv4i_tcore's ar_ts (the start crossing's destination reset and the result
--     crossing's write-side reset) for [t+1, t+L+2).  Tiles, links and ar_ts deassert
--     together (last reset edge E_{t+L+1}).  Over [t+1, t+L+2) the crossing discards every
--     write (async_fifo wr_now needs wrst = '0') and holds afull, so a link emitting a
--     stale word before its own reset lands cannot put it into the crossing; from t+L+2
--     on the links are clear.  MARGIN (fix round 1, MEASURED): the crossing's registered
--     afull is '1' in every cycle of [t+2, t+L+3) (set during wrst, released one edge
--     after), so link 0 cannot take a word before cycle t+L+3.  With D registers from ar2
--     to a link (D = 2 here) the link's first reset edge is E_{t+D}; a stale word escapes
--     only if link 0 can take in a cycle of [t+L+3, t+D), so the tree is safe for
--     D <= L + 3, i.e. up to two more stages even for a one-cycle reset.  Mutants S3
--     (D = 3) and S4 (D = 4) survive tb_mv4i_tiled's job 17 (a one-cycle reset in SAME while
--     the chain holds words); S5 (D = 5) is killed there.
--   * the first go after a reset reaches mv_dist no earlier than cycle t+L+2 (mv_tsync's
--     destination is reset by ar_ts, last reset edge E_{t+L+1}); dist left reset at
--     E_{t+L} (its last reset edge), so it is idle and ready a cycle before.  In SAME the
--     first start after a reset arrives with zero edges to spare against ar_ts
--     (mv4i_tcore's RESETS header); dist's one-cycle earlier exit keeps one edge of its
--     own.  The go's first flit reaches a tile's FIFO at least D_SET1 + D_SET2 + D_PAR + LF
--     cycles later, long after the tiles left reset at t+L+2.
--   * stale flits: dist's stage registers and the tree's valids are cleared at E_{t+1}, so
--     the last flit a tile can receive is written at E_{t+1}; the tile's first reset edge
--     is E_{t+2}, which clears it.  After E_{t+1} dist is idle (st = D_IDLE) and emits
--     nothing until a new go.  A port_start popped before the tile reset cannot issue an AR
--     before it lands (mv_rdfsm needs S_DRAIN, S_CLR, S_CLR2 and its hold first), and
--     every burst accepted before the reset is drained after it (mv_rdfsm `owed`).
-- rtl/mv4i_tcore.vhd's ar1/ar2/ar3/ar_ts are not changed.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;
-- synthesis translate_off
use std.textio.all;
-- synthesis translate_on

entity mv_afast is
  generic(
    BLK        : positive := 32;
    ROWS_IF    : positive := 48;
    NPORTS_W   : positive := 24;
    NPORTS_S   : positive := 3;
    AXI_DW     : positive := 256;
    ADDR_W     : positive := 40;
    MAXCOLS    : positive := 17408;
    FIFO_DEPTH : positive := 512;
    MAXB       : positive := 16;
    MAXOUT     : positive := 16;
    XD         : positive := 32;
    G          : positive := 6
  );
  port(
    clk, rst  : in  std_logic;
    -- the HBM AXI port reset, synchronous to clk, active high (a450 Task 8, carry C1):
    -- registered here per tile group and for the distributor, as rst is, then clears
    -- every port's owed-burst count (rtl/mv_rdfsm.vhd)
    hbm_rst   : in  std_logic := '0';
    go        : in  std_logic;
    j_nb      : in  natural;
    j_rows    : in  natural;
    j_lastv   : in  natural;
    j_os      : in  std_logic_vector(5 downto 0);
    j_mode    : in  std_logic_vector(1 downto 0);
    j_cb      : in  std_logic_vector(127 downto 0);
    w_base    : in  std_logic_vector(NPORTS_W*ADDR_W-1 downto 0);
    w_beats   : in  integer;
    s_base    : in  std_logic_vector(NPORTS_S*ADDR_W-1 downto 0);
    s_beats   : in  integer;
    x_rbaddr  : out std_logic_vector(clog2((MAXCOLS+BLK-1)/BLK)-1 downto 0);
    x_rdata   : in  std_logic_vector(BLK*16-1 downto 0);
    m_arvalid : out std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
    m_arready : in  std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
    m_araddr  : out std_logic_vector((NPORTS_W+NPORTS_S)*ADDR_W-1 downto 0);
    m_arlen   : out std_logic_vector((NPORTS_W+NPORTS_S)*8-1 downto 0);
    m_arsize  : out std_logic_vector((NPORTS_W+NPORTS_S)*3-1 downto 0);
    m_arburst : out std_logic_vector((NPORTS_W+NPORTS_S)*2-1 downto 0);
    m_rvalid  : in  std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
    m_rready  : out std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
    m_rdata   : in  std_logic_vector((NPORTS_W+NPORTS_S)*AXI_DW-1 downto 0);
    m_rlast   : in  std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
    res_v     : out std_logic;
    res_d     : out std_logic_vector(96 downto 0);
    res_afull : in  std_logic
  );
end entity;

architecture rtl of mv_afast is
  constant NT    : positive := NPORTS_W;
  constant XW    : positive := BLK*16;
  constant LF    : positive := 5;
  constant LR    : positive := 3;
  constant SLACK : positive := LF + LR + 4;
  -- ROWS_IF must be two rows per weight port (lane split 6.5a at AXI_DW = 256)
  constant CHK_ROWS : natural := 1 - abs(ROWS_IF - 2*NT);
  signal d_v, d_f, d_l : std_logic;
  signal d_k : std_logic_vector(1 downto 0);
  signal d_x : std_logic_vector(XW-1 downto 0);
  signal d_s : std_logic_vector(ROWS_IF*16-1 downto 0);
  signal l_v, l_f, l_l, rooms : std_logic_vector(NT-1 downto 0);
  signal l_k : std_logic_vector(NT*2-1 downto 0);
  signal l_x : std_logic_vector(NT*XW-1 downto 0);
  signal l_s : std_logic_vector(NT*32-1 downto 0);
  signal room_all, busy : std_logic;
  signal own_v, own_rdy : std_logic_vector(NT-1 downto 0);
  signal own_d : std_logic_vector(NT*97-1 downto 0);
  -- the reset tree (see RESET TREE above): mid registers, then the tiles' own
  constant NRM : positive := NT / G;
  signal rst_m : std_logic_vector(NRM-1 downto 0) := (others => '1');
  signal rst_t : std_logic_vector(NT-1 downto 0);
  attribute dont_touch : string;
  attribute dont_touch of rst_m : signal is "true";
  signal rst_d : std_logic := '1';          -- dist and tree
  attribute dont_touch of rst_d : signal is "true";
  -- hbm_rst through the same shape of mid registers (latency is free: see mv_rdfsm's owed)
  signal hbm_m : std_logic_vector(NRM-1 downto 0) := (others => '1');
  attribute dont_touch of hbm_m : signal is "true";
  signal hbm_d : std_logic := '1';
  attribute dont_touch of hbm_d : signal is "true";
begin
  rmid : process(clk)
  begin
    if rising_edge(clk) then
      rst_m <= (others => rst); rst_d <= rst;
      hbm_m <= (others => hbm_rst); hbm_d <= hbm_rst;
    end if;
  end process;

  dist : entity work.mv_dist
    generic map(BLK => BLK, ROWS_IF => ROWS_IF, NPORTS_S => NPORTS_S, AXI_DW => AXI_DW,
                ADDR_W => ADDR_W, DEPTH => FIFO_DEPTH, MAXB => MAXB, MAXOUT => MAXOUT,
                MAXCOLS => MAXCOLS)
    port map(clk => clk, rst => rst_d, hbm_rst => hbm_d, go => go, j_nb => j_nb,
             j_rows => j_rows,
             j_lastv => j_lastv, j_os => j_os, j_mode => j_mode, j_cb => j_cb,
             s_base => s_base, s_beats => s_beats, x_rbaddr => x_rbaddr, x_rdata => x_rdata,
             m_arvalid => m_arvalid(NT+NPORTS_S-1 downto NT),
             m_arready => m_arready(NT+NPORTS_S-1 downto NT),
             m_araddr  => m_araddr((NT+NPORTS_S)*ADDR_W-1 downto NT*ADDR_W),
             m_arlen   => m_arlen((NT+NPORTS_S)*8-1 downto NT*8),
             m_arsize  => m_arsize((NT+NPORTS_S)*3-1 downto NT*3),
             m_arburst => m_arburst((NT+NPORTS_S)*2-1 downto NT*2),
             m_rvalid  => m_rvalid(NT+NPORTS_S-1 downto NT),
             m_rready  => m_rready(NT+NPORTS_S-1 downto NT),
             m_rdata   => m_rdata((NT+NPORTS_S)*AXI_DW-1 downto NT*AXI_DW),
             m_rlast   => m_rlast(NT+NPORTS_S-1 downto NT),
             o_v => d_v, o_kind => d_k, o_x => d_x, o_s => d_s, o_first => d_f,
             o_last => d_l, room_all => room_all, busy => busy);

  tree : entity work.mv_xbcast
    generic map(NT => NT, G => G, XW => XW)
    port map(clk => clk, rst => rst_d, i_v => d_v, i_kind => d_k, i_x => d_x, i_s => d_s,
             i_first => d_f, i_last => d_l, o_v => l_v, o_kind => l_k, o_x => l_x,
             o_s => l_s, o_first => l_f, o_last => l_l, rooms => rooms,
             room_all => room_all);

  g_t : for p in 0 to NT-1 generate
    tile : entity work.mv_tile
      generic map(BLK => BLK, AXI_DW => AXI_DW, ADDR_W => ADDR_W, DEPTH => FIFO_DEPTH,
                  MAXB => MAXB, MAXOUT => MAXOUT, XD => XD, SLACK => SLACK, RD => 4)
      port map(clk => clk, rst => rst_m(p / G), hbm_rst => hbm_m(p / G),
               w_base => w_base((p+1)*ADDR_W-1 downto p*ADDR_W), w_beats => w_beats,
               arvalid => m_arvalid(p), arready => m_arready(p),
               araddr => m_araddr((p+1)*ADDR_W-1 downto p*ADDR_W),
               arlen => m_arlen((p+1)*8-1 downto p*8),
               arsize => m_arsize((p+1)*3-1 downto p*3),
               arburst => m_arburst((p+1)*2-1 downto p*2),
               rvalid => m_rvalid(p), rready => m_rready(p),
               rdata => m_rdata((p+1)*AXI_DW-1 downto p*AXI_DW), rlast => m_rlast(p),
               f_v => l_v(p), f_kind => l_k(p*2+1 downto p*2),
               f_x => l_x((p+1)*XW-1 downto p*XW), f_s => l_s(p*32+31 downto p*32),
               f_first => l_f(p), f_last => l_l(p), room => rooms(p),
               r_v => own_v(p), r_d => own_d((p+1)*97-1 downto p*97), r_rdy => own_rdy(p),
               rst_o => rst_t(p));
  end generate;

  chain : entity work.mv_rchain
    generic map(NT => NT, W => 97)
    port map(clk => clk, rst => rst_t, own_v => own_v, own_d => own_d, own_rdy => own_rdy,
             d_v => res_v, d_d => res_d, d_afull => res_afull);

  -- synthesis translate_off
  -- RESULT-WAIT AND ROOM MONITOR (simulation only; a450 Task 6 ruling 4).  Per tile, per
  -- job (reported at the next go or at a reset, for the interval since the previous
  -- report):
  --   bp    cycles a FINISHED result waited at the head of the tile's RD-deep result FIFO
  --         for the chain (own_v and not own_rdy).  This is result-wait telemetry, NOT a
  --         tile stall: the tile keeps computing until outst reaches RD, and only a lost
  --         room (below) can hold the distributor.
  --   room  cycles the tile's own room was '0' (the only way a tile holds every tile),
  -- and, for the whole fast side, `held`: cycles the distributor was busy with room_all
  -- '0' (every tile held), and `tail`: cycles the crossing's almost-full held the chain.
  stallmon : process(clk)
    type cnt_a is array(0 to NT-1) of natural;
    variable bp, rl : cnt_a := (others => 0);
    variable held, tail, cyc : natural := 0;
    variable rst_q : std_logic := '0';
    variable lb, lrm : line;
    function img(n : natural) return string is
    begin
      return integer'image(n);
    end function;
  begin
    if rising_edge(clk) then
      if go = '1' or (rst = '1' and rst_q = '0') then
        if cyc > 0 then
          report "mv_afast stall " & stallmon'path_name & " cycles " & img(cyc)
               & " held " & img(held) & " tail " & img(tail) severity note;
          for p in 0 to NT-1 loop
            write(lb, " " & img(bp(p)));
            write(lrm, " " & img(rl(p)));
          end loop;
          report "mv_afast stall bp(tile 0..) " & lb.all severity note;
          report "mv_afast stall room0(tile 0..) " & lrm.all severity note;
          deallocate(lb); deallocate(lrm);
        end if;
        bp := (others => 0); rl := (others => 0); held := 0; tail := 0; cyc := 0;
      elsif rst = '0' then
        cyc := cyc + 1;
        for p in 0 to NT-1 loop
          if own_v(p) = '1' and own_rdy(p) = '0' then bp(p) := bp(p) + 1; end if;
          if rooms(p) = '0' then rl(p) := rl(p) + 1; end if;
        end loop;
        if busy = '1' and room_all = '0' then held := held + 1; end if;
        if res_afull = '1' then tail := tail + 1; end if;
      end if;
      rst_q := rst;
    end if;
  end process;
  -- synthesis translate_on
end architecture;
