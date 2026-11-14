-- rtl/mv4i_tcore.vhd -- the body of rtl/mv4i_tiled.vhd, with clk_core (`clk`) and
-- aclk_a as two ports.  mv4i_tiled ties aclk_a to clk or to its `aclk` (A_CLK_SPLIT).
--
--   clk     mv_back (checks, codebook, assembly, ybuf, emit), the x write port
--   aclk_a  mv_afast (distributor, trees, tiles, chain), the x read port
--   crossings: j_go by mv_tsync; the result words by mv_rcross; x by act_mem_dp.
--   The j_* values and the bases/beats are held by the back end from the start pulse
--   to the next start, so aclk_a reads them only after j_go has crossed: they need a
--   set_max_delay -datapath_only of one aclk_a period, not a synchroniser.  The card's
--   timing Tcl applies it (plan Task 9, a450_cdc.tcl).
--
-- RESETS.  One source, `rst` (clk).  aclk_a's reset ar2 is rst through two flops.  The
-- start crossing (mv_tsync) is reset from that same source on both sides: srst = rst,
-- drst = ar_ts = ar2 or ar3, ar2 stretched by one aclk_a cycle.  ar1 is the first
-- ASYNC_REG stage and feeds nothing but ar2 (review fix: ar_ts read ar1 before, a CDC
-- violation).  The stretch is load bearing: a reset clears the source toggle, which is
-- itself a toggle edge whenever an odd number of starts preceded it, and the detector
-- fires on it three aclk_a edges after the edge at which s1 first samples it.  rst
-- reaches ar1 and tog reaches s1 by two INDEPENDENT asynchronous paths, so in SPLIT
-- either may land one aclk_a edge before the other; nothing orders them.  For a
-- one-cycle rst, ar2 alone deasserts on exactly the edge the phantom start fires when
-- tog's path is the slower one: zero edges of margin (and a phantom replays the last
-- job into the tiles).  ar3 adds ONE edge of margin, no more: it covers the worst
-- relative landing of the two paths by one aclk_a edge.  MARGIN ON THE OTHER SIDE: the
-- first start the back end can issue after a reset (start sampled one clk edge after
-- rst falls) is detected at the fifth clk edge; with aclk_a = clk (SAME) ar_ts is
-- deasserted at that edge with zero edges to spare, so ar_ts must not be stretched
-- further; in SPLIT (aclk_a 3.6x clk) the spare is several aclk_a edges.  Proven by
-- tb_mv4i_tiled's one-cycle reset before job 16; mutant R1 (drst = ar2) removes the
-- one edge and is killed.
--
-- The result crossing (mv_rcross, an async_fifo) needs the same care in both directions:
-- each side clears its own pointers AND its synchronised copy of the other side's, so a
-- side that leaves reset while the other still holds its old pointer reloads that old
-- pointer and replays stale words.  MEASURED on the first run of tb_mv4i_tiled with
-- rrst = rst and wrst = ar2: the one-cycle reset before job 16 left SAME's crossing
-- almost-full for 866 of the next 870 cycles and all 10 beats of job 16 wrong (stale
-- words of job 15 in front).  So wrst = ar_ts (zeroes the write pointer three aclk_a
-- edges after rst rises, while the read side is already in reset), and the read side's reset
-- rrst_x = rst or rr_hold, where rr_hold is set by rst and cleared only after ar_ts,
-- synchronised back into clk (wr1, wr2), has been seen to rise and then fall.  The read
-- side therefore leaves reset with the write pointer already zero and synchronised.  It
-- costs nothing: no result reaches the crossing within the few cycles of the hold, and
-- the back end's own reset is plain rst, so start acceptance is unchanged.  Mutant X1
-- restores rrst = rst.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity mv4i_tcore is
  generic(
    BLK, ROWS_IF, NPORTS_W, NPORTS_S, AXI_DW, ADDR_W, MAXCOLS, MAXROWS_BFP,
    FIFO_DEPTH, MAXB, MAXOUT, XD, G : positive
  );
  port(
    clk, rst, aclk_a, start : in std_logic;
    n_rows, n_cols, out_shift, w_exp, x_exp : in std_logic_vector(31 downto 0);
    out_mode : in std_logic_vector(1 downto 0);
    w_base : in std_logic_vector(NPORTS_W*ADDR_W-1 downto 0);
    w_beats : in std_logic_vector(31 downto 0);
    s_base : in std_logic_vector(NPORTS_S*ADDR_W-1 downto 0);
    s_beats : in std_logic_vector(31 downto 0);
    cb_we : in std_logic;
    cb_addr : in std_logic_vector(3 downto 0);
    cb_data : in std_logic_vector(7 downto 0);
    x_we : in std_logic;
    x_waddr, x_wdata : in std_logic_vector(15 downto 0);
    m_arvalid : out std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
    m_arready : in std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
    m_araddr : out std_logic_vector((NPORTS_W+NPORTS_S)*ADDR_W-1 downto 0);
    m_arlen : out std_logic_vector((NPORTS_W+NPORTS_S)*8-1 downto 0);
    m_arsize : out std_logic_vector((NPORTS_W+NPORTS_S)*3-1 downto 0);
    m_arburst : out std_logic_vector((NPORTS_W+NPORTS_S)*2-1 downto 0);
    m_rvalid : in std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
    m_rready : out std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
    m_rdata : in std_logic_vector((NPORTS_W+NPORTS_S)*AXI_DW-1 downto 0);
    m_rlast : in std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
    y_we : out std_logic;
    y_addr : out std_logic_vector(15 downto 0);
    y_data : out std_logic_vector(ROWS_IF*64-1 downto 0);
    y_mask : out std_logic_vector(ROWS_IF-1 downto 0);
    y_exp : out std_logic_vector(31 downto 0);
    done, err, sat_event : out std_logic;
    dbg_rtile : out std_logic;
    dbg_words : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of mv4i_tcore is
  constant XA : positive := clog2(MAXCOLS);
  constant XB : positive := clog2((MAXCOLS + BLK - 1) / BLK);
  signal ar1, ar2, ar3, ar_ts : std_logic := '1';
  signal wr1, wr2, rr_hold : std_logic := '1';
  signal rr_seen, rrst_x : std_logic := '0';
  attribute async_reg : string;
  attribute async_reg of ar1 : signal is "TRUE";
  attribute async_reg of ar2 : signal is "TRUE";
  attribute async_reg of ar3 : signal is "TRUE";
  attribute async_reg of wr1 : signal is "TRUE";
  attribute async_reg of wr2 : signal is "TRUE";
  signal i_rows, i_cols, i_osh, i_wexp, i_xexp, i_yexp, i_wb, i_sb : integer := 0;
  signal j_go, a_go : std_logic;
  signal j_nb, j_rows, j_lastv : natural;
  signal j_os : std_logic_vector(5 downto 0);
  signal j_mode : std_logic_vector(1 downto 0);
  signal j_cb : std_logic_vector(127 downto 0);
  signal xr_baddr : std_logic_vector(XB-1 downto 0);
  signal x_rdata : std_logic_vector(BLK*16-1 downto 0);
  signal res_v, res_af, q_v, q_r : std_logic;
  signal res_d, q_d : std_logic_vector(96 downto 0);
  signal i_words : natural;
begin
  dbg_words <= std_logic_vector(to_unsigned(i_words, 32));
  i_rows <= to_integer(signed(n_rows));
  i_cols <= to_integer(signed(n_cols));
  i_osh  <= to_integer(signed(out_shift));
  i_wexp <= to_integer(signed(w_exp));
  i_xexp <= to_integer(signed(x_exp));
  i_wb   <= to_integer(signed(w_beats));
  i_sb   <= to_integer(signed(s_beats));
  y_exp  <= std_logic_vector(to_signed(i_yexp, 32));

  -- aclk_a's reset: rst through two flops
  arst : process(aclk_a)
  begin
    if rising_edge(aclk_a) then
      ar1 <= rst; ar2 <= ar1; ar3 <= ar2;
      ar_ts <= ar2 or ar3;
    end if;
  end process;

  -- the crossing's read-side reset: rst, held until aclk_a's reset has come and gone
  rrst : process(clk)
  begin
    if rising_edge(clk) then
      wr1 <= ar_ts; wr2 <= wr1;
      if rst = '1' then
        rr_hold <= '1'; rr_seen <= '0';
      elsif rr_hold = '1' then
        if wr2 = '1' then rr_seen <= '1';
        elsif rr_seen = '1' then rr_hold <= '0';
        end if;
      end if;
    end if;
  end process;
  rrst_x <= rst or rr_hold;

  back : entity work.mv_back
    generic map(BLK => BLK, ROWS_IF => ROWS_IF, MAXCOLS => MAXCOLS, MAXROWS_BFP => MAXROWS_BFP)
    port map(clk => clk, rst => rst, start => start, n_rows => i_rows, n_cols => i_cols,
             out_shift => i_osh, w_exp => i_wexp, x_exp => i_xexp, out_mode => out_mode,
             cb_we => cb_we, cb_addr => cb_addr, cb_data => cb_data,
             j_go => j_go, j_nb => j_nb, j_rows => j_rows, j_lastv => j_lastv,
             j_os => j_os, j_mode => j_mode, j_cb => j_cb,
             q_valid => q_v, q_data => q_d, q_ready => q_r,
             y_we => y_we, y_addr => y_addr, y_data => y_data, y_mask => y_mask,
             y_exp => i_yexp, done => done, err => err, sat_event => sat_event,
             w_beat => dbg_rtile, w_words => i_words);

  gosync : entity work.mv_tsync
    port map(sclk => clk, srst => rst, s_pulse => j_go, dclk => aclk_a, drst => ar_ts,
             d_pulse => a_go);

  xmem : entity work.act_mem_dp
    generic map(ELEMS => MAXCOLS, BLK => BLK, W => 16)
    port map(wclk => clk, we => x_we, waddr => x_waddr(XA-1 downto 0), wdata => x_wdata,
             rclk => aclk_a, rbaddr => xr_baddr, rdata => x_rdata);

  fast : entity work.mv_afast
    generic map(BLK => BLK, ROWS_IF => ROWS_IF, NPORTS_W => NPORTS_W, NPORTS_S => NPORTS_S,
                AXI_DW => AXI_DW, ADDR_W => ADDR_W, MAXCOLS => MAXCOLS,
                FIFO_DEPTH => FIFO_DEPTH, MAXB => MAXB, MAXOUT => MAXOUT, XD => XD, G => G)
    port map(clk => aclk_a, rst => ar2, go => a_go, j_nb => j_nb, j_rows => j_rows,
             j_lastv => j_lastv, j_os => j_os, j_mode => j_mode, j_cb => j_cb,
             w_base => w_base, w_beats => i_wb, s_base => s_base, s_beats => i_sb,
             x_rbaddr => xr_baddr, x_rdata => x_rdata,
             m_arvalid => m_arvalid, m_arready => m_arready, m_araddr => m_araddr,
             m_arlen => m_arlen, m_arsize => m_arsize, m_arburst => m_arburst,
             m_rvalid => m_rvalid, m_rready => m_rready, m_rdata => m_rdata,
             m_rlast => m_rlast, res_v => res_v, res_d => res_d, res_afull => res_af);

  cross : entity work.mv_rcross
    generic map(W => 97, DEPTH => 16)
    port map(wclk => aclk_a, wrst => ar_ts, w_v => res_v, w_d => res_d, w_afull => res_af,
             rclk => clk, rrst => rrst_x, q_valid => q_v, q_data => q_d, q_ready => q_r);
end architecture;
