-- sim/tb_mv_dist.vhd -- rtl/mv_dist.vhd + rtl/mv_xbcast.vhd + rtl/act_mem_dp.vhd.
--
-- What it proves: every one of the NT tiles receives exactly the flit sequence the a450
-- spec 2.2 defines, in order -- PARAM, 16 CB, then one ITEM per (row-tile, block) with
-- the activation block read through the dual-clock memory, every column at or past n_cols
-- zero, and that tile's own two scales from the 3-port scale superword -- and that the
-- room/credit loop never lets a tile FIFO of depth XD overflow, even with tile 0 stalled
-- for long stretches while the others drain.
--
-- The tiles are bench stubs: a level counter per tile (one arrival per flit, random pops,
-- long stalls on tile 0) and a registered room = level < XD - SLACK, which is
-- rtl/mv_tile.vhd's rule.  The expected flits are built here from the same random data
-- the bench writes into the activation memory and the three scale AXI models.
--
-- Clocks: the activation memory is written on wclk (125 MHz) and read on aclk (450 MHz).
-- Sweep the credit sizing by hand:  -gXD=24 -gSLACK=12 passes;  -gSLACK=3 must FAIL with
-- "overflow" (the slack no longer covers the 5 + 3 cycle loop).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_mv_dist is
  generic(
    XD    : positive := 32;
    SLACK : positive := 12
  );
end entity;

architecture sim of tb_mv_dist is
  constant NT   : positive := 24;
  constant BLK  : positive := 32;
  constant MAXC : positive := 1024;
  constant NBMX : positive := MAXC / BLK;
  constant XW   : positive := BLK*16;
  signal aclk, wclk : std_logic := '0';
  signal rst : std_logic := '1';
  signal done_sim : boolean := false;

  signal go : std_logic := '0';
  signal j_nb, j_rows, j_lastv : natural := 1;
  signal j_os : std_logic_vector(5 downto 0) := (others => '0');
  signal j_mode : std_logic_vector(1 downto 0) := "00";
  signal j_cb : std_logic_vector(127 downto 0) := (others => '0');
  signal s_beats : integer := 0;
  signal x_we : std_logic := '0';
  signal x_waddr : std_logic_vector(9 downto 0) := (others => '0');
  signal x_wdata : std_logic_vector(15 downto 0) := (others => '0');
  signal x_rbaddr : std_logic_vector(4 downto 0);
  signal x_rdata : std_logic_vector(XW-1 downto 0);
  signal arv, arr, rv, rr, rl : std_logic_vector(2 downto 0);
  signal ara : std_logic_vector(3*40-1 downto 0);
  signal arl : std_logic_vector(3*8-1 downto 0);
  signal ars : std_logic_vector(3*3-1 downto 0);
  signal arb : std_logic_vector(3*2-1 downto 0);
  signal rd  : std_logic_vector(3*256-1 downto 0);
  signal s_wr : std_logic := '0';
  signal s_wa : natural := 0;
  type s3_t is array(0 to 2) of std_logic_vector(255 downto 0);
  signal s_wd : s3_t := (others => (others => '0'));
  signal d_v, d_f, d_l : std_logic;
  signal d_k : std_logic_vector(1 downto 0);
  signal d_x : std_logic_vector(XW-1 downto 0);
  signal d_s : std_logic_vector(NT*32-1 downto 0);
  signal o_v, o_f, o_l : std_logic_vector(NT-1 downto 0);
  signal o_k : std_logic_vector(NT*2-1 downto 0);
  signal o_x : std_logic_vector(NT*XW-1 downto 0);
  signal o_s : std_logic_vector(NT*32-1 downto 0);
  signal rooms : std_logic_vector(NT-1 downto 0) := (others => '0');
  signal room_all, busy : std_logic;
begin
  aclk <= not aclk after 1.111 ns when not done_sim else '0';
  wclk <= not wclk after 4 ns when not done_sim else '0';

  xmem : entity work.act_mem_dp
    generic map(ELEMS => MAXC, BLK => BLK, W => 16)
    port map(wclk => wclk, we => x_we, waddr => x_waddr, wdata => x_wdata,
             rclk => aclk, rbaddr => x_rbaddr, rdata => x_rdata);

  dist : entity work.mv_dist
    generic map(BLK => BLK, ROWS_IF => 2*NT, NPORTS_S => 3, AXI_DW => 256, ADDR_W => 40,
                DEPTH => 64, MAXB => 16, MAXOUT => 16, MAXCOLS => MAXC)
    port map(clk => aclk, rst => rst, go => go, j_nb => j_nb, j_rows => j_rows,
             j_lastv => j_lastv, j_os => j_os, j_mode => j_mode, j_cb => j_cb,
             s_base => (others => '0'), s_beats => s_beats,
             x_rbaddr => x_rbaddr, x_rdata => x_rdata,
             m_arvalid => arv, m_arready => arr, m_araddr => ara, m_arlen => arl,
             m_arsize => ars, m_arburst => arb, m_rvalid => rv, m_rready => rr,
             m_rdata => rd, m_rlast => rl,
             o_v => d_v, o_kind => d_k, o_x => d_x, o_s => d_s, o_first => d_f,
             o_last => d_l, room_all => room_all, busy => busy);

  gm : for q in 0 to 2 generate
    sm : entity work.axi_rd_mem_model
      generic map(AXI_DW => 256, ADDR_W => 40, NWORDS => 256, SEED => 11 + q, GAPPCT => 20)
      port map(clk => aclk, rst => rst, arvalid => arv(q), arready => arr(q),
               araddr => ara(q*40+39 downto q*40), arlen => arl(q*8+7 downto q*8),
               rvalid => rv(q), rready => rr(q), rdata => rd(q*256+255 downto q*256),
               rlast => rl(q), wr_en => s_wr, wr_addr => s_wa, wr_data => s_wd(q));
  end generate;

  tree : entity work.mv_xbcast
    generic map(NT => NT, G => 6, XW => XW)
    port map(clk => aclk, rst => rst, i_v => d_v, i_kind => d_k, i_x => d_x, i_s => d_s,
             i_first => d_f, i_last => d_l, o_v => o_v, o_kind => o_k, o_x => o_x,
             o_s => o_s, o_first => o_f, o_last => o_l, rooms => rooms,
             room_all => room_all);

  run : process
    type xmem_t is array(0 to MAXC-1) of std_logic_vector(15 downto 0);
    type sm_t is array(0 to 255) of std_logic_vector(3*256-1 downto 0);
    type nat_arr is array(0 to NT-1) of natural;
    variable xm : xmem_t;
    variable sm : sm_t;
    variable got, lvl : nat_arr;
    variable rng : unsigned(31 downto 0) := x"C0FFEE11";
    variable cbv : std_logic_vector(127 downto 0);
    variable checks, fails, cyc, stall0 : natural := 0;
    variable ncols, nrows, nb, ntl, total, osv, mdv, lastv : natural;
    variable fi, t, bb : natural;
    variable ek : std_logic_vector(1 downto 0);
    variable ex : std_logic_vector(XW-1 downto 0);
    variable es : std_logic_vector(31 downto 0);
    variable ef, el : std_logic;
    variable allin : boolean;
    type job_t is record cols, rows, os, md : natural; end record;
    type jobs_t is array(0 to 5) of job_t;
    constant JOBS : jobs_t := ((96, 48, 3, 0), (100, 96, 40, 1), (31, 1, 0, 2),
                               (1024, 50, 7, 0), (33, 144, 12, 1), (257, 49, 0, 0));
    procedure rnd is
    begin
      rng := rng xor shift_left(rng, 13);
      rng := rng xor shift_right(rng, 17);
      rng := rng xor shift_left(rng, 5);
    end procedure;
    procedure chk(c : boolean; msg : string) is
    begin
      checks := checks + 1;
      if not c then
        fails := fails + 1;
        report "tb_mv_dist: MISMATCH " & msg severity error;
      end if;
    end procedure;
  begin
    rst <= '1';
    for i in 1 to 10 loop wait until rising_edge(aclk); end loop;
    rst <= '0';
    for jb in JOBS'range loop
      ncols := JOBS(jb).cols; nrows := JOBS(jb).rows;
      osv := JOBS(jb).os; mdv := JOBS(jb).md;
      nb := (ncols + BLK - 1) / BLK;
      ntl := (nrows + 2*NT - 1) / (2*NT);
      lastv := ncols - (nb - 1) * BLK;
      total := 17 + ntl * nb;
      -- activations: every element of the memory, so stale columns are nonzero
      for k in 0 to MAXC-1 loop
        rnd;
        xm(k) := std_logic_vector(rng(15 downto 0));
        x_we <= '1'; x_waddr <= std_logic_vector(to_unsigned(k, 10)); x_wdata <= xm(k);
        wait until rising_edge(wclk);
      end loop;
      x_we <= '0';
      -- scales, one superword per (row-tile, block)
      for i in 0 to ntl * nb - 1 loop
        for q in 0 to 2 loop
          for w in 0 to 7 loop
            rnd;
            sm(i)(q*256 + w*32 + 31 downto q*256 + w*32) := std_logic_vector(rng);
          end loop;
          s_wd(q) <= sm(i)(q*256 + 255 downto q*256);
        end loop;
        s_wr <= '1'; s_wa <= i;
        wait until rising_edge(aclk);
      end loop;
      s_wr <= '0';
      for e in 0 to 15 loop
        rnd; cbv(e*8+7 downto e*8) := std_logic_vector(rng(7 downto 0));
      end loop;
      j_nb <= nb; j_rows <= nrows; j_lastv <= lastv;
      j_os <= std_logic_vector(to_unsigned(osv, 6));
      j_mode <= std_logic_vector(to_unsigned(mdv, 2));
      j_cb <= cbv; s_beats <= ntl * nb;
      for t2 in 0 to NT-1 loop got(t2) := 0; end loop;
      wait until rising_edge(aclk);
      go <= '1';
      wait until rising_edge(aclk);
      go <= '0';
      cyc := 0;
      loop
        -- leaves: arrivals are checked against the expected sequence
        for t2 in 0 to NT-1 loop
          if o_v(t2) = '1' then
            fi := got(t2);
            chk(fi < total, "tile " & integer'image(t2) & " got more than " & integer'image(total) & " flits");
            if fi < total then
              ex := (others => '0'); es := (others => '0'); ef := '0'; el := '0';
              if fi = 0 then
                ek := "10";
                ex(5 downto 0) := std_logic_vector(to_unsigned(osv, 6));
                ex(7 downto 6) := std_logic_vector(to_unsigned(mdv, 2));
              elsif fi <= 16 then
                ek := "01";
                ex(3 downto 0) := std_logic_vector(to_unsigned(fi - 1, 4));
                ex(11 downto 4) := cbv((fi-1)*8+7 downto (fi-1)*8);
              else
                ek := "00";
                t := (fi - 17) / nb; bb := (fi - 17) mod nb;
                for j in 0 to BLK-1 loop
                  if bb*BLK + j < ncols then ex(j*16+15 downto j*16) := xm(bb*BLK + j); end if;
                end loop;
                es := sm(fi - 17)(t2*32 + 31 downto t2*32);
                if bb = 0 then ef := '1'; end if;
                if bb = nb - 1 then el := '1'; end if;
              end if;
              -- s, first and last are don't-care on PARAM and CB flits (mv_tile ignores them)
              chk(o_k(t2*2+1 downto t2*2) = ek and o_x((t2+1)*XW-1 downto t2*XW) = ex
                  and (ek /= "00" or (o_s(t2*32+31 downto t2*32) = es
                                      and o_f(t2) = ef and o_l(t2) = el)),
                  "job " & integer'image(jb) & " tile " & integer'image(t2) & " k=" & to_hstring(o_k(t2*2+1 downto t2*2)) & " x=" & to_hstring(o_x(t2*XW+15 downto t2*XW)) & " ex=" & to_hstring(ex(15 downto 0)) & " s=" & to_hstring(o_s(t2*32+31 downto t2*32)) & " es=" & to_hstring(es) & " fl=" & std_logic'image(o_f(t2)) & std_logic'image(o_l(t2)) & " flit "
                  & integer'image(fi));
            end if;
            got(t2) := fi + 1;
            lvl(t2) := lvl(t2) + 1;
            assert lvl(t2) <= XD report "tb_mv_dist: tile " & integer'image(t2)
              & " flit FIFO overflow (level " & integer'image(lvl(t2)) & " > XD)" severity failure;
          end if;
        end loop;
        -- leaves: random pops, tile 0 stalls in long runs
        rnd;
        if stall0 > 0 then stall0 := stall0 - 1;
        elsif to_integer(rng(9 downto 0)) < 8 then stall0 := 150; end if;
        for t2 in 0 to NT-1 loop
          rnd;
          if lvl(t2) > 0 and to_integer(rng(6 downto 0)) mod 4 /= 0
             and not (t2 = 0 and stall0 > 0) then
            lvl(t2) := lvl(t2) - 1;
          end if;
          if lvl(t2) < XD - SLACK then rooms(t2) <= '1'; else rooms(t2) <= '0'; end if;
        end loop;
        allin := true;
        for t2 in 0 to NT-1 loop
          if got(t2) /= total then allin := false; end if;
        end loop;
        exit when allin and busy = '0';
        cyc := cyc + 1;
        assert cyc < 100000 report "tb_mv_dist: job " & integer'image(jb) & " timed out"
          severity failure;
        wait until rising_edge(aclk);
      end loop;
      -- nothing more may arrive
      for i in 1 to 40 loop
        wait until rising_edge(aclk);
        chk(o_v = (o_v'range => '0'), "a flit after the job's last");
      end loop;
    end loop;
    assert fails = 0 report "tb_mv_dist: FAIL " & integer'image(fails) severity failure;
    report "PASS: tb_mv_dist checks=" & integer'image(checks) severity note;
    done_sim <= true;
    wait;
  end process;
end architecture;
