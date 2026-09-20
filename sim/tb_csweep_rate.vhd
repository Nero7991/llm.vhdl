-- sim/tb_csweep_rate.vhd
-- WHAT DOES SUBSYSTEM C SPEND PER SEQUENCE POSITION, AND IS IT PER BEAT OR
-- PER POSITION?
--
-- ======================================================================
-- THE QUESTION THIS BENCH EXISTS TO ANSWER
-- ======================================================================
-- MEASURED on silicon 2026-09-20
-- (docs/debugging/2026-09-20_token-cost-grows-2793-cycles-per-position.md):
-- a token costs `30,115,217 + 2,793.4 * p` core cycles and 100% of the slope
-- is subsystem C.  DERIVED from the per-step profile,
-- `664,852 / 8 C jobs / 238 positions = 349.2` cycles per position per C job.
-- One layer's KV record for one position is 2176 B (manifest
-- `kv_bytes_per_layer_per_token`), which is 68 beats of 32 B, so the headline
-- rate is 5.14 core cycles per beat.
--
-- 5.14 cycles per beat LOOKS like the three other findings of the same day --
-- a wide memory reached one item per cycle.  This bench exists to test that
-- reading rather than assume it, because **a per-BEAT cost and a per-POSITION
-- cost have different fixes** and nothing on the card can tell them apart.
--
-- ======================================================================
-- WHAT IT MEASURES, AND WHY EACH NUMBER IS THE ONE IT IS
-- ======================================================================
-- One C job -- `rtl/attn_block.vhd` joined to `rtl/attn_kv_axi.vhd` at the
-- REAL Qwen3.5-9B geometry (HEAD_DIM 256, N_QH 16, N_KVH 4, KV_BLOCK 32,
-- NBLK 8) -- is run at several `cur_pos`, and the total cycles from `start`
-- to `busy` falling are printed per position.
--
--   CSWEEP_CYCLES <pos> <cycles>
--
-- The per-position slope is then taken THE SAME WAY THE SILICON FIGURE WAS:
-- from two endpoints, with the interior points as the test.  Fitting to all
-- of them would not be a test.
--
--   CSWEEP_SLOPE <cycles per position per job>
--
-- The breakdown is taken at the PORTS, because `attn_block`'s phase register
-- is not visible from outside and an external name would tie this bench to
-- a locally-declared enumeration.  Four spans per record pair, all of them
-- directly observable on `kr_en` / `vr_en`:
--
--   KSPAN   first `kr_en` of a record to its NBLK'th.  7 with no stall:
--           P_RECK issues one beat per cycle while `kr_rdy` stands.
--   MIDGAP  NBLK'th `kr_en` to first `vr_en`.  This is P_HDR, P_SCORE,
--           P_SCW, P_EPW and any rescale pass -- the SCORE half of the
--           position -- plus any wait for `vr_rdy`.
--   VSPAN   first `vr_en` to its NBLK'th.  7 with no stall.
--   LOOP    NBLK'th `vr_en` to the NEXT record pair's first `kr_en`, within
--           one KV head.  This is P_PV, P_POSN and any wait for `kr_rdy`.
--
-- KSPAN + MIDGAP + VSPAN + LOOP is the whole per-position cost of one KV
-- head, and N_KVH of them is the per-position cost of the job, which is the
-- 349.2 the card measured.
--
-- ======================================================================
-- THE CONTROL THAT MAKES THE SPLIT ATTRIBUTABLE
-- ======================================================================
-- `IDEAL_CACHE` replaces `attn_kv_axi` with a memory that can never refuse:
-- `kr_rdy` / `vr_rdy` tied high and a one-cycle registered read, which is
-- bit for bit the model `sim/tb_attn_block.vhd` uses.  Everything else --
-- the block, the geometry, the stimulus, the schedule -- is identical.
--
-- So `cycles(IDEAL) / position` is `attn_block`'s own floor and
-- `cycles(REAL) - cycles(IDEAL)` is the ENTIRE cost of the cache, with no
-- modelling argument in between.  Sweeping `RD_LAT` on top of that says
-- whether the cache's share is latency-bound (a prefetch window too shallow
-- for the bandwidth-delay product) or rate-bound (a narrow unpack).
--
-- A NOTE ON THE STIMULUS, STATED RATHER THAN BURIED.  The records this bench
-- serves are a deterministic function of the byte address and the activation
-- memories are a deterministic function of the read address; no oracle is
-- involved and none is claimed.  `attn_block`'s schedule is data-dependent
-- in exactly one place -- the softmax rescale pass (P_RSPASS / P_RSACK) fires
-- when a position produces a new running maximum -- so a constant-score
-- stimulus under-counts that pass and a wild one over-counts it.  `SPREAD`
-- selects between a flat record image and a varying one so the size of that
-- term is measured rather than assumed.  VALUES ARE NOT CHECKED HERE; they
-- are checked by `sim:seamgate_*`, `sim/tb_attn_kv_seam.vhd` and
-- `sim/tb_attn_kv_map.vhd` against `tools/ref9b/` and `ref/`.
--
-- ======================================================================
-- THE AXI SLAVE MODEL, AND HOW IT DIFFERS FROM THE SEAM BENCH'S
-- ======================================================================
-- `sim/tb_attn_kv_seam.vhd`'s read slave re-arms its latency timer AFTER
-- each burst completes, so two outstanding bursts cost 2*RD_LAT rather than
-- overlapping.  That is fine for a correctness bench and WRONG for a rate
-- one: real HBM pipelines, and a serialising slave would charge the design
-- for the model's own choice.  The slave here stamps each accepted AR with
-- `now + RD_LAT` and serves in order, so latency overlaps across the MAXOUT
-- window and the only serialisation left is the one beat per cycle the data
-- bus actually has.
--
-- The three AXI3 protocol facts the seam bench checks are checked here too,
-- because a rate bench that silently accepted a 17-beat burst would be
-- measuring a design that cannot be built: **the FK33 HBM slave is AXI3,
-- ARLEN is 4 bits, 16 beats is the hard cap** (rtl/hbm_tg_ip.vhd:1036).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.util_pkg.all;

entity tb_csweep_rate is
  generic(
    -- ---- the REAL Qwen3.5-9B one-card attention geometry --------------
    -- Provenance: rtl/model_cfg_pkg.vhd's QWEN35_9B at NCARDS = 1
    -- (attn_q_heads 16, attn_kv_heads 4, attn_head_dim 256) and
    -- rtl/fk33_llama_top.vhd's C_KV_BLOCK 32.  These are also
    -- rtl/attn_block.vhd's own generic defaults.
    HEAD_DIM : positive := 256;
    N_QH     : positive := 16;
    N_KVH    : positive := 4;
    KV_BLOCK : positive := 32;
    N_ROT    : positive := 64;
    -- LAYERS is 2 and not the card's 8 only so that the modelled address
    -- space stays small; the layer term of C spec 2.2's address equation is
    -- exercised either way and nothing here is per-layer.
    LAYERS   : positive := 2;
    MAXCTX   : positive := 2048;
    POS_W    : positive := 16;
    MANT_W   : positive := 16;
    CM_W     : positive := 8;
    EXP_W    : positive := 8;
    -- ---- the AXI side ------------------------------------------------
    AXI_DW   : positive := 256;
    ADDR_W   : positive := 25;
    MAXB     : positive := 16;   -- AXI3 cap; see the header
    MAXOUT   : positive := 4;
    RBUF     : positive := 4;
    RD_LAT   : natural  := 100;  -- AR accepted -> first beat, cycles
    WR_LAT   : natural  := 12;   -- WLAST -> BVALID
    STALL    : natural  := 0;    -- 0 = the slave never gaps RVALID
    -- ---- the experiment ----------------------------------------------
    -- Four positions.  P0 and P3 are the endpoints the slope is fitted
    -- from; P1 and P2 are the test, exactly as on the card.
    -- DEFAULTS ARE SMALL ON PURPOSE.  A new sim/tb_*.vhd is a gate row for
    -- every track whether its author meant it or not, so the shipping
    -- configuration is the one that runs in seconds; the 1/64/256/1024 sweep
    -- the finding needed is driven from the command line with -gP0.. .
    P0       : natural  := 1;
    P1       : natural  := 8;
    P2       : natural  := 16;
    P3       : natural  := 64;
    -- The control: no cache at all, a memory that cannot refuse.
    IDEAL_CACHE : boolean := false;
    -- 0 = a flat record image (no rescale pass after the first position);
    -- n > 0 = records varying with the address, which makes the running
    -- maximum move and the rescale pass fire.
    SPREAD   : natural  := 0;
    -- ---- the fix, OFF by default -------------------------------------
    -- See rtl/attn_block.vhd's SWEEP_PIPE generic.  This bench passes it
    -- straight through so one invocation measures both.
    SWEEP_PIPE : boolean := false;
    -- THE ROW'S TEETH.  Without a ceiling this bench prints numbers and
    -- passes whatever they are, which is decoration: a schedule regression
    -- in the sweep loop would raise the slope and the gate would stay green.
    -- The default is the MEASURED shipping slope at these generics
    -- (355.17 cycles per position per job, RD_LAT 100) plus 10 percent.  It
    -- is a CEILING and not a target: a change that lowers it is welcome and
    -- a change that raises it has to say so here, in a diff, on purpose.
    SLOPE_MAX_X100 : natural := 39000;
    WDOG     : positive := 200000
  );
end entity;

architecture sim of tb_csweep_rate is

  constant NBLK   : integer := HEAD_DIM/KV_BLOCK;
  constant G      : integer := N_QH/N_KVH;
  constant AW_B   : integer := clog2(NBLK);
  constant AW_H   : integer := clog2(N_KVH);
  constant CH_B   : integer := 16;
  constant REC_B  : integer := CH_B + HEAD_DIM*CM_W/8;   -- 272
  constant BEAT_B : integer := AXI_DW/8;                 -- 32

  -- C spec 2.2.  K and V are separate regions with separate bases; both are
  -- 16-byte aligned, which rtl/attn_kv_axi.vhd:619 REFUSES otherwise -- the
  -- recorded trap where a base one byte off is quantised away by the read
  -- engine and honoured by the write engine.
  constant RGN_B  : integer := LAYERS*N_KVH*MAXCTX*REC_B;
  constant K_BASE : integer := 0;
  constant V_BASE : integer := RGN_B;

  type pos_arr is array (0 to 3) of integer;
  constant CPOS : pos_arr := (P0, P1, P2, P3);

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal running : boolean := true;

  signal blk_start, kv_start : std_logic := '0';
  signal cur_pos : unsigned(POS_W-1 downto 0) := (others => '0');
  signal ctx_len : unsigned(POS_W-1 downto 0) := to_unsigned(MAXCTX, POS_W);
  signal busy, cfg_taken : std_logic;
  signal kv_seq_rst : std_logic := '0';
  signal seq_rst_taken : std_logic;
  signal lay_i : integer range 0 to LAYERS-1 := 0;

  signal qg_raddr : unsigned(clog2(2*HEAD_DIM*N_QH)-1 downto 0);
  signal qg_re    : std_logic;
  signal qg_rdata : signed(MANT_W-1 downto 0) := (others => '0');
  signal qg_exp   : signed(EXP_W-1 downto 0) := to_signed(0, EXP_W);
  signal kin_raddr : unsigned(clog2(HEAD_DIM*N_KVH)-1 downto 0);
  signal kin_re    : std_logic;
  signal kin_rdata : signed(MANT_W-1 downto 0) := (others => '0');
  signal kin_exp   : signed(EXP_W-1 downto 0) := to_signed(0, EXP_W);
  signal vin_raddr : unsigned(clog2(HEAD_DIM*N_KVH)-1 downto 0);
  signal vin_re    : std_logic;
  signal vin_rdata : signed(MANT_W-1 downto 0) := (others => '0');
  signal vin_exp   : signed(EXP_W-1 downto 0) := to_signed(0, EXP_W);

  signal qn_mant, kn_mant : std_logic_vector(HEAD_DIM*MANT_W-1 downto 0)
                            := (others => '0');
  signal qn_exp, kn_exp : signed(EXP_W-1 downto 0) := to_signed(12, EXP_W);
  signal wn_taken : std_logic;

  signal kv_layer : unsigned(clog2(LAYERS)-1 downto 0);
  signal kw_sel, kw_hen, kw_en : std_logic;
  signal kw_head : unsigned(AW_H-1 downto 0);
  signal kw_pos  : unsigned(POS_W-1 downto 0);
  signal kw_hdr  : std_logic_vector(NBLK*EXP_W-1 downto 0);
  signal kw_blk  : unsigned(AW_B-1 downto 0);
  signal kw_mant : std_logic_vector(KV_BLOCK*CM_W-1 downto 0);
  signal kw_rdy  : std_logic;

  signal kr_en, vr_en : std_logic;
  signal kr_head, vr_head : unsigned(AW_H-1 downto 0);
  signal kr_pos, vr_pos : unsigned(POS_W-1 downto 0);
  signal kr_rdy, vr_rdy : std_logic;
  signal kr_blk, vr_blk : unsigned(AW_B-1 downto 0);
  signal kr_hdr, vr_hdr : std_logic_vector(NBLK*EXP_W-1 downto 0)
                          := (others => '0');
  signal kr_mant, vr_mant : std_logic_vector(KV_BLOCK*CM_W-1 downto 0)
                            := (others => '0');
  signal kv_wr_idle : std_logic;

  signal y_valid, y_last, y_hdr_valid : std_logic;
  signal y_mant : signed(MANT_W-1 downto 0);
  signal y_index : unsigned(clog2(N_QH*HEAD_DIM)-1 downto 0);
  signal y_exp : signed(EXP_W-1 downto 0);
  signal blk_done : std_logic;
  signal blk_err, rope_sat, kv_sat, y_sat, z_sat, dbg_ep_lost : std_logic;
  signal rescale_max : unsigned(15 downto 0);

  signal kv_cfgt, kv_busy, kv_err : std_logic;

  signal r_arvalid : std_logic_vector(1 downto 0);
  signal r_arready : std_logic_vector(1 downto 0) := "11";
  signal r_araddr  : std_logic_vector(2*ADDR_W-1 downto 0);
  signal r_arlen   : std_logic_vector(15 downto 0);
  signal r_arsize  : std_logic_vector(5 downto 0);
  signal r_arburst : std_logic_vector(3 downto 0);
  signal r_rvalid  : std_logic_vector(1 downto 0) := "00";
  signal r_rready  : std_logic_vector(1 downto 0);
  signal r_rdata   : std_logic_vector(2*AXI_DW-1 downto 0)
                     := (others => '0');
  signal r_rlast   : std_logic_vector(1 downto 0) := "00";
  signal r_rresp   : std_logic_vector(3 downto 0) := "0000";

  signal w_awvalid, w_wvalid, w_wlast, w_bready : std_logic;
  signal w_awready : std_logic := '1';
  signal w_wready  : std_logic := '1';
  signal w_awaddr  : std_logic_vector(ADDR_W-1 downto 0);
  signal w_awlen   : std_logic_vector(7 downto 0);
  signal w_awsize  : std_logic_vector(2 downto 0);
  signal w_awburst : std_logic_vector(1 downto 0);
  signal w_wdata   : std_logic_vector(AXI_DW-1 downto 0);
  signal w_wstrb   : std_logic_vector(AXI_DW/8-1 downto 0);
  signal w_bvalid  : std_logic := '0';
  signal w_bresp   : std_logic_vector(1 downto 0) := "00";

  -- ---- instrumentation -------------------------------------------------
  signal cyc : integer := 0;
  signal job_active : boolean := false;
  -- ONE DRIVER PER SIGNAL.  The counters below are cleared by a PULSE from
  -- the driver rather than by the driver assigning them: two processes on an
  -- unresolved integer is `several sources for unresolved signal` with no
  -- line number, and it cost a round trip here already.
  signal instr_clr : std_logic := '0';

  signal n_pair  : integer := 0;   -- record pairs seen this job
  signal s_kspan : integer := 0;
  signal s_mid   : integer := 0;
  signal s_vspan : integer := 0;
  signal s_loop  : integer := 0;
  signal n_loop  : integer := 0;
  signal s_krlow : integer := 0;   -- cycles kr_rdy low inside a K span
  signal s_vrlow : integer := 0;
  signal n_ar    : integer := 0;
  signal n_beat  : integer := 0;
  signal slv_bad : integer := 0;

  signal job_cyc : pos_arr := (others => 0);

  -- ---- the modelled record image, a FUNCTION of the byte address -------
  -- Byte `i` of the region.  The first CH_B bytes of a record are its
  -- header chunk, of which only the first NBLK carry block exponents; the
  -- rest of the record is HEAD_DIM int8 mantissas.  The exponents are held
  -- at a constant well above anything the block's own quantizer produces so
  -- that site 3's `e_v[b] - v_ref` shift stays non-negative for the read
  -- records; a negative one is a legal quality event, not a fault, but it
  -- would be noise in a rate measurement.
  function mem_byte(i : integer) return std_logic_vector is
    variable off : integer;
    variable r   : integer;
  begin
    off := i mod REC_B;
    r   := i / REC_B;
    if off < NBLK then
      return std_logic_vector(to_unsigned(80, 8));
    elsif off < CH_B then
      return (7 downto 0 => '0');
    elsif SPREAD = 0 then
      return std_logic_vector(to_signed(3, 8));
    else
      return std_logic_vector(to_signed(((off*7 + r*13) mod (2*SPREAD+1))
                                        - SPREAD, 8));
    end if;
  end function;

begin

  clk <= not clk after 5 ns when running else '0';

  assert ADDR_W >= clog2(2*RGN_B + REC_B)
    report "tb_csweep_rate: ADDR_W too small for the modelled regions"
    severity failure;
  assert P3 < MAXCTX
    report "tb_csweep_rate: the largest position must be below MAXCTX"
    severity failure;
  assert (K_BASE mod CH_B) = 0 and (V_BASE mod CH_B) = 0
    report "tb_csweep_rate: both bases must be 16-byte aligned -- that is "
         & "the record granule and rtl/attn_kv_axi.vhd refuses otherwise"
    severity failure;

  -- ======================= the block ====================================
  u_blk : entity work.attn_block
    generic map ( HEAD_DIM => HEAD_DIM, N_QH => N_QH, N_KVH => N_KVH,
                  KV_BLOCK => KV_BLOCK, N_ROT => N_ROT, LAYERS => LAYERS,
                  POS_W => POS_W, MANT_W => MANT_W, CM_W => CM_W,
                  EXP_W => EXP_W, NORM_LANES => 1,
                  SWEEP_PIPE => SWEEP_PIPE,
                  STRICT_PRODUCER => true )
    port map ( clk => clk, rst => rst,
               start => blk_start, layer => lay_i,
               cur_pos => cur_pos, ctx_len => ctx_len, busy => busy,
               cfg_taken => cfg_taken,
               kv_seq_rst => kv_seq_rst, seq_rst_taken => seq_rst_taken,
               qg_raddr => qg_raddr, qg_re => qg_re, qg_rdata => qg_rdata,
               qg_exp => qg_exp,
               kin_raddr => kin_raddr, kin_re => kin_re,
               kin_rdata => kin_rdata, kin_exp => kin_exp,
               vin_raddr => vin_raddr, vin_re => vin_re,
               vin_rdata => vin_rdata, vin_exp => vin_exp,
               qn_mant => qn_mant, qn_exp => qn_exp,
               kn_mant => kn_mant, kn_exp => kn_exp, wn_taken => wn_taken,
               kv_layer => kv_layer,
               kw_sel => kw_sel, kw_head => kw_head, kw_pos => kw_pos,
               kw_hen => kw_hen, kw_hdr => kw_hdr, kw_en => kw_en,
               kw_blk => kw_blk, kw_mant => kw_mant, kw_rdy => kw_rdy,
               kr_en => kr_en, kr_head => kr_head, kr_pos => kr_pos,
               kr_rdy => kr_rdy,
               kr_blk => kr_blk, kr_hdr => kr_hdr, kr_mant => kr_mant,
               vr_en => vr_en, vr_head => vr_head, vr_pos => vr_pos,
               vr_rdy => vr_rdy,
               vr_blk => vr_blk, vr_hdr => vr_hdr, vr_mant => vr_mant,
               kv_wr_idle => kv_wr_idle,
               y_valid => y_valid, y_mant => y_mant, y_index => y_index,
               y_last => y_last, y_exp => y_exp, y_ready => '1',
               y_hdr_valid => y_hdr_valid,
               done => blk_done, done_ack => '1',
               err => blk_err, rope_sat => rope_sat, kv_sat => kv_sat,
               y_sat => y_sat, z_sat => z_sat,
               rescale_max => rescale_max, dbg_ep_lost => dbg_ep_lost );

  -- ======================= the cache, or the control ====================
  GEN_REAL : if not IDEAL_CACHE generate
    u_kv : entity work.attn_kv_axi
      generic map ( HEAD_DIM => HEAD_DIM, KV_BLOCK => KV_BLOCK,
                    N_KVH => N_KVH, LAYERS => LAYERS, MAXCTX => MAXCTX,
                    POS_W => POS_W, CM_W => CM_W, EXP_W => EXP_W,
                    AXI_DW => AXI_DW, ADDR_W => ADDR_W, MAXB => MAXB,
                    MAXOUT => MAXOUT, RBUF => RBUF )
      port map ( clk => clk, rst => rst,
                 start => kv_start, layer => lay_i,
                 cur_pos => cur_pos, ctx_len => ctx_len,
                 k_base => std_logic_vector(to_unsigned(K_BASE, ADDR_W)),
                 v_base => std_logic_vector(to_unsigned(V_BASE, ADDR_W)),
                 cfg_taken => kv_cfgt, busy => kv_busy,
                 wr_idle => kv_wr_idle, err => kv_err,
                 kw_sel => kw_sel, kw_head => kw_head, kw_pos => kw_pos,
                 kw_hen => kw_hen, kw_hdr => kw_hdr, kw_en => kw_en,
                 kw_blk => kw_blk, kw_mant => kw_mant, kw_rdy => kw_rdy,
                 kr_head => kr_head, kr_pos => kr_pos, kr_rdy => kr_rdy,
                 kr_en => kr_en, kr_blk => kr_blk, kr_hdr => kr_hdr,
                 kr_mant => kr_mant,
                 vr_head => vr_head, vr_pos => vr_pos, vr_rdy => vr_rdy,
                 vr_en => vr_en, vr_blk => vr_blk, vr_hdr => vr_hdr,
                 vr_mant => vr_mant,
                 r_arvalid => r_arvalid, r_arready => r_arready,
                 r_araddr => r_araddr, r_arlen => r_arlen,
                 r_arsize => r_arsize, r_arburst => r_arburst,
                 r_rvalid => r_rvalid, r_rready => r_rready,
                 r_rdata => r_rdata, r_rlast => r_rlast, r_rresp => r_rresp,
                 w_awvalid => w_awvalid, w_awready => w_awready,
                 w_awaddr => w_awaddr, w_awlen => w_awlen,
                 w_awsize => w_awsize, w_awburst => w_awburst,
                 w_wvalid => w_wvalid, w_wready => w_wready,
                 w_wdata => w_wdata, w_wstrb => w_wstrb, w_wlast => w_wlast,
                 w_bvalid => w_bvalid, w_bready => w_bready,
                 w_bresp => w_bresp );
  end generate;

  -- THE CONTROL.  A memory that can never refuse: the four `_rdy` inputs
  -- high and a ONE-CYCLE registered read with the header alongside every
  -- beat, which is bit for bit sim/tb_attn_block.vhd's model.  Nothing else
  -- in the bench changes, so the difference between the two runs is the
  -- cache and only the cache.
  GEN_IDEAL : if IDEAL_CACHE generate
    kr_rdy <= '1';
    vr_rdy <= '1';
    kw_rdy <= '1';
    kv_wr_idle <= '1';
    kv_err <= '0';
    r_arvalid <= "00";
    w_awvalid <= '0';
    w_wvalid  <= '0';
    w_wlast   <= '0';
    w_bready  <= '1';
    r_rready  <= "11";
    P_IDEAL : process(clk)
      variable a : integer;
    begin
      if rising_edge(clk) then
        if kr_en = '1' then
          a := K_BASE + ((lay_i*N_KVH + to_integer(kr_head))*MAXCTX
                         + to_integer(kr_pos))*REC_B;
          for b in 0 to NBLK-1 loop
            kr_hdr((b+1)*EXP_W-1 downto b*EXP_W) <= mem_byte(a + b);
          end loop;
          for t in 0 to KV_BLOCK-1 loop
            kr_mant((t+1)*CM_W-1 downto t*CM_W)
              <= mem_byte(a + CH_B + to_integer(kr_blk)*KV_BLOCK + t);
          end loop;
        end if;
        if vr_en = '1' then
          a := V_BASE + ((lay_i*N_KVH + to_integer(vr_head))*MAXCTX
                         + to_integer(vr_pos))*REC_B;
          for b in 0 to NBLK-1 loop
            vr_hdr((b+1)*EXP_W-1 downto b*EXP_W) <= mem_byte(a + b);
          end loop;
          for t in 0 to KV_BLOCK-1 loop
            vr_mant((t+1)*CM_W-1 downto t*CM_W)
              <= mem_byte(a + CH_B + to_integer(vr_blk)*KV_BLOCK + t);
          end loop;
        end if;
      end if;
    end process;
  end generate;

  -- ======================= the activation memories ======================
  -- Registered read WITH ENABLE, held across an edge at which the enable was
  -- low: the contract every master in attn_block states.
  amem : process(clk)
  begin
    if rising_edge(clk) then
      if qg_re  = '1' then
        qg_rdata  <= to_signed((to_integer(qg_raddr)  mod 23) - 11, MANT_W);
      end if;
      if kin_re = '1' then
        kin_rdata <= to_signed((to_integer(kin_raddr) mod 19) - 9, MANT_W);
      end if;
      if vin_re = '1' then
        vin_rdata <= to_signed((to_integer(vin_raddr) mod 17) - 8, MANT_W);
      end if;
    end if;
  end process;

  GEN_WN : for i in 0 to HEAD_DIM-1 generate
    qn_mant((i+1)*MANT_W-1 downto i*MANT_W)
      <= std_logic_vector(to_signed(4096, MANT_W));
    kn_mant((i+1)*MANT_W-1 downto i*MANT_W)
      <= std_logic_vector(to_signed(4096, MANT_W));
  end generate;

  -- ======================= the AXI read slaves ==========================
  -- ONE PROCESS FOR BOTH, and the reason is a recorded GHDL trap: two
  -- processes driving DISJOINT SLICES of one unresolved std_logic_vector do
  -- NOT elaborate as an error the way two processes on a scalar do, and GHDL
  -- mcode then delivers 'U' on one half silently
  -- (sim/tb_attn_kv_seam.vhd:687).
  --
  -- PIPELINED, unlike that bench's: each accepted AR is stamped with the
  -- cycle its first beat becomes available and the queue is served in order,
  -- so RD_LAT overlaps across the MAXOUT window.  A serialising slave would
  -- charge the design for the model.
  rslv : process(clk)
    type na_t is array (0 to 15) of integer;
    type ia_t is array (0 to 1) of integer;
    variable qa, ql, qt_rdy : na_t := (others => 0);
    variable qh, qt, qn, beat : ia_t := (others => 0);
    variable a, l : integer;
    variable lfsr : unsigned(15 downto 0) := x"ACE1";
    -- A SIGNAL ASSIGNED TWICE IN ONE DELTA KEEPS ONLY THE LAST VALUE, so
    -- `n_ar <= n_ar + 1` inside this `for s in 0 to 1` loop counted ONE event
    -- on any cycle where both masters acted.  MEASURED before the fix:
    -- rbeat = 2229 for a sweep that moves 4352 beats.  Accumulate in a
    -- variable, assign once.  Same trap the project records for bench check
    -- counters.
    variable dar, dbt : integer;
  begin
    if rising_edge(clk) then
      dar := 0; dbt := 0;
      lfsr := lfsr(14 downto 0)
              & (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));
      if rst = '1' then
        qh := (others => 0); qt := (others => 0); qn := (others => 0);
        beat := (others => 0);
        r_arready <= "11"; r_rvalid <= "00"; r_rlast <= "00";
      else
        if instr_clr = '1' then n_ar <= 0; n_beat <= 0; end if;
        r_rvalid <= "00"; r_rlast <= "00";
        for s in 0 to 1 loop
          if r_arvalid(s) = '1' and r_arready(s) = '1' then
            a := to_integer(unsigned(
                   r_araddr((s+1)*ADDR_W-1 downto s*ADDR_W)));
            l := to_integer(unsigned(r_arlen((s+1)*8-1 downto s*8))) + 1;
            -- The three AXI3 facts.  A 17-beat burst does not fail on a
            -- 4-bit ARLEN, it silently becomes a 1-beat burst.
            if l > MAXB then
              slv_bad <= slv_bad + 1;
              report "tb_csweep_rate: read burst of " & integer'image(l)
                   & " beats exceeds the AXI3 cap of " & integer'image(MAXB)
                severity error;
            end if;
            if (a mod 4096) + l*BEAT_B > 4096 then
              slv_bad <= slv_bad + 1;
              report "tb_csweep_rate: read burst at " & integer'image(a)
                   & " for " & integer'image(l) & " beats crosses 4 KB"
                severity error;
            end if;
            if a mod BEAT_B /= 0 then
              slv_bad <= slv_bad + 1;
              report "tb_csweep_rate: read address " & integer'image(a)
                   & " is not beat aligned" severity error;
            end if;
            qa(s*8 + qt(s)) := a;
            ql(s*8 + qt(s)) := l;
            qt_rdy(s*8 + qt(s)) := cyc + RD_LAT;
            qt(s) := (qt(s) + 1) mod 8;
            qn(s) := qn(s) + 1;
            dar := dar + 1;
          end if;
          if qn(s) < MAXOUT then r_arready(s) <= '1';
          else r_arready(s) <= '0'; end if;

          if qn(s) > 0 and cyc >= qt_rdy(s*8 + qh(s)) then
            if STALL /= 0
               and (to_integer(lfsr(7 downto 0)) + s) mod STALL = 0 then
              null;
            else
              for c in 0 to BEAT_B-1 loop
                r_rdata(s*AXI_DW + (c+1)*8-1 downto s*AXI_DW + c*8)
                  <= mem_byte(qa(s*8 + qh(s)) + beat(s)*BEAT_B + c);
              end loop;
              r_rvalid(s) <= '1';
              dbt := dbt + 1;
              if beat(s) = ql(s*8 + qh(s))-1 then r_rlast(s) <= '1'; end if;
              beat(s) := beat(s) + 1;
              if beat(s) = ql(s*8 + qh(s)) then
                beat(s) := 0;
                qh(s) := (qh(s) + 1) mod 8;
                qn(s) := qn(s) - 1;
              end if;
            end if;
          end if;
        end loop;
        if instr_clr = '0' then
          n_ar   <= n_ar + dar;
          n_beat <= n_beat + dbt;
        end if;
      end if;
    end if;
  end process;

  -- ======================= the AXI write slave ==========================
  -- Accept and discard.  This bench never reads back what it wrote -- every
  -- record it serves is a function of the address -- so the write path is
  -- modelled only well enough that `wr_idle` retires and `done` is not held
  -- by a missing BRESP.
  wslv : process(clk)
    variable tmr : integer := 0;
    variable pend : integer := 0;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        w_awready <= '1'; w_wready <= '1'; w_bvalid <= '0';
        pend := 0; tmr := 0;
      else
        if w_bvalid = '1' then w_bvalid <= '0'; end if;
        if w_awvalid = '1' and w_awready = '1' then
          pend := pend + 1;
        end if;
        if w_wvalid = '1' and w_wready = '1' and w_wlast = '1' then
          tmr := WR_LAT;
        end if;
        if tmr > 0 then
          tmr := tmr - 1;
          if tmr = 0 and pend > 0 then
            w_bvalid <= '1'; w_bresp <= "00"; pend := pend - 1;
          end if;
        end if;
      end if;
    end if;
  end process;

  -- ======================= the instrument ===============================
  -- Four spans per record pair, all taken from `kr_en` / `vr_en`, which are
  -- PORTS.  Nothing here reads inside either DUT.
  instr : process(clk)
    variable kc, vc : integer := 0;       -- beats seen in this record
    variable t_k1, t_k8, t_v1, t_v8 : integer := 0;
    variable have_prev : boolean := false;
    variable prev_head : integer := -1;
  begin
    if rising_edge(clk) then
      cyc <= cyc + 1;
      if rst = '1' then
        kc := 0; vc := 0; have_prev := false; prev_head := -1;
      elsif instr_clr = '1' then
        kc := 0; vc := 0; have_prev := false; prev_head := -1;
        n_pair <= 0; s_kspan <= 0; s_mid <= 0; s_vspan <= 0;
        s_loop <= 0; n_loop <= 0; s_krlow <= 0; s_vrlow <= 0;
      elsif job_active then
        if kr_en = '1' then
          if kc = 0 then
            t_k1 := cyc;
            if have_prev and to_integer(kr_head) = prev_head then
              s_loop <= s_loop + (cyc - t_v8);
              n_loop <= n_loop + 1;
            end if;
          end if;
          kc := kc + 1;
          if kc = NBLK then
            t_k8 := cyc;
            s_kspan <= s_kspan + (cyc - t_k1);
            kc := 0;
          end if;
        end if;
        if vr_en = '1' then
          if vc = 0 then
            t_v1 := cyc;
            s_mid <= s_mid + (cyc - t_k8);
          end if;
          vc := vc + 1;
          if vc = NBLK then
            t_v8 := cyc;
            s_vspan <= s_vspan + (cyc - t_v1);
            vc := 0;
            n_pair <= n_pair + 1;
            have_prev := true;
            prev_head := to_integer(vr_head);
          end if;
        end if;
        -- Residency refusals, counted only INSIDE a record the block has
        -- started, which is the only window in which a low `_rdy` is a
        -- stall rather than an idle answer.
        if kc > 0 and kr_rdy = '0' then s_krlow <= s_krlow + 1; end if;
        if vc > 0 and vr_rdy = '0' then s_vrlow <= s_vrlow + 1; end if;
      end if;
    end if;
  end process;

  -- ======================= the driver ===================================
  drive : process
    variable t0 : integer;
    variable den, num : integer;
    variable slope_x100 : integer;
    variable pred : integer;
    variable l : line;

    impure function nl_safe(n : integer) return integer is
    begin
      if n < 1 then return 1; else return n; end if;
    end function;

    procedure emit(s : string) is
      variable ll : line;
    begin
      write(ll, s); writeline(output, ll);
    end procedure;

    procedure run_job(p : integer; idx : integer) is
      variable ts : integer;
    begin
      cur_pos <= to_unsigned(p, POS_W);
      ctx_len <= to_unsigned(MAXCTX, POS_W);
      wait until rising_edge(clk);
      instr_clr <= '1';
      wait until rising_edge(clk);
      instr_clr <= '0';
      wait until rising_edge(clk);
      ts := cyc;
      job_active <= true;
      blk_start <= '1'; kv_start <= '1';
      wait until rising_edge(clk);
      blk_start <= '0'; kv_start <= '0';
      wait until rising_edge(clk);
      loop
        wait until rising_edge(clk);
        exit when busy = '0';
      end loop;
      job_active <= false;
      job_cyc(idx) <= cyc - ts;
      wait until rising_edge(clk);
      emit("CSWEEP_CYCLES " & integer'image(p) & " "
           & integer'image(job_cyc(idx)));
      emit("CSWEEP_BREAK " & integer'image(p)
           & " pairs=" & integer'image(n_pair)
           & " kspan=" & integer'image(s_kspan)
           & " midgap=" & integer'image(s_mid)
           & " vspan=" & integer'image(s_vspan)
           & " loop=" & integer'image(s_loop)
           & " nloop=" & integer'image(n_loop)
           & " krdy_low=" & integer'image(s_krlow)
           & " vrdy_low=" & integer'image(s_vrlow)
           & " ar=" & integer'image(n_ar)
           & " rbeat=" & integer'image(n_beat));
      if n_pair > 0 then
        emit("CSWEEP_PER_PAIR " & integer'image(p)
             & " kspan_x100=" & integer'image(s_kspan*100/n_pair)
             & " midgap_x100=" & integer'image(s_mid*100/n_pair)
             & " vspan_x100=" & integer'image(s_vspan*100/n_pair)
             & " loop_x100="
             & integer'image(s_loop*100/nl_safe(n_loop)));
      end if;
    end procedure;
  begin
    emit("CSWEEP_CONFIG hd=" & integer'image(HEAD_DIM)
         & " nqh=" & integer'image(N_QH)
         & " nkvh=" & integer'image(N_KVH)
         & " kvblk=" & integer'image(KV_BLOCK)
         & " nblk=" & integer'image(NBLK)
         & " rec_b=" & integer'image(REC_B)
         & " axi_dw=" & integer'image(AXI_DW)
         & " maxb=" & integer'image(MAXB)
         & " maxout=" & integer'image(MAXOUT)
         & " rbuf=" & integer'image(RBUF)
         & " rd_lat=" & integer'image(RD_LAT)
         & " stall=" & integer'image(STALL)
         & " spread=" & integer'image(SPREAD)
         & " ideal=" & boolean'image(IDEAL_CACHE)
         & " sweep_pipe=" & boolean'image(SWEEP_PIPE));

    rst <= '1';
    for i in 1 to 8 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);
    kv_seq_rst <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    kv_seq_rst <= '0';
    wait until rising_edge(clk);

    for i in 0 to 3 loop
      run_job(CPOS(i), i);
    end loop;

    -- THE SLOPE, FITTED FROM THE TWO ENDPOINTS AND TESTED ON THE INTERIOR.
    -- Fitting to all four would not be a test: with two free parameters and
    -- four points a good fit is nearly guaranteed.  This is the method the
    -- card's own measurement used and it is copied deliberately.
    den := CPOS(3) - CPOS(0);
    num := job_cyc(3) - job_cyc(0);
    slope_x100 := (num*100)/den;
    emit("CSWEEP_SLOPE_X100 " & integer'image(slope_x100));
    for i in 1 to 2 loop
      pred := job_cyc(0) + (slope_x100*(CPOS(i) - CPOS(0)))/100;
      emit("CSWEEP_TEST " & integer'image(CPOS(i))
           & " measured=" & integer'image(job_cyc(i))
           & " predicted=" & integer'image(pred)
           & " residual=" & integer'image(job_cyc(i) - pred));
    end loop;
    emit("CSWEEP_PER_POS_PER_JOB_X100 " & integer'image(slope_x100));
    emit("CSWEEP_SLOPE_CEILING " & integer'image(SLOPE_MAX_X100));
    emit("CSWEEP_STATUS err=" & std_logic'image(blk_err)
         & " kv_err=" & std_logic'image(kv_err)
         & " slv_bad=" & integer'image(slv_bad));

    if slv_bad /= 0 then
      emit("CSWEEP: FAIL slave protocol violations");
      running <= false;
      wait;
    end if;
    if slope_x100 > SLOPE_MAX_X100 then
      emit("CSWEEP: FAIL the sweep costs "
           & integer'image(slope_x100/100) & " cycles per position per job, "
           & "over the ceiling of " & integer'image(SLOPE_MAX_X100/100));
      running <= false;
      wait;
    end if;
    emit("CSWEEP: PASS");
    running <= false;
    wait;
  end process;

  -- ======================= the watchdog =================================
  -- A sweep that stalls is a HANG, and a hang scored by the stop time is
  -- indistinguishable from a slow run.
  wdog_p : process(clk)
    variable q : integer := 0;
  begin
    if rising_edge(clk) then
      if kr_en = '1' or vr_en = '1' or y_valid = '1' or blk_done = '1'
         or busy = '0' then
        q := 0;
      else
        q := q + 1;
        assert q < WDOG
          report "tb_csweep_rate: " & integer'image(WDOG)
               & " cycles of dead air -- the sweep has hung"
          severity failure;
      end if;
    end if;
  end process;

end architecture;
