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
    dbg_emb_nz  : out std_logic; dbg_emb_e : out integer; dbg_emb_m : out std_logic_vector(15 downto 0);
    dbg_l0_nz   : out std_logic; dbg_l0_e  : out integer; dbg_l0_m  : out std_logic_vector(15 downto 0);
    dbg_l4_nz   : out std_logic; dbg_l4_e  : out integer; dbg_l4_m  : out std_logic_vector(15 downto 0);
    dbg_fin_nz  : out std_logic; dbg_fin_e : out integer; dbg_fin_m : out std_logic_vector(15 downto 0);
    -- intra-layer-0 taps: after the attention-rmsnorm and after attention itself
    dbg_rms_nz  : out std_logic; dbg_rms_e : out integer; dbg_rms_m : out std_logic_vector(15 downto 0);
    dbg_att_nz  : out std_logic; dbg_att_e : out integer; dbg_att_m : out std_logic_vector(15 downto 0);
    -- inputs the engine feeds the L0 att-rmsnorm: checksums (sum of the 64 int16s)
    -- of x and w, plus their exps -- to see if x/weights are corrupt on HW.
    dbg_rxchk   : out integer; dbg_rwchk : out integer;
    dbg_rxe     : out integer; dbg_rwe   : out integer; dbg_rw0 : out std_logic_vector(15 downto 0);
    dbg_samptok : out integer
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
  constant PROMPT : intarr(0 to NUM_PROMPT-1) := (1, 403, 407, 261, 378);

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

  -- ---- shared swiglu ----------------------------------------------------
  signal sw_start   : std_logic := '0';
  signal sw_done    : std_logic;
  signal sw_hb_mant : std_logic_vector(HIDDEN*16-1 downto 0) := (others => '0');
  signal sw_hb_exp  : integer := 0;
  signal sw_hb2_mant: std_logic_vector(HIDDEN*16-1 downto 0) := (others => '0');
  signal sw_hb2_exp : integer := 0;
  signal sw_out_q   : std_logic_vector(HIDDEN*32-1 downto 0);

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
  signal d_emb_nz, d_l0_nz, d_l4_nz, d_fin_nz, d_rms_nz, d_att_nz : std_logic := '0';
  signal d_emb_e, d_l0_e, d_l4_e, d_fin_e, d_rms_e, d_att_e, d_stok : integer := 0;
  signal d_emb_m, d_l0_m, d_l4_m, d_fin_m, d_rms_m, d_att_m : std_logic_vector(15 downto 0) := (others=>'0');
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
    generic map(N => DIM, Q => 12)
    port map(clk => clk, rst => rst, start => rms_start,
             x_mant => rms_x_mant, x_exp => rms_x_exp,
             w_mant => rms_w_mant, w_exp => rms_w_exp,
             done => rms_done, o_mant => rms_o_mant, o_exp => rms_o_exp);

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
                NLAYERS => NLAYERS, Q => 12)
    port map(clk => clk, rst => att_rst, start => att_start,
             layer => att_layer, cur_pos => att_curpos,
             q_mant => att_q_mant, q_exp => att_q_exp,
             k_new_mant => att_k_new_mant, k_new_exp => att_k_new_exp,
             v_new_mant => att_v_new_mant, v_new_exp => att_v_new_exp,
             done => att_done, xb_mant => att_xb_mant, xb_exp => att_xb_exp);

  u_sw: entity work.swiglu
    generic map(N => HIDDEN, Q => 12)
    port map(clk => clk, rst => rst, start => sw_start,
             hb_mant => sw_hb_mant, hb_exp => sw_hb_exp,
             hb2_mant => sw_hb2_mant, hb2_exp => sw_hb2_exp,
             done => sw_done, out_q => sw_out_q);

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
             in_q => sw_out_q, done => hbp_done,
             o_mant => hbp_o_mant, o_exp => hbp_o_exp);

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
            if p_idx = 0 then tok := PROMPT(0);
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
              if p_idx = dbg_pos then   -- DEBUG: x after embed
                d_emb_nz <= is_nz(embed_x_mant); d_emb_e <= embed_x_exp;
                d_emb_m  <= embed_x_mant(15 downto 0);
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
            state <= L_RMS_ATT_W;
          when L_RMS_ATT_W =>
            if rms_done = '1' then
              state <= L_WQ_S;
              if p_idx = dbg_pos and cur_layer = 0 then   -- DEBUG: attention-rmsnorm out + INPUTS (L0)
                d_rms_nz <= is_nz(rms_o_mant); d_rms_e <= rms_o_exp;
                d_rms_m  <= rms_o_mant(15 downto 0);
                -- raw x[1] / w[1] (cheap slices; adder-tree checksums made the
                -- 93%-full design unroutable). x[0]/w[0] captured elsewhere.
                d_rxchk  <= to_integer(signed(rms_x_mant(31 downto 16)));
                d_rwchk  <= to_integer(signed(rms_w_mant(31 downto 16)));
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
              if p_idx = dbg_pos and cur_layer = 0 then   -- DEBUG: attention output xb (L0)
                d_att_nz <= is_nz(att_xb_mant); d_att_e <= att_xb_exp;
                d_att_m  <= att_xb_mant(15 downto 0);
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
            end if;
          when L_RES1_S =>
            res_a_mant <= x_mant_cur; res_a_exp <= x_exp_cur;
            res_b_mant <= wo_reg;     res_b_exp <= wo_exp_r;
            res_start  <= '1';
            state <= L_RES1_W;
          when L_RES1_W =>
            if res_done = '1' then
              xm_mant <= res_o_mant;
              xm_exp  <= res_o_exp;
              state <= L_RMS_FFN_S;
            end if;

          -- ---- 6. FFN RMSNorm --------------------------------------
          when L_RMS_FFN_S =>
            rms_mode   <= RMS_FFN;
            rms_layer  <= cur_layer;
            rms_x_mant <= xm_mant;
            rms_x_exp  <= xm_exp;
            rms_start  <= '1';
            state <= L_RMS_FFN_W;
          when L_RMS_FFN_W =>
            if rms_done = '1' then state <= L_W1_S; end if;

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
            end if;

          -- ---- 8. SwiGLU + BFP-pack --------------------------------
          when L_SW_S =>
            sw_hb_mant  <= w1_reg; sw_hb_exp  <= w1_exp_r;
            sw_hb2_mant <= w3_reg; sw_hb2_exp <= w3_exp_r;
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
              if p_idx = dbg_pos then   -- DEBUG: x after this layer's residual2
                if cur_layer = 0 then
                  d_l0_nz <= is_nz(res_o_mant); d_l0_e <= res_o_exp;
                  d_l0_m  <= res_o_mant(15 downto 0);
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
              if p_idx = dbg_pos then   -- DEBUG: x after final rmsnorm (lm_head input)
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
            if p_idx < NUM_PROMPT - 1 then
              next_tok := PROMPT(p_idx + 1);
            else
              next_tok := samp_token;
            end if;
            token_out   <= next_tok;
            pos_out     <= p_idx;
            token_valid <= '1';
            prev_next   <= next_tok;
            if p_idx = dbg_pos then d_stok <= samp_token; end if;  -- DEBUG: this pos's argmax
            if p_idx = NGEN - 1 then
              state <= E_FIN;
            else
              p_idx <= p_idx + 1;
              state <= E_TOKSET;
            end if;

          when E_FIN =>
            run_done <= '1';
            state    <= E_FIN;

        end case;
      end if;
    end if;
  end process;

  -- DEBUG tap outputs (driven from the latched summaries).
  dbg_emb_nz <= d_emb_nz; dbg_emb_e <= d_emb_e; dbg_emb_m <= d_emb_m;
  dbg_l0_nz  <= d_l0_nz;  dbg_l0_e  <= d_l0_e;  dbg_l0_m  <= d_l0_m;
  dbg_l4_nz  <= d_l4_nz;  dbg_l4_e  <= d_l4_e;  dbg_l4_m  <= d_l4_m;
  dbg_fin_nz <= d_fin_nz; dbg_fin_e <= d_fin_e; dbg_fin_m <= d_fin_m;
  dbg_rms_nz <= d_rms_nz; dbg_rms_e <= d_rms_e; dbg_rms_m <= d_rms_m;
  dbg_att_nz <= d_att_nz; dbg_att_e <= d_att_e; dbg_att_m <= d_att_m;
  dbg_rxchk <= d_rxchk; dbg_rwchk <= d_rwchk; dbg_rxe <= d_rxe; dbg_rwe <= d_rwe; dbg_rw0 <= d_rw0;
  dbg_samptok <= d_stok;

end architecture;
