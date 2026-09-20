-- rtl/weight_streamer.vhd -- subsystem A weight/scale streaming front end.
--
-- Spec: docs/superpowers/specs/2026-08-20-int4-streaming-matvec-design.md 7.7
--
-- This is the DEVICE-SPECIFIC half of 7.1: it owns the AXI masters, so it is
-- DDR4 on the AXU3EG and HBM on the FK33, while matvec_core below it is neither.
--
-- REASSEMBLY IS LANE-SPLIT, NOT GRANULE ROUND-ROBIN.  Rev 2 of the spec striped
-- the weight region across ports in 4 KB granules and popped granules in the
-- same order; that delivers AXI_DW bits per cycle, not NPORTS_W*AXI_DW, because
-- at any instant the current granule lives in exactly ONE port's FIFO.  Rev 3
-- patched it with per-port width conversion and a drain schedule, which works
-- but costs ~8 BRAM36 per port for the read port width alone.  Rev 4 moved the
-- interleave into the PACKER instead: sub-region p holds lane p of every word,
-- so each port reads its own region as plain sequential bursts and the merge
-- here is pure wiring with no mux, no width conversion, no drain schedule and
-- no reordering.
--
--     W_t = { fifo(NPORTS_W-1)[t], ... , fifo1[t], fifo0[t] }
--
-- Scales get a DEDICATED port rather than sharing a weight port.  Sharing would
-- leave (NPORTS_W-1)*AXI_DW + ROWS_IF*16 bits/cycle for weights, below what the
-- array consumes, and interleaving scales into the weight region would break
-- the 4 KB alignment the sub-region layout depends on.
--
-- GENERALISED 2026-08-28 to spec 6.5a.  Two things here were pinned at
-- AXI_DW = 128 and blocked the FK33, whose HBM SAXI ports are 256 bits:
--
--   1. The WEIGHT merge was already general and only its comments were not.
--      6.5a says weight sub-region p carries bit slice p of the tile word, and
--      `w_data((p+1)*AXI_DW-1 downto p*AXI_DW) <= qd(p)` is exactly that for
--      every AXI_DW.  What was pinned at 128 was the CLAIM that a lane is a
--      row.  At ROWS_IF=48/AXI_DW=256 slice p carries rows 2p and 2p+1, and
--      this merge delivers them without change; the packer had to move, not
--      the RTL.  Only the assert stayed, and it stays.
--
--   2. The SCALE path assumed one sub-region, i.e. that a whole group of
--      ROWS_IF scales fits one beat.  At ROWS_IF=48 a group is 768 bits
--      against a 256-bit port, so it needs three.  NPORTS_S is now a generic,
--      the scale ports are popped in the same all-valid lockstep as the weight
--      ports, and the holding register is the SUPERWORD of NPORTS_S*AXI_DW
--      bits that 6.5a defines.  GRP = NPORTS_S*AXI_DW / SW groups come out of
--      it one per cycle.
--
-- NPORTS_S defaults to 1, at which the superword is one beat, GRP is the old
-- UNPACK, and the lockstep pop over one port is the old single-port pop -- so
-- the AXU3EG build and every instantiation of this entity are untouched.
--
-- CLOSED 2026-08-28 (spec 14.5 item 3): this entity used to be SINGLE-CLOCK,
-- and the FK33's HBM AXI clock is not the core clock.  The CDC now lives one
-- level down, in rtl/axi_rd_port.vhd, because that is where the only FIFO in
-- the weight path already is and it is the only point where a word crosses.
-- Set DUAL_CLK and drive `aclk`; everything below this line stays in the core
-- domain, so the merge, the scale unpack and the assert set are unchanged.
-- The default is false, at which `aclk` is ignored and every existing
-- instantiation is bit-identical to before.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity weight_streamer is
  generic(
    NPORTS_W : positive := 4;      -- 7.7; spec 14.4 pins 4 on the AXU3EG
    -- Scale sub-regions, spec 6.5a: lcm(ROWS_IF*16, AXI_DW) / AXI_DW, which is
    -- 1 on the AXU3EG and 3 at ROWS_IF=48 / AXI_DW=256.  Asserted below rather
    -- than derived, because deriving it needs an lcm at elaboration and an
    -- assert that the caller and the PACKED FILE agree is the thing that
    -- actually matters.
    NPORTS_S : positive := 1;
    AXI_DW   : positive := 128;
    ADDR_W   : positive := 32;
    ROWS_IF  : positive := 4;
    BLK      : positive := 32;
    DEPTH    : positive := 512;    -- beats per FIFO, 7.7 budgets 8 KB
    -- Beats per burst.  MAXB*AXI_DW/8 must not exceed 4096: AXI4 forbids a
    -- burst crossing a 4 KB boundary and the sub-regions are 4 KB aligned, so
    -- 256 beats is exactly one burst at 128 bits and TWICE the legal size at
    -- 256.  An AXI_DW=256 build must pass MAXB=128.  Asserted below.
    MAXB     : positive := 256;
    -- Bursts allowed in flight per port. Was hardcoded at axi_rd_port's default
    -- of 2 because it was never plumbed through, which made it untestable: on
    -- the AXU3EG every port sustains 0.664 beats/cycle, and 256/(256+L) fits
    -- that at L~129 cycles of read latency, i.e. the port spends a third of its
    -- time waiting rather than the FIFO being drained faster than DDR fills it.
    -- Matters MORE on HBM, whose latency is higher than DDR's.
    -- RAISED TO 16 on 2026-08-28 to match axi_rd_port's new default and the
    -- 288.0 GB/s measurement; see that file's MAXOUT comment for the cost.
    MAXOUT   : positive := 16;
    -- Run the AXI masters on `aclk` instead of `clk`.  See the header.
    DUAL_CLK : boolean := false;
    -- FAST_POP -- forwarded to EVERY one of the NPORTS_W + NPORTS_S ports,
    -- weight and scale alike, and that is the point: matvec_core accepts a
    -- word only when all of them present a beat in the SAME cycle
    -- (rtl/matvec_core.vhd:860), so a rate lever applied to some of them and
    -- not the others buys nothing at all.  false is the shipping cadence.
    FAST_POP : boolean := false
  );
  port(
    clk, rst : in  std_logic;
    -- HBM AXI clock.  IGNORED when DUAL_CLK = false, and defaulted so that no
    -- existing instantiation or testbench needs an edit.
    aclk     : in  std_logic := '0';

    -- job.  Sub-region bases come from the packed header (6.4), which carries
    -- NPORTS_W of them precisely because the file is tied to NPORTS_W as well
    -- as to ROWS_IF.
    start    : in  std_logic;
    w_base   : in  std_logic_vector(NPORTS_W*ADDR_W-1 downto 0);
    w_beats  : in  integer;        -- beats per weight sub-region
    -- NPORTS_S scale sub-region bases, s_sub_offset[] of the header (6.4).
    -- At the default NPORTS_S=1 this is the single ADDR_W vector it always was.
    s_base   : in  std_logic_vector(NPORTS_S*ADDR_W-1 downto 0);
    s_beats  : in  integer;        -- beats per scale sub-region

    -- NPORTS_W+NPORTS_S AXI4 read masters, flattened; indices
    -- NPORTS_W .. NPORTS_W+NPORTS_S-1 are the scale ports
    m_arvalid : out std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
    m_arready : in  std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
    m_araddr  : out std_logic_vector((NPORTS_W+NPORTS_S)*ADDR_W-1 downto 0);
    m_arlen   : out std_logic_vector((NPORTS_W+NPORTS_S)*8-1 downto 0);
    m_arsize  : out std_logic_vector((NPORTS_W+NPORTS_S)*3-1 downto 0);
    m_arburst : out std_logic_vector((NPORTS_W+NPORTS_S)*2-1 downto 0);
    m_rvalid  : in  std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
    m_rready  : out std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);
    m_rdata   : in  std_logic_vector((NPORTS_W+NPORTS_S)*AXI_DW-1 downto 0);
    m_rlast   : in  std_logic_vector(NPORTS_W+NPORTS_S-1 downto 0);

    -- to matvec_core
    w_valid : out std_logic;
    w_data  : out std_logic_vector(ROWS_IF*BLK*4-1 downto 0);
    w_ready : in  std_logic;
    s_valid : out std_logic;
    s_data  : out std_logic_vector(ROWS_IF*16-1 downto 0);
    s_ready : in  std_logic
  );
end entity;

architecture rtl of weight_streamer is
  constant SW     : positive := ROWS_IF * 16;        -- scale bits per cycle
  -- Spec 6.5a.  SUPER is the scale superword; GRP is how many cycles' worth of
  -- scales it carries.  Exactly one of NPORTS_S and GRP exceeds 1 for any
  -- power-of-two geometry, but nothing below depends on that.
  constant SUPER  : positive := NPORTS_S * AXI_DW;
  constant GRP    : positive := SUPER / SW;
  constant NP_ALL : positive := NPORTS_W + NPORTS_S;

  -- The MINIMAL NPORTS_S of 6.5a, computed so the assert below can check the
  -- caller against the packed file rather than trusting the generic.  n = SW
  -- always satisfies the condition, so the loop always returns.
  function nss_min(sw_bits, dw : positive) return positive is
  begin
    for n in 1 to sw_bits loop
      if (n * dw) mod sw_bits = 0 then return n; end if;
    end loop;
    return sw_bits;
  end function;

  signal qv, qr : std_logic_vector(NP_ALL-1 downto 0);
  type qd_t is array(0 to NP_ALL-1) of std_logic_vector(AXI_DW-1 downto 0);
  signal qd : qd_t;

  signal all_v : std_logic;
  signal pop_w : std_logic;

  -- scale unpack
  signal s_allv  : std_logic;
  signal s_hold  : std_logic_vector(SUPER-1 downto 0) := (others => '0');
  signal s_hv    : std_logic := '0';
  signal s_chunk : integer range 0 to GRP-1 := 0;
  signal s_take  : std_logic;
begin
  -- 6.5 invariant.  Break it and the packed file no longer describes what this
  -- merge produces, which is a silent wrong answer, not a build failure.
  assert NPORTS_W * AXI_DW = ROWS_IF * BLK * 4
    report "weight_streamer: 6.5 invariant NPORTS_W*AXI_DW = ROWS_IF*BLK*4 is " &
           "violated; the packed file does not match this reassembly"
    severity failure;
  -- 6.5a: the superword must hold a whole number of scale groups, and it must
  -- be the SMALLEST such superword, because a larger one that also divides
  -- describes a different file.  This replaces the old "AXI_DW >= SW and
  -- AXI_DW mod SW = 0", which was that same condition at NPORTS_S = 1.
  assert SUPER mod SW = 0
    report "weight_streamer: 6.5a superword NPORTS_S*AXI_DW does not hold a " &
           "whole number of ROWS_IF*16-bit scale groups"
    severity failure;
  assert NPORTS_S = nss_min(SW, AXI_DW)
    report "weight_streamer: NPORTS_S is not the minimal n_scale_sub of 6.5a; " &
           "the packed file's scale sub-regions are cut differently"
    severity failure;
  -- AXI4 forbids a burst crossing a 4 KB boundary.  MAXB was justified in 6.4
  -- as "256 beats x 16 bytes = one 4 KB burst", which stops being true the
  -- moment AXI_DW moves: at 256 bits the same MAXB is an 8 KB burst.
  assert MAXB * (AXI_DW / 8) <= 4096
    report "weight_streamer: MAXB*AXI_DW/8 exceeds 4096, so a burst would " &
           "cross a 4 KB boundary (AXI4 forbids it); use MAXB=128 at AXI_DW=256 " &
           "on an AXI4 slave -- but note the FK33 HBM slave is AXI3, whose " &
           "ARLEN is 4 bits, so 16 beats is the real cap there (see " &
           "rtl/hbm_tg_ip.vhd:1036).  This assert deliberately does NOT enforce " &
           "16: weight_streamer is generic and may drive an AXI4 slave"
    severity failure;

  gen_w : for p in 0 to NPORTS_W-1 generate
    port_p : entity work.axi_rd_port
      generic map(AXI_DW => AXI_DW, ADDR_W => ADDR_W, DEPTH => DEPTH,
                  MAXB => MAXB, MAXOUT => MAXOUT, DUAL_CLK => DUAL_CLK,
                  FAST_POP => FAST_POP)
      port map(
        clk => clk, rst => rst, aclk => aclk, start => start,
        base => w_base((p+1)*ADDR_W-1 downto p*ADDR_W), n_beats => w_beats,
        arvalid => m_arvalid(p), arready => m_arready(p),
        araddr  => m_araddr((p+1)*ADDR_W-1 downto p*ADDR_W),
        arlen   => m_arlen((p+1)*8-1 downto p*8),
        arsize  => m_arsize((p+1)*3-1 downto p*3),
        arburst => m_arburst((p+1)*2-1 downto p*2),
        rvalid  => m_rvalid(p), rready => m_rready(p),
        rdata   => m_rdata((p+1)*AXI_DW-1 downto p*AXI_DW),
        rlast   => m_rlast(p),
        q_valid => qv(p), q_data => qd(p), q_ready => qr(p));
  end generate;

  -- One port per scale sub-region.  All NPORTS_S read the same number of beats
  -- from their own 4 KB-aligned region, exactly like the weight ports.
  gen_s : for q in 0 to NPORTS_S-1 generate
    scale_port : entity work.axi_rd_port
      generic map(AXI_DW => AXI_DW, ADDR_W => ADDR_W, DEPTH => DEPTH,
                  MAXB => MAXB, MAXOUT => MAXOUT, DUAL_CLK => DUAL_CLK,
                  FAST_POP => FAST_POP)
      port map(
        clk => clk, rst => rst, aclk => aclk, start => start,
        base => s_base((q+1)*ADDR_W-1 downto q*ADDR_W), n_beats => s_beats,
        arvalid => m_arvalid(NPORTS_W+q), arready => m_arready(NPORTS_W+q),
        araddr  => m_araddr((NPORTS_W+q+1)*ADDR_W-1 downto (NPORTS_W+q)*ADDR_W),
        arlen   => m_arlen((NPORTS_W+q+1)*8-1 downto (NPORTS_W+q)*8),
        arsize  => m_arsize((NPORTS_W+q+1)*3-1 downto (NPORTS_W+q)*3),
        arburst => m_arburst((NPORTS_W+q+1)*2-1 downto (NPORTS_W+q)*2),
        rvalid  => m_rvalid(NPORTS_W+q), rready => m_rready(NPORTS_W+q),
        rdata   => m_rdata((NPORTS_W+q+1)*AXI_DW-1 downto (NPORTS_W+q)*AXI_DW),
        rlast   => m_rlast(NPORTS_W+q),
        q_valid => qv(NPORTS_W+q), q_data => qd(NPORTS_W+q),
        q_ready => qr(NPORTS_W+q));
  end generate;

  -- ------------------------------------------------------------ weight merge
  -- POP GATE: pop only when EVERY weight FIFO is non-empty, so the lanes can
  -- never come from different words.  Obvious -- and so was rev 2's reassembly.
  agg : process(qv)
    variable a : std_logic;
  begin
    a := '1';
    for p in 0 to NPORTS_W-1 loop a := a and qv(p); end loop;
    all_v <= a;
  end process;

  pop_w   <= all_v and w_ready;
  w_valid <= all_v;

  -- 6.5a: weight sub-region p carries bit slice p of the tile word, so the
  -- merge is the same slice assignment at every AXI_DW.  At AXI_DW = BLK*4 a
  -- slice is one row; at 256 bits with BLK=32 it is rows 2p and 2p+1.  Nothing
  -- here needs to know which, and that is the point.
  wire : for p in 0 to NPORTS_W-1 generate
    w_data((p+1)*AXI_DW-1 downto p*AXI_DW) <= qd(p);
    qr(p) <= pop_w;
  end generate;

  -- ------------------------------------------------------------- scale unpack
  -- 6.5a: the NPORTS_S scale sub-regions are the slices of one SUPERWORD, and
  -- the superword carries GRP cycles' worth of scales (7.7's UNPACK, which is
  -- this at NPORTS_S=1: two at ROWS_IF=4/AXI_DW=128).  At ROWS_IF=48/AXI_DW=256
  -- it is the other way round -- three slices, GRP=1 -- and the same code
  -- serves both because the superword is assembled before it is chunked.
  --
  -- The pop is the SAME all-valid lockstep as the weight side, for the same
  -- reason: pop a scale FIFO on its own and the slices of one superword would
  -- come from different superwords.  Refill is allowed in the SAME cycle the
  -- last chunk is consumed, otherwise the scale path bubbles every GRP cycles
  -- and stalls the array.
  s_agg : process(qv)
    variable a : std_logic;
  begin
    a := '1';
    for q in 0 to NPORTS_S-1 loop a := a and qv(NPORTS_W+q); end loop;
    s_allv <= a;
  end process;

  s_take <= '1' when s_allv = '1'
                 and (s_hv = '0' or (s_ready = '1' and s_chunk = GRP-1))
            else '0';
  gen_sr : for q in 0 to NPORTS_S-1 generate
    qr(NPORTS_W+q) <= s_take;
  end generate;

  s_valid <= s_hv;
  s_data  <= s_hold((s_chunk+1)*SW-1 downto s_chunk*SW);

  process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' or start = '1' then
        s_hv <= '0'; s_chunk <= 0;
      else
        if s_hv = '1' and s_ready = '1' then
          if s_chunk = GRP-1 then
            s_chunk <= 0;
            s_hv    <= '0';
          else
            s_chunk <= s_chunk + 1;
          end if;
        end if;
        if s_take = '1' then
          -- slice q of the superword comes from scale sub-region q, LSB first
          for q in 0 to NPORTS_S-1 loop
            s_hold((q+1)*AXI_DW-1 downto q*AXI_DW) <= qd(NPORTS_W+q);
          end loop;
          s_hv    <= '1';
          s_chunk <= 0;
        end if;
      end if;
    end if;
  end process;
end architecture;
