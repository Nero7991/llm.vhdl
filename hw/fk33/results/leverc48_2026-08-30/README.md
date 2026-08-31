# TRACK LEVERC48 -- lever C drawn at the FK33 geometry

Full write-up: `docs/debugging/2026-08-30_leverc48-the-fk33-geometry.md`.

**All of this is `synth_design -mode out_of_context` on `matvec_core` plus
`report_*`. No place, no route, no programming, no hardware of any kind.**
Lever C's claim is about CLB PACKING and only `place_design` measures that;
nothing here is a fit verdict.

Vivado 2023.2, `xcvu33p-fsvh2104-2L-e`, `BLK=32`,
`MAXCOLS = MAXROWS_BFP = 17408`, clock period 3.3 ns created BEFORE
`synth_design`, `general.maxThreads 4`. Workstation only; the BC-250 lane was
held by another track. Every run gated on the `CBINFER_DONE` sentinel the script
itself writes and on a non-empty `report_utilization`, never on an exit code.

## Provenance

The headline pair was drawn against `rtl/matvec_core.vhd` md5
`163eab020fb0d5e00a3192344bea9e7f`, which is `git show HEAD:rtl/matvec_core.vhd`
at `3f1235c` and is byte-identical to the file TRACK CBINFER drew ROWS_IF
4/8/16 against on the BC-250. The tree was frozen with
`sim/cbinfer_variants.sh` and md5'd BEFORE any tool ran, and the draws used
`sim/leverc48_run.sh`, which never writes to the tree it reads.

## Files

| file | what it is |
|---|---|
| `results_r48.csv` | the headline pair, `v_regs_r48` and `v_dist_r48`, against HEAD's RTL |
| `results_controls.csv` | the neutrality controls (the same pair drawn again from the EDITED tree and from the COMMITTED tree) and the ROWS_IF 24 / 32 points |
| `results_wrapper_threading.csv` | `matvec_int4` OOC at ROWS_IF=48 with `CB_STYLE` on the `synth_design` command line: does the generic thread in SYNTHESIS, through two hierarchy levels |
| `util_mv4_regs.rpt`, `util_mv4_distributed.rpt` | the two wrapper-level reports behind that |
| `util_vars_pre_v_{regs,dist}_r{24,32}.rpt` | the two extra geometries, 768 and 1,024 lanes |
| `util_v_regs_r48.rpt` | full `report_utilization`, register bank, 1,536 lanes |
| `util_v_dist_r48.rpt` | full `report_utilization`, lever C, 1,536 lanes |
| `synth_8-7186_vs_mapping_r48.txt` | the trap: 101 log lines saying the RAM was not inferred, beside the 1,536 `RAM32M16` rows in the same run's mapping report, beside the object-level census that settles it |

## The one-line answer

MEASURED, `v_regs_r48` against `v_dist_r48`:

```
CLB LUT       121,139 -> 78,506    -42,633     (the ESTIMATE was 36,000-39,000)
LUT as memory   1,126 -> 13,414    +12,288  =  8.000 per lane, exactly
MUXF7          24,583 -> 0         -24,583
MUXF8          12,288 -> 0         -12,288  =  8.000 per lane, exactly
CLB FF         60,268 -> 73,463    +13,195     (DERIVED +13,200, residual -5)
BRAM / DSP / SRL                   unchanged
WNS @ 3.3 ns   +0.242 -> -0.027    -0.269      the FIRST geometry where lever C
                                               costs timing rather than gaining it
```

The structural per-lane constants extrapolated exactly from CBINFER's three
smaller geometries. The LUT total did not: both published models are low, by
8.6% and 14.9%, because the per-lane saving is not monotone in lane count. Six
geometries:

```
lanes    128     256     512     768    1024    1536
per-lane 29.109  27.707  26.051  25.353  28.391  27.756
```

**A constant per-lane saving, taken as the mean of the SAME three points both
models were fitted to, predicts 42,428 against the measured 42,633 -- an error
of 0.48%, against the fitted models' 8.6% and 14.9%.** The quantity is flat with
+-6.9% scatter and no direction; both fits read the scatter as a slope and
extrapolated it.

Separately, `matvec_int4` (the entity a board top instantiates) saves **45,768
LUT**, and at the real 5.0 ns build period lever C costs only **0.029 ns** with
both styles holding over 1.18 ns of margin. `cb_reg*` there goes from 6,144
flip-flops and no RAM to 26,112 RAM cells and no flip-flops, which is how the
generic is known to arrive through two hierarchy levels in synthesis and not
only in simulation.
