-- sim/tb_gdn_state_store.vhd -- the property the whole design rests on:
-- PER-LAYER RECURRENT STATE SURVIVES ACROSS TOKENS, THROUGH HBM.
--
-- `rtl/gdn_state_store.vhd` holds ONE GDN layer on-chip because all 24 are
-- 24.0 MB against 14.2 MB of BRAM plus URAM
-- (docs/debugging/2026-09-02_gdn-state-does-not-fit-on-chip.md).  Every layer
-- therefore evicts the previous one, 24 times per token.  The thing that can
-- silently go wrong is not the transfer -- `tb_gdn_state_axi` covers that --
-- it is the COMPOSITION: layer 3's state coming back as layer 2's, or as its
-- own value from the wrong token, in a design where every individual transfer
-- is correct.
--
-- SO THIS BENCH RUNS TOKENS, NOT TRANSFERS.  Token 0 walks the layers writing
-- a value that is a function of (layer, token) through the UNIT's port, the
-- way `gdn_block` would.  Token 1 walks them again, reads what token 0 left,
-- checks it, and writes token 1's value.  Token 2 checks token 1's.  A store
-- that loses a layer, swaps two, or returns a stale token fails; a store that
-- merely moves bytes correctly does not pass by accident.
--
-- THE INTERLEAVE IS THE POINT.  Between writing layer L and reading it back,
-- every OTHER layer has been loaded into and evicted from the same physical
-- URAM.  A design that kept state on-chip would pass this trivially and is
-- exactly what does not fit.
--
-- BOTH HALVES OF THE STATE, AND THEY ARE NOT THE SAME KIND OF MEMORY.  The
-- mantissas live in URAM with a REGISTERED read; the exponents live in
-- distributed RAM with a COMBINATIONAL one, because gdn_block consumes an
-- exponent on the same edge it drives the address.  They are moved by two
-- instances of the SAME mover over ONE shared pair of AXI masters, in
-- sequence, so the failure this bench is really hunting is a phase that
-- steals the other's handshake or writes the other's region of the arena.
-- Layer L's exponents sit at `base + L*stride + MANT_BYTES`, immediately
-- after its mantissas: an off-by-one-region address error is invisible at
-- layer 0 and corrupts every other layer.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.finish;

entity tb_gdn_state_store is
  generic(
    -- SHAPED SO THE EXPONENT PHASE IS MORE THAN ONE BURST.  The exponents are
    -- `VAL_HEADS*DIM` BYTES, so at the previous 2x8 shape they were 16 bytes
    -- against a 4-beat burst of 16-byte beats: BURSTS would round to zero and
    -- the mover's `bad_fewer_beats_than_one_burst` refusal would fire during
    -- elaboration.  Narrowing AXI_DW to 64 rather than widening the geometry
    -- keeps the mantissa side small: at 4x16 the exponents are 64 bytes = 8
    -- beats = 2 bursts, which also exercises the MAXOUT=2 bound on a phase
    -- short enough that a bug in it cannot hide behind the long one.
    VAL_HEADS   : positive := 4;
    DIM         : positive := 16;
    RECUR_LANES : positive := 2;
    LAYERS      : positive := 4;
    NTOK        : positive := 3;
    AXI_DW      : positive := 64;
    MAXB        : positive := 4;
    MAXOUT      : positive := 2;
    RD_LAT      : positive := 5;
    B_LAT       : natural  := 4
  );
end entity;

architecture sim of tb_gdn_state_store is
  constant NBR   : positive := DIM / RECUR_LANES;
  constant WORDS : positive := VAL_HEADS * DIM * NBR;
  constant WBITS : positive := RECUR_LANES * 16;
  constant WPB   : positive := AXI_DW / WBITS;
  constant BEATS : positive := WORDS / WPB;
  constant BPB   : positive := AXI_DW / 8;
  constant MANT_BYTES   : positive := BEATS * BPB;
  constant EXPN         : positive := VAL_HEADS * DIM;
  constant EXP_BYTES    : positive := EXPN;          -- one byte per entry
  constant EXP_BEATS    : positive := EXP_BYTES / BPB;
  -- A GAP AFTER THE EXPONENTS, ON PURPOSE.  `MANT_BYTES + EXP_BYTES` exactly
  -- would make "the end of layer L's exponents" and "the start of layer L+1"
  -- the same address, so a mover that ran one region too long would land on
  -- the next layer's data and be caught only by luck.  With a spare beat, an
  -- overrun writes a hole nothing reads and the CHECK is what catches it.
  constant LAYER_STRIDE : positive := MANT_BYTES + EXP_BYTES + BPB;
  constant ADDR_W : positive := 33;
  constant BASE   : natural := 8192;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  signal load_start, save_start : std_logic := '0';
  signal layer : integer range 0 to LAYERS-1 := 0;
  signal busy, dn, er : std_logic;

  signal st_ren, st_wen : std_logic := '0';
  signal st_rhead, st_whead : natural range 0 to VAL_HEADS-1 := 0;
  signal st_rcol,  st_wcol  : natural range 0 to DIM-1 := 0;
  signal st_rgrp,  st_wgrp  : natural range 0 to NBR-1 := 0;
  signal st_rdata : std_logic_vector(WBITS-1 downto 0);
  signal st_wdata : std_logic_vector(WBITS-1 downto 0) := (others => '0');

  signal se_rhead, se_whead : natural range 0 to VAL_HEADS-1 := 0;
  signal se_rcol,  se_wcol  : natural range 0 to DIM-1 := 0;
  signal se_rdata : signed(7 downto 0);
  signal se_wen   : std_logic := '0';
  signal se_wdata : signed(7 downto 0) := (others => '0');

  signal arvalid, arready, rvalid, rready, rlast : std_logic := '0';
  signal araddr : std_logic_vector(ADDR_W-1 downto 0);
  signal arlen  : std_logic_vector(7 downto 0);
  signal arsize : std_logic_vector(2 downto 0);
  signal arburst: std_logic_vector(1 downto 0);
  signal rdata  : std_logic_vector(AXI_DW-1 downto 0) := (others => '0');
  signal rresp  : std_logic_vector(1 downto 0) := "00";

  signal awvalid, awready, wvalid, wready, wlast : std_logic := '0';
  signal awaddr : std_logic_vector(ADDR_W-1 downto 0);
  signal awlen  : std_logic_vector(7 downto 0);
  signal awsize : std_logic_vector(2 downto 0);
  signal awburst: std_logic_vector(1 downto 0);
  signal wdata  : std_logic_vector(AXI_DW-1 downto 0);
  signal wstrb  : std_logic_vector(AXI_DW/8-1 downto 0);
  signal bvalid, bready : std_logic := '0';
  signal bresp  : std_logic_vector(1 downto 0) := "00";

  constant SLAVE_BEATS : positive := LAYERS * (LAYER_STRIDE / BPB)
                                    + BEATS + EXP_BEATS;
  type smem_t is array (0 to SLAVE_BEATS-1)
                 of std_logic_vector(AXI_DW-1 downto 0);
  -- Driven by the slave process ONLY; nothing else assigns it.  Two drivers
  -- on one resolved signal resolve rather than take turns, and it costs an
  -- afternoon (see docs/debugging/2026-09-02_gdn-state-dma.md, defect B2).
  signal smem : smem_t := (others => (others => '0'));

  signal n_chk, n_bad : natural := 0;
  signal n_stall : natural := 0;
  signal n_exp   : natural := 0;   -- exponent bytes actually checked

  -- the value layer L holds at token T, distinct in every 16-bit lane
  function val(L, T, i : natural) return std_logic_vector is
    variable v : std_logic_vector(WBITS-1 downto 0);
  begin
    for k in 0 to WBITS/16 - 1 loop
      v((k+1)*16-1 downto k*16) := std_logic_vector(to_unsigned(
        ((L*7919 + T*104729 + i*31 + k*613) mod 65536), 16));
    end loop;
    return v;
  end function;

  -- the exponent layer L holds at token T, entry i.  A DIFFERENT generator
  -- from `val`, deliberately: if both regions were filled from one function
  -- a mover that wrote the exponents over the mantissas' address range could
  -- still read back consistent-looking bytes.
  function eval(L, T, i : natural) return signed is
  begin
    return to_signed(((L*23 + T*57 + i*11 + 19) mod 256) - 128, 8);
  end function;
begin
  clk <= not clk after 5 ns;

  dut : entity work.gdn_state_store
    -- STYLE = "auto" HERE AND "ultra" ON THE CARD, AND THE DIFFERENCE IS NOT
    -- BEHAVIOURAL IN SIMULATION.  `ram_style` is a synthesis attribute; GHDL
    -- ignores it entirely, so this bench would run identically at "ultra".
    -- It is set to "auto" so the row does not read as though it were
    -- exercising the URAM configuration, WHICH IT IS NOT.
    --
    -- The one place that distinction could bite is recorded as an open item
    -- in docs/debugging/2026-09-02_gdn-state-does-not-fit-on-chip.md: URAM288
    -- read-during-write collision behaviour is not BRAM's, and no simulation
    -- here can settle it because GHDL's answer comes from VHDL signal
    -- semantics rather than from the primitive.
    generic map(VAL_HEADS => VAL_HEADS, DIM => DIM,
                RECUR_LANES => RECUR_LANES, LAYERS => LAYERS,
                STYLE => "auto",
                EXP_STYLE => "distributed",
                LAYER_STRIDE => LAYER_STRIDE, MANT_BYTES => MANT_BYTES,
                EXP_BYTES => EXP_BYTES,
                AXI_DW => AXI_DW, ADDR_W => ADDR_W,
                MAXB => MAXB, MAXOUT => MAXOUT)
    port map(clk => clk, rst => rst,
             load_start => load_start, save_start => save_start,
             layer => layer,
             state_base => std_logic_vector(to_unsigned(BASE, ADDR_W)),
             busy => busy, done => dn, err => er,
             st_ren => st_ren, st_rhead => st_rhead, st_rcol => st_rcol,
             st_rgrp => st_rgrp, st_rdata => st_rdata,
             st_wen => st_wen, st_whead => st_whead, st_wcol => st_wcol,
             st_wgrp => st_wgrp, st_wdata => st_wdata,
             se_rhead => se_rhead, se_rcol => se_rcol, se_rdata => se_rdata,
             se_wen => se_wen, se_whead => se_whead, se_wcol => se_wcol,
             se_wdata => se_wdata,
             r_arvalid => arvalid, r_arready => arready, r_araddr => araddr,
             r_arlen => arlen, r_arsize => arsize, r_arburst => arburst,
             r_rvalid => rvalid, r_rready => rready, r_rdata => rdata,
             r_rlast => rlast, r_rresp => rresp,
             w_awvalid => awvalid, w_awready => awready, w_awaddr => awaddr,
             w_awlen => awlen, w_awsize => awsize, w_awburst => awburst,
             w_wvalid => wvalid, w_wready => wready, w_wdata => wdata,
             w_wstrb => wstrb, w_wlast => wlast,
             w_bvalid => bvalid, w_bready => bready, w_bresp => bresp);

  -- ---- the AXI3 slave.  Same model as tb_gdn_state_axi. ----------------
  slave : process(clk) is
    type qent_t is record
      addr : natural; len : natural; age : natural; live : boolean;
    end record;
    type q_t is array (0 to 7) of qent_t;
    variable rq, wq : q_t := (others => (0,0,0,false));
    variable seed : unsigned(31 downto 0) := x"5EED1234";
    variable bpend, bage : natural := 0;
    variable head, tail, whead, wtail : natural := 0;
    impure function nxt return natural is
      variable t : unsigned(63 downto 0);
    begin
      t := seed * to_unsigned(1103515245, 32);
      seed := t(31 downto 0) + to_unsigned(12345, 32);
      seed := seed xor shift_right(seed, 15);
      return to_integer(seed(30 downto 0));
    end function;
  begin
    if rising_edge(clk) then
      arready <= '1' when (nxt mod 4) /= 0
                      and not rq((head + 1) mod 8).live else '0';
      awready <= '1' when (nxt mod 4) /= 0
                      and not wq((whead + 1) mod 8).live else '0';
      wready  <= '1' when (nxt mod 3) /= 0 else '0';
      if wvalid = '1' and wready = '0' then n_stall <= n_stall + 1; end if;

      if arvalid = '1' and arready = '1' then
        rq(head) := ((to_integer(unsigned(araddr)) - BASE) / BPB,
                     to_integer(unsigned(arlen)) + 1, 0, true);
        head := (head + 1) mod 8;
      end if;
      if rvalid = '1' and rready = '1' then
        if rq(tail).len = 1 then
          rq(tail).live := false; tail := (tail + 1) mod 8;
          rvalid <= '0'; rlast <= '0';
        else
          rq(tail).addr := rq(tail).addr + 1;
          rq(tail).len  := rq(tail).len - 1;
          rdata <= smem(rq(tail).addr);
          rlast <= '1' when rq(tail).len = 1 else '0';
        end if;
      elsif rvalid = '0' and rq(tail).live then
        if rq(tail).age < RD_LAT then rq(tail).age := rq(tail).age + 1;
        else
          rvalid <= '1'; rdata <= smem(rq(tail).addr);
          rlast <= '1' when rq(tail).len = 1 else '0';
        end if;
      end if;

      if awvalid = '1' and awready = '1' then
        wq(whead) := ((to_integer(unsigned(awaddr)) - BASE) / BPB,
                      to_integer(unsigned(awlen)) + 1, 0, true);
        whead := (whead + 1) mod 8;
      end if;
      if wvalid = '1' and wready = '1' then
        assert wq(wtail).live
          report "tb_gdn_state_store: W beat with no outstanding AW"
          severity failure;
        smem(wq(wtail).addr) <= wdata;
        if wq(wtail).len = 1 then
          assert wlast = '1' report "tb_gdn_state_store: burst without WLAST"
            severity failure;
          wq(wtail).live := false; wtail := (wtail + 1) mod 8;
          bpend := bpend + 1;
        else
          wq(wtail).addr := wq(wtail).addr + 1;
          wq(wtail).len  := wq(wtail).len - 1;
        end if;
      end if;
      if bvalid = '1' and bready = '1' then
        bvalid <= '0'; bpend := bpend - 1; bage := 0;
      elsif bvalid = '0' and bpend > 0 then
        if bage < B_LAT then bage := bage + 1; else bvalid <= '1'; end if;
      end if;

      if rst = '1' then
        rq := (others => (0,0,0,false));
        wq := (others => (0,0,0,false));
        head := 0; tail := 0; whead := 0; wtail := 0;
        bpend := 0; bage := 0;
        rvalid <= '0'; rlast <= '0'; bvalid <= '0';
      end if;
    end if;
  end process;

  -- ---- the stimulus: tokens, each walking every layer -------------------
  stim : process is
    procedure tick(n : natural := 1) is
    begin
      for i in 1 to n loop wait until rising_edge(clk); end loop;
    end procedure;

    -- WAIT ON `done`.  `busy` does not rise on the start edge; see
    -- docs/debugging/2026-09-02_gdn-state-dma.md, defect B1.
    procedure wait_done is
      variable n : natural := 0;
    begin
      loop
        wait until rising_edge(clk);
        exit when dn = '1';
        n := n + 1;
        assert n < 200 * BEATS + 5000
          report "tb_gdn_state_store: FAIL, the mover never asserted `done`."
          severity failure;
      end loop;
    end procedure;

    procedure chk(cond : boolean; msg : string) is
    begin
      n_chk <= n_chk + 1;
      if not cond then
        n_bad <= n_bad + 1;
        report "tb_gdn_state_store: " & msg severity error;
      end if;
      wait for 0 ns;
    end procedure;

    -- the unit's own port, addressed the way gdn_block addresses it
    procedure unit_write(i : natural; d : std_logic_vector) is
    begin
      st_wen   <= '1';
      st_whead <= i / (DIM*NBR);
      st_wcol  <= (i / NBR) mod DIM;
      st_wgrp  <= i mod NBR;
      st_wdata <= d;
      tick;
      st_wen <= '0';
    end procedure;

    procedure unit_read(i : natural) is
    begin
      st_ren   <= '1';
      st_rhead <= i / (DIM*NBR);
      st_rcol  <= (i / NBR) mod DIM;
      st_rgrp  <= i mod NBR;
      tick;
      st_ren <= '0';
      tick;   -- registered read: the data is valid on the second edge
    end procedure;

    -- the exponent port.  Same shape as gdn_block's se_*, including the
    -- absence of a read enable: the read is COMBINATIONAL and there is
    -- nothing to enable.
    procedure unit_ewrite(i : natural; d : signed) is
    begin
      se_wen   <= '1';
      se_whead <= i / DIM;
      se_wcol  <= i mod DIM;
      se_wdata <= d;
      tick;
      se_wen <= '0';
    end procedure;

    -- NO RISING EDGE between driving the address and checking the data.  If
    -- there were one, the check would pass against a REGISTERED exponent
    -- memory, which is the one memory gdn_block cannot use (see the
    -- rtl/gdn_exp_mem.vhd header).
    --
    -- POSITIONED AT A FALLING EDGE AND THEN WAITING A REAL 1 ns, rather than
    -- counting `wait for 0 ns`.  A fixed delta count encodes a private detail
    -- of the DUT's internal wiring -- how many concurrent assignments the
    -- signal passes through on its way out -- so adding one relay inside the
    -- DUT silently shifts every read by one address.  MEASURED: that is
    -- exactly what happened here, and it read as a mover bug until a probe
    -- showed the unit port was already wrong BEFORE any DMA ran.  Half a
    -- clock period is unambiguous and survives any internal rewiring.
    procedure unit_eread(i : natural) is
    begin
      wait until falling_edge(clk);
      se_rhead <= i / DIM;
      se_rcol  <= i mod DIM;
      wait for 1 ns;
    end procedure;
  begin
    rst <= '1'; tick(4); rst <= '0'; tick(2);

    for T in 0 to NTOK-1 loop
      for L in 0 to LAYERS-1 loop
        layer <= L; tick;
        load_start <= '1'; tick; load_start <= '0';
        wait_done;
        chk(er = '0', "err after LOAD, token " & integer'image(T)
                    & " layer " & integer'image(L));

        -- Token 0 has nothing to check: HBM starts zeroed and that is what a
        -- real sequence start means.  From token 1 the layer MUST hold what
        -- this bench wrote to it on the previous token, which is only true if
        -- it survived being evicted by every other layer in between.
        if T > 0 then
          for i in 0 to WORDS-1 loop
            unit_read(i);
            chk(st_rdata = val(L, T-1, i),
                "token " & integer'image(T) & " layer " & integer'image(L)
                & " word " & integer'image(i) & " lost its state: got "
                & to_hstring(st_rdata) & " want "
                & to_hstring(val(L, T-1, i)));
          end loop;
        end if;

        -- The exponents, same rule: token 0 seeds, later tokens must find
        -- what the previous one left after every other layer has passed
        -- through the same distributed RAM.
        if T > 0 then
          for i in 0 to EXPN-1 loop
            unit_eread(i);
            n_exp <= n_exp + 1;
            chk(se_rdata = eval(L, T-1, i),
                "token " & integer'image(T) & " layer " & integer'image(L)
                & " exponent " & integer'image(i) & " lost its state: got "
                & integer'image(to_integer(se_rdata)) & " want "
                & integer'image(to_integer(eval(L, T-1, i))));
          end loop;
        end if;

        for i in 0 to WORDS-1 loop
          unit_write(i, val(L, T, i));
        end loop;
        for i in 0 to EXPN-1 loop
          unit_ewrite(i, eval(L, T, i));
        end loop;

        save_start <= '1'; tick; save_start <= '0';
        wait_done;
        chk(er = '0', "err after SAVE, token " & integer'image(T)
                    & " layer " & integer'image(L));
      end loop;
    end loop;

    tick(4);
    report "tb_gdn_state_store: checks=" & integer'image(n_chk)
         & " bad=" & integer'image(n_bad)
         & " tokens=" & integer'image(NTOK)
         & " layers=" & integer'image(LAYERS)
         & " exponent bytes=" & integer'image(n_exp)
         & " W stalls=" & integer'image(n_stall) severity note;

    -- A run that never reached token 1 checked no persistence at all.
    assert NTOK >= 2
      report "tb_gdn_state_store: FAIL, NTOK < 2 checks nothing."
      severity failure;
    assert n_stall > 0
      report "tb_gdn_state_store: FAIL, the slave never stalled."
      severity failure;
    -- The exponent phase is 0.39% of the traffic and 50% of the state's
    -- correctness.  A run that moved only mantissas and still said PASS is
    -- the exact failure this assertion exists to prevent.
    assert n_exp > 0
      report "tb_gdn_state_store: FAIL, no exponent was ever checked, so the "
           & "second phase of every transfer is UNTESTED."
      severity failure;

    if n_bad = 0 then
      report "tb_gdn_state_store RESULT: PASS -- " & integer'image(n_chk)
           & " checks, of which " & integer'image(n_exp)
           & " exponents; every layer's mantissas AND exponents survived "
           & integer'image(LAYERS-1)
           & " evictions per token across " & integer'image(NTOK)
           & " tokens." severity note;
    else
      report "tb_gdn_state_store RESULT: FAIL -- " & integer'image(n_bad)
           & " of " & integer'image(n_chk) severity error;
    end if;
    finish;
  end process;
end architecture;
