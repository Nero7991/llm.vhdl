-- sim/tb_mv4i_tiled.vhd -- the a450 composed-A equivalence bench (spec 3.1).
--
-- Three DUTs see the same jobs, the same weights, scales, activations and codebook:
--   OLD   rtl/matvec_int4.vhd at the JC geometry (ROWS_IF 48, 24+3 ports, 256-bit), the
--         design proven bit-exact on silicon, on clk (125 MHz)
--   SPLIT rtl/mv4i_tiled.vhd, A_CLK_SPLIT = true: tiles on aclk (450 MHz, rolling phase
--         against clk because 8 / 2.222 is not an integer)
--   SAME  rtl/mv4i_tiled.vhd, A_CLK_SPLIT = false: everything on clk
-- and every y beat (y_addr, y_data, y_mask, y_exp), and err, sat_event and y_exp at done,
-- must be IDENTICAL across the three, beat by beat, for every job.  Each DUT has its own
-- 27 AXI read models with their own random RVALID gaps; on SPLIT, weight ports 0 and 13
-- and scale port 1 (index 25) also stall for 300-cycle stretches, so tiles drift, tile
-- credits run out, and every tile starves at once.
--
-- Jobs: all three out modes, pad rows (n_rows not a multiple of 48), pad columns (n_cols
-- not a multiple of 32, with nonzero junk written past n_cols), a codebook over the
-- full int8 range (-128 included: the cascade's 28-bit wrap must equal the old tree's),
-- out_shift 0 and 40, a saturating job (raw: sat_event 1; partial: 0), three refused
-- descriptors (err), and a job after them (err and sat cleared).  Then the plan's Review
-- Focus cases: a raw job with n_rows above MAXROWS_BFP and one block per row (the LM-head
-- shape, and the crossing fills because tiles finish row-tiles faster than clk drains
-- them), the same weights with only the codebook changed, and a reset pulsed in the
-- middle of a job followed by a compared job.  Last, a raw job of 200 items per tile:
-- every earlier job fits in the 64-beat weight FIFO and in a tile's 32-deep flit FIFO,
-- so only this one makes a stalled port stop its tile while the others run on, which is
-- what the credit loop exists for (without it the credit-loss mutant C1 SURVIVED).
--
-- a450 Task 6 additions (rulings carried from Tasks 4 and 5):
--   * job 16 is preceded by a ONE-cycle reset pulse at idle, after an odd number of
--     starts since the mid-job reset, so rtl/mv_tsync.vhd's toggle falls 1 -> 0 under
--     reset.  If the start crossing's destination reset does not outlast that edge, the
--     fast side starts a phantom job and job 16 dies (tile `serialize` assertion, or
--     misaligned words).  Mutant R1 in sim/mutants/mv4i_tiled.json removes the cover.
--   * after the last job a final reset makes rtl/mv_afast.vhd's simulation-only stall
--     monitor print the last job's counts (it reports at each go and at each reset).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_mv4i_tiled is
  generic(
    -- a450 Task 7b fix round 1.  The two NEW DUTs' 54 memory models are reset only at
    -- power-on (`por`), like the card's HBM, which A's reset does not reach: bursts they
    -- accepted before a reset are still delivered after it (rtl/mv_rdfsm.vhd `owed`).
    -- (Before fix round 1 they were reset with `rst` and silently dropped those bursts, a
    -- memory the card does not have.)  HOLD_OWED = true additionally holds back their R
    -- beats from the mid-job reset (job 14) until 20 clk cycles after the next start, so
    -- the bursts job 14 left owed arrive after job 15 has started.  The OLD reference's
    -- models keep resetting with rst (its own port has no owed count).  With HOLD_OWED the
    -- hold starts at job 14's START, not at its reset, and the reset comes 100 cycles in
    -- (not 300): job 14 reads only 40 beats per port, so without the hold every burst had
    -- landed before the reset and nothing was owed (MEASURED: the unguarded RTL PASSED the
    -- first version of this mode).  Under the hold each port's credit fills (FIFO_DEPTH 64
    -- = 4 bursts of 16) and every one of those bursts is owed at the reset.
    HOLD_OWED : boolean := false
  );
end entity;

architecture sim of tb_mv4i_tiled is
  constant NW   : positive := 24;
  constant NSP   : positive := 3;
  constant NP   : positive := NW + NSP;
  constant RI   : positive := 48;
  constant DW   : positive := 256;
  constant AW   : positive := 40;
  constant MAXC : positive := 2048;
  constant MAXR : positive := 240;
  constant NWRD : positive := 256;
  constant ND   : positive := 3;      -- 0 OLD, 1 SPLIT, 2 SAME
  signal clk, aclk : std_logic := '0';
  signal rst : std_logic := '1';
  signal done_sim : boolean := false;

  signal start, cb_we, x_we : std_logic := '0';
  signal n_rows, n_cols, out_shift, w_exp, x_exp, beats : std_logic_vector(31 downto 0) := (others => '0');
  signal out_mode : std_logic_vector(1 downto 0) := "00";
  signal cb_addr : std_logic_vector(3 downto 0) := (others => '0');
  signal cb_data : std_logic_vector(7 downto 0) := (others => '0');
  signal x_waddr, x_wdata : std_logic_vector(15 downto 0) := (others => '0');
  signal wr_en : std_logic := '0';
  signal wr_addr : natural := 0;
  type pw_t is array(0 to NP-1) of std_logic_vector(DW-1 downto 0);
  signal wr_data : pw_t := (others => (others => '0'));

  type v1_t  is array(0 to ND-1) of std_logic_vector(NP-1 downto 0);
  type va_t  is array(0 to ND-1) of std_logic_vector(NP*AW-1 downto 0);
  type v8_t  is array(0 to ND-1) of std_logic_vector(NP*8-1 downto 0);
  type v3_t  is array(0 to ND-1) of std_logic_vector(NP*3-1 downto 0);
  type v2_t  is array(0 to ND-1) of std_logic_vector(NP*2-1 downto 0);
  type vd_t  is array(0 to ND-1) of std_logic_vector(NP*DW-1 downto 0);
  signal arv, arr, rv, rr, rl : v1_t;
  signal ara : va_t; signal arl : v8_t; signal ars : v3_t; signal arb : v2_t;
  signal rd : vd_t;
  type yd_t is array(0 to ND-1) of std_logic_vector(RI*64-1 downto 0);
  type ym_t is array(0 to ND-1) of std_logic_vector(RI-1 downto 0);
  type y16_t is array(0 to ND-1) of std_logic_vector(15 downto 0);
  type y32_t is array(0 to ND-1) of std_logic_vector(31 downto 0);
  signal y_we, done, err, sat : std_logic_vector(0 to ND-1);
  signal y_addr : y16_t; signal y_data : yd_t; signal y_mask : ym_t; signal y_exp : y32_t;
  signal wbase : std_logic_vector(NW*AW-1 downto 0) := (others => '0');
  signal sbase : std_logic_vector(NSP*AW-1 downto 0) := (others => '0');

  -- the beat log each DUT appends to; the main process compares them
  constant MAXBT : positive := 16;
  type beat_t is record
    a : std_logic_vector(15 downto 0); d : std_logic_vector(RI*64-1 downto 0);
    m : std_logic_vector(RI-1 downto 0); e : std_logic_vector(31 downto 0);
  end record;
  type blog_t is array(0 to MAXBT-1) of beat_t;
  type logs_t is array(0 to ND-1) of blog_t;
  signal logs : logs_t;
  type cnt_t is array(0 to ND-1) of natural;
  signal nbeat : cnt_t := (others => 0);
  signal clr_log : std_logic := '0';
  -- the new DUTs' memory reset and R hold (see HOLD_OWED)
  signal por, mrst, mhold : std_logic := '1';
begin
  mrst <= por;
  clk  <= not clk after 4 ns when not done_sim else '0';
  aclk <= not aclk after 1.111 ns when not done_sim else '0';

  old : entity work.matvec_int4
    generic map(BLK => 32, ROWS_IF => RI, NPORTS_W => NW, NPORTS_S => NSP, AXI_DW => DW,
                ADDR_W => AW, MAXCOLS => MAXC, MAXROWS_BFP => MAXR, FIFO_DEPTH => 64,
                MAXB => 16, MAXOUT => 16, DUAL_CLK => false, FAST_POP => false)
    port map(clk => clk, rst => rst, start => start, n_rows => n_rows, n_cols => n_cols,
             out_shift => out_shift, w_exp => w_exp, x_exp => x_exp, out_mode => out_mode,
             w_base => wbase, w_beats => beats, s_base => sbase, s_beats => beats,
             cb_we => cb_we, cb_addr => cb_addr, cb_data => cb_data,
             x_we => x_we, x_waddr => x_waddr, x_wdata => x_wdata,
             m_arvalid => arv(0), m_arready => arr(0), m_araddr => ara(0), m_arlen => arl(0),
             m_arsize => ars(0), m_arburst => arb(0), m_rvalid => rv(0), m_rready => rr(0),
             m_rdata => rd(0), m_rlast => rl(0),
             y_we => y_we(0), y_addr => y_addr(0), y_data => y_data(0), y_mask => y_mask(0),
             y_exp => y_exp(0), done => done(0), err => err(0), sat_event => sat(0),
             dbg_wbeat => open, dbg_wstarve => open, dbg_sstarve => open);

  g_new : for d in 1 to 2 generate
    dut : entity work.mv4i_tiled
      generic map(BLK => 32, ROWS_IF => RI, NPORTS_W => NW, NPORTS_S => NSP, AXI_DW => DW,
                  ADDR_W => AW, MAXCOLS => MAXC, MAXROWS_BFP => MAXR, FIFO_DEPTH => 64,
                  MAXB => 16, MAXOUT => 16, A_CLK_SPLIT => (d = 1))
      port map(clk => clk, rst => rst, aclk => aclk, start => start, n_rows => n_rows,
               n_cols => n_cols, out_shift => out_shift, w_exp => w_exp, x_exp => x_exp,
               out_mode => out_mode, w_base => wbase, w_beats => beats, s_base => sbase,
               s_beats => beats, cb_we => cb_we, cb_addr => cb_addr, cb_data => cb_data,
               x_we => x_we, x_waddr => x_waddr, x_wdata => x_wdata,
               m_arvalid => arv(d), m_arready => arr(d), m_araddr => ara(d),
               m_arlen => arl(d), m_arsize => ars(d), m_arburst => arb(d),
               m_rvalid => rv(d), m_rready => rr(d), m_rdata => rd(d), m_rlast => rl(d),
               y_we => y_we(d), y_addr => y_addr(d), y_data => y_data(d),
               y_mask => y_mask(d), y_exp => y_exp(d), done => done(d), err => err(d),
               sat_event => sat(d));
  end generate;

  -- 27 AXI read models per DUT.  OLD and SAME run their masters on clk, SPLIT on aclk.
  g_d : for d in 0 to ND-1 generate
    g_p : for p in 0 to NP-1 generate
      function lpm(dd, pp : natural) return natural is
      begin
        -- SPLIT only.  Port 13 stalls most (8 per 1024 cycles, about 70% of the time
        -- stalled): with a 64-beat weight FIFO and a 32-deep flit FIFO, a rarer stall
        -- let the credit-loss mutant C1 SURVIVE twice (MEASURED 2026-11-12).
        if dd = 1 and pp = 13 then return 8;
        elsif dd = 1 and (pp = 0 or pp = 25) then return 3;
        else return 0; end if;
      end function;
      function mclk_is_a(dd : natural) return boolean is
      begin
        return dd = 1;
      end function;
      -- OLD (d = 0) is the reference: its models always reset with rst and never hold
      function sel_rst(dd : natural; r, m : std_logic) return std_logic is
      begin
        if dd = 0 then return r; else return m; end if;
      end function;
      function sel_hold(dd : natural; h : std_logic) return std_logic is
      begin
        if dd = 0 then return '0'; else return h; end if;
      end function;
    begin
      g_a : if mclk_is_a(d) generate
        m : entity work.axi_rd_mem_model
          generic map(AXI_DW => DW, ADDR_W => AW, NWORDS => NWRD, SEED => 100*d + p + 1,
                      GAPPCT => 20, LONGPM => lpm(d, p), LONGLEN => 300)
          port map(clk => aclk, rst => mrst, arvalid => arv(d)(p), arready => arr(d)(p),
                   araddr => ara(d)(p*AW+AW-1 downto p*AW), arlen => arl(d)(p*8+7 downto p*8),
                   rvalid => rv(d)(p), rready => rr(d)(p), rdata => rd(d)(p*DW+DW-1 downto p*DW),
                   rlast => rl(d)(p), wr_en => wr_en, wr_addr => wr_addr, wr_data => wr_data(p),
                   hold => mhold);
      end generate;
      g_c : if not mclk_is_a(d) generate
        m : entity work.axi_rd_mem_model
          generic map(AXI_DW => DW, ADDR_W => AW, NWORDS => NWRD, SEED => 100*d + p + 1,
                      GAPPCT => 20, LONGPM => lpm(d, p), LONGLEN => 300)
          port map(clk => clk, rst => sel_rst(d, rst, mrst), arvalid => arv(d)(p), arready => arr(d)(p),
                   araddr => ara(d)(p*AW+AW-1 downto p*AW), arlen => arl(d)(p*8+7 downto p*8),
                   rvalid => rv(d)(p), rready => rr(d)(p), rdata => rd(d)(p*DW+DW-1 downto p*DW),
                   rlast => rl(d)(p), wr_en => wr_en, wr_addr => wr_addr, wr_data => wr_data(p),
                   hold => sel_hold(d, mhold));
      end generate;
    end generate;

    logger : process(clk)
      variable n : natural := 0;
    begin
      if rising_edge(clk) then
        if clr_log = '1' then
          n := 0;
        elsif y_we(d) = '1' then
          assert n < MAXBT report "tb_mv4i_tiled: beat log full" severity failure;
          logs(d)(n) <= (y_addr(d), y_data(d), y_mask(d), y_exp(d));
          n := n + 1;
        end if;
        nbeat(d) <= n;
      end if;
    end process;
  end generate;

  run : process
    type job_t is record
      rows, cols, os, md, wexp, xexp : integer;
      kind : natural;  -- 0 random, 1 saturating, 2 reset mid-job (not compared),
                       -- 3 the previous job's weights and x with a new codebook
                       -- 4 random, preceded by a one-cycle reset pulse at idle
                       -- 5 a ONE-cycle reset two cycles after SAME's first y beat, while
                       --   the result chain still holds words (not compared)
    end record;
    type jobs_t is array(natural range <>) of job_t;
    constant JOBS : jobs_t := (
      (48, 32, 3, 1, 2, 5, 0), (50, 100, 7, 0, -3, 4, 0), (144, 64, 0, 2, 1, 1, 0),
      (97, 250, 12, 1, 0, -2, 0), (10, 544, 0, 1, 0, 0, 1), (10, 544, 0, 2, 0, 0, 1),
      (200, 33, 40, 0, 6, -7, 0), (1, 1, 5, 1, 0, 0, 0),
      (20, 0, 3, 1, 0, 0, 0),        -- refused: n_cols = 0
      (241, 64, 3, 0, 0, 0, 0),      -- refused: BFP above MAXROWS_BFP
      (20, 64, 41, 1, 0, 0, 0),      -- refused: out_shift 41
      (60, 300, 5, 0, 1, 2, 0),
      (480, 32, 9, 1, 2, 3, 0),      -- LM-head shape: raw, n_rows above MAXROWS_BFP, nb 1
      (480, 32, 9, 2, 0, 0, 3),      -- same weights and x, a new codebook, partial
      (96, 640, 4, 0, 0, 0, 2),      -- rst pulsed 300 cycles into the job
      (96, 640, 4, 0, 1, 1, 0),      -- the job after the reset
      (480, 640, 9, 1, 1, 2, 4),     -- 200 items per tile, over the 64-beat weight FIFO:
                                     -- the SPLIT stalls now exhaust tile credits; a
                                     -- one-cycle reset at idle before it (kind 4)
      (480, 32, 9, 1, 0, 0, 5),      -- Task 7b fix round 1: one-cycle reset mid-result
      (96, 64, 4, 0, 2, 1, 0));      -- the job after it (a stale chain word shows here)
    variable rng : unsigned(31 downto 0) := x"5EED1234";
    variable nb, nt, cyc, checks, fails : natural := 0;
    variable bad : boolean;
    variable w : std_logic_vector(DW-1 downto 0);
    variable alldone : std_logic_vector(0 to ND-1);
    variable e0, s0, ex0 : std_logic_vector(31 downto 0);
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
        report "tb_mv4i_tiled: MISMATCH " & msg severity error;
      end if;
    end procedure;
  begin
    rst <= '1';
    for i in 1 to 10 loop wait until rising_edge(clk); end loop;
    rst <= '0'; por <= '0'; mhold <= '0';
    for i in 1 to 10 loop wait until rising_edge(clk); end loop;
    for j in JOBS'range loop
      if JOBS(j).kind = 4 then
        rst <= '1';
        wait until rising_edge(clk);
        rst <= '0';
        for i in 1 to 10 loop wait until rising_edge(clk); end loop;
      end if;
      if JOBS(j).cols > 0 then nb := (JOBS(j).cols + 31) / 32; else nb := 1; end if;
      nt := (JOBS(j).rows + RI - 1) / RI;
      -- weights and scales, written to all 81 models at once (kind 3 reuses them)
      for i in 0 to nt*nb - 1 loop
        exit when JOBS(j).kind = 3;
        for p in 0 to NP-1 loop
          for k in 0 to DW/32 - 1 loop
            rnd;
            if JOBS(j).kind = 1 then
              if p < NW then w(k*32+31 downto k*32) := (others => '0');       -- idx 0
              else w(k*32+31 downto k*32) := x"7FFF7FFF"; end if;              -- scale 32767
            elsif p < NW then
              w(k*32+31 downto k*32) := std_logic_vector(rng);
            else
              w(k*32+31 downto k*32) := std_logic_vector(rng and x"7FFF7FFF"); -- uint15
            end if;
          end loop;
          wr_data(p) <= w;
        end loop;
        wr_en <= '1'; wr_addr <= i;
        wait until rising_edge(aclk);
        wait until rising_edge(clk);
      end loop;
      wr_en <= '0';
      -- activations: n_cols rounded up to a block, plus junk past n_cols
      for k in 0 to nb*32 - 1 loop
        exit when JOBS(j).kind = 3;
        rnd;
        x_we <= '1'; x_waddr <= std_logic_vector(to_unsigned(k, 16));
        if JOBS(j).kind = 1 then x_wdata <= x"8000";
        else x_wdata <= std_logic_vector(rng(15 downto 0)); end if;
        wait until rising_edge(clk);
      end loop;
      x_we <= '0';
      -- codebook: cb[0] = -127 for the saturating job, else the full int8 range
      for e in 0 to 15 loop
        rnd;
        cb_we <= '1'; cb_addr <= std_logic_vector(to_unsigned(e, 4));
        if JOBS(j).kind = 1 and e = 0 then cb_data <= x"81";
        elsif e = 15 then cb_data <= x"80";
        else cb_data <= std_logic_vector(rng(7 downto 0)); end if;
        wait until rising_edge(clk);
      end loop;
      cb_we <= '0';
      n_rows <= std_logic_vector(to_signed(JOBS(j).rows, 32));
      n_cols <= std_logic_vector(to_signed(JOBS(j).cols, 32));
      out_shift <= std_logic_vector(to_signed(JOBS(j).os, 32));
      out_mode <= std_logic_vector(to_unsigned(JOBS(j).md, 2));
      w_exp <= std_logic_vector(to_signed(JOBS(j).wexp, 32));
      x_exp <= std_logic_vector(to_signed(JOBS(j).xexp, 32));
      beats <= std_logic_vector(to_unsigned(nt*nb, 32));
      clr_log <= '1';
      wait until rising_edge(clk);
      clr_log <= '0';
      start <= '1';
      wait until rising_edge(clk);
      start <= '0';
      if mhold = '1' then
        -- release the owed bursts 20 clk cycles into the job after the mid-job reset
        for i in 1 to 20 loop wait until rising_edge(clk); end loop;
        mhold <= '0';
      end if;
      if JOBS(j).kind = 5 then
        -- a ONE-cycle reset while results are moving: in SAME (aclk_a = clk) that is a
        -- one-cycle ar2, the case where the tile/link reset and ar_ts deassert on the same
        -- edge with nothing to spare (rtl/mv_afast.vhd RESET TREE).  Nothing of this job is
        -- compared; the next job is.
        cyc := 0;
        while y_we(2) = '0' loop
          wait until rising_edge(clk);
          cyc := cyc + 1;
          assert cyc < 400000 report "tb_mv4i_tiled: job " & integer'image(j)
            & " never produced a SAME beat" severity failure;
        end loop;
        for i in 1 to 2 loop wait until rising_edge(clk); end loop;
        rst <= '1';
        wait until rising_edge(clk);
        rst <= '0';
        for i in 1 to 30 loop wait until rising_edge(clk); end loop;
        report "tb_mv4i_tiled: job " & integer'image(j) & " one-cycle reset mid-result"
          severity note;
        next;
      end if;
      if JOBS(j).kind = 2 then
        -- reset in the middle of the job; nothing of it is compared, the next job is
        if HOLD_OWED then
          mhold <= '1';
          for i in 1 to 100 loop wait until rising_edge(clk); end loop;
        else
          for i in 1 to 300 loop wait until rising_edge(clk); end loop;
        end if;
        rst <= '1';
        for i in 1 to 3 loop wait until rising_edge(clk); end loop;
        rst <= '0';
        for i in 1 to 30 loop wait until rising_edge(clk); end loop;
        report "tb_mv4i_tiled: job " & integer'image(j) & " reset mid-job" severity note;
        next;
      end if;
      alldone := (others => '0'); cyc := 0;
      while alldone /= "111" loop
        wait until rising_edge(clk);
        for d in 0 to ND-1 loop
          if done(d) = '1' then
            alldone(d) := '1';
          end if;
        end loop;
        cyc := cyc + 1;
        assert cyc < 400000 report "tb_mv4i_tiled: job " & integer'image(j) & " timed out"
          severity failure;
      end loop;
      wait until rising_edge(clk);
      -- compare
      chk(nbeat(1) = nbeat(0) and nbeat(2) = nbeat(0),
          "job " & integer'image(j) & " beat counts " & integer'image(nbeat(0)) & " "
          & integer'image(nbeat(1)) & " " & integer'image(nbeat(2)));
      for b in 0 to nbeat(0) - 1 loop
        for d in 1 to ND-1 loop
          if b < nbeat(d) then
            chk(logs(d)(b) = logs(0)(b), "job " & integer'image(j) & " DUT "
                & integer'image(d) & " beat " & integer'image(b) & " addr "
                & to_hstring(logs(d)(b).a) & " vs " & to_hstring(logs(0)(b).a));
          end if;
        end loop;
      end loop;
      for d in 1 to ND-1 loop
        chk(err(d) = err(0) and sat(d) = sat(0) and y_exp(d) = y_exp(0),
            "job " & integer'image(j) & " DUT " & integer'image(d) & " err/sat/y_exp at done");
      end loop;
      report "tb_mv4i_tiled: job " & integer'image(j) & " beats " & integer'image(nbeat(0))
           & " err " & std_logic'image(err(0)) & " sat " & std_logic'image(sat(0)) severity note;
    end loop;
    -- a final reset: the stall monitors print the last job's counts on it
    rst <= '1';
    for i in 1 to 3 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    for i in 1 to 10 loop wait until rising_edge(clk); end loop;
    assert fails = 0 report "tb_mv4i_tiled: FAIL " & integer'image(fails) severity failure;
    -- the wrapper row (HOLD_OWED) reports under its own name, so sim/mutate_rows.py and
    -- the gate read each row's own PASS line
    if HOLD_OWED then
      report "PASS: tb_mv4i_tiled_hbmnr checks=" & integer'image(checks) severity note;
    else
      report "PASS: tb_mv4i_tiled checks=" & integer'image(checks) severity note;
    end if;
    done_sim <= true;
    wait;
  end process;
end architecture;
