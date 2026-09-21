-- sim/tb_weight_streamer.vhd -- weight_streamer reassembly at BOTH geometries.
--
-- Spec: docs/superpowers/specs/2026-08-20-int4-streaming-matvec-design.md
--       6.5 (bit ordering) and 6.5a (the general rule at arbitrary AXI_DW)
--
-- WHAT THIS IS FOR.  Until 2026-08-28 the sub-region byte layout was pinned at
-- AXI_DW = 128, where one AXI lane is exactly one row's BLK*4 = 128-bit chunk.
-- 6.5 warned in as many words that "the ROWS_IF = 4 coincidence is load-bearing
-- and must not be assumed elsewhere", and the FK33 assumes it elsewhere: its
-- HBM SAXI ports are 256 bits, so one lane spans TWO rows, and its ROWS_IF = 48
-- scale group is 768 bits against a 256-bit port and needs THREE sub-regions.
-- Neither case had ever been simulated, because nothing could build the bytes.
--
-- The check is deliberately at the SEAM the packer and the RTL share and
-- nothing else looks at.  Two independently written encodings of 6.5a must
-- agree:
--
--   * the MEMORY is built by the SLICE definition -- walk the bits of
--     sub-region p, work out from the bit index which row, which weight and
--     which nibble bit it is, and fetch that (wmem/smem below);
--   * the EXPECTED value is built by the ROW definition -- walk rows and
--     weights and place each at its own bit offset (wword/sword below).
--
-- The DUT is what has to turn the first into the second.  Getting the slice
-- order, the row order, the nibble order, the endianness or the scale
-- sub-region order wrong makes the two disagree, and disagreement is checked
-- BIT-EXACTLY with no tolerance, per this repo's verification discipline.
--
-- Two instances, because a generalisation is only proved by the case it was
-- generalised from failing to change:
--
--   A  ROWS_IF=48 BLK=32 AXI_DW=256  ->  NPORTS_W=24, n_scale_sub=3, 27 masters
--      The FK33 target.  A slice is rows 2p and 2p+1; a scale group is three
--      slices; GRP = 1.
--   B  ROWS_IF=4  BLK=32 AXI_DW=128  ->  NPORTS_W=4,  n_scale_sub=1,  5 masters
--      The AXU3EG, already built and taped into a bitstream.  A slice IS a
--      row; GRP = 2, so one beat carries two cycles of scales and the last
--      superword is half padding.
--
-- The AXI slaves stall at random and the consumer deasserts ready at random,
-- so the per-port FIFOs fill at different rates and the all-valid lockstep pop
-- is actually exercised rather than assumed.  A streamer that popped scale
-- sub-regions independently would pass with zero stalls and fail here.
--
-- ===========================================================================
-- EXTENDED 2026-09-20 by TRACK POPPORT: THE CARD'S ARM, AND THE RENDEZVOUS
-- ===========================================================================
--
-- WHAT WAS MISSING.  TRACK SHAPEAUDIT (92ba3ec) established that `FAST_POP`,
-- which hw/fk33/rtl/fk33_engine.vhd:1356 sets TRUE, was named in zero
-- `sim/tb_*.vhd` files; TRACK POPCOVER (fbac64e) cleared the arm inside
-- rtl/async_fifo.vhd ITSELF -- same values, same order, maxocc 18/16 in both
-- arms, minslack 0 -- and closed by saying outright that this "says nothing
-- about axi_rd_port, weight_streamer ... nor the 27-port composition".
--
-- This file is that composition.  Geometry A below is ALREADY the card's
-- 27 masters (ROWS_IF=48 / AXI_DW=256 -> NPORTS_W=24 + NPORTS_S=3), and
-- rtl/weight_streamer.vhd's own FAST_POP comment says why that matters:
-- the lever is forwarded to EVERY one of the 27 ports because matvec_core
-- accepts a word only when all of them present a beat in the SAME cycle.
--
-- THE PROPERTY, STATED BEFORE IT IS TESTED.  Per-port equivalence is
-- POPCOVER's result and is not re-litigated here.  What this file adds is
-- the RENDEZVOUS:
--
--   P1  VALUES.  Every word the consumer accepts is the 24 slices of the
--       SAME word index in order, and every scale group the 3 slices of the
--       same superword, under the card's FAST_POP = true exactly as under
--       false.  Checked bit-exactly against the two independent encodings
--       of 6.5a that this bench already had.
--   P2  RATE, WEIGHT SIDE.  With all 24 weight FIFOs stocked and the
--       consumer flat out, the 24-way `all_v` rendezvous delivers one word
--       per core cycle at FAST_POP = true and one per 1.5 at false.  A
--       24-way AND of ports that were individually 2-cycles-in-3 could have
--       been far worse than 1.5 if the ports drifted out of phase; that is
--       the composition question and it is not answerable per-port.
--   P3  RATE, SCALE SIDE, MEASURED SEPARATELY.  The 3 scale ports pop on
--       `s_take`, a DIFFERENT condition from `pop_w`, so the lever reaching
--       the weight ports is no evidence it reached the scale ports.  Timing
--       the two streams separately is what gives "forwarded to every one of
--       the 27" any teeth at all.
--
-- A VALUE ORACLE CAN ONLY PROVE THE LEVER HARMLESS, NEVER PRESENT, because
-- FAST_POP changes no value by construction -- POPCOVER's phrasing, and its
-- mutation table is the proof: three defects (lever INVERTED, NOT THREADED,
-- WIRED ON) that every value oracle in the project reports 0 errors on.  So
-- the cadence probe below is TWO-SIDED in the same way: the fast arm fails
-- if it is slow AND the slow arm fails if it is fast.  "Both arms pass" is
-- not a result.
--
-- WHY THIS LEVEL AND NOT sim/tb_matvec_fk33_desc_dual.  That bench is at the
-- same 27-master geometry and at DUAL_CLK=true, and it is where SHAPEAUDIT
-- demonstrated its 2x2, so it was the named starting point.  It is the wrong
-- level for the RATE property: it is a value oracle end to end, its window
-- is the whole descriptor control plane plus the array, and its consumer is
-- matvec_core rather than a probe that can be shut and opened.  A cadence
-- measured there is a property of the array's acceptance pattern, not of the
-- rendezvous.  weight_streamer is the SMALLEST entity whose cone contains
-- all three of the per-port FIFO, the fan-out of FAST_POP to all 27 ports,
-- and the rendezvous itself -- and it already had this bench, so extending
-- it adds no gate row.
--
-- BOTH axi_rd_port BRANCHES ARE COVERED, and they are not textually
-- identical: rtl/axi_rd_port.vhd forwards FAST_POP at :276 into stream_fifo
-- (single clock) and at :397 into async_fifo (dual clock, where it also
-- carries OUT_MARGIN).  A generic dropped from ONE of them is a defect that
-- only shows at that branch's DUAL_CLK, so the cadence probe runs at both.
-- The card is the dual-clock one.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- ---------------------------------------------------------------------------
-- One geometry under test.  Instantiated twice by tb_weight_streamer below.
-- ---------------------------------------------------------------------------
entity ws_check is
  generic(
    NAME    : string    := "?";
    ROWS_IF : positive  := 4;
    BLK     : positive  := 32;
    AXI_DW  : positive  := 128;
    NPW     : positive  := 4;      -- NPORTS_W, must equal ROWS_IF*BLK*4/AXI_DW
    NPS     : positive  := 1;      -- n_scale_sub of 6.5a
    MAXB    : positive  := 256;
    TILES   : positive  := 3;
    NB      : positive  := 5;
    STALL   : natural   := 3;
    -- ------------------------------------------------------- TRACK POPPORT
    -- The card's two arm-selecting booleans, forwarded to the DUT unchanged.
    -- Both default to the value every pre-existing instantiation of this
    -- block ran at, so the two original instances below are bit-identical.
    DUAL    : boolean   := false;  -- axi_rd_port g_dc: async_fifo + the CDC
    FASTP   : boolean   := false;  -- FAST_POP, forwarded to all NPW+NPS
    -- PROBE selects the CADENCE arm instead of the random-stall value arm.
    -- It is not a second bench: the DUT, the slaves and the memory model are
    -- the same; only the consumer's behaviour and the checker change.
    PROBE   : boolean   := false;
    PN      : positive  := 21      -- accepts timed in the drain window
  );
  port(
    clk, rst : in  std_logic;
    -- AXI clock.  IGNORED unless DUAL, and defaulted, so the original two
    -- instances need no edit.  Driven from its OWN process at the top level,
    -- never from a `sclk <= aclk when DUAL else clk` assignment: that costs a
    -- delta, and a delta-skewed clock is what silently broke
    -- sim/tb_matvec_int4_ip when axi_rd_port was first written that way (see
    -- sim/tb_matvec_fk33_desc.vhd's DUAL CLOCK header).
    aclk     : in  std_logic := '0';
    done     : out boolean := false;
    nbad     : out natural := 0;
    -- Cadence result, core cycles spanned by PN accepts.  -1 until measured.
    w_cyc    : out integer := -1;
    s_cyc    : out integer := -1
  );
end entity;

architecture sim of ws_check is
  constant ADDR_W : positive := 32;
  constant BYTES  : positive := AXI_DW / 8;
  constant SW     : positive := ROWS_IF * 16;          -- scale bits per cycle
  constant GRP    : positive := NPS * AXI_DW / SW;     -- groups per superword
  constant NPALL  : positive := NPW + NPS;
  constant NWORD  : positive := TILES * NB;            -- tile-block words
  constant NSUP   : positive := (NWORD + GRP - 1) / GRP;
  constant SUBSZ  : positive := 4096;                  -- one region per port

  -- ARSIZE is log2(bytes per beat); computed here rather than imported so the
  -- testbench does not depend on the same util_pkg the DUT does.
  function log2i(n : positive) return natural is
    variable v : positive := 1;
    variable r : natural  := 0;
  begin
    while v < n loop v := v * 2; r := r + 1; end loop;
    return r;
  end function;
  constant ARSZ : natural := log2i(BYTES);

  -- ------------------------------------------------------------- the content
  -- Arbitrary but deterministic and row/block/weight dependent, so a swap of
  -- any two of them is visible.  Coprime multipliers, and never all-zero.
  function wnib(row, b, j : natural) return natural is
  begin
    return (row * 7 + b * 13 + j * 3 + 1) mod 16;
  end function;

  function sclv(row, b : natural) return natural is
  begin
    return (row * 1103 + b * 271 + 7) mod 32768;   -- uint15, 6.1
  end function;

  -- ------------------------------------------- EXPECTED, by the row definition
  -- 6.5a: row r of the tile at bits (r+1)*BLK*4-1 downto r*BLK*4, and within a
  -- row-chunk weight j at bits 4j+3 downto 4j (6.5, unchanged).
  function wword(t, b : natural) return std_logic_vector is
    variable v : std_logic_vector(ROWS_IF*BLK*4-1 downto 0) := (others => '0');
  begin
    for r in 0 to ROWS_IF-1 loop
      for j in 0 to BLK-1 loop
        v(r*BLK*4 + 4*j + 3 downto r*BLK*4 + 4*j) :=
          std_logic_vector(to_unsigned(wnib(t*ROWS_IF + r, b, j), 4));
      end loop;
    end loop;
    return v;
  end function;

  -- 6.5: the scale for row r sits at byte offset 2r of the group, int16 LE.
  function sword(t, b : natural) return std_logic_vector is
    variable v : std_logic_vector(SW-1 downto 0) := (others => '0');
  begin
    for r in 0 to ROWS_IF-1 loop
      v(r*16 + 15 downto r*16) :=
        std_logic_vector(to_unsigned(sclv(t*ROWS_IF + r, b), 16));
    end loop;
    return v;
  end function;

  -- --------------------------------------- MEMORY, by the slice definition
  -- 6.5a: weight sub-region p carries bit slice p of the tile word.  Written
  -- as a walk over the SLICE's bits deducing what each one is, which is the
  -- opposite direction from wword and therefore an independent statement of
  -- the same rule.
  function wmem(p, n : natural) return std_logic_vector is
    variable v  : std_logic_vector(AXI_DW-1 downto 0);
    variable nv : std_logic_vector(3 downto 0);
    variable gb, r, wb, j, nb4, t, b : natural;
  begin
    t := n / NB;  b := n mod NB;
    for i in 0 to AXI_DW-1 loop
      gb  := p * AXI_DW + i;          -- bit index within the tile word
      r   := gb / (BLK*4);            -- which row of the tile
      wb  := gb mod (BLK*4);          -- bit index within that row-chunk
      j   := wb / 4;                  -- which weight
      nb4 := wb mod 4;                -- which bit of its nibble
      nv  := std_logic_vector(to_unsigned(wnib(t*ROWS_IF + r, b, j), 4));
      v(i) := nv(nb4);
    end loop;
    return v;
  end function;

  -- 6.5a: superword m holds groups m*GRP .. m*GRP+GRP-1, group g at bits
  -- (g mod GRP + 1)*SW-1 downto (g mod GRP)*SW, and scale sub-region q carries
  -- bit slice q of it.  Groups past the end are pad fill 0x00 (6.4).
  function smem(q, m : natural) return std_logic_vector is
    variable v  : std_logic_vector(AXI_DW-1 downto 0) := (others => '0');
    variable sv : std_logic_vector(15 downto 0);
    variable gb, g, sb, r, b16, t, b : natural;
  begin
    for i in 0 to AXI_DW-1 loop
      gb := q * AXI_DW + i;           -- bit index within the superword
      g  := m * GRP + gb / SW;        -- flat scale-group index
      sb := gb mod SW;                -- bit index within that group
      r  := sb / 16;                  -- which row
      b16 := sb mod 16;               -- which bit of its uint16
      if g < NWORD then
        t := g / NB;  b := g mod NB;
        sv := std_logic_vector(to_unsigned(sclv(t*ROWS_IF + r, b), 16));
        v(i) := sv(b16);
      else
        v(i) := '0';
      end if;
    end loop;
    return v;
  end function;

  -- ---------------------------------------------------------------- signals
  signal start   : std_logic := '0';
  signal w_base  : std_logic_vector(NPW*ADDR_W-1 downto 0) := (others => '0');
  signal s_base  : std_logic_vector(NPS*ADDR_W-1 downto 0) := (others => '0');
  signal w_beats : integer := NWORD;
  signal s_beats : integer := NSUP;

  signal m_arvalid, m_arready, m_rvalid, m_rready, m_rlast :
    std_logic_vector(NPALL-1 downto 0) := (others => '0');
  signal m_araddr  : std_logic_vector(NPALL*ADDR_W-1 downto 0);
  signal m_arlen   : std_logic_vector(NPALL*8-1 downto 0);
  signal m_arsize  : std_logic_vector(NPALL*3-1 downto 0);
  signal m_arburst : std_logic_vector(NPALL*2-1 downto 0);
  signal m_rdata   : std_logic_vector(NPALL*AXI_DW-1 downto 0)
                     := (others => '0');

  signal w_valid, s_valid : std_logic;
  signal rdy : std_logic := '0';
  signal w_data : std_logic_vector(ROWS_IF*BLK*4-1 downto 0);
  signal s_data : std_logic_vector(SW-1 downto 0);

  signal i_done : boolean := false;
  signal i_bad  : natural := 0;
  signal i_wcyc : integer := -1;
  signal i_scyc : integer := -1;
begin
  done  <= i_done;
  nbad  <= i_bad;
  w_cyc <= i_wcyc;
  s_cyc <= i_scyc;

  -- Sub-region bases: one 4 KB region per port, weights then scales, exactly
  -- the shape tools/pack_int4.py emits (header + NPW weight regions + NPS
  -- scale regions, all 4 KB aligned).
  gen_wb : for p in 0 to NPW-1 generate
    w_base((p+1)*ADDR_W-1 downto p*ADDR_W) <=
      std_logic_vector(to_unsigned(p*SUBSZ, ADDR_W));
  end generate;
  gen_sb : for q in 0 to NPS-1 generate
    s_base((q+1)*ADDR_W-1 downto q*ADDR_W) <=
      std_logic_vector(to_unsigned((NPW+q)*SUBSZ, ADDR_W));
  end generate;

  dut : entity work.weight_streamer
    generic map(NPORTS_W => NPW, NPORTS_S => NPS, AXI_DW => AXI_DW,
                ADDR_W => ADDR_W, ROWS_IF => ROWS_IF, BLK => BLK,
                DEPTH => 64, MAXB => MAXB, MAXOUT => 2,
                DUAL_CLK => DUAL, FAST_POP => FASTP)
    port map(clk => clk, rst => rst, aclk => aclk, start => start,
             w_base => w_base, w_beats => w_beats,
             s_base => s_base, s_beats => s_beats,
             m_arvalid => m_arvalid, m_arready => m_arready,
             m_araddr => m_araddr, m_arlen => m_arlen,
             m_arsize => m_arsize, m_arburst => m_arburst,
             m_rvalid => m_rvalid, m_rready => m_rready,
             m_rdata => m_rdata, m_rlast => m_rlast,
             w_valid => w_valid, w_data => w_data, w_ready => rdy,
             s_valid => s_valid, s_data => s_data, s_ready => rdy);

  -- ------------------------------------------------- behavioural AXI4 slaves
  -- One per master.  Data comes from the memory functions above, addressed by
  -- the beat the master actually asked for, so a dropped or reordered beat
  -- shows up as the WRONG BEAT and not as generic corruption.
  gen_slv : for p in 0 to NPALL-1 generate
    slave : process
      variable lf : unsigned(15 downto 0) :=
                    to_unsigned((p*2711 + 1237) mod 65536, 16);
      variable a  : unsigned(ADDR_W-1 downto 0);
      variable n, beat : integer;
      -- EVERY clock reference in this slave goes through `tick`, which is
      -- what makes the dual-clock arm a five-line change rather than a
      -- duplicated process.  The `if DUAL` is a constant condition and the
      -- wait is on a real clock signal, so there is no delta skew and no
      -- generate-arm duplication.  When DUAL, the AXI side of axi_rd_port
      -- runs on aclk, so a slave clocked on clk would be a protocol
      -- violation across the domain, not a stylistic choice.
      procedure tick is
      begin
        if DUAL then
          wait until rising_edge(aclk);
        else
          wait until rising_edge(clk);
        end if;
        lf := lf(14 downto 0) & (lf(15) xor lf(13) xor lf(12) xor lf(10));
      end procedure;
    begin
      m_arready(p) <= '0'; m_rvalid(p) <= '0'; m_rlast(p) <= '0';
      wait until rst = '0';
      loop
        m_arready(p) <= '0';
        while m_arvalid(p) = '0' loop tick; end loop;
        if STALL /= 0 then
          while (to_integer(lf) mod STALL) = 0 loop tick; end loop;
        end if;
        a := unsigned(m_araddr((p+1)*ADDR_W-1 downto p*ADDR_W));
        n := to_integer(unsigned(m_arlen((p+1)*8-1 downto p*8))) + 1;
        assert m_arburst((p+1)*2-1 downto p*2) = "01"
          report NAME & ": burst type must be INCR" severity failure;
        assert to_integer(unsigned(m_arsize((p+1)*3-1 downto p*3))) = ARSZ
          report NAME & ": arsize must match AXI_DW" severity failure;
        m_arready(p) <= '1'; tick; m_arready(p) <= '0';

        for i in 0 to n-1 loop
          if STALL /= 0 then
            m_rvalid(p) <= '0';
            while (to_integer(lf) mod STALL) = 0 loop tick; end loop;
          end if;
          beat := (to_integer(a) - p*SUBSZ) / BYTES;
          if p < NPW then
            m_rdata((p+1)*AXI_DW-1 downto p*AXI_DW) <= wmem(p, beat);
          else
            m_rdata((p+1)*AXI_DW-1 downto p*AXI_DW) <= smem(p-NPW, beat);
          end if;
          m_rvalid(p) <= '1';
          if i = n-1 then m_rlast(p) <= '1'; else m_rlast(p) <= '0'; end if;
          loop
            tick;
            exit when m_rready(p) = '1';
          end loop;
          a := a + BYTES;
        end loop;
        m_rvalid(p) <= '0'; m_rlast(p) <= '0';
      end loop;
    end process;
  end generate;

  -- =========================================================================
  -- VALUE ARM.  Byte-for-byte what this block always did.
  -- =========================================================================
  g_val : if not PROBE generate
  begin
  -- --------------------------------------------------------- consumer stalls
  -- w_ready and s_ready are tied together, as matvec_core drives them, but the
  -- two streams are checked with SEPARATE counters, so a streamer that let one
  -- run ahead of the other would still have to deliver each in the right order.
  rdygen : process(clk)
    variable lf : unsigned(15 downto 0) := to_unsigned(4321, 16);
  begin
    if rising_edge(clk) then
      lf := lf(14 downto 0) & (lf(15) xor lf(13) xor lf(12) xor lf(10));
      if STALL = 0 or (to_integer(lf) mod STALL) /= 0 then
        rdy <= '1';
      else
        rdy <= '0';
      end if;
    end if;
  end process;

  -- ----------------------------------------------------------------- checker
  chk : process
    variable nw, ns, bad : natural := 0;
  begin
    wait until rst = '0';
    wait until rising_edge(clk);
    start <= '1';
    wait until rising_edge(clk);
    start <= '0';

    while nw < NWORD or ns < NWORD loop
      wait until rising_edge(clk);
      if w_valid = '1' and rdy = '1' and nw < NWORD then
        if w_data /= wword(nw / NB, nw mod NB) then
          bad := bad + 1;
          if bad < 8 then
            report NAME & ": WEIGHT word " & integer'image(nw) &
                   " (tile " & integer'image(nw / NB) & " block " &
                   integer'image(nw mod NB) & ") reassembled wrong"
              severity error;
          end if;
        end if;
        nw := nw + 1;
      end if;
      if s_valid = '1' and rdy = '1' and ns < NWORD then
        if s_data /= sword(ns / NB, ns mod NB) then
          bad := bad + 1;
          if bad < 8 then
            report NAME & ": SCALE group " & integer'image(ns) &
                   " (tile " & integer'image(ns / NB) & " block " &
                   integer'image(ns mod NB) & ") reassembled wrong"
              severity error;
          end if;
        end if;
        ns := ns + 1;
      end if;
    end loop;

    i_bad  <= bad;
    wait until rising_edge(clk);
    report NAME & ": " & integer'image(NWORD) & " weight words of " &
           integer'image(ROWS_IF*BLK*4) & " bits over " & integer'image(NPW) &
           " sub-regions, " & integer'image(NWORD) & " scale groups of " &
           integer'image(SW) & " bits over " & integer'image(NPS) &
           " sub-regions (GRP=" & integer'image(GRP) & "), " &
           integer'image(bad) & " wrong" severity note;
    i_done <= true;
    wait;
  end process;
  end generate;

  -- =========================================================================
  -- CADENCE ARM (TRACK POPPORT).  P2 and P3 of the header.
  --
  -- THE WINDOW MUST CONTAIN THE READ-ISSUE CONDITION AND NOTHING ELSE, which
  -- is POPCOVER's shape and the reason this is not just "run the value arm
  -- with no stalls and time it".  Phase 1 shuts the consumer and lets all
  -- NPALL FIFOs stock to at least PN beats; phase 2 opens it flat out and
  -- times the drain.  Nothing refills during the window -- every port already
  -- holds what it will deliver -- so the number measures the rendezvous and
  -- the FIFOs' own `do_rd`, never AXI latency, never the slaves' stalls and
  -- never the AR throttle.
  --
  -- THE CHECK IS TWO-SIDED.  A fast instance carries W_CYC_MAX and fails if
  -- it is slow; a slow instance carries W_CYC_MIN and fails if it is fast.
  -- One-sided would pass a build where the lever does nothing (every arm
  -- slow) or one where it is wired on (every arm fast), and those are two of
  -- the three defects POPCOVER showed no value oracle in this project sees.
  --
  -- The value check runs HERE TOO, against the same two independent
  -- encodings of 6.5a, so a probe instance is not a hole in P1.
  -- =========================================================================
  g_prb : if PROBE generate
    type nat_a is array(0 to NPALL-1) of natural;
    signal rb    : nat_a   := (others => 0);
    signal minb  : natural := 0;
    signal p_go  : std_logic := '0';
    signal cyc   : natural := 0;
    signal w_cnt, s_cnt : natural := 0;
    signal w_t1, w_tN, s_t1, s_tN : integer := -1;
    signal p_bad : natural := 0;
  begin
    -- The consumer is shut or flat out, never random: a random ready would
    -- put the stall generator's period into the measured cadence.
    rdy <= p_go;

    -- R-beat census, taken in the AXI DOMAIN because that is where the
    -- handshake lives.  Sampling it on clk would miss or double-count beats
    -- whenever DUAL puts the two clocks at 1.67x, and the stocking gate
    -- below would then open early on a FIFO that was not stocked.
    rbc : process
    begin
      loop
        if DUAL then
          wait until rising_edge(aclk);
        else
          wait until rising_edge(clk);
        end if;
        for p in 0 to NPALL-1 loop
          if m_rvalid(p) = '1' and m_rready(p) = '1' then
            rb(p) <= rb(p) + 1;
          end if;
        end loop;
      end loop;
    end process;

    mbp : process(rb)
      variable m : natural;
    begin
      m := rb(0);
      for p in 1 to NPALL-1 loop
        if rb(p) < m then m := rb(p); end if;
      end loop;
      minb <= m;
    end process;

    -- Accept census and in-window value check, both in the core domain,
    -- which is where w_valid/s_valid live in BOTH configurations.
    --
    -- The error count lives in a VARIABLE, not in consecutive signal
    -- assignments: two increments in one delta keep only the last, which
    -- CLAUDE.md records as a bench that reported 13 checks for a body
    -- containing 60 and passed.
    acc : process(clk)
      variable nbv : natural := 0;
    begin
      if rising_edge(clk) then
        cyc <= cyc + 1;
        if w_valid = '1' and rdy = '1' and w_cnt < PN then
          if w_data /= wword(w_cnt / NB, w_cnt mod NB) then
            nbv := nbv + 1;
            if nbv < 8 then
              report NAME & " PROBE: WEIGHT word " & integer'image(w_cnt) &
                     " reassembled wrong" severity error;
            end if;
          end if;
          if w_cnt = 0      then w_t1 <= cyc; end if;
          if w_cnt = PN - 1 then w_tN <= cyc; end if;
          w_cnt <= w_cnt + 1;
        end if;
        if s_valid = '1' and rdy = '1' and s_cnt < PN then
          if s_data /= sword(s_cnt / NB, s_cnt mod NB) then
            nbv := nbv + 1;
            if nbv < 8 then
              report NAME & " PROBE: SCALE group " & integer'image(s_cnt) &
                     " reassembled wrong" severity error;
            end if;
          end if;
          if s_cnt = 0      then s_t1 <= cyc; end if;
          if s_cnt = PN - 1 then s_tN <= cyc; end if;
          s_cnt <= s_cnt + 1;
        end if;
        p_bad <= nbv;
      end if;
    end process;

    prb : process
      variable wc, sc : integer;
    begin
      wait until rst = '0';
      wait until rising_edge(clk);
      start <= '1';
      wait until rising_edge(clk);
      start <= '0';

      -- PHASE 1 -- stock.  p_go is already '0'.
      while minb < PN loop wait until rising_edge(clk); end loop;
      wait until rising_edge(clk);
      wait until rising_edge(clk);

      -- PHASE 2 -- flat out.
      p_go <= '1';
      while w_cnt < PN or s_cnt < PN loop wait until rising_edge(clk); end loop;
      wait until rising_edge(clk);

      wc := w_tN - w_t1;
      sc := s_tN - s_t1;
      i_wcyc <= wc;
      i_scyc <= sc;
      i_bad  <= p_bad;
      wait until rising_edge(clk);

      report NAME & " CADENCE fast_pop=" & boolean'image(FASTP) &
             " dual=" & boolean'image(DUAL) & ": " & integer'image(PN) &
             " accepts span " & integer'image(wc) & " core cycles on the " &
             integer'image(NPW) & "-way weight rendezvous and " &
             integer'image(sc) & " on the " & integer'image(NPS) &
             "-way scale rendezvous (ideal 1/cycle = " &
             integer'image(PN - 1) & "), " & integer'image(p_bad) &
             " wrong" severity note;

      i_done <= true;
      wait;
    end process;
  end generate;
end architecture;


-- ---------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity tb_weight_streamer is
end entity;

architecture sim of tb_weight_streamer is
  signal clk  : std_logic := '0';
  -- The HBM AXI clock.  3 ns half-period against the core's 5 ns is 1.67x,
  -- the direction the FK33 actually has, and it is generated unconditionally
  -- from its own process: an instance at DUAL=false ignores it, and nothing
  -- anywhere selects a clock through a signal assignment.
  signal aclk : std_logic := '0';
  signal rst : std_logic := '1';
  signal finished : boolean := false;
  signal d_a, d_b : boolean;
  signal b_a, b_b : natural;

  -- TRACK POPPORT arms.
  signal d_ds, d_df, d_ps, d_pf, d_qs, d_qf : boolean;
  signal b_ds, b_df, b_ps, b_pf, b_qs, b_qf : natural;
  signal wc_ps, wc_pf, wc_qs, wc_qf : integer;
  signal sc_ps, sc_pf, sc_qs, sc_qf : integer;

  -- ---------------------------------------------------------------- bounds
  -- MEASURED FIRST, WITH THE BOUNDS OFF, and only then written down.  At
  -- PN = 21 the four probes reported, with no scatter at all:
  --
  --     dual   slow  weight 30  scale 29     dual   fast  weight 20  scale 20
  --     single slow  weight 30  scale 29     single fast  weight 20  scale 20
  --
  -- PN accepts span PN-1 = 20 gaps, so 20 is EXACTLY one word per core cycle
  -- and 30 is EXACTLY the 1.5 core cycles per beat POPCOVER measured on a
  -- single FIFO.  The 24-way rendezvous therefore costs nothing: the ports
  -- do not drift out of phase, which is the composition question and was not
  -- answerable per-port.  The scale side's 29 is one less because `s_hold`
  -- is PRE-LOADED during the shut phase -- s_take fires once on s_hv='0'
  -- with s_ready still low -- so the window's first accept needs no pop and
  -- the first pop overlaps it (DERIVED; the 29 is MEASURED).
  --
  -- FAST_MAX is the ideal EXACTLY, not a fitted number: a FIFO cannot emit
  -- more than one beat per cycle, so 20 is a hard floor and `<= 20` means
  -- `= 20`.  A future change that costs even one bubble is a real rate
  -- regression and should turn this red.
  --
  -- SLOW_MIN is deliberately NOT the measured 29/30.  The question it asks
  -- is "is the shipping arm fast", and any threshold in (20, 29) answers it;
  -- 25 sits 5 above the fast ideal and 4 below the slower of the two
  -- measurements, so it is not a hair-trigger in either direction.
  --
  -- TWO-SIDED, and that is the whole point of the pair.  FAST_MAX alone
  -- passes a build where the lever does nothing; SLOW_MIN alone passes one
  -- where it is wired on.  Both of those are defects that POPCOVER showed no
  -- value oracle in this project reports a single error on.
  constant PNW      : positive := 21;
  constant FAST_MAX : natural  := PNW - 1;  -- 20, one accept per core cycle
  constant SLOW_MIN : natural  := PNW + 4;  -- 25, between 20 and 29
begin
  rst <= '1', '0' after 40 ns;

  clkgen : process
  begin
    while not finished loop
      clk <= '0'; wait for 5 ns; clk <= '1'; wait for 5 ns;
    end loop;
    wait;
  end process;

  aclkgen : process
  begin
    while not finished loop
      aclk <= '0'; wait for 3 ns; aclk <= '1'; wait for 3 ns;
    end loop;
    wait;
  end process;

  -- A: the FK33 target.  6144-bit tile word over 24 x 256-bit sub-regions, a
  -- 768-bit scale group over 3.  A slice spans two rows.
  fk33 : entity work.ws_check
    generic map(NAME => "ROWS_IF=48 AXI_DW=256", ROWS_IF => 48, BLK => 32,
                AXI_DW => 256, NPW => 24, NPS => 3, MAXB => 128,
                TILES => 3, NB => 5, STALL => 3)
    port map(clk => clk, rst => rst, done => d_a, nbad => b_a);

  -- B: the AXU3EG, already built.  This is the case 6.5 pinned; it must not
  -- have moved.  A slice IS a row, GRP=2, and the last superword is padded.
  axu3eg : entity work.ws_check
    generic map(NAME => "ROWS_IF=4 AXI_DW=128", ROWS_IF => 4, BLK => 32,
                AXI_DW => 128, NPW => 4, NPS => 1, MAXB => 256,
                TILES => 3, NB => 5, STALL => 4)
    port map(clk => clk, rst => rst, done => d_b, nbad => b_b);

  -- =======================================================================
  -- TRACK POPPORT: the card's arm, at the card's geometry.
  --
  -- Six instances, all at geometry A's 27 masters.  Four of them run
  -- DUAL=true, which is what hw/fk33/rtl/fk33_engine.vhd:1171 instantiates
  -- and which selects axi_rd_port's g_dc -- async_fifo with the real clock
  -- domain crossing, not stream_fifo.  The two remaining probes hold the
  -- single-clock branch, because FAST_POP is forwarded at TWO sites in
  -- rtl/axi_rd_port.vhd (:276 and :397) and a generic dropped from one of
  -- them is invisible at the other's DUAL_CLK.
  -- =======================================================================

  -- VALUE, card FIFO, shipping cadence.  The attribution control for the
  -- one below it: a FAIL at FAST_POP=true means the lever, not DUAL_CLK.
  fk33_dcslow : entity work.ws_check
    generic map(NAME => "CARD-FIFO fast_pop=false", ROWS_IF => 48, BLK => 32,
                AXI_DW => 256, NPW => 24, NPS => 3, MAXB => 128,
                TILES => 3, NB => 5, STALL => 3,
                DUAL => true, FASTP => false)
    port map(clk => clk, rst => rst, aclk => aclk, done => d_ds, nbad => b_ds);

  -- VALUE, THE CARD.  DUAL_CLK=true and FAST_POP=true, which is the exact
  -- pair build 11b's bitstream carries.
  fk33_dcfast : entity work.ws_check
    generic map(NAME => "CARD fast_pop=true", ROWS_IF => 48, BLK => 32,
                AXI_DW => 256, NPW => 24, NPS => 3, MAXB => 128,
                TILES => 3, NB => 5, STALL => 3,
                DUAL => true, FASTP => true)
    port map(clk => clk, rst => rst, aclk => aclk, done => d_df, nbad => b_df);

  -- CADENCE, dual clock.  TILES*NB = 24 words so the FIFOs can be stocked
  -- with more than the PNW the window consumes; DEPTH is 64 inside ws_check,
  -- so nothing is capacity-bound.  STALL=0 so the stocking phase is quick
  -- and deterministic; the window itself contains no AXI activity at all.
  prb_dcslow : entity work.ws_check
    generic map(NAME => "PROBE dual", ROWS_IF => 48, BLK => 32,
                AXI_DW => 256, NPW => 24, NPS => 3, MAXB => 128,
                TILES => 4, NB => 6, STALL => 0,
                DUAL => true, FASTP => false, PROBE => true, PN => PNW)
    port map(clk => clk, rst => rst, aclk => aclk, done => d_ps, nbad => b_ps,
             w_cyc => wc_ps, s_cyc => sc_ps);

  prb_dcfast : entity work.ws_check
    generic map(NAME => "PROBE dual", ROWS_IF => 48, BLK => 32,
                AXI_DW => 256, NPW => 24, NPS => 3, MAXB => 128,
                TILES => 4, NB => 6, STALL => 0,
                DUAL => true, FASTP => true, PROBE => true, PN => PNW)
    port map(clk => clk, rst => rst, aclk => aclk, done => d_pf, nbad => b_pf,
             w_cyc => wc_pf, s_cyc => sc_pf);

  -- CADENCE, single clock: axi_rd_port's OTHER forwarding site, into
  -- stream_fifo.  Not the card's arm, and covered here only because the
  -- generic is threaded twice and one of the two could be dropped alone.
  prb_scslow : entity work.ws_check
    generic map(NAME => "PROBE single", ROWS_IF => 48, BLK => 32,
                AXI_DW => 256, NPW => 24, NPS => 3, MAXB => 128,
                TILES => 4, NB => 6, STALL => 0,
                DUAL => false, FASTP => false, PROBE => true, PN => PNW)
    port map(clk => clk, rst => rst, done => d_qs, nbad => b_qs,
             w_cyc => wc_qs, s_cyc => sc_qs);

  prb_scfast : entity work.ws_check
    generic map(NAME => "PROBE single", ROWS_IF => 48, BLK => 32,
                AXI_DW => 256, NPW => 24, NPS => 3, MAXB => 128,
                TILES => 4, NB => 6, STALL => 0,
                DUAL => false, FASTP => true, PROBE => true, PN => PNW)
    port map(clk => clk, rst => rst, done => d_qf, nbad => b_qf,
             w_cyc => wc_qf, s_cyc => sc_qf);

  verdict : process
  begin
    wait until d_a and d_b and d_ds and d_df and d_ps and d_pf
               and d_qs and d_qf;
    wait until rising_edge(clk);

    -- THE MARKER LINE.  sim/regress.sh keys this row's PASS on the exact
    -- string '0 reassembly errors across both geometries', so the sentence
    -- and its counter must not move -- but a non-zero exit is checked BEFORE
    -- the marker, so a cadence assert below still scores FAIL and not a
    -- pass.  The counter now sums every VALUE arm, the four new ones
    -- included; cadence is reported separately and never folded in, because
    -- calling a cadence miss a "reassembly error" would be a lie.
    report "weight_streamer: " &
           integer'image(b_a + b_b + b_ds + b_df + b_ps + b_pf + b_qs + b_qf) &
           " reassembly errors across both geometries" severity note;
    report "weight_streamer CADENCE (cycles spanned by " & integer'image(PNW) &
           " accepts, weight/scale): dual slow " & integer'image(wc_ps) &
           "/" & integer'image(sc_ps) & "  dual fast " & integer'image(wc_pf) &
           "/" & integer'image(sc_pf) & "  single slow " &
           integer'image(wc_qs) & "/" & integer'image(sc_qs) &
           "  single fast " & integer'image(wc_qf) & "/" &
           integer'image(sc_qf) severity note;

    assert b_a = 0
      report "weight_streamer REASSEMBLED THE FK33 GEOMETRY WRONG"
      severity failure;
    assert b_b = 0
      report "weight_streamer REASSEMBLED THE AXU3EG GEOMETRY WRONG"
      severity failure;
    assert b_ds = 0
      report "weight_streamer REASSEMBLED WRONG AT DUAL_CLK (fast_pop=false)"
      severity failure;
    assert b_df = 0
      report "weight_streamer REASSEMBLED WRONG AT THE CARD'S ARM " &
             "(DUAL_CLK=true, FAST_POP=true)"
      severity failure;
    assert b_ps = 0 and b_pf = 0 and b_qs = 0 and b_qf = 0
      report "weight_streamer REASSEMBLED WRONG INSIDE A CADENCE PROBE"
      severity failure;

    -- ------------------------------------------------- P2 and P3, two-sided
    assert wc_pf <= FAST_MAX and sc_pf <= FAST_MAX
      report "FAST_POP=true AT THE CARD'S ARM IS NOT FAST: the 24-way weight " &
             "rendezvous spans " & integer'image(wc_pf) & " cycles and the " &
             "3-way scale rendezvous " & integer'image(sc_pf) & " for " &
             integer'image(PNW) & " accepts, against " &
             integer'image(FAST_MAX) & " for one per cycle.  The lever is " &
             "not reaching every port, or not reaching async_fifo at all"
      severity failure;
    assert wc_ps >= SLOW_MIN and sc_ps >= SLOW_MIN
      report "FAST_POP=false IS FAST: the shipping arm spans " &
             integer'image(wc_ps) & "/" & integer'image(sc_ps) &
             " cycles where the shipping cadence floor is " &
             integer'image(SLOW_MIN) & ".  The lever is WIRED ON, so the " &
             "default every other bench and every non-FK33 build runs has " &
             "silently changed"
      severity failure;
    assert wc_qf <= FAST_MAX and sc_qf <= FAST_MAX
      report "FAST_POP=true IS NOT FAST IN THE SINGLE-CLOCK BRANCH: " &
             integer'image(wc_qf) & "/" & integer'image(sc_qf) &
             " against " & integer'image(FAST_MAX) & ".  axi_rd_port " &
             "forwards the generic at two sites; this is the stream_fifo one"
      severity failure;
    assert wc_qs >= SLOW_MIN and sc_qs >= SLOW_MIN
      report "FAST_POP=false IS FAST IN THE SINGLE-CLOCK BRANCH: " &
             integer'image(wc_qs) & "/" & integer'image(sc_qs) &
             " against " & integer'image(SLOW_MIN)
      severity failure;

    finished <= true;
    wait;
  end process;
end architecture;
