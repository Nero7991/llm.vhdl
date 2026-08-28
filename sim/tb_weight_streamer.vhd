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
    STALL   : natural   := 3
  );
  port(
    clk, rst : in  std_logic;
    done     : out boolean := false;
    nbad     : out natural := 0
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
begin
  done <= i_done;
  nbad <= i_bad;

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
                DEPTH => 64, MAXB => MAXB, MAXOUT => 2)
    port map(clk => clk, rst => rst, start => start,
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
end architecture;


-- ---------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity tb_weight_streamer is
end entity;

architecture sim of tb_weight_streamer is
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal finished : boolean := false;
  signal d_a, d_b : boolean;
  signal b_a, b_b : natural;
begin
  rst <= '1', '0' after 40 ns;

  clkgen : process
  begin
    while not finished loop
      clk <= '0'; wait for 5 ns; clk <= '1'; wait for 5 ns;
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

  verdict : process
  begin
    wait until d_a and d_b;
    wait until rising_edge(clk);
    report "weight_streamer: " & integer'image(b_a + b_b) &
           " reassembly errors across both geometries" severity note;
    assert b_a = 0
      report "weight_streamer REASSEMBLED THE FK33 GEOMETRY WRONG"
      severity failure;
    assert b_b = 0
      report "weight_streamer REASSEMBLED THE AXU3EG GEOMETRY WRONG"
      severity failure;
    finished <= true;
    wait;
  end process;
end architecture;
