-- tb_ctr_rate.vhd -- TRACK COUNTERS, 2026-08-30.
--
-- NOT a value oracle and deliberately not one.  It exists to answer ONE
-- question: what rate does subsystem A's datapath consume weight words at,
-- as a function of what the memory system gives it?  The card measures 21.67
-- core cycles per BEATS increment and two readings fit that number:
--
--   (i)  the array is STARVED and the intended rate is ~1 word/cycle;
--   (ii) ~22 cycles/word is the datapath's own arithmetic rate.
--
-- The discriminator is to hold the RTL fixed and move only the memory model.
-- If (ii) were true the rate would not move.
--
-- The AXI slave model is ONE process for all 27 ports with a SHARED beat
-- budget, because that is the thing being modelled: on the card every one of
-- the 27 sub-regions of a tensor lies inside a single 256 MiB HBM segment,
-- i.e. one pseudo-channel, so all 27 masters funnel through one 256-bit AXI
-- slave port that retires one beat per AXI clock.
--
--   GNUM / GDEN : the shared budget.  GNUM beat-credits accrue per CORE
--                 cycle and a beat costs GDEN.  GNUM=GDEN models one beat per
--                 core cycle across all ports; GNUM=5 GDEN=4 models one beat
--                 per AXI cycle with ACLK/CLK = 250/200.
--   UNLIM       : ignore the budget entirely (every port may take a beat every
--                 cycle).  This is the "ideal memory" control.
--   LAT         : AR-to-first-beat latency in cycles, per burst, at the head
--                 of each port's queue.
--
-- This bench is SINGLE CLOCK (DUAL_CLK => false).  The card is DUAL_CLK, and
-- that is stated as a limitation rather than papered over: the clock ratio is
-- modelled in the slave's credit rate, not in a second clock.  What that
-- costs is the CDC's own latency (a few cycles per job), which is far below
-- the effect being measured.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_ctr_rate is
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
    TAG     : string   := "ideal"
  );
end entity;

architecture sim of tb_ctr_rate is
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
  signal dbg_wbeat, dbg_wstarve : std_logic;

  -- the three counters, EXACTLY as rtl/matvec_int4_desc_axi.vhd:924-926
  -- increments them (in S_WAIT, i.e. between core_start and core_done)
  signal busy     : std_logic := '0';
  signal c_cycles : integer := 0;
  signal c_beats  : integer := 0;
  signal c_starve : integer := 0;
  -- the residual: w_valid was high and the core did not take the word
  signal c_resid  : integer := 0;
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
                DUAL_CLK => false)
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
             dbg_wbeat => dbg_wbeat, dbg_wstarve => dbg_wstarve);

  -- ------------------------------------------------------ the memory model
  -- One process, all NP ports, one shared beat budget.
  mem : process(clk)
    constant QD : integer := 64;                 -- burst queue depth per port
    type ilen_t is array(0 to QD-1) of integer;
    type q_t    is array(0 to NP-1) of ilen_t;
    variable q      : q_t := (others => (others => 0));
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
            qt(i) := (qt(i) + 1) mod QD;
            qn(i) := qn(i) + 1;
            m_arready(i) <= '1';
          else
            m_arready(i) <= '0';
          end if;
        end loop;

        -- head-of-queue burst arming and its latency
        for i in 0 to NP-1 loop
          if armed(i) = 0 and qn(i) > 0 then
            armed(i) := 1;
            rem_b(i) := q(i)(qh(i));
            latc(i)  := LAT;
          elsif armed(i) = 1 and latc(i) > 0 then
            latc(i) := latc(i) - 1;
          end if;
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
      else
        if start = '1' then
          busy <= '1'; c_cycles <= 0; c_beats <= 0; c_starve <= 0; c_resid <= 0;
        elsif busy = '1' then
          c_cycles <= c_cycles + 1;
          if dbg_wbeat = '1' then c_beats <= c_beats + 1; end if;
          if dbg_wstarve = '1' then c_starve <= c_starve + 1; end if;
          if dbg_wstarve = '0' and dbg_wbeat = '0' then
            c_resid <= c_resid + 1;
          end if;
          if done = '1' then busy <= '0'; end if;
        end if;
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

    report "CTRRATE tag=" & TAG
         & " rows=" & integer'image(N_ROWS)
         & " cols=" & integer'image(N_COLS)
         & " expect_beats=" & integer'image(beats)
         & " CYCLES=" & integer'image(c_cycles)
         & " BEATS="  & integer'image(c_beats)
         & " STARVED=" & integer'image(c_starve)
         & " RESID=" & integer'image(c_resid)
         & " err=" & std_logic'image(err);
    finished <= true;
    wait for 100 ns;
    std.env.stop;
    wait;
  end process;
end architecture;
