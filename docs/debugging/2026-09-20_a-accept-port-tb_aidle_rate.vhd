-- tb_aidle_rate.vhd -- TRACK AIDLE, 2026-09-20.
--
-- DESCENDED FROM docs/debugging/2026-08-30_counters-tb_ctr_rate.vhd, TRACK
-- COUNTERS' bench, and it is under docs/debugging/ for that file's reason and
-- no other: sim/regress.sh globs sim/tb_*.vhd off the FILESYSTEM, so dropping
-- a new bench there while three tracks are running turns the shared gate red
-- until BASELINE_PASS moves.
--
-- WHAT IS NEW HERE, against the parent bench:
--
--   1. FAST_POP is plumbed to the DUT, so the SAME bench measures the
--      shipping cadence and the lever, one variable, no re-analysis.
--   2. The stall is SPLIT BY REASON rather than reported as one STARVED
--      total.  The parent bench measured `RESID` -- w_valid high and the word
--      not taken -- and could not say whether it was the scale path, the
--      activation queue or a control state.  matvec_int4 now publishes
--      dbg_sstarve, so W and S are separated at the port and only the
--      activation queue and the control states remain in one bucket.
--   3. The y stream is dumped to a file, so bit-identity of the RESULT
--      between FAST_POP false and true is a `cmp`, not an argument.
--
-- IT IS STILL NOT A VALUE ORACLE.  Bit-identity across the lever says the
-- lever changed nothing; it says nothing about whether the numbers are right.
-- That is sim/tb_matvec_core.vhd against ref/matvec_int4.c, and the gate rows
-- named in this track''s write-up.
--
-- IT IS STILL SINGLE CLOCK, as the parent was.  The card is DUAL_CLK, i.e.
-- rtl/async_fifo.vhd rather than rtl/stream_fifo.vhd -- and the two files
-- carry the IDENTICAL `do_rd` line, which is why the single-clock number
-- transfers.  The dual-clock cross-check is a separate bench.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_aidle_rate is
  generic(
    RI      : positive := 48;
    NPW     : positive := 24;
    NPS     : positive := 3;
    AXI_DW  : positive := 256;
    BLK     : positive := 32;
    ADDR_W  : positive := 64;
    MAXCOLS : positive := 4096;
    MAXROWS : positive := 192;
    FDEPTH  : positive := 512;
    MAXB    : positive := 16;
    MAXOUT  : positive := 16;
    -- job
    N_ROWS  : positive := 100;
    N_COLS  : positive := 4096;
    -- memory model
    LAT     : natural  := 0;
    UNLIM   : boolean  := true;
    GNUM    : positive := 1;
    GDEN    : positive := 1;
    TAG     : string   := "ideal";
    -- the lever under test
    FAST_POP : boolean := false;
    -- where to write the y stream; "" disables the dump
    YDUMP   : string   := ""
  );
end entity;

architecture sim of tb_aidle_rate is
  constant NP : positive := NPW + NPS;

  signal clk  : std_logic := '0';
  signal rst  : std_logic := '1';
  signal start : std_logic := '0';
  signal finished : boolean := false;

  signal v_rows, v_cols, v_osh, v_wexp, v_xexp : std_logic_vector(31 downto 0)
        := (others => '0');
  signal v_wbeats, v_sbeats, v_yexp : std_logic_vector(31 downto 0)
        := (others => '0');
  signal out_mode : std_logic_vector(1 downto 0) := "00";

  signal cb_we   : std_logic := '0';
  signal cb_addr : std_logic_vector(3 downto 0) := (others => '0');
  signal cb_data : std_logic_vector(7 downto 0) := (others => '0');

  signal w_base : std_logic_vector(NPW*ADDR_W-1 downto 0) := (others => '0');
  signal s_base : std_logic_vector(NPS*ADDR_W-1 downto 0) := (others => '0');

  signal x_we    : std_logic := '0';
  signal x_waddr : std_logic_vector(15 downto 0) := (others => '0');
  signal x_wdata : std_logic_vector(15 downto 0) := (others => '0');

  signal m_arvalid, m_arready, m_rvalid, m_rready, m_rlast :
    std_logic_vector(NP-1 downto 0) := (others => '0');
  signal m_araddr  : std_logic_vector(NP*ADDR_W-1 downto 0);
  signal m_arlen   : std_logic_vector(NP*8-1 downto 0);
  signal m_arsize  : std_logic_vector(NP*3-1 downto 0);
  signal m_arburst : std_logic_vector(NP*2-1 downto 0);
  signal m_rdata   : std_logic_vector(NP*AXI_DW-1 downto 0) := (others => '0');

  signal y_we   : std_logic;
  signal y_addr : std_logic_vector(15 downto 0);
  signal y_data : std_logic_vector(RI*64-1 downto 0);
  signal y_mask : std_logic_vector(RI-1 downto 0);
  signal done, err, sat_event : std_logic;
  signal dbg_wbeat, dbg_wstarve, dbg_sstarve : std_logic;

  -- the three counters, EXACTLY as rtl/matvec_int4_desc_axi.vhd:924-926
  -- increments them (in S_WAIT, i.e. between core_start and core_done)
  signal busy     : std_logic := '0';
  signal c_cycles : integer := 0;
  signal c_beats  : integer := 0;
  signal c_starve : integer := 0;
  -- the residual: w_valid was high and the core did not take the word
  signal c_resid  : integer := 0;
  -- the residual, SPLIT.  c_sstall is w_valid high and s_valid low, which is
  -- the scale path; c_other is everything left -- the activation prefetch
  -- queue empty, and the S_IDLE/S_DRAIN/S_SCAN/S_EMIT/S_DONE control states,
  -- which this bench does not separate and does not claim to.
  signal c_sstall : integer := 0;
  signal c_other  : integer := 0;
begin
  clkgen : process
  begin
    while not finished loop
      clk <= '0'; wait for 5 ns; clk <= '1'; wait for 5 ns;
    end loop;
    wait;
  end process;

  rst <= '1', '0' after 40 ns;

  dut : entity work.matvec_int4
    generic map(BLK => BLK, ROWS_IF => RI, NPORTS_W => NPW, NPORTS_S => NPS,
                AXI_DW => AXI_DW, ADDR_W => ADDR_W,
                MAXCOLS => MAXCOLS, MAXROWS_BFP => MAXROWS,
                FIFO_DEPTH => FDEPTH, MAXB => MAXB, MAXOUT => MAXOUT,
                DUAL_CLK => false, FAST_POP => FAST_POP)
    port map(clk => clk, rst => rst, aclk => '0', start => start,
             n_rows => v_rows, n_cols => v_cols, out_shift => v_osh,
             w_exp => v_wexp, x_exp => v_xexp, out_mode => out_mode,
             w_base => w_base, w_beats => v_wbeats,
             s_base => s_base, s_beats => v_sbeats,
             cb_we => cb_we, cb_addr => cb_addr, cb_data => cb_data,
             x_we => x_we, x_waddr => x_waddr, x_wdata => x_wdata,
             m_arvalid => m_arvalid, m_arready => m_arready,
             m_araddr => m_araddr, m_arlen => m_arlen,
             m_arsize => m_arsize, m_arburst => m_arburst,
             m_rvalid => m_rvalid, m_rready => m_rready,
             m_rdata => m_rdata, m_rlast => m_rlast,
             y_we => y_we, y_addr => y_addr, y_data => y_data,
             y_mask => y_mask, y_exp => v_yexp,
             done => done, err => err, sat_event => sat_event,
             dbg_wbeat => dbg_wbeat, dbg_wstarve => dbg_wstarve,
             dbg_sstarve => dbg_sstarve);

  -- ------------------------------------------------------ the memory model
  -- One process, all NP ports, one shared beat budget.
  mem : process(clk)
    constant QD : integer := 64;                 -- burst queue depth per port
    type ilen_t is array(0 to QD-1) of integer;
    type q_t    is array(0 to NP-1) of ilen_t;
    variable q      : q_t := (others => (others => 0));
    -- PER-BURST LATENCY COUNTDOWN, ADDED BY TRACK AIDLE 2026-09-20, AND THE
    -- REASON IT HAD TO BE.  The parent bench's own trap list says it outright:
    -- "my slave applies LAT to the HEAD of each port's burst queue, so burst
    -- k's latency starts only after burst k-1 has fully delivered.  That is
    -- SERIALISED latency, not outstanding-request pipelining ... It is my
    -- model failing to model MAXOUT at all."  A sweep of MAXOUT against that
    -- model measures the model.  Here every queued burst carries its OWN
    -- countdown, started when its AR was ACCEPTED, and they all run
    -- concurrently -- which is what an outstanding read is.
    type qlat_t is array(0 to QD-1) of integer;
    type ql_t   is array(0 to NP-1) of qlat_t;
    variable ql     : ql_t := (others => (others => 0));
    type ia is array(0 to NP-1) of integer;
    variable qh, qt, qn : ia := (others => 0);   -- head, tail, count
    variable rem_b  : ia := (others => 0);       -- beats left in head burst
    variable latc   : ia := (others => 0);
    variable armed  : ia := (others => 0);       -- head burst has been started
    variable credit : integer := 0;
    variable rr     : integer := 0;
    variable p      : integer;
    variable free   : boolean;
    variable grant  : boolean;
    variable dcnt   : ia := (others => 1);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        qh := (others => 0); qt := (others => 0); qn := (others => 0);
        rem_b := (others => 0); latc := (others => 0); armed := (others => 0);
        credit := 0; rr := 0;
        m_arready <= (others => '0');
        m_rvalid  <= (others => '0');
        m_rlast   <= (others => '0');
      else
        -- AR: accept whatever is offered, one per port per cycle
        for i in 0 to NP-1 loop
          if m_arvalid(i) = '1' and qn(i) < QD then
            q(i)(qt(i)) := to_integer(unsigned(m_arlen((i+1)*8-1 downto i*8))) + 1;
            ql(i)(qt(i)) := LAT;          -- this burst's clock starts NOW
            qt(i) := (qt(i) + 1) mod QD;
            qn(i) := qn(i) + 1;
            m_arready(i) <= '1';
          else
            m_arready(i) <= '0';
          end if;
        end loop;

        -- every OUTSTANDING burst's countdown runs, concurrently
        for i in 0 to NP-1 loop
          for k in 0 to QD-1 loop
            if ql(i)(k) > 0 then ql(i)(k) := ql(i)(k) - 1; end if;
          end loop;
        end loop;

        -- head-of-queue arming.  The head's remaining latency is its OWN,
        -- already counted down while it sat behind other bursts.
        for i in 0 to NP-1 loop
          if armed(i) = 0 and qn(i) > 0 then
            armed(i) := 1;
            rem_b(i) := q(i)(qh(i));
          end if;
          if armed(i) = 1 then latc(i) := ql(i)(qh(i)); end if;
        end loop;

        -- shared beat budget
        credit := credit + GNUM;

        -- round robin over the ports
        for k in 0 to NP-1 loop
          p := (rr + k) mod NP;
          free := (m_rvalid(p) = '0') or (m_rready(p) = '1');
          grant := free and armed(p) = 1 and latc(p) = 0 and rem_b(p) > 0;
          if grant and not UNLIM then
            if credit >= GDEN then credit := credit - GDEN;
            else grant := false; end if;
          end if;
          if grant then
            m_rvalid(p) <= '1';
            m_rdata((p+1)*AXI_DW-1 downto p*AXI_DW) <=
              std_logic_vector(to_unsigned((dcnt(p) * 37) mod 65536, AXI_DW));
            dcnt(p) := (dcnt(p) + 1) mod 65536;
            if rem_b(p) = 1 then m_rlast(p) <= '1';
            else m_rlast(p) <= '0'; end if;
            rem_b(p) := rem_b(p) - 1;
            if rem_b(p) = 0 then
              qh(p) := (qh(p) + 1) mod QD;
              qn(p) := qn(p) - 1;
              armed(p) := 0;
            end if;
          elsif free then
            m_rvalid(p) <= '0';
            m_rlast(p)  <= '0';
          end if;
        end loop;
        rr := (rr + 1) mod NP;
        if credit > 4 * GDEN then credit := 4 * GDEN; end if;  -- no hoarding
      end if;
    end if;
  end process;

  -- ------------------------------------------------------- the counters
  ctr : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        busy <= '0'; c_cycles <= 0; c_beats <= 0; c_starve <= 0; c_resid <= 0;
        c_sstall <= 0; c_other <= 0;
      else
        if start = '1' then
          busy <= '1'; c_cycles <= 0; c_beats <= 0; c_starve <= 0; c_resid <= 0;
          c_sstall <= 0; c_other <= 0;
        elsif busy = '1' then
          c_cycles <= c_cycles + 1;
          if dbg_wbeat = '1' then c_beats <= c_beats + 1; end if;
          if dbg_wstarve = '1' then c_starve <= c_starve + 1; end if;
          if dbg_wstarve = '0' and dbg_wbeat = '0' then
            c_resid <= c_resid + 1;
            -- and the split.  dbg_sstarve is `wv and not sv`, so these two
            -- arms partition the residual exactly and cannot both fire.
            if dbg_sstarve = '1' then c_sstall <= c_sstall + 1;
            else                      c_other  <= c_other + 1; end if;
          end if;
          if done = '1' then busy <= '0'; end if;
        end if;
      end if;
    end if;
  end process;

  -- ------------------------------------------------- the y stream, dumped
  -- Every y_we cycle, in order, with its address and the whole ROWS_IF-wide
  -- payload and the mask.  Comparing two runs' files is the bit-identity
  -- evidence for the lever; it is a diff of the DUT''s output port, not a
  -- round trip through anything this bench also wrote.
  --
  -- THE FILE IS CLOSED EXPLICITLY, AND THE FIRST VERSION OF THIS BENCH WAS
  -- NOT.  MEASURED 2026-09-20: without `file_close` before `std.env.stop`,
  -- GHDL leaves the buffered lines unwritten and BOTH runs produce a
  -- ZERO-BYTE file -- which a `cmp -s` then calls BIT_IDENTICAL.  That is a
  -- guard passing over an object it never read, the defect class CLAUDE.md
  -- names, and it reported a clean pass on the first attempt.  The `lines=`
  -- and `bytes=` fields in the AIDLE_IDENT line exist so the pass cannot be
  -- believed without also reading how much was compared, and the runner
  -- refuses a zero-line comparison outright.
  ydumpp : process(clk, finished)
    file f : text;
    variable fst : boolean := true;
    variable opn : boolean := false;
    variable l   : line;
  begin
    if finished and opn then
      file_close(f);
      opn := false;
    end if;
    if rising_edge(clk) and YDUMP /= "" then
      if fst then
        file_open(f, YDUMP, write_mode);
        fst := false; opn := true;
      end if;
      if y_we = '1' then
        -- HEX, NOT to_integer, AND THE PARENT BENCH ALREADY WARNED ABOUT THIS.
        -- docs/debugging/2026-08-30_counters-cycles-beats-starved.md trap 1:
        -- "VHDL integer is 32-bit signed; that is an elaboration-time-legal,
        -- runtime-fatal overflow".  MEASURED 2026-09-20: the first version of
        -- this process wrote `to_integer(unsigned(y_mask))` over a 48-bit
        -- mask and `to_integer(signed(...))` over a 64-bit lane, and GHDL
        -- died with `overflow detected ... from ieee.numeric_std.to_integer`
        -- -- AFTER the identity comparison had already been written, so the
        -- only thing that caught it was the runner refusing a zero-line
        -- comparison.  to_hstring is lossless and has no range at all.
        write(l, string'("Y "));
        write(l, to_hstring(y_addr));
        write(l, string'(" "));
        write(l, to_hstring(y_mask));
        write(l, string'(" "));
        write(l, to_hstring(y_data));
        writeline(f, l);
      end if;
    end if;
  end process;

  -- --------------------------------------------------------------- stimulus
  stim : process
    variable tiles, nblk, beats : integer;
    procedure tick is begin wait until rising_edge(clk); end procedure;
  begin
    wait until rst = '0';
    tick; tick;

    -- activations
    for i in 0 to N_COLS-1 loop
      x_waddr <= std_logic_vector(to_unsigned(i, 16));
      x_wdata <= std_logic_vector(to_signed(((i * 37) mod 401) - 200, 16));
      x_we    <= '1';
      tick;
    end loop;
    x_we <= '0';
    tick;

    -- codebook: a plain signed ramp, so nothing is all-zero
    for i in 0 to 15 loop
      cb_addr <= std_logic_vector(to_unsigned(i, 4));
      cb_data <= std_logic_vector(to_signed(i - 8, 8));
      cb_we   <= '1';
      tick;
    end loop;
    cb_we <= '0';
    tick; tick;

    tiles := (N_ROWS + RI - 1) / RI;
    nblk  := N_COLS / BLK;
    beats := tiles * nblk;

    v_rows   <= std_logic_vector(to_signed(N_ROWS, 32));
    v_cols   <= std_logic_vector(to_signed(N_COLS, 32));
    v_osh    <= std_logic_vector(to_signed(8, 32));
    v_wexp   <= std_logic_vector(to_signed(0, 32));
    v_xexp   <= std_logic_vector(to_signed(0, 32));
    v_wbeats <= std_logic_vector(to_signed(beats, 32));
    v_sbeats <= std_logic_vector(to_signed(beats, 32));
    for pp in 0 to NPW-1 loop
      w_base((pp+1)*ADDR_W-1 downto pp*ADDR_W) <=
        std_logic_vector(to_unsigned(pp * 1048576, ADDR_W));
    end loop;
    for qq in 0 to NPS-1 loop
      s_base((qq+1)*ADDR_W-1 downto qq*ADDR_W) <=
        std_logic_vector(to_unsigned(33554432 + qq * 1048576, ADDR_W));
    end loop;
    tick; tick;

    start <= '1'; tick; start <= '0';

    for i in 0 to 4000000 loop
      exit when done = '1' or err = '1';
      tick;
    end loop;
    tick;

    -- THE PARTITION.  Every cycle of the CYCLES window increments exactly one
    -- of the four buckets, by construction of the counter process above, so
    -- this is a TAUTOLOGY of that process -- which is exactly the kind of
    -- invariant worth asserting, because it is what a mis-wired dbg_sstarve
    -- breaks.  A `not sv` that forgot the `wv and` would double-count the
    -- weight stalls into S and the sum would exceed CYCLES.
    assert c_beats + c_starve + c_sstall + c_other = c_cycles
      report "tb_aidle_rate: the stall buckets do not partition CYCLES -- "
           & "ACCEPT " & integer'image(c_beats)
           & " + W " & integer'image(c_starve)
           & " + S " & integer'image(c_sstall)
           & " + XCTRL " & integer'image(c_other)
           & " /= CYCLES " & integer'image(c_cycles)
      severity failure;
    -- and the floor: a weight word cannot be consumed faster than one per
    -- cycle, so CYCLES < BEATS is a broken measurement, not a fast one.
    assert c_cycles >= c_beats
      report "tb_aidle_rate: CYCLES below BEATS, which is below the "
           & "structural floor of one weight word per cycle"
      severity failure;
    report "AIDLE_STALL W "     & integer'image(c_starve)  severity note;
    report "AIDLE_STALL S "     & integer'image(c_sstall)  severity note;
    report "AIDLE_STALL XCTRL " & integer'image(c_other)   severity note;
    report "AIDLE_STALL ACCEPT "& integer'image(c_beats)   severity note;
    report "AIDLERATE tag=" & TAG
         & " fast_pop=" & boolean'image(FAST_POP)
         & " lat=" & integer'image(LAT)
         & " maxout=" & integer'image(MAXOUT)
         & " rows=" & integer'image(N_ROWS)
         & " cols=" & integer'image(N_COLS)
         & " expect_beats=" & integer'image(beats)
         & " CYCLES=" & integer'image(c_cycles)
         & " BEATS="  & integer'image(c_beats)
         & " STARVED=" & integer'image(c_starve)
         & " RESID=" & integer'image(c_resid)
         & " CPW_x10000=" & integer'image((c_cycles * 10000) / beats)
         & " err=" & std_logic'image(err);
    finished <= true;
    wait for 100 ns;
    std.env.stop;
    wait;
  end process;
end architecture;
