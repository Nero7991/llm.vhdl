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
begin
  dist : entity work.mv_dist
    generic map(BLK => BLK, ROWS_IF => ROWS_IF, NPORTS_S => NPORTS_S, AXI_DW => AXI_DW,
                ADDR_W => ADDR_W, DEPTH => FIFO_DEPTH, MAXB => MAXB, MAXOUT => MAXOUT,
                MAXCOLS => MAXCOLS)
    port map(clk => clk, rst => rst, go => go, j_nb => j_nb, j_rows => j_rows,
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
    port map(clk => clk, rst => rst, i_v => d_v, i_kind => d_k, i_x => d_x, i_s => d_s,
             i_first => d_f, i_last => d_l, o_v => l_v, o_kind => l_k, o_x => l_x,
             o_s => l_s, o_first => l_f, o_last => l_l, rooms => rooms,
             room_all => room_all);

  g_t : for p in 0 to NT-1 generate
    tile : entity work.mv_tile
      generic map(BLK => BLK, AXI_DW => AXI_DW, ADDR_W => ADDR_W, DEPTH => FIFO_DEPTH,
                  MAXB => MAXB, MAXOUT => MAXOUT, XD => XD, SLACK => SLACK, RD => 4)
      port map(clk => clk, rst => rst,
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
               r_v => own_v(p), r_d => own_d((p+1)*97-1 downto p*97), r_rdy => own_rdy(p));
  end generate;

  chain : entity work.mv_rchain
    generic map(NT => NT, W => 97)
    port map(clk => clk, rst => rst, own_v => own_v, own_d => own_d, own_rdy => own_rdy,
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
