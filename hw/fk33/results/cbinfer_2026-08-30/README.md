# CBINFER, 2026-08-30

Raw artefacts behind
`docs/debugging/2026-08-30_cbinfer-does-cb-infer-lutram.md`.

All drawn on the BC-250 (`cachyos-bc250`), Vivado 2023.2, part
`xcvu33p-fsvh2104-2L-e`, `synth_design -mode out_of_context -top matvec_core`,
BLK=32, MAXCOLS=MAXROWS_BFP=17408, clock period 3.3 ns constrained BEFORE
synthesis, `general.maxThreads 4`. No place, no route, no hardware.

The RTL under test is `rtl/matvec_core.vhd` md5
`163eab020fb0d5e00a3192344bea9e7f`, plus five edited variants of it built by
`sim/cbinfer_variants.sh`.

| file | what it is |
|---|---|
| `util_v_*.rpt` | `report_utilization` per variant per geometry. Read section 1 (CLB Logic) AND section 8 (Primitives) and check they agree |
| `distributed_ram_final_mapping.txt` | the `Inference` column per variant. This is the only artefact that says WHICH signal the memory came from and WHY the tool built it |
| `synth_8-7186_warning_is_wrong.txt` | the log message that says `cb` was NOT inferred as RAM, beside the mapping rows for the same objects showing that it was. Read the census, not the log |
| `object_level_cb_census.txt` | `get_cells` counts of RAM cells and flip-flops carrying `cb`'s name. RAM=0/FF=1024 for the shipping style, RAM=4352/FF=0 for lever C |
| `results_r4_r16.csv` | the six-variant sweep at ROWS_IF=4 plus the ROWS_IF=16 pair. **Its `muxf7`, `muxf8`, `fdre` and `ram_cells` columns are all zero and are WRONG** -- the first version of the parser required a four-column Primitives table and the table has three. The correct census for these rows is in the `util_*.rpt` files and in section 2.3 of the write-up |
| `results_r8_objcensus.csv` | ROWS_IF=8, drawn with the fixed parser and the object-level `cb` census columns |

Naming: `v_regs` is the shipping design byte for byte; `v_dist` is
`CB_STYLE = "distributed"`; `_noattr` deletes `ram_style` (and, on the
distributed side, `dont_touch`) from `cb`; `_lit` replaces the function-derived
attribute values with string literals; `_nodt` deletes `dont_touch` rather than
setting it `"false"`; `_rep` is a repeat draw of the baseline, the determinism
control.
