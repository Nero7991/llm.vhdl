-- rtl/attn_kv_axi.vhd
-- Subsystem C: the KV cache in HBM.  Two AXI read masters (K and V) and one
-- AXI write master, behind the exact memory-port shape rtl/attn_block.vhd
-- already drives.
--
-- ======================================================================
-- WHY THIS FILE EXISTS
-- ======================================================================
-- rtl/attn_block.vhd is bit-exact against ref/attn_block_vec.c as of
-- 2026-08-28, and it cannot produce a second token, because its KV cache is a
-- PORT and nothing implements the other side of that port.  Its own header
-- says so at :55-70 ("that unit -- `attn_kv_axi` in the C skeleton's section 2
-- table -- does not exist and is NOT written here") and again in its open list
-- at :168-172.  The 9B completeness audit lists it ABSENT
-- (docs/2026-08-28_9b-completeness-audit.md:206) and names it in the largest
-- single block of unwritten RTL in the project (:596).
--
-- The contract is C spec section 2.2 (DDR layout), 2.1.1 (the record), 2.7
-- (arbitration, drain-then-flush, BRESP gating) and 3.9 (the error table), in
-- docs/superpowers/specs/2026-08-21-gated-attention-design.md.
--
-- ======================================================================
-- 1. THE RECORD, AND THE ADDRESS EQUATION
-- ======================================================================
-- C spec 2.1.1.  One head-vector record is
--
--     NBLK int8 block exponents, zero-padded to 16 bytes
--   + HEAD_DIM int8 mantissas
--
-- which at the build geometry (HEAD_DIM 256, KV_BLOCK 32, so NBLK = 8) is
-- 8 + 8 pad + 256 = 272 bytes, the number the spec prints.  Everything below
-- is written in terms of REC_B = 16 + HEAD_DIM, so the 16-byte granule -- the
-- thing that makes the spec's "16-byte record-phase realignment" possible at
-- all -- is a property of the format and not of one geometry.
--
-- C spec 2.2, verbatim, with 272 generalised:
--
--     addr = base + ((layer * N_KVH + kv_head) * MAXCTX + pos) * REC_B
--
-- K and V are SEPARATE regions with separate bases, so the two read masters
-- run in lockstep over two contiguous streams rather than one interleaved one.
--
-- ONE DELIBERATE DEPARTURE FROM THE SPEC, AND IT REMOVES A REQUIREMENT.
-- C spec 2.2 requires `k_base` and `v_base` to be 4 KB aligned "for the split
-- arithmetic to hold", and requires MAXCTX to be a multiple of 256 so that
-- `MAXCTX * REC_B` is 4 KB aligned.  Neither is needed here, because the
-- splitter below computes `4096 - (addr mod 4096)` on the ABSOLUTE beat
-- address rather than on an offset from the base.  Both bases are still
-- required to be 16-byte aligned, which is a format requirement (the record
-- granule) and not an AXI one.  The spec's constraints are not wrong; they are
-- what a base-relative splitter would need.  Stated rather than silently
-- relaxed, because a future reader comparing the two will otherwise assume one
-- of them is a defect.
--
-- ======================================================================
-- 2. THE INTERFACE attn_block ACTUALLY NEEDS, AND THE GAP IN IT
-- ======================================================================
-- MEASURED by reading rtl/attn_block.vhd, not assumed:
--
--   * P_RECK (:1290-1300) raises `kr_en` with `kr_head` / `kr_pos` / `kr_blk`
--     for blk = 0 .. NBLK-1, ONE PER CYCLE, back to back, with no ready and no
--     gate of any kind.  P_RECV (:1387-1397) does the same on the V side.
--   * The capture is at :1013-1027: `rbv(1)` is set on the issue cycle,
--     `rbv(2) <= rbv(1)`, and the capture fires on `rbv(2)`.  So the returned
--     beat is sampled exactly TWO cycles after the issue cycle, which is a
--     fixed ONE-CYCLE synchronous read.  There is no elasticity anywhere in
--     that path.
--   * The capture index is `rbi`, a counter separate from `blk`, so beats must
--     be returned IN ISSUE ORDER; the returned `kr_blk` is never inspected.
--   * `kr_hdr` / `vr_hdr` must be valid alongside every beat of the record
--     they belong to.  That is the "header first" property attn_score_q12
--     depends on, and attn_block re-latches it on every captured beat.
--   * The state machine leaves P_RECK only on `rbi = NBLK`, so the COMPLETION
--     of a record is elastic even though each beat is not.
--
-- THE GAP.  A one-cycle synchronous read cannot be served by an AXI master:
-- HBM read latency is O(100) cycles.  attn_block has no signal on which it
-- could wait, so as it stands today it is not connectable to this unit, or to
-- any other AXI-backed cache.  **That is a genuine under-specification of the
-- C boundary and it is reported rather than papered over.**  It is not fixed
-- here because rtl/attn_block.vhd is another track's file and because the
-- brief for this one says explicitly not to integrate.
--
-- The contract this unit publishes, which closes the gap with ONE new signal
-- per read stream:
--
--   REQUEST     `kr_head` / `kr_pos` are a REQUEST.  The consumer drives them
--               and HOLDS them from the moment it wants the record until it
--               has taken the last beat of that record.
--   RESIDENCY   `kr_rdy` is '1' exactly while the record named by the held
--               `kr_head` / `kr_pos` is resident in this unit.  It is
--               combinational in the request, so a consumer that moves the
--               request sees `kr_rdy` fall in the same cycle.
--   BEATS       While `kr_rdy` = '1', `kr_en` with `kr_blk` returns `kr_mant`
--               and `kr_hdr` on the NEXT cycle.  That is bit-for-bit the
--               behaviour of the memory model in sim/tb_attn_block.vhd:498-510
--               -- the same one-cycle registered read, and the header
--               registered alongside every beat.
--
-- So the integration change attn_block needs is exactly: drive `kr_head` /
-- `kr_pos` one state earlier and gate P_RECK's issue on `kr_rdy`.  Two lines,
-- in a file this track does not own.
--
-- Same shape on the write side: `kw_rdy` says the record buffer is free.
-- attn_block does not have that input either, and there the gap is benign --
-- it writes two records per KV head separated by a full quantizer invocation
-- (~800 cycles at HEAD_DIM 256) against a 9-beat burst -- but it is a schedule
-- property, not an interface property, which is the exact class of invisible
-- contract that produced subsystem B's head-23 defect.  It is published so a
-- future schedule cannot break it silently.
--
-- ======================================================================
-- 3. WHAT THE READ ENGINE DOES: DEMAND-DRIVEN, WITH SEQUENTIAL PREFETCH
-- ======================================================================
-- The sweep order is fixed by C spec 3.1 and by attn_block's P_POSN: for each
-- KV head, [cur_pos (bypassed, never read), 0, 1, ..., cur_pos-1].  Positions
-- are therefore consumed in ASCENDING order within a head, and the records of
-- one head are contiguous in memory.  That is the whole basis of the design:
--
--   * A RUN is (head, pos0) plus every record from pos0 upward.  The engine
--     fetches ahead along the run into a circular buffer of RBUF record slots.
--   * The consumer's held request defines `c_rec`, the record it is on.  Slots
--     for records below `c_rec` are dead and may be refilled; the fetcher is
--     therefore allowed to run up to `c_rec + RBUF - 1`.
--   * A request that is not on the current run -- a head change, or a jump
--     backwards -- forces a RETARGET, which is the same drain-then-flush the
--     job `start` uses.
--
-- Prefetch is what makes the AXI3 burst cap bite.  One record is 272 B = 9
-- beats at AXI_DW 256, comfortably under the cap, so a per-record fetcher
-- would never split and the splitter would never be exercised.  A run of RBUF
-- records is RBUF*REC_B bytes and does.
--
-- ======================================================================
-- 4. BURST SPLITTING: TWO CAPS, NOT ONE
-- ======================================================================
-- MEASURED, and already the subject of one wrong answer in this project
-- (worklog "AXI3 burst cap", commit 809ada7): **the FK33 HBM slave is AXI3.**
-- rtl/hbm_tg_ip.vhd:1036-1039 truncates `arlen(3 downto 0)` at the pin, so
-- ARLEN is 4 bits and **16 beats is the hard maximum**, not the 128 that
-- AXI4's 4 KB rule would allow at 256 bits.  `MAXB` defaults to 16 and an
-- elaboration assert refuses anything above it.
--
-- Each AR is therefore the minimum of three numbers:
--
--     this_len = min( MAXB,
--                     beats still permitted by the slot window,
--                     (4096 - (addr mod 4096)) / BEAT_B )
--
-- The third term is exact for every legal AXI_DW because BEAT_B divides 4096.
--
-- ======================================================================
-- 5. THE 16-BYTE PHASE, AND PARTIALLY FILLED BEATS
-- ======================================================================
-- REC_B = 272 does not divide BEAT_B = 32, so a record's start address is
-- 16-byte aligned but only 32-byte aligned for even `pos`.  Reads are issued
-- from the beat-aligned address below the run's first record, so the first
-- beat delivers 16 bytes of padding when the phase is 16, and the last beat of
-- the run delivers up to BEAT_B-16 bytes past the end.  Both are discarded.
--
-- The realignment is done in 16-BYTE CHUNKS rather than bytes, which is what
-- the spec means by a "16-byte record-phase realignment mux" and is why the
-- format pads the header to 16.  Run-relative chunk index of beat n, lane c:
--
--     k = n*BEAT_CH + c - PH_CH          PH_CH = (run_base mod BEAT_B)/16
--     record r = k / CPR                 CPR = REC_B/16
--     chunk-in-record m = k mod CPR      m = 0 is the header, else mantissa m-1
--
-- k < 0 and k past the permitted window are dropped.  A slot is marked
-- resident when its LAST chunk lands, which is sound only because responses on
-- one ID arrive in order -- stated here because it is the property the whole
-- capture depends on.
--
-- On the write side the same phase produces partially strobed first and last
-- beats; WSTRB is computed per byte lane from the record's byte range, so the
-- pad bytes belonging to the record ARE written and the bytes outside it are
-- not.  A write that used a full-strobe beat would corrupt the neighbouring
-- record, and at phase 16 the neighbour is a real record 6% of the time.
--
-- ======================================================================
-- 6. cur_pos = 0, AND THE EMPTY CACHE
-- ======================================================================
-- The readable range is `pos < cur_pos`, NOT `pos < ctx_len`, and that is a
-- correctness rule rather than an off-by-one.  C spec 2.4: the record at
-- `cur_pos` is WRITTEN by this job through the write master and would be read
-- back through a read master in the same job, and "AXI orders nothing between
-- masters".  attn_block bypasses it from registers for exactly that reason, so
-- a fetch of `cur_pos` here is never a hit -- it is a race.  This unit refuses
-- it: a request for `pos >= cur_pos` raises `err` and leaves `kr_rdy` low, and
-- the fetcher never issues an AR for it.
--
-- At the first token of a sequence `cur_pos` = 0, so nothing is readable and
-- the fetcher issues NOTHING: no AR, no speculative read of a record that has
-- never been written.  The one-token `llama_top` case therefore exercises the
-- write path and the empty-cache path and nothing else, which is precisely why
-- the two attn_block defects of 2026-08-28 were unreachable from it.
--
-- `ctx_len` is still taken, and is still range-checked against MAXCTX at
-- `start` (C spec 3.9's first row), because it is the allocation bound and
-- `cur_pos >= ctx_len` is the same row's second clause.
--
-- ======================================================================
-- 7. DRAIN-THEN-FLUSH, AND THE RULE THAT OUTRANKS EVERYTHING
-- ======================================================================
-- C spec 2.7: "C flushes its own read FIFOs on `start`, internally" and
-- "Flushing alone is insufficient: outstanding transactions must be drained
-- first."  rtl/hbm_tg.vhd:727-737 states the harder version of the same rule
-- from the other side: a datapath MUST complete AXI bursts it has already
-- issued, because abandoning an accepted burst hangs the HBM channel
-- permanently.
--
-- This unit obeys it STRUCTURALLY rather than by sequencing:
--
--   * `rready` and `bready` are tied to '1' for the entire life of the design.
--     They are never gated on a state, a flush, an error or a reset-release.
--     An accepted read burst therefore always drains, at full rate, in every
--     state the unit can be in.  Beats that arrive during a drain are simply
--     not written into any slot.
--   * AW is issued ONLY when the complete record is already in the write
--     buffer, so the W engine can never starve mid-burst, and `start` cannot
--     interrupt it: the write FSM finishes every burst of the record in flight
--     before it acknowledges a flush.  A partially CAPTURED record (header
--     taken, some blocks missing) is discarded, which is safe precisely
--     because nothing was issued for it.
--
-- `busy` is high from `start` until the drain and flush have completed; a
-- consumer must not read while it is high.  `cfg_taken` pulses on the cycle
-- the new layer/ctx_len/bases are latched, which is after the drain, so the
-- previous job's in-flight beats can never be mapped with the new job's
-- geometry.
--
-- ======================================================================
-- 8. RRESP / BRESP
-- ======================================================================
-- C spec 3.9: `RRESP`/`BRESP` /= OKAY is `err` + abort after drain-then-flush.
-- A non-OKAY RRESP raises sticky `err`, halts AR issue on that stream and
-- invalidates its slots; the burst carrying it still drains to RLAST.  A
-- non-OKAY BRESP raises sticky `err` and stops further AW issue; bursts
-- already accepted still complete.
--
-- C spec 2.7 also requires that `done` not assert until every outstanding
-- write has completed, because token T's write of K/V[cur_pos] is read by
-- token T+1 through a DIFFERENT master and AXI orders nothing between masters.
-- That is `wr_idle` here: '1' only when the write buffer is empty, no AW is
-- outstanding and every B has been received.  This unit does not own `done`;
-- it publishes the term that gates it.
--
-- ======================================================================
-- 9. WHAT THIS FILE DOES NOT DO
-- ======================================================================
--   * It is NOT wired into attn_block.  See the gap in section 2.
--   * One outstanding-burst credit scheme, one ID.  Responses are assumed
--     in-order per master, which is what an AXI3 slave with a single ID
--     guarantees and what rtl/hbm_tg_ip.vhd provides.
--   * No K/V region interleave, no write combining across records, and no
--     read of the current position (attn_block bypasses it; C spec 2.4 makes
--     that a correctness requirement, not an optimisation).
--   * The prefetch depth RBUF is a fixed generic; there is no adaptive depth
--     and no measurement here of the sustained port efficiency C spec 2.5
--     needs.  That is a hardware measurement and this is simulation only.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity attn_kv_axi is
  generic(
    -- geometry, matching rtl/attn_block.vhd's generics of the same name
    HEAD_DIM : positive := 256;
    KV_BLOCK : positive := 32;
    N_KVH    : positive := 2;
    LAYERS   : positive := 16;
    MAXCTX   : positive := 2048;
    POS_W    : positive := 16;
    CM_W     : positive := 8;    -- cache mantissa; the record format is int8
    EXP_W    : positive := 8;    -- block exponent; the record format is int8
    -- AXI
    AXI_DW   : positive := 256;  -- FK33 HBM SAXI data width
    ADDR_W   : positive := 33;   -- 8 GiB of HBM
    MAXB     : positive := 16;   -- AXI3: ARLEN is 4 bits.  16 is the CAP.
    MAXOUT   : positive := 4;    -- bursts in flight per read master
    RBUF     : positive := 4     -- record slots prefetched per read stream
  );
  port(
    clk : in std_logic;
    rst : in std_logic;

    -- ---- job control ----------------------------------------------------
    start     : in  std_logic;   -- one-cycle pulse: drain, flush, latch
    layer     : in  integer range 0 to LAYERS-1;
    cur_pos   : in  unsigned(POS_W-1 downto 0);
    ctx_len   : in  unsigned(POS_W-1 downto 0);
    k_base    : in  std_logic_vector(ADDR_W-1 downto 0);
    v_base    : in  std_logic_vector(ADDR_W-1 downto 0);
    cfg_taken : out std_logic;
    busy      : out std_logic;   -- draining/flushing; do not read
    wr_idle   : out std_logic;   -- every write retired, BRESP in (C spec 2.7)
    err       : out std_logic;   -- sticky, C spec 3.9

    -- ---- the write port, shapes from rtl/attn_block.vhd:268-276 ----------
    kw_sel  : in  std_logic;                       -- '0' = K, '1' = V
    kw_head : in  unsigned(clog2(N_KVH)-1 downto 0);
    kw_pos  : in  unsigned(POS_W-1 downto 0);
    kw_hen  : in  std_logic;
    kw_hdr  : in  std_logic_vector((HEAD_DIM/KV_BLOCK)*EXP_W-1 downto 0);
    kw_en   : in  std_logic;
    kw_blk  : in  unsigned(clog2(HEAD_DIM/KV_BLOCK)-1 downto 0);
    kw_mant : in  std_logic_vector(KV_BLOCK*CM_W-1 downto 0);
    kw_rdy  : out std_logic;                       -- record buffer free

    -- ---- the K read port, shapes from rtl/attn_block.vhd:279-284 ---------
    kr_head : in  unsigned(clog2(N_KVH)-1 downto 0);
    kr_pos  : in  unsigned(POS_W-1 downto 0);
    kr_rdy  : out std_logic;                       -- NEW; see section 2
    kr_en   : in  std_logic;
    kr_blk  : in  unsigned(clog2(HEAD_DIM/KV_BLOCK)-1 downto 0);
    kr_hdr  : out std_logic_vector((HEAD_DIM/KV_BLOCK)*EXP_W-1 downto 0);
    kr_mant : out std_logic_vector(KV_BLOCK*CM_W-1 downto 0);

    -- ---- the V read port ------------------------------------------------
    vr_head : in  unsigned(clog2(N_KVH)-1 downto 0);
    vr_pos  : in  unsigned(POS_W-1 downto 0);
    vr_rdy  : out std_logic;
    vr_en   : in  std_logic;
    vr_blk  : in  unsigned(clog2(HEAD_DIM/KV_BLOCK)-1 downto 0);
    vr_hdr  : out std_logic_vector((HEAD_DIM/KV_BLOCK)*EXP_W-1 downto 0);
    vr_mant : out std_logic_vector(KV_BLOCK*CM_W-1 downto 0);

    -- ---- the two read masters.  Index 0 = K, index 1 = V. ----------------
    r_arvalid : out std_logic_vector(1 downto 0);
    r_arready : in  std_logic_vector(1 downto 0);
    r_araddr  : out std_logic_vector(2*ADDR_W-1 downto 0);
    r_arlen   : out std_logic_vector(15 downto 0);
    r_arsize  : out std_logic_vector(5 downto 0);
    r_arburst : out std_logic_vector(3 downto 0);
    r_rvalid  : in  std_logic_vector(1 downto 0);
    r_rready  : out std_logic_vector(1 downto 0);
    r_rdata   : in  std_logic_vector(2*AXI_DW-1 downto 0);
    r_rlast   : in  std_logic_vector(1 downto 0);
    r_rresp   : in  std_logic_vector(3 downto 0);

    -- ---- the write master ------------------------------------------------
    w_awvalid : out std_logic;
    w_awready : in  std_logic;
    w_awaddr  : out std_logic_vector(ADDR_W-1 downto 0);
    w_awlen   : out std_logic_vector(7 downto 0);
    w_awsize  : out std_logic_vector(2 downto 0);
    w_awburst : out std_logic_vector(1 downto 0);
    w_wvalid  : out std_logic;
    w_wready  : in  std_logic;
    w_wdata   : out std_logic_vector(AXI_DW-1 downto 0);
    w_wstrb   : out std_logic_vector(AXI_DW/8-1 downto 0);
    w_wlast   : out std_logic;
    w_bvalid  : in  std_logic;
    w_bready  : out std_logic;
    w_bresp   : in  std_logic_vector(1 downto 0)
  );
end entity;

architecture rtl of attn_kv_axi is

  -- ---- the format -------------------------------------------------------
  constant NBLK   : integer := HEAD_DIM/KV_BLOCK;
  constant CH_B   : integer := 16;                    -- the record granule
  constant CH_W   : integer := CH_B*8;                -- 128
  constant MANT_B : integer := HEAD_DIM*CM_W/8;
  constant REC_B  : integer := CH_B + MANT_B;         -- 272 at the geometry
  constant CPR    : integer := REC_B/CH_B;            -- chunks per record, 17
  constant MPB    : integer := KV_BLOCK*CM_W/8/CH_B;  -- chunks per KV block
  constant BEAT_B : integer := AXI_DW/8;
  constant BEAT_CH: integer := BEAT_B/CH_B;
  -- THE LOW BITS OF AN ADDRESS ARE TAKEN AS BITS, NEVER THROUGH `to_integer`
  -- OF THE WHOLE VECTOR.  `to_integer(a) mod 4096` reads like a slow way of
  -- masking; at the real 9B KV map it is a SIMULATION-KILLING OVERFLOW.
  -- MEASURED 2026-08-29, TRACK KVVALUE, GHDL 1.0.0 mcode, this file at
  -- ADDR_W 33 with the manifest's k_base = 4,521,582,592:
  --
  --   ghdl:error: overflow detected
  --   in process .tb_attn_kv_map(sim).dut@attn_kv_axi(rtl).gen_rd(1).p_rd
  --     from: ieee.numeric_std.to_integer at numeric_std-body.vhdl:3042
  --
  -- because `natural'high` is 2,147,483,647 and the base alone is 2.1x that.
  -- Every existing bench ran with bases under 36 MB, so the whole 32-bit
  -- region of the address space was outside their coverage and this was
  -- unreachable from all of them.  It is the same wall TRACK CGENERICS hit on
  -- the GENERIC and TRACK CKVMAP closed by counting the base in 16-byte
  -- chunks -- the generic stopped being a byte count, and this did not.
  --
  -- `resize` on an UNSIGNED drops the leftmost bits, so `low_bits(a,n)` is
  -- exactly `a mod 2**n` for every ADDR_W: it TRUNCATES when ADDR_W > n and
  -- zero-EXTENDS when ADDR_W < n, and in the second case the value is already
  -- below 2**n so the answer is the value itself.  All four call sites below
  -- take a power-of-two modulus, so no call site loses anything.
  constant BEAT_LW: integer := clog2(BEAT_B);   -- BEAT_B is a power of two

  function low_bits(a : unsigned; n : positive) return integer is
  begin
    return to_integer(resize(a, n));
  end function;

  constant AW_B   : integer := clog2(NBLK);
  constant AW_H   : integer := clog2(N_KVH);

  -- THE HEADER-CHUNK BOUND, AS A DECLARATION AND NOT ONLY AS AN ASSERT.
  -- The concurrent `assert NBLK*EXP_W/8 <= CH_B` below states the same
  -- invariant, and at the shipping geometry it is UNREACHABLE: GHDL
  -- elaborates every declaration and every statement part before it runs a
  -- single concurrent assert, and at HEAD_DIM 256 the static slice
  -- `wbuf(0)(NBLK*EXP_W-1 downto 0)` in P_WR (:829, a CH_W = 128-bit
  -- element) overflows during statement elaboration first.  The result was
  -- `ghdl: error: overflow detected` with no file, no line and no message,
  -- while the SAME illegal KV_BLOCK at HEAD_DIM 32 or 64 printed the named
  -- assert -- which is why no simulation ever saw this (MEASURED, TRACK
  -- REALSHAPE).  A `natural` constant that goes negative is evaluated in the
  -- declarative part, so it names the file and the line, and unlike the
  -- assert it also survives Vivado.  MEASURED 2026-08-29, Vivado 2023.2,
  -- three OOC runs of THIS file on xczu3eg: with HEAD_DIM 256 / KV_BLOCK 4
  -- the constant is `ERROR: [Synth 8-11323] assigned value '-48' out of
  -- range` and synthesis FAILS; with HEAD_DIM 64 / KV_BLOCK 4, which
  -- violates only the `assert ... severity failure` two declarations down,
  -- synthesis COMPLETES.  Same file, same tool, same invocation shape.
  --
  -- ZERO MARGIN AT THE SHIPPING SHAPE, and that is not an accident of this
  -- check: attn_head_dim is 256 for both 9B and 27B, so KV_BLOCK 16 puts
  -- NBLK at exactly 16 and one step past it the diagnostic used to vanish.
  constant CHK_HDR_FITS : natural := CH_B - NBLK*EXP_W/8;

  type ch_arr is array (natural range <>) of std_logic_vector(CH_W-1 downto 0);

  -- addr = base + ((layer*N_KVH + head)*MAXCTX + pos) * REC_B   (C spec 2.2)
  function rec_addr(base : std_logic_vector; lay, hd, ps : integer)
    return unsigned is
    variable idx : integer;
  begin
    idx := (lay*N_KVH + hd)*MAXCTX + ps;
    return unsigned(base) + to_unsigned(idx*REC_B, ADDR_W);
  end function;

  -- Section 4: the two caps, plus whatever the window still permits.
  function burst_len(a : unsigned; left : integer) return integer is
    variable to4k : integer;
    variable n    : integer;
  begin
    to4k := (4096 - low_bits(a, 12))/BEAT_B;
    n := left;
    if n > MAXB then n := MAXB; end if;
    if n > to4k then n := to4k; end if;
    return n;
  end function;

  -- ---- consumer-side plumbing, so the read engine can be a generate ------
  type hd_arr  is array (0 to 1) of unsigned(AW_H-1 downto 0);
  type ps_arr  is array (0 to 1) of unsigned(POS_W-1 downto 0);
  type bk_arr  is array (0 to 1) of unsigned(AW_B-1 downto 0);
  type hdr_arr is array (0 to 1) of std_logic_vector(NBLK*EXP_W-1 downto 0);
  type mnt_arr is array (0 to 1) of std_logic_vector(KV_BLOCK*CM_W-1 downto 0);

  signal q_head : hd_arr;
  signal q_pos  : ps_arr;
  signal q_blk  : bk_arr;
  signal q_en   : std_logic_vector(1 downto 0);
  signal q_rdy  : std_logic_vector(1 downto 0);
  signal q_hdr  : hdr_arr := (others => (others => '0'));
  signal q_mant : mnt_arr := (others => (others => '0'));

  -- ---- job state ---------------------------------------------------------
  signal lay_r  : integer range 0 to LAYERS-1 := 0;
  signal cpos_r : unsigned(POS_W-1 downto 0) := (others => '0');
  signal clen_r : unsigned(POS_W-1 downto 0) := (others => '0');
  signal kb_r, vb_r : std_logic_vector(ADDR_W-1 downto 0) := (others => '0');
  signal flushing : std_logic := '0';
  signal cfgt_r   : std_logic := '0';

  -- Sticky error, one owner per contributor.  A single `err_r` written from
  -- four processes would be four drivers on one signal; the OR below is the
  -- resolution, stated once.
  signal err_cfg : std_logic := '0';
  signal err_rd  : std_logic_vector(1 downto 0) := (others => '0');
  signal err_w   : std_logic := '0';

  -- drain acknowledgements from the three engines
  signal rd_quiet : std_logic_vector(1 downto 0);
  signal wr_quiet : std_logic := '1';

  -- ---- write engine ------------------------------------------------------
  signal wbuf   : ch_arr(0 to CPR-1) := (others => (others => '0'));
  signal wb_sel : std_logic := '0';
  signal wb_hd  : unsigned(AW_H-1 downto 0) := (others => '0');
  signal wb_ps  : unsigned(POS_W-1 downto 0) := (others => '0');
  signal wb_cnt : integer range 0 to NBLK := 0;
  signal wb_hgot: std_logic := '0';
  signal wb_full: std_logic := '0';       -- a complete record awaits issue
  signal w_outst: integer range 0 to 63 := 0;   -- AW issued, B not returned
  signal wseq_idle : std_logic := '1';       -- the AW/W sequencer is at rest

begin

  -- ======================================================================
  -- elaboration checks.  Every one is a format or protocol invariant the
  -- arithmetic depends on; none is a style preference.
  -- ======================================================================
  assert CM_W = 8 and EXP_W = 8
    report "attn_kv_axi: the C spec 2.1.1 record is a BYTE layout -- int8 "
         & "mantissas and int8 block exponents.  CM_W and EXP_W must both be "
         & "8; anything else is a different format, not a wider one."
    severity failure;
  assert NBLK*EXP_W/8 <= CH_B
    report "attn_kv_axi: the block exponents do not fit the 16-byte header "
         & "chunk.  HEAD_DIM/KV_BLOCK must be <= 16."
    severity failure;
  assert MANT_B mod CH_B = 0
    report "attn_kv_axi: the mantissa area must be a whole number of 16-byte "
         & "chunks, or the record-phase realignment is not 16-byte granular."
    severity failure;
  assert (KV_BLOCK*CM_W/8) mod CH_B = 0
    report "attn_kv_axi: one KV block must be a whole number of 16-byte "
         & "chunks (KV_BLOCK*CM_W must be a multiple of 128)."
    severity failure;
  assert BEAT_B >= CH_B and BEAT_B mod CH_B = 0
    report "attn_kv_axi: AXI_DW must be at least 128 and a multiple of 128."
    severity failure;
  assert 4096 mod BEAT_B = 0
    report "attn_kv_axi: BEAT_B must divide 4096 or the 4 KB split is inexact."
    severity failure;
  assert CPR > BEAT_CH
    report "attn_kv_axi: a record must span more than one beat, or one beat "
         & "can carry both the first and the last chunk of one slot and the "
         & "residency rule of section 5 does not hold."
    severity failure;
  assert MAXB <= 16
    report "attn_kv_axi: MAXB > 16.  THE FK33 HBM SLAVE IS AXI3 -- "
         & "rtl/hbm_tg_ip.vhd:1036 truncates arlen(3 downto 0) at the pin, so "
         & "anything above 16 beats silently wraps.  This is not AXI4's 4 KB "
         & "rule and 128 beats is NOT legal here."
    severity failure;
  assert RBUF >= 2
    report "attn_kv_axi: RBUF < 2 leaves no slot for the straddle record, so "
         & "the last beat of a burst would overwrite the slot the consumer is "
         & "reading.  Prefetch depth is RBUF-2 records beyond the current one."
    severity failure;
  assert NBLK >= 2 and N_KVH >= 2
    report "attn_kv_axi: NBLK and N_KVH must be >= 2; at 1 the index widths "
         & "clog2(1) = 0 are null ranges."
    severity failure;

  -- ======================================================================
  -- consumer-side wiring
  -- ======================================================================
  q_head(0) <= kr_head;   q_head(1) <= vr_head;
  q_pos(0)  <= kr_pos;    q_pos(1)  <= vr_pos;
  q_blk(0)  <= kr_blk;    q_blk(1)  <= vr_blk;
  q_en(0)   <= kr_en;     q_en(1)   <= vr_en;
  kr_rdy    <= q_rdy(0);  vr_rdy    <= q_rdy(1);
  kr_hdr    <= q_hdr(0);  vr_hdr    <= q_hdr(1);
  kr_mant   <= q_mant(0); vr_mant   <= q_mant(1);

  cfg_taken <= cfgt_r;
  busy      <= flushing;
  err       <= err_cfg or err_rd(0) or err_rd(1) or err_w;
  wr_idle   <= '1' when (w_outst = 0 and wb_full = '0' and wb_hgot = '0'
                         and wseq_idle = '1') else '0';
  kw_rdy    <= '1' when (wb_full = '0' and flushing = '0') else '0';

  -- SECTION 7: rready and bready are tied high for the life of the design.
  -- They are deliberately NOT a function of any state.  An accepted burst
  -- therefore always drains, in every state, which is the rule
  -- rtl/hbm_tg.vhd:727 states from the slave's side.
  r_rready <= "11";
  w_bready <= '1';

  r_arsize  <= std_logic_vector(to_unsigned(clog2(BEAT_B), 3))
             & std_logic_vector(to_unsigned(clog2(BEAT_B), 3));
  r_arburst <= "0101";
  w_awsize  <= std_logic_vector(to_unsigned(clog2(BEAT_B), 3));
  w_awburst <= "01";

  -- ======================================================================
  -- job control: drain, THEN flush, THEN latch.  Nothing about the new job
  -- exists until the old job's last beat has landed.
  -- ======================================================================
  P_JOB : process(clk)
  begin
    if rising_edge(clk) then
      cfgt_r <= '0';
      if rst = '1' then
        flushing <= '0'; err_cfg <= '0';
        lay_r <= 0; cpos_r <= (others => '0'); clen_r <= (others => '0');
        kb_r <= (others => '0'); vb_r <= (others => '0');
      else
        if start = '1' then
          flushing <= '1';
          err_cfg  <= '0';
          -- C spec 3.9 row 1, checked at start, before any AXI or state write
          if to_integer(ctx_len) > MAXCTX or ctx_len = 0
             or cur_pos >= ctx_len or layer > LAYERS-1 then
            err_cfg <= '1';
          end if;
          -- THE 16-BYTE BASE ALIGNMENT, WHICH IS A FORMAT REQUIREMENT AND
          -- WHOSE ONLY REMAINING HOME IS HERE.  Section 1 states it: the
          -- record granule is 16 bytes and the realignment mux works in
          -- chunks.  rtl/llama_top.vhd used to assert it, and TRACK CKVMAP
          -- correctly RETIRED that assert when C_K_BASE_CH/C_V_BASE_CH became
          -- chunk counts, because from there an unaligned base stopped being
          -- representable.  But THIS module's `k_base`/`v_base` are BYTE
          -- addresses and any other instantiator can still hand it one.
          --
          -- MEASURED 2026-08-29, TRACK KVVALUE, sim/mutate_kv_map.sh row
          -- `k_one_byte` before this check existed: a base ONE BYTE high is
          -- not merely unchecked, the two engines DISAGREE about it.  The
          -- read side computes `ph_ch = low_bits(a0,BEAT_LW)/CH_B`, an
          -- integer divide by 16, so an offset of 1..15 bytes is quantised
          -- away and the reads are correct.  The write side keeps the same
          -- offset as `phase` and shifts every strobe by it, so the RECORD
          -- LANDS ONE BYTE LATE and byte 0 of its first chunk is never
          -- written at all.  A silent one-byte corruption of the cache, with
          -- the reader unable to see the cause.  Refusing the job is the
          -- whole fix; there is no alignment either engine could agree on.
          if k_base(3 downto 0) /= "0000" or v_base(3 downto 0) /= "0000" then
            err_cfg <= '1';
            report "attn_kv_axi: k_base/v_base must be 16-byte aligned -- "
                 & "that is the record granule (section 1).  An unaligned "
                 & "base is quantised away by the read engine and honoured "
                 & "by the write engine, so the record lands late and the "
                 & "reader cannot see why." severity warning;
          end if;
        elsif flushing = '1' and rd_quiet = "11" and wr_quiet = '1' then
          flushing <= '0';
          lay_r    <= layer;
          cpos_r   <= cur_pos;
          clen_r   <= ctx_len;
          kb_r     <= k_base;
          vb_r     <= v_base;
          cfgt_r   <= '1';
        end if;
      end if;
    end if;
  end process;

  -- ======================================================================
  -- THE READ ENGINES.  s = 0 is K, s = 1 is V.  One instance each; the two
  -- are structurally identical and the generate says so once instead of the
  -- file saying it twice and drifting.
  -- ======================================================================
  GEN_RD : for s in 0 to 1 generate
    -- recbuf WAS one flat ch_arr(0 to RBUF*CPR-1) -- 68 words of 128 bits at
    -- the composed shape -- carrying the header word and every mantissa chunk
    -- of every slot together.  MEASURED 2026-09-06, that cost about 21,000
    -- LUT PER PREFETCH SLOT, roughly 10 LUT per stored bit, because the
    -- consumer read three words per cycle through a 68-way multiplexer, and
    -- the array is written twice per cycle besides.  Storage was never the
    -- expensive part; the SELECT across slots was.
    --
    -- THE SPLIT IS AN IDENTITY, not an approximation.  The read index was
    --     hit_slot*CPR + 1 + q_blk*MPB + c,   c in 0 .. MPB-1
    -- so substituting mm = 1 + q_blk*MPB + c gives (mm-1) mod MPB = c exactly
    -- and (mm-1)/MPB = q_blk exactly.  Banking on (mm-1) mod MPB therefore
    -- turns each of the MPB reads into its OWN bank at index
    -- hit_slot*NBLK + q_blk, and CPR-1 = NBLK*MPB makes that index range
    -- exact rather than merely sufficient.
    --
    -- The header (mm = 0) is kept separate because only NBLK*EXP_W of its
    -- bits are ever read and there are only RBUF of them -- four words, far
    -- too small to be worth a bank, and reading it from one would add a port
    -- for nothing.
    type   mbank_t  is array (0 to RBUF*NBLK-1) of std_logic_vector(CH_W-1 downto 0);
    type   mbanks_t is array (0 to MPB-1) of mbank_t;
    signal mbank : mbanks_t := (others => (others => (others => '0')));
    signal hdr_r : ch_arr(0 to RBUF-1) := (others => (others => '0'));
    signal sv    : std_logic_vector(RBUF-1 downto 0) := (others => '0');
    type   sh_t  is array (0 to RBUF-1) of unsigned(AW_H-1 downto 0);
    type   sp_t  is array (0 to RBUF-1) of unsigned(POS_W-1 downto 0);
    signal sh    : sh_t := (others => (others => '0'));
    signal sp    : sp_t := (others => (others => '0'));

    signal run_v   : std_logic := '0';
    signal run_hd  : unsigned(AW_H-1 downto 0) := (others => '0');
    signal run_p0  : unsigned(POS_W-1 downto 0) := (others => '0');
    signal ph_ch   : integer range 0 to BEAT_CH-1 := 0;
    signal ar_addr : unsigned(ADDR_W-1 downto 0) := (others => '0');
    -- The highest beat index a read run can reach, DERIVED: phase < BEAT_CH,
    -- MAXCTX records of CPR chunks, rounded up, plus one burst of overshoot.
    constant FB_MAX : natural := (2*BEAT_CH - 2 + MAXCTX*CPR)/BEAT_CH + MAXB;
    signal lim_beat_r : natural range 0 to FB_MAX := 0;
    signal lim_ok_r   : std_logic := '0';
    -- '0' for the one cycle after anything the limit is computed from was
    -- reassigned (run start/end, flush, reset, token start): lim_beat_r then
    -- still holds the PREVIOUS run's limit.  Issue requires it '1'.
    signal lim_fresh  : std_logic := '0';
    signal f_beat  : natural range 0 to FB_MAX := 0;   -- next beat index to request, from astart
    -- (record, chunk-in-record, slot) of chunk 0 of the beat about to arrive,
    -- kept INCREMENTALLY so no beat divides by CPR.  Invariant, with n the
    -- number of beats arrived in this run: w_rr*CPR + w_mm = n*BEAT_CH - ph_ch, with 0 <= w_mm < CPR
    -- once past beat 0 and w_mm = -ph_ch (w_rr = 0) at beat 0, and
    -- w_slot = w_rr mod RBUF.  MEASURED 2026-09-22, build 15 draw 3: the
    -- former per-beat `kk / CPR`, `kk mod CPR` and `rr mod RBUF` on the
    -- 32-bit beat counter were the design's worst path, r_beat_reg ->
    -- mbank CE, 33 logic levels with 14 CARRY8, 12.945 ns against 13.333,
    -- the top ten violated paths of the routed card at -0.254 ns.
    signal w_rr    : integer := 0;
    signal w_mm    : integer range -(BEAT_CH-1) to CPR-1 := 0;
    signal w_slot  : integer range 0 to RBUF-1 := 0;
    signal c_max   : natural range 0 to MAXCTX := 0;   -- highest record index the consumer took
    signal outst   : integer range 0 to MAXOUT+1 := 0;
    signal arv     : std_logic := '0';
    signal alen    : integer range 1 to MAXB := 1;
    signal halted  : std_logic := '0';

    signal hit     : std_logic;
    signal hit_slot: integer range 0 to RBUF-1;
    signal in_run  : std_logic;
    signal c_rec   : integer;
    signal oor     : std_logic;
  begin
    -- ---- residency, combinational in the HELD request (section 2) --------
    P_HIT : process(sv, sh, sp, q_head, q_pos, run_v, run_hd, run_p0, c_max,
                    cpos_r)
      variable h : std_logic;
      variable k : integer;
      variable d : integer;
    begin
      h := '0'; k := 0;
      for i in 0 to RBUF-1 loop
        if sv(i) = '1' and sh(i) = q_head(s) and sp(i) = q_pos(s) then
          h := '1'; k := i;
        end if;
      end loop;
      hit      <= h;
      hit_slot <= k;

      -- Section 6: the readable range is pos < cur_pos.  pos = cur_pos is the
      -- record this job WRITES and attn_block bypasses.
      if q_pos(s) >= cpos_r then oor <= '1'; else oor <= '0'; end if;

      d := to_integer(q_pos(s)) - to_integer(run_p0);
      if run_v = '1' and q_head(s) = run_hd and d >= 0 and d >= c_max
         and q_pos(s) < cpos_r then
        in_run <= '1';
      else
        in_run <= '0';
      end if;
      c_rec <= d;
    end process;

    q_rdy(s) <= hit and (not flushing) and (not oor);

    r_arvalid(s) <= arv;
    r_araddr((s+1)*ADDR_W-1 downto s*ADDR_W) <= std_logic_vector(ar_addr);
    r_arlen((s+1)*8-1 downto s*8) <= std_logic_vector(to_unsigned(alen-1, 8));
    rd_quiet(s) <= '1' when (outst = 0 and arv = '0') else '0';

    P_RD : process(clk)
      variable rr, mm, slot : integer;
      variable lim_rec, left, n : integer;
      variable lane : std_logic_vector(CH_W-1 downto 0);
      variable dout : integer;       -- outstanding delta this cycle
      variable base : std_logic_vector(ADDR_W-1 downto 0);
      variable a0   : unsigned(ADDR_W-1 downto 0);
    begin
      if rising_edge(clk) then
        if rst = '1' then
          sv <= (others => '0'); run_v <= '0'; arv <= '0';
          outst <= 0; f_beat <= 0; c_max <= 0; halted <= '0';
          w_rr <= 0; w_mm <= 0; w_slot <= 0;
          err_rd(s) <= '0';
          lim_fresh <= '0'; lim_ok_r <= '0';
        else
          -- The read limit, registered one cycle ahead of its use (block
          -- ratings 2026-09-26: this arithmetic was 28 levels in the issue
          -- cycle, 114.9 MHz on VU33P -2LV).  A limit one cycle old is SAFE:
          -- c_max only grows within a run and cpos_r/run_p0/ph_ch are fixed
          -- in it, so the old limit is never above the true one.  The cycles
          -- where that premise breaks clear lim_fresh below.
          lim_fresh <= '1';
          lim_rec := c_max + RBUF - 2;
          if lim_rec > to_integer(cpos_r) - 1 - to_integer(run_p0) then
            lim_rec := to_integer(cpos_r) - 1 - to_integer(run_p0);
          end if;
          if lim_rec >= 0 then
            lim_ok_r   <= '1';
            lim_beat_r <= (ph_ch + (lim_rec+1)*CPR + BEAT_CH - 1)/BEAT_CH;
          else
            lim_ok_r   <= '0';
          end if;
          if start = '1' then lim_fresh <= '0'; end if;

          dout := 0;
          if start = '1' then err_rd(s) <= '0'; end if;

          -- ---- consumer read, ONE CYCLE synchronous, header alongside ----
          -- Identical in shape to sim/tb_attn_block.vhd:498-510: registered
          -- data, and the record's header registered with every beat.
          if q_en(s) = '1' and hit = '1' then
            q_hdr(s) <= hdr_r(hit_slot)(NBLK*EXP_W-1 downto 0);
            for c in 0 to MPB-1 loop
              -- was recbuf(hit_slot*CPR + 1 + q_blk*MPB + c); by the identity
              -- above this is bank c at index hit_slot*NBLK + q_blk.
              q_mant(s)((c+1)*CH_W-1 downto c*CH_W)
                <= mbank(c)(hit_slot*NBLK + to_integer(q_blk(s)));
            end loop;
          end if;

          -- an enabled read outside the readable range is C spec 3.9's range
          -- violation, not a fetch
          if q_en(s) = '1' and oor = '1' then err_rd(s) <= '1'; end if;

          -- ---- consumer progress: which slots may be refilled ------------
          if in_run = '1' and c_rec > c_max then c_max <= c_rec; end if;

          -- ---- AR handshake ---------------------------------------------
          if arv = '1' and r_arready(s) = '1' then
            arv     <= '0';
            dout    := dout + 1;
            f_beat  <= f_beat + alen;
            ar_addr <= ar_addr + to_unsigned(alen*BEAT_B, ADDR_W);
          end if;

          -- ---- R beats.  rready is '1' always, so a beat is always taken --
          if r_rvalid(s) = '1' then
            if r_rresp((s+1)*2-1 downto s*2) /= "00" then
              err_rd(s) <= '1';
              halted    <= '1';
              sv        <= (others => '0');
            end if;
            for c in 0 to BEAT_CH-1 loop
              -- kk = n*BEAT_CH + c - ph_ch = w_rr*CPR + w_mm + c, and
              -- BEAT_CH < CPR (asserted above) so w_mm + c wraps at most
              -- once.  kk < 0 exactly when w_mm + c < 0, which only beat 0
              -- can reach.
              mm   := w_mm + c;
              lane := r_rdata(s*AXI_DW + (c+1)*CH_W-1
                              downto s*AXI_DW + c*CH_W);
              if mm >= 0 and halted = '0' and run_v = '1' and flushing = '0'
              then
                if mm >= CPR then
                  mm := mm - CPR;
                  rr := w_rr + 1;
                  if w_slot = RBUF-1 then slot := 0; else slot := w_slot + 1; end if;
                else
                  rr   := w_rr;
                  slot := w_slot;
                end if;
                if rr <= c_max + RBUF - 1
                   and (to_integer(run_p0) + rr) < to_integer(cpos_r) then
                  -- mm = 0 is the header; mm >= 1 lands in bank
                  -- (mm-1) mod MPB at slot*NBLK + (mm-1)/MPB.  Two chunks
                  -- arrive per cycle and their mm always differ, so no bank
                  -- ever sees two writes in one cycle.
                  if mm = 0 then
                    hdr_r(slot) <= lane;
                  else
                    mbank((mm-1) mod MPB)(slot*NBLK + (mm-1)/MPB) <= lane;
                  end if;
                  if mm = 0 then
                    sh(slot) <= run_hd;
                    sp(slot) <= run_p0 + to_unsigned(rr, POS_W);
                    sv(slot) <= '0';
                  elsif mm = CPR-1 then
                    sv(slot) <= '1';
                  end if;
                end if;
              end if;
            end loop;
            if w_mm + BEAT_CH >= CPR then
              w_mm <= w_mm + BEAT_CH - CPR;
              w_rr <= w_rr + 1;
              if w_slot = RBUF-1 then w_slot <= 0; else w_slot <= w_slot + 1; end if;
            else
              w_mm <= w_mm + BEAT_CH;
            end if;
            if r_rlast(s) = '1' then dout := dout - 1; end if;
          end if;

          outst <= outst + dout;

          -- ---- flush, AFTER the drain -----------------------------------
          --
          -- NOTHING BELOW EVER CLEARS `arv`.  Once ARVALID is asserted it must
          -- stand until ARREADY (AXI3 A3.1.2), and an AR withdrawn under a
          -- flush is the same class of channel corruption as an abandoned
          -- burst.  A flush therefore stops ISSUING and waits; the AR already
          -- presented completes, its beats arrive, and only then does the
          -- state clear.  The elsif chain is what stops the issue: the AR
          -- generator lives in the final `else` and no other branch reaches it.
          if flushing = '1' then
            if outst + dout = 0 and arv = '0' then
              sv <= (others => '0'); run_v <= '0'; halted <= '0';
              f_beat <= 0; c_max <= 0;
              lim_fresh <= '0';
              w_rr <= 0; w_mm <= 0; w_slot <= 0;
            end if;
          elsif halted = '1' then
            null;                             -- halted until the next start
          elsif run_v = '1' and hit = '0' and in_run = '0' and oor = '0' then
            -- ---- retarget: the same drain-then-flush, mid-job ------------
            if outst + dout = 0 and arv = '0' then
              run_v <= '0'; sv <= (others => '0');
              f_beat <= 0; c_max <= 0;
              lim_fresh <= '0';
              w_rr <= 0; w_mm <= 0; w_slot <= 0;
            end if;
          elsif run_v = '0' then
            -- ---- open a run at the held request -------------------------
            if oor = '0' and outst + dout = 0 and arv = '0' then
              if s = 0 then base := kb_r; else base := vb_r; end if;
              a0 := rec_addr(base, lay_r, to_integer(q_head(s)),
                             to_integer(q_pos(s)));
              ph_ch   <= low_bits(a0, BEAT_LW)/CH_B;
              w_rr    <= 0; w_slot <= 0;
              w_mm    <= -(low_bits(a0, BEAT_LW)/CH_B);   -- beat 0: kk = c - ph_ch
              ar_addr <= a0 - to_unsigned(low_bits(a0, BEAT_LW), ADDR_W);
              run_hd  <= q_head(s);
              run_p0  <= q_pos(s);
              run_v   <= '1';
              f_beat  <= 0; c_max <= 0;
              lim_fresh <= '0';
              sv      <= (others => '0');
            end if;
          else
            -- ---- AR issue along the run ---------------------------------
            if arv = '0' and outst + dout < MAXOUT
               and lim_fresh = '1' and lim_ok_r = '1' then
              -- ONE RECORD OF HEADROOM IS MANDATORY, and it is not slack.
              -- `lim_beat` is a CEILING, so the last beat of the permitted
              -- range carries the first chunk(s) of record lim_rec+1 as well.
              -- Those chunks must be ACCEPTED -- dropping them leaves a hole
              -- that no later AR re-requests, because `f_beat` has already
              -- moved past that beat -- so the slot they land in must not be
              -- one the consumer still owns.  MEASURED before this bound
              -- existed: the straddled chunk was record 4's HEADER, it was
              -- dropped, slot 0 kept record 0's `sp` while filling with record
              -- 4's mantissas, and the sweep hung at pos = 4 having silently
              -- built a record out of two different positions.
              -- The limit itself is lim_beat_r, computed at the top of the
              -- process one cycle ahead.
              left := lim_beat_r - f_beat;
              if left > 0 then
                n := burst_len(ar_addr, left);
                alen <= n;
                arv  <= '1';
              end if;
              -- The safety argument, checked in simulation on every issue: the
              -- registered limit never exceeds the one this cycle's values give.
              -- pragma translate_off
              lim_rec := c_max + RBUF - 2;
              if lim_rec > to_integer(cpos_r) - 1 - to_integer(run_p0) then
                lim_rec := to_integer(cpos_r) - 1 - to_integer(run_p0);
              end if;
              assert lim_rec >= 0
                     and lim_beat_r <= (ph_ch + (lim_rec+1)*CPR + BEAT_CH - 1)/BEAT_CH
                report "attn_kv_axi: the registered read limit is above the "
                     & "current one; a stale limit would issue past the buffer"
                severity failure;
              -- pragma translate_on
            end if;
          end if;
        end if;
      end if;
    end process;
  end generate;

  -- ======================================================================
  -- THE WRITE MASTER.  Capture and issue are ONE process: the buffer is read
  -- by the sequencer and written by the capture, and two processes would be
  -- two drivers on it.
  -- ======================================================================
  P_WR : process(clk)
    type wst_t is (WS_IDLE, WS_AW, WS_DATA);
    variable st     : wst_t := WS_IDLE;
    variable a0     : unsigned(ADDR_W-1 downto 0);
    variable astart : unsigned(ADDR_W-1 downto 0);
    variable phase  : integer := 0;
    variable nbeats : integer := 0;
    variable bi     : integer := 0;   -- beat index within the record stream
    variable blen   : integer := 0;   -- beats left in the current burst
    variable base   : std_logic_vector(ADDR_W-1 downto 0);
    variable bidx   : integer;

    -- Preload the beat `bi` into the W channel registers.  Bytes outside the
    -- record's own byte range are NOT strobed: at phase 16 the neighbouring
    -- record is real data 6% of the time and a full-strobe beat destroys it.
    procedure preload is
    begin
      for l in 0 to BEAT_CH-1 loop
        bidx := (bi*BEAT_B + l*CH_B) - phase;
        if bidx >= 0 and bidx < REC_B then
          w_wdata((l+1)*CH_W-1 downto l*CH_W) <= wbuf(bidx/CH_B);
        else
          w_wdata((l+1)*CH_W-1 downto l*CH_W) <= (others => '0');
        end if;
      end loop;
      for b in 0 to BEAT_B-1 loop
        bidx := bi*BEAT_B + b - phase;
        if bidx >= 0 and bidx < REC_B then
          w_wstrb(b) <= '1';
        else
          w_wstrb(b) <= '0';
        end if;
      end loop;
      if blen = 1 then w_wlast <= '1'; else w_wlast <= '0'; end if;
    end procedure;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        st := WS_IDLE; bi := 0; blen := 0;
        wb_cnt <= 0; wb_hgot <= '0'; wb_full <= '0';
        w_outst <= 0; wseq_idle <= '1'; err_w <= '0';
        w_awvalid <= '0'; w_wvalid <= '0'; w_wlast <= '0';
      else
        if start = '1' then err_w <= '0'; end if;

        -- ---- record capture from the quantizer side --------------------
        if kw_hen = '1' and wb_full = '0' and flushing = '0' then
          wbuf(0) <= (others => '0');
          wbuf(0)(NBLK*EXP_W-1 downto 0) <= kw_hdr;
          wb_sel  <= kw_sel;
          wb_hd   <= kw_head;
          wb_ps   <= kw_pos;
          wb_cnt  <= 0;
          wb_hgot <= '1';
        end if;
        if kw_en = '1' and wb_full = '0' and flushing = '0'
           and wb_hgot = '1' then
          for c in 0 to MPB-1 loop
            wbuf(1 + to_integer(kw_blk)*MPB + c)
              <= kw_mant((c+1)*CH_W-1 downto c*CH_W);
          end loop;
          if wb_cnt = NBLK-1 then
            wb_full <= '1';
            wb_hgot <= '0';
            wb_cnt  <= 0;
          else
            wb_cnt <= wb_cnt + 1;
          end if;
        end if;

        -- A flush discards a PARTIAL record.  Nothing was issued for it, so
        -- discarding it cannot hang a channel (section 7).
        if flushing = '1' and wb_full = '0' then
          wb_hgot <= '0'; wb_cnt <= 0;
        end if;

        -- ---- B responses -----------------------------------------------
        if w_bvalid = '1' then
          if w_bresp /= "00" then err_w <= '1'; end if;
          w_outst <= w_outst - 1;
        end if;

        -- ---- the AW/W sequencer ----------------------------------------
        case st is
          when WS_IDLE =>
            w_wvalid <= '0'; w_wlast <= '0';
            -- A record is issued only when the WHOLE of it is in the buffer,
            -- so the W engine can never starve mid-burst.
            if wb_full = '1' and err_w = '0' then
              if wb_sel = '0' then base := kb_r; else base := vb_r; end if;
              a0     := rec_addr(base, lay_r, to_integer(wb_hd),
                                 to_integer(wb_ps));
              phase  := low_bits(a0, BEAT_LW);
              astart := a0 - to_unsigned(phase, ADDR_W);
              nbeats := (phase + REC_B + BEAT_B - 1)/BEAT_B;
              bi     := 0;
              blen   := burst_len(astart, nbeats);
              w_awaddr  <= std_logic_vector(astart);
              w_awlen   <= std_logic_vector(to_unsigned(blen-1, 8));
              w_awvalid <= '1';
              preload;
              wseq_idle <= '0';
              st := WS_AW;
            elsif wb_full = '1' and err_w = '1' then
              wb_full <= '0';           -- halted: drop it rather than issue
            else
              wseq_idle <= '1';
            end if;

          when WS_AW =>
            if w_awready = '1' then
              w_awvalid <= '0';
              w_outst   <= w_outst + 1;
              w_wvalid  <= '1';
              st := WS_DATA;
            end if;

          when WS_DATA =>
            -- Once AW is accepted these beats MUST be delivered; no branch
            -- below can abandon them (section 7).
            if w_wready = '1' then
              bi   := bi + 1;
              blen := blen - 1;
              if blen = 0 then
                w_wvalid <= '0'; w_wlast <= '0';
                if bi >= nbeats then
                  wb_full <= '0';
                  wseq_idle <= '1';
                  st := WS_IDLE;
                else
                  astart := astart;   -- unchanged; the address advances by bi
                  blen := burst_len(astart + to_unsigned(bi*BEAT_B, ADDR_W),
                                    nbeats - bi);
                  w_awaddr  <= std_logic_vector(astart +
                                 to_unsigned(bi*BEAT_B, ADDR_W));
                  w_awlen   <= std_logic_vector(to_unsigned(blen-1, 8));
                  w_awvalid <= '1';
                  preload;
                  st := WS_AW;
                end if;
              else
                preload;
              end if;
            end if;
        end case;

        wr_quiet <= '0';
        if st = WS_IDLE and wb_full = '0' then wr_quiet <= '1'; end if;
      end if;
    end if;
  end process;

end architecture;
