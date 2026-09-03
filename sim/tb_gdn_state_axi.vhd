-- sim/tb_gdn_state_axi.vhd -- `rtl/gdn_state_axi.vhd` against a behavioural
-- AXI3 slave and a real `gdn_state_mem`.
--
-- THE ORACLE IS A ROUND TRIP THROUGH TWO INDEPENDENT STORES, WHICH IS NOT THE
-- SAME AS A SELF-TEST.  The bench writes a known pattern into HBM, LOADS it
-- into `gdn_state_mem` through the DUT, reads the store back through its own
-- port and compares against the pattern; then it writes a DIFFERENT pattern
-- into the store, SAVES it, and compares the slave's memory against that.
-- Neither direction is checked by replaying the other, and the two patterns
-- differ so that a save which never ran cannot be mistaken for one that did.
--
-- WHY THAT MATTERS HERE.  A DMA that byte-swaps, that drops the last word of
-- every beat, or that addresses the store transposed will still round-trip
-- perfectly if you load and then immediately save without looking.  The first
-- draft of the DUT DID drop the last word of every beat -- one index where
-- two were needed, because the store's read is registered -- and a
-- load-then-save comparison would have passed it.
--
-- THE SLAVE IS DELIBERATELY AWKWARD.  It inserts a configurable latency, it
-- deasserts AWREADY/WREADY/ARREADY pseudo-randomly, and it returns beats no
-- earlier than the latency allows.  A DMA tested against an always-ready
-- slave is tested against a bus that does not exist.
--
-- SHAPE.  Small by default, because `regress.sh` runs this row with DEFAULT
-- generics and the real 9B store is 131,072 words, which no GHDL run in this
-- repository has reached (see
-- docs/debugging/2026-09-02_gdn-state-does-not-fit-on-chip.md).  Every
-- STRUCTURAL property under test -- burst count, outstanding depth, the
-- word/beat tiling, the two-index assembly -- is exercised at this size.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.finish;

entity tb_gdn_state_axi is
  generic(
    VAL_HEADS   : positive := 2;
    DIM         : positive := 8;
    RECUR_LANES : positive := 2;
    LAYERS      : positive := 3;
    AXI_DW      : positive := 128;   -- 4 words of 32 bits
    MAXB        : positive := 4;
    MAXOUT      : positive := 2;
    RD_LAT      : positive := 7;     -- slave read latency, cycles
    -- WRITE-RESPONSE LATENCY, AND IT IS LOAD-BEARING FOR ONE CHECK.  With B
    -- returned the cycle after the last beat, a DMA that skips the BRESP wait
    -- entirely still has every response in hand by the time `done` reaches
    -- the bench, so mutant M2 SURVIVED at B_LAT = 0.  A real HBM slave does
    -- not answer that fast.  This is the difference between a check that
    -- exists and a check that discriminates.
    B_LAT       : natural  := 6
  );
end entity;

architecture sim of tb_gdn_state_axi is
  constant NBR   : positive := DIM / RECUR_LANES;
  constant WORDS : positive := VAL_HEADS * DIM * NBR;
  constant WBITS : positive := RECUR_LANES * 16;
  constant WPB   : positive := AXI_DW / WBITS;
  constant BEATS : positive := WORDS / WPB;
  constant BPB   : positive := AXI_DW / 8;
  constant MANT_BYTES   : positive := BEATS * BPB;
  -- + a gap standing in for the per-layer exponent block.  MUST BE A WHOLE
  -- NUMBER OF BEATS: an unaligned stride makes odd layers start mid-beat and
  -- the DUT now refuses it.  The first version used a flat +16, which is
  -- aligned at AXI_DW=128 and NOT at 256, so the sweep found it and nothing
  -- else would have.
  constant LAYER_STRIDE : positive := MANT_BYTES + BPB;
  constant ADDR_W : positive := 33;
  constant BASE   : natural := 4096;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  signal load_start, save_start : std_logic := '0';
  signal layer : integer range 0 to LAYERS-1 := 0;
  signal busy, dn, er : std_logic;

  -- DUT <-> store, in the store's own (head, col, grp) shape
  signal d_we   : std_logic;
  signal d_wh, d_wc, d_wg : natural;
  signal d_wd   : std_logic_vector(WBITS-1 downto 0);
  signal d_re   : std_logic;
  signal d_rh, d_rc, d_rg : natural;
  signal d_rd   : std_logic_vector(WBITS-1 downto 0);

  -- bench <-> store (the second port, used only when the DUT is idle).  The
  -- bench addresses FLAT and decomposes here, deliberately using the same
  -- expression the DUT does so that a transposed store index shows up as a
  -- mismatch in both directions rather than cancelling.
  signal b_we   : std_logic := '0';
  signal b_wa   : natural range 0 to WORDS-1 := 0;
  signal b_wd   : std_logic_vector(WBITS-1 downto 0) := (others => '0');
  signal b_re   : std_logic := '0';
  signal b_ra   : natural range 0 to WORDS-1 := 0;

  -- muxed store ports
  signal s_we : std_logic;
  signal s_wh, s_wc, s_wg : natural;
  signal s_wd : std_logic_vector(WBITS-1 downto 0);
  signal s_re : std_logic;
  signal s_rh, s_rc, s_rg : natural;
  signal s_rd : std_logic_vector(WBITS-1 downto 0);

  -- AXI
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

  -- the slave's memory, addressed in BEATS from BASE
  constant SLAVE_BEATS : positive := LAYERS * (LAYER_STRIDE / BPB) + BEATS;
  type smem_t is array (0 to SLAVE_BEATS-1)
                 of std_logic_vector(AXI_DW-1 downto 0);
  -- DRIVEN BY THE SLAVE PROCESS ONLY.  The stimulus fills it through the
  -- backdoor below rather than assigning it directly, and reads it directly
  -- because reading is not driving.
  --
  -- WHY: the first version had the stimulus assign `smem` to lay down the
  -- test pattern while the slave also assigned it on writes.  Two processes
  -- driving one resolved signal do not "take turns"; they resolve, and every
  -- loaded word came back as 'X'.  This is the same defect that was fixed in
  -- `rtl/llama_top.vhd`'s `f_lost` earlier the same day, which is a good
  -- indication of how easy it is to write twice.
  signal smem : smem_t := (others => (others => '0'));

  signal bd_we : std_logic := '0';
  signal bd_a  : natural := 0;
  signal bd_d  : std_logic_vector(AXI_DW-1 downto 0) := (others => '0');

  signal running  : boolean := true;
  signal n_bad    : natural := 0;
  signal n_chk    : natural := 0;
  signal n_arstall, n_wstall : natural := 0;
  -- B RESPONSES, COUNTED, because `done` firing before they land is a real
  -- and silent defect and nothing else here sees it.  MEASURED: mutant M2
  -- (S_SDRAIN exits without waiting for BRESP) SURVIVED the first version of
  -- this bench, because the slave applies each write on the W handshake, so
  -- the memory already holds the right bytes by the time the last beat is
  -- accepted.  On real hardware the same mutation means the next token starts
  -- while writes are still in flight.
  signal n_bresp : natural := 0;

  -- The two patterns.  Different functions, so a save that never happened
  -- cannot look like one that did, and DIFFERENT IN EVERY 16-BIT LANE, so a
  -- DMA that swaps or drops a lane inside a word is visible.
  --
  -- Built lane by lane rather than as one arithmetic expression: WBITS is
  -- RECUR_LANES*16 and reaches 64 at the real shape, so `2**WBITS` and a
  -- 32-bit multiply both overflow VHDL's `integer`.  The first version did
  -- exactly that and died with `overflow detected` rather than a wrong value,
  -- which is the good failure, but it is still a failure.
  function lane16(a, b : natural) return natural is
  begin
    return ((a*40503 + b*12345 + 7) mod 65536);
  end function;

  function pat_a(i : natural) return std_logic_vector is
    variable v : std_logic_vector(WBITS-1 downto 0);
  begin
    for k in 0 to WBITS/16 - 1 loop
      v((k+1)*16-1 downto k*16) :=
        std_logic_vector(to_unsigned(lane16(i, k*3 + 1), 16));
    end loop;
    return v;
  end function;

  function pat_b(i : natural) return std_logic_vector is
    variable v : std_logic_vector(WBITS-1 downto 0);
  begin
    for k in 0 to WBITS/16 - 1 loop
      v((k+1)*16-1 downto k*16) :=
        std_logic_vector(to_unsigned(lane16(i + 555, k*7 + 2), 16));
    end loop;
    return v;
  end function;
begin
  clk <= not clk after 5 ns;

  -- the store, with its ports muxed: DUT while busy, bench while idle
  s_we <= d_we when busy = '1' else b_we;
  s_wh <= d_wh when busy = '1' else b_wa / (DIM*NBR);
  s_wc <= d_wc when busy = '1' else (b_wa / NBR) mod DIM;
  s_wg <= d_wg when busy = '1' else b_wa mod NBR;
  s_wd <= d_wd when busy = '1' else b_wd;
  s_re <= d_re when busy = '1' else b_re;
  s_rh <= d_rh when busy = '1' else b_ra / (DIM*NBR);
  s_rc <= d_rc when busy = '1' else (b_ra / NBR) mod DIM;
  s_rg <= d_rg when busy = '1' else b_ra mod NBR;
  d_rd <= s_rd;

  store : entity work.gdn_state_mem
    generic map(VAL_HEADS => VAL_HEADS, DIM => DIM,
                RECUR_LANES => RECUR_LANES, STYLE => "auto")
    port map(clk => clk,
             r_en => s_re, r_head => s_rh, r_col => s_rc, r_grp => s_rg,
             r_data => s_rd,
             w_en => s_we, w_head => s_wh, w_col => s_wc, w_grp => s_wg,
             w_data => s_wd);

  dut : entity work.gdn_state_axi
    generic map(VAL_HEADS => VAL_HEADS, DIM => DIM,
                RECUR_LANES => RECUR_LANES, LAYERS => LAYERS,
                LAYER_STRIDE => LAYER_STRIDE, MANT_BYTES => MANT_BYTES,
                AXI_DW => AXI_DW, ADDR_W => ADDR_W,
                MAXB => MAXB, MAXOUT => MAXOUT)
    port map(clk => clk, rst => rst,
             load_start => load_start, save_start => save_start,
             layer => layer,
             state_base => std_logic_vector(to_unsigned(BASE, ADDR_W)),
             busy => busy, done => dn, err => er,
             m_w_en => d_we, m_w_head => d_wh, m_w_col => d_wc,
             m_w_grp => d_wg, m_w_data => d_wd,
             m_r_en => d_re, m_r_head => d_rh, m_r_col => d_rc,
             m_r_grp => d_rg, m_r_data => d_rd,
             r_arvalid => arvalid, r_arready => arready, r_araddr => araddr,
             r_arlen => arlen, r_arsize => arsize, r_arburst => arburst,
             r_rvalid => rvalid, r_rready => rready, r_rdata => rdata,
             r_rlast => rlast, r_rresp => rresp,
             w_awvalid => awvalid, w_awready => awready, w_awaddr => awaddr,
             w_awlen => awlen, w_awsize => awsize, w_awburst => awburst,
             w_wvalid => wvalid, w_wready => wready, w_wdata => wdata,
             w_wstrb => wstrb, w_wlast => wlast,
             w_bvalid => bvalid, w_bready => bready, w_bresp => bresp);

  -- ---- THE SLAVE ------------------------------------------------------
  slave : process(clk) is
    type qent_t is record
      addr : natural;
      len  : natural;
      age  : natural;
      live : boolean;
    end record;
    type q_t is array (0 to 7) of qent_t;
    variable rq : q_t := (others => (0,0,0,false));
    variable wq : q_t := (others => (0,0,0,false));
    variable seed : unsigned(31 downto 0) := x"0BADF00D";
    variable bpend : natural := 0;
    variable bage  : natural := 0;
    variable head, tail : natural := 0;
    variable whead, wtail : natural := 0;

    impure function nxt return natural is
      variable t : unsigned(63 downto 0);
    begin
      t    := seed * to_unsigned(1103515245, 32);
      seed := t(31 downto 0) + to_unsigned(12345, 32);
      seed := seed xor shift_right(seed, 15);
      return to_integer(seed(30 downto 0));
    end function;
  begin
    if rising_edge(clk) then
      -- READY signals wobble.  A DMA tested against an always-ready slave is
      -- tested against a bus that does not exist.
      -- READY IS ALSO GATED ON QUEUE SPACE, not only on the random stall.
      -- A slave that asserts AWREADY with a full queue is not modelling a
      -- slave, it is modelling an infinite one, and it silently corrupts
      -- rather than backpressuring.  Leaving one slot spare of the 8.
      arready <= '1' when (nxt mod 4) /= 0
                      and not rq((head + 1) mod 8).live else '0';
      awready <= '1' when (nxt mod 4) /= 0
                      and not wq((whead + 1) mod 8).live else '0';
      wready  <= '1' when (nxt mod 3) /= 0 else '0';
      if arvalid = '1' and arready = '0' then n_arstall <= n_arstall + 1; end if;
      if wvalid  = '1' and wready  = '0' then n_wstall  <= n_wstall  + 1; end if;

      -- ---- the stimulus's backdoor into the slave memory -----------------
      if bd_we = '1' then smem(bd_a) <= bd_d; end if;

      -- ---- AR: queue the burst ------------------------------------------
      if arvalid = '1' and arready = '1' then
        rq(head) := ((to_integer(unsigned(araddr)) - BASE) / BPB,
                     to_integer(unsigned(arlen)) + 1, 0, true);
        head := (head + 1) mod 8;
        assert to_integer(unsigned(arlen)) + 1 <= 16
          report "tb_gdn_state_axi: ARLEN asks for more than 16 beats, which "
               & "the FK33's AXI3 HBM slave cannot do." severity failure;
        assert arburst = "01"
          report "tb_gdn_state_axi: burst type is not INCR" severity failure;
      end if;

      -- ---- R: serve the oldest queued burst after RD_LAT -----------------
      if rvalid = '1' and rready = '1' then
        if rq(tail).len = 1 then
          rq(tail).live := false;
          tail := (tail + 1) mod 8;
          rvalid <= '0'; rlast <= '0';
        else
          -- `addr` and `len` are VARIABLES, so the two lines above have
          -- ALREADY taken effect by the time these two run.  Writing
          -- `smem(addr + 1)` here therefore skipped a beat, and `len - 1`
          -- decremented twice.  The symptom was a clean one-beat shift from
          -- word 4 onward, which reads exactly like a DMA bug and was the
          -- model's.  Variables update immediately; signals do not.
          rq(tail).addr := rq(tail).addr + 1;
          rq(tail).len  := rq(tail).len - 1;
          rdata <= smem(rq(tail).addr);
          rlast <= '1' when rq(tail).len = 1 else '0';
        end if;
      elsif rvalid = '0' and rq(tail).live then
        if rq(tail).age < RD_LAT then
          rq(tail).age := rq(tail).age + 1;
        else
          rvalid <= '1';
          rdata  <= smem(rq(tail).addr);
          rlast  <= '1' when rq(tail).len = 1 else '0';
        end if;
      end if;

      -- ---- AW / W / B ----------------------------------------------------
      -- THE AW QUEUE IS NOT OPTIONAL, AND THE FIRST VERSION OF THIS SLAVE DID
      -- NOT HAVE ONE.  AXI lets a master run the AW channel ahead of the W
      -- channel, and this DUT does: it issues address phases as fast as the
      -- slave accepts them while the data streams behind.  A slave that keeps
      -- a single `waddr` has it CLOBBERED by the next AW mid-burst, so the
      -- data lands at the wrong beat and `wcnt` underflows.  That presented
      -- as a DUT bug -- "SAVE wrong from beat 14" plus a bound check -- and
      -- was entirely the model's.  W beats belong to the OLDEST un-retired
      -- AW, which is what a queue expresses.
      if awvalid = '1' and awready = '1' then
        wq(whead) := ((to_integer(unsigned(awaddr)) - BASE) / BPB,
                      to_integer(unsigned(awlen)) + 1, 0, true);
        whead := (whead + 1) mod 8;
        assert to_integer(unsigned(awlen)) + 1 <= 16
          report "tb_gdn_state_axi: AWLEN asks for more than 16 beats, which "
               & "the FK33's AXI3 HBM slave cannot do." severity failure;
        assert awburst = "01"
          report "tb_gdn_state_axi: write burst type is not INCR"
          severity failure;
      end if;
      if wvalid = '1' and wready = '1' then
        assert wq(wtail).live
          report "tb_gdn_state_axi: a W beat arrived with no outstanding AW."
          severity failure;
        smem(wq(wtail).addr) <= wdata;
        assert wstrb = (wstrb'range => '1')
          report "tb_gdn_state_axi: a partial WSTRB would leave stale bytes"
          severity failure;
        if wq(wtail).len = 1 then
          assert wlast = '1'
            report "tb_gdn_state_axi: the burst ended without WLAST"
            severity failure;
          wq(wtail).live := false;
          wtail := (wtail + 1) mod 8;
          bpend := bpend + 1;
        else
          assert wlast = '0'
            report "tb_gdn_state_axi: WLAST asserted mid-burst"
            severity failure;
          wq(wtail).addr := wq(wtail).addr + 1;
          wq(wtail).len  := wq(wtail).len - 1;
        end if;
      end if;
      if bvalid = '1' and bready = '1' then
        bvalid <= '0';
        bpend  := bpend - 1;
        bage   := 0;
        n_bresp <= n_bresp + 1;
      elsif bvalid = '0' and bpend > 0 then
        if bage < B_LAT then
          bage := bage + 1;
        else
          bvalid <= '1';
        end if;
      end if;

      if rst = '1' then
        n_bresp <= 0;
        rq := (others => (0,0,0,false));
        wq := (others => (0,0,0,false));
        head := 0; tail := 0; whead := 0; wtail := 0; bpend := 0;
        bage := 0;
        rvalid <= '0'; rlast <= '0'; bvalid <= '0';
      end if;
    end if;
  end process;

  -- ---- THE STIMULUS ---------------------------------------------------
  stim : process is
    procedure tick(n : natural := 1) is
    begin
      for i in 1 to n loop wait until rising_edge(clk); end loop;
    end procedure;

    -- WAIT ON `done`, NOT ON `busy` FALLING.  `busy` does not rise on the same
    -- edge as the start pulse, so `while busy = '1' loop` completes INSTANTLY
    -- and every subsequent check reads a store the DMA has not touched.  That
    -- is exactly the trap `rtl/llama_top.vhd`'s S_ARM comment records for
    -- `gdn_block` ("waiting for it to FALL without first seeing it RISE
    -- completes instantly"), and the first version of this bench walked into
    -- it: 384 of 390 checks failed with the store reading all zeros, which
    -- looks like a dead DMA and was a dead wait.
    procedure wait_done is
      variable n : natural := 0;
    begin
      loop
        wait until rising_edge(clk);
        exit when dn = '1';
        n := n + 1;
        -- A BOUND, SO A DMA THAT NEVER FINISHES SAYS SO.  Mutant M4 (the LOAD
        -- stops one beat short) hangs rather than computing anything wrong,
        -- and without this the row is a bare `regress.sh` TIMEOUT with no
        -- line number.  A generous bound: the whole transfer is BEATS beats
        -- and no beat can take more than a few tens of cycles even with the
        -- slave stalling.
        assert n < 200 * BEATS + 5000
          report "tb_gdn_state_axi: FAIL, the DMA never asserted `done` -- "
               & "it is stuck, not wrong."
          severity failure;
      end loop;
    end procedure;

    procedure chk(cond : boolean; msg : string) is
    begin
      n_chk <= n_chk + 1;
      if not cond then
        n_bad <= n_bad + 1;
        report "tb_gdn_state_axi: " & msg severity error;
      end if;
      wait for 0 ns;
    end procedure;

    variable lbase : natural;
    variable bresp_before : natural := 0;
  begin
    rst <= '1'; tick(4); rst <= '0'; tick(2);

    for L in 0 to LAYERS-1 loop
      lbase := L * (LAYER_STRIDE / BPB);

      -- ---- fill HBM with pattern A for this layer, through the backdoor --
      for b in 0 to BEATS-1 loop
        bd_a <= lbase + b;
        for k in 0 to WPB-1 loop
          bd_d((k+1)*WBITS-1 downto k*WBITS) <= pat_a(L*1000 + b*WPB + k);
        end loop;
        bd_we <= '1';
        tick;
      end loop;
      bd_we <= '0';
      tick;

      -- ---- LOAD, then read the store back through the bench port --------
      layer <= L; tick;
      load_start <= '1'; tick; load_start <= '0';
      wait_done;
      chk(er = '0', "err asserted after a clean LOAD");

      for i in 0 to WORDS-1 loop
        b_re <= '1'; b_ra <= i; tick; b_re <= '0'; tick;
        chk(s_rd = pat_a(L*1000 + i),
            "LOAD layer " & integer'image(L) & " word " & integer'image(i)
            & " got " & to_hstring(s_rd)
            & " want " & to_hstring(pat_a(L*1000 + i)));
      end loop;

      -- ---- write pattern B into the store, SAVE, check HBM --------------
      for i in 0 to WORDS-1 loop
        b_we <= '1'; b_wa <= i; b_wd <= pat_b(L*1000 + i); tick;
      end loop;
      b_we <= '0'; tick;

      save_start <= '1'; tick; save_start <= '0';
      bresp_before := n_bresp;
      wait_done;
      chk(er = '0', "err asserted after a clean SAVE");
      -- EVERY BURST ACKNOWLEDGED BEFORE `done`.  This is the check that makes
      -- M2 bite; see the n_bresp declaration.
      chk(n_bresp - bresp_before = BEATS / MAXB,
          "SAVE layer " & integer'image(L) & " reported done with "
          & integer'image(n_bresp - bresp_before) & " of "
          & integer'image(BEATS / MAXB) & " write responses retired");

      for b in 0 to BEATS-1 loop
        for k in 0 to WPB-1 loop
          chk(smem(lbase + b)((k+1)*WBITS-1 downto k*WBITS)
                = pat_b(L*1000 + b*WPB + k),
              "SAVE layer " & integer'image(L) & " beat " & integer'image(b)
              & " word " & integer'image(k)
              & " got " & to_hstring(smem(lbase + b)((k+1)*WBITS-1
                                                     downto k*WBITS))
              & " want " & to_hstring(pat_b(L*1000 + b*WPB + k)));
        end loop;
      end loop;
    end loop;

    tick(4);
    running <= false; wait for 0 ns;

    report "tb_gdn_state_axi: checks=" & integer'image(n_chk)
         & " bad=" & integer'image(n_bad)
         & " AR stalls=" & integer'image(n_arstall)
         & " W stalls=" & integer'image(n_wstall)
      severity note;

    -- A slave that never stalled did not test the handshakes.
    assert n_arstall > 0 and n_wstall > 0
      report "tb_gdn_state_axi: FAIL, the slave never stalled, so the "
           & "handshakes are UNTESTED and the pass is empty."
      severity failure;

    if n_bad = 0 then
      report "tb_gdn_state_axi RESULT: PASS -- " & integer'image(n_chk)
           & " checks over " & integer'image(LAYERS)
           & " layers, load and save, against a stalling AXI3 slave."
        severity note;
    else
      report "tb_gdn_state_axi RESULT: FAIL -- " & integer'image(n_bad)
           & " of " & integer'image(n_chk) severity error;
    end if;
    finish;
  end process;
end architecture;
