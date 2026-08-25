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
-- READS ONLY.  A's weight path is read-only (rtl/axi_rd_port.vhd has no write
-- channel at all), so a write-capable generator would measure traffic the
-- design never issues, and would risk corrupting whatever else is resident.
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
    m_rlast   : in  std_logic_vector(NPORT-1 downto 0)
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
  signal outst   : u16a := (others => (others => '0'));
  signal arv     : std_logic_vector(NPORT-1 downto 0) := (others => '0');
  signal active  : std_logic_vector(NPORT-1 downto 0) := (others => '0');
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

  signal awr, wrq, bv, arr, rv : std_logic := '0';
  signal rdata_r : std_logic_vector(31 downto 0) := (others => '0');
  signal wa : unsigned(15 downto 0) := (others => '0');
  signal wd : std_logic_vector(31 downto 0) := (others => '0');
  signal aw_seen, w_seen : std_logic := '0';
begin
  ----------------------------------------------------------------- AXI-Lite
  -- Deliberately the simplest legal slave: one transaction at a time, no
  -- outstanding, no write strobes.  It carries control and status only and is
  -- never in the measured path, so its performance is irrelevant and its
  -- correctness is worth more than its throughput.
  s_awready <= awr; s_wready <= wrq; s_bvalid <= bv;
  s_arready <= arr; s_rvalid <= rv;  s_rdata <= rdata_r;

  lite : process(clk)
    variable idx : natural;
  begin
    if rising_edge(clk) then
      clr <= '0';
      if rstn = '0' then
        awr <= '1'; wrq <= '1'; bv <= '0'; arr <= '1'; rv <= '0';
        aw_seen <= '0'; w_seen <= '0';
        go <= '0'; mask <= (others => '0');
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
                       & hbm_temp1 & hbm_temp0;
          elsif idx = 5 then
            rdata_r <= (31 downto 4 => '0')
                       & trip_lim & trip_cat & therm_stop & '0';
          elsif idx >= 256 and idx < 256 + NPORT then
            rdata_r <= std_logic_vector(beats(idx - 256));
          elsif idx >= 512 and idx < 512 + NPORT then
            rdata_r <= std_logic_vector(arstall(idx - 512));
          elsif idx >= 768 and idx < 768 + NPORT then
            rdata_r <= std_logic_vector(retired(idx - 768));
          else rdata_r <= (others => '0');
          end if;
          arr <= '0'; rv <= '1';
        end if;
        if rv = '1' and s_rready = '1' then rv <= '0'; arr <= '1'; end if;
      end if;
    end if;
  end process;

  any_act <= '1' when active /= (active'range => '0') else '0';

  -- The thermal watchdog.  In FABRIC, not in the host: a JTAG poll loop is
  -- milliseconds away and 15 HBM ports at 450 MHz do not wait for it.
  therm : process(clk)
  begin
    if rising_edge(clk) then
      if rstn = '0' then
        therm_stop <= '0'; trip_cat <= '0'; trip_lim <= '0';
        tmax0 <= (others => '0'); tmax1 <= (others => '0');
      else
        if clr = '1' then
          therm_stop <= '0'; trip_cat <= '0'; trip_lim <= '0';
          tmax0 <= (others => '0'); tmax1 <= (others => '0');
        end if;
        -- high-water marks, held across the run
        if unsigned(hbm_temp0) > tmax0 then tmax0 <= unsigned(hbm_temp0); end if;
        if unsigned(hbm_temp1) > tmax1 then tmax1 <= unsigned(hbm_temp1); end if;
        -- CATTRIP is the stacks' own catastrophic signal and needs no
        -- calibration, so it is always armed.
        if hbm_cattrip0 = '1' or hbm_cattrip1 = '1' then
          trip_cat <= '1'; therm_stop <= '1';
        end if;
        -- the soft ceiling, only when a nonzero limit has been programmed
        if temp_limit /= 0 and
           (unsigned(hbm_temp0) > temp_limit or
            unsigned(hbm_temp1) > temp_limit) then
          trip_lim <= '1'; therm_stop <= '1';
        end if;
      end if;
    end if;
  end process;

  ------------------------------------------------------------- generators
  gen : for i in 0 to NPORT-1 generate
    signal aoff : unsigned(REGION_LOG2-1 downto 0) := (others => '0');
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
    signal ev_ar, ev_r, ev_rl : std_logic := '0';
  begin
    m_arvalid(i) <= arv(i);
    m_arlen  ((i+1)*8-1 downto i*8) <= std_logic_vector(arlen_r);
    m_arsize ((i+1)*3-1 downto i*3) <= std_logic_vector(to_unsigned(ARSIZE_V, 3));
    m_arburst((i+1)*2-1 downto i*2) <= "01";                       -- INCR
    -- Port-local slice: the high bits are the port index, the low bits sweep.
    m_araddr((i+1)*ADDR_W-1 downto i*ADDR_W) <=
      std_logic_vector(resize(to_unsigned(i + PORT0, ADDR_W-REGION_LOG2) &
                              aoff, ADDR_W));
    -- Always ready: a generator that back-pressures its own read data would
    -- measure the generator, not the memory.
    m_rready(i) <= '1';

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
    begin
      if rising_edge(clk) then
        -- one register stage on everything the HBM drives, see the note above
        ev_ar <= '0'; ev_r <= '0'; ev_rl <= '0';
        if rstn = '0' then
          arv(i) <= '0'; active(i) <= '0';
          beats(i) <= (others => '0'); arstall(i) <= (others => '0');
          issued(i) <= (others => '0'); retired(i) <= (others => '0');
          outst(i) <= (others => '0'); aoff <= (others => '0');
        else
          if clr = '1' then
            beats(i) <= (others => '0'); arstall(i) <= (others => '0');
            issued(i) <= (others => '0'); retired(i) <= (others => '0');
            outst(i) <= (others => '0'); aoff <= (others => '0');
            arv(i) <= '0'; active(i) <= '0';
          elsif therm_stop = '1' then
            -- Thermal stop wins over everything.  Dropping `active` halts AR
            -- issue immediately; bursts already accepted still drain, which is
            -- required -- abandoning them would hang the AXI channel.
            active(i) <= '0';
            arv(i)    <= '0';
          elsif go = '1' and active(i) = '0' and mask(i) = '1'
                and retired(i) < nburst and therm_stop = '0' then
            -- `retired < nburst` is the ARM CONDITION, not decoration.  The
            -- host holds `go` high for the whole run, so without it a
            -- generator that has just finished sees go=1 and active=0 on the
            -- very next cycle and re-arms itself with no work left: it can
            -- never retire another burst, so it never clears active, so the
            -- busy flag never deasserts and the host polls forever.  `clr`
            -- zeroes `retired`, which is what makes the next run start.
            active(i) <= '1';
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

          -- ACCEPT.  rready is a constant '1', so there is no handshake to
          -- preserve here and the whole R channel can be registered.
          if m_rvalid(i) = '1' then
            ev_r <= '1';
            if m_rlast(i) = '1' then ev_rl <= '1'; end if;
          end if;

          -- the registered bookkeeping, one cycle behind the bus
          ar_acc := ev_ar = '1';
          r_end  := ev_rl = '1';
          if ev_r = '1' then beats(i) <= beats(i) + 1; end if;
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
        end if;
      end if;
    end process;
  end generate;

  -- One clock domain, one counter: the wall time every port shares.
  tick : process(clk)
  begin
    if rising_edge(clk) then
      if rstn = '0' or clr = '1' then cycles <= (others => '0');
      elsif any_act = '1' then        cycles <= cycles + 1;
      end if;
    end if;
  end process;
end architecture;
