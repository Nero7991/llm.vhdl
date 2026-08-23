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

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_matvec_int4 is
  generic(
    TRACE : string   := "../tr.txt";
    RI    : positive := 4;
    STALL : natural  := 3
  );
end entity;

architecture sim of tb_matvec_int4 is
  constant BLK    : positive := 32;
  constant AXI_DW : positive := 128;
  constant ADDR_W : positive := 32;
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

  -- the packed image, defaulting to zero exactly as the packer's calloc does
  type img_t is array(0 to MAXW-1) of std_logic_vector(AXI_DW-1 downto 0);
  signal img : img_t := (others => (others => '0'));

  type xm_t is array(0 to MAXB*BLK-1) of std_logic_vector(15 downto 0);
  signal xv : xm_t := (others => (others => '0'));

  type row_t is array(0 to MAXR-1) of signed(63 downto 0);
  signal e_ymant : row_t := (others => (others => '0'));
  signal e_yexp  : integer := 0;

  signal loaded, finished : boolean := false;
  signal nbad, nchk : integer := 0;
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
    generic map(BLK => BLK, ROWS_IF => RI, NPORTS_W => NP, AXI_DW => AXI_DW,
                ADDR_W => ADDR_W, MAXCOLS => 512, MAXROWS_BFP => MAXR,
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
             dbg_wbeat => open, dbg_wstarve => open);

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
        m_arready(p) <= '1'; tick; m_arready(p) <= '0';
        for i in 0 to n-1 loop
          if STALL > 1 then
            m_rvalid(p) <= '0';
            while (to_integer(lf) mod STALL) = 0 loop tick; end loop;
          end if;
          m_rdata((p+1)*AXI_DW-1 downto p*AXI_DW)
            <= img(to_integer(a / 16) mod MAXW);
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
        out_shift <= osh; w_exp <= wev; x_exp <= xev;
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
          <= std_logic_vector(to_unsigned(v, ADDR_W));
      elsif tok(1 to 5) = "SBASE" then
        read(l, v); s_base <= std_logic_vector(to_unsigned(v, ADDR_W));
      elsif tok(1 to 6) = "WBEATS" then
        read(l, v); w_beats <= v;
      elsif tok(1 to 6) = "SBEATS" then
        read(l, v); s_beats <= v;
      elsif tok(1 to 4) = "IMG " then
        read(l, a); hread(l, h128); img(a) <= h128;
      elsif tok(1 to 5) = "YMANT" then
        read(l, a); hread(l, hv); e_ymant(a) <= signed(hv);
      elsif tok(1 to 4) = "YEXP" then
        read(l, a); e_yexp <= a;
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

  -- ------------------------------------------------------------------ driver
  drv : process
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
    report "subsystem A matches ref/matvec_int4.c from the packed bytes up"
      severity note;
    finished <= true;
    wait;
  end process;
end architecture;
