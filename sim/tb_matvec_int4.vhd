-- sim/tb_matvec_int4.vhd -- subsystem A end to end, from the REAL packed bytes.
--
-- Everything upstream of this point tests one layer against another derivation
-- of the same idea.  This one closes the loop: ref/matvec_int4 --trace emits the
-- packed image exactly as the packer lays it out (6.4/6.5), the testbench serves
-- those bytes over AXI to weight_streamer, and the result is compared against
-- the C reference's own output for the same matrix.  A wrong sub-region layout,
-- a wrong lane order, a wrong nibble order or a wrong scale interleave all show
-- up here and nowhere else -- a testbench that re-derived the layout would agree
-- with a wrong layout just as happily.
--
-- All NPORTS_W+1 slaves stall independently, because the merge's pop gate (7.7)
-- is only meaningful when the ports actually run out of step.
--
-- ADDRESS WIDTH (added 2026-08-27, spec A 15.5).  ADDR_W is a GENERIC, not a
-- constant, and BASE_HI lifts every sub-region base by BASE_HI * 4 GB.  The two
-- exist together because a >4 GB base is the case the FK33 needs and the one
-- nothing could previously express:
--
--   * the base cannot be built through a VHDL `integer`.  A VHDL integer is
--     32-bit SIGNED, so `to_unsigned(v, ADDR_W)` -- what this file used to do,
--     and what the natural fix looks like -- cannot represent 0x1_0000_0000 at
--     any ADDR_W.  Bases are therefore assembled in `unsigned` throughout.
--   * the slave must not index its image by `to_integer(a / 16)`.  That is a
--     second integer, and at a 64-bit address it overflows before it can be
--     wrapped.  The word index is taken as an ADDRESS SLICE instead.
--   * the slave CHECKS the high half.  Without that, truncation is invisible
--     here: the image is served modulo MAXW, so a base that silently loses its
--     top 32 bits reads exactly the right bytes and the test passes.  That is
--     precisely the silent wrap this generic exists to catch, so the check is
--     the test, not a nicety.  `shift_right(a, 32)` is 0 at ADDR_W=32 by
--     numeric_std's own definition, so the assertion is legal at both widths
--     and fails at the narrow one -- which is the evidence.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.util_pkg.all;

entity tb_matvec_int4 is
  generic(
    TRACE  : string   := "../tr.txt";
    RI     : positive := 4;
    STALL  : natural  := 3;
    -- 32 reproduces every result from before this generic existed; 64 is the
    -- FK33 width.  Anything in between is legal and untested.
    ADDR_W : positive := 64;
    -- Units of 4 GB added to every sub-region base.  0 is the historical case.
    -- Non-zero requires ADDR_W > 32 and FAILS loudly at 32.
    BASE_HI : natural := 0;

    -- ----------------------------------------------------------------------
    -- STIMULUS KNOBS, added 2026-08-29 (TRACK ASURV) to reach three regions
    -- the mutation table named as unreached.  EVERY ONE DEFAULTS TO THE
    -- HISTORICAL VALUE, so the gate row does not move.
    -- ----------------------------------------------------------------------
    -- The DUT's column bound.  512 is what this file hard-coded.  The reason
    -- it is a generic is rtl/matvec_int4.vhd's
    --     XB = clog2((MAXCOLS + BLK - 1) / BLK)
    -- whose CEILING is only distinguishable from a plain divide when MAXCOLS
    -- is NOT a multiple of BLK -- and 512 is.  See the MAXCOLS note below the
    -- entity for which values separate the two.
    MAXCOLS : positive := 512;

    -- Added to the trace's w_exp / x_exp on the way into the DUT, and to the
    -- trace's YEXP on the way into the expectation.  This is EXACT, not an
    -- approximation: ref/matvec_int4.c:426 computes
    --     y_exp = w_exp + x_exp - out_shift - ns
    -- and rtl/matvec_core.vhd:1031 computes the same expression, so biasing
    -- both inputs shifts the output by exactly the sum and NOTHING else in
    -- either implementation reads w_exp or x_exp (grep: matvec_core has them
    -- at lines 70/71 as ports and at 1031-1033 as this expression, nowhere
    -- else).  The mantissas are untouched, so the whole packed image, the
    -- activation vector and every YMANT stay valid.
    --
    -- WHY IT EXISTS: no trace in this tree drives a NEGATIVE w_exp or x_exp
    -- (--trace pins 2 and 5), so `signed` and `unsigned` are the same function
    -- on the descriptor's exponent words and the two conversions in
    -- rtl/matvec_int4.vhd could not be told apart.  The .mv4i format calls the
    -- field signed (ref/matvec_int4.c:173).
    WEXP_BIAS : integer := 0;
    XEXP_BIAS : integer := 0;

    -- Observe dbg_wbeat / dbg_wstarve.  Every bench in the tree left both
    -- `open`, which is what spec 11's bandwidth number would be built from.
    -- false is the ATTRIBUTION CONTROL for the two rows these checks kill.
    CHK_TAPS : boolean := true;

    -- A SECOND, DELIBERATELY ILLEGAL descriptor issued after the good job,
    -- whose only expectation is that `err` goes high and no row is emitted.
    --   0  none -- the historical single-job behaviour
    --   1  out_shift = -1, which spec 7.6 and rtl/matvec_core.vhd:946
    --      (`out_shift < 0`) both forbid
    --   2  n_rows = -1, forbidden by the same line (`n_rows <= 0`)
    --
    -- WHY: those two guard arms can only fire on a NEGATIVE integer, and
    -- rtl/matvec_int4.vhd reaches them through `to_integer(signed(...))`.
    -- Read as `unsigned` the same word is a large positive, so the `< 0` arm
    -- becomes unreachable -- the conversion and the guard arm are one
    -- requirement.  sim/tb_matvec_core.vhd exercises the guard, but it drives
    -- matvec_core's INTEGER ports directly and so bypasses the conversion
    -- entirely; no bench drove an illegal descriptor through this level.
    ERRINJ : natural := 0
  );
end entity;

architecture sim of tb_matvec_int4 is
  constant BLK    : positive := 32;
  constant AXI_DW : positive := 128;
  constant NP     : positive := RI;          -- NPORTS_W, 6.5 invariant
  constant MAXW   : positive := 16384;       -- image words of 128 b
  constant MAXR   : positive := 64;
  constant MAXB   : positive := 16;

  signal clk, rst : std_logic := '0';
  signal start : std_logic := '0';

  signal n_rows, n_cols, out_shift, w_exp, x_exp : integer := 0;
  signal y_exp : integer;
  signal v_rows, v_cols, v_osh, v_wexp, v_xexp : std_logic_vector(31 downto 0);
  signal v_wbeats, v_sbeats, v_yexp            : std_logic_vector(31 downto 0);
  signal out_mode : std_logic_vector(1 downto 0) := "00";
  signal cb_we : std_logic := '0';
  signal cb_addr : std_logic_vector(3 downto 0) := (others => '0');
  signal cb_data : std_logic_vector(7 downto 0) := (others => '0');

  signal w_base : std_logic_vector(NP*ADDR_W-1 downto 0) := (others => '0');
  signal s_base : std_logic_vector(ADDR_W-1 downto 0) := (others => '0');
  signal w_beats, s_beats : integer := 0;

  signal x_we : std_logic := '0';
  signal x_waddr, x_wdata : std_logic_vector(15 downto 0) := (others => '0');

  signal m_arvalid, m_arready, m_rvalid, m_rready, m_rlast :
    std_logic_vector(NP downto 0) := (others => '0');
  signal m_araddr  : std_logic_vector((NP+1)*ADDR_W-1 downto 0);
  signal m_arlen   : std_logic_vector((NP+1)*8-1 downto 0);
  signal m_arsize  : std_logic_vector((NP+1)*3-1 downto 0);
  signal m_arburst : std_logic_vector((NP+1)*2-1 downto 0);
  signal m_rdata   : std_logic_vector((NP+1)*AXI_DW-1 downto 0) := (others => '0');

  signal y_we : std_logic;
  signal y_addr : std_logic_vector(15 downto 0);
  signal y_data : std_logic_vector(RI*64-1 downto 0);
  signal y_mask : std_logic_vector(RI-1 downto 0);
  signal done, err, sat_event : std_logic;

  -- Image word index taken as an address SLICE, never as to_integer(a/16):
  -- the latter is a VHDL integer and overflows at a 64-bit address before the
  -- `mod MAXW` that was meant to bound it can run.
  constant WSEL : positive := clog2(MAXW);        -- 14 at MAXW = 16384

  -- What the high half of every emitted address must be.  This is the whole
  -- point of BASE_HI: with the image served modulo MAXW, a truncated base
  -- still reads the right bytes, so only an explicit check sees the wrap.
  constant HI_EXP : natural := BASE_HI;

  -- the packed image, defaulting to zero exactly as the packer's calloc does
  type img_t is array(0 to MAXW-1) of std_logic_vector(AXI_DW-1 downto 0);
  signal img : img_t := (others => (others => '0'));

  -- MAXCOLS, not MAXB*BLK.  The two were equal only because MAXB happened to
  -- be 16 and MAXCOLS 512; MAXB is the AXI burst cap and has nothing to do
  -- with how long the activation vector is.
  type xm_t is array(0 to MAXCOLS-1) of std_logic_vector(15 downto 0);
  signal xv : xm_t := (others => (others => '0'));

  -- the two performance taps, which every bench in the tree left `open`
  signal s_wbeat, s_wstarve : std_logic;
  signal n_wbeat, n_both    : integer := 0;

  type row_t is array(0 to MAXR-1) of signed(63 downto 0);
  signal e_ymant : row_t := (others => (others => '0'));
  signal e_yexp  : integer := 0;

  signal loaded, finished : boolean := false;
  signal inj : boolean := false;
  signal nbad, nchk : integer := 0;

  -- Assemble a sub-region base from the trace's byte offset plus BASE_HI * 4 GB.
  -- The high term is built with shift_left on an `unsigned`, NOT by adding
  -- BASE_HI * 2**32 as an integer: 2**32 is not representable as a VHDL integer
  -- and the addition would fail to elaborate, which is why nothing here could
  -- express a >4 GB base before.  At ADDR_W <= 32 the shift yields 0 and the
  -- high half is lost silently -- deliberately, so the slave's check sees it.
  function lift (off : integer) return unsigned is
  begin
    return to_unsigned(off, ADDR_W)
         + shift_left(to_unsigned(BASE_HI, ADDR_W), 32);
  end function;
begin
  rst <= '1', '0' after 40 ns;

  -- `inj` is driven by drv alone; n_rows / out_shift are driven by the loader
  -- alone.  They are unresolved integers, so the override has to be a mux
  -- here rather than a second driver on the signal -- the same reason
  -- sim/tb_matvec_core.vhd carries ov_rows.
  v_rows   <= std_logic_vector(to_signed(-1, 32))
                when inj and ERRINJ = 2 else
              std_logic_vector(to_signed(n_rows, 32));
  v_cols   <= std_logic_vector(to_signed(n_cols, 32));
  v_osh    <= std_logic_vector(to_signed(-1, 32))
                when inj and ERRINJ = 1 else
              std_logic_vector(to_signed(out_shift, 32));
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
    generic map(BLK => BLK, ROWS_IF => RI, NPORTS_W => NP, AXI_DW => AXI_DW,
                ADDR_W => ADDR_W, MAXCOLS => MAXCOLS, MAXROWS_BFP => MAXR,
                FIFO_DEPTH => 64, MAXB => 16)
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
             dbg_wbeat => s_wbeat, dbg_wstarve => s_wstarve);

  -- ------------------------------------------------- one AXI slave per port
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
      wait until rst = '0';
      loop
        m_arready(p) <= '0';
        while m_arvalid(p) = '0' loop tick; end loop;
        if STALL > 1 then
          while (to_integer(lf) mod STALL) = 0 loop tick; end loop;
        end if;
        a := unsigned(m_araddr((p+1)*ADDR_W-1 downto p*ADDR_W));
        n := to_integer(unsigned(m_arlen((p+1)*8-1 downto p*8))) + 1;
        assert m_arburst((p+1)*2-1 downto p*2) = "01"
          report "port " & integer'image(p) & ": burst must be INCR"
          severity failure;
        -- THE ADDRESS-WIDTH CHECK.  shift_right by 32 is defined for any
        -- length, and yields 0 when ADDR_W <= 32, so this line is legal at
        -- both widths and is exactly what a truncated base trips.
        assert to_integer(shift_right(a, 32)) = HI_EXP
          report "port " & integer'image(p) & ": address high half is " &
                 integer'image(to_integer(shift_right(a, 32))) &
                 ", expected " & integer'image(HI_EXP) &
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
            <= img(to_integer(a(WSEL + 3 downto 4)));
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

      if tok(1 to 4) = "DIMS" then
        read(l, M); read(l, K); read(l, NB); read(l, osh);
        read(l, wev); read(l, xev); read(l, R);
        assert R = RI report "trace ROWS_IF mismatch" severity failure;
        n_rows <= M; n_cols <= K;
        assert K <= MAXCOLS
          report "trace K=" & integer'image(K) & " exceeds MAXCOLS=" &
                 integer'image(MAXCOLS) severity failure;
        out_shift <= osh; w_exp <= wev + WEXP_BIAS; x_exp <= xev + XEXP_BIAS;
      elsif tok(1 to 2) = "CB" then
        read(l, a); read(l, v);
        cb_addr <= std_logic_vector(to_unsigned(a, 4));
        cb_data <= std_logic_vector(to_signed(v, 8));
        cb_we <= '1'; wait until rising_edge(clk); cb_we <= '0';
      elsif tok(1 to 1) = "X" then
        read(l, a); hread(l, h16); xv(a) <= h16;
      elsif tok(1 to 5) = "WBASE" then
        read(l, a); read(l, v);
        w_base((a+1)*ADDR_W-1 downto a*ADDR_W)
          <= std_logic_vector(lift(v));
      elsif tok(1 to 5) = "SBASE" then
        read(l, v); s_base <= std_logic_vector(lift(v));
      elsif tok(1 to 6) = "WBEATS" then
        read(l, v); w_beats <= v;
      elsif tok(1 to 6) = "SBEATS" then
        read(l, v); s_beats <= v;
      elsif tok(1 to 4) = "IMG " then
        read(l, a); hread(l, h128); img(a) <= h128;
      elsif tok(1 to 5) = "YMANT" then
        read(l, a); hread(l, hv); e_ymant(a) <= signed(hv);
      elsif tok(1 to 4) = "YEXP" then
        read(l, a); e_yexp <= a + WEXP_BIAS + XEXP_BIAS;
      end if;
      wait for 0 ns;
    end loop;
    wait until rising_edge(clk);
    loaded <= true;
    wait;
  end process;

  -- -------------------------------------------------------- output checking
  ycap : process(clk)
    variable r, got, want : integer;
    variable nc, nb : integer;
  begin
    if rising_edge(clk) then
      nc := nchk; nb := nbad;
      if y_we = '1' then
        for rr in 0 to RI-1 loop
          if y_mask(rr) = '1' then
            r := to_integer(unsigned(y_addr)) + rr;
            got  := to_integer(resize(signed(y_data(rr*64+63 downto rr*64)), 32));
            want := to_integer(resize(e_ymant(r), 32));
            nc := nc + 1;
            if got /= want then
              nb := nb + 1;
              if nb < 8 then
                report "END-TO-END MISMATCH r=" & integer'image(r) &
                       " got "  & integer'image(got) &
                       " want " & integer'image(want) severity error;
              end if;
            end if;
          end if;
        end loop;
      end if;
      nchk <= nc; nbad <= nb;
    end if;
  end process;

  -- ------------------------------------------------- the two performance taps
  -- Spec 11 wants sustained bandwidth as a percentage of DDR peak, and
  -- rtl/matvec_int4.vhd's dbg_wbeat / dbg_wstarve are the only measurement it
  -- could be built from.  Until 2026-08-29 every bench in the tree left both
  -- `open`, so both were free to be anything at all.
  --
  -- TWO ORACLES, and they are independent of the geometry:
  --
  --   both  dbg_wbeat = '1' and dbg_wstarve = '1' on the same cycle is a
  --         CONTRADICTION IN THE PORT DEFINITIONS -- "a weight word was
  --         accepted" and "no weight word was available" cannot both hold.
  --         MEASURED 0 in twelve (M, K, STALL) combinations.
  --   count the number of cycles dbg_wbeat is high over one job is the number
  --         of w_data words the core consumed, which at AXI_DW=128 / BLK=32 is
  --         exactly the trace's WBEATS (one 128-bit beat per row-block chunk,
  --         one chunk per port, one w_data per pop).  MEASURED equal to
  --         w_beats in the SAME twelve combinations: M in {8,32},
  --         K in {96,256,512}, STALL in {0,3}.
  --
  -- The count is the sharper of the two: rtl/matvec_core.vhd:566 makes
  -- `w_ready` depend on `w_valid`, so `wv and wr` and `wv` differ only on the
  -- cycles the core cannot accept (not S_RUN, or the scale stream behind, or
  -- the activation prefetch queue empty).  Whether such a cycle occurs is a
  -- property of the STIMULUS -- at M=8 K=96 STALL=3, the historical
  -- configuration, there is not one and the two expressions agree.
  tapchk : process(clk)
  begin
    if rising_edge(clk) then
      if CHK_TAPS and loaded then
        if s_wbeat = '1' then n_wbeat <= n_wbeat + 1; end if;
        if s_wbeat = '1' and s_wstarve = '1' then
          n_both <= n_both + 1;
        end if;
      end if;
    end if;
  end process;

  -- ------------------------------------------------------------------ driver
  drv : process
    variable ne_inj : integer := 0;
  begin
    wait until loaded;
    wait until rising_edge(clk);
    -- load the activation vector through the producer port, one element/cycle
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

    assert err = '0' report "descriptor rejected" severity failure;
    assert y_exp = e_yexp
      report "YEXP got " & integer'image(y_exp) &
             " want " & integer'image(e_yexp) severity error;
    report "end to end: " & integer'image(nchk) & " rows compared, " &
           integer'image(nbad) & " mismatches, y_exp=" & integer'image(y_exp)
           severity note;
    assert nchk = n_rows
      report "expected " & integer'image(n_rows) & " rows, saw " &
             integer'image(nchk) severity failure;
    assert nbad = 0 and y_exp = e_yexp
      report "SUBSYSTEM A DIVERGES FROM THE C REFERENCE END TO END"
      severity failure;
    if CHK_TAPS then
      report "taps: dbg_wbeat high on " & integer'image(n_wbeat) &
             " cycles, w_beats=" & integer'image(w_beats) &
             ", wbeat-and-wstarve on " & integer'image(n_both) & " cycles"
        severity note;
      assert n_both = 0
        report "TAP CONTRADICTION: dbg_wbeat and dbg_wstarve were both high " &
               "on " & integer'image(n_both) & " cycles.  A weight word " &
               "cannot be accepted on a cycle when none was available."
        severity failure;
      assert n_wbeat = w_beats
        report "TAP COUNT: dbg_wbeat was high on " & integer'image(n_wbeat) &
               " cycles but the job consumed " & integer'image(w_beats) &
               " weight words.  dbg_wbeat must count ACCEPTED words, not " &
               "offered ones (spec 11 builds sustained bandwidth from it)."
        severity failure;
    end if;
    -- ------------------------------------------------------------------
    -- PHASE 2, only when ERRINJ /= 0: an illegal descriptor MUST be refused.
    -- Two things are checked, not one -- a rejection that still emitted rows
    -- would be a rejection in name only.  This mirrors PASS 9 of
    -- sim/tb_matvec_core.vhd, one level up and through the conversions.
    -- ------------------------------------------------------------------
    if ERRINJ /= 0 then
      wait until done = '0';
      wait until rising_edge(clk);
      ne_inj := nchk;
      inj <= true;
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      if ERRINJ = 1 then
        report "ERRINJ 1: issuing an illegal descriptor (out_shift = -1)"
          severity note;
      else
        report "ERRINJ 2: issuing an illegal descriptor (n_rows = -1)"
          severity note;
      end if;
      start <= '1'; wait until rising_edge(clk); start <= '0';
      wait until done = '1';
      wait until rising_edge(clk);
      assert err = '1'
        report "ERRINJ " & integer'image(ERRINJ) & ": the illegal descriptor " &
               "was ACCEPTED.  spec 7.6 and rtl/matvec_core.vhd's S_IDLE " &
               "check both forbid it, and the negative arm of that check is " &
               "only reachable if this level converts the descriptor word as " &
               "SIGNED."
        severity failure;
      assert nchk = ne_inj
        report "ERRINJ " & integer'image(ERRINJ) & ": the descriptor was " &
               "refused but " & integer'image(nchk - ne_inj) &
               " rows still left the port" severity failure;
      report "the illegal descriptor was refused, err=1, 0 rows emitted"
        severity note;
    end if;

    report "subsystem A matches ref/matvec_int4.c from the packed bytes up"
      severity note;
    finished <= true;
    wait;
  end process;
end architecture;
