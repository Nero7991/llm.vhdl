-- rtl/engine_shared.vhd
-- SHARED-DATAPATH autoregressive transformer engine -- the SILICON-FITTABLE
-- version of rtl/engine.vhd.
--
-- engine.vhd is functionally correct but instantiates EVERY unit per use (5
-- layer_ar, each with its own rmsnorm x3 / matmul x7 / rope / attention / swiglu
-- -> ~902 DSP), so it does not fit the XCZU3EG.  engine_shared instead holds ONE
-- instance of each unit and TIME-MULTIPLEXES them, via a single master FSM,
-- across all 5 transformer layers and all 35 matmuls, producing the IDENTICAL
-- token stream:
--
--   * ONE `matmul_rt` for ALL matmuls -- the FSM drives mat_sel in
--     {WQ,WK,WV,WO,W1,W3,W2} and layer in 0..4; weights come from the unit's
--     on-chip ROM (one shared mac_array = 1 DSP).
--   * ONE `rmsnorm` reused for att-rmsnorm, ffn-rmsnorm AND final rmsnorm -- the
--     FSM routes the small (64-wide) weight vector from work.weights_pkg
--     (ATT_RMS_W[L] / FFN_RMS_W[L] / FINAL_RMS_W) via a combinational mux into
--     the shared unit's w_mant/w_exp ports.
--   * ONE `rope`, ONE `swiglu`, ONE `embed`, ONE `lm_head`, ONE `sampler`.
--   * ONE `attention_ml` holding NLAYERS persistent KV banks selected by a
--     runtime `layer` port; the attention COMPUTE (scores/softmax/weighted-sum)
--     is shared across all layers.  A kv_reset pulse at run start clears every
--     bank so the run begins empty.
--
-- Master FSM per token at position `pos` (mirrors engine.vhd + layer_ar.vhd):
--   embed -> for L in 0..4: rmsnorm(att,L) -> matmul(WQ/WK/WV,L) -> rope(pos) ->
--            attention(bank=L, cur_pos=pos) -> matmul(WO,L) -> residual1 ->
--            rmsnorm(ffn,L) -> matmul(W1/W3,L) -> swiglu -> matmul(W2,L) ->
--            residual2 -> x
--   after 5 layers: rmsnorm(final) -> lm_head -> sampler(argmax) -> next token.
-- Prompt is teacher-forced (ids 1,403,407,261,378) then greedy, exactly as
-- engine.vhd / tb_engine.  RESIDUALS use the same integer exp-aligned add as
-- layer_ar.vhd.  No `real`, no TEXTIO.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;      -- msb_pos
use work.fixed_pkg.all;     -- scale_mul
use work.rms_weights_pkg.all;   -- intarr + ATT_RMS_W/FFN_RMS_W/FINAL_RMS_W (+ exps)
                                -- (small split-out pkg; the 227K weight aggregate
                                -- lives in mem/rom/*.mem, file-loaded by matmul_rt)

entity engine_shared is
  generic(
    DIM        : integer := 64;
    HIDDEN     : integer := 172;
    NHEADS     : integer := 8;
    NKVH       : integer := 4;
    KVDIM      : integer := 32;
    HEAD_SIZE  : integer := 8;
    VOCAB      : integer := 512;
    MAXPOS     : integer := 24;
    NLAYERS    : integer := 5;
    NUM_PROMPT : integer := 5;
    NGEN       : integer := 16;  -- total positions to run: p = 0 .. NGEN-1
    -- DEBUG_TAPS: when true, the residual-stream observation taps (is_nz OR-trees
    -- over the full DIM*16 mantissa buses at embed/att-rms/att-out/L0/L4/final,
    -- plus the rms input/argmax taps) are synthesized and drive the dbg_* ports.
    -- When false (default) those `if DEBUG_TAPS ...` branches are statically dead,
    -- so Vivado PRUNES the ~6 wide OR-reductions -> frees ~1.2K LUT of routing
    -- headroom for the FIT build (the taps do NOT affect the token stream, so the
    -- result is bit-identical; tb_engine_shared stays 24/24).  Re-enable
    -- (DEBUG_TAPS=>true) for the on-board residual-stream debug build.
    DEBUG_TAPS : boolean := false;
    -- Directory of the file-init weight ROMs (matmul_rt/embed/lm_head).  Default
    -- "../mem/rom/" resolves from sim/ for GHDL + OOC Vivado; the design_1
    -- module-reference overrides this to an ABSOLUTE path so the .mem files
    -- resolve during the impl synth run (whose CWD is the run dir).
    ROM_DIR    : string  := "../mem/rom/"
  );
  port(
    clk         : in  std_logic;
    rst         : in  std_logic;
    start       : in  std_logic;
    token_out   : out integer;
    pos_out     : out integer;
    token_valid : out std_logic;
    run_done    : out std_logic;
    -- DEBUG TAPS: for the position p_idx == dbg_pos, latch a summary of the
    -- residual stream x at 4 points (after embed / after layer 0 / after all 5
    -- layers / after final rmsnorm = lm_head input) plus that position's argmax.
    -- nz = OR of all mantissa bits (is x all-zero?), e = block exp, m = x[0].
    dbg_pos     : in  integer := -1;
    -- ---- RUNTIME PROMPT ----------------------------------------------------
    -- The prompt used to be the compile-time constant PROMPT=(1,403,407,261,378)
    -- ("<BOS> Once upon a time"), so the engine could only ever tell one story.
    -- It is now an input: prompt_mant packs up to MAXPOS token ids, 16 bits each,
    -- index i in bits (i+1)*16-1 downto i*16, and prompt_len says how many are
    -- valid.  The DEFAULTS below reproduce the old baked prompt exactly, so any
    -- instantiation that leaves these unmapped (tb_engine_shared, tb_engine_dbg,
    -- ...) is bit-identical to before -- which keeps the 24/24 golden gate honest.
    --   x"...0000 017A 0105 0197 0193 0001" = 1, 403, 407, 261, 378, then zeros
    prompt_mant : in  std_logic_vector(MAXPOS*16-1 downto 0) :=
        x"0000000000000000000000000000000000000000000000000000000000000000000000000000" &
        x"017A0105019701930001";
    prompt_len  : in  integer := NUM_PROMPT;
    dbg_emb_nz  : out std_logic; dbg_emb_e : out integer; dbg_emb_m : out std_logic_vector(15 downto 0);
    dbg_l0_nz   : out std_logic; dbg_l0_e  : out integer; dbg_l0_m  : out std_logic_vector(15 downto 0);
    -- finer per-layer x taps: x after residual2 of layers 1, 2, 3 (localise collapse)
    dbg_l1_nz   : out std_logic; dbg_l1_e  : out integer; dbg_l1_m  : out std_logic_vector(15 downto 0);
    dbg_l2_nz   : out std_logic; dbg_l2_e  : out integer; dbg_l2_m  : out std_logic_vector(15 downto 0);
    dbg_l3_nz   : out std_logic; dbg_l3_e  : out integer; dbg_l3_m  : out std_logic_vector(15 downto 0);
    dbg_l4_nz   : out std_logic; dbg_l4_e  : out integer; dbg_l4_m  : out std_logic_vector(15 downto 0);
    dbg_fin_nz  : out std_logic; dbg_fin_e : out integer; dbg_fin_m : out std_logic_vector(15 downto 0);
    -- intra-layer-0 taps: after the attention-rmsnorm and after attention itself
    dbg_rms_nz  : out std_logic; dbg_rms_e : out integer; dbg_rms_m : out std_logic_vector(15 downto 0);
    dbg_att_nz  : out std_logic; dbg_att_e : out integer; dbg_att_m : out std_logic_vector(15 downto 0);
    -- ---- INTRA-LAYER-0 STAGE BISECT TAPS -----------------------------------
    -- The attention OUTPUT (dbg_att_*) now reads BIT-EXACT on silicon, yet x after
    -- layer 0 (dbg_l0_*) is still ~2^20 over-scaled, so a stage between them breaks.
    -- One tap per stage of the remaining layer-0 chain, same dbgpack summary
    -- (nz = OR of every mantissa bit, e = block exp, m = element 0), latched in the
    -- FSM wait-state where that stage's result becomes valid, under the same
    -- DEBUG_TAPS / p_idx = dbg_pos / cur_layer = 0 gate as every other tap:
    --   attention out -> [WO] -> [res1] -> [ffn-rms] -> [W1] -> [W3] ->
    --   swiglu -> [bfp_pack] -> [W2] -> residual2 (= dbg_l0_*)
    dbg_wo_nz   : out std_logic; dbg_wo_e  : out integer; dbg_wo_m  : out std_logic_vector(15 downto 0);
    dbg_r1_nz   : out std_logic; dbg_r1_e  : out integer; dbg_r1_m  : out std_logic_vector(15 downto 0);
    dbg_rf_nz   : out std_logic; dbg_rf_e  : out integer; dbg_rf_m  : out std_logic_vector(15 downto 0);
    dbg_w1_nz   : out std_logic; dbg_w1_e  : out integer; dbg_w1_m  : out std_logic_vector(15 downto 0);
    dbg_w3_nz   : out std_logic; dbg_w3_e  : out integer; dbg_w3_m  : out std_logic_vector(15 downto 0);
    dbg_hb_nz   : out std_logic; dbg_hb_e  : out integer; dbg_hb_m  : out std_logic_vector(15 downto 0);
    dbg_w2_nz   : out std_logic; dbg_w2_e  : out integer; dbg_w2_m  : out std_logic_vector(15 downto 0);
    -- inputs the engine feeds the L0 att-rmsnorm: checksums (sum of the 64 int16s)
    -- of x and w, plus their exps -- to see if x/weights are corrupt on HW.
    dbg_rxchk   : out integer; dbg_rwchk : out integer;
    dbg_rxe     : out integer; dbg_rwe   : out integer; dbg_rw0 : out std_logic_vector(15 downto 0);
    dbg_samptok : out integer;
    -- attention-internal taps (localise the attention non-determinism)
    dbg_att_sc  : out integer; dbg_att_sum : out integer; dbg_att_num : out integer;
    -- PER-HEAD / PER-LANE attention probes (oversized-lane hunt).  dbg_att_sum /
    -- dbg_att_num above are HEAD-0 ONLY and read bit-correct on silicon, yet the
    -- QCLAMP guard fires -> the oversized xb_acc lane is in another head.  These
    -- cover all 8 heads / 64 lanes.  Latched, like every other tap, at att_done
    -- for p_idx = dbg_pos and cur_layer = 0.
    dbg_att_sums   : out std_logic_vector(NHEADS*32-1 downto 0); -- sum_l per head
    dbg_att_amax_l : out std_logic_vector(31 downto 0);          -- amax_s(31:0)
    dbg_att_amax_h : out std_logic_vector(31 downto 0);          -- amax_s(63:32)
    dbg_att_nmax_l : out std_logic_vector(31 downto 0);          -- max|num_s|(31:0)
    dbg_att_nmax_h : out std_logic_vector(31 downto 0);          -- max|num_s|(63:32)
    -- {nmax lane[15:8], amax lane[7:0]}; head = lane/HEAD_SIZE
    dbg_att_idx    : out std_logic_vector(15 downto 0);
    -- ---- FAILING-DIVISION taps (attention_ml S_WDIV) -----------------------
    -- Every divide INPUT reads bit-correct on silicon yet amax_s comes back as
    -- exactly QCLAMP (2^40-1) -- impossible from those operands.  These expose the
    -- actual division: the PRE-clamp quotient plus the operands as consumed, for
    -- (a) the FIRST division that exceeded the guard (event-latched, lane not
    -- hardcoded) and (b) unconditionally for hd=0/t_idx=1.  Same latch gate as
    -- every other tap: p_idx = dbg_pos and cur_layer = 0.
    dbg_cd_qmag_l  : out std_logic_vector(31 downto 0);  -- pre-clamp qmag[31:0]
    dbg_cd_qmag_h  : out std_logic_vector(31 downto 0);  -- pre-clamp qmag[63:32]
    dbg_cd_nmag_l  : out std_logic_vector(31 downto 0);  -- dividend mag[31:0]
    dbg_cd_nmag_h  : out std_logic_vector(31 downto 0);  -- dividend mag[63:32]
    dbg_cd_nsd_l   : out std_logic_vector(31 downto 0);  -- raw ns_dout[31:0]
    dbg_cd_nsd_h   : out std_logic_vector(31 downto 0);  -- raw ns_dout[63:32]
    dbg_cd_sum     : out std_logic_vector(31 downto 0);  -- divisor sum_l[31:0]
    dbg_cd_meta    : out std_logic_vector(31 downto 0);  -- {seen,cnt[6:0],hd,t,lane}
    dbg_l1_qmag_l  : out std_logic_vector(31 downto 0);  -- hd0/t1 pre-clamp qmag lo
    dbg_l1_qmag_h  : out std_logic_vector(31 downto 0);  -- hd0/t1 pre-clamp qmag hi
    dbg_l1_nsd_l   : out std_logic_vector(31 downto 0);  -- hd0/t1 ns_dout lo
    dbg_l1_nsd_h   : out std_logic_vector(31 downto 0);  -- hd0/t1 ns_dout hi
    dbg_l1_sum     : out std_logic_vector(31 downto 0);  -- hd0/t1 sum_l[31:0]
    -- nmag / running-max-quotient capture (same gating as every other tap:
    -- p_idx = dbg_pos and cur_layer = 0).  dbg_l1_nmag_* is the DIVIDEND the
    -- hd0/t1 divide actually consumed -- the operand the old probe set missed,
    -- since it was only latched on a clamp event and clamps no longer fire.
    -- dbg_qx_* is the largest-pre-clamp-quotient division of the whole call
    -- (lane-agnostic), i.e. the one that sets the sticky amax_s / output exp.
    dbg_l1_nmag_l  : out std_logic_vector(31 downto 0);  -- hd0/t1 nmag[31:0]
    dbg_l1_nmag_h  : out std_logic_vector(31 downto 0);  -- hd0/t1 nmag[63:32]
    dbg_qx_qmag_l  : out std_logic_vector(31 downto 0);  -- max pre-clamp qmag lo
    dbg_qx_qmag_h  : out std_logic_vector(31 downto 0);  -- max pre-clamp qmag hi
    dbg_qx_nmag_l  : out std_logic_vector(31 downto 0);  -- its dividend lo
    dbg_qx_nmag_h  : out std_logic_vector(31 downto 0);  -- its dividend hi
    dbg_qx_nsd_l   : out std_logic_vector(31 downto 0);  -- its ns_dout lo
    dbg_qx_nsd_h   : out std_logic_vector(31 downto 0);  -- its ns_dout hi
    dbg_qx_sum     : out std_logic_vector(31 downto 0);  -- its divisor sum_l[31:0]
    dbg_qx_meta    : out std_logic_vector(31 downto 0);  -- {valid,cnt,hd,t,lane}
    -- ---- SHARED-RMSNORM INTERNAL BISECT (the current first divergence) ------
    -- The SAME rmsnorm instance is bit-exact on its layer-0 ATT invocation and
    -- wrong on its FFN invocation.  u_rmsnorm exposes its whole pipeline; these
    -- latch it at BOTH invocations (same p_idx = dbg_pos / cur_layer = 0 gate),
    -- so one board read says which step first differs -- and the ATT copy is the
    -- known-good control measured on the same silicon in the same run.
    --   xchk/ssq -> the WHOLE input vector (the dbgpack taps only see element 0,
    --               so a wrong element 1..63 is invisible to them yet changes
    --               ssq -> mean_sq -> inv -> every output mantissa)
    --   msq      -> S_INV shift math;  inv -> the pipelined rsqrt
    --   wchk     -> the ATT/FFN weight mux;  maxraw/shift -> S_RAW scan
    dbg_rf_xchk    : out std_logic_vector(31 downto 0);  -- FFN call: sum(x mant)
    dbg_rf_wchk    : out std_logic_vector(31 downto 0);  -- FFN call: sum(w mant)
    dbg_rf_ssq_l   : out std_logic_vector(31 downto 0);  -- FFN call: S[31:0]
    dbg_rf_ssq_h   : out std_logic_vector(31 downto 0);  -- FFN call: S[63:32]
    dbg_rf_msq_l   : out std_logic_vector(31 downto 0);  -- FFN call: mean_sq_q lo
    dbg_rf_msq_h   : out std_logic_vector(31 downto 0);  -- FFN call: mean_sq_q hi
    dbg_rf_inv     : out std_logic_vector(31 downto 0);  -- FFN call: inv32
    dbg_rf_mrw_l   : out std_logic_vector(31 downto 0);  -- FFN call: max_raw lo
    dbg_rf_mrw_h   : out std_logic_vector(31 downto 0);  -- FFN call: max_raw hi
    dbg_rf_sh      : out integer;                        -- FFN call: shift_total
    dbg_ra_xchk    : out std_logic_vector(31 downto 0);  -- ATT call: sum(x mant)
    dbg_ra_ssq_l   : out std_logic_vector(31 downto 0);  -- ATT call: S[31:0]
    dbg_ra_inv     : out std_logic_vector(31 downto 0);   -- ATT call: inv32
    -- ---- WHOLE-VECTOR DATAFLOW CHAIN (vchk signatures) ---------------------
    -- Walked in dataflow order, the first vchk that differs from sim names the
    -- exact point the residual stream is corrupted.  Each UNIT OUTPUT is paired
    -- with the STAGING REGISTER the engine copies it into, because a wide
    -- zero-logic reg-to-reg copy is this design's known on-silicon hold hazard
    -- (the attention v_reg->att_v_new_mant bug had exactly that shape), and an
    -- element-0 tap cannot see it.
    dbg_vc_emb     : out std_logic_vector(31 downto 0);  -- embed unit output
    dbg_vc_xcur    : out std_logic_vector(31 downto 0);  -- -> x_mant_cur staging
    dbg_vc_wo      : out std_logic_vector(31 downto 0);  -- WO matmul unit output
    dbg_vc_woreg   : out std_logic_vector(31 downto 0);  -- -> wo_reg staging
    dbg_vc_res1    : out std_logic_vector(31 downto 0);  -- residual-1 unit output
    dbg_vc_xm      : out std_logic_vector(31 downto 0);  -- -> xm_mant staging
    dbg_vc_rmsx    : out std_logic_vector(31 downto 0);  -- -> rmsnorm x port
    dbg_vc_rmso    : out std_logic_vector(31 downto 0);  -- FFN rmsnorm output
    -- W1/W3 are HIDDEN(172)-wide; the dbgpack taps only ever showed element 0,
    -- so a wrong element 1..171 there is invisible yet drives swiglu -> bfp_pack's
    -- max scan.  Whole-vector signatures close that gap.
    dbg_vc_w1      : out std_logic_vector(31 downto 0);
    dbg_vc_w3      : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of engine_shared is

  -- matmul_rt shared-width parameters (largest of any matmul).
  constant MAXROWS : integer := HIDDEN;   -- 172 (W1/W3)
  constant MAXCOLS : integer := HIDDEN;   -- 172 (W2 in_cols)

  -- mat_sel encoding (matches matmul_rt ROM layout).
  constant WQ_SEL : integer := 0;
  constant WK_SEL : integer := 1;
  constant WV_SEL : integer := 2;
  constant WO_SEL : integer := 3;
  constant W1_SEL : integer := 4;
  constant W3_SEL : integer := 5;
  constant W2_SEL : integer := 6;

  -- rmsnorm weight-mode encoding.
  constant RMS_ATT   : integer := 0;
  constant RMS_FFN   : integer := 1;
  constant RMS_FINAL : integer := 2;

  -- Prompt tokens (stories260K "Once upon a time"), compile-time constant.
  -- Retired: the prompt is now the runtime `prompt_mant`/`prompt_len` inputs.
  -- Token ids are 0..VOCAB-1 and unsigned, so a plain unsigned slice is right --
  -- do NOT route this through a VHDL integer and back (see the bfp_pack history).
  function ptok(v : std_logic_vector; i : integer) return integer is
  begin
    return to_integer(unsigned(v((i+1)*16-1 downto i*16)));
  end function;

  type s64arr is array(natural range <>) of signed(63 downto 0);

  -- ---- packed per-layer RMSNorm weight constants -------------------------
  subtype dimslv is std_logic_vector(DIM*16-1 downto 0);
  type dimslv_arr is array(0 to NLAYERS-1) of dimslv;

  -- Pack an intarr's per-layer DIM slice into an int16-mantissa slv.
  function pack_layers(a : intarr) return dimslv_arr is
    variable r : dimslv_arr;
  begin
    for l in 0 to NLAYERS-1 loop
      for j in 0 to DIM-1 loop
        r(l)((j+1)*16-1 downto j*16) := std_logic_vector(to_signed(a(l*DIM+j), 16));
      end loop;
    end loop;
    return r;
  end function;

  function pack_final(a : intarr) return dimslv is
    variable r : dimslv;
  begin
    for j in 0 to DIM-1 loop
      r((j+1)*16-1 downto j*16) := std_logic_vector(to_signed(a(j), 16));
    end loop;
    return r;
  end function;

  constant ATT_W_MANT_L : dimslv_arr := pack_layers(ATT_RMS_W);
  constant FFN_W_MANT_L : dimslv_arr := pack_layers(FFN_RMS_W);
  constant FINAL_W_MANT : dimslv     := pack_final(FINAL_RMS_W);

  -- Zero-pad a narrow packed vector up to MAXCOLS*16 (matmul_rt masks the
  -- surplus columns internally; padding just keeps sim clean).
  function pad_cols(v : std_logic_vector) return std_logic_vector is
    variable r : std_logic_vector(MAXCOLS*16-1 downto 0) := (others => '0');
  begin
    r(v'length-1 downto 0) := v;
    return r;
  end function;

  -- ---------------------------------------------------------------------
  -- vchk: cheap POSITION-SENSITIVE signature of a whole packed vector.
  -- Every debug tap so far reported only element 0 + the block exponent, which
  -- is blind to a corrupted element 1..63 -- and that is exactly what the
  -- rmsnorm bisect found (rmsnorm's own math is faithful, but the x vector it
  -- consumes has a different sum AND sum-of-squares from sim while element 0
  -- and the exponent are bit-exact).  A plain sum would alias (two errors can
  -- cancel), so fold the vector 32 bits at a time with a per-word rotate: the
  -- rotate makes the signature sensitive to WHICH word changed, and the whole
  -- thing is just XOR trees + fixed wiring (no adders, no carry chains), so it
  -- is cheaper than the is_nz OR-trees already used for the taps.
  function vchk(v : std_logic_vector) return std_logic_vector is
    variable r : std_logic_vector(31 downto 0) := (others => '0');
    variable w : std_logic_vector(31 downto 0);
  begin
    for i in 0 to v'length/32 - 1 loop
      w := v(32*i+31 downto 32*i);
      r := r xor std_logic_vector(rotate_left(unsigned(w), i mod 32));
    end loop;
    return r;
  end function;

  -- Highest set-bit index of a nonnegative signed value (0 for 0).
  function msb_pos64(v : signed) return integer is
    variable p : integer := 0;
  begin
    for i in 0 to v'length-2 loop
      if v(i) = '1' then p := i; end if;
    end loop;
    return p;
  end function;

  -- ---- shared residual-stream bus + position ----------------------------
  signal x_mant_cur  : std_logic_vector(DIM*16-1 downto 0) := (others => '0');
  signal x_exp_cur   : integer := 0;
  signal cur_pos_reg : integer := 0;

  -- ---- embed ------------------------------------------------------------
  signal embed_token  : integer := 0;
  signal embed_x_mant : std_logic_vector(DIM*16-1 downto 0);
  signal embed_x_exp  : integer;
  signal emb_en       : std_logic := '0';
  signal emb_done     : std_logic;

  -- ---- shared rmsnorm ---------------------------------------------------
  signal rms_start  : std_logic := '0';
  signal rms_done   : std_logic;
  signal rms_x_mant : std_logic_vector(DIM*16-1 downto 0) := (others => '0');
  signal rms_x_exp  : integer := 0;
  signal rms_w_mant : std_logic_vector(DIM*16-1 downto 0);
  signal rms_w_exp  : integer;
  signal rms_o_mant : std_logic_vector(DIM*16-1 downto 0);
  signal rms_o_exp  : integer;
  signal rms_mode   : integer := 0;   -- RMS_ATT / RMS_FFN / RMS_FINAL
  signal rms_layer  : integer := 0;

  -- ---- shared matmul_rt -------------------------------------------------
  signal mm_start : std_logic := '0';
  signal mm_done  : std_logic;
  signal mm_sel   : integer := 0;
  signal mm_layer : integer := 0;
  signal mm_xin   : std_logic_vector(MAXCOLS*16-1 downto 0) := (others => '0');
  signal mm_xexp  : integer := 0;
  signal mm_o_mant: std_logic_vector(MAXROWS*16-1 downto 0);
  signal mm_o_exp : integer;

  -- ---- shared rope ------------------------------------------------------
  signal rope_start   : std_logic := '0';
  signal rope_done    : std_logic;
  signal rope_q_mant  : std_logic_vector(DIM*16-1 downto 0)   := (others => '0');
  signal rope_q_exp   : integer := 0;
  signal rope_k_mant  : std_logic_vector(KVDIM*16-1 downto 0) := (others => '0');
  signal rope_k_exp   : integer := 0;
  signal rope_qo_mant : std_logic_vector(DIM*16-1 downto 0);
  signal rope_qo_exp  : integer;
  signal rope_ko_mant : std_logic_vector(KVDIM*16-1 downto 0);
  signal rope_ko_exp  : integer;

  -- ---- shared attention (banked KV) -------------------------------------
  signal att_start     : std_logic := '0';
  signal att_done      : std_logic;
  signal att_rst       : std_logic;
  signal kv_reset      : std_logic := '0';
  signal att_layer     : integer := 0;
  signal att_curpos    : integer := 0;
  signal att_q_mant    : std_logic_vector(DIM*16-1 downto 0)   := (others => '0');
  signal att_q_exp     : integer := 0;
  signal att_k_new_mant: std_logic_vector(KVDIM*16-1 downto 0) := (others => '0');
  signal att_k_new_exp : integer := 0;
  signal att_v_new_mant: std_logic_vector(KVDIM*16-1 downto 0) := (others => '0');
  signal att_v_new_exp : integer := 0;
  signal att_xb_mant   : std_logic_vector(DIM*16-1 downto 0);
  signal att_xb_exp    : integer;
  signal att_dbg_sc    : integer;   -- attention score/sum/num taps (HW debug)
  signal att_dbg_sum   : integer;
  signal att_dbg_num   : integer;
  signal d_att_sc      : integer := 0;
  signal d_att_sum     : integer := 0;
  signal d_att_num     : integer := 0;
  -- per-head / per-lane probes straight out of attention_ml ...
  signal att_p_sums    : std_logic_vector(NHEADS*32-1 downto 0);
  signal att_p_amax    : std_logic_vector(63 downto 0);
  signal att_p_nmax    : std_logic_vector(63 downto 0);
  signal att_p_amaxidx : std_logic_vector(7 downto 0);
  signal att_p_nmaxidx : std_logic_vector(7 downto 0);
  -- ... and their latched (dbg_pos, layer 0) snapshots.
  signal d_att_sums    : std_logic_vector(NHEADS*32-1 downto 0) := (others => '0');
  signal d_att_amax    : std_logic_vector(63 downto 0) := (others => '0');
  signal d_att_nmax    : std_logic_vector(63 downto 0) := (others => '0');
  signal d_att_idx     : std_logic_vector(15 downto 0) := (others => '0');
  -- failing-division probes out of attention_ml ...
  signal att_p_cd_qmag : std_logic_vector(63 downto 0);
  signal att_p_cd_nmag : std_logic_vector(63 downto 0);
  signal att_p_cd_nsd  : std_logic_vector(63 downto 0);
  signal att_p_cd_sum  : std_logic_vector(31 downto 0);
  signal att_p_cd_meta : std_logic_vector(31 downto 0);
  signal att_p_l1_qmag : std_logic_vector(63 downto 0);
  signal att_p_l1_nsd  : std_logic_vector(63 downto 0);
  signal att_p_l1_sum  : std_logic_vector(31 downto 0);
  -- ... and their latched (dbg_pos, layer 0) snapshots.
  signal d_cd_qmag     : std_logic_vector(63 downto 0) := (others => '0');
  signal d_cd_nmag     : std_logic_vector(63 downto 0) := (others => '0');
  signal d_cd_nsd      : std_logic_vector(63 downto 0) := (others => '0');
  signal d_cd_sum      : std_logic_vector(31 downto 0) := (others => '0');
  signal d_cd_meta     : std_logic_vector(31 downto 0) := (others => '0');
  signal d_l1_qmag     : std_logic_vector(63 downto 0) := (others => '0');
  signal d_l1_nsd      : std_logic_vector(63 downto 0) := (others => '0');
  signal d_l1_sum      : std_logic_vector(31 downto 0) := (others => '0');
  -- nmag / running-max-quotient probes out of attention_ml ...
  signal att_p_l1_nmag : std_logic_vector(63 downto 0);
  signal att_p_qx_qmag : std_logic_vector(63 downto 0);
  signal att_p_qx_nmag : std_logic_vector(63 downto 0);
  signal att_p_qx_nsd  : std_logic_vector(63 downto 0);
  signal att_p_qx_sum  : std_logic_vector(31 downto 0);
  signal att_p_qx_meta : std_logic_vector(31 downto 0);
  -- ... and their latched (dbg_pos, layer 0) snapshots.
  signal d_l1_nmag     : std_logic_vector(63 downto 0) := (others => '0');
  signal d_qx_qmag     : std_logic_vector(63 downto 0) := (others => '0');
  signal d_qx_nmag     : std_logic_vector(63 downto 0) := (others => '0');
  signal d_qx_nsd      : std_logic_vector(63 downto 0) := (others => '0');
  signal d_qx_sum      : std_logic_vector(31 downto 0) := (others => '0');
  signal d_qx_meta     : std_logic_vector(31 downto 0) := (others => '0');

  -- ---- shared swiglu ----------------------------------------------------
  signal sw_start   : std_logic := '0';
  signal sw_done    : std_logic;
  signal sw_hb_mant : std_logic_vector(HIDDEN*16-1 downto 0) := (others => '0');
  signal sw_hb_exp  : integer := 0;
  signal sw_hb2_mant: std_logic_vector(HIDDEN*16-1 downto 0) := (others => '0');
  signal sw_hb2_exp : integer := 0;
  -- swiglu->bfp_pack intermediate now lives in vec_mem BRAM (LUT reduction):
  -- swiglu writes one element/cycle, bfp_pack reads via a 1-cycle read-ahead.
  signal sw_o_we    : std_logic;
  signal sw_o_waddr : std_logic_vector(clog2(HIDDEN)-1 downto 0);
  signal sw_o_wdata : std_logic_vector(31 downto 0);
  signal hbp_raddr  : std_logic_vector(clog2(HIDDEN)-1 downto 0);
  signal vm_dout    : std_logic_vector(31 downto 0);

  -- ---- shared lm_head / sampler -----------------------------------------
  signal lm_start  : std_logic := '0';
  signal lm_done   : std_logic;
  signal lm_x_mant : std_logic_vector(DIM*16-1 downto 0) := (others => '0');
  signal lm_x_exp  : integer := 0;
  signal lm_logit_valid : std_logic;                       -- streamed logit strobe
  signal lm_logit_v     : std_logic_vector(31 downto 0);   -- streamed logit value

  signal samp_clr   : std_logic := '0';
  signal samp_token : integer;

  -- ---- shared sequential residual add (o = a + b, BFP) ------------------
  signal res_start  : std_logic := '0';
  signal res_done   : std_logic;
  signal res_a_mant : std_logic_vector(DIM*16-1 downto 0) := (others => '0');
  signal res_a_exp  : integer := 0;
  signal res_b_mant : std_logic_vector(DIM*16-1 downto 0) := (others => '0');
  signal res_b_exp  : integer := 0;
  signal res_o_mant : std_logic_vector(DIM*16-1 downto 0);
  signal res_o_exp  : integer;

  -- ---- shared sequential BFP pack (swiglu Q12 int32 -> int16 BFP) --------
  signal hbp_start  : std_logic := '0';
  signal hbp_done   : std_logic;
  signal hbp_o_mant : std_logic_vector(HIDDEN*16-1 downto 0);
  signal hbp_o_exp  : integer;

  -- ---- datapath holding registers ---------------------------------------
  signal q_reg   : std_logic_vector(DIM*16-1 downto 0)   := (others => '0');
  signal q_exp_r : integer := 0;
  signal k_reg   : std_logic_vector(KVDIM*16-1 downto 0) := (others => '0');
  signal k_exp_r : integer := 0;
  signal v_reg   : std_logic_vector(KVDIM*16-1 downto 0) := (others => '0');
  signal v_exp_r : integer := 0;
  signal wo_reg  : std_logic_vector(DIM*16-1 downto 0)   := (others => '0');
  signal wo_exp_r: integer := 0;
  signal w1_reg  : std_logic_vector(HIDDEN*16-1 downto 0) := (others => '0');
  signal w1_exp_r: integer := 0;
  signal w3_reg  : std_logic_vector(HIDDEN*16-1 downto 0) := (others => '0');
  signal w3_exp_r: integer := 0;
  signal w2_reg  : std_logic_vector(DIM*16-1 downto 0)   := (others => '0');
  signal w2_exp_r: integer := 0;
  signal xm_mant : std_logic_vector(DIM*16-1 downto 0)   := (others => '0');
  signal xm_exp  : integer := 0;

  -- ---- master FSM -------------------------------------------------------
  type state_t is (
    E_IDLE, E_KV, E_TOKSET, E_EMB_S, E_EMB_W,
    L_RMS_ATT_S, L_RMS_ATT_W,
    L_WQ_S, L_WQ_W, L_WK_S, L_WK_W, L_WV_S, L_WV_W,
    L_ROPE_S, L_ROPE_W,
    L_ATT_S, L_ATT_W,
    L_WO_S, L_WO_W, L_RES1_S, L_RES1_W,
    L_RMS_FFN_S, L_RMS_FFN_W,
    L_W1_S, L_W1_W, L_W3_S, L_W3_W,
    L_SW_S, L_SW_W, L_HBPACK_S, L_HBPACK_W,
    L_W2_S, L_W2_W, L_RES2_S, L_RES2_W,
    E_RMS_S, E_RMS_W, E_LM_S, E_LM_W,
    E_EMIT, E_FIN
  );
  signal state     : state_t := E_IDLE;
  signal p_idx     : integer := 0;
  signal cur_layer : integer := 0;
  signal prev_next : integer := 0;

  -- DEBUG taps: OR-reduce of a mantissa vector (nonzero if any bit set).
  function is_nz(v : std_logic_vector) return std_logic is
    variable r : std_logic := '0';
  begin
    for i in v'range loop r := r or v(i); end loop;
    return r;
  end function;
  signal d_emb_nz, d_l0_nz, d_l1_nz, d_l2_nz, d_l3_nz, d_l4_nz, d_fin_nz, d_rms_nz, d_att_nz : std_logic := '0';
  signal d_emb_e, d_l0_e, d_l1_e, d_l2_e, d_l3_e, d_l4_e, d_fin_e, d_rms_e, d_att_e, d_stok : integer := 0;
  signal d_emb_m, d_l0_m, d_l1_m, d_l2_m, d_l3_m, d_l4_m, d_fin_m, d_rms_m, d_att_m : std_logic_vector(15 downto 0) := (others=>'0');
  -- intra-layer-0 stage bisect taps (WO / res1 / ffn-rms / W1 / W3 / bfp_pack / W2)
  signal d_wo_nz, d_r1_nz, d_rf_nz, d_w1_nz, d_w3_nz, d_hb_nz, d_w2_nz : std_logic := '0';
  signal d_wo_e,  d_r1_e,  d_rf_e,  d_w1_e,  d_w3_e,  d_hb_e,  d_w2_e  : integer := 0;
  signal d_wo_m,  d_r1_m,  d_rf_m,  d_w1_m,  d_w3_m,  d_hb_m,  d_w2_m  : std_logic_vector(15 downto 0) := (others=>'0');
  -- rmsnorm internal bisect: live taps from u_rmsnorm + their per-invocation
  -- capture registers (FFN = the failing call, ATT = the known-good control).
  signal rn_xchk, rn_wchk, rn_inv : std_logic_vector(31 downto 0);
  signal rn_ssq, rn_msq, rn_mrw   : std_logic_vector(63 downto 0);
  signal rn_sh                    : integer;
  signal d_rf_xchk, d_rf_wchk, d_rf_inv : std_logic_vector(31 downto 0) := (others=>'0');
  signal d_rf_ssq, d_rf_msq, d_rf_mrw   : std_logic_vector(63 downto 0) := (others=>'0');
  signal d_rf_sh                        : integer := 0;
  signal d_ra_xchk, d_ra_inv            : std_logic_vector(31 downto 0) := (others=>'0');
  signal d_ra_ssq                       : std_logic_vector(63 downto 0) := (others=>'0');
  -- whole-vector dataflow signatures (unit output vs the staging reg it feeds)
  signal d_vc_emb, d_vc_xcur, d_vc_wo, d_vc_woreg : std_logic_vector(31 downto 0) := (others=>'0');
  signal d_vc_res1, d_vc_xm, d_vc_rmsx, d_vc_rmso : std_logic_vector(31 downto 0) := (others=>'0');
  signal d_vc_w1, d_vc_w3                         : std_logic_vector(31 downto 0) := (others=>'0');

  signal d_rxchk, d_rwchk, d_rxe, d_rwe : integer := 0;
  signal d_rw0 : std_logic_vector(15 downto 0) := (others=>'0');

  -- sum of the N int16 words of a mant vector (checksum to detect corruption).
  function chksum(v : std_logic_vector) return integer is
    variable s : integer := 0;
  begin
    for i in 0 to DIM-1 loop
      s := s + to_integer(signed(v((i+1)*16-1 downto i*16)));
    end loop;
    return s;
  end function;

begin

  assert NGEN <= MAXPOS
    report "engine_shared: NGEN must be <= MAXPOS (KV cache has only MAXPOS slots)"
    severity failure;

  -- ---------------------------------------------------------------------
  -- Sub-unit instances (ONE of each).
  -- ---------------------------------------------------------------------
  u_embed: entity work.embed
    generic map(DIM => DIM, VOCAB => VOCAB, ROM_DIR => ROM_DIR)
    port map(clk => clk, en => emb_en, token => embed_token, done => emb_done,
             x_mant => embed_x_mant, x_exp => embed_x_exp);
  emb_en <= '1' when (state = E_EMB_S or state = E_EMB_W) else '0';

  u_rmsnorm: entity work.rmsnorm
    generic map(N => DIM, Q => 12, DEBUG => DEBUG_TAPS)
    port map(clk => clk, rst => rst, start => rms_start,
             x_mant => rms_x_mant, x_exp => rms_x_exp,
             w_mant => rms_w_mant, w_exp => rms_w_exp,
             done => rms_done, o_mant => rms_o_mant, o_exp => rms_o_exp,
             dbg_xchk => rn_xchk, dbg_wchk => rn_wchk, dbg_ssq => rn_ssq,
             dbg_msq => rn_msq, dbg_inv => rn_inv, dbg_maxraw => rn_mrw,
             dbg_shift => rn_sh);

  u_matmul: entity work.matmul_rt
    generic map(MAXROWS => MAXROWS, MAXCOLS => MAXCOLS, ROM_DIR => ROM_DIR)
    port map(clk => clk, rst => rst, start => mm_start,
             mat_sel => mm_sel, layer => mm_layer,
             x_mant => mm_xin, x_exp => mm_xexp,
             done => mm_done, o_mant => mm_o_mant, o_exp => mm_o_exp);

  u_rope: entity work.rope
    generic map(DIM => DIM, HEAD => HEAD_SIZE, KVDIM => KVDIM)
    port map(clk => clk, rst => rst, start => rope_start, pos => cur_pos_reg,
             q_mant => rope_q_mant, q_exp => rope_q_exp,
             k_mant => rope_k_mant, k_exp => rope_k_exp,
             done => rope_done,
             qo_mant => rope_qo_mant, qo_exp => rope_qo_exp,
             ko_mant => rope_ko_mant, ko_exp => rope_ko_exp);

  att_rst <= rst or kv_reset;
  u_att: entity work.attention_ml
    generic map(DIM => DIM, HEAD_SIZE => HEAD_SIZE, NHEADS => NHEADS,
                NKVH => NKVH, KVDIM => KVDIM, MAXPOS => MAXPOS,
                NLAYERS => NLAYERS, Q => 12, PROBES => DEBUG_TAPS)
    port map(clk => clk, rst => att_rst, start => att_start,
             layer => att_layer, cur_pos => att_curpos,
             q_mant => att_q_mant, q_exp => att_q_exp,
             k_new_mant => att_k_new_mant, k_new_exp => att_k_new_exp,
             v_new_mant => att_v_new_mant, v_new_exp => att_v_new_exp,
             done => att_done, xb_mant => att_xb_mant, xb_exp => att_xb_exp,
             dbg_sc => att_dbg_sc, dbg_sum => att_dbg_sum, dbg_num => att_dbg_num,
             p_sums => att_p_sums, p_amax => att_p_amax, p_amax_idx => att_p_amaxidx,
             p_nmax => att_p_nmax, p_nmax_idx => att_p_nmaxidx,
             p_cd_qmag => att_p_cd_qmag, p_cd_nmag => att_p_cd_nmag,
             p_cd_nsd  => att_p_cd_nsd,  p_cd_sum  => att_p_cd_sum,
             p_cd_meta => att_p_cd_meta,
             p_l1_qmag => att_p_l1_qmag, p_l1_nsd => att_p_l1_nsd,
             p_l1_sum  => att_p_l1_sum,
             p_l1_nmag => att_p_l1_nmag,
             p_qx_qmag => att_p_qx_qmag, p_qx_nmag => att_p_qx_nmag,
             p_qx_nsd  => att_p_qx_nsd,  p_qx_sum  => att_p_qx_sum,
             p_qx_meta => att_p_qx_meta);

  u_sw: entity work.swiglu
    generic map(N => HIDDEN, Q => 12)
    port map(clk => clk, rst => rst, start => sw_start,
             hb_mant => sw_hb_mant, hb_exp => sw_hb_exp,
             hb2_mant => sw_hb2_mant, hb2_exp => sw_hb2_exp,
             done => sw_done,
             out_q => open,                 -- wide bus unused here -> demux pruned
             o_we => sw_o_we, o_waddr => sw_o_waddr, o_wdata => sw_o_wdata);

  -- FFN intermediate BRAM: swiglu writes the N Q12 int32 results one/cycle;
  -- bfp_pack reads them back (twice: max pass + pack pass) via read-ahead.
  u_swmem: entity work.vec_mem
    generic map(WORDS => HIDDEN, W => 32)
    port map(clk => clk, we => sw_o_we,
             waddr => sw_o_waddr, raddr => hbp_raddr,
             din => sw_o_wdata, dout => vm_dout);

  u_lm_head: entity work.lm_head
    generic map(DIM => DIM, VOCAB => VOCAB, ROM_DIR => ROM_DIR)
    port map(clk => clk, rst => rst, start => lm_start,
             x_mant => lm_x_mant, x_exp => lm_x_exp,
             done => lm_done,
             logits => open,     -- parallel bus unused here -> pruned
             logit_valid => lm_logit_valid, logit_v => lm_logit_v);

  -- Streaming argmax: cleared at lm_head start, folds each streamed logit.
  u_sampler: entity work.sampler_stream
    generic map(VOCAB => VOCAB)
    port map(clk => clk, rst => rst, clr => samp_clr,
             in_valid => lm_logit_valid, in_v => lm_logit_v,
             token => samp_token);

  -- Sequential top-level residual add + BFP pack (extracted from the former
  -- inline combinational blocks; one shared datapath each, handshake-driven).
  u_res: entity work.residual
    generic map(N => DIM)
    port map(clk => clk, rst => rst, start => res_start,
             a_mant => res_a_mant, a_exp => res_a_exp,
             b_mant => res_b_mant, b_exp => res_b_exp,
             done => res_done, o_mant => res_o_mant, o_exp => res_o_exp);

  u_hbpack: entity work.bfp_pack
    generic map(N => HIDDEN, Q => 12)
    port map(clk => clk, rst => rst, start => hbp_start,
             o_raddr => hbp_raddr, i_rdata => vm_dout, done => hbp_done,
             o_mant => hbp_o_mant, o_exp => hbp_o_exp);

  -- FFN staging-register elimination (Task 1): swiglu reads its operands
  -- combinationally across its sweep and w1_reg/w3_reg are stable for that whole
  -- window, so feed them directly instead of a wide reg-to-reg staging copy
  -- (removes the w1_reg->sw_hb_mant / w3_reg->sw_hb2_mant on-silicon hold hazard).
  sw_hb_mant  <= w1_reg;
  sw_hb_exp   <= w1_exp_r;
  sw_hb2_mant <= w3_reg;
  sw_hb2_exp  <= w3_exp_r;

  -- ---------------------------------------------------------------------
  -- Combinational RMSNorm weight mux (small 64-wide constants).
  -- ---------------------------------------------------------------------
  rms_w_mux: process(all)
  begin
    case rms_mode is
      when RMS_ATT =>
        rms_w_mant <= ATT_W_MANT_L(rms_layer);
        rms_w_exp  <= ATT_RMS_W_EXP(rms_layer);
      when RMS_FFN =>
        rms_w_mant <= FFN_W_MANT_L(rms_layer);
        rms_w_exp  <= FFN_RMS_W_EXP(rms_layer);
      when others =>
        rms_w_mant <= FINAL_W_MANT;
        rms_w_exp  <= FINAL_RMS_W_EXP;
    end case;
  end process;

  -- ---------------------------------------------------------------------
  -- Master autoregressive FSM.
  -- ---------------------------------------------------------------------
  process(clk)
    -- integer residual add: out = a + b (both BFP), int64 exp-aligned.
    procedure residual_add(
      a_mant : in  std_logic_vector; a_exp : in integer;
      b_mant : in  std_logic_vector; b_exp : in integer;
      o_mant : out std_logic_vector; o_exp : out integer) is
      variable E    : integer;
      variable av, bv : integer;
      variable sums : s64arr(0 to DIM-1);
      variable mx   : signed(63 downto 0);
      variable ab   : signed(63 downto 0);
      variable p    : integer;
      variable sh   : integer;
      variable r32  : signed(31 downto 0);
      variable r64  : signed(63 downto 0);
      variable sat  : integer;
    begin
      if a_exp > b_exp then E := a_exp; else E := b_exp; end if;
      mx := (others => '0');
      for j in 0 to DIM-1 loop
        av := to_integer(signed(a_mant((j+1)*16-1 downto j*16)));
        bv := to_integer(signed(b_mant((j+1)*16-1 downto j*16)));
        sums(j) := shift_left(to_signed(av, 64), E - a_exp)
                 + shift_left(to_signed(bv, 64), E - b_exp);
        if sums(j) < 0 then ab := -sums(j); else ab := sums(j); end if;
        if ab > mx then mx := ab; end if;
      end loop;
      p  := msb_pos64(mx);
      sh := p - 14;               -- no clamp (allow left-shift for precision)
      o_exp := E - sh;
      for j in 0 to DIM-1 loop
        if sh >= 0 then
          r32 := scale_mul(sums(j), to_signed(1, 32), sh);
          if    r32 >  32767 then sat :=  32767;
          elsif r32 < -32768 then sat := -32768;
          else                    sat := to_integer(r32);
          end if;
        else
          r64 := shift_left(sums(j), -sh);
          if    r64 >  32767 then sat :=  32767;
          elsif r64 < -32768 then sat := -32768;
          else                    sat := to_integer(r64);
          end if;
        end if;
        o_mant((j+1)*16-1 downto j*16) := std_logic_vector(to_signed(sat, 16));
      end loop;
    end procedure;

    variable rm    : std_logic_vector(DIM*16-1 downto 0);
    variable re    : integer;
    variable tok      : integer;
    variable next_tok : integer;
    -- hb-pack temporaries (Q12 int -> BFP int16)
    variable hbq     : integer;
    variable max_abs : integer;
    variable av      : integer;
    variable p_msb   : integer;
    variable shift_o : integer;
    variable r32     : signed(31 downto 0);
    variable sat     : integer;
  begin
    if rising_edge(clk) then
      -- one-cycle strobes default low each edge
      kv_reset    <= '0';
      rms_start   <= '0';
      mm_start    <= '0';
      rope_start  <= '0';
      att_start   <= '0';
      sw_start    <= '0';
      lm_start    <= '0';
      samp_clr    <= '0';
      res_start   <= '0';
      hbp_start   <= '0';
      token_valid <= '0';
      run_done    <= '0';   -- one-cycle pulse (E_FIN); was held high -> broke re-run

      if rst = '1' then
        state     <= E_IDLE;
        run_done  <= '0';
        p_idx     <= 0;
        prev_next <= 0;
        cur_layer <= 0;
        token_out <= 0;
        pos_out   <= 0;
      else
        case state is

          when E_IDLE =>
            if start = '1' then
              p_idx    <= 0;
              kv_reset <= '1';    -- clear every KV bank
              state    <= E_KV;
            end if;

          when E_KV =>
            state <= E_TOKSET;

          -- ---- pick input token, embed it ---------------------------
          when E_TOKSET =>
            cur_pos_reg <= p_idx;
            if p_idx = 0 then tok := ptok(prompt_mant, 0);
            else              tok := prev_next; end if;
            embed_token <= tok;
            state <= E_EMB_S;
          when E_EMB_S =>
            state <= E_EMB_W;
          when E_EMB_W =>
            if emb_done = '1' then
              x_mant_cur <= embed_x_mant;
              x_exp_cur  <= embed_x_exp;
              cur_layer  <= 0;
              state <= L_RMS_ATT_S;
              if DEBUG_TAPS and p_idx = dbg_pos then   -- DEBUG: x after embed
                d_emb_nz <= is_nz(embed_x_mant); d_emb_e <= embed_x_exp;
                d_emb_m  <= embed_x_mant(15 downto 0);
                d_vc_emb <= vchk(embed_x_mant);   -- embed UNIT output
              end if;
            end if;

          -- =========================================================
          -- Per-layer body (mirrors layer_ar.vhd), shared units.
          -- =========================================================
          -- ---- 1. attention RMSNorm --------------------------------
          when L_RMS_ATT_S =>
            rms_mode   <= RMS_ATT;
            rms_layer  <= cur_layer;
            rms_x_mant <= x_mant_cur;
            rms_x_exp  <= x_exp_cur;
            rms_start  <= '1';
            -- x_mant_cur STAGING reg vs the embed unit output captured above:
            -- a difference here is the wide reg-to-reg copy corrupting bits.
            if DEBUG_TAPS and p_idx = dbg_pos and cur_layer = 0 then
              d_vc_xcur <= vchk(x_mant_cur);
            end if;
            state <= L_RMS_ATT_W;
          when L_RMS_ATT_W =>
            if rms_done = '1' then
              state <= L_WQ_S;
              if DEBUG_TAPS and p_idx = dbg_pos and cur_layer = 0 then   -- DEBUG: attention-rmsnorm out + INPUTS (L0)
                d_rms_nz <= is_nz(rms_o_mant); d_rms_e <= rms_o_exp;
                d_rms_m  <= rms_o_mant(15 downto 0);
                -- single-element taps (the full-vector chksum adder-trees cost ~3K
                -- LUT and are no longer needed -- the non-determinism is fixed).
                d_rxchk  <= to_integer(signed(rms_x_mant(31 downto 16)));
                d_rwchk  <= to_integer(signed(rms_o_mant(31 downto 16)));
                -- rmsnorm INTERNALS for the ATT invocation (known-good control)
                d_ra_xchk <= rn_xchk; d_ra_ssq <= rn_ssq; d_ra_inv <= rn_inv;
                d_rxe    <= rms_x_exp; d_rwe <= rms_w_exp; d_rw0 <= rms_w_mant(15 downto 0);
              end if;
            end if;

          -- ---- 2. WQ / WK / WV matmuls (input = att-rms output) -----
          when L_WQ_S =>
            mm_sel <= WQ_SEL; mm_layer <= cur_layer;
            mm_xin <= pad_cols(rms_o_mant); mm_xexp <= rms_o_exp;
            mm_start <= '1'; state <= L_WQ_W;
          when L_WQ_W =>
            if mm_done = '1' then
              q_reg   <= mm_o_mant(DIM*16-1 downto 0);
              q_exp_r <= mm_o_exp;
              state <= L_WK_S;
            end if;
          when L_WK_S =>
            mm_sel <= WK_SEL; mm_layer <= cur_layer;
            mm_xin <= pad_cols(rms_o_mant); mm_xexp <= rms_o_exp;
            mm_start <= '1'; state <= L_WK_W;
          when L_WK_W =>
            if mm_done = '1' then
              k_reg   <= mm_o_mant(KVDIM*16-1 downto 0);
              k_exp_r <= mm_o_exp;
              state <= L_WV_S;
            end if;
          when L_WV_S =>
            mm_sel <= WV_SEL; mm_layer <= cur_layer;
            mm_xin <= pad_cols(rms_o_mant); mm_xexp <= rms_o_exp;
            mm_start <= '1'; state <= L_WV_W;
          when L_WV_W =>
            if mm_done = '1' then
              v_reg   <= mm_o_mant(KVDIM*16-1 downto 0);
              v_exp_r <= mm_o_exp;
              state <= L_ROPE_S;
            end if;

          -- ---- 3. RoPE on Q and K ----------------------------------
          when L_ROPE_S =>
            rope_q_mant <= q_reg; rope_q_exp <= q_exp_r;
            rope_k_mant <= k_reg; rope_k_exp <= k_exp_r;
            rope_start  <= '1'; state <= L_ROPE_W;
          when L_ROPE_W =>
            if rope_done = '1' then state <= L_ATT_S; end if;

          -- ---- 4. attention: drive ONCE for this token (bank=L) ----
          when L_ATT_S =>
            att_layer      <= cur_layer;
            att_curpos     <= cur_pos_reg;
            att_q_mant     <= rope_qo_mant;
            att_q_exp      <= rope_qo_exp;
            att_k_new_mant <= rope_ko_mant;   -- post-rope K[pos]
            att_k_new_exp  <= rope_ko_exp;
            att_v_new_mant <= v_reg;          -- pre-rope V[pos]
            att_v_new_exp  <= v_exp_r;
            att_start <= '1'; state <= L_ATT_W;
          when L_ATT_W =>
            if att_done = '1' then
              state <= L_WO_S;
              if DEBUG_TAPS and p_idx = dbg_pos and cur_layer = 0 then   -- DEBUG: attention output xb (L0)
                d_att_nz <= is_nz(att_xb_mant); d_att_e <= att_xb_exp;
                d_att_m  <= att_xb_mant(15 downto 0);
                -- d_att_sc = FULL attention-output checksum (all 64 elems) -> is the
                -- WHOLE attention output right, or just element 0 that we tap?
                -- DETERMINISM PROBE 2: 0xF0 = attention's dbg_sc = the CACHED K read
                -- (from the KV BRAM, inside attention).  If it varies run-to-run while
                -- the K INPUT was stable, the KV cache read is the non-det source.
                d_att_sc  <= att_dbg_sc;
                d_att_sum <= att_dbg_sum;
                d_att_num <= att_dbg_num;
                -- PER-HEAD/PER-LANE probes: all 8 softmax denominators, the final
                -- sticky |xb_acc| max + its lane, and max|num_s| + its lane.
                d_att_sums <= att_p_sums;
                d_att_amax <= att_p_amax;
                d_att_nmax <= att_p_nmax;
                d_att_idx  <= att_p_nmaxidx & att_p_amaxidx;
                -- FAILING-DIVISION capture: pre-clamp quotient + operands as
                -- consumed, for the first clamping divide and for hd0/lane1.
                d_cd_qmag <= att_p_cd_qmag;
                d_cd_nmag <= att_p_cd_nmag;
                d_cd_nsd  <= att_p_cd_nsd;
                d_cd_sum  <= att_p_cd_sum;
                d_cd_meta <= att_p_cd_meta;
                d_l1_qmag <= att_p_l1_qmag;
                d_l1_nsd  <= att_p_l1_nsd;
                d_l1_sum  <= att_p_l1_sum;
                -- nmag AS CONSUMED at hd0/t1 (unconditional -- the operand the
                -- clamp-gated capture can no longer show), plus the running-max
                -- pre-clamp quotient of the call and its full operand set.
                d_l1_nmag <= att_p_l1_nmag;
                d_qx_qmag <= att_p_qx_qmag;
                d_qx_nmag <= att_p_qx_nmag;
                d_qx_nsd  <= att_p_qx_nsd;
                d_qx_sum  <= att_p_qx_sum;
                d_qx_meta <= att_p_qx_meta;
              end if;
            end if;

          -- ---- 5. WO matmul + residual add 1 -----------------------
          when L_WO_S =>
            mm_sel <= WO_SEL; mm_layer <= cur_layer;
            mm_xin <= pad_cols(att_xb_mant); mm_xexp <= att_xb_exp;
            mm_start <= '1'; state <= L_WO_W;
          when L_WO_W =>
            if mm_done = '1' then
              wo_reg   <= mm_o_mant(DIM*16-1 downto 0);
              wo_exp_r <= mm_o_exp;
              state <= L_RES1_S;
              -- STAGE TAP 1: WO matmul output (the value wo_reg is taking now).
              if DEBUG_TAPS and p_idx = dbg_pos and cur_layer = 0 then
                d_wo_nz <= is_nz(mm_o_mant(DIM*16-1 downto 0)); d_wo_e <= mm_o_exp;
                d_wo_m  <= mm_o_mant(15 downto 0);
                d_vc_wo <= vchk(mm_o_mant(DIM*16-1 downto 0));  -- matmul UNIT output
              end if;
            end if;
          when L_RES1_S =>
            res_a_mant <= x_mant_cur; res_a_exp <= x_exp_cur;
            res_b_mant <= wo_reg;     res_b_exp <= wo_exp_r;
            res_start  <= '1';
            state <= L_RES1_W;
            if DEBUG_TAPS and p_idx = dbg_pos and cur_layer = 0 then
              d_vc_woreg <= vchk(wo_reg);   -- wo_reg STAGING reg
            end if;
          when L_RES1_W =>
            if res_done = '1' then
              xm_mant <= res_o_mant;
              xm_exp  <= res_o_exp;
              state <= L_RMS_FFN_S;
              -- STAGE TAP 2: residual-1 output (x + WO), the value xm_mant takes now.
              if DEBUG_TAPS and p_idx = dbg_pos and cur_layer = 0 then
                d_r1_nz <= is_nz(res_o_mant); d_r1_e <= res_o_exp;
                d_r1_m  <= res_o_mant(15 downto 0);
                d_vc_res1 <= vchk(res_o_mant);   -- residual UNIT output
              end if;
            end if;

          -- ---- 6. FFN RMSNorm --------------------------------------
          when L_RMS_FFN_S =>
            rms_mode   <= RMS_FFN;
            rms_layer  <= cur_layer;
            rms_x_mant <= xm_mant;
            rms_x_exp  <= xm_exp;
            rms_start  <= '1';
            state <= L_RMS_FFN_W;
            if DEBUG_TAPS and p_idx = dbg_pos and cur_layer = 0 then
              d_vc_xm <= vchk(xm_mant);   -- xm_mant STAGING reg
            end if;
          when L_RMS_FFN_W =>
            if rms_done = '1' then
              state <= L_W1_S;
              -- STAGE TAP 3: FFN rmsnorm output (the W1/W3 matmul input).
              if DEBUG_TAPS and p_idx = dbg_pos and cur_layer = 0 then
                d_rf_nz <= is_nz(rms_o_mant); d_rf_e <= rms_o_exp;
                d_rf_m  <= rms_o_mant(15 downto 0);
                -- rmsnorm INTERNALS for this (failing) FFN invocation
                d_rf_xchk <= rn_xchk; d_rf_wchk <= rn_wchk;
                d_rf_ssq  <= rn_ssq;  d_rf_msq  <= rn_msq;
                d_rf_inv  <= rn_inv;  d_rf_mrw  <= rn_mrw; d_rf_sh <= rn_sh;
                -- the vector rmsnorm ACTUALLY read (its port), and its output
                d_vc_rmsx <= vchk(rms_x_mant);
                d_vc_rmso <= vchk(rms_o_mant);
              end if;
            end if;

          -- ---- 7. W1 / W3 matmuls (input = ffn-rms output) ---------
          when L_W1_S =>
            mm_sel <= W1_SEL; mm_layer <= cur_layer;
            mm_xin <= pad_cols(rms_o_mant); mm_xexp <= rms_o_exp;
            mm_start <= '1'; state <= L_W1_W;
          when L_W1_W =>
            if mm_done = '1' then
              w1_reg   <= mm_o_mant(HIDDEN*16-1 downto 0);
              w1_exp_r <= mm_o_exp;
              state <= L_W3_S;
              -- STAGE TAP 4: W1 matmul output (HIDDEN-wide).
              if DEBUG_TAPS and p_idx = dbg_pos and cur_layer = 0 then
                d_w1_nz <= is_nz(mm_o_mant(HIDDEN*16-1 downto 0)); d_w1_e <= mm_o_exp;
                d_w1_m  <= mm_o_mant(15 downto 0);
                d_vc_w1 <= vchk(mm_o_mant(HIDDEN*16-1 downto 0));
              end if;
            end if;
          when L_W3_S =>
            mm_sel <= W3_SEL; mm_layer <= cur_layer;
            mm_xin <= pad_cols(rms_o_mant); mm_xexp <= rms_o_exp;
            mm_start <= '1'; state <= L_W3_W;
          when L_W3_W =>
            if mm_done = '1' then
              w3_reg   <= mm_o_mant(HIDDEN*16-1 downto 0);
              w3_exp_r <= mm_o_exp;
              state <= L_SW_S;
              -- STAGE TAP 5: W3 matmul output (HIDDEN-wide).
              if DEBUG_TAPS and p_idx = dbg_pos and cur_layer = 0 then
                d_w3_nz <= is_nz(mm_o_mant(HIDDEN*16-1 downto 0)); d_w3_e <= mm_o_exp;
                d_w3_m  <= mm_o_mant(15 downto 0);
                d_vc_w3 <= vchk(mm_o_mant(HIDDEN*16-1 downto 0));
              end if;
            end if;

          -- ---- 8. SwiGLU + BFP-pack --------------------------------
          when L_SW_S =>
            -- sw_hb*/sw_hb2* are now concurrent wires to w1_reg/w3_reg (stable
            -- through the swiglu sweep); no reg-to-reg staging copy -> no hold hazard.
            sw_start <= '1'; state <= L_SW_W;
          when L_SW_W =>
            if sw_done = '1' then state <= L_HBPACK_S; end if;
          -- Q12 int (sw_out_q) -> BFP int16 mantissas (feeds W2), sequential.
          when L_HBPACK_S =>
            hbp_start <= '1';
            state <= L_HBPACK_W;
          when L_HBPACK_W =>
            if hbp_done = '1' then
              mm_xin  <= pad_cols(hbp_o_mant);
              mm_xexp <= hbp_o_exp;
              state <= L_W2_S;
              -- STAGE TAP 6: bfp_pack output = swiglu result repacked to int16 BFP
              -- (the W2 matmul input).  Brackets swiglu + the pack shift together.
              if DEBUG_TAPS and p_idx = dbg_pos and cur_layer = 0 then
                d_hb_nz <= is_nz(hbp_o_mant); d_hb_e <= hbp_o_exp;
                d_hb_m  <= hbp_o_mant(15 downto 0);
              end if;
            end if;

          -- ---- 9. W2 matmul + residual add 2 -> output -------------
          when L_W2_S =>
            -- mm_xin / mm_xexp already hold the packed hb from L_HBPACK.
            mm_sel <= W2_SEL; mm_layer <= cur_layer;
            mm_start <= '1'; state <= L_W2_W;
          when L_W2_W =>
            if mm_done = '1' then
              w2_reg   <= mm_o_mant(DIM*16-1 downto 0);
              w2_exp_r <= mm_o_exp;
              state <= L_RES2_S;
              -- STAGE TAP 7: W2 matmul output (the residual-2 addend).
              if DEBUG_TAPS and p_idx = dbg_pos and cur_layer = 0 then
                d_w2_nz <= is_nz(mm_o_mant(DIM*16-1 downto 0)); d_w2_e <= mm_o_exp;
                d_w2_m  <= mm_o_mant(15 downto 0);
              end if;
            end if;
          when L_RES2_S =>
            res_a_mant <= xm_mant; res_a_exp <= xm_exp;
            res_b_mant <= w2_reg;  res_b_exp <= w2_exp_r;
            res_start  <= '1';
            state <= L_RES2_W;
          when L_RES2_W =>
            if res_done = '1' then
              x_mant_cur <= res_o_mant;
              x_exp_cur  <= res_o_exp;
              if DEBUG_TAPS and p_idx = dbg_pos then   -- DEBUG: x after this layer's residual2
                if cur_layer = 0 then
                  d_l0_nz <= is_nz(res_o_mant); d_l0_e <= res_o_exp;
                  d_l0_m  <= res_o_mant(15 downto 0);
                end if;
                if cur_layer = 1 then
                  d_l1_nz <= is_nz(res_o_mant); d_l1_e <= res_o_exp;
                  d_l1_m  <= res_o_mant(15 downto 0);
                end if;
                if cur_layer = 2 then
                  d_l2_nz <= is_nz(res_o_mant); d_l2_e <= res_o_exp;
                  d_l2_m  <= res_o_mant(15 downto 0);
                end if;
                if cur_layer = 3 then
                  d_l3_nz <= is_nz(res_o_mant); d_l3_e <= res_o_exp;
                  d_l3_m  <= res_o_mant(15 downto 0);
                end if;
                if cur_layer = NLAYERS-1 then
                  d_l4_nz <= is_nz(res_o_mant); d_l4_e <= res_o_exp;
                  d_l4_m  <= res_o_mant(15 downto 0);
                end if;
              end if;
              if cur_layer = NLAYERS-1 then
                state <= E_RMS_S;
              else
                cur_layer <= cur_layer + 1;
                state <= L_RMS_ATT_S;
              end if;
            end if;

          -- =========================================================
          -- final rmsnorm -> lm_head -> sampler
          -- =========================================================
          when E_RMS_S =>
            rms_mode   <= RMS_FINAL;
            rms_x_mant <= x_mant_cur;
            rms_x_exp  <= x_exp_cur;
            rms_start  <= '1';
            state <= E_RMS_W;
          when E_RMS_W =>
            if rms_done = '1' then
              state <= E_LM_S;
              if DEBUG_TAPS and p_idx = dbg_pos then   -- DEBUG: x after final rmsnorm (lm_head input)
                d_fin_nz <= is_nz(rms_o_mant); d_fin_e <= rms_o_exp;
                d_fin_m  <= rms_o_mant(15 downto 0);
              end if;
            end if;
          when E_LM_S =>
            lm_x_mant <= rms_o_mant;
            lm_x_exp  <= rms_o_exp;
            lm_start  <= '1';
            samp_clr  <= '1';    -- clear the streaming sampler before logits arrive
            state <= E_LM_W;
          -- lm_head streams logits into the sampler during E_LM_W; when lm_done
          -- pulses the sampler's running argmax (samp_token) is already final.
          when E_LM_W =>
            if lm_done = '1' then state <= E_EMIT; end if;

          -- ---- teacher forcing vs argmax, emit, advance ------------
          when E_EMIT =>
            -- teacher-force while inside the prompt, then greedy argmax
            if p_idx < prompt_len - 1 then
              next_tok := ptok(prompt_mant, p_idx + 1);
            else
              next_tok := samp_token;
            end if;
            token_out   <= next_tok;
            pos_out     <= p_idx;
            token_valid <= '1';
            prev_next   <= next_tok;
            if DEBUG_TAPS and p_idx = dbg_pos then d_stok <= samp_token; end if;  -- DEBUG: this pos's argmax
            if p_idx = NGEN - 1 then
              state <= E_FIN;
            else
              p_idx <= p_idx + 1;
              state <= E_TOKSET;
            end if;

          when E_FIN =>
            run_done <= '1';     -- one-cycle pulse; then wait idle for a fresh START
            state    <= E_IDLE;  -- clean re-run: next START re-triggers from E_IDLE

        end case;
      end if;
    end if;
  end process;

  -- DEBUG tap outputs (driven from the latched summaries).
  dbg_emb_nz <= d_emb_nz; dbg_emb_e <= d_emb_e; dbg_emb_m <= d_emb_m;
  dbg_l0_nz  <= d_l0_nz;  dbg_l0_e  <= d_l0_e;  dbg_l0_m  <= d_l0_m;
  dbg_l1_nz  <= d_l1_nz;  dbg_l1_e  <= d_l1_e;  dbg_l1_m  <= d_l1_m;
  dbg_l2_nz  <= d_l2_nz;  dbg_l2_e  <= d_l2_e;  dbg_l2_m  <= d_l2_m;
  dbg_l3_nz  <= d_l3_nz;  dbg_l3_e  <= d_l3_e;  dbg_l3_m  <= d_l3_m;
  dbg_l4_nz  <= d_l4_nz;  dbg_l4_e  <= d_l4_e;  dbg_l4_m  <= d_l4_m;
  dbg_fin_nz <= d_fin_nz; dbg_fin_e <= d_fin_e; dbg_fin_m <= d_fin_m;
  dbg_rms_nz <= d_rms_nz; dbg_rms_e <= d_rms_e; dbg_rms_m <= d_rms_m;
  dbg_att_nz <= d_att_nz; dbg_att_e <= d_att_e; dbg_att_m <= d_att_m;
  -- intra-layer-0 stage bisect taps, in dataflow order
  dbg_wo_nz  <= d_wo_nz;  dbg_wo_e  <= d_wo_e;  dbg_wo_m  <= d_wo_m;
  dbg_r1_nz  <= d_r1_nz;  dbg_r1_e  <= d_r1_e;  dbg_r1_m  <= d_r1_m;
  dbg_rf_nz  <= d_rf_nz;  dbg_rf_e  <= d_rf_e;  dbg_rf_m  <= d_rf_m;
  dbg_w1_nz  <= d_w1_nz;  dbg_w1_e  <= d_w1_e;  dbg_w1_m  <= d_w1_m;
  dbg_w3_nz  <= d_w3_nz;  dbg_w3_e  <= d_w3_e;  dbg_w3_m  <= d_w3_m;
  dbg_hb_nz  <= d_hb_nz;  dbg_hb_e  <= d_hb_e;  dbg_hb_m  <= d_hb_m;
  dbg_w2_nz  <= d_w2_nz;  dbg_w2_e  <= d_w2_e;  dbg_w2_m  <= d_w2_m;
  dbg_rxchk <= d_rxchk; dbg_rwchk <= d_rwchk; dbg_rxe <= d_rxe; dbg_rwe <= d_rwe; dbg_rw0 <= d_rw0;
  dbg_samptok <= d_stok;
  dbg_att_sc <= d_att_sc; dbg_att_sum <= d_att_sum; dbg_att_num <= d_att_num;
  dbg_att_sums   <= d_att_sums;
  dbg_att_amax_l <= d_att_amax(31 downto 0);
  dbg_att_amax_h <= d_att_amax(63 downto 32);
  dbg_att_nmax_l <= d_att_nmax(31 downto 0);
  dbg_att_nmax_h <= d_att_nmax(63 downto 32);
  dbg_att_idx    <= d_att_idx;
  dbg_cd_qmag_l  <= d_cd_qmag(31 downto 0);
  dbg_cd_qmag_h  <= d_cd_qmag(63 downto 32);
  dbg_cd_nmag_l  <= d_cd_nmag(31 downto 0);
  dbg_cd_nmag_h  <= d_cd_nmag(63 downto 32);
  dbg_cd_nsd_l   <= d_cd_nsd(31 downto 0);
  dbg_cd_nsd_h   <= d_cd_nsd(63 downto 32);
  dbg_cd_sum     <= d_cd_sum;
  dbg_cd_meta    <= d_cd_meta;
  dbg_l1_qmag_l  <= d_l1_qmag(31 downto 0);
  dbg_l1_qmag_h  <= d_l1_qmag(63 downto 32);
  dbg_l1_nsd_l   <= d_l1_nsd(31 downto 0);
  dbg_l1_nsd_h   <= d_l1_nsd(63 downto 32);
  dbg_l1_sum     <= d_l1_sum;
  dbg_l1_nmag_l  <= d_l1_nmag(31 downto 0);
  dbg_l1_nmag_h  <= d_l1_nmag(63 downto 32);
  dbg_rf_xchk    <= d_rf_xchk;
  dbg_rf_wchk    <= d_rf_wchk;
  dbg_rf_ssq_l   <= d_rf_ssq(31 downto 0);
  dbg_rf_ssq_h   <= d_rf_ssq(63 downto 32);
  dbg_rf_msq_l   <= d_rf_msq(31 downto 0);
  dbg_rf_msq_h   <= d_rf_msq(63 downto 32);
  dbg_rf_inv     <= d_rf_inv;
  dbg_rf_mrw_l   <= d_rf_mrw(31 downto 0);
  dbg_rf_mrw_h   <= d_rf_mrw(63 downto 32);
  dbg_rf_sh      <= d_rf_sh;
  dbg_ra_xchk    <= d_ra_xchk;
  dbg_ra_ssq_l   <= d_ra_ssq(31 downto 0);
  dbg_ra_inv     <= d_ra_inv;
  dbg_vc_emb     <= d_vc_emb;
  dbg_vc_xcur    <= d_vc_xcur;
  dbg_vc_wo      <= d_vc_wo;
  dbg_vc_woreg   <= d_vc_woreg;
  dbg_vc_res1    <= d_vc_res1;
  dbg_vc_xm      <= d_vc_xm;
  dbg_vc_rmsx    <= d_vc_rmsx;
  dbg_vc_rmso    <= d_vc_rmso;
  dbg_vc_w1      <= d_vc_w1;
  dbg_vc_w3      <= d_vc_w3;
  dbg_qx_qmag_l  <= d_qx_qmag(31 downto 0);
  dbg_qx_qmag_h  <= d_qx_qmag(63 downto 32);
  dbg_qx_nmag_l  <= d_qx_nmag(31 downto 0);
  dbg_qx_nmag_h  <= d_qx_nmag(63 downto 32);
  dbg_qx_nsd_l   <= d_qx_nsd(31 downto 0);
  dbg_qx_nsd_h   <= d_qx_nsd(63 downto 32);
  dbg_qx_sum     <= d_qx_sum;
  dbg_qx_meta    <= d_qx_meta;

end architecture;
