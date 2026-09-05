-- shape_probe.vhd -- print the 9B shape AS THE PACKAGE COMPUTES IT.
--
-- Deliberately NOT named tb_*.  sim/regress.sh auto-discovers `tb_*.vhd` and
-- would turn this into a gate row of its own; it is not a bench and has no
-- checks.  It is the ORACLE half of sim/check_model_shape.py.
--
-- WHY THIS EXISTS RATHER THAN THE ARITHMETIC IN PYTHON.  The defect being
-- guarded is that the 9B shape is hand-transcribed at three independent
-- sites (rtl/model_cfg_pkg.vhd's record, the units' generic defaults, and
-- hw/fk33/gen_compose4_top.py's literals for c_attn).  Re-deriving
-- `blocks / attn_interval` in the checker would make the checker a FOURTH
-- transcription, and a guard that restates the thing it guards agrees with
-- it by construction.  So the expected values come from GHDL evaluating
-- model_cfg_pkg's own functions, and the checker only compares.
--
-- MEASURED 2026-09-04: at MODEL = QWEN35_9B, NCARDS = 1 the composed top's
-- literals already MATCH.  The shape is right; nothing holds it there.

library ieee;
use ieee.std_logic_1164.all;
use work.model_cfg_pkg.all;

entity shape_probe is
end entity;

architecture rtl of shape_probe is
begin
  process
  begin
    report "SHAPE ncards="        & integer'image(NCARDS);
    report "SHAPE blocks="        & integer'image(MODEL.blocks);
    report "SHAPE attn_interval=" & integer'image(MODEL.attn_interval);
    report "SHAPE hidden="        & integer'image(MODEL.hidden);
    report "SHAPE ffn="           & integer'image(MODEL.ffn);
    report "SHAPE conv_kernel="   & integer'image(MODEL.conv_kernel);
    -- attention, exactly as rtl/attn_block.vhd:199-206 states the derivation
    report "ATTN HEAD_DIM="       & integer'image(MODEL.attn_head_dim);
    report "ATTN N_QH="           & integer'image(MODEL.attn_q_heads / NCARDS);
    report "ATTN N_KVH="          & integer'image(MODEL.attn_kv_heads);
    report "ATTN LAYERS="         & integer'image(attn_layers(MODEL));
    -- GDN.  The per-card functions are the semantically correct ones; at
    -- NCARDS = 1 they equal the totals, so this file cannot DISCRIMINATE
    -- between the two at the current build target.  Stated rather than
    -- implied: a 27B/N>1 retarget is where that distinction starts to bite,
    -- and model_cfg_pkg:97-99 records that it has been confused before.
    report "GDN KEY_HEADS="       & integer'image(key_heads_per_card(MODEL, NCARDS));
    report "GDN VAL_HEADS="       & integer'image(val_heads_per_card(MODEL, NCARDS));
    report "GDN DIM="             & integer'image(MODEL.lin_head_dim);
    report "GDN LAYERS="          & integer'image(gdn_layers(MODEL));
    report "SHAPE_PROBE_DONE";
    wait;
  end process;
end architecture;
