-- rtl/hbm_tg.vhd -- HBM read-bandwidth traffic generator for the FK33.
--
-- WHY THIS EXISTS.  Every throughput number in all five v2 design specs rests
-- on one unmeasured premise: that the FK33's HBM delivers ~460 GB/s, of which
-- subsystem A's ROWS_IF=58 configuration demands ~432.  Nothing on this card
-- has ever moved a byte of HBM at speed.  A 6% error in that premise moves
-- ROWS_IF; a 50% error invalidates the whole allocation.
--
-- WHAT IT MEASURES, and why it is built as ONE bitstream rather than several.
-- The interesting quantity is not a single number, it is the SHAPE: how
-- achieved bandwidth scales with the number of AXI ports driven concurrently.
-- That shape is what resolves A 14.5 (lanes versus physical HBM ports, left
-- open in the spec), and it is the only way to see the HBM AXI switch's cost.
-- So NPORT generators are built, each independently armed by a bit of a
-- run-time MASK register, and one bitstream yields the whole curve: arm 1
-- port, measure, arm 2, measure, ... arm all NPORT.  Rebuilding per point
-- would cost an hour each and, worse, would compare numbers from different
-- placements.
--
-- ADDRESSING IS PORT-LOCAL BY DEFAULT.  Generator i reads only within its own
-- REGION-sized slice at i*REGION.  With the HBM global switch enabled a port
-- may reach any pseudo-channel, but doing so pays the switch's arbitration and
-- is not what subsystem A does: A streams a contiguous weight shard per port.
-- Measuring the access pattern A will actually use is the point; a random or
-- cross-channel pattern would measure a different machine.
--
-- READS AND WRITES.  The first version was read-only, on the argument that A's
-- weight path is read-only (rtl/axi_rd_port.vhd still has no write channel).
-- That argument was right about A and wrong about the die: C 2.5 assumes two
-- reads and one write CONCURRENTLY, and B needs four masters.  So every
-- bandwidth number this instrument had produced -- 144.0 GB/s at 15 ports,
-- 288.0 at 30 -- described a traffic pattern that only ONE of five subsystems
-- actually issues, and the specs were quoting it as if it were the memory
-- system's capability.
--
-- WRITE BANDWIDTH ALONE IS NOT A FINDING AT 300 MHz, and building this to
-- measure it would repeat a mistake this instrument has already made once.  A
-- port demands 32 B x 300 MHz = 9.6 GB/s; a pseudo-channel supplies 14.4.  A
-- write-only sweep is therefore guaranteed to report 100% of the port's
-- ceiling for the same arithmetic reason the oversubscription sweep returned a
-- flat 9.60 GB/s -- it measures the CLOCK, not the memory.  It is run as one
-- sanity point and is labelled as guaranteed in the results, not cited.
--
-- THE EXPERIMENT WITH INFORMATION IN IT IS CONCURRENT R+W ON ONE CHANNEL.
-- AXI's read and write paths are independent, so a single port in rw_both mode
-- demands 64 B/cycle = 19.2 GB/s against that same 14.4 GB/s of DRAM supply.
-- That is the first configuration reachable from fabric at 300 MHz where the
-- memory, not the datapath's clock, has to set the answer -- and what it
-- measures is precisely the read/write bus turnaround (tWTR/tRTW) that C 3.13
-- lists as unmeasured behind its 53% duty premise and that B 2.5 assumes away
-- for four concurrent masters.
--
-- So the modes exist to separate turnaround from arbitration, which are
-- different costs that a single aggregate number would average together:
--
--   wmask=0                reads only            reproduces the old numbers
--                                                exactly, and is kept as the
--                                                regression check that the
--                                                write path cost nothing
--   wmask=all              writes only           SANITY ONLY, guaranteed by
--                                                arithmetic, see above
--   wmask=every 3rd port   2R+1W across ports    C 2.5's pattern with the
--                                                channels INDEPENDENT: costs
--                                                switch arbitration, not
--                                                turnaround
--   RW_BOTH=1, stride=0    R and W into ONE      THE HEADLINE.  19.2 GB/s of
--                          pseudo-channel        demand against 14.4 supply,
--                                                so the shortfall is the
--                                                turnaround and nothing else
--
-- Nothing on this card holds data worth preserving, so writing over it costs
-- nothing.  The generator does NOT read back what it wrote: this measures
-- bandwidth, not memory integrity, and a read-verify would halve the write
-- rate being measured.
--
-- The counters deliberately measure DIFFERENT things so a disagreement is
-- visible rather than averaged away:
--   beats[i]   R-channel beats accepted by generator i        -> the payload
--   cycles     clocks during which ANY generator was active   -> the wall time
--   arstall[i] cycles generator i held ARVALID without ARREADY -> where the
--              back-pressure is, if achieved falls short of nominal
-- Bandwidth = sum(beats) * (AXI_DW/8) / (cycles / f_axi).  Reporting only an
-- aggregate would leave a shortfall unattributable; arstall says whether the
-- limit is the memory or our own issue rate.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity hbm_tg is
  generic(
    NPORT   : positive := 16;   -- generators, one per HBM SAXI port
    AXI_DW  : positive := 256;  -- HBM SAXI data width
    ADDR_W  : positive := 33;   -- 8 GB
    -- Bytes each generator owns.  256 MB per generator, inside the 8 GB device
    -- and large enough that no generator can sit resident in one HBM row.
    REGION_LOG2 : positive := 28;
    -- HBM channel index that generator 0 drives.  NOT cosmetic: the HBM IP
    -- FIXES pseudo-channel n at n * 256 MB and refuses any other offset
    -- ("must be equivalent to the fixed address"), so a generator whose
    -- addresses do not carry its own channel index simply cannot be mapped.
    -- SAXI_00 is already taken by jtag_hbm on this board, so generator 0
    -- drives SAXI_01 and PORT0 is 1.
    PORT0 : natural := 0
  );
  port(
    clk    : in std_logic;
    rstn   : in std_logic;

    -- THERMAL.  Straight from the HBM IP's own per-stack outputs.  In the
    -- stock FK33 design these are left UNCONNECTED, which means the stacks'
    -- catastrophic-temperature signal is asserted into the void: SYSMON's
    -- 101 C over-temperature trip watches the FPGA DIE, and the die is not
    -- the HBM stack.  This unit is the first thing on this card to drive HBM
    -- hard, so it is the first thing that needs to listen.
    hbm_temp0    : in std_logic_vector(6 downto 0);
    hbm_temp1    : in std_logic_vector(6 downto 0);
    hbm_cattrip0 : in std_logic;
    hbm_cattrip1 : in std_logic;

    -- AXI4-Lite control, from jtag_axi.  32-bit, no burst.
    s_awvalid : in  std_logic;
    s_awready : out std_logic;
    s_awaddr  : in  std_logic_vector(15 downto 0);
    s_wvalid  : in  std_logic;
    s_wready  : out std_logic;
    s_wdata   : in  std_logic_vector(31 downto 0);
    s_bvalid  : out std_logic;
    s_bready  : in  std_logic;
    s_arvalid : in  std_logic;
    s_arready : out std_logic;
    s_araddr  : in  std_logic_vector(15 downto 0);
    s_rvalid  : out std_logic;
    s_rready  : in  std_logic;
    s_rdata   : out std_logic_vector(31 downto 0);

    -- NPORT AXI4 read masters, flattened.  No write channel exists.
    m_arvalid : out std_logic_vector(NPORT-1 downto 0);
    m_arready : in  std_logic_vector(NPORT-1 downto 0);
    m_araddr  : out std_logic_vector(NPORT*ADDR_W-1 downto 0);
    m_arlen   : out std_logic_vector(NPORT*8-1 downto 0);
    m_arsize  : out std_logic_vector(NPORT*3-1 downto 0);
    m_arburst : out std_logic_vector(NPORT*2-1 downto 0);
    m_rvalid  : in  std_logic_vector(NPORT-1 downto 0);
    m_rready  : out std_logic_vector(NPORT-1 downto 0);
    m_rlast   : in  std_logic_vector(NPORT-1 downto 0);
    -- READ RESPONSE.  Added after the first 144 GB/s run, which counted beats
    -- without ever asking whether they were SUCCESSFUL reads.  A DECERR from
    -- the interconnect returns data beats too, and it returns them FASTER
    -- than memory does, so a mis-decoded address inflates the bandwidth
    -- figure instead of failing visibly.  An instrument whose failure mode is
    -- a better-looking number is the wrong way round.
    m_rresp   : in  std_logic_vector(NPORT*2-1 downto 0);

    -- NPORT AXI4 WRITE masters, flattened, same shape as the read side.
    -- WSTRB is all ones and never varies: a partial write is a read-modify-
    -- write inside the memory controller and would measure a different
    -- machine than the full-width stores B and C issue.
    m_awvalid : out std_logic_vector(NPORT-1 downto 0);
    m_awready : in  std_logic_vector(NPORT-1 downto 0);
    m_awaddr  : out std_logic_vector(NPORT*ADDR_W-1 downto 0);
    m_awlen   : out std_logic_vector(NPORT*8-1 downto 0);
    m_awsize  : out std_logic_vector(NPORT*3-1 downto 0);
    m_awburst : out std_logic_vector(NPORT*2-1 downto 0);
    m_wvalid  : out std_logic_vector(NPORT-1 downto 0);
    m_wready  : in  std_logic_vector(NPORT-1 downto 0);
    m_wdata   : out std_logic_vector(NPORT*AXI_DW-1 downto 0);
    m_wstrb   : out std_logic_vector(NPORT*(AXI_DW/8)-1 downto 0);
    m_wlast   : out std_logic_vector(NPORT-1 downto 0);
    m_bvalid  : in  std_logic_vector(NPORT-1 downto 0);
    m_bready  : out std_logic_vector(NPORT-1 downto 0);
    -- WRITE RESPONSE, carried for the same reason m_rresp is: a write that
    -- DECERRs completes FASTER than one that reaches memory, so an unchecked
    -- write path reports its own misconfiguration as higher bandwidth.
    m_bresp   : in  std_logic_vector(NPORT*2-1 downto 0);

    -- RESET OUT for the HBM IP's own AXI interfaces.  AXI_n_ARESET_N is
    -- specified synchronous to AXI_n_ACLK, and the build was driving all 15 of
    -- them straight from a proc_sys_reset in the 100 MHz control domain.  That
    -- is the same CDC defect fixed inside this unit, left in place on the path
    -- INTO the hard block, and it is the single worst timing path in the
    -- design at 350 MHz: zero logic levels and 1.5-1.7 ns of pure routing from
    -- one far-away source to fifteen hard-block pins.
    --
    -- Driving them from the synchronised reset instead makes it a normal
    -- same-domain path.  MAX_FANOUT lets the tool replicate the driver next to
    -- the loads, which is what actually removes the route delay -- one flop
    -- feeding fifteen scattered hard-block pins cannot be routed well no
    -- matter which domain it comes from.
    aresetn_o : out std_logic
  );
end entity;

architecture rtl of hbm_tg is
  constant BYTES_PER_BEAT : natural := AXI_DW / 8;
  -- log2 of BYTES_PER_BEAT, for ARSIZE.  256 bit -> 32 B -> ARSIZE 5.
  function clog2(n : natural) return natural is
    variable r : natural := 0; variable v : natural := n - 1;
  begin
    while v > 0 loop r := r + 1; v := v / 2; end loop; return r;
  end function;
  constant ARSIZE_V : natural := clog2(BYTES_PER_BEAT);

  -- control registers
  signal go        : std_logic := '0';
  signal clr       : std_logic := '0';
  signal mask      : std_logic_vector(31 downto 0) := (others => '0');
  signal arlen_r   : unsigned(7 downto 0) := to_unsigned(15, 8);  -- 16 beats
  signal nburst    : unsigned(31 downto 0) := to_unsigned(65536, 32);
  signal outst_max : unsigned(7 downto 0) := to_unsigned(16, 8);
  -- Soft temperature ceiling on the RAW 7-bit stack code.  DISABLED (0) by
  -- default and deliberately so: the code-to-Celsius mapping has NOT been
  -- verified on this card, and a limit on a scale nobody has calibrated is
  -- worse than no limit -- it either never fires or fires at random.  Read
  -- the code at a known idle temperature first, against SYSMON and the board
  -- sensors, then set this.  CATTRIP needs no calibration and is always on.
  signal temp_limit : unsigned(6 downto 0) := (others => '0');

  -- per generator
  type u32a is array(0 to NPORT-1) of unsigned(31 downto 0);
  type u16a is array(0 to NPORT-1) of unsigned(15 downto 0);
  signal beats, arstall, issued, retired : u32a := (others => (others => '0'));
  -- WRITE-side counters, deliberately separate from the read ones rather than
  -- summed in fabric.  A mixed run whose totals only appear added cannot say
  -- WHICH direction lost throughput, and that is the whole question.
  signal wbeats, awstall, wissued, wretired : u32a
       := (others => (others => '0'));
  signal werr : u32a := (others => (others => '0'));
  -- Non-OKAY read responses, per port.  OKAY is "00"; EXOKAY "01" cannot
  -- occur on a normal read, SLVERR "10" and DECERR "11" both mean the data
  -- is meaningless.  Anything nonzero invalidates that port's beat count.
  signal rerr : u32a := (others => (others => '0'));
  signal outst   : u16a := (others => (others => '0'));
  -- woutst: AW accepted minus B returned, the write analogue of `outst`.
  -- wcred:  AW accepted minus W BURSTS completed.  These are different
  -- quantities and conflating them is the classic write-path bug -- B can lag
  -- the data by a long time on DRAM, so gating W data on `woutst` would stall
  -- the data channel behind the response channel and measure the controller's
  -- response latency instead of its write bandwidth.
  signal woutst  : u16a := (others => (others => '0'));
  signal wcred   : u16a := (others => (others => '0'));
  signal arv     : std_logic_vector(NPORT-1 downto 0) := (others => '0');
  signal awv     : std_logic_vector(NPORT-1 downto 0) := (others => '0');
  signal wv      : std_logic_vector(NPORT-1 downto 0) := (others => '0');
  signal active  : std_logic_vector(NPORT-1 downto 0) := (others => '0');
  signal wactive : std_logic_vector(NPORT-1 downto 0) := (others => '0');
  signal cycles  : unsigned(31 downto 0) := (others => '0');
  signal any_act : std_logic;

  -- Thermal abort, registered so it cannot glitch, and STICKY so a trip that
  -- lasted one cycle is still visible to a host polling over JTAG milliseconds
  -- later.  A run that trips is not a measurement and must not be reported as
  -- one, which is why the reason is readable.
  signal therm_stop : std_logic := '0';
  signal trip_cat   : std_logic := '0';
  signal trip_lim   : std_logic := '0';
  signal tmax0, tmax1 : unsigned(6 downto 0) := (others => '0');

  -- THERMAL CDC.  hbm_temp/hbm_cattrip leave the HBM IP in its APB status
  -- domain (HBM_SNGLBLI_INTF_APB_INST/PCLK) and were being compared
  -- COMBINATIONALLY here in the AXI domain, with no synchroniser.  Two
  -- separate faults in one:
  --
  --   * Metastability on a SAFETY signal.  CATTRIP is the stacks' own
  --     catastrophic-temperature output and it is the only hard protection
  --     this design has; sampling it asynchronously is the worst possible
  --     place to accept a metastable capture.
  --   * A timed path from a slow domain through a 7-bit compare into the
  --     fast domain.  It made timing at 300 MHz and did NOT at 350: all 34
  --     failing endpoints in the 350 MHz build were this one structure,
  --     worst path PCLK -> therm_stop_reg/D.  It read as an HBM AXI
  --     frequency ceiling and was nothing of the kind.
  --
  -- Two flops per bit, ASYNC_REG so the placer keeps each pair together.
  signal cat0_m, cat0_s, cat1_m, cat1_s : std_logic := '0';
  signal t0_m, t0_s, t1_m, t1_s : std_logic_vector(6 downto 0)
                                := (others => '0');
  attribute ASYNC_REG : string;
  attribute ASYNC_REG of cat0_m : signal is "TRUE";
  attribute ASYNC_REG of cat0_s : signal is "TRUE";
  attribute ASYNC_REG of cat1_m : signal is "TRUE";
  attribute ASYNC_REG of cat1_s : signal is "TRUE";
  attribute ASYNC_REG of t0_m   : signal is "TRUE";
  attribute ASYNC_REG of t0_s   : signal is "TRUE";
  attribute ASYNC_REG of t1_m   : signal is "TRUE";
  attribute ASYNC_REG of t1_s   : signal is "TRUE";

  -- A 7-bit code crossing bit-by-bit can TEAR: two flops make each bit
  -- stable but not the word coherent, so a code stepping 31 -> 32 can be
  -- sampled as 63 for one cycle.  Against a threshold that is a spurious
  -- trip, and a spurious trip aborts a run and is reported as a thermal
  -- event, i.e. it would look exactly like the thing it exists to detect.
  -- Requiring the compare to hold makes a one-cycle tear harmless; the
  -- filter costs 0.2 us at 300 MHz against a thermal time constant of
  -- seconds, so it gives up nothing that matters.
  -- ADDRESS MAPPING.  Port i targets pseudo-channel `rgn_base + i*rgn_stride`.
  --
  -- stride = 1 (the default, and the original hardwired behaviour) gives each
  -- port its OWN channel, which measures aggregate plumbing: it proves N
  -- channels run concurrently without a shared upstream limit.
  --
  -- stride = 0 points EVERY port at one channel, and that is what makes the
  -- memory's own ceiling measurable at 300 MHz.  A 256-bit port at 300 MHz
  -- demands 32 B x 300 MHz = 9.6 GB/s while a pseudo-channel supplies
  -- 460.8/32 = 14.4 GB/s, so a single port can never saturate one and 100% of
  -- the port's ceiling is arithmetically guaranteed rather than discovered.
  -- Two ports on one channel demand 19.2 GB/s against that 14.4 and the
  -- channel becomes the bottleneck; the rate then STOPS scaling with port
  -- count, and the plateau is the channel's real delivered bandwidth.
  --
  -- This is why the upper bound does not require a 450 MHz datapath: 450 MHz
  -- is what a single port needs to match a channel, and oversubscription
  -- reaches the same place with more ports instead of a faster clock.
  -- Defaults reproduce the ORIGINAL hardwired mapping exactly: base = PORT0,
  -- stride = 1, so port i addresses channel i + PORT0 as before.  A build that
  -- never writes register 6 behaves identically to the one that measured
  -- 144.0 GB/s, which keeps that result comparable.
  signal rgn_base   : unsigned(7 downto 0) := to_unsigned(PORT0, 8);
  signal rgn_stride : unsigned(7 downto 0) := to_unsigned(1, 8);

  -- DIRECTION.  `wmask` is per port and orthogonal to `mask`: mask enables a
  -- port at all, wmask says that port writes instead of reads.  Per port
  -- rather than global because C 2.5's pattern is a MIX -- two readers and one
  -- writer live at once -- and a global direction bit could only ever measure
  -- the two pure cases, which are the two least interesting ones.
  --
  -- `rw_both` overrides wmask and runs BOTH engines on every enabled port,
  -- into the same pseudo-channel.  That is the read/write turnaround case, and
  -- it is separate from the mixed-across-ports case because they stress
  -- different things: across ports the channels are independent and the switch
  -- arbitrates; on one port the DRAM bus itself has to turn around.
  --
  -- Defaults are wmask = 0 and rw_both = 0, i.e. read-only, so a build that
  -- never writes these registers behaves EXACTLY as the one that measured
  -- 288.0 GB/s.  That is deliberate: it keeps the new bitstream's read numbers
  -- directly comparable to the old one's, and any difference is then the write
  -- path's cost in placement rather than a change of experiment.
  signal wmask   : std_logic_vector(31 downto 0) := (others => '0');
  signal rw_both : std_logic := '0';

  constant TEMP_HOLD : natural := 64;
  signal lim_hold : unsigned(7 downto 0) := (others => '0');

  -- RESET CDC.  `rstn` comes from a proc_sys_reset in the 100 MHz control
  -- domain and is consumed here at the AXI clock, so Vivado times it as a
  -- data path to the reset input of EVERY flop in this unit.  Two problems:
  --
  --   * Functionally, an unsynchronised reset RELEASE lets flops leave reset
  --     on different cycles.  For counters and an issue FSM that is a
  --     genuinely wrong start state, not a cosmetic race.
  --   * For timing, it puts hundreds of endpoints on one slow-domain source.
  --     At 300 MHz it cost 0.029 ns and looked ignorable.  At 350 MHz it is
  --     386 of the 400 failing endpoints -- the same "one structure, many
  --     instances" shape as every other failure this design has produced.
  --
  -- Async assert, synchronous deassert: the reset still takes effect
  -- immediately without waiting for a clock that may not be running, and it
  -- releases on a single clean edge in THIS domain.  It also collapses those
  -- hundreds of timed paths to two.
  signal rstn_m, rstn_s : std_logic := '0';
  attribute ASYNC_REG of rstn_m : signal is "TRUE";
  attribute ASYNC_REG of rstn_s : signal is "TRUE";

  -- Separate flop for the HBM reset fanout, so replicating it cannot disturb
  -- the synchroniser pair (ASYNC_REG and replication do not mix).
  signal hbm_rstn : std_logic := '0';
  attribute MAX_FANOUT : integer;
  attribute MAX_FANOUT of hbm_rstn : signal is 4;

  signal awr, wrq, bv, arr, rv : std_logic := '0';
  signal rdata_r : std_logic_vector(31 downto 0) := (others => '0');
  signal wa : unsigned(15 downto 0) := (others => '0');
  signal wd : std_logic_vector(31 downto 0) := (others => '0');
  signal aw_seen, w_seen : std_logic := '0';
begin
  ------------------------------------------------------------- reset CDC
  rsync : process(clk, rstn)
  begin
    if rstn = '0' then
      rstn_m <= '0'; rstn_s <= '0';
    elsif rising_edge(clk) then
      rstn_m <= '1'; rstn_s <= rstn_m;
    end if;
  end process;

  -- One more stage before it leaves for the hard block: this is the flop the
  -- tool replicates, and it also guarantees the HBM interfaces come out of
  -- reset no earlier than this unit's own logic.
  hbmrst : process(clk, rstn)
  begin
    if rstn = '0' then
      hbm_rstn <= '0';
    elsif rising_edge(clk) then
      hbm_rstn <= rstn_s;
    end if;
  end process;
  aresetn_o <= hbm_rstn;

  ----------------------------------------------------------------- AXI-Lite
  -- Deliberately the simplest legal slave: one transaction at a time, no
  -- outstanding, no write strobes.  It carries control and status only and is
  -- never in the measured path, so its performance is irrelevant and its
  -- correctness is worth more than its throughput.
  -- READY IS GATED BY RESET.  The reset branch below parks awr/wrq at '1' so
  -- the slave is ready on the first cycle out of reset -- but that also meant
  -- it advertised READY *while still in reset*, where the decode is in the
  -- reset branch and throws the beat away.  A master that takes READY at its
  -- word therefore loses any transfer issued during the reset window, which
  -- is the SAME defect as the AW/W one fixed in 8643fcb, arriving by a
  -- different route.  It was invisible until the reset synchroniser widened
  -- that window from zero cycles to two.
  s_awready <= awr and rstn_s; s_wready <= wrq and rstn_s; s_bvalid <= bv;
  s_arready <= arr and rstn_s; s_rvalid <= rv;  s_rdata <= rdata_r;

  lite : process(clk)
    variable idx : natural;
  begin
    if rising_edge(clk) then
      clr <= '0';
      if rstn_s = '0' then
        awr <= '1'; wrq <= '1'; bv <= '0'; arr <= '1'; rv <= '0';
        aw_seen <= '0'; w_seen <= '0';
        go <= '0'; mask <= (others => '0');
        rgn_base <= to_unsigned(PORT0, 8); rgn_stride <= to_unsigned(1, 8);
        wmask <= (others => '0'); rw_both <= '0';
      else
        -- WRITE.  AW and W are captured INDEPENDENTLY and the decode fires
        -- when both have arrived.
        --
        -- The first version made the W decode conditional on the address
        -- having already been captured, while holding WREADY high from reset.
        -- A master that presents AW and W in the SAME cycle -- which
        -- smartconnect does -- therefore saw WREADY high, considered the data
        -- beat transferred, and dropped WVALID; the slave meanwhile skipped it
        -- because the address had not been latched yet.  Every write was
        -- silently lost.  Reads worked perfectly throughout, which made it
        -- look like an address-map or a generator problem rather than a
        -- protocol one.  MEASURED on hardware 2026-08-25: the sweep moved
        -- zero beats and no control register ever changed.
        --
        -- A ready signal is a PROMISE that the beat is being taken this cycle.
        -- It must not be asserted by a slave that is not yet able to keep it.
        if s_awvalid = '1' and awr = '1' then
          wa <= unsigned(s_awaddr);
          aw_seen <= '1';
          awr <= '0';
        end if;
        if s_wvalid = '1' and wrq = '1' then
          wd <= s_wdata;
          w_seen <= '1';
          wrq <= '0';
        end if;
        if (aw_seen = '1' or (s_awvalid = '1' and awr = '1')) and
           (w_seen  = '1' or (s_wvalid  = '1' and wrq = '1')) and bv = '0' then
          bv <= '1';
        end if;
        if bv = '1' and s_bready = '1' then
          bv <= '0'; awr <= '1'; wrq <= '1';
          aw_seen <= '0'; w_seen <= '0';
          -- decode from the CAPTURED address and data, once, at completion
          case to_integer(wa(7 downto 2)) is
            when 0 => go  <= wd(0); clr <= wd(1);
            when 1 => mask       <= wd;
            when 2 => arlen_r    <= unsigned(wd(7 downto 0));
            when 3 => nburst     <= unsigned(wd);
            when 4 => outst_max  <= unsigned(wd(7 downto 0));
            when 5 => temp_limit <= unsigned(wd(6 downto 0));
            when 6 => rgn_base   <= unsigned(wd(7 downto 0));
                      rgn_stride <= unsigned(wd(15 downto 8));
            when 7 => wmask      <= wd;
            when 8 => rw_both    <= wd(0);
            when others => null;
          end case;
        end if;
        -- read
        if s_arvalid = '1' and arr = '1' then
          idx := to_integer(unsigned(s_araddr(13 downto 2)));
          if    idx = 0 then rdata_r <= x"48424D31";                 -- "HBM1"
          elsif idx = 1 then rdata_r <= std_logic_vector(cycles);
          elsif idx = 2 then
            rdata_r <= (31 downto 1 => '0') & any_act;   -- 31 + 1, checked
          elsif idx = 3 then rdata_r <= std_logic_vector(to_unsigned(NPORT, 32));
          -- THERMAL status.  Live codes, the high-water marks seen during the
          -- run, and why it stopped.  A host that reads only bandwidth and not
          -- this register is reading a number that may have been produced by a
          -- run that aborted a microsecond in.
          elsif idx = 4 then
            -- FOUR 7-bit fields plus 4 pad = 32.  Written as an explicit
            -- 4-bit literal rather than a (31 downto N => '0') aggregate:
            -- that form's width is inferred from context inside a
            -- concatenation, GHDL and Vivado inferred it DIFFERENTLY, and the
            -- first version packed 39 bits into 32 with simulation green.
            rdata_r <= "0000" & std_logic_vector(tmax1)
                       & std_logic_vector(tmax0)
                       & t1_s & t0_s;   -- synchronised, not the raw pins
          elsif idx = 5 then
            rdata_r <= (31 downto 4 => '0')
                       & trip_lim & trip_cat & therm_stop & '0';
          -- CONTROL READBACK, at 0x100.  The control registers were
          -- write-only, so when every write was being silently dropped on the
          -- bus there was no way to ask the design what it thought it had been
          -- told, and the fault had to be cornered indirectly.  A register you
          -- cannot read back is a register you cannot debug.
          elsif idx = 64 then
            rdata_r <= (31 downto 2 => '0') & clr & go;
          elsif idx = 65 then rdata_r <= mask;
          elsif idx = 66 then
            rdata_r <= (31 downto 8 => '0') & std_logic_vector(arlen_r);
          elsif idx = 67 then rdata_r <= std_logic_vector(nburst);
          elsif idx = 68 then
            rdata_r <= (31 downto 8 => '0') & std_logic_vector(outst_max);
          elsif idx = 69 then
            rdata_r <= (31 downto 7 => '0') & std_logic_vector(temp_limit);
          elsif idx = 70 then
            rdata_r <= (31 downto 16 => '0') & std_logic_vector(rgn_stride)
                       & std_logic_vector(rgn_base);
          elsif idx = 71 then rdata_r <= wmask;
          elsif idx = 72 then rdata_r <= (31 downto 1 => '0') & rw_both;
          elsif idx >= 256 and idx < 256 + NPORT then
            rdata_r <= std_logic_vector(beats(idx - 256));
          elsif idx >= 512 and idx < 512 + NPORT then
            rdata_r <= std_logic_vector(arstall(idx - 512));
          elsif idx >= 768 and idx < 768 + NPORT then
            rdata_r <= std_logic_vector(retired(idx - 768));
          elsif idx >= 1024 and idx < 1024 + NPORT then
            rdata_r <= std_logic_vector(rerr(idx - 1024));
          -- write-side status, mirroring the read blocks
          elsif idx >= 1280 and idx < 1280 + NPORT then
            rdata_r <= std_logic_vector(wbeats(idx - 1280));
          elsif idx >= 1536 and idx < 1536 + NPORT then
            rdata_r <= std_logic_vector(awstall(idx - 1536));
          elsif idx >= 1792 and idx < 1792 + NPORT then
            rdata_r <= std_logic_vector(wretired(idx - 1792));
          elsif idx >= 2048 and idx < 2048 + NPORT then
            rdata_r <= std_logic_vector(werr(idx - 2048));
          else rdata_r <= (others => '0');
          end if;
          arr <= '0'; rv <= '1';
        end if;
        if rv = '1' and s_rready = '1' then rv <= '0'; arr <= '1'; end if;
      end if;
    end if;
  end process;

  -- Wall time counts while EITHER engine is running.  wactive only clears when
  -- the last B response is in, so a write run's cycle count covers the drain
  -- and a mixed run's covers whichever direction finishes last.
  any_act <= '1' when active  /= (active'range  => '0')
                   or wactive /= (wactive'range => '0') else '0';

  -- The thermal watchdog.  In FABRIC, not in the host: a JTAG poll loop is
  -- milliseconds away and 15 HBM ports at 450 MHz do not wait for it.
  therm : process(clk)
    variable over : boolean;
  begin
    if rising_edge(clk) then
      -- the CDC itself, unconditional: a synchroniser that can be held in
      -- reset is a synchroniser that reports stale data after reset release
      cat0_m <= hbm_cattrip0; cat0_s <= cat0_m;
      cat1_m <= hbm_cattrip1; cat1_s <= cat1_m;
      t0_m   <= hbm_temp0;    t0_s   <= t0_m;
      t1_m   <= hbm_temp1;    t1_s   <= t1_m;

      if rstn_s = '0' then
        therm_stop <= '0'; trip_cat <= '0'; trip_lim <= '0';
        tmax0 <= (others => '0'); tmax1 <= (others => '0');
        lim_hold <= (others => '0');
      else
        if clr = '1' then
          therm_stop <= '0'; trip_cat <= '0'; trip_lim <= '0';
          tmax0 <= (others => '0'); tmax1 <= (others => '0');
          lim_hold <= (others => '0');
        end if;
        -- high-water marks, held across the run
        if unsigned(t0_s) > tmax0 then tmax0 <= unsigned(t0_s); end if;
        if unsigned(t1_s) > tmax1 then tmax1 <= unsigned(t1_s); end if;
        -- CATTRIP is the stacks' own catastrophic signal and needs no
        -- calibration, so it is always armed and is NOT hold-filtered: it is
        -- a single bit, so it cannot tear, and delaying the only hard
        -- protection to debounce a fault that cannot occur would be trading
        -- real safety for none.
        if cat0_s = '1' or cat1_s = '1' then
          trip_cat <= '1'; therm_stop <= '1';
        end if;
        -- the soft ceiling, only when a nonzero limit has been programmed,
        -- and only once the condition has held TEMP_HOLD cycles (see the
        -- tearing note at the declaration)
        over := temp_limit /= 0 and
                (unsigned(t0_s) > temp_limit or unsigned(t1_s) > temp_limit);
        if over then
          if lim_hold < TEMP_HOLD then
            lim_hold <= lim_hold + 1;
          else
            trip_lim <= '1'; therm_stop <= '1';
          end if;
        else
          lim_hold <= (others => '0');
        end if;
      end if;
    end if;
  end process;

  ------------------------------------------------------------- generators
  -- mask/wmask are 32 bits, so a build with more than 32 ports would index
  -- past them silently.  30 is this instrument's ceiling anyway (SAXI_00 and
  -- SAXI_16 carry jtag_hbm), but a silent wrap is not an acceptable way to
  -- discover that.
  assert NPORT <= 32
    report "hbm_tg: NPORT > 32 exceeds the width of mask/wmask"
    severity failure;

  gen : for i in 0 to NPORT-1 generate
    signal aoff  : unsigned(REGION_LOG2-1 downto 0) := (others => '0');
    -- Separate write cursor.  In rw_both mode the two engines sweep the SAME
    -- region independently, which is the point: they collide in the DRAM
    -- pages exactly as two masters on one channel would.
    signal waoff : unsigned(REGION_LOG2-1 downto 0) := (others => '0');
    signal wbcnt : unsigned(7 downto 0) := (others => '0');
    -- Write payload.  Free-running, so no operand is constant: a synthesiser
    -- given a constant WDATA is free to collapse the 256-bit fanout, and the
    -- write path would then be cheaper in the bitstream than in the design it
    -- is standing in for.  The VALUE is meaningless -- nothing reads it back.
    signal wpat  : unsigned(31 downto 0) := (others => '0');
    signal rd_en, wr_en : std_logic;
    -- EVENT REGISTERS.  The HBM AXI interface cell has a large clock-to-out,
    -- and at a 2.1 ns period its outputs cannot cross the fabric AND drive a
    -- counter's control pins in the same cycle: the first build missed by
    -- 1.868 ns on 4,597 endpoints, which is 15 generators x their counters,
    -- i.e. ONE structural problem replicated rather than 4,597 distinct ones.
    --
    -- So the HANDSHAKE stays combinational, because AXI requires it, and only
    -- the BOOKKEEPING is delayed by a cycle.  Nothing is lost: every beat is
    -- still counted, the run is millions of cycles long, and a uniform
    -- one-cycle offset does not bias a ratio.  `outst` may momentarily exceed
    -- its cap by one, which is harmless.
    signal ev_ar, ev_r, ev_rl, ev_re : std_logic := '0';
    signal ev_aw, ev_w, ev_b, ev_be : std_logic := '0';
  begin
    rd_en <= mask(i) and ((not wmask(i)) or rw_both);
    wr_en <= mask(i) and (wmask(i) or rw_both);

    m_arvalid(i) <= arv(i);
    m_arlen  ((i+1)*8-1 downto i*8) <= std_logic_vector(arlen_r);
    m_arsize ((i+1)*3-1 downto i*3) <= std_logic_vector(to_unsigned(ARSIZE_V, 3));
    m_arburst((i+1)*2-1 downto i*2) <= "01";                       -- INCR
    -- High bits select the pseudo-channel, low bits sweep within it.  The
    -- channel is `rgn_base + i*rgn_stride`, truncated to the region field, so
    -- stride 0 puts every port on one channel (see the declaration).
    m_araddr((i+1)*ADDR_W-1 downto i*ADDR_W) <=
      std_logic_vector(resize(
        resize(rgn_base + to_unsigned(i, 8) * rgn_stride, ADDR_W-REGION_LOG2) &
        aoff, ADDR_W));
    -- Always ready: a generator that back-pressures its own read data would
    -- measure the generator, not the memory.
    m_rready(i) <= '1';

    ------------------------------------------------------------ write outputs
    m_awvalid(i) <= awv(i);
    m_awlen  ((i+1)*8-1 downto i*8) <= std_logic_vector(arlen_r);
    m_awsize ((i+1)*3-1 downto i*3) <= std_logic_vector(to_unsigned(ARSIZE_V, 3));
    m_awburst((i+1)*2-1 downto i*2) <= "01";                       -- INCR
    m_awaddr((i+1)*ADDR_W-1 downto i*ADDR_W) <=
      std_logic_vector(resize(
        resize(rgn_base + to_unsigned(i, 8) * rgn_stride, ADDR_W-REGION_LOG2) &
        waoff, ADDR_W));
    m_wvalid(i) <= wv(i);
    -- WLAST from the beat counter, which is a register, so this is one level
    -- of compare out of a flop and not a path from the HBM cell.
    m_wlast(i)  <= '1' when wbcnt = arlen_r else '0';
    m_wstrb((i+1)*(AXI_DW/8)-1 downto i*(AXI_DW/8)) <= (others => '1');
    -- One 32-bit pattern replicated across the beat.  Replication is fine --
    -- nothing inspects the data -- and it keeps the payload register 32 bits
    -- instead of 256 per port, which at 30 ports is the difference between a
    -- rounding error and 7,680 flops.
    wrep : for k in 0 to AXI_DW/32 - 1 generate
      m_wdata(i*AXI_DW + (k+1)*32 - 1 downto i*AXI_DW + k*32)
        <= std_logic_vector(wpat);
    end generate;
    -- Always ready for B: back-pressuring the response channel would stall
    -- the write engine on our own bookkeeping.
    m_bready(i) <= '1';

    -- OUTSTANDING COUNT: one assignment, never two.  An AR accept and the
    -- LAST beat of the previous burst land on the SAME edge whenever the
    -- memory turns around promptly, and with a separate `+1` and `-1` branch
    -- the later signal assignment simply wins, so the increment is lost.  The
    -- counter then drifts down, underflows its unsigned range, and the
    -- generator stops issuing FOREVER while still reporting itself active --
    -- the run looks like a memory that went quiet rather than a counter bug.
    -- Caught in simulation against the known-rate model (sim/tb_hbm_tg.vhd),
    -- which is the entire reason that model exists.
    p : process(clk)
      variable burst_bytes : unsigned(REGION_LOG2-1 downto 0);
      variable ar_acc, r_end : boolean;
      variable wl_hs         : boolean;
    begin
      if rising_edge(clk) then
        -- one register stage on everything the HBM drives, see the note above
        ev_ar <= '0'; ev_r <= '0'; ev_rl <= '0'; ev_re <= '0';
        ev_aw <= '0'; ev_w <= '0'; ev_b <= '0'; ev_be <= '0';
        -- free-running payload, never reset to a constant during a run
        wpat <= wpat + to_unsigned(i, 32) + 1;
        if rstn_s = '0' then
          arv(i) <= '0'; active(i) <= '0';
          beats(i) <= (others => '0'); arstall(i) <= (others => '0');
          rerr(i) <= (others => '0');
          issued(i) <= (others => '0'); retired(i) <= (others => '0');
          outst(i) <= (others => '0'); aoff <= (others => '0');
          awv(i) <= '0'; wv(i) <= '0'; wactive(i) <= '0';
          wbeats(i) <= (others => '0'); awstall(i) <= (others => '0');
          werr(i) <= (others => '0');
          wissued(i) <= (others => '0'); wretired(i) <= (others => '0');
          woutst(i) <= (others => '0'); wcred(i) <= (others => '0');
          waoff <= (others => '0'); wbcnt <= (others => '0');
        else
          if clr = '1' then
            beats(i) <= (others => '0'); arstall(i) <= (others => '0');
            rerr(i) <= (others => '0');
            issued(i) <= (others => '0'); retired(i) <= (others => '0');
            outst(i) <= (others => '0'); aoff <= (others => '0');
            arv(i) <= '0'; active(i) <= '0';
            awv(i) <= '0'; wv(i) <= '0'; wactive(i) <= '0';
            wbeats(i) <= (others => '0'); awstall(i) <= (others => '0');
            werr(i) <= (others => '0');
            wissued(i) <= (others => '0'); wretired(i) <= (others => '0');
            woutst(i) <= (others => '0'); wcred(i) <= (others => '0');
            waoff <= (others => '0'); wbcnt <= (others => '0');
          elsif therm_stop = '1' then
            -- Thermal stop wins over everything.  Dropping `active` halts AR
            -- issue immediately; bursts already accepted still drain, which is
            -- required -- abandoning them would hang the AXI channel.
            active(i) <= '0';
            arv(i)    <= '0';
            -- Same rule on the write side, with one addition: AW issue stops
            -- but W data does NOT, because the W engine is gated on `wcred`
            -- and must finish the bursts whose AW the memory has already
            -- accepted.  Abandoning write data mid-burst hangs the channel
            -- permanently -- worse than the thermal event being escaped.
            wactive(i) <= '0';
            awv(i)     <= '0';
          else
            -- `retired < nburst` is the ARM CONDITION, not decoration.  The
            -- host holds `go` high for the whole run, so without it a
            -- generator that has just finished sees go=1 and active=0 on the
            -- very next cycle and re-arms itself with no work left: it can
            -- never retire another burst, so it never clears active, so the
            -- busy flag never deasserts and the host polls forever.  `clr`
            -- zeroes `retired`, which is what makes the next run start.
            --
            -- The two engines arm INDEPENDENTLY, not in an elsif chain: in
            -- rw_both mode one port runs both, and a chain would let whichever
            -- branch came first starve the other for the whole run.
            if go = '1' and active(i) = '0' and rd_en = '1'
               and retired(i) < nburst then
              active(i) <= '1';
            end if;
            if go = '1' and wactive(i) = '0' and wr_en = '1'
               and wretired(i) < nburst then
              wactive(i) <= '1';
            end if;
          end if;

          ar_acc := false;
          r_end  := false;

          -- ISSUE.  The handshake itself is combinational because AXI
          -- requires arvalid/arready to be sampled together; only what it
          -- RECORDS is registered.
          if active(i) = '1' then
            if arv(i) = '0' then
              -- `issued` is now registered and therefore one cycle stale, so
              -- the gate must add the accept already in flight or the run
              -- overshoots by exactly the pipeline depth (measured: 1029 beats
              -- against 1024).  ev_ar is a LOCAL register, not an HBM signal,
              -- so adding it here does not put the bus back on this path.
              if issued(i) + (0 => ev_ar) < nburst
                 and outst(i) < resize(outst_max, 16) then
                arv(i) <= '1';
              end if;
            else
              if m_arready(i) = '1' then
                arv(i) <= '0';
                ev_ar  <= '1';
                burst_bytes := resize((resize(arlen_r,32) + 1) *
                                      to_unsigned(BYTES_PER_BEAT, 24),
                                      REGION_LOG2);
                aoff <= aoff + burst_bytes;   -- wraps inside the region
              else
                -- ARVALID held without ARREADY: the memory is the limit here
                arstall(i) <= arstall(i) + 1;
              end if;
            end if;
          end if;

          ------------------------------------------------------ write issue
          -- AW, structurally identical to AR.  `woutst` is the AW-to-B
          -- outstanding count and is what the depth cap applies to; it is NOT
          -- what gates the data channel (see the wcred note at the
          -- declaration).
          if wactive(i) = '1' then
            if awv(i) = '0' then
              if wissued(i) + (0 => ev_aw) < nburst
                 and woutst(i) < resize(outst_max, 16) then
                awv(i) <= '1';
              end if;
            else
              if m_awready(i) = '1' then
                awv(i) <= '0';
                ev_aw  <= '1';
                waoff <= waoff + resize((resize(arlen_r,32) + 1) *
                                        to_unsigned(BYTES_PER_BEAT, 24),
                                        REGION_LOG2);
              else
                awstall(i) <= awstall(i) + 1;
              end if;
            end if;
          end if;

          ------------------------------------------------------- write data
          -- W streams whenever an accepted AW has data still owing.  The
          -- burst boundary is the part worth being careful about: dropping
          -- WVALID for one cycle between bursts costs 1 cycle in ARLEN+1,
          -- which at the AXI3 maximum of 16 beats is 6% -- large enough to be
          -- mistaken for a property of the memory.  So WVALID is held across
          -- the boundary whenever another burst is already owed.
          --
          -- wcred is DECREMENTED ON THE HANDSHAKE ITSELF, not via an event
          -- register.  The first version deferred it by a cycle like every
          -- other counter here, and that is a real bug, not a cosmetic one:
          -- after the last burst's final beat the idle branch below still saw
          -- a nonzero credit for one cycle and re-asserted WVALID with no AW
          -- behind it.  Against this testbench's original model it was
          -- invisible, because that model refused write data with no address;
          -- against real HBM, which asserts WREADY freely out of its write
          -- buffer, it sends an extra burst of data the memory never framed --
          -- a permanently desynchronised write channel.
          --
          -- The AW side stays deferred, which is the safe direction: it makes
          -- the credit UNDERSTATE what is owed, so the engine can idle a cycle
          -- but can never over-send.
          wl_hs := wv(i) = '1' and m_wready(i) = '1' and wbcnt = arlen_r;
          if wv(i) = '0' then
            if wcred(i) /= 0 or ev_aw = '1' then
              wv(i) <= '1';
              wbcnt <= (others => '0');
            end if;
          else
            if m_wready(i) = '1' then
              ev_w <= '1';
              if wbcnt = arlen_r then
                wbcnt <= (others => '0');
                -- Continue across the boundary only if another burst is
                -- already owed.  wcred still counts the one just finished at
                -- this point (its decrement lands on this same edge), so the
                -- test is > 1, plus an AW landing on this edge.
                if wcred(i) > 1 or ev_aw = '1' then
                  wv(i) <= '1';
                else
                  wv(i) <= '0';
                end if;
              else
                wbcnt <= wbcnt + 1;
              end if;
            end if;
          end if;

          -- B response.  Always accepted, so no handshake to preserve.
          if m_bvalid(i) = '1' then
            ev_b  <= '1';
            ev_be <= m_bresp(2*i+1) or m_bresp(2*i);
          else
            ev_be <= '0';
          end if;

          -- ACCEPT.  rready is a constant '1', so there is no handshake to
          -- preserve here and the whole R channel can be registered.
          if m_rvalid(i) = '1' then
            ev_r <= '1';
            if m_rlast(i) = '1' then ev_rl <= '1'; end if;
            -- Registered alongside the beat, on the same condition, so an
            -- errored beat is counted in BOTH places and the two totals stay
            -- directly comparable: beats == good beats exactly when rerr = 0.
            ev_re <= m_rresp(2*i+1) or m_rresp(2*i);
          else
            ev_re <= '0';
          end if;

          -- the registered bookkeeping, one cycle behind the bus
          ar_acc := ev_ar = '1';
          r_end  := ev_rl = '1';
          if ev_r = '1' then
            beats(i) <= beats(i) + 1;
            if ev_re = '1' then rerr(i) <= rerr(i) + 1; end if;
          end if;
          if ar_acc then issued(i) <= issued(i) + 1; end if;
          if r_end then
            retired(i) <= retired(i) + 1;
            if retired(i) + 1 = nburst then active(i) <= '0'; end if;
          end if;
          -- the single outstanding-count update, see the note above
          if ar_acc and not r_end then
            outst(i) <= outst(i) + 1;
          elsif r_end and not ar_acc then
            outst(i) <= outst(i) - 1;
          end if;

          ------------------------------------------- registered write counters
          if ev_w = '1' then
            wbeats(i) <= wbeats(i) + 1;
          end if;
          if ev_aw = '1' then wissued(i) <= wissued(i) + 1; end if;
          if ev_b = '1' then
            wretired(i) <= wretired(i) + 1;
            if ev_be = '1' then werr(i) <= werr(i) + 1; end if;
            if wretired(i) + 1 = nburst then wactive(i) <= '0'; end if;
          end if;
          -- Both write counters get the same one-assignment treatment the read
          -- side needed, and for the same reason: an AW accept and a B return
          -- land on the same edge routinely, and two branches would silently
          -- drop the increment and underflow the counter.
          if ev_aw = '1' and ev_b = '0' then
            woutst(i) <= woutst(i) + 1;
          elsif ev_b = '1' and ev_aw = '0' then
            woutst(i) <= woutst(i) - 1;
          end if;
          if ev_aw = '1' and not wl_hs then
            wcred(i) <= wcred(i) + 1;
          elsif wl_hs and ev_aw = '0' then
            wcred(i) <= wcred(i) - 1;
          end if;
        end if;
      end if;
    end process;
  end generate;

  -- One clock domain, one counter: the wall time every port shares.
  tick : process(clk)
  begin
    if rising_edge(clk) then
      if rstn_s = '0' or clr = '1' then cycles <= (others => '0');
      elsif any_act = '1' then        cycles <= cycles + 1;
      end if;
    end if;
  end process;
end architecture;
