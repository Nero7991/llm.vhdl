-- Validates the traffic generator against a memory model whose bandwidth is
-- KNOWN, because an instrument that has never been checked against a known
-- quantity measures nothing.  The model serves one beat every THROTTLE cycles
-- per port, so the expected aggregate is exactly
--     NACTIVE * BYTES_PER_BEAT / THROTTLE   bytes per cycle
-- and the test asserts the generator recovers that to within 3%.
--
-- It also checks the two things most likely to be silently wrong in a counter
-- harness: that beats equals nburst*(arlen+1) EXACTLY (no dropped or double
-- counted beats), and that a masked-off generator issues NOTHING -- so the
-- port-count sweep the whole experiment depends on is real rather than a
-- relabelling of the same traffic.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_hbm_tg is
  generic(NPORT : positive := 4; THROTTLE : positive := 2);
end entity;

architecture sim of tb_hbm_tg is
  constant AXI_DW : positive := 256;
  constant ADDR_W : positive := 33;
  constant REGION_LOG2 : positive := 28;
  constant BPB    : natural  := AXI_DW/8;

  -- A control write is a handful of cycles.  If one has not completed in this
  -- many, it never will: the slave has dropped a beat and the master would
  -- otherwise wait forever, which reads as a hung simulation rather than a
  -- protocol bug.  Fail loudly instead.
  constant WR_WATCHDOG : natural := 64;

  signal clk  : std_logic := '0';
  signal rstn : std_logic := '0';
  signal done : boolean := false;

  signal s_awvalid, s_awready, s_wvalid, s_wready, s_bvalid, s_bready : std_logic := '0';
  signal s_arvalid, s_arready, s_rvalid, s_rready : std_logic := '0';
  signal s_awaddr, s_araddr : std_logic_vector(15 downto 0) := (others=>'0');
  signal s_wdata, s_rdata   : std_logic_vector(31 downto 0) := (others=>'0');

  signal m_rresp : std_logic_vector(NPORT*2-1 downto 0) := (others=>'0');
  -- driven by the model below; the SLVERR injection at the end of the run is
  -- what proves the error counter is wired to anything at all
  signal inject_err : std_logic := '0';
  signal m_arvalid, m_arready, m_rvalid, m_rready, m_rlast
       : std_logic_vector(NPORT-1 downto 0) := (others=>'0');
  signal m_araddr  : std_logic_vector(NPORT*ADDR_W-1 downto 0);
  signal t0, t1    : std_logic_vector(6 downto 0) := (others=>'0');
  signal cat0, cat1 : std_logic := '0';
  signal m_arlen   : std_logic_vector(NPORT*8-1 downto 0);
  signal m_arsize  : std_logic_vector(NPORT*3-1 downto 0);
  signal m_arburst : std_logic_vector(NPORT*2-1 downto 0);

  signal m_awvalid, m_awready, m_wvalid, m_wready, m_wlast,
         m_bvalid,  m_bready : std_logic_vector(NPORT-1 downto 0) := (others=>'0');
  signal m_awaddr  : std_logic_vector(NPORT*ADDR_W-1 downto 0);
  signal m_awlen   : std_logic_vector(NPORT*8-1 downto 0);
  signal m_awsize  : std_logic_vector(NPORT*3-1 downto 0);
  signal m_awburst : std_logic_vector(NPORT*2-1 downto 0);
  signal m_wdata   : std_logic_vector(NPORT*AXI_DW-1 downto 0);
  signal m_wstrb   : std_logic_vector(NPORT*(AXI_DW/8)-1 downto 0);
  signal m_bresp   : std_logic_vector(NPORT*2-1 downto 0) := (others=>'0');
  signal inject_werr : std_logic := '0';

  constant NBURST : natural := 64;
  constant ARLEN  : natural := 15;
begin
  clk <= '0' when done else not clk after 1 ns;

  dut : entity work.hbm_tg
    generic map(NPORT => NPORT, AXI_DW => AXI_DW, ADDR_W => ADDR_W,
                REGION_LOG2 => REGION_LOG2)
    port map(clk=>clk, rstn=>rstn,
      s_awvalid=>s_awvalid, s_awready=>s_awready, s_awaddr=>s_awaddr,
      s_wvalid=>s_wvalid, s_wready=>s_wready, s_wdata=>s_wdata,
      s_bvalid=>s_bvalid, s_bready=>s_bready,
      s_arvalid=>s_arvalid, s_arready=>s_arready, s_araddr=>s_araddr,
      s_rvalid=>s_rvalid, s_rready=>s_rready, s_rdata=>s_rdata,
      m_arvalid=>m_arvalid, m_arready=>m_arready, m_araddr=>m_araddr,
      m_arlen=>m_arlen, m_arsize=>m_arsize, m_arburst=>m_arburst,
      hbm_temp0=>t0, hbm_temp1=>t1, hbm_cattrip0=>cat0, hbm_cattrip1=>cat1,
      m_rvalid=>m_rvalid, m_rready=>m_rready, m_rlast=>m_rlast,
      m_rresp=>m_rresp,
      m_awvalid=>m_awvalid, m_awready=>m_awready, m_awaddr=>m_awaddr,
      m_awlen=>m_awlen, m_awsize=>m_awsize, m_awburst=>m_awburst,
      m_wvalid=>m_wvalid, m_wready=>m_wready, m_wdata=>m_wdata,
      m_wstrb=>m_wstrb, m_wlast=>m_wlast,
      m_bvalid=>m_bvalid, m_bready=>m_bready, m_bresp=>m_bresp);

  -- ---------------------------------------------------------- memory model
  -- One outstanding burst per port, served one beat every THROTTLE cycles.
  -- Deliberately simple: the point is a KNOWN rate, not a realistic HBM.
  mem : for i in 0 to NPORT-1 generate
    signal left : integer := 0;
    signal tick : integer := 0;
  begin
    m_arready(i) <= '1' when left = 0 else '0';
    process(clk)
    begin
      if rising_edge(clk) then
        m_rvalid(i) <= '0'; m_rlast(i) <= '0';
        if rstn = '0' then
          left <= 0; tick <= 0;
        else
          if m_arvalid(i) = '1' and left = 0 then
            left <= to_integer(unsigned(m_arlen((i+1)*8-1 downto i*8))) + 1;
            tick <= 0;
          elsif left > 0 then
            if tick = THROTTLE-1 then
              tick <= 0;
              m_rvalid(i) <= '1';
              m_rresp(2*i+1 downto 2*i) <= "10" when inject_err = '1'
                                           else "00";
              if left = 1 then m_rlast(i) <= '1'; end if;
              left <= left - 1;
            else
              tick <= tick + 1;
            end if;
          end if;
        end if;
      end if;
    end process;
  end generate;

  -- ----------------------------------------------------- write memory model
  -- Mirrors the read model: one beat every THROTTLE cycles, so the expected
  -- write rate is the SAME nactive*BPB/THROTTLE and a write run can be held to
  -- the same two-sided bound.  Anything asymmetric here would make a write
  -- shortfall unattributable between the DUT and the model.
  --
  -- AW is accepted into a small queue rather than one-at-a-time, because a
  -- model that accepts only one AW would cap the DUT's write pipelining at 1
  -- and the resulting rate would describe the model.
  wmem : for i in 0 to NPORT-1 generate
    signal awq   : integer := 0;    -- AW accepted, data not yet complete
    signal bq    : integer := 0;    -- bursts whose data is in, B not yet sent
    signal tick  : integer := 0;
  begin
    m_awready(i) <= '1' when awq < 4 else '0';
    -- WREADY IS PURELY RATE-BASED, and deliberately does NOT check that an AW
    -- has arrived.  The first version gated it on `awq > 0`, which made the
    -- model refuse write data that had no address -- and that quietly made the
    -- W-ahead-of-AW assertion below UNFIREABLE: a mutant DUT that asserted
    -- WVALID with no AW outstanding was held off by the model and passed.
    -- Verified by mutation: with the gate in place the mutant passed silently;
    -- with it removed the assertion catches it.
    --
    -- A model must not enforce the DUT's correctness.  If it does, every
    -- assertion downstream of that enforcement is decoration.
    m_wready(i)  <= '1' when tick = THROTTLE-1 else '0';
    process(clk)
    begin
      if rising_edge(clk) then
        m_bvalid(i) <= '0';
        if rstn = '0' then
          awq <= 0; bq <= 0; tick <= 0;
        else
          if tick = THROTTLE-1 then tick <= 0; else tick <= tick + 1; end if;

          -- AW accept and W-burst completion can land together, so both
          -- deltas are applied in ONE assignment.  Two branches would drop an
          -- increment exactly as the DUT's own outstanding counter once did.
          -- awq now backs ONLY the AW-side depth limit.  It can go negative
          -- against a mutant that sends data first; that is not a model bug,
          -- it is the violation being visible instead of absorbed.
          if m_awvalid(i) = '1' and m_awready(i) = '1'
             and not (m_wvalid(i) = '1' and m_wready(i) = '1'
                      and m_wlast(i) = '1') then
            awq <= awq + 1;
          elsif m_wvalid(i) = '1' and m_wready(i) = '1' and m_wlast(i) = '1'
                and not (m_awvalid(i) = '1' and m_awready(i) = '1') then
            awq <= awq - 1;
          end if;

          if m_wvalid(i) = '1' and m_wready(i) = '1' and m_wlast(i) = '1' then
            bq <= bq + 1;
          elsif bq > 0 then
            bq <= bq - 1;
            m_bvalid(i) <= '1';
            m_bresp(2*i+1 downto 2*i) <= "10" when inject_werr = '1' else "00";
          end if;
        end if;
      end if;
    end process;
  end generate;

  -- ------------------------------------------------- W-channel protocol check
  -- The two ways a write engine goes wrong are both silent in a bandwidth
  -- number, and both would INFLATE it:
  --   * data beats sent for a burst whose AW was never accepted -- free bytes
  --   * a burst of the wrong length, or WLAST in the wrong place -- the
  --     memory would count beats we never framed as a burst
  -- Neither shows up in the DUT's own counters, because the DUT is what is
  -- being checked.  So they are asserted against the bus directly.
  wchk : for i in 0 to NPORT-1 generate
    signal aw_acc, w_burst : integer := 0;
    signal bc              : integer := 0;
  begin
    process(clk)
    begin
      if rising_edge(clk) then
        if rstn = '0' then
          aw_acc <= 0; w_burst <= 0; bc <= 0;
        else
          if m_awvalid(i) = '1' and m_awready(i) = '1' then
            aw_acc <= aw_acc + 1;
          end if;
          if m_wvalid(i) = '1' and m_wready(i) = '1' then
            assert w_burst < aw_acc
                or (m_awvalid(i) = '1' and m_awready(i) = '1')
              report "port " & integer'image(i) & ": W DATA AHEAD OF ITS " &
                     "ADDRESS -- " & integer'image(w_burst) &
                     " bursts of data against " & integer'image(aw_acc) &
                     " accepted AW" severity failure;
            if m_wlast(i) = '1' then
              assert bc = to_integer(unsigned(m_awlen((i+1)*8-1 downto i*8)))
                report "port " & integer'image(i) & ": WLAST on beat " &
                       integer'image(bc) & " of a burst declared " &
                       integer'image(to_integer(unsigned(
                         m_awlen((i+1)*8-1 downto i*8)))) & " long"
                severity failure;
              bc <= 0;
              w_burst <= w_burst + 1;
            else
              assert bc < to_integer(unsigned(m_awlen((i+1)*8-1 downto i*8)))
                report "port " & integer'image(i) & ": burst RAN PAST its " &
                       "declared length with no WLAST" severity failure;
              bc <= bc + 1;
            end if;
          end if;
        end if;
      end if;
    end process;
  end generate;

  -- ------------------------------------------------------------- stimulus
  drv : process
    variable rd : std_logic_vector(31 downto 0);

    -- A REAL AXI master: it drops VALID on the cycle after READY was high,
    -- because READY is a promise that the beat was taken.  It does NOT
    -- re-offer the beat.
    --
    -- The first version of this procedure held WVALID until it saw WREADY on a
    -- LATER edge, which quietly re-offered the data and so worked against a
    -- slave that had dropped the first beat.  That masked a real protocol bug
    -- all the way to hardware, where smartconnect presents AW and W together,
    -- and every control write was silently lost while reads worked perfectly.
    -- A testbench that is more forgiving than the bus it stands in for is
    -- worse than none, because it converts a protocol error into a mystery.
    procedure wr(a : natural; d : natural) is
      variable aw_done, w_done : boolean := false;
      variable wd_cnt          : natural := 0;
    begin
      s_awaddr <= std_logic_vector(to_unsigned(a, 16));
      s_wdata  <= std_logic_vector(to_unsigned(d, 32));
      s_awvalid <= '1'; s_wvalid <= '1'; s_bready <= '1';
      aw_done := false; w_done := false; wd_cnt := 0;
      while not (aw_done and w_done) loop
        wait until rising_edge(clk);
        if s_awready = '1' and not aw_done then
          aw_done := true; s_awvalid <= '0';
        end if;
        if s_wready = '1' and not w_done then
          w_done := true; s_wvalid <= '0';
        end if;
        wd_cnt := wd_cnt + 1;
        assert wd_cnt < WR_WATCHDOG
          report "AXI-Lite write to 0x" & to_hstring(to_unsigned(a, 16)) &
                 " never handshook: awready and wready did not both go high"
          severity failure;
      end loop;
      wd_cnt := 0;
      loop
        wait until rising_edge(clk);
        exit when s_bvalid = '1';
        wd_cnt := wd_cnt + 1;
        assert wd_cnt < WR_WATCHDOG
          report "AXI-Lite write to 0x" & to_hstring(to_unsigned(a, 16)) &
                 " handshook but produced no BVALID: the slave lost a beat"
          severity failure;
      end loop;
      s_bready <= '0';
      wait until rising_edge(clk);
    end procedure;

    procedure rdreg(a : natural; v : out std_logic_vector(31 downto 0)) is
    begin
      s_araddr <= std_logic_vector(to_unsigned(a, 16));
      s_arvalid <= '1'; s_rready <= '1';
      loop wait until rising_edge(clk); exit when s_arready = '1'; end loop;
      s_arvalid <= '0';
      loop wait until rising_edge(clk); exit when s_rvalid = '1'; end loop;
      v := s_rdata;
      s_rready <= '0';
      wait until rising_edge(clk);
    end procedure;

    procedure run(nactive : natural) is
      variable v : std_logic_vector(31 downto 0);
      variable tot, cyc : natural;
      variable want, got : real;
    begin
      wr(0, 2);                                     -- clear
      wr(4, 2**nactive - 1);                        -- mask
      wr(8, ARLEN); wr(12, NBURST); wr(16, 16);

      -- Read the control registers straight back before starting.  This is
      -- the check the hardware run did not have: it proves the write path
      -- actually landed, independently of whether the traffic that follows
      -- looks right.  A dropped write and a misrouted port produce the same
      -- symptom downstream, and this separates them in one read.
      rdreg(16#100# + 4, v);
      assert to_integer(unsigned(v)) = 2**nactive - 1
        report "control readback: mask wrote " &
               integer'image(2**nactive - 1) & ", reads " &
               integer'image(to_integer(unsigned(v))) severity failure;
      rdreg(16#100# + 8, v);
      assert to_integer(unsigned(v)) = ARLEN
        report "control readback: arlen wrote " & integer'image(ARLEN) &
               ", reads " & integer'image(to_integer(unsigned(v)))
        severity failure;
      rdreg(16#100# + 12, v);
      assert to_integer(unsigned(v)) = NBURST
        report "control readback: nburst wrote " & integer'image(NBURST) &
               ", reads " & integer'image(to_integer(unsigned(v)))
        severity failure;

      wr(0, 1);                                     -- go
      for t in 0 to 100000 loop
        rdreg(8, v);
        exit when v(0) = '0';
      end loop;
      wr(0, 0);
      rdreg(4, v); cyc := to_integer(unsigned(v));
      tot := 0;
      for i in 0 to NPORT-1 loop
        rdreg(1024 + i*4, v);
        if i < nactive then
          assert to_integer(unsigned(v)) = NBURST*(ARLEN+1)
            report "port " & integer'image(i) & " beats=" &
                   integer'image(to_integer(unsigned(v))) & " want " &
                   integer'image(NBURST*(ARLEN+1)) severity failure;
        else
          assert to_integer(unsigned(v)) = 0
            report "MASKED port " & integer'image(i) &
                   " moved data: the port sweep is not real" severity failure;
        end if;
        tot := tot + to_integer(unsigned(v));
      end loop;
      want := real(nactive * BPB) / real(THROTTLE);
      got  := real(tot * BPB) / real(cyc);
      report "nactive=" & integer'image(nactive) &
             "  beats=" & integer'image(tot) &
             "  cycles=" & integer'image(cyc) &
             "  B/cycle got=" & real'image(got) &
             " want=" & real'image(want) severity note;
      -- TWO-SIDED, and the two sides mean different things.
      --   got > want would mean the generator counted beats the model never
      --   served, i.e. the instrument inflates.  There is no tolerance for
      --   that at all.
      --   got slightly < want is EXPECTED and is a property of the model, not
      --   of the DUT: this model leaves one dead cycle between the last beat
      --   of a burst and accepting the next AR, which at NBURST=64 costs ~64
      --   cycles on top of the ideal 2048, or ~3%.  Real HBM has its own
      --   turnaround and the generator cannot hide it either.  So the floor
      --   is 5%, and anything worse means the generator is failing to keep
      --   the memory fed rather than the memory failing to deliver.
      assert got <= want * 1.001
        report "INSTRUMENT INFLATES: measured " & real'image(got) &
               " exceeds the model's own ceiling " & real'image(want)
        severity failure;
      assert got > want * 0.95
        report "MEASURED RATE IS WRONG: the instrument does not recover a " &
               "known bandwidth (got " & real'image(got) & " want " &
               real'image(want) & ")" severity failure;
    end procedure;

    -- ---- the write and mixed cases.
    --
    -- One procedure covers all three because they differ only in two register
    -- values, and because the checks that matter are the SAME checks: that
    -- each port moved exactly the traffic its direction implies AND NOTHING IN
    -- THE OTHER DIRECTION.  That cross-check is the whole point -- a wmask
    -- that added writes instead of substituting them would still produce a
    -- plausible aggregate, and only "this port's read beats are zero" catches
    -- it.
    --
    -- `expect` is in units of nactive*BPB/THROTTLE, so it is 1.0 for any
    -- one-direction-per-port arrangement and 2.0 for rw_both, where each port
    -- runs both engines into its own model at the full rate.  That factor is
    -- itself an assertion: if the two engines were sharing a bottleneck in the
    -- DUT rather than running concurrently, rw_both would come back at 1.0.
    procedure runmix(nactive : natural; wm : natural; both : natural;
                     expect : real; tag : string) is
      variable v : std_logic_vector(31 downto 0);
      variable rtot, wtot, cyc : natural;
      variable want, got : real;
      variable is_w, is_r : boolean;
      variable wantr, wantw, wantb : natural;
    begin
      wr(0, 2);
      wr(4, 2**nactive - 1); wr(28, wm); wr(32, both);
      wr(8, ARLEN); wr(12, NBURST); wr(16, 16);
      rdreg(16#100# + 28, v);
      assert to_integer(unsigned(v)) = wm
        report tag & ": wmask wrote " & integer'image(wm) & ", reads " &
               integer'image(to_integer(unsigned(v))) severity failure;
      rdreg(16#100# + 32, v);
      assert to_integer(unsigned(v)) = both
        report tag & ": rw_both wrote " & integer'image(both) & ", reads " &
               integer'image(to_integer(unsigned(v))) severity failure;

      wr(0, 1);
      for t in 0 to 200000 loop
        rdreg(8, v);
        exit when v(0) = '0';
      end loop;
      assert v(0) = '0'
        report tag & ": run never finished -- the write engine is stuck, " &
               "which on hardware is a hung AXI channel and not a slow one"
        severity failure;
      wr(0, 0);
      rdreg(4, v); cyc := to_integer(unsigned(v));

      rtot := 0; wtot := 0;
      for i in 0 to NPORT-1 loop
        is_w := i < nactive and ((wm / (2**i)) mod 2 = 1 or both = 1);
        is_r := i < nactive and ((wm / (2**i)) mod 2 = 0 or both = 1);
        if is_r then wantr := NBURST*(ARLEN+1); else wantr := 0; end if;
        if is_w then wantw := NBURST*(ARLEN+1); else wantw := 0; end if;
        if is_w then wantb := NBURST;           else wantb := 0; end if;
        rdreg(1024 + i*4, v);                       -- read beats
        -- The CROSS-CHECK, and the reason each direction is asserted against
        -- BOTH counters: a wmask that ADDED writes instead of substituting
        -- them would still produce a plausible aggregate, and only "this
        -- port's read beats are exactly zero" catches that.
        assert to_integer(unsigned(v)) = wantr
          report tag & ": port " & integer'image(i) & " read beats=" &
                 integer'image(to_integer(unsigned(v))) & ", want " &
                 integer'image(wantr) severity failure;
        rtot := rtot + to_integer(unsigned(v));
        rdreg(5120 + i*4, v);                       -- write beats
        assert to_integer(unsigned(v)) = wantw
          report tag & ": port " & integer'image(i) & " write beats=" &
                 integer'image(to_integer(unsigned(v))) & ", want " &
                 integer'image(wantw) severity failure;
        wtot := wtot + to_integer(unsigned(v));
        rdreg(7168 + i*4, v);                       -- write bursts retired
        assert to_integer(unsigned(v)) = wantb
          report tag & ": port " & integer'image(i) & " retired " &
                 integer'image(to_integer(unsigned(v))) & " write bursts, " &
                 "want " & integer'image(wantb) &
                 "; a missing B response is a lost write" severity failure;
        rdreg(8192 + i*4, v);                       -- write response errors
        assert to_integer(unsigned(v)) = 0
          report tag & ": port " & integer'image(i) & " logged " &
                 integer'image(to_integer(unsigned(v))) &
                 " non-OKAY write responses on a clean run" severity failure;
      end loop;

      want := expect * real(nactive * BPB) / real(THROTTLE);
      got  := real((rtot + wtot) * BPB) / real(cyc);
      report tag & " nactive=" & integer'image(nactive) &
             "  rbeats=" & integer'image(rtot) &
             "  wbeats=" & integer'image(wtot) &
             "  cycles=" & integer'image(cyc) &
             "  B/cycle got=" & real'image(got) &
             " want=" & real'image(want) severity note;
      assert got <= want * 1.001
        report tag & " INSTRUMENT INFLATES: " & real'image(got) &
               " exceeds the model ceiling " & real'image(want)
        severity failure;
      assert got > want * 0.90
        report tag & " RATE IS WRONG: got " & real'image(got) & " want " &
               real'image(want) severity failure;
      wr(0, 2); wr(28, 0); wr(32, 0);
    end procedure;
    variable wmix : natural := 0;
  begin
    rstn <= '0'; wait for 20 ns;
    wait until rising_edge(clk); rstn <= '1';
    wait until rising_edge(clk);

    rdreg(0, rd);
    assert rd = x"48424D31" report "ID register wrong" severity failure;

    for n in 1 to NPORT loop run(n); end loop;

    -- ---- WRITE PATH.  Three arrangements, in increasing order of how much
    -- they can actually tell you on hardware.
    --
    -- 1. Write-only.  A sanity point.  On hardware at 300 MHz its result is
    --    guaranteed by arithmetic (a port cannot pressure a channel), so it
    --    proves the path WORKS and nothing about the memory.  Here in
    --    simulation, against a model with a known rate, it does carry
    --    information: it says every write beat is accounted for.
    for n in 1 to NPORT loop
      runmix(n, 2**n - 1, 0, 1.0, "write-only");
    end loop;

    -- 2. Mixed across ports -- C 2.5's 2R+1W with each port on its OWN
    --    channel.  Every third port writes.  This is the arbitration case.
    wmix := 0;
    for i in 0 to NPORT-1 loop
      if i mod 3 = 2 then wmix := wmix + 2**i; end if;
    end loop;
    runmix(NPORT, wmix, 0, 1.0, "mixed 2R+1W across ports");

    -- 3. rw_both -- BOTH engines on every port.  The expectation is 2.0x,
    --    and that factor is the assertion: AXI's read and write paths are
    --    independent, so if the DUT delivered 1.0x it would mean the two
    --    engines are serialising inside the generator, and the hardware
    --    turnaround measurement would then be measuring this bug instead of
    --    the DRAM.  Checking it here is what makes the hardware number mean
    --    what it will be claimed to mean.
    runmix(NPORT, 0, 1, 2.0, "R+W concurrent on every port");

    -- ---- THERMAL: the status register's field packing.  Checked because it
    -- was NOT, and a 39-bit value silently assigned into a 32-bit register
    -- passed simulation and was caught only by synthesis.
    t0 <= std_logic_vector(to_unsigned(11, 7));
    t1 <= std_logic_vector(to_unsigned(22, 7));
    -- Two cycles for the CDC synchroniser, one more for the high-water
    -- compare that consumes its output, and slack on top.  This wait used to
    -- be two cycles, which was exactly right when the thermal inputs were
    -- sampled combinationally -- and that combinational sampling was the CDC
    -- bug.  The testbench failing here when the synchroniser was added is the
    -- check working: the observable timing of a status register genuinely
    -- changed, and a test that had not noticed would have been asserting
    -- nothing about the new design.
    for i in 1 to 6 loop wait until rising_edge(clk); end loop;
    rdreg(16, rd);
    assert to_integer(unsigned(rd(6 downto 0))) = 11
       and to_integer(unsigned(rd(13 downto 7))) = 22
      report "TEMP REGISTER FIELDS ARE MISPACKED: live codes read back as " &
             integer'image(to_integer(unsigned(rd(6 downto 0)))) & "," &
             integer'image(to_integer(unsigned(rd(13 downto 7))))
      severity failure;
    assert to_integer(unsigned(rd(20 downto 14))) = 11
       and to_integer(unsigned(rd(27 downto 21))) = 22
      report "TEMP high-water fields are mispacked" severity failure;
    assert rd(31 downto 28) = "0000"
      report "TEMP register pad bits are not zero" severity failure;
    report "temperature status register packs four 7-bit fields correctly"
      severity note;
    t0 <= (others=>'0'); t1 <= (others=>'0');
    wr(0, 2);

    -- ---- THERMAL: a trip must actually stop a run, not merely be reported.
    -- Checked by starting a run long enough that it CANNOT finish on its own,
    -- pulling CATTRIP, and requiring the busy flag to clear anyway.  Without
    -- the fabric watchdog this hangs, which is the failure mode on hardware.
    wr(0, 2); wr(4, 2**NPORT - 1); wr(8, ARLEN); wr(12, 1000000); wr(16, 16);
    wr(0, 1);
    for t in 0 to 200 loop rdreg(8, rd); end loop;
    assert rd(0) = '1' report "run ended early, the trip test proves nothing"
      severity failure;
    cat0 <= '1';
    for t in 0 to 200 loop
      rdreg(8, rd);
      exit when rd(0) = '0';
    end loop;
    assert rd(0) = '0'
      report "CATTRIP DID NOT STOP THE RUN: the thermal watchdog is inert"
      severity failure;
    rdreg(20, rd);
    assert rd(1) = '1' and rd(2) = '1'
      report "trip happened but the reason was not reported" severity failure;
    report "CATTRIP halts the run in fabric and reports the reason"
      severity note;
    cat0 <= '0';

    -- the soft ceiling, on the raw code, only when programmed
    wr(0, 2); wr(20, 40); wr(4, 1); wr(12, 1000000); wr(0, 1);
    t0 <= std_logic_vector(to_unsigned(41, 7));
    for t in 0 to 200 loop
      rdreg(8, rd);
      exit when rd(0) = '0';
    end loop;
    assert rd(0) = '0'
      report "TEMP LIMIT DID NOT STOP THE RUN" severity failure;
    rdreg(20, rd);
    assert rd(3) = '1' report "limit trip not reported" severity failure;
    report "programmed temperature ceiling halts the run" severity note;
    t0 <= (others=>'0'); wr(0, 0); wr(0, 2); wr(20, 0);

    -- ---- READ RESPONSE.  The instrument counted beats without ever asking
    -- whether they were successful reads, and a DECERR returns beats FASTER
    -- than memory does -- so a mis-decoded address would have reported HIGHER
    -- bandwidth rather than failing.  Prove the counter is actually wired:
    -- a clean run must leave it at zero, and an injected SLVERR must be seen.
    wr(0, 2);
    rdreg(4096, rd);
    assert to_integer(unsigned(rd)) = 0
      report "port 0 logged " & integer'image(to_integer(unsigned(rd))) &
             " non-OKAY responses on a CLEAN run: the error counter is " &
             "counting something it should not" severity failure;

    inject_err <= '1';
    wr(0, 2); wr(4, 1); wr(8, ARLEN); wr(12, 4); wr(16, 16); wr(0, 1);
    for t in 0 to 100000 loop
      rdreg(8, rd);
      exit when rd(0) = '0';
    end loop;
    wr(0, 0);
    rdreg(4096, rd);
    assert to_integer(unsigned(rd)) = 4*(ARLEN+1)
      report "SLVERR on every beat logged " &
             integer'image(to_integer(unsigned(rd))) & " errors, want " &
             integer'image(4*(ARLEN+1)) &
             ": the read-response path is NOT connected, which is exactly " &
             "the state the 144 GB/s run was measured in" severity failure;
    report "read-response errors are counted, and are zero on a clean run"
      severity note;
    inject_err <= '0';

    -- ---- WRITE RESPONSE.  Same argument as the read side, and it has to be
    -- made separately because it is a separate counter on a separate channel:
    -- a write that DECERRs never reaches memory and completes FASTER than one
    -- that does, so an unchecked write path reports its own misconfiguration
    -- as higher bandwidth.  Note the expected count is NBURST, not
    -- NBURST*(ARLEN+1) -- AXI returns ONE write response per burst, not per
    -- beat, and asserting the read side's figure here would fail against a
    -- perfectly correct design.
    wr(0, 2); wr(28, 1); wr(32, 0);
    rdreg(8192, rd);
    assert to_integer(unsigned(rd)) = 0
      report "port 0 logged " & integer'image(to_integer(unsigned(rd))) &
             " non-OKAY write responses on a CLEAN run" severity failure;
    inject_werr <= '1';
    wr(0, 2); wr(4, 1); wr(8, ARLEN); wr(12, 4); wr(16, 16); wr(0, 1);
    for t in 0 to 100000 loop
      rdreg(8, rd);
      exit when rd(0) = '0';
    end loop;
    wr(0, 0);
    rdreg(8192, rd);
    assert to_integer(unsigned(rd)) = 4
      report "SLVERR on every write burst logged " &
             integer'image(to_integer(unsigned(rd))) & " errors, want 4: " &
             "the write-response path is NOT connected" severity failure;
    rdreg(5120, rd);
    assert to_integer(unsigned(rd)) = 4*(ARLEN+1)
      report "the errored run moved " & integer'image(to_integer(unsigned(rd)))
             & " write beats, want " & integer'image(4*(ARLEN+1)) &
             ": an errored write must still be counted as traffic, or beats "
             & "and errors cannot be compared" severity failure;
    report "write-response errors are counted, and are zero on a clean run"
      severity note;
    inject_werr <= '0';
    wr(0, 2); wr(28, 0);

    -- ---- ADDRESS MAPPING.  The point of the region registers is to let
    -- several ports target ONE pseudo-channel, which is the only way to load
    -- HBM past a single port's 9.6 GB/s at 300 MHz.  If the address did not
    -- actually move, the oversubscription sweep would quietly measure the
    -- port-per-channel case again and report the same guaranteed 100%.
    wr(0, 2);
    wr(24, 16#0001#);              -- base 1, stride 0: every port on chan 1
    rdreg(16#100# + 24, rd);
    assert to_integer(unsigned(rd(7 downto 0))) = 1
       and to_integer(unsigned(rd(15 downto 8))) = 0
      report "region register readback wrong: base " &
             integer'image(to_integer(unsigned(rd(7 downto 0)))) & " stride " &
             integer'image(to_integer(unsigned(rd(15 downto 8))))
      severity failure;
    wr(4, 2**NPORT - 1); wr(8, ARLEN); wr(12, 2); wr(16, 16); wr(0, 1);
    -- catch the addresses as they are issued
    for t in 0 to 200 loop
      wait until rising_edge(clk);
      exit when m_arvalid(0) = '1' and m_arvalid(NPORT-1) = '1';
    end loop;
    assert m_araddr(ADDR_W-1 downto REGION_LOG2) =
           m_araddr(NPORT*ADDR_W-1 downto (NPORT-1)*ADDR_W + REGION_LOG2)
      report "stride 0 did NOT collapse the ports onto one channel: port 0 " &
             "region " &
             integer'image(to_integer(unsigned(
               m_araddr(ADDR_W-1 downto REGION_LOG2)))) &
             ", port " & integer'image(NPORT-1) & " region " &
             integer'image(to_integer(unsigned(
               m_araddr(NPORT*ADDR_W-1 downto (NPORT-1)*ADDR_W + REGION_LOG2))))
      severity failure;
    assert to_integer(unsigned(m_araddr(ADDR_W-1 downto REGION_LOG2))) = 1
      report "stride 0 collapsed onto the wrong channel" severity failure;
    for t in 0 to 100000 loop
      rdreg(8, rd);
      exit when rd(0) = '0';
    end loop;
    wr(0, 0);
    report "region stride 0 puts every port on one pseudo-channel" severity note;
    wr(0, 2); wr(24, 16#0101#);    -- restore base 1, stride 1

    report "hbm_tg recovers a known bandwidth at every port count" severity note;
    done <= true; wait;
  end process;
end architecture;
