-- sim/tb_eng_cdc.vhd -- bench for rtl/fk33_eng_cdc.vhd, the A clock-domain
-- seam.  TRACK ACLK, 2026-09-20.
--
-- Two unrelated clocks.  A model of the CARD on the slow side drives the seam
-- exactly as rtl/fk33_llama_top.vhd's ga_desc arm and rtl/a_desc_adapter.vhd
-- do: j_cols x elements back to back with no ready, a_x_exp written on the
-- cycle after the last push, three AXI-Lite writes (LO, HI, GO), then a wait
-- on a_job_done.  A model of the ENGINE on the fast side answers like
-- rtl/matvec_int4_desc_axi.vhd: awready/wready together for one cycle,
-- bvalid the cycle after, job_done a LEVEL cleared by the GO write, and the
-- job's y beats emitted BACK TO BACK one per fast cycle (matvec_core S_EMIT).
--
-- WHAT IS CHECKED, per job, and which of the wrapper's three orderings each
-- one is the oracle for (numbers refer to the header of the RTL):
--   x   every element arrives on the engine side exactly once, in order, with
--       the pushed value, and ALL of them before the job's first AXI write
--       executes there                                               (1)
--   go  d_x_exp and job_index at the GO write are the values the card held
--       when it armed the write                                       (1)
--   b   bresp comes back per write, including a non-OKAY one
--   y   every beat arrives on the card side exactly once, in order, with the
--       emitted addr/data/mask/exp; the last beat's exp is still on a_y_exp
--       after done; NO beat after a_job_done                          (3)
--   dn  a_job_done is LOW at the GO write's response (never the previous
--       job's level), rises exactly once per job, after the last beat, stays
--       up until the next write is accepted                           (2)
--   f   a push into a full x FIFO and a burst past Y_DEPTH each raise
--       cdc_fault and a_job_err, and the seam recovers after reset
--
-- PHASES: card 13.333 ns / engine 5 ns (the shipped 75 / 200 MHz), then the
-- SWAPPED ratio 5 / 13.333 with the x pushes throttled to what a slower
-- consumer can take (MEASURED on the first run: async_fifo's read side pops
-- TWO beats per THREE rclk cycles with q_ready held high, because do_rd is
-- gated on ocnt + inflight < 2, so a push every 15 ns overran a 13.333 ns
-- consumer that pops every 20 ns), because the swap is what makes (1) reachable:
-- with the engine faster than the card, luck alone orders x ahead of the GO.
-- Then the two fault phases.
--
-- Checks are counted in VARIABLES (CLAUDE.md: a signal assigned twice in one
-- delta keeps the last value).  Per-process counts are published once at
-- the end.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_eng_cdc is
end entity;

architecture sim of tb_eng_cdc is
  constant ROWS_IF : positive := 8;
  constant LITE_AW : positive := 12;
  constant X_DEPTH : positive := 16;
  constant Y_DEPTH : positive := 256;

  -- clocks whose periods are SIGNALS, so the ratio can be swapped mid-run
  signal s_per : time := 13333 ps;
  signal m_per : time := 5000 ps;
  signal s_clk : std_logic := '0';
  signal m_clk : std_logic := '0';
  signal s_rstn : std_logic := '0';
  signal m_rstn : std_logic := '0';
  signal run_clocks : boolean := true;

  -- card side
  signal a_job_index : std_logic_vector(31 downto 0) := (others => '0');
  signal a_x_we      : std_logic := '0';
  signal a_x_waddr   : std_logic_vector(15 downto 0) := (others => '0');
  signal a_x_wdata   : std_logic_vector(15 downto 0) := (others => '0');
  signal a_x_exp     : std_logic_vector(31 downto 0) := (others => '0');
  signal a_y_we      : std_logic;
  signal a_y_addr    : std_logic_vector(15 downto 0);
  signal a_y_data    : std_logic_vector(ROWS_IF*64-1 downto 0);
  signal a_y_mask    : std_logic_vector(ROWS_IF-1 downto 0);
  signal a_y_exp     : std_logic_vector(31 downto 0);
  signal a_job_done  : std_logic;
  signal a_job_err   : std_logic;
  signal sa_awaddr   : std_logic_vector(LITE_AW-1 downto 0) := (others => '0');
  signal sa_awvalid  : std_logic := '0';
  signal sa_awready  : std_logic;
  signal sa_wdata    : std_logic_vector(31 downto 0) := (others => '0');
  signal sa_wstrb    : std_logic_vector(3 downto 0) := "1111";
  signal sa_wvalid   : std_logic := '0';
  signal sa_wready   : std_logic;
  signal sa_bresp    : std_logic_vector(1 downto 0);
  signal sa_bvalid   : std_logic;
  signal sa_bready   : std_logic := '1';
  signal cdc_fault   : std_logic;

  -- engine side
  signal job_index   : std_logic_vector(31 downto 0);
  signal d_x_we      : std_logic;
  signal d_x_waddr   : std_logic_vector(15 downto 0);
  signal d_x_wdata   : std_logic_vector(15 downto 0);
  signal d_x_exp     : std_logic_vector(31 downto 0);
  signal d_y_we      : std_logic := '0';
  signal d_y_addr    : std_logic_vector(15 downto 0) := (others => '0');
  signal d_y_data    : std_logic_vector(ROWS_IF*64-1 downto 0) := (others => '0');
  signal d_y_mask    : std_logic_vector(ROWS_IF-1 downto 0) := (others => '0');
  signal d_y_exp     : std_logic_vector(31 downto 0) := (others => '0');
  signal d_job_done  : std_logic := '0';
  signal d_job_err   : std_logic := '0';
  signal ma_awaddr   : std_logic_vector(LITE_AW-1 downto 0);
  signal ma_awvalid  : std_logic;
  signal ma_awready  : std_logic := '0';
  signal ma_wdata    : std_logic_vector(31 downto 0);
  signal ma_wstrb    : std_logic_vector(3 downto 0);
  signal ma_wvalid   : std_logic;
  signal ma_wready   : std_logic := '0';
  signal ma_bresp    : std_logic_vector(1 downto 0) := "00";
  signal ma_bvalid   : std_logic := '0';
  signal ma_bready   : std_logic;

  -- ---- the job description, card -> engine model (bench-internal) --------
  signal j_cols   : natural := 0;     -- x elements this job pushes
  signal j_beats  : natural := 0;     -- y beats the engine model emits on GO
  signal j_seed   : natural := 0;
  signal j_bad_hi : boolean := false; -- engine answers the HI write with SLVERR
  signal x_gap    : natural := 0;     -- idle slow cycles between x pushes

  -- ---- engine-model observations, read by the card process ---------------
  signal e_x_count  : natural := 0;   -- x elements received this job
  signal e_x_ok     : boolean := true;
  signal e_x_at_lo  : integer := -1;  -- e_x_count when the LO write executed
  signal e_xexp_go  : std_logic_vector(31 downto 0) := (others => '0');
  signal e_jidx_go  : std_logic_vector(31 downto 0) := (others => '0');
  signal e_go_seen  : natural := 0;
  signal e_lo_seen  : natural := 0;
  signal e_hi_seen  : natural := 0;
  signal e_x_reset  : std_logic := '0';  -- card asks the model to zero its x view
  signal e_x_strict : boolean := true;   -- false in the phases that LOSE elements

  -- ---- the always-on y monitor (the real card captures a_y_we in EVERY
  -- state; a beat outside the run window is f_lost_a).  Read by the card
  -- process after done.
  signal ymon_reset   : std_logic := '0';
  signal ymon_strict  : boolean := true;
  signal ymon_window  : boolean := false;  -- push_x start .. done consumed
  signal ymon_seen    : natural := 0;
  signal ymon_bad     : natural := 0;      -- wrong value / out of order
  signal ymon_outside : natural := 0;      -- beat outside the run window
  signal ymon_after_done : natural := 0;   -- beat while a_job_done = '1'
  signal ymon_last_t  : time := 0 ns;
  signal ymon_done_rises : natural := 0;
  signal ymon_done_t  : time := 0 ns;

  -- ---- check bookkeeping ------------------------------------------------
  signal n_chk_card : natural := 0;
  signal n_chk_eng  : natural := 0;
  signal n_fail_card : natural := 0;
  signal n_fail_eng  : natural := 0;
  signal eng_done_reporting : boolean := false;
  signal card_finished : boolean := false;

  function xval(seed, k : natural) return std_logic_vector is
    variable v : unsigned(15 downto 0);
  begin
    v := to_unsigned((seed * 7919 + k * 104729 + 13) mod 65536, 16);
    return std_logic_vector(v);
  end function;

  function ybeat(seed, i, rr : natural) return std_logic_vector is
    variable v : unsigned(63 downto 0);
  begin
    v := to_unsigned((seed * 31 + i * 1009 + rr * 17 + 5) mod 65536, 64);
    return std_logic_vector(v);
  end function;

  function ymask(seed, i : natural) return std_logic_vector is
    variable m : std_logic_vector(ROWS_IF-1 downto 0);
  begin
    for rr in 0 to ROWS_IF-1 loop
      if ((seed + i + rr) mod 3) = 0 then m(rr) := '0'; else m(rr) := '1'; end if;
    end loop;
    return m;
  end function;

  function yexp(seed, i : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(seed * 100 + i, 32));
  end function;

begin

  -- ======================================================================
  -- clocks: half-period read every edge, so a period change takes effect
  -- on the next edge without a glitch
  -- ======================================================================
  sclk_p : process
  begin
    while run_clocks loop
      s_clk <= '0'; wait for s_per / 2;
      s_clk <= '1'; wait for s_per / 2;
    end loop;
    wait;
  end process;
  mclk_p : process
  begin
    while run_clocks loop
      m_clk <= '0'; wait for m_per / 2;
      m_clk <= '1'; wait for m_per / 2;
    end loop;
    wait;
  end process;

  dut : entity work.fk33_eng_cdc
    generic map (ROWS_IF => ROWS_IF, LITE_AW => LITE_AW,
                 X_DEPTH => X_DEPTH, Y_DEPTH => Y_DEPTH)
    port map (
      s_clk => s_clk, s_rstn => s_rstn,
      a_job_index => a_job_index,
      a_x_we => a_x_we, a_x_waddr => a_x_waddr, a_x_wdata => a_x_wdata,
      a_x_exp => a_x_exp,
      a_y_we => a_y_we, a_y_addr => a_y_addr, a_y_data => a_y_data,
      a_y_mask => a_y_mask, a_y_exp => a_y_exp,
      a_job_done => a_job_done, a_job_err => a_job_err,
      sa_awaddr => sa_awaddr, sa_awvalid => sa_awvalid, sa_awready => sa_awready,
      sa_wdata => sa_wdata, sa_wstrb => sa_wstrb, sa_wvalid => sa_wvalid,
      sa_wready => sa_wready, sa_bresp => sa_bresp, sa_bvalid => sa_bvalid,
      sa_bready => sa_bready,
      cdc_fault => cdc_fault,
      m_clk => m_clk, m_rstn => m_rstn,
      job_index => job_index,
      d_x_we => d_x_we, d_x_waddr => d_x_waddr, d_x_wdata => d_x_wdata,
      d_x_exp => d_x_exp,
      d_y_we => d_y_we, d_y_addr => d_y_addr, d_y_data => d_y_data,
      d_y_mask => d_y_mask, d_y_exp => d_y_exp,
      d_job_done => d_job_done, d_job_err => d_job_err,
      ma_awaddr => ma_awaddr, ma_awvalid => ma_awvalid, ma_awready => ma_awready,
      ma_wdata => ma_wdata, ma_wstrb => ma_wstrb, ma_wvalid => ma_wvalid,
      ma_wready => ma_wready, ma_bresp => ma_bresp, ma_bvalid => ma_bvalid,
      ma_bready => ma_bready);

  -- ======================================================================
  -- THE ENGINE MODEL (fast domain)
  -- ======================================================================
  eng_model : process(m_clk)
    variable nchk, nfail : natural := 0;
    variable go_pending : boolean := false;
    variable emit_i     : integer := -1;   -- beat being emitted, -1 idle
    variable emit_n     : natural := 0;
    variable emit_seed  : natural := 0;
    variable done_wait  : integer := -1;   -- cycles until done rises
    variable acc        : boolean := false; -- awready/wready cycle
    variable wr_addr    : std_logic_vector(LITE_AW-1 downto 0);
    variable wr_data    : std_logic_vector(31 downto 0);
    variable xc         : natural := 0;
    procedure chk(cond : boolean; msg : string) is
    begin
      nchk := nchk + 1;
      if not cond then
        nfail := nfail + 1;
        report "ENG CHECK FAIL: " & msg severity error;
      end if;
    end procedure;
  begin
    if rising_edge(m_clk) then
      if m_rstn = '0' then
        ma_awready <= '0'; ma_wready <= '0'; ma_bvalid <= '0';
        d_y_we <= '0'; d_job_done <= '0';
        acc := false; emit_i := -1; done_wait := -1; xc := 0;
        e_x_count <= 0; e_x_ok <= true;
      else
        -- x capture: exactly the pushed value, in order
        if e_x_reset = '1' then
          xc := 0; e_x_count <= 0; e_x_ok <= true;
        end if;
        if d_x_we = '1' then
          if e_x_strict then
            chk(unsigned(d_x_waddr) = xc,
                "x element " & integer'image(xc) & " arrived with addr "
                & integer'image(to_integer(unsigned(d_x_waddr))));
            chk(d_x_wdata = xval(j_seed, xc),
                "x element " & integer'image(xc) & " value");
          end if;
          if unsigned(d_x_waddr) /= xc or d_x_wdata /= xval(j_seed, xc) then
            e_x_ok <= false;
          end if;
          xc := xc + 1;
          e_x_count <= xc;
        end if;

        -- AXI-Lite write slave, the unit's shape: both ready together for
        -- one cycle when both valid, bvalid the cycle after
        ma_bvalid <= '0';
        if acc then
          ma_awready <= '0'; ma_wready <= '0';
          acc := false;
          -- the handshake happened on THIS edge: valid still held
          wr_addr := ma_awaddr; wr_data := ma_wdata;
          chk(ma_awvalid = '1' and ma_wvalid = '1',
              "AW/W not held through the ready cycle");
          ma_bvalid <= '1';
          ma_bresp  <= "00";
          case to_integer(unsigned(wr_addr)) is
            when 0 =>
              e_lo_seen <= e_lo_seen + 1;
              e_x_at_lo <= xc;
            when 4 =>
              e_hi_seen <= e_hi_seen + 1;
              if j_bad_hi then ma_bresp <= "10"; end if;
            when 8 =>
              e_go_seen <= e_go_seen + 1;
              e_xexp_go <= d_x_exp;
              e_jidx_go <= job_index;
              -- go_now: done cleared on the write cycle, job starts
              d_job_done <= '0';
              emit_seed := j_seed; emit_n := j_beats;
              if emit_n = 0 then
                emit_i := -1; done_wait := 6;
              else
                emit_i := 0;
              end if;
            when others =>
              chk(false, "write to an unknown address " & integer'image(to_integer(unsigned(wr_addr))));
          end case;
        elsif ma_awvalid = '1' and ma_wvalid = '1' and ma_awready = '0' then
          ma_awready <= '1'; ma_wready <= '1';
          acc := true;
        end if;
        if ma_bvalid = '1' then
          chk(ma_bready = '1', "bready dropped while bvalid");
        end if;

        -- the y burst, back to back, then done a few cycles later
        d_y_we <= '0';
        if emit_i >= 0 then
          d_y_we   <= '1';
          d_y_addr <= std_logic_vector(to_unsigned(emit_i * ROWS_IF, 16));
          for rr in 0 to ROWS_IF-1 loop
            d_y_data(rr*64+63 downto rr*64) <= ybeat(emit_seed, emit_i, rr);
          end loop;
          d_y_mask <= ymask(emit_seed, emit_i);
          d_y_exp  <= yexp(emit_seed, emit_i);
          if emit_i = emit_n - 1 then
            emit_i := -1; done_wait := 6;
          else
            emit_i := emit_i + 1;
          end if;
        end if;
        if done_wait > 0 then
          done_wait := done_wait - 1;
        elsif done_wait = 0 then
          d_job_done <= '1';
          done_wait := -1;
        end if;
      end if;
      if eng_done_reporting then
        n_chk_eng  <= nchk;
        n_fail_eng <= nfail;
      end if;
    end if;
  end process;

  -- ======================================================================
  -- THE y MONITOR (slow domain), always on
  -- ======================================================================
  y_mon : process(s_clk)
    variable n : natural := 0;
    variable ok : boolean;
    variable prev_done : std_logic := '0';
  begin
    if rising_edge(s_clk) then
      if ymon_reset = '1' then
        n := 0; ymon_seen <= 0; ymon_bad <= 0; ymon_outside <= 0;
        ymon_after_done <= 0; ymon_done_rises <= 0;
        ymon_last_t <= now; prev_done := a_job_done;
      else
        if a_y_we = '1' then
          ok := unsigned(a_y_addr) = n * ROWS_IF;
          ok := ok and (a_y_mask = ymask(j_seed, n));
          ok := ok and (a_y_exp = yexp(j_seed, n));
          for rr in 0 to ROWS_IF-1 loop
            ok := ok and (a_y_data(rr*64+63 downto rr*64) = ybeat(j_seed, n, rr));
          end loop;
          if not ok and ymon_strict then
            ymon_bad <= ymon_bad + 1;
            report "y beat " & integer'image(n) & " wrong or out of order: addr="
              & integer'image(to_integer(unsigned(a_y_addr))) & " exp="
              & integer'image(to_integer(unsigned(a_y_exp)))
              severity warning;
          end if;
          if not ymon_window then ymon_outside <= ymon_outside + 1; end if;
          if a_job_done = '1' then ymon_after_done <= ymon_after_done + 1; end if;
          n := n + 1;
          ymon_seen <= n;
          ymon_last_t <= now;
        end if;
        if a_job_done = '1' and prev_done = '0' then
          ymon_done_rises <= ymon_done_rises + 1;
          ymon_done_t <= now;
        end if;
        prev_done := a_job_done;
      end if;
    end if;
  end process;

  -- ======================================================================
  -- THE CARD MODEL (slow domain) and the phase sequencer
  -- ======================================================================
  card_model : process
    variable nchk, nfail : natural := 0;
    variable jobno   : natural := 0;
    variable beats_seen : natural := 0;
    variable lo_seen0, hi_seen0, go_seen0 : natural;

    procedure chk(cond : boolean; msg : string) is
    begin
      nchk := nchk + 1;
      if not cond then
        nfail := nfail + 1;
        report "CARD CHECK FAIL: " & msg severity error;
      end if;
    end procedure;

    procedure sclk(n : natural) is
    begin
      for i in 1 to n loop
        wait until rising_edge(s_clk);
      end loop;
    end procedure;

    -- one AXI-Lite write, the adapter's shape: AW and W offered together,
    -- each held until its own ready, then wait for B
    procedure lite_write(addr : natural; data : std_logic_vector(31 downto 0);
                         want_resp : std_logic_vector(1 downto 0)) is
      variable awd, wd : boolean := false;
    begin
      sa_awaddr <= std_logic_vector(to_unsigned(addr, LITE_AW));
      sa_wdata  <= data;
      sa_awvalid <= '1'; sa_wvalid <= '1';
      while not (awd and wd) loop
        wait until rising_edge(s_clk);
        if sa_awvalid = '1' and sa_awready = '1' then awd := true; sa_awvalid <= '0'; end if;
        if sa_wvalid = '1' and sa_wready = '1' then wd := true; sa_wvalid <= '0'; end if;
      end loop;
      while sa_bvalid /= '1' loop
        wait until rising_edge(s_clk);
      end loop;
      chk(sa_bresp = want_resp, "bresp for write to " & integer'image(addr)
          & " differs from the expected one");
      wait until rising_edge(s_clk);
    end procedure;

    -- push j_cols x elements; `gap` idle cycles between pushes, except the
    -- last `tail` elements which go back to back.  The tail is what makes
    -- ordering (1) checkable in the swapped phase: a dozen elements still
    -- queued in the x FIFO when the first write is armed, so a wrapper that
    -- does not wait executes the write before they have crossed.  Without
    -- it the request path's own latency (five card cycles plus five engine
    -- cycles) exceeds the FIFO's at either ratio and orders them by luck --
    -- MEASURED: mutant W12 survived a bench with no tail.
    procedure push_x(cols, gap, tail : natural) is
    begin
      for k in 0 to cols-1 loop
        a_x_we    <= '1';
        a_x_waddr <= std_logic_vector(to_unsigned(k, 16));
        a_x_wdata <= xval(j_seed, k);
        wait until rising_edge(s_clk);
        a_x_we <= '0';
        if gap > 0 and k < cols - tail then sclk(gap); end if;
      end loop;
    end procedure;

    -- wait for a_job_done, then judge what the monitor saw
    procedure run_job(expect_fault : boolean) is
    begin
      -- the adapter's S_WAIT: done must be LOW right after the GO's bvalid
      chk(a_job_done = '0', "a_job_done is HIGH at the GO write's response "
          & "(the previous job's level leaked through)");
      while a_job_done /= '1' loop
        wait until rising_edge(s_clk);
      end loop;
      -- a few more cycles: nothing may trail the done
      sclk(6);
      beats_seen := ymon_seen;
      chk(ymon_after_done = 0, "a y beat arrived AFTER a_job_done (job "
          & integer'image(jobno) & ")");
      chk(ymon_outside = 0, "a y beat arrived outside the run window (job "
          & integer'image(jobno) & ")");
      chk(ymon_done_rises = 1, "a_job_done rose " & integer'image(ymon_done_rises)
          & " times in job " & integer'image(jobno));
      chk(ymon_done_t > ymon_last_t or j_beats = 0,
          "a_job_done rose before the last y beat (job " & integer'image(jobno) & ")");
      if not expect_fault then
        chk(ymon_bad = 0, "job " & integer'image(jobno) & ": "
            & integer'image(ymon_bad) & " y beats wrong or out of order");
        chk(beats_seen = j_beats, "job " & integer'image(jobno) & ": "
            & integer'image(beats_seen) & " beats seen, " & integer'image(j_beats) & " emitted");
        if j_beats > 0 then
          chk(a_y_exp = yexp(j_seed, j_beats-1),
              "a_y_exp after done differs from the last beat's exp");
        end if;
      end if;
      -- the engine side's view of ordering (1) and the GO's payload
      if not expect_fault then
        chk(e_x_at_lo = j_cols, "job " & integer'image(jobno) & ": LO write executed "
            & "with " & integer'image(e_x_at_lo) & " of " & integer'image(j_cols)
            & " x elements in the engine");
        chk(e_x_count = j_cols and e_x_ok, "job " & integer'image(jobno)
            & ": x elements in the engine " & integer'image(e_x_count) & " ok="
            & boolean'image(e_x_ok));
      end if;
      chk(e_xexp_go = a_x_exp, "d_x_exp at GO differs from the card's a_x_exp");
      chk(e_jidx_go = a_job_index, "job_index at GO differs from the card's a_job_index");
      chk(e_lo_seen = lo_seen0 + 1 and e_hi_seen = hi_seen0 + 1
          and e_go_seen = go_seen0 + 1, "the three writes did not each execute once");
      ymon_window <= false;
    end procedure;

    procedure do_job(cols, beats, seed, gap, tail : natural; bad_hi, expect_fault : boolean) is
    begin
      jobno := jobno + 1;
      j_cols <= cols; j_beats <= beats; j_seed <= seed; j_bad_hi <= bad_hi;
      x_gap <= gap;
      e_x_strict <= not expect_fault;
      ymon_strict <= not expect_fault;
      lo_seen0 := e_lo_seen; hi_seen0 := e_hi_seen; go_seen0 := e_go_seen;
      e_x_reset <= '1'; ymon_reset <= '1';
      sclk(6);   -- let the engine side see the reset request
      e_x_reset <= '0'; ymon_reset <= '0';
      sclk(4);
      ymon_window <= true;   -- the real card is in S_RUN before the GO
      a_job_index <= std_logic_vector(to_unsigned(seed * 3 + jobno, 32));
      push_x(cols, gap, tail);
      -- fk33_llama_top S_GO: x_exp written the cycle after the last push, and
      -- the adapter's first write two cycles later
      a_x_exp <= std_logic_vector(to_unsigned(seed * 1000 + 77, 32));
      sclk(2);
      lite_write(0, x"0000_1000", "00");
      -- the previous job's done must have been cleared by the accepted write
      chk(a_job_done = '0', "a_job_done still HIGH after the LO write");
      if bad_hi then
        lite_write(4, x"0000_0000", "10");
      else
        lite_write(4, x"0000_0000", "00");
      end if;
      lite_write(8, x"0000_0001", "00");
      run_job(expect_fault);
    end procedure;

  begin
    -- ------------------------------------------------------------ reset
    s_rstn <= '0'; m_rstn <= '0';
    wait for 100 ns;
    m_rstn <= '1';        -- the engine domain releases FIRST here ...
    wait for 200 ns;
    s_rstn <= '1';        -- ... and the card domain later; the swap below
    sclk(4);              -- covers the other order

    -- ============================================================
    -- PHASE 1: card 13.333 ns, engine 5 ns (the shipped ratio)
    -- ============================================================
    report "PHASE 1: card 13.333 ns / engine 5 ns";
    do_job(64, 8, 1, 0, 0, false, false);
    do_job(4096, 256, 2, 0, 0, false, false);   -- the largest job: 256 beats back to back
    do_job(1, 1, 3, 0, 0, false, false);
    do_job(300, 0, 4, 0, 0, false, false);      -- a job with no beats at all
    do_job(128, 17, 5, 0, 0, true, false);      -- SLVERR on HI comes back as-is
    chk(cdc_fault = '0', "cdc_fault raised in phase 1");
    chk(a_job_err = '0', "a_job_err raised in phase 1");

    -- ============================================================
    -- PHASE 2: SWAPPED, card 5 ns, engine 13.333 ns.  x pushes are
    -- throttled to one per 3 card cycles (15 ns > 13.333 ns).  This is the
    -- ratio under which the x-before-write ordering (1) is NOT free.
    -- ============================================================
    report "PHASE 2: card 5 ns / engine 13.333 ns (swapped), x throttled";
    s_rstn <= '0'; m_rstn <= '0';
    wait for 50 ns;
    s_per <= 5000 ps; m_per <= 13333 ps;
    wait for 100 ns;
    s_rstn <= '1';        -- the card domain releases FIRST this time
    wait for 200 ns;
    m_rstn <= '1';
    sclk(8);
    do_job(64, 8, 6, 4, 12, false, false);     -- 12-element tail burst queued at the write
    do_job(1024, 100, 7, 4, 12, false, false);
    do_job(2, 3, 8, 4, 0, false, false);
    chk(cdc_fault = '0', "cdc_fault raised in phase 2");

    -- ============================================================
    -- PHASE 3: x FIFO overflow, swapped ratio, pushes back to back.
    -- 64 elements at 5 ns into a consumer at 13.333 ns overflow a 16-deep
    -- FIFO; the wrapper must flag it, not silently drop.
    -- ============================================================
    report "PHASE 3: x overflow (expected fault)";
    do_job(64, 4, 9, 0, 0, false, true);
    chk(cdc_fault = '1', "x overflow did not raise cdc_fault");
    chk(a_job_err = '1', "x overflow did not raise a_job_err");
    chk(e_x_count < 64, "phase 3 control: no element was lost, so the phase "
        & "did not exercise the overflow at all");

    -- ============================================================
    -- PHASE 4: back to the shipped ratio after a reset (the fault clears),
    -- then a burst past Y_DEPTH: 700 beats at 5 ns draining at 13.333 ns
    -- leaves ~437 resident against 256.  Must flag, and done must still
    -- arrive after everything that was kept.
    -- ============================================================
    report "PHASE 4: reset clears the fault; y overflow (expected fault)";
    s_rstn <= '0'; m_rstn <= '0';
    wait for 50 ns;
    s_per <= 13333 ps; m_per <= 5000 ps;
    wait for 100 ns;
    m_rstn <= '1';
    wait for 100 ns;
    s_rstn <= '1';
    sclk(8);
    chk(cdc_fault = '0', "cdc_fault did not clear on reset");
    chk(a_job_err = '0', "a_job_err did not clear on reset");
    do_job(32, 6, 10, 0, 0, false, false);
    chk(cdc_fault = '0', "cdc_fault raised on a clean job after reset");
    do_job(32, 700, 11, 0, 0, false, true);
    chk(cdc_fault = '1', "y overflow did not raise cdc_fault");
    chk(a_job_err = '1', "y overflow did not raise a_job_err");
    chk(beats_seen < 700 and beats_seen >= 256,
        "phase 4 control: " & integer'image(beats_seen) & " beats seen; the "
        & "burst did not overflow, or the FIFO kept fewer than its depth");

    -- ============================================================
    -- PHASE 5: the engine's sticky err level crosses
    -- ============================================================
    report "PHASE 5: d_job_err";
    s_rstn <= '0'; m_rstn <= '0';
    wait for 100 ns;
    m_rstn <= '1'; s_rstn <= '1';
    sclk(8);
    chk(a_job_err = '0', "a_job_err not clear after reset");
    d_job_err <= '1';
    sclk(6);
    chk(a_job_err = '1', "d_job_err did not reach a_job_err");
    d_job_err <= '0';   -- the real level is sticky; the bench releases it
    sclk(6);

    n_chk_card  <= nchk;
    n_fail_card <= nfail;
    card_finished <= true;
    eng_done_reporting <= true;
    wait until rising_edge(m_clk);
    wait until rising_edge(m_clk);
    wait until rising_edge(m_clk);

    report "tb_eng_cdc: checks card=" & integer'image(nchk)
         & " eng=" & integer'image(n_chk_eng)
         & " fails card=" & integer'image(nfail)
         & " eng=" & integer'image(n_fail_eng);
    if nfail = 0 and n_fail_eng = 0 then
      report "tb_eng_cdc: PASS  checks=" & integer'image(nchk + n_chk_eng);
    else
      report "tb_eng_cdc: FAIL  fails=" & integer'image(nfail + n_fail_eng)
        severity failure;
    end if;
    run_clocks <= false;
    wait;
  end process;

end architecture;
