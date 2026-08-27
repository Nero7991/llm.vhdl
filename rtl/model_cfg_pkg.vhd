-- Model shape, in ONE place.
--
-- WHY THIS EXISTS.  This project has retargeted once already, Qwen3.5-0.8B to
-- Qwen3.8-27B, and the spec still carries CORRECTION blocks from dimensions
-- that survived the move.  The 16-versus-24 head confusion alone produced a
-- wrong cycle model, a wrong BRAM table and a wrong norm-overlap conclusion,
-- because "16" stayed right-LOOKING at 27B: it is the KEY head count there,
-- while the quantity wanted was the VALUE head count of 48.  A constant that is
-- wrong AND plausible is the expensive kind.
--
-- Retargeting to Qwen3.5-9B first, with 27B still the end goal, would invite
-- exactly that again.  So every count that differs between the two models lives
-- here and nowhere else, and switching model is a change to `MODEL` alone.
--
-- THE TWO MODELS ARE ONE ARCHITECTURE.  The shipped 27B GGUF reports
-- `general.architecture = 'qwen35'`, so 3.8-27B and 3.5-9B are two scales of a
-- single design.  Every generic that sets DATAPATH WIDTH is identical between
-- them; only counts differ.  That is what makes the stepping stone cheap:
--
--   identical: linear key head dim 128, linear value head dim 128,
--              linear key heads 16, conv kernel 4, rms eps 1e-6,
--              attention key/value length 256, attention KV heads 4,
--              full_attention_interval 4
--   differs:   blocks, linear value heads, hidden, FFN, attention query heads
--
-- PROVENANCE.  The 27B row is read from the shipped GGUF's own metadata
-- (`gguf_dump.py --no-tensors` on Qwen3.8-27B-Q4_K_M.gguf), NOT from prose.
-- The 9B row is from `huggingface.co/Qwen/Qwen3.5-9B` `config.json`.  The two
-- sources name things differently and the mapping is worth stating, because
-- getting it backwards is the exact 16-versus-24 failure again:
--
--   GGUF `ssm.state_size`     = HF `linear_key_head_dim`     = 128
--   GGUF `ssm.group_count`    = HF `linear_num_key_heads`    = 16
--   GGUF `ssm.time_step_rank` = HF `linear_num_value_heads`  = 48 / 32
--   GGUF `ssm.inner_size`     = value heads x value head dim = 6144 / 4096
--
-- `ssm.time_step_rank` is NOT a dt rank here despite the name; it is the value
-- head count, and it is the field the whole state sweep is dimensioned on.
library ieee; use ieee.std_logic_1164.all;

package model_cfg_pkg is

  type model_cfg_t is record
    -- transformer shape
    blocks         : positive;  -- total blocks, GDN + attention
    attn_interval  : positive;  -- every Nth block is full attention
    hidden         : positive;  -- embedding_length
    ffn            : positive;  -- feed_forward_length
    -- Gated DeltaNet
    lin_key_heads  : positive;
    lin_val_heads  : positive;
    lin_head_dim   : positive;  -- key AND value head dim; equal in both models
    conv_kernel    : positive;
    -- attention
    attn_q_heads   : positive;
    attn_kv_heads  : positive;
    attn_head_dim  : positive;  -- key_length = value_length
    -- misc
    vocab          : positive;
    max_context    : positive;
  end record;

  -- Qwen3.5-9B.  Source: huggingface.co/Qwen/Qwen3.5-9B config.json.
  constant QWEN35_9B : model_cfg_t := (
    blocks        => 32,   attn_interval => 4,
    hidden        => 4096, ffn           => 12288,
    lin_key_heads => 16,   lin_val_heads => 32,   lin_head_dim  => 128,
    conv_kernel   => 4,
    attn_q_heads  => 16,   attn_kv_heads => 4,    attn_head_dim => 256,
    vocab         => 248320, max_context => 262144 );

  -- Qwen3.8-27B.  Source: the shipped GGUF's own metadata.
  constant QWEN38_27B : model_cfg_t := (
    blocks        => 64,   attn_interval => 4,
    hidden        => 5120, ffn           => 17408,
    lin_key_heads => 16,   lin_val_heads => 48,   lin_head_dim  => 128,
    conv_kernel   => 4,
    attn_q_heads  => 24,   attn_kv_heads => 4,    attn_head_dim => 256,
    vocab         => 248320, max_context => 262144 );

  -- THE BUILD TARGET.  Qwen3.5-9B is the bring-up vehicle because it fits ONE
  -- FK33 at INT4 (about 4.5 GB against 8 GB HBM), so N=1 and there is no
  -- collective at all: A, B, C and D can all be validated before the
  -- interconnect has to work.  Qwen3.8-27B remains the real target.
  constant MODEL : model_cfg_t := QWEN35_9B;

  -- Cards in the tensor-parallel group.  1 for the 9B bring-up.  The 27B needs
  -- 4, and that is a capacity requirement rather than an optimisation: 262,144
  -- context is 8.59 GB of KV cache, which is 11.86 GB per card at N=2 against
  -- 8 GB of HBM, and 5.94 GB at N=4.  See ~/GitHub/pcie-llm-hardware.
  constant NCARDS : positive := 1;

  -- ---- derived, so no caller re-derives them differently ----------------
  function gdn_layers   (m : model_cfg_t) return positive;
  function attn_layers  (m : model_cfg_t) return positive;
  function d_inner      (m : model_cfg_t) return positive;
  -- Value heads on THIS card.  This is the quantity the GDN state sweep is
  -- dimensioned on, and the one that was historically confused with the key
  -- head count.  Named to make that hard to repeat.
  function val_heads_per_card (m : model_cfg_t; n : positive) return positive;
  function key_heads_per_card (m : model_cfg_t; n : positive) return positive;
  -- Cycles the GDN state sweep costs per token on one card, at `lanes`
  -- elements per cycle.  Stated as a function because every hand-derivation of
  -- it in the spec has been wrong at least once.
  function gdn_sweep_cycles (m : model_cfg_t; n : positive; lanes : positive)
    return natural;

end package;

package body model_cfg_pkg is

  function attn_layers (m : model_cfg_t) return positive is
  begin
    return m.blocks / m.attn_interval;
  end function;

  function gdn_layers (m : model_cfg_t) return positive is
  begin
    return m.blocks - attn_layers(m);
  end function;

  function d_inner (m : model_cfg_t) return positive is
  begin
    return m.lin_val_heads * m.lin_head_dim;
  end function;

  function val_heads_per_card (m : model_cfg_t; n : positive) return positive is
  begin
    assert m.lin_val_heads mod n = 0
      report "model_cfg_pkg: linear value heads do not divide across the cards"
      severity failure;
    return m.lin_val_heads / n;
  end function;

  function key_heads_per_card (m : model_cfg_t; n : positive) return positive is
  begin
    assert m.lin_key_heads mod n = 0
      report "model_cfg_pkg: linear key heads do not divide across the cards"
      severity failure;
    return m.lin_key_heads / n;
  end function;

  function gdn_sweep_cycles (m : model_cfg_t; n : positive; lanes : positive)
    return natural is
    variable per_layer : natural;
  begin
    -- state is head_dim x head_dim per VALUE head, read and written once
    per_layer := (m.lin_head_dim * m.lin_head_dim
                  * val_heads_per_card(m, n)) / lanes;
    return per_layer * gdn_layers(m);
  end function;

end package body;
