-- sim/tb_axi_rd_port.vhd -- axi_rd_port against a behavioural AXI4 slave.
--
-- The slave answers with a data word derived from the address, so an out-of-
-- order or dropped beat shows up as a specific wrong address rather than as
-- generic corruption.  It injects random AR and R stalls, because a read port
-- that only works against a zero-latency always-ready slave has not been
-- tested at all.
--
-- CONSUMER BACKPRESSURE -- the generic QSTALL, added 2026-08-29 (TRACK ACOV).
-- Before it, this bench held `q_ready` high for the whole of every job, so the
-- FIFO drained as fast as the slave could fill it and its level never rose.
-- The entire reason axi_rd_port plumbs `f_level` and `LVL_MARGIN` out of the
-- FIFO and into axi_rd_fsm is so the AR issue can be throttled against FIFO
-- FREE SPACE (`f_level + pr + want <= DEPTH`, rtl/axi_rd_fsm.vhd:223), and a
-- bench whose FIFO stays near empty never makes that comparison decide
-- anything.  MEASURED by sim/mutate_axi_rd_port.sh: at QSTALL=0 eleven of its
-- twenty mutations survived, and telling the FSM the FIFO is twice as deep as
-- it is (C1), building the FIFO half the depth the FSM throttles against (C2)
-- and collapsing LVL_MARGIN on one side only (A9) were among them.
--
-- WHAT THIS DOES *NOT* BUY, stated because the obvious expectation is wrong.
-- It does not make `rready` fall.  The throttle above is precisely the
-- guarantee that outstanding-plus-queued beats never exceed DEPTH, so in a
-- CORRECT axi_rd_port the FIFO is never full, `f_ir` is high always, and
-- `rready` is high always -- at every QSTALL.  The occupancy witness below is
-- therefore built from the boundary counts, not from `rready`.
--
-- QSTALL defaults to 0, so the row sim/regress.sh runs is bit-for-bit the run
-- it ran before this generic existed; the stalling configurations are reached
-- from the mutation script and from sim/run_matvec.sh.
--
-- SEED IS BOUNDED BY 8.  The slave's LFSR seeds itself with SEED*7919 + 1
-- through a 16-bit to_unsigned, which TRUNCATES above SEED = 8 and prints a
-- numeric_std warning at time 0.  Harmless -- it only picks a different LFSR
-- start -- but it is noise in a mutation log, so callers stay under it.
--
-- The last case is the one that matters most: 7.7 says the FIFO must be FLUSHED
-- on start, because sub-regions are padded to whole 4 KB bursts and the burst
-- carrying the final needed beat also delivers padding beats that stay resident
-- when the job ends.  The residue differs per port, so without a flush the next
-- job's stream is misaligned by a per-port-varying amount -- silently.  So the
-- test abandons a job part-consumed and checks the NEXT job starts at its own
-- first beat.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_axi_rd_port is
  generic(SEED : integer := 1; STALL : natural := 3;
          MAXOUT : positive := 2; DEPTH : positive := 64;
          -- Consumer-side stall modulus.  0 or 1 = never stall, which is the
          -- historical behaviour and the gate row's; N > 1 withholds q_ready
          -- on roughly one LFSR draw in N.  See the header.
          QSTALL : natural := 0;
          -- Largest ARLEN this slave will accept, i.e. burst length minus one.
          -- 15 is the AXI3 cap and therefore the FK33's HBM cap; see the
          -- ARLEN paragraph in the header.  Raise it only to test a slave that
          -- really is AXI4.
          ARLEN_MAX : natural := 15;
          -- THE THROTTLE INVARIANT, added 2026-08-29 (TRACK ASURV).
          -- rtl/axi_rd_fsm.vhd:223 issues a burst only while
          --     f_level + pr + want <= DEPTH
          -- and rtl/axi_rd_port.vhd's header states the consequence in as many
          -- words: "the AR throttle is against FIFO FREE SPACE including beats
          -- already requested, so MAXOUT can never make the FIFO overrun."
          -- The observable form of that promise is that the port NEVER has to
          -- refuse a beat the slave is offering, i.e. `rvalid and not rready`
          -- is 0 on every cycle of every legal trace.  MEASURED 0 in eight
          -- configurations of the unmutated port, including QSTALL up to 9.
          --
          -- Refusing a beat is legal AXI and costs no data -- the slave holds
          -- it.  What it means is that the throttle stopped being the thing
          -- that decides when an AR goes out, and on the FK33 that is 27
          -- masters holding the HBM's R channel against each other rather than
          -- against their own FIFOs.  So this is an invariant on the FSM's
          -- contract, NOT a data-corruption check, and it is stated that way.
          --
          -- false is the ATTRIBUTION CONTROL for the two rows it kills.
          CHK_FLOW : boolean := true);
end entity;

architecture sim of tb_axi_rd_port is
  constant AXI_DW : positive := 128;
  constant ADDR_W : positive := 32;
  constant BYTES  : positive := AXI_DW / 8;

  signal clk, rst : std_logic := '0';
  signal start    : std_logic := '0';
  signal base     : std_logic_vector(ADDR_W-1 downto 0) := (others => '0');
  signal n_beats  : integer := 0;

  signal arvalid, arready, rvalid, rready, rlast : std_logic := '0';
  signal araddr : std_logic_vector(ADDR_W-1 downto 0);
  signal arlen  : std_logic_vector(7 downto 0);
  signal arsize : std_logic_vector(2 downto 0);
  signal arburst: std_logic_vector(1 downto 0);
  signal rdata  : std_logic_vector(AXI_DW-1 downto 0) := (others => '0');

  signal q_valid, q_ready : std_logic := '0';
  signal q_data : std_logic_vector(AXI_DW-1 downto 0);

  signal finished : boolean := false;
  signal nbad : integer := 0;

  -- COVERAGE WITNESS, not a check.  The FIFO's high-water mark, derived at the
  -- BOUNDARY as (beats accepted on R) - (beats popped on Q), so it needs no
  -- visibility into the DUT.  It answers the one question the mutation table
  -- cannot answer for itself: did the FSM's AR throttle -- `f_level + pr +
  -- want <= DEPTH` at rtl/axi_rd_fsm.vhd:223, the reason `f_level` and
  -- `LVL_MARGIN` are plumbed out of the FIFO at all -- ever actually BIND?
  --
  -- Do NOT expect `rready` to fall instead.  That throttle is exactly the
  -- guarantee that requested beats never exceed DEPTH, so in a CORRECT
  -- axi_rd_port `f_ir` is high always and `rready` is high always; a witness
  -- built on `rvalid and not rready` measures something this design makes
  -- impossible and reads 0 no matter what the consumer does.  That was
  -- MEASURED here first, and it is also why counting a beat on `rvalid` alone
  -- is an EQUIVALENT mutant rather than a coverage gap (row A5 of
  -- sim/mutate_axi_rd_port.sh).
  --
  -- CORRECTION 2026-08-29 (TRACK ASURV).  The line that stood here said
  -- "`track` excludes the abandoned job's drain window".  IT DOES NOT, and the
  -- number below is an OVER-COUNT by however many beats that drain discards.
  -- `track` is raised immediately after `start`, and the drain is what the
  -- port does immediately after `start`: those beats are accepted on R with
  -- `rready` forced high and thrown away without ever entering the FIFO, and
  -- this counter counts every one of them in.
  --
  -- MEASURED, unmutated port, -gMAXOUT=16 -gDEPTH=32 -gSTALL=0 -gQSTALL=7
  -- -gSEED=2: occ_hi = 41.  A DEPTH=32 stream_fifo holds at most
  -- mcnt(32) + ocnt(2) + inflight(1) = 35 words, so 41 is not an occupancy at
  -- all.  The gate row's own configuration (DEPTH=64, QSTALL=0) reports 26 and
  -- is not affected, which is why this went unnoticed.
  --
  -- It is left as a WITNESS and deliberately NOT turned into a check: an
  -- honest occupancy needs the FIFO's own `level`, which this port does not
  -- expose.  Read it as an upper bound, never as the FIFO's high-water mark.
  signal track  : std_logic := '0';
  signal occ    : integer := 0;
  signal occ_hi : integer := 0;

  -- Cycles on which the slave offered a beat and the port would not take it.
  signal n_refuse : integer := 0;
begin
  rst <= '1', '0' after 40 ns;

  -- The throttle invariant's witness.  Unconditional: the count is reported
  -- either way, and CHK_FLOW governs only whether it is ASSERTED on, so the
  -- attribution control still prints the number that would have failed.
  refusal : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '0' and rvalid = '1' and rready = '0' then
        n_refuse <= n_refuse + 1;
      end if;
    end if;
  end process;

  occup : process(clk)
    variable o : integer;
  begin
    if rising_edge(clk) then
      if rst = '1' or start = '1' then
        occ <= 0;
      elsif track = '1' then
        o := occ;
        if rvalid = '1' and rready = '1' then o := o + 1; end if;
        if q_valid = '1' and q_ready = '1' then o := o - 1; end if;
        occ <= o;
        if o > occ_hi then occ_hi <= o; end if;
      end if;
    end if;
  end process;

  clkgen : process
  begin
    while not finished loop
      clk <= '0'; wait for 5 ns; clk <= '1'; wait for 5 ns;
    end loop;
    wait;
  end process;

  dut : entity work.axi_rd_port
    generic map(AXI_DW => AXI_DW, ADDR_W => ADDR_W, DEPTH => DEPTH,
                MAXB => 16, MAXOUT => MAXOUT)
    port map(clk => clk, rst => rst, start => start, base => base,
             n_beats => n_beats,
             arvalid => arvalid, arready => arready, araddr => araddr,
             arlen => arlen, arsize => arsize, arburst => arburst,
             rvalid => rvalid, rready => rready, rdata => rdata, rlast => rlast,
             q_valid => q_valid, q_data => q_data, q_ready => q_ready);

  -- ------------------------------------------------------- behavioural slave
  slave : process
    variable lf   : unsigned(15 downto 0) := to_unsigned(SEED*7919 + 1, 16);
    variable a    : unsigned(ADDR_W-1 downto 0);
    variable n    : integer;
    procedure tick is
    begin
      wait until rising_edge(clk);
      lf := lf(14 downto 0) & (lf(15) xor lf(13) xor lf(12) xor lf(10));
    end procedure;
  begin
    arready <= '0'; rvalid <= '0'; rlast <= '0';
    wait until rst = '0';   -- else the first delta samples arvalid as 'U'
    loop
      -- accept an AR, after a random delay
      arready <= '0';
      while arvalid = '0' loop tick; end loop;
      if STALL /= 0 then
        while (to_integer(lf) mod STALL) = 0 loop tick; end loop;
      end if;
      a := unsigned(araddr);
      n := to_integer(unsigned(arlen)) + 1;
      assert arburst = "01" report "burst type must be INCR" severity failure;
      assert to_integer(unsigned(arsize)) = 4
        report "arsize must match AXI_DW" severity failure;
      -- THE AXI3 BURST CAP.  ARLEN is eight bits on AXI4 and this port emits
      -- eight bits, but the FK33's HBM slave is AXI3, where ARLEN is FOUR --
      -- so 16 beats is the hard cap on the card and a 17-beat burst is not a
      -- slow burst, it is a burst the slave will not answer.  Before this
      -- assert existed, raising the FSM's MAXB to 256 produced ARLEN=255 here
      -- and the bench reported 0 bad beats (MEASURED, 2026-08-29, row C5 of
      -- sim/mutate_axi_rd_port.sh), because a behavioural slave will happily
      -- answer a burst no real slave would.
      assert to_integer(unsigned(arlen)) <= ARLEN_MAX
        report "ARLEN " & integer'image(to_integer(unsigned(arlen))) &
               " exceeds " & integer'image(ARLEN_MAX) &
               " -- the FK33's HBM slave is AXI3 and cannot answer this burst"
        severity failure;
      arready <= '1'; tick; arready <= '0';

      -- return n beats, data = the beat's own word address
      for i in 0 to n-1 loop
        if STALL /= 0 then
          rvalid <= '0';
          while (to_integer(lf) mod STALL) = 0 loop tick; end loop;
        end if;
        rdata <= std_logic_vector(resize(a / BYTES, AXI_DW));
        rvalid <= '1';
        if i = n-1 then rlast <= '1'; else rlast <= '0'; end if;
        loop
          tick;
          exit when rready = '1';
        end loop;
        a := a + BYTES;
      end loop;
      rvalid <= '0'; rlast <= '0';
    end loop;
  end process;

  -- ------------------------------------------------------------------ driver
  drv : process
    variable got, want : integer;
    variable nb : integer := 0;
    -- The consumer's own LFSR, deliberately seeded differently from every
    -- slave's so the consumer's stalls do not fall in step with the R-channel
    -- stalls -- if they did, the FIFO would empty exactly as fast as it filled
    -- and QSTALL would buy nothing.
    variable qlf : unsigned(15 downto 0) := to_unsigned(SEED*31 + 12007, 16);

    -- One clock, advancing the consumer LFSR.  A separate procedure so that
    -- every wait in this process draws, including the ones inside the stall
    -- loop; a draw that only advances while NOT stalling gives a stall length
    -- that is either 0 or infinite.
    procedure qtick is
    begin
      wait until rising_edge(clk);
      qlf := qlf(14 downto 0) & (qlf(15) xor qlf(13) xor qlf(12) xor qlf(10));
    end procedure;

    procedure run_job(constant bs : integer; constant nbe : integer;
                      constant consume : integer; constant nm : string) is
    begin
      base    <= std_logic_vector(to_unsigned(bs, ADDR_W));
      n_beats <= nbe;
      wait until rising_edge(clk);
      start <= '1'; wait until rising_edge(clk); start <= '0';
      track <= '1';
      for i in 0 to consume-1 loop
        -- WITHHOLD q_ready first, so the FIFO backs up towards its high-water
        -- mark and the FSM's free-space throttle is the thing that decides
        -- when the next AR goes out.  With QSTALL <= 1 this loop is skipped
        -- entirely and the timing below is the historical one.
        if QSTALL > 1 then
          q_ready <= '0';
          while (to_integer(qlf) mod QSTALL) = 0 loop qtick; end loop;
        end if;
        q_ready <= '1';
        loop
          qtick;
          exit when q_valid = '1';
        end loop;
        got  := to_integer(unsigned(q_data));
        want := bs / BYTES + i;
        if got /= want then
          nb := nb + 1;
          if nb < 6 then
            report nm & ": beat " & integer'image(i) &
                   " got "  & integer'image(got) &
                   " want " & integer'image(want) severity error;
          end if;
        end if;
      end loop;
      q_ready <= '0';
      track   <= '0';
      wait until rising_edge(clk);
    end procedure;
  begin
    q_ready <= '0';
    wait until rst = '0';
    wait until rising_edge(clk);

    run_job(16#1000#, 64,  64, "job1 full");
    run_job(16#3000#, 48,  48, "job2 short-of-burst");
    -- ABANDON a job part-consumed, then start another: without the flush of
    -- 7.7 the residue would be delivered as job4's first beats.
    run_job(16#5000#, 64,  20, "job3 abandoned");
    run_job(16#9000#, 32,  32, "job4 after abandon");

    nbad <= nb;
    wait until rising_edge(clk);
    report "axi_rd_port: " & integer'image(nbad) & " bad beats" &
           " (QSTALL=" & integer'image(QSTALL) &
           ", occupancy upper bound " & integer'image(occ_hi) &
           " of DEPTH " & integer'image(DEPTH) &
           ", R beats refused " & integer'image(n_refuse) & ")" severity note;
    assert nbad = 0 report "axi_rd_port DELIVERED THE WRONG BEATS"
      severity failure;
    if CHK_FLOW then
      assert n_refuse = 0
        report "THE THROTTLE DID NOT HOLD: the port refused an offered R beat "
             & "on " & integer'image(n_refuse) & " cycles.  "
             & "rtl/axi_rd_fsm.vhd's f_level + pr + want <= DEPTH exists so "
             & "that this cannot happen -- an AR is issued only against free "
             & "space the FIFO already has.  No data is lost (the slave holds "
             & "the beat), so nbad is still 0; what is lost is the guarantee, "
             & "and on the FK33 that is 27 masters back-pressuring one HBM "
             & "R channel instead of their own FIFOs."
        severity failure;
    end if;
    finished <= true;
    wait;
  end process;
end architecture;
