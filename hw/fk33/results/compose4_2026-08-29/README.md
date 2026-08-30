# TRACK COMPOSE4 -- artefacts, 2026-08-29

Board row **N3**: an RTL top that composes subsystems A+B+C+D for the card, taken
through **place and route**, so TRACK DISTRAM's post-synthesis 217,381 CLB LUT
for B+C+D stops being a sum of seven independent estimates.

**NO HARDWARE was touched at any point.** `synth_design`, `opt_design`,
`place_design`, `phys_opt_design`, `route_design` and `report_*` only.

## What produced these files

| file | produced by |
|---|---|
| `hw/fk33/gen_compose4_top.py` | generator for the composed top (in the repo) |
| `hw/fk33/rtl/compose4_top.vhd` | its output, checked in (in the repo) |
| `sim/ooc_compose4_pnr.tcl` | the Vivado flow, four stages (in the repo) |
| `sim/ooc_compose4_run.sh` | the runner, one Vivado at a time (in the repo) |
| `PINNED_SHA` | the tree every number here was measured against |
| `elab.stdout`, `synth.stdout`, `impl_*.stdout` | raw Vivado stdout per stage |
| `util_*`, `timing_*`, `route_status_*`, `drc_*`, `congestion_*`, `pbutil_*` | Vivado reports |
| `bufg_probe.txt` | the measurement that made the RTL BUFGCE necessary |

## Reproducing

The composed top instantiates `ooc_normadapt`, which is GENERATED from
`rtl/llama_top.vhd` by `sim/ooc_normadapt_extract.py` (TRACK NORMADAPT) and is
deliberately not in `rtl/`. So the order is:

```
git archive <PINNED_SHA> rtl hw/fk33/rtl sim | tar -x -C <scratch>/tree
cd <scratch>/tree
python3 <repo>/sim/ooc_normadapt_extract.py rtl/llama_top.vhd \
        rtl/ooc_normadapt_top.vhd ooc_normadapt
python3 <repo>/hw/fk33/gen_compose4_top.py --rtl rtl --fk33-rtl hw/fk33/rtl \
        --out hw/fk33/rtl/compose4_top.vhd
cmp <repo>/hw/fk33/rtl/compose4_top.vhd hw/fk33/rtl/compose4_top.vhd
bash <repo>/sim/ooc_compose4_run.sh <scratch>
```

The `cmp` is not decoration. Synthesising without copying the changed file into
the tree yields a plausible wrong number, and that has cost this project time
already.

The write-up is `docs/debugging/2026-08-29_compose4-place-and-route.md`.
