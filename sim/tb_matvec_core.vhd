-- sim/tb_matvec_core.vhd
-- Validates rtl/matvec_core.vhd against ref/matvec_int4.c STAGE BY STAGE.
--
-- The stimulus AND every expected intermediate come from one file emitted by
--   ref/matvec_int4 --trace <out> [M K ROWS_IF]
-- so there is no hand-written expectation anywhere: a divergence localizes to
-- one stage (partial / contrib / acc / ns / ymant) on the first failing vector,
-- instead of appearing as a wrong output that has to be bisected.
--
-- Weights and scales are driven as STREAMS in the packer's tile-major order
-- (spec 6.5), which is what weight_streamer will deliver, and both are gated by
-- a pseudo-random valid so the core is exercised under backpressure rather than
-- only at full rate.  Activations come from a 1-cycle-latency block memory,
-- standing in for act_mem_striped.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_matvec_core is
  generic(
    TRACE : string   := "../matvec_trace.txt";
    RI    : positive := 4;
    STALL : natural  := 0        -- 0 = full rate, else 1-in-N valid deassert
  );
end entity;

architecture sim of tb_matvec_core is
  constant BLK  : positive := 32;
  constant MAXR : positive := 64;
  constant MAXB : positive := 16;

  signal clk   : std_logic := '0';
  signal rst   : std_logic := '1';
  signal start : std_logic := '0';

  signal n_rows, n_cols, out_shift, w_exp, x_exp, y_exp : integer := 0;
  signal out_mode : std_logic_vector(1 downto 0) := "00";
  signal cb_we    : std_logic := '0';
  signal cb_addr  : std_logic_vector(3 downto 0) := (others => '0');
  signal cb_data  : std_logic_vector(7 downto 0) := (others => '0');

  signal w_valid, w_ready, s_valid, s_ready : std_logic := '0';
  signal w_data : std_logic_vector(RI*BLK*4-1 downto 0) := (others => '0');
  signal s_data : std_logic_vector(RI*16-1 downto 0)    := (others => '0');

  signal x_rbaddr : std_logic_vector(15 downto 0);
  signal x_rdata  : std_logic_vector(BLK*16-1 downto 0) := (others => '0');

  signal y_we   : std_logic;
  signal y_addr : std_logic_vector(15 downto 0);
  signal y_data : std_logic_vector(RI*64-1 downto 0);
  signal y_mask : std_logic_vector(RI-1 downto 0);
  signal done, err, sat_event : std_logic;

  signal tp_v, tc_v, ta_v, tm_v : std_logic;
  signal tp_r, tc_r, ta_r, tm_r, tp_b, tc_b, tap_ns : integer;
  signal tp_val, tc_val, ta_val, tm_val : std_logic_vector(RI*64-1 downto 0);

  -- source data, from the trace
  type idx_t is array(0 to MAXR-1, 0 to MAXB*BLK-1) of integer;
  type scl_t is array(0 to MAXR-1, 0 to MAXB-1) of std_logic_vector(15 downto 0);
  type xm_t  is array(0 to MAXB-1) of std_logic_vector(BLK*16-1 downto 0);
  signal widx : idx_t := (others => (others => 0));
  signal wscl : scl_t := (others => (others => (others => '0')));
  signal xmem : xm_t  := (others => (others => '0'));

  -- expectations
  type exp_t is array(0 to MAXR*MAXB-1) of signed(63 downto 0);
  type row_t is array(0 to MAXR-1)      of signed(63 downto 0);
  signal e_part, e_contrib : exp_t := (others => (others => '0'));
  signal e_acc, e_ymant    : row_t := (others => (others => '0'));
  signal e_ns, e_yexp, nb_s, ri_s : integer := 0;

  signal loaded : boolean := false;
  signal nbad, nchk : integer := 0;
  signal nmant : integer := 0;   -- rows actually emitted, for coverage
  signal ybad, ychk : integer := 0;   -- own counters: one driver per signal
  signal tiles_s : integer := 0;
  signal finished : boolean := false;
begin
  -- The clock STOPS at the end of the run.  A free-running clock would make the
  -- simulator grind through the whole --stop-time after the checks are done,
  -- which with a 128-multiplier datapath is minutes of wall clock for nothing.
  clkgen : process
  begin
    while not finished loop
      clk <= '0'; wait for 5 ns;
      clk <= '1'; wait for 5 ns;
    end loop;
    wait;
  end process;

  -- stand-in for act_mem_striped: registered read, 1-cycle latency (7.8)
  actmem : process(clk)
  begin
    if rising_edge(clk) then
      x_rdata <= xmem(to_integer(unsigned(x_rbaddr)) mod MAXB);
    end if;
  end process;

  dut : entity work.matvec_core
    generic map(BLK => BLK, ROWS_IF => RI, MAXCOLS => 17408, MAXROWS_BFP => MAXR)
    port map(clk => clk, rst => rst, start => start,
             n_rows => n_rows, n_cols => n_cols, out_shift => out_shift,
             w_exp => w_exp, x_exp => x_exp, out_mode => out_mode,
             cb_we => cb_we, cb_addr => cb_addr, cb_data => cb_data,
             w_valid => w_valid, w_data => w_data, w_ready => w_ready,
             s_valid => s_valid, s_data => s_data, s_ready => s_ready,
             x_rbaddr => x_rbaddr, x_rdata => x_rdata,
             y_we => y_we, y_addr => y_addr, y_data => y_data,
             y_mask => y_mask, y_exp => y_exp,
             done => done, err => err, sat_event => sat_event,
             tp_v => tp_v, tc_v => tc_v, ta_v => ta_v, tm_v => tm_v,
             tp_r => tp_r, tc_r => tc_r, ta_r => ta_r, tm_r => tm_r,
             tp_b => tp_b, tc_b => tc_b,
             tp_val => tp_val, tc_val => tc_val,
             ta_val => ta_val, tm_val => tm_val, tap_ns => tap_ns);

  -- ---------------------------------------------------------------- loader
  load : process
    file     tf : text open read_mode is TRACE;
    variable l  : line;
    variable tok : string(1 to 10);
    variable c  : character;
    variable slen, a, b, v : integer;
    variable h16 : std_logic_vector(15 downto 0);
    variable hv  : std_logic_vector(63 downto 0);
    variable good : boolean;
    variable M, K, NB, osh, wev, xev, R : integer;
  begin
    -- The core gates cb_we on st = S_IDLE, and its reset branch takes priority,
    -- so codebook writes issued while rst is high are silently swallowed.
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
        assert R = RI
          report "trace was packed for ROWS_IF=" & integer'image(R) &
                 " but the DUT is " & integer'image(RI) severity failure;
        n_rows <= M; n_cols <= K; nb_s <= NB; ri_s <= R;
        tiles_s <= (M + R - 1) / R;
        out_shift <= osh; w_exp <= wev; x_exp <= xev;
      elsif tok(1 to 2) = "CB" then
        read(l, a); read(l, v);
        cb_addr <= std_logic_vector(to_unsigned(a, 4));
        cb_data <= std_logic_vector(to_signed(v, 8));
        cb_we <= '1'; wait until rising_edge(clk); cb_we <= '0';
      elsif tok(1 to 1) = "X" then
        read(l, a); hread(l, h16);
        xmem(a / BLK)((a mod BLK)*16+15 downto (a mod BLK)*16) <= h16;
      elsif tok(1 to 5) = "SCALE" then
        read(l, a); read(l, b); hread(l, h16); wscl(a, b) <= h16;
      elsif tok(1 to 3) = "IDX" then
        read(l, a); read(l, b); read(l, v); widx(a, b) <= v;
      elsif tok(1 to 7) = "PARTIAL" then
        read(l, a); read(l, b); hread(l, hv); e_part(a*nb_s + b) <= signed(hv);
      elsif tok(1 to 7) = "CONTRIB" then
        read(l, a); read(l, b); hread(l, hv); e_contrib(a*nb_s + b) <= signed(hv);
      elsif tok(1 to 3) = "ACC" then
        read(l, a); hread(l, hv); e_acc(a) <= signed(hv);
      elsif tok(1 to 5) = "YMANT" then
        read(l, a); hread(l, hv); e_ymant(a) <= signed(hv);
      elsif tok(1 to 2) = "NS" then
        read(l, a); e_ns <= a;
      elsif tok(1 to 4) = "YEXP" then
        read(l, a); e_yexp <= a;
      end if;
      wait for 0 ns;
    end loop;
    wait until rising_edge(clk);
    loaded <= true;
    wait;
  end process;

  -- ------------------------------------------------------------- stage check
  -- Lookup is BY INDEX, so it does not care that the pipeline retires stages in
  -- a different order than the reference computes them.
  chk : process(clk)
    variable want, g : signed(63 downto 0);
    variable base    : integer;
    variable nc, nb  : integer;
    variable nm      : integer;
  begin
    if rising_edge(clk) then
      nc := nchk; nb := nbad; nm := nmant;
      if tp_v = '1' then
        for rr in 0 to RI-1 loop
          base := tp_r + rr;
          if base < n_rows then          -- pad rows have no expectation
            want := e_part(base*nb_s + tp_b);
            g    := signed(tp_val(rr*64+63 downto rr*64));
            nc := nc + 1;
            if g /= want then
              nb := nb + 1;
              report "STAGE MISMATCH PARTIAL r=" & integer'image(base) &
                     " b=" & integer'image(tp_b) &
                     " got "  & integer'image(to_integer(resize(g, 32))) &
                     " want " & integer'image(to_integer(resize(want, 32)))
                     severity error;
            end if;
          end if;
        end loop;
      end if;

      if tc_v = '1' then
        for rr in 0 to RI-1 loop
          base := tc_r + rr;
          if base < n_rows then
            want := e_contrib(base*nb_s + tc_b);
            g    := signed(tc_val(rr*64+63 downto rr*64));
            nc := nc + 1;
            if g /= want then
              nb := nb + 1;
              report "STAGE MISMATCH CONTRIB r=" & integer'image(base) &
                     " b=" & integer'image(tc_b) &
                     " got "  & integer'image(to_integer(resize(g, 32))) &
                     " want " & integer'image(to_integer(resize(want, 32)))
                     severity error;
            end if;
          end if;
        end loop;
      end if;

      if ta_v = '1' then
        for rr in 0 to RI-1 loop
          base := ta_r + rr;
          if base < n_rows then
            want := e_acc(base);
            g    := signed(ta_val(rr*64+63 downto rr*64));
            nc := nc + 1;
            if g /= want then
              nb := nb + 1;
              report "STAGE MISMATCH ACC r=" & integer'image(base) &
                     " got "  & integer'image(to_integer(resize(g, 32))) &
                     " want " & integer'image(to_integer(resize(want, 32)))
                     severity error;
            end if;
          end if;
        end loop;
      end if;

      if tm_v = '1' then
        for rr in 0 to RI-1 loop
          base := tm_r + rr;
          if base < n_rows then
            nm := nm + 1;
            want := e_ymant(base);
            g    := signed(tm_val(rr*64+63 downto rr*64));
            nc := nc + 1;
            if g /= want then
              nb := nb + 1;
              report "STAGE MISMATCH YMANT r=" & integer'image(base) &
                     " got "  & integer'image(to_integer(resize(g, 32))) &
                     " want " & integer'image(to_integer(resize(want, 32)))
                     severity error;
            end if;
          end if;
        end loop;
      end if;
      nchk <= nc; nbad <= nb; nmant <= nm;
    end if;
  end process;

  -- ------------------------------------------------------------ stream feeder
  -- Emits the packer's tile-major word order (6.5): for tile t, for block b,
  -- lane rr holds row t*RI+rr.  Pad rows carry index 0 and scale 0, exactly as
  -- tools/pack_int4.py zero-fills them.
  feed : process
    variable lfsr : unsigned(15 downto 0) := x"ACE1";
    variable r    : integer;
  begin
    w_valid <= '0'; s_valid <= '0';
    wait until loaded;
    -- one feed per start pulse, so the driver can run several passes
    forever : loop
    loop
      wait until rising_edge(clk);
      exit when start = '1';
    end loop;
    for t in 0 to tiles_s-1 loop
      for b in 0 to nb_s-1 loop
        for rr in 0 to RI-1 loop
          r := t*RI + rr;
          for j in 0 to BLK-1 loop
            if r < n_rows then
              w_data((rr*BLK + j)*4+3 downto (rr*BLK + j)*4)
                <= std_logic_vector(to_unsigned(widx(r, b*BLK + j), 4));
            else
              w_data((rr*BLK + j)*4+3 downto (rr*BLK + j)*4) <= "0000";
            end if;
          end loop;
          if r < n_rows then s_data(rr*16+15 downto rr*16) <= wscl(r, b);
          else               s_data(rr*16+15 downto rr*16) <= x"0000"; end if;
        end loop;
        -- pseudo-random backpressure
        if STALL /= 0 then
          while (to_integer(lfsr) mod STALL) = 0 loop
            w_valid <= '0'; s_valid <= '0';
            wait until rising_edge(clk);
            lfsr := lfsr(14 downto 0) &
                    (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));
          end loop;
          lfsr := lfsr(14 downto 0) &
                  (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));
        end if;
        w_valid <= '1'; s_valid <= '1';
        loop
          wait until rising_edge(clk);
          exit when w_ready = '1';
        end loop;
      end loop;
    end loop;
    w_valid <= '0'; s_valid <= '0';
    end loop forever;
  end process;

  -- --------------------------------------------------------- output checking
  -- The TAPS could be right while the real output port is wrong, so y_data is
  -- checked independently: YMANT in BFP mode, and in PARTIAL mode the
  -- UNROUNDED s48 accumulator that 14.2 requires.  The first version of this
  -- core emitted sat32(round_shift(acc)) there and nothing noticed.
  ycap : process(clk)
    variable want, g : signed(63 downto 0);
    variable r       : integer;
    variable nc, nb  : integer;
  begin
    if rising_edge(clk) then
      nc := ychk; nb := ybad;
      if y_we = '1' then
        for rr in 0 to RI-1 loop
          if y_mask(rr) = '1' then
            r := to_integer(unsigned(y_addr)) + rr;
            if out_mode = "10" then want := e_acc(r);
            else                    want := e_ymant(r); end if;
            g := signed(y_data(rr*64+63 downto rr*64));
            nc := nc + 1;
            if g /= want then
              nb := nb + 1;
              report "Y MISMATCH mode=" & to_string(out_mode) &
                     " r=" & integer'image(r) &
                     " got "  & integer'image(to_integer(resize(g, 32))) &
                     " want " & integer'image(to_integer(resize(want, 32)))
                     severity error;
            end if;
          end if;
        end loop;
      end if;
      ychk <= nc; ybad <= nb;
    end if;
  end process;

  -- ------------------------------------------------------------------ driver
  drv : process
  begin
    rst <= '1'; wait for 40 ns;
    rst <= '0';                       -- release BEFORE loading, see loader
    wait until loaded;
    wait until rising_edge(clk);
    out_mode <= "00";
    start <= '1'; wait until rising_edge(clk); start <= '0';
    wait until done = '1';
    wait until rising_edge(clk);

    assert tap_ns = e_ns
      report "NS MISMATCH got " & integer'image(tap_ns) &
             " want " & integer'image(e_ns) severity error;
    assert y_exp = e_yexp
      report "YEXP MISMATCH got " & integer'image(y_exp) &
             " want " & integer'image(e_yexp) severity error;

    -- COVERAGE: a dropped tile still emits correct values for the tiles it does
    -- emit, so a value-only check passes.  Every row must be seen.
    assert nmant = n_rows
      report "COVERAGE: YMANT emitted for " & integer'image(nmant) &
             " rows, expected " & integer'image(n_rows) severity failure;
    report "BFP: " & integer'image(nchk) & " stage values compared, " &
           integer'image(nbad) & " mismatches, ns=" & integer'image(tap_ns) &
           " y_exp=" & integer'image(y_exp) severity note;
    assert nbad = 0 and tap_ns = e_ns and y_exp = e_yexp
      report "RTL DIVERGES FROM THE C REFERENCE" severity failure;
    -- PASS 2: partial mode.  Same weights, same activations; the output must
    -- now be the raw s48 accumulator, and the ACC tap must be unchanged.
    out_mode <= "10";
    wait until rising_edge(clk);
    start <= '1'; wait until rising_edge(clk); start <= '0';
    wait until done = '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);

    report "TOTAL: " & integer'image(nchk) & " stage + " &
           integer'image(ychk) & " output values compared, " &
           integer'image(nbad + ybad) & " mismatches (BFP and PARTIAL)"
           severity note;
    assert nbad = 0 and ybad = 0
      report "RTL DIVERGES FROM THE C REFERENCE" severity failure;
    assert ychk > 0 report "output port never checked" severity failure;
    report "RTL matches ref/matvec_int4.c at every stage" severity note;
    finished <= true;
    wait;
  end process;
end architecture;
