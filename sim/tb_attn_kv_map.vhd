-- sim/tb_attn_kv_map.vhd
-- rtl/attn_kv_axi.vhd AT THE REAL 9B KV MAP, CHECKED ON VALUES.
--
-- ======================================================================
-- WHY THIS FILE EXISTS
-- ======================================================================
-- TRACK CKVMAP made subsystem C's real 9B KV map ELABORATE
-- (docs/debugging/2026-08-29_ckvmap-the-kv-map-fits-once-the-bases-are-
-- counted-in-chunks.md) and said so in its own open list:
--
--     "Nothing here checked a VALUE.  Every measurement is a shape, a width,
--      a range or an address, at elaboration.  THE REAL MAP ELABORATING IS
--      NOT THE REAL MAP WORKING."
--
-- Neither existing KV bench can close that.  MEASURED by reading them:
--
--   * sim/kv_axi_harness.vhd models memory as a DENSE byte array of NB_MAX
--     bytes and computes `rec_addr` in a VHDL `integer`.  The real K base is
--     4,521,582,592, which is 2.1x `integer'high`, so that harness cannot
--     represent the real map at all -- the same wall CGENERICS hit on the
--     generics themselves.  It runs at MAXCTX 32 with bases under 36 MB.
--   * sim/tb_attn_kv_seam.vhd is the value oracle for the C composition, but
--     at HEAD_DIM 64 / MAXCTX 8 / K_BASE 16 / V_BASE 4064 and ADDR_W 16.
--     The whole 32-bit region of the address space is outside its coverage.
--
-- So this bench exists to answer ONE question: at the real bases, the real
-- MAXCTX and the real geometry, does the KV path move the right BYTES to and
-- from the right ADDRESSES, over more than one token?
--
-- ======================================================================
-- THE TWO THINGS THAT MAKE THE REAL MAP REACHABLE IN A BENCH
-- ======================================================================
--
--   1. THE ADDRESS DOMAIN IS 16-BYTE CHUNKS EVERYWHERE ABOVE THE DUT PORT.
--      Exactly the encoding rtl/llama_top.vhd:549-550 uses for
--      C_K_BASE_CH / C_V_BASE_CH, and for exactly the same reason: the whole
--      K+V extent is 425,205,248 chunks, which fits a `natural`, while its
--      6,803,283,968 bytes do not.  The conversion back to bytes happens in
--      ONE place, `KB_C`/`VB_C` below, which is the bench's copy of
--      rtl/llama_top.vhd:3715-3720.
--
--   2. MEMORY IS SPARSE.  The modelled region spans 5.7 GB; the test touches
--      a few thousand 16-byte chunks.  `mem` is a hash of chunks and every
--      chunk that was never written reads back as POISON (-128 in every
--      byte), a value the oracle's encoding can never produce.  A read that
--      lands outside the written set therefore returns something the checker
--      can NAME as poison rather than something that merely mismatches.
--
-- ======================================================================
-- THE ORACLE, AND WHY IT IS NOT A ROUND TRIP
-- ======================================================================
-- A packer plus a reversed unpacker passes its own self-test; this project
-- has the recorded case.  Three independent anchors, not one:
--
--   A1  THE READ PATH AGAINST MEMORY THE RTL NEVER WROTE.  Phase A preseeds
--       records for layers PA_L0/PA_L1 DIRECTLY into `mem`, at addresses this
--       bench computes from C spec 2.2 in the chunk domain, and then asks the
--       DUT for them.  Nothing the write master does can make this pass.
--
--   A2  THE WRITE PATH AGAINST AN INDEPENDENTLY COMPUTED ADDRESS.  After the
--       run, every record phase B wrote is compared byte for byte at the
--       chunk address THIS FILE computes, not at the address the DUT used.
--       Two masters agreeing on a wrong address is the failure mode a
--       read-back-only check cannot see.
--
--   A3  NO STRAY WRITES.  `mem.count` must equal the expected chunk count
--       exactly.  A1/A2 say every expected chunk is right; A3 says there are
--       no others.  Together they are set equality, so a record written
--       twice -- once correctly and once somewhere else -- is caught.
--
-- AND THE PAYLOAD CARRIES ITS OWN COORDINATES.  Every record stamps
-- (region, layer, kv head, position) into fixed slots of its header AND of
-- every one of its NBLK mantissa blocks, with the block index alongside.  A
-- read that lands on the neighbouring record, the neighbouring head, the
-- neighbouring layer or the other region returns data that DECODES to the
-- wrong coordinates, and the mismatch report prints what it decoded to.
-- That is why the failure message for a mutated base names the record it
-- actually reached instead of printing two unequal integers.
--
-- ======================================================================
-- WHAT THIS DOES NOT ESTABLISH
-- ======================================================================
--   * NOT rtl/llama_top.vhd's port map.  The chunk-to-byte shift at
--     rtl/llama_top.vhd:3715-3720 is REPRODUCED here (BASE_SHIFT) so that a
--     mutation of it can be measured, but a green run of this bench is not a
--     statement about that line of llama_top.  See the write-up.
--   * NOT attention.  rtl/attn_block.vhd is not instantiated; the consumer is
--     a model that issues the port shape attn_block issues.  The composition
--     is sim/tb_attn_kv_seam.vhd's question and it runs at a toy map.
--   * NOT the real HBM.  Fixed in-order single-ID slaves.
--   * NOT every layer, head or position.  Phase A covers layers PA_L0/PA_L1
--     and Phase B covers PB_L0/PB_L1/PB_L2; positions are 0..NPOS_A-1 and
--     0..NTOK-1.  MAXCTX is the real 131,072 -- it is the address STRIDE that
--     is real, not the context actually swept, and a defect that needs
--     position 70,000 to appear is not reachable here.
--   * NOT AXI_DW other than the FK33's 256.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity tb_attn_kv_map is
  generic(
    -- ---- the real 9B attention geometry -------------------------------
    HEAD_DIM : positive := 256;
    KV_BLOCK : positive := 32;
    N_KVH    : positive := 4;
    LAYERS   : positive := 8;
    MAXCTX   : positive := 131072;
    POS_W    : positive := 18;     -- clog2(131072+1), llama_top's POSW
    AXI_DW   : positive := 256;
    ADDR_W   : positive := 33;
    MAXB     : positive := 16;
    MAXOUT   : positive := 4;
    RBUF     : positive := 4;
    -- ---- the real map, in the record's own 16-byte chunks ---------------
    -- tools/hbm_map.py: hbm.kv_base = 4521582592 = 282598912 * 16.
    -- V = K + LAYERS*N_KVH*MAXCTX*(REC_B/16).
    K_BASE_CH : natural := 282598912;
    V_BASE_CH : natural := 353902080;
    -- ---- the chunk -> byte seam, llama_top.vhd:3715-3720 ----------------
    BASE_SHIFT : natural := 4;
    -- ---- mutation hooks.  All zero/false in the shipping bench. ---------
    MUT_K_CH  : integer := 0;      -- chunks added to the K base at the port
    MUT_V_CH  : integer := 0;      -- chunks added to the V base at the port
    MUT_K_BY  : integer := 0;      -- BYTES added to the K base at the port
    MUT_V_BY  : integer := 0;      -- BYTES added to the V base at the port
    MUT_SWAP  : boolean := false;  -- hand the DUT the two bases swapped
    -- ---- the schedule --------------------------------------------------
    PA_L0 : natural := 1;          -- phase A layers (preseeded, read only)
    PA_L1 : natural := 5;
    PB_L0 : natural := 0;          -- phase B layers (written, then read)
    PB_L1 : natural := 3;
    PB_L2 : natural := 7;
    NPOS_A : positive := 4;
    NTOK   : positive := 5;
    STALL  : natural  := 5;
    WDOG   : positive := 3000000
  );
end entity;

architecture sim of tb_attn_kv_map is

  ---------------------------------------------------------------------------
  -- the format
  ---------------------------------------------------------------------------
  constant NBLK   : integer := HEAD_DIM/KV_BLOCK;
  constant CH_B   : integer := 16;
  constant CH_W   : integer := CH_B*8;
  constant REC_B  : integer := CH_B + HEAD_DIM;      -- CM_W is 8
  constant CPR    : integer := REC_B/CH_B;
  constant BEAT_B : integer := AXI_DW/8;
  constant BEAT_CH: integer := BEAT_B/CH_B;
  constant AW_B   : integer := clog2(NBLK);
  constant AW_H   : integer := clog2(N_KVH);
  constant POISON : integer := -128;

  -- The stamps need four header slots and five elements per block.
  constant CHK_NBLK : natural := NBLK - 4;
  constant CHK_KVB  : natural := KV_BLOCK - 5;

  ---------------------------------------------------------------------------
  -- THE ORACLE.  Addresses in chunks, content stamped with its coordinates.
  ---------------------------------------------------------------------------
  -- C spec 2.2 divided through by the 16-byte granule.  This is the ONLY
  -- spelling of the address equation in this file.
  function rec_ch(base_ch, lay, hd, ps : integer) return integer is
  begin
    return base_ch + ((lay*N_KVH + hd)*MAXCTX + ps)*CPR;
  end function;

  -- A per-record id.  Injective over reg<2, lay<8, hd<8, ps<128 by
  -- construction: each weight strictly exceeds the span of everything below
  -- it (127*7 = 889 < 1021, 7*1021 = 7147 < 8191).
  function rcode(reg, lay, hd, ps : integer) return integer is
  begin
    return reg*8191 + lay*1021 + hd*131 + ps*7;
  end function;

  -- header slot b, as the int8 the record holds
  function ehdr(reg, lay, hd, ps, b : integer) return integer is
  begin
    case b is
      when 0 => return reg;
      when 1 => return lay;
      when 2 => return hd;
      when 3 => return ps;
      when others =>
        return ((rcode(reg,lay,hd,ps)*13 + b*29 + 5) mod 241) - 120;
    end case;
  end function;

  -- mantissa element i of HEAD_DIM.  Element k of EVERY block carries the
  -- coordinates AND the block index, so a block reordering inside one record
  -- is caught as such and not as a wrong number.
  function emnt(reg, lay, hd, ps, i : integer) return integer is
    variable b : integer;
    variable k : integer;
  begin
    b := i/KV_BLOCK;
    k := i mod KV_BLOCK;
    case k is
      when 0 => return reg;
      when 1 => return lay;
      when 2 => return hd;
      when 3 => return ps;
      when 4 => return b;
      when others =>
        return ((rcode(reg,lay,hd,ps)*7 + i*11 + 3) mod 241) - 120;
    end case;
  end function;

  -- byte j of the 272-byte record image.  Bytes NBLK..CH_B-1 are the header
  -- pad, and rtl/attn_kv_axi.vhd:852-854 zeroes the whole header chunk before
  -- overlaying the exponents, so the pad is 0 and IS strobed.
  function erec(reg, lay, hd, ps, j : integer) return integer is
  begin
    if j < CH_B then
      if j < NBLK then return ehdr(reg,lay,hd,ps,j); else return 0; end if;
    else
      return emnt(reg,lay,hd,ps,j-CH_B);
    end if;
  end function;

  function slv8(v : integer) return std_logic_vector is
  begin
    return std_logic_vector(to_signed(v, 8));
  end function;

  ---------------------------------------------------------------------------
  -- THE SPARSE MEMORY.  Keyed by 16-byte chunk index; absent reads as POISON.
  ---------------------------------------------------------------------------
  type b16_t is array (0 to 15) of std_logic_vector(7 downto 0);
  type node_t;
  type node_p is access node_t;
  type node_t is record
    key : integer;
    d   : b16_t;
    nxt : node_p;
  end record;

  type mem_t is protected
    procedure wrb(key, off : integer; v : std_logic_vector(7 downto 0));
    impure function rdb(key, off : integer) return std_logic_vector;
    impure function present(key : integer) return boolean;
    impure function count return integer;
  end protected;

  type mem_t is protected body
    constant NBUCK : integer := 8192;
    type barr_t is array (0 to NBUCK-1) of node_p;
    variable bk : barr_t := (others => null);
    variable n  : integer := 0;
    impure function find(key : integer) return node_p is
      variable p : node_p;
    begin
      p := bk(key mod NBUCK);
      while p /= null loop
        if p.key = key then return p; end if;
        p := p.nxt;
      end loop;
      return null;
    end function;
    procedure wrb(key, off : integer; v : std_logic_vector(7 downto 0)) is
      variable p : node_p;
    begin
      p := find(key);
      if p = null then
        p := new node_t;
        p.key := key;
        p.d   := (others => slv8(POISON));
        p.nxt := bk(key mod NBUCK);
        bk(key mod NBUCK) := p;
        n := n + 1;
      end if;
      p.d(off) := v;
    end procedure;
    impure function rdb(key, off : integer) return std_logic_vector is
      variable p : node_p;
    begin
      p := find(key);
      if p = null then return slv8(POISON); end if;
      return p.d(off);
    end function;
    impure function present(key : integer) return boolean is
    begin
      return find(key) /= null;
    end function;
    impure function count return integer is
    begin
      return n;
    end function;
  end protected body;

  shared variable mem : mem_t;

  ---------------------------------------------------------------------------
  -- the bases, in both domains.  THE ONE SHIFT, and the bench's copy of
  -- rtl/llama_top.vhd:3715-3720.  Mutations are applied here and ONLY here,
  -- so what they perturb is the value handed across the port, never the
  -- oracle: `rec_ch(K_BASE_CH, ...)` below is unmutated by construction.
  ---------------------------------------------------------------------------
  constant KB_C : std_logic_vector(ADDR_W-1 downto 0)
                := std_logic_vector(
                     shift_left(to_unsigned(K_BASE_CH + MUT_K_CH, ADDR_W),
                                BASE_SHIFT)
                     + to_unsigned(MUT_K_BY mod 2**16, ADDR_W));
  constant VB_C : std_logic_vector(ADDR_W-1 downto 0)
                := std_logic_vector(
                     shift_left(to_unsigned(V_BASE_CH + MUT_V_CH, ADDR_W),
                                BASE_SHIFT)
                     + to_unsigned(MUT_V_BY mod 2**16, ADDR_W));

  ---------------------------------------------------------------------------
  -- DUT ports
  ---------------------------------------------------------------------------
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal running : boolean := true;

  signal d_start : std_logic := '0';
  signal d_layer : integer range 0 to LAYERS-1 := 0;
  signal d_cpos, d_ctx : unsigned(POS_W-1 downto 0) := (others => '0');
  signal d_kb, d_vb : std_logic_vector(ADDR_W-1 downto 0)
                    := (others => '0');
  signal d_cfgt, d_busy, d_wridle, d_err : std_logic;

  signal kw_sel : std_logic := '0';
  signal kw_head : unsigned(AW_H-1 downto 0) := (others => '0');
  signal kw_pos  : unsigned(POS_W-1 downto 0) := (others => '0');
  signal kw_hen, kw_en : std_logic := '0';
  signal kw_hdr : std_logic_vector(NBLK*8-1 downto 0) := (others => '0');
  signal kw_blk : unsigned(AW_B-1 downto 0) := (others => '0');
  signal kw_mant: std_logic_vector(KV_BLOCK*8-1 downto 0) := (others => '0');
  signal kw_rdy : std_logic;

  signal kr_head, vr_head : unsigned(AW_H-1 downto 0) := (others => '0');
  signal kr_pos, vr_pos   : unsigned(POS_W-1 downto 0) := (others => '0');
  signal kr_en, vr_en     : std_logic := '0';
  signal kr_blk, vr_blk   : unsigned(AW_B-1 downto 0) := (others => '0');
  signal kr_rdy, vr_rdy   : std_logic;
  signal kr_hdr, vr_hdr   : std_logic_vector(NBLK*8-1 downto 0);
  signal kr_mant, vr_mant : std_logic_vector(KV_BLOCK*8-1 downto 0);

  signal r_arvalid, r_arready, r_rvalid, r_rready, r_rlast
        : std_logic_vector(1 downto 0);
  signal r_araddr : std_logic_vector(2*ADDR_W-1 downto 0);
  signal r_arlen  : std_logic_vector(15 downto 0);
  signal r_arsize : std_logic_vector(5 downto 0);
  signal r_arburst: std_logic_vector(3 downto 0);
  -- ONE SIGNAL PER STREAM, indexed by the generate parameter.  A process that
  -- assigns to r_rdata(<expression>) has r_rdata as its longest STATIC prefix
  -- and so drives the WHOLE vector; sim/kv_axi_harness.vhd:158-172 records
  -- that this presented as the DUT reading zeros out of a correct memory.
  type rd_arr is array (0 to 1) of std_logic_vector(AXI_DW-1 downto 0);
  signal rdat     : rd_arr := (others => (others => '0'));
  signal r_rdata  : std_logic_vector(2*AXI_DW-1 downto 0) := (others => '0');
  signal r_rresp  : std_logic_vector(3 downto 0) := (others => '0');

  signal w_awvalid, w_awready, w_wvalid, w_wready, w_wlast : std_logic;
  signal w_bvalid : std_logic := '0';
  signal w_bready : std_logic;
  signal w_awaddr : std_logic_vector(ADDR_W-1 downto 0);
  signal w_awlen  : std_logic_vector(7 downto 0);
  signal w_awsize : std_logic_vector(2 downto 0);
  signal w_awburst: std_logic_vector(1 downto 0);
  signal w_wdata  : std_logic_vector(AXI_DW-1 downto 0);
  signal w_wstrb  : std_logic_vector(AXI_DW/8-1 downto 0);
  signal w_bresp  : std_logic_vector(1 downto 0) := "00";

  ---------------------------------------------------------------------------
  -- what the slaves are allowed to see: the job as the DUT latched it
  ---------------------------------------------------------------------------
  signal s_cpos : integer := 0;
  signal s_lay  : integer := 0;

  -- coverage, and the error tally
  type i2 is array (0 to 1) of integer;
  signal n_ar, n_rlast, n_cap, n_ph, n_4k : i2 := (others => 0);
  signal n_aw, n_wlast, n_b, n_wcap, n_wph : integer := 0;
  signal nbad_s : i2 := (others => 0);      -- slave-detected address faults
  signal cyc : integer := 0;

  -- capture, one cycle behind the enable
  type cap_t is array (0 to 31) of std_logic_vector(KV_BLOCK*8-1 downto 0);
  signal cap_k, cap_v : cap_t := (others => (others => '0'));
  signal cap_kh, cap_vh : std_logic_vector(NBLK*8-1 downto 0)
                        := (others => '0');
  signal cap_rst : std_logic := '0';

  signal all_done : boolean := false;
  signal verdict_ok : boolean := false;

begin

  clk <= (not clk) after 5 ns when running else '0';
  rst <= '0' after 40 ns;

  -- Elaboration guards for the stamping scheme, as `natural` constants so
  -- they name the file and the line rather than dying inside a slice.
  assert CHK_NBLK >= 0
    report "tb_attn_kv_map: NBLK must be at least 4 for the header stamps"
    severity failure;
  assert CHK_KVB >= 0
    report "tb_attn_kv_map: KV_BLOCK must be at least 5 for the block stamps"
    severity failure;

  P_CYC : process(clk)
  begin
    if rising_edge(clk) then
      cyc <= cyc + 1;
      assert cyc < WDOG or all_done
        report "tb_attn_kv_map: WATCHDOG -- no verdict after "
             & integer'image(WDOG) & " cycles" severity failure;
    end if;
  end process;

  ---------------------------------------------------------------------------
  dut : entity work.attn_kv_axi
    generic map(HEAD_DIM => HEAD_DIM, KV_BLOCK => KV_BLOCK, N_KVH => N_KVH,
                LAYERS => LAYERS, MAXCTX => MAXCTX, POS_W => POS_W,
                CM_W => 8, EXP_W => 8, AXI_DW => AXI_DW, ADDR_W => ADDR_W,
                MAXB => MAXB, MAXOUT => MAXOUT, RBUF => RBUF)
    port map(
      clk => clk, rst => rst,
      start => d_start, layer => d_layer, cur_pos => d_cpos, ctx_len => d_ctx,
      k_base => d_kb, v_base => d_vb,
      cfg_taken => d_cfgt, busy => d_busy, wr_idle => d_wridle, err => d_err,
      kw_sel => kw_sel, kw_head => kw_head, kw_pos => kw_pos,
      kw_hen => kw_hen, kw_hdr => kw_hdr, kw_en => kw_en, kw_blk => kw_blk,
      kw_mant => kw_mant, kw_rdy => kw_rdy,
      kr_head => kr_head, kr_pos => kr_pos, kr_rdy => kr_rdy, kr_en => kr_en,
      kr_blk => kr_blk, kr_hdr => kr_hdr, kr_mant => kr_mant,
      vr_head => vr_head, vr_pos => vr_pos, vr_rdy => vr_rdy, vr_en => vr_en,
      vr_blk => vr_blk, vr_hdr => vr_hdr, vr_mant => vr_mant,
      r_arvalid => r_arvalid, r_arready => r_arready, r_araddr => r_araddr,
      r_arlen => r_arlen, r_arsize => r_arsize, r_arburst => r_arburst,
      r_rvalid => r_rvalid, r_rready => r_rready, r_rdata => r_rdata,
      r_rlast => r_rlast, r_rresp => r_rresp,
      w_awvalid => w_awvalid, w_awready => w_awready, w_awaddr => w_awaddr,
      w_awlen => w_awlen, w_awsize => w_awsize, w_awburst => w_awburst,
      w_wvalid => w_wvalid, w_wready => w_wready, w_wdata => w_wdata,
      w_wstrb => w_wstrb, w_wlast => w_wlast,
      w_bvalid => w_bvalid, w_bready => w_bready, w_bresp => w_bresp);

  r_rdata <= rdat(1) & rdat(0);
  d_kb <= VB_C when MUT_SWAP else KB_C;
  d_vb <= KB_C when MUT_SWAP else VB_C;

  -- the slaves see the job the DUT latched, not the job the driver is about
  -- to request: the DUT drains before it latches, so no AR belonging to the
  -- old job can be issued after cfg_taken.
  P_LATCH : process(clk)
  begin
    if rising_edge(clk) then
      if d_cfgt = '1' then
        s_cpos <= to_integer(d_cpos);
        s_lay  <= d_layer;
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- the two read slaves, in the CHUNK domain.  A byte address of 5.7e9 does
  -- not fit `integer`; the chunk index does, at 4.25e8.
  ---------------------------------------------------------------------------
  GEN_SLV : for s in 0 to 1 generate
    signal arr : std_logic := '0';
  begin
    r_arready(s) <= arr;
    P_SLV : process(clk)
      constant QD : integer := 8;
      type qa_t is array (0 to QD-1) of integer;
      variable qa, ql : qa_t := (others => 0);
      variable qh, qt, qn : integer := 0;
      variable busyb : boolean := false;
      variable bch, bleft : integer := 0;
      variable lf : unsigned(15 downto 0) := to_unsigned(7919 + s*331, 16);
      variable av : std_logic_vector(ADDR_W-1 downto 0);
      variable ach, n, base_ch, lo, hi, sub, a4k : integer;
    begin
      if rising_edge(clk) then
        lf := lf(14 downto 0) & (lf(15) xor lf(13) xor lf(12) xor lf(10));
        if rst = '1' then
          qh := 0; qt := 0; qn := 0; busyb := false;
          arr <= '0'; r_rvalid(s) <= '0'; r_rlast(s) <= '0';
        else
          if r_rvalid(s) = '1' and r_rready(s) /= '1' then
            report "tb_attn_kv_map: RREADY low while RVALID high, master "
                 & integer'image(s) severity failure;
          end if;
          arr <= '0';
          if r_arvalid(s) = '1' and qn < QD and arr = '0'
             and (to_integer(lf) mod 8) = 0 then
            av  := r_araddr((s+1)*ADDR_W-1 downto s*ADDR_W);
            -- THE WHOLE POINT: the address is decoded on its BITS, never
            -- through to_integer of the full vector.
            ach := to_integer(unsigned(av(ADDR_W-1 downto 4)));
            a4k := to_integer(unsigned(av(11 downto 0)));
            n   := to_integer(unsigned(r_arlen((s+1)*8-1 downto s*8))) + 1;
            assert n <= MAXB
              report "tb_attn_kv_map: read master " & integer'image(s)
                   & " ARLEN+1 = " & integer'image(n) & " > MAXB "
                   & "-- the FK33 HBM slave is AXI3 and arlen is 4 bits"
              severity failure;
            assert a4k + n*BEAT_B <= 4096
              report "tb_attn_kv_map: read master " & integer'image(s)
                   & " burst CROSSES A 4 KB BOUNDARY" severity failure;
            assert to_integer(unsigned(av(3 downto 0))) = 0
                   and (ach mod BEAT_CH) = 0
              report "tb_attn_kv_map: read master " & integer'image(s)
                   & " ARADDR is not beat aligned" severity failure;
            assert r_arburst((s+1)*2-1 downto s*2) = "01"
              report "tb_attn_kv_map: ARBURST is not INCR" severity failure;
            assert to_integer(unsigned(r_arsize((s+1)*3-1 downto s*3)))
                   = clog2(BEAT_B)
              report "tb_attn_kv_map: ARSIZE does not match the data width"
              severity failure;

            -- THE ADDRESS ORACLE ON THE READ PATH.  The sub-region index is
            -- recovered from the burst address against the NOMINAL map, so a
            -- mutated base, a wrong layer stride or a K/V swap is caught here
            -- as an ADDRESS fault, before any data is compared.
            if s = 0 then base_ch := K_BASE_CH; else base_ch := V_BASE_CH; end if;
            sub := (ach - base_ch + 1)/(MAXCTX*CPR);
            if ach < base_ch or sub < 0 or sub > LAYERS*N_KVH-1
               or sub/N_KVH /= s_lay then
              nbad_s(s) <= nbad_s(s) + 1;
              report "tb_attn_kv_map: READ ADDRESS FAULT, master "
                   & integer'image(s) & " chunk " & integer'image(ach)
                   & " is sub-region " & integer'image(sub)
                   & " (layer " & integer'image(sub/N_KVH)
                   & ") but the job is layer " & integer'image(s_lay)
                   & "; nominal base chunk " & integer'image(base_ch)
                severity error;
            else
              lo := rec_ch(base_ch, sub/N_KVH, sub mod N_KVH, 0);
              hi := rec_ch(base_ch, sub/N_KVH, sub mod N_KVH, s_cpos);
              if not (ach >= lo - BEAT_CH and ach + n*BEAT_CH <= hi + BEAT_CH)
              then
                nbad_s(s) <= nbad_s(s) + 1;
                report "tb_attn_kv_map: READ RANGE FAULT, master "
                     & integer'image(s) & " burst [" & integer'image(ach)
                     & "," & integer'image(ach + n*BEAT_CH)
                     & ") chunks leaves the readable range ["
                     & integer'image(lo) & "," & integer'image(hi + BEAT_CH)
                     & ")" severity error;
              end if;
            end if;

            arr <= '1';
            qa(qt) := ach; ql(qt) := n;
            qt := (qt + 1) mod QD; qn := qn + 1;
            n_ar(s) <= n_ar(s) + 1;
            if n = MAXB then n_cap(s) <= n_cap(s) + 1; end if;
            if (a4k + n*BEAT_B) = 4096 then n_4k(s) <= n_4k(s) + 1; end if;
            if ((ach - base_ch) mod CPR) /= 0 then n_ph(s) <= n_ph(s) + 1; end if;
          end if;

          if r_rvalid(s) = '1' and r_rready(s) = '1' then
            bleft := bleft - 1;
            bch   := bch + BEAT_CH;
            if bleft = 0 then
              busyb := false;
              r_rvalid(s) <= '0'; r_rlast(s) <= '0';
              n_rlast(s) <= n_rlast(s) + 1;
            end if;
          end if;
          if not busyb and qn > 0 then
            bch := qa(qh); bleft := ql(qh);
            qh := (qh + 1) mod QD; qn := qn - 1;
            busyb := true;
          end if;
          if busyb and (r_rvalid(s) = '0' or r_rready(s) = '1') then
            if STALL > 1 and (to_integer(lf) mod STALL) = 0 then
              r_rvalid(s) <= '0';
            elsif bleft > 0 then
              for l in 0 to BEAT_CH-1 loop
                for b in 0 to 15 loop
                  rdat(s)((l*16+b+1)*8-1 downto (l*16+b)*8)
                    <= mem.rdb(bch + l, b);
                end loop;
              end loop;
              r_rvalid(s) <= '1';
              if bleft = 1 then r_rlast(s) <= '1';
              else r_rlast(s) <= '0'; end if;
            end if;
          end if;
        end if;
      end if;
    end process;
  end generate;

  ---------------------------------------------------------------------------
  -- the write slave, also in the chunk domain
  ---------------------------------------------------------------------------
  P_WSLV : process(clk)
    constant QD : integer := 8;
    type qa_t is array (0 to QD-1) of integer;
    variable qa, ql : qa_t := (others => 0);
    variable qh, qt, qn : integer := 0;
    variable busyb : boolean := false;
    variable bch, bleft : integer := 0;
    variable ach, n, a4k : integer;
    variable bq : integer := 0;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        qh := 0; qt := 0; qn := 0; busyb := false; bq := 0;
        w_awready <= '0'; w_wready <= '0'; w_bvalid <= '0';
      else
        w_awready <= '0';
        w_wready  <= '1';
        if w_awvalid = '1' and qn < QD and w_awready = '0' then
          ach := to_integer(unsigned(w_awaddr(ADDR_W-1 downto 4)));
          a4k := to_integer(unsigned(w_awaddr(11 downto 0)));
          n   := to_integer(unsigned(w_awlen)) + 1;
          assert n <= MAXB
            report "tb_attn_kv_map: write master AWLEN+1 = "
                 & integer'image(n) & " > MAXB -- AXI3, 4-bit awlen"
            severity failure;
          assert a4k + n*BEAT_B <= 4096
            report "tb_attn_kv_map: write burst CROSSES A 4 KB BOUNDARY"
            severity failure;
          assert to_integer(unsigned(w_awaddr(3 downto 0))) = 0
                 and (ach mod BEAT_CH) = 0
            report "tb_attn_kv_map: AWADDR is not beat aligned"
            severity failure;
          assert w_awburst = "01"
            report "tb_attn_kv_map: AWBURST is not INCR" severity failure;
          assert to_integer(unsigned(w_awsize)) = clog2(BEAT_B)
            report "tb_attn_kv_map: AWSIZE does not match the data width"
            severity failure;
          w_awready <= '1';
          qa(qt) := ach; ql(qt) := n; qt := (qt + 1) mod QD; qn := qn + 1;
          n_aw <= n_aw + 1;
          if n = MAXB then n_wcap <= n_wcap + 1; end if;
          if ((ach - K_BASE_CH) mod CPR) /= 0
             and ((ach - V_BASE_CH) mod CPR) /= 0 then
            n_wph <= n_wph + 1;
          end if;
        end if;

        if not busyb and qn > 0 then
          bch := qa(qh); bleft := ql(qh);
          qh := (qh + 1) mod QD; qn := qn - 1;
          busyb := true;
        end if;
        if busyb and w_wvalid = '1' and w_wready = '1' then
          for l in 0 to BEAT_CH-1 loop
            for b in 0 to 15 loop
              if w_wstrb(l*16+b) = '1' then
                mem.wrb(bch + l, b,
                        w_wdata((l*16+b+1)*8-1 downto (l*16+b)*8));
              end if;
            end loop;
          end loop;
          bleft := bleft - 1;
          bch   := bch + BEAT_CH;
          if bleft = 0 then
            assert w_wlast = '1'
              report "tb_attn_kv_map: WLAST missing on the last write beat"
              severity failure;
            busyb := false; bq := bq + 1;
            n_wlast <= n_wlast + 1;
          else
            assert w_wlast = '0'
              report "tb_attn_kv_map: WLAST asserted early" severity failure;
          end if;
        end if;

        -- C spec 2.7 as a property, on every cycle a BRESP is owed
        if bq > 0 then
          assert d_wridle = '0'
            report "tb_attn_kv_map: wr_idle HIGH with " & integer'image(bq)
                 & " write burst(s) unretired (C spec 2.7)" severity failure;
        end if;
        if w_bvalid = '1' and w_bready = '1' then
          w_bvalid <= '0'; bq := bq - 1; n_b <= n_b + 1;
        end if;
        if bq > 0 and w_bvalid = '0' then
          w_bvalid <= '1'; w_bresp <= "00";
        end if;
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- the consumer's capture, one cycle behind the enable
  ---------------------------------------------------------------------------
  P_CAP : process(clk)
    variable ke, ve : std_logic := '0';
    variable kn, vn : integer := 0;
  begin
    if rising_edge(clk) then
      if cap_rst = '1' then
        kn := 0; vn := 0; ke := '0'; ve := '0';
      else
        if ke = '1' then
          cap_k(kn) <= kr_mant; cap_kh <= kr_hdr; kn := kn + 1;
        end if;
        if ve = '1' then
          cap_v(vn) <= vr_mant; cap_vh <= vr_hdr; vn := vn + 1;
        end if;
        ke := kr_en; ve := vr_en;
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- the stimulus and the checker
  ---------------------------------------------------------------------------
  P_MAIN : process
    variable nbad : integer := 0;
    variable nrd  : integer := 0;
    variable nwr  : integer := 0;
    variable nimg : integer := 0;
    variable err_said : boolean := false;
    variable pa_l, pb_l : integer;
    variable e, g, gr, gl, gh, gp : integer;

    procedure tick is begin wait until rising_edge(clk); end procedure;

    -- report a mismatch, DECODING what actually arrived so the message names
    -- the record that was reached instead of printing two integers
    procedure say(reg, lay, hd, ps, b, k, ev, gv : integer;
                  what : string) is
    begin
      if nbad < 20 then
        report "tb_attn_kv_map: " & what & " MISMATCH  want (reg "
             & integer'image(reg) & " lay " & integer'image(lay) & " hd "
             & integer'image(hd) & " pos " & integer'image(ps) & ") blk "
             & integer'image(b) & " el " & integer'image(k)
             & "  oracle " & integer'image(ev) & " rtl " & integer'image(gv)
          severity error;
      end if;
    end procedure;

    -- one full record read through port `sel`, exactly as attn_block issues
    -- it, then compared against the oracle.
    procedure do_read(sel, lay, hd, ps : integer) is
      variable cnt : integer;
      variable ee, gg : integer;
    begin
      cap_rst <= '1'; tick; cap_rst <= '0'; tick;
      if sel = 0 then
        kr_head <= to_unsigned(hd, AW_H); kr_pos <= to_unsigned(ps, POS_W);
      else
        vr_head <= to_unsigned(hd, AW_H); vr_pos <= to_unsigned(ps, POS_W);
      end if;
      tick;
      cnt := 0;
      loop
        exit when (sel = 0 and kr_rdy = '1') or (sel = 1 and vr_rdy = '1');
        cnt := cnt + 1;
        assert cnt < 200000
          report "tb_attn_kv_map: residency never arrived, sel "
               & integer'image(sel) & " lay " & integer'image(lay)
               & " hd " & integer'image(hd) & " pos " & integer'image(ps)
          severity failure;
        tick;
      end loop;
      for b in 0 to NBLK-1 loop
        if sel = 0 then kr_en <= '1'; kr_blk <= to_unsigned(b, AW_B);
        else            vr_en <= '1'; vr_blk <= to_unsigned(b, AW_B); end if;
        tick;
      end loop;
      kr_en <= '0'; vr_en <= '0';
      tick; tick;
      nrd := nrd + 1;
      -- the header
      for b in 0 to NBLK-1 loop
        ee := ehdr(sel, lay, hd, ps, b);
        if sel = 0 then gg := to_integer(signed(cap_kh((b+1)*8-1 downto b*8)));
        else            gg := to_integer(signed(cap_vh((b+1)*8-1 downto b*8)));
        end if;
        if ee /= gg then
          nbad := nbad + 1;
          say(sel, lay, hd, ps, b, -1, ee, gg, "HEADER");
        end if;
      end loop;
      -- the mantissas
      for b in 0 to NBLK-1 loop
        for k in 0 to KV_BLOCK-1 loop
          ee := emnt(sel, lay, hd, ps, b*KV_BLOCK + k);
          if sel = 0 then
            gg := to_integer(signed(cap_k(b)((k+1)*8-1 downto k*8)));
          else
            gg := to_integer(signed(cap_v(b)((k+1)*8-1 downto k*8)));
          end if;
          if ee /= gg then
            nbad := nbad + 1;
            say(sel, lay, hd, ps, b, k, ee, gg, "MANTISSA");
          end if;
        end loop;
      end loop;
    end procedure;

    procedure do_write(sel, lay, hd, ps : integer) is
    begin
      while kw_rdy = '0' loop tick; end loop;
      if sel = 0 then kw_sel <= '0'; else kw_sel <= '1'; end if;
      kw_head <= to_unsigned(hd, AW_H);
      kw_pos  <= to_unsigned(ps, POS_W);
      for b in 0 to NBLK-1 loop
        kw_hdr((b+1)*8-1 downto b*8) <= slv8(ehdr(sel, lay, hd, ps, b));
      end loop;
      kw_hen <= '1'; tick; kw_hen <= '0';
      for b in 0 to NBLK-1 loop
        for k in 0 to KV_BLOCK-1 loop
          kw_mant((k+1)*8-1 downto k*8)
            <= slv8(emnt(sel, lay, hd, ps, b*KV_BLOCK + k));
        end loop;
        kw_blk <= to_unsigned(b, AW_B);
        kw_en  <= '1'; tick;
      end loop;
      kw_en <= '0'; tick;
      nwr := nwr + 1;
    end procedure;

    procedure job(lay, cpos, ctx : integer) is
    begin
      d_layer <= lay;
      d_cpos  <= to_unsigned(cpos, POS_W);
      d_ctx   <= to_unsigned(ctx, POS_W);
      tick;
      d_start <= '1'; tick; d_start <= '0';
      loop
        exit when d_cfgt = '1';
        tick;
      end loop;
      tick;
      -- `err` on a configuration this bench believes is legal is a CHECKER
      -- verdict, not a reason to abandon the run: a mutation harness that
      -- kills the simulation here would score the DUT's own refusal as ABORT
      -- ("the checker was not shown to catch this") when the refusal is
      -- exactly what was wanted.  Counted, reported once, and carried on.
      if d_err /= '0' and not err_said then
        nbad := nbad + 1;
        err_said := true;
        report "tb_attn_kv_map: attn_kv_axi RAISED err on job (layer "
             & integer'image(lay) & " cur_pos " & integer'image(cpos)
             & " ctx_len " & integer'image(ctx)
             & ") -- it refused a configuration this bench believes legal"
          severity error;
      end if;
    end procedure;

    -- A2/A3: the record image, at the address THIS FILE computes
    procedure img_check(reg, lay, hd, ps : integer) is
      variable c0, ee, gg : integer;
    begin
      if reg = 0 then c0 := rec_ch(K_BASE_CH, lay, hd, ps);
      else            c0 := rec_ch(V_BASE_CH, lay, hd, ps); end if;
      nimg := nimg + 1;
      for j in 0 to REC_B-1 loop
        ee := erec(reg, lay, hd, ps, j);
        gg := to_integer(signed(mem.rdb(c0 + j/16, j mod 16)));
        if ee /= gg then
          nbad := nbad + 1;
          if nbad < 20 then
            report "tb_attn_kv_map: IMAGE MISMATCH at chunk "
                 & integer'image(c0 + j/16) & " byte " & integer'image(j)
                 & " of record (reg " & integer'image(reg) & " lay "
                 & integer'image(lay) & " hd " & integer'image(hd) & " pos "
                 & integer'image(ps) & ")  oracle " & integer'image(ee)
                 & " memory " & integer'image(gg)
                 & "   (" & integer'image(POISON) & " means NOTHING WAS "
                 & "EVER WRITTEN THERE)" severity error;
          end if;
        end if;
      end loop;
    end procedure;

    procedure preseed(reg, lay, hd, ps : integer) is
      variable c0 : integer;
    begin
      if reg = 0 then c0 := rec_ch(K_BASE_CH, lay, hd, ps);
      else            c0 := rec_ch(V_BASE_CH, lay, hd, ps); end if;
      for j in 0 to REC_B-1 loop
        mem.wrb(c0 + j/16, j mod 16, slv8(erec(reg, lay, hd, ps, j)));
      end loop;
    end procedure;

  begin
    wait until rst = '0';
    tick; tick;

    ------------------------------------------------------------------
    -- ANCHOR A1.  Phase A: memory the RTL never wrote.
    ------------------------------------------------------------------
    for li in 0 to 1 loop
      if li = 0 then pa_l := PA_L0; else pa_l := PA_L1; end if;
      for hd in 0 to N_KVH-1 loop
        for ps in 0 to NPOS_A-1 loop
          preseed(0, pa_l, hd, ps);
          preseed(1, pa_l, hd, ps);
        end loop;
      end loop;
    end loop;

    for li in 0 to 1 loop
      if li = 0 then pa_l := PA_L0; else pa_l := PA_L1; end if;
      job(pa_l, NPOS_A, NPOS_A + 1);
      for hd in 0 to N_KVH-1 loop
        for ps in 0 to NPOS_A-1 loop
          do_read(0, pa_l, hd, ps);
          do_read(1, pa_l, hd, ps);
        end loop;
      end loop;
    end loop;
    report "tb_attn_kv_map: phase A done -- " & integer'image(nrd)
         & " preseeded records read back, " & integer'image(nbad)
         & " mismatches so far";

    ------------------------------------------------------------------
    -- Phase B: the multi-token, multi-layer write-then-read sequence.
    ------------------------------------------------------------------
    for t in 0 to NTOK-1 loop
      for li in 0 to 2 loop
        if    li = 0 then pb_l := PB_L0;
        elsif li = 1 then pb_l := PB_L1;
        else              pb_l := PB_L2; end if;
        job(pb_l, t, NTOK);
        -- read back every position this layer already holds
        for hd in 0 to N_KVH-1 loop
          for ps in 0 to t-1 loop
            do_read(0, pb_l, hd, ps);
            do_read(1, pb_l, hd, ps);
          end loop;
        end loop;
        -- append this token's records
        for hd in 0 to N_KVH-1 loop
          do_write(0, pb_l, hd, t);
          do_write(1, pb_l, hd, t);
        end loop;
        loop
          exit when d_wridle = '1';
          tick;
        end loop;
      end loop;
    end loop;

    ------------------------------------------------------------------
    -- ANCHORS A2 and A3.
    ------------------------------------------------------------------
    for li in 0 to 2 loop
      if    li = 0 then pb_l := PB_L0;
      elsif li = 1 then pb_l := PB_L1;
      else              pb_l := PB_L2; end if;
      for hd in 0 to N_KVH-1 loop
        for ps in 0 to NTOK-1 loop
          img_check(0, pb_l, hd, ps);
          img_check(1, pb_l, hd, ps);
        end loop;
      end loop;
    end loop;
    -- phase A's preseed is part of the expected image too
    for li in 0 to 1 loop
      if li = 0 then pa_l := PA_L0; else pa_l := PA_L1; end if;
      for hd in 0 to N_KVH-1 loop
        for ps in 0 to NPOS_A-1 loop
          img_check(0, pa_l, hd, ps);
          img_check(1, pa_l, hd, ps);
        end loop;
      end loop;
    end loop;

    if mem.count /= nimg*CPR then
      nbad := nbad + 1;
      report "tb_attn_kv_map: STRAY WRITES -- memory holds "
           & integer'image(mem.count) & " chunks but the "
           & integer'image(nimg) & " expected records occupy exactly "
           & integer'image(nimg*CPR) severity error;
    end if;

    if d_err /= '0' and not err_said then
      nbad := nbad + 1;
      report "tb_attn_kv_map: err is set at end of test" severity error;
    end if;

    nbad := nbad + nbad_s(0) + nbad_s(1);

    report "tb_attn_kv_map: COVERAGE  records read " & integer'image(nrd)
         & "  written " & integer'image(nwr)
         & "  image-checked " & integer'image(nimg)
         & "  chunks resident " & integer'image(mem.count)
         & " | AR " & integer'image(n_ar(0)) & "/" & integer'image(n_ar(1))
         & "  at the 16-beat cap " & integer'image(n_cap(0)) & "/"
         & integer'image(n_cap(1))
         & "  phase-16 runs " & integer'image(n_ph(0)) & "/"
         & integer'image(n_ph(1))
         & "  ending on 4 KB " & integer'image(n_4k(0)) & "/"
         & integer'image(n_4k(1))
         & " | AW " & integer'image(n_aw) & "  B " & integer'image(n_b)
         & "  write bursts at the cap " & integer'image(n_wcap)
         & "  phase-16 writes " & integer'image(n_wph);

    -- COVERAGE AS A GATE, not as a print.  A splitter that never split and a
    -- phase that was always zero would satisfy every check above.
    if n_cap(0) = 0 or n_cap(1) = 0 then
      nbad := nbad + 1;
      report "tb_attn_kv_map: NO read burst reached the AXI3 16-beat cap -- "
           & "the splitter was never exercised" severity error;
    end if;
    if n_ph(0) = 0 or n_ph(1) = 0 then
      nbad := nbad + 1;
      report "tb_attn_kv_map: NO read run started at record phase 16 -- "
           & "the realignment mux was never exercised" severity error;
    end if;
    if n_aw /= n_b or n_aw /= n_wlast then
      nbad := nbad + 1;
      report "tb_attn_kv_map: AW " & integer'image(n_aw) & " WLAST "
           & integer'image(n_wlast) & " B " & integer'image(n_b)
           & " -- an accepted write burst was abandoned" severity error;
    end if;
    if n_ar(0) /= n_rlast(0) or n_ar(1) /= n_rlast(1) then
      nbad := nbad + 1;
      report "tb_attn_kv_map: AR/RLAST counts differ -- an accepted read "
           & "burst was abandoned" severity error;
    end if;

    if nbad = 0 then
      verdict_ok <= true;
      report "tb_attn_kv_map: PASS -- rtl/attn_kv_axi.vhd at the REAL 9B KV "
           & "map (K base chunk " & integer'image(K_BASE_CH)
           & " of 16 bytes, V base chunk " & integer'image(V_BASE_CH)
           & ", MAXCTX "
           & integer'image(MAXCTX) & ", " & integer'image(LAYERS)
           & " layers, " & integer'image(N_KVH) & " KV heads, HEAD_DIM "
           & integer'image(HEAD_DIM) & "): " & integer'image(nrd)
           & " records read BIT-EXACT, " & integer'image(nwr)
           & " records written and their " & integer'image(nimg*CPR)
           & "-chunk memory image BIT-EXACT at independently computed "
           & "addresses, with no stray chunk anywhere in the 5.7 GB region";
    else
      report "tb_attn_kv_map: FAIL -- " & integer'image(nbad)
           & " mismatches (slave-detected address faults: "
           & integer'image(nbad_s(0)) & "/" & integer'image(nbad_s(1)) & ")"
        severity error;
    end if;
    all_done <= true;
    tick;
    running <= false;
    wait;
  end process;

end architecture;
