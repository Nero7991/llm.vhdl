# lutdiet_2026-08-29 -- artefacts for TRACK LUTDIET

Write-up: `docs/debugging/2026-08-29_lutdiet-flat-vector-ports.md`.
Pinned tree: `01a9e95e28fa0f0fd05b5aa7d09da8feb932ff08`.
Part `xcvu33p-fsvh2104-2L-e`, Vivado 2023.2 (Build 4029153), 5.0 ns.
**No hardware was touched by anything in this directory.**

| file | what it is |
|---|---|
| `result_*.csv` | one row per synthesis run: LUT / FF / BRAM / URAM / DSP / CARRY8 / F7 / F8 / WNS, post-synth and post-`opt_design` |
| `census_*.txt` | the netlist cell-name census: LUT, MUXF7, MUXF8, FF and CARRY8 primitives grouped by the RTL signal root Vivado named them after, with a raw example cell per row so the root heuristic can be audited |
| `synthutil_*.rpt`, `util_*.rpt` | `report_utilization` before and after `opt_design` |
| `synthutil_hier_*.rpt`, `util_hier_*.rpt` | the same, `-hierarchical` |
| `timing_*.rpt` | `report_timing_summary` |
| `mem_*.txt` | peak RSS of the whole Vivado process tree for that run |
| `run_*.log`, `vivado_*.log` | full transcripts |
| `rtl/rmsnorm_rs_mem.vhd` | MEASUREMENT ARTEFACT. `rmsnorm_rs` with its three flat whole-vector ports replaced by LANES-way banked block RAM. Derived mechanically by `mkmem.py`; **do not edit by hand and do not move into `rtl/`** |
| `rtl/rmsnorm_rs_hotw.vhd` | MEASUREMENT ARTEFACT. `rmsnorm_rs` with the flat register and the ORIGINAL port list kept, and only the write decode changed. Derived mechanically by `mkhotw.py` |
| `rtl/lutdiet_rms_flat.vhd` | the same-contract control: the flat unit plus the flat vector storage its parent must supply, behind the identical streaming port list |
| `rtl/tb_lutdiet_rmsmem.vhd`, `rtl/tb_lutdiet_hotw.vhd` | the equivalence benches. **Deliberately NOT in `sim/`**: a new `sim/tb_*.vhd` is auto-discovered into the shared gate, and these need RTL that is not in `rtl/` |
| `mkmem.py`, `mkhotw.py` | the transforms. Each asserts every substitution fired the expected number of times and aborts otherwise, so the diff is the measurement's definition rather than a retyped file |
| `run_equiv.sh` | GHDL bit-exactness run, both variants against the original |
| `run_mutants.sh` | the teeth-check: three broken variants that the bench must catch |
| `project.py` | reads the CSVs and prints the composition arithmetic. Everything it prints that is not read from a CSV is DERIVED with the arithmetic shown |

Reproduce one synthesis point:

    LUTDIET_FLATTEN=none LUTDIET_CENSUS=1 \
      bash sim/ooc_lutdiet_run.sh <tag> <top> <outdir> <rtldir> N=4096 LANES=4

Reproduce the equivalence and the teeth-check:

    bash hw/fk33/results/lutdiet_2026-08-29/run_equiv.sh   <pinned-rtl> <variant-rtl> <scratch>
    bash hw/fk33/results/lutdiet_2026-08-29/run_mutants.sh <pinned-rtl> <variant-rtl> <scratch>
