-- sim/tb_matvec_axi.vhd -- subsystem A driven exactly as the PS will drive it.
--
-- This is the §10 step-5 sequence executed in simulation: program the
-- descriptor from the header fields, load the codebook, load the activation
-- vector, start, poll STATUS, read the results back and compare against
-- ref/matvec_int4.c.  It validates the register map and the driver sequence
-- before any hardware exists, and it is the specification the board-side C
-- driver should follow.
--
-- The weight path is served over real AXI4 from the packer's actual image, as
-- in sim/tb_matvec_int4, so this exercises the whole stack: AXI-Lite control,
-- AXI4 read masters, reassembly, datapath, result readback.
--
-- ADDRESS WIDTH (added 2026-08-27, audit item N5).  ADDR_W and BASE_HI mirror
-- sim/tb_matvec_int4, and this file additionally covers the three things that
-- only exist in the register map:
--
--   * the LO/HI register pair actually assembles a >4 GB base end to end,
--   * ADDR_CAP (reg 31) reports the width the build was synthesised with, so a
--     driver can discover it rather than assume it,
--   * ERR_ADDR (STATUS bit 4) latches when a HI word carries a bit this build
--     cannot reach.  That check runs LAST, after the results are compared,
--     because it deliberately programs a base the hardware must reject and
--     doing so earlier would poison the run it is meant to protect.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.util_pkg.all;

entity tb_matvec_axi is
  generic(TRACE : string := "../tr.txt"; RI : positive := 4; STALL : natural := 3;
          ADDR_W : positive := 64; BASE_HI : natural := 0);
end entity;

architecture sim of tb_matvec_axi is
  constant BLK    : positive := 32;
  constant AXI_DW : positive := 128;
  constant NP     : positive := RI;
  constant MAXW   : positive := 16384;
  constant MAXR   : positive := 64;
  constant MAXB   : positive := 16;

  signal clk : std_logic := '0';
  signal aresetn : std_logic := '0';

  signal awaddr, araddr : std_logic_vector(7 downto 0) := (others => '0');
  signal wdata, rdata   : std_logic_vector(31 downto 0) := (others => '0');
  signal wstrb : std_logic_vector(3 downto 0) := "1111";
  signal awvalid, awready, wvalid, wready, bvalid, bready : std_logic := '0';
  signal arvalid, arready, rvalid, rready : std_logic := '0';
  signal bresp, rresp : std_logic_vector(1 downto 0);

  signal m_arvalid, m_arready, m_rvalid, m_rready, m_rlast :
    std_logic_vector(NP downto 0) := (others => '0');
  signal m_araddr  : std_logic_vector((NP+1)*ADDR_W-1 downto 0);
  signal m_arlen   : std_logic_vector((NP+1)*8-1 downto 0);
  signal m_arsize  : std_logic_vector((NP+1)*3-1 downto 0);
  signal m_arburst : std_logic_vector((NP+1)*2-1 downto 0);
  signal m_rdata   : std_logic_vector((NP+1)*AXI_DW-1 downto 0) := (others => '0');

  type img_t is array(0 to MAXW-1) of std_logic_vector(AXI_DW-1 downto 0);
  signal img : img_t := (others => (others => '0'));
  type xm_t is array(0 to MAXB*BLK-1) of std_logic_vector(15 downto 0);
  signal xv : xm_t := (others => (others => '0'));
  type cb_t is array(0 to 15) of integer;
  signal cbv : cb_t := (others => 0);
  type row_t is array(0 to MAXR-1) of signed(63 downto 0);
  signal e_ymant : row_t := (others => (others => '0'));

  signal n_rows, n_cols, out_shift, w_exp, x_exp : integer := 0;
  signal wb0, wb1, wb2, wb3, sbase, wbeats, sbeats : integer := 0;
  signal e_yexp : integer := 0;
  signal loaded, finished : boolean := false;
  signal nbad, nchk : integer := 0;
begin
  aresetn <= '0', '1' after 40 ns;

  clkgen : process
  begin
    while not finished loop
      clk <= '0'; wait for 5 ns; clk <= '1'; wait for 5 ns;
    end loop;
    wait;
  end process;

  dut : entity work.matvec_int4_axi
    generic map(BLK => BLK, ROWS_IF => RI, NPORTS_W => NP, AXI_DW => AXI_DW,
                ADDR_W => ADDR_W, MAXCOLS => 512, MAXROWS_BFP => MAXR,
                FIFO_DEPTH => 64, MAXB => 16)
    port map(s_axi_aclk => clk, s_axi_aresetn => aresetn,
             s_axi_awaddr => awaddr, s_axi_awprot => "000",
             s_axi_awvalid => awvalid, s_axi_awready => awready,
             s_axi_wdata => wdata, s_axi_wstrb => wstrb,
             s_axi_wvalid => wvalid, s_axi_wready => wready,
             s_axi_bresp => bresp, s_axi_bvalid => bvalid, s_axi_bready => bready,
             s_axi_araddr => araddr, s_axi_arprot => "000",
             s_axi_arvalid => arvalid, s_axi_arready => arready,
             s_axi_rdata => rdata, s_axi_rresp => rresp,
             s_axi_rvalid => rvalid, s_axi_rready => rready,
             m_arvalid => m_arvalid, m_arready => m_arready,
             m_araddr => m_araddr, m_arlen => m_arlen,
             m_arsize => m_arsize, m_arburst => m_arburst,
             m_rvalid => m_rvalid, m_rready => m_rready,
             m_rdata => m_rdata, m_rlast => m_rlast);

  -- ------------------------------------------------- AXI4 slaves for weights
  slaves : for p in 0 to NP generate
    slv : process
      variable lf : unsigned(15 downto 0) := to_unsigned(4919 + p*277, 16);
      variable a  : unsigned(ADDR_W-1 downto 0);
      variable n  : integer;
      procedure tick is
      begin
        wait until rising_edge(clk);
        lf := lf(14 downto 0) & (lf(15) xor lf(13) xor lf(12) xor lf(10));
      end procedure;
    begin
      m_arready(p) <= '0'; m_rvalid(p) <= '0'; m_rlast(p) <= '0';
      wait until aresetn = '1';
      loop
        m_arready(p) <= '0';
        while m_arvalid(p) = '0' loop tick; end loop;
        if STALL > 1 then
          while (to_integer(lf) mod STALL) = 0 loop tick; end loop;
        end if;
        a := unsigned(m_araddr((p+1)*ADDR_W-1 downto p*ADDR_W));
        n := to_integer(unsigned(m_arlen((p+1)*8-1 downto p*8))) + 1;
        -- see sim/tb_matvec_int4: truncation is invisible without this, because
        -- the image is served modulo MAXW and a wrapped base reads right.
        assert to_integer(shift_right(a, 32)) = BASE_HI
          report "port " & integer'image(p) & ": address high half is " &
                 integer'image(to_integer(shift_right(a, 32))) &
                 ", expected " & integer'image(BASE_HI) &
                 " -- the base was truncated (ADDR_W=" &
                 integer'image(ADDR_W) & ")"
          severity failure;
        m_arready(p) <= '1'; tick; m_arready(p) <= '0';
        for i in 0 to n-1 loop
          if STALL > 1 then
            m_rvalid(p) <= '0';
            while (to_integer(lf) mod STALL) = 0 loop tick; end loop;
          end if;
          m_rdata((p+1)*AXI_DW-1 downto p*AXI_DW)
            <= img(to_integer(a(clog2(MAXW) + 3 downto 4)));
          m_rvalid(p) <= '1';
          if i = n-1 then m_rlast(p) <= '1'; else m_rlast(p) <= '0'; end if;
          loop
            tick;
            exit when m_rready(p) = '1';
          end loop;
          a := a + 16;
        end loop;
        m_rvalid(p) <= '0'; m_rlast(p) <= '0';
      end loop;
    end process;
  end generate;

  -- ---------------------------------------------------------------- loader
  load : process
    file     tf : text open read_mode is TRACE;
    variable l  : line;
    variable tok : string(1 to 10);
    variable c  : character;
    variable slen, a, b, v : integer;
    variable h16 : std_logic_vector(15 downto 0);
    variable hv  : std_logic_vector(63 downto 0);
    variable h128 : std_logic_vector(AXI_DW-1 downto 0);
    variable good : boolean;
    variable M, K, NB, osh, wev, xev, R : integer;
  begin
    wait until aresetn = '1';
    while not endfile(tf) loop
      readline(tf, l);
      if l'length = 0 then next; end if;
      read(l, c, good);
      if not good or c = '#' then next; end if;
      tok := (others => ' '); slen := 1; tok(1) := c;
      loop
        read(l, c, good);
        exit when not good or c = ' ';
        slen := slen + 1; tok(slen) := c;
      end loop;

      if tok(1 to 4) = "DIMS" then
        read(l, M); read(l, K); read(l, NB); read(l, osh);
        read(l, wev); read(l, xev); read(l, R);
        assert R = RI report "trace ROWS_IF mismatch" severity failure;
        n_rows <= M; n_cols <= K;
        out_shift <= osh; w_exp <= wev; x_exp <= xev;
      elsif tok(1 to 2) = "CB" then
        read(l, a); read(l, v); cbv(a) <= v;
      elsif tok(1 to 1) = "X" then
        read(l, a); hread(l, h16); xv(a) <= h16;
      elsif tok(1 to 5) = "WBASE" then
        read(l, a); read(l, v);
        case a is
          when 0 => wb0 <= v; when 1 => wb1 <= v;
          when 2 => wb2 <= v; when others => wb3 <= v;
        end case;
      elsif tok(1 to 5) = "SBASE"  then read(l, v); sbase  <= v;
      elsif tok(1 to 6) = "WBEATS" then read(l, v); wbeats <= v;
      elsif tok(1 to 6) = "SBEATS" then read(l, v); sbeats <= v;
      elsif tok(1 to 4) = "IMG "   then
        read(l, a); hread(l, h128); img(a) <= h128;
      elsif tok(1 to 5) = "YMANT"  then
        read(l, a); hread(l, hv); e_ymant(a) <= signed(hv);
      elsif tok(1 to 4) = "YEXP"   then read(l, a); e_yexp <= a;
      end if;
      wait for 0 ns;
    end loop;
    loaded <= true;
    wait;
  end process;

  -- ------------------------------------------------------- the PS, in VHDL
  ps : process
    variable d  : std_logic_vector(31 downto 0);
    variable nb, nc, got, want : integer;

    procedure wr(constant reg : integer; constant val : integer) is
    begin
      awaddr  <= std_logic_vector(to_unsigned(reg * 4, 8));
      wdata   <= std_logic_vector(to_signed(val, 32));
      awvalid <= '1'; wvalid <= '1';
      loop
        wait until rising_edge(clk);
        exit when awready = '1' and wready = '1';
      end loop;
      awvalid <= '0'; wvalid <= '0'; bready <= '1';
      loop
        wait until rising_edge(clk);
        exit when bvalid = '1';
      end loop;
      bready <= '0';
    end procedure;

    procedure rd(constant reg : integer; variable val : out std_logic_vector(31 downto 0)) is
    begin
      araddr  <= std_logic_vector(to_unsigned(reg * 4, 8));
      arvalid <= '1'; rready <= '1';
      loop
        wait until rising_edge(clk);
        exit when rvalid = '1';
      end loop;
      val := rdata;
      arvalid <= '0'; rready <= '0';
      wait until rising_edge(clk);
    end procedure;
  begin
    wait until loaded;
    wait until rising_edge(clk);

    rd(25, d);
    assert d = x"4D563449"
      report "ID register reads " & to_hstring(d) & ", expected 4D563449"
      severity failure;

    -- ADDR_CAP.  A driver reads the width instead of assuming it, and refuses
    -- a base it can see will not fit rather than letting the hardware take it.
    rd(31, d);
    assert to_integer(unsigned(d)) = ADDR_W
      report "ADDR_CAP reads " & integer'image(to_integer(unsigned(d))) &
             ", expected " & integer'image(ADDR_W)
      severity failure;
    assert BASE_HI = 0 or ADDR_W > 32
      report "BASE_HI /= 0 needs ADDR_W > 32; this build reports " &
             integer'image(to_integer(unsigned(d)))
      severity note;

    -- descriptor, exactly the fields the PS takes from the 4 KB header
    wr(2, n_rows); wr(3, n_cols); wr(4, out_shift);
    wr(5, w_exp);  wr(6, x_exp);  wr(7, 0);            -- BFP
    wr(8, wb0); wr(9, wb1); wr(10, wb2); wr(11, wb3);
    wr(12, wbeats); wr(13, sbase); wr(14, sbeats);
    -- HIGH halves.  Zero is the historical case and costs five writes; a
    -- driver that omits them entirely still works, because they reset to 0.
    wr(26, BASE_HI); wr(27, BASE_HI); wr(28, BASE_HI); wr(29, BASE_HI);
    wr(30, BASE_HI);
    -- and they must read back, or the LO/HI pair is write-only in one half
    rd(26, d);
    assert to_integer(unsigned(d)) = BASE_HI
      report "W_BASE0_HI reads " & to_hstring(d) severity failure;
    rd(30, d);
    assert to_integer(unsigned(d)) = BASE_HI
      report "S_BASE_HI reads " & to_hstring(d) severity failure;
    -- programming a base must not have latched ERR_ADDR
    rd(1, d);
    assert d(4) = '0'
      report "ERR_ADDR latched on a base this build can represent" severity failure;

    for i in 0 to 15 loop                              -- codebook
      wr(15, i * 256 + (cbv(i) mod 256));
    end loop;

    wr(16, 0);                                         -- X_IDX = 0
    for k in 0 to n_cols-1 loop                        -- auto-increments
      wr(17, to_integer(signed(xv(k))));
    end loop;

    wr(0, 1);                                          -- START
    loop
      rd(1, d);
      exit when d(0) = '1';
    end loop;
    assert d(2) = '0' report "err asserted" severity failure;

    rd(21, d);
    assert to_integer(signed(d)) = e_yexp
      report "Y_EXP got " & integer'image(to_integer(signed(d))) &
             " want " & integer'image(e_yexp) severity error;

    nb := 0; nc := 0;
    for r in 0 to n_rows-1 loop
      wr(18, r);                                       -- Y_IDX
      rd(19, d);                                       -- Y_LO
      got  := to_integer(resize(signed(d(15 downto 0)), 32));
      want := to_integer(resize(e_ymant(r), 32));
      nc := nc + 1;
      if got /= want then
        nb := nb + 1;
        if nb < 6 then
          report "AXI READBACK MISMATCH r=" & integer'image(r) &
                 " got "  & integer'image(got) &
                 " want " & integer'image(want) severity error;
        end if;
      end if;
    end loop;
    nchk <= nc; nbad <= nb;

    rd(22, d); report "CYCLES  = " & integer'image(to_integer(unsigned(d))) severity note;
    rd(23, d); report "BEATS   = " & integer'image(to_integer(unsigned(d))) severity note;
    rd(24, d); report "STARVED = " & integer'image(to_integer(unsigned(d))) severity note;

    wait until rising_edge(clk);
    report "AXI: " & integer'image(nchk) & " rows read back, " &
           integer'image(nbad) & " mismatches" severity note;
    assert nbad = 0 and nchk = n_rows
      report "THE AXI-LITE PATH DIVERGES FROM THE C REFERENCE" severity failure;
    report "subsystem A matches the C reference through the AXI-Lite register map"
      severity note;

    -- ---------------------------------------------- ERR_ADDR, deliberately
    -- LAST, because it programs a base the hardware is supposed to reject.
    -- Writing 1 into a HIGH register sets absolute address bit 32, which fits
    -- iff ADDR_W > 32, so this is a TWO-SIDED check that runs at both widths:
    -- it must latch at 32 and must NOT latch at 64.  A one-sided version would
    -- pass on a build where ERR_ADDR was tied high.
    wr(26, 1);
    rd(1, d);
    if ADDR_W <= 32 then
      assert d(4) = '1'
        report "ERR_ADDR did NOT latch on a base past ADDR_W=" &
               integer'image(ADDR_W) & " -- the wrap is silent again"
        severity failure;
      report "ERR_ADDR correctly latched on a base past ADDR_W" severity note;
    else
      assert d(4) = '0'
        report "ERR_ADDR latched on a base that fits ADDR_W=" &
               integer'image(ADDR_W)
        severity failure;
      report "ERR_ADDR correctly silent on a base that fits" severity note;
    end if;

    finished <= true;
    wait;
  end process;
end architecture;
