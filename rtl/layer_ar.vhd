-- rtl/layer_ar.vhd
-- Autoregressive transformer layer for the full PL engine.
--
-- Adapted from rtl/layer_fsm.vhd (the validated one-layer FSM, tb_layer_fsm
-- max_dev=8 vs fx_layer0_out).  Two changes versus layer_fsm:
--
--   1. GENERIC `LAYER` selects which layer's weights to bake in: every weight
--      aggregate from work.weights_pkg is sliced by LAYER (WQ, WQ_MULT/SHIFT,
--      ATT_RMS_W/_EXP, ... for L in 0..4).  matmul.vhd indexes its WMANT/
--      WMULT/WSHFT generics via 'low, so non-zero-low slices are fine.
--
--   2. NO KV-HISTORY REPLAY.  layer_fsm replays history because its testbench
--      preloads the cache; it drives attention.vhd once per position 0..cur_pos.
--      The ENGINE instead gives EACH layer its OWN persistent attention.vhd
--      instance whose KV cache already holds positions 0..pos-1 from earlier
--      tokens.  So this unit drives attention EXACTLY ONCE per token:
--        cur_pos = pos, k_new = post-rope K[pos], v_new = pre-rope V[pos];
--      attention stores at slot pos and computes over 0..pos.  There are no
--      history ports and no k_out/v_out ports (the cache is internal).
--
--   `kv_reset` clears this layer's attention KV cache (routed to attention's
--   rst, which now zeroes the cache) so a fresh run starts empty.
--
--   `pos` is a runtime port (rope.vhd takes a runtime `pos` port too).
--
-- Synthesizable: no `real`, no TEXTIO.  Weight/LUT data all come from the
-- generated weights_pkg / rope_rom_pkg constant packages.  (GHDL-functional:
-- the nonlinear sub-units are still fully unrolled -- area/fit is a later task.)

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;      -- msb_pos
use work.fixed_pkg.all;     -- scale_mul
use work.weights_pkg.all;   -- intarr + WQ/WK/.../ATT_RMS_W/... constants

entity layer_ar is
  generic(
    LAYER     : integer := 0;    -- which transformer layer (0..N_LAYERS-1)
    DIM       : integer := 64;
    HIDDEN    : integer := 172;
    NHEADS    : integer := 8;
    NKVH      : integer := 4;
    KVDIM     : integer := 32;
    HEAD_SIZE : integer := 8;    -- DIM/NHEADS
    MAXPOS    : integer := 256   -- KV cache depth (context cap)
  );
  port(
    clk      : in  std_logic;
    rst      : in  std_logic;
    start    : in  std_logic;
    kv_reset : in  std_logic;    -- clear this layer's KV cache (pulse at run start)
    pos      : in  integer;      -- 0-based decode position
    -- Input residual (DIM int16 mantissas packed, one shared exponent)
    x_mant : in  std_logic_vector(DIM*16-1 downto 0);
    x_exp  : in  integer;
    -- Output residual
    done   : out std_logic;
    xo_mant : out std_logic_vector(DIM*16-1 downto 0);
    xo_exp  : out integer
  );
end entity;

architecture rtl of layer_ar is

  type s64arr is array(natural range <>) of signed(63 downto 0);

  -- Pack an intarr slice (base..base+n-1) into an int16-mantissa slv constant.
  function pack16(a : intarr; base, n : integer) return std_logic_vector is
    variable r : std_logic_vector(n*16-1 downto 0);
  begin
    for j in 0 to n-1 loop
      r((j+1)*16-1 downto j*16) := std_logic_vector(to_signed(a(base+j), 16));
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

  -- RMSNorm per-layer weight constants (BFP: mant + shared exp).
  constant ATT_W_MANT : std_logic_vector(DIM*16-1 downto 0) := pack16(ATT_RMS_W, LAYER*DIM, DIM);
  constant ATT_W_EXP  : integer := ATT_RMS_W_EXP(LAYER);
  constant FFN_W_MANT : std_logic_vector(DIM*16-1 downto 0) := pack16(FFN_RMS_W, LAYER*DIM, DIM);
  constant FFN_W_EXP  : integer := FFN_RMS_W_EXP(LAYER);

  -- Attention KV reset (clears cache without disturbing the rest of the layer).
  signal att_rst : std_logic;

  -- ---- sub-block handshakes / outputs -----------------------------------
  signal rms_att_start, rms_att_done : std_logic := '0';
  signal rms_att_o_mant : std_logic_vector(DIM*16-1 downto 0);
  signal rms_att_o_exp  : integer;

  signal rms_ffn_start, rms_ffn_done : std_logic := '0';
  signal rms_ffn_o_mant : std_logic_vector(DIM*16-1 downto 0);
  signal rms_ffn_o_exp  : integer;

  signal wq_start, wq_done : std_logic := '0';
  signal wq_o_mant : std_logic_vector(DIM*16-1 downto 0);
  signal wq_o_exp  : integer;
  signal wk_start, wk_done : std_logic := '0';
  signal wk_o_mant : std_logic_vector(KVDIM*16-1 downto 0);
  signal wk_o_exp  : integer;
  signal wv_start, wv_done : std_logic := '0';
  signal wv_o_mant : std_logic_vector(KVDIM*16-1 downto 0);
  signal wv_o_exp  : integer;

  signal wo_start, wo_done : std_logic := '0';
  signal wo_o_mant : std_logic_vector(DIM*16-1 downto 0);
  signal wo_o_exp  : integer;

  signal w1_start, w1_done : std_logic := '0';
  signal w1_o_mant : std_logic_vector(HIDDEN*16-1 downto 0);
  signal w1_o_exp  : integer;
  signal w3_start, w3_done : std_logic := '0';
  signal w3_o_mant : std_logic_vector(HIDDEN*16-1 downto 0);
  signal w3_o_exp  : integer;

  signal w2_start, w2_done : std_logic := '0';
  signal w2_o_mant : std_logic_vector(DIM*16-1 downto 0);
  signal w2_o_exp  : integer;

  signal rope_start, rope_done : std_logic := '0';
  signal rope_qo_mant : std_logic_vector(DIM*16-1 downto 0);
  signal rope_qo_exp  : integer;
  signal rope_ko_mant : std_logic_vector(KVDIM*16-1 downto 0);
  signal rope_ko_exp  : integer;

  signal sw_start, sw_done : std_logic := '0';
  signal sw_out_q : std_logic_vector(HIDDEN*32-1 downto 0);

  -- ---- attention interface (driven ONCE per token) ----------------------
  signal att_start, att_done : std_logic := '0';
  signal att_curpos    : integer := 0;
  signal att_q_mant    : std_logic_vector(DIM*16-1 downto 0)   := (others => '0');
  signal att_q_exp     : integer := 0;
  signal att_k_new_mant: std_logic_vector(KVDIM*16-1 downto 0) := (others => '0');
  signal att_k_new_exp : integer := 0;
  signal att_v_new_mant: std_logic_vector(KVDIM*16-1 downto 0) := (others => '0');
  signal att_v_new_exp : integer := 0;
  signal att_xb_mant   : std_logic_vector(DIM*16-1 downto 0);
  signal att_xb_exp    : integer;

  -- ---- datapath registers -----------------------------------------------
  signal x_mant_l  : std_logic_vector(DIM*16-1 downto 0) := (others => '0');
  signal x_exp_l   : integer := 0;
  signal xm_mant_l : std_logic_vector(DIM*16-1 downto 0) := (others => '0'); -- after residual 1
  signal xm_exp_l  : integer := 0;
  signal hb_mant_l : std_logic_vector(HIDDEN*16-1 downto 0) := (others => '0'); -- swiglu BFP
  signal hb_exp_l  : integer := 0;

  type state_t is (
    S_IDLE,
    S_RMS_ATT_S, S_RMS_ATT_W,
    S_WQ_S, S_WQ_W, S_WK_S, S_WK_W, S_WV_S, S_WV_W,
    S_ROPE_S, S_ROPE_W,
    S_ATT_S, S_ATT_W,
    S_WO_S, S_WO_W,
    S_RES1,
    S_RMS_FFN_S, S_RMS_FFN_W,
    S_W1_S, S_W1_W, S_W3_S, S_W3_W,
    S_SW_S, S_SW_W, S_HBPACK,
    S_W2_S, S_W2_W,
    S_RES2
  );
  signal state : state_t := S_IDLE;

begin

  -- Attention cache clear = layer reset OR kv_reset pulse (attention zeroes its
  -- KV cache on rst).  The other sub-units are stateless between calls, so they
  -- take the plain layer rst.
  att_rst <= rst or kv_reset;

  -- =========================================================================
  -- Sub-block instances (each a validated single-shot unit), weights per LAYER.
  -- =========================================================================
  u_rms_att : entity work.rmsnorm
    generic map(N => DIM, Q => 12)
    port map(clk => clk, rst => rst, start => rms_att_start,
             x_mant => x_mant_l, x_exp => x_exp_l,
             w_mant => ATT_W_MANT, w_exp => ATT_W_EXP,
             done => rms_att_done, o_mant => rms_att_o_mant, o_exp => rms_att_o_exp);

  u_rms_ffn : entity work.rmsnorm
    generic map(N => DIM, Q => 12)
    port map(clk => clk, rst => rst, start => rms_ffn_start,
             x_mant => xm_mant_l, x_exp => xm_exp_l,
             w_mant => FFN_W_MANT, w_exp => FFN_W_EXP,
             done => rms_ffn_done, o_mant => rms_ffn_o_mant, o_exp => rms_ffn_o_exp);

  -- WQ: 64x64, clamp shift_o >= 0.
  u_wq : entity work.matmul
    generic map(OUT_ROWS => DIM, IN_COLS => DIM, CLAMP_NONNEG => true,
                WMANT => WQ(LAYER*WQ_STRIDE to (LAYER+1)*WQ_STRIDE-1),
                WMULT => WQ_MULT(LAYER*DIM to (LAYER+1)*DIM-1),
                WSHFT => WQ_SHIFT(LAYER*DIM to (LAYER+1)*DIM-1))
    port map(clk => clk, rst => rst, start => wq_start,
             x_mant => rms_att_o_mant, x_exp => rms_att_o_exp,
             done => wq_done, o_mant => wq_o_mant, o_exp => wq_o_exp);

  -- WK: 32x64, allow negative shift.
  u_wk : entity work.matmul
    generic map(OUT_ROWS => KVDIM, IN_COLS => DIM, CLAMP_NONNEG => false,
                WMANT => WK(LAYER*WK_STRIDE to (LAYER+1)*WK_STRIDE-1),
                WMULT => WK_MULT(LAYER*KVDIM to (LAYER+1)*KVDIM-1),
                WSHFT => WK_SHIFT(LAYER*KVDIM to (LAYER+1)*KVDIM-1))
    port map(clk => clk, rst => rst, start => wk_start,
             x_mant => rms_att_o_mant, x_exp => rms_att_o_exp,
             done => wk_done, o_mant => wk_o_mant, o_exp => wk_o_exp);

  -- WV: 32x64, allow negative shift.
  u_wv : entity work.matmul
    generic map(OUT_ROWS => KVDIM, IN_COLS => DIM, CLAMP_NONNEG => false,
                WMANT => WV(LAYER*WV_STRIDE to (LAYER+1)*WV_STRIDE-1),
                WMULT => WV_MULT(LAYER*KVDIM to (LAYER+1)*KVDIM-1),
                WSHFT => WV_SHIFT(LAYER*KVDIM to (LAYER+1)*KVDIM-1))
    port map(clk => clk, rst => rst, start => wv_start,
             x_mant => rms_att_o_mant, x_exp => rms_att_o_exp,
             done => wv_done, o_mant => wv_o_mant, o_exp => wv_o_exp);

  -- RoPE on Q (post-WQ) and K (post-WK) at runtime `pos`; exponents preserved.
  u_rope : entity work.rope
    generic map(DIM => DIM, HEAD => HEAD_SIZE, KVDIM => KVDIM)
    port map(clk => clk, rst => rst, start => rope_start, pos => pos,
             q_mant => wq_o_mant, q_exp => wq_o_exp,
             k_mant => wk_o_mant, k_exp => wk_o_exp,
             done => rope_done,
             qo_mant => rope_qo_mant, qo_exp => rope_qo_exp,
             ko_mant => rope_ko_mant, ko_exp => rope_ko_exp);

  -- Multi-head attention with a PERSISTENT internal KV cache (driven once per
  -- token).  att_rst clears the cache at run start (kv_reset) or on layer rst.
  u_att : entity work.attention
    generic map(DIM => DIM, HEAD_SIZE => HEAD_SIZE, NHEADS => NHEADS,
                NKVH => NKVH, KVDIM => KVDIM, MAXPOS => MAXPOS, Q => 12)
    port map(clk => clk, rst => att_rst, start => att_start, cur_pos => att_curpos,
             q_mant => att_q_mant, q_exp => att_q_exp,
             k_new_mant => att_k_new_mant, k_new_exp => att_k_new_exp,
             v_new_mant => att_v_new_mant, v_new_exp => att_v_new_exp,
             done => att_done, xb_mant => att_xb_mant, xb_exp => att_xb_exp,
             dbg_score_mant => open, dbg_score_exp => open, dbg_prob_q => open,
             dbg_slot => 0,
             dbg_k_mant => open, dbg_k_exp => open,
             dbg_v_mant => open, dbg_v_exp => open);

  -- WO: 64x64, allow negative shift.
  u_wo : entity work.matmul
    generic map(OUT_ROWS => DIM, IN_COLS => DIM, CLAMP_NONNEG => false,
                WMANT => WO(LAYER*WO_STRIDE to (LAYER+1)*WO_STRIDE-1),
                WMULT => WO_MULT(LAYER*DIM to (LAYER+1)*DIM-1),
                WSHFT => WO_SHIFT(LAYER*DIM to (LAYER+1)*DIM-1))
    port map(clk => clk, rst => rst, start => wo_start,
             x_mant => att_xb_mant, x_exp => att_xb_exp,
             done => wo_done, o_mant => wo_o_mant, o_exp => wo_o_exp);

  -- W1: 172x64, clamp shift_o >= 0.
  u_w1 : entity work.matmul
    generic map(OUT_ROWS => HIDDEN, IN_COLS => DIM, CLAMP_NONNEG => true,
                WMANT => W1(LAYER*W1_STRIDE to (LAYER+1)*W1_STRIDE-1),
                WMULT => W1_MULT(LAYER*HIDDEN to (LAYER+1)*HIDDEN-1),
                WSHFT => W1_SHIFT(LAYER*HIDDEN to (LAYER+1)*HIDDEN-1))
    port map(clk => clk, rst => rst, start => w1_start,
             x_mant => rms_ffn_o_mant, x_exp => rms_ffn_o_exp,
             done => w1_done, o_mant => w1_o_mant, o_exp => w1_o_exp);

  -- W3: 172x64, clamp shift_o >= 0.
  u_w3 : entity work.matmul
    generic map(OUT_ROWS => HIDDEN, IN_COLS => DIM, CLAMP_NONNEG => true,
                WMANT => W3(LAYER*W3_STRIDE to (LAYER+1)*W3_STRIDE-1),
                WMULT => W3_MULT(LAYER*HIDDEN to (LAYER+1)*HIDDEN-1),
                WSHFT => W3_SHIFT(LAYER*HIDDEN to (LAYER+1)*HIDDEN-1))
    port map(clk => clk, rst => rst, start => w3_start,
             x_mant => rms_ffn_o_mant, x_exp => rms_ffn_o_exp,
             done => w3_done, o_mant => w3_o_mant, o_exp => w3_o_exp);

  -- SwiGLU: hb = silu(h1) * h3, Q12 output.
  u_sw : entity work.swiglu
    generic map(N => HIDDEN, Q => 12)
    port map(clk => clk, rst => rst, start => sw_start,
             hb_mant => w1_o_mant, hb_exp => w1_o_exp,
             hb2_mant => w3_o_mant, hb2_exp => w3_o_exp,
             done => sw_done, out_q => sw_out_q);

  -- W2: 64x172, allow negative shift.
  u_w2 : entity work.matmul
    generic map(OUT_ROWS => DIM, IN_COLS => HIDDEN, CLAMP_NONNEG => false,
                WMANT => W2(LAYER*W2_STRIDE to (LAYER+1)*W2_STRIDE-1),
                WMULT => W2_MULT(LAYER*DIM to (LAYER+1)*DIM-1),
                WSHFT => W2_SHIFT(LAYER*DIM to (LAYER+1)*DIM-1))
    port map(clk => clk, rst => rst, start => w2_start,
             x_mant => hb_mant_l, x_exp => hb_exp_l,
             done => w2_done, o_mant => w2_o_mant, o_exp => w2_o_exp);

  -- =========================================================================
  -- Control FSM + block-float routing / residual adds / hb-pack.
  -- =========================================================================
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
    -- hb-pack temporaries (Q12 int -> BFP int16)
    variable hbq   : integer;
    variable max_abs : integer;
    variable av    : integer;
    variable p_msb : integer;
    variable shift_o : integer;
    variable r32   : signed(31 downto 0);
    variable sat   : integer;
  begin
    if rising_edge(clk) then
      done          <= '0';
      rms_att_start <= '0';
      rms_ffn_start <= '0';
      wq_start <= '0'; wk_start <= '0'; wv_start <= '0';
      wo_start <= '0'; w1_start <= '0'; w3_start <= '0'; w2_start <= '0';
      rope_start <= '0'; att_start <= '0'; sw_start <= '0';

      if rst = '1' then
        state  <= S_IDLE;
        xo_mant <= (others => '0');
        xo_exp  <= 0;
      else
        case state is

          when S_IDLE =>
            if start = '1' then
              x_mant_l <= x_mant;
              x_exp_l  <= x_exp;
              state <= S_RMS_ATT_S;
            end if;

          -- ---- 1. attention RMSNorm --------------------------------------
          when S_RMS_ATT_S =>
            rms_att_start <= '1';
            state <= S_RMS_ATT_W;
          when S_RMS_ATT_W =>
            if rms_att_done = '1' then
              state <= S_WQ_S;   -- xb held on rms_att_o_* (feeds wq/wk/wv)
            end if;

          -- ---- 2. WQ / WK / WV matmuls -----------------------------------
          when S_WQ_S =>
            wq_start <= '1'; state <= S_WQ_W;
          when S_WQ_W =>
            if wq_done = '1' then state <= S_WK_S; end if;
          when S_WK_S =>
            wk_start <= '1'; state <= S_WK_W;
          when S_WK_W =>
            if wk_done = '1' then state <= S_WV_S; end if;
          when S_WV_S =>
            wv_start <= '1'; state <= S_WV_W;
          when S_WV_W =>
            if wv_done = '1' then
              state <= S_ROPE_S;   -- current-position V (pre-rope) on wv_o_*
            end if;

          -- ---- 3. RoPE on Q and K ----------------------------------------
          when S_ROPE_S =>
            rope_start <= '1'; state <= S_ROPE_W;
          when S_ROPE_W =>
            if rope_done = '1' then
              state <= S_ATT_S;    -- post-rope K[pos] on rope_ko_*
            end if;

          -- ---- 4. attention: drive ONCE for this token -------------------
          when S_ATT_S =>
            att_curpos     <= pos;
            att_q_mant     <= rope_qo_mant;
            att_q_exp      <= rope_qo_exp;
            att_k_new_mant <= rope_ko_mant;  -- computed post-rope K[pos]
            att_k_new_exp  <= rope_ko_exp;
            att_v_new_mant <= wv_o_mant;     -- computed pre-rope V[pos]
            att_v_new_exp  <= wv_o_exp;
            att_start <= '1';
            state <= S_ATT_W;
          when S_ATT_W =>
            if att_done = '1' then
              state <= S_WO_S;      -- xb held on att_xb_* (feeds wo)
            end if;

          -- ---- 5. WO matmul + residual add 1 -----------------------------
          when S_WO_S =>
            wo_start <= '1'; state <= S_WO_W;
          when S_WO_W =>
            if wo_done = '1' then state <= S_RES1; end if;
          when S_RES1 =>
            residual_add(x_mant_l, x_exp_l, wo_o_mant, wo_o_exp, rm, re);
            xm_mant_l <= rm;
            xm_exp_l  <= re;
            state <= S_RMS_FFN_S;

          -- ---- 6. FFN RMSNorm --------------------------------------------
          when S_RMS_FFN_S =>
            rms_ffn_start <= '1'; state <= S_RMS_FFN_W;
          when S_RMS_FFN_W =>
            if rms_ffn_done = '1' then state <= S_W1_S; end if;

          -- ---- 7. W1 / W3 matmuls ----------------------------------------
          when S_W1_S =>
            w1_start <= '1'; state <= S_W1_W;
          when S_W1_W =>
            if w1_done = '1' then state <= S_W3_S; end if;
          when S_W3_S =>
            w3_start <= '1'; state <= S_W3_W;
          when S_W3_W =>
            if w3_done = '1' then state <= S_SW_S; end if;

          -- ---- 8. SwiGLU + BFP-pack --------------------------------------
          when S_SW_S =>
            sw_start <= '1'; state <= S_SW_W;
          when S_SW_W =>
            if sw_done = '1' then state <= S_HBPACK; end if;
          when S_HBPACK =>
            -- Q12 int (sw_out_q) -> BFP int16 mantissas.
            max_abs := 0;
            for i in 0 to HIDDEN-1 loop
              hbq := to_integer(signed(sw_out_q((i+1)*32-1 downto i*32)));
              av := hbq; if av < 0 then av := -av; end if;
              if av > max_abs then max_abs := av; end if;
            end loop;
            p_msb   := msb_pos(max_abs);
            shift_o := p_msb - 14; if shift_o < 0 then shift_o := 0; end if;
            hb_exp_l <= 12 - shift_o;
            for i in 0 to HIDDEN-1 loop
              hbq := to_integer(signed(sw_out_q((i+1)*32-1 downto i*32)));
              r32 := scale_mul(to_signed(hbq, 64), to_signed(1, 32), shift_o);
              if    r32 >  32767 then sat :=  32767;
              elsif r32 < -32768 then sat := -32768;
              else                    sat := to_integer(r32);
              end if;
              hb_mant_l((i+1)*16-1 downto i*16) <= std_logic_vector(to_signed(sat, 16));
            end loop;
            state <= S_W2_S;

          -- ---- 9. W2 matmul + residual add 2 -> output -------------------
          when S_W2_S =>
            w2_start <= '1'; state <= S_W2_W;
          when S_W2_W =>
            if w2_done = '1' then state <= S_RES2; end if;
          when S_RES2 =>
            residual_add(xm_mant_l, xm_exp_l, w2_o_mant, w2_o_exp, rm, re);
            xo_mant <= rm;
            xo_exp  <= re;
            done    <= '1';
            state   <= S_IDLE;

        end case;
      end if;
    end if;
  end process;

end architecture;
