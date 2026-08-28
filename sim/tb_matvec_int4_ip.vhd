-- sim/tb_matvec_int4_ip.vhd
--
-- WHY THIS EXISTS.  rtl/matvec_int4_ip.vhd is the top the AXU3EG and FK33
-- block designs instantiate as a module reference, and until this file it was
-- simulated by NOTHING.  sim/regress.sh's coverage section named it as the one
-- gap on the uncovered list that is not a skeleton.
--
-- The near miss is that it LOOKS covered.  tb_matvec_axi exercises the whole
-- hierarchy underneath it -- but it instantiates `matvec_int4_axi` directly and
-- drives the FLATTENED master ports (`m_araddr` and friends, one wide vector
-- for all NPORTS_W+1 masters).  matvec_int4_ip's entire content is the
-- translation between that flattened convention and the individually NAMED
-- m00_axi_* .. m04_axi_* ports Vivado's interface inference keys on.  The
-- translation is therefore the one layer no simulation touched, and it is the
-- layer whose mistakes reach a bitstream directly:
--
--   * a slice off by one ADDR_W would point a master at another master's
--     sub-region.  Every weight still arrives, so nothing hangs and nothing
--     errors -- the answer is just wrong, which is the failure mode this
--     project has repeatedly found hardest to see.
--   * a lane swap on the RETURN path (rdata/rvalid/rlast) is the same class.
--   * the tied-off constants (arlock, arcache, arprot, arqos) exist only here.
--     arcache = "0011" in particular is what makes the HP ports treat the
--     stream as bufferable; a wrong constant is a performance cliff nobody
--     would attribute to this file.
--   * sim/run_matvec.sh stage 4c ELABORATES this wrapper, deliberately, to
--     catch a generic that was not threaded through.  Elaboration proves the
--     ports connect.  It cannot prove they connect to the RIGHT lane, and that
--     is the whole difference between stage 4c and this file.
--
-- HOW IT IS TESTED.  Differentially, against the thing the wrapper wraps.
-- Both `matvec_int4_ip` (DUT) and `matvec_int4_axi` (REF) are instantiated with
-- IDENTICAL generics and driven from ONE AXI-Lite stimulus.  The wrapper is
-- pure combinational re-bundling, so the two must agree cycle for cycle:
-- lane k of the REF's flattened bus must equal the DUT's m0k_axi_* port, in
-- both directions.  Any mis-slice, lane swap or missing tie-off breaks that
-- equality.  The five AXI read slaves serve DATA THAT DEPENDS ON THE LANE, so
-- a swap on the return path also changes what the core computes next and
-- diverges the AR stream, rather than being invisible.
--
-- Independently of the differential check, the five sub-region bases are
-- programmed with DISTINCT top nibbles (0x1..0x5), and the nibble is asserted
-- in BOTH places it can be seen: on the REF's flattened bus, inside the slave
-- model, which pins the CORE's sub-region ordering; and on the DUT's own
-- m0k_axi_araddr in the comparator, which pins the WRAPPER's.  That makes the
-- order claim -- master k serves weight sub-region k, master 4 serves the
-- scales -- hold without reference to the other instance, so a wrapper and a
-- core that were wrong the same way would still be caught.
--
-- NO GOLDEN DATA IS NEEDED and none is read.  The arithmetic result is
-- irrelevant here; tb_matvec_core and tb_matvec_int4 own that.  What is
-- asserted is that the wiring is a bijection.
--
-- THE VACUOUS-PASS GUARD.  A wiring test that runs before any traffic appears
-- passes trivially.  Every one of the five masters must complete at least one
-- AR handshake or the run FAILS, at severity failure, saying so.
--
-- ROWS_IF IS FIXED AT 4 HERE, ON PURPOSE.  matvec_int4_ip declares exactly five
-- named masters (m00..m04) but sizes its internal vectors as ROWS_IF+1, so it
-- is only well formed at ROWS_IF = 4; at 2 the m03/m04 slices index past the
-- vector and it fails to ELABORATE rather than failing a test.  That is a
-- property of the wrapper, not of this testbench, and it is asserted below so
-- the constraint is written down somewhere executable.
--
-- GHDL here is the mcode backend: `ghdl -e` produces no binary and silently
-- succeeds, so `ghdl -r` is run directly.  sim/regress.sh does that.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_matvec_int4_ip is
  generic(
    BLK     : positive := 32;
    RI      : positive := 4;      -- ROWS_IF; see the note above, must be 4
    AXI_DW  : positive := 128;
    ADDR_W  : positive := 32;
    -- STATUS poll cap for the run phase.  A backstop only: the testbench
    -- stops on STATUS.done.  It is not a correctness parameter.
    MAXPOLL : positive := 4000;
    -- Progress line every N microseconds, 0 = off.  The same convention as
    -- tb_attn_emit and friends: a long run that says nothing is
    -- indistinguishable from a hung one.
    HEARTBEAT_US : natural := 0
  );
end entity;

architecture sim of tb_matvec_int4_ip is

  constant NP : integer := RI;              -- NPORTS_W; masters are 0 .. NP

  subtype addr_t is std_logic_vector(ADDR_W-1 downto 0);
  subtype data_t is std_logic_vector(AXI_DW-1 downto 0);
  type addr_arr is array(0 to NP) of addr_t;
  type data_arr is array(0 to NP) of data_t;
  type len_arr  is array(0 to NP) of std_logic_vector(7 downto 0);
  type siz_arr  is array(0 to NP) of std_logic_vector(2 downto 0);
  type bst_arr  is array(0 to NP) of std_logic_vector(1 downto 0);
  type cch_arr  is array(0 to NP) of std_logic_vector(3 downto 0);
  type qos_arr  is array(0 to NP) of std_logic_vector(3 downto 0);
  type prt_arr  is array(0 to NP) of std_logic_vector(2 downto 0);

  signal clk     : std_logic := '0';
  signal aresetn : std_logic := '0';
  signal finished : boolean := false;

  -- ---- AXI-Lite, one stimulus fanned to both instances --------------------
  signal awaddr, araddr_l : std_logic_vector(7 downto 0) := (others => '0');
  signal wdata            : std_logic_vector(31 downto 0) := (others => '0');
  signal wstrb            : std_logic_vector(3 downto 0)  := "1111";
  signal awvalid, wvalid, bready, arvalid_l, rready_l : std_logic := '0';

  -- slave-side outputs, kept separate so they can be compared
  signal d_awready, d_wready, d_bvalid, d_arready_l, d_rvalid_l : std_logic;
  signal r_awready, r_wready, r_bvalid, r_arready_l, r_rvalid_l : std_logic;
  signal d_bresp, d_rresp, r_bresp, r_rresp : std_logic_vector(1 downto 0);
  signal d_rdata_l, r_rdata_l : std_logic_vector(31 downto 0);

  -- ---- REF: flattened master bus -----------------------------------------
  signal r_arvalid, r_arready, r_rvalid, r_rready, r_rlast :
    std_logic_vector(NP downto 0) := (others => '0');
  signal r_araddr  : std_logic_vector((NP+1)*ADDR_W-1 downto 0);
  signal r_arlen   : std_logic_vector((NP+1)*8-1 downto 0);
  signal r_arsize  : std_logic_vector((NP+1)*3-1 downto 0);
  signal r_arburst : std_logic_vector((NP+1)*2-1 downto 0);
  signal r_rdata   : std_logic_vector((NP+1)*AXI_DW-1 downto 0) := (others => '0');

  -- ---- DUT: named masters, collected into arrays so the checker and the
  --      slave models can be generate loops.  The port map below is the only
  --      place the individual names appear, which is the point of the file.
  signal d_arvalid, d_arready, d_rvalid, d_rready, d_rlast :
    std_logic_vector(NP downto 0) := (others => '0');
  signal d_arlock : std_logic_vector(NP downto 0);
  signal d_araddr  : addr_arr;
  signal d_rdata   : data_arr := (others => (others => '0'));
  signal d_arlen   : len_arr;
  signal d_arsize  : siz_arr;
  signal d_arburst : bst_arr;
  signal d_arcache : cch_arr;
  signal d_arprot  : prt_arr;
  signal d_arqos   : qos_arr;

  -- ---- bookkeeping --------------------------------------------------------
  signal ar_seen  : integer_vector(0 to NP) := (others => 0);
  signal nbad     : integer := 0;
  signal nchk     : integer := 0;
  signal running  : boolean := true;

  -- The five sub-region bases, one recognisable nibble each.  Lane k must only
  -- ever see addresses carrying nibble k+1.
  function base_of(k : integer) return unsigned is
  begin
    return to_unsigned((k + 1) * 16#10000000#, ADDR_W);
  end function;

  -- Lane-dependent read data.  A swap on the return path therefore changes
  -- what the core consumes, which diverges the AR stream, instead of being
  -- invisible the way constant fill would be.
  function beat_of(k : integer; a : unsigned) return data_t is
    variable w : std_logic_vector(31 downto 0);
    variable r : data_t;
  begin
    w := std_logic_vector(resize(a, 32) xor to_unsigned(k * 16#11111111#, 32));
    for i in 0 to AXI_DW/32 - 1 loop
      r((i+1)*32-1 downto i*32) := w xor std_logic_vector(to_unsigned(i, 32));
    end loop;
    return r;
  end function;

begin

  assert RI = 4
    report "tb_matvec_int4_ip: matvec_int4_ip declares exactly five named "
         & "masters but sizes its vectors as ROWS_IF+1, so it is only well "
         & "formed at ROWS_IF = 4.  This testbench pins that."
    severity failure;

  aresetn <= '0', '1' after 40 ns;

  clkgen : process
  begin
    while not finished loop
      clk <= '0'; wait for 5 ns; clk <= '1'; wait for 5 ns;
    end loop;
    wait;
  end process;

  -- =======================================================================
  -- DUT: the board-facing wrapper, through its NAMED ports
  -- =======================================================================
  u_ip : entity work.matvec_int4_ip
    generic map(BLK => BLK, ROWS_IF => RI, AXI_DW => AXI_DW, ADDR_W => ADDR_W,
                MAXCOLS => 512, MAXROWS_BFP => 64, FIFO_DEPTH => 64,
                MAXB => 16, MAXOUT => 2)
    port map(
      s_axi_aclk => clk, s_axi_aresetn => aresetn,
      s_axi_awaddr => awaddr, s_axi_awprot => "000",
      s_axi_awvalid => awvalid, s_axi_awready => d_awready,
      s_axi_wdata => wdata, s_axi_wstrb => wstrb,
      s_axi_wvalid => wvalid, s_axi_wready => d_wready,
      s_axi_bresp => d_bresp, s_axi_bvalid => d_bvalid, s_axi_bready => bready,
      s_axi_araddr => araddr_l, s_axi_arprot => "000",
      s_axi_arvalid => arvalid_l, s_axi_arready => d_arready_l,
      s_axi_rdata => d_rdata_l, s_axi_rresp => d_rresp,
      s_axi_rvalid => d_rvalid_l, s_axi_rready => rready_l,

      m00_axi_arvalid => d_arvalid(0), m00_axi_arready => d_arready(0),
      m00_axi_araddr  => d_araddr(0),  m00_axi_arlen   => d_arlen(0),
      m00_axi_arsize  => d_arsize(0),  m00_axi_arburst => d_arburst(0),
      m00_axi_arlock  => d_arlock(0),  m00_axi_arcache => d_arcache(0),
      m00_axi_arprot  => d_arprot(0),  m00_axi_arqos   => d_arqos(0),
      m00_axi_rvalid  => d_rvalid(0),  m00_axi_rready  => d_rready(0),
      m00_axi_rdata   => d_rdata(0),   m00_axi_rresp   => "00",
      m00_axi_rlast   => d_rlast(0),

      m01_axi_arvalid => d_arvalid(1), m01_axi_arready => d_arready(1),
      m01_axi_araddr  => d_araddr(1),  m01_axi_arlen   => d_arlen(1),
      m01_axi_arsize  => d_arsize(1),  m01_axi_arburst => d_arburst(1),
      m01_axi_arlock  => d_arlock(1),  m01_axi_arcache => d_arcache(1),
      m01_axi_arprot  => d_arprot(1),  m01_axi_arqos   => d_arqos(1),
      m01_axi_rvalid  => d_rvalid(1),  m01_axi_rready  => d_rready(1),
      m01_axi_rdata   => d_rdata(1),   m01_axi_rresp   => "00",
      m01_axi_rlast   => d_rlast(1),

      m02_axi_arvalid => d_arvalid(2), m02_axi_arready => d_arready(2),
      m02_axi_araddr  => d_araddr(2),  m02_axi_arlen   => d_arlen(2),
      m02_axi_arsize  => d_arsize(2),  m02_axi_arburst => d_arburst(2),
      m02_axi_arlock  => d_arlock(2),  m02_axi_arcache => d_arcache(2),
      m02_axi_arprot  => d_arprot(2),  m02_axi_arqos   => d_arqos(2),
      m02_axi_rvalid  => d_rvalid(2),  m02_axi_rready  => d_rready(2),
      m02_axi_rdata   => d_rdata(2),   m02_axi_rresp   => "00",
      m02_axi_rlast   => d_rlast(2),

      m03_axi_arvalid => d_arvalid(3), m03_axi_arready => d_arready(3),
      m03_axi_araddr  => d_araddr(3),  m03_axi_arlen   => d_arlen(3),
      m03_axi_arsize  => d_arsize(3),  m03_axi_arburst => d_arburst(3),
      m03_axi_arlock  => d_arlock(3),  m03_axi_arcache => d_arcache(3),
      m03_axi_arprot  => d_arprot(3),  m03_axi_arqos   => d_arqos(3),
      m03_axi_rvalid  => d_rvalid(3),  m03_axi_rready  => d_rready(3),
      m03_axi_rdata   => d_rdata(3),   m03_axi_rresp   => "00",
      m03_axi_rlast   => d_rlast(3),

      m04_axi_arvalid => d_arvalid(4), m04_axi_arready => d_arready(4),
      m04_axi_araddr  => d_araddr(4),  m04_axi_arlen   => d_arlen(4),
      m04_axi_arsize  => d_arsize(4),  m04_axi_arburst => d_arburst(4),
      m04_axi_arlock  => d_arlock(4),  m04_axi_arcache => d_arcache(4),
      m04_axi_arprot  => d_arprot(4),  m04_axi_arqos   => d_arqos(4),
      m04_axi_rvalid  => d_rvalid(4),  m04_axi_rready  => d_rready(4),
      m04_axi_rdata   => d_rdata(4),   m04_axi_rresp   => "00",
      m04_axi_rlast   => d_rlast(4));

  -- =======================================================================
  -- REF: the same core, flattened, as tb_matvec_axi drives it
  -- =======================================================================
  u_ref : entity work.matvec_int4_axi
    generic map(BLK => BLK, ROWS_IF => RI, NPORTS_W => NP, AXI_DW => AXI_DW,
                ADDR_W => ADDR_W, MAXCOLS => 512, MAXROWS_BFP => 64,
                FIFO_DEPTH => 64, MAXB => 16, MAXOUT => 2,
                C_S_AXI_ADDR_WIDTH => 8)
    port map(
      s_axi_aclk => clk, s_axi_aresetn => aresetn,
      s_axi_awaddr => awaddr, s_axi_awprot => "000",
      s_axi_awvalid => awvalid, s_axi_awready => r_awready,
      s_axi_wdata => wdata, s_axi_wstrb => wstrb,
      s_axi_wvalid => wvalid, s_axi_wready => r_wready,
      s_axi_bresp => r_bresp, s_axi_bvalid => r_bvalid, s_axi_bready => bready,
      s_axi_araddr => araddr_l, s_axi_arprot => "000",
      s_axi_arvalid => arvalid_l, s_axi_arready => r_arready_l,
      s_axi_rdata => r_rdata_l, s_axi_rresp => r_rresp,
      s_axi_rvalid => r_rvalid_l, s_axi_rready => rready_l,
      m_arvalid => r_arvalid, m_arready => r_arready,
      m_araddr => r_araddr, m_arlen => r_arlen,
      m_arsize => r_arsize, m_arburst => r_arburst,
      m_rvalid => r_rvalid, m_rready => r_rready,
      m_rdata => r_rdata, m_rlast => r_rlast);

  -- =======================================================================
  -- Five AXI4 read slaves.  ONE model per lane, driving BOTH instances with
  -- identical values.  If the wrapper mis-wires a lane, the DUT's core sees
  -- data meant for another lane and its AR stream diverges from the REF's,
  -- which the comparator below catches.
  -- =======================================================================
  slaves : for p in 0 to NP generate
    slv : process
      variable a : unsigned(ADDR_W-1 downto 0);
      variable n : integer;
      procedure tick is begin wait until rising_edge(clk); end procedure;
    begin
      r_arready(p) <= '0'; r_rvalid(p) <= '0'; r_rlast(p) <= '0';
      d_arready(p) <= '0'; d_rvalid(p) <= '0'; d_rlast(p) <= '0';
      wait until aresetn = '1';
      loop
        r_arready(p) <= '0'; d_arready(p) <= '0';
        while r_arvalid(p) = '0' loop
          tick;
          exit when not running;
        end loop;
        exit when not running;

        a := unsigned(r_araddr((p+1)*ADDR_W-1 downto p*ADDR_W));
        n := to_integer(unsigned(r_arlen((p+1)*8-1 downto p*8))) + 1;

        -- ORDER CHECK, independent of the REF comparison: lane p must only
        -- ever be handed sub-region p's base nibble.  A wrapper and a core
        -- that were wrong the same way would still be caught here.
        assert a(ADDR_W-1 downto ADDR_W-4) = to_unsigned(p + 1, 4)
          report "tb_matvec_int4_ip: master " & integer'image(p)
               & " fetched from nibble "
               & integer'image(to_integer(a(ADDR_W-1 downto ADDR_W-4)))
               & ", expected " & integer'image(p + 1)
               & " -- the sub-region to master mapping is wrong"
          severity failure;

        ar_seen(p) <= ar_seen(p) + 1;
        r_arready(p) <= '1'; d_arready(p) <= '1';
        tick;
        r_arready(p) <= '0'; d_arready(p) <= '0';

        for i in 0 to n-1 loop
          r_rdata((p+1)*AXI_DW-1 downto p*AXI_DW) <= beat_of(p, a);
          d_rdata(p) <= beat_of(p, a);
          r_rvalid(p) <= '1'; d_rvalid(p) <= '1';
          if i = n-1 then
            r_rlast(p) <= '1'; d_rlast(p) <= '1';
          else
            r_rlast(p) <= '0'; d_rlast(p) <= '0';
          end if;
          loop
            tick;
            exit when r_rready(p) = '1' or not running;
          end loop;
          exit when not running;
          a := a + AXI_DW/8;
        end loop;
        r_rvalid(p) <= '0'; d_rvalid(p) <= '0';
        r_rlast(p) <= '0';  d_rlast(p) <= '0';
      end loop;
      wait;
    end process;
  end generate;

  -- =======================================================================
  -- The comparator.  This is the actual test: the wrapper is a bijection.
  -- =======================================================================
  cmp : process(clk)
    procedure bad(msg : string) is
    begin
      nbad <= nbad + 1;
      report "tb_matvec_int4_ip: MISMATCH " & msg severity error;
    end procedure;
  begin
    if rising_edge(clk) and aresetn = '1' and running then
      nchk <= nchk + 1;

      -- AXI-Lite slave side must be identical: the wrapper passes it straight
      -- through, so any difference is a wiring error on the control path.
      if d_awready /= r_awready then bad("s_axi_awready"); end if;
      if d_wready  /= r_wready  then bad("s_axi_wready");  end if;
      if d_bvalid  /= r_bvalid  then bad("s_axi_bvalid");  end if;
      if d_bresp   /= r_bresp   then bad("s_axi_bresp");   end if;
      if d_arready_l /= r_arready_l then bad("s_axi_arready"); end if;
      if d_rvalid_l  /= r_rvalid_l  then bad("s_axi_rvalid");  end if;
      if d_rresp     /= r_rresp     then bad("s_axi_rresp");   end if;
      if d_rvalid_l = '1' and d_rdata_l /= r_rdata_l then
        bad("s_axi_rdata");
      end if;

      for p in 0 to NP loop
        if d_arvalid(p) /= r_arvalid(p) then
          bad("m" & integer'image(p) & " arvalid");
        end if;
        if d_rready(p) /= r_rready(p) then
          bad("m" & integer'image(p) & " rready");
        end if;
        -- Address and burst attributes are only meaningful while arvalid.
        if r_arvalid(p) = '1' then
          if d_araddr(p) /= r_araddr((p+1)*ADDR_W-1 downto p*ADDR_W) then
            bad("m" & integer'image(p) & " araddr slice");
          end if;
          if d_arlen(p) /= r_arlen((p+1)*8-1 downto p*8) then
            bad("m" & integer'image(p) & " arlen slice");
          end if;
          if d_arsize(p) /= r_arsize((p+1)*3-1 downto p*3) then
            bad("m" & integer'image(p) & " arsize slice");
          end if;
          if d_arburst(p) /= r_arburst((p+1)*2-1 downto p*2) then
            bad("m" & integer'image(p) & " arburst slice");
          end if;
        end if;
        -- The ORDER claim, made on the WRAPPER's own port rather than on the
        -- REF's bus: whatever master k presents must carry sub-region k's
        -- nibble.  Independent of the differential check above, so a wrapper
        -- and a core that were wrong in the same way are still caught, and a
        -- mis-slice is caught twice rather than once.
        if d_arvalid(p) = '1' and
           unsigned(d_araddr(p)(ADDR_W-1 downto ADDR_W-4)) /=
             to_unsigned(p + 1, 4) then
          bad("m" & integer'image(p) & " fetched nibble " &
              integer'image(to_integer(unsigned(
                d_araddr(p)(ADDR_W-1 downto ADDR_W-4)))) &
              ", expected " & integer'image(p + 1) &
              " -- sub-region to master mapping");
        end if;
        -- The tie-offs exist ONLY in the wrapper, so nothing else can check
        -- them.  arcache = "0011" is normal, non-cacheable, bufferable, which
        -- is what makes the HP ports stream rather than serialise.
        if d_arlock(p)  /= '0'    then bad("m" & integer'image(p) & " arlock tie-off");  end if;
        if d_arcache(p) /= "0011" then bad("m" & integer'image(p) & " arcache tie-off"); end if;
        if d_arprot(p)  /= "000"  then bad("m" & integer'image(p) & " arprot tie-off");  end if;
        if d_arqos(p)   /= "0000" then bad("m" & integer'image(p) & " arqos tie-off");   end if;
      end loop;
    end if;
  end process;

  hb : process
  begin
    if HEARTBEAT_US = 0 then wait; end if;
    loop
      wait for HEARTBEAT_US * 1 us;
      exit when not running;
      report "tb_matvec_int4_ip: heartbeat, AR bursts per master "
           & integer'image(ar_seen(0)) & "/" & integer'image(ar_seen(1)) & "/"
           & integer'image(ar_seen(2)) & "/" & integer'image(ar_seen(3)) & "/"
           & integer'image(ar_seen(4)) & ", " & integer'image(nchk)
           & " compare cycles, " & integer'image(nbad) & " mismatches"
        severity note;
    end loop;
    wait;
  end process;

  -- =======================================================================
  -- Stimulus: program a minimal descriptor and start.  No golden data is
  -- needed; the arithmetic is tb_matvec_core's and tb_matvec_int4's job.
  -- =======================================================================
  stim : process
    procedure tick is begin wait until rising_edge(clk); end procedure;

    procedure wr(a : integer; d : std_logic_vector(31 downto 0)) is
    begin
      awaddr  <= std_logic_vector(to_unsigned(a, 8));
      wdata   <= d;
      awvalid <= '1'; wvalid <= '1'; bready <= '1';
      loop
        tick;
        exit when r_awready = '1' and r_wready = '1';
      end loop;
      awvalid <= '0'; wvalid <= '0';
      loop
        tick;
        exit when r_bvalid = '1';
      end loop;
      bready <= '0';
      tick;
    end procedure;

    procedure wri(a : integer; v : integer) is
    begin
      wr(a, std_logic_vector(to_unsigned(v, 32)));
    end procedure;

    -- AR and R are checked in ONE loop, deliberately.  matvec_int4_axi raises
    -- `arready` and `rvalid` in the SAME cycle (rtl/matvec_int4_axi.vhd:420),
    -- and it drops `rvalid` the cycle after it sees `rready` high.  A reader
    -- that waits for arready, then ticks, then waits for rvalid, misses the
    -- beat entirely and hangs forever.  That is not hypothetical: it is what
    -- the first draft of this file did, and it deadlocked on the very first
    -- register read with no output at all.
    procedure rd(a : integer; v : out std_logic_vector(31 downto 0)) is
    begin
      araddr_l  <= std_logic_vector(to_unsigned(a, 8));
      arvalid_l <= '1'; rready_l <= '1';
      loop
        tick;
        if r_arready_l = '1' then arvalid_l <= '0'; end if;
        exit when r_rvalid_l = '1';
      end loop;
      v := r_rdata_l;
      arvalid_l <= '0';
      tick;
      rready_l <= '0';
    end procedure;

    variable st  : std_logic_vector(31 downto 0);
    variable cyc : integer := 0;
    variable idb : std_logic_vector(31 downto 0);
  begin
    wait until aresetn = '1';
    tick; tick;

    -- The ID register, first, as a check that the AXI-Lite path through the
    -- wrapper works at all before anything else is believed.
    rd(16#64#, idb);
    assert idb = x"4D563449"
      report "tb_matvec_int4_ip: ID register read back " &
             integer'image(to_integer(unsigned(idb))) &
             " through the wrapper, expected 0x4D563449 -- the AXI-Lite path " &
             "is not wired"
      severity failure;

    -- Sized so each master issues SEVERAL bursts rather than one.  A single
    -- burst per lane would still prove the slicing, but not that the address
    -- increment survives a burst boundary on every lane.
    wri(16#08#, 8);          -- N_ROWS
    wri(16#0C#, 256);        -- N_COLS, eight BLK=32 blocks
    wri(16#10#, 0);          -- OUT_SHIFT
    wri(16#14#, 0);          -- W_EXP
    wri(16#18#, 0);          -- X_EXP
    wri(16#1C#, 0);          -- OUT_MODE = BFP

    -- One recognisable nibble per sub-region.  See base_of / the slave's
    -- order check.
    wr(16#20#, std_logic_vector(resize(base_of(0), 32)));
    wr(16#24#, std_logic_vector(resize(base_of(1), 32)));
    wr(16#28#, std_logic_vector(resize(base_of(2), 32)));
    wr(16#2C#, std_logic_vector(resize(base_of(3), 32)));
    wri(16#30#, 64);         -- W_BEATS per sub-region
    wr(16#34#, std_logic_vector(resize(base_of(4), 32)));
    wri(16#38#, 16);         -- S_BEATS

    for i in 0 to 15 loop    -- codebook
      wri(16#3C#, i * 256 + (i * 7) mod 256);
    end loop;
    wri(16#40#, 0);          -- X_IDX
    for i in 0 to 255 loop   -- activations
      wri(16#44#, (i * 137) mod 65536);
    end loop;

    wri(16#00#, 1);          -- CTRL: START

    -- Run until done, or the backstop.
    loop
      rd(16#04#, st);
      exit when st(0) = '1';
      cyc := cyc + 1;
      exit when cyc > MAXPOLL;
    end loop;

    -- Let the last beats settle and the comparator see them.
    for i in 0 to 20 loop tick; end loop;
    running <= false;
    tick; tick;

    -- ---- the vacuous-pass guard ----------------------------------------
    for p in 0 to NP loop
      assert ar_seen(p) > 0
        report "tb_matvec_int4_ip: master " & integer'image(p)
             & " never issued a single AR burst, so its wiring was never "
             & "exercised.  A wiring test with no traffic is a vacuous pass."
        severity failure;
    end loop;

    assert nchk > 100
      report "tb_matvec_int4_ip: only " & integer'image(nchk)
           & " comparison cycles ran; the run did not get going"
      severity failure;

    if nbad = 0 then
      report "tb_matvec_int4_ip: PASS -- matvec_int4_ip is a bijection onto "
           & "matvec_int4_axi over " & integer'image(nchk)
           & " cycles: every m0k_axi_* port equals lane k of the flattened "
           & "bus in both directions, every tie-off holds (arlock 0, arcache "
           & "0011, arprot 000, arqos 0000), and each of the 5 masters "
           & "fetched only its own sub-region nibble ("
           & integer'image(ar_seen(0)) & "/" & integer'image(ar_seen(1)) & "/"
           & integer'image(ar_seen(2)) & "/" & integer'image(ar_seen(3)) & "/"
           & integer'image(ar_seen(4)) & " bursts)"
        severity note;
    else
      report "tb_matvec_int4_ip: FAIL -- " & integer'image(nbad)
           & " wiring mismatches between the named ports and the flattened bus"
        severity failure;
    end if;

    finished <= true;
    wait;
  end process;

end architecture;
