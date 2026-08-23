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

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity weight_streamer is
  generic(
    NPORTS_W : positive := 4;      -- 7.7; spec 14.4 pins 4 on the AXU3EG
    AXI_DW   : positive := 128;
    ADDR_W   : positive := 32;
    ROWS_IF  : positive := 4;
    BLK      : positive := 32;
    DEPTH    : positive := 512;    -- beats per FIFO, 7.7 budgets 8 KB
    MAXB     : positive := 256     -- beats per burst: 256 x 16 B = 4 KB
  );
  port(
    clk, rst : in  std_logic;

    -- job.  Sub-region bases come from the packed header (6.4), which carries
    -- NPORTS_W of them precisely because the file is tied to NPORTS_W as well
    -- as to ROWS_IF.
    start    : in  std_logic;
    w_base   : in  std_logic_vector(NPORTS_W*ADDR_W-1 downto 0);
    w_beats  : in  integer;        -- beats per weight sub-region
    s_base   : in  std_logic_vector(ADDR_W-1 downto 0);
    s_beats  : in  integer;

    -- NPORTS_W+1 AXI4 read masters, flattened; index NPORTS_W is the scale port
    m_arvalid : out std_logic_vector(NPORTS_W downto 0);
    m_arready : in  std_logic_vector(NPORTS_W downto 0);
    m_araddr  : out std_logic_vector((NPORTS_W+1)*ADDR_W-1 downto 0);
    m_arlen   : out std_logic_vector((NPORTS_W+1)*8-1 downto 0);
    m_arsize  : out std_logic_vector((NPORTS_W+1)*3-1 downto 0);
    m_arburst : out std_logic_vector((NPORTS_W+1)*2-1 downto 0);
    m_rvalid  : in  std_logic_vector(NPORTS_W downto 0);
    m_rready  : out std_logic_vector(NPORTS_W downto 0);
    m_rdata   : in  std_logic_vector((NPORTS_W+1)*AXI_DW-1 downto 0);
    m_rlast   : in  std_logic_vector(NPORTS_W downto 0);

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
  constant UNPACK : positive := AXI_DW / SW;

  signal qv, qr : std_logic_vector(NPORTS_W downto 0);
  type qd_t is array(0 to NPORTS_W) of std_logic_vector(AXI_DW-1 downto 0);
  signal qd : qd_t;

  signal all_v : std_logic;
  signal pop_w : std_logic;

  -- scale unpack
  signal s_hold  : std_logic_vector(AXI_DW-1 downto 0) := (others => '0');
  signal s_hv    : std_logic := '0';
  signal s_chunk : integer range 0 to UNPACK-1 := 0;
  signal s_take  : std_logic;
begin
  -- 6.5 invariant.  Break it and the packed file no longer describes what this
  -- merge produces, which is a silent wrong answer, not a build failure.
  assert NPORTS_W * AXI_DW = ROWS_IF * BLK * 4
    report "weight_streamer: 6.5 invariant NPORTS_W*AXI_DW = ROWS_IF*BLK*4 is " &
           "violated; the packed file does not match this reassembly"
    severity failure;
  -- 14.5: at ROWS_IF=80 the scale path needs SW = 1,280 bits/cycle against one
  -- 256-bit HBM port, so it must become several sub-regions.  The header
  -- already carries n_scale_sub for that; this build does not implement it.
  assert AXI_DW >= SW and AXI_DW mod SW = 0
    report "weight_streamer: scale path needs multiple sub-regions at this " &
           "ROWS_IF (spec 14.5); not implemented"
    severity failure;

  gen_w : for p in 0 to NPORTS_W-1 generate
    port_p : entity work.axi_rd_port
      generic map(AXI_DW => AXI_DW, ADDR_W => ADDR_W, DEPTH => DEPTH,
                  MAXB => MAXB)
      port map(
        clk => clk, rst => rst, start => start,
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

  scale_port : entity work.axi_rd_port
    generic map(AXI_DW => AXI_DW, ADDR_W => ADDR_W, DEPTH => DEPTH,
                MAXB => MAXB)
    port map(
      clk => clk, rst => rst, start => start,
      base => s_base, n_beats => s_beats,
      arvalid => m_arvalid(NPORTS_W), arready => m_arready(NPORTS_W),
      araddr  => m_araddr((NPORTS_W+1)*ADDR_W-1 downto NPORTS_W*ADDR_W),
      arlen   => m_arlen((NPORTS_W+1)*8-1 downto NPORTS_W*8),
      arsize  => m_arsize((NPORTS_W+1)*3-1 downto NPORTS_W*3),
      arburst => m_arburst((NPORTS_W+1)*2-1 downto NPORTS_W*2),
      rvalid  => m_rvalid(NPORTS_W), rready => m_rready(NPORTS_W),
      rdata   => m_rdata((NPORTS_W+1)*AXI_DW-1 downto NPORTS_W*AXI_DW),
      rlast   => m_rlast(NPORTS_W),
      q_valid => qv(NPORTS_W), q_data => qd(NPORTS_W), q_ready => qr(NPORTS_W));

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

  wire : for p in 0 to NPORTS_W-1 generate
    w_data((p+1)*AXI_DW-1 downto p*AXI_DW) <= qd(p);
    qr(p) <= pop_w;
  end generate;

  -- ------------------------------------------------------------- scale unpack
  -- One AXI beat carries UNPACK cycles' worth of scales (7.7: two at ROWS_IF=4).
  -- Refill is allowed in the SAME cycle the last chunk is consumed, otherwise
  -- the scale path would bubble every UNPACK cycles and stall the array.
  s_take <= '1' when qv(NPORTS_W) = '1'
                 and (s_hv = '0' or (s_ready = '1' and s_chunk = UNPACK-1))
            else '0';
  qr(NPORTS_W) <= s_take;

  s_valid <= s_hv;
  s_data  <= s_hold((s_chunk+1)*SW-1 downto s_chunk*SW);

  process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' or start = '1' then
        s_hv <= '0'; s_chunk <= 0;
      else
        if s_hv = '1' and s_ready = '1' then
          if s_chunk = UNPACK-1 then
            s_chunk <= 0;
            s_hv    <= '0';
          else
            s_chunk <= s_chunk + 1;
          end if;
        end if;
        if s_take = '1' then
          s_hold  <= qd(NPORTS_W);
          s_hv    <= '1';
          s_chunk <= 0;
        end if;
      end if;
    end if;
  end process;
end architecture;
