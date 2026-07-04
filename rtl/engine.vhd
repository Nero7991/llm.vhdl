-- rtl/engine.vhd
-- Full synthesizable autoregressive transformer engine.
--
-- Composes the already-validated units into the whole stories260K model:
--   embed -> 5x layer_ar (each with its OWN persistent KV cache) ->
--   final rmsnorm -> lm_head -> sampler (argmax),
-- driven token-by-token by a clocked outer FSM that mirrors the C oracle's
-- greedy generate loop (ref/run_fx.c), exactly as rtl/seq_ctrl.vhd does -- but
-- as a real state-machine (no `wait`), and with NO `real` and NO TEXTIO:
--
--   * the prompt tokens and the final-rmsnorm weight are compile-time
--     constants (prompt hard-coded from mem/golden/prompt_tokens.txt; weight
--     from work.weights_pkg.FINAL_RMS_W), not file-loaded;
--   * each layer_ar holds its KV cache internally and is driven exactly once
--     per token (no history replay).  A kv_reset pulse at run start clears all
--     caches so the run begins empty.
--
-- Generate loop (p = 0 .. NGEN-1):
--   token = (p==0) ? PROMPT(0) : prev_next
--   x      = embed(token)
--   for L in 0..NLAYERS-1: x = layer_ar[L](x, pos=p)   -- persistent KV per L
--   logits = lm_head(final_rmsnorm(x))
--   amax   = argmax(logits)
--   next   = (p < NUM_PROMPT-1) ? PROMPT(p+1) : amax   -- teacher-forced prompt
--   emit(next); prev_next = next
--
-- One token_valid strobe per position carries token_out/pos_out; run_done
-- latches high after all NGEN positions are emitted.  NGEN <= MAXPOS.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.weights_pkg.all;   -- FINAL_RMS_W / FINAL_RMS_W_EXP (+ intarr)

entity engine is
  generic(
    DIM        : integer := 64;
    HIDDEN     : integer := 172;
    NHEADS     : integer := 8;
    NKVH       : integer := 4;
    KVDIM      : integer := 32;
    HEAD_SIZE  : integer := 8;
    VOCAB      : integer := 512;
    MAXPOS     : integer := 256;
    NLAYERS    : integer := 5;
    NUM_PROMPT : integer := 5;
    NGEN       : integer := 16   -- total positions to run: p = 0 .. NGEN-1
  );
  port(
    clk         : in  std_logic;
    rst         : in  std_logic;
    start       : in  std_logic;
    -- Generated-token stream: one token_valid pulse per position p, in order.
    token_out   : out integer;
    pos_out     : out integer;
    token_valid : out std_logic;
    -- Latches (and stays) high once all NGEN positions have been emitted.
    run_done    : out std_logic
  );
end entity;

architecture rtl of engine is

  -- Prompt tokens (stories260K "Once upon a time"), from
  -- mem/golden/prompt_tokens.txt -- compile-time constant (no TEXTIO).
  constant PROMPT : intarr(0 to NUM_PROMPT-1) := (1, 403, 407, 261, 378);

  -- Pack an intarr (0..n-1) into an int16-mantissa slv constant.
  function pack16_0(a : intarr; n : integer) return std_logic_vector is
    variable r : std_logic_vector(n*16-1 downto 0);
  begin
    for j in 0 to n-1 loop
      r((j+1)*16-1 downto j*16) := std_logic_vector(to_signed(a(j), 16));
    end loop;
    return r;
  end function;

  constant FINAL_W_MANT : std_logic_vector(DIM*16-1 downto 0) :=
    pack16_0(FINAL_RMS_W, DIM);

  -- ---- shared residual-stream bus + position ----------------------------
  signal x_mant_cur  : std_logic_vector(DIM*16-1 downto 0) := (others => '0');
  signal x_exp_cur   : integer := 0;
  signal cur_pos_reg : integer := 0;

  -- ---- embed ------------------------------------------------------------
  signal embed_token  : integer := 0;
  signal embed_x_mant : std_logic_vector(DIM*16-1 downto 0);
  signal embed_x_exp  : integer;
  signal emb_en       : std_logic := '0';   -- gate embed's heavy per-edge body

  -- ---- per-layer (5 layer_ar instances, each with its own KV cache) ------
  type dim_mant_arr is array(0 to NLAYERS-1) of std_logic_vector(DIM*16-1 downto 0);
  type int_arr      is array(0 to NLAYERS-1) of integer;

  signal layer_start  : std_logic_vector(0 to NLAYERS-1) := (others => '0');
  signal layer_done   : std_logic_vector(0 to NLAYERS-1);
  signal layer_y_mant : dim_mant_arr;
  signal layer_y_exp  : int_arr;
  signal kv_reset     : std_logic := '0';

  -- ---- final rmsnorm / lm_head / sampler --------------------------------
  signal rms_start  : std_logic := '0';
  signal rms_done   : std_logic;
  signal rms_o_mant : std_logic_vector(DIM*16-1 downto 0);
  signal rms_o_exp  : integer;

  signal lm_start  : std_logic := '0';
  signal lm_done   : std_logic;
  signal lm_logits : std_logic_vector(VOCAB*32-1 downto 0);

  signal samp_start : std_logic := '0';
  signal samp_done  : std_logic;
  signal samp_token : integer;

  -- ---- outer FSM --------------------------------------------------------
  type state_t is (
    E_IDLE, E_KV, E_TOKSET, E_EMB1, E_EMB2,
    E_LAY_S, E_LAY_W,
    E_RMS_S, E_RMS_W, E_LM_S, E_LM_W, E_SAMP_S, E_SAMP_W,
    E_EMIT, E_FIN
  );
  signal state     : state_t := E_IDLE;
  signal p_idx     : integer := 0;    -- current position
  signal cur_layer : integer := 0;    -- active layer in the L-loop
  signal prev_next : integer := 0;    -- previously emitted token (feeds next embed)

begin

  assert NGEN <= MAXPOS
    report "engine: NGEN must be <= MAXPOS (KV cache has only MAXPOS slots)"
    severity failure;

  -- ---------------------------------------------------------------------
  -- Sub-unit instances
  -- ---------------------------------------------------------------------
  u_embed: entity work.embed
    generic map(DIM => DIM, VOCAB => VOCAB)
    port map(clk => clk, en => emb_en, token => embed_token, done => open,
             x_mant => embed_x_mant, x_exp => embed_x_exp);

  -- Enable embed only during its one-shot window (token set -> row latched),
  -- so it does not re-run its heavy body every cycle of the layer datapath.
  emb_en <= '1' when (state = E_TOKSET or state = E_EMB1 or state = E_EMB2)
            else '0';

  gen_layers: for l in 0 to NLAYERS-1 generate
  begin
    u_layer: entity work.layer_ar
      generic map(LAYER => l, DIM => DIM, HIDDEN => HIDDEN, NHEADS => NHEADS,
                  NKVH => NKVH, KVDIM => KVDIM, HEAD_SIZE => HEAD_SIZE,
                  MAXPOS => MAXPOS)
      port map(clk => clk, rst => rst, start => layer_start(l),
               kv_reset => kv_reset, pos => cur_pos_reg,
               x_mant => x_mant_cur, x_exp => x_exp_cur,
               done => layer_done(l),
               xo_mant => layer_y_mant(l), xo_exp => layer_y_exp(l));
  end generate gen_layers;

  u_rmsnorm: entity work.rmsnorm
    generic map(N => DIM, Q => 12)
    port map(clk => clk, rst => rst, start => rms_start,
             x_mant => x_mant_cur, x_exp => x_exp_cur,
             w_mant => FINAL_W_MANT, w_exp => FINAL_RMS_W_EXP,
             done => rms_done, o_mant => rms_o_mant, o_exp => rms_o_exp);

  u_lm_head: entity work.lm_head
    generic map(DIM => DIM, VOCAB => VOCAB)
    port map(clk => clk, rst => rst, start => lm_start,
             x_mant => rms_o_mant, x_exp => rms_o_exp,
             done => lm_done, logits => lm_logits);

  u_sampler: entity work.sampler
    generic map(VOCAB => VOCAB)
    port map(clk => clk, rst => rst, start => samp_start,
             logits => lm_logits, done => samp_done, token => samp_token);

  -- ---------------------------------------------------------------------
  -- Outer autoregressive FSM
  -- ---------------------------------------------------------------------
  process(clk)
    variable tok      : integer;
    variable next_tok : integer;
  begin
    if rising_edge(clk) then
      -- one-cycle strobes default low each edge
      kv_reset    <= '0';
      layer_start <= (others => '0');
      rms_start   <= '0';
      lm_start    <= '0';
      samp_start  <= '0';
      token_valid <= '0';

      if rst = '1' then
        state       <= E_IDLE;
        run_done    <= '0';
        p_idx       <= 0;
        prev_next   <= 0;
        cur_layer   <= 0;
        token_out   <= 0;
        pos_out     <= 0;
      else
        case state is

          when E_IDLE =>
            if start = '1' then
              p_idx    <= 0;
              kv_reset <= '1';    -- clear every layer's KV cache
              state    <= E_KV;
            end if;

          when E_KV =>
            state <= E_TOKSET;

          -- ---- pick the input token, embed it -----------------------
          when E_TOKSET =>
            cur_pos_reg <= p_idx;
            if p_idx = 0 then tok := PROMPT(0);
            else              tok := prev_next; end if;
            embed_token <= tok;
            state <= E_EMB1;

          when E_EMB1 =>
            state <= E_EMB2;      -- let embed register its row (1 edge)
          when E_EMB2 =>
            x_mant_cur <= embed_x_mant;
            x_exp_cur  <= embed_x_exp;
            cur_layer  <= 0;
            state <= E_LAY_S;

          -- ---- 5 transformer layers, sequentially -------------------
          when E_LAY_S =>
            layer_start(cur_layer) <= '1';
            state <= E_LAY_W;
          when E_LAY_W =>
            if layer_done(cur_layer) = '1' then
              x_mant_cur <= layer_y_mant(cur_layer);
              x_exp_cur  <= layer_y_exp(cur_layer);
              if cur_layer = NLAYERS-1 then
                state <= E_RMS_S;
              else
                cur_layer <= cur_layer + 1;
                state <= E_LAY_S;
              end if;
            end if;

          -- ---- final rmsnorm -> lm_head -> sampler ------------------
          when E_RMS_S =>
            rms_start <= '1'; state <= E_RMS_W;
          when E_RMS_W =>
            if rms_done = '1' then state <= E_LM_S; end if;
          when E_LM_S =>
            lm_start <= '1'; state <= E_LM_W;
          when E_LM_W =>
            if lm_done = '1' then state <= E_SAMP_S; end if;
          when E_SAMP_S =>
            samp_start <= '1'; state <= E_SAMP_W;
          when E_SAMP_W =>
            if samp_done = '1' then state <= E_EMIT; end if;

          -- ---- teacher forcing vs argmax, emit, advance -------------
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

end architecture;
