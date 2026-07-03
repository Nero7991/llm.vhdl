-- rtl/seq_ctrl.vhd
-- Top-level autoregressive sequencer: drives embed -> 5x layer -> final
-- rmsnorm -> lm_head -> sampler, position by position, exactly mirroring
-- the C oracle's generate loop in ref/run_fx.c:
--
--   for pos = 0 .. NGEN-1:
--     token = (pos==0) ? prompt(0) : prev_next
--     logits = forward(token, pos)
--     amax   = argmax(logits)
--     next   = (pos < NUM_PROMPT-1) ? prompt(pos+1) : amax   -- teacher forcing
--     emit(next); prev_next = next
--
-- This is a behavioural driver process (procedural "wait until rising_edge
-- (clk)" sequencing), not a one-hot register FSM -- consistent with the
-- rest of this project, where every unit (layer.vhd, rmsnorm.vhd, ...)
-- already uses VHDL `real` and impure file I/O inside a clocked process and
-- is therefore a simulation/golden-model description rather than
-- synthesizable RTL. Every sub-unit in this design has the same handshake:
-- assert start for one clock, then done pulses high for one clock with the
-- registered result valid; this driver just chains that handshake through
-- embed -> 5 layers -> rmsnorm -> lm_head -> sampler once per position.
--
-- KV cache: one history buffer per layer, MAXPOS slots each, in the exact
-- packed layout layer.vhd's k_mant/k_exp_packed/v_mant/v_exp_packed ports
-- expect (slot t occupies bits [(t+1)*KVDIM*16-1 : t*KVDIM*16] for mant,
-- [(t+1)*32-1 : t*32] for the exponent). After layer l finishes position p,
-- its own computed k_out/v_out (post-RoPE K[p], raw V[p]) are written into
-- slot p of that layer's cache so future positions can read it as history.
-- Only slots 0..cur_pos-1 are ever read by layer.vhd (guarded by cur_pos),
-- so writing slot p AFTER using the cache as history for position p is race
-- free.
--
-- NGEN is the TOTAL number of positions to run (p = 0 .. NGEN-1), i.e. the
-- same N a testbench wants to compare against fx_tokens_greedy.txt -- not
-- just the autoregressive tail. Must have NGEN <= MAXPOS.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity seq_ctrl is
  generic(
    DIM        : integer := 64;
    HIDDEN     : integer := 172;
    NHEADS     : integer := 8;
    NKVH       : integer := 4;
    KVDIM      : integer := 32;
    HEAD_SIZE  : integer := 8;
    VOCAB      : integer := 512;
    MAXPOS     : integer := 16;
    NLAYERS    : integer := 5;
    NUM_PROMPT : integer := 5;
    NGEN       : integer := 16   -- total positions to run: p = 0 .. NGEN-1
  );
  port(
    clk        : in  std_logic;
    rst        : in  std_logic;
    start      : in  std_logic;
    -- Emitted-token stream: one pulse per position p, in order.
    emit_token : out integer;
    emit_pos   : out integer;
    emit_valid : out std_logic;
    -- Pulses (and stays) high once all NGEN positions have been emitted.
    run_done   : out std_logic
  );
end entity;

architecture rtl of seq_ctrl is

  -- ---------------------------------------------------------------------
  -- File-loaded constants (prompt tokens, final RMSNorm weight)
  -- ---------------------------------------------------------------------
  type intarr is array(natural range <>) of integer;

  impure function load_ints(fn : string; n : integer) return intarr is
    file   fh : text open read_mode is fn;
    variable L : line; variable v : integer;
    variable r : intarr(0 to n-1);
  begin
    for i in 0 to n-1 loop
      readline(fh, L); read(L, v); r(i) := v;
    end loop;
    return r;
  end function;

  impure function load_int(fn : string) return integer is
    file   fh : text open read_mode is fn;
    variable L : line; variable v : integer;
  begin
    readline(fh, L); read(L, v); return v;
  end function;

  constant PROMPT         : intarr(0 to NUM_PROMPT-1) :=
    load_ints("../mem/golden/prompt_tokens.txt", NUM_PROMPT);
  constant FINAL_W_MANT_I : intarr(0 to DIM-1) :=
    load_ints("../mem/weights/final_rmsnorm_w.mem", DIM);
  constant FINAL_W_EXP    : integer :=
    load_int("../mem/weights/final_rmsnorm_w_exp.txt");

  signal final_w_mant_sig : std_logic_vector(DIM*16-1 downto 0);

  -- ---------------------------------------------------------------------
  -- Shared residual-stream bus (embed output, then each layer's y in turn,
  -- then final rmsnorm's input)
  -- ---------------------------------------------------------------------
  signal x_mant_cur : std_logic_vector(DIM*16-1 downto 0) := (others => '0');
  signal x_exp_cur  : integer := 0;
  signal cur_pos_reg : integer := 0;

  -- ---------------------------------------------------------------------
  -- Embed
  -- ---------------------------------------------------------------------
  signal embed_token  : integer := 0;
  signal embed_x_mant : std_logic_vector(DIM*16-1 downto 0);
  signal embed_x_exp  : integer;

  -- ---------------------------------------------------------------------
  -- Per-layer arrays (5 independent layer instances, each with its own KV
  -- cache; all share the same x_mant_cur/x_exp_cur/cur_pos_reg bus -- only
  -- the active layer's start is pulsed at a time)
  -- ---------------------------------------------------------------------
  type dim_mant_arr   is array(0 to NLAYERS-1) of std_logic_vector(DIM*16-1 downto 0);
  type kvdim_mant_arr is array(0 to NLAYERS-1) of std_logic_vector(KVDIM*16-1 downto 0);
  type kv_mant_arr    is array(0 to NLAYERS-1) of std_logic_vector(MAXPOS*KVDIM*16-1 downto 0);
  type kv_exp_arr     is array(0 to NLAYERS-1) of std_logic_vector(MAXPOS*32-1 downto 0);
  type int_arr        is array(0 to NLAYERS-1) of integer;

  signal layer_start : std_logic_vector(0 to NLAYERS-1) := (others => '0');
  signal layer_done  : std_logic_vector(0 to NLAYERS-1);

  signal layer_y_mant : dim_mant_arr;
  signal layer_y_exp  : int_arr;

  signal layer_k_out_mant, layer_v_out_mant : kvdim_mant_arr;
  signal layer_k_out_exp,  layer_v_out_exp  : int_arr;

  signal kv_k_mant, kv_v_mant : kv_mant_arr := (others => (others => '0'));
  signal kv_k_exp,  kv_v_exp  : kv_exp_arr  := (others => (others => '0'));

  -- ---------------------------------------------------------------------
  -- Final RMSNorm / lm_head / sampler
  -- ---------------------------------------------------------------------
  signal rms_start : std_logic := '0';
  signal rms_done  : std_logic;
  signal rms_o_mant : std_logic_vector(DIM*16-1 downto 0);
  signal rms_o_exp  : integer;

  signal lm_start : std_logic := '0';
  signal lm_done  : std_logic;
  signal lm_logits : std_logic_vector(VOCAB*32-1 downto 0);

  signal samp_start : std_logic := '0';
  signal samp_done  : std_logic;
  signal samp_token : integer;

begin

  assert NGEN <= MAXPOS
    report "seq_ctrl: NGEN must be <= MAXPOS (KV cache has only MAXPOS slots)"
    severity failure;

  -- Unpack final RMSNorm weight (loaded once at elaboration) into a
  -- block-fp mantissa bus for the rmsnorm instance below.
  gen_fw: for j in 0 to DIM-1 generate
  begin
    final_w_mant_sig((j+1)*16-1 downto j*16) <=
      std_logic_vector(to_signed(FINAL_W_MANT_I(j), 16));
  end generate gen_fw;

  -- ---------------------------------------------------------------------
  -- Sub-unit instances
  -- ---------------------------------------------------------------------
  u_embed: entity work.embed
    generic map(DIM => DIM, VOCAB => VOCAB)
    port map(
      clk    => clk,
      token  => embed_token,
      done   => open,
      x_mant => embed_x_mant,
      x_exp  => embed_x_exp
    );

  gen_layers: for l in 0 to NLAYERS-1 generate
  begin
    u_layer: entity work.layer
      generic map(
        DIM        => DIM,
        HIDDEN     => HIDDEN,
        NHEADS     => NHEADS,
        NKVH       => NKVH,
        KVDIM      => KVDIM,
        HEAD_SIZE  => HEAD_SIZE,
        MAXPOS     => MAXPOS,
        WEIGHT_DIR => "../mem/weights/L" & integer'image(l) & "/"
      )
      port map(
        clk          => clk,
        rst          => rst,
        start        => layer_start(l),
        cur_pos      => cur_pos_reg,
        x_mant       => x_mant_cur,
        x_exp        => x_exp_cur,
        k_mant       => kv_k_mant(l),
        k_exp_packed => kv_k_exp(l),
        v_mant       => kv_v_mant(l),
        v_exp_packed => kv_v_exp(l),
        done         => layer_done(l),
        y_mant       => layer_y_mant(l),
        y_exp        => layer_y_exp(l),
        k_out_mant   => layer_k_out_mant(l),
        k_out_exp    => layer_k_out_exp(l),
        v_out_mant   => layer_v_out_mant(l),
        v_out_exp    => layer_v_out_exp(l)
      );
  end generate gen_layers;

  u_rmsnorm: entity work.rmsnorm
    generic map(N => DIM, Q => 12)
    port map(
      clk    => clk,
      rst    => rst,
      start  => rms_start,
      x_mant => x_mant_cur,
      x_exp  => x_exp_cur,
      w_mant => final_w_mant_sig,
      w_exp  => FINAL_W_EXP,
      done   => rms_done,
      o_mant => rms_o_mant,
      o_exp  => rms_o_exp
    );

  u_lm_head: entity work.lm_head
    generic map(DIM => DIM, VOCAB => VOCAB)
    port map(
      clk    => clk,
      rst    => rst,
      start  => lm_start,
      x_mant => rms_o_mant,
      x_exp  => rms_o_exp,
      done   => lm_done,
      logits => lm_logits
    );

  u_sampler: entity work.sampler
    generic map(VOCAB => VOCAB)
    port map(
      clk    => clk,
      rst    => rst,
      start  => samp_start,
      logits => lm_logits,
      done   => samp_done,
      token  => samp_token
    );

  -- ---------------------------------------------------------------------
  -- Driver process: procedurally sequences one position at a time through
  -- embed -> 5 layers -> rmsnorm -> lm_head -> sampler, handling teacher
  -- forcing and emitting the resulting token stream.
  -- ---------------------------------------------------------------------
  process
    variable tok       : integer;
    variable prev_next : integer := 0;
    variable next_tok  : integer;
  begin
    emit_valid <= '0';
    run_done   <= '0';

    wait until rst = '0';
    wait until rising_edge(clk);
    wait until start = '1';
    wait until rising_edge(clk);

    for p in 0 to NGEN-1 loop

      cur_pos_reg <= p;
      if p = 0 then
        tok := PROMPT(0);
      else
        tok := prev_next;
      end if;

      -- Step: embed(token) -> x  (no start/rst; continuously computes,
      -- registered one cycle after `token` is sampled)
      embed_token <= tok;
      wait until rising_edge(clk);
      wait for 1 ns;
      x_mant_cur <= embed_x_mant;
      x_exp_cur  <= embed_x_exp;
      wait for 1 ns;

      -- Step: 5 transformer layers, sequentially, threading x through each
      for l in 0 to NLAYERS-1 loop
        layer_start(l) <= '1';
        wait until rising_edge(clk);
        layer_start(l) <= '0';
        wait until layer_done(l) = '1';
        wait for 1 ns;

        x_mant_cur <= layer_y_mant(l);
        x_exp_cur  <= layer_y_exp(l);

        -- Cache this layer's own computed K[p]/V[p] for future positions.
        kv_k_mant(l)((p+1)*KVDIM*16-1 downto p*KVDIM*16) <= layer_k_out_mant(l);
        kv_k_exp(l)((p+1)*32-1 downto p*32) <=
          std_logic_vector(to_signed(layer_k_out_exp(l), 32));
        kv_v_mant(l)((p+1)*KVDIM*16-1 downto p*KVDIM*16) <= layer_v_out_mant(l);
        kv_v_exp(l)((p+1)*32-1 downto p*32) <=
          std_logic_vector(to_signed(layer_v_out_exp(l), 32));

        wait for 1 ns;
      end loop;

      -- Step: final rmsnorm(x) -> xn
      rms_start <= '1';
      wait until rising_edge(clk);
      rms_start <= '0';
      wait until rms_done = '1';
      wait for 1 ns;

      -- Step: lm_head(xn) -> logits
      lm_start <= '1';
      wait until rising_edge(clk);
      lm_start <= '0';
      wait until lm_done = '1';
      wait for 1 ns;

      -- Step: sampler(logits) -> argmax
      samp_start <= '1';
      wait until rising_edge(clk);
      samp_start <= '0';
      wait until samp_done = '1';
      wait for 1 ns;

      -- Step: teacher forcing vs. real argmax, then emit
      if p < NUM_PROMPT - 1 then
        next_tok := PROMPT(p + 1);
      else
        next_tok := samp_token;
      end if;

      emit_token <= next_tok;
      emit_pos   <= p;
      emit_valid <= '1';
      wait until rising_edge(clk);
      emit_valid <= '0';

      prev_next := next_tok;
    end loop;

    run_done <= '1';
    wait;
  end process;

end architecture;
