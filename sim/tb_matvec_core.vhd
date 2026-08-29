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
--
-- ALL THREE out_mode VALUES ARE DRIVEN HERE, and all three are compared against
-- ref/matvec_int4.c rather than against each other (spec 7.6's mode table):
--
--   "00" BFP      int32 into ybuf, then one shared ns over all n_rows and an
--                 int16 mantissa out.  y_exp = w_exp + x_exp - out_shift - ns.
--                 n_rows <= MAXROWS_BFP is ENFORCED by the core.
--   "01" raw      no buffering; sat32(round_shift(acc, out_shift)) straight
--                 out of row end, sign-extended to 64.  y_exp carries no ns
--                 term.  n_rows > MAXROWS_BFP is LEGAL (nothing is buffered).
--   "10" partial  no buffering, no requant and no sat32 at all: the UNROUNDED
--                 s48 accumulator, y_exp = w_exp + x_exp (14.2).
--                 n_rows > MAXROWS_BFP is legal here too.
--
-- The raw-mode expectation needed NO new vector: ref/matvec_int4.c writes a
-- YDATA line inside mv4i_matvec on every non-partial pass, and that value IS
-- the raw payload.  The loader was throwing the line away.

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
  -- 32, not 16: the adversarial sat vector needs NB > 16 to push acc past
  -- 2^31 at all (each block contributes ~1.33e8, so 16 blocks reach 2.13e9,
  -- just UNDER the s32 limit and nothing saturates).  K=1024 gives NB=32.
  constant MAXB : positive := 32;

  signal clk   : std_logic := '0';
  signal rst   : std_logic := '1';
  signal start : std_logic := '0';

  signal n_cols, out_shift, w_exp, x_exp, y_exp : integer := 0;
  -- n_rows and tiles_s have TWO sources -- the trace's DIMS line, and the
  -- shape-override passes below -- and a signal may have only one driver, so
  -- the loader writes the _tr pair and the driver only writes ov_rows.
  -- ov_rows = 0 means "use the trace's own M"; any other value overrides it,
  -- which is how the top-of-range and above-the-range passes are shaped
  -- without a second trace.
  signal n_rows_tr, tiles_tr : integer := 0;
  signal ov_rows : integer := 0;
  signal n_rows, tiles_s : integer;
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

  -- xmem IS POISONED, NOT ZEROED, AND THAT IS LOAD-BEARING.
  --
  -- The trace emits an `X k <value>` line only for k < K, so with the old
  -- `(others => '0')` default every PAD column -- the lanes of the last scale
  -- block at k >= n_cols -- carried a ZERO ACTIVATION.  Spec 6.2's COLUMN
  -- MASK (`if k < n_cols` in rtl/matvec_core.vhd) exists precisely because
  -- the IQ4_NL codebook has NO zero entry: index 0 decodes to -127, so a pad
  -- column that is not masked contributes cb(0) * x(k), which is nonzero
  -- ONLY IF x(k) is.  With a zero default the mask was multiplying a zero by
  -- a nonzero and removing it changed nothing, so the mask was UNTESTABLE by
  -- any trace shape.
  --
  -- MEASURED, sim/mutate_matvec_core.sh before this changed: mutations D1
  -- ("the column mask is removed") and D2 ("k <= n_cols") BOTH SURVIVED all
  -- three traces, including the 6x100 trace whose last block carries 28 pad
  -- columns.  With the poison below both are killed on every trace that has
  -- a pad column at all.
  --
  -- Zero was also the WRONG model of the hardware.  x comes from
  -- act_mem_striped, a plain RAM that nothing clears between operations, so
  -- in a real build the tail of the last block holds whatever the previous
  -- layer left there.  Poison is the honest stand-in for that; zero quietly
  -- assumed the one value that makes the defect invisible.
  --
  -- The pattern is per-block and per-lane so that a lane- or block-ordering
  -- error in the pad region is distinguishable from a magnitude error.  The
  -- magnitude is bounded on purpose: the worst case an unmasked block can
  -- reach is 127 * 5646 * 32 = 2.29e7, inside the s28 partial the contract
  -- allows (2^27 = 1.34e8), so a mutation that breaks the mask produces a
  -- WRONG NUMBER the checker compares, not a bound-check abort that tells
  -- us less.
  --
  -- Rows at and above the trace's M are unaffected: their scales are zero, so
  -- sprod is zero whatever the activations are.
  function xpoison return xm_t is
    variable r : xm_t;
  begin
    for b in 0 to MAXB-1 loop
      for j in 0 to BLK-1 loop
        r(b)(j*16+15 downto j*16) :=
          std_logic_vector(to_signed(4096 + 37*b + 13*j, 16));
      end loop;
    end loop;
    return r;
  end function;
  signal xmem : xm_t  := xpoison;

  -- expectations
  type exp_t is array(0 to MAXR*MAXB-1) of signed(63 downto 0);
  type row_t is array(0 to MAXR-1)      of signed(63 downto 0);
  signal e_part, e_contrib : exp_t := (others => (others => '0'));
  signal e_acc, e_ymant    : row_t := (others => (others => '0'));
  -- The RAW-mode payload: sat32(round_shift(acc, out_shift)), sign-extended.
  -- Same line the BFP pass consumes as its pre-normalisation intermediate, so
  -- one trace serves both modes.
  signal e_ydata           : row_t := (others => (others => '0'));
  signal e_ns, e_yexp, nb_s, ri_s : integer := 0;
  -- expected sticky sat_event for the BFP pass, from the trace.  -1 means
  -- the trace predates SATEV, in which case the check is skipped rather
  -- than silently comparing against a default.
  signal e_satev : integer := -1;

  signal loaded : boolean := false;
  signal nbad, nchk : integer := 0;
  signal nmant : integer := 0;   -- rows actually emitted, for coverage
  signal nemit  : integer := 0;  -- y_mask'd rows out of the port, UNGATED
  signal nm_top : integer := 0;  -- nemit as it stood entering PASS 3
  signal yb3    : integer := 0;  -- ychk as it stood entering PASS 4
  signal ybad, ychk : integer := 0;   -- own counters: one driver per signal
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

  -- THE SHAPE OVERRIDE.  n_rows = MAXR makes ceil(n_rows / RI) equal the
  -- core's own TILES = ceil(MAXROWS_BFP / RI) exactly, at every RI, which is
  -- the shape the emit pointer walks one word past (PASS 3).  n_rows > MAXR is
  -- illegal in BFP mode and LEGAL in raw and partial, which is the shape the
  -- ybuf WRITE walks past the end of (PASS 8, worklog OI-10).
  n_rows  <= ov_rows                  when ov_rows /= 0 else n_rows_tr;
  tiles_s <= (ov_rows + RI - 1) / RI  when ov_rows /= 0 else tiles_tr;

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
        n_rows_tr <= M; n_cols <= K; nb_s <= NB; ri_s <= R;
        tiles_tr <= (M + R - 1) / R;
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
      elsif tok(1 to 5) = "YDATA" then
        -- the raw-mode payload, and the BFP pass's own pre-ns intermediate
        read(l, a); hread(l, hv); e_ydata(a) <= signed(hv);
      elsif tok(1 to 2) = "NS" then
        read(l, a); e_ns <= a;
      elsif tok(1 to 4) = "YEXP" then
        read(l, a); e_yexp <= a;
      elsif tok(1 to 5) = "SATEV" then
        read(l, a); e_satev <= a;
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
          if base < n_rows_tr then          -- pad rows have no expectation
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
          if base < n_rows_tr then
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
          if base < n_rows_tr then
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
          if base < n_rows_tr then
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
          -- `r < MAXR` as well as `r < n_rows`: PASS 8 drives n_rows ABOVE the
          -- core's MAXROWS_BFP, which raw mode admits, and widx/wscl are only
          -- MAXR deep.  Rows the trace never described are fed index 0 with
          -- SCALE 0 -- the same zero-fill the packer applies to pad rows -- so
          -- their contribution is identically zero and the checker below knows
          -- to expect zero rather than nothing.
          for j in 0 to BLK-1 loop
            if r < n_rows and r < MAXR then
              w_data((rr*BLK + j)*4+3 downto (rr*BLK + j)*4)
                <= std_logic_vector(to_unsigned(widx(r, b*BLK + j), 4));
            else
              w_data((rr*BLK + j)*4+3 downto (rr*BLK + j)*4) <= "0000";
            end if;
          end loop;
          if r < n_rows and r < MAXR then
                             s_data(rr*16+15 downto rr*16) <= wscl(r, b);
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
    variable nc, nb, ne : integer;
  begin
    if rising_edge(clk) then
      nc := ychk; nb := ybad; ne := nemit;
      if y_we = '1' then
        for rr in 0 to RI-1 loop
          if y_mask(rr) = '1' then
            -- Counted BEFORE the expectation gate: PASS 3 raises n_rows above
            -- anything the trace scored, and the property that pass turns on
            -- is that every row still comes OUT.  A counter that only ticked
            -- where an expectation exists could not see a dropped tile there.
            ne := ne + 1;
            r := to_integer(unsigned(y_addr)) + rr;
            -- EVERY masked row carries an expectation now, including the ones
            -- above the trace's own M.  The feeder gives those rows index 0
            -- and SCALE 0, so acc is identically zero and the expected output
            -- is zero in all three modes.  The previous version skipped them,
            -- which is why the passes that raise n_rows above the trace shape
            -- scored a row COUNT and no values at all -- exactly the hole
            -- TRACK DIVIDE's mutation M3 walked through, where the only
            -- value-checking case ran at one shape and the shape sweep checked
            -- completion.
            if r < n_rows_tr then
              if    out_mode = "10" then want := e_acc(r);
              elsif out_mode = "01" then want := e_ydata(r);
              else                       want := e_ymant(r); end if;
            else
              want := (others => '0');
            end if;
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
      ychk <= nc; ybad <= nb; nemit <= ne;
    end if;
  end process;

  -- ------------------------------------------------------------------ driver
  drv : process
    -- One operation, with the shape and the mode named, plus the two checks
    -- that are the same in every mode: the descriptor was accepted, and every
    -- row it asked for came OUT.  The VALUES are scored by ycap/chk above and
    -- reported in aggregate at the end.
    --
    -- The row COUNT is not decoration.  A dropped tile emits correct values
    -- for the tiles it does emit, so a value-only check passes on it; and a
    -- HANG scores as an acceptance on any check that only reads `err` after a
    -- bounded poll (worklog OI-11).  Here a hang cannot score at all: the pass
    -- blocks on `done`, so the run simply never reaches its report.
    procedure run_pass(constant mode : in std_logic_vector(1 downto 0);
                       constant rows : in integer;    -- 0 = the trace's own M
                       constant tag  : in string) is
      variable ne0 : integer;
    begin
      out_mode <= mode;
      ov_rows  <= rows;
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      -- Named on entry, not only on failure.  These passes deliberately drive
      -- shapes that ABORT the simulator on unfixed RTL, and an abort prints no
      -- context of its own: without this line the log shows PASS 1's note and
      -- then a bare index error, and which pass reached the defect has to be
      -- bisected by deleting passes.
      report tag & ": out_mode=" & to_string(mode) & " n_rows=" &
             integer'image(n_rows) severity note;
      ne0 := nemit;
      start <= '1'; wait until rising_edge(clk); start <= '0';
      wait until done = '1';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      assert err = '0'
        report tag & ": err fired on a descriptor spec 7.6 admits (n_rows = "
               & integer'image(n_rows) & ", out_mode = " & to_string(mode)
               & ")" severity failure;
      assert nemit - ne0 = n_rows
        report tag & " COVERAGE: " & integer'image(nemit - ne0) &
               " rows out of the port, expected " & integer'image(n_rows) &
               " -- a tile went missing rather than wrong" severity failure;
      -- The exponent each mode owes, from spec 7.6's mode table and 14.2,
      -- computed from the trace's own DIMS rather than from the BFP answer.
      if mode = "01" then
        assert y_exp = w_exp + x_exp - out_shift
          report tag & ": RAW y_exp got " & integer'image(y_exp) & " want " &
                 integer'image(w_exp + x_exp - out_shift) &
                 " -- raw carries out_shift and NO ns term" severity failure;
      elsif mode = "10" then
        assert y_exp = w_exp + x_exp
          report tag & ": PARTIAL y_exp got " & integer'image(y_exp) & " want "
                 & integer'image(w_exp + x_exp) &
                 " -- 14.2: the payload was never shifted" severity failure;
      end if;
    end procedure;
    -- nemit as it stood entering PASS 9, so that pass can assert NOTHING was
    -- emitted without depending on the absolute count of everything before it.
    variable ne_p9 : integer;
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

    -- 14.2: the sticky flag is normative output, not debug.  It was wired
    -- through this testbench from the start and never compared.
    assert e_satev < 0
        or (e_satev = 1 and sat_event = '1')
        or (e_satev = 0 and sat_event = '0')
      report "SAT_EVENT MISMATCH (BFP) got " & std_logic'image(sat_event) &
             " want " & integer'image(e_satev) severity failure;

    -- COVERAGE: a dropped tile still emits correct values for the tiles it does
    -- emit, so a value-only check passes.  Every row must be seen.
    assert nmant = n_rows
      report "COVERAGE: YMANT emitted for " & integer'image(nmant) &
             " rows, expected " & integer'image(n_rows) severity failure;
    -- COVERAGE ON THE PORT, not only on the tap.  nmant counts the tm_val
    -- STAGE TAP, which is NOT gated by y_mask, so a corrupted emit mask is
    -- invisible to it.  nemit counts rows that left the PORT with y_mask set,
    -- which is what a consumer actually sees.
    --
    -- MEASURED: mutation B13 of sim/mutate_matvec_core.sh -- "the emit y_mask
    -- admits one pad row", rbase + rr <= n_rows -- SURVIVED all three traces
    -- with only the nmant check present.  Two things hid it, and both are
    -- properties of the stimulus rather than of the checker: the extra row
    -- carries ZERO, so it compares equal to the zero expectation and no value
    -- check can see it; and the run_pass COVERAGE assert that WOULD have
    -- caught it runs only in the RAW and PARTIAL passes.  PASS 3 cannot catch
    -- it either -- n_rows = MAXR = 64 is tile-aligned at RI = 4, so rbase + rr
    -- never reaches n_rows.  It takes a RAGGED BFP tile, which is exactly what
    -- a trace whose M is not a multiple of RI supplies.
    assert nemit = n_rows
      report "COVERAGE: y_mask admitted " & integer'image(nemit) &
             " rows out of the PORT, expected " & integer'image(n_rows) &
             " -- the emit mask is wrong, and a pad row's payload is zero so "
           & "no value check can see it" severity failure;
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

    -- 14.2: PARTIAL applies no requant and no saturation, so sat_event must be
    -- clear here even on a vector that saturates every row in BFP mode.  This
    -- is INVARIANT, so it needs no expectation from the trace.  The core used
    -- to compute sat32 unconditionally and report the flag from a value this
    -- mode discards, which would make subsystem E reject good partials in
    -- precisely the cancellation cases where a K-slice legitimately exceeds
    -- the full-K result.
    assert sat_event = '0'
      report "SAT_EVENT SET IN PARTIAL MODE: 14.2 runs no sat32 on this path"
      severity failure;

    -- ---------------------------------------------------------------------
    -- PASS 3: THE TOP OF THE ROW RANGE.  The trace shapes are all well below
    -- MAXROWS_BFP, so nothing above ever exercised the LAST tile the core can
    -- hold, and that is precisely where the emit pointer overruns: S_EMIT
    -- advances rd_t to tiles_r and stops, and tiles_r = TILES exactly when
    -- n_rows lands in the top RI rows of MAXROWS_BFP.  The core then read
    -- ybuf(TILES) on its final emit cycle -- harmless in hardware, since rd_v
    -- is '0' and nothing consumes the word, and an immediate abort in
    -- simulation.  MEASURED before the fix at MAXR=64/RI=4, n_rows = 61 and
    -- 64: "index (16) out of bounds (0 to 15) at rtl/matvec_core.vhd:835".
    -- Worklog OI-8.
    --
    -- The stimulus needs no new trace.  Rows at and above the trace's M carry
    -- index 0 and SCALE 0, exactly as the feeder already zero-fills pad rows,
    -- so their contribution is identically zero: acc, amax, ns and y_exp are
    -- all unchanged from PASS 1, and e_acc/e_ymant are zero there too.  So the
    -- existing checkers score this pass as well, and the assertions below are
    -- the ones that would notice a tile going missing rather than wrong.
    ov_rows  <= MAXR;
    out_mode <= "00";
    wait until rising_edge(clk);
    nm_top <= nemit;
    wait until rising_edge(clk);
    start <= '1'; wait until rising_edge(clk); start <= '0';
    wait until done = '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);

    assert err = '0'
      report "TOP OF RANGE: err fired at n_rows = MAXROWS_BFP, which 7.6 "
             & "admits" severity failure;
    assert nemit - nm_top = MAXR
      report "TOP OF RANGE COVERAGE: y_data emitted for " &
             integer'image(nemit - nm_top) & " rows, expected " &
             integer'image(MAXR) & " -- the last tile was dropped, not wrong"
      severity failure;
    -- The pad tiles contribute zero, so neither the shared shift nor the
    -- exponent may move.  A core that let them into the magnitude scan would
    -- change ns here and nowhere else.
    assert tap_ns = e_ns and y_exp = e_yexp
      report "TOP OF RANGE: ns/y_exp moved when the row count was raised to "
             & "MAXROWS_BFP -- got ns=" & integer'image(tap_ns) & " y_exp="
             & integer'image(y_exp) & ", want ns=" & integer'image(e_ns)
             & " y_exp=" & integer'image(e_yexp) severity failure;
    ov_rows <= 0;
    yb3 <= ychk;

    -- ---------------------------------------------------------------------
    -- PASS 4: RAW MODE, AGAINST THE REFERENCE.
    --
    -- out_mode = "01" emits sat32(round_shift(acc, out_shift)) straight out of
    -- row end with no BFP normalisation, which is EXACTLY the YDATA line
    -- ref/matvec_int4.c already writes inside mv4i_matvec.  So the oracle for
    -- this mode was in the trace file the whole time and the loader was
    -- dropping the line.
    --
    -- WHAT DROVE THIS MODE BEFORE, and why it is not an oracle: exactly one
    -- bench in the tree, sim/tb_matvec_cb_lockstep, at one tile of ROWS_IF
    -- rows.  It compares four runs AGAINST EACH OTHER (same codebook twice, a
    -- different codebook, then the first one back) and never against the C
    -- reference at all -- by design, it is testing codebook visibility.  A
    -- round trip is not an oracle: a raw path that computed a consistently
    -- wrong number would pass all four of its comparisons.
    run_pass("01", 0, "PASS 4 RAW");
    -- raw runs the SAME sat32 as BFP -- 14.2 exempts only partial -- so the
    -- sticky flag must agree with the reference's BFP-pass value.
    assert e_satev < 0
        or (e_satev = 1 and sat_event = '1')
        or (e_satev = 0 and sat_event = '0')
      report "PASS 4 RAW: SAT_EVENT got " & std_logic'image(sat_event) &
             " want " & integer'image(e_satev) & " -- raw applies sat32"
      severity failure;
    assert ychk > yb3
      report "PASS 4 RAW: not one output value was compared" severity failure;

    -- PASS 5 and 6: RAW at the TILE BOUNDARY, with VALUES checked.
    --
    -- n_rows = MAXR - RI + 1 gives a RAGGED last tile (one real row, RI-1 pad)
    -- at tiles_r = TILES; n_rows = MAXR gives a FULL last tile at the same
    -- tiles_r.  Both are the top corner of the declared range, and rows at and
    -- above the trace's M are scored against zero rather than skipped, so
    -- these are value checks and not merely completion checks.  That
    -- distinction is the one TRACK DIVIDE's mutation M3 exploited: it was
    -- wrong only at n_rows = 49/97/145, the shape sweep ran those shapes, and
    -- the sweep checked only that the job completed.
    run_pass("01", MAXR - RI + 1, "PASS 5 RAW ragged top tile");
    run_pass("01", MAXR,          "PASS 6 RAW full top tile");

    -- ---------------------------------------------------------------------
    -- PASS 7: PARTIAL ABOVE MAXROWS_BFP.  THE CONTROL FOR PASS 8.
    --
    -- Spec 7.6's mode table: "n_rows > MAXROWS_BFP is legal in partial mode
    -- (no output buffer is used)", and the core agrees -- S_IDLE bounds n_rows
    -- against MAXROWS_BFP only when out_mode = "00".  Partial is the mode that
    -- takes the SAME illegal-for-BFP row count and does NOT write ybuf, so it
    -- separates "anything above MAXROWS_BFP breaks" from "the ybuf write
    -- breaks".  Without it PASS 8 would not localize.
    run_pass("10", MAXR + 1, "PASS 7 PARTIAL above MAXROWS_BFP");
    assert sat_event = '0'
      report "PASS 7: SAT_EVENT SET IN PARTIAL MODE: 14.2 runs no sat32"
      severity failure;

    -- ---------------------------------------------------------------------
    -- PASS 8: RAW ABOVE MAXROWS_BFP.  WORKLOG OI-10.
    --
    -- Same row count as PASS 7, one mode over.  Raw is equally legal above
    -- MAXROWS_BFP -- 7.6 says "in raw mode M may exceed MAXROWS_BFP" and the
    -- lm_head is the caller that needs it -- but the row-end stage wrote
    -- `ybuf(re2_t)` on every mode except partial, and ybuf is only
    -- ceil(MAXROWS_BFP / RI) tiles deep.  So a raw job one row past the BFP
    -- bound indexed one tile past the array.
    --
    -- MEASURED before the fix at MAXR=64 / RI=4 (TILES=16), n_rows = 65:
    --   ghdl: index (16) out of bounds (0 to 15) at rtl/matvec_core.vhd:839
    -- with PASS 7 -- the same 65 rows in partial mode -- passing immediately
    -- before it.  Same family as OI-8 and the opposite side of the same
    -- buffer: OI-8 was the READ walking one past on the last emit cycle.
    --
    -- Synthesis-benign for the same reason OI-8 was: nothing ever reads ybuf
    -- in raw mode, because S_EMIT is reachable only through S_SCAN and only
    -- out_mode = "00" goes there.  Simulation-fatal, and fatal on the ONE
    -- descriptor the lm_head is supposed to issue.
    run_pass("01", MAXR + 1, "PASS 8 RAW above MAXROWS_BFP");

    -- ---------------------------------------------------------------------
    -- PASS 9: BFP ABOVE MAXROWS_BFP MUST BE REFUSED.  The mirror of PASS 8,
    -- and the ONLY pass here that expects `err` to go HIGH.
    --
    -- Spec 7.6's mode table admits n_rows > MAXROWS_BFP in raw and partial
    -- and FORBIDS it in BFP, because ybuf is only ceil(MAXROWS_BFP/ROWS_IF)
    -- tiles deep and BFP is the one mode that writes and reads it.  S_IDLE
    -- therefore has to REJECT the descriptor.  Every other pass in this file
    -- asserts that err stays LOW, so until this pass existed NOTHING checked
    -- that it ever goes high -- the guard on a buffer overrun was itself
    -- unguarded.
    --
    -- MEASURED: mutation I1 of sim/mutate_matvec_core.sh, which deletes the
    -- BFP row bound from the S_IDLE check, SURVIVED all three traces before
    -- this pass existed.  PASS 8 does not cover it: 7.6 makes that same row
    -- count LEGAL in raw, so PASS 8 proves the opposite property.
    --
    -- Two things are checked, not one.  A rejection that still emitted rows
    -- would be a rejection in name only, and an err that fired while the core
    -- also ran the job is worse than either alone.
    ne_p9 := nemit;
    out_mode <= "00";
    ov_rows  <= MAXR + 1;
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    report "PASS 9 BFP above MAXROWS_BFP must be REFUSED: out_mode=00 n_rows="
           & integer'image(n_rows) severity note;
    start <= '1'; wait until rising_edge(clk); start <= '0';
    wait until done = '1';
    wait until rising_edge(clk);
    assert err = '1'
      report "PASS 9: BFP at n_rows = " & integer'image(n_rows) & " > "
           & "MAXROWS_BFP was ACCEPTED.  7.6 forbids it, and ybuf is only "
           & "ceil(MAXROWS_BFP/ROWS_IF) tiles deep, so the job walks the "
           & "output buffer off its end." severity failure;
    assert nemit = ne_p9
      report "PASS 9: the descriptor was refused but " &
             integer'image(nemit - ne_p9) & " rows still left the port"
      severity failure;

    report "TOTAL: " & integer'image(nchk) & " stage + " &
           integer'image(ychk) & " output values compared, " &
           integer'image(nbad + ybad) & " mismatches (BFP, PARTIAL, RAW, the "
           & "top of the row range at n_rows = " & integer'image(MAXR) &
           " and both no-buffer modes above it at n_rows = " &
           integer'image(MAXR + 1) & ")" severity note;
    assert nbad = 0 and ybad = 0
      report "RTL DIVERGES FROM THE C REFERENCE" severity failure;
    assert ychk > 0 report "output port never checked" severity failure;
    report "RTL matches ref/matvec_int4.c at every stage, in all three "
           & "out_mode values" severity note;
    finished <= true;
    wait;
  end process;
end architecture;
