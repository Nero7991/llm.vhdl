-- sim/tb_matvec_fk33.vhd -- subsystem A at the FK33 geometry, from a REAL
-- .mv4i file, checked bit-exactly against ref/matvec_int4.c.
--
-- WHAT WAS MISSING.  sim/tb_matvec_int4.vhd already drives the whole of
-- subsystem A from packed bytes, but only at the AXU3EG geometry: AXI_DW is a
-- CONSTANT 128 in that file, NPORTS_W is ROWS_IF, and there is exactly one
-- scale base.  The FK33 runs ROWS_IF=48 / AXI_DW=256, which spec 6.5a turns
-- into NPORTS_W=24 weight sub-regions plus n_scale_sub=3 scale sub-regions --
-- 27 AXI read masters.  Both prior notes state the gap in their own "open, not
-- yet answered" sections:
--
--   docs/debugging/2026-08-28_c-reference-general-axi-dw.md
--     "There is no DATA-level test of matvec_int4 at NPORTS_S = 3. [...]
--      sim/tb_matvec_int4.vhd is the vehicle and it is hardcoded to
--      AXI_DW = 128."
--   docs/debugging/2026-08-28_fk33-pack-layout-axi256.md
--     "rtl/matvec_int4.vhd is fixed at NPORTS_S = 1."   (since plumbed)
--
-- sim/tb_weight_streamer.vhd covers the REASSEMBLY at 48/256, but it stops at
-- the streamer's output: nothing carried those words into matvec_core, so the
-- lane-to-row mapping the ARRAY assumes was never checked against the lane
-- split the PACKER writes at this width.  That is the one seam this file adds.
--
-- WHERE THE BYTES COME FROM.  ref/mv_fk33_tr reads one of the 250 packed
-- tensors of the 9B model -- written by tools/pack_int4.py, hash-verified into
-- HBM by the weight path -- and dumps, per AXI port, the sub-region beats that
-- port will actually read, verbatim, at the byte offsets the file's own 4 KB
-- header names.  Nothing here re-derives the 6.5a layout: a testbench that
-- rebuilt the bytes from the rule would agree with a wrong rule just as
-- happily.  The EXPECTED result in the same trace comes from mv4i_matvec(),
-- which reaches those same bytes through get_widx()/get_scale() -- a different
-- code path from the raw dump.  Two implementations, one file, compared at the
-- output.  That is the double oracle; a round trip would not be one.
--
-- ONE ARRAY PER PORT, NOT A FLAT IMAGE.  The tensor is 2.4 MB and its
-- sub-regions are 4 KB-aligned megabytes apart, so a flat address-indexed
-- memory would be almost all padding.  Each master reads ONE contiguous
-- sub-region, so a per-port array is both smaller and a stronger check: the
-- slave asserts that port p addressed ITS OWN region at the expected beat,
-- which a flat memory would silently serve.
--
-- ADDRESS WIDTH.  ADDR_W=64 with BASE_HI in units of 4 GB, the same
-- construction sim/tb_matvec_int4.vhd uses and for the same reason: the FK33
-- has 8 GB of HBM, a base above 4 GB cannot be built through a VHDL integer,
-- and with the image served per port a truncated base would otherwise read
-- exactly the right bytes.  The slave therefore CHECKS the high half; that
-- check is the test, not a nicety.
--
-- BIT-EXACT MEANS BIT-EXACT.  Every one of the n_rows result lanes is compared
-- as a full 64-bit vector against the reference's sign-extended int16
-- mantissa, plus y_exp, plus the sticky sat_event, plus the row count.  There
-- is no tolerance anywhere in this file.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.util_pkg.all;

entity tb_matvec_fk33 is
  generic(
    TRACE   : string   := "mv_fk33_tr.txt";
    -- FK33 geometry, spec 6.5a.  These are elaboration-time and the trace's
    -- GEOM line is asserted against them, so a trace built for another
    -- geometry fails loudly instead of being half-read.
    RI      : positive := 48;
    NPW     : positive := 24;
    NPS     : positive := 3;
    AXI_DW  : positive := 256;
    BLK     : positive := 32;
    -- Beats per sub-region the arrays are sized for.  n_rows=100 over
    -- K=4096 is 3 tiles x 128 blocks = 384.
    MAXBEAT : positive := 384;
    MAXROWS : positive := 192;
    MAXCOLS : positive := 4096;
    STALL   : natural  := 3;
    ADDR_W  : positive := 64;
    -- Units of 4 GB added to every sub-region base.  Non-zero is the FK33
    -- case and requires ADDR_W > 32; it FAILS loudly at 32.
    BASE_HI : natural  := 1
  );
end entity;

architecture sim of tb_matvec_fk33 is
  constant NP_ALL : positive := NPW + NPS;
  constant PORT_B : positive := AXI_DW / 8;          -- bytes per beat
  constant BSEL   : positive := clog2(MAXBEAT);
  constant LSB    : positive := clog2(PORT_B);       -- 5 at 256 bits
  -- AXI4 forbids a burst crossing 4 KB, so 128 beats is the cap at 256 bits.
  constant MAXB   : positive := 128;

  signal clk, rst : std_logic := '0';
  signal start    : std_logic := '0';

  signal n_rows, n_cols, out_shift, w_exp, x_exp : integer := 0;
  signal w_beats, s_beats : integer := 0;
  signal v_rows, v_cols, v_osh, v_wexp, v_xexp : std_logic_vector(31 downto 0);
  signal v_wbeats, v_sbeats, v_yexp            : std_logic_vector(31 downto 0);
  signal y_exp    : integer;
  signal out_mode : std_logic_vector(1 downto 0) := "00";

  signal cb_we   : std_logic := '0';
  signal cb_addr : std_logic_vector(3 downto 0) := (others => '0');
  signal cb_data : std_logic_vector(7 downto 0) := (others => '0');

  signal w_base : std_logic_vector(NPW*ADDR_W-1 downto 0) := (others => '0');
  signal s_base : std_logic_vector(NPS*ADDR_W-1 downto 0) := (others => '0');

  type addr_arr is array(0 to NP_ALL-1) of unsigned(ADDR_W-1 downto 0);
  signal pbase : addr_arr := (others => (others => '0'));

  signal x_we    : std_logic := '0';
  signal x_waddr : std_logic_vector(15 downto 0) := (others => '0');
  signal x_wdata : std_logic_vector(15 downto 0) := (others => '0');

  signal m_arvalid, m_arready, m_rvalid, m_rready, m_rlast :
    std_logic_vector(NP_ALL-1 downto 0) := (others => '0');
  signal m_araddr  : std_logic_vector(NP_ALL*ADDR_W-1 downto 0);
  signal m_arlen   : std_logic_vector(NP_ALL*8-1 downto 0);
  signal m_arsize  : std_logic_vector(NP_ALL*3-1 downto 0);
  signal m_arburst : std_logic_vector(NP_ALL*2-1 downto 0);
  signal m_rdata   : std_logic_vector(NP_ALL*AXI_DW-1 downto 0)
                     := (others => '0');

  signal y_we   : std_logic;
  signal y_addr : std_logic_vector(15 downto 0);
  signal y_data : std_logic_vector(RI*64-1 downto 0);
  signal y_mask : std_logic_vector(RI-1 downto 0);
  signal done, err, sat_event : std_logic;

  -- The sub-region bytes, one array per AXI port.  SHARED VARIABLES, not
  -- signals: 27 ports x 384 beats x 256 bits is 2.65 M scalars, and as a
  -- signal that is 2.65 M drivers plus a delta per loaded line.  Nothing but
  -- the loader writes them, and nothing reads them before `loaded`.
  type beat_v is array(0 to MAXBEAT-1) of std_logic_vector(AXI_DW-1 downto 0);
  type beat_a is array(0 to NP_ALL-1) of beat_v;
  shared variable img : beat_a := (others => (others => (others => '0')));

  type xm_t is array(0 to MAXCOLS-1) of std_logic_vector(15 downto 0);
  shared variable xv : xm_t := (others => (others => '0'));

  type row_t is array(0 to MAXROWS-1) of std_logic_vector(63 downto 0);
  shared variable e_ymant : row_t := (others => (others => '0'));

  signal e_yexp  : integer := 0;
  signal e_satev : integer := 0;
  signal loaded, finished : boolean := false;
  signal nbad, nchk : integer := 0;
  signal saw_sat : std_logic := '0';

  -- Assemble a sub-region base from the trace's byte offset plus BASE_HI*4 GB.
  -- shift_left on an `unsigned`, never `+ BASE_HI*2**32`: 2**32 is not a VHDL
  -- integer and the addition would not elaborate.  At ADDR_W <= 32 the shift
  -- yields 0 and the high half is lost -- deliberately, so the slave sees it.
  function lift (off : integer) return unsigned is
  begin
    return to_unsigned(off, ADDR_W)
         + shift_left(to_unsigned(BASE_HI, ADDR_W), 32);
  end function;

  -- Token compare that will not accept a PREFIX.  "SBEATS" and "SSUB" share
  -- no prefix but "WSUB"/"WBEATS" and "SATEV"/"SBEATS" are close enough that
  -- the tb_matvec_int4 style of comparing tok(1 to n) alone is a hazard here.
  function tokis (t : string; s : string) return boolean is
  begin
    if s'length > t'length then return false; end if;
    if t(t'low to t'low + s'length - 1) /= s then return false; end if;
    if t'length = s'length then return true; end if;
    return t(t'low + s'length) = ' ';
  end function;
begin
  rst <= '1', '0' after 40 ns;

  v_rows   <= std_logic_vector(to_signed(n_rows, 32));
  v_cols   <= std_logic_vector(to_signed(n_cols, 32));
  v_osh    <= std_logic_vector(to_signed(out_shift, 32));
  v_wexp   <= std_logic_vector(to_signed(w_exp, 32));
  v_xexp   <= std_logic_vector(to_signed(x_exp, 32));
  v_wbeats <= std_logic_vector(to_signed(w_beats, 32));
  v_sbeats <= std_logic_vector(to_signed(s_beats, 32));
  y_exp    <= to_integer(signed(v_yexp));

  clkgen : process
  begin
    while not finished loop
      clk <= '0'; wait for 5 ns; clk <= '1'; wait for 5 ns;
    end loop;
    wait;
  end process;

  dut : entity work.matvec_int4
    generic map(BLK => BLK, ROWS_IF => RI, NPORTS_W => NPW, NPORTS_S => NPS,
                AXI_DW => AXI_DW, ADDR_W => ADDR_W,
                MAXCOLS => MAXCOLS, MAXROWS_BFP => MAXROWS,
                FIFO_DEPTH => 256, MAXB => MAXB)
    port map(clk => clk, rst => rst, start => start,
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
             dbg_wbeat => open, dbg_wstarve => open);

  -- ---------------------------------------------- one AXI slave per port
  -- Each serves its OWN sub-region and nothing else.  Three checks are
  -- structural, not decorative:
  --   * INCR burst, because axi_rd_port claims sequential bursts;
  --   * the address high half equals BASE_HI*4 GB, which is the only thing
  --     that can see a >4 GB base truncated when each port serves its own
  --     array;
  --   * the offset from that port's base is a whole beat and inside the beat
  --     count the descriptor programmed -- i.e. the port did not wander into
  --     another sub-region.
  slaves : for p in 0 to NP_ALL-1 generate
    slv : process
      variable lf : unsigned(15 downto 0) := to_unsigned(4919 + p*277, 16);
      variable a  : unsigned(ADDR_W-1 downto 0);
      variable d  : unsigned(ADDR_W-1 downto 0);
      variable n, idx, lim : integer;
      procedure tick is
      begin
        wait until rising_edge(clk);
        lf := lf(14 downto 0) & (lf(15) xor lf(13) xor lf(12) xor lf(10));
      end procedure;
    begin
      m_arready(p) <= '0'; m_rvalid(p) <= '0'; m_rlast(p) <= '0';
      wait until rst = '0';
      loop
        m_arready(p) <= '0';
        while m_arvalid(p) = '0' loop tick; end loop;
        if STALL > 1 then
          while (to_integer(lf) mod STALL) = 0 loop tick; end loop;
        end if;
        a := unsigned(m_araddr((p+1)*ADDR_W-1 downto p*ADDR_W));
        n := to_integer(unsigned(m_arlen((p+1)*8-1 downto p*8))) + 1;
        if p < NPW then lim := w_beats; else lim := s_beats; end if;

        assert m_arburst((p+1)*2-1 downto p*2) = "01"
          report "port " & integer'image(p) & ": burst IS NOT INCR"
          severity failure;
        assert to_integer(shift_right(a, 32)) = BASE_HI
          report "port " & integer'image(p) & ": address high half is " &
                 integer'image(to_integer(shift_right(a, 32))) &
                 ", expected " & integer'image(BASE_HI) &
                 " -- the base was truncated (ADDR_W=" &
                 integer'image(ADDR_W) & ")"
          severity failure;

        d := a - pbase(p);
        assert d(LSB-1 downto 0) = to_unsigned(0, LSB)
          report "port " & integer'image(p) &
                 ": address IS NOT beat aligned" severity failure;
        assert to_integer(shift_right(d, LSB + BSEL)) = 0
          report "port " & integer'image(p) &
                 ": read address is outside its own sub-region -- MISMATCH"
          severity failure;
        idx := to_integer(d(LSB + BSEL - 1 downto LSB));
        assert idx + n <= lim
          report "port " & integer'image(p) & ": burst of " &
                 integer'image(n) & " from beat " & integer'image(idx) &
                 " runs past the " & integer'image(lim) &
                 " beats programmed -- MISMATCH"
          severity failure;

        m_arready(p) <= '1'; tick; m_arready(p) <= '0';
        for i in 0 to n-1 loop
          if STALL > 1 then
            m_rvalid(p) <= '0';
            while (to_integer(lf) mod STALL) = 0 loop tick; end loop;
          end if;
          m_rdata((p+1)*AXI_DW-1 downto p*AXI_DW) <= img(p)(idx + i);
          m_rvalid(p) <= '1';
          if i = n-1 then m_rlast(p) <= '1'; else m_rlast(p) <= '0'; end if;
          loop
            tick;
            exit when m_rready(p) = '1';
          end loop;
        end loop;
        m_rvalid(p) <= '0'; m_rlast(p) <= '0';
      end loop;
    end process;
  end generate;

  -- ----------------------------------------------------------------- loader
  load : process
    file     tf : text open read_mode is TRACE;
    variable l  : line;
    variable tok : string(1 to 12);
    variable c  : character;
    variable slen, a, b, v : integer;
    variable h16 : std_logic_vector(15 downto 0);
    variable h64 : std_logic_vector(63 downto 0);
    variable hbe : std_logic_vector(AXI_DW-1 downto 0);
    variable good, saw_end : boolean;
    variable gRI, gNPW, gNPS, gDW, gBLK, gGRP : integer;
    variable M, K, NB, osh, wev, xev : integer;
    variable nimg : integer := 0;
  begin
    saw_end := false;
    wait until rst = '0';
    wait until rising_edge(clk);
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

      if tokis(tok, "GEOM") then
        read(l, gRI); read(l, gNPW); read(l, gNPS);
        read(l, gDW); read(l, gBLK); read(l, gGRP);
        assert gRI = RI and gNPW = NPW and gNPS = NPS
               and gDW = AXI_DW and gBLK = BLK
          report "trace GEOMETRY IS WRONG for this testbench: trace has " &
                 "ROWS_IF=" & integer'image(gRI) &
                 " NPORTS_W=" & integer'image(gNPW) &
                 " NPORTS_S=" & integer'image(gNPS) &
                 " AXI_DW=" & integer'image(gDW) &
                 " BLK=" & integer'image(gBLK) &
                 ", generics say " & integer'image(RI) & "/" &
                 integer'image(NPW) & "/" & integer'image(NPS) & "/" &
                 integer'image(AXI_DW) & "/" & integer'image(BLK)
          severity failure;
      elsif tokis(tok, "DIMS") then
        read(l, M); read(l, K); read(l, NB);
        read(l, osh); read(l, wev); read(l, xev);
        assert M <= MAXROWS and K <= MAXCOLS
          report "trace shape does not fit this testbench's arrays"
          severity failure;
        n_rows <= M; n_cols <= K;
        out_shift <= osh; w_exp <= wev; x_exp <= xev;
      elsif tokis(tok, "CB") then
        read(l, a); read(l, v);
        cb_addr <= std_logic_vector(to_unsigned(a, 4));
        cb_data <= std_logic_vector(to_signed(v, 8));
        cb_we <= '1'; wait until rising_edge(clk); cb_we <= '0';
      elsif tokis(tok, "X") then
        read(l, a); hread(l, h16); xv(a) := h16;
      elsif tokis(tok, "WSUB") then
        read(l, a); read(l, v);
        w_base((a+1)*ADDR_W-1 downto a*ADDR_W)
          <= std_logic_vector(lift(v));
        pbase(a) <= lift(v);
      elsif tokis(tok, "SSUB") then
        read(l, a); read(l, v);
        s_base((a+1)*ADDR_W-1 downto a*ADDR_W)
          <= std_logic_vector(lift(v));
        pbase(NPW + a) <= lift(v);
      elsif tokis(tok, "WBEATS") then
        read(l, v);
        assert v <= MAXBEAT report "WBEATS exceeds MAXBEAT" severity failure;
        w_beats <= v;
      elsif tokis(tok, "SBEATS") then
        read(l, v);
        assert v <= MAXBEAT report "SBEATS exceeds MAXBEAT" severity failure;
        s_beats <= v;
      elsif tokis(tok, "IMG") then
        read(l, a); read(l, b); hread(l, hbe);
        img(a)(b) := hbe;
        nimg := nimg + 1;
      elsif tokis(tok, "YMANT") then
        read(l, a); hread(l, h64); e_ymant(a) := h64;
      elsif tokis(tok, "YEXP") then
        read(l, a); e_yexp <= a;
      elsif tokis(tok, "SATEV") then
        read(l, a); e_satev <= a;
      elsif tokis(tok, "END") then
        saw_end := true;
      end if;
    end loop;
    -- A truncated trace would otherwise present as a wrong answer.  It is not
    -- one, and it must not be reported as one.
    assert saw_end
      report "the trace has no END line: it IS NOT complete, so nothing " &
             "below this point means anything"
      severity failure;
    report "loaded " & integer'image(nimg) & " sub-region beats from " & TRACE
      severity note;
    wait until rising_edge(clk);
    loaded <= true;
    wait;
  end process;

  -- -------------------------------------------------------- output checking
  ycap : process(clk)
    variable r  : integer;
    variable nc, nb : integer;
    variable got, want : std_logic_vector(63 downto 0);
  begin
    if rising_edge(clk) then
      nc := nchk; nb := nbad;
      if sat_event = '1' then saw_sat <= '1'; end if;
      if y_we = '1' then
        for rr in 0 to RI-1 loop
          if y_mask(rr) = '1' then
            r    := to_integer(unsigned(y_addr)) + rr;
            got  := y_data(rr*64+63 downto rr*64);
            want := e_ymant(r);
            nc := nc + 1;
            if got /= want then
              nb := nb + 1;
              if nb < 8 then
                report "END-TO-END MISMATCH r=" & integer'image(r) &
                       " got "  & integer'image(to_integer(signed(got))) &
                       " want " & integer'image(to_integer(signed(want)))
                  severity error;
              end if;
            end if;
          end if;
        end loop;
      end if;
      nchk <= nc; nbad <= nb;
    end if;
  end process;

  -- ------------------------------------------------------------------ driver
  drv : process
  begin
    wait until loaded;
    wait until rising_edge(clk);
    for k in 0 to n_cols-1 loop
      x_we    <= '1';
      x_waddr <= std_logic_vector(to_unsigned(k, 16));
      x_wdata <= xv(k);
      wait until rising_edge(clk);
    end loop;
    x_we <= '0';
    wait until rising_edge(clk);

    out_mode <= "00";
    start <= '1'; wait until rising_edge(clk); start <= '0';
    wait until done = '1';
    wait until rising_edge(clk);

    assert err = '0' report "descriptor rejected: err IS SET" severity failure;
    assert y_exp = e_yexp
      report "YEXP MISMATCH got " & integer'image(y_exp) &
             " want " & integer'image(e_yexp) severity error;
    assert (saw_sat = '1' and e_satev = 1) or (saw_sat = '0' and e_satev = 0)
      report "SAT_EVENT MISMATCH got " & std_logic'image(saw_sat) &
             " want " & integer'image(e_satev) severity error;
    report "FK33 geometry ROWS_IF=" & integer'image(RI) &
           " AXI_DW=" & integer'image(AXI_DW) &
           " NPORTS_W=" & integer'image(NPW) &
           " NPORTS_S=" & integer'image(NPS) & " over " &
           integer'image(NP_ALL) & " AXI masters: " &
           integer'image(nchk) & " rows compared, " &
           integer'image(nbad) & " mismatches, y_exp=" &
           integer'image(y_exp) severity note;
    assert nchk = n_rows
      report "expected " & integer'image(n_rows) & " rows, saw " &
             integer'image(nchk) & " -- the row count IS WRONG"
      severity failure;
    assert nbad = 0 and y_exp = e_yexp
           and ((saw_sat = '1') = (e_satev = 1))
      report "SUBSYSTEM A DIVERGES FROM ref/matvec_int4.c AT THE FK33 GEOMETRY"
      severity failure;
    report "subsystem A is bit-exact with ref/matvec_int4.c from the real " &
           ".mv4i bytes up, at ROWS_IF=48 / AXI_DW=256"
      severity note;
    finished <= true;
    wait;
  end process;
end architecture;
