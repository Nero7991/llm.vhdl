-- Pins model_cfg_pkg against numbers established elsewhere and independently.
--
-- A shape package that computes the wrong sweep is worse than no package,
-- because every consumer would then be consistently wrong and the disagreement
-- that usually exposes such a bug would never appear.  The 589,824 figure in
-- particular has its own history: it was WITHDRAWN on 2026-08-26 as
-- self-contradictory and then restored on 2026-08-27 when the contradiction
-- turned out to be an exact coincidence, so it is checked here rather than
-- trusted.
library ieee; use ieee.std_logic_1164.all;
use work.model_cfg_pkg.all;

entity tb_model_cfg is end entity;

architecture sim of tb_model_cfg is
  procedure chk(name : string; got, want : integer) is
  begin
    assert got = want
      report "tb_model_cfg: " & name & " is " & integer'image(got)
           & ", expected " & integer'image(want)
      severity failure;
    report "  ok  " & name & " = " & integer'image(got);
  end procedure;
begin
  main : process
  begin
    report "---- Qwen3.8-27B, the figures the project already verified ----";
    chk("27B gdn_layers",  gdn_layers(QWEN38_27B),  48);
    chk("27B attn_layers", attn_layers(QWEN38_27B), 16);
    -- must equal the GGUF's own ssm.inner_size = 6144
    chk("27B d_inner",     d_inner(QWEN38_27B),     6144);
    chk("27B val heads per card, N=2", val_heads_per_card(QWEN38_27B, 2), 24);
    chk("27B key heads per card, N=2", key_heads_per_card(QWEN38_27B, 2),  8);
    -- The state sweep, restored 2026-08-27 after being wrongly withdrawn.
    -- 128*128*24/32 = 12,288 per layer, x 48 layers.
    chk("27B sweep, N=2 LANES=32", gdn_sweep_cycles(QWEN38_27B, 2, 32), 589824);
    -- Four cards halve it, which is what makes N=4 relieve DSP and bandwidth
    -- at once. Capacity is the reason for N=4; this is the side effect.
    chk("27B val heads per card, N=4", val_heads_per_card(QWEN38_27B, 4), 12);
    chk("27B sweep, N=4 LANES=32", gdn_sweep_cycles(QWEN38_27B, 4, 32), 294912);

    report "---- Qwen3.5-9B, the bring-up target ----";
    chk("9B gdn_layers",  gdn_layers(QWEN35_9B),  24);
    chk("9B attn_layers", attn_layers(QWEN35_9B),  8);
    -- 32 value heads x 128 = 4096, and equals hidden here by coincidence, not
    -- by construction; they are 6144 vs 5120 at 27B.
    chk("9B d_inner",     d_inner(QWEN35_9B),     4096);
    chk("9B val heads per card, N=1", val_heads_per_card(QWEN35_9B, 1), 32);
    chk("9B key heads per card, N=1", key_heads_per_card(QWEN35_9B, 1), 16);
    -- 128*128*32/32 = 16,384 per layer, x 24 layers. Two thirds of the 27B's
    -- per-card sweep, on a single card with no collective at all.
    chk("9B sweep, N=1 LANES=32", gdn_sweep_cycles(QWEN35_9B, 1, 32), 393216);

    report "---- invariants that make the retarget a generic change ----";
    chk("lin_head_dim equal",  QWEN35_9B.lin_head_dim,  QWEN38_27B.lin_head_dim);
    chk("lin_key_heads equal", QWEN35_9B.lin_key_heads, QWEN38_27B.lin_key_heads);
    chk("conv_kernel equal",   QWEN35_9B.conv_kernel,   QWEN38_27B.conv_kernel);
    chk("attn_head_dim equal", QWEN35_9B.attn_head_dim, QWEN38_27B.attn_head_dim);
    chk("attn_kv_heads equal", QWEN35_9B.attn_kv_heads, QWEN38_27B.attn_kv_heads);
    chk("attn_interval equal", QWEN35_9B.attn_interval, QWEN38_27B.attn_interval);

    report "tb_model_cfg: PASS";
    wait;
  end process;
end architecture;
