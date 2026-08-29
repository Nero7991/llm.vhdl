-- sim/tb_mv4i_desc_image.vhd -- serve a descriptor image FROM A FILE to
-- rtl/matvec_int4_desc_axi.vhd and report what its S_CHECK did with it.
--
-- WHY THIS EXISTS, AND WHY IT IS NOT sim/tb_matvec_fk33_desc.vhd.  That bench
-- is the arithmetic claim: it BUILDS a descriptor in VHDL from a trace and
-- proves the answer is bit-exact through the control plane.  Because it builds
-- the descriptor itself, it cannot judge bytes produced by a host tool -- and
-- a host tool checked only by its own decoder proves nothing (this project has
-- the m7 mutant on record for exactly that).
--
-- So this bench does the one thing that bench cannot: it takes an image
-- written by tools/gen_mv4i_desc.py, byte for byte, and lets the REAL RTL be
-- the judge of it.  It answers "does the gateware accept these bytes, and if
-- not, with which error code", which is precisely the question a generator's
-- teeth check has to ask.
--
-- WHAT IT DELIBERATELY DOES NOT DO.  It does not check arithmetic.  The 27
-- weight/scale slaves never assert arready, so a descriptor that is ACCEPTED
-- makes the core issue its first read and stall there forever.  That is the
-- accept signal: the first m_arvalid is proof that S_CHECK passed and `start`
-- was pulsed, which is the whole observable this bench is after.  The bit-exact
-- result stays sim/tb_matvec_fk33_desc's claim, and this bench does not
-- weaken or duplicate it.
--
--   ghdl -r --workdir=W tb_mv4i_desc_image -gDESC=desc.hex -gEXPECT=-1
--
-- DESC is one 64-bit word per line, most significant nibble first, '#'
-- comments and blank lines skipped -- the form tools/gen_mv4i_desc.py --hex
-- emits.  EXPECT is -1 for "must be accepted" or an err_code (0..15) for
-- "must be refused with this code".  EXPECT_INFO, when >= 0, additionally
-- pins ERR_INFO, which is what distinguishes "refused for the right reason"
-- from "refused for some reason".
--
-- THE DEFAULT VECTOR IS COMMITTED, AND ITS EXTENSION IS LOAD BEARING.
-- sim/mv4i_desc_image.txt is a real descriptor for a real tensor, emitted by
-- tools/gen_mv4i_desc.py.  It is committed and named `.txt` because
-- sim/regress.sh symlinks every sim/*.txt into a test's run directory, so the
-- unfiltered gate picks this bench up and runs it with no row in that script
-- and no dependency on the 4.7 GiB model set, which is not in git.
--
-- What a committed golden does and does not prove.  It proves the gateware
-- accepts a descriptor a host tool actually wrote, which is the only claim
-- made here.  It does NOT re-verify the generator: if gen_mv4i_desc.py
-- regressed tomorrow this file would not move and this bench would keep
-- passing.  Checking the generator is tools/verify_mv4i_desc.py's job, against
-- ref/mv_fk33_tr and tools/mv4i_desc_ref.c.  Staleness of the GEOMETRY is
-- caught, though: the word count and CAPS are asserted against the build
-- below, so a build that moves ROWS_IF or AXI_DW fails loudly here.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.util_pkg.all;
use work.matvec_int4_desc_pkg.all;

entity tb_mv4i_desc_image is
  generic(
    DESC        : string   := "mv4i_desc_image.txt";
    -- -1 = must be accepted (the core starts); 0..15 = must be refused with
    -- this err_code.
    EXPECT      : integer  := -1;
    -- -1 = do not check ERR_INFO.
    EXPECT_INFO : integer  := -1;
    -- The FK33 build.  Same numbers as rtl/matvec_int4_desc_axi.vhd's own
    -- generic defaults, so this bench talks to the build the card will carry
    -- rather than to a shrunken one.
    RI          : positive := 48;
    NPW         : positive := 24;
    NPS         : positive := 3;
    AXI_DW      : positive := 256;
    BLK         : positive := 32;
    ADDR_W      : positive := 40;
    MAXCOLS     : positive := 17408;
    MAXROWS_BFP : positive := 17408;
    -- Where the descriptor sits.  Must be a multiple of DESC_MAXB*AXI_DW/8 =
    -- 512, or the design raises ERR_ALIGN on the pointer -- which is itself a
    -- case worth running, so it is a generic and not a constant.
    DESC_ADDR   : natural  := 16#300000#;
    -- The high 32 bits of the pointer, programmed into DESC_PTR_HI.  A
    -- separate generic because a VHDL `natural` cannot hold a 40-bit address,
    -- and because a bit at or above ADDR_W here is latched AT WRITE TIME,
    -- which is a distinct check from every other one in this bench.
    DESC_ADDR_HI : natural := 0
  );
end entity;

architecture sim of tb_mv4i_desc_image is
  constant NP_ALL : positive := NPW + NPS;
  constant PORT_B : positive := AXI_DW / 8;
  constant WPB    : positive := AXI_DW / 64;
  constant DWORDS : positive := desc_words(NPW, NPS);
  constant DBEATS : positive := desc_beats(NPW, NPS, AXI_DW);
  constant EXT0   : natural  := desc_ext0(NPW, NPS);

  signal clk      : std_logic := '0';
  signal aresetn  : std_logic := '0';
  signal finished : boolean   := false;

  -- AXI-Lite
  signal awaddr, araddr_l : std_logic_vector(7 downto 0) := (others => '0');
  signal wdata, rdata_l   : std_logic_vector(31 downto 0) := (others => '0');
  signal wstrb  : std_logic_vector(3 downto 0) := "1111";
  signal awvalid, awready, wvalid, wready, bvalid, bready : std_logic := '0';
  signal arvalid_l, arready_l, rvalid_l, rready_l : std_logic := '0';
  signal bresp, rresp : std_logic_vector(1 downto 0);

  -- descriptor master
  signal d_arvalid, d_arready, d_rvalid, d_rready, d_rlast : std_logic := '0';
  signal d_araddr  : std_logic_vector(ADDR_W-1 downto 0);
  signal d_arlen   : std_logic_vector(7 downto 0);
  signal d_arsize  : std_logic_vector(2 downto 0);
  signal d_arburst : std_logic_vector(1 downto 0);
  signal d_rdata   : std_logic_vector(AXI_DW-1 downto 0) := (others => '0');

  -- weight/scale masters.  Never answered: see the header.
  signal m_arvalid, m_arready, m_rvalid, m_rready, m_rlast :
    std_logic_vector(NP_ALL-1 downto 0) := (others => '0');
  signal m_araddr  : std_logic_vector(NP_ALL*ADDR_W-1 downto 0);
  signal m_arlen   : std_logic_vector(NP_ALL*8-1 downto 0);
  signal m_arsize  : std_logic_vector(NP_ALL*3-1 downto 0);
  signal m_arburst : std_logic_vector(NP_ALL*2-1 downto 0);
  signal m_rdata   : std_logic_vector(NP_ALL*AXI_DW-1 downto 0)
                     := (others => '0');

  signal y_we    : std_logic;
  signal y_addr  : std_logic_vector(15 downto 0);
  signal y_data  : std_logic_vector(RI*64-1 downto 0);
  signal y_mask  : std_logic_vector(RI-1 downto 0);
  signal y_exp_o : std_logic_vector(31 downto 0);
  signal job_done, job_err : std_logic;

  -- the image, as loaded
  type dword_arr is array(0 to DWORDS-1) of std_logic_vector(63 downto 0);
  signal dimg   : dword_arr := (others => (others => '0'));
  signal loaded : boolean := false;
  signal nword  : integer := 0;

  -- "the core was started", latched off the first weight-side AR
  signal started : std_logic := '0';
begin
  ck : process
  begin
    while not finished loop
      clk <= '0'; wait for 5 ns;
      clk <= '1'; wait for 5 ns;
    end loop;
    wait;
  end process;

  -- =====================================================================
  -- Load the image.  A word count that disagrees with what this build
  -- expects is a REFUSAL, not a truncation: a generator that disagrees with
  -- the gateware about DESC_WORDS disagrees about where the extension is, and
  -- padding it out here would hide exactly that.
  -- =====================================================================
  ld : process
    file     tf : text open read_mode is DESC;
    variable l  : line;
    variable c  : character;
    variable good : boolean;
    variable h  : std_logic_vector(63 downto 0);
    variable n  : integer := 0;
  begin
    while not endfile(tf) loop
      readline(tf, l);
      if l'length = 0 then next; end if;
      -- peek without consuming: a '#' line is a comment
      c := l(l'left);
      if c = '#' then next; end if;
      hread(l, h, good);
      exit when not good;
      assert n < DWORDS
        report "descriptor image has MORE than the " & integer'image(DWORDS) &
               " words this build expects" severity failure;
      dimg(n) <= h;
      n := n + 1;
    end loop;
    assert n = DWORDS
      report "descriptor image has " & integer'image(n) & " words, this " &
             "build expects " & integer'image(DWORDS) severity failure;
    nword <= n;
    wait for 1 ns;
    loaded <= true;
    wait;
  end process;

  -- =====================================================================
  -- The descriptor slave.  Serves DBEATS beats from DESC_ADDR.
  -- =====================================================================
  dslv : process
    variable a : unsigned(ADDR_W-1 downto 0);
    variable n, idx : integer;
    variable b : std_logic_vector(AXI_DW-1 downto 0);
  begin
    d_arready <= '0'; d_rvalid <= '0'; d_rlast <= '0';
    wait until aresetn = '1';
    loop
      d_arready <= '0';
      while d_arvalid = '0' loop wait until rising_edge(clk); end loop;
      a := unsigned(d_araddr);
      n := to_integer(unsigned(d_arlen)) + 1;
      assert d_arburst = "01"
        report "descriptor burst IS NOT INCR" severity failure;
      -- The pointer is programmed, so the design must ask inside the block it
      -- was pointed at.  A fetch that walked elsewhere would otherwise be
      -- served silently.
      assert a >= to_unsigned(DESC_ADDR, ADDR_W)
        report "descriptor fetch below DESC_ADDR" severity failure;
      idx := (to_integer(a) - DESC_ADDR) / PORT_B;
      assert idx + n <= DBEATS
        report "descriptor fetch of " & integer'image(n) & " from beat " &
               integer'image(idx) & " runs past the " & integer'image(DBEATS) &
               " beats the descriptor occupies" severity failure;
      d_arready <= '1'; wait until rising_edge(clk); d_arready <= '0';
      for i in 0 to n-1 loop
        b := (others => '0');
        for j in 0 to WPB-1 loop
          if (idx + i) * WPB + j < DWORDS then
            b((j+1)*64-1 downto j*64) := dimg((idx + i) * WPB + j);
          end if;
        end loop;
        d_rdata  <= b;
        d_rvalid <= '1';
        if i = n-1 then d_rlast <= '1'; else d_rlast <= '0'; end if;
        loop
          wait until rising_edge(clk);
          exit when d_rready = '1';
        end loop;
      end loop;
      d_rvalid <= '0'; d_rlast <= '0';
    end loop;
  end process;

  -- The accept signal: the first weight-side address request can only happen
  -- after S_CHECK passed and `start` was pulsed.
  watch : process(clk)
  begin
    if rising_edge(clk) then
      if aresetn = '0' then
        started <= '0';
      elsif m_arvalid /= (m_arvalid'range => '0') then
        started <= '1';
      end if;
    end if;
  end process;

  dut : entity work.matvec_int4_desc_axi
    generic map(BLK => BLK, ROWS_IF => RI, NPORTS_W => NPW, NPORTS_S => NPS,
                AXI_DW => AXI_DW, ADDR_W => ADDR_W, MAXCOLS => MAXCOLS,
                MAXROWS_BFP => MAXROWS_BFP)
    port map(
      s_axi_aclk => clk, s_axi_aresetn => aresetn, m_aclk => clk,
      s_axi_awaddr => awaddr, s_axi_awprot => "000", s_axi_awvalid => awvalid,
      s_axi_awready => awready, s_axi_wdata => wdata, s_axi_wstrb => wstrb,
      s_axi_wvalid => wvalid, s_axi_wready => wready, s_axi_bresp => bresp,
      s_axi_bvalid => bvalid, s_axi_bready => bready,
      s_axi_araddr => araddr_l, s_axi_arprot => "000",
      s_axi_arvalid => arvalid_l, s_axi_arready => arready_l,
      s_axi_rdata => rdata_l, s_axi_rresp => rresp, s_axi_rvalid => rvalid_l,
      s_axi_rready => rready_l,
      d_arvalid => d_arvalid, d_arready => d_arready, d_araddr => d_araddr,
      d_arlen => d_arlen, d_arsize => d_arsize, d_arburst => d_arburst,
      d_rvalid => d_rvalid, d_rready => d_rready, d_rdata => d_rdata,
      d_rlast => d_rlast,
      m_arvalid => m_arvalid, m_arready => m_arready, m_araddr => m_araddr,
      m_arlen => m_arlen, m_arsize => m_arsize, m_arburst => m_arburst,
      m_rvalid => m_rvalid, m_rready => m_rready, m_rdata => m_rdata,
      m_rlast => m_rlast,
      x_we => '0', x_waddr => (others => '0'), x_wdata => (others => '0'),
      x_exp_in => (others => '0'),
      y_we => y_we, y_addr => y_addr, y_data => y_data, y_mask => y_mask,
      y_exp_o => y_exp_o, job_done => job_done, job_err => job_err);

  drv : process
    variable rd  : std_logic_vector(31 downto 0);
    variable st  : std_logic_vector(31 downto 0);
    variable ec  : integer;
    variable ei  : integer;
    variable tmo : integer;
    variable verdict : integer;      -- -1 accepted, else the err_code
    variable info    : integer;

    procedure awr(addr : natural; d : std_logic_vector(31 downto 0)) is
    begin
      wait until rising_edge(clk);
      awaddr <= std_logic_vector(to_unsigned(addr, 8));
      wdata  <= d; awvalid <= '1'; wvalid <= '1'; bready <= '1';
      loop
        wait until rising_edge(clk);
        exit when awready = '1' and wready = '1';
      end loop;
      awvalid <= '0'; wvalid <= '0';
      loop
        wait until rising_edge(clk);
        exit when bvalid = '1';
      end loop;
      bready <= '0';
    end procedure;

    procedure ard(addr : natural; d : out std_logic_vector(31 downto 0)) is
    begin
      wait until rising_edge(clk);
      araddr_l <= std_logic_vector(to_unsigned(addr, 8));
      arvalid_l <= '1'; rready_l <= '1';
      loop
        wait until rising_edge(clk);
        exit when rvalid_l = '1';
      end loop;
      d := rdata_l;
      arvalid_l <= '0'; rready_l <= '0';
      wait until rising_edge(clk);
    end procedure;
  begin
    wait until loaded;
    report "loaded " & integer'image(nword) & " descriptor words from " & DESC
      severity note;

    aresetn <= '0';
    for i in 0 to 7 loop wait until rising_edge(clk); end loop;
    aresetn <= '1';
    wait until rising_edge(clk);

    -- The build this image claims to be for.  A generator that disagrees here
    -- has landed the extension somewhere else and every field after 0x40 is
    -- being read from the wrong offset, so this is checked BEFORE the run.
    ard(16#14#, rd);
    assert rd = MV4I_MAGIC report "ID register IS WRONG" severity failure;
    ard(16#1C#, rd);
    assert to_integer(unsigned(rd(7 downto 0)))   = NPW
       and to_integer(unsigned(rd(15 downto 8)))  = NPS
       and to_integer(unsigned(rd(23 downto 16))) = RI
       and to_integer(unsigned(rd(31 downto 24))) = AXI_DW/8
      report "CAPS IS WRONG" severity failure;
    ard(16#20#, rd);
    assert to_integer(unsigned(rd)) = DWORDS
      report "DESC_WORDS reports " & integer'image(to_integer(unsigned(rd))) &
             ", package says " & integer'image(DWORDS) severity failure;

    -- program the pointer and go
    awr(16#00#, std_logic_vector(to_unsigned(DESC_ADDR, 32)));
    awr(16#04#, std_logic_vector(to_unsigned(DESC_ADDR_HI, 32)));
    awr(16#08#, x"00000001");

    verdict := -2; info := -1;
    tmo := 0;
    while verdict = -2 and tmo < 200000 loop
      ard(16#0C#, st);
      if st(2) = '1' then
        verdict := to_integer(unsigned(st(11 downto 8)));
        ard(16#10#, rd);
        info := to_integer(unsigned(rd(15 downto 0)));
      elsif started = '1' then
        verdict := -1;
      end if;
      tmo := tmo + 1;
    end loop;

    if verdict = -2 then
      report "RESULT timeout: neither err nor a weight-side read in " &
             integer'image(tmo) & " status polls" severity note;
    elsif verdict = -1 then
      report "RESULT accept: S_CHECK passed and the core started" severity note;
    else
      report "RESULT reject: err_code 0x" &
             integer'image(verdict) & " err_info " & integer'image(info)
        severity note;
    end if;

    if verdict = EXPECT and (EXPECT_INFO < 0 or info = EXPECT_INFO) then
      report "PASS: descriptor image judged as expected (" &
             integer'image(verdict) & ")" severity note;
    else
      report "FAIL: expected " & integer'image(EXPECT) &
             " info " & integer'image(EXPECT_INFO) &
             ", got " & integer'image(verdict) &
             " info " & integer'image(info) severity failure;
    end if;

    finished <= true;
    wait;
  end process;
end architecture;
